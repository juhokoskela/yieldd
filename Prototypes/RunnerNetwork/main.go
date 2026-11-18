package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/transport"
	"github.com/containers/gvisor-tap-vsock/pkg/types"
	"github.com/containers/gvisor-tap-vsock/pkg/virtualnetwork"
	log "github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

func main() {
	// Upstream logs packet-level denials. Do not let guest traffic flood host logs.
	log.SetOutput(io.Discard)
	socket := flag.String("socket", "", "Datagram socket in a private, host-owned directory")
	runner := flag.String("runner", "", "Host-issued runner identity for diagnostic summaries")
	platform := flag.String("platform", "", "Runner platform for diagnostic summaries: linux or macos")
	cacheSocket := flag.String("cache-socket", "", "Private archive service socket")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	identity := relayIdentity{Runner: *runner, Platform: *platform}
	if err := runOwnedRelay(ctx, *socket, os.Stdin, os.Stdout, os.Stderr, identity, *cacheSocket); err != nil {
		reported := make(chan struct{})
		go func() { defer close(reported); fmt.Fprintln(os.Stderr, err) }()
		select {
		case <-reported:
		case <-time.After(100 * time.Millisecond):
		}
		os.Exit(1)
	}
}

// The owner holds stdin open without sending data. EOF, an error, or any input
// revokes ownership. This covers owner crashes without trusting a reusable PID.
func runOwnedRelay(ctx context.Context, socket string, owner *os.File, ready, diagnostics io.Writer, identity relayIdentity, cacheSocket string) error {
	if err := identity.validate(); err != nil {
		return err
	}
	descriptor := int(owner.Fd())
	if err := unix.SetNonblock(descriptor, true); err != nil {
		return fmt.Errorf("prepare relay lifetime pipe: %w", err)
	}
	ctx, stop := context.WithCancel(ctx)
	defer stop()
	ownerDone := make(chan struct{})
	go func() {
		defer close(ownerDone)
		defer stop()
		var command [1]byte
		descriptors := []unix.PollFd{{Fd: int32(descriptor), Events: unix.POLLIN}}
		for ctx.Err() == nil {
			_, err := unix.Poll(descriptors, 100)
			if errors.Is(err, unix.EINTR) {
				continue
			}
			if err != nil {
				return
			}
			if descriptors[0].Revents != 0 {
				_, err := unix.Read(descriptor, command[:])
				if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EINTR) {
					continue
				}
				return
			}
		}
	}()
	defer func() { stop(); <-ownerDone; owner.Close() }()
	counts := &denialCounters{identity: identity, reportedAt: time.Now()}
	// Diagnostics belong to the helper process. Never join a reporter that may
	// be blocked by its consumer; process exit also ends that goroutine.
	go counts.report(ctx, diagnostics)
	err := serve(ctx, socket, ready, counts, cacheSocket)
	if err != nil && ctx.Err() == nil {
		return err
	}
	return nil
}

var diagnosticRunnerPattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9-]{0,127}$`)

func (i relayIdentity) validate() error {
	if i.Runner == "" && i.Platform == "" {
		return nil
	}
	if !diagnosticRunnerPattern.MatchString(i.Runner) || (i.Platform != "linux" && i.Platform != "macos") {
		return errors.New("invalid relay diagnostic identity")
	}
	return nil
}

func serve(ctx context.Context, path string, ready io.Writer, counts *denialCounters, cacheSocket string) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	if !filepath.IsAbs(path) {
		return errors.New("socket path must be absolute")
	}
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil {
		return err
	}
	stat, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || !parent.IsDir() || parent.Mode().Perm() != 0700 || stat.Uid != uint32(os.Getuid()) {
		return errors.New("socket directory must be owned by this user with mode 0700")
	}
	conn, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		return err
	}
	defer conn.Close()
	defer os.Remove(path)
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	// The private parent prevents access before the socket's mode is tightened.
	if err := os.Chmod(path, 0600); err != nil {
		return err
	}
	dial := outboundDial(ctx, counts)
	network, err := newRelayNetwork(ctx, dial, counts)
	if err != nil {
		return err
	}
	if cacheSocket != "" {
		results := githubResultsTransport(counts)
		defer results.CloseIdleConnections()
		cache := newRelayCache(cacheSocket, filepath.Dir(path), results)
		listener, err := network.Listen("tcp", cacheAddress)
		if err != nil {
			return err
		}
		server := &http.Server{Handler: cache, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: time.Minute,
			MaxHeaderBytes: 64 << 10, BaseContext: func(net.Listener) context.Context { return ctx }}
		go func() { _ = server.Serve(listener) }()
		defer func() { cancel(); server.Close(); listener.Close(); cache.client.CloseIdleConnections() }()
	}
	if cacheSocket != "" && counts.identity.Platform == "linux" {
		disk, err := network.Listen("tcp", "192.168.127.1:7342")
		if err != nil {
			return err
		}
		done := make(chan struct{})
		go func() {
			defer close(done)
			_ = serveNativeDisk(ctx, disk, filepath.Dir(path))
		}()
		defer func() { cancel(); disk.Close(); <-done }()
	}
	ssh, err := net.ListenUnix("unix", &net.UnixAddr{Name: path + ".ssh", Net: "unix"})
	if err != nil {
		return err
	}
	defer ssh.Close()
	if err := os.Chmod(path+".ssh", 0600); err != nil {
		return err
	}
	stopSSH := context.AfterFunc(ctx, func() { ssh.Close() })
	defer stopSSH()
	sshDone := make(chan struct{})
	go func() { defer close(sshDone); forwardSSH(ctx, network, ssh) }()
	defer func() { cancel(); ssh.Close(); <-sshDone }()
	if err := json.NewEncoder(ready).Encode(struct {
		Version int    `json:"version"`
		SSH     string `json:"ssh"`
	}{2, ssh.Addr().String()}); err != nil {
		return err
	}
	peer, err := transport.AcceptVfkit(conn)
	if err != nil {
		return err
	}
	return network.AcceptVfkit(ctx, filteredConn{peer, counts})
}

func newRelayNetwork(ctx context.Context, dial func(string, string) (net.Conn, error), counts *denialCounters) (*virtualnetwork.VirtualNetwork, error) {
	return virtualnetwork.New(&types.Configuration{
		MTU: 1500, Subnet: "192.168.127.0/24", GatewayIP: gatewayIP,
		GatewayMacAddress: gatewayMAC, DHCPStaticLeases: map[string]string{guestIP: guestMAC},
		Dial: dial, DNSHandler: publicDNS(ctx, dial, counts),
	})
}
