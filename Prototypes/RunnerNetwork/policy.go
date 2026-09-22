package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"time"
)

var errDenied = errors.New("guest destination denied")

// IPv4-only prototype. IPv6, including mapped and transition addresses, is denied.
var deniedNetworks = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/3"),
}

func publicDestination(ip netip.Addr, local []netip.Addr) bool {
	if !ip.Is4() {
		return false
	}
	for _, prefix := range deniedNetworks {
		if prefix.Contains(ip) {
			return false
		}
	}
	for _, address := range local {
		if address.Unmap() == ip {
			return false
		}
	}
	return true
}

func hostAddresses() ([]netip.Addr, error) {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return nil, err
	}
	result := make([]netip.Addr, 0, len(addresses))
	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err != nil {
			return nil, fmt.Errorf("read host interface address: %w", err)
		}
		result = append(result, prefix.Addr())
	}
	return result, nil
}

func permittedDial(ctx context.Context, network, address string, local func() ([]netip.Addr, error), dial func(context.Context, string, string) (net.Conn, error)) (net.Conn, error) {
	if network != "tcp" && network != "udp" {
		return nil, errDenied
	}
	endpoint, err := netip.ParseAddrPort(address)
	if err != nil || endpoint.Port() == 0 {
		return nil, errDenied
	}
	// Refresh at each new host connection, including after Wi-Fi/VPN changes.
	addresses, err := local()
	if err != nil {
		return nil, errors.Join(errDenied, fmt.Errorf("cannot validate host addresses: %w", err))
	}
	if !publicDestination(endpoint.Addr(), addresses) {
		return nil, errDenied
	}
	// No name resolution or proxy environment is involved at this boundary.
	return dial(ctx, network+"4", endpoint.String())
}

func outboundDial(ctx context.Context, counts *denialCounters) func(string, string) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	return func(network, address string) (net.Conn, error) {
		connection, err := permittedDial(ctx, network, address, hostAddresses, dialer.DialContext)
		if errors.Is(err, errDenied) {
			counts.destinations.Add(1)
		}
		return connection, err
	}
}
