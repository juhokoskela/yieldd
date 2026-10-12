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

func TestBootstrapIdentityDiagnosticsDoNotExposeArbitraryResponseText(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	l := singleLease(c.state)
	w.run.ID = 100
	w.run.Status = "secret-status\nforged log"
	w.run.DisplayTitle = "private-token\nforged log"
	_, err := c.assigned(l.Name).reconcile(t.Context(), false)
	if !errors.Is(err, bootstrapIdentityMismatch) {
		t.Fatal(err)
	}
	for _, field := range []string{l.Name, "expected_run=99", "observed_run=100", "status=unexpected", "title=unexpected"} {
		if !strings.Contains(err.Error(), field) {
			t.Fatal("identity diagnostic is missing", field, err)
		}
	}
	for _, secret := range []string{"private-token", "secret-status", "forged log", "\n"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatal("identity diagnostic exposed untrusted response text", err)
		}
	}
}

func TestIdentityDiagnosticsDistinguishMissingMetadataFromAnotherBootstrap(t *testing.T) {
	l := &lease{Name: "yieldd-bootstrap-00000000-0000-4000-8000-000000000001", RunID: 99}
	otherTitle := "Bootstrap yieldd-bootstrap-00000000-0000-4000-8000-000000000002"
	for _, test := range []struct {
		name string
		run  *workflowRun
		want []string
	}{
		{"missing", nil, []string{"observed_run=0", "status=missing", "title=missing"}},
		{"another bootstrap", &workflowRun{ID: 100, Status: "completed", DisplayTitle: otherTitle}, []string{"observed_run=100", "status=completed", "title=" + otherTitle}},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := identityMismatch(l, test.run)
			if !errors.Is(err, bootstrapIdentityMismatch) {
				t.Fatal("error identity was lost", err)
			}
			for _, field := range test.want {
				if !strings.Contains(err.Error(), field) {
					t.Fatal("safe identity field missing", field, err)
				}
			}
		})
	}
}

func TestIdentityPauseRequiresFullVerificationAndThenResumes(t *testing.T) {
	c, w, store := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	l := singleLease(c.state)
	w.run.ID++
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || c.paused == nil {
		t.Fatal("identity mismatch stopped the queue instead of retaining it for verification", n, err)
	}
	w.run.ID = l.RunID
	w.run.DisplayTitle = "Pending bootstrap metadata"
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || c.paused == nil {
		t.Fatal("an unverified title cleared the identity pause", err)
	}
	if w.dispatched != 1 || l.CleanupIntent || w.secret == "" || w.runner == nil {
		t.Fatal("unverified execution was redispatched or cleaned up", w.events)
	}
	w.run.DisplayTitle = "Bootstrap " + l.Name
	w.run.Status, w.run.Conclusion = "completed", "success"
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 || c.paused != nil {
		t.Fatal("verified cleanup did not clear the stale pause", n, err, c.paused)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || len(saved.Leases) != 0 || w.dispatched != 1 {
		t.Fatal("recovery lost state or replayed execution", saved, err)
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || w.dispatched != 2 {
		t.Fatal("fresh demand cannot provision after verified recovery", n, err)
	}
}

func TestIdentityPauseRetriesWithoutDemandAndWithoutIssuedSiblings(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := concurrentFixture(t, 1)
		request := issueLocal(t, c, 0, 1)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		w.run.ID++
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || c.paused == nil {
			t.Fatal("queue did not pause for verification", err)
		}
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		loop.demandObserved, loop.desiredCount = true, 2
		if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop}); err != nil {
			cancel()
			t.Fatal(err)
		}
		done := make(chan struct{})
		var loopErr error
		go func() { loopErr = loop.run(); close(done) }()
		t.Cleanup(func() { cancel(); <-done })
		if err := loop.invoke(t.Context(), func(ctx context.Context) error {
			return c.completeDevice(ctx, request)
		}); err != nil {
			t.Fatal(err)
		}
		synctest.Wait()
		var before int
		if err := loop.invoke(t.Context(), func(context.Context) error {
			before = w.getCalls
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(cleanupRetryDelay - time.Second)
		synctest.Wait()
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if w.getCalls != before {
				return fmt.Errorf("identity pause retries in a tight loop: %d calls", w.getCalls-before)
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second)
		synctest.Wait()
		select {
		case <-done:
			t.Fatal("queue stopped after its last local runner completed", loopErr)
		default:
		}
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if w.getCalls != before+1 {
				return fmt.Errorf("identity pause has no autonomous bounded retry: %d calls", w.getCalls-before)
			}
			w.run.ID--
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(cleanupRetryDelay)
		synctest.Wait()
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if c.paused != nil || w.dispatched != 1 || len(c.state.Leases) != 1 || slices.Contains(w.events, "cancel") {
				return fmt.Errorf("verified run did not resume without replaying execution: %v, %v", c.paused, w.events)
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	})
}

func TestJournalFailureCannotBecomeAnIdentityRetry(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	w.run.Status, w.run.Conclusion = "completed", "success"
	failure := identityMismatch(singleLease(c.state), w.run)
	c.save = func(*state) error { return failure }
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 0); !isJournalWrite(err) || c.paused != nil {
		t.Fatal("a journal write failure was downgraded to an identity retry", err, c.paused)
	}
}

func TestIndependentBootstrapFailureIsNotClearedWithIdentityPause(t *testing.T) {
	c, w, _ := concurrentFixture(t, 1)
	request := issueLocal(t, c, 0, 1)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
		t.Fatal(err)
	}
	w.run.ID++
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || c.paused == nil {
		t.Fatal(err)
	}
	w.run.ID--
	w.run.Status, w.run.Conclusion = "completed", "failure"
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || c.paused == nil {
		t.Fatal("bootstrap failure revoked the issued sibling", err)
	}
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err == nil || !strings.Contains(err.Error(), "concluded failure") || w.dispatched != 1 {
		t.Fatal("an independent failure was cleared or workload retried", err, w.events)
	}
}
