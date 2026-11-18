package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
)

func identityMismatch(l *lease, run *workflowRun) error {
	var observed workflowRun
	if run != nil {
		observed = *run
	}
	status := "unexpected"
	switch observed.Status {
	case "":
		status = "missing"
	case "queued", "requested", "waiting", "pending", "in_progress", "completed", "action_required":
		status = observed.Status
	}
	title := "unexpected"
	if observed.DisplayTitle == "" {
		title = "missing"
	} else if runner, ok := strings.CutPrefix(observed.DisplayTitle, "Bootstrap "); ok && runnerNamePattern.MatchString(runner) {
		title = observed.DisplayTitle
	}
	// Only generated bootstrap titles are safe to print. An unrelated workflow
	// can put arbitrary input, including credentials, in its display title.
	return fmt.Errorf("%w: runner=%s expected_run=%d observed_run=%d status=%s title=%s", bootstrapIdentityMismatch, l.Name, l.RunID, observed.ID, status, title)
}

// Only an observation can authorize another automatic verification attempt.
type temporaryStatusError struct{ cause error }

func (e *temporaryStatusError) Error() string { return e.cause.Error() }
func (e *temporaryStatusError) Unwrap() error { return e.cause }

func statusReadError(err error) error {
	if !errors.Is(err, context.Canceled) && !isJournalWrite(err) && allCauses(err, func(cause error) bool {
		return transientCause(cause) || cause == io.ErrUnexpectedEOF
	}) {
		return &temporaryStatusError{err}
	}
	return err
}

func retryableBootstrapVerification(err error) bool {
	return !isJournalWrite(err) && allCauses(err, func(err error) bool {
		_, temporary := err.(*temporaryStatusError)
		return err == bootstrapIdentityMismatch || temporary
	})
}
