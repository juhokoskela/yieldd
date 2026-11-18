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
)

type localPhase string

const (
	localOffered  localPhase = "offered"
	localDeclined localPhase = "declined"
	localAccepted localPhase = "accepted"
	localIssued   localPhase = "issued"
)

type localLease struct {
	Slot         int        `json:"slot"`
	DeviceID     string     `json:"device_id"`
	Phase        localPhase `json:"phase"`
	Expires      time.Time  `json:"expires"`
	JobStarted   bool       `json:"job_started,omitempty"`
	JobCompleted bool       `json:"job_completed,omitempty"`
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
	Continue bool `json:"continue"`
}

func (c *coordinator) renewDevice(ctx context.Context, request deviceRequest) (*deviceAuthorization, error) {
	if err := c.checkDevice(request); err != nil {
		return nil, err
	}
	return c.assigned(request.Runner).renew(ctx, request)
}
func (a *assignment) renew(ctx context.Context, request deviceRequest) (*deviceAuthorization, error) {
	l := a.lease
	if l == nil || l.Local == nil || l.Local.Slot != request.Slot || l.Local.Phase != localIssued {
		return &deviceAuthorization{}, nil
	}
	if l.CleanupIntent || l.Local.JobCompleted {
		return &deviceAuthorization{}, nil
	}
	busy, err := a.bootstrap.runnerBusy(ctx, a.state.Config.Repository, l.RunnerID)
	if err != nil {
		return nil, err
	}
	if busy {
		if !l.Local.JobStarted {
			next := *l.Local
			next.JobStarted = true
			if err := a.saveLocal(&next); err != nil {
				return nil, err
			}
		}
		return &deviceAuthorization{Continue: true}, nil
	}
	if l.Local.JobStarted {
		// An idle response can lag a start event. Do not grant more execution
		// time, but let the Mac's offline grace absorb temporary inconsistency.
		return nil, &deviceError{status: http.StatusServiceUnavailable, message: "GitHub has not confirmed an active runner; execution authorization was not renewed"}
	}
	return &deviceAuthorization{Continue: !l.Local.expired()}, nil
}

func (a *assignment) recordLocalJob(id int, completed bool) error {
	l := a.lease
	if l == nil || l.Local == nil || l.CleanupIntent || l.Local.Phase != localIssued || l.RunnerID != id {
		return nil
	}
	next := *l.Local
	next.JobStarted = true
	next.JobCompleted = next.JobCompleted || completed
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
	retire := recoverOnly || (expired && (l.Local.Phase == localAccepted || a.state.Config.LocalOnly || a.fallbackFull()))
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
