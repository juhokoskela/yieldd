package main

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/google/uuid"
)

type controlledMessages struct {
	initial  int
	messages chan *scaleset.RunnerScaleSetMessage
	delete   func(context.Context) error
	acquire  func(context.Context) error
	get      func(context.Context) (*scaleset.RunnerScaleSetMessage, error)
	close    func(context.Context) error
}

func (s *controlledMessages) Session() scaleset.RunnerScaleSetSession {
	return scaleset.RunnerScaleSetSession{SessionID: uuid.New(), Statistics: &scaleset.RunnerScaleSetStatistic{TotalAssignedJobs: s.initial}}
}

func (s *controlledMessages) GetMessage(ctx context.Context, _, _ int) (*scaleset.RunnerScaleSetMessage, error) {
	if s.get != nil {
		return s.get(ctx)
	}
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case message := <-s.messages:
		return message, nil
	}
}

func (s *controlledMessages) Close(ctx context.Context) error {
	if s.close != nil {
		return s.close(ctx)
	}
	return nil
}

func (s *controlledMessages) DeleteMessage(ctx context.Context, _ int) error {
	if s.delete != nil {
		return s.delete(ctx)
	}
	return nil
}

func (s *controlledMessages) AcquireJobs(ctx context.Context, ids []int64) ([]int64, error) {
	if s.acquire != nil {
		if err := s.acquire(ctx); err != nil {
			return nil, err
		}
	}
	return ids, nil
}

func testPlatform(t *testing.T, ctx context.Context, c *coordinator, stream *controlledMessages) *platformCoordinator {
	t.Helper()
	ctx, cancel := context.WithCancel(ctx)
	messages, err := listener.New(shutdownAwareListenerClient{Client: stream, lifetime: ctx}, listener.Config{ScaleSetID: c.state.ScaleSetID, MaxRunners: maximumAssignments})
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	return &platformCoordinator{cancel: cancel, loop: newCoordinatorLoop(ctx, c), messages: messages, session: stream, scaleSetID: c.state.ScaleSetID,
		newSession: func(context.Context) (listenerSession, error) { return stream, nil }}
}

func TestListenerDetachedOperationsHonorShutdown(t *testing.T) {
	for _, operation := range []string{"delete", "acquire"} {
		t.Run(operation, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, _, _ := newFixture(t)
				ctx, cancel := context.WithCancel(t.Context())
				defer cancel()
				entered := false
				block := func(ctx context.Context) error {
					entered = true
					select {
					case <-ctx.Done():
						return ctx.Err()
					case <-time.After(59 * time.Second):
						return nil
					}
				}
				stream := &controlledMessages{messages: make(chan *scaleset.RunnerScaleSetMessage, 1)}
				if operation == "delete" {
					stream.delete = block
				} else {
					stream.acquire = block
				}
				stream.messages <- &scaleset.RunnerScaleSetMessage{MessageID: 1, Statistics: &scaleset.RunnerScaleSetStatistic{}, JobAvailableMessages: []*scaleset.JobAvailable{{JobMessageBase: scaleset.JobMessageBase{RunnerRequestID: 42}}}}
				p := testPlatform(t, ctx, c, stream)
				done := make(chan error, 1)
				go func() { done <- p.run(ctx, false) }()
				synctest.Wait()
				if !entered {
					t.Fatal("listener did not reach detached operation")
				}
				start := time.Now()
				cancel()
				if err := <-done; err != nil {
					t.Fatal(err)
				}
				if elapsed := time.Since(start); elapsed != 0 {
					t.Fatal("shutdown waited for the detached request timeout", elapsed)
				}
			})
		})
	}
}

func TestListenerRejectsOperationsAfterShutdown(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	// A nil embedded client also proves no upstream operation is attempted.
	client := shutdownAwareListenerClient{lifetime: ctx}
	if err := client.DeleteMessage(context.WithoutCancel(ctx), 1); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := client.AcquireJobs(context.WithoutCancel(ctx), []int64{42}); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestColdStartDefersHostedCleanupWhileAMacCanRenew(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 1)
		c.device.pollNow(0)
		req := issueLocal(t, c, 0, 1)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		for name, l := range c.state.Leases {
			if l.Local == nil {
				if err := c.assigned(name).beginCleanup("success"); err != nil {
					t.Fatal(err)
				}
			}
		}
		c.demandUnavailable = true
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		startLoops(t, cancel, []*coordinatorLoop{loop})
		time.Sleep(2 * cleanupRetryDelay)
		synctest.Wait()
		if err := loop.invoke(t.Context(), func(ctx context.Context) error {
			if c.fallbackCount() != 1 || c.paused != nil {
				return errors.New("hosted cleanup ran before demand")
			}
			auth, err := c.renewDevice(ctx, req)
			if err == nil && !auth.Continue {
				return errors.New("issued guest lost authorization")
			}
			return err
		}); err != nil {
			t.Fatal(err)
		}
		if n, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || w.dispatched != 1 {
			t.Fatal("first demand did not resume cleanup", n, err)
		}
	})
}

func TestColdSessionSetupDoesNotBlockIssuedDevice(t *testing.T) {
	c, world, store, req := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), req); err != nil {
		t.Fatal(err)
	}
	dir := store.root.Name()
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	p, err := openPlatformCoordinator(ctx, c.state.Config, dir, "test-token", false, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer closeCoordinators(p)
	c = p.loop.worker
	c.runners, c.bootstrap = world, world
	if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{p.loop}); err != nil {
		t.Fatal(err)
	}
	if !c.demandUnavailable {
		t.Fatal("restored offers eligible before fresh demand")
	}
	entered := make(chan struct{})
	p.newSession = func(ctx context.Context) (listenerSession, error) {
		close(entered)
		<-ctx.Done()
		return nil, ctx.Err()
	}
	done := make(chan error, 1)
	go func() { done <- p.run(ctx, false) }()
	<-entered
	if err := p.loop.invoke(ctx, func(ctx context.Context) error {
		auth, err := c.renewDevice(ctx, req)
		if err != nil {
			return err
		}
		if !auth.Continue {
			return errors.New("issued guest lost authorization")
		}
		return c.completeDevice(ctx, req)
	}); err != nil {
		t.Fatal(err)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
