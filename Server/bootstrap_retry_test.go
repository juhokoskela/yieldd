package main

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

func TestIdentityRetryBackoffCapsAndResetsWithoutBlockingDeviceCalls(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 3)
		for range 3 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
				t.Fatal(err)
			}
		}
		for _, run := range w.runs {
			run.ID++
		}
		lookups := w.getCalls + 3
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop}); err != nil {
			cancel()
			t.Fatal(err)
		}
		startLoops(t, cancel, []*coordinatorLoop{loop})
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
		assertLookups := func() {
			t.Helper()
			if err := loop.invoke(t.Context(), func(context.Context) error {
				if w.getCalls != lookups {
					return fmt.Errorf("lookups = %d, want %d", w.getCalls, lookups)
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
		}
		for _, interval := range []time.Duration{5, 10, 20, 40, 60, 60} {
			interval *= time.Second
			time.Sleep(interval - time.Second)
			synctest.Wait()
			// Listener callbacks and capacity notifications must not bypass backoff.
			if _, err := loop.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
				t.Fatal(err)
			}
			if err := loop.invoke(t.Context(), func(context.Context) error {
				c.device.redrive(c.state.Owner)
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			synctest.Wait()
			assertLookups()
			time.Sleep(time.Second)
			synctest.Wait()
			lookups += 3
			assertLookups()
		}
		if err := loop.invoke(t.Context(), func(context.Context) error {
			for _, run := range w.runs {
				run.ID--
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Minute)
		synctest.Wait()
		lookups += 3
		assertLookups()
		if err := loop.invoke(t.Context(), func(context.Context) error {
			if c.paused != nil || c.identityRetryDelay != 0 || !c.identityRetryAt.IsZero() {
				return fmt.Errorf("successful verification did not reset backoff: %v, %s", c.paused, c.identityRetryDelay)
			}
			for _, run := range w.runs {
				run.ID++
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
		lookups += 3
		time.Sleep(4 * time.Second)
		synctest.Wait()
		assertLookups()
		time.Sleep(time.Second)
		synctest.Wait()
		lookups += 3
		assertLookups()
	})
}

func TestIdentityRetryReportsChangedRunnersAndPersistentFailures(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 2)
		var logs bytes.Buffer
		c.logger = slog.New(slog.NewTextHandler(&logs, nil))
		for range 2 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
				t.Fatal(err)
			}
		}
		names := c.names()
		for _, run := range w.runs {
			run.ID++
		}
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || !slices.Equal(c.identityRunners, names) {
			t.Fatal("affected runners not tracked", err, c.identityRunners)
		}
		w.runs[c.state.Leases[names[0]].RunID].ID--
		time.Sleep(5 * time.Second)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || !slices.Equal(c.identityRunners, names[1:]) {
			t.Fatal("verified sibling remained in the affected set", err, c.identityRunners)
		}
		warnings := strings.Count(logs.String(), "level=WARN")
		if warnings != 2 || !strings.Contains(logs.String(), "runners=["+names[1]+"]") {
			t.Fatal("changed runner set was not reported", logs.String())
		}
		for _, delay := range []time.Duration{10, 20, 40, 60, 60} {
			time.Sleep(delay * time.Second)
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
				t.Fatal(err)
			}
		}
		if strings.Count(logs.String(), "level=WARN") != warnings+3 {
			t.Fatal("persistent identity failure became silent", logs.String())
		}
	})
}
