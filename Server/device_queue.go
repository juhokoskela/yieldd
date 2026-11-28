package main

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"sync"
	"time"
)

type deviceSlot struct {
	availableUntil time.Time
	owner          string
	releasedOwner  string
	runner         string
	offer          *deviceOffer
	lease          localLease
	changed        chan struct{}
}

func (s *deviceSlot) idle(now time.Time) bool {
	return s.owner == "" && now.Before(s.availableUntil)
}

// Capacity is advertised by idle Mac workers, not inferred from repository demand.
type deviceQueue struct {
	mu      sync.Mutex
	slots   [maximumAssignments]deviceSlot
	waiting []string
	wake    map[string]chan struct{}
}

func newDeviceQueue(wake map[string]chan struct{}) *deviceQueue {
	q := &deviceQueue{wake: wake}
	for i := range q.slots {
		q.slots[i].changed = make(chan struct{}, 1)
	}
	return q
}

func (q *deviceQueue) wait(owner string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if !slices.Contains(q.waiting, owner) {
		q.waiting = append(q.waiting, owner)
	}
	q.wakeNext()
}

func (q *deviceQueue) claim(owner, runner string) (int, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.waiting) != 0 && q.waiting[0] != owner {
		return 0, false
	}
	now := time.Now()
	for i := range q.slots {
		slot := &q.slots[i]
		if !slot.idle(now) {
			continue
		}
		if len(q.waiting) != 0 {
			q.waiting = q.waiting[1:]
		}
		slot.owner, slot.runner, slot.availableUntil = owner, runner, time.Time{}
		q.wakeNext()
		return i, true
	}
	return 0, false
}

func (q *deviceQueue) forget(owner string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.waiting = slices.DeleteFunc(q.waiting, func(value string) bool { return value == owner })
	q.wakeNext()
}

func (q *deviceQueue) redrive(owner string) {
	select {
	case q.wake[owner] <- struct{}{}:
	default:
	}
}

func (q *deviceQueue) wakeNext() {
	if len(q.waiting) == 0 {
		return
	}
	now := time.Now()
	for i := range q.slots {
		if q.slots[i].idle(now) {
			q.redrive(q.waiting[0])
			return
		}
	}
}

func (q *deviceQueue) restore(s *state) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, l := range s.Leases {
		if l.Local == nil {
			continue
		}
		slot := &q.slots[l.Local.Slot]
		if slot.owner != "" {
			return errors.New("multiple local assignments occupy one Mac slot; recover their original coordinators before combining repositories")
		}
		slot.owner, slot.runner = s.Owner, l.Name
	}
	q.publish(s)
	return nil
}

func (q *deviceQueue) clearAvailability(index int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	slot := &q.slots[index]
	if slot.owner == "" {
		slot.availableUntil = time.Time{}
	}
}

func (q *deviceQueue) slotIdle(index int) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.slots[index].idle(time.Now())
}

func (q *deviceQueue) expireAllAvailability() {
	q.mu.Lock()
	defer q.mu.Unlock()
	for i := range q.slots {
		if q.slots[i].owner == "" {
			q.slots[i].availableUntil = time.Time{}
		}
	}
}

func (q *deviceQueue) update(s *state) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.publish(s)
}

func (q *deviceQueue) publish(s *state) {
	for i := range q.slots {
		slot := &q.slots[i]
		if slot.owner != s.Owner {
			continue
		}
		previousOffer, previousLease := slot.offer, slot.lease
		slot.offer = nil
		l := s.Leases[slot.runner]
		if l == nil || l.Local == nil {
			slot.releasedOwner = slot.owner
			slot.owner, slot.runner, slot.availableUntil = "", "", time.Time{}
		} else if !l.CleanupIntent && l.Local.Phase == localOffered {
			slot.offer = &deviceOffer{Slot: i, Owner: s.Owner, Runner: l.Name, Repository: s.Config.Repository, Platform: s.Config.platform(), Architecture: "arm64"}
			slot.lease = *l.Local
		}
		if (previousOffer == nil) != (slot.offer == nil) || (previousOffer != nil && slot.offer != nil && (*previousOffer != *slot.offer || previousLease != slot.lease)) {
			select {
			case slot.changed <- struct{}{}:
			default:
			}
		}
	}
}

func (q *deviceQueue) pollNow(index int) *deviceOffer {
	q.mu.Lock()
	defer q.mu.Unlock()
	slot := &q.slots[index]
	if slot.owner == "" {
		slot.availableUntil = time.Now().Add(availabilityLifetime)
		q.wakeNext()
		// Refresh completed demand only once the Mac advertises new capacity.
		q.redrive(slot.releasedOwner)
		slot.releasedOwner = ""
	}
	if slot.offer == nil || slot.lease.expired() {
		return nil
	}
	offer := *slot.offer
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
			d.queue.clearAvailability(request.Slot)
			return nil, err
		}
		if offer := d.queue.pollNow(request.Slot); offer != nil {
			return offer, nil
		}
		select {
		case <-ctx.Done():
			d.queue.clearAvailability(request.Slot)
			return nil, ctx.Err()
		case <-timer.C:
			return nil, nil
		case <-d.queue.slots[request.Slot].changed:
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
