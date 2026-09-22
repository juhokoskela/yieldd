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
	lease          localLease
	waiting        []string
	wake           map[string]chan struct{}
	changed        chan struct{}
}

func newDeviceQueue(wake map[string]chan struct{}) *deviceQueue {
	return &deviceQueue{wake: wake, changed: make(chan struct{}, 1)}
}

func (q *deviceQueue) wait(owner string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if !slices.Contains(q.waiting, owner) {
		q.waiting = append(q.waiting, owner)
	}
	q.wakeNext()
}

func (q *deviceQueue) claim(owner string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.owner != "" || !time.Now().Before(q.availableUntil) || (len(q.waiting) != 0 && q.waiting[0] != owner) {
		return false
	}
	if len(q.waiting) != 0 {
		q.waiting = q.waiting[1:]
	}
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
		q.lease = *l.Local
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
	if q.offer == nil || q.lease.expired() {
		return nil
	}
	offer := *q.offer
	return &offer
}

type deviceRouter struct {
	device string
	queue  *deviceQueue
	loops  map[string]*coordinatorLoop
}

func newDeviceRouter(device string, loops []*coordinatorLoop) (*deviceRouter, error) {
	d := &deviceRouter{device: device, loops: make(map[string]*coordinatorLoop)}
	wake := make(map[string]chan struct{}, len(loops))
	for _, loop := range loops {
		owner := loop.worker.state.Owner
		if _, exists := d.loops[owner]; exists {
			return nil, errors.New("duplicate coordinator queue identity")
		}
		d.loops[owner] = loop
		wake[owner] = loop.capacityChanged
	}
	d.queue = newDeviceQueue(wake)
	for _, loop := range loops {
		if err := d.queue.restore(loop.worker.state); err != nil {
			return nil, err
		}
		loop.worker.device = d.queue
	}
	return d, nil
}

func (d *deviceRouter) poll(ctx context.Context, request deviceRequest) (*deviceOffer, error) {
	if request.DeviceID == "" || request.DeviceID != d.device {
		return nil, &deviceError{status: http.StatusForbidden, message: "device identity does not match"}
	}
	timer := time.NewTimer(20 * time.Second)
	defer timer.Stop()
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if offer := d.queue.pollNow(); offer != nil {
			return offer, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
			return nil, nil
		case <-d.queue.changed:
		}
	}
}

func (d *deviceRouter) invoke(ctx context.Context, request deviceRequest, run func(context.Context, *coordinator) error) error {
	loop := d.loops[request.Owner]
	if loop == nil {
		return &deviceError{status: http.StatusConflict, message: "coordinator queue identity does not match; retain local recovery state"}
	}
	err := loop.invoke(ctx, func(ctx context.Context) error { return run(ctx, loop.worker) })
	var rejection *deviceError
	if err != nil && !onlyCancellation(err) && !errors.As(err, &rejection) {
		loop.worker.logger.Error("Device request failed", "error", err)
	}
	return err
}
