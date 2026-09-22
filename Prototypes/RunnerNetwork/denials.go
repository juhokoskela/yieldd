package main

import (
	"context"
	"encoding/json"
	"io"
	"sync/atomic"
	"time"
)

type denialCounters struct {
	destinations atomic.Uint64
	frames       atomic.Uint64
	dns          atomic.Uint64
}

func (c *denialCounters) write(w io.Writer) {
	// Fixed-size aggregate output only, never guest-provided addresses or names.
	_ = json.NewEncoder(w).Encode(struct {
		Event        string `json:"event"`
		Destinations uint64 `json:"denied_destinations"`
		Frames       uint64 `json:"dropped_frames"`
		DNS          uint64 `json:"rejected_dns"`
	}{"relay_policy_totals", c.destinations.Load(), c.frames.Load(), c.dns.Load()})
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
