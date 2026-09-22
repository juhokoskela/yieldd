package main

import (
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func TestLocalAuthorizationRequiresIssuedIdentity(t *testing.T) {
	c, w, _, request := localFixture(t)
	check := func(want bool) {
		t.Helper()
		value, err := c.renewDevice(t.Context(), request)
		if err != nil || value.Continue != want {
			t.Fatalf("renew: %v %v", value, err)
		}
	}
	check(false)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	check(true)
	wrong := request
	wrong.Owner = "other"
	if _, err := c.renewDevice(t.Context(), wrong); err == nil {
		t.Fatal("wrong identity renewed")
	}
	singleLease(c.state).Local.Expires = time.Now().Add(-time.Second)
	check(false)
	w.busy = true
	check(true)
	w.busy = false
	_, err := c.renewDevice(t.Context(), request)
	var deviceErr *deviceError
	if !errors.As(err, &deviceErr) || deviceErr.status != http.StatusServiceUnavailable {
		t.Fatalf("idle runner renewed: %v", err)
	}
	if count, err := c.HandleDesiredRunnerCount(t.Context(), 1); count != 1 || err != nil || w.dispatched != 0 {
		t.Fatal("withholding authorization must not permit duplicate execution", count, err)
	}
}

func TestLocalCompletionRevokesDurablyAndLateStartCannotRenew(t *testing.T) {
	c, w, store, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	id := singleLease(c.state).RunnerID
	if err := c.HandleJobCompleted(t.Context(), &scaleset.JobCompleted{RunnerName: request.Runner, RunnerID: id}); err != nil {
		t.Fatal(err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil {
		t.Fatal(err)
	}
	c.state = saved
	w.busy = true
	if err := c.HandleJobStarted(t.Context(), &scaleset.JobStarted{RunnerName: request.Runner, RunnerID: id}); err != nil {
		t.Fatal(err)
	}
	authorization, err := c.renewDevice(t.Context(), request)
	if err != nil || authorization.Continue {
		t.Fatal("completed job renewed", err)
	}
	if count, err := c.HandleDesiredRunnerCount(t.Context(), 1); count != 1 || err != nil || w.dispatched != 0 {
		t.Fatal("completion bypassed guest destruction acknowledgement", count, err)
	}
}

func TestLocalAuthorizationProgressRequiresMatchingRunnerAndDurableSave(t *testing.T) {
	c, w, store, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	for _, job := range []*scaleset.JobCompleted{
		{RunnerName: "another", RunnerID: singleLease(c.state).RunnerID},
		{RunnerName: request.Runner, RunnerID: singleLease(c.state).RunnerID + 1},
	} {
		if err := c.HandleJobCompleted(t.Context(), job); err != nil {
			t.Fatal(err)
		}
	}
	if singleLease(c.state).Local.JobStarted || singleLease(c.state).Local.JobCompleted {
		t.Fatal("unrelated job changed authorization")
	}
	w.busy = true
	c.save = func(*state) error { return errors.New("disk failure") }
	if _, err := c.renewDevice(t.Context(), request); err == nil {
		t.Fatal("granted authorization after failed save")
	}
	if singleLease(c.state).Local.JobStarted {
		t.Fatal("mutated before saving")
	}
	c.save = store.save
	if err := c.assigned(singleLease(c.state).Name).beginCleanup(""); err != nil {
		t.Fatal(err)
	}
	authorization, err := c.renewDevice(t.Context(), request)
	if err != nil || authorization.Continue {
		t.Fatal("cleanup renewed", err)
	}
}
