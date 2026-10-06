package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"testing"
)

func TestSDKDiagnosticPreservesIdentityWithoutErrorText(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		kind string
	}{
		{"canceled", context.Canceled, "request canceled"},
		{"deadline", context.DeadlineExceeded, "request deadline exceeded"},
		{"empty", io.EOF, "empty or incomplete response"},
		{"truncated", io.ErrUnexpectedEOF, "invalid response JSON"},
		{"json", &json.SyntaxError{Offset: 7}, "invalid response JSON"},
		{"network", &url.Error{Op: "GET", URL: "https://private-token", Err: io.ErrClosedPipe}, "network failure"},
		{"unknown", errors.New("private-jit secret-token"), "unclassified error"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cause := fmt.Errorf("private-jit secret-token: %w", tc.err)
			err := &sdkError{"find scale set", cause}
			if !strings.Contains(err.Error(), tc.kind) || strings.Contains(err.Error(), "private") || strings.Contains(err.Error(), "secret-token") {
				t.Fatal("unsafe or incomplete diagnostic", err)
			}
			if !errors.Is(err, tc.err) {
				t.Fatal("error identity lost")
			}
		})
	}
}

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
