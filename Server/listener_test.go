package main

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/google/uuid"
)

type messageStream struct {
	t        *testing.T
	world    *fakeWorld
	calls    int
	acquired []int64
	deleted  []int
	cancel   context.CancelFunc
}

func (s *messageStream) Session() scaleset.RunnerScaleSetSession {
	return scaleset.RunnerScaleSetSession{SessionID: uuid.New(), Statistics: &scaleset.RunnerScaleSetStatistic{}}
}
func (s *messageStream) AcquireJobs(_ context.Context, ids []int64) ([]int64, error) {
	s.acquired = append(s.acquired, ids...)
	return ids, nil
}
func (s *messageStream) DeleteMessage(_ context.Context, id int) error {
	s.deleted = append(s.deleted, id)
	return nil
}
func (s *messageStream) GetMessage(ctx context.Context, _, capacity int) (*scaleset.RunnerScaleSetMessage, error) {
	if capacity != maximumAssignments {
		s.t.Error("unexpected advertised capacity", capacity)
	}
	s.calls++
	switch s.calls {
	case 1:
		if s.world.dispatched != 0 {
			s.t.Error("provisioned without assigned demand")
		}
		return &scaleset.RunnerScaleSetMessage{MessageID: 1, Statistics: &scaleset.RunnerScaleSetStatistic{}, JobAvailableMessages: []*scaleset.JobAvailable{{JobMessageBase: scaleset.JobMessageBase{RunnerRequestID: 42}}}}, nil
	case 2:
		if s.world.dispatched != 0 {
			s.t.Error("individual job notification caused provisioning")
		}
		return &scaleset.RunnerScaleSetMessage{MessageID: 2, Statistics: &scaleset.RunnerScaleSetStatistic{TotalAssignedJobs: 1}}, nil
	case 3:
		if s.world.dispatched != 1 {
			s.t.Error("assigned count did not provision")
		}
		return nil, nil // Upstream long-poll timeout must still reconcile the existing bootstrap.
	case 4:
		s.world.run.Status = "completed"
		s.world.run.Conclusion = "success"
		return &scaleset.RunnerScaleSetMessage{MessageID: 3, Statistics: &scaleset.RunnerScaleSetStatistic{}}, nil
	default:
		s.cancel()
		return nil, ctx.Err()
	}
}

func TestUpstreamListenerDrivesDemandAndReconciliation(t *testing.T) {
	c, world, _ := newFixture(t)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	loop := newCoordinatorLoop(ctx, c)
	done := make(chan struct{})
	go func() {
		defer close(done)
		loop.run()
	}()
	defer func() { cancel(); <-done }()
	stream := &messageStream{t: t, world: world, cancel: cancel}
	l, err := listener.New(stream, listener.Config{ScaleSetID: 3, MaxRunners: maximumAssignments})
	if err != nil {
		t.Fatal(err)
	}
	if err := l.Run(ctx, loop); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(stream.acquired, []int64{42}) || !reflect.DeepEqual(stream.deleted, []int{1, 2, 3}) {
		t.Fatal(stream.acquired, stream.deleted)
	}
	if world.dispatched != 1 || world.runner != nil || world.secret != "" || singleLease(c.state) != nil {
		t.Fatal("listener did not complete one provisioning lifecycle")
	}
}
