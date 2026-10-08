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

const cleanupRetryDelay = 5 * time.Second

type coordinatorCall struct {
	ctx    context.Context
	run    func(context.Context) error
	result chan error
}

// One event loop owns all coordinator state, including writes that span remote API calls.
type coordinatorLoop struct {
	worker          *coordinator
	ctx             context.Context
	calls           chan coordinatorCall
	capacityChanged chan struct{}
	demandObserved  bool
	desiredCount    int
}

func newCoordinatorLoop(ctx context.Context, worker *coordinator) *coordinatorLoop {
	return &coordinatorLoop{worker: worker, ctx: ctx, calls: make(chan coordinatorCall), capacityChanged: make(chan struct{}, 1)}
}

func (s *coordinatorLoop) run() error {
	timer := time.NewTimer(0)
	timer.Stop()
	defer timer.Stop()
	var retryAt time.Time
	for {
		var expired <-chan time.Time

		var deadline time.Time
		cleanupPending := false
		for _, l := range s.worker.state.Leases {
			if l.Local == nil {
				continue
			}
			if l.CleanupIntent {
				cleanupPending = true
				continue
			}
			if l.Local.Phase == localAccepted || l.Local.Phase == localDeclined || (s.demandObserved && l.Local.Phase == localOffered) {
				when := l.Local.Expires
				if l.Local.expired() {
					when = time.Now()
				}
				if deadline.IsZero() || when.Before(deadline) {
					deadline = when
				}
			}
		}
		if cleanupPending {
			if retryAt.IsZero() {
				retryAt = time.Now().Add(cleanupRetryDelay)
			}
			if deadline.IsZero() || retryAt.Before(deadline) {
				deadline = retryAt
			}
		} else {
			retryAt = time.Time{}
		}
		if !deadline.IsZero() {
			timer.Reset(time.Until(deadline))
			expired = timer.C
		}

		select {
		case <-s.ctx.Done():
			return nil
		case <-s.capacityChanged:
			if s.demandObserved {
				if err := s.redrive(); err != nil {
					return err
				}
			}
		case <-expired:
			retryAt = time.Time{}
			if err := s.redrive(); err != nil {
				return err
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

func (s *coordinatorLoop) redrive() error {
	if s.ctx.Err() != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(s.ctx, 60*time.Second)
	defer cancel()
	_, err := s.worker.HandleDesiredRunnerCount(ctx, s.desiredCount)
	return err
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
		s.desiredCount = count
		actual, err = s.worker.HandleDesiredRunnerCount(ctx, count)
		return err
	})
	return actual, err
}
func (s *coordinatorLoop) HandleJobStarted(ctx context.Context, job *scaleset.JobStarted) error {
	err := s.invoke(ctx, func(ctx context.Context) error { return s.worker.HandleJobStarted(ctx, job) })
	if err != nil {
		return &callbackError{err}
	}
	return nil
}
func (s *coordinatorLoop) HandleJobCompleted(ctx context.Context, job *scaleset.JobCompleted) error {
	err := s.invoke(ctx, func(ctx context.Context) error { return s.worker.HandleJobCompleted(ctx, job) })
	if err != nil {
		return &callbackError{err}
	}
	return nil
}

func listenForDevice(address, token string, allowNonLoopback bool) (net.Listener, error) {
	host, _, err := net.SplitHostPort(address)
	ip := net.ParseIP(host)
	if err != nil || ip == nil || (!ip.IsLoopback() && !ip.IsUnspecified()) {
		return nil, errors.New("client-listen must use a loopback or unspecified IP address")
	}
	if !ip.IsLoopback() && !allowNonLoopback {
		return nil, errors.New("non-loopback device HTTP requires --allow-non-loopback-client-listen; use it only inside a container with a loopback-only published port and an HTTPS proxy")
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

func (d *deviceRouter) deviceHandler(token string) http.Handler {
	expected := sha256.Sum256([]byte("Bearer " + token))
	var pollSlots [maximumAssignments]chan struct{}
	for i := range pollSlots {
		pollSlots[i] = make(chan struct{}, 1)
	}
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
		case "/v1/poll", "/v1/accept", "/v1/decline", "/v1/complete", "/v1/renew":
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
		if request.Slot < 0 || request.Slot >= maximumAssignments {
			http.Error(w, "invalid worker slot", http.StatusBadRequest)
			return
		}
		var response any
		var err error
		switch r.URL.Path {
		case "/v1/poll":
			select {
			case pollSlots[request.Slot] <- struct{}{}:
				defer func() { <-pollSlots[request.Slot] }()
			default:
				http.Error(w, "one poll per worker slot", http.StatusConflict)
				return
			}
			offer, pollErr := d.poll(r.Context(), request)
			if pollErr != nil {
				err = pollErr
			} else if offer == nil {
				w.WriteHeader(http.StatusNoContent)
				return
			} else {
				response = offer
			}
		case "/v1/accept":
			err = d.invoke(r.Context(), request, func(ctx context.Context, worker *coordinator) error {
				credential, acceptErr := worker.acceptDevice(ctx, request)
				response = credential
				return acceptErr
			})
		case "/v1/complete":
			err = d.invoke(r.Context(), request, func(ctx context.Context, worker *coordinator) error { return worker.completeDevice(ctx, request) })
			response = struct{}{}
		case "/v1/decline":
			err = d.invoke(r.Context(), request, func(_ context.Context, worker *coordinator) error { return worker.declineDevice(request) })
			response = struct{}{}
		case "/v1/renew":
			err = d.invoke(r.Context(), request, func(ctx context.Context, worker *coordinator) error {
				var renewalErr error
				response, renewalErr = worker.renewDevice(ctx, request)
				return renewalErr
			})
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
				http.Error(w, "coordinator operation failed; retain local recovery state", http.StatusServiceUnavailable)
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(response)
	})
}
