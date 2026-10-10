package main

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"

	"github.com/miekg/dns"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
)

func TestGuestDNSUsesOnlyCheckedPublicResolver(t *testing.T) {
	if runInRelayProcess(t) {
		return
	}
	queries := make(chan dns.Question, 2)
	s, _ := testNetwork(t, func(network, address string) (net.Conn, error) {
		if network != "tcp" || address != publicResolver {
			t.Errorf("DNS used unexpected destination: %s %s", network, address)
		}
		return permittedDial(t.Context(), network, address, func() ([]netip.Addr, error) { return nil, nil },
			func(_ context.Context, network, address string) (net.Conn, error) {
				if network != "tcp4" || address != publicResolver {
					t.Errorf("DNS bypassed numeric destination validation: %s %s", network, address)
				}
				client, server := net.Pipe()
				done := make(chan struct{})
				t.Cleanup(func() { client.Close(); server.Close(); <-done })
				go func() {
					defer close(done)
					defer server.Close()
					server.SetDeadline(time.Now().Add(3 * time.Second))
					wire := &dns.Conn{Conn: server}
					query, err := wire.ReadMsg()
					if err != nil {
						t.Error(err)
						return
					}
					queries <- query.Question[0]
					answer := new(dns.Msg)
					answer.SetReply(query)
					answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: query.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET}, A: net.IPv4(8, 8, 8, 8)}}
					if err := wire.WriteMsg(answer); err != nil {
						t.Error(err)
					}
				}()
				return client, nil
			})
	})
	for _, transport := range []string{"udp", "tcp"} {
		var connection net.Conn
		var err error
		if transport == "udp" {
			connection, err = gonet.DialUDP(s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{192, 168, 127, 1}), Port: 53}, ipv4.ProtocolNumber)
		} else {
			connection, err = guestDial(t.Context(), s, gatewayIP+":53")
		}
		if err != nil {
			t.Fatal(err)
		}
		query := new(dns.Msg)
		query.SetQuestion("public.example.", dns.TypeA)
		answer, _, err := (&dns.Client{Timeout: 3 * time.Second}).ExchangeWithConnContext(t.Context(), query, &dns.Conn{Conn: connection})
		connection.Close()
		if err != nil || answer == nil || len(answer.Answer) != 1 {
			t.Fatalf("%s DNS response: %v %v", transport, answer, err)
		}
		select {
		case got := <-queries:
			if got != query.Question[0] {
				t.Fatalf("upstream question changed: %v", got)
			}
		case <-time.After(time.Second):
			t.Fatal("guest DNS did not cross the checked dial")
		}
	}
	// Exercise rejection through the installed gateway DNS handler, not only
	// the handler's direct unit tests.
	connection, err := guestDial(t.Context(), s, gatewayIP+":53")
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	query := new(dns.Msg)
	query.SetQuestion("private.local.", dns.TypeTXT)
	answer, _, err := (&dns.Client{Timeout: 3 * time.Second}).ExchangeWithConnContext(t.Context(), query, &dns.Conn{Conn: connection})
	if err != nil || answer == nil || answer.Rcode != dns.RcodeRefused {
		t.Fatalf("gateway did not refuse local TXT query: %v %v", answer, err)
	}
	select {
	case got := <-queries:
		t.Fatalf("rejected query reached upstream: %v", got)
	default:
	}
}

func TestDNSRejectsLocalNamesAndUnneededTypes(t *testing.T) {
	counts := new(denialCounters)
	handler := publicDNS(t.Context(), func(string, string) (net.Conn, error) {
		t.Error("rejected DNS query reached a host socket")
		return nil, errDenied
	}, counts)
	for _, test := range []struct {
		name string
		kind uint16
	}{
		{"printer.local.", dns.TypeA}, {"host.LOCAL.", dns.TypeA},
		{"printer.", dns.TypeA}, {"service.localhost.", dns.TypeA}, {"home.arpa.", dns.TypeA},
		{"host.home.arpa.", dns.TypeA}, {"public.example.", dns.TypeTXT},
		{"public.example.", dns.TypeCNAME}, {"public.example.", dns.TypeMX},
		{"public.example.", dns.TypeNS}, {"public.example.", dns.TypeSRV}, {"public.example.", dns.TypeANY},
	} {
		query := new(dns.Msg)
		query.SetQuestion(test.name, test.kind)
		response := new(dnsRecorder)
		handler.ServeDNS(response, query)
		if response.message == nil || response.message.Rcode != dns.RcodeRefused {
			t.Errorf("%s %d was not refused: %v", test.name, test.kind, response.message)
		}
	}
	var rejected uint64
	report := readPolicyReport(t, counts)
	for _, reason := range []string{"dns_malformed", "dns_local_name", "dns_record_type"} {
		rejected += report.Reasons[reason].Total
	}
	if rejected != 12 {
		t.Fatal("missing DNS denial counts", rejected)
	}
	query := new(dns.Msg)
	query.SetQuestion("public.example.", dns.TypeAAAA)
	response := new(dnsRecorder)
	handler.ServeDNS(response, query)
	if response.message == nil || response.message.Rcode != dns.RcodeSuccess || len(response.message.Answer) != 0 {
		t.Fatal("IPv4-only service did not return AAAA NODATA")
	}
}

func TestDNSFailsClosedWhenResolverIsAHostAddress(t *testing.T) {
	handler := publicDNS(t.Context(), func(network, address string) (net.Conn, error) {
		return permittedDial(t.Context(), network, address,
			func() ([]netip.Addr, error) { return []netip.Addr{netip.MustParseAddr("1.1.1.1")}, nil },
			func(context.Context, string, string) (net.Conn, error) {
				t.Error("dialed a host address")
				return nil, errDenied
			})
	}, new(denialCounters))
	query := new(dns.Msg)
	query.SetQuestion("public.example.", dns.TypeA)
	response := new(dnsRecorder)
	handler.ServeDNS(response, query)
	if response.message == nil || response.message.Rcode != dns.RcodeServerFailure {
		t.Fatal("resolver policy failure was not returned to the guest")
	}
}

type dnsRecorder struct{ message *dns.Msg }

func (r *dnsRecorder) WriteMsg(m *dns.Msg) error { r.message = m.Copy(); return nil }
func (*dnsRecorder) LocalAddr() net.Addr         { return &net.UDPAddr{} }
func (*dnsRecorder) RemoteAddr() net.Addr        { return &net.UDPAddr{} }
func (*dnsRecorder) Write([]byte) (int, error)   { panic("unexpected raw DNS write") }
func (*dnsRecorder) Close() error                { return nil }
func (*dnsRecorder) TsigStatus() error           { return nil }
func (*dnsRecorder) TsigTimersOnly(bool)         {}
func (*dnsRecorder) Hijack()                     {}
