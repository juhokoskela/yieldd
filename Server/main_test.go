package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

type interruptedCleanup struct {
	*fakeWorld
	started chan struct{}
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
	if err := waitForCoordinators(results, 1, true, cancel); !errors.Is(err, context.Canceled) {
		t.Fatal("interrupted recovery reported success", err)
	}
	saved, err := store.load(testConfig)
	if err != nil || saved.Lease == nil || !saved.Lease.CleanupIntent {
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
		stops := 0
		err := waitForCoordinators(results, 3, recoverOnly, func() { stops++ })
		if !errors.Is(err, failure) || errors.Is(err, context.Canceled) != recoverOnly || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("incorrect shutdown result", recoverOnly, err)
		}
		if (recoverOnly && stops != 0) || (!recoverOnly && stops != 3) {
			t.Fatal("incorrect sibling shutdown policy", recoverOnly, stops)
		}
	}
}
