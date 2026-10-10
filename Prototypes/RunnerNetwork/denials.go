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
	frameNeighbor
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
	frameMalformed:       "frame_malformed",
	frameIdentity:        "frame_identity",
	frameIPv6:            "frame_ipv6",
	frameProtocol:        "frame_unsupported_protocol",
	frameOptions:         "frame_ip_options",
	frameFragment:        "frame_fragment",
	frameNeighbor:        "frame_neighbor",
	destinationInvalid:   "destination_invalid",
	destinationNonPublic: "destination_non_public",
	destinationHost:      "destination_host",
	destinationHostCheck: "host_address_check_failed",
	dnsMalformed:         "dns_malformed",
	dnsLocalName:         "dns_local_name",
	dnsRecordType:        "dns_record_type",
	dnsSaturated:         "dns_saturated",
	dnsUpstreamFailure:   "dns_upstream_failed",
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
	seen       [denialReasonCount]map[[32]byte]struct{}
	reportedAt time.Time
}

func (c *denialCounters) record(reason denialReason, signature []byte) {
	// Fingerprints stay in memory for one reporting interval. Never emit guest data.
	fingerprint := sha256.Sum256(signature)
	c.mu.Lock()
	defer c.mu.Unlock()
	sample := &c.reasons[reason]
	sample.Total++
	sample.Interval++
	if _, found := c.seen[reason][fingerprint]; found {
		sample.Repeated++
	} else if len(c.seen[reason]) < maximumTrackedDenials {
		if c.seen[reason] == nil {
			c.seen[reason] = make(map[[32]byte]struct{})
		}
		c.seen[reason][fingerprint] = struct{}{}
		sample.Distinct++
	} else {
		sample.Untracked++
	}
}

type denialReport struct {
	Event string `json:"event"`
	relayIdentity
	IntervalSeconds float64 `json:"interval_seconds"`
	Reason          string  `json:"reason,omitempty"`
	reasonCounts
}

func (c *denialCounters) write(w io.Writer) {
	c.mu.Lock()
	now := time.Now()
	interval := now.Sub(c.reportedAt).Seconds()
	var reports []denialReport
	for reason := range c.reasons {
		sample := c.reasons[reason]
		if sample.Total != 0 {
			reports = append(reports, denialReport{Event: "relay_policy_totals", relayIdentity: c.identity,
				IntervalSeconds: interval, Reason: reasonNames[reason], reasonCounts: sample})
		}
		c.reasons[reason] = reasonCounts{Total: sample.Total}
		c.seen[reason] = nil
	}
	c.reportedAt = now
	if len(reports) == 0 {
		reports = append(reports, denialReport{Event: "relay_policy_totals", relayIdentity: c.identity, IntervalSeconds: interval})
	}
	c.mu.Unlock()
	// A blocked log consumer must not hold up packet handling or process shutdown.
	// Each reason fits one atomic Darwin pipe write, even with maximum counters.
	encoder := json.NewEncoder(w)
	for _, report := range reports {
		if err := encoder.Encode(report); err != nil {
			return
		}
	}
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
