package main

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"sync"
	"time"
)

// One Mac slot is shared by all repositories for a platform. Queue owners keep
// their durable state; this lock protects only availability and offer snapshots.
type deviceQueue struct {
	mu             sync.Mutex
	availableUntil time.Time
	owner          string
	offer          *deviceOffer
	expires        time.Time
	waiting        []string
	wake           map[string]chan struct{}
	changed        chan struct{}
}

func newDeviceQueue() *deviceQueue {
	return &deviceQueue{wake: make(map[string]chan struct{}), changed: make(chan struct{}, 1)}
}

func (q *deviceQueue) claim(owner string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if !slices.Contains(q.waiting, owner) {
		q.waiting = append(q.waiting, owner)
	}
	if q.owner != "" || !time.Now().Before(q.availableUntil) || q.waiting[0] != owner {
		return false
	}
	q.waiting = q.waiting[1:]
	q.owner = owner
	q.availableUntil = time.Time{}
	return true
}

func (q *deviceQueue) forget(owner string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.waiting = slices.DeleteFunc(q.waiting, func(value string) bool { return value == owner })
	q.wakeNext()
}

func (q *deviceQueue) wakeNext() {
	if q.owner == "" && time.Now().Before(q.availableUntil) && len(q.waiting) != 0 {
		select {
		case q.wake[q.waiting[0]] <- struct{}{}:
		default:
		}
	}
}

func (q *deviceQueue) restore(s *state) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	if s.Lease == nil || s.Lease.Local == nil {
		return nil
	}
	if q.owner != "" && q.owner != s.Owner {
		return errors.New("multiple local assignments occupy one Mac platform; recover their original coordinators before combining repositories")
	}
	q.owner = s.Owner
	q.publish(s)
	return nil
}

func (q *deviceQueue) update(s *state) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.owner != s.Owner {
		return
	}
	q.publish(s)
}

func (q *deviceQueue) publish(s *state) {
	q.offer = nil
	l := s.Lease
	if l == nil || l.Local == nil {
		q.owner = ""
		// Require a new capacity advertisement after guest cleanup.
		q.availableUntil = time.Time{}
	} else if !l.CleanupIntent && l.Local.Phase == localOffered {
		q.offer = &deviceOffer{Owner: s.Owner, Runner: l.Name, Repository: s.Config.Repository, Platform: s.Config.platform(), Architecture: "arm64"}
		q.expires = l.Local.Expires
	}
	select {
	case q.changed <- struct{}{}:
	default:
	}
}

func (q *deviceQueue) pollNow() *deviceOffer {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.owner == "" {
		q.availableUntil = time.Now().Add(availabilityLifetime)
		q.wakeNext()
	}
	remaining := time.Until(q.expires)
	if q.offer == nil || remaining <= 0 || remaining > offerLifetime {
		return nil
	}
	copy := *q.offer
	return &copy
}

type deviceRouter struct {
	device string
	queue  *deviceQueue
	loops  map[string]*coordinatorLoop
	done   <-chan struct{}
}

func newDeviceRouter(device string, done <-chan struct{}, loops []*coordinatorLoop) (*deviceRouter, error) {
	r := &deviceRouter{device: device, queue: newDeviceQueue(), loops: make(map[string]*coordinatorLoop), done: done}
	for _, loop := range loops {
		owner := loop.worker.state.Owner
		if _, exists := r.loops[owner]; exists {
			return nil, errors.New("duplicate coordinator queue identity")
		}
		r.loops[owner] = loop
		r.queue.wake[owner] = loop.capacityChanged
		if err := r.queue.restore(loop.worker.state); err != nil {
			return nil, err
		}
		loop.worker.device = r.queue
	}
	return r, nil
}

func (r *deviceRouter) poll(ctx context.Context, request deviceRequest) (*deviceOffer, error) {
	if request.DeviceID == "" || request.DeviceID != r.device {
		return nil, &deviceError{status: http.StatusForbidden, message: "device identity does not match"}
	}
	timer := time.NewTimer(20 * time.Second)
	defer timer.Stop()
	for {
		select {
		case <-r.done:
			return nil, context.Canceled
		default:
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if offer := r.queue.pollNow(); offer != nil {
			return offer, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-r.done:
			return nil, context.Canceled
		case <-timer.C:
			return nil, nil
		case <-r.queue.changed:
		}
	}
}

func (r *deviceRouter) invoke(ctx context.Context, request deviceRequest, run func(context.Context, *coordinator) error) error {
	loop := r.loops[request.Owner]
	if loop == nil {
		return &deviceError{status: http.StatusConflict, message: "coordinator queue identity does not match; retain local recovery state"}
	}
	return loop.invoke(ctx, func(ctx context.Context) error { return run(ctx, loop.worker) })
}
