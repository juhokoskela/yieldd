package main

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"testing/synctest"
	"time"

	"github.com/actions/scaleset"
)

func TestAssignmentTransitionsPreserveIdentityAndPersistedIntent(t *testing.T) {
	for _, change := range []struct {
		name string
		edit func(*lease)
	}{
		{"runner name", func(l *lease) { l.Name += "-other" }},
		{"creation time", func(l *lease) { l.Created = l.Created.Add(time.Second) }},
		{"runner ID", func(l *lease) { l.RunnerID++ }},
		{"workflow ID", func(l *lease) { l.RunID++ }},
		{"dispatch intent", func(l *lease) { l.DispatchIntent = false }},
		{"hosted to local", func(l *lease) { l.Local = &localLease{Phase: localOffered} }},
	} {
		t.Run(change.name, func(t *testing.T) {
			c, _, store := newFixture(t)
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
			original := singleLease(c.state)
			next := *original
			change.edit(&next)
			if err := c.assigned(original.Name).replace(&next); err == nil {
				t.Fatal("invalid transition was committed")
			}
			saved, err := store.load(c.state.Config)
			if err != nil || *singleLease(saved) != *original || singleLease(c.state) != original {
				t.Fatal("failed transition changed durable or in-memory state", err)
			}
		})
	}
}

func TestLocalTransitionsCannotReopenExecutionOrReleaseUnacknowledgedCapacity(t *testing.T) {
	for _, change := range []struct {
		name string
		edit func(*lease)
	}{
		{"slot", func(l *lease) { l.Local.Slot++ }},
		{"device", func(l *lease) { l.Local.DeviceID = "other" }},
		{"phase", func(l *lease) { l.Local.Phase = localOffered }},
		{"job started", func(l *lease) { l.Local.JobStarted = false }},
		{"job completed", func(l *lease) { l.Local.JobCompleted = false }},
		{"issued to hosted", func(l *lease) { l.Local = nil }},
	} {
		t.Run(change.name, func(t *testing.T) {
			c, _, store, request := localFixture(t)
			if _, err := c.acceptDevice(t.Context(), request); err != nil {
				t.Fatal(err)
			}
			if err := c.assigned(request.Runner).recordLocalJob(singleLease(c.state).RunnerID, new("Succeeded")); err != nil {
				t.Fatal(err)
			}
			original := singleLease(c.state)
			next, local := *original, *original.Local
			next.Local = &local
			change.edit(&next)
			if err := c.assigned(request.Runner).replace(&next); err == nil {
				t.Fatal("local execution was reopened or moved")
			}
			saved, err := store.load(c.state.Config)
			if err != nil || *singleLease(saved).Local != *original.Local || singleLease(c.state) != original {
				t.Fatal("invalid local transition changed the journal", err)
			}
		})
	}
}

func TestCleanupIntentIsRequiredBeforeAnyDeletionAndCannotBeRevoked(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	a := c.assigned(singleLease(c.state).Name)
	if err := a.cleanup(t.Context()); err == nil || w.runner == nil || w.secret == "" {
		t.Fatal("cleanup deleted resources without durable intent", err)
	}
	if err := a.beginCleanup("success"); err != nil {
		t.Fatal(err)
	}
	next := *a.lease
	next.CleanupIntent = false
	if err := a.replace(&next); err == nil {
		t.Fatal("persisted cleanup intent was revoked")
	}
	if !singleLease(c.state).CleanupIntent {
		t.Fatal("cleanup intent was lost")
	}
}

func TestOldCallbacksCannotChangeAReusedWorkerSlot(t *testing.T) {
	c, w, _, old := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), old); err != nil {
		t.Fatal(err)
	}
	oldID := singleLease(c.state).RunnerID
	if err := c.completeDevice(t.Context(), old); err != nil {
		t.Fatal(err)
	}
	w.assignedJobs = 1
	c.device.pollNow(old.Slot)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	current := singleLease(c.state)
	if current.Name == old.Runner {
		t.Fatal("worker slot reused an assignment identity")
	}
	if err := c.HandleJobCompleted(t.Context(), &scaleset.JobCompleted{RunnerName: old.Runner, RunnerID: oldID}); err != nil {
		t.Fatal(err)
	}
	if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{RunnerName: old.Runner, RunnerID: oldID}); err != nil {
		t.Fatal(err)
	}
	if err := c.completeDevice(t.Context(), old); err != nil {
		t.Fatal("old completion is not idempotent", err)
	}
	if err := c.declineDevice(old); err != nil {
		t.Fatal(err)
	}
	if _, err := c.acceptDevice(t.Context(), old); err == nil {
		t.Fatal("old offer issued new credentials")
	}
	if singleLease(c.state) != current || current.Local.Phase != localOffered || current.Local.JobStarted {
		t.Fatal("late callback changed the new assignment")
	}
}

func TestOfferAcceptanceDeclineAndExpiryInterleavings(t *testing.T) {
	for _, events := range [][]string{
		{"accept", "decline", "expire"}, {"accept", "expire", "decline"},
		{"decline", "accept", "expire"}, {"decline", "expire", "accept"},
		{"expire", "accept", "decline"}, {"expire", "decline", "accept"},
	} {
		t.Run(events[0]+"-"+events[1]+"-"+events[2], func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, _, request := localFixture(t)
				ctx, cancel := context.WithCancel(t.Context())
				loop := newCoordinatorLoop(ctx, c)
				startLoops(t, cancel, []*coordinatorLoop{loop})
				accepted := false
				for _, event := range events {
					if event == "expire" {
						time.Sleep(offerLifetime + time.Second)
						if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
							t.Fatal(err)
						}
						continue
					}
					if err := loop.invoke(t.Context(), func(ctx context.Context) error {
						var err error
						if event == "accept" {
							_, err = c.acceptDevice(ctx, request)
							accepted = err == nil
						} else {
							err = c.declineDevice(request)
						}
						var rejection *deviceError
						if errors.As(err, &rejection) && (rejection.status == http.StatusGone || rejection.status == http.StatusConflict) {
							return nil
						}
						return err
					}); err != nil {
						t.Fatal(err)
					}
				}
				synctest.Wait()
				if accepted != (events[0] == "accept") || (accepted && w.dispatched != 0) || (!accepted && w.dispatched != 1) {
					t.Fatal("offer was consumed twice or neither path made progress", accepted, w.events)
				}
			})
		})
	}
}

func TestCompletionBeforeStartCannotMoveJobProgressBackwards(t *testing.T) {
	c, _, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	l := singleLease(c.state)
	if err := c.HandleJobCompleted(t.Context(), &scaleset.JobCompleted{RunnerName: l.Name, RunnerID: l.RunnerID}); err != nil {
		t.Fatal(err)
	}
	if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{RunnerName: l.Name, RunnerID: l.RunnerID}); err != nil {
		t.Fatal(err)
	}
	if !singleLease(c.state).Local.JobStarted || !singleLease(c.state).Local.JobCompleted {
		t.Fatal("late start reopened completed execution")
	}
}
