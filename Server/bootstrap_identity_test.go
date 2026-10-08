package main

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"
)

type delayedRunIdentity struct {
	*fakeWorld
	wrong int
}

func (w *delayedRunIdentity) getRun(ctx context.Context, id int64) (*workflowRun, error) {
	run, err := w.fakeWorld.getRun(ctx, id)
	if err == nil && run != nil && w.getCalls <= w.wrong {
		run.DisplayTitle = "Pending bootstrap metadata"
	}
	return run, err
}

func TestBootstrapIdentityRecheckDoesNotPauseRedispatchOrDropCleanup(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, store := newFixture(t)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		c.bootstrap = &delayedRunIdentity{fakeWorld: w, wrong: 2}
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal("temporary metadata poisoned the queue", err)
		}
		if c.paused != nil || w.dispatched != 1 || w.getCalls != 3 {
			t.Fatal("identity recheck did not preserve the assignment", c.paused, w.events)
		}
		w.run.Status, w.run.Conclusion = "completed", "success"
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 0); err != nil {
			t.Fatal(err)
		}
		saved, err := store.load(c.state.Config)
		if err != nil || len(saved.Leases) != 0 || w.runner != nil || w.secret != "" {
			t.Fatal("completed bootstrap could not clean up", saved, err)
		}
	})
}

func TestBootstrapIdentityMismatchRemainsBoundedAndFailClosed(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, store := newFixture(t)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		c.bootstrap = &delayedRunIdentity{fakeWorld: w, wrong: bootstrapIdentityAttempts + 1}
		start := time.Now()
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 0); !errors.Is(err, bootstrapIdentityMismatch) {
			t.Fatal("persistent identity mismatch was ignored", err)
		}
		saved, err := store.load(c.state.Config)
		if err != nil || len(saved.Leases) != 1 || w.runner == nil || w.secret == "" || w.dispatched != 1 || w.getCalls != bootstrapIdentityAttempts {
			t.Fatal("unverified workflow caused cleanup or redispatch", saved, err, w.events)
		}
		if time.Since(start) != (bootstrapIdentityAttempts-1)*bootstrapIdentityRetryDelay {
			t.Fatal("identity checks were not bounded")
		}
	})
}

func TestBootstrapIdentityRecheckHonorsCancellation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := newFixture(t)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		c.bootstrap = &delayedRunIdentity{fakeWorld: w, wrong: bootstrapIdentityAttempts}
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		defer cancel()
		if _, err := c.assigned(singleLease(c.state).Name).reconcile(ctx, false); !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("identity wait lost cancellation", err)
		}
		if w.getCalls != 1 || singleLease(c.state) == nil || w.dispatched != 1 {
			t.Fatal("canceled recheck mutated provisioning", w.events)
		}
	})
}
