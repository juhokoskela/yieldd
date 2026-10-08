package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestRelayOwnership(t *testing.T) {
	for _, test := range []struct {
		action             string
		blockedDiagnostics bool
	}{
		{"eof", false}, {"input", false}, {"signal", false}, {"owner-killed", false},
		{"eof", true}, {"owner-killed", true},
	} {
		name := test.action
		if test.blockedDiagnostics {
			name += "-blocked-stderr"
		}
		t.Run(name, func(t *testing.T) {
			action := test.action
			path := filepath.Join(socketTestDirectory(t), "relay.sock")
			mode := "relay"
			if action == "owner-killed" {
				mode = "owner"
			}
			command := ownershipCommand(mode, path)
			owner, err := command.StdinPipe()
			if err != nil {
				t.Fatal(err)
			}
			defer owner.Close()
			reader, writer, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Close()
			defer writer.Close()
			command.Stdout = writer
			command.Stderr = os.Stderr
			if test.blockedDiagnostics {
				command.Stderr = fullDiagnosticPipe(t)
			}
			if err := command.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			var exitError error
			go func() { exitError = command.Wait(); close(done) }()
			t.Cleanup(func() {
				select {
				case <-done:
					return
				default:
					command.Process.Kill()
				}
				select {
				case <-done:
				case <-time.After(5 * time.Second):
					t.Error("ownership test process did not exit")
				}
			})
			if err := reader.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
				t.Fatal(err)
			}
			decoder := json.NewDecoder(reader)
			var pid int
			if err := decoder.Decode(&pid); err != nil {
				t.Fatal("relay process did not start", err)
			}
			if pid <= 0 {
				t.Fatal("invalid relay PID", pid)
			}
			relayExited := false
			t.Cleanup(func() {
				if !relayExited {
					syscall.Kill(pid, syscall.SIGKILL)
				}
			})
			var ready struct {
				Version int
				SSH     string
			}
			if err := decoder.Decode(&ready); err != nil {
				t.Fatal("relay did not become ready", err)
			}
			if ready.Version != 2 {
				t.Fatal("unsupported readiness version", ready.Version)
			}
			ssh, err := net.DialTimeout("unix", ready.SSH, time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer ssh.Close()
			switch action {
			case "eof":
				err = owner.Close()
			case "input":
				_, err = owner.Write([]byte{1})
			case "signal":
				err = command.Process.Signal(syscall.SIGTERM)
			case "owner-killed":
				err = command.Process.Kill()
			}
			if err != nil {
				t.Fatal(err)
			}
			select {
			case <-done:
				if exitError != nil && action != "owner-killed" {
					t.Fatal("relay failed to stop cleanly", exitError)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("relay or owner did not exit")
			}
			deadline := time.Now().Add(5 * time.Second)
			for !errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
				if time.Now().After(deadline) {
					t.Fatal("relay survived revocation of its lifetime pipe")
				}
				time.Sleep(10 * time.Millisecond)
			}
			relayExited = true
			if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("relay retained its socket", err)
			}
			if err := ssh.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			if _, err := ssh.Read(make([]byte, 1)); err == nil {
				t.Fatal("SSH connection remained open")
			} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
				t.Fatal("SSH connection was not closed")
			}
		})
	}
}

// Keep the read end open but never drain it, including during shutdown.
func fullDiagnosticPipe(t *testing.T) *os.File {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reader.Close(); writer.Close() })
	descriptor := int(writer.Fd())
	if err := unix.SetNonblock(descriptor, true); err != nil {
		t.Fatal(err)
	}
	for _, chunk := range [][]byte{make([]byte, 4096), {0}} {
		for {
			_, err := unix.Write(descriptor, chunk)
			if errors.Is(err, unix.EAGAIN) {
				break
			}
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := unix.SetNonblock(descriptor, false); err != nil {
		t.Fatal(err)
	}
	return writer
}

func ownershipCommand(mode, path string) *exec.Cmd {
	command := exec.Command(os.Args[0], "-test.run=^TestOwnedRelayProcess$", "-test.timeout=15s")
	command.Env = append(os.Environ(), "YIELDD_OWNER_MODE="+mode, "YIELDD_OWNER_SOCKET="+path)
	return command
}

func TestRelayStartupErrorWithBlockedStderr(t *testing.T) {
	command := ownershipCommand("invalid-socket", "relative.sock")
	owner, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	command.Stderr = fullDiagnosticPipe(t)
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case err := <-done:
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != 1 {
			t.Fatalf("expected startup failure, got %v", err)
		}
	case <-time.After(5 * time.Second):
		command.Process.Kill()
		<-done
		t.Fatal("startup failure waited for stderr to drain")
	}
}

func TestOwnedRelayProcess(t *testing.T) {
	mode := os.Getenv("YIELDD_OWNER_MODE")
	path := os.Getenv("YIELDD_OWNER_SOCKET")
	switch mode {
	case "invalid-socket":
		flag.CommandLine = flag.NewFlagSet("relay", flag.ExitOnError)
		os.Args = []string{"relay", "--socket", path}
		main()
	case "relay":
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM)
		defer cancel()
		if err := json.NewEncoder(os.Stdout).Encode(os.Getpid()); err != nil {
			t.Fatal(err)
		}
		if err := runOwnedRelay(ctx, path, os.Stdin, os.Stdout, os.Stderr); err != nil {
			t.Fatal(err)
		}
	case "owner":
		reader, writer, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		defer reader.Close()
		defer writer.Close()
		child := ownershipCommand("relay", path)
		child.Stdin, child.Stdout, child.Stderr = reader, os.Stdout, os.Stderr
		if err := child.Start(); err != nil {
			t.Fatal(err)
		}
		reader.Close()
		io.Copy(io.Discard, os.Stdin)
		writer.Close()
		if err := child.Wait(); err != nil {
			t.Fatal(err)
		}
	}
}
