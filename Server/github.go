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
	ID           int64     `json:"id"`
	DisplayTitle string    `json:"display_title"`
	Status       string    `json:"status"`
	Conclusion   string    `json:"conclusion"`
	CreatedAt    time.Time `json:"created_at"`
	observedAt   time.Time
}

func (r *workflowRun) age() (time.Duration, error) {
	if r.CreatedAt.IsZero() || r.observedAt.IsZero() || r.observedAt.Before(r.CreatedAt) {
		return 0, errors.New("workflow age is unavailable or invalid; retry with --recover to request cancellation")
	}
	return r.observedAt.Sub(r.CreatedAt), nil
}

type apiError struct{ status int }

func (e *apiError) Error() string { return fmt.Sprintf("GitHub API returned HTTP %d", e.status) }

func hasHTTPStatus(err error, status int) bool {
	var e *apiError
	return errors.As(err, &e) && e.status == status
}

func dispatchRejected(err error) bool {
	var e *apiError
	if !errors.As(err, &e) {
		return false
	}
	// Only explicit client rejections establish that no workflow was queued.
	// Timeouts, redirects, server failures, and invalid success responses remain ambiguous.
	switch e.status {
	case http.StatusBadRequest, http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound, http.StatusUnprocessableEntity, http.StatusTooManyRequests:
		return true
	default:
		return false
	}
}

func (r *workflowRun) matches(l *lease) bool {
	return r != nil && r.ID > 0 && (l.RunID == 0 || r.ID == l.RunID) && r.DisplayTitle == "Bootstrap "+l.Name
}

type githubAPI struct {
	client                      *http.Client
	base, token, infrastructure string
}

func (g *githubAPI) request(ctx context.Context, method, path string, body, output any) error {
	_, err := g.requestWithHeaders(ctx, method, path, body, output)
	return err
}

func (g *githubAPI) requestWithHeaders(ctx context.Context, method, path string, body, output any) (http.Header, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			return nil, err
		}
	}
	request, err := http.NewRequestWithContext(ctx, method, g.base+path, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+g.token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("Content-Type", "application/json")
	response, err := g.client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("GitHub request failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return response.Header, &apiError{response.StatusCode}
	}
	if output == nil {
		return response.Header, nil
	}
	data, err = io.ReadAll(io.LimitReader(response.Body, (2<<20)+1))
	if err != nil {
		return response.Header, err
	}
	if len(data) > 2<<20 {
		return response.Header, errors.New("GitHub response exceeded size limit")
	}
	if err := json.Unmarshal(data, output); err != nil {
		return response.Header, errors.New("invalid GitHub response")
	}
	return response.Header, nil
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
	if hasHTTPStatus(err, http.StatusNotFound) {
		return nil
	}
	return err
}

func (g *githubAPI) dispatch(ctx context.Context, l *lease, fallback string) (int64, error) {
	var result struct {
		RunID int64 `json:"workflow_run_id"`
	}
	err := g.request(ctx, "POST", g.path("workflows/runner-bootstrap.yml/dispatches"), struct {
		Ref              string            `json:"ref"`
		Inputs           map[string]string `json:"inputs"`
		ReturnRunDetails bool              `json:"return_run_details"`
	}{"main", map[string]string{"runner-name": l.Name, "fallback-runner": fallback}, true}, &result)
	if err != nil {
		return 0, err
	}
	if result.RunID <= 0 {
		return 0, errors.New("dispatch response lacks a valid workflow run ID")
	}
	return result.RunID, nil
}

func (g *githubAPI) findRun(ctx context.Context, l *lease) (*workflowRun, error) {
	var match *workflowRun
	for page := 1; page <= 10; page++ {
		var result struct {
			Runs []workflowRun `json:"workflow_runs"`
		}
		query := url.Values{"event": {"workflow_dispatch"}, "branch": {"main"}, "per_page": {"100"}, "page": {fmt.Sprint(page)}}
		headers, err := g.requestWithHeaders(ctx, "GET", g.path("workflows/runner-bootstrap.yml/runs?")+query.Encode(), nil, &result)
		if err != nil {
			return nil, err
		}
		for _, run := range result.Runs {
			if run.DisplayTitle != "Bootstrap "+l.Name {
				continue
			}
			if match != nil && match.ID != run.ID {
				return nil, errors.New("multiple bootstrap runs match the provisioning lease")
			}
			run.observedAt, _ = http.ParseTime(headers.Get("Date"))
			match = &run
		}
		if len(result.Runs) < 100 {
			return match, nil
		}
	}
	return nil, errors.New("bootstrap run search exceeded its page limit")
}

func (g *githubAPI) getRun(ctx context.Context, id int64) (*workflowRun, error) {
	var run workflowRun
	headers, err := g.requestWithHeaders(ctx, "GET", g.path(fmt.Sprintf("runs/%d", id)), nil, &run)
	if err != nil {
		return nil, err
	}
	run.observedAt, _ = http.ParseTime(headers.Get("Date"))
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
	if hasHTTPStatus(err, http.StatusNotFound) {
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
