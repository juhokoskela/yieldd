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
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

var testConfig = config{Repository: "example/application", Infrastructure: "example/infrastructure", Fallback: `"ubuntu-24.04"`}

type fakeWorld struct {
	getRunMu                                       sync.Mutex
	events                                         []string
	runner                                         *scaleset.RunnerReference
	run                                            *workflowRun
	secret                                         string
	dispatched                                     int
	fallback                                       string
	generateErr, dispatchErr, secretErr, deleteErr error
	busy                                           bool
	beforeGenerate, beforeDispatch                 func()
	afterSecret                                    func()
	cancelErr                                      error
	beforeCancel                                   func()
	findCalls, getCalls                            int
	getErr                                         error
	assignedJobs                                   int
	demandErr, lookupErr                           error
	demandCalls                                    int
}

func (f *fakeWorld) GetRunnerScaleSetByID(_ context.Context, id int) (*scaleset.RunnerScaleSet, error) {
	f.demandCalls++
	return &scaleset.RunnerScaleSet{ID: id, Statistics: &scaleset.RunnerScaleSetStatistic{TotalAssignedJobs: f.assignedJobs}}, f.demandErr
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
	return f.runner, f.lookupErr
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
func (f *fakeWorld) dispatch(_ context.Context, l *lease, fallback string) (int64, error) {
	f.fallback = fallback
	f.events = append(f.events, "dispatch")
	f.dispatched++
	if f.beforeDispatch != nil {
		f.beforeDispatch()
	}
	f.run = &workflowRun{ID: 99, Path: ".github/workflows/runner-bootstrap.yml", DisplayTitle: "Bootstrap " + l.Name, Status: "queued"}
	if f.dispatchErr != nil {
		return 0, f.dispatchErr
	}
	return f.run.ID, nil
}
func (f *fakeWorld) findRun(_ context.Context, l *lease) (*workflowRun, error) {
	f.findCalls++
	if f.run == nil || f.run.DisplayTitle != "Bootstrap "+l.Name {
		return nil, nil
	}
	if f.run.ID <= 0 {
		return nil, errors.New("discovered bootstrap has an invalid run ID")
	}
	copy := *f.run
	return &copy, nil
}
func (f *fakeWorld) getRun(context.Context, int64) (*workflowRun, error) {
	f.getRunMu.Lock()
	defer f.getRunMu.Unlock()
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
	world := &fakeWorld{assignedJobs: 1}
	return &coordinator{state: saved, save: store.save, runners: world, bootstrap: world, device: newDeviceQueue(nil), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), maxFallbackRunners: defaultMaxFallbackRunners}, world, store
}

func checkJournalOmitsCredential(t *testing.T, c *coordinator, store *stateStore) {
	t.Helper()
	save := c.save
	c.save = func(s *state) error {
		if err := save(s); err != nil {
			return err
		}
		data, err := store.root.ReadFile("state.json")
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(data), "private-jit") || strings.Contains(string(data), "\"jit\"") {
			t.Fatal("credential reached the coordinator journal")
		}
		return nil
	}
}

func TestDemandPersistsBeforeSideEffectsAndBoundsCapacity(t *testing.T) {
	c, w, store := newFixture(t)
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 0); err != nil || n != 0 || len(w.events) != 0 {
		t.Fatalf("idle: %d %v %v", n, err, w.events)
	}
	checkJournalOmitsCredential(t, c, store)
	w.beforeGenerate = func() {
		s, err := store.load(testConfig)
		if err != nil || singleLease(s) == nil || singleLease(s).RunnerID != 0 {
			t.Fatal("registration intent not durable", err)
		}
	}
	w.beforeDispatch = func() {
		s, err := store.load(testConfig)
		if err != nil || !singleLease(s).DispatchIntent || singleLease(s).RunnerID != 7 {
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
	if err != nil || singleLease(saved).RunID != 99 || w.findCalls != 0 || w.getCalls != 3 {
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
	if singleLease(c.state).RunID != 99 || w.dispatched != 1 {
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
	for range 2 {
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
			t.Fatal("unknown dispatch should stop")
		}
	}
	if w.dispatched != 1 {
		t.Fatal("redispatched unknown outcome")
	}
	saved, err := store.load(testConfig)
	if err != nil || singleLease(saved) == nil || !singleLease(saved).DispatchIntent {
		t.Fatal("lost obligation", err)
	}
}

func TestInterruptedHostedRegistrationCleansUpBeforeFreshDemand(t *testing.T) {
	for _, phase := range []string{"before-registration", "lost-registration", "lost-secret-upload"} {
		t.Run(phase, func(t *testing.T) {
			c, w, store := newFixture(t)
			checkJournalOmitsCredential(t, c, store)
			if phase == "lost-secret-upload" {
				w.secretErr = errors.New("upload response lost")
			} else {
				w.generateErr = errors.New("registration interrupted")
			}
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err == nil {
				t.Fatal("expected interruption")
			}
			saved, err := store.load(testConfig)
			if err != nil {
				t.Fatal(err)
			}
			l := singleLease(saved)
			if l == nil || l.DispatchIntent || l.RunnerID != 0 {
				t.Fatal("lost pre-dispatch journal")
			}
			switch phase {
			case "lost-registration":
				w.runner = &scaleset.RunnerReference{ID: 7, Name: l.Name, RunnerScaleSetID: 3}
			case "lost-secret-upload":
				w.secret = "private-jit"
			}
			c.state, w.generateErr, w.secretErr = saved, nil, nil
			before := len(w.events)
			if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 {
				t.Fatal("restart cleanup", n, err)
			}
			if w.runner != nil || w.secret != "" || w.dispatched != 0 || strings.Contains(strings.Join(w.events[before:], ","), "register") {
				t.Fatal("cleanup replayed registration or retained resources", w.events)
			}
			w.assignedJobs = 0
			if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 || w.demandCalls != 1 {
				t.Fatal("cached demand replayed work", n, err)
			}
			w.assignedJobs = 1
			if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 || singleLease(c.state).Name == l.Name || w.dispatched != 1 {
				t.Fatal("fresh demand did not get a new assignment", n, err)
			}
		})
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
	if err != nil || singleLease(saved) == nil {
		t.Fatal("cleanup obligation lost", err)
	}
	c.state = saved
	w.deleteErr = nil
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 0 {
		t.Fatal(n, err)
	}
	if singleLease(c.state) != nil || w.dispatched != 1 {
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
			if w.runner == nil || singleLease(c.state) == nil {
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
	w.run.DisplayTitle = "Runner bootstrap prototype"
	w.run.Status, w.run.Conclusion = "completed", "startup_failure"
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatalf("failed bootstrap should back off hosted provisioning without erroring queue: %v", err)
	}
	if !c.hostedBackoffActive() {
		t.Fatal("failed bootstrap did not activate hosted backoff")
	}
	if singleLease(c.state) != nil || w.runner != nil || w.secret != "" || w.dispatched != 1 {
		t.Fatalf("failure cleanup or dispatch count: lease=%v runner=%v secret_present=%v dispatches=%d", singleLease(c.state), w.runner, w.secret != "", w.dispatched)
	}
}

func TestRecoveryWaitsForCancellationBeforeDeleting(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	w.run.DisplayTitle = ""
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
	if singleLease(c.state) != nil || w.runner != nil || w.secret != "" || w.dispatched != 1 || w.findCalls != 0 {
		t.Fatalf("recovery left resources or replayed execution: lease=%v runner=%v secret_present=%v dispatches=%d find=%d", singleLease(c.state), w.runner, w.secret != "", w.dispatched, w.findCalls)
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
	for failAt := 1; failAt <= 2; failAt++ {
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
			if failAt > 1 && singleLease(saved) == nil {
				t.Fatal("lost prior durable intent")
			}
			c.state = saved
			c.save = store.save
			if failAt == 2 {
				if !singleLease(saved).CleanupIntent {
					t.Fatal("failed dispatch intent was not moved to cleanup")
				}
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
					t.Fatal(err)
				}
				if singleLease(c.state) != nil || w.dispatched != 0 || w.runner != nil || w.secret != "" {
					t.Fatal("failed intent resumed provisioning")
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
	if singleLease(c.state) != nil || len(w.events) != 0 {
		t.Fatal("provisioned after cancellation")
	}
}

func TestShutdownStillPreventsProvisioningWithDetachedCallbackContext(t *testing.T) {
	c, w, _ := newFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	loop := newCoordinatorLoop(ctx, c)
	cancel()
	if _, err := loop.HandleDesiredRunnerCount(context.WithoutCancel(ctx), 1); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if singleLease(c.state) != nil || len(w.events) != 0 {
		t.Fatal("provisioned during shutdown")
	}
}

func TestExplicitRecoveryCancelsBootstrapAndRetainsLeaseUntilTermination(t *testing.T) {
	c, w, _ := newFixture(t)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if done, err := c.reconcile(t.Context(), true); err != nil || done {
		t.Fatal(err)
	}
	if singleLease(c.state) == nil || w.secret == "" || w.events[len(w.events)-1] != "cancel" || w.dispatched != 1 {
		t.Fatal("unsafe recovery cleanup", w.events)
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

func TestLegacyHostedCredentialRequiresOldCoordinator(t *testing.T) {
	c, _, store := newFixture(t)
	cfg, err := json.Marshal(testConfig)
	if err != nil {
		t.Fatal(err)
	}
	old := fmt.Sprintf(`{"config":%s,"owner":%q,"scale_set_id":3,"leases":{%q:{"name":%q,"created":"2026-01-01T00:00:00Z","runner_id":7,"jit":"private-jit"}}}`, cfg, c.state.Owner, fixtureRunner, fixtureRunner)
	if err := store.root.WriteFile("state.json", []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.load(testConfig); err == nil || strings.Contains(err.Error(), "private-jit") {
		t.Fatal("legacy credential was accepted or disclosed")
	}
	after, err := store.root.ReadFile("state.json")
	if err != nil || string(after) != old {
		t.Fatal("legacy journal changed on refusal", err)
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
	l := &lease{Name: "yieldd-bootstrap-01234567-89ab-cdef-0123-456789abcdef", Created: time.Now().UTC(), RunnerID: 7, DispatchIntent: true}
	saved.Leases = map[string]*lease{l.Name: l}
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
	if err != nil || *singleLease(loaded) != *l {
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
