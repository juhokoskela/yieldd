package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/actions/scaleset"
)

type concurrentWorld struct {
	*fakeWorld
	runners map[string]*scaleset.RunnerReference
	nextID  int
}

func (w *concurrentWorld) GenerateJitRunnerConfig(ctx context.Context, settings *scaleset.RunnerScaleSetJitRunnerSetting, id int) (*scaleset.RunnerScaleSetJitRunnerConfig, error) {
	result, err := w.fakeWorld.GenerateJitRunnerConfig(ctx, settings, id)
	if err != nil {
		return nil, err
	}
	w.nextID++
	result.Runner.ID = w.nextID
	w.runners[settings.Name] = result.Runner
	return result, nil
}

func (w *concurrentWorld) GetRunnerByName(_ context.Context, name string) (*scaleset.RunnerReference, error) {
	return w.runners[name], w.lookupErr
}

func (w *concurrentWorld) RemoveRunner(_ context.Context, id int64) error {
	for name, runner := range w.runners {
		if int64(runner.ID) == id {
			delete(w.runners, name)
			return nil
		}
	}
	return errors.New("test removed an unknown runner")
}

func concurrentFixture(t *testing.T, slots int) (*coordinator, *concurrentWorld, *stateStore) {
	t.Helper()
	c, world, store := newFixture(t)
	c.state.Config.DeviceID = testDevice
	w := &concurrentWorld{fakeWorld: world, runners: make(map[string]*scaleset.RunnerReference)}
	c.runners, c.bootstrap = w, w
	for i := range slots {
		c.device.pollNow(i)
	}
	return c, w, store
}

func issueLocal(t *testing.T, c *coordinator, slot, count int) deviceRequest {
	t.Helper()
	if _, err := c.HandleDesiredRunnerCount(t.Context(), count); err != nil {
		t.Fatal(err)
	}
	offer := c.device.pollNow(slot)
	if offer == nil || offer.Slot != slot {
		t.Fatal("missing worker offer", slot, offer)
	}
	request := requestFor(offer)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	return request
}

func requestFor(offer *deviceOffer) deviceRequest {
	return deviceRequest{DeviceID: testDevice, Owner: offer.Owner, Runner: offer.Runner, Slot: offer.Slot}
}

func TestConcurrentLocalAssignmentsSurviveRestartAndCompleteIndependently(t *testing.T) {
	c, w, store := concurrentFixture(t, 3)
	requests := make([]deviceRequest, 3)
	for i := range requests {
		requests[i] = issueLocal(t, c, i, 3)
	}
	if len(w.runners) != 3 || w.dispatched != 0 {
		t.Fatal("local jobs were serialized or sent to fallback", w.runners)
	}
	first := c.state.Leases[requests[0].Runner]
	if err := c.HandleJobCompleted(t.Context(), &scaleset.JobCompleted{RunnerName: first.Name, RunnerID: first.RunnerID}); err != nil {
		t.Fatal(err)
	}
	if !c.state.Leases[first.Name].Local.JobCompleted || c.state.Leases[requests[1].Runner].Local.JobStarted {
		t.Fatal("job events crossed assignments")
	}
	saved, err := store.load(c.state.Config)
	if err != nil {
		t.Fatal(err)
	}
	c.state, c.device = saved, newDeviceQueue(nil)
	if err := c.device.restore(saved); err != nil {
		t.Fatal(err)
	}
	for i := range requests {
		c.device.pollNow(i)
		if _, ok := c.device.claim("other", "unrelated"); ok {
			t.Fatal("restart released an issued slot")
		}
	}
	wrong := requests[1]
	wrong.Slot = 0
	if _, err := c.acceptDevice(t.Context(), wrong); err == nil {
		t.Fatal("another slot accepted credentials")
	}
	if renewed, err := c.renewDevice(t.Context(), wrong); err != nil || renewed.Continue {
		t.Fatal("another slot renewed", renewed, err)
	}
	if err := c.completeDevice(t.Context(), wrong); err == nil {
		t.Fatal("another slot cleared an assignment")
	}
	if err := c.completeDevice(t.Context(), requests[1]); err != nil {
		t.Fatal(err)
	}
	if len(c.state.Leases) != 2 || len(w.runners) != 2 {
		t.Fatal("cleanup removed sibling assignments")
	}
	if err := c.completeDevice(t.Context(), requests[1]); err != nil {
		t.Fatal("completion is not idempotent", err)
	}
	w.assignedJobs = 2
	c.device.pollNow(1)
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 3); n != 2 || err != nil {
		t.Fatal("cached demand created extra work", n, err)
	}
	w.assignedJobs = 3
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 3); n != 3 || err != nil {
		t.Fatal("fresh demand did not refill capacity", n, err)
	}
	if offer := c.device.pollNow(1); offer == nil || offer.Runner == requests[1].Runner {
		t.Fatal("freed slot was not reused with a fresh identity", offer)
	}
	for _, request := range []deviceRequest{requests[0], requests[2]} {
		if c.state.Leases[request.Runner].Local.Phase != localIssued {
			t.Fatal("sibling state changed")
		}
	}
}

func TestConcurrentCleanupRefreshesDemandAndRefillsWithoutListenerTick(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := concurrentFixture(t, 2)
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		router, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop})
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		startLoops(t, cancel, []*coordinatorLoop{loop})
		router.queue.pollNow(0)
		router.queue.pollNow(1)
		if n, err := loop.HandleDesiredRunnerCount(t.Context(), 2); n != 1 || err != nil {
			t.Fatal(n, err)
		}
		var first deviceRequest
		for slot := range 2 {
			synctest.Wait()
			offer := router.queue.pollNow(slot)
			if offer == nil {
				t.Fatal("next offer not created after issuance", slot)
			}
			request := requestFor(offer)
			if slot == 0 {
				first = request
			}
			if err := router.invoke(t.Context(), request, func(ctx context.Context, c *coordinator) error {
				_, err := c.acceptDevice(ctx, request)
				return err
			}); err != nil {
				t.Fatal(err)
			}
		}
		// Drain the second issuance wake while both slots still satisfy demand.
		synctest.Wait()
		if err := router.invoke(t.Context(), first, func(ctx context.Context, c *coordinator) error {
			w.assignedJobs = 2
			return c.completeDevice(ctx, first)
		}); err != nil {
			t.Fatal(err)
		}
		router.queue.pollNow(0)
		synctest.Wait()
		if offer := router.queue.pollNow(0); offer == nil || offer.Runner == first.Runner {
			t.Fatal("new capacity did not refill", offer)
		}
	})
}

func TestConcurrentAssignmentsBoundLocalCapacityAndPaidFallback(t *testing.T) {
	t.Run("one fallback alongside three local runners", func(t *testing.T) {
		c, w, _ := concurrentFixture(t, 3)
		for slot := range 3 {
			issueLocal(t, c, slot, 20)
		}
		if n, err := c.HandleDesiredRunnerCount(t.Context(), 20); n != 4 || err != nil {
			t.Fatal(n, err)
		}
		if w.dispatched != 1 {
			t.Fatal("paid fallback limit changed", w.dispatched)
		}
		for range 3 {
			if n, err := c.HandleDesiredRunnerCount(t.Context(), 20); n != 4 || err != nil {
				t.Fatal(n, err)
			}
		}
		if w.dispatched != 1 {
			t.Fatal("reconciliation dispatched more paid runners")
		}

	})
	t.Run("expired offer does not duplicate fallback", func(t *testing.T) {
		c, w, _ := concurrentFixture(t, 0)

		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		c.device.pollNow(0)
		if n, err := c.HandleDesiredRunnerCount(t.Context(), 2); n != 2 || err != nil {
			t.Fatal(n, err)
		}
		for _, l := range c.state.Leases {
			if l.Local != nil {
				l.Local.Expires = time.Now().Add(-time.Second)
			}
		}
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		if len(c.state.Leases) != 1 || w.dispatched != 1 {
			t.Fatal("expired offer created a second paid runner")
		}

	})
	t.Run("local assignments respect queue limit", func(t *testing.T) {
		c, _, _ := concurrentFixture(t, maximumAssignments)

		c.state.Config.LocalOnly, c.state.Config.Fallback = true, ""
		for slot := range maximumAssignments {
			issueLocal(t, c, slot, 100)
		}
		if n, err := c.HandleDesiredRunnerCount(t.Context(), 100); n != maximumAssignments || err != nil {
			t.Fatal(n, err)
		}
	})
}
func TestConcurrentPublicationFailureRetainsSiblingAndUncertainSlot(t *testing.T) {
	c, _, store := concurrentFixture(t, 2)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	request := requestFor(c.device.pollNow(0))
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	failure := errors.New("journal unavailable")
	c.save = func(*state) error { return failure }
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || len(saved.Leases) != 1 || saved.Leases[request.Runner].Local.Phase != localIssued {
		t.Fatal("failed publication damaged sibling", saved, err)
	}
	if c.device.pollNow(1) != nil {
		t.Fatal("unpublished offer became visible")
	}
	if _, ok := c.device.claim("other", "unrelated"); ok {
		t.Fatal("uncertain publication released slot")
	}
}

func TestProvisioningFailurePausesNewWorkWithoutRevokingIssuedSiblings(t *testing.T) {
	c, w, store := concurrentFixture(t, 2)
	requests := []deviceRequest{issueLocal(t, c, 0, 2), issueLocal(t, c, 1, 2)}
	w.generateErr = context.DeadlineExceeded
	c.device.wait(c.state.Owner)
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil || n != 3 || c.paused == nil {
		t.Fatal("hosted failure would stop healthy local runners", n, err)
	}
	if len(c.device.waiting) != 0 {
		t.Fatal("paused queue blocks other repositories' capacity")
	}
	w.generateErr, w.busy = nil, true
	for _, request := range requests {
		if auth, err := c.renewDevice(t.Context(), request); err != nil || !auth.Continue {
			t.Fatal("healthy sibling cannot renew", auth, err)
		}
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 10); n != 2 || err != nil {
		t.Fatal(n, err)
	}
	if w.dispatched != 0 || len(w.runners) != 2 {
		t.Fatal("paused queue provisioned more work")
	}
	w.busy = false
	for _, request := range requests {
		if err := c.completeDevice(t.Context(), request); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 10); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("pause disappeared without restart", err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || len(saved.Leases) != 0 {
		t.Fatal("cleanup failed while queue paused", saved, err)
	}
}

func TestFailedFallbackDoesNotStarveLaterExpiredOffer(t *testing.T) {
	c, w, store := concurrentFixture(t, 1)
	issued := issueLocal(t, c, 0, 1)
	// Fixed names establish the failure-before-expiry ordering deterministically.
	fallback := &lease{Name: "yieldd-bootstrap-00000000-0000-4000-8000-000000000000", Created: time.Now().UTC(), RunnerID: 99, DispatchIntent: true, RunID: 99}
	offer := &lease{Name: "yieldd-bootstrap-ffffffff-ffff-4fff-8fff-ffffffffffff", Created: time.Now().UTC(), Local: &localLease{DeviceID: testDevice, Slot: 1, Phase: localOffered, Expires: time.Now().Add(-time.Second)}}
	c.state.Leases[fallback.Name], c.state.Leases[offer.Name] = fallback, offer
	c.device = newDeviceQueue(nil)
	if err := c.device.restore(c.state); err != nil {
		t.Fatal(err)
	}
	w.getErr = errors.New("GitHub unavailable")
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil || n != 2 || c.paused == nil {
		t.Fatalf("expired offer was starved behind a failed fallback: count=%d err=%v", n, err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || saved.Leases[offer.Name] != nil || saved.Leases[issued.Runner] == nil || c.device.slots[1].owner != "" {
		t.Fatal("cleanup was not published without releasing the issued sibling", saved, err)
	}
	// No expired offer remains to arm an immediate redrive timer.
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		loop.demandObserved, loop.desiredCount = true, 3
		startLoops(t, cancel, []*coordinatorLoop{loop})
		before := w.getCalls
		time.Sleep(time.Minute)
		if w.getCalls != before {
			t.Fatal("paused queue spun without new demand", w.getCalls-before)
		}
	})
}

func TestPausedQueueRejectsOutstandingOfferWithoutIssuingCredentials(t *testing.T) {
	c, w, _ := concurrentFixture(t, 1)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	request := requestFor(c.device.pollNow(0))
	c.paused = errors.New("another assignment failed")
	credential, err := c.acceptDevice(t.Context(), request)
	var rejection *deviceError
	if credential != nil || !errors.As(err, &rejection) || rejection.status != 410 || len(w.runners) != 0 || len(w.events) != 0 {
		t.Fatal("paused queue issued new credentials", credential, err, w.events)
	}
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal("pause blocked unused offer cleanup", err)
	}
}

func TestDeclinedOfferReconcilesWithoutWaitingForAcceptanceExpiry(t *testing.T) {
	for _, localOnly := range []bool{false, true} {
		t.Run(fmt.Sprint("local-only=", localOnly), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, _ := concurrentFixture(t, 0)
				c.state.Config.LocalOnly = localOnly
				if localOnly {
					c.state.Config.Fallback = ""
				}
				ctx, cancel := context.WithCancel(t.Context())
				loop := newCoordinatorLoop(ctx, c)
				router, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop})
				if err != nil {
					cancel()
					t.Fatal(err)
				}
				startLoops(t, cancel, []*coordinatorLoop{loop})
				router.queue.pollNow(0)
				if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
					t.Fatal(err)
				}
				request := requestFor(router.queue.pollNow(0))
				before := time.Now()
				handler := router.deviceHandler(strings.Repeat("x", 32))
				if out := requestDevice(handler, "decline", request); out.Code != 200 {
					t.Fatal(out.Code, out.Body)
				}
				synctest.Wait()
				if time.Since(before) != 0 || router.queue.slots[0].owner != "" {
					t.Fatal("decline waited for expiry or retained the worker")
				}
				if localOnly {
					if len(c.state.Leases) != 0 || w.dispatched != 0 {
						t.Fatal("local-only decline dispatched fallback")
					}
				} else if len(c.state.Leases) != 1 || w.dispatched != 1 {
					t.Fatal("decline did not start fallback")
				}
				if out := requestDevice(handler, "decline", request); out.Code != 200 {
					t.Fatal("decline not idempotent", out.Code)
				}
				if out := requestDevice(handler, "accept", request); out.Code != 410 {
					t.Fatal("declined offer issued credentials", out.Code)
				}
			})
		})
	}
}

func TestDeclineCannotRevokeAnotherSlotOrIssuedAssignment(t *testing.T) {
	c, _, store := concurrentFixture(t, 2)
	issued := issueLocal(t, c, 0, 2)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
		t.Fatal(err)
	}
	offered := requestFor(c.device.pollNow(1))
	wrong := offered
	wrong.Slot = 0
	for _, request := range []deviceRequest{issued, wrong} {
		var rejection *deviceError
		if err := c.declineDevice(request); !errors.As(err, &rejection) || rejection.status != 409 {
			t.Fatal(err)
		}
	}
	failure := errors.New("journal unavailable")
	c.save = func(*state) error { return failure }
	if err := c.declineDevice(offered); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || saved.Leases[offered.Runner].Local.expired() || c.state.Leases[offered.Runner].Local.expired() {
		t.Fatal("failed decline publication changed the offer", err)
	}
}

func TestDeclineRemainsUnavailableAfterRestartAndClockRollback(t *testing.T) {
	c, w, store := concurrentFixture(t, 1)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	request := requestFor(c.device.pollNow(0))
	if err := c.declineDevice(request); err != nil {
		t.Fatal(err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil {
		t.Fatal(err)
	}
	c.state = saved
	// Even a deadline that becomes live again cannot reopen an explicit decline.
	c.state.Leases[request.Runner].Local.Expires = time.Now().Add(offerLifetime)
	if _, err := c.acceptDevice(t.Context(), request); err == nil || len(w.events) != 0 {
		t.Fatal("declined offer reopened", err)
	}
	if err := c.declineDevice(request); err != nil {
		t.Fatal(err)
	}
}

type blockedBootstrapStatus struct {
	bootstrapAPI
	entered chan struct{}
	resume  chan struct{}
}

func (b *blockedBootstrapStatus) getRun(ctx context.Context, id int64) (*workflowRun, error) {
	select {
	case b.entered <- struct{}{}:
	default:
	}
	select {
	case <-b.resume:
		return b.bootstrapAPI.getRun(ctx, id)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func TestSlowFallbackStatusDoesNotBlockAnotherRepositoryFromIdleCapacity(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		router, loops, worlds := routerFixture(t, false)
		first := loops[0]
		if _, err := first.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		blocked := &blockedBootstrapStatus{bootstrapAPI: worlds[0], entered: make(chan struct{}, 1), resume: make(chan struct{})}
		if err := first.invoke(t.Context(), func(context.Context) error { first.worker.bootstrap = blocked; return nil }); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { _, err := first.HandleDesiredRunnerCount(t.Context(), 2); done <- err }()
		defer func() {
			close(blocked.resume)
			if err := <-done; err != nil {
				t.Error(err)
			}
		}()
		<-blocked.entered
		router.queue.pollNow(0)
		if _, err := loops[1].HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		if offer := router.queue.pollNow(0); offer == nil || offer.Owner != loops[1].worker.state.Owner || worlds[1].dispatched != 0 {
			t.Fatal("slow fallback status blocked an idle Mac slot", offer, worlds[1].dispatched)
		}
	})
}

func TestWorkerLongPollsAreIndependentAndRejectDuplicateSlots(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, _, _ := concurrentFixture(t, 0)
		c.state.Config.LocalOnly, c.state.Config.Fallback = true, ""
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		router, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop})
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		startLoops(t, cancel, []*coordinatorLoop{loop})
		handler := router.deviceHandler(strings.Repeat("x", 32))
		results := make(chan *httptest.ResponseRecorder, 2)
		for slot := range 2 {
			go func() { results <- requestDevice(handler, "poll", deviceRequest{DeviceID: testDevice, Slot: slot}) }()
		}
		synctest.Wait()
		if out := requestDevice(handler, "poll", deviceRequest{DeviceID: testDevice, Slot: 1}); out.Code != 409 {
			t.Fatal(out.Code, out.Body)
		}
		for _, slot := range []int{-1, maximumAssignments} {
			if out := requestDevice(handler, "poll", deviceRequest{DeviceID: testDevice, Slot: slot}); out.Code != 400 {
				t.Fatal(out.Code, out.Body)
			}
		}
		if count, err := loop.HandleDesiredRunnerCount(t.Context(), 2); count != 1 || err != nil {
			t.Fatal(count, err)
		}
		seen := make(map[int]string)
		for range 2 {
			out := <-results
			var offer deviceOffer
			if out.Code != 200 || json.Unmarshal(out.Body.Bytes(), &offer) != nil {
				t.Fatal(out.Code, out.Body)
			}
			if seen[offer.Slot] != "" {
				t.Fatal("polls received the same worker", offer)
			}
			seen[offer.Slot] = offer.Runner
			if out := requestDevice(handler, "accept", requestFor(&offer)); out.Code != 200 {
				t.Fatal(out.Code, out.Body)
			}
		}
		if seen[0] == seen[1] {
			t.Fatal("two slots received one assignment")
		}
	})
}

func TestListenerAdmitsSeveralLocalRunnersForOneRepository(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, world, _ := concurrentFixture(t, 3)
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		p := testPlatform(t, ctx, c, &controlledMessages{initial: 3})
		router, err := newDeviceRouter(testDevice, []*coordinatorLoop{p.loop})
		if err != nil {
			t.Fatal(err)
		}
		for slot := range 3 {
			router.queue.pollNow(slot)
		}
		world.beforeGenerate = func() { time.Sleep(4 * time.Second) }
		done := make(chan error, 1)
		go func() { done <- p.run(ctx, false) }()
		for slot := range 3 {
			synctest.Wait()
			offer := router.queue.pollNow(slot)
			if offer == nil {
				t.Fatal("worker was not offered after slow sibling registration", slot)
			}
			request := requestFor(offer)
			if err := router.invoke(t.Context(), request, func(ctx context.Context, c *coordinator) error { _, err := c.acceptDevice(ctx, request); return err }); err != nil {
				t.Fatal(err)
			}
		}
		synctest.Wait()
		if len(c.state.Leases) != 3 {
			t.Fatal("upstream listener still serialized demand", len(c.state.Leases))
		}
		cancel()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	})
}

func TestAssignmentStateRejectsMismatchedKeysDuplicateSlotsAndOldActiveJournal(t *testing.T) {
	for _, kind := range []string{"key", "slot", "old"} {
		t.Run(kind, func(t *testing.T) {
			c, _, store := concurrentFixture(t, 2)
			issueLocal(t, c, 0, 2)
			issueLocal(t, c, 1, 2)
			names := c.names()
			switch kind {
			case "key":
				c.state.Leases[names[0]] = c.state.Leases[names[1]]
			case "slot":
				c.state.Leases[names[0]].Local.Slot = c.state.Leases[names[1]].Local.Slot
			}
			if err := store.save(c.state); err != nil {
				t.Fatal(err)
			}
			if kind == "old" {
				data, err := store.root.ReadFile("state.json")
				if err != nil {
					t.Fatal(err)
				}
				if err := store.root.WriteFile("state.json", []byte(strings.Replace(string(data), `"leases":`, `"lease":`, 1)), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := store.load(c.state.Config); err == nil {
				t.Fatal("invalid journal accepted")
			} else if kind == "old" && !errors.Is(err, previousVersionState) {
				t.Fatal("old journal did not explain previous-version recovery", err)
			}
		})
	}
}

func TestOversizedAssignmentStateCannotReplaceReadableJournal(t *testing.T) {
	c, _, store := concurrentFixture(t, 1)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	before, err := store.root.ReadFile("state.json")
	if err != nil {
		t.Fatal(err)
	}
	c.state.Leases[c.names()[0]].Conclusion = strings.Repeat("x", maximumStateBytes)
	if err := store.save(c.state); err == nil {
		t.Fatal("oversized journal was published")
	}
	after, err := store.root.ReadFile("state.json")
	if err != nil || string(before) != string(after) {
		t.Fatal("previous journal replaced", err)
	}
	if _, err := store.load(c.state.Config); err != nil {
		t.Fatal(err)
	}
	entries, err := fs.ReadDir(store.root.FS(), ".")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".tmp") {
			t.Fatal("temporary journal leaked")
		}
	}
}

// This helper keeps single-assignment lifecycle tests explicit without adding
// a single-lease compatibility path to production.
func singleLease(s *state) *lease {
	if len(s.Leases) > 1 {
		panic("test expected at most one assignment")
	}
	for _, l := range s.Leases {
		return l
	}
	return nil
}
