package main

import (
	"context"
	"errors"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/actions/scaleset"
)

type interruptedCleanup struct {
	*fakeWorld
	started chan struct{}
}

func TestFailedQueueAndItsRestartLeaveSiblingServing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		failed, broken, store := newFixture(t)
		healthy, world, _ := newFixture(t)
		healthy.state.Config.Repository = "example/healthy"
		broken.generateErr = context.DeadlineExceeded
		bad := testPlatform(t, ctx, failed, &controlledMessages{initial: 1})
		good := testPlatform(t, ctx, healthy, &controlledMessages{})
		if _, err := newDeviceRouter("", []*coordinatorLoop{bad.loop, good.loop}); err != nil {
			t.Fatal(err)
		}
		results := make(chan error, 2)
		failedResult := make(chan error, 1)
		go func() {
			err := bad.run(ctx, false)
			failedResult <- err
			results <- err
		}()
		go func() { results <- good.run(ctx, false) }()
		allDone := make(chan error, 1)
		go func() { allDone <- waitForCoordinators(results, 2, false) }()
		if err := <-failedResult; !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("registration failure lost", err)
		}
		synctest.Wait()
		select {
		case err := <-allDone:
			t.Fatal("healthy sibling stopped", err)
		default:
		}
		saved, err := store.load(failed.state.Config)
		if err != nil || singleLease(saved) == nil || singleLease(saved).RunnerID != 0 {
			t.Fatal("uncertain registration journal lost", saved, err)
		}
		failed.state = saved
		broken.generateErr = nil
		restarted := testPlatform(t, ctx, failed, &controlledMessages{initial: 1})
		if err := restarted.run(ctx, false); err == nil || !strings.Contains(err.Error(), "run with --recover") {
			t.Fatal("uncertain registration was replayed", err)
		}
		if n, err := good.loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || world.dispatched != 1 {
			t.Fatal("sibling cannot provision after failure and restart", n, err)
		}
		if err := good.loop.invoke(t.Context(), func(context.Context) error {
			world.run.Status, world.run.Conclusion = "completed", "success"
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		if n, err := good.loop.HandleDesiredRunnerCount(t.Context(), 0); err != nil || n != 0 {
			t.Fatal("sibling cannot clean up", n, err)
		}
		cancel()
		if err := <-allDone; !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("original queue failure not reported at shutdown", err)
		}
	})
}

func TestFailedQueueLeavesFIFOButRetainsIssuedReservation(t *testing.T) {
	c, _, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	c.device.wait(c.state.Owner)
	failure := errors.New("journal unavailable")
	c.save = func(*state) error { return failure }
	stream := &controlledMessages{initial: 1, messages: make(chan *scaleset.RunnerScaleSetMessage, 1)}
	stream.messages <- &scaleset.RunnerScaleSetMessage{
		MessageID: 1, Statistics: &scaleset.RunnerScaleSetStatistic{TotalAssignedJobs: 1},
		JobStartedMessages: []*scaleset.JobStarted{{RunnerName: request.Runner, RunnerID: singleLease(c.state).RunnerID}},
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	p := testPlatform(t, ctx, c, stream)
	if err := p.run(ctx, false); !errors.Is(err, failure) {
		t.Fatal("journal failure not surfaced", err)
	}
	if len(c.device.waiting) != 0 || c.device.slots[0].owner != c.state.Owner || singleLease(c.state) == nil {
		t.Fatal("failed worker lost its reservation or retained a waiting entry")
	}
}

func (f *interruptedCleanup) deleteSecret(ctx context.Context, _ string) error {
	close(f.started)
	<-ctx.Done()
	return ctx.Err()
}

func TestInterruptedRecoveryReturnsFailureWithLeaseRetained(t *testing.T) {
	c, world, store := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	world.run.Status = "completed"
	cleanup := &interruptedCleanup{fakeWorld: world, started: make(chan struct{})}
	c.bootstrap = cleanup
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	worker := &platformCoordinator{loop: newCoordinatorLoop(ctx, c)}
	results := make(chan error, 1)
	go func() { results <- worker.run(ctx, true) }()
	select {
	case <-cleanup.started:
	case <-ctx.Done():
		t.Fatal("recovery did not reach cleanup", ctx.Err())
	}
	cancel()
	if err := waitForCoordinators(results, 1, true); !errors.Is(err, context.Canceled) {
		t.Fatal("interrupted recovery reported success", err)
	}
	saved, err := store.load(testConfig)
	if err != nil || singleLease(saved) == nil || !singleLease(saved).CleanupIntent {
		t.Fatal("cleanup obligation lost", saved, err)
	}
}

func TestCoordinatorShutdownIgnoresOnlyCancellationOutsideRecovery(t *testing.T) {
	failure := errors.New("cleanup failed")
	for _, recoverOnly := range []bool{false, true} {
		results := make(chan error, 3)
		results <- context.Canceled
		results <- context.DeadlineExceeded
		results <- failure
		err := waitForCoordinators(results, 3, recoverOnly)
		if !errors.Is(err, failure) || errors.Is(err, context.Canceled) != recoverOnly || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("incorrect shutdown result", recoverOnly, err)
		}
	}
}

func TestTargetedRecoveryLeavesOtherQueueAlone(t *testing.T) {
	first, _, _, req := localFixture(t)
	sibling, world, _ := multipleFallbackFixture(t, 1)
	sibling.device.pollNow(0)
	if _, err := sibling.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	other := requestFor(sibling.device.pollNow(0))
	// A second lease in the selected queue must never enter reconciliation.
	name := "yieldd-bootstrap-00000000-0000-0000-0000-000000000001"
	healthy := &assignment{coordinator: sibling}
	if err := healthy.replace(&lease{Name: name, Created: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	if err := healthy.register(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err := healthy.prepare(t.Context()); err != nil {
		t.Fatal(err)
	}
	sibling.state.Config.Repository = "example/yieldd-bootstrap-sibling"
	workers := []*platformCoordinator{{loop: newCoordinatorLoop(t.Context(), first)}, {loop: newCoordinatorLoop(t.Context(), sibling)}}
	for _, target := range []string{"", "wrong/queue/linux/" + req.Runner, sibling.state.Config.Repository + "/linux/" + req.Runner} {
		if err := recoverAssignment(t.Context(), workers, target); err == nil {
			t.Fatalf("accepted %q", target)
		}
	}
	if err := recoverAssignment(t.Context(), workers, sibling.state.Config.Repository+"/linux/"+other.Runner); err != nil {
		t.Fatal(err)
	}
	if sibling.assigned(other.Runner).lease != nil || first.assigned(req.Runner).lease == nil || sibling.assigned(name).lease == nil || world.getCalls != 0 {
		t.Fatal("wrong recovery scope")
	}
}
