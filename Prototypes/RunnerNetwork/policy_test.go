package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"testing"
)

func TestDestinationPolicy(t *testing.T) {
	for _, address := range []string{
		"0.1.2.3", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254",
		"172.16.1.1", "192.168.3.213", "192.168.127.1", "192.168.127.2",
		"192.0.0.8", "192.0.2.1", "192.88.99.1", "198.18.0.1", "198.51.100.1",
		"203.0.113.1", "224.0.0.1", "255.255.255.255", "240.0.0.1",
		"::", "::1", "::ffff:8.8.8.8", "fe80::1", "fd00::1", "64:ff9b::a00:1", "2001:4860:4860::8888",
	} {
		t.Run(address, func(t *testing.T) {
			if publicDestination(netip.MustParseAddr(address)) {
				t.Fatal("permitted restricted destination")
			}
		})
	}
	if !publicDestination(netip.MustParseAddr("8.8.8.8")) {
		t.Fatal("rejected public address")
	}
}

func TestDialBoundary(t *testing.T) {
	called := false
	client, peer := net.Pipe()
	defer client.Close()
	defer peer.Close()
	dial := func(_ context.Context, network, address string) (net.Conn, error) {
		called = true
		if network != "tcp4" || address != "8.8.8.8:443" {
			t.Fatalf("changed destination: %s %s", network, address)
		}
		return client, nil
	}
	local := func() ([]netip.Addr, error) { return nil, nil }
	for _, address := range []string{"localhost:443", "127.1:443", "2130706433:443", "0x7f000001:443", "[::ffff:127.0.0.1]:443", "127.0.0.1:443", "8.8.8.8:0"} {
		if _, err := permittedDial(t.Context(), "tcp", address, local, dial); !errors.Is(err, errDenied) {
			t.Fatalf("%s: %v", address, err)
		}
	}
	if called {
		t.Fatal("dialed denied address")
	}
	failure := errors.New("interface enumeration failed")
	if _, err := permittedDial(t.Context(), "tcp", "8.8.8.8:443", func() ([]netip.Addr, error) { return nil, failure }, dial); !errors.Is(err, failure) || called {
		t.Fatal("host address validation failed open")
	}
	if _, err := permittedDial(t.Context(), "tcp", "8.8.8.8:443", local, dial); err != nil || !called {
		t.Fatal(err)
	}
}

func TestForbiddenDestinationsSkipHostInterfaceLookup(t *testing.T) {
	for _, address := range []string{
		"10.0.0.1:443", "127.0.0.1:443", "169.254.169.254:80", "192.168.3.1:53",
		"224.0.0.1:53", "198.51.100.1:443", "[::1]:443", "[::ffff:8.8.8.8]:443",
	} {
		t.Run(address, func(t *testing.T) {
			local := func() ([]netip.Addr, error) {
				t.Error("enumerated host interfaces for a statically forbidden destination")
				return nil, nil
			}
			dial := func(context.Context, string, string) (net.Conn, error) {
				t.Error("dialed a forbidden destination")
				return nil, errDenied
			}
			if _, err := permittedDial(t.Context(), "tcp", address, local, dial); !errors.Is(err, errDenied) {
				t.Fatal("did not reject forbidden destination", err)
			}
		})
	}
}

func TestHostAddressChangesApplyToNewConnections(t *testing.T) {
	var addresses []netip.Addr
	local := func() ([]netip.Addr, error) { return addresses, nil }
	connections := 0
	client, peer := net.Pipe()
	defer client.Close()
	defer peer.Close()
	dial := func(context.Context, string, string) (net.Conn, error) {
		connections++
		return client, nil
	}
	if _, err := permittedDial(t.Context(), "tcp", "8.8.8.8:443", local, dial); err != nil {
		t.Fatal(err)
	}
	addresses = []netip.Addr{netip.MustParseAddr("8.8.8.8")}
	if _, err := permittedDial(t.Context(), "tcp", "8.8.8.8:443", local, dial); !errors.Is(err, errDenied) {
		t.Fatal("permitted an address now assigned to the host", err)
	}
	if connections != 1 {
		t.Fatalf("opened %d host connections, want 1", connections)
	}
}
