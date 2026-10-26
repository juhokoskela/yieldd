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
	for _, test := range []struct {
		name        string
		recoverOnly bool
		discover    bool
	}{
		{"cleanup with wrong ID", false, false},
		{"cancellation with wrong ID", true, false},
		{"cleanup with unverified discovery", false, true},
		{"cancellation with unverified discovery", true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, store := newFixture(t)
				if test.discover {
					w.dispatchErr = errors.New("dispatch response lost")
				}
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); (err != nil) != test.discover {
					t.Fatal(err)
				}
				if !test.recoverOnly {
					w.run.Status, w.run.Conclusion = "completed", "success"
				}
				if test.discover {
					w.run.DisplayTitle = "Runner bootstrap prototype"
				} else {
					w.run.ID++
				}
				start := time.Now()
				_, err := c.assigned(singleLease(c.state).Name).reconcile(t.Context(), test.recoverOnly)
				if !errors.Is(err, bootstrapIdentityMismatch) {
					t.Fatal("unverified run was accepted", err)
				}
				saved, err := store.load(c.state.Config)
				if err != nil || len(saved.Leases) != 1 || w.runner == nil || w.secret == "" || w.getCalls+w.findCalls != 1 || time.Since(start) != 0 {
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

func TestStartupFailureCleansUpUsingSavedRunID(t *testing.T) {
	for _, recoverOnly := range []bool{false, true} {
		t.Run(fmt.Sprintf("recover=%v", recoverOnly), func(t *testing.T) {
			c, w, store := newFixture(t)
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
			saved, err := store.load(testConfig)
			if err != nil {
				t.Fatal(err)
			}
			c.state = saved
			w.run.DisplayTitle = "Runner bootstrap prototype"
			w.run.Status, w.run.Conclusion = "completed", "startup_failure"
			if recoverOnly {
				if done, err := c.reconcile(t.Context(), true); err != nil || !done {
					t.Fatal("startup failure could not recover", done, err)
				}
			} else {
				if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); n != 0 || err == nil || !strings.Contains(err.Error(), "concluded startup_failure") || errors.Is(err, bootstrapIdentityMismatch) || c.paused != nil {
					t.Fatal("startup failure was not reported after cleanup", n, err, c.paused)
				}
			}
			saved, err = store.load(testConfig)
			if err != nil || len(saved.Leases) != 0 || w.runner != nil || w.secret != "" || w.dispatched != 1 || w.findCalls != 0 || slices.Contains(w.events, "cancel") {
				t.Fatal("startup failure left resources or replayed execution", saved, err, w.events)
			}
		})
	}
}

func TestRecoveryUsesSavedRunIDBeforeTitleIsRendered(t *testing.T) {
	c, w, store := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	w.run.DisplayTitle = ""
	if done, err := c.reconcile(t.Context(), true); err != nil || done {
		t.Fatal("recovery could not request cancellation by saved run ID", done, err)
	}
	if !slices.Contains(w.events, "cancel") || w.runner == nil || w.secret == "" || singleLease(c.state).CleanupIntent {
		t.Fatal("recovery did not wait for terminal state", w.events)
	}
	w.run.Status, w.run.Conclusion = "completed", "cancelled"
	if done, err := c.reconcile(t.Context(), true); err != nil || !done {
		t.Fatal("recovery could not clean up by saved run ID", done, err)
	}
	saved, err := store.load(testConfig)
	if err != nil || len(saved.Leases) != 0 || w.runner != nil || w.secret != "" || w.dispatched != 1 || w.findCalls != 0 {
		t.Fatal("recovery left resources or replayed execution", saved, err, w.events)
	}
}

func TestStartupFailureCleanupSurvivesRestart(t *testing.T) {
	for _, fail := range []string{"busy runner", "delete secret", "clear journal"} {
		t.Run(fail, func(t *testing.T) {
			c, w, store := newFixture(t)
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
			w.run.DisplayTitle = "Runner bootstrap prototype"
			w.run.Status, w.run.Conclusion = "completed", "startup_failure"
			failure := errors.New("cleanup interrupted")
			switch fail {
			case "busy runner":
				w.busy = true
				failure = runnerStillBusy
			case "delete secret":
				w.deleteErr = failure
			case "clear journal":
				c.save = func(s *state) error {
					if len(s.Leases) == 0 {
						return failure
					}
					return store.save(s)
				}
			}
			if done, err := c.reconcile(t.Context(), true); done || !errors.Is(err, failure) {
				t.Fatal("cleanup failure was not retained", done, err)
			}
			saved, err := store.load(testConfig)
			if err != nil {
				t.Fatal(err)
			}
			l := singleLease(saved)
			if l == nil || !l.CleanupIntent || l.Conclusion != "startup_failure" || l.RunID != w.run.ID {
				t.Fatal("cleanup intent or failure conclusion was lost", l)
			}
			if fail == "busy runner" && (w.runner == nil || w.secret == "") {
				t.Fatal("busy runner or its credential was removed")
			}
			c.state, c.save, w.deleteErr, w.busy = saved, store.save, nil, false
			w.getErr = errors.New("workflow API unavailable during cleanup")
			if done, err := c.reconcile(t.Context(), true); err != nil || !done {
				t.Fatal("restart could not finish saved cleanup", done, err)
			}
			saved, err = store.load(testConfig)
			if err != nil || len(saved.Leases) != 0 || w.runner != nil || w.secret != "" || w.dispatched != 1 || w.findCalls != 0 || w.getCalls != 1 || slices.Contains(w.events, "cancel") {
				t.Fatal("restart lost cleanup or replayed execution", saved, err, w.events)
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
