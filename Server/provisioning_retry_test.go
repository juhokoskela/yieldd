package main

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"testing/synctest"
	"time"
)

func TestRefreshedDemandSurvivesProvisioningRedrives(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 3)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
		l := c.state.Leases[c.names()[0]]
		w.runs[l.RunID].Status, w.runs[l.RunID].Conclusion = "completed", "success"
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
		w.assignedJobs = 1
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop}); err != nil {
			cancel()
			t.Fatal(err)
		}
		startLoops(t, cancel, []*coordinatorLoop{loop})
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
		synctest.Wait()
		// The SDK repeats its last statistics on empty polls.
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if w.dispatched != 2 || len(c.state.Leases) != 1 {
				return fmt.Errorf("cached demand dispatched surplus bootstraps: %d dispatches, %d leases", w.dispatched, len(c.state.Leases))
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	})
}

func TestMatchingDemandAboveCapacityEndsRefresh(t *testing.T) {
	c, w, _ := newFixture(t)
	count := maximumAssignments + 1
	if _, err := c.HandleDesiredRunnerCount(t.Context(), count); err != nil {
		t.Fatal(err)
	}
	c.refreshDemand, w.assignedJobs = true, count
	for range 2 {
		if _, err := c.HandleDesiredRunnerCount(t.Context(), count); err != nil {
			t.Fatal(err)
		}
	}
	if w.demandCalls != 1 || w.dispatched != 1 {
		t.Fatal("matching counts kept refreshing at capacity", w.demandCalls, w.dispatched)
	}
}

func TestExpiredOfferRechecksDemandBeforePaidFallback(t *testing.T) {
	for _, fresh := range []int{0, 1} {
		t.Run(fmt.Sprintf("assigned=%d", fresh), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, _ := concurrentFixture(t, 2)
				issued := issueLocal(t, c, 0, 2)
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
					t.Fatal(err)
				}
				offer := c.device.pollNow(1)
				if offer == nil {
					t.Fatal("missing second offer")
				}
				if err := c.completeDevice(t.Context(), issued); err != nil {
					t.Fatal(err)
				}
				w.assignedJobs = fresh
				time.Sleep(offerLifetime)
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
					t.Fatal(err)
				}
				if w.dispatched != fresh || w.demandCalls == 0 || (c.state.Leases[offer.Runner] != nil) != (fresh == 1) {
					t.Fatal("offer expiry ignored current demand", w.dispatched, w.demandCalls)
				}
			})
		})
	}
}

func TestInterruptedIssuedCleanupCannotFundAnExpiredOffer(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := concurrentFixture(t, 2)
		issued := issueLocal(t, c, 0, 2)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		offer := c.device.pollNow(1)
		w.lookupErr = &apiError{502}
		if err := c.completeDevice(t.Context(), issued); err == nil || !c.state.Leases[issued.Runner].CleanupIntent {
			t.Fatal("missing issued cleanup", err)
		}
		w.assignedJobs = 0
		time.Sleep(offerLifetime)
		_, err := c.HandleDesiredRunnerCount(t.Context(), 2)
		if err != nil || w.dispatched != 0 || w.demandCalls == 0 || c.state.Leases[issued.Runner] == nil || offer == nil {
			t.Fatal("paid fallback bypassed pending cleanup", err, w.events)
		}
	})
}

func TestIdentityPauseSurvivesTransientVerificationFailures(t *testing.T) {
	for _, failure := range []error{&apiError{status: 502}, &apiError{status: 429}, context.DeadlineExceeded} {
		for _, slots := range []int{0, 1} {
			t.Run(fmt.Sprintf("%s/local=%d", failure, slots), func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					c, w, _ := concurrentFixture(t, slots)
					if slots != 0 {
						issueLocal(t, c, 0, 1)
					}
					if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil {
						t.Fatal(err)
					}
					w.run.ID++
					if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil || !c.verificationPaused() {
						t.Fatal("identity pause missing", err, c.paused)
					}
					time.Sleep(5 * time.Second)
					w.getErr = failure
					if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil || !c.verificationPaused() {
						t.Fatal("transient failure ended identity recovery", err, c.paused)
					}
					w.getErr = nil
					w.run.ID--
					time.Sleep(10 * time.Second)
					if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil || c.paused != nil || w.dispatched != 1 {
						t.Fatal("verified identity could not resume after transient failure", err, c.paused)
					}
				})
			})
		}
	}
}

func TestFirstStatusOutagePausesOnlyUntilVerification(t *testing.T) {
	for _, slots := range []int{0, 1} {
		t.Run(fmt.Sprintf("local=%d", slots), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, _ := concurrentFixture(t, slots)
				var issued deviceRequest
				if slots != 0 {
					issued = issueLocal(t, c, 0, 1)
				}
				if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil {
					t.Fatal(err)
				}
				w.getErr = &apiError{502}
				if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+2); err != nil || !c.verificationPaused() {
					t.Fatal("initial 502 stopped the queue", err, c.paused)
				}
				w.getErr = nil
				before := w.getCalls
				if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil || w.getCalls != before {
					t.Fatal("callback bypassed retry deadline", err)
				}
				if slots != 0 {
					if renewal, err := c.renewDevice(t.Context(), issued); err != nil || !renewal.Continue {
						t.Fatal("local sibling lost authorization", renewal, err)
					}
				}
				time.Sleep(cleanupRetryDelay)
				if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil || c.paused != nil || w.dispatched != 1 {
					t.Fatal("status recovery changed execution", err, c.paused, w.dispatched)
				}
			})
		})
	}
}

type cancellingBootstrap struct {
	bootstrapAPI
	cancel context.CancelFunc
}

type deadlineBootstrap struct{ bootstrapAPI }

func (deadlineBootstrap) getRun(ctx context.Context, _ int64) (*workflowRun, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

func TestInitialStatusReadSurvivesItsCallDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := newFixture(t)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		c.bootstrap = deadlineBootstrap{w}
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		defer cancel()
		if _, err := c.HandleDesiredRunnerCount(ctx, 1); err != nil || !c.verificationPaused() {
			t.Fatal("call deadline ended automatic verification", err, c.paused)
		}
		c.bootstrap = w
		time.Sleep(cleanupRetryDelay)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || c.paused != nil || w.dispatched != 1 {
			t.Fatal("verification could not recover after its deadline", err, c.paused)
		}
	})
}

func (b cancellingBootstrap) getRun(ctx context.Context, id int64) (*workflowRun, error) {
	run, err := b.bootstrapAPI.getRun(ctx, id)
	b.cancel()
	return run, err
}

func TestShutdownDuringIdentityRetryReturnsCancellation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 2)
		for range 2 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
				t.Fatal(err)
			}
		}
		for _, run := range w.runs {
			run.ID++
		}
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || !c.verificationPaused() {
			t.Fatal("identity retry was not pending", err, c.paused)
		}
		pause := c.paused
		time.Sleep(5 * time.Second)
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		c.bootstrap = cancellingBootstrap{w, cancel}
		if _, err := c.HandleDesiredRunnerCount(ctx, 2); !onlyCancellation(err) {
			t.Fatal("shutdown was reported as an identity failure", err)
		}
		if c.paused != pause || w.dispatched != 2 {
			t.Fatal("shutdown changed provisioning state", c.paused)
		}
	})
}

func TestOperatorAttentionPauseCannotBecomeIdentityRecovery(t *testing.T) {
	c, w, _ := concurrentFixture(t, 1)
	issueLocal(t, c, 0, 1)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
		t.Fatal(err)
	}
	failure := errors.New("operator attention required")
	c.paused = failure
	w.run.ID++
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || c.paused != failure {
		t.Fatal("operator pause was downgraded", err, c.paused)
	}
	w.run.ID--
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || c.paused != failure {
		t.Fatal("operator pause cleared itself after identity verification", err, c.paused)
	}
}
