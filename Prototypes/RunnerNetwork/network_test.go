package main

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/virtualnetwork"
	"github.com/miekg/dns"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/link/ethernet"
	"gvisor.dev/gvisor/pkg/tcpip/network/arp"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// A second gVisor stack acts as the guest. Ethernet crosses real datagram sockets,
// exactly as it does at the VZ attachment, without requiring a VM or privileges.
func testNetwork(t *testing.T, dial func(string, string) (net.Conn, error)) (*stack.Stack, *virtualnetwork.VirtualNetwork) {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	dir := socketTestDirectory(t)
	a := &net.UnixAddr{Name: filepath.Join(dir, "a"), Net: "unixgram"}
	b := &net.UnixAddr{Name: filepath.Join(dir, "b"), Net: "unixgram"}
	host, err := net.ListenUnixgram("unixgram", a)
	if err != nil {
		t.Fatal(err)
	}
	guest, err := net.DialUnix("unixgram", b, a)
	if err != nil {
		host.Close()
		t.Fatal(err)
	}
	link := channel.New(128, 1500, tcpip.LinkAddress(guestHardware))
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, arp.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	if err := s.CreateNIC(1, ethernet.New(link)); err != nil {
		t.Fatal(err)
	}
	if err := s.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: tcpip.AddrFrom4([4]byte{192, 168, 127, 2}).WithPrefix()}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	zero := tcpip.AddrFrom4([4]byte{})
	subnet, tcpErr := tcpip.NewSubnet(zero, tcpip.MaskFromBytes([]byte{0, 0, 0, 0}))
	if tcpErr != nil {
		t.Fatal(tcpErr)
	}
	s.SetRouteTable([]tcpip.Route{{Destination: subnet, Gateway: tcpip.AddrFrom4([4]byte{192, 168, 127, 1}), NIC: 1}})
	counts := new(denialCounters)
	v, err := newRelayNetwork(ctx, dial, counts)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{}, 3)
	go func() {
		defer func() { done <- struct{}{} }()
		_ = v.AcceptVfkit(ctx, filteredConn{&datagramPeer{host, b}, counts})
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		for {
			p := link.ReadContext(ctx)
			if p == nil {
				return
			}
			view := p.ToView()
			_, err := guest.Write(view.AsSlice())
			view.Release()
			p.DecRef()
			if err != nil {
				return
			}
		}
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 65536)
		for {
			n, err := guest.Read(buf)
			if err != nil {
				return
			}
			p := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte(nil), buf[:n]...))})
			link.InjectInbound(0, p)
			p.DecRef()
		}
	}()
	t.Cleanup(func() {
		cancel()
		host.Close()
		guest.Close()
		s.Close()
		s.Wait()
		for range 3 {
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Error("relay goroutine did not stop")
			}
		}
	})
	return s, v
}

type datagramPeer struct {
	*net.UnixConn
	peer *net.UnixAddr
}

func (c *datagramPeer) Write(b []byte) (int, error) { return c.WriteToUnix(b, c.peer) }
func (c *datagramPeer) RemoteAddr() net.Addr        { return c.peer }

func guestDial(ctx context.Context, s *stack.Stack, address string) (net.Conn, error) {
	endpoint, err := netip.ParseAddrPort(address)
	if err != nil {
		return nil, err
	}
	conn, err := gonet.DialContextTCP(ctx, s, tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4(endpoint.Addr().As4()), Port: endpoint.Port()}, ipv4.ProtocolNumber)
	if err != nil {
		return nil, err
	}
	return conn, nil
}

func TestPacketsReachPolicyAndCannotDialHost(t *testing.T) {
	if runInRelayProcess(t) {
		return
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	// Establish the positive control from the real host first.
	control, err := net.Dial("tcp4", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	control.Close()
	accepted, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	accepted.Close()
	// Model a public host interface without requiring a LAN adapter. If the
	// policy regresses, the injected host dial reaches the real local fixture,
	// never the Internet. Guest loopback is handled inside the guest stack.
	hostIP := netip.MustParseAddr("8.8.8.8")
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	decisions := make(chan error, 4)
	s, _ := testNetwork(t, func(network, address string) (net.Conn, error) {
		c, err := permittedDial(t.Context(), network, address,
			func() ([]netip.Addr, error) { return []netip.Addr{hostIP}, nil },
			func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp4", listener.Addr().String())
			})
		decisions <- err
		return c, err
	})
	for _, address := range []string{hostIP.String(), "192.168.3.1"} {
		ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
		defer cancel()
		c, err := guestDial(ctx, s, net.JoinHostPort(address, port))
		if c != nil {
			c.Close()
		}
		if err == nil {
			t.Fatal("guest reached host listener", address)
		}
		select {
		case decision := <-decisions:
			if !errors.Is(decision, errDenied) {
				t.Fatal(address, decision)
			}
		case <-ctx.Done():
			t.Fatal("packet never reached policy; timeout is not enforcement evidence", address)
		}
	}
}

func TestHostCanConnectIntoGuest(t *testing.T) {
	if runInRelayProcess(t) {
		return
	}
	s, v := testNetwork(t, outboundDial(t.Context(), new(denialCounters)))
	listener, err := gonet.ListenTCP(s, tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{192, 168, 127, 2}), Port: 22}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	c, err := v.DialContextTCP(ctx, guestIP+":22")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	peer, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	if _, err := peer.Write([]byte("SSH-prototype\n")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 14)
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != "SSH-prototype\n" {
		t.Fatalf("%q %v", buf, err)
	}
}

func TestGuestUDPToPrivateDestinationIsDenied(t *testing.T) {
	if runInRelayProcess(t) {
		return
	}
	decisions := make(chan error, 1)
	s, _ := testNetwork(t, func(network, address string) (net.Conn, error) {
		conn, err := outboundDial(t.Context(), new(denialCounters))(network, address)
		select {
		case decisions <- err:
		default:
		}
		return conn, err
	})
	conn, err := gonet.DialUDP(s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{10, 0, 0, 1}), Port: 12345}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("test")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-decisions:
		if !errors.Is(err, errDenied) {
			t.Fatalf("private UDP reached a host socket: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("packet did not reach the forwarding policy")
	}
}

func TestPublicHTTPS(t *testing.T) {
	if os.Getenv("YIELDD_NETWORK_LIVE") != "1" {
		t.Skip("set YIELDD_NETWORK_LIVE=1 for public HTTPS over the packet relay")
	}
	if runInRelayProcess(t) {
		return
	}
	s, _ := testNetwork(t, outboundDial(t.Context(), new(denialCounters)))
	dnsConn, err := gonet.DialUDP(s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{192, 168, 127, 1}), Port: 53}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer dnsConn.Close()
	query := new(dns.Msg)
	query.SetQuestion("github.com.", dns.TypeA)
	answer, _, err := (&dns.Client{Timeout: 5 * time.Second}).ExchangeWithConnContext(t.Context(), query, &dns.Conn{Conn: dnsConn})
	if err != nil {
		t.Fatal(err)
	}
	var publicAddress netip.Addr
	for _, record := range answer.Answer {
		if a, ok := record.(*dns.A); ok {
			publicAddress = netip.MustParseAddr(a.A.String())
			break
		}
	}
	if !publicAddress.IsValid() {
		t.Fatal("guest DNS returned no IPv4 address")
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		return guestDial(ctx, s, net.JoinHostPort(publicAddress.String(), "443"))
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Get("https://github.com/")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatal(response.Status)
	}
	if !strings.Contains(response.Header.Get("Content-Type"), "text/html") {
		t.Fatal("unexpected response")
	}
}
