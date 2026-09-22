package main

import (
	"bytes"
	"context"
	"encoding/json"
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
	var report struct {
		Event        string `json:"event"`
		Destinations uint64 `json:"denied_destinations"`
		Frames       uint64 `json:"dropped_frames"`
		DNS          uint64 `json:"rejected_dns"`
	}
	if err := json.Unmarshal(output.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if report.Event != "relay_policy_totals" || report.Destinations != 1 || report.Frames != 1 || report.DNS != 0 {
		t.Fatalf("incorrect shutdown totals: %+v", report)
	}
}
