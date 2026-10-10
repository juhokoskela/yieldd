package main

import (
	"context"
	"errors"
	"slices"
	"testing"
	"testing/synctest"
	"time"
)

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
			t.Fatal("metadata lag delayed or poisoned the queue", c.paused, w.events, time.Since(start))
		}
		time.Sleep(time.Hour)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		w.run.DisplayTitle = "Bootstrap " + singleLease(c.state).Name
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
	for _, mode := range []string{"completed title", "cancellation title", "different ID"} {
		t.Run(mode, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, store := newFixture(t)
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
					t.Fatal(err)
				}
				w.run.DisplayTitle = "Bootstrap someone-else"
				if mode == "completed title" {
					w.run.Status, w.run.Conclusion = "completed", "success"
				}
				if mode == "different ID" {
					w.run.ID++
				}
				start := time.Now()
				_, err := c.assigned(singleLease(c.state).Name).reconcile(t.Context(), mode == "cancellation title")
				if !errors.Is(err, bootstrapIdentityMismatch) {
					t.Fatal("unverified run was accepted", err)
				}
				saved, err := store.load(c.state.Config)
				if err != nil || len(saved.Leases) != 1 || w.runner == nil || w.secret == "" || w.getCalls != 1 || time.Since(start) != 0 {
					t.Fatal("unverified run caused deletion or blocked the queue", saved, err, w.events)
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
