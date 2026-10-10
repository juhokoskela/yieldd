package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/actions/scaleset"
)

func TestListenerOutageSuspendsProvisioningUntilFreshDemand(t *testing.T) {
	for _, demand := range []int{0, 1} {
		t.Run(fmt.Sprintf("fresh-demand-%d", demand), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, _, request := localFixture(t)
				ctx, cancel := context.WithCancel(t.Context())
				broken := &controlledMessages{initial: 1, get: func(context.Context) (*scaleset.RunnerScaleSetMessage, error) {
					return nil, errors.New("listener unavailable")
				}}
				p := testPlatform(t, ctx, c, broken)
				if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{p.loop}); err != nil {
					t.Fatal(err)
				}
				var opened atomic.Int64
				p.newSession = func(context.Context) (listenerSession, error) {
					if opened.Add(1) == 1 {
						return nil, context.DeadlineExceeded
					}
					return &controlledMessages{initial: demand}, nil
				}
				done := make(chan error, 1)
				go func() { done <- p.run(ctx, false) }()
				defer func() { cancel(); <-done }()
				synctest.Wait()
				time.Sleep(listenerRetryDelay)
				synctest.Wait()
				if err := p.loop.invoke(t.Context(), func(context.Context) error {
					if len(c.state.Leases) != 0 || w.dispatched != 0 || w.runner != nil {
						return fmt.Errorf("expired offer provisioned from disconnected demand: %v", w.events)
					}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
				if err := p.loop.invoke(t.Context(), func(context.Context) error { c.device.pollNow(0); return nil }); err != nil {
					t.Fatal(err)
				}
				synctest.Wait()
				if err := p.loop.invoke(t.Context(), func(context.Context) error {
					if len(c.state.Leases) != 0 || w.dispatched != 0 {
						return fmt.Errorf("advertised capacity redrove disconnected demand: %v", w.events)
					}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
				time.Sleep(listenerRetryDelay * 2)
				synctest.Wait()
				if err := p.loop.invoke(t.Context(), func(context.Context) error {
					if opened.Load() != 2 || len(c.state.Leases) != demand || w.dispatched != 0 {
						return fmt.Errorf("reconnect did not use fresh demand: %d, %d, %v", opened.Load(), len(c.state.Leases), w.events)
					}
					if demand > 0 && singleLease(c.state).Name == request.Runner {
						return errors.New("reconnect reused the retired offer")
					}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
			})
		})
	}
}

func TestListenerOutageRejectsUnissuedAcceptance(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _, request := localFixture(t)
		ctx, cancel := context.WithCancel(t.Context())
		p := testPlatform(t, ctx, c, &controlledMessages{initial: 1, get: func(context.Context) (*scaleset.RunnerScaleSetMessage, error) {
			return nil, errors.New("listener unavailable")
		}})
		done := make(chan error, 1)
		go func() { done <- p.run(ctx, false) }()
		defer func() { cancel(); <-done }()
		synctest.Wait()
		if err := p.loop.invoke(t.Context(), func(ctx context.Context) error {
			credential, err := c.acceptDevice(ctx, request)
			var rejection *deviceError
			if credential != nil || !errors.As(err, &rejection) || rejection.status != http.StatusGone || w.runner != nil {
				return fmt.Errorf("outage allowed credential issuance: %v, %v", credential, err)
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	})
}

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
		if err := p.loop.invoke(t.Context(), func(ctx context.Context) error {
			authorization, err := c.renewDevice(ctx, request)
			if err != nil || !authorization.Continue {
				return fmt.Errorf("renewal unavailable during reconnect: %v, %v", authorization, err)
			}
			return c.completeDevice(ctx, request)
		}); err != nil {
			t.Fatal("device cleanup unavailable during reconnect", err)
		}
		time.Sleep(listenerRetryDelay)
		synctest.Wait()
		if opened.Load() != 1 || closed.Load() != 1 {
			t.Fatal("first reconnect did not respect backoff", opened.Load(), closed.Load())
		}
		time.Sleep(listenerRetryDelay * 2)
		synctest.Wait()
		if opened.Load() != 2 || closed.Load() != 1 || singleLease(c.state) != nil || w.dispatched != 0 {
			t.Fatal("reconnect replayed credentials or provisioned from stale demand", opened.Load(), w.events)
		}
		cancel()
		if err := <-done; err != nil {
			t.Fatal("shutdown did not stop reconnected listener", err)
		}
	})
}

func TestListenerReconnectBackoffCapsAndResetsAfterAHealthySession(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, _, _ := newFixture(t)
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		failure := errors.New("listener unavailable")
		broken := &controlledMessages{get: func(context.Context) (*scaleset.RunnerScaleSetMessage, error) { return nil, failure }}
		p := testPlatform(t, ctx, c, broken)
		opened := make(chan time.Time, 8)
		attempt := 0
		p.newSession = func(context.Context) (listenerSession, error) {
			attempt++
			opened <- time.Now()
			if attempt == 6 {
				return &controlledMessages{get: func(context.Context) (*scaleset.RunnerScaleSetMessage, error) {
					time.Sleep(time.Minute + time.Second)
					return nil, failure
				}}, nil
			}
			return broken, nil
		}
		done := make(chan error, 1)
		go func() { done <- p.run(ctx, false) }()
		synctest.Wait()
		last := time.Now()
		for _, delay := range []time.Duration{5 * time.Second, 10 * time.Second, 20 * time.Second, 40 * time.Second, time.Minute, time.Minute} {
			time.Sleep(delay)
			synctest.Wait()
			select {
			case now := <-opened:
				if now.Sub(last) != delay {
					t.Fatal("incorrect reconnect delay", now.Sub(last), delay)
				}
				last = now
			default:
				t.Fatal("reconnect missed its capped deadline", delay)
			}
		}
		time.Sleep(time.Minute + time.Second)
		synctest.Wait()
		time.Sleep(listenerRetryDelay)
		synctest.Wait()
		select {
		case now := <-opened:
			if now.Sub(last) != time.Minute+time.Second+listenerRetryDelay {
				t.Fatal("healthy session did not reset backoff", now.Sub(last))
			}
		default:
			t.Fatal("healthy session retained maximum backoff")
		}
		cancel()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	})
}

func TestListenerCallbackFailureWinsOverConcurrentShutdown(t *testing.T) {
	c, _, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	failure := errors.New("journal write failed during shutdown")
	c.save = func(*state) error { cancel(); return failure }
	stream := &controlledMessages{initial: 1, messages: make(chan *scaleset.RunnerScaleSetMessage, 1)}
	stream.messages <- &scaleset.RunnerScaleSetMessage{MessageID: 1,
		Statistics:         &scaleset.RunnerScaleSetStatistic{TotalAssignedJobs: 1},
		JobStartedMessages: []*scaleset.JobStarted{{RunnerName: request.Runner, RunnerID: singleLease(c.state).RunnerID}},
	}
	if err := testPlatform(t, ctx, c, stream).run(ctx, false); !errors.Is(err, failure) {
		t.Fatal("shutdown hid callback failure", err)
	}
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
