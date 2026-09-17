package main

import (
	"context"
	"errors"
	"net/http"
	"time"
)

const offerLifetime = 30 * time.Second

type localPhase string

const (
	localOffered  localPhase = "offered"
	localAccepted localPhase = "accepted"
	localIssued   localPhase = "issued"
)

type localLease struct {
	DeviceID string     `json:"device_id"`
	Phase    localPhase `json:"phase"`
	Expires  time.Time  `json:"expires"`
}

func (l *lease) validateLocal(device string) error {
	if l.Local == nil {
		return nil
	}
	a := l.Local
	if device == "" || a.DeviceID != device || a.Expires.IsZero() || l.DispatchIntent || l.RunID != 0 {
		return errors.New("invalid local lease identity")
	}
	switch a.Phase {
	case localOffered:
		if l.RunnerID != 0 || l.JIT != "" {
			return errors.New("unaccepted offer has credentials")
		}
	case localAccepted:
	case localIssued:
		if l.RunnerID == 0 || l.JIT != "" {
			return errors.New("invalid issued local lease")
		}
	default:
		return errors.New("invalid local lease phase")
	}
	return nil
}

func (l *localLease) expired() bool {
	remaining := time.Until(l.Expires)
	// Clock rollback may invalidate an offer, but never an issued assignment.
	return remaining <= 0 || remaining > offerLifetime
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

func (c *coordinator) pollDevice(request deviceRequest) (*deviceOffer, error) {
	if request.DeviceID != c.state.Config.DeviceID || request.DeviceID == "" {
		return nil, &deviceError{http.StatusForbidden, "device identity does not match"}
	}
	c.availableUntil = time.Now().Add(offerLifetime)
	l := c.state.Lease
	if l == nil || l.Local == nil || l.CleanupIntent || l.Local.Phase != localOffered || l.Local.expired() {
		return nil, nil
	}
	return &deviceOffer{Owner: c.state.Owner, Runner: l.Name, Repository: c.state.Config.Repository, Platform: "linux", Architecture: "arm64"}, nil
}

func (c *coordinator) checkDevice(request deviceRequest) error {
	if request.DeviceID == "" || request.DeviceID != c.state.Config.DeviceID || request.Owner != c.state.Owner || !runnerNamePattern.MatchString(request.Runner) {
		return &deviceError{http.StatusConflict, "device or coordinator identity does not match"}
	}
	return nil
}

func (c *coordinator) acceptDevice(ctx context.Context, request deviceRequest) (*deviceCredential, error) {
	if err := c.checkDevice(request); err != nil {
		return nil, err
	}
	l := c.state.Lease
	if l == nil || l.Name != request.Runner || l.Local == nil || l.CleanupIntent || l.Local.Phase != localOffered || l.Local.expired() {
		return nil, &deviceError{http.StatusGone, "offer is no longer available; clean up without starting a runner"}
	}
	l.Local.Phase = localAccepted
	if err := c.save(c.state); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := c.register(ctx); err != nil {
		return nil, err
	}
	credential := &deviceCredential{JIT: l.JIT}
	l.JIT = ""
	l.Local.Phase = localIssued
	// Persist possible delivery before returning credentials. Never issue them a second time.
	if err := c.save(c.state); err != nil {
		return nil, err
	}
	c.logger.Info("Local credentials issued", "runner", l.Name, "device", l.Local.DeviceID)
	return credential, nil
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
		if recoverOnly {
			return false, errors.New("local credentials may be in use; reconnect the assigned Mac to destroy its guest and acknowledge cleanup")
		}
		return false, nil
	}
	if recoverOnly {
		if err := c.beginCleanup(""); err != nil {
			return false, err
		}
		return c.finishCleanup(ctx, true)
	}
	if l.Local.Phase == localAccepted || !l.Local.expired() {
		return false, nil
	}
	// An expired, unaccepted offer never carried credentials. Convert it to hosted provisioning.
	l.Local = nil
	if err := c.save(c.state); err != nil {
		return false, err
	}
	if err := c.register(ctx); err != nil {
		return false, err
	}
	return false, c.prepare(ctx)
}
