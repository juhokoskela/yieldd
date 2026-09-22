package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"testing"
	"time"
)

type cleanupTimeout struct{ bootstrapAPI }

func (cleanupTimeout) runnerBusy(context.Context, string, int) (bool, error) {
	return false, context.DeadlineExceeded
}

func TestLocalCompletionFailureRetriesWithoutMacRestart(t *testing.T) {
	c, w, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	c.bootstrap = cleanupTimeout{w}
	if err := c.completeDevice(t.Context(), request); err == nil {
		t.Fatal("expected timeout")
	}
	if !c.state.Lease.CleanupIntent {
		t.Fatal("lost cleanup intent")
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	c.bootstrap = w
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 {
		t.Fatal(n, err)
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || w.dispatched != 1 {
		t.Fatal(n, err)
	}
}

func TestCompletedAssignmentRefreshesCachedDemandBeforeClaimingCapacity(t *testing.T) {
	c, w, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	w.assignedJobs = 0
	c.device.pollNow()
	for range 3 {
		if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 || c.state.Lease != nil {
			t.Fatal("cached count reclaimed capacity", n, err)
		}
	}
	if w.demandCalls != 3 || c.device.owner != "" {
		t.Fatal("did not recheck cached demand", w.demandCalls, c.device.owner)
	}
	w.demandErr = context.DeadlineExceeded
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, context.DeadlineExceeded) || c.device.owner != "" {
		t.Fatal("failed refresh consumed capacity", err)
	}
	w.demandErr, w.assignedJobs = nil, 1
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || c.state.Lease.Local == nil {
		t.Fatal("fresh demand did not create an offer", n, err)
	}
}

func TestZeroDemandRevokesIdleStartupButRetainsIssuedCapacity(t *testing.T) {
	c, w, store, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 0); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || saved.Lease == nil || !saved.Lease.Local.expired() || c.device.owner != c.state.Owner {
		t.Fatal("startup retraction lost the issued reservation", saved, err)
	}
	if authorization, err := c.renewDevice(t.Context(), request); err != nil || authorization.Continue {
		t.Fatal("idle runner retained startup authorization", authorization, err)
	}
	w.busy = true
	if authorization, err := c.renewDevice(t.Context(), request); err != nil || !authorization.Continue {
		t.Fatal("a running job was interrupted by a zero count", authorization, err)
	}
	if err := c.completeDevice(t.Context(), request); !errors.Is(err, runnerStillBusy) || c.device.owner != c.state.Owner {
		t.Fatal("busy capacity was released", err)
	}
	w.busy = false
	if err := c.completeDevice(t.Context(), request); err != nil || c.device.owner != "" {
		t.Fatal("confirmed destruction did not release capacity", err)
	}
}

func TestAcceptedLocalLeaseCleansUpOnExpiryOrZeroDemand(t *testing.T) {
	for _, expired := range []bool{false, true} {
		t.Run(map[bool]string{false: "zero-demand", true: "expired"}[expired], func(t *testing.T) {
			c, w, _, request := localFixture(t)
			w.generateErr = context.DeadlineExceeded
			if _, err := c.acceptDevice(t.Context(), request); err == nil {
				t.Fatal("expected registration failure")
			}
			demand := 0
			if expired {
				c.state.Lease.Local.Expires = time.Now().Add(-time.Hour)
				demand = 1
			}
			if n, err := c.HandleDesiredRunnerCount(t.Context(), demand); err != nil || n != 0 || c.state.Lease != nil {
				t.Fatal(n, err)
			}
			if w.runner != nil {
				t.Fatal("registration retained")
			}
		})
	}
}

func TestFailedLocalSaveDoesNotCommitPhaseInMemory(t *testing.T) {
	for _, phase := range []localPhase{localAccepted, localIssued} {
		t.Run(string(phase), func(t *testing.T) {
			c, _, store, request := localFixture(t)
			failure := errors.New("disk failure")
			c.save = func(s *state) error {
				if s.Lease.Local.Phase == phase {
					return failure
				}
				return store.save(s)
			}
			if _, err := c.acceptDevice(t.Context(), request); !errors.Is(err, failure) {
				t.Fatal(err)
			}
			disk, err := store.load(c.state.Config)
			if err != nil {
				t.Fatal(err)
			}
			if c.state.Lease.Local.Phase == phase || c.state.Lease.Local.Phase != disk.Lease.Local.Phase {
				t.Fatal("phase advanced before durable save")
			}
		})
	}
}

func TestExpiredOfferFailedSaveRetainsLocalIdentity(t *testing.T) {
	c, w, _, _ := localFixture(t)
	c.state.Lease.Local.Expires = time.Now().Add(-time.Hour)
	failure := errors.New("disk failure")
	c.save = func(*state) error { return failure }
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	if c.state.Lease.Local == nil || len(w.events) != 0 {
		t.Fatal("failed publication advanced provisioning")
	}
}

func TestIssuedLocalHoldIsReportedOnceAndNeverExpires(t *testing.T) {
	c, _, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	c.logger = slog.New(slog.NewTextHandler(&logs, nil))
	c.state.Lease.Local.Expires = time.Now().Add(-time.Hour)
	for _, demand := range []int{0, 1, 0} {
		if n, err := c.HandleDesiredRunnerCount(t.Context(), demand); err != nil || n != 1 {
			t.Fatal(n, err)
		}
	}
	if bytes.Count(logs.Bytes(), []byte("blocks local and hosted provisioning")) != 1 {
		t.Fatal(logs.String())
	}
	if _, err := c.reconcile(t.Context(), true); err == nil {
		t.Fatal("issued lease bypassed")
	}
}

func TestTransientCleanupClassificationPreservesOtherFailures(t *testing.T) {
	disk := errors.New("disk failure")
	for _, test := range []struct {
		err   error
		retry bool
	}{
		{context.DeadlineExceeded, true}, {&apiError{503}, true}, {&apiError{403}, false},
		{context.Canceled, false}, {errors.Join(context.DeadlineExceeded, disk), false},
		{fmt.Errorf("outer: %w", errors.Join(context.DeadlineExceeded, disk)), false}, {runnerStillBusy, true},
	} {
		if transientFailure(test.err) != test.retry {
			t.Fatal(test.err)
		}
	}
}
