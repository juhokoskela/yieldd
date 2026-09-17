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
	Name           string      `json:"name"`
	Created        time.Time   `json:"created"`
	RunnerID       int         `json:"runner_id,omitempty"`
	JIT            string      `json:"jit,omitempty"`
	DispatchIntent bool        `json:"dispatch_intent,omitempty"`
	RunID          int64       `json:"run_id,omitempty"`
	CleanupIntent  bool        `json:"cleanup_intent,omitempty"`
	Conclusion     string      `json:"conclusion,omitempty"`
	Local          *localLease `json:"local,omitempty"`
}

func (l lease) secretName() string {
	return "YIELDD_JIT_" + strings.ToUpper(strings.ReplaceAll(strings.TrimPrefix(l.Name, "yieldd-bootstrap-"), "-", ""))
}

type state struct {
	Config     config `json:"config"`
	Owner      string `json:"owner"`
	ScaleSetID int    `json:"scale_set_id"`
	Lease      *lease `json:"lease,omitempty"`
}

type stateStore struct {
	root *os.Root
	lock *os.File
}

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
	file, err := s.root.Open("state.json")
	if errors.Is(err, os.ErrNotExist) {
		value := &state{Config: c, Owner: uuid.NewString()}
		return value, s.save(value)
	}
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
	if info.Size() > 2<<20 {
		return nil, errors.New("state file exceeded size limit")
	}
	var value state
	decoder := json.NewDecoder(io.LimitReader(file, 2<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return nil, fmt.Errorf("read coordinator state: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, errors.New("unexpected trailing state data")
	}
	if value.Config != c {
		return nil, errors.New("state belongs to a different configuration; recover with its original configuration and use a separate state directory for the new configuration")
	}
	if _, err := uuid.Parse(value.Owner); err != nil {
		return nil, errors.New("invalid state owner")
	}
	if value.ScaleSetID < 0 || (value.Lease != nil && value.ScaleSetID == 0) {
		return nil, errors.New("invalid scale set identity")
	}
	if l := value.Lease; l != nil {
		if !runnerNamePattern.MatchString(l.Name) || l.Created.IsZero() || l.RunnerID < 0 || l.RunID < 0 || (l.RunID != 0 && !l.DispatchIntent) || (l.DispatchIntent && l.RunnerID == 0) || (l.Conclusion != "" && !l.CleanupIntent) || ((l.DispatchIntent || l.CleanupIntent) && l.JIT != "") {
			return nil, errors.New("invalid provisioning lease")
		}
		if err := l.validateLocal(c.DeviceID); err != nil {
			return nil, err
		}
	}
	return &value, nil
}

func (s *stateStore) save(value *state) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
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
	if device == "" || a.DeviceID != device || a.Expires.IsZero() || l.DispatchIntent {
		return errors.New("invalid local lease identity")
	}
	switch a.Phase {
	case localOffered:
		if l.RunnerID != 0 || l.JIT != "" {
			return errors.New("unaccepted offer has credentials")
		}
	case localAccepted:
	case localIssued:
		if l.RunnerID == 0 || l.JIT != "" {
			return errors.New("invalid issued local lease")
		}
	default:
		return errors.New("invalid local lease phase")
	}
	return nil
}
