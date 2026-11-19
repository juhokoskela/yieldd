package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

type bootstrapLookup struct {
	bootstrapAPI
	lookup func(context.Context, int64) (*workflowRun, error)
}

func (b bootstrapLookup) getRun(ctx context.Context, id int64) (*workflowRun, error) {
	return b.lookup(ctx, id)
}

func TestRestartIdentityMismatchBlocksPendingSiblingProvisioning(t *testing.T) {
	for _, pendingKind := range []string{"registered", "expired-local-offer"} {
		for _, pendingFirst := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/pending-first=%t", pendingKind, pendingFirst), func(t *testing.T) {
				c, w, store := multipleFallbackFixture(t, 3)
				c.device.pollNow(0)
				issued := issueLocal(t, c, 0, 1)
				hostedName := "yieldd-bootstrap-00000000-0000-0000-0000-000000000001"
				pendingName := "yieldd-bootstrap-00000000-0000-0000-0000-000000000002"
				if pendingFirst {
					hostedName, pendingName = pendingName, hostedName
				}
				hosted := &assignment{coordinator: c}
				if err := hosted.replace(&lease{Name: hostedName, Created: time.Now().UTC()}); err != nil {
					t.Fatal(err)
				}
				registration, err := hosted.generateRegistration(t.Context())
				if err != nil {
					t.Fatal(err)
				}
				next := *hosted.lease
				next.DispatchIntent, next.RunnerID = true, registration.Runner.ID
				next.RunID = 101
				if err := hosted.replace(&next); err != nil {
					t.Fatal(err)
				}
				api := testAPI(t, func(response http.ResponseWriter, request *http.Request) {
					fmt.Fprint(response, `{"id":101,"path":".github/workflows/other.yml","status":"completed","conclusion":"success"}`)
				})
				c.bootstrap = bootstrapLookup{w, api.getRun}
				pending := &assignment{coordinator: c}
				l := &lease{Name: pendingName, Created: time.Now().UTC()}
				if pendingKind == "expired-local-offer" {
					l.Local = &localLease{DeviceID: testDevice, Slot: 1, Phase: localOffered, Expires: time.Now().UTC().Add(-time.Second)}
				}
				if err := pending.replace(l); err != nil {
					t.Fatal(err)
				}
				if pendingKind == "registered" {
					if _, err := pending.generateRegistration(t.Context()); err != nil {
						t.Fatal(err)
					}
				}
				saved, err := store.load(c.state.Config)
				if err != nil {
					t.Fatal(err)
				}
				c.state, c.device = saved, newDeviceQueue(nil)
				if err := c.device.restore(saved); err != nil {
					t.Fatal(err)
				}
				before := len(w.events)
				if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil || !c.verificationPaused() {
					t.Fatal("restart did not retain the unverified identity", err, c.paused)
				}
				for _, event := range w.events[before:] {
					if event == "register" || event == "secret" || event == "dispatch" || event == "cancel" {
						t.Fatal("identity mismatch allowed a pending sibling to provision", w.events[before:])
					}
				}
				if w.dispatched != 0 || c.state.Leases[pendingName] != nil || w.runners[pendingName] != nil {
					t.Fatal("pending sibling was dispatched instead of cleaned up", w.dispatched, c.state.Leases[pendingName])
				}
				if l := c.state.Leases[hostedName]; l == nil || l.CleanupIntent || l.RunID != next.RunID {
					t.Fatal("unverified execution was changed", l)
				}
				if authorization, err := c.renewDevice(t.Context(), issued); err != nil || !authorization.Continue {
					t.Fatal("identity pause revoked the issued local sibling", authorization, err)
				}
				if err := c.completeDevice(t.Context(), issued); err != nil || c.state.Leases[issued.Runner] != nil {
					t.Fatal("issued local sibling could not finish during the pause", err)
				}
			})
		}
	}
}

func TestPermanentHostedReadFailureBlocksExpiredOffer(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 3)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		c.device.pollNow(0)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
			t.Fatal(err)
		}
		c.bootstrap = bootstrapLookup{w, func(context.Context, int64) (*workflowRun, error) { return nil, fmt.Errorf("invalid status document") }}
		time.Sleep(offerLifetime)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err == nil || w.dispatched != 1 || c.verificationPaused() {
			t.Fatal("permanent read failed to stop provisioning", w.dispatched, err)
		}
	})
}

func TestMissingRunAndTimedOutSiblingGetFreshVerification(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 2)
		for range 2 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
				t.Fatal(err)
			}
		}
		missing := c.state.Leases[c.names()[0]].RunID
		c.bootstrap = bootstrapLookup{w, func(ctx context.Context, id int64) (*workflowRun, error) {
			if id == missing {
				return nil, &missingWorkflowRun{id}
			}
			<-ctx.Done()
			return nil, ctx.Err()
		}}
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		defer cancel()
		if _, err := c.HandleDesiredRunnerCount(ctx, 2); err != nil || !c.verificationPaused() {
			t.Fatal("missing run suppressed timeout retry", err, c.paused)
		}
		c.bootstrap = w
		time.Sleep(cleanupRetryDelay)
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil || c.paused != nil || w.dispatched != 2 {
			t.Fatal("fresh read did not resume verification", err, c.paused)
		}
	})
}

func TestInitialMixedIdentityAndTransientFailuresRetry(t *testing.T) {
	for _, failure := range []error{&apiError{429}, &apiError{502}, context.DeadlineExceeded} {
		for _, local := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/local=%t", failure, local), func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					c, w, _ := multipleFallbackFixture(t, 2)
					count := 2
					if local {
						c.device.pollNow(0)
						issueLocal(t, c, 0, 1)
						count++
					}
					for range 2 {
						if _, err := c.HandleDesiredRunnerCount(t.Context(), count); err != nil {
							t.Fatal(err)
						}
					}
					var hosted []*lease
					for _, name := range c.names() {
						if l := c.state.Leases[name]; l.Local == nil {
							hosted = append(hosted, l)
						}
					}
					first, second := hosted[0], hosted[1]
					w.runs[first.RunID].ID++
					c.bootstrap = bootstrapLookup{w, func(ctx context.Context, id int64) (*workflowRun, error) {
						if id == second.RunID {
							return nil, failure
						}
						return w.getRun(ctx, id)
					}}
					if _, err := c.HandleDesiredRunnerCount(t.Context(), count); err != nil || !c.verificationPaused() {
						t.Fatal("initial mixed failures stopped automatic identity recovery", err, c.paused)
					}
					c.bootstrap = w
					w.runs[first.RunID].ID--
					time.Sleep(5 * time.Second)
					if _, err := c.HandleDesiredRunnerCount(t.Context(), count); err != nil || c.paused != nil || w.dispatched != 2 || slices.Contains(w.events, "cancel") {
						t.Fatal("verified mixed failure did not resume without replaying execution", err, c.paused, w.events)
					}
				})
			})
		}
	}
}

func TestSlowHostedLookupsFitTheCoordinatorCallDeadline(t *testing.T) {
	for _, limit := range []int{3, maximumAssignments} {
		t.Run(fmt.Sprint(limit), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, w, _ := multipleFallbackFixture(t, limit)
				for range limit {
					if _, err := c.HandleDesiredRunnerCount(t.Context(), limit); err != nil {
						t.Fatal(err)
					}
				}
				c.bootstrap = bootstrapLookup{w, func(ctx context.Context, id int64) (*workflowRun, error) {
					select {
					case <-ctx.Done():
						return nil, ctx.Err()
					case <-time.After(25 * time.Second):
						return w.getRun(ctx, id)
					}
				}}
				ctx, cancel := context.WithCancel(t.Context())
				loop := newCoordinatorLoop(ctx, c)
				if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop}); err != nil {
					cancel()
					t.Fatal(err)
				}
				startLoops(t, cancel, []*coordinatorLoop{loop})
				before := w.getCalls
				started := time.Now()
				if actual, err := loop.HandleDesiredRunnerCount(t.Context(), limit); err != nil || actual != limit {
					t.Fatal("slow status reads exhausted the callback deadline", actual, err, time.Since(started))
				}
				if time.Since(started) != 25*time.Second {
					t.Fatal("read-only status lookups accumulated per-lease latency", time.Since(started))
				}
				if err := loop.invoke(t.Context(), func(context.Context) error {
					if c.paused != nil || w.dispatched != limit || len(c.state.Leases) != limit || w.getCalls != before+limit {
						return fmt.Errorf("slow lookup changed queue state: %v, %d dispatches", c.paused, w.dispatched)
					}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
			})
		})
	}
}

func TestShutdownWaitsForAllBootstrapLookupsWithoutChangingLeases(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := multipleFallbackFixture(t, 2)
		for range 2 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
				t.Fatal(err)
			}
		}
		events := slices.Clone(w.events)
		started := make(chan int64, 2)
		returned := make(chan int64, 2)
		c.bootstrap = bootstrapLookup{w, func(ctx context.Context, id int64) (*workflowRun, error) {
			started <- id
			<-ctx.Done()
			returned <- id
			return nil, ctx.Err()
		}}
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		if _, err := newDeviceRouter(testDevice, []*coordinatorLoop{loop}); err != nil {
			cancel()
			t.Fatal(err)
		}
		startLoops(t, cancel, []*coordinatorLoop{loop})
		result := make(chan error, 1)
		go func() {
			_, err := loop.HandleDesiredRunnerCount(t.Context(), 2)
			result <- err
		}()
		for range 2 {
			<-started
		}
		cancel()
		if err := <-result; !onlyCancellation(err) {
			t.Fatal("cancelled status reads became a queue failure", err)
		}
		for range 2 {
			select {
			case <-returned:
			default:
				t.Fatal("queue returned before its lookups stopped")
			}
		}
		if c.paused != nil || len(c.state.Leases) != 2 || w.dispatched != 2 || !slices.Equal(w.events, events) {
			t.Fatal("cancelled reads altered execution or cleanup", c.paused, w.events)
		}
	})
}

func TestProductionBootstrapStatusRequestsRunConcurrently(t *testing.T) {
	c, w, _ := multipleFallbackFixture(t, 3)
	for range 3 {
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 3); err != nil {
			t.Fatal(err)
		}
	}
	started := make(chan int64, 3)
	release := make(chan struct{}, 3)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		id, err := strconv.ParseInt(strings.TrimPrefix(request.URL.Path, "/repos/example/infrastructure/actions/runs/"), 10, 64)
		if err != nil || request.Method != http.MethodGet || w.runs[id] == nil {
			t.Error("unexpected status request", request.Method, request.URL.Path)
			response.WriteHeader(http.StatusBadRequest)
			return
		}
		started <- id
		select {
		case <-release:
			if err := json.NewEncoder(response).Encode(w.runs[id]); err != nil {
				t.Error(err)
			}
		case <-request.Context().Done():
		}
	}))
	t.Cleanup(server.Close)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	c.bootstrap = bootstrapWithRunAPI{bootstrapAPI: w, api: &githubAPI{base: server.URL, infrastructure: testConfig.Infrastructure, client: server.Client()}}
	result := make(chan error, 1)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		_, err := c.HandleDesiredRunnerCount(ctx, 3)
		result <- err
	}()
	t.Cleanup(func() { cancel(); <-finished })
	seen := make(map[int64]bool)
	for range 3 {
		select {
		case id := <-started:
			seen[id] = true
		case <-ctx.Done():
			t.Fatal("status requests did not overlap", ctx.Err())
		}
	}
	for range 3 {
		release <- struct{}{}
	}
	if err := <-result; err != nil || len(seen) != 3 || c.paused != nil || len(c.state.Leases) != 3 || w.dispatched != 3 {
		t.Fatal("production status reads did not preserve the queue", err, seen, c.paused)
	}
}
