package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNativeCacheExchangeUsesVerifiedScopesAndMatchingResponse(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	req := httptest.NewRequestWithContext(ctx, http.MethodPost, "/yieldd/native/open", nil)
	req.Header.Set("Authorization", "Bearer test-token")
	reply := httptest.NewRecorder()
	goDone := make(chan struct{})
	handler := nativeCacheHandler(dir, func(_ context.Context, authorization string) (nativeCacheGrants, error) {
		if authorization != "Bearer test-token" {
			return nativeCacheGrants{}, errors.New("wrong token")
		}
		return nativeCacheGrants{RepositoryID: "42", ReadScopes: []string{"allowed"}}, nil
	})
	server := filepath.Join(dir, "native-response")
	if err := os.WriteFile(server, []byte(`{"id":"stale","path":"wrong"}`), 0600); err != nil {
		t.Fatal(err)
	}
	go func() { defer close(goDone); handler.ServeHTTP(reply, req) }()
	requestFile := filepath.Join(dir, "native-request")
	var msg nativeCacheRequest
	for {
		data, err := os.ReadFile(requestFile)
		if err == nil {
			if err := json.Unmarshal(data, &msg); err != nil {
				t.Fatal(err)
			}
			break
		}
		if !errors.Is(err, os.ErrNotExist) || ctx.Err() != nil {
			t.Fatalf("request missing: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if msg.Operation != "open" || msg.ID == "" || msg.Grants.RepositoryID != "42" || len(msg.Grants.ReadScopes) != 1 || msg.Grants.ReadScopes[0] != "allowed" {
		t.Fatalf("unexpected request: %+v", msg)
	}
	busy := httptest.NewRecorder()
	handler.ServeHTTP(busy, req)
	if busy.Code != http.StatusConflict {
		t.Fatalf("concurrent request: %d", busy.Code)
	}
	response, err := json.Marshal(nativeCacheResponse{ID: msg.ID, Writable: new(true)})
	if err != nil {
		t.Fatal(err)
	}
	temp := filepath.Join(dir, "reply")
	if err := os.WriteFile(temp, response, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(temp, server); err != nil {
		t.Fatal(err)
	}
	select {
	case <-goDone:
	case <-ctx.Done():
		t.Fatal("request did not complete")
	}
	if reply.Code != http.StatusOK {
		t.Fatal(reply.Body.String())
	}
	var actual nativeCacheResponse
	if err := json.Unmarshal(reply.Body.Bytes(), &actual); err != nil || actual.Writable == nil || !*actual.Writable {
		t.Fatalf("bad response: %q", reply.Body)
	}
	if _, err := os.Stat(requestFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("finished request still present")
	}
}

func TestNativeCacheRejectsUnverifiedRequests(t *testing.T) {
	dir := t.TempDir()
	handler := nativeCacheHandler(dir, func(context.Context, string) (nativeCacheGrants, error) {
		return nativeCacheGrants{}, errors.New("not authorized")
	})
	relay := &relayCache{native: handler}
	bind := httptest.NewRequest(http.MethodPost, "/yieldd/bind", nil)
	bind.Header.Set("Authorization", "Bearer bad")
	relay.ServeHTTP(httptest.NewRecorder(), bind)
	for _, test := range []struct {
		method string
		url    string
		token  string
		body   string
		want   int
	}{
		{http.MethodPost, "/yieldd/native/save", "", "", http.StatusUnauthorized},
		{http.MethodPost, "/yieldd/native/open", "bad", "", http.StatusForbidden},
		{http.MethodPost, "/yieldd/native/open?scope=other", "bad", "", http.StatusNotFound},
		{http.MethodGet, "/yieldd/native/open", "bad", "", http.StatusNotFound},
		{http.MethodPost, "/yieldd/native/open", "another", "", http.StatusUnauthorized},
		{http.MethodPost, "/yieldd/native/delete", "bad", "", http.StatusNotFound},
		{http.MethodPost, "/yieldd/native/open", "bad", "{}", http.StatusBadRequest},
	} {
		req := httptest.NewRequest(test.method, test.url, strings.NewReader(test.body))
		if test.token != "" {
			req.Header.Set("Authorization", "Bearer "+test.token)
		}
		w := httptest.NewRecorder()
		relay.ServeHTTP(w, req)
		if w.Code != test.want {
			t.Errorf("%s %s: got %d, want %d", test.method, test.url, w.Code, test.want)
		}
	}
	if files, err := os.ReadDir(dir); err != nil || len(files) != 0 {
		t.Fatalf("unexpected request files %v: %v", files, err)
	}
}
