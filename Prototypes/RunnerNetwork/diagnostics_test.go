package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
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
	Reasons  map[string]reasonCounts `json:"reasons"`
}

func readPolicyReport(t *testing.T, counts *denialCounters) policyReport {
	t.Helper()
	var buffer bytes.Buffer
	counts.write(&buffer)
	report := decodePolicyReports(t, buffer.Bytes())
	if strings.Contains(buffer.String(), "private-query") {
		t.Fatal("guest data leaked into diagnostics")
	}
	return report
}

func decodePolicyReports(t *testing.T, output []byte) policyReport {
	t.Helper()
	result := policyReport{Reasons: make(map[string]reasonCounts)}
	decoder := json.NewDecoder(bytes.NewReader(output))
	for {
		var report denialReport
		err := decoder.Decode(&report)
		if errors.Is(err, io.EOF) {
			return result
		}
		if err != nil {
			t.Fatal(err)
		}
		result.Event, result.relayIdentity, result.Interval = report.Event, report.relayIdentity, report.IntervalSeconds
		if report.Reason != "" {
			result.Reasons[report.Reason] = report.reasonCounts
		}
	}
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
		query := new(dns.Msg)
		query.SetQuestion("private-query.local.", dns.TypeA)
		handler.ServeDNS(new(dnsRecorder), query)
		time.Sleep(30 * time.Second)
		if got := readPolicyReport(t, counts).Reasons["dns_local_name"]; got != (reasonCounts{Total: 4, Interval: 1, Distinct: 1}) {
			t.Fatal("repeat tracking or totals did not reset correctly", got)
		}
	})
}

func TestFrameTrafficDoesNotConsumeDNSRepeatTracking(t *testing.T) {
	counts := new(denialCounters)
	for i := range 300 {
		counts.record(frameProtocol, []byte(fmt.Sprint(i)))
	}
	handler := publicDNS(t.Context(), nil, counts)
	query := new(dns.Msg)
	query.SetQuestion("printer.local.", dns.TypeA)
	for range 50 {
		handler.ServeDNS(new(dnsRecorder), query.Copy())
	}
	got := readPolicyReport(t, counts).Reasons["dns_local_name"]
	if got.Distinct != 1 || got.Repeated != 49 || got.Untracked != 0 {
		t.Fatal("frame noise hid a DNS retry loop", got)
	}
}

func TestDNSPolicyDenialIsNotAnUpstreamFailure(t *testing.T) {
	counts := new(denialCounters)
	handler := publicDNS(t.Context(), func(string, string) (net.Conn, error) {
		counts.record(destinationHost, []byte(publicResolver))
		return nil, &deniedDestination{destinationHost}
	}, counts)
	query := new(dns.Msg)
	query.SetQuestion("public.example.", dns.TypeA)
	response := new(dnsRecorder)
	handler.ServeDNS(response, query)
	report := readPolicyReport(t, counts)
	if response.message.Rcode != dns.RcodeServerFailure || report.Reasons["destination_host"].Total != 1 || report.Reasons["dns_upstream_failed"].Total != 0 {
		t.Fatal("one policy refusal was also reported as a resolver outage", report)
	}
}

func TestDiagnosticRepeatTrackingIsBoundedAndReportsIncompleteTracking(t *testing.T) {
	counts := new(denialCounters)
	for i := range maximumTrackedDenials + 20 {
		counts.record(destinationNonPublic, []byte(fmt.Sprint(i)))
	}
	counts.record(destinationNonPublic, []byte("0"))
	if len(counts.seen[destinationNonPublic]) != maximumTrackedDenials {
		t.Fatal("unbounded guest-controlled tracking", len(counts.seen[destinationNonPublic]))
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
	if report.Reasons["dns_saturated"].Total != 1 || report.Reasons["dns_upstream_failed"].Total != 16 || len(report.Reasons) != 2 {
		t.Fatal("upstream failures were counted as policy refusals", report)
	}
}

type atomicDiagnosticWrites struct {
	bytes.Buffer
	lengths []int
}

func (w *atomicDiagnosticWrites) Write(b []byte) (int, error) {
	w.lengths = append(w.lengths, len(b))
	return w.Buffer.Write(b)
}

func TestDiagnosticReasonsHaveNamesAndFitAtomicPipeWrites(t *testing.T) {
	counts := &denialCounters{identity: relayIdentity{Runner: strings.Repeat("x", 128), Platform: "macos"}, reportedAt: time.Now().Add(-time.Duration(math.MaxInt64))}
	names := make(map[string]bool)
	for reason, name := range reasonNames {
		if name == "" || names[name] {
			t.Fatal("reason has a missing or duplicate name", reason, name)
		}
		names[name] = true
		counts.reasons[reason] = reasonCounts{math.MaxUint64, math.MaxUint64, math.MaxUint64, math.MaxUint64, math.MaxUint64}
	}
	var output atomicDiagnosticWrites
	counts.write(&output)
	if len(output.lengths) != int(denialReasonCount) {
		t.Fatal("reasons were not written separately", output.lengths)
	}
	for _, length := range output.lengths {
		if length > 512 {
			t.Fatal("diagnostic line exceeds Darwin's atomic pipe limit", length)
		}
	}
	if len(decodePolicyReports(t, output.Bytes()).Reasons) != int(denialReasonCount) {
		t.Fatal("reason disappeared from output")
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
