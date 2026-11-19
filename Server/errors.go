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
	return !isJournalWrite(err) && allCauses(err, transientCause)
}

func transientCause(err error) bool {
	if err == context.DeadlineExceeded || err == io.EOF || err == runnerStillBusy {
		return true
	}
	if _, ok := err.(net.Error); ok {
		return true
	}
	api, ok := err.(*apiError)
	return ok && (api.status == 429 || api.status >= 500)
}

func allCauses(err error, matches func(error) bool) bool {
	if err == nil {
		return false
	}
	if matches(err) {
		return true
	}
	switch e := err.(type) {
	case interface{ Unwrap() []error }:
		causes := e.Unwrap()
		if len(causes) == 0 {
			return false
		}
		for _, cause := range causes {
			if !allCauses(cause, matches) {
				return false
			}
		}
		return true
	case interface{ Unwrap() error }:
		return allCauses(e.Unwrap(), matches)
	default:
		return false
	}
}

func onlyCancellation(err error) bool {
	return !isJournalWrite(err) && allCauses(err, func(err error) bool { return err == context.Canceled })
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
