package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"slices"
	"time"

	"github.com/actions/scaleset"
	"github.com/google/uuid"
)

type runnerAPI interface {
	GetRunnerScaleSetByID(context.Context, int) (*scaleset.RunnerScaleSet, error)
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

const maximumAssignments = 16

// One event loop owns every assignment in a repository/platform queue.
type coordinator struct {
	state             *state
	save              func(*state) error
	runners           runnerAPI
	bootstrap         bootstrapAPI
	logger            *slog.Logger
	device            *deviceQueue
	reportedLocalHold map[string]localPhase
	refreshDemand     bool
	paused            error
}

type assignment struct {
	*coordinator
	lease *lease
}

type journalWriteError struct{ cause error }

func (e *journalWriteError) Error() string { return e.cause.Error() }
func (e *journalWriteError) Unwrap() error { return e.cause }

func isJournalWrite(err error) bool {
	var journal *journalWriteError
	return errors.As(err, &journal)
}

func (c *coordinator) hasFallback() bool {
	for _, l := range c.state.Leases {
		if l.Local == nil {
			return true
		}
	}
	return false
}

func (c *coordinator) hasPendingOffer() bool {
	for _, l := range c.state.Leases {
		if l.Local != nil && !l.CleanupIntent && l.Local.Phase != localIssued {
			return true
		}
	}
	return false
}

func (c *coordinator) hasIssuedLocal() bool {
	for _, l := range c.state.Leases {
		if l.Local != nil && l.Local.Phase == localIssued {
			return true
		}
	}
	return false
}

func (c *coordinator) assigned(name string) *assignment {
	return &assignment{coordinator: c, lease: c.state.Leases[name]}
}

func (c *coordinator) names() []string {
	return slices.Sorted(maps.Keys(c.state.Leases))
}

// Publish the complete journal before changing the event loop's view.
func (a *assignment) replace(nextLease *lease) error {
	next := *a.state
	next.Leases = maps.Clone(a.state.Leases)
	if next.Leases == nil {
		next.Leases = make(map[string]*lease)
	}
	if nextLease == nil {
		delete(next.Leases, a.lease.Name)
	} else {
		next.Leases[nextLease.Name] = nextLease
	}
	if err := a.save(&next); err != nil {
		return &journalWriteError{err}
	}
	*a.state = next
	a.lease = nextLease
	a.device.update(a.state)
	return nil
}

func (c *coordinator) HandleJobStarted(_ context.Context, job *scaleset.JobStarted) error {
	if err := c.assigned(job.RunnerName).recordLocalJob(job.RunnerID, false); err != nil {
		return err
	}
	c.logger.Info("Job started", "runner", job.RunnerName, "workflow_run", job.WorkflowRunID)
	return nil
}

func (c *coordinator) HandleJobCompleted(_ context.Context, job *scaleset.JobCompleted) error {
	if err := c.assigned(job.RunnerName).recordLocalJob(job.RunnerID, true); err != nil {
		return err
	}
	c.logger.Info("Job completed", "runner", job.RunnerName, "workflow_run", job.WorkflowRunID, "result", job.Result)
	return nil
}

func (c *coordinator) reconcile(ctx context.Context, recoverOnly bool) (bool, error) {
	var failures []error
	for _, name := range c.names() {
		if err := ctx.Err(); err != nil {
			return false, errors.Join(append(failures, err)...)
		}
		if _, err := c.assigned(name).reconcile(ctx, recoverOnly); err != nil {
			failures = append(failures, err)
			if isJournalWrite(err) {
				return false, errors.Join(failures...)
			}
		}
	}
	return len(c.state.Leases) == 0, errors.Join(failures...)
}

func (c *coordinator) HandleDesiredRunnerCount(ctx context.Context, count int) (int, error) {
	err := c.reconcileAndProvision(ctx, count)
	if err != nil && !isJournalWrite(err) && !onlyCancellation(err) && c.hasIssuedLocal() {
		// Stop provisioning, not renewal or completion of already issued siblings.
		if c.paused == nil {
			c.logger.Error("Queue provisioning paused; issued local runners can finish. Resolve the error and restart to resume", "error", err)
			c.paused = err
		}
		c.device.forget(c.state.Owner)
		err = nil
	}
	if err != nil {
		err = &provisioningError{err}
	}
	return len(c.state.Leases), err
}

func (c *coordinator) reconcileAndProvision(ctx context.Context, count int) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if c.hasFallback() {
		// A queue already using fallback must not hold FIFO priority while
		// blocked on GitHub. Rejoin after reconciliation if it still needs a Mac.
		c.device.forget(c.state.Owner)
	}
	completed := false
	var failures []error
	for _, name := range c.names() {
		if err := ctx.Err(); err != nil {
			return errors.Join(append(failures, err)...)
		}
		a := c.assigned(name)
		l := a.lease
		local := l.Local
		if count <= 0 && local != nil && local.Phase == localIssued && !local.JobStarted && !local.expired() {
			next := *local
			next.Expires = time.Now().UTC()
			if err := a.saveLocal(&next, ""); err != nil {
				return err
			}
		}
		recoverOnly := (count <= 0 || c.paused != nil) && !l.DispatchIntent && (local == nil || local.Phase != localIssued)
		done, err := a.reconcile(ctx, recoverOnly)
		if err != nil && !isJournalWrite(err) && a.lease != nil && a.lease.Local != nil && a.lease.CleanupIntent && transientFailure(err) {
			c.logger.Warn("Local cleanup retained for retry", "runner", name, "retry_delay", cleanupRetryDelay, "error", err)
			continue
		}
		if err != nil {
			failures = append(failures, err)
			if isJournalWrite(err) || onlyCancellation(err) {
				return errors.Join(failures...)
			}
			continue
		}
		completed = completed || (done && !(c.state.Config.LocalOnly && local != nil && local.Phase != localIssued))
	}
	if err := errors.Join(failures...); err != nil {
		return err
	}
	if c.paused != nil {
		if c.hasIssuedLocal() {
			return nil
		}
		return c.paused
	}
	// Never replace completed execution from the listener's cached demand.
	if completed {
		return nil
	}
	if count > 0 && c.refreshDemand {
		set, err := c.runners.GetRunnerScaleSetByID(ctx, c.state.ScaleSetID)
		if err != nil {
			return &sdkError{"refresh demand after cleanup", err}
		}
		if set == nil || set.ID != c.state.ScaleSetID || set.Statistics == nil || set.Statistics.TotalAssignedJobs < 0 {
			return errors.New("invalid scale set statistics after cleanup")
		}
		count = set.Statistics.TotalAssignedJobs
	}
	count = min(count, maximumAssignments)
	if count <= len(c.state.Leases) {
		c.device.forget(c.state.Owner)
		return nil
	}
	// Registration runs on this queue's event loop. Offer the next worker only
	// after issuance so slow GitHub I/O cannot consume another offer's five seconds.
	if c.hasPendingOffer() {
		return nil
	}
	for len(c.state.Leases) < count {
		if err := ctx.Err(); err != nil {
			return err
		}
		if c.state.Config.LocalOnly {
			c.device.wait(c.state.Owner)
		}
		l := &lease{Name: "yieldd-bootstrap-" + uuid.NewString(), Created: time.Now().UTC()}
		slot, local := 0, false
		if c.state.Config.DeviceID != "" {
			slot, local = c.device.claim(c.state.Owner, l.Name)
		}
		if !local {
			if c.state.Config.LocalOnly {
				return nil
			}
			// Preserve the existing paid-fallback limit while local work scales out.
			if c.hasFallback() {
				if c.state.Config.DeviceID != "" {
					c.device.wait(c.state.Owner)
				}
				return nil
			}
		} else {
			l.Local = &localLease{DeviceID: c.state.Config.DeviceID, Slot: slot, Phase: localOffered, Expires: time.Now().UTC().Add(offerLifetime)}
		}
		a := &assignment{coordinator: c, lease: l}
		if err := a.replace(l); err != nil {
			return err
		}
		c.refreshDemand = false
		if local {
			c.logger.Info("Local offer created", "runner", l.Name, "device", c.state.Config.DeviceID, "slot", slot, "accept_timeout", offerLifetime)
			return nil
		}
		if err := a.register(ctx); err != nil {
			return err
		}
		if err := a.prepare(ctx); err != nil {
			return err
		}
	}
	return nil
}

func (a *assignment) register(ctx context.Context) error {
	l := a.lease
	generated, err := a.runners.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{Name: l.Name, WorkFolder: "_work"}, a.state.ScaleSetID)
	if err != nil {
		return fmt.Errorf("registration outcome requires recovery for %s: %w", l.Name, &sdkError{"register runner", err})
	}
	if generated == nil || generated.Runner == nil || generated.Runner.ID <= 0 || generated.Runner.Name != l.Name || generated.Runner.RunnerScaleSetID != a.state.ScaleSetID || generated.EncodedJITConfig == "" {
		return errors.New("invalid JIT response; provisioning intent retained for recovery")
	}
	next := *l
	next.RunnerID, next.JIT = generated.Runner.ID, generated.EncodedJITConfig
	return a.replace(&next)
}

func (a *assignment) prepare(ctx context.Context) error {
	if a.state.Config.LocalOnly {
		return errors.New("local-only queues cannot dispatch fallback runners")
	}
	l := a.lease
	if l.RunnerID == 0 {
		return errors.New("registration outcome is unknown; run with --recover before provisioning again")
	}
	if l.JIT == "" {
		return errors.New("JIT configuration is missing; run with --recover")
	}
	if err := a.bootstrap.putSecret(ctx, l.secretName(), l.JIT); err != nil {
		return fmt.Errorf("store bootstrap credential: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	next := *l
	next.JIT, next.DispatchIntent = "", true
	if err := a.replace(&next); err != nil {
		// Rename may have published intent before directory sync failed.
		return errors.Join(err, a.beginCleanup(""))
	}
	if err := ctx.Err(); err != nil {
		// The durable save can outlast the deadline. No dispatch was attempted.
		return errors.Join(err, a.beginCleanup(""))
	}
	l = a.lease
	runID, err := a.bootstrap.dispatch(ctx, l, a.state.Config.Fallback)
	if err != nil {
		var notSent *requestNotSent
		if errors.As(err, &notSent) {
			return errors.Join(err, a.beginCleanup(""))
		}
		if dispatchRejected(err) {
			return errors.Join(fmt.Errorf("bootstrap dispatch rejected; restart or use --recover to clean up: %w", err), a.beginCleanup("rejected"))
		}
		return fmt.Errorf("dispatch outcome is uncertain; restart to reconcile, not redispatch: %w", err)
	}
	next = *a.lease
	next.RunID = runID
	if err := a.replace(&next); err != nil {
		return fmt.Errorf("record dispatched bootstrap: %w", err)
	}
	a.logger.Info("Bootstrap dispatched", "runner", l.Name, "run", runID, "infrastructure", a.state.Config.Infrastructure)
	return nil
}

func (a *assignment) reconcile(ctx context.Context, recoverOnly bool) (bool, error) {
	l := a.lease
	if l == nil {
		return true, nil
	}
	if l.CleanupIntent {
		return a.finishCleanup(ctx, recoverOnly)
	}
	if l.Local != nil {
		return a.reconcileLocal(ctx, recoverOnly)
	}
	if !l.DispatchIntent {
		if recoverOnly {
			if err := a.beginCleanup(""); err != nil {
				return false, err
			}
			return a.finishCleanup(ctx, recoverOnly)
		}
		return false, a.prepare(ctx)
	}
	var run *workflowRun
	var err error
	if l.RunID == 0 {
		run, err = a.bootstrap.findRun(ctx, l)
		if err != nil {
			return false, err
		}
		if run == nil {
			return false, fmt.Errorf("dispatch for %s is still unconfirmed; intent retained, retry reconciliation later without redispatching", l.Name)
		}
	} else {
		run, err = a.bootstrap.getRun(ctx, l.RunID)
		var missing *missingWorkflowRun
		if errors.As(err, &missing) {
			return a.recoverMissingRun(ctx, recoverOnly)
		}
		if err != nil {
			return false, err
		}
	}
	if !run.matches(l) {
		return false, errors.New("bootstrap run identity does not match its lease")
	}
	if l.RunID == 0 {
		next := *l
		next.RunID = run.ID
		if err := a.replace(&next); err != nil {
			return false, err
		}
	}
	l = a.lease
	if run.Status != "completed" {
		if !recoverOnly {
			return false, nil
		}
		err := a.bootstrap.cancelRun(ctx, l.RunID)
		if err == nil {
			a.logger.Info("Bootstrap cancellation requested; waiting for terminal state", "run", l.RunID)
			return false, nil
		}
		if !hasHTTPStatus(err, 409) {
			return false, fmt.Errorf("cancel bootstrap: %w", err)
		}
		run, err = a.bootstrap.getRun(ctx, l.RunID)
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
	if err := a.beginCleanup(run.Conclusion); err != nil {
		return false, err
	}
	return a.finishCleanup(ctx, recoverOnly)
}

func (a *assignment) recoverMissingRun(ctx context.Context, recoverOnly bool) (bool, error) {
	runner, err := a.runners.GetRunnerByName(ctx, a.lease.Name)
	if err != nil {
		return false, &sdkError{"check runner for missing workflow", err}
	}
	if runner != nil {
		return false, errors.New("workflow is unavailable but its runner is still registered; restore workflow access or confirm termination and remove the registration before retrying --recover")
	}
	if err := a.beginCleanup("unknown"); err != nil {
		return false, err
	}
	return a.finishCleanup(ctx, recoverOnly)
}

func (a *assignment) beginCleanup(conclusion string) error {
	l := a.lease
	if l.CleanupIntent {
		return nil
	}
	nextLease := *l
	nextLease.CleanupIntent = true
	nextLease.Conclusion = conclusion
	nextLease.JIT = ""
	if err := a.replace(&nextLease); err != nil {
		return fmt.Errorf("persist cleanup intent: %w", err)
	}
	return nil
}

func (a *assignment) finishCleanup(ctx context.Context, recoverOnly bool) (bool, error) {
	l := a.lease
	if err := a.cleanup(ctx); err != nil {
		return false, err
	}
	if l.Local != nil {
		a.logger.Info("Local runner cleaned up", "runner", l.Name, "device", l.Local.DeviceID)
	} else {
		a.logger.Info("Bootstrap cleaned up", "runner", l.Name, "run", l.RunID, "conclusion", l.Conclusion)
	}
	if l.RunID != 0 && l.Conclusion != "success" && !recoverOnly {
		return true, fmt.Errorf("bootstrap %d concluded %s; stopped after cleanup rather than automatically retrying the workload", l.RunID, l.Conclusion)
	}
	return true, nil
}

func (a *assignment) cleanup(ctx context.Context) error {
	l := a.lease
	if !l.CleanupIntent {
		return errors.New("cleanup requires a persisted cleanup intent")
	}
	runner, err := a.runners.GetRunnerByName(ctx, l.Name)
	if err != nil {
		return &sdkError{"find runner for cleanup", err}
	}
	if runner != nil {
		if runner.Name != l.Name || runner.RunnerScaleSetID != a.state.ScaleSetID || (l.RunnerID != 0 && runner.ID != l.RunnerID) {
			return errors.New("runner identity does not match its lease; cleanup refused")
		}
		busy, err := a.bootstrap.runnerBusy(ctx, a.state.Config.Repository, runner.ID)
		if err != nil {
			return err
		}
		if busy {
			return runnerStillBusy
		}
		if err := a.runners.RemoveRunner(ctx, int64(runner.ID)); err != nil && !errors.Is(err, scaleset.RunnerNotFoundError) {
			return &sdkError{"remove runner", err}
		}
	}
	if l.Local == nil {
		if err := a.bootstrap.deleteSecret(ctx, l.secretName()); err != nil {
			return err
		}
	}
	if err := a.replace(nil); err != nil {
		return err
	}
	delete(a.reportedLocalHold, l.Name)
	if l.RunnerID != 0 || l.DispatchIntent || (l.Local != nil && l.Local.Phase == localIssued) {
		a.refreshDemand = true
	}
	return nil
}
