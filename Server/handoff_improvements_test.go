package main

import (
	"context"
	"errors"
	"net/http"
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
	if !c.state.Leases[request.Runner].Local.Fenced {
		t.Fatal("expired unstarted local runner was not fenced before hosted overflow")
	}
	// Reloading journal with quarantined + hosted leases succeeds and preserves fenced state.
	reloaded, err := store.load(c.state.Config)
	if err != nil {
		t.Fatalf("journal reload failed: %v", err)
	}
	if !reloaded.Leases[request.Runner].Local.Fenced {
		t.Fatal("fenced flag did not survive journal reload")
	}
	// A delayed JobStarted event must NOT reauthorize the fenced runner.
	if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{
		RunnerName:    request.Runner,
		RunnerID:      c.state.Leases[request.Runner].RunnerID,
		WorkflowRunID: 55555,
	}); err != nil {
		t.Fatalf("delayed JobStarted errored: %v", err)
	}
	// A late renewal from the waking Mac is revoked immediately.
	auth, err := c.renewDevice(t.Context(), request)
	if err != nil || auth.Continue {
		t.Fatalf("fenced local runner renewed after delayed JobStarted: %+v %v", auth, err)
	}
}

func TestIdleBusyCheckDoesNotRearmFastPath(t *testing.T) {
	c, w, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	id := singleLease(c.state).RunnerID
	if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{
		RunnerName:    request.Runner,
		RunnerID:      id,
		WorkflowRunID: 12345,
	}); err != nil {
		t.Fatal(err)
	}
	// Expire the 2-minute fast path and report runner idle from GitHub.
	c.lastBusyCheck[request.Runner] = time.Now().Add(-busyCheckInterval - time.Second)
	w.busy = false

	for attempt := 1; attempt <= 2; attempt++ {
		_, err := c.renewDevice(t.Context(), request)
		var devErr *deviceError
		if !errors.As(err, &devErr) || devErr.status != http.StatusServiceUnavailable {
			t.Fatalf("attempt %d: expected 503 for idle runner, got %v", attempt, err)
		}
	}
}

func TestOfferConversionToHostedFencesExpiredUnstartedLocal(t *testing.T) {
	for _, busy := range []bool{false, true} {
		t.Run(map[bool]string{false: "idle", true: "busy"}[busy], func(t *testing.T) {
			c, w, _ := concurrentFixture(t, 2)
			slot0 := issueLocal(t, c, 0, 1)
			// Create an offer on slot 1 (demand=2) while slot 0 is still active, then let slot 0 expire unstarted.
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
				t.Fatal(err)
			}
			offer1 := c.device.pollNow(1)
			if offer1 == nil {
				t.Fatal("expected offer on slot 1")
			}
			c.state.Leases[slot0.Runner].Local.Expires = time.Now().Add(-time.Minute)
			c.state.Leases[offer1.Runner].Local.Expires = time.Now().Add(-time.Second)
			w.busy = busy
			w.assignedJobs = 1

			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
			if busy {
				if w.dispatched != 0 {
					t.Fatalf("busy local runner still triggered hosted dispatch: %d", w.dispatched)
				}
				if !c.state.Leases[slot0.Runner].Local.JobStarted {
					t.Fatal("busy local runner was not marked started during fence")
				}
			} else {
				if !c.state.Leases[slot0.Runner].Local.Fenced {
					t.Fatal("expired unstarted local runner was not fenced before offer-to-hosted conversion")
				}
				if w.dispatched != 1 {
					t.Fatalf("expected 1 hosted dispatch after fencing idle runner, got %d", w.dispatched)
				}
			}
		})
	}
}

func TestTransientFenceErrorRetriesWithoutPausingQueue(t *testing.T) {
	c, w, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	c.device.slots[0].availableUntil = time.Time{}
	singleLease(c.state).Local.Expires = time.Now().Add(-time.Minute)
	w.assignedJobs = 1

	c.bootstrap = failingBusyAPI{w, &apiError{status: 502}}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatalf("transient fence failure errored queue: %v", err)
	}
	if c.paused != nil || c.demandRetryAt.IsZero() || w.dispatched != 0 {
		t.Fatalf("expected retryable backoff without queue pause: paused=%v retryAt=%v dispatched=%d", c.paused, c.demandRetryAt, w.dispatched)
	}

	// Recover API and advance past retry window using an elapsed timestamp (matching production timer expiry).
	c.bootstrap = w
	c.demandRetryAt = time.Now().Add(-time.Second)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if c.paused != nil || w.dispatched != 1 || !c.state.Leases[request.Runner].Local.Fenced || !c.demandRetryAt.IsZero() {
		t.Fatalf("expected fence + dispatch after transient recovery: paused=%v dispatched=%d fenced=%v retryAt=%v",
			c.paused, w.dispatched, c.state.Leases[request.Runner].Local.Fenced, c.demandRetryAt)
	}
}

func TestExpiredOfferConversionDoesNotDispatchHostedWithZeroLiveDemand(t *testing.T) {
	c, w, _ := concurrentFixture(t, 2)
	slot0 := issueLocal(t, c, 0, 1)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
		t.Fatal(err)
	}
	offer1 := c.device.pollNow(1)
	if offer1 == nil {
		t.Fatal("expected offer on slot 1")
	}
	c.state.Leases[slot0.Runner].Local.Expires = time.Now().Add(-time.Minute)
	c.state.Leases[offer1.Runner].Local.Expires = time.Now().Add(-time.Second)
	w.busy = false
	w.assignedJobs = 0

	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if !c.state.Leases[slot0.Runner].Local.Fenced {
		t.Fatal("expected expired idle sibling fenced")
	}
	if w.dispatched != 0 {
		t.Fatalf("expected 0 hosted dispatches when live scale-set demand is 0, got %d", w.dispatched)
	}
	if c.state.Leases[offer1.Runner] != nil {
		t.Fatal("expected expired offer retired when live demand is 0")
	}
}

func TestBusyCleanupEventOrderingsDoNotSpawnHosted(t *testing.T) {
	t.Run("complete_before_job_started", func(t *testing.T) {
		c, w, _, request := localFixture(t)
		if _, err := c.acceptDevice(t.Context(), request); err != nil {
			t.Fatal(err)
		}
		w.busy = true
		w.assignedJobs = 1
		if err := c.completeDevice(t.Context(), request); err != nil {
			t.Fatal(err)
		}
		if !c.state.Leases[request.Runner].Local.JobStarted {
			t.Fatal("expected busy completion to persist JobStarted")
		}
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		if w.dispatched != 0 {
			t.Fatalf("complete before JobStarted spawned hosted runner: %d", w.dispatched)
		}
	})

	t.Run("job_started_then_busy_complete_retires_outstanding_offer", func(t *testing.T) {
		c, w, _ := concurrentFixture(t, 2)
		slot0 := issueLocal(t, c, 0, 1)
		if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{
			RunnerName: slot0.Runner,
			RunnerID:   c.state.Leases[slot0.Runner].RunnerID,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		offer1 := c.device.pollNow(1)
		if offer1 == nil {
			t.Fatal("expected offer on slot 1")
		}
		w.busy = true
		w.assignedJobs = 1
		if err := c.completeDevice(t.Context(), slot0); err != nil {
			t.Fatal(err)
		}
		// Expire the outstanding offer while only 1 job (the still-busy slot0) exists.
		c.state.Leases[offer1.Runner].Local.Expires = time.Now().Add(-time.Second)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		if w.dispatched != 0 {
			t.Fatalf("outstanding offer converted to hosted despite busy cleanup supply: %d", w.dispatched)
		}
		if c.state.Leases[offer1.Runner] != nil {
			t.Fatal("expected surplus offer retired")
		}
	})
}

func TestRemoveRunnerUntypedErrorRetriesWithoutPausingQueue(t *testing.T) {
	c, w, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	c.device.slots[0].availableUntil = time.Time{}
	singleLease(c.state).Local.Expires = time.Now().Add(-time.Minute)
	w.assignedJobs = 1

	origRunners := c.runners
	c.runners = failingRemoveRunnerAPI{origRunners, errors.New("unexpected status code: 500")}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatalf("untyped RemoveRunner 5xx errored queue: %v", err)
	}
	if c.paused != nil || c.demandRetryAt.IsZero() || w.dispatched != 0 {
		t.Fatalf("expected retryable backoff without queue pause: paused=%v retryAt=%v dispatched=%d", c.paused, c.demandRetryAt, w.dispatched)
	}
	// Restore runners API and let retry timer elapse: fencing succeeds and dispatches hosted.
	c.runners = origRunners
	c.demandRetryAt = time.Now().Add(-time.Second)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if c.paused != nil || !c.state.Leases[request.Runner].Local.Fenced || w.dispatched != 1 {
		t.Fatalf("expected clean recovery after RemoveRunner 5xx: paused=%v fenced=%v dispatched=%d",
			c.paused, c.state.Leases[request.Runner].Local.Fenced, w.dispatched)
	}
}

type failingRemoveRunnerAPI struct {
	runnerAPI
	err error
}

func (f failingRemoveRunnerAPI) RemoveRunner(context.Context, int64) error {
	return f.err
}

func TestBusyCompletionDoesNotTriggerPhantomHostedOverflow(t *testing.T) {
	c, w, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	id := singleLease(c.state).RunnerID
	if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{RunnerName: request.Runner, RunnerID: id}); err != nil {
		t.Fatal(err)
	}
	w.busy = true
	w.assignedJobs = 1
	// Mac destroys guest and calls /v1/complete while GitHub still reports runner busy.
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatalf("busy completion should return 200 OK after persisting CleanupIntent: %v", err)
	}
	// Redrive with TotalAssignedJobs=1 (the still-dying job on GitHub) must NOT spawn a phantom hosted runner.
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if w.dispatched != 0 {
		t.Fatalf("busy local cleanup triggered phantom hosted overflow: dispatched=%d", w.dispatched)
	}
	// Once GitHub marks the job completed and idle, cleanup finishes cleanly.
	if err := c.HandleJobCompleted(t.Context(), &scaleset.JobCompleted{RunnerName: request.Runner, RunnerID: id, Result: "canceled"}); err != nil {
		t.Fatal(err)
	}
	w.busy = false
	w.assignedJobs = 0
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 0); err != nil {
		t.Fatal(err)
	}
	if len(c.state.Leases) != 0 {
		t.Fatalf("expected completed cleanup lease removed, remaining=%d", len(c.state.Leases))
	}
}

func TestFailedHostedBootstrapBacksOffHostedOnlyWithoutBlockingLocalOffers(t *testing.T) {
	c, w, _ := concurrentFixture(t, 1)
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
	for slot := 1; slot < 3; slot++ {
		if c.device.slotIdle(slot) {
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
	advertised := false
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if router.queue.slotIdle(0) {
			advertised = true
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !advertised {
		cancel()
		<-done
		t.Fatal("poll never advertised slot availability")
	}
	cancel()
	if err := <-done; err == nil {
		t.Fatal("expected canceled poll error")
	}
	if router.queue.slotIdle(0) {
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

type failingBusyAPI struct {
	bootstrapAPI
	err error
}

func (f failingBusyAPI) runnerBusy(context.Context, string, int) (bool, error) {
	return false, f.err
}
