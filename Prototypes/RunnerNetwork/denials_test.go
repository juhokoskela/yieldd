package main

import (
	"bytes"
	"context"
	"errors"
	"net"
	"testing"
)

func TestDenialCountersIncludeFramesAndDestinations(t *testing.T) {
	counts := new(denialCounters)
	if _, err := outboundDial(t.Context(), counts)("tcp", "127.0.0.1:443"); !errors.Is(err, errDenied) {
		t.Fatal("loopback allowed", err)
	}
	client, peer := net.Pipe()
	defer client.Close()
	defer peer.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		peer.Write([]byte("invalid frame"))
		peer.Write(sampleFrame())
	}()
	frame := filteredConn{client, counts}
	if _, err := frame.Read(make([]byte, 1514)); err != nil {
		t.Fatal(err)
	}
	<-done
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	var output bytes.Buffer
	counts.report(ctx, &output)
	report := decodePolicyReports(t, output.Bytes())
	if report.Event != "relay_policy_totals" || report.Reasons["destination_non_public"].Total != 1 || report.Reasons["frame_malformed"].Total != 1 || len(report.Reasons) != 2 {
		t.Fatalf("incorrect shutdown totals: %+v", report)
	}
}
