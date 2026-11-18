package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"slices"
	"sync"
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
	// Status reads may run concurrently; all other operations stay serialized.
	getRun(context.Context, int64) (*workflowRun, error)
	cancelRun(context.Context, int64) error
	runnerBusy(context.Context, string, int) (bool, error)
}

const (
	maximumAssignments        = 16
	defaultMaxFallbackRunners = 1
	identityMaximumRetryDelay = time.Minute
)

var bootstrapIdentityMismatch = errors.New("bootstrap run identity does not match its lease")

// One event loop owns every assignment in a repository/platform queue.
type coordinator struct {
	state              *state
	save               func(*state) error
	runners            runnerAPI
	bootstrap          bootstrapAPI
	logger             *slog.Logger
	device             *deviceQueue
	reportedLocalHold  map[string]localPhase
	refreshDemand      bool
	demandUnavailable  bool
	paused             error
	identityRunners    []string
	identityRetryAt    time.Time
	identityRetryDelay time.Duration
	maxFallbackRunners int
	lastHostedCleanup  string
}

type assignment struct {
	*coordinator
	lease              *lease
	deferHostedCleanup bool
}

type journalWriteError struct{ cause error }

func (e *journalWriteError) Error() string { return e.cause.Error() }
func (e *journalWriteError) Unwrap() error { return e.cause }

func isJournalWrite(err error) bool {
	var journal *journalWriteError
	return errors.As(err, &journal)
}

func (c *coordinator) identityPaused() bool {
	return errors.Is(c.paused, bootstrapIdentityMismatch) && retryableBootstrapVerification(c.paused)
}

func (c *coordinator) fallbackFull() bool {
	return c.fallbackCount() >= c.maxFallbackRunners
}

func (c *coordinator) fallbackCount() int {
	count := 0
	for _, l := range c.state.Leases {
		if l.Local == nil {
			count++
		}
	}
	return count
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

func (c *coordinator) surplusAssignments(count int) map[string]bool {
	count = max(count, 0)
	var idle, pending []string
	for _, name := range c.names() {
		l := c.state.Leases[name]
		if l.CleanupIntent {
			continue
		}
		if local := l.Local; local != nil && local.Phase == localIssued {
			// Retired workers still hold their slots, but no longer satisfy demand.
			if local.JobCompleted || (!local.JobStarted && local.expired()) {
				continue
			}
			if !local.JobStarted {
				idle = append(idle, name)
				continue
			}
		} else if !l.DispatchIntent {
			pending = append(pending, name)
			continue
		}
		// Started jobs and dispatched or uncertain bootstraps must be reconciled,
		// not stopped solely because the aggregate demand count decreased.
		count--
	}
	retire := make(map[string]bool)
	// Keep issued idle workers before offers or undispatched provisioning.
	for _, name := range append(idle, pending...) {
		if count > 0 {
			count--
		} else {
			retire[name] = true
		}
	}
	return retire
}

// Publish the complete journal before changing the event loop's view.
func (a *assignment) replace(nextLease *lease) error {
	if a.lease != nil {
		if err := a.lease.validateTransition(nextLease); err != nil {
			return err
		}
	}
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
	identityPaused := c.identityPaused()
	retryDue := identityPaused && !time.Now().Before(c.identityRetryAt)
	previousRunners := c.identityRunners
	err := c.reconcileAndProvision(ctx, count)
	if ctx.Err() != nil && !isJournalWrite(err) {
		err = ctx.Err()
	}
	retryable := c.paused == nil || identityPaused
	switch {
	case retryable && (identityPaused || errors.Is(err, bootstrapIdentityMismatch)) && retryableBootstrapVerification(err):
		if !identityPaused || retryDue {
			c.identityRetryDelay = min(max(cleanupRetryDelay, c.identityRetryDelay*2), identityMaximumRetryDelay)
			c.identityRetryAt = time.Now().Add(c.identityRetryDelay)
		}
		if !identityPaused || !slices.Equal(previousRunners, c.identityRunners) || retryDue && c.identityRetryDelay == identityMaximumRetryDelay {
			c.logger.Warn("Bootstrap identity unverified; provisioning paused for automatic retry", "runners", c.identityRunners, "retry_delay", c.identityRetryDelay, "error", err)
		}
		if errors.Is(err, bootstrapIdentityMismatch) {
			c.paused = err
		}
	case err != nil && !isJournalWrite(err) && !onlyCancellation(err) && c.hasIssuedLocal():
		// Stop provisioning, not renewal or completion of already issued siblings.
		if retryable {
			c.logger.Error("Queue provisioning paused; issued local runners can finish. Resolve the error and restart to resume", "error", err)
			c.paused = err
		}
	default:
		return len(c.state.Leases), err
	}
	c.device.forget(c.state.Owner)
	return len(c.state.Leases), nil
}

func (c *coordinator) reconcileAndProvision(ctx context.Context, count int) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if c.fallbackCount() != 0 {
		// A queue already using fallback must not hold FIFO priority while
		// blocked on GitHub. Rejoin after reconciliation if it still needs a Mac.
		c.device.forget(c.state.Owner)
	}
	if a := c.nextHostedCleanup(); a != nil {
		c.lastHostedCleanup = a.lease.Name
		_, err := a.finishCleanup(ctx, false)
		if err == nil && c.nextHostedCleanup() != nil {
			c.device.redrive(c.state.Owner)
		}
		return err
	}
	completed := false
	hostedCleanupAttempted, hostedCleanupCompleted := false, false
	hostedProvisioned := false
	verificationPending := false
	retryLater := c.identityPaused() && time.Now().Before(c.identityRetryAt)
	var identityRunners []string
	var failures []error
	var surplus map[string]bool
	if !c.demandUnavailable {
		surplus = c.surplusAssignments(count)
	}
	var runs map[string]*bootstrapRunResult
	if !retryLater {
		runs = c.lookupBootstrapRuns(ctx)
	}
	// Verify dispatched identities before any sibling can resume provisioning.
	names := c.names()
	slices.SortStableFunc(names, func(a, b string) int {
		first, second := c.state.Leases[a].DispatchIntent, c.state.Leases[b].DispatchIntent
		if first == second {
			return 0
		}
		if first {
			return -1
		}
		return 1
	})
	provisioningPaused := c.paused != nil
	for _, name := range names {
		if err := ctx.Err(); err != nil {
			return err
		}
		a := c.assigned(name)
		a.deferHostedCleanup = hostedCleanupAttempted
		l := a.lease
		local := l.Local
		if retryLater && l.DispatchIntent && !l.CleanupIntent {
			verificationPending = true
			if slices.Contains(c.identityRunners, name) {
				identityRunners = append(identityRunners, name)
			}
			continue
		}
		if surplus[name] && local != nil && local.Phase == localIssued {
			next := *local
			next.Expires = time.Now().UTC()
			if err := a.saveLocal(&next, ""); err != nil {
				return err
			}
		}
		recoverOnly := (surplus[name] || provisioningPaused || c.demandUnavailable) && !l.DispatchIntent && (local == nil || local.Phase != localIssued)
		done, err := a.reconcileWithRun(ctx, recoverOnly, runs[name])
		if local == nil && !a.deferHostedCleanup && (done || a.lease != nil && a.lease.CleanupIntent) {
			hostedCleanupAttempted, hostedCleanupCompleted = true, done
			c.lastHostedCleanup = name
		}
		provisioningPaused = provisioningPaused || errors.Is(err, bootstrapIdentityMismatch)
		hostedProvisioned = hostedProvisioned || (!l.DispatchIntent && a.lease != nil && a.lease.DispatchIntent)
		if errors.Is(err, bootstrapIdentityMismatch) || (transientFailure(err) && slices.Contains(c.identityRunners, name)) {
			identityRunners = append(identityRunners, name)
		}
		if err != nil && !isJournalWrite(err) && a.lease != nil && a.lease.Local != nil && a.lease.CleanupIntent && transientFailure(err) {
			c.logger.Warn("Local cleanup retained for retry", "runner", name, "retry_delay", cleanupRetryDelay, "error", err)
			continue
		}
		if err != nil {
			failures = append(failures, err)
			if isJournalWrite(err) {
				return errors.Join(failures...)
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if onlyCancellation(err) {
				return err
			}
			continue
		}
		completed = completed || (done && !(c.state.Config.LocalOnly && local != nil && local.Phase != localIssued))
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if hostedCleanupCompleted && c.nextHostedCleanup() != nil {
		c.device.redrive(c.state.Owner)
	}
	c.identityRunners = identityRunners
	if err := errors.Join(failures...); err != nil {
		return err
	}
	if verificationPending {
		return c.paused
	}
	if c.identityPaused() {
		c.paused = nil
		c.identityRetryAt, c.identityRetryDelay = time.Time{}, 0
		c.logger.Info("Bootstrap identities verified; provisioning resumed")
	}
	if c.paused != nil {
		if c.hasIssuedLocal() {
			return nil
		}
		return c.paused
	}
	if c.demandUnavailable {
		c.device.forget(c.state.Owner)
		return nil
	}
	if hostedProvisioned {
		c.device.redrive(c.state.Owner)
		return nil
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
		// A stale positive listener count still needs refreshing after GitHub
		// reports no work. Keep that protection until positive demand is satisfied.
		if count > 0 {
			c.refreshDemand = false
		}
		c.device.forget(c.state.Owner)
		return nil
	}
	// Registration runs on this queue's event loop. Offer the next worker only
	// after issuance so slow GitHub I/O cannot consume another offer's five seconds.
	if c.hasPendingOffer() {
		return nil
	}
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
	if local {
		l.Local = &localLease{DeviceID: c.state.Config.DeviceID, Slot: slot, Phase: localOffered, Expires: time.Now().UTC().Add(offerLifetime)}
	} else if c.state.Config.LocalOnly {
		return nil
	} else if c.fallbackFull() {
		c.refreshDemand = false
		if c.state.Config.DeviceID != "" {
			c.device.wait(c.state.Owner)
		}
		return nil
	}
	a := &assignment{coordinator: c}
	if err := a.replace(l); err != nil {
		return err
	}
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
	// Give device requests a turn before the next provisioning operation.
	c.device.redrive(c.state.Owner)
	return nil
}

func (c *coordinator) nextHostedCleanup() *assignment {
	var first *assignment
	for _, name := range c.names() {
		l := c.state.Leases[name]
		if l.Local != nil || !l.CleanupIntent {
			continue
		}
		if first == nil {
			first = c.assigned(name)
		}
		if name > c.lastHostedCleanup {
			return c.assigned(name)
		}
	}
	return first
}

type bootstrapRunResult struct {
	run *workflowRun
	err error
}

func (c *coordinator) lookupBootstrapRuns(ctx context.Context) map[string]*bootstrapRunResult {
	runs := make(map[string]*bootstrapRunResult)
	api := c.bootstrap
	var pending sync.WaitGroup
	for name, l := range c.state.Leases {
		if l.Local != nil || l.CleanupIntent || l.RunID == 0 {
			continue
		}
		id, result := l.RunID, new(bootstrapRunResult)
		runs[name] = result
		// The queue has at most 16 leases. Only immutable status reads run
		// concurrently; the owner waits before validating or changing any lease.
		pending.Go(func() { result.run, result.err = api.getRun(ctx, id) })
	}
	pending.Wait()
	return runs
}

func (a *assignment) generateRegistration(ctx context.Context) (*scaleset.RunnerScaleSetJitRunnerConfig, error) {
	l := a.lease
	generated, err := a.runners.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{Name: l.Name, WorkFolder: "_work"}, a.state.ScaleSetID)
	if err != nil {
		return nil, fmt.Errorf("registration outcome requires recovery for %s: %w", l.Name, &sdkError{"register runner", err})
	}
	if generated == nil || generated.Runner == nil || generated.Runner.ID <= 0 || generated.Runner.Name != l.Name || generated.Runner.RunnerScaleSetID != a.state.ScaleSetID || generated.EncodedJITConfig == "" {
		return nil, errors.New("invalid JIT response; provisioning intent retained for recovery")
	}
	return generated, nil
}

func (a *assignment) register(ctx context.Context) error {
	generated, err := a.generateRegistration(ctx)
	if err != nil {
		return err
	}
	next := *a.lease
	next.RunnerID, next.JIT = generated.Runner.ID, generated.EncodedJITConfig
	return a.replace(&next)
}

func (a *assignment) recoveryTarget() string {
	return a.state.Config.Repository + "/" + a.state.Config.platform() + "/" + a.lease.Name
}

func (a *assignment) prepare(ctx context.Context) error {
	if a.state.Config.LocalOnly {
		return errors.New("local-only queues cannot dispatch fallback runners")
	}
	l := a.lease
	if l.RunnerID == 0 {
		return fmt.Errorf("registration outcome is unknown; run with --recover %s before provisioning again", a.recoveryTarget())
	}
	if l.JIT == "" {
		return fmt.Errorf("JIT configuration is missing; run with --recover %s", a.recoveryTarget())
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
			return errors.Join(fmt.Errorf("bootstrap dispatch rejected; restart or use --recover %s to clean up: %w", a.recoveryTarget(), err), a.beginCleanup("rejected"))
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
	return a.reconcileWithRun(ctx, recoverOnly, nil)
}

func (a *assignment) reconcileWithRun(ctx context.Context, recoverOnly bool, observed *bootstrapRunResult) (bool, error) {
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
		if observed != nil {
			run, err = observed.run, observed.err
		} else {
			run, err = a.bootstrap.getRun(ctx, l.RunID)
		}
		var missing *missingWorkflowRun
		if errors.As(err, &missing) {
			return a.recoverMissingRun(ctx, recoverOnly)
		}
		if err != nil {
			return false, err
		}
		if run == nil || run.ID != l.RunID {
			return false, identityMismatch(l, run)
		}
	}
	if l.RunID == 0 {
		next := *l
		next.RunID = run.ID
		if err := a.replace(&next); err != nil {
			return false, err
		}
		l = a.lease
	}
	if run.Status != "completed" && !recoverOnly {
		return false, nil
	}
	if run.Status != "completed" {
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
		if run == nil || run.ID != l.RunID {
			return false, identityMismatch(l, run)
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
		return false, fmt.Errorf("workflow is unavailable but its runner is still registered; restore workflow access or confirm termination and remove the registration before retrying --recover %s", a.recoveryTarget())
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
	if l.Local == nil && a.deferHostedCleanup {
		return false, nil
	}
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
	if runner != nil || l.RunnerID != 0 || l.DispatchIntent || (l.Local != nil && l.Local.Phase == localIssued) {
		a.refreshDemand = true
	}
	return nil
}
