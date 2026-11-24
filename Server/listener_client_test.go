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
	loop := newCoordinatorLoop(ctx, c)
	messages, err := listener.New(shutdownAwareListenerClient{Client: stream, lifetime: ctx, loop: loop}, listener.Config{ScaleSetID: c.state.ScaleSetID, MaxRunners: maximumAssignments})
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	return &platformCoordinator{cancel: cancel, loop: loop, messages: messages, session: stream, scaleSetID: c.state.ScaleSetID,
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

func TestOpeningQueueRetractsUnacceptedOfferBeforeRestoringCapacity(t *testing.T) {
	c, _, store, req := localFixture(t)
	path := store.root.Name()
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	p, err := openPlatformCoordinator(t.Context(), c.state.Config, path, "unused", false, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer closeCoordinators(p)
	saved, err := p.store.read()
	if err != nil || saved.Leases[req.Runner] != nil {
		t.Fatal("old offer held a slot", err)
	}
}

func TestUncertainFirstScaleSetIDStopsQueueBeforeOpeningSession(t *testing.T) {
	c, _, store := newFixture(t)
	c.state.ScaleSetID = 0
	if err := store.save(c.state); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	p := &platformCoordinator{loop: newCoordinatorLoop(ctx, c)}
	failure := errors.New("directory sync failed after publication")
	c.save = func(s *state) error {
		if err := store.save(s); err != nil {
			return err
		}
		return failure
	}
	stopped := make(chan error, 1)
	go func() { stopped <- p.loop.run() }()
	if err := p.recordScaleSetID(ctx, 42); !isJournalWrite(err) || !errors.Is(err, failure) {
		t.Fatal(err)
	}
	select {
	case err := <-stopped:
		if !errors.Is(err, failure) {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("queue stayed up after uncertain publication")
	}
	saved, err := store.load(c.state.Config)
	if err != nil || saved.ScaleSetID != 42 || c.state.ScaleSetID != 0 {
		t.Fatal(saved, err)
	}
}

func TestEC2CompletionSurvivesFailedJournalBeforeAcknowledgement(t *testing.T) {
	c, _, store := newFixture(t)
	c.state.Config.EC2 = exampleEC2()
	c.fleet = &fakeFleet{instance: ec2Host{id: "i-1", state: "running"}}
	l := &lease{Name: fixtureRunner, Created: time.Now(), RunnerID: 7, DispatchIntent: true, EC2: &ec2Lease{Instance: "i-1", Issuing: true}}
	if err := c.assigned(l.Name).replace(l); err != nil {
		t.Fatal(err)
	}
	job := &scaleset.JobCompleted{RunnerName: l.Name, RunnerID: 7, Result: "success", JobMessageBase: scaleset.JobMessageBase{OwnerName: "example", RepositoryName: "application", JobDisplayName: "build", JobWorkflowRef: "Example/application/.github/workflows/ci.yml@refs/heads/main", WorkflowRunID: 23, EventName: "push"}}
	msg := &scaleset.RunnerScaleSetMessage{MessageID: 1, Statistics: &scaleset.RunnerScaleSetStatistic{}, JobCompletedMessages: []*scaleset.JobCompleted{job}}
	for _, failWrite := range []bool{true, false} {
		saved, err := store.read()
		if err != nil {
			t.Fatal(err)
		}
		c.state = saved
		c.save = store.save
		if failWrite {
			c.save = func(*state) error { return errors.New("journal unavailable") }
		}
		ctx, cancel := context.WithCancel(t.Context())
		acknowledged := false
		stream := &controlledMessages{messages: make(chan *scaleset.RunnerScaleSetMessage, 1), delete: func(context.Context) error {
			acknowledged = true
			saved, err := store.read()
			if err != nil || !saved.Leases[l.Name].EC2.Completed || saved.Leases[l.Name].EC2.ProducerRun != 23 {
				t.Fatal("acknowledged before persistence", err)
			}
			cancel()
			return context.Canceled
		}}
		stream.messages <- msg
		p := testPlatform(t, ctx, c, stream)
		done := make(chan error, 1)
		go func() { done <- p.loop.run() }()
		err = p.messages.Run(ctx, p.loop)
		cancel()
		<-done
		p.cancel()
		if failWrite != isJournalWrite(err) || acknowledged == failWrite {
			t.Fatal("incorrect acknowledgement after write", failWrite, acknowledged, err)
		}
	}
}
