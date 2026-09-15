package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

var testConfig = config{Repository: "example/application", Infrastructure: "example/infrastructure", Fallback: `"ubuntu-24.04"`}

type fakeWorld struct {
	events                                         []string
	runner                                         *scaleset.RunnerReference
	run                                            *workflowRun
	secret                                         string
	dispatched                                     int
	generateErr, dispatchErr, secretErr, deleteErr error
	busy                                           bool
	beforeGenerate, beforeDispatch                 func()
	afterSecret                                    func()
	cancelErr                                      error
	beforeCancel                                   func()
	findCalls, getCalls                            int
	getErr                                         error
}

func (f *fakeWorld) GenerateJitRunnerConfig(_ context.Context, s *scaleset.RunnerScaleSetJitRunnerSetting, id int) (*scaleset.RunnerScaleSetJitRunnerConfig, error) {
	f.events = append(f.events, "register")
	if f.beforeGenerate != nil {
		f.beforeGenerate()
	}
	if f.generateErr != nil {
		return nil, f.generateErr
	}
	f.runner = &scaleset.RunnerReference{ID: 7, Name: s.Name, RunnerScaleSetID: id}
	return &scaleset.RunnerScaleSetJitRunnerConfig{Runner: f.runner, EncodedJITConfig: "private-jit"}, nil
}
func (f *fakeWorld) GetRunnerByName(context.Context, string) (*scaleset.RunnerReference, error) {
	return f.runner, nil
}
func (f *fakeWorld) RemoveRunner(context.Context, int64) error {
	f.events = append(f.events, "remove-runner")
	f.runner = nil
	return nil
}
func (f *fakeWorld) putSecret(_ context.Context, _, value string) error {
	f.events = append(f.events, "secret")
	if f.secretErr != nil {
		return f.secretErr
	}
	f.secret = value
	if f.afterSecret != nil {
		f.afterSecret()
	}
	return nil
}
func (f *fakeWorld) deleteSecret(context.Context, string) error {
	f.events = append(f.events, "remove-secret")
	if f.deleteErr != nil {
		return f.deleteErr
	}
	f.secret = ""
	return nil
}
func (f *fakeWorld) dispatch(_ context.Context, l *lease, _ string) (int64, error) {
	f.events = append(f.events, "dispatch")
	f.dispatched++
	if f.beforeDispatch != nil {
		f.beforeDispatch()
	}
	f.run = &workflowRun{ID: 99, DisplayTitle: "Bootstrap " + l.Name, Status: "queued", CreatedAt: time.Unix(100000, 0), observedAt: time.Unix(100000, 0)}
	if f.dispatchErr != nil {
		return 0, f.dispatchErr
	}
	return f.run.ID, nil
}
func (f *fakeWorld) findRun(context.Context, *lease) (*workflowRun, error) {
	f.findCalls++
	if f.run == nil {
		return nil, nil
	}
	copy := *f.run
	return &copy, nil
}
func (f *fakeWorld) getRun(context.Context, int64) (*workflowRun, error) {
	f.getCalls++
	if f.getErr != nil {
		return nil, f.getErr
	}
	if f.run == nil {
		return nil, nil
	}
	copy := *f.run
	return &copy, nil
}
func (f *fakeWorld) cancelRun(context.Context, int64) error {
	f.events = append(f.events, "cancel")
	if f.beforeCancel != nil {
		f.beforeCancel()
	}
	return f.cancelErr
}
func (f *fakeWorld) runnerBusy(context.Context, string, int) (bool, error) { return f.busy, nil }

func newFixture(t *testing.T) (*coordinator, *fakeWorld, *stateStore) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "state")
	store, err := openStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	saved.ScaleSetID = 3
	if err := store.save(saved); err != nil {
		t.Fatal(err)
	}
	world := new(fakeWorld)
	return &coordinator{lifetime: t.Context(), state: saved, save: store.save, runners: world, bootstrap: world, now: func() time.Time { return time.Unix(100000, 0) }, logger: slog.New(slog.NewTextHandler(io.Discard, nil))}, world, store
}

func TestDemandPersistsBeforeSideEffectsAndBoundsCapacity(t *testing.T) {
	c, w, store := newFixture(t)
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 0); err != nil || n != 0 || len(w.events) != 0 {
		t.Fatalf("idle: %d %v %v", n, err, w.events)
	}
	w.beforeGenerate = func() {
		s, err := store.load(testConfig)
		if err != nil || s.Lease == nil || s.Lease.RunnerID != 0 {
			t.Fatal("registration intent not durable", err)
		}
	}
	w.beforeDispatch = func() {
		s, err := store.load(testConfig)
		if err != nil || !s.Lease.DispatchIntent || s.Lease.JIT != "" {
			t.Fatal("dispatch intent not durable", err)
		}
	}
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 20); err != nil || n != 1 {
		t.Fatalf("provision: %d %v", n, err)
	}
	if !reflect.DeepEqual(w.events, []string{"register", "secret", "dispatch"}) {
		t.Fatal(w.events)
	}
	if w.secret != "private-jit" {
		t.Fatal("JIT not delivered")
	}
	for range 3 {
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 20); err != nil {
			t.Fatal(err)
		}
	}
	if w.dispatched != 1 {
		t.Fatal("duplicate dispatch", w.dispatched)
	}
	saved, err := store.load(testConfig)
	if err != nil || saved.Lease.RunID != 99 || w.findCalls != 0 || w.getCalls != 3 {
		t.Fatal("ordinary dispatch did not use its persisted run ID", err, w.findCalls, w.getCalls)
	}
}

func TestRestartAfterLostDispatchResponseReconcilesWithoutRedispatch(t *testing.T) {
	c, w, store := newFixture(t)
	w.dispatchErr = errors.New("response lost")
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
		t.Fatal("expected uncertain dispatch")
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	c.state = saved
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if c.state.Lease.RunID != 99 || w.dispatched != 1 {
		t.Fatal("lost response caused redispatch")
	}
	if w.findCalls != 1 {
		t.Fatal("lost response did not use run discovery")
	}
}

func TestUnknownDispatchNeverRedispatchesOrDropsObligation(t *testing.T) {
	c, w, store := newFixture(t)
	w.dispatchErr = errors.New("lost")
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
		t.Fatal("expected uncertain dispatch")
	}
	w.run = nil
	c.now = func() time.Time { return time.Unix(100000, 0).Add(6 * time.Minute) }
	for range 2 {
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
			t.Fatal("unknown dispatch should stop")
		}
	}
	if w.dispatched != 1 {
		t.Fatal("redispatched unknown outcome")
	}
	saved, err := store.load(testConfig)
	if err != nil || saved.Lease == nil || !saved.Lease.DispatchIntent {
		t.Fatal("lost obligation", err)
	}
}

func TestRestartResumesSecretDeliveryBeforeFirstDispatch(t *testing.T) {
	c, w, store := newFixture(t)
	w.secretErr = errors.New("secret unavailable")
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
		t.Fatal("expected secret failure")
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Lease.JIT != "private-jit" || saved.Lease.DispatchIntent {
		t.Fatal("cannot resume secret delivery")
	}
	c.state = saved
	w.secretErr = nil
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if w.dispatched != 1 || strings.Join(w.events, ",") != "register,secret,secret,dispatch" {
		t.Fatal(w.events)
	}
}

func TestUncertainRegistrationRequiresRecovery(t *testing.T) {
	c, w, store := newFixture(t)
	w.generateErr = errors.New("lost registration response")
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
		t.Fatal("expected registration failure")
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	c.state = saved
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
		t.Fatal("must not repeat registration")
	}
	if strings.Join(w.events, ",") != "register" {
		t.Fatal(w.events)
	}
	// The original request created a runner even though its response was lost.
	w.runner = &scaleset.RunnerReference{ID: 7, Name: c.state.Lease.Name, RunnerScaleSetID: 3}
	if done, err := c.reconcile(t.Context(), true); err != nil || !done {
		t.Fatal(done, err)
	}
	if c.state.Lease != nil || w.runner != nil {
		t.Fatal("registration not recovered")
	}
}

func TestCleanupFailuresRetainLeaseAndRetryOnlyCleanup(t *testing.T) {
	c, w, store := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	w.run.Status = "completed"
	w.run.Conclusion = "success"
	w.deleteErr = errors.New("delete unavailable")
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 0); err == nil {
		t.Fatal("expected cleanup failure")
	}
	saved, err := store.load(testConfig)
	if err != nil || saved.Lease == nil {
		t.Fatal("cleanup obligation lost", err)
	}
	c.state = saved
	w.deleteErr = nil
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 {
		t.Fatal(n, err)
	}
	if c.state.Lease != nil || w.dispatched != 1 {
		t.Fatal("cleanup re-provisioned against stale demand")
	}
}

func TestBusyAndForeignRunnersAreNotDeleted(t *testing.T) {
	for _, foreign := range []bool{false, true} {
		t.Run(fmt.Sprint(foreign), func(t *testing.T) {
			c, w, _ := newFixture(t)
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
			w.run.Status = "completed"
			w.run.Conclusion = "success"
			if foreign {
				w.runner.RunnerScaleSetID = 9
			} else {
				w.busy = true
			}
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 0); err == nil {
				t.Fatal("unsafe cleanup allowed")
			}
			if w.runner == nil || c.state.Lease == nil {
				t.Fatal("deleted active or foreign runner")
			}
		})
	}
}

func TestFailedBootstrapCleansUpAndStopsRatherThanRerunning(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	w.run.Status = "completed"
	w.run.Conclusion = "failure"
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
		t.Fatal("bootstrap failure ignored")
	}
	if c.state.Lease != nil || w.runner != nil || w.secret != "" || w.dispatched != 1 {
		t.Fatal("failure cleanup or dispatch count")
	}
}

func TestRecoveryWaitsForCancellationBeforeDeleting(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	done, err := c.reconcile(t.Context(), true)
	if err != nil || done {
		t.Fatal(done, err)
	}
	if w.runner == nil || w.secret == "" {
		t.Fatal("removed credentials before termination")
	}
	if w.events[len(w.events)-1] != "cancel" {
		t.Fatal(w.events)
	}
	w.run.Status = "completed"
	w.run.Conclusion = "cancelled"
	if done, err := c.reconcile(t.Context(), true); err != nil || !done {
		t.Fatal(done, err)
	}
}

func TestPersistenceFailurePreventsRegistration(t *testing.T) {
	c, w, _ := newFixture(t)
	failure := errors.New("disk full")
	c.save = func(*state) error { return failure }
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, failure) {
		t.Fatal(err)
	}
	if len(w.events) != 0 {
		t.Fatal("external action before persistence", w.events)
	}
}

func TestEveryPreDispatchPersistenceBarrierPreventsDispatch(t *testing.T) {
	for failAt := 1; failAt <= 3; failAt++ {
		t.Run(fmt.Sprint(failAt), func(t *testing.T) {
			c, w, store := newFixture(t)
			failure := errors.New("disk full")
			writes := 0
			c.save = func(s *state) error {
				writes++
				if writes == failAt {
					return failure
				}
				return store.save(s)
			}
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); !errors.Is(err, failure) {
				t.Fatal(err)
			}
			if w.dispatched != 0 {
				t.Fatal("dispatched past a failed persistence barrier")
			}
			saved, err := store.load(testConfig)
			if err != nil {
				t.Fatal(err)
			}
			if failAt > 1 && saved.Lease == nil {
				t.Fatal("lost prior durable intent")
			}
			c.state = saved
			c.save = store.save
			if failAt == 2 {
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
					t.Fatal("unknown registration retried")
				}
				if done, err := c.reconcile(t.Context(), true); err != nil || !done {
					t.Fatal(done, err)
				}
				return
			}
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
			if w.dispatched != 1 {
				t.Fatal("restart failed to resume undispatched intent")
			}
		})
	}
}

func TestCancellationBeforeProvisioningHasNoSideEffects(t *testing.T) {
	c, w, _ := newFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := c.HandleDesiredRunnerCount(ctx, 1); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if c.state.Lease != nil || len(w.events) != 0 {
		t.Fatal("provisioned after cancellation")
	}
}

func TestShutdownStillPreventsProvisioningWithDetachedCallbackContext(t *testing.T) {
	c, w, _ := newFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	c.lifetime = ctx
	cancel()
	if _, err := c.HandleDesiredRunnerCount(context.WithoutCancel(ctx), 1); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if c.state.Lease != nil || len(w.events) != 0 {
		t.Fatal("provisioned during shutdown")
	}
}

func TestQueuedBootstrapDeadlineRetainsLeaseUntilTermination(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	w.run.observedAt = w.run.CreatedAt.Add(26 * time.Minute)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if c.state.Lease == nil || w.secret == "" || w.events[len(w.events)-1] != "cancel" || w.dispatched != 1 {
		t.Fatal("unsafe queued timeout cleanup", w.events)
	}
}

func TestSDKDiagnosticsHidePayloadsAndPreserveIdentity(t *testing.T) {
	c, w, _ := newFixture(t)
	w.generateErr = fmt.Errorf("response body private-jit: %w", context.DeadlineExceeded)
	_, err := c.HandleDesiredRunnerCount(t.Context(), 1)
	if err == nil || strings.Contains(err.Error(), "private-jit") || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
}

func TestPrivateStateAndExclusiveOwnership(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	store, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := openStore(dir); err == nil {
		t.Fatal("second owner admitted")
	}
	saved, err := store.load(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	saved.Lease = &lease{Name: "yieldd-bootstrap-01234567-89ab-cdef-0123-456789abcdef", Created: time.Now(), RunnerID: 7, JIT: "private-jit"}
	saved.ScaleSetID = 3
	if err := store.save(saved); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, "state.json"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatal(info, err)
	}
	other := testConfig
	other.Repository = "other/repository"
	if _, err := store.load(other); err == nil {
		t.Fatal("accepted mismatched state")
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	loaded, err := reopened.load(testConfig)
	if err != nil || loaded.Lease.JIT != "private-jit" {
		t.Fatal("state did not survive reopen", err)
	}
	data, err := json.Marshal(loaded)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.json"), append(data, []byte("{}")...), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := reopened.load(testConfig); err == nil {
		t.Fatal("accepted trailing state")
	}
}

func TestConfigurationValidation(t *testing.T) {
	for _, target := range []string{`"ubuntu-24.04"`, `["self-hosted","linux","custom"]`} {
		c := testConfig
		c.Fallback = target
		if err := c.validate(); err != nil {
			t.Fatal(err)
		}
	}
	for _, target := range []string{"", `null`, `[]`, `{}`, `[""]`, `"yieldd"`, `["linux","YIELDD"]`, `" ubuntu-24.04"`} {
		c := testConfig
		c.Fallback = target
		if err := c.validate(); err == nil {
			t.Fatal("accepted", target)
		}
	}
	for _, repository := range []string{"../escape", "example/.", "example/..", "EXAMPLE/INFRASTRUCTURE"} {
		c := testConfig
		c.Repository = repository
		if err := c.validate(); err == nil {
			t.Fatal("accepted invalid application repository", repository)
		}
	}
}

func TestStateRejectsOversizeAndPublicFiles(t *testing.T) {
	_, _, store := newFixture(t)
	file, err := store.root.OpenFile("state.json", os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(strings.Repeat(" ", (2<<20)+1)); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := store.load(testConfig); err == nil || !strings.Contains(err.Error(), "size limit") {
		t.Fatal(err)
	}
	if err := store.root.Chmod("state.json", 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := store.load(testConfig); err == nil || !strings.Contains(err.Error(), "private") {
		t.Fatal(err)
	}
}
