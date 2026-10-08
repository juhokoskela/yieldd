package main

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/actions/scaleset"
)

func TestListenerReconnectKeepsIssuedAssignmentsAndDeviceCleanupAvailable(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _, request := localFixture(t)
		if _, err := c.acceptDevice(t.Context(), request); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		var closed, opened atomic.Int64
		broken := &controlledMessages{initial: 1, get: func(context.Context) (*scaleset.RunnerScaleSetMessage, error) {
			return nil, errors.New("private SDK response")
		}, close: func(context.Context) error { closed.Add(1); return nil }}
		p := testPlatform(t, ctx, c, broken)
		p.newSession = func(context.Context) (listenerSession, error) {
			if opened.Add(1) == 1 {
				return nil, context.DeadlineExceeded
			}
			return &controlledMessages{}, nil // Fresh demand is zero, not the old session's count.
		}
		done := make(chan error, 1)
		go func() { done <- p.run(ctx, false) }()
		synctest.Wait()
		if opened.Load() != 0 || singleLease(c.state) == nil || c.device.slots[request.Slot].owner == "" {
			t.Fatal("listener failure discarded issued capacity or skipped backoff")
		}
		if err := p.loop.invoke(t.Context(), func(ctx context.Context) error { return c.completeDevice(ctx, request) }); err != nil {
			t.Fatal("device cleanup unavailable during reconnect", err)
		}
		time.Sleep(listenerRetryDelay)
		synctest.Wait()
		if opened.Load() != 1 || closed.Load() != 1 {
			t.Fatal("first reconnect did not respect backoff", opened.Load(), closed.Load())
		}
		time.Sleep(listenerRetryDelay * 2)
		synctest.Wait()
		if opened.Load() != 2 || singleLease(c.state) != nil || w.dispatched != 0 {
			t.Fatal("reconnect replayed credentials or provisioned from stale demand", opened.Load(), w.events)
		}
		cancel()
		if err := <-done; err != nil {
			t.Fatal("shutdown did not stop reconnected listener", err)
		}
	})
}

func TestListenerReconnectBackoffStopsImmediatelyOnShutdown(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, _, _ := newFixture(t)
		ctx, cancel := context.WithCancel(t.Context())
		p := testPlatform(t, ctx, c, &controlledMessages{get: func(context.Context) (*scaleset.RunnerScaleSetMessage, error) {
			return nil, context.DeadlineExceeded
		}})
		p.newSession = func(context.Context) (listenerSession, error) {
			t.Error("reconnected after shutdown")
			return &controlledMessages{}, nil
		}
		done := make(chan error, 1)
		go func() { done <- p.run(ctx, false) }()
		synctest.Wait()
		start := time.Now()
		cancel()
		if err := <-done; err != nil || time.Since(start) != 0 {
			t.Fatal("shutdown waited for reconnect delay", err)
		}
	})
}
