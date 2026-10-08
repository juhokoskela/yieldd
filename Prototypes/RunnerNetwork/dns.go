package main

import (
	"context"
	"encoding/binary"
	"errors"
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
		var signature []byte
		refuse := func(reason denialReason) { response.Rcode = dns.RcodeRefused; counts.record(reason, signature) }
		if request.Opcode != dns.OpcodeQuery || len(request.Question) != 1 {
			signature = []byte{byte(request.Opcode)}
			refuse(dnsMalformed)
			return
		}
		question := request.Question[0]
		name := strings.ToLower(question.Name)
		// Ignore transaction IDs and case when tracking repeated questions.
		signature = append([]byte(name), 0)
		signature = binary.BigEndian.AppendUint16(signature, question.Qtype)
		signature = binary.BigEndian.AppendUint16(signature, question.Qclass)
		if question.Qclass != dns.ClassINET || !dns.IsFqdn(name) {
			refuse(dnsMalformed)
			return
		}
		if !strings.Contains(strings.TrimSuffix(name, "."), ".") ||
			name == "home.arpa." || strings.HasSuffix(name, ".home.arpa.") ||
			strings.HasSuffix(name, ".local.") || strings.HasSuffix(name, ".localhost.") {
			refuse(dnsLocalName)
			return
		}
		if question.Qtype != dns.TypeA && question.Qtype != dns.TypeAAAA {
			refuse(dnsRecordType)
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
		answer, err := exchangeDNS(ctx, dial, question.Name)
		if err != nil {
			response.Rcode = dns.RcodeServerFailure
			var denied *deniedDestination
			if ctx.Err() == nil && !errors.As(err, &denied) {
				counts.record(dnsUpstreamFailure, signature)
			}
			return
		}
		response.Rcode = answer.Rcode
		response.Answer = answer.Answer
	})
}

func exchangeDNS(ctx context.Context, dial func(string, string) (net.Conn, error), name string) (*dns.Msg, error) {
	// TCP avoids truncated answers and uses the guest's checked dial path.
	connection, err := dial("tcp", publicResolver)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	query := new(dns.Msg)
	query.SetQuestion(name, dns.TypeA)
	lookup, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	stop := context.AfterFunc(lookup, func() { connection.Close() })
	defer stop()
	answer, _, err := (&dns.Client{Timeout: 5 * time.Second}).ExchangeWithConnContext(lookup, query, &dns.Conn{Conn: connection})
	return answer, err
}
