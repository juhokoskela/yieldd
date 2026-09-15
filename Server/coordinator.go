package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/actions/scaleset"
	"github.com/google/uuid"
)

type runnerAPI interface {
	GenerateJitRunnerConfig(context.Context, *scaleset.RunnerScaleSetJitRunnerSetting, int) (*scaleset.RunnerScaleSetJitRunnerConfig, error)
	GetRunnerByName(context.Context, string) (*scaleset.RunnerReference, error)
	RemoveRunner(context.Context, int64) error
}

type bootstrapAPI interface {
	putSecret(context.Context, string, string) error
	deleteSecret(context.Context, string) error
	dispatch(context.Context, *lease, string) (int64, error)
	findRun(context.Context, *lease) (*workflowRun, error)
	getRun(context.Context, int64) (*workflowRun, error)
	cancelRun(context.Context, int64) error
	runnerBusy(context.Context, string, int) (bool, error)
}

// The listener calls the scaler serially. The state-directory lock excludes another local owner.
type coordinator struct {
	lifetime  context.Context
	state     *state
	save      func(*state) error
	runners   runnerAPI
	bootstrap bootstrapAPI
	now       func() time.Time
	logger    *slog.Logger
}

func (c *coordinator) HandleJobStarted(_ context.Context, job *scaleset.JobStarted) error {
	c.logger.Info("Job started", "runner", job.RunnerName, "workflow_run", job.WorkflowRunID)
	return nil
}
func (c *coordinator) HandleJobCompleted(_ context.Context, job *scaleset.JobCompleted) error {
	c.logger.Info("Job completed", "runner", job.RunnerName, "workflow_run", job.WorkflowRunID, "result", job.Result)
	return nil
}

func (c *coordinator) HandleDesiredRunnerCount(ctx context.Context, count int) (actual int, err error) {
	defer func() {
		if err != nil {
			err = &provisioningError{err}
		}
	}()
	// The upstream listener removes cancellation while handling messages. Restore shutdown cancellation.
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if err := c.lifetime.Err(); err != nil {
		return 0, err
	}
	stop := context.AfterFunc(c.lifetime, cancel)
	defer stop()
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if c.state.Lease != nil {
		done, err := c.reconcile(ctx, false)
		if err != nil {
			return 1, err
		}
		if done {
			return 0, nil
		}
		return 1, nil
	}
	if count <= 0 {
		return 0, nil
	}
	c.state.Lease = &lease{Name: "yieldd-bootstrap-" + uuid.NewString(), Created: c.now().UTC()}
	if err := c.save(c.state); err != nil {
		return 0, err
	}
	l := c.state.Lease
	generated, err := c.runners.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{Name: l.Name, WorkFolder: "_work"}, c.state.ScaleSetID)
	if err != nil {
		return 1, fmt.Errorf("registration outcome requires recovery for %s: %w", l.Name, &sdkError{"register runner", err})
	}
	if generated == nil || generated.Runner == nil || generated.Runner.ID <= 0 || generated.Runner.Name != l.Name || generated.Runner.RunnerScaleSetID != c.state.ScaleSetID || generated.EncodedJITConfig == "" {
		return 1, errors.New("invalid JIT response; provisioning intent retained for recovery")
	}
	l.RunnerID = generated.Runner.ID
	l.JIT = generated.EncodedJITConfig
	if err := c.save(c.state); err != nil {
		return 1, err
	}
	return 1, c.prepare(ctx)
}

func (c *coordinator) prepare(ctx context.Context) error {
	l := c.state.Lease
	if l.RunnerID == 0 {
		return errors.New("registration outcome is unknown; run with --recover before provisioning again")
	}
	if l.JIT == "" {
		return errors.New("JIT configuration is missing; run with --recover")
	}
	if err := c.bootstrap.putSecret(ctx, l.secretName(), l.JIT); err != nil {
		return fmt.Errorf("store bootstrap credential: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	l.JIT = ""
	l.DispatchIntent = true
	if err := c.save(c.state); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		// The durable save can outlast the deadline. No dispatch was attempted.
		return errors.Join(err, c.beginCleanup(""))
	}
	runID, err := c.bootstrap.dispatch(ctx, l, c.state.Config.Fallback)
	if err != nil {
		if dispatchRejected(err) {
			return errors.Join(fmt.Errorf("bootstrap dispatch rejected; restart or use --recover to clean up: %w", err), c.beginCleanup("rejected"))
		}
		return fmt.Errorf("dispatch outcome is uncertain; restart to reconcile, not redispatch: %w", err)
	}
	l.RunID = runID
	if err := c.save(c.state); err != nil {
		return fmt.Errorf("record dispatched bootstrap: %w", err)
	}
	c.logger.Info("Bootstrap dispatched", "runner", l.Name, "run", runID, "infrastructure", c.state.Config.Infrastructure)
	return nil
}

func (c *coordinator) reconcile(ctx context.Context, recoverOnly bool) (bool, error) {
	l := c.state.Lease
	if l == nil {
		return true, nil
	}
	if l.CleanupIntent {
		return c.finishCleanup(ctx, recoverOnly)
	}
	if !l.DispatchIntent {
		if recoverOnly {
			if err := c.beginCleanup(""); err != nil {
				return false, err
			}
			return c.finishCleanup(ctx, recoverOnly)
		}
		return false, c.prepare(ctx)
	}
	var run *workflowRun
	var err error
	if l.RunID == 0 {
		run, err = c.bootstrap.findRun(ctx, l)
		if err != nil {
			return false, err
		}
		if run == nil {
			if c.now().Sub(l.Created) > 5*time.Minute {
				return false, fmt.Errorf("dispatch for %s is still unconfirmed; intent retained, no replacement dispatched", l.Name)
			}
			return false, nil
		}
	} else {
		run, err = c.bootstrap.getRun(ctx, l.RunID)
		if hasHTTPStatus(err, 404) {
			return c.recoverMissingRun(ctx, recoverOnly)
		}
		if err != nil {
			return false, err
		}
	}
	if !run.matches(l) {
		return false, errors.New("bootstrap run identity does not match its lease")
	}
	if l.RunID == 0 {
		l.RunID = run.ID
		if err := c.save(c.state); err != nil {
			return false, err
		}
	}
	if run.Status != "completed" {
		// Queue time is not covered by the workflow job timeout. Do not leave a queued bootstrap indefinitely.
		if !recoverOnly && c.now().Sub(l.Created) <= 25*time.Minute {
			return false, nil
		}
		err := c.bootstrap.cancelRun(ctx, l.RunID)
		if err == nil {
			c.logger.Info("Bootstrap cancellation requested; waiting for terminal state", "run", l.RunID)
			return false, nil
		}
		if !hasHTTPStatus(err, 409) {
			return false, fmt.Errorf("cancel bootstrap: %w", err)
		}
		run, err = c.bootstrap.getRun(ctx, l.RunID)
		if err != nil {
			return false, fmt.Errorf("recheck bootstrap after cancellation conflict: %w", err)
		}
		if !run.matches(l) {
			return false, errors.New("bootstrap run identity does not match its lease")
		}
		if run.Status != "completed" {
			return false, nil
		}
	}
	if err := c.beginCleanup(run.Conclusion); err != nil {
		return false, err
	}
	return c.finishCleanup(ctx, recoverOnly)
}

func (c *coordinator) recoverMissingRun(ctx context.Context, recoverOnly bool) (bool, error) {
	runner, err := c.runners.GetRunnerByName(ctx, c.state.Lease.Name)
	if err != nil {
		return false, &sdkError{"check runner for missing workflow", err}
	}
	if runner != nil {
		return false, errors.New("workflow is unavailable but its runner is still registered; restore workflow access or confirm termination and remove the registration before retrying --recover")
	}
	if err := c.beginCleanup("unknown"); err != nil {
		return false, err
	}
	return c.finishCleanup(ctx, recoverOnly)
}

func (c *coordinator) beginCleanup(conclusion string) error {
	l := c.state.Lease
	if l.CleanupIntent {
		return nil
	}
	nextLease := *l
	nextLease.CleanupIntent = true
	nextLease.Conclusion = conclusion
	nextLease.JIT = ""
	next := *c.state
	next.Lease = &nextLease
	if err := c.save(&next); err != nil {
		return fmt.Errorf("persist cleanup intent: %w", err)
	}
	*l = nextLease
	return nil
}

func (c *coordinator) finishCleanup(ctx context.Context, recoverOnly bool) (bool, error) {
	l := c.state.Lease
	if err := c.cleanup(ctx); err != nil {
		return false, err
	}
	c.logger.Info("Bootstrap cleaned up", "runner", l.Name, "run", l.RunID, "conclusion", l.Conclusion)
	if l.RunID != 0 && l.Conclusion != "success" && !recoverOnly {
		return true, fmt.Errorf("bootstrap %d concluded %s; stopped after cleanup rather than automatically retrying the workload", l.RunID, l.Conclusion)
	}
	return true, nil
}

func (c *coordinator) cleanup(ctx context.Context) error {
	l := c.state.Lease
	if !l.CleanupIntent {
		return errors.New("cleanup requires a persisted cleanup intent")
	}
	runner, err := c.runners.GetRunnerByName(ctx, l.Name)
	if err != nil {
		return &sdkError{"find runner for cleanup", err}
	}
	if runner != nil {
		if runner.Name != l.Name || runner.RunnerScaleSetID != c.state.ScaleSetID || (l.RunnerID != 0 && runner.ID != l.RunnerID) {
			return errors.New("runner identity does not match its lease; cleanup refused")
		}
		busy, err := c.bootstrap.runnerBusy(ctx, c.state.Config.Repository, runner.ID)
		if err != nil {
			return err
		}
		if busy {
			return errors.New("runner is still busy; cleanup obligation retained")
		}
		if err := c.runners.RemoveRunner(ctx, int64(runner.ID)); err != nil && !errors.Is(err, scaleset.RunnerNotFoundError) {
			return &sdkError{"remove runner", err}
		}
	}
	if err := c.bootstrap.deleteSecret(ctx, l.secretName()); err != nil {
		return err
	}
	next := *c.state
	next.Lease = nil
	if err := c.save(&next); err != nil {
		return err
	}
	*c.state = next
	return nil
}
