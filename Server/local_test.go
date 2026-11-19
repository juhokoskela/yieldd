package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testDevice = "01234567-89ab-4def-8123-456789abcdef"

func localFixture(t *testing.T) (*coordinator, *fakeWorld, *stateStore, deviceRequest) {
	t.Helper()
	c, w, store := newFixture(t)
	c.state.Config.DeviceID = testDevice
	c.device.pollNow(0)
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || n != 1 {
		t.Fatalf("offer: %d %v", n, err)
	}
	return c, w, store, deviceRequest{DeviceID: testDevice, Owner: c.state.Owner, Runner: singleLease(c.state).Name}
}

func TestLocalOfferDoesNotRegisterUntilAccepted(t *testing.T) {
	c, w, store, request := localFixture(t)
	if len(w.events) != 0 || singleLease(c.state).Local.Phase != localOffered {
		t.Fatal("offer caused external provisioning")
	}
	checkJournalOmitsCredential(t, c, store)
	w.beforeGenerate = func() {
		saved, err := store.load(c.state.Config)
		if err != nil || singleLease(saved).Local.Phase != localAccepted {
			t.Fatalf("acceptance not durable: %v", err)
		}
	}
	credential, err := c.acceptDevice(t.Context(), request)
	if err != nil || credential.JIT != "private-jit" {
		t.Fatalf("accept: %v %v", credential, err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil || singleLease(saved).Local.Phase != localIssued {
		t.Fatalf("delivery not durable: %v", err)
	}
	if _, err := c.acceptDevice(t.Context(), request); err == nil {
		t.Fatal("credentials issued twice")
	}
	if w.dispatched != 0 || w.secret != "" {
		t.Fatal("local assignment touched infrastructure")
	}
}

func TestIssuedLocalLeaseSurvivesRestartAndDisconnection(t *testing.T) {
	c, w, store, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	saved, err := store.load(c.state.Config)
	if err != nil {
		t.Fatal(err)
	}
	c.state = saved
	c.device.slots[0].availableUntil = time.Time{}
	singleLease(c.state).Local.Expires = time.Now().Add(-time.Hour)
	for _, demand := range []int{0, 1} {
		if n, err := c.HandleDesiredRunnerCount(t.Context(), demand); err != nil || n != 1 {
			t.Fatalf("lost local capacity: %d %v", n, err)
		}
	}
	if _, err := c.reconcile(t.Context(), true); err == nil {
		t.Fatal("recovery abandoned an issued credential")
	}
	if w.dispatched != 0 || w.runner == nil {
		t.Fatal("disconnection replaced local execution")
	}
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	if singleLease(c.state) != nil || w.runner != nil {
		t.Fatal("local completion did not clean up")
	}
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal("lost acknowledgement was not retryable", err)
	}
}

func TestExpiredOfferFallsBackWithoutIssuingLocalCredentials(t *testing.T) {
	c, w, _, request := localFixture(t)
	singleLease(c.state).Local.Expires = time.Now().Add(-time.Second)
	if _, err := c.acceptDevice(t.Context(), request); err == nil {
		t.Fatal("expired offer accepted")
	}
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if w.dispatched != 1 || singleLease(c.state).Local != nil {
		t.Fatal("no hosted fallback")
	}
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	if singleLease(c.state) == nil || w.runner == nil {
		t.Fatal("late local acknowledgement deleted hosted execution")
	}
}

func TestLocalCapacityExpiresAndZeroDemandRetractsUnacceptedOffer(t *testing.T) {
	c, w, _, _ := localFixture(t)
	if n, err := c.HandleDesiredRunnerCount(t.Context(), 0); err != nil || n != 0 {
		t.Fatalf("retract: %d %v", n, err)
	}
	c.device.slots[0].availableUntil = time.Now().Add(-time.Second)
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if w.dispatched != 1 {
		t.Fatal("offline Mac prevented fallback")
	}
}

func TestLocalCleanupMustConfirmRegistrationIsIdle(t *testing.T) {
	c, w, store, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	w.busy = true
	if err := c.completeDevice(t.Context(), request); err == nil {
		t.Fatal("busy registration removed")
	}
	saved, err := store.load(c.state.Config)
	if err != nil || !singleLease(saved).CleanupIntent || w.runner == nil {
		t.Fatalf("cleanup intent lost: %v", err)
	}
	c.state = saved
	w.busy = false
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
}

func TestLocalFailureBeforeCredentialDeliveryIsRecoverable(t *testing.T) {
	for _, phase := range []localPhase{localAccepted, localIssued} {
		t.Run(string(phase), func(t *testing.T) {
			c, w, store, request := localFixture(t)
			c.save = func(s *state) error {
				if singleLease(s) != nil && singleLease(s).Local.Phase == phase {
					return errors.New("disk failure")
				}
				return store.save(s)
			}
			if value, err := c.acceptDevice(t.Context(), request); err == nil || value != nil {
				t.Fatal("returned credentials after failed save")
			}
			c.save = store.save
			saved, err := store.load(c.state.Config)
			if err != nil {
				t.Fatal(err)
			}
			c.state = saved
			if err := c.completeDevice(t.Context(), request); err != nil {
				t.Fatal(err)
			}
			if w.runner != nil || singleLease(c.state) != nil {
				t.Fatal("failed acceptance was not cleaned up")
			}
		})
	}
}

func TestLocalIdentityIsBoundToDeviceAndCoordinator(t *testing.T) {
	for _, field := range []string{"device", "owner", "runner"} {
		t.Run(field, func(t *testing.T) {
			c, w, _, request := localFixture(t)
			switch field {
			case "device":
				request.DeviceID = "other"
			case "owner":
				request.Owner = "other"
			case "runner":
				request.Runner = "../other"
			}
			if _, err := c.acceptDevice(t.Context(), request); err == nil {
				t.Fatal("invalid identity accepted")
			}
			if err := c.completeDevice(t.Context(), request); err == nil {
				t.Fatal("invalid identity cleaned up")
			}
			if len(w.events) != 0 {
				t.Fatal("invalid identity caused external calls")
			}
		})
	}
}

func TestDeviceHTTPAuthenticatesAndDoesNotReplayCredentials(t *testing.T) {
	c, _, _, request := localFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	loop := newCoordinatorLoop(ctx, c)
	done := make(chan struct{})
	go func() { defer close(done); loop.run() }()
	t.Cleanup(func() { cancel(); <-done })
	token := strings.Repeat("x", 32)
	server := httptest.NewServer(deviceHandlerFor(t, loop, token))
	t.Cleanup(server.Close)
	body, _ := json.Marshal(request)
	for _, test := range []struct {
		path, token string
		status      int
	}{
		{"accept", "wrong", 401}, {"renew", "wrong", 401}, {"poll", token, 200}, {"accept", token, 200}, {"renew", token, 200}, {"accept", token, 410}, {"complete", token, 200}, {"complete", token, 200},
	} {
		r, _ := http.NewRequestWithContext(t.Context(), "POST", server.URL+"/v1/"+test.path, strings.NewReader(string(body)))
		r.Header.Set("Authorization", "Bearer "+test.token)
		response, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || response.StatusCode != test.status {
			t.Fatalf("%s: %d %s %v", test.path, response.StatusCode, data, err)
		}
		if test.status != 200 && strings.Contains(string(data), "private-jit") {
			t.Fatal("credential leaked")
		}
	}
}

func TestDeviceListenerRejectsWildcardBindingByDefault(t *testing.T) {
	for _, address := range []string{"0.0.0.0:0", "[::]:0"} {
		listener, err := listenForDevice(address, strings.Repeat("x", 32), false)
		if err == nil {
			listener.Close()
			t.Errorf("wildcard binding %s accepted without explicit opt-in", address)
		} else if !strings.Contains(err.Error(), "--allow-non-loopback-client-listen") {
			t.Errorf("missing opt-in guidance: %v", err)
		}
	}
}

func TestDeviceListenerRequiresExplicitLoopbackOrContainerBindingAndStrongTokens(t *testing.T) {
	for _, address := range []string{":0", "localhost:0", "192.168.1.2:0"} {
		for _, allow := range []bool{false, true} {
			if listener, err := listenForDevice(address, strings.Repeat("x", 32), allow); err == nil {
				listener.Close()
				t.Fatalf("unsupported address %s accepted with opt-in %v", address, allow)
			}
		}
	}
	for _, test := range []struct {
		address string
		allow   bool
	}{
		{"127.0.0.1:0", false}, {"[::1]:0", false}, {"127.0.0.1:0", true},
		{"0.0.0.0:0", true}, {"[::]:0", true},
	} {
		listener, err := listenForDevice(test.address, strings.Repeat("x", 32), test.allow)
		if err != nil {
			t.Fatal(err)
		}
		listener.Close()
		if listener, err := listenForDevice(test.address, "short", test.allow); err == nil {
			listener.Close()
			t.Fatal("weak token accepted")
		}
	}
}

func TestCoordinatorLoopBoundsDetachedCallsAndCancelsInFlightWork(t *testing.T) {
	for _, source := range []string{"request", "shutdown"} {
		t.Run(source, func(t *testing.T) {
			c, _, _ := newFixture(t)
			lifetime, stop := context.WithCancel(t.Context())
			request, cancel := context.WithCancel(t.Context())
			defer cancel()
			loop := newCoordinatorLoop(lifetime, c)
			done := make(chan struct{})
			go func() { defer close(done); loop.run() }()
			defer func() { stop(); <-done }()
			if source == "shutdown" {
				request = context.WithoutCancel(lifetime)
				cancel = stop
			}
			err := loop.invoke(request, func(ctx context.Context) error {
				deadline, ok := ctx.Deadline()
				if !ok || time.Until(deadline) > 60*time.Second {
					return errors.New("callback has no bounded deadline")
				}
				cancel()
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(5 * time.Second):
					return errors.New("callback did not receive cancellation")
				}
			})
			if !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
		})
	}
}

func TestConcurrentAcceptsRegisterOnlyOneRunner(t *testing.T) {
	c, w, _, request := localFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	loop := newCoordinatorLoop(ctx, c)
	done := make(chan struct{})
	go func() { defer close(done); loop.run() }()
	defer func() { cancel(); <-done }()
	results := make(chan error, 2)
	for range 2 {
		go func() {
			results <- loop.invoke(t.Context(), func(ctx context.Context) error {
				_, err := c.acceptDevice(ctx, request)
				return err
			})
		}()
	}
	accepted := 0
	for range 2 {
		if err := <-results; err == nil {
			accepted++
		} else {
			var rejected *deviceError
			if !errors.As(err, &rejected) || rejected.status != http.StatusGone {
				t.Fatal(err)
			}
		}
	}
	if accepted != 1 || len(w.events) != 1 || w.events[0] != "register" {
		t.Fatalf("accepted %d, events %v", accepted, w.events)
	}
}

func TestDeviceRequestRejectsOversizedAndUnknownFields(t *testing.T) {
	c, w, _, _ := localFixture(t)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	loop := newCoordinatorLoop(ctx, c)
	done := make(chan struct{})
	go func() { defer close(done); loop.run() }()
	defer func() { cancel(); <-done }()
	token := strings.Repeat("x", 32)
	handler := deviceHandlerFor(t, loop, token)
	for _, body := range []string{`{"device_id":"` + strings.Repeat("x", 4096) + `"}`, `{"device_id":"x","command":"execute"}`, `{} {}`} {
		request := httptest.NewRequestWithContext(ctx, "POST", "/v1/accept", strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusBadRequest {
			t.Fatalf("bad input accepted: %d", response.Code)
		}
	}
	if len(w.events) != 0 {
		t.Fatal("invalid requests performed provisioning")
	}
}

func TestLocalStateRejectsMixedHostedAndLocalIdentities(t *testing.T) {
	for _, invalid := range []string{"device", "phase", "run", "issued", "accepted-id"} {
		t.Run(invalid, func(t *testing.T) {
			c, _, store, _ := localFixture(t)
			l := singleLease(c.state)
			switch invalid {
			case "device":
				l.Local.DeviceID = "another-device"
			case "phase":
				l.Local.Phase = "unknown"
			case "run":
				l.RunnerID = 7
				l.DispatchIntent = true
				l.RunID = 99
			case "issued":
				l.Local.Phase = localIssued
			case "accepted-id":
				l.Local.Phase = localAccepted
				l.RunnerID = 7
			}
			if err := store.save(c.state); err != nil {
				t.Fatal(err)
			}
			if _, err := store.load(c.state.Config); err == nil {
				t.Fatal("invalid local state accepted")
			}
		})
	}
}
