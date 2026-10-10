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
	return fmt.Sprintf("Scale Set API %s failed: %s (response details withheld)", e.operation, failureKind(e.cause))
}

func failureKind(err error) string {
	var syntax *json.SyntaxError
	var shape *json.UnmarshalTypeError
	var network net.Error
	if errors.Is(err, context.Canceled) {
		return "request canceled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "request timed out"
	}
	if errors.As(err, &network) {
		if network.Timeout() {
			return "request timed out"
		}
		return "request did not complete"
	}
	if errors.Is(err, io.EOF) {
		return "empty response"
	}
	if errors.Is(err, io.ErrUnexpectedEOF) {
		return "incomplete response"
	}
	if errors.As(err, &syntax) || errors.As(err, &shape) {
		return "invalid response"
	}
	return "unclassified error"
}
func (e *sdkError) Unwrap() error { return e.cause }

// Coordinator callback failures must not be retried as SDK listener failures.
type callbackError struct{ cause error }

func (e *callbackError) Error() string { return e.cause.Error() }
func (e *callbackError) Unwrap() error { return e.cause }
