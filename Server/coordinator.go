package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"slices"
	"strings"
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
	maximumAssignments            = 16
	defaultMaxFallbackRunners     = 1
	verificationMaximumRetryDelay = time.Minute
)

var bootstrapIdentityMismatch = errors.New("bootstrap run identity does not match its lease")

// One event loop owns every assignment in a repository/platform queue.
type coordinator struct {
	state                  *state
	save                   func(*state) error
	runners                runnerAPI
	bootstrap              bootstrapAPI
	logger                 *slog.Logger
	device                 *deviceQueue
	reportedLocalHold      map[string]localPhase
	refreshDemand          bool
	demandUnavailable      bool
	paused                 error
	unverifiedRunners      []string
	verificationRetryAt    time.Time
	verificationRetryDelay time.Duration
	maxFallbackRunners     int
	demandRetryAt          time.Time
	hostedCleanupRetry     map[string]time.Time
	hostedBackoffUntil     time.Time
	hostedBackoffDelay     time.Duration
	lastRenewed            map[string]time.Time
	lastBusyCheck          map[string]time.Time
	jobStartedByEvent      map[string]bool
	fencedLocal            map[string]bool
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

func (c *coordinator) verificationPaused() bool {
	return retryableBootstrapVerification(c.paused)
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

func (l *lease) countsAsSupply() bool {
	if l == nil || l.CleanupIntent {
		return false
	}
	if local := l.Local; local != nil && local.Phase == localIssued {
		if local.JobCompleted || (!local.JobStarted && local.expired()) {
			return false
		}
	}
	return true
}

func (c *coordinator) supplyCount() int {
	count := 0
	for _, l := range c.state.Leases {
		if l.countsAsSupply() {
			count++
		}
	}
	return count
}

func (c *coordinator) hostedBackoffActive() bool {
	return !c.hostedBackoffUntil.IsZero() && time.Now().Before(c.hostedBackoffUntil)
}

func (c *coordinator) hasNonSupplyLease() bool {
	for _, l := range c.state.Leases {
		if !l.countsAsSupply() {
			return true
		}
	}
	return false
}

func (c *coordinator) needsDemandRefresh() bool {
	if c.refreshDemand {
		return true
	}
	for _, l := range c.state.Leases {
		if l.CleanupIntent && l.Local != nil && l.Local.Phase == localIssued {
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
		delete(a.lastRenewed, a.lease.Name)
		delete(a.lastBusyCheck, a.lease.Name)
		delete(a.jobStartedByEvent, a.lease.Name)
		delete(a.fencedLocal, a.lease.Name)
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
	if err := c.assigned(job.RunnerName).recordLocalJob(job.RunnerID, job.WorkflowRunID, jobStarted); err != nil {
		return err
	}
	c.logger.Info("Job started", "runner", job.RunnerName, "workflow_run", job.WorkflowRunID)
	return nil
}

func (c *coordinator) HandleJobCompleted(_ context.Context, job *scaleset.JobCompleted) error {
	event := jobUnsuccessful
	if strings.EqualFold(job.Result, "succeeded") || strings.EqualFold(job.Result, "success") {
		event = jobSucceeded
	}
	if err := c.assigned(job.RunnerName).recordLocalJob(job.RunnerID, job.WorkflowRunID, event); err != nil {
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
	verificationPaused := c.verificationPaused()
	retryDue := verificationPaused && !time.Now().Before(c.verificationRetryAt)
	previousRunners := c.unverifiedRunners
	err := c.reconcileAndProvision(ctx, count)
	if ctx.Err() == context.Canceled && !isJournalWrite(err) {
		err = ctx.Err()
	}
	retryable := c.paused == nil || verificationPaused
	switch {
	case retryable && retryableBootstrapVerification(err):
		if !verificationPaused || retryDue {
			c.verificationRetryDelay = min(max(cleanupRetryDelay, c.verificationRetryDelay*2), verificationMaximumRetryDelay)
			c.verificationRetryAt = time.Now().Add(c.verificationRetryDelay)
		}
		if !verificationPaused || !slices.Equal(previousRunners, c.unverifiedRunners) || retryDue && c.verificationRetryDelay == verificationMaximumRetryDelay {
			c.logger.Warn("Bootstrap status unverified; provisioning paused for automatic retry", "runners", c.unverifiedRunners, "retry_delay", c.verificationRetryDelay, "error", err)
		}
		c.paused = err
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
		done, err := a.finishCleanup(ctx, false)
		if c.nextHostedCleanup() != nil || (done && err == nil && count > 0 && !c.demandUnavailable) {
			c.device.redrive(c.state.Owner)
		}
		return err
	}
	completed := false
	hostedCleanupAttempted, hostedCleanupCompleted := false, false
	hostedProvisioned := false
	verificationPending := false
	retryLater := c.verificationPaused() && time.Now().Before(c.verificationRetryAt)
	var unverifiedRunners []string
	var failures []error
	listenerCount := count
	if count == 0 || c.demandUnavailable || c.paused != nil {
		c.demandRetryAt = time.Time{}
	}
	// A full hosted-only queue can observe and clean up its existing runs
	// without a separate demand read. Cleanup wakes it when capacity returns.
	fullHosted := c.state.Config.DeviceID == "" && c.fallbackFull()
	if count > 0 && !fullHosted && !c.demandUnavailable && c.paused == nil && c.needsDemandRefresh() {
		var err error
		count, err = c.readPlacementDemand(ctx)
		if err != nil {
			return err
		}
		if ctx.Err() == context.DeadlineExceeded && !c.demandRetryAt.IsZero() {
			return nil
		}
	}
	var surplus map[string]bool
	if !c.demandUnavailable && c.demandRetryAt.IsZero() && (c.paused == nil || count == 0) {
		surplus = c.surplusAssignments(count)
	}
	var runs map[string]*bootstrapRunResult
	if !retryLater {
		runs = c.lookupBootstrapRuns(ctx)
		if ctx.Err() == context.DeadlineExceeded {
			// The reads used the full callback budget. Preserve their errors
			// without starting any writes on the expired context.
			for _, name := range c.names() {
				if result := runs[name]; result != nil && result.err != nil {
					unverifiedRunners = append(unverifiedRunners, name)
					var missing *missingWorkflowRun
					if errors.As(result.err, &missing) {
						// Absence needs a runner lookup on a fresh context.
						failures = append(failures, statusReadError(ctx.Err()))
					} else {
						failures = append(failures, statusReadError(result.err))
					}
				}
			}
			if len(failures) > 0 {
				c.unverifiedRunners = unverifiedRunners
				return errors.Join(failures...)
			}
		}
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
		a.deferHostedCleanup = hostedCleanupAttempted || time.Now().Before(c.hostedCleanupRetry[name])
		l := a.lease
		local := l.Local
		if retryLater && l.DispatchIntent && !l.CleanupIntent {
			verificationPending = true
			if slices.Contains(c.unverifiedRunners, name) {
				unverifiedRunners = append(unverifiedRunners, name)
			}
			continue
		}
		if local != nil && !l.CleanupIntent && (local.Phase == localOffered || local.Phase == localDeclined) &&
			(!c.demandRetryAt.IsZero() || completed && !provisioningPaused) {
			continue
		}
		if surplus[name] && local != nil && local.Phase == localIssued {
			next := *local
			next.Expires = time.Now().UTC()
			if err := a.saveLocal(&next); err != nil {
				return err
			}
		}
		recoverOnly := (surplus[name] || provisioningPaused || c.demandUnavailable) && !l.DispatchIntent && (local == nil || local.Phase != localIssued)
		done, err := a.reconcileWithRun(ctx, recoverOnly, runs[name])
		if local == nil && !a.deferHostedCleanup && (done || a.lease != nil && a.lease.CleanupIntent) {
			hostedCleanupAttempted, hostedCleanupCompleted = true, done
		}
		provisioningPaused = provisioningPaused || (local == nil && err != nil)
		hostedProvisioned = hostedProvisioned || (!l.DispatchIntent && a.lease != nil && a.lease.DispatchIntent)
		if retryableBootstrapVerification(err) {
			unverifiedRunners = append(unverifiedRunners, name)
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
				c.unverifiedRunners = unverifiedRunners
				return errors.Join(failures...)
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
	c.unverifiedRunners = unverifiedRunners
	if err := errors.Join(failures...); err != nil {
		return err
	}
	if verificationPending {
		return c.paused
	}
	if c.verificationPaused() {
		c.paused = nil
		c.verificationRetryAt, c.verificationRetryDelay = time.Time{}, 0
		c.logger.Info("Bootstrap status verified; provisioning resumed")
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
		if listenerCount > 0 && c.needsDemandRefresh() {
			c.device.redrive(c.state.Owner)
		}
		return nil
	}
	if !c.demandRetryAt.IsZero() || fullHosted {
		return nil
	}
	// Verification may just have resumed. Recheck demand before allocating.
	if provisioningPaused && c.needsDemandRefresh() && count > 0 {
		c.device.redrive(c.state.Owner)
		return nil
	}
	countsAgree := count == listenerCount
	count = min(count, maximumAssignments)
	if count <= c.supplyCount() {
		// The listener can repeat a stale positive count on every empty poll.
		if count > 0 && countsAgree {
			c.refreshDemand = false
		}
		c.device.forget(c.state.Owner)
		return nil
	}
	if !c.needsDemandRefresh() && c.hasNonSupplyLease() {
		// Confirm real GitHub demand before provisioning replacement capacity
		// alongside an unacknowledged completed or expired local lease.
		refreshed, err := c.readPlacementDemand(ctx)
		if err != nil {
			return err
		}
		if ctx.Err() == context.DeadlineExceeded && !c.demandRetryAt.IsZero() {
			return nil
		}
		count = min(refreshed, maximumAssignments)
		if count <= c.supplyCount() {
			c.device.forget(c.state.Owner)
			return nil
		}
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
	} else if c.fallbackFull() || c.hostedBackoffActive() {
		if countsAgree && c.fallbackFull() {
			c.refreshDemand = false
		}
		if c.state.Config.DeviceID != "" {
			c.device.wait(c.state.Owner)
		}
		return nil
	}
	if !local {
		if err := c.fenceExpiredLocalForOverflow(ctx); err != nil {
			return err
		}
		if count <= c.supplyCount() || len(c.state.Leases) >= maximumAssignments*2 {
			return nil
		}
	}
	a := &assignment{coordinator: c}
	if err := a.replace(l); err != nil {
		return err
	}
	if local {
		c.logger.Info("Local offer created", "runner", l.Name, "device", c.state.Config.DeviceID, "slot", slot, "accept_timeout", offerLifetime)
		return nil
	}
	if err := a.provisionHosted(ctx); err != nil {
		return err
	}
	// Give device requests a turn before the next provisioning operation.
	c.device.redrive(c.state.Owner)
	return nil
}

func (c *coordinator) fenceExpiredLocalForOverflow(ctx context.Context) error {
	for _, name := range c.names() {
		l := c.state.Leases[name]
		if l == nil || l.CleanupIntent || l.Local == nil || l.Local.Phase != localIssued || l.Local.JobStarted || !l.Local.expired() || c.fencedLocal[name] {
			continue
		}
		busy, err := c.bootstrap.runnerBusy(ctx, c.state.Config.Repository, l.RunnerID)
		if err != nil {
			return err
		}
		if busy {
			next := *l.Local
			next.JobStarted = true
			if err := c.assigned(name).saveLocal(&next); err != nil {
				return err
			}
			continue
		}
		if err := c.runners.RemoveRunner(ctx, int64(l.RunnerID)); err != nil && !errors.Is(err, scaleset.RunnerNotFoundError) {
			return &sdkError{"fence expired local runner", err}
		}
		if c.fencedLocal == nil {
			c.fencedLocal = make(map[string]bool)
		}
		c.fencedLocal[name] = true
		c.logger.Warn("Expired unstarted local runner fenced before hosted overflow", "runner", name, "device", l.Local.DeviceID)
	}
	return nil
}

// A failed read cannot authorize a new runner. Keep the queue available for
// issued devices and let its timer retry even without another listener callback.
func (c *coordinator) readPlacementDemand(ctx context.Context) (int, error) {
	if time.Now().Before(c.demandRetryAt) {
		return 0, nil
	}
	set, err := c.runners.GetRunnerScaleSetByID(ctx, c.state.ScaleSetID)
	if err != nil {
		if ctx.Err() == context.Canceled {
			return 0, ctx.Err()
		}
		c.demandRetryAt = time.Now().Add(cleanupRetryDelay)
		c.device.forget(c.state.Owner)
		c.logger.Warn("Demand refresh failed; retrying before provisioning", "error", &sdkError{"refresh demand", err}, "retry_delay", cleanupRetryDelay)
		return 0, nil
	}
	if set == nil || set.ID != c.state.ScaleSetID || set.Statistics == nil || set.Statistics.TotalAssignedJobs < 0 {
		return 0, errors.New("invalid scale set statistics after cleanup")
	}
	c.demandRetryAt = time.Time{}
	return set.Statistics.TotalAssignedJobs, nil
}

func (c *coordinator) nextHostedCleanup() *assignment {
	var first *assignment
	for _, name := range c.names() {
		l := c.state.Leases[name]
		if l.Local != nil || !l.CleanupIntent || time.Now().Before(c.hostedCleanupRetry[name]) {
			continue
		}
		if first == nil || c.hostedCleanupRetry[name].Before(c.hostedCleanupRetry[first.lease.Name]) {
			first = c.assigned(name)
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
		return nil, fmt.Errorf("registration interrupted for %s; cleanup required: %w", l.Name, &sdkError{"register runner", err})
	}
	if generated == nil || generated.Runner == nil || generated.Runner.ID <= 0 || generated.Runner.Name != l.Name || generated.Runner.RunnerScaleSetID != a.state.ScaleSetID || generated.EncodedJITConfig == "" {
		return nil, errors.New("invalid JIT response; assignment retained for cleanup")
	}
	return generated, nil
}

func (a *assignment) recoveryTarget() string {
	return a.state.Config.Repository + "/" + a.state.Config.platform() + "/" + a.lease.Name
}

// Called only for a newly journaled hosted assignment or an unissued local offer
// just converted to hosted. Reconciliation cleans up interrupted attempts.
func (a *assignment) provisionHosted(ctx context.Context) error {
	if a.state.Config.LocalOnly {
		return errors.New("local-only queues cannot dispatch fallback runners")
	}
	l := a.lease
	generated, err := a.generateRegistration(ctx)
	if err != nil {
		return err
	}
	if err := a.bootstrap.putSecret(ctx, l.secretName(), generated.EncodedJITConfig); err != nil {
		return fmt.Errorf("store bootstrap credential: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	next := *l
	next.RunnerID, next.DispatchIntent = generated.Runner.ID, true
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
		if err := a.beginCleanup(""); err != nil {
			return false, err
		}
		return a.finishCleanup(ctx, recoverOnly)
	}
	var run *workflowRun
	var err error
	if l.RunID == 0 {
		run, err = a.bootstrap.findRun(ctx, l)
		if err != nil {
			return false, statusReadError(err)
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
			return false, statusReadError(err)
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
		// An issued sibling keeps this queue serving after a cleanup failure.
		if l.Local == nil && a.hasIssuedLocal() && !isJournalWrite(err) {
			if a.hostedCleanupRetry == nil {
				a.hostedCleanupRetry = make(map[string]time.Time)
			}
			a.hostedCleanupRetry[l.Name] = time.Now().Add(cleanupRetryDelay)
		}
		return false, err
	}
	delete(a.hostedCleanupRetry, l.Name)
	if l.Local != nil {
		a.logger.Info("Local runner cleaned up", "runner", l.Name, "device", l.Local.DeviceID)
	} else {
		a.logger.Info("Bootstrap cleaned up", "runner", l.Name, "run", l.RunID, "conclusion", l.Conclusion)
	}
	if l.RunID != 0 && !recoverOnly {
		if l.Conclusion == "success" {
			a.hostedBackoffDelay = 0
			a.hostedBackoffUntil = time.Time{}
		} else {
			a.hostedBackoffDelay = min(max(cleanupRetryDelay, a.hostedBackoffDelay*2), verificationMaximumRetryDelay)
			a.hostedBackoffUntil = time.Now().Add(a.hostedBackoffDelay)
			a.logger.Warn("Bootstrap concluded unsuccessfully; backing off hosted provisioning", "runner", l.Name, "run", l.RunID, "conclusion", l.Conclusion, "retry_delay", a.hostedBackoffDelay)
		}
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
	if l.Local == nil || runner != nil || l.Local.Phase == localIssued {
		a.refreshDemand = true
	}
	return nil
}
