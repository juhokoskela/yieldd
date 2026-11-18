package main

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"testing/synctest"
	"time"
)

type bootstrapCleanup struct {
	bootstrapAPI
	delete func(context.Context, string) error
}

func (b bootstrapCleanup) deleteSecret(ctx context.Context, name string) error {
	return b.delete(ctx, name)
}

func TestTerminalHostedCleanupsYieldToFreshCallBudgets(t *testing.T) {
	for _, limit := range []int{3, maximumAssignments} {
		for _, restart := range []bool{false, true} {
			t.Run(fmt.Sprintf("limit=%d/restart=%t", limit, restart), func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					c, w, store := multipleFallbackFixture(t, limit)
					for range limit {
						if _, err := c.HandleDesiredRunnerCount(t.Context(), limit); err != nil {
							t.Fatal(err)
						}
					}
					active := c.state.Leases[c.names()[0]]
					for id, run := range w.runs {
						if id != active.RunID {
							run.Status, run.Conclusion = "completed", "success"
						}
					}
					if restart {
						for _, name := range c.names() {
							if name == active.Name {
								continue
							}
							if err := c.assigned(name).beginCleanup("success"); err != nil {
								t.Fatal(err)
							}
						}
						saved, err := store.load(c.state.Config)
						if err != nil {
							t.Fatal(err)
						}
						c.state = saved
					}
					var budgets []time.Duration
					cleanup := bootstrapCleanup{w, func(ctx context.Context, name string) error {
						deadline, _ := ctx.Deadline()
						budgets = append(budgets, time.Until(deadline))
						select {
						case <-ctx.Done():
							return ctx.Err()
						case <-time.After(25 * time.Second):
							return w.deleteSecret(ctx, name)
						}
					}}
					c.bootstrap = bootstrapLookup{cleanup, func(ctx context.Context, id int64) (*workflowRun, error) {
						select {
						case <-ctx.Done():
							return nil, ctx.Err()
						case <-time.After(15 * time.Second):
							return w.getRun(ctx, id)
						}
					}}
					w.assignedJobs = 1
					ctx, cancel := context.WithCancel(t.Context())
					loop := newCoordinatorLoop(ctx, c)
					if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop}); err != nil {
						cancel()
						t.Fatal(err)
					}
					startLoops(t, cancel, []*coordinatorLoop{loop})
					if actual, err := loop.HandleDesiredRunnerCount(t.Context(), limit); err != nil || actual != limit-1 {
						t.Fatal("terminal cleanups exhausted one shared call budget", actual, err)
					}
					time.Sleep(time.Duration(limit) * 25 * time.Second)
					synctest.Wait()
					if err := loop.invoke(t.Context(), func(context.Context) error {
						if len(c.state.Leases) != 1 || c.state.Leases[active.Name] == nil || len(w.runners) != 1 || c.paused != nil || w.dispatched != limit || len(budgets) != limit-1 {
							return fmt.Errorf("cleanup did not drain without replaying demand: %d leases, pause %v, budgets %v", len(c.state.Leases), c.paused, budgets)
						}
						for i, budget := range budgets {
							want := time.Minute
							if i == 0 && !restart {
								want -= 15 * time.Second
							}
							if budget != want {
								return fmt.Errorf("cleanup %d received %s, want a fresh %s budget", i, budget, want)
							}
						}
						return nil
					}); err != nil {
						t.Fatal(err)
					}
					saved, err := store.load(c.state.Config)
					if err != nil || len(saved.Leases) != 1 || saved.Leases[active.Name] == nil || saved.Leases[active.Name].CleanupIntent {
						t.Fatal("completed cleanup obligations remained in the journal", saved, err)
					}
				})
			})
		}
	}
}

func TestDeferredTerminalCleanupStillRequiresMatchingIdentity(t *testing.T) {
	c, w, store := multipleFallbackFixture(t, 3)
	for range 3 {
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
	}
	names := c.names()
	for _, run := range w.runs {
		run.Status, run.Conclusion = "completed", "success"
	}
	bad := c.state.Leases[names[2]]
	w.runs[bad.RunID].ID++
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil || n != 2 || !c.verificationPaused() {
		t.Fatal("deferred cleanup hid an identity mismatch", n, err, c.paused)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || !saved.Leases[names[1]].CleanupIntent || saved.Leases[bad.Name].CleanupIntent {
		t.Fatal("cleanup intent was missing or recorded for an unverified run", saved, err)
	}
	before := w.getCalls
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil || n != 1 || !c.verificationPaused() || w.getCalls != before {
		t.Fatal("deferred cleanup repeated status reads or cleared the identity pause", n, err, c.paused)
	}
	if c.state.Leases[bad.Name] == nil || w.runners[bad.Name] == nil || !slices.Equal(c.unverifiedRunners, []string{bad.Name}) || w.dispatched != 3 {
		t.Fatal("unverified execution was cleaned up or replayed", c.unverifiedRunners, w.dispatched)
	}
}

func TestFailedHostedCleanupDoesNotStarveOtherPendingCleanups(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 3)
		c.device.pollNow(0)
		issued := issueLocal(t, c, 0, 1)
		for range 3 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 4); err != nil {
				t.Fatal(err)
			}
		}
		var pending []*lease
		for _, name := range c.names() {
			if l := c.state.Leases[name]; l.Local == nil {
				pending = append(pending, l)
				if err := c.assigned(name).beginCleanup("success"); err != nil {
					t.Fatal(err)
				}
			}
		}
		failure := &apiError{502}
		c.bootstrap = bootstrapCleanup{w, func(ctx context.Context, name string) error {
			if name == pending[0].secretName() {
				return failure
			}
			return w.deleteSecret(ctx, name)
		}}
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop}); err != nil {
			cancel()
			t.Fatal(err)
		}
		startLoops(t, cancel, []*coordinatorLoop{loop})
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 4); err != nil {
			t.Fatal(err)
		}
		time.Sleep(cleanupRetryDelay)
		synctest.Wait()
		if err := loop.invoke(t.Context(), func(ctx context.Context) error {
			if len(c.state.Leases) != 2 || c.state.Leases[pending[0].Name] == nil || !c.state.Leases[pending[0].Name].CleanupIntent || c.paused != failure || w.dispatched != 3 {
				return fmt.Errorf("failed cleanup blocked siblings or lost its obligation: %d leases, pause %v", len(c.state.Leases), c.paused)
			}
			authorization, err := c.renewDevice(ctx, issued)
			if err != nil || !authorization.Continue {
				return fmt.Errorf("cleanup blocked local renewal: %v", err)
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	})
}

func TestExpiredOfferDoesNotHammerFailedHostedCleanup(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 1)
		c.device.pollNow(0)
		issued := issueLocal(t, c, 0, 1)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		c.device.pollNow(1)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
		offer := c.device.pollNow(1)
		if offer == nil {
			t.Fatal("missing offer")
		}
		for name, l := range c.state.Leases {
			if l.Local == nil {
				if err := c.assigned(name).beginCleanup("success"); err != nil {
					t.Fatal(err)
				}
			}
		}
		time.Sleep(offerLifetime)
		var attempts []time.Time
		c.bootstrap = bootstrapCleanup{w, func(ctx context.Context, name string) error {
			attempts = append(attempts, time.Now())
			if len(attempts) <= 3 {
				return &apiError{502}
			}
			return w.deleteSecret(ctx, name)
		}}
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		loop.demandObserved, loop.desiredCount = true, 3
		startLoops(t, cancel, []*coordinatorLoop{loop})
		start := time.Now()
		synctest.Wait()
		for range 3 {
			if _, err := loop.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
				t.Fatal(err)
			}
		}
		if err := loop.invoke(t.Context(), func(ctx context.Context) error {
			if len(attempts) != 1 || c.state.Leases[offer.Runner] != nil || w.dispatched != 1 {
				return fmt.Errorf("after expiry: attempts %v, remaining offer %v, dispatches %d", attempts, c.state.Leases[offer.Runner], w.dispatched)
			}
			renewal, err := c.renewDevice(ctx, issued)
			if err == nil && !renewal.Continue {
				return fmt.Errorf("issued runner lost authorization")
			}
			return err
		}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(cleanupRetryDelay)
		synctest.Wait()
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if len(attempts) != 2 || attempts[1].Sub(start) != cleanupRetryDelay {
				return fmt.Errorf("cleanup retry times %v", attempts)
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	})
}
