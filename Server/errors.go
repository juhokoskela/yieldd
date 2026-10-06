package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
)

var runnerStillBusy = errors.New("runner is still busy; cleanup obligation retained")

func transientFailure(err error) bool {
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		causes := joined.Unwrap()
		if len(causes) == 0 {
			return false
		}
		for _, cause := range causes {
			if !transientFailure(cause) {
				return false
			}
		}
		return true
	}
	if err == context.DeadlineExceeded || err == io.EOF || err == runnerStillBusy {
		return true
	}
	if _, ok := err.(net.Error); ok {
		return true
	}
	if wrapped, ok := err.(interface{ Unwrap() error }); ok {
		return transientFailure(wrapped.Unwrap())
	}
	var api *apiError
	return errors.As(err, &api) && (api.status == 429 || api.status >= 500)
}

func onlyCancellation(err error) bool {
	if err == context.Canceled {
		return true
	}
	switch e := err.(type) {
	case interface{ Unwrap() []error }:
		causes := e.Unwrap()
		if len(causes) == 0 {
			return false
		}
		for _, cause := range causes {
			if !onlyCancellation(cause) {
				return false
			}
		}
		return true
	case interface{ Unwrap() error }:
		return onlyCancellation(e.Unwrap())
	default:
		return false
	}
}

// SDK errors can contain credential-bearing response bodies. Keep their identity, not their text.
type sdkError struct {
	operation string
	cause     error
}

func (e *sdkError) Error() string {
	kind := "unclassified error"
	var syntax *json.SyntaxError
	var shape *json.UnmarshalTypeError
	var network net.Error
	switch {
	case errors.Is(e.cause, context.Canceled):
		kind = "request canceled"
	case errors.Is(e.cause, context.DeadlineExceeded):
		kind = "request deadline exceeded"
	case errors.Is(e.cause, io.EOF):
		kind = "empty or incomplete response"
	case errors.Is(e.cause, io.ErrUnexpectedEOF), errors.As(e.cause, &syntax), errors.As(e.cause, &shape):
		kind = "invalid response JSON"
	case errors.As(e.cause, &network):
		if network.Timeout() {
			kind = "network timeout"
		} else {
			kind = "network failure"
		}
	}
	return fmt.Sprintf("Scale Set API %s failed: %s (response details withheld)", e.operation, kind)
}
func (e *sdkError) Unwrap() error { return e.cause }

// Distinguish our diagnostics from raw SDK errors returned by the listener.
type provisioningError struct{ cause error }

func (e *provisioningError) Error() string { return e.cause.Error() }
func (e *provisioningError) Unwrap() error { return e.cause }
