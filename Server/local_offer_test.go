package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

func TestLocalExpiryUsesEachPhaseLifetime(t *testing.T) {
	for _, phase := range []struct {
		name     localPhase
		lifetime time.Duration
	}{
		{localOffered, offerLifetime},
		{localAccepted, registrationLifetime},
		{localIssued, localStartupLifetime},
	} {
		t.Run(string(phase.name), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				for _, test := range []struct {
					remaining time.Duration
					expired   bool
				}{
					{-time.Nanosecond, true}, {0, true},
					{phase.lifetime / 2, false}, {phase.lifetime, false},
					{phase.lifetime + time.Nanosecond, true},
				} {
					lease := localLease{Phase: phase.name, Expires: time.Now().Add(test.remaining)}
					if got := lease.expired(); got != test.expired {
						t.Errorf("remaining %s: expired = %v, want %v", test.remaining, got, test.expired)
					}
				}
			})
		})
	}
}

func startOfferLoop(t *testing.T, c *coordinator) (*coordinatorLoop, func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	loop := newCoordinatorLoop(ctx, c)
	done := make(chan error, 1)
	go func() { done <- loop.run() }()
	if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		cancel()
		<-done
		t.Fatal(err)
	}
	return loop, func() {
		cancel()
		if err := <-done; err != nil {
			t.Error("coordinator loop:", err)
		}
	}
}

func TestOfferTimerFallsBackWithoutAnotherDemandMessage(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _, request := localFixture(t)
		var logs bytes.Buffer
		c.logger = slog.New(slog.NewTextHandler(&logs, nil))
		loop, stop := startOfferLoop(t, c)
		defer stop()
		synctest.Wait()
		time.Sleep(4 * time.Second)
		synctest.Wait()
		if len(w.events) != 0 {
			t.Fatal("offer expired early", w.events)
		}
		// Polling refreshes availability, not the outstanding offer deadline.
		if err := loop.invoke(t.Context(), func(context.Context) error {
			c.device.pollNow(0)
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second)
		synctest.Wait()
		if w.dispatched != 1 || singleLease(c.state).Local != nil || singleLease(c.state).RunID != 99 {
			t.Fatal("timer did not dispatch hosted fallback", w.events)
		}
		err := loop.invoke(t.Context(), func(ctx context.Context) error {
			_, err := c.acceptDevice(ctx, request)
			return err
		})
		var rejected *deviceError
		if !errors.As(err, &rejected) || rejected.status != http.StatusGone {
			t.Fatal("late acceptance was not rejected", err)
		}
		time.Sleep(time.Minute)
		synctest.Wait()
		if w.dispatched != 1 {
			t.Fatal("timer dispatched twice")
		}
		if !strings.Contains(logs.String(), "Local offer expired; using hosted fallback") || !strings.Contains(logs.String(), "offer_age=5s") {
			t.Fatal("missing expiry diagnostics", logs.String())
		}
	})
}

func TestOfferAcceptedBeforeDeadlineCanRegisterAfterDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _, request := localFixture(t)
		var logs bytes.Buffer
		c.logger = slog.New(slog.NewTextHandler(&logs, nil))
		loop, stop := startOfferLoop(t, c)
		defer stop()
		synctest.Wait()
		time.Sleep(4 * time.Second)
		var registrationWindow time.Duration
		w.beforeGenerate = func() {
			registrationWindow = time.Until(singleLease(c.state).Local.Expires)
			time.Sleep(10 * time.Second)
		}
		err := loop.invoke(t.Context(), func(ctx context.Context) error {
			credential, err := c.acceptDevice(ctx, request)
			if err == nil && credential.JIT != "private-jit" {
				return errors.New("missing credential")
			}
			return err
		})
		if err != nil || registrationWindow != 30*time.Second {
			t.Fatal("acceptance lost registration budget", registrationWindow, err)
		}
		time.Sleep(time.Minute)
		synctest.Wait()
		if w.dispatched != 0 || singleLease(c.state).Local.Phase != localIssued || len(w.events) != 1 {
			t.Fatal("accepted offer also dispatched hosted fallback", w.events)
		}
		if !strings.Contains(logs.String(), "Local offer accepted") || !strings.Contains(logs.String(), "accept_latency=4s") {
			t.Fatal("missing acceptance diagnostics", logs.String())
		}
	})
}

func TestOfferTimerRetractedOrStoppedDoesNotProvision(t *testing.T) {
	for _, retract := range []bool{false, true} {
		t.Run(map[bool]string{false: "shutdown", true: "zero demand"}[retract], func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, _, _ := localFixture(t)
				loop, stop := startOfferLoop(t, c)
				synctest.Wait()
				time.Sleep(4 * time.Second)
				if retract {
					defer stop()
					if n, err := loop.HandleDesiredRunnerCount(t.Context(), 0); err != nil || n != 0 {
						t.Fatal("retraction failed", n, err)
					}
				} else {
					stop()
				}
				time.Sleep(time.Minute)
				synctest.Wait()
				if len(w.events) != 0 {
					t.Fatal("inactive offer provisioned", w.events)
				}
			})
		})
	}
}

func TestOfferTimerRestoresPersistedDeadline(t *testing.T) {
	for _, elapsed := range []time.Duration{3 * time.Second, 10 * time.Second} {
		t.Run(elapsed.String(), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, store, _ := localFixture(t)
				time.Sleep(elapsed)
				saved, err := store.load(c.state.Config)
				if err != nil {
					t.Fatal(err)
				}
				c.state = saved
				loop, stop := startOfferLoop(t, c)
				defer stop()
				synctest.Wait()
				if elapsed < 5*time.Second {
					if err := loop.invoke(t.Context(), func(context.Context) error {
						if w.dispatched != 0 {
							return errors.New("restored offer expired early")
						}
						return nil
					}); err != nil {
						t.Fatal(err)
					}
					time.Sleep(5*time.Second - elapsed)
					synctest.Wait()
				}
				if w.dispatched != 1 {
					t.Fatal("restored offer did not expire")
				}
			})
		})
	}
}

func TestOfferTimerFailureStopsWithDurableRecoveryState(t *testing.T) {
	for _, phase := range []string{"save", "register", "dispatch"} {
		t.Run(phase, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, store, _ := localFixture(t)
				switch phase {
				case "save":
					c.save = func(*state) error { return io.ErrUnexpectedEOF }
				case "register":
					w.generateErr = io.ErrUnexpectedEOF
				case "dispatch":
					w.dispatchErr = io.ErrUnexpectedEOF
				}
				ctx, cancel := context.WithCancel(t.Context())
				defer cancel()
				loop := newCoordinatorLoop(ctx, c)
				done := make(chan error, 1)
				go func() { done <- loop.run() }()
				if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
					t.Fatal(err)
				}
				err := <-done
				var provisioning *provisioningError
				if !errors.As(err, &provisioning) || !errors.Is(err, io.ErrUnexpectedEOF) {
					t.Fatal("lost timer failure", err)
				}
				saved, err := store.load(c.state.Config)
				if err != nil || singleLease(saved) == nil {
					t.Fatal("lost recovery state", err)
				}
				if phase == "save" && (singleLease(saved).Local == nil || singleLease(c.state).Local == nil || len(w.events) != 0) {
					t.Fatal("failed transition mutated local offer")
				}
				if phase == "dispatch" && !singleLease(saved).DispatchIntent {
					t.Fatal("lost ambiguous dispatch intent")
				}
			})
		})
	}
}

func TestRestoredOfferWaitsForDemandBeforeFallback(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _, _ := localFixture(t)
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		done := make(chan error, 1)
		go func() { done <- loop.run() }()
		defer func() {
			cancel()
			if err := <-done; err != nil {
				t.Error(err)
			}
		}()
		time.Sleep(time.Minute)
		synctest.Wait()
		if len(w.events) != 0 {
			t.Fatal("restored offer provisioned without confirming demand", w.events)
		}
		if n, err := loop.HandleDesiredRunnerCount(t.Context(), 0); err != nil || n != 0 {
			t.Fatal("could not retract expired offer", n, err)
		}
		time.Sleep(time.Minute)
		synctest.Wait()
		if singleLease(c.state) != nil || len(w.events) != 0 {
			t.Fatal("retracted offer provisioned", w.events)
		}
	})
}

func TestRestoredLocalCleanupDoesNotWaitForDemand(t *testing.T) {
	for _, phase := range []string{"accepted", "cleanup"} {
		t.Run(phase, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, world, store, request := localFixture(t)
				delay := cleanupRetryDelay
				if phase == "accepted" {
					world.generateErr = context.DeadlineExceeded
					if _, err := c.acceptDevice(t.Context(), request); err == nil {
						t.Fatal("registration did not fail")
					}
					delay = registrationLifetime
				} else {
					if _, err := c.acceptDevice(t.Context(), request); err != nil {
						t.Fatal(err)
					}
					c.bootstrap = cleanupTimeout{world}
					if err := c.completeDevice(t.Context(), request); err == nil {
						t.Fatal("cleanup did not fail")
					}
				}
				saved, err := store.load(c.state.Config)
				if err != nil {
					t.Fatal(err)
				}
				c.state, c.bootstrap = saved, world
				ctx, cancel := context.WithCancel(t.Context())
				loop := newCoordinatorLoop(ctx, c)
				startLoops(t, cancel, []*coordinatorLoop{loop})
				synctest.Wait()
				time.Sleep(delay)
				synctest.Wait()
				if singleLease(c.state) != nil || c.device.slots[0].owner != "" || world.runner != nil || world.dispatched != 0 {
					t.Fatal("restored cleanup waited for demand or provisioned a replacement")
				}
			})
		})
	}
}

func TestOfferTimerUsesReplacementOfferDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _, _ := localFixture(t)
		loop, stop := startOfferLoop(t, c)
		defer stop()
		time.Sleep(4 * time.Second)
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 0); err != nil {
			t.Fatal(err)
		}
		if err := loop.invoke(t.Context(), func(context.Context) error {
			c.device.pollNow(0)
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second)
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if len(w.events) != 0 {
				return errors.New("previous timer expired the new offer")
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(4 * time.Second)
		synctest.Wait()
		if w.dispatched != 1 {
			t.Fatal("replacement offer did not expire")
		}
	})
}

func TestOfferAndAvailabilityHaveSeparateLifetimes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := newFixture(t)
		c.state.Config.DeviceID = testDevice
		c.device.pollNow(0)
		time.Sleep(21 * time.Second)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		if singleLease(c.state).Local == nil || len(w.events) != 0 || time.Until(singleLease(c.state).Local.Expires) != 5*time.Second {
			t.Fatal("availability expired with the shorter acceptance deadline")
		}
	})
}
