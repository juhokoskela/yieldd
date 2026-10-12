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
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if w.dispatched != 2 || len(c.state.Leases) != 1 || c.refreshDemand {
				return fmt.Errorf("cached demand dispatched surplus bootstraps: %d dispatches, %d leases", w.dispatched, len(c.state.Leases))
			}
			return nil
		}); err != nil {
			t.Fatal(err)
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
					if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil || !c.identityPaused() {
						t.Fatal("identity pause missing", err, c.paused)
					}
					time.Sleep(5 * time.Second)
					w.getErr = failure
					if _, err := c.HandleDesiredRunnerCount(t.Context(), slots+1); err != nil || !c.identityPaused() {
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

type cancellingBootstrap struct {
	bootstrapAPI
	cancel context.CancelFunc
}

type deadlineBootstrap struct{ bootstrapAPI }

func (deadlineBootstrap) getRun(ctx context.Context, _ int64) (*workflowRun, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

func TestIdentityRetrySurvivesItsCallDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := newFixture(t)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		w.run.ID++
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || !c.identityPaused() {
			t.Fatal(err, c.paused)
		}
		time.Sleep(5 * time.Second)
		c.bootstrap = deadlineBootstrap{w}
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		defer cancel()
		if _, err := c.HandleDesiredRunnerCount(ctx, 1); err != nil || !c.identityPaused() {
			t.Fatal("call deadline ended automatic verification", err, c.paused)
		}
		c.bootstrap = w
		w.run.ID--
		time.Sleep(10 * time.Second)
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
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || !c.identityPaused() {
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
