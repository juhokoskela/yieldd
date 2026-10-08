package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"reflect"
	"testing"
)

func TestSDKDiagnosticPreservesIdentityWithoutErrorText(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		kind string
	}{
		{"canceled", context.Canceled, "request canceled"},
		{"deadline", context.DeadlineExceeded, "request timed out"},
		{"empty", io.EOF, "empty response"},
		{"truncated", io.ErrUnexpectedEOF, "incomplete response"},
		{"json", &json.SyntaxError{Offset: 7}, "invalid response"},
		{"shape", &json.UnmarshalTypeError{Value: "private-jit", Type: reflect.TypeFor[int]()}, "invalid response"},
		{"network", &url.Error{Op: "GET", URL: "https://private-token", Err: io.ErrClosedPipe}, "request did not complete"},
		{"network-eof", &url.Error{Op: "GET", URL: "https://private-token", Err: io.EOF}, "request did not complete"},
		{"network-deadline", &url.Error{Op: "GET", URL: "https://private-token", Err: context.DeadlineExceeded}, "request timed out"},
		{"unknown", errors.New("private-jit secret-token"), "unclassified error"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cause := fmt.Errorf("private-jit secret-token: %w", tc.err)
			err := &sdkError{"find scale set", cause}
			if err.Error() != "Scale Set API find scale set failed: "+tc.kind+" (response details withheld)" {
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
		{"joined-cancellations", errors.Join(context.Canceled, &callbackError{context.Canceled}), true},
		{"deadline", context.DeadlineExceeded, false},
		{"failure", failure, false},
		{"joined-failure", errors.Join(context.Canceled, failure), false},
		{"nested-provisioning-failure", fmt.Errorf("listener: %w", &callbackError{errors.Join(context.Canceled, failure)}), false},
		{"joined-deadline", errors.Join(context.Canceled, context.DeadlineExceeded), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := onlyCancellation(tc.err); got != tc.only {
				t.Fatalf("onlyCancellation = %v, want %v", got, tc.only)
			}
		})
	}
}
