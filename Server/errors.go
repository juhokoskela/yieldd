package main

import (
	"context"
	"fmt"
)

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
	return fmt.Sprintf("Scale Set API %s failed (response details withheld)", e.operation)
}
func (e *sdkError) Unwrap() error { return e.cause }

// Distinguish our diagnostics from raw SDK errors returned by the listener.
type provisioningError struct{ cause error }

func (e *provisioningError) Error() string { return e.cause.Error() }
func (e *provisioningError) Unwrap() error { return e.cause }
