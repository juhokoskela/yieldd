package main

import (
	"bytes"
	"io"
	"sync"
)

// RoundTripper may close or read a body asynchronously. Seal it before deciding
// that no payload was supplied; once any bytes were read, delivery is uncertain.
type requestPayload struct {
	mu               sync.Mutex
	reader           *bytes.Reader
	closed, consumed bool
}

func (p *requestPayload) Read(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return 0, io.ErrClosedPipe
	}
	n, err := p.reader.Read(b)
	if n > 0 {
		p.consumed = true
	}
	return n, err
}

func (p *requestPayload) Close() error {
	p.closeUnread()
	return nil
}

func (p *requestPayload) closeUnread() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closed = true
	return !p.consumed
}

type requestNotSent struct{ cause error }

func (e *requestNotSent) Error() string { return e.cause.Error() }
func (e *requestNotSent) Unwrap() error { return e.cause }
