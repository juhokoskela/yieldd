package main

import (
	"fmt"
	"strings"
)

type bootstrapIdentityError struct {
	runner      string
	expectedRun int64
	observed    workflowRun
}

func identityMismatch(l *lease, run *workflowRun) error {
	failure := &bootstrapIdentityError{runner: l.Name, expectedRun: l.RunID}
	if run != nil {
		failure.observed = *run
	}
	return failure
}

func (e *bootstrapIdentityError) Error() string {
	status := "unexpected"
	switch e.observed.Status {
	case "":
		status = "missing"
	case "queued", "requested", "waiting", "pending", "in_progress", "completed":
		status = e.observed.Status
	}
	title := "unexpected"
	if e.observed.DisplayTitle == "" {
		title = "missing"
	} else if runner, ok := strings.CutPrefix(e.observed.DisplayTitle, "Bootstrap "); ok && runnerNamePattern.MatchString(runner) {
		title = e.observed.DisplayTitle
	}
	// Only generated bootstrap titles are safe to print. An unrelated workflow
	// can put arbitrary input, including credentials, in its display title.
	return fmt.Sprintf("%s: runner=%s expected_run=%d observed_run=%d status=%s title=%s", bootstrapIdentityMismatch, e.runner, e.expectedRun, e.observed.ID, status, title)
}

func (e *bootstrapIdentityError) Unwrap() error { return bootstrapIdentityMismatch }

func onlyBootstrapIdentityErrors(err error) bool {
	switch e := err.(type) {
	case *bootstrapIdentityError:
		return true
	case *journalWriteError:
		return false
	case interface{ Unwrap() []error }:
		causes := e.Unwrap()
		if len(causes) == 0 {
			return false
		}
		for _, cause := range causes {
			if !onlyBootstrapIdentityErrors(cause) {
				return false
			}
		}
		return true
	case interface{ Unwrap() error }:
		return onlyBootstrapIdentityErrors(e.Unwrap())
	default:
		return false
	}
}
