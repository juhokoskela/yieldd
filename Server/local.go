package main

import (
	"context"
	"errors"
	"net/http"
	"time"
)

const (
	offerLifetime        = 5 * time.Second
	availabilityLifetime = 30 * time.Second
	registrationLifetime = 30 * time.Second
	localStartupLifetime = 10 * time.Minute
	busyCheckInterval    = 2 * time.Minute
)

type localPhase string

const (
	localOffered  localPhase = "offered"
	localDeclined localPhase = "declined"
	localAccepted localPhase = "accepted"
	localIssued   localPhase = "issued"
)

type localLease struct {
	Slot          int        `json:"slot"`
	DeviceID      string     `json:"device_id"`
	Phase         localPhase `json:"phase"`
	Expires       time.Time  `json:"expires"`
	JobStarted    bool       `json:"job_started,omitempty"`
	JobCompleted  bool       `json:"job_completed,omitempty"`
	JobSucceeded  bool       `json:"job_succeeded,omitempty"`
	Fenced        bool       `json:"fenced,omitempty"`
	WorkflowRunID int64      `json:"workflow_run_id,omitempty"`
}

func (l *localLease) expired() bool {
	remaining := time.Until(l.Expires)
	lifetime := offerLifetime
	switch l.Phase {
	case localDeclined:
		return true
	case localAccepted:
		lifetime = registrationLifetime
	case localIssued:
		lifetime = localStartupLifetime
	}
	// Issued expiry ends startup authorization, not the obligation to confirm guest destruction.
	return remaining <= 0 || remaining > lifetime
}

type deviceRequest struct {
	Slot     int    `json:"slot"`
	DeviceID string `json:"device_id"`
	Owner    string `json:"owner,omitempty"`
	Runner   string `json:"runner,omitempty"`
}

type deviceOffer struct {
	Slot         int    `json:"slot"`
	Owner        string `json:"owner"`
	Runner       string `json:"runner"`
	Repository   string `json:"repository"`
	Platform     string `json:"platform"`
	Architecture string `json:"architecture"`
}

type deviceCredential struct {
	JIT string `json:"jit"`
}

type deviceError struct {
	status  int
	message string
}

func (e *deviceError) Error() string { return e.message }

func (c *coordinator) checkDevice(request deviceRequest) error {
	if request.DeviceID == "" || request.DeviceID != c.state.Config.DeviceID || request.Owner != c.state.Owner || !runnerNamePattern.MatchString(request.Runner) {
		return &deviceError{status: http.StatusConflict, message: "device or coordinator identity does not match"}
	}
	return nil
}

func (c *coordinator) acceptDevice(ctx context.Context, request deviceRequest) (*deviceCredential, error) {
	if err := c.checkDevice(request); err != nil {
		return nil, err
	}
	return c.assigned(request.Runner).accept(ctx, request)
}

func (c *coordinator) declineDevice(request deviceRequest) error {
	if err := c.checkDevice(request); err != nil {
		return err
	}
	a := c.assigned(request.Runner)
	l := a.lease
	if l == nil || l.Local == nil {
		return nil
	}
	if l.Local.Slot != request.Slot || (l.Local.Phase != localOffered && l.Local.Phase != localDeclined) {
		return &deviceError{status: http.StatusConflict, message: "only an unaccepted offer for this worker can be declined"}
	}
	if l.Local.Phase != localDeclined {
		next := *l.Local
		next.Phase = localDeclined
		if err := a.saveLocal(&next); err != nil {
			return err
		}
		c.logger.Info("Local offer declined; reconciling without the acceptance delay", "runner", l.Name, "slot", request.Slot)
	}
	c.device.redrive(c.state.Owner)
	return nil
}

func (a *assignment) accept(ctx context.Context, request deviceRequest) (*deviceCredential, error) {
	l := a.lease
	if a.paused != nil || a.demandUnavailable || l == nil || l.Local == nil || l.Local.Slot != request.Slot || l.CleanupIntent || l.Local.Phase != localOffered || l.Local.expired() {
		return nil, &deviceError{status: http.StatusGone, message: "offer is no longer available; clean up without starting a runner"}
	}
	if a.needsDemandRefresh() {
		count, err := a.readPlacementDemand(ctx)
		if err != nil {
			return nil, err
		}
		if l.Local.expired() || !a.demandRetryAt.IsZero() || a.surplusAssignments(count)[l.Name] {
			return nil, &deviceError{status: http.StatusGone, message: "offer no longer has confirmed demand"}
		}
	}
	next := *l.Local
	next.Phase = localAccepted
	next.Expires = time.Now().UTC().Add(registrationLifetime)
	acceptLatency := time.Since(l.Created)
	if err := a.saveLocal(&next); err != nil {
		return nil, err
	}
	a.logger.Info("Local offer accepted", "runner", l.Name, "device", next.DeviceID, "accept_latency", acceptLatency)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	generated, err := a.generateRegistration(ctx)
	if err != nil {
		return nil, err
	}
	issued := *a.lease.Local
	issued.Phase = localIssued
	issued.Expires = time.Now().UTC().Add(localStartupLifetime)
	// Persist possible delivery before returning credentials. Never issue them a second time.
	issuedLease := *a.lease
	issuedLease.Local, issuedLease.RunnerID = &issued, generated.Runner.ID
	if err := a.replace(&issuedLease); err != nil {
		return nil, err
	}
	a.logger.Info("Local credentials issued", "runner", l.Name, "device", l.Local.DeviceID)
	a.device.redrive(a.state.Owner)
	return &deviceCredential{JIT: generated.EncodedJITConfig}, nil
}

type deviceAuthorization struct {
	Continue      bool  `json:"continue"`
	JobSucceeded  bool  `json:"job_succeeded,omitempty"`
	WorkflowRunID int64 `json:"workflow_run_id,omitempty"`
}

type finalJobResult string

const (
	resultPending     finalJobResult = "pending"
	resultSucceeded   finalJobResult = "succeeded"
	resultUnavailable finalJobResult = "unavailable"
)

type deviceJobResult struct {
	Result finalJobResult `json:"result"`
}

func (l *lease) jobResult(slot int) finalJobResult {
	if l == nil || l.CleanupIntent || l.Local == nil || l.Local.Slot != slot || l.Local.Phase != localIssued {
		return resultUnavailable
	}
	if !l.Local.JobCompleted {
		return resultPending
	}
	if l.Local.JobSucceeded {
		return resultSucceeded
	}
	return resultUnavailable
}

func (c *coordinator) deviceJobResult(request deviceRequest) (deviceJobResult, error) {
	if err := c.checkDevice(request); err != nil {
		return deviceJobResult{}, err
	}
	return deviceJobResult{Result: c.state.Leases[request.Runner].jobResult(request.Slot)}, nil
}

func (c *coordinator) renewDevice(ctx context.Context, request deviceRequest) (*deviceAuthorization, error) {
	if err := c.checkDevice(request); err != nil {
		return nil, err
	}
	return c.assigned(request.Runner).renew(ctx, request)
}
func (a *assignment) renew(ctx context.Context, request deviceRequest) (*deviceAuthorization, error) {
	l := a.lease
	var runID int64
	if l != nil && l.Local != nil {
		runID = l.Local.WorkflowRunID
	}
	if result := l.jobResult(request.Slot); result != resultPending {
		return &deviceAuthorization{JobSucceeded: result == resultSucceeded, WorkflowRunID: runID}, nil
	}
	if l.Local.Fenced {
		return &deviceAuthorization{Continue: false, WorkflowRunID: runID}, nil
	}
	if l.Local.JobStarted && !a.demandUnavailable && a.jobStartedByEvent[l.Name] && time.Since(a.lastBusyCheck[l.Name]) < busyCheckInterval {
		return &deviceAuthorization{Continue: true, WorkflowRunID: runID}, nil
	}
	busy, err := a.bootstrap.runnerBusy(ctx, a.state.Config.Repository, l.RunnerID)
	if err != nil {
		return nil, err
	}
	if busy {
		if a.lastBusyCheck == nil {
			a.lastBusyCheck = make(map[string]time.Time)
		}
		a.lastBusyCheck[l.Name] = time.Now()
		if !l.Local.JobStarted {
			next := *l.Local
			next.JobStarted = true
			if err := a.saveLocal(&next); err != nil {
				return nil, err
			}
		}
		return &deviceAuthorization{Continue: true, WorkflowRunID: runID}, nil
	}
	delete(a.lastBusyCheck, l.Name)
	delete(a.jobStartedByEvent, l.Name)
	if l.Local.JobStarted {
		// An idle response can lag a start event. Do not grant more execution
		// time, but let the Mac's offline grace absorb temporary inconsistency.
		return nil, &deviceError{status: http.StatusServiceUnavailable, message: "GitHub has not confirmed an active runner; execution authorization was not renewed"}
	}
	return &deviceAuthorization{Continue: !l.Local.expired(), WorkflowRunID: runID}, nil
}

type localJobEvent uint8

const (
	jobStarted localJobEvent = iota
	jobUnsuccessful
	jobSucceeded
)

func (a *assignment) recordLocalJob(id int, workflowRunID int64, event localJobEvent) error {
	l := a.lease
	if l == nil || l.Local == nil || l.Local.Phase != localIssued || l.RunnerID != id {
		return nil
	}
	if l.Local.Fenced {
		// A fenced runner is permanently revoked; a delayed start event must never reauthorize it.
		if event == jobStarted {
			return nil
		}
	}
	next := *l.Local
	next.JobStarted = true
	if workflowRunID > 0 && next.WorkflowRunID == 0 {
		next.WorkflowRunID = workflowRunID
	}
	if event != jobStarted && !next.JobCompleted {
		next.JobCompleted = true
		next.JobSucceeded = event == jobSucceeded
	}
	if event == jobStarted && !l.CleanupIntent && !l.Local.Fenced {
		if a.jobStartedByEvent == nil {
			a.jobStartedByEvent = make(map[string]bool)
		}
		if a.lastBusyCheck == nil {
			a.lastBusyCheck = make(map[string]time.Time)
		}
		a.jobStartedByEvent[l.Name] = true
		a.lastBusyCheck[l.Name] = time.Now()
	}
	if next == *l.Local {
		return nil
	}
	return a.saveLocal(&next)
}

func (c *coordinator) completeDevice(ctx context.Context, request deviceRequest) error {
	if err := c.checkDevice(request); err != nil {
		return err
	}
	return c.assigned(request.Runner).complete(ctx, request)
}
func (a *assignment) complete(ctx context.Context, request deviceRequest) error {
	l := a.lease
	if l == nil || l.Local == nil {
		// Completion is idempotent, including a lost response after clearing the lease.
		return nil
	}
	if l.Local.Slot != request.Slot {
		return &deviceError{status: http.StatusConflict, message: "assignment belongs to another worker slot"}
	}
	if err := a.beginCleanup(""); err != nil {
		return err
	}
	_, err := a.finishCleanup(ctx, true)
	if errors.Is(err, runnerStillBusy) {
		if a.lease != nil && a.lease.Local != nil && a.lease.Local.Phase == localIssued && !a.lease.Local.JobStarted && !a.lease.Local.Fenced {
			// GitHub confirmed the runner is busy; record JobStarted so countsAsSupply
			// and surplusAssignments account for it until JobCompleted / idle.
			next := *a.lease.Local
			next.JobStarted = true
			if saveErr := a.saveLocal(&next); saveErr != nil {
				return saveErr
			}
		}
		a.logger.Info("Local cleanup recorded; waiting asynchronously for GitHub runner to become idle before removal", "runner", l.Name)
		a.device.redrive(a.state.Owner)
		return nil
	}
	return err
}

func (a *assignment) reconcileLocal(ctx context.Context, recoverOnly bool) (bool, error) {
	l := a.lease
	if l.Local.Phase == localIssued {
		a.reportLocalHold("Local assignment retains its slot until the Mac confirms guest destruction")
		if recoverOnly {
			return false, errors.New("local credentials may be in use; reconnect the assigned Mac to destroy its guest and acknowledge cleanup")
		}
		return false, nil
	}
	expired := l.Local.expired()
	if l.Local.Phase == localOffered && expired && !recoverOnly {
		a.device.expireAllAvailability()
	}
	retire := recoverOnly || (expired && (l.Local.Phase == localAccepted || a.state.Config.LocalOnly || a.fallbackFull() || a.hostedBackoffActive()))
	if retire {
		if err := a.beginCleanup(""); err != nil {
			return false, err
		}
		if a.state.Config.LocalOnly && l.Local.Phase == localOffered && expired {
			a.logger.Info("Local offer expired; waiting for local capacity", "runner", l.Name)
		}
		return a.finishCleanup(ctx, true)
	}
	if l.Local.Phase == localAccepted {
		a.reportLocalHold("Waiting for local acceptance to finish; undelivered credentials will be cleaned up after expiry")
		return false, nil
	}
	if !expired {
		return false, nil
	}
	busyPromoted := false
	if a.hasUnfencedExpiredLocal() {
		var ready bool
		var err error
		ready, busyPromoted, err = a.fenceExpiredLocalForOverflow(ctx)
		if err != nil {
			return false, err
		}
		if !ready {
			return false, nil
		}
	}
	if busyPromoted || a.hasNonSupplyLease() {
		count, err := a.readPlacementDemand(ctx)
		if err != nil {
			return false, err
		}
		if !a.demandRetryAt.IsZero() {
			return false, nil
		}
		// Supply count includes this expired offer, so subtract 1 to check whether
		// remaining active runners already cover current demand.
		if count <= a.supplyCount()-1 {
			if err := a.beginCleanup(""); err != nil {
				return false, err
			}
			return a.finishCleanup(ctx, true)
		}
	}
	// An expired, unaccepted offer never carried credentials. Convert it to hosted provisioning.
	if err := a.saveLocal(nil); err != nil {
		return false, err
	}
	a.logger.Info("Local offer expired; using hosted fallback", "runner", l.Name, "device", a.state.Config.DeviceID, "offer_age", time.Since(l.Created))
	return false, a.provisionHosted(ctx)
}

func (a *assignment) saveLocal(local *localLease) error {
	nextLease := *a.lease
	nextLease.Local = local
	return a.replace(&nextLease)
}

func (a *assignment) reportLocalHold(message string) {
	l := a.lease
	if a.reportedLocalHold[l.Name] == l.Local.Phase {
		return
	}
	if a.reportedLocalHold == nil {
		a.reportedLocalHold = make(map[string]localPhase)
	}
	a.reportedLocalHold[l.Name] = l.Local.Phase
	a.logger.Warn(message, "runner", l.Name, "phase", l.Local.Phase)
}
