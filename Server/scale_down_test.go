package main

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestPositiveScaleDownRetiresUnusedLocalAssignmentsBeforeFallback(t *testing.T) {
	for _, localOnly := range []bool{false, true} {
		for _, phase := range []localPhase{localOffered, localAccepted, localDeclined} {
			t.Run(fmt.Sprintf("local-only=%t/%s", localOnly, phase), func(t *testing.T) {
				c, w, store := concurrentFixture(t, 3)
				c.state.Config.LocalOnly = localOnly
				requests := []deviceRequest{issueLocal(t, c, 0, 3), issueLocal(t, c, 1, 3)}
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
					t.Fatal(err)
				}
				offer := requestFor(c.device.pollNow(2))
				a := c.assigned(offer.Runner)
				local := *a.lease.Local
				local.Phase, local.Expires = phase, time.Now().Add(-time.Second)
				if err := a.saveLocal(&local); err != nil {
					t.Fatal(err)
				}
				if phase == localAccepted {
					if err := a.register(t.Context()); err != nil {
						t.Fatal(err)
					}
				}
				// Preserve a started runner even when an idle runner sorts before it.
				started, idle := requests[0], requests[1]
				if started.Runner < idle.Runner {
					started, idle = idle, started
				}
				if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{RunnerName: started.Runner, RunnerID: c.state.Leases[started.Runner].RunnerID}); err != nil {
					t.Fatal(err)
				}
				if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 2 {
					t.Fatal("unused offer was not retired while issued obligations stayed held", n, err)
				}
				if w.dispatched != 0 || c.state.Leases[offer.Runner] != nil || w.runners[offer.Runner] != nil || c.device.slots[2].owner != "" {
					t.Fatal("surplus offer started fallback or retained resources")
				}
				saved, err := store.load(c.state.Config)
				if err != nil {
					t.Fatal(err)
				}
				c.state = saved
				for range 2 {
					if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
						t.Fatal(err)
					}
					if !c.state.Leases[idle.Runner].Local.expired() || c.state.Leases[started.Runner].CleanupIntent || c.state.Leases[started.Runner].Local.expired() {
						t.Fatal("scale-down revoked started work or renewed surplus idle work")
					}
				}
				w.busy = true
				if auth, err := c.renewDevice(t.Context(), started); err != nil || !auth.Continue {
					t.Fatal("started runner lost authorization", auth, err)
				}
				w.busy = false
				if auth, err := c.renewDevice(t.Context(), idle); err != nil || auth.Continue {
					t.Fatal("surplus idle runner still authorized", auth, err)
				}
				if len(w.runners) != 2 || c.device.slots[idle.Slot].owner != c.state.Owner {
					t.Fatal("issued runner was deleted before destruction acknowledgement")
				}
				if err := c.completeDevice(t.Context(), idle); err != nil {
					t.Fatal(err)
				}
				if len(c.state.Leases) != 1 || c.state.Leases[started.Runner] == nil || c.device.slots[idle.Slot].owner != "" {
					t.Fatal("cleanup did not release only the retired runner")
				}
			})
		}
	}
}

func TestScaleDownDoesNotRetireAdditionalIdleWorkersOnRetry(t *testing.T) {
	for _, desired := range []int{0, 1, 2} {
		t.Run(fmt.Sprint(desired), func(t *testing.T) {
			c, w, store := concurrentFixture(t, 3)
			for slot := range 3 {
				issueLocal(t, c, slot, 3)
			}
			for range 3 {
				if n, err := c.HandleDesiredRunnerCount(t.Context(), desired); err != nil || n != 3 {
					t.Fatal("issued obligations must stay held", n, err)
				}
				saved, err := store.load(c.state.Config)
				if err != nil {
					t.Fatal(err)
				}
				c.state = saved
				authorized := 0
				for _, l := range saved.Leases {
					request := deviceRequest{DeviceID: testDevice, Owner: saved.Owner, Runner: l.Name, Slot: l.Local.Slot}
					auth, err := c.renewDevice(t.Context(), request)
					if err != nil {
						t.Fatal(err)
					}
					if auth.Continue {
						authorized++
					}
				}
				if authorized != desired || len(w.runners) != 3 || w.dispatched != 0 {
					t.Fatal("repeated scale-down retired the wrong number of workers", authorized, desired)
				}
			}
		})
	}
}

func TestPositiveScaleDownPersistsBeforeWithdrawingAuthorization(t *testing.T) {
	c, w, store := concurrentFixture(t, 2)
	first, second := issueLocal(t, c, 0, 2), issueLocal(t, c, 1, 2)
	failure := errors.New("journal unavailable")
	c.save = func(*state) error { return failure }
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, failure) || !isJournalWrite(err) {
		t.Fatal("failed retirement publication was ignored", err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil {
		t.Fatal(err)
	}
	for _, request := range []deviceRequest{first, second} {
		if saved.Leases[request.Runner].Local.expired() || c.state.Leases[request.Runner].Local.expired() || c.device.slots[request.Slot].owner != c.state.Owner {
			t.Fatal("failed publication changed authorization or released capacity")
		}
	}
	if len(w.runners) != 2 || w.dispatched != 0 {
		t.Fatal("failed publication changed runner resources")
	}
}

func TestPositiveScaleDownKeepsDispatchedFallbackInsteadOfExpiredOffer(t *testing.T) {
	c, w, store := concurrentFixture(t, 0)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	fallback := singleLease(c.state).Name
	c.device.pollNow(0)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
		t.Fatal(err)
	}
	offer := requestFor(c.device.pollNow(0))
	c.state.Leases[offer.Runner].Local.Expires = time.Now().Add(-time.Second)
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 {
		t.Fatal("surplus offer was not removed", n, err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || saved.Leases[fallback] == nil || saved.Leases[fallback].CleanupIntent || saved.Leases[offer.Runner] != nil {
		t.Fatal("scale-down changed dispatched fallback", saved, err)
	}
	if w.dispatched != 1 || c.device.slots[0].owner != "" {
		t.Fatal("surplus offer retained a worker or dispatched again")
	}
	for _, event := range w.events {
		if event == "cancel" {
			t.Fatal("aggregate demand canceled a dispatched bootstrap")
		}
	}
}

func TestPositiveScaleDownKeepsIdleWorkersBeforeOffersOrCleanupObligations(t *testing.T) {
	c, w, _ := concurrentFixture(t, 3)
	requests := []deviceRequest{issueLocal(t, c, 0, 3), issueLocal(t, c, 1, 3)}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
		t.Fatal(err)
	}
	offer := requestFor(c.device.pollNow(2))
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || n != 2 || c.state.Leases[offer.Runner] != nil {
		t.Fatal("live surplus offer was kept instead of idle issued workers", n, err)
	}
	for _, request := range requests {
		if auth, err := c.renewDevice(t.Context(), request); err != nil || !auth.Continue {
			t.Fatal("needed idle worker was retired", auth, err)
		}
	}
	if err := c.assigned(requests[0].Runner).beginCleanup(""); err != nil {
		t.Fatal(err)
	}
	w.lookupErr = &apiError{status: 503}
	for range 2 {
		if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 2 {
			t.Fatal("cleanup failure lost an obligation", n, err)
		}
		if auth, err := c.renewDevice(t.Context(), requests[1]); err != nil || !auth.Continue {
			t.Fatal("pending cleanup caused another idle worker to be retired", auth, err)
		}
	}
}

func TestPositiveScaleDownCleansUndispatchedFallbackAfterRestart(t *testing.T) {
	c, w, store := concurrentFixture(t, 1)
	request := issueLocal(t, c, 0, 1)
	if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{RunnerName: request.Runner, RunnerID: c.state.Leases[request.Runner].RunnerID}); err != nil {
		t.Fatal(err)
	}
	w.secretErr = errors.New("secret upload interrupted")
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || n != 2 || c.paused == nil {
		t.Fatal("expected a paused queue with undispatched fallback", n, err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil {
		t.Fatal(err)
	}
	c.state, c.paused, w.secretErr = saved, nil, nil
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 {
		t.Fatal("restart did not retire surplus undispatched fallback", n, err)
	}
	if w.dispatched != 0 || len(w.runners) != 1 || w.runners[request.Runner] == nil || c.state.Leases[request.Runner].CleanupIntent {
		t.Fatal("scale-down dispatched surplus work or removed the started runner")
	}
}

func TestScaleDownAllowsRenewalWhenGitHubConfirmsALateJobStart(t *testing.T) {
	c, w, _ := concurrentFixture(t, 2)
	for slot := range 2 {
		issueLocal(t, c, slot, 2)
	}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	var retired *lease
	for _, l := range c.state.Leases {
		if l.Local.expired() {
			retired = l
		}
	}
	if retired == nil {
		t.Fatal("no surplus idle runner was retired")
	}
	w.busy = true
	request := deviceRequest{DeviceID: testDevice, Owner: c.state.Owner, Runner: retired.Name, Slot: retired.Local.Slot}
	if auth, err := c.renewDevice(t.Context(), request); err != nil || !auth.Continue || !c.state.Leases[retired.Name].Local.JobStarted {
		t.Fatal("aggregate demand revoked a job GitHub confirms is running", auth, err)
	}
	if len(c.state.Leases) != 2 || len(w.runners) != 2 {
		t.Fatal("renewal released an unacknowledged runner")
	}
}
