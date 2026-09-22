package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
)

// The Swift suite launches this fixture from a compiled Go test binary. All
// routing, HTTP, and journals are real; only GitHub is replaced by the test API.
func TestSwiftClientProtocolFixture(t *testing.T) {
	if os.Getenv("YIELDD_SWIFT_PROTOCOL_FIXTURE") != "1" {
		t.Skip("launched by the Swift client protocol test")
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	mux := http.NewServeMux()
	for _, platform := range []string{"linux", "macos"} {
		var loops []*coordinatorLoop
		for _, repository := range []string{"example/a", "example/b"} {
			c, _, _ := concurrentFixture(t, 0)
			c.state.Config.Repository, c.state.Config.Platform = repository, platform
			c.state.Config.LocalOnly, c.state.Config.Fallback = true, ""
			loops = append(loops, newCoordinatorLoop(ctx, c))
		}
		router, err := newDeviceRouter(testDevice, loops)
		if err != nil {
			t.Fatal(err)
		}
		startLoops(t, cancel, loops)
		for _, loop := range loops {
			if _, err := loop.HandleDesiredRunnerCount(ctx, 1); err != nil {
				t.Fatal(err)
			}
		}
		handler := router.deviceHandler(strings.Repeat("x", 32))
		if platform == "macos" {
			mux.Handle("/v1/macos/", platformDeviceHandler(handler))
		} else {
			mux.Handle("/", handler)
		}
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: mux, BaseContext: func(net.Listener) context.Context { return ctx }}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	defer func() {
		cancel()
		_ = server.Close()
		if err := <-done; err != http.ErrServerClosed {
			t.Error(err)
		}
	}()
	if _, err := fmt.Fprintln(os.Stdout, "http://"+listener.Addr().String()); err != nil {
		t.Fatal(err)
	}
	// EOF publishes the complete endpoint to the parent without line-reading races.
	_ = os.Stdout.Close()
	_, _ = io.Copy(io.Discard, os.Stdin)
}
