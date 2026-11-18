package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/actions/scaleset"
)

func TestDeviceHTTPValidationAndShutdownDiagnostics(t *testing.T) {
	c, _, _, request := localFixture(t)
	var logs bytes.Buffer
	c.logger = slog.New(slog.NewTextHandler(&logs, nil))
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	handler := deviceHandlerFor(t, newCoordinatorLoop(ctx, c), strings.Repeat("x", 32))
	body, _ := json.Marshal(request)
	for _, test := range []struct {
		method, path, body string
		status             int
	}{
		{"GET", "/v1/poll", "", 405}, {"POST", "/v1/bogus", "", 404},
		{"POST", "/v1/bogus", string(body), 404}, {"POST", "/v1/poll", string(body), 503},
	} {
		req := httptest.NewRequest(test.method, test.path, strings.NewReader(test.body))
		req = req.WithContext(ctx)
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
	handler := deviceHandlerFor(t, loop, strings.Repeat("x", 32))
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handler.ServeHTTP(w, r)
		close(issued)
		<-release
	}))
	server.Config.BaseContext = func(net.Listener) context.Context { return ctx }
	server.Start()
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

func TestDeviceLongPollStopsWithServerBaseContext(t *testing.T) {
	c, _, _ := newFixture(t)
	c.state.Config.DeviceID = testDevice
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	entered := make(chan struct{})
	token := strings.Repeat("x", 32)
	handler := deviceHandlerFor(t, newCoordinatorLoop(ctx, c), token)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		handler.ServeHTTP(w, r)
	}))
	server.Config.BaseContext = func(net.Listener) context.Context { return ctx }
	server.Start()
	defer server.Close()
	request, err := http.NewRequestWithContext(t.Context(), "POST", server.URL+"/v1/poll", strings.NewReader(`{"device_id":"`+testDevice+`"}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	response := make(chan int, 1)
	go func() {
		client := &http.Client{Timeout: 2 * time.Second}
		res, err := client.Do(request)
		if err != nil {
			response <- 0
			return
		}
		res.Body.Close()
		response <- res.StatusCode
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		cancel()
		t.Fatal("poll did not reach server")
	}
	cancel()
	if status := <-response; status != http.StatusServiceUnavailable {
		t.Fatal("poll did not exit on server cancellation", status)
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
				handler := deviceHandlerFor(t, loop, strings.Repeat("x", 32))
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

func TestDeviceJournalErrorAfterPublicationStopsQueue(t *testing.T) {
	for _, phase := range []localPhase{localAccepted, localIssued} {
		t.Run(string(phase), func(t *testing.T) {
			c, _, store, req := localFixture(t)
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			loop := newCoordinatorLoop(ctx, c)
			token := strings.Repeat("x", 32)
			h := deviceHandlerFor(t, loop, token)
			failure := errors.New("directory sync failed after rename")
			c.save = func(s *state) error {
				if err := store.save(s); err != nil {
					return err
				}
				if s.Leases[req.Runner].Local.Phase == phase {
					return failure
				}
				return nil
			}
			done := make(chan error, 1)
			go func() { done <- loop.run() }()
			body, _ := json.Marshal(req)
			r := httptest.NewRequest("POST", "/v1/accept", bytes.NewReader(body)).WithContext(ctx)
			r.Header.Set("Authorization", "Bearer "+token)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != 503 {
				t.Fatal(w.Code)
			}
			select {
			case err := <-done:
				if !errors.Is(err, failure) {
					t.Fatal(err)
				}
			case <-ctx.Done():
				t.Fatal("queue continued after uncertain publication")
			}
			saved, err := store.load(c.state.Config)
			if err != nil || saved.Leases[req.Runner].Local.Phase != phase {
				t.Fatal(saved, err)
			}
			if phase == localIssued {
				if saved.Leases[req.Runner].RunnerID == 0 || strings.Contains(w.Body.String(), "private-jit") {
					t.Fatal("issued obligation was lost or credentials disclosed")
				}
				c.state, c.save = saved, store.save
				if done, err := c.reconcile(ctx, true); done || err == nil {
					t.Fatal("restart released issued runner", err)
				}
				if err := c.completeDevice(ctx, req); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestDeviceFinalResultReadsTheMatchedLeaseWithoutGitHub(t *testing.T) {
	c, _, _, request := localFixture(t)
	if _, err := c.acceptDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	id := c.state.Leases[request.Runner].RunnerID
	c.bootstrap, c.runners = nil, nil
	ctx, cancel := context.WithCancel(t.Context())
	loop := newCoordinatorLoop(ctx, c)
	handler := deviceHandlerFor(t, loop, strings.Repeat("x", 32))
	startLoops(t, cancel, []*coordinatorLoop{loop})
	check := func(req deviceRequest, want string) {
		t.Helper()
		response := requestDevice(handler, "job-result", req)
		var got deviceJobResult
		if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil || response.Code != http.StatusOK || got.Result != want {
			t.Fatalf("job result: %d %s; want %q", response.Code, response.Body, want)
		}
	}
	check(request, "pending")
	if err := loop.HandleJobCompleted(ctx, &scaleset.JobCompleted{RunnerName: request.Runner, RunnerID: id, Result: "Succeeded"}); err != nil {
		t.Fatal(err)
	}
	check(request, "succeeded")
	wrong := request
	wrong.Slot++
	check(wrong, "unavailable")
}
