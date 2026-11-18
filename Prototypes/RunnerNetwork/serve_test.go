package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestServeRefusesSharedDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := serve(t.Context(), filepath.Join(dir, "relay.sock"), io.Discard, new(denialCounters), ""); err == nil {
		t.Fatal("accepted shared socket directory")
	}
}

func TestServeCancellationBeforeGuestArrives(t *testing.T) {
	testServeCancellation(t, false)
}

func TestServeCancellationWithGuestAndSSHClient(t *testing.T) {
	testServeCancellation(t, true)
}

func testServeCancellation(t *testing.T, connectGuest bool) {
	t.Helper()
	if runInRelayProcess(t) {
		return
	}
	dir := socketTestDirectory(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	path := filepath.Join(dir, "relay.sock")
	reader, writer := net.Pipe()
	defer reader.Close()
	defer writer.Close()
	if err := reader.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { defer close(done); _ = serve(ctx, path, writer, new(denialCounters), "") }()
	t.Cleanup(func() {
		cancel()
		writer.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("relay goroutine did not stop")
		}
	})
	var ready struct {
		Version int
		SSH     string
	}
	if err := json.NewDecoder(reader).Decode(&ready); err != nil {
		t.Fatal("relay did not report readiness", err)
	}
	if ready.Version != 2 || ready.SSH != path+".ssh" {
		t.Fatalf("unexpected private SSH endpoint: %+v", ready)
	}
	info, err := os.Lstat(ready.SSH)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0600 {
		t.Fatalf("SSH endpoint is not a private Unix socket: %v, %v", info, err)
	}
	var ssh net.Conn
	if connectGuest {
		guest, err := net.DialUnix("unixgram", &net.UnixAddr{Name: path + ".vm", Net: "unixgram"}, &net.UnixAddr{Name: path, Net: "unixgram"})
		if err != nil {
			t.Fatal(err)
		}
		defer guest.Close()
		if _, err := guest.Write(sampleFrame()); err != nil {
			t.Fatal(err)
		}
		ssh, err = net.DialTimeout("unix", ready.SSH, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		defer ssh.Close()
		if err := ssh.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("relay did not stop")
	}
	if ssh != nil {
		if _, err := ssh.Read(make([]byte, 1)); err == nil {
			t.Fatal("SSH client remained connected")
		} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
			t.Fatal("SSH client was not closed on cancellation")
		}
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("socket retained", err)
	}
	if _, err := os.Lstat(ready.SSH); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("SSH socket retained", err)
	}
}

func TestServeDoesNotRemoveExistingSSHEndpoint(t *testing.T) {
	if runInRelayProcess(t) {
		return
	}
	dir := socketTestDirectory(t)
	path := filepath.Join(dir, "relay.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path + ".ssh", Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := serve(t.Context(), path, io.Discard, new(denialCounters), ""); err == nil {
		t.Fatal("replaced existing SSH endpoint")
	}
	if _, err := os.Lstat(path + ".ssh"); err != nil {
		t.Fatal("removed SSH endpoint owned by another helper", err)
	}
}

func TestServeDoesNotRemoveExistingSocket(t *testing.T) {
	dir := socketTestDirectory(t)
	path := filepath.Join(dir, "relay.sock")
	listener, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := serve(t.Context(), path, io.Discard, new(denialCounters), ""); err == nil {
		t.Fatal("replaced existing endpoint")
	}
	if _, err := os.Lstat(path); err != nil {
		t.Fatal("removed endpoint owned by another helper", err)
	}
}
