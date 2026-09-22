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
	localAccepted localPhase = "accepted"
	localIssued   localPhase = "issued"
)

type localLease struct {
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
	case localAccepted:
		lifetime = registrationLifetime
	case localIssued:
		lifetime = localStartupLifetime
	}
	// Issued expiry ends startup authorization, not the obligation to confirm guest destruction.
	return remaining <= 0 || remaining > lifetime
}

type deviceRequest struct {
	DeviceID string `json:"device_id"`
	Owner    string `json:"owner,omitempty"`
	Runner   string `json:"runner,omitempty"`
}

type deviceOffer struct {
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
	l := c.state.Lease
	if l == nil || l.Name != request.Runner || l.Local == nil || l.CleanupIntent || l.Local.Phase != localOffered || l.Local.expired() {
		return nil, &deviceError{status: http.StatusGone, message: "offer is no longer available; clean up without starting a runner"}
	}
	next := *l.Local
	next.Phase = localAccepted
	next.Expires = time.Now().UTC().Add(registrationLifetime)
	acceptLatency := time.Since(l.Created)
	if err := c.saveLocal(&next, l.JIT); err != nil {
		return nil, err
	}
	c.logger.Info("Local offer accepted", "runner", l.Name, "device", next.DeviceID, "accept_latency", acceptLatency)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := c.register(ctx); err != nil {
		return nil, err
	}
	credential := &deviceCredential{JIT: l.JIT}
	issued := *l.Local
	issued.Phase = localIssued
	issued.Expires = time.Now().UTC().Add(localStartupLifetime)
	// Persist possible delivery before returning credentials. Never issue them a second time.
	if err := c.saveLocal(&issued, ""); err != nil {
		return nil, err
	}
	c.logger.Info("Local credentials issued", "runner", l.Name, "device", l.Local.DeviceID)
	return credential, nil
}

type deviceAuthorization struct {
	Continue bool `json:"continue"`
}

func (c *coordinator) renewDevice(ctx context.Context, request deviceRequest) (*deviceAuthorization, error) {
	if err := c.checkDevice(request); err != nil {
		return nil, err
	}
	l := c.state.Lease
	if l == nil || l.Name != request.Runner || l.Local == nil || l.Local.Phase != localIssued {
		return &deviceAuthorization{}, nil
	}
	if l.CleanupIntent || l.Local.JobCompleted {
		return &deviceAuthorization{}, nil
	}
	busy, err := c.bootstrap.runnerBusy(ctx, c.state.Config.Repository, l.RunnerID)
	if err != nil {
		return nil, err
	}
	if busy {
		if !l.Local.JobStarted {
			next := *l.Local
			next.JobStarted = true
			if err := c.saveLocal(&next, ""); err != nil {
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

func (c *coordinator) recordLocalJob(runner string, id int, completed bool) error {
	l := c.state.Lease
	if l == nil || l.Local == nil || l.CleanupIntent || l.Local.Phase != localIssued || l.Name != runner || l.RunnerID != id {
		return nil
	}
	next := *l.Local
	next.JobStarted = true
	next.JobCompleted = next.JobCompleted || completed
	if next == *l.Local {
		return nil
	}
	return c.saveLocal(&next, "")
}

func (c *coordinator) completeDevice(ctx context.Context, request deviceRequest) error {
	if err := c.checkDevice(request); err != nil {
		return err
	}
	l := c.state.Lease
	if l == nil || l.Name != request.Runner || l.Local == nil {
		// Completion is idempotent, including a lost response after clearing the lease.
		return nil
	}
	if err := c.beginCleanup(""); err != nil {
		return err
	}
	_, err := c.finishCleanup(ctx, true)
	return err
}

func (c *coordinator) reconcileLocal(ctx context.Context, recoverOnly bool) (bool, error) {
	l := c.state.Lease
	if l.Local.Phase == localIssued {
		c.reportLocalHold("Local assignment blocks local and hosted provisioning until the Mac confirms guest destruction")
		if recoverOnly {
			return false, errors.New("local credentials may be in use; reconnect the assigned Mac to destroy its guest and acknowledge cleanup")
		}
		return false, nil
	}
	if recoverOnly || (l.Local.Phase == localAccepted && l.Local.expired()) {
		if err := c.beginCleanup(""); err != nil {
			return false, err
		}
		return c.finishCleanup(ctx, true)
	}
	if l.Local.Phase == localAccepted {
		c.reportLocalHold("Waiting for local acceptance to finish; undelivered credentials will be cleaned up after expiry")
		return false, nil
	}
	if !l.Local.expired() {
		return false, nil
	}
	if c.state.Config.LocalOnly {
		if err := c.beginCleanup(""); err != nil {
			return false, err
		}
		c.logger.Info("Local offer expired; waiting for local capacity", "runner", l.Name)
		return c.finishCleanup(ctx, true)
	}
	// An expired, unaccepted offer never carried credentials. Convert it to hosted provisioning.
	if err := c.saveLocal(nil, l.JIT); err != nil {
		return false, err
	}
	c.logger.Info("Local offer expired; using hosted fallback", "runner", l.Name, "device", c.state.Config.DeviceID, "offer_age", time.Since(l.Created))
	if err := c.register(ctx); err != nil {
		return false, err
	}
	return false, c.prepare(ctx)
}

func (c *coordinator) saveLocal(local *localLease, jit string) error {
	nextLease := *c.state.Lease
	nextLease.Local, nextLease.JIT = local, jit
	next := *c.state
	next.Lease = &nextLease
	if err := c.save(&next); err != nil {
		return err
	}
	*c.state.Lease = nextLease
	c.device.update(c.state)
	return nil
}

func (c *coordinator) reportLocalHold(message string) {
	l := c.state.Lease
	identity := l.Name + "/" + string(l.Local.Phase)
	if c.reportedLocalHold == identity {
		return
	}
	c.reportedLocalHold = identity
	c.logger.Warn(message, "runner", l.Name, "phase", l.Local.Phase)
}
