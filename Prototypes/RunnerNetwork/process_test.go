package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
	"time"
)

func socketTestDirectory(t *testing.T) string {
	t.Helper()
	parent := os.TempDir()
	// The usual macOS TMPDIR is too long; a short override is honored.
	if len(filepath.Join(parent, "yn-1234567890", "relay.sock.vm")) >= 104 {
		parent = "/tmp"
	}
	directory, err := os.MkdirTemp(parent, "yn-")
	if err != nil {
		t.Fatalf("create socket directory (set TMPDIR to a short writable path): %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	if len(filepath.Join(directory, "relay.sock.vm")) >= 104 {
		t.Fatal("socket path exceeds Darwin's limit; set TMPDIR to a shorter path")
	}
	return directory
}

// Upstream network services live until process exit. Match the relay's one
// process per guest so repeated tests do not accumulate those services.
func runInRelayProcess(t *testing.T) bool {
	t.Helper()
	const marker = "YIELDD_RELAY_TEST"
	if os.Getenv(marker) == t.Name() {
		return false
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 35*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "-test.run=^"+regexp.QuoteMeta(t.Name())+"$", "-test.timeout=30s")
	command.Env = append(os.Environ(), marker+"="+t.Name())
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("relay test process: %v\n%s", err, output)
	}
	return true
}
