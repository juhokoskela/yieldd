package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/actions/scaleset"
	"github.com/golang-jwt/jwt/v4"
	"github.com/hashicorp/go-retryablehttp"
)

func TestCoordinatorSessionsCloseWithinOneBudget(t *testing.T) {
	for _, delay := range []time.Duration{14 * time.Second, time.Minute} {
		t.Run(delay.String(), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				const queues = 32
				var attempted, completed atomic.Int32
				var workers []*platformCoordinator
				for range queues {
					store, err := openStore(filepath.Join(t.TempDir(), "state"))
					if err != nil {
						t.Fatal(err)
					}
					session := shutdownSession(t, func(ctx context.Context) error {
						attempted.Add(1)
						select {
						case <-time.After(delay):
							completed.Add(1)
							return nil
						case <-ctx.Done():
							return ctx.Err()
						}
					})
					workers = append(workers, &platformCoordinator{store: store, session: session})
				}
				started := time.Now()
				closeCoordinators(workers...)
				if elapsed := time.Since(started); elapsed != min(delay, 15*time.Second) {
					t.Errorf("shutdown took %v for %d queues", elapsed, queues)
				}
				if attempted.Load() != queues || (delay < 15*time.Second && completed.Load() != queues) {
					t.Error("session cleanup was skipped", attempted.Load(), completed.Load())
				}
				for _, worker := range workers {
					if _, err := worker.store.root.Open("."); err == nil {
						t.Fatal("state store was not closed")
					}
				}
			})
		})
	}
}

type shutdownTransport func(*http.Request) (*http.Response, error)

func (f shutdownTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func shutdownSession(t *testing.T, remove func(context.Context) error) *scaleset.MessageSessionClient {
	t.Helper()
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}).SignedString([]byte("test-only"))
	if err != nil {
		t.Fatal(err)
	}
	transport := &http.Transport{}
	transport.RegisterProtocol("https", shutdownTransport(func(r *http.Request) (*http.Response, error) {
		status, body := http.StatusOK, ""
		switch {
		case strings.HasSuffix(r.URL.Path, "/registration-token"):
			status, body = http.StatusCreated, `{"token":"test-registration"}`
		case strings.HasSuffix(r.URL.Path, "/runner-registration"):
			status, body = http.StatusCreated, fmt.Sprintf(`{"url":"https://test.invalid/tenant/","token":%q}`, token)
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/sessions"):
			body = `{"sessionId":"01234567-89ab-4def-8123-456789abcdef"}`
		case r.Method == http.MethodDelete && strings.Contains(r.URL.Path, "/sessions/"):
			if err := remove(r.Context()); err != nil {
				return nil, err
			}
			status = http.StatusNoContent
		default:
			return nil, fmt.Errorf("unexpected session request: %s %s", r.Method, r.URL)
		}
		return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	}))
	retry := retryablehttp.NewClient()
	retry.RetryMax = 0
	retry.HTTPClient.Transport = transport
	client, err := scaleset.NewClientWithPersonalAccessToken(scaleset.NewClientWithPersonalAccessTokenConfig{
		GitHubConfigURL: "https://github.com/example/application", PersonalAccessToken: "test-only",
	}, scaleset.WithRetryableHTTPClint(retry))
	if err != nil {
		t.Fatal(err)
	}
	session, err := client.MessageSessionClient(t.Context(), 1, "test-owner")
	if err != nil {
		t.Fatal(err)
	}
	return session
}
