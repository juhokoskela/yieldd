package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"time"

	"github.com/miekg/dns"
)

const resultsHost = "results-receiver.actions.githubusercontent.com"

func githubResultsTransport(counts *denialCounters) *http.Transport {
	return &http.Transport{
		// Resolve through the relay's public DNS service. Validate each numeric
		// address at dial time; net/http still authenticates resultsHost via TLS.
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if network != "tcp" || address != resultsHost+":443" {
				return nil, errDenied
			}
			ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			dial := outboundDial(ctx, counts)
			answer, err := exchangeDNS(ctx, dial, resultsHost+".")
			if err != nil {
				return nil, err
			}
			if answer.Rcode != dns.RcodeSuccess {
				return nil, errors.New("results host lookup failed")
			}
			lastErr := errors.New("results host has no IPv4 address")
			for _, record := range answer.Answer {
				if a, ok := record.(*dns.A); ok {
					conn, err := dial("tcp", net.JoinHostPort(a.A.String(), "443"))
					if err == nil {
						return conn, nil
					}
					lastErr = err
				}
			}
			return nil, lastErr
		},
		TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: time.Minute,
		MaxConnsPerHost: 8, IdleConnTimeout: time.Minute,
	}
}
