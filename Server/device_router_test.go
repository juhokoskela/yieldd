package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

func deviceHandlerFor(t *testing.T, loop *coordinatorLoop, token string) http.Handler {
	t.Helper()
	router, err := newDeviceRouter(loop.worker.state.Config.DeviceID, []*coordinatorLoop{loop})
	if err != nil {
		t.Fatal(err)
	}
	return router.deviceHandler(token)
}

func routerFixture(t *testing.T, localOnly bool) (*deviceRouter, []*coordinatorLoop, []*fakeWorld) {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	var loops []*coordinatorLoop
	var worlds []*fakeWorld
	for _, repository := range []string{"example/a", "example/b"} {
		worker, world, _ := newFixture(t)
		worker.state.Config.Repository = repository
		worker.state.Config.DeviceID = testDevice
		worker.state.Config.LocalOnly = localOnly
		if localOnly {
			worker.state.Config.Fallback = ""
		}
		loops = append(loops, newCoordinatorLoop(ctx, worker))
		worlds = append(worlds, world)
	}
	router, err := newDeviceRouter(testDevice, loops)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	startLoops(t, cancel, loops)
	return router, loops, worlds
}

func startLoops(t *testing.T, cancel context.CancelFunc, loops []*coordinatorLoop) {
	t.Helper()
	done := make(chan error, len(loops))
	for _, loop := range loops {
		go func() { done <- loop.run() }()
	}
	t.Cleanup(func() {
		cancel()
		for range loops {
			if err := <-done; err != nil {
				t.Error(err)
			}
		}
	})
}

func requestDevice(handler http.Handler, action string, request deviceRequest) *httptest.ResponseRecorder {
	data, _ := json.Marshal(request)
	r := httptest.NewRequest("POST", "/v1/"+action, strings.NewReader(string(data)))
	r.Header.Set("Authorization", "Bearer "+strings.Repeat("x", 32))
	out := httptest.NewRecorder()
	handler.ServeHTTP(out, r)
	return out
}

func TestLocalOnlyCleanupRetriesWithoutDemandAndRetainsSlotUntilSuccess(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		router, loops, worlds := routerFixture(t, false)
		local := loops[0]
		if err := local.invoke(t.Context(), func(context.Context) error {
			local.worker.state.Config.LocalOnly = true
			local.worker.state.Config.Fallback = ""
			worlds[0].lookupErr = context.DeadlineExceeded
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		router.queue.pollNow()
		if _, err := local.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		time.Sleep(offerLifetime)
		synctest.Wait()
		if local.worker.state.Lease == nil || !local.worker.state.Lease.CleanupIntent || router.queue.owner != local.worker.state.Owner {
			t.Fatal("failed cleanup did not retain the slot")
		}
		if n, err := loops[1].HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || worlds[1].dispatched != 1 {
			t.Fatal("app fallback was blocked by local-only cleanup", n, err)
		}
		time.Sleep(cleanupRetryDelay - time.Second)
		if err := local.invoke(t.Context(), func(context.Context) error {
			worlds[0].lookupErr = nil
			if local.worker.state.Lease == nil {
				return fmt.Errorf("cleanup ran before its retry deadline")
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		// This unrelated call must not postpone the pending retry.
		time.Sleep(time.Second)
		synctest.Wait()
		if local.worker.state.Lease != nil || router.queue.owner != "" {
			t.Fatal("cleanup did not retry autonomously")
		}
		router.queue.pollNow()
		synctest.Wait()
		if offer := router.queue.pollNow(); offer == nil || offer.Owner != local.worker.state.Owner {
			t.Fatal("local-only demand was not requeued", offer)
		}
	})
}

func TestFallbackQueueCannotPassWaitingLocalOnlyQueue(t *testing.T) {
	local, _, _ := newFixture(t)
	app, world, _ := newFixture(t)
	queue := newDeviceQueue(nil)
	local.device, app.device = queue, queue
	local.state.Config.DeviceID, app.state.Config.DeviceID = testDevice, testDevice
	local.state.Config.LocalOnly, local.state.Config.Fallback = true, ""
	if n, err := local.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 {
		t.Fatal(n, err)
	}
	queue.pollNow()
	if n, err := app.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || world.dispatched != 1 {
		t.Fatal("fallback queue took the waiting queue's capacity", n, err)
	}
	if !slices.Equal(queue.waiting, []string{local.state.Owner}) {
		t.Fatal("fallback queue joined the local FIFO", queue.waiting)
	}
	if n, err := local.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || local.state.Lease.Local == nil {
		t.Fatal("waiting queue did not receive capacity", n, err)
	}
}

func TestRepositoriesShareOneLocalSlotAndKeepHostedFallback(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		router, loops, worlds := routerFixture(t, false)
		router.queue.pollNow()
		for _, loop := range loops {
			if n, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 {
				t.Fatal(n, err)
			}
		}
		synctest.Wait()
		if loops[0].worker.state.Lease.Local == nil || worlds[0].dispatched != 0 || worlds[1].dispatched != 1 {
			t.Fatal("local capacity was duplicated or fallback lost")
		}
		handler := router.deviceHandler(strings.Repeat("x", 32))
		out := requestDevice(handler, "poll", deviceRequest{DeviceID: testDevice})
		var offer deviceOffer
		if out.Code != 200 || json.Unmarshal(out.Body.Bytes(), &offer) != nil || offer.Repository != "example/a" {
			t.Fatal(out.Code, out.Body)
		}
		request := deviceRequest{DeviceID: testDevice, Owner: offer.Owner, Runner: offer.Runner}
		if out := requestDevice(handler, "accept", request); out.Code != 200 {
			t.Fatal(out.Code, out.Body)
		}
		wrong := request
		wrong.Owner = loops[1].worker.state.Owner
		if out := requestDevice(handler, "accept", wrong); out.Code != 410 {
			t.Fatal(out.Code, out.Body)
		}
		if out := requestDevice(handler, "renew", wrong); out.Code != 200 || !strings.Contains(out.Body.String(), `"continue":false`) {
			t.Fatal(out.Code, out.Body)
		}
		if out := requestDevice(handler, "complete", wrong); out.Code != 200 {
			t.Fatal(out.Code, out.Body)
		}
		if out := requestDevice(handler, "complete", request); out.Code != 200 {
			t.Fatal(out.Code, out.Body)
		}
		synctest.Wait()
		if worlds[0].runner != nil || loops[0].worker.state.Lease != nil || worlds[1].runner == nil || loops[1].worker.state.Lease == nil {
			t.Fatal("cleanup crossed repository boundaries")
		}
		if out := requestDevice(handler, "complete", request); out.Code != 200 {
			t.Fatal("lost completion response was not idempotent", out.Code)
		}
		request.Owner = "unknown"
		if out := requestDevice(handler, "complete", request); out.Code != 409 {
			t.Fatal(out.Code)
		}
	})
}

func TestLocalOnlyQueuesWaitInOrderAndWakeWithoutNewGitHubDemand(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		router, loops, worlds := routerFixture(t, true)
		for _, loop := range loops {
			if n, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 {
				t.Fatal(n, err)
			}
		}
		synctest.Wait()
		for i, loop := range loops {
			if loop.worker.state.Lease != nil || len(worlds[i].events) != 0 {
				t.Fatal("offline queue provisioned")
			}
		}
		router.queue.pollNow()
		synctest.Wait()
		offer := router.queue.pollNow()
		if offer == nil || offer.Repository != "example/a" {
			t.Fatal("first waiting queue lost its turn", offer)
		}
		handler := router.deviceHandler(strings.Repeat("x", 32))
		request := deviceRequest{DeviceID: testDevice, Owner: offer.Owner, Runner: offer.Runner}
		if out := requestDevice(handler, "accept", request); out.Code != 200 {
			t.Fatal(out.Code, out.Body)
		}
		if out := requestDevice(handler, "complete", request); out.Code != 200 {
			t.Fatal(out.Code, out.Body)
		}
		// The same repository receives more demand, but the other was already waiting.
		if _, err := loops[0].HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		router.queue.pollNow()
		synctest.Wait()
		offer = router.queue.pollNow()
		if offer == nil || offer.Repository != "example/b" {
			t.Fatal("waiting repository starved", offer)
		}
		for _, world := range worlds {
			if world.dispatched != 0 || world.secret != "" {
				t.Fatal("local-only queue used infrastructure")
			}
		}
	})
}

func TestLocalOnlyExpiryReleasesOfferWithoutHostedSideEffects(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		router, loops, worlds := routerFixture(t, true)
		router.queue.pollNow()
		if _, err := loops[0].HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		if _, err := loops[1].HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		time.Sleep(offerLifetime)
		synctest.Wait()
		for _, world := range worlds {
			if len(world.events) != 0 {
				t.Fatal(world.events)
			}
		}
		router.queue.pollNow()
		synctest.Wait()
		offer := router.queue.pollNow()
		if offer == nil || offer.Repository != "example/b" {
			t.Fatal("expired queue did not yield", offer)
		}
	})
}

func TestRestoredExpiredLocalOnlyOfferRequeuesOutstandingDemand(t *testing.T) {
	for _, failure := range []string{"unaccepted", "registration", "issuance"} {
		for _, demand := range []int{0, 1} {
			t.Run(fmt.Sprintf("%s/demand=%d", failure, demand), func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					c, world, store, request := localFixture(t)
					c.state.Config.LocalOnly, c.state.Config.Fallback = true, ""
					if err := c.save(c.state); err != nil {
						t.Fatal(err)
					}
					var wantEvents []string
					switch failure {
					case "registration":
						world.generateErr = io.ErrUnexpectedEOF
						wantEvents = []string{"register"}
					case "issuance":
						c.save = func(s *state) error {
							if s.Lease != nil && s.Lease.Local.Phase == localIssued {
								return io.ErrUnexpectedEOF
							}
							return store.save(s)
						}
						wantEvents = []string{"register", "remove-runner"}
					}
					if failure != "unaccepted" {
						if credential, err := c.acceptDevice(t.Context(), request); err == nil || credential != nil {
							t.Fatal("acceptance did not fail before credential delivery", err)
						}
						if c.state.Lease.Local.Phase != localAccepted {
							t.Fatal("failed acceptance did not retain its phase")
						}
						c.save, world.generateErr = store.save, nil
					}
					time.Sleep(time.Until(c.state.Lease.Local.Expires) + time.Second)
					saved, err := store.load(c.state.Config)
					if err != nil {
						t.Fatal(err)
					}
					c.state = saved
					ctx, cancel := context.WithCancel(t.Context())
					loop := newCoordinatorLoop(ctx, c)
					router, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop})
					if err != nil {
						cancel()
						t.Fatal(err)
					}
					startLoops(t, cancel, []*coordinatorLoop{loop})
					if _, err := loop.HandleDesiredRunnerCount(t.Context(), demand); err != nil {
						t.Fatal(err)
					}
					cleared, err := store.load(c.state.Config)
					if err != nil || cleared.Lease != nil || world.runner != nil {
						t.Fatal("expired assignment was not cleaned up before polling", err)
					}
					router.queue.pollNow()
					synctest.Wait()
					offer := router.queue.pollNow()
					if (offer != nil) != (demand > 0) || !slices.Equal(world.events, wantEvents) {
						t.Fatal("incorrect demand after expired offer recovery", demand, offer, world.events)
					}
					if offer != nil && offer.Runner == request.Runner {
						t.Fatal("expired assignment was reused")
					}
				})
			})
		}
	}
}

func TestIssuedLocalOnlyCleanupDoesNotReuseStaleDemand(t *testing.T) {
	c, world, _, request := localFixture(t)
	c.state.Config.LocalOnly, c.state.Config.Fallback = true, ""
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	if err := c.beginCleanup(""); err != nil {
		t.Fatal(err)
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 {
		t.Fatal(n, err)
	}
	if c.state.Lease != nil || world.runner != nil || c.device.pollNow() != nil || len(c.device.waiting) != 0 {
		t.Fatal("completed assignment requeued stale demand")
	}
}

func TestSlowHostedRepositoryDoesNotBlockAnotherRepositoryPoll(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		router, loops, worlds := routerFixture(t, false)
		started, release := make(chan struct{}), make(chan struct{})
		worlds[0].afterSecret = func() { close(started); <-release }
		provisioned := make(chan error, 1)
		go func() { _, err := loops[0].HandleDesiredRunnerCount(t.Context(), 1); provisioned <- err }()
		<-started
		router.queue.pollNow()
		if _, err := loops[1].HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			close(release)
			t.Fatal(err)
		}
		offer, err := router.poll(t.Context(), deviceRequest{DeviceID: testDevice})
		close(release)
		if err != nil || offer == nil || offer.Repository != "example/b" {
			t.Fatal(offer, err)
		}
		if err := <-provisioned; err != nil {
			t.Fatal(err)
		}
	})
}

func TestRestoredLocalAssignmentHoldsSharedCapacityUntilAcknowledged(t *testing.T) {
	c, _, store, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil {
		t.Fatal(err)
	}
	queue := newDeviceQueue(nil)
	if err := queue.restore(saved); err != nil {
		t.Fatal(err)
	}
	queue.pollNow()
	if queue.claim("another queue") {
		t.Fatal("issued assignment lost local hold")
	}
	other := *saved
	other.Owner = testDevice
	if err := queue.restore(&other); err == nil {
		t.Fatal("overlapping assignments accepted")
	}
	c.device, c.state = queue, saved
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	queue.pollNow()
	if !queue.claim("another queue") {
		t.Fatal("completed assignment retained local hold")
	}
}

func TestFailedLocalPublicationDoesNotExposeAnOffer(t *testing.T) {
	c, world, _ := newFixture(t)
	c.state.Config.DeviceID = testDevice
	c.device.pollNow()
	c.save = func(*state) error { return io.ErrUnexpectedEOF }
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
		t.Fatal("save failure ignored")
	}
	if offer := c.device.pollNow(); offer != nil {
		t.Fatal("uncommitted offer exposed", offer)
	}
	if c.device.claim("another queue") || len(world.events) != 0 {
		t.Fatal("uncertain save released capacity or registered a runner")
	}
}

func TestConcurrentRepositoryDemandCannotDuplicateLocalCapacity(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	var loops []*coordinatorLoop
	var worlds []*fakeWorld
	for _, repository := range []string{"example/a", "example/b", "example/c", "example/d"} {
		worker, world, _ := newFixture(t)
		worker.state.Config.Repository, worker.state.Config.DeviceID = repository, testDevice
		loops = append(loops, newCoordinatorLoop(ctx, worker))
		worlds = append(worlds, world)
	}
	router, err := newDeviceRouter(testDevice, loops)
	if err != nil {
		t.Fatal(err)
	}
	startLoops(t, cancel, loops)
	router.queue.pollNow()
	start := make(chan struct{})
	results := make(chan error, len(loops))
	for _, loop := range loops {
		go func() { <-start; _, err := loop.HandleDesiredRunnerCount(ctx, 1); results <- err }()
	}
	close(start)
	for range loops {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	local, fallback := 0, 0
	for i, loop := range loops {
		if err := loop.invoke(ctx, func(context.Context) error {
			if loop.worker.state.Lease.Local != nil {
				local++
			}
			fallback += worlds[i].dispatched
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	if local != 1 || fallback != 3 {
		t.Fatal("incorrect shared admission", local, fallback)
	}
}

func TestRetractedLocalOnlyDemandDoesNotOccupyTheWaitingQueue(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		router, loops, _ := routerFixture(t, true)
		for _, loop := range loops {
			if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := loops[0].HandleDesiredRunnerCount(t.Context(), 0); err != nil {
			t.Fatal(err)
		}
		router.queue.pollNow()
		synctest.Wait()
		offer := router.queue.pollNow()
		if offer == nil || offer.Repository != "example/b" {
			t.Fatal("cancelled demand retained its place", offer)
		}
	})
}

func TestLocalOnlyQueueRejectsHostedStateAndDispatch(t *testing.T) {
	c, world, store := newFixture(t)
	c.state.Config.DeviceID, c.state.Config.LocalOnly, c.state.Config.Fallback = testDevice, true, ""
	c.state.Lease = &lease{Name: fixtureRunner, Created: time.Now().UTC()}
	if err := c.save(c.state); err != nil {
		t.Fatal(err)
	}
	if _, err := store.load(c.state.Config); err == nil {
		t.Fatal("hosted state loaded into local-only queue")
	}
	if err := c.prepare(t.Context()); err == nil || len(world.events) != 0 {
		t.Fatal("local-only fallback was attempted", err, world.events)
	}
}
