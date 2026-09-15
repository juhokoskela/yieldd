package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/nacl/box"
)

var runnerNamePattern = regexp.MustCompile(`^yieldd-bootstrap-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func stringsUpperUUID(name string) string {
	return strings.ToUpper(strings.ReplaceAll(strings.TrimPrefix(name, "yieldd-bootstrap-"), "-", ""))
}

type workflowRun struct {
	ID           int64  `json:"id"`
	DisplayTitle string `json:"display_title"`
	Status       string `json:"status"`
	Conclusion   string `json:"conclusion"`
}

type apiError struct{ status int }

func (e *apiError) Error() string { return fmt.Sprintf("GitHub API returned HTTP %d", e.status) }
func notFound(err error) bool     { var e *apiError; return errors.As(err, &e) && e.status == 404 }

type githubAPI struct {
	client                      *http.Client
	base, token, infrastructure string
}

func (g *githubAPI) request(ctx context.Context, method, path string, body, output any) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	request, err := http.NewRequestWithContext(ctx, method, g.base+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+g.token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("Content-Type", "application/json")
	response, err := g.client.Do(request)
	if err != nil {
		return fmt.Errorf("GitHub request failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return &apiError{response.StatusCode}
	}
	if output == nil {
		return nil
	}
	data, err = io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	if err != nil {
		return err
	}
	if len(data) > 2<<20 {
		return errors.New("GitHub response exceeded size limit")
	}
	if err := json.Unmarshal(data, output); err != nil {
		return errors.New("invalid GitHub response")
	}
	return nil
}

func (g *githubAPI) path(suffix string) string {
	return "/repos/" + g.infrastructure + "/actions/" + suffix
}

func (g *githubAPI) putSecret(ctx context.Context, name, value string) error {
	var key struct {
		ID  string `json:"key_id"`
		Key string `json:"key"`
	}
	if err := g.request(ctx, "GET", g.path("secrets/public-key"), nil, &key); err != nil {
		return err
	}
	decoded, err := base64.StdEncoding.DecodeString(key.Key)
	if err != nil || len(decoded) != 32 || key.ID == "" {
		return errors.New("invalid GitHub secret encryption key")
	}
	var public [32]byte
	copy(public[:], decoded)
	encrypted, err := box.SealAnonymous(nil, []byte(value), &public, rand.Reader)
	if err != nil {
		return err
	}
	return g.request(ctx, "PUT", g.path("secrets/"+name), struct {
		KeyID string `json:"key_id"`
		Value string `json:"encrypted_value"`
	}{key.ID, base64.StdEncoding.EncodeToString(encrypted)}, nil)
}

func (g *githubAPI) deleteSecret(ctx context.Context, name string) error {
	err := g.request(ctx, "DELETE", g.path("secrets/"+name), nil, nil)
	if notFound(err) {
		return nil
	}
	return err
}

func (g *githubAPI) dispatch(ctx context.Context, l *lease, fallback string) error {
	return g.request(ctx, "POST", g.path("workflows/runner-bootstrap.yml/dispatches"), struct {
		Ref    string            `json:"ref"`
		Inputs map[string]string `json:"inputs"`
	}{"main", map[string]string{"runner-name": l.Name, "fallback-runner": fallback}}, nil)
}

func (g *githubAPI) findRun(ctx context.Context, l *lease) (*workflowRun, error) {
	var match *workflowRun
	for page := 1; page <= 10; page++ {
		var result struct {
			Runs []workflowRun `json:"workflow_runs"`
		}
		query := url.Values{"event": {"workflow_dispatch"}, "branch": {"main"}, "created": {">=" + l.Created.Add(-time.Minute).UTC().Format(time.RFC3339)}, "per_page": {"100"}, "page": {fmt.Sprint(page)}}
		if err := g.request(ctx, "GET", g.path("workflows/runner-bootstrap.yml/runs?")+query.Encode(), nil, &result); err != nil {
			return nil, err
		}
		for _, run := range result.Runs {
			if run.DisplayTitle == "Bootstrap "+l.Name {
				if match != nil && match.ID != run.ID {
					return nil, errors.New("multiple bootstrap runs match the provisioning lease")
				}
				copy := run
				match = &copy
			}
		}
		if len(result.Runs) < 100 {
			return match, nil
		}
	}
	return nil, errors.New("bootstrap run search exceeded its page limit")
}

func (g *githubAPI) getRun(ctx context.Context, id int64) (*workflowRun, error) {
	var run workflowRun
	if err := g.request(ctx, "GET", g.path(fmt.Sprintf("runs/%d", id)), nil, &run); err != nil {
		return nil, err
	}
	return &run, nil
}

func (g *githubAPI) cancelRun(ctx context.Context, id int64) error {
	return g.request(ctx, "POST", g.path(fmt.Sprintf("runs/%d/cancel", id)), nil, nil)
}

func (g *githubAPI) runnerBusy(ctx context.Context, repository string, id int) (bool, error) {
	var runner struct {
		ID   int   `json:"id"`
		Busy *bool `json:"busy"`
	}
	err := g.request(ctx, "GET", fmt.Sprintf("/repos/%s/actions/runners/%d", repository, id), nil, &runner)
	if notFound(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if runner.ID != id || runner.Busy == nil {
		return false, errors.New("invalid runner status response; cleanup refused")
	}
	return *runner.Busy, nil
}
