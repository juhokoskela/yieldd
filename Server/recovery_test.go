package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

func TestExpiredContextAfterSecretUploadLeavesResumableIntent(t *testing.T) {
	for _, mode := range []string{"cancel", "deadline"} {
		for _, recoverOnly := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/recover=%v", mode, recoverOnly), func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					c, w, store := newFixture(t)
					ctx, cancel := context.WithCancel(t.Context())
					defer cancel()
					wantErr := context.Canceled
					w.afterSecret = cancel
					if mode == "deadline" {
						wantErr = context.DeadlineExceeded
						w.afterSecret = func() { time.Sleep(61 * time.Second) }
					}
					w.dispatchErr = wantErr
					if _, err := c.HandleDesiredRunnerCount(ctx, 1); !errors.Is(err, wantErr) {
						t.Fatal("lost cancellation identity", err)
					}
					saved, err := store.load(testConfig)
					if err != nil {
						t.Fatal(err)
					}
					if saved.Lease == nil || saved.Lease.DispatchIntent || saved.Lease.JIT != "private-jit" || saved.Lease.RunnerID != 7 {
						t.Fatal("expired context recorded dispatch or lost resumable credentials")
					}
					if c.state.Lease.DispatchIntent || w.dispatched != 0 || w.secret != "private-jit" {
						t.Fatal("dispatch attempted after upload exhausted its context")
					}
					c.state, w.afterSecret, w.dispatchErr = saved, nil, nil
					if recoverOnly {
						if done, err := c.reconcile(t.Context(), true); err != nil || !done {
							t.Fatal(done, err)
						}
						if c.state.Lease != nil || w.runner != nil || w.secret != "" || w.dispatched != 0 {
							t.Fatal("could not recover undispatched attempt")
						}
					} else {
						if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
							t.Fatal(err)
						}
						if w.dispatched != 1 || w.findCalls != 0 || c.state.Lease.RunID != 99 {
							t.Fatal("restart could not resume provisioning")
						}
					}
				})
			})
		}
	}
}

func TestExpiredContextDuringDispatchIntentSaveEntersCleanup(t *testing.T) {
	for _, mode := range []string{"cancel", "deadline"} {
		for _, recoverOnly := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/recover=%v", mode, recoverOnly), func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					c, w, store := newFixture(t)
					ctx, cancel := context.WithCancel(t.Context())
					defer cancel()
					wantErr := context.Canceled
					if mode == "deadline" {
						wantErr = context.DeadlineExceeded
						w.afterSecret = func() { time.Sleep(59 * time.Second) }
					}
					c.save = func(s *state) error {
						if s.Lease != nil && s.Lease.DispatchIntent && !s.Lease.CleanupIntent {
							if mode == "deadline" {
								time.Sleep(2 * time.Second)
							} else {
								cancel()
							}
						}
						return store.save(s)
					}
					w.dispatchErr = wantErr
					if _, err := c.HandleDesiredRunnerCount(ctx, 1); !errors.Is(err, wantErr) {
						t.Fatal("lost cancellation identity", err)
					}
					saved, err := store.load(testConfig)
					if err != nil {
						t.Fatal(err)
					}
					if saved.Lease == nil || !saved.Lease.CleanupIntent || saved.Lease.JIT != "" || saved.Lease.RunID != 0 {
						t.Fatal("unattempted dispatch did not persist cleanup intent")
					}
					if w.dispatched != 0 || w.runner == nil || w.secret == "" {
						t.Fatal("expired context attempted dispatch or deleted resources")
					}
					c.state, c.save = saved, store.save
					if done, err := c.reconcile(t.Context(), recoverOnly); err != nil || !done {
						t.Fatal(done, err)
					}
					if c.state.Lease != nil || w.runner != nil || w.secret != "" || w.dispatched != 0 || w.findCalls != 0 {
						t.Fatal("restart did not clean up the unattempted dispatch directly")
					}
				})
			})
		}
	}
}

func TestUnattemptedDispatchCleanupSaveFailureRetainsObligation(t *testing.T) {
	c, w, store := newFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	failure := errors.New("disk full")
	c.save = func(s *state) error {
		if s.Lease != nil && s.Lease.CleanupIntent {
			return failure
		}
		if s.Lease != nil && s.Lease.DispatchIntent {
			cancel()
		}
		return store.save(s)
	}
	if _, err := c.HandleDesiredRunnerCount(ctx, 1); !errors.Is(err, context.Canceled) || !errors.Is(err, failure) {
		t.Fatal("lost cancellation or persistence error", err)
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Lease == nil || !saved.Lease.DispatchIntent || saved.Lease.CleanupIntent || c.state.Lease.CleanupIntent {
		t.Fatal("failed cleanup save lost the durable obligation")
	}
	if w.dispatched != 0 || w.runner == nil || w.secret == "" {
		t.Fatal("failed cleanup save dispatched or removed resources")
	}
}

type bootstrapWithRunAPI struct {
	bootstrapAPI
	api *githubAPI
}

func (b bootstrapWithRunAPI) getRun(ctx context.Context, id int64) (*workflowRun, error) {
	return b.api.getRun(ctx, id)
}

func (b bootstrapWithRunAPI) findRun(ctx context.Context, l *lease) (*workflowRun, error) {
	return b.api.findRun(ctx, l)
}

func TestRestartUsesServerTimeForBootstrapAge(t *testing.T) {
	serverNow := time.Date(2026, time.September, 15, 12, 0, 0, 0, time.UTC)
	for _, skew := range []time.Duration{-24 * time.Hour, 24 * time.Hour} {
		for _, age := range []time.Duration{time.Minute, 26 * time.Minute} {
			for _, discover := range []bool{false, true} {
				t.Run(fmt.Sprintf("skew=%v/age=%v/discover=%v", skew, age, discover), func(t *testing.T) {
					c, w, store := newFixture(t)
					c.now = func() time.Time { return serverNow.Add(skew) }
					if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
						t.Fatal(err)
					}
					if discover {
						c.state.Lease.RunID = 0
						if err := store.save(c.state); err != nil {
							t.Fatal(err)
						}
					}
					saved, err := store.load(testConfig)
					if err != nil {
						t.Fatal(err)
					}
					c.state = saved
					c.now = func() time.Time { return serverNow.Add(-skew) }
					api := testAPI(t, func(response http.ResponseWriter, request *http.Request) {
						response.Header().Set("Date", serverNow.Format(http.TimeFormat))
						run := map[string]any{"id": 99, "display_title": "Bootstrap " + saved.Lease.Name, "status": "queued", "created_at": serverNow.Add(-age)}
						if discover {
							json.NewEncoder(response).Encode(map[string]any{"workflow_runs": []any{run}})
						} else {
							json.NewEncoder(response).Encode(run)
						}
					})
					c.bootstrap = bootstrapWithRunAPI{bootstrapAPI: w, api: api}
					if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
						t.Fatal(err)
					}
					cancelled := w.events[len(w.events)-1] == "cancel"
					if cancelled != (age > 25*time.Minute) || w.dispatched != 1 || c.state.Lease == nil || w.secret == "" {
						t.Fatal("host clock changed cancellation or cleanup", w.events)
					}
				})
			}
		}
	}
}

type bootstrapWithDispatchAPI struct {
	bootstrapAPI
	api *githubAPI
}

func (b bootstrapWithDispatchAPI) dispatch(ctx context.Context, l *lease, fallback string) (int64, error) {
	return b.api.dispatch(ctx, l, fallback)
}

func TestRejectedDispatchRecoversAfterStateReload(t *testing.T) {
	for _, recoverOnly := range []bool{false, true} {
		t.Run(fmt.Sprint(recoverOnly), func(t *testing.T) {
			c, w, store := newFixture(t)
			requests := 0
			api := testAPI(t, func(response http.ResponseWriter, request *http.Request) {
				requests++
				response.WriteHeader(http.StatusForbidden)
			})
			c.bootstrap = bootstrapWithDispatchAPI{bootstrapAPI: w, api: api}
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !hasHTTPStatus(err, http.StatusForbidden) {
				t.Fatal("expected dispatch rejection")
			}
			saved, err := store.load(testConfig)
			if err != nil {
				t.Fatal(err)
			}
			c.state = saved
			if !saved.Lease.CleanupIntent || saved.Lease.Conclusion != "rejected" {
				t.Fatal("rejection was not durable")
			}
			if done, err := c.reconcile(t.Context(), recoverOnly); err != nil || !done {
				t.Fatalf("rejected dispatch could not recover: done=%v err=%v", done, err)
			}
			if c.state.Lease != nil || w.runner != nil || w.secret != "" || requests != 1 {
				t.Fatal("rejected attempt was not cleaned up exactly once")
			}
		})
	}
}

func TestInterruptedUndispatchedCleanupCannotResumeProvisioning(t *testing.T) {
	for _, fail := range []string{"delete-secret", "clear-state"} {
		t.Run(fail, func(t *testing.T) {
			c, w, store := newFixture(t)
			w.secretErr = errors.New("secret upload response lost")
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
				t.Fatal("expected interrupted upload")
			}
			w.secretErr = nil
			w.secret = "private-jit"
			failure := errors.New("cleanup interrupted")
			if fail == "delete-secret" {
				w.deleteErr = failure
			} else {
				c.save = func(s *state) error {
					if s.Lease == nil {
						return failure
					}
					return store.save(s)
				}
			}
			if _, err := c.reconcile(t.Context(), true); !errors.Is(err, failure) {
				t.Fatal(err)
			}
			if w.runner != nil {
				t.Fatal("expected deletion before the injected failure")
			}
			saved, err := store.load(testConfig)
			if err != nil {
				t.Fatal(err)
			}
			c.state, c.save, w.deleteErr = saved, store.save, nil
			if !saved.Lease.CleanupIntent {
				t.Fatal("cleanup intent did not survive restart")
			}
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
			if c.state.Lease != nil || w.dispatched != 0 || w.secret != "" {
				t.Fatal("normal restart resumed provisioning after runner deletion")
			}
		})
	}
}

func TestCancellationConflictRechecksTerminalState(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	w.cancelErr = &apiError{status: http.StatusConflict}
	w.beforeCancel = func() { w.run.Status = "completed"; w.run.Conclusion = "success" }
	if done, err := c.reconcile(t.Context(), true); err != nil || !done {
		t.Fatalf("completion race blocked cleanup: done=%v err=%v", done, err)
	}
	if c.state.Lease != nil || w.runner != nil || w.secret != "" {
		t.Fatal("terminal run left a cleanup obligation")
	}
	if w.getCalls != 2 {
		t.Fatal("cancellation conflict did not reread run status")
	}
}

func TestCleanupIntentMustBeDurableBeforeDeletion(t *testing.T) {
	c, w, store := newFixture(t)
	w.secretErr = errors.New("upload interrupted")
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
		t.Fatal("expected interrupted provisioning")
	}
	failure := errors.New("disk full")
	c.save = func(*state) error { return failure }
	if _, err := c.reconcile(t.Context(), true); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	if w.runner == nil || c.state.Lease.CleanupIntent || saved.Lease.CleanupIntent {
		t.Fatal("deletion or phase transition occurred before durable intent")
	}
}

func TestRejectionPersistenceFailureRetainsAmbiguousDispatch(t *testing.T) {
	c, w, store := newFixture(t)
	c.bootstrap = bootstrapWithDispatchAPI{bootstrapAPI: w, api: testAPI(t, func(response http.ResponseWriter, request *http.Request) { response.WriteHeader(http.StatusForbidden) })}
	failure := errors.New("disk full")
	c.save = func(s *state) error {
		if s.Lease != nil && s.Lease.CleanupIntent {
			return failure
		}
		return store.save(s)
	}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	if !saved.Lease.DispatchIntent || saved.Lease.CleanupIntent || c.state.Lease.CleanupIntent || w.runner == nil || w.secret == "" {
		t.Fatal("failed rejection persistence lost the cleanup obligation")
	}
}

func TestLostRunIDPersistenceUsesDiscoveryWithoutRedispatch(t *testing.T) {
	c, w, store := newFixture(t)
	failure := errors.New("disk full")
	c.save = func(s *state) error {
		if s.Lease != nil && s.Lease.RunID != 0 {
			return failure
		}
		return store.save(s)
	}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Lease.RunID != 0 || !saved.Lease.DispatchIntent {
		t.Fatal("lost dispatch intent")
	}
	c.state, c.save = saved, store.save
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if w.dispatched != 1 || w.findCalls != 1 || c.state.Lease.RunID != 99 {
		t.Fatal("lost run ID was not reconciled")
	}
}

func TestFailedBootstrapConclusionSurvivesInterruptedCleanup(t *testing.T) {
	c, w, store := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	w.run.Status, w.run.Conclusion = "completed", "failure"
	w.deleteErr = errors.New("cleanup interrupted")
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, w.deleteErr) {
		t.Fatal(err)
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	if !saved.Lease.CleanupIntent || saved.Lease.Conclusion != "failure" {
		t.Fatal("lost terminal conclusion")
	}
	c.state, w.deleteErr = saved, nil
	w.getErr = errors.New("workflow API unavailable during cleanup")
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil || !strings.Contains(err.Error(), "concluded failure") {
		t.Fatal("bootstrap failure not preserved", err)
	}
	if c.state.Lease != nil || w.runner != nil || w.secret != "" || w.dispatched != 1 {
		t.Fatal("terminal cleanup did not finish")
	}
}

func TestMissingWorkflowRequiresAbsentRunnerBeforeCleanup(t *testing.T) {
	for _, registered := range []bool{false, true} {
		for _, recoverOnly := range []bool{false, true} {
			t.Run(fmt.Sprintf("registered=%v/recover=%v", registered, recoverOnly), func(t *testing.T) {
				c, w, store := newFixture(t)
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
					t.Fatal(err)
				}
				saved, err := store.load(testConfig)
				if err != nil {
					t.Fatal(err)
				}
				c.state = saved
				w.getErr = &apiError{status: http.StatusNotFound}
				if !registered {
					w.runner = nil
				}
				done, err := c.reconcile(t.Context(), recoverOnly)
				if registered {
					if err == nil || done || c.state.Lease.CleanupIntent || w.secret == "" || w.runner == nil {
						t.Fatal("missing workflow allowed cleanup of a registered runner", done, err)
					}
					return
				}
				if !done || (err != nil) == recoverOnly || c.state.Lease != nil || w.secret != "" || w.dispatched != 1 {
					t.Fatal("missing workflow did not clean up while preserving unknown conclusion", done, err)
				}
			})
		}
	}
}

func TestCancellationConflictRetainsNonterminalOrUnverifiedRuns(t *testing.T) {
	for _, mode := range []string{"running", "read-failed", "wrong-id", "wrong-title", "missing", "non-conflict"} {
		t.Run(mode, func(t *testing.T) {
			c, w, _ := newFixture(t)
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
			w.cancelErr = &apiError{status: http.StatusConflict}
			if mode == "non-conflict" {
				w.cancelErr = &apiError{status: http.StatusForbidden}
			}
			w.beforeCancel = func() {
				switch mode {
				case "read-failed":
					w.getErr = errors.New("cannot read run")
				case "wrong-id":
					w.run.Status = "completed"
					w.run.ID++
				case "wrong-title":
					w.run.Status = "completed"
					w.run.DisplayTitle = "Bootstrap someone-else"
				case "missing":
					w.run = nil
				}
			}
			done, err := c.reconcile(t.Context(), true)
			if done || (err == nil) != (mode == "running") {
				t.Fatal(done, err)
			}
			if c.state.Lease.CleanupIntent || w.runner == nil || w.secret == "" {
				t.Fatal("cleaned up without verified termination")
			}
			wantReads := 2
			if mode == "non-conflict" {
				wantReads = 1
			}
			if w.getCalls != wantReads {
				t.Fatal("unexpected status reads", w.getCalls)
			}
		})
	}
}
