package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/nacl/box"
)

const fixtureRunner = "yieldd-bootstrap-01234567-89ab-cdef-0123-456789abcdef"

func testAPI(t *testing.T, handler http.HandlerFunc) *githubAPI {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	client := server.Client()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &githubAPI{base: server.URL, token: "server-only-token", infrastructure: "example/infrastructure", client: client}
}

func TestCredentialAndDispatchHTTPContract(t *testing.T) {
	public, private, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	l := &lease{Name: fixtureRunner, Created: time.Now()}
	// This fixture is also asserted by yieldd-infra's credential-name.test.cjs.
	if l.secretName() != "YIELDD_JIT_0123456789ABCDEF0123456789ABCDEF" {
		t.Fatal(l.secretName())
	}
	var methods []string
	api := testAPI(t, func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method)
		if r.Header.Get("Authorization") != "Bearer server-only-token" {
			t.Error("missing coordinator authentication")
		}
		switch r.Method {
		case "GET":
			if r.URL.Path != "/repos/example/infrastructure/actions/secrets/public-key" {
				t.Error(r.URL.Path)
			}
			json.NewEncoder(w).Encode(map[string]string{"key_id": "key-1", "key": base64.StdEncoding.EncodeToString(public[:])})
		case "PUT":
			if r.URL.Path != "/repos/example/infrastructure/actions/secrets/"+l.secretName() {
				t.Error(r.URL.Path)
			}
			var body struct {
				KeyID string `json:"key_id"`
				Value string `json:"encrypted_value"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
				return
			}
			encrypted, err := base64.StdEncoding.DecodeString(body.Value)
			if err != nil {
				t.Error(err)
				return
			}
			plaintext, ok := box.OpenAnonymous(nil, encrypted, public, private)
			if !ok || string(plaintext) != "private-jit" || body.KeyID != "key-1" {
				t.Error("invalid sealed credential")
			}
			w.WriteHeader(201)
		case "POST":
			if r.URL.Path != "/repos/example/infrastructure/actions/workflows/runner-bootstrap.yml/dispatches" {
				t.Error(r.URL.Path)
			}
			data, err := io.ReadAll(r.Body)
			if err != nil {
				t.Error(err)
				return
			}
			var body struct {
				Ref              string
				Inputs           map[string]string
				ReturnRunDetails bool `json:"return_run_details"`
			}
			if err := json.Unmarshal(data, &body); err != nil {
				t.Error(err)
				return
			}
			if body.Ref != "main" || !body.ReturnRunDetails || len(body.Inputs) != 2 || body.Inputs["runner-name"] != l.Name || body.Inputs["fallback-runner"] != `["self-hosted","disposable"]` {
				t.Error(string(data))
			}
			if strings.Contains(string(data), "private-jit") || strings.Contains(string(data), "server-only-token") {
				t.Error("credential exposed in dispatch")
			}
			fmt.Fprint(w, `{"workflow_run_id":99,"run_url":"https://api.github.com/repos/example/infrastructure/actions/runs/99","html_url":"https://github.com/example/infrastructure/actions/runs/99"}`)
		case "DELETE":
			if r.URL.Path != "/repos/example/infrastructure/actions/secrets/"+l.secretName() {
				t.Error(r.URL.Path)
			}
			w.WriteHeader(404)
		default:
			t.Error(r.Method)
		}
	})
	if err := api.putSecret(t.Context(), l.secretName(), "private-jit"); err != nil {
		t.Fatal(err)
	}
	if id, err := api.dispatch(t.Context(), l, `["self-hosted","disposable"]`); err != nil || id != 99 {
		t.Fatal(id, err)
	}
	if err := api.deleteSecret(t.Context(), l.secretName()); err != nil {
		t.Fatal(err)
	}
	if strings.Join(methods, ",") != "GET,PUT,POST,DELETE" {
		t.Fatal(methods)
	}
}

func TestDispatchDoesNotRetryOrFollowRedirects(t *testing.T) {
	for _, status := range []int{302, 429, 503} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			calls := 0
			api := testAPI(t, func(w http.ResponseWriter, r *http.Request) {
				calls++
				w.Header().Set("Location", "/redirect")
				w.Header().Set("Retry-After", "0")
				w.WriteHeader(status)
				fmt.Fprint(w, "private-jit server-only-token")
			})
			_, err := api.dispatch(t.Context(), &lease{Name: fixtureRunner}, `"ubuntu-24.04"`)
			if err == nil || calls != 1 {
				t.Fatal(calls, err)
			}
			if strings.Contains(err.Error(), "private-jit") || strings.Contains(err.Error(), "server-only-token") {
				t.Fatal("response leaked", err)
			}
		})
	}
}

func TestRunSearchPaginatesAndRejectsDuplicateIdentities(t *testing.T) {
	for _, duplicate := range []bool{false, true} {
		t.Run(fmt.Sprint(duplicate), func(t *testing.T) {
			calls := 0
			api := testAPI(t, func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.URL.Query().Get("event") != "workflow_dispatch" || r.URL.Query().Get("branch") != "main" || r.URL.Query().Has("created") {
					t.Error(r.URL.RawQuery)
				}
				runs := []workflowRun{{ID: 99, DisplayTitle: "Bootstrap " + fixtureRunner, Status: "queued"}}
				if r.URL.Query().Get("page") == "1" {
					runs = make([]workflowRun, 100)
					if duplicate {
						runs[0] = workflowRun{ID: 98, DisplayTitle: "Bootstrap " + fixtureRunner}
					}
				}
				json.NewEncoder(w).Encode(map[string]any{"workflow_runs": runs})
			})
			run, err := api.findRun(t.Context(), &lease{Name: fixtureRunner, Created: time.Now()})
			if calls != 2 {
				t.Fatal(calls)
			}
			if duplicate {
				if err == nil {
					t.Fatal("accepted duplicate identity")
				}
				return
			}
			if err != nil || run == nil || run.ID != 99 {
				t.Fatal(run, err)
			}
		})
	}
}

func TestRunSearchIgnoresCoordinatorClock(t *testing.T) {
	serverTime := time.Date(2026, time.September, 15, 12, 0, 0, 0, time.UTC)
	for _, skew := range []time.Duration{-24 * time.Hour, 24 * time.Hour} {
		t.Run(skew.String(), func(t *testing.T) {
			api := testAPI(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Query().Has("created") {
					// Model the server excluding a run older than the requested lower bound.
					lower, err := time.Parse(time.RFC3339, strings.TrimPrefix(r.URL.Query().Get("created"), ">="))
					if err != nil {
						t.Error(err)
					}
					if serverTime.Before(lower) {
						fmt.Fprint(w, `{"workflow_runs":[]}`)
						return
					}
					t.Error("run discovery must not depend on the coordinator clock")
				}
				json.NewEncoder(w).Encode(map[string]any{"workflow_runs": []workflowRun{
					{ID: 99, DisplayTitle: "Bootstrap " + fixtureRunner, Status: "completed", Conclusion: "success"},
				}})
			})
			run, err := api.findRun(t.Context(), &lease{Name: fixtureRunner, Created: serverTime.Add(skew)})
			if err != nil || run == nil || run.ID != 99 {
				t.Fatal("clock skew hid the matching bootstrap", run, err)
			}
		})
	}
}

func TestRunnerStatusRequiresExplicitMatchingIdentity(t *testing.T) {
	for _, tc := range []struct {
		body        string
		status      int
		busy, fails bool
	}{
		{`{"id":7,"busy":true}`, 200, true, false},
		{`{"id":7,"busy":false}`, 200, false, false},
		{`{}`, 200, false, true},
		{`{"id":8,"busy":false}`, 200, false, true},
		{`{"id":7,"busy":null}`, 200, false, true},
		{``, 404, false, false},
		{``, 403, false, true},
	} {
		t.Run(fmt.Sprint(tc.status)+tc.body, func(t *testing.T) {
			api := testAPI(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(tc.status); fmt.Fprint(w, tc.body) })
			busy, err := api.runnerBusy(t.Context(), "example/application", 7)
			if (err != nil) != tc.fails || busy != tc.busy {
				t.Fatal(busy, err)
			}
		})
	}
}

func TestWorkflowAgeRequiresConsistentServerTimestamps(t *testing.T) {
	created := time.Date(2026, time.September, 15, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name              string
		created, observed time.Time
	}{
		{"missing-creation", time.Time{}, created},
		{"missing-response-date", created, time.Time{}},
		{"creation-after-response", created, created.Add(-time.Minute)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			run := &workflowRun{CreatedAt: tc.created, observedAt: tc.observed}
			if _, err := run.age(); err == nil {
				t.Fatal("invalid server timestamps accepted")
			}
		})
	}
}

func TestResponseSizeAndCancellation(t *testing.T) {
	api := testAPI(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, strings.Repeat(" ", (2<<20)+1)) })
	if _, err := api.getRun(t.Context(), 7); err == nil || !strings.Contains(err.Error(), "size limit") {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := api.dispatch(ctx, &lease{Name: fixtureRunner}, `"ubuntu-24.04"`); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestDispatchRejectionClassification(t *testing.T) {
	for _, tc := range []struct {
		status   int
		rejected bool
	}{
		{400, true}, {401, true}, {403, true}, {404, true}, {422, true}, {429, true},
		{302, false}, {408, false}, {499, false}, {500, false}, {502, false}, {503, false}, {504, false},
	} {
		t.Run(fmt.Sprint(tc.status), func(t *testing.T) {
			api := testAPI(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(tc.status) })
			id, err := api.dispatch(t.Context(), &lease{Name: fixtureRunner}, testConfig.Fallback)
			if err == nil || id != 0 || dispatchRejected(fmt.Errorf("dispatch: %w", err)) != tc.rejected {
				t.Fatal(id, err)
			}
		})
	}
	for _, err := range []error{context.Canceled, context.DeadlineExceeded, io.ErrUnexpectedEOF} {
		if dispatchRejected(err) {
			t.Fatal("ambiguous transport error treated as rejection", err)
		}
	}
}

func TestInvalidDispatchSuccessRemainsAmbiguous(t *testing.T) {
	for _, body := range []string{"", `{}`, `null`, `{"workflow_run_id":0}`, `{"workflow_run_id":-1}`, `{"workflow_run_id":"99"}`, `{"workflow_run_id":99`} {
		t.Run(body, func(t *testing.T) {
			api := testAPI(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) })
			id, err := api.dispatch(t.Context(), &lease{Name: fixtureRunner}, testConfig.Fallback)
			if err == nil || id != 0 || dispatchRejected(err) {
				t.Fatal(id, err)
			}
		})
	}
}
