package main

import (
	"context"
	"encoding/binary"
	"net"
	"strings"
	"time"

	"github.com/miekg/dns"
)

const publicResolver = "1.1.1.1:53"

// Forward DNS directly so host search domains, hosts files, VPN resolvers, and
// mDNS are never consulted. Public DNS is still an Internet egress channel.
func publicDNS(ctx context.Context, dial func(string, string) (net.Conn, error), counts *denialCounters) dns.Handler {
	slots := make(chan struct{}, 16)
	return dns.HandlerFunc(func(w dns.ResponseWriter, request *dns.Msg) {
		response := new(dns.Msg)
		response.SetReply(request)
		response.RecursionAvailable = true
		defer func() {
			if w.LocalAddr().Network() == "udp" {
				response.Truncate(dns.MinMsgSize)
			}
			_ = w.WriteMsg(response)
		}()
		if request.Opcode != dns.OpcodeQuery || len(request.Question) != 1 {
			response.Rcode = dns.RcodeRefused
			counts.record(dnsMalformed, []byte{byte(request.Opcode)})
			return
		}
		question := request.Question[0]
		name := strings.ToLower(question.Name)
		// Ignore transaction IDs and case when tracking repeated questions.
		signature := append([]byte(name), 0)
		signature = binary.BigEndian.AppendUint16(signature, question.Qtype)
		signature = binary.BigEndian.AppendUint16(signature, question.Qclass)
		if question.Qclass != dns.ClassINET || !dns.IsFqdn(name) {
			response.Rcode = dns.RcodeRefused
			counts.record(dnsMalformed, signature)
			return
		}
		if !strings.Contains(strings.TrimSuffix(name, "."), ".") ||
			name == "home.arpa." || strings.HasSuffix(name, ".home.arpa.") ||
			strings.HasSuffix(name, ".local.") || strings.HasSuffix(name, ".localhost.") {
			response.Rcode = dns.RcodeRefused
			counts.record(dnsLocalName, signature)
			return
		}
		if question.Qtype != dns.TypeA && question.Qtype != dns.TypeAAAA {
			response.Rcode = dns.RcodeRefused
			counts.record(dnsRecordType, signature)
			return
		}
		// There is no IPv6 packet path in this prototype. Answer AAAA with NODATA.
		if question.Qtype == dns.TypeAAAA {
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			response.Rcode = dns.RcodeServerFailure
			counts.record(dnsSaturated, signature)
			return
		}
		// TCP avoids truncated recursive answers and uses the same checked dial
		// path as guest TCP traffic. No fallback to another resolver is allowed.
		connection, err := dial("tcp", publicResolver)
		if err != nil {
			response.Rcode = dns.RcodeServerFailure
			if ctx.Err() == nil {
				counts.record(dnsUpstreamFailure, signature)
			}
			return
		}
		defer connection.Close()
		query := new(dns.Msg)
		query.SetQuestion(question.Name, dns.TypeA)
		lookup, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		stop := context.AfterFunc(lookup, func() { connection.Close() })
		defer stop()
		answer, _, err := (&dns.Client{Timeout: 5 * time.Second}).ExchangeWithConnContext(lookup, query, &dns.Conn{Conn: connection})
		if err != nil {
			response.Rcode = dns.RcodeServerFailure
			if ctx.Err() == nil {
				counts.record(dnsUpstreamFailure, signature)
			}
			return
		}
		response.Rcode = answer.Rcode
		response.Answer = answer.Answer
	})
}
