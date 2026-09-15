package main

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

func TestOnlyCancellationDoesNotHideJoinedFailures(t *testing.T) {
	failure := errors.New("persist cleanup intent: disk full")
	for _, tc := range []struct {
		name string
		err  error
		only bool
	}{
		{"nil", nil, false},
		{"cancellation", context.Canceled, true},
		{"wrapped-cancellation", fmt.Errorf("listener: %w", context.Canceled), true},
		{"joined-cancellations", errors.Join(context.Canceled, &provisioningError{context.Canceled}), true},
		{"deadline", context.DeadlineExceeded, false},
		{"failure", failure, false},
		{"joined-failure", errors.Join(context.Canceled, failure), false},
		{"nested-provisioning-failure", fmt.Errorf("listener: %w", &provisioningError{errors.Join(context.Canceled, failure)}), false},
		{"joined-deadline", errors.Join(context.Canceled, context.DeadlineExceeded), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := onlyCancellation(tc.err); got != tc.only {
				t.Fatalf("onlyCancellation = %v, want %v", got, tc.only)
			}
		})
	}
}
