package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

func TestBootstrapIdentityDiagnostics(t *testing.T) {
	l := &lease{Name: "yieldd-bootstrap-00000000-0000-4000-8000-000000000001", RunID: 99}
	otherTitle := "Bootstrap yieldd-bootstrap-00000000-0000-4000-8000-000000000002"
	for _, test := range []struct {
		name string
		run  *workflowRun
		want string
	}{
		{"missing", nil, "observed_run=0 status=missing title=missing"},
		{"another bootstrap", &workflowRun{ID: 100, Status: "completed", DisplayTitle: otherTitle}, "observed_run=100 status=completed title=" + otherTitle},
		{"untrusted text", &workflowRun{ID: 100, Status: "secret-status\nforged log", DisplayTitle: "private-token\nforged log"}, "observed_run=100 status=unexpected title=unexpected"},
		{"token after prefix", &workflowRun{ID: 100, Status: "queued", DisplayTitle: "Bootstrap ghp_secret_token"}, "observed_run=100 status=queued title=unexpected"},
		{"action required", &workflowRun{ID: 99, Status: "action_required"}, "observed_run=99 status=action_required title=missing"},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := identityMismatch(l, test.run)
			want := fmt.Sprintf("%s: runner=%s expected_run=99 %s", bootstrapIdentityMismatch, l.Name, test.want)
			if !errors.Is(err, bootstrapIdentityMismatch) || err.Error() != want {
				t.Fatal("unsafe or incomplete identity diagnostic", err, "want", want)
			}
		})
	}
}

func TestNonterminalBootstrapMetadataDoesNotPauseOrDelayTheQueue(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, store := newFixture(t)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		w.run.DisplayTitle = "Pending bootstrap metadata"
		start := time.Now()
		for range 3 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
		}
		if c.paused != nil || w.dispatched != 1 || w.getCalls != 3 || time.Since(start) != 0 {
			t.Fatalf("metadata lag delayed or paused the queue: paused=%v dispatches=%d get=%d elapsed=%s events=%v", c.paused, w.dispatched, w.getCalls, time.Since(start), w.events)
		}
		time.Sleep(time.Hour)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		w.run.Status, w.run.Conclusion = "completed", "success"
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 0); err != nil {
			t.Fatal(err)
		}
		saved, err := store.load(c.state.Config)
		if err != nil || len(saved.Leases) != 0 || w.runner != nil || w.secret != "" || w.dispatched != 1 {
			t.Fatal("completed bootstrap could not clean up without redispatch", saved, err, w.events)
		}
	})
}

func TestBootstrapIdentityIsRequiredBeforeCancellationOrCleanup(t *testing.T) {
	for _, recoverOnly := range []bool{false, true} {
		t.Run(fmt.Sprintf("recover=%v", recoverOnly), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, store := newFixture(t)
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
					t.Fatal("initial dispatch failed", err)
				}
				if !recoverOnly {
					w.run.Status, w.run.Conclusion = "completed", "success"
				}
				w.run.ID++
				start := time.Now()
				_, err := c.assigned(singleLease(c.state).Name).reconcile(t.Context(), recoverOnly)
				if !errors.Is(err, bootstrapIdentityMismatch) {
					t.Fatalf("wrong run ID was not rejected: error=%v", err)
				}
				saved, err := store.load(c.state.Config)
				if err != nil || len(saved.Leases) != 1 || w.runner == nil || w.secret == "" || time.Since(start) != 0 {
					t.Fatal("unverified run caused deletion or blocked the queue", saved, err, w.events)
				}
				if w.getCalls != 1 || w.findCalls != 0 {
					t.Fatalf("wrong lookup for a saved run ID: get=%d find=%d", w.getCalls, w.findCalls)
				}
				if slices.Contains(w.events, "cancel") {
					t.Fatal("unverified workflow was canceled")
				}
				if singleLease(c.state).CleanupIntent {
					t.Fatal("unverified workflow entered cleanup")
				}
			})
		})
	}
}

func TestStartupFailureWithoutSavedRunIDRemainsUnconfirmed(t *testing.T) {
	for _, recoverOnly := range []bool{false, true} {
		t.Run(fmt.Sprintf("recover=%v", recoverOnly), func(t *testing.T) {
			c, w, store := newFixture(t)
			w.dispatchErr = errors.New("dispatch response lost")
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, w.dispatchErr) {
				t.Fatalf("expected lost dispatch response, got %v", err)
			}
			saved, err := store.load(testConfig)
			if err != nil {
				t.Fatal(err)
			}
			c.state = saved
			w.run.DisplayTitle = "Runner bootstrap prototype"
			w.run.Status, w.run.Conclusion = "completed", "startup_failure"
			if done, err := c.reconcile(t.Context(), recoverOnly); done || err == nil || !strings.Contains(err.Error(), "still unconfirmed") || errors.Is(err, bootstrapIdentityMismatch) {
				t.Fatalf("unknown dispatch was not retained as unconfirmed: done=%v error=%v", done, err)
			}
			saved, err = store.load(testConfig)
			if err != nil {
				t.Fatal(err)
			}
			l := singleLease(saved)
			if l == nil || l.RunID != 0 || !l.DispatchIntent || l.CleanupIntent || w.runner == nil || w.secret == "" || slices.Contains(w.events, "cancel") {
				t.Fatal("unconfirmed dispatch lost its obligation or resources", l, w.events)
			}
			if w.dispatched != 1 || w.findCalls != 1 || w.getCalls != 0 {
				t.Fatalf("unconfirmed dispatch was replayed or looked up by ID: dispatches=%d find=%d get=%d", w.dispatched, w.findCalls, w.getCalls)
			}
		})
	}
}

func TestBootstrapReconciliationHonorsCancellation(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := c.HandleDesiredRunnerCount(ctx, 1); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if w.getCalls != 0 || w.dispatched != 1 {
		t.Fatal("canceled reconciliation touched GitHub", w.events)
	}
}
