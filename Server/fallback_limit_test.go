package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"testing/synctest"
	"time"
)

type multipleBootstrapWorld struct {
	*concurrentWorld
	runs map[int64]*workflowRun
}

func (w *multipleBootstrapWorld) dispatch(ctx context.Context, l *lease, fallback string) (int64, error) {
	_, err := w.fakeWorld.dispatch(ctx, l, fallback)
	if err != nil {
		return 0, err
	}
	w.run.ID += int64(w.dispatched)
	w.runs[w.run.ID] = w.run
	return w.run.ID, nil
}

func (w *multipleBootstrapWorld) getRun(_ context.Context, id int64) (*workflowRun, error) {
	w.getRunMu.Lock()
	defer w.getRunMu.Unlock()
	w.getCalls++
	if w.getErr != nil {
		return nil, w.getErr
	}
	run := w.runs[id]
	if run == nil {
		return nil, errors.New("test looked up an unknown bootstrap")
	}
	snapshot := *run
	return &snapshot, nil
}

func multipleFallbackFixture(t *testing.T, limit int) (*coordinator, *multipleBootstrapWorld, *stateStore) {
	t.Helper()
	c, world, store := concurrentFixture(t, 0)
	w := &multipleBootstrapWorld{concurrentWorld: world, runs: make(map[int64]*workflowRun)}
	c.bootstrap = w
	c.maxFallbackRunners = limit
	w.assignedJobs = maximumAssignments
	return c, w, store
}

func TestFallbackLimitCanIncreaseAndDecreaseWithoutChangingJournals(t *testing.T) {
	c, w, store := multipleFallbackFixture(t, 3)
	for want := 1; want <= 3; want++ {
		if n, err := c.HandleDesiredRunnerCount(t.Context(), maximumAssignments); err != nil || n != want {
			t.Fatal("fallback did not scale one assignment per pass", n, want, err)
		}
	}
	for range 3 {
		if n, err := c.HandleDesiredRunnerCount(t.Context(), maximumAssignments); err != nil || n != 3 || w.dispatched != 3 {
			t.Fatal("fallback exceeded the configured cap", n, err, w.dispatched)
		}
	}
	saved, err := store.load(c.state.Config)
	if err != nil || len(saved.Leases) != 3 {
		t.Fatal("concurrent fallback identities were not persisted", saved, err)
	}
	c.state, c.maxFallbackRunners = saved, 1
	if n, err := c.HandleDesiredRunnerCount(t.Context(), maximumAssignments); err != nil || n != 3 || w.dispatched != 3 {
		t.Fatal("lowering the cap terminated or duplicated existing execution", n, err)
	}
	name := c.names()[0]
	l := c.state.Leases[name]
	w.runs[l.RunID].Status, w.runs[l.RunID].Conclusion = "completed", "success"
	if n, err := c.HandleDesiredRunnerCount(t.Context(), maximumAssignments); err != nil || n != 2 {
		t.Fatal("one fallback could not clean up independently", n, err)
	}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), maximumAssignments); err != nil || w.dispatched != 3 || len(w.runners) != 2 {
		t.Fatal("lower cap admitted another fallback", err, w.dispatched)
	}
	c.maxFallbackRunners = 3
	if n, err := c.HandleDesiredRunnerCount(t.Context(), maximumAssignments); err != nil || n != 3 || w.dispatched != 4 {
		t.Fatal("raising the cap did not refill from fresh demand", n, err)
	}
}

func TestExpiredLocalOffersUseTheConfiguredFallbackLimit(t *testing.T) {
	c, w, _ := multipleFallbackFixture(t, 2)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
		t.Fatal(err)
	}
	c.device.pollNow(0)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
		t.Fatal(err)
	}
	offer := c.device.pollNow(0)
	if offer == nil {
		t.Fatal("local capacity was not preferred below the cap")
	}
	if err := c.declineDevice(requestFor(offer)); err != nil {
		t.Fatal(err)
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil || n != 2 || w.dispatched != 2 || c.state.Leases[offer.Runner].RunID == 0 {
		t.Fatal("declined offer was not converted below the cap", n, err, w.dispatched)
	}
	c.device.pollNow(0)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
		t.Fatal(err)
	}
	offer = c.device.pollNow(0)
	if offer == nil {
		t.Fatal("local capacity was not preferred above the cap")
	}
	if err := c.declineDevice(requestFor(offer)); err != nil {
		t.Fatal(err)
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil || n != 2 || w.dispatched != 2 || c.state.Leases[offer.Runner] != nil {
		t.Fatal("declined offer was retained above the cap", n, err, w.dispatched)
	}
}

func TestHostedProvisioningLeavesTheEventLoopBetweenAssignments(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 3)
		c.device.pollNow(0)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
		offer := c.device.pollNow(0)
		if offer == nil {
			t.Fatal("offer missing")
		}
		if err := c.declineDevice(requestFor(offer)); err != nil {
			t.Fatal(err)
		}
		w.beforeGenerate = func() { time.Sleep(40 * time.Second) }
		for want := 1; want <= 3; want++ {
			ctx, cancel := context.WithTimeout(t.Context(), time.Minute)
			started := time.Now()
			n, err := c.HandleDesiredRunnerCount(ctx, 3)
			cancel()
			if err != nil || n != want || time.Since(started) != 40*time.Second {
				t.Fatal("one provisioning pass consumed another assignment's request budget", n, want, err, time.Since(started))
			}
		}
	})
}

func TestLocalOnlyQueueIgnoresRaisedFallbackLimit(t *testing.T) {
	c, w, _ := multipleFallbackFixture(t, maximumAssignments)
	c.state.Config.LocalOnly, c.state.Config.Fallback = true, ""
	if n, err := c.HandleDesiredRunnerCount(t.Context(), maximumAssignments); err != nil || n != 0 || w.dispatched != 0 || len(w.runners) != 0 {
		t.Fatal("local-only queue used paid capacity", n, err, w.events)
	}
}

func TestIdentityRecoveryVerifiesEveryAffectedFallback(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 2)
		for range 2 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
				t.Fatal(err)
			}
		}
		names := c.names()
		first, second := c.state.Leases[names[0]], c.state.Leases[names[1]]
		w.runs[first.RunID].ID++
		w.runs[second.RunID].ID++
		w.runs[second.RunID].DisplayTitle = "Pending bootstrap metadata"
		w.runs[second.RunID].Status, w.runs[second.RunID].Conclusion = "completed", "success"
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || c.paused == nil {
			t.Fatal("identity errors were not retained", err)
		}
		w.runs[first.RunID].ID = first.RunID
		time.Sleep(5 * time.Second)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || c.paused == nil || len(c.state.Leases) != 2 {
			t.Fatal("one verified run cleared another assignment's pause", err)
		}
		w.runs[second.RunID].ID = second.RunID
		time.Sleep(10 * time.Second)
		if n, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || n != 1 || c.paused != nil || c.state.Leases[first.Name] == nil || w.dispatched != 2 || slices.Contains(w.events, "cancel") {
			t.Fatal("verified recovery canceled or redispatched ongoing execution", n, err, w.events)
		}
	})
}

func TestFallbackCapacityFillsWithoutAnotherDemandCallback(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 3)
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop}); err != nil {
			cancel()
			t.Fatal(err)
		}
		startLoops(t, cancel, []*coordinatorLoop{loop})
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 10); err != nil {
			t.Fatal(err)
		}
		synctest.Wait()
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if len(c.state.Leases) != 3 || w.dispatched != 3 {
				return fmt.Errorf("fallback cap did not fill autonomously: %d leases, %d dispatches", len(c.state.Leases), w.dispatched)
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	})
}
