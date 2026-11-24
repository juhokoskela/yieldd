package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
)

type lease struct {
	EC2            *ec2Lease   `json:"ec2,omitempty"`
	Name           string      `json:"name"`
	Created        time.Time   `json:"created"`
	RunnerID       int         `json:"runner_id,omitempty"`
	DispatchIntent bool        `json:"dispatch_intent,omitempty"`
	RunID          int64       `json:"run_id,omitempty"`
	CleanupIntent  bool        `json:"cleanup_intent,omitempty"`
	Conclusion     string      `json:"conclusion,omitempty"`
	Local          *localLease `json:"local,omitempty"`
}

func (l *lease) validateTransition(next *lease) error {
	if next == nil {
		return nil
	}
	if next.Name != l.Name || !next.Created.Equal(l.Created) ||
		(l.RunnerID != 0 && next.RunnerID != l.RunnerID) || (l.RunID != 0 && next.RunID != l.RunID) {
		return errors.New("assignment identity cannot change during a transition")
	}
	if (l.CleanupIntent && !next.CleanupIntent) || (l.DispatchIntent && !next.DispatchIntent) {
		return errors.New("persisted cleanup or dispatch intent cannot be revoked")
	}
	if e, n := l.EC2, next.EC2; e != nil && (n == nil || e.Seed != n.Seed || e.KeyID != n.KeyID ||
		(e.Instance != "" && e.Instance != n.Instance) || (e.Volume != "" && e.Volume != n.Volume) ||
		(e.Issuing && !n.Issuing) ||
		(e.Completed && (!n.Completed || e.ProducerRun != n.ProducerRun || e.ProducerBranch != n.ProducerBranch)) ||
		(e.SnapshotAttempted && !n.SnapshotAttempted)) {
		return errors.New("EC2 assignment identity and progress cannot change")
	}
	if l.Local == nil {
		if next.Local != nil {
			return errors.New("hosted assignment cannot become a local offer")
		}
		return nil
	}
	if next.Local == nil {
		if l.Local.Phase != localOffered && l.Local.Phase != localDeclined {
			return errors.New("accepted local assignment cannot become hosted provisioning")
		}
		return nil
	}
	previous, current := l.Local, next.Local
	if previous.Slot != current.Slot || previous.DeviceID != current.DeviceID ||
		(previous.JobStarted && !current.JobStarted) || (previous.JobCompleted && (!current.JobCompleted || current.JobSucceeded != previous.JobSucceeded)) {
		return errors.New("local assignment identity and job progress cannot be reset")
	}
	if current.Phase == previous.Phase ||
		(previous.Phase == localOffered && (current.Phase == localDeclined || current.Phase == localAccepted)) ||
		(previous.Phase == localAccepted && current.Phase == localIssued) {
		return nil
	}
	return errors.New("invalid local assignment phase transition")
}

func (l lease) secretName() string {
	return "YIELDD_JIT_" + strings.ToUpper(strings.ReplaceAll(strings.TrimPrefix(l.Name, "yieldd-bootstrap-"), "-", ""))
}

type state struct {
	Config     config            `json:"config"`
	Owner      string            `json:"owner"`
	ScaleSetID int               `json:"scale_set_id"`
	Leases     map[string]*lease `json:"leases,omitempty"`
}

type stateStore struct {
	root *os.Root
	lock *os.File
}

const maximumStateBytes = 2 << 20

var previousVersionState = errors.New("single-assignment journal found; finish recovery with the previous coordinator version before upgrading; do not delete unresolved state")

func openStore(path string) (*stateStore, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("state directory must be absolute")
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("state directory must be a private directory with mode 0700")
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	lock, err := root.OpenFile("coordinator.lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		root.Close()
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		root.Close()
		return nil, fmt.Errorf("state directory is already in use: %w", err)
	}
	return &stateStore{root: root, lock: lock}, nil
}

func (s *stateStore) Close() error { return errors.Join(s.lock.Close(), s.root.Close()) }

func (s *stateStore) load(c config) (*state, error) {
	value, err := s.read()
	if errors.Is(err, os.ErrNotExist) {
		value := &state{Config: c, Owner: uuid.NewString()}
		return value, s.save(value)
	}
	if err != nil {
		return nil, err
	}
	if !value.Config.sameRoute(c) {
		old := value.Config
		if old.Repository != c.Repository || old.Platform != c.Platform || old.DeviceID != c.DeviceID {
			return nil, errors.New("state belongs to a different configuration; finish recovery with the original identity and use a fresh state directory for the new one")
		}
		if len(value.Leases) > 0 || old.validate() != nil || c.validate() != nil {
			return nil, errors.New("state belongs to a different configuration; recover with its original configuration")
		}
		value.Config = c
		return value, s.save(value)
	}
	return value, nil
}

func (s *stateStore) read() (*state, error) {
	file, err := s.root.Open("state.json")
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("state file must be private and regular")
	}
	if info.Size() > maximumStateBytes {
		return nil, errors.New("state file exceeded size limit")
	}
	var value state
	// Recognize the old field only to give an actionable refusal, not to migrate it.
	envelope := struct {
		*state
		PreviousLease json.RawMessage `json:"lease"`
	}{state: &value}
	decoder := json.NewDecoder(io.LimitReader(file, maximumStateBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&envelope); err != nil {
		return nil, fmt.Errorf("read coordinator state: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, errors.New("unexpected trailing state data")
	}
	if envelope.PreviousLease != nil {
		return nil, previousVersionState
	}
	if _, err := uuid.Parse(value.Owner); err != nil {
		return nil, errors.New("invalid state owner")
	}
	if value.ScaleSetID < 0 || (len(value.Leases) != 0 && value.ScaleSetID == 0) {
		return nil, errors.New("invalid scale set identity")
	}
	if len(value.Leases) > maximumAssignments {
		return nil, errors.New("too many saved assignments")
	}
	var slots [maximumAssignments]bool
	for name, l := range value.Leases {
		if l == nil || name != l.Name {
			return nil, errors.New("invalid assignment identity")
		}
		if value.Config.LocalOnly && l.Local == nil {
			return nil, errors.New("local-only queue contains a fallback lease")
		}
		if l.EC2 != nil && (value.Config.EC2.Repository == "" || l.Local != nil || !l.DispatchIntent || l.RunID != 0 || (l.RunnerID != 0 && !l.EC2.Issuing)) {
			return nil, errors.New("invalid EC2 assignment")
		}
		if !runnerNamePattern.MatchString(l.Name) || l.Created.IsZero() || l.RunnerID < 0 || l.RunID < 0 || (l.RunID != 0 && !l.DispatchIntent) || (l.DispatchIntent && l.RunnerID == 0 && l.EC2 == nil) || (l.Conclusion != "" && !l.CleanupIntent) {
			return nil, errors.New("invalid provisioning lease")
		}
		if err := l.validateLocal(value.Config.DeviceID); err != nil {
			return nil, err
		}
		if l.Local != nil {
			if slots[l.Local.Slot] {
				return nil, errors.New("multiple assignments occupy one worker slot")
			}
			slots[l.Local.Slot] = true
		}
	}
	return &value, nil
}

func (s *stateStore) save(value *state) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(data) > maximumStateBytes {
		return errors.New("state file exceeded size limit")
	}
	name := "state-" + uuid.NewString() + ".tmp"
	file, err := s.root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer s.root.Remove(name)
	_, writeErr := file.Write(data)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		return err
	}
	if err := s.root.Rename(name, "state.json"); err != nil {
		return err
	}
	dir, err := s.root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func (l *lease) validateLocal(device string) error {
	if l.Local == nil {
		return nil
	}
	a := l.Local
	if (a.JobSucceeded && !a.JobCompleted) || (a.JobCompleted && !a.JobStarted) || ((a.JobStarted || a.JobCompleted) && a.Phase != localIssued) {
		return errors.New("invalid local job state")
	}
	if device == "" || a.DeviceID != device || a.Slot < 0 || a.Slot >= maximumAssignments || a.Expires.IsZero() || l.DispatchIntent {
		return errors.New("invalid local lease identity")
	}
	switch a.Phase {
	case localOffered, localDeclined, localAccepted:
		if l.RunnerID != 0 {
			return errors.New("unissued local lease has credentials")
		}
	case localIssued:
		if l.RunnerID == 0 {
			return errors.New("invalid issued local lease")
		}
	default:
		return errors.New("invalid local lease phase")
	}
	return nil
}
