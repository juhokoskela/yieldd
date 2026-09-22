package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

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
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	if err := runOwnedRelay(ctx, *socket, os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// The owner holds stdin open without sending data. EOF, an error, or any input
// revokes ownership. This covers owner crashes without trusting a reusable PID.
func runOwnedRelay(ctx context.Context, socket string, owner *os.File, ready, diagnostics io.Writer) error {
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
	counts := new(denialCounters)
	reported := make(chan struct{})
	go func() { defer close(reported); counts.report(ctx, diagnostics) }()
	err := serve(ctx, socket, ready, counts)
	interrupted := ctx.Err() != nil
	stop()
	<-reported
	if err != nil && !interrupted {
		return err
	}
	return nil
}

func serve(ctx context.Context, path string, ready io.Writer, counts *denialCounters) error {
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
	ssh, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer ssh.Close()
	stopSSH := context.AfterFunc(ctx, func() { ssh.Close() })
	defer stopSSH()
	sshDone := make(chan struct{})
	go func() { defer close(sshDone); forwardSSH(ctx, network, ssh) }()
	defer func() { cancel(); ssh.Close(); <-sshDone }()
	if err := json.NewEncoder(ready).Encode(struct {
		Version int    `json:"version"`
		SSH     string `json:"ssh"`
	}{1, ssh.Addr().String()}); err != nil {
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
