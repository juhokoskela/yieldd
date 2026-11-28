package main

import (
	"context"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestExpiredUnstartedLocalLeaseFencesAndAllowsHostedOverflowOnConfirmedDemand(t *testing.T) {
	c, w, store, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	c.device.slots[0].availableUntil = time.Time{}
	singleLease(c.state).Local.Expires = time.Now().Add(-time.Minute)
	w.assignedJobs = 1

	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 2 {
		t.Fatalf("expected quarantined local lease + hosted overflow, got count=%d err=%v", n, err)
	}
	if w.dispatched != 1 {
		t.Fatalf("expected 1 hosted overflow dispatch, got %d", w.dispatched)
	}
	if c.state.Leases[request.Runner] == nil || c.device.slots[0].owner != c.state.Owner {
		t.Fatal("local slot quarantine was lost during hosted overflow")
	}
	if !c.fencedLocal[request.Runner] {
		t.Fatal("expired unstarted local runner was not fenced before hosted overflow")
	}
	// Reloading journal with quarantined + hosted leases succeeds.
	if _, err := store.load(c.state.Config); err != nil {
		t.Fatalf("journal reload failed: %v", err)
	}
	// A late renewal from the waking Mac is revoked immediately.
	auth, err := c.renewDevice(t.Context(), request)
	if err != nil || auth.Continue {
		t.Fatalf("fenced local runner renewed: %+v %v", auth, err)
	}
}

func TestFailedHostedBootstrapBacksOffHostedOnlyWithoutBlockingLocalOffers(t *testing.T) {
	c, w, _ := concurrentFixture(t, 1)
	// First dispatch hosted fallback when Mac is offline.
	c.device.slots[0].availableUntil = time.Time{}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if w.dispatched != 1 {
		t.Fatalf("expected initial hosted dispatch, got %d", w.dispatched)
	}
	w.run.Status, w.run.Conclusion = "completed", "failure"
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatalf("hosted failure errored queue: %v", err)
	}
	if c.paused != nil || !c.hostedBackoffActive() {
		t.Fatalf("expected hosted-only backoff without queue pause: paused=%v backoff=%v", c.paused, c.hostedBackoffActive())
	}
	// Mac comes back online: local offer is still accepted immediately during hosted backoff.
	c.device.pollNow(0)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatalf("local admission blocked during hosted backoff: %v", err)
	}
	offer := c.device.pollNow(0)
	if offer == nil {
		t.Fatal("expected local offer during hosted backoff")
	}
}

func TestUnansweredOfferExpiryClearsAllIdleSlotAvailability(t *testing.T) {
	c, _, _ := concurrentFixture(t, 3)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	offer := c.device.pollNow(0)
	if offer == nil {
		t.Fatal("expected offer on slot 0")
	}
	c.state.Leases[offer.Runner].Local.Expires = time.Now().Add(-time.Second)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for slot := 1; slot < 3; slot++ {
		if c.device.slots[slot].idle(now) {
			t.Fatalf("slot %d remained advertised after unanswered offer expiry", slot)
		}
	}
}

func TestPollDisconnectClearsSlotAvailability(t *testing.T) {
	c, _, _ := concurrentFixture(t, 0)
	loop := newCoordinatorLoop(t.Context(), c)
	router, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() {
		_, pollErr := router.poll(ctx, deviceRequest{DeviceID: testDevice, Slot: 0})
		done <- pollErr
	}()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) && !router.queue.slots[0].idle(time.Now()) {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	if err := <-done; err == nil {
		t.Fatal("expected canceled poll error")
	}
	if router.queue.slots[0].idle(time.Now()) {
		t.Fatal("disconnected poll retained slot availability")
	}
}

func TestRenewIncludesTrustedWorkflowRunIDAndSkipsRedundantBusyReads(t *testing.T) {
	c, w, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	busyCalls := 0
	c.bootstrap = busyCounter{w, &busyCalls}
	id := singleLease(c.state).RunnerID
	if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{
		RunnerName:    request.Runner,
		RunnerID:      id,
		WorkflowRunID: 987654321,
	}); err != nil {
		t.Fatal(err)
	}
	auth, err := c.renewDevice(t.Context(), request)
	if err != nil || !auth.Continue || auth.WorkflowRunID != 987654321 {
		t.Fatalf("unexpected renew response: %+v err=%v", auth, err)
	}
	if busyCalls != 0 {
		t.Fatalf("expected 0 runnerBusy REST calls right after JobStarted event, got %d", busyCalls)
	}
}

type busyCounter struct {
	bootstrapAPI
	calls *int
}

func (b busyCounter) runnerBusy(ctx context.Context, repo string, id int) (bool, error) {
	*b.calls++
	return b.bootstrapAPI.runnerBusy(ctx, repo, id)
}
