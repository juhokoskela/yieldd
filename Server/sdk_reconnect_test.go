package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/actions/scaleset"
	"github.com/google/uuid"
)

func TestSDKListenerReopensSessionAfterHTTPFailureWithoutLosingIssuedLease(t *testing.T) {
	c, _, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	owner, scaleSetID := c.state.Owner, c.state.ScaleSetID
	auth := sdkAuthentication(t)
	var created, closed atomic.Int64
	polled := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if status, body := auth(r, "http://"+r.Host+"/"); status != 0 {
			w.WriteHeader(status)
			io.WriteString(w, body)
			return
		}
		switch {
		case r.Method == "POST" && r.URL.Path == fmt.Sprintf("/_apis/runtime/runnerscalesets/%d/sessions", scaleSetID):
			var session scaleset.RunnerScaleSetSession
			if err := json.NewDecoder(r.Body).Decode(&session); err != nil || session.OwnerName != owner {
				t.Error("reconnect changed the saved session owner", session.OwnerName, err)
			}
			attempt := created.Add(1)
			demand := 1
			if attempt > 1 {
				demand = 0
			}
			_ = json.NewEncoder(w).Encode(scaleset.RunnerScaleSetSession{
				SessionID: uuid.New(), OwnerName: owner,
				MessageQueueURL:         fmt.Sprintf("http://%s/messages/%d", r.Host, attempt),
				MessageQueueAccessToken: "test-session-token", Statistics: &scaleset.RunnerScaleSetStatistic{TotalAssignedJobs: demand},
			})
		case r.Method == "DELETE" && strings.HasPrefix(r.URL.Path, fmt.Sprintf("/_apis/runtime/runnerscalesets/%d/sessions/", scaleSetID)):
			closed.Add(1)
			w.WriteHeader(http.StatusNoContent)
		case r.URL.Path == "/messages/1":
			w.WriteHeader(http.StatusServiceUnavailable)
			io.WriteString(w, `{"message":"private-sdk-body"}`)
		case r.URL.Path == "/messages/2":
			select {
			case polled <- struct{}{}:
			default:
			}
			<-r.Context().Done()
		default:
			t.Error("unexpected SDK request", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer server.Close()
	client, err := newScaleSetClient(server.URL+"/owner/repo", "test-pat")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	var logs bytes.Buffer
	c.logger = slog.New(slog.NewTextHandler(&logs, nil))
	p := &platformCoordinator{cancel: cancel, loop: newCoordinatorLoop(ctx, c), scaleSetID: scaleSetID,
		newSession: func(ctx context.Context) (listenerSession, error) {
			return client.MessageSessionClient(ctx, scaleSetID, owner)
		}}
	if err := p.openMessages(ctx); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	var runErr error
	go func() { defer close(done); runErr = p.run(ctx, false) }()
	defer func() { cancel(); <-done }()
	select {
	case <-polled:
	case <-ctx.Done():
		t.Fatal("SDK did not reach the reconnected long poll", ctx.Err())
	}
	if err := p.loop.invoke(t.Context(), func(ctx context.Context) error {
		if singleLease(c.state) == nil || c.device.slots[request.Slot].owner != owner {
			t.Error("reconnect discarded issued capacity")
		}
		return c.completeDevice(ctx, request)
	}); err != nil {
		t.Fatal("reconnect blocked device cleanup", err)
	}
	cancel()
	<-done
	if runErr != nil {
		t.Fatal(runErr)
	}
	if created.Load() != 2 || closed.Load() != 1 || strings.Contains(logs.String(), "private-sdk-body") || !strings.Contains(logs.String(), "Demand listener reconnected") {
		t.Fatal("session replacement or safe diagnostics failed", created.Load(), closed.Load(), logs.String())
	}
}
