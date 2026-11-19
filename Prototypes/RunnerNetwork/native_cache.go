package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sync"
	"time"
)

// These namespaces have already been resolved by the host's signed-token verifier.
type nativeCacheGrants struct {
	RepositoryID string   `json:"repository_id"`
	Repository   string   `json:"repository,omitempty"`
	ReadScopes   []string `json:"read_scopes"`
	WriteScope   string   `json:"write_scope,omitempty"`
}

type nativeCacheRequest struct {
	ID        string            `json:"id"`
	Operation string            `json:"operation"`
	Grants    nativeCacheGrants `json:"grants"`
}

type nativeCacheResponse struct {
	ID       string `json:"id"`
	Writable *bool  `json:"writable,omitempty"`
	Error    string `json:"error,omitempty"`
}

// The relay and VM owner share a private local directory. Only the owner has a reference
// to the live backend. The guest supplies an operation, never a path, namespace or runner ID.
func nativeCacheHandler(directory string, verify func(context.Context, string) (nativeCacheGrants, error)) http.Handler {
	var active sync.Mutex
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ContentLength != 0 {
			http.Error(w, "invalid native cache request", http.StatusBadRequest)
			return
		}
		if !active.TryLock() {
			http.Error(w, "another cache request is in progress", http.StatusConflict)
			return
		}
		defer active.Unlock()
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
		defer cancel()
		grants, err := verify(ctx, r.Header.Get("Authorization"))
		if err != nil {
			http.Error(w, "cache authorization failed", http.StatusForbidden)
			return
		}
		request := nativeCacheRequest{ID: rand.Text(), Operation: path.Base(r.URL.Path), Grants: grants}
		response, err := exchangeNativeCacheRequest(ctx, directory, request)
		if err != nil {
			http.Error(w, "native cache owner unavailable", http.StatusServiceUnavailable)
			return
		}
		if response.Error != "" {
			http.Error(w, response.Error, http.StatusConflict)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(response)
	})
}

func exchangeNativeCacheRequest(ctx context.Context, directory string, request nativeCacheRequest) (nativeCacheResponse, error) {
	var response nativeCacheResponse
	file, err := os.CreateTemp(directory, ".native-request-*")
	if err != nil {
		return response, err
	}
	defer os.Remove(file.Name())
	writeErr := json.NewEncoder(file).Encode(request)
	if err := errors.Join(writeErr, file.Close()); err != nil {
		return response, err
	}
	target := filepath.Join(directory, "native-request")
	if err := os.Rename(file.Name(), target); err != nil {
		return response, err
	}
	defer os.Remove(target)
	poll := time.NewTicker(200 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return response, ctx.Err()
		case <-poll.C:
			// Responses are small, atomically replaced, and only written by the VM owner.
			data, err := os.ReadFile(filepath.Join(directory, "native-response"))
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			if err != nil {
				return response, err
			}
			response = nativeCacheResponse{}
			if err := json.Unmarshal(data, &response); err != nil {
				return response, err
			}
			if response.ID == request.ID {
				return response, nil
			}
		}
	}
}
