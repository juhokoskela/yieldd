package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/miekg/dns"
)

type policyReport struct {
	Event string `json:"event"`
	relayIdentity
	Interval float64                 `json:"interval_seconds"`
	DNS      uint64                  `json:"rejected_dns"`
	Reasons  map[string]reasonCounts `json:"reasons"`
}

func readPolicyReport(t *testing.T, counts *denialCounters) policyReport {
	t.Helper()
	var buffer bytes.Buffer
	counts.write(&buffer)
	var report policyReport
	if err := json.Unmarshal(buffer.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(buffer.String(), "private-query") {
		t.Fatal("guest data leaked into diagnostics")
	}
	return report
}

func TestDiagnosticsIdentifyRelayAndSeparateRepeatedQuestionsByInterval(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		counts := &denialCounters{identity: relayIdentity{Runner: "yieldd-test", Platform: "macos"}, reportedAt: time.Now()}
		handler := publicDNS(t.Context(), func(string, string) (net.Conn, error) {
			t.Error("local query reached resolver")
			return nil, errDenied
		}, counts)
		for _, name := range []string{"private-query.local.", "PRIVATE-QUERY.local.", "other.local."} {
			query := new(dns.Msg)
			query.SetQuestion(name, dns.TypeA)
			handler.ServeDNS(new(dnsRecorder), query)
		}
		time.Sleep(30 * time.Second)
		report := readPolicyReport(t, counts)
		if report.Runner != "yieldd-test" || report.Platform != "macos" || report.Interval != 30 || report.Event != "relay_policy_totals" {
			t.Fatal("missing report identity or reporting window", report)
		}
		if got := report.Reasons["dns_local_name"]; got != (reasonCounts{Total: 3, Interval: 3, Distinct: 2, Repeated: 1}) {
			t.Fatal("DNS repeats included IDs/case or mixed up intervals", got)
		}
		counts.record(dnsLocalName, []byte("private-query.local."))
		time.Sleep(30 * time.Second)
		if got := readPolicyReport(t, counts).Reasons["dns_local_name"]; got != (reasonCounts{Total: 4, Interval: 1, Distinct: 1}) {
			t.Fatal("repeat tracking or totals did not reset correctly", got)
		}
	})
}

func TestDiagnosticRepeatTrackingIsBoundedAndReportsIncompleteTracking(t *testing.T) {
	counts := new(denialCounters)
	for i := range maximumTrackedDenials + 20 {
		counts.record(destinationNonPublic, []byte(fmt.Sprint(i)))
	}
	counts.record(destinationNonPublic, []byte("0"))
	if len(counts.seen) != maximumTrackedDenials {
		t.Fatal("unbounded guest-controlled tracking", len(counts.seen))
	}
	got := readPolicyReport(t, counts).Reasons["destination_non_public"]
	if got.Distinct != maximumTrackedDenials || got.Repeated != 1 || got.Untracked != 20 || got.Interval != maximumTrackedDenials+21 {
		t.Fatal("overflow was misrepresented as unique or repeated traffic", got)
	}
}

func TestDNSSaturationAndUpstreamFailuresAreSeparateFromPolicyRefusals(t *testing.T) {
	counts := new(denialCounters)
	entered, release := make(chan struct{}, 16), make(chan struct{})
	var once sync.Once
	var pending sync.WaitGroup
	defer func() { once.Do(func() { close(release) }); pending.Wait() }()
	handler := publicDNS(t.Context(), func(string, string) (net.Conn, error) {
		entered <- struct{}{}
		<-release
		return nil, errors.New("upstream unavailable")
	}, counts)
	query := new(dns.Msg)
	query.SetQuestion("public.example.", dns.TypeA)
	for range 16 {
		pending.Add(1)
		go func() { defer pending.Done(); handler.ServeDNS(new(dnsRecorder), query.Copy()) }()
	}
	for range 16 {
		select {
		case <-entered:
		case <-time.After(3 * time.Second):
			t.Fatal("DNS requests did not reach the controlled resolver")
		}
	}
	response := new(dnsRecorder)
	handler.ServeDNS(response, query.Copy())
	if response.message.Rcode != dns.RcodeServerFailure {
		t.Fatal("saturated DNS unexpectedly succeeded")
	}
	once.Do(func() { close(release) })
	pending.Wait()
	report := readPolicyReport(t, counts)
	if report.Reasons["dns_saturated"].Total != 1 || report.Reasons["dns_upstream_failed"].Total != 16 || report.DNS != 1 {
		t.Fatal("upstream failures were counted as policy refusals", report)
	}
}

type blockedDiagnostics struct {
	entered chan struct{}
	release chan struct{}
}

func (w blockedDiagnostics) Write(b []byte) (int, error) {
	close(w.entered)
	<-w.release
	return len(b), nil
}

func TestBlockedDiagnosticsDoNotBlockPolicyAccounting(t *testing.T) {
	counts := new(denialCounters)
	w := blockedDiagnostics{make(chan struct{}), make(chan struct{})}
	done := make(chan struct{})
	go func() { defer close(done); counts.write(w) }()
	<-w.entered
	defer func() { close(w.release); <-done }()
	updated := make(chan struct{})
	go func() { counts.record(frameIPv6, []byte("frame")); close(updated) }()
	select {
	case <-updated:
	case <-time.After(time.Second):
		t.Fatal("blocked stderr held the accounting lock")
	}
	counts.write(io.Discard)
}

func TestRelayDiagnosticIdentityRejectsUnboundedAndControlInputs(t *testing.T) {
	for _, identity := range []relayIdentity{
		{Runner: strings.Repeat("x", 129), Platform: "linux"}, {Runner: "bad\nname", Platform: "linux"},
		{Runner: "yieldd-test", Platform: "unknown"}, {Runner: "yieldd-test"}, {Platform: "macos"},
	} {
		if err := identity.validate(); err == nil {
			t.Fatal("unsafe relay identity accepted", identity)
		}
	}
	for _, identity := range []relayIdentity{{}, {Runner: "yieldd-test", Platform: "linux"}, {Runner: "yieldd-test", Platform: "macos"}} {
		if err := identity.validate(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestDestinationDiagnosticReasonsPreserveDenialIdentity(t *testing.T) {
	for _, test := range []struct {
		address string
		local   func() ([]netip.Addr, error)
		reason  denialReason
	}{
		{"localhost:443", hostAddresses, destinationInvalid},
		{"192.168.1.1:443", hostAddresses, destinationNonPublic},
		{"8.8.8.8:443", func() ([]netip.Addr, error) { return []netip.Addr{netip.MustParseAddr("8.8.8.8")}, nil }, destinationHost},
		{"8.8.8.8:443", func() ([]netip.Addr, error) { return nil, context.DeadlineExceeded }, destinationHostCheck},
	} {
		_, err := permittedDial(t.Context(), "tcp", test.address, test.local, func(context.Context, string, string) (net.Conn, error) {
			t.Error("denied destination reached a host socket")
			return nil, nil
		})
		var denied *deniedDestination
		if !errors.Is(err, errDenied) || !errors.As(err, &denied) || denied.reason != test.reason {
			t.Fatal("denial reason or error identity lost", err)
		}
	}
}
