package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"time"

	"github.com/actions/scaleset"
)

type coordinatorCall struct {
	ctx    context.Context
	run    func(context.Context) error
	result chan error
}

// One event loop owns all coordinator state, including writes that span remote API calls.
type coordinatorLoop struct {
	worker         *coordinator
	ctx            context.Context
	calls          chan coordinatorCall
	changed        chan struct{}
	demandObserved bool
}

func newCoordinatorLoop(ctx context.Context, worker *coordinator) *coordinatorLoop {
	return &coordinatorLoop{worker: worker, ctx: ctx, calls: make(chan coordinatorCall), changed: make(chan struct{}, 1)}
}

func (s *coordinatorLoop) run() error {
	timer := time.NewTimer(0)
	timer.Stop()
	defer timer.Stop()
	for {
		var expired <-chan time.Time
		l := s.worker.state.Lease
		// On restart, let GitHub retract obsolete demand before starting paid fallback.
		if s.demandObserved && l != nil && !l.CleanupIntent && l.Local != nil && l.Local.Phase == localOffered {
			delay := time.Until(l.Local.Expires)
			if l.Local.expired() {
				delay = 0
			}
			timer.Reset(delay)
			expired = timer.C
		}
		select {
		case <-s.ctx.Done():
			return nil
		case <-expired:
			if s.ctx.Err() != nil {
				return nil
			}
			ctx, cancel := context.WithTimeout(s.ctx, 60*time.Second)
			_, err := s.worker.reconcileLocal(ctx, false)
			cancel()
			if err != nil {
				return &provisioningError{err}
			}
		case call := <-s.calls:
			ctx, cancel := context.WithTimeout(call.ctx, 60*time.Second)
			// The upstream listener detaches callback cancellation; restore shutdown here.
			stop := context.AfterFunc(s.ctx, cancel)
			err := s.ctx.Err()
			if err == nil {
				err = ctx.Err()
			}
			if err == nil {
				err = call.run(ctx)
			}
			stop()
			cancel()
			call.result <- err
		}
		timer.Stop()
	}
}

func (s *coordinatorLoop) invoke(ctx context.Context, run func(context.Context) error) error {
	call := coordinatorCall{ctx: ctx, run: run, result: make(chan error, 1)}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.ctx.Done():
		return s.ctx.Err()
	case s.calls <- call:
	}
	// Once accepted, wait for the owner to finish before the caller can read its result values.
	return <-call.result
}

func (s *coordinatorLoop) HandleDesiredRunnerCount(ctx context.Context, count int) (int, error) {
	var actual int
	err := s.invoke(ctx, func(ctx context.Context) (err error) {
		s.demandObserved = true
		actual, err = s.worker.HandleDesiredRunnerCount(ctx, count)
		return err
	})
	select {
	case s.changed <- struct{}{}:
	default:
	}
	return actual, err
}
func (s *coordinatorLoop) HandleJobStarted(ctx context.Context, job *scaleset.JobStarted) error {
	return s.invoke(ctx, func(ctx context.Context) error { return s.worker.HandleJobStarted(ctx, job) })
}
func (s *coordinatorLoop) HandleJobCompleted(ctx context.Context, job *scaleset.JobCompleted) error {
	return s.invoke(ctx, func(ctx context.Context) error { return s.worker.HandleJobCompleted(ctx, job) })
}

func listenForDevice(address, token string) (net.Listener, error) {
	host, _, err := net.SplitHostPort(address)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		return nil, errors.New("client-listen must use a loopback IP; terminate remote HTTPS at a trusted local proxy")
	}
	if len(token) < 32 || len(token) > 256 {
		return nil, errors.New("YIELDD_CLIENT_TOKEN must contain 32 to 256 non-whitespace characters")
	}
	for _, character := range []byte(token) {
		if character < 33 || character > 126 {
			return nil, errors.New("YIELDD_CLIENT_TOKEN must contain printable ASCII characters")
		}
	}
	return net.Listen("tcp", address)
}

func (s *coordinatorLoop) deviceHandler(token string) http.Handler {
	expected := sha256.Sum256([]byte("Bearer " + token))
	pollSlot := make(chan struct{}, 1)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		provided := sha256.Sum256([]byte(r.Header.Get("Authorization")))
		if subtle.ConstantTimeCompare(expected[:], provided[:]) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "POST required", http.StatusMethodNotAllowed)
			return
		}
		switch r.URL.Path {
		case "/v1/poll", "/v1/accept", "/v1/complete":
		default:
			http.NotFound(w, r)
			return
		}
		var request deviceRequest
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&request); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		if decoder.Decode(new(any)) != io.EOF {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		var response any
		var err error
		switch r.URL.Path {
		case "/v1/poll":
			select {
			case pollSlot <- struct{}{}:
				defer func() { <-pollSlot }()
			default:
				http.Error(w, "one poll per device", http.StatusConflict)
				return
			}
			offer, pollErr := s.poll(r.Context(), request)
			if pollErr != nil {
				err = pollErr
			} else if offer == nil {
				w.WriteHeader(http.StatusNoContent)
				return
			} else {
				response = offer
			}
		case "/v1/accept":
			err = s.invoke(r.Context(), func(ctx context.Context) error {
				credential, acceptErr := s.worker.acceptDevice(ctx, request)
				response = credential
				return acceptErr
			})
		case "/v1/complete":
			err = s.invoke(r.Context(), func(ctx context.Context) error { return s.worker.completeDevice(ctx, request) })
			response = struct{}{}
		default:
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		if err != nil {
			if onlyCancellation(err) {
				http.Error(w, "coordinator is stopping; retry with the same recovery state", http.StatusServiceUnavailable)
				return
			}
			var rejection *deviceError
			if errors.As(err, &rejection) {
				http.Error(w, rejection.message, rejection.status)
			} else {
				s.worker.logger.Error("Device request failed", "error", err)
				http.Error(w, "coordinator operation failed; retain local recovery state", http.StatusServiceUnavailable)
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(response)
	})
}

func (s *coordinatorLoop) poll(ctx context.Context, request deviceRequest) (*deviceOffer, error) {
	timer := time.NewTimer(20 * time.Second)
	defer timer.Stop()
	for {
		var offer *deviceOffer
		err := s.invoke(ctx, func(context.Context) (err error) { offer, err = s.worker.pollDevice(request); return err })
		if err != nil || offer != nil {
			return offer, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-s.ctx.Done():
			return nil, s.ctx.Err()
		case <-timer.C:
			return nil, nil
		case <-s.changed:
		}
	}
}
