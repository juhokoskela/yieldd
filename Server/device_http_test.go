package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

func TestDeviceHTTPValidationAndShutdownDiagnostics(t *testing.T) {
	c, _, _, request := localFixture(t)
	var logs bytes.Buffer
	c.logger = slog.New(slog.NewTextHandler(&logs, nil))
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	handler := newCoordinatorLoop(ctx, c).deviceHandler(strings.Repeat("x", 32))
	body, _ := json.Marshal(request)
	for _, test := range []struct {
		method, path, body string
		status             int
	}{
		{"GET", "/v1/poll", "", 405}, {"POST", "/v1/bogus", "", 404},
		{"POST", "/v1/bogus", string(body), 404}, {"POST", "/v1/poll", string(body), 503},
	} {
		req := httptest.NewRequest(test.method, test.path, strings.NewReader(test.body))
		req.Header.Set("Authorization", "Bearer "+strings.Repeat("x", 32))
		out := httptest.NewRecorder()
		handler.ServeHTTP(out, req)
		if out.Code != test.status {
			t.Fatal(out.Code, test.status)
		}
		if out.Code == 405 && out.Header().Get("Allow") != "POST" {
			t.Fatal("missing Allow")
		}
	}
	if logs.Len() != 0 {
		t.Fatal("shutdown logged as failure", logs.String())
	}
}

func TestDeviceHTTPDrainDeliversAlreadyIssuedCredential(t *testing.T) {
	c, _, _, request := localFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	loop := newCoordinatorLoop(ctx, c)
	loopDone := make(chan struct{})
	go func() { defer close(loopDone); loop.run() }()
	defer func() { cancel(); <-loopDone }()
	issued := make(chan struct{})
	release := make(chan struct{})
	handler := loop.deviceHandler(strings.Repeat("x", 32))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handler.ServeHTTP(w, r)
		close(issued)
		<-release
	}))
	defer server.Close()
	stopping := make(chan struct{})
	server.Config.RegisterOnShutdown(func() { close(stopping) })
	body, _ := json.Marshal(request)
	req, _ := http.NewRequestWithContext(t.Context(), "POST", server.URL+"/v1/accept", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+strings.Repeat("x", 32))
	response := make(chan error, 1)
	go func() {
		client := &http.Client{Timeout: 5 * time.Second}
		res, err := client.Do(req)
		if err == nil {
			defer res.Body.Close()
			var value deviceCredential
			err = json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&value)
			if err == nil && value.JIT != "private-jit" {
				err = io.ErrUnexpectedEOF
			}
		}
		response <- err
	}()
	select {
	case <-issued:
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("acceptance did not finish")
	}
	cancel()
	drained := make(chan error, 1)
	go func() { drained <- drainDeviceHTTP(server.Config) }()
	<-stopping
	select {
	case err := <-drained:
		close(release)
		t.Fatal("drain did not await handler", err)
	default:
	}
	close(release)
	if err := <-drained; err != nil {
		t.Fatal(err)
	}
	if err := <-response; err != nil {
		t.Fatal(err)
	}
}

func TestLongPollTimeoutAndWakeup(t *testing.T) {
	for _, wake := range []bool{false, true} {
		t.Run(map[bool]string{false: "timeout", true: "wakeup"}[wake], func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				c, _, _ := newFixture(t)
				c.state.Config.DeviceID = testDevice
				ctx, cancel := context.WithCancel(t.Context())
				loop := newCoordinatorLoop(ctx, c)
				done := make(chan struct{})
				go func() { defer close(done); loop.run() }()
				defer func() { cancel(); <-done }()
				handler := loop.deviceHandler(strings.Repeat("x", 32))
				request := func(device string) *httptest.ResponseRecorder {
					r := httptest.NewRequest("POST", "/v1/poll", strings.NewReader(`{"device_id":"`+device+`"}`))
					r.Header.Set("Authorization", "Bearer "+strings.Repeat("x", 32))
					out := httptest.NewRecorder()
					handler.ServeHTTP(out, r)
					return out
				}
				out := make(chan *httptest.ResponseRecorder, 1)
				go func() { out <- request(testDevice) }()
				synctest.Wait()
				if got := request(testDevice); got.Code != 409 {
					t.Fatal(got.Code)
				}
				if wake {
					if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
						t.Fatal(err)
					}
				} else {
					time.Sleep(20 * time.Second)
				}
				got := <-out
				if wake && got.Code != 200 || !wake && got.Code != 204 {
					t.Fatal(got.Code)
				}
				if !wake && got.Header().Get("Content-Type") != "" {
					t.Fatal(got.Header())
				}
				if got := request("wrong"); got.Code != 403 {
					t.Fatal(got.Code)
				}
			})
		})
	}
}

func TestQueuedPollRefreshesAvailabilityAfterSlowHostedPreparation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c, w, _ := newFixture(t)
		c.state.Config.DeviceID = testDevice
		ctx, cancel := context.WithCancel(t.Context())
		loop := newCoordinatorLoop(ctx, c)
		done := make(chan struct{})
		go func() { defer close(done); loop.run() }()
		defer func() { cancel(); <-done }()
		entered := make(chan struct{})
		release := make(chan struct{})
		w.afterSecret = func() { close(entered); <-release }
		provision := make(chan error, 1)
		go func() { _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); provision <- err }()
		<-entered
		polled := make(chan error, 1)
		go func() {
			polled <- loop.invoke(t.Context(), func(context.Context) error { _, err := c.pollDevice(deviceRequest{DeviceID: testDevice}); return err })
		}()
		synctest.Wait()
		time.Sleep(35 * time.Second)
		close(release)
		if err := <-provision; err != nil {
			t.Fatal(err)
		}
		if err := <-polled; err != nil {
			t.Fatal(err)
		}
		w.run.Status = "completed"
		w.run.Conclusion = "success"
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		if _, err := loop.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		if c.state.Lease.Local == nil {
			t.Fatal("fresh pending poll lost preference")
		}
	})
}
