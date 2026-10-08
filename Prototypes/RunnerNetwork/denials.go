package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"io"
	"sync"
	"time"
)

type denialReason uint8

const (
	frameMalformed denialReason = iota
	frameIdentity
	frameIPv6
	frameProtocol
	frameOptions
	frameFragment
	destinationInvalid
	destinationNonPublic
	destinationHost
	destinationHostCheck
	dnsMalformed
	dnsLocalName
	dnsRecordType
	dnsSaturated
	dnsUpstreamFailure
	denialReasonCount
)

var reasonNames = [denialReasonCount]string{
	"frame_malformed", "frame_identity", "frame_ipv6", "frame_unsupported_protocol", "frame_ip_options", "frame_fragment",
	"destination_invalid", "destination_non_public", "destination_host", "host_address_check_failed",
	"dns_malformed", "dns_local_name", "dns_record_type", "dns_saturated", "dns_upstream_failed",
}

const maximumTrackedDenials = 256

type relayIdentity struct {
	Runner   string `json:"runner,omitempty"`
	Platform string `json:"platform,omitempty"`
}

type reasonCounts struct {
	Total     uint64 `json:"total"`
	Interval  uint64 `json:"interval"`
	Distinct  uint64 `json:"distinct_tracked"`
	Repeated  uint64 `json:"repeated_tracked"`
	Untracked uint64 `json:"untracked"`
}

type denialCounters struct {
	identity   relayIdentity
	mu         sync.Mutex
	reasons    [denialReasonCount]reasonCounts
	previous   [denialReasonCount]uint64
	seen       map[[32]byte]struct{}
	reportedAt time.Time
}

func (c *denialCounters) record(reason denialReason, signature []byte) {
	// Fingerprints stay in memory for one reporting interval. Never emit guest data.
	hash := sha256.New()
	hash.Write([]byte{byte(reason)})
	hash.Write(signature)
	var fingerprint [32]byte
	hash.Sum(fingerprint[:0])
	c.mu.Lock()
	defer c.mu.Unlock()
	sample := &c.reasons[reason]
	sample.Total++
	if _, found := c.seen[fingerprint]; found {
		sample.Repeated++
	} else if len(c.seen) < maximumTrackedDenials {
		if c.seen == nil {
			c.seen = make(map[[32]byte]struct{})
		}
		c.seen[fingerprint] = struct{}{}
		sample.Distinct++
	} else {
		sample.Untracked++
	}
}

func (c *denialCounters) write(w io.Writer) {
	c.mu.Lock()
	now := time.Now()
	var interval float64
	if !c.reportedAt.IsZero() {
		interval = now.Sub(c.reportedAt).Seconds()
	}
	reasons := make(map[string]reasonCounts)
	var frames, destinations, rejectedDNS uint64
	for reason := range c.reasons {
		sample := c.reasons[reason]
		switch {
		case denialReason(reason) <= frameFragment:
			frames += sample.Total
		case denialReason(reason) <= destinationHostCheck:
			destinations += sample.Total
		case denialReason(reason) <= dnsSaturated:
			rejectedDNS += sample.Total
		}
		if sample.Total != 0 {
			sample.Interval = sample.Total - c.previous[reason]
			reasons[reasonNames[reason]] = sample
		}
		c.previous[reason] = sample.Total
		c.reasons[reason].Distinct, c.reasons[reason].Repeated, c.reasons[reason].Untracked = 0, 0, 0
	}
	c.seen, c.reportedAt = nil, now
	report := struct {
		Event string `json:"event"`
		relayIdentity
		Interval     float64                 `json:"interval_seconds"`
		Destinations uint64                  `json:"denied_destinations"`
		Frames       uint64                  `json:"dropped_frames"`
		DNS          uint64                  `json:"rejected_dns"`
		Reasons      map[string]reasonCounts `json:"reasons"`
	}{"relay_policy_totals", c.identity, interval, destinations, frames, rejectedDNS, reasons}
	c.mu.Unlock()
	// A blocked log consumer must not hold up packet handling or process shutdown.
	_ = json.NewEncoder(w).Encode(report)
}

func (c *denialCounters) report(ctx context.Context, w io.Writer) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	defer c.write(w)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.write(w)
		}
	}
}
