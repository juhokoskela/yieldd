package main

import (
	"encoding/binary"
	"testing"
)

func sampleFrame() []byte {
	frame := make([]byte, 54)
	copy(frame[:6], []byte{2, 0, 0, 0, 0, 1})
	copy(frame[6:12], guestHardware)
	binary.BigEndian.PutUint16(frame[12:14], 0x0800)
	frame[14] = 0x45
	binary.BigEndian.PutUint16(frame[16:18], 40)
	frame[23] = 6
	copy(frame[26:30], guestAddress)
	copy(frame[30:34], []byte{8, 8, 8, 8})
	return frame
}

func TestFrameBoundary(t *testing.T) {
	if _, valid := frameRejection(sampleFrame()); !valid {
		t.Fatal("valid IPv4 frame denied")
	}
	for _, test := range []struct {
		name   string
		mutate func([]byte) []byte
		reason denialReason
	}{
		{"short", func(b []byte) []byte { return b[:13] }, frameMalformed},
		{"oversize", func(b []byte) []byte { return append(b, make([]byte, 1514)...) }, frameMalformed},
		{"spoofed MAC", func(b []byte) []byte { b[6] = 4; return b }, frameIdentity},
		{"spoofed IP", func(b []byte) []byte { b[26] = 8; return b }, frameIdentity},
		{"IPv6", func(b []byte) []byte { b[12] = 0x86; b[13] = 0xdd; return b }, frameIPv6},
		{"VLAN", func(b []byte) []byte { b[12] = 0x81; b[13] = 0; return b }, frameProtocol},
		{"fragment", func(b []byte) []byte { b[20] = 0x20; return b }, frameFragment},
		{"options", func(b []byte) []byte { b[14] = 0x46; return b }, frameOptions},
		{"wrong IP version", func(b []byte) []byte { b[14] = 0x65; return b }, frameMalformed},
		{"short IP header", func(b []byte) []byte { b[14] = 0x44; return b }, frameMalformed},
		{"truncated IP options", func(b []byte) []byte { b[14] = 0x4f; return b }, frameMalformed},
		{"options exceed IP size", func(b []byte) []byte { b[14] = 0x46; b[17] = 20; return b }, frameMalformed},
		{"ICMP", func(b []byte) []byte { b[23] = 1; return b }, frameProtocol},
	} {
		t.Run(test.name, func(t *testing.T) {
			reason, valid := frameRejection(test.mutate(sampleFrame()))
			if valid || reason != test.reason {
				t.Fatal("invalid frame permitted or incorrectly categorized", reason, test.reason)
			}
		})
	}
}

func FuzzFrameBoundary(f *testing.F) {
	f.Add(sampleFrame())
	f.Add([]byte{})
	f.Fuzz(func(_ *testing.T, data []byte) { frameRejection(data) })
}

func TestARPReasonsSeparateNeighborsFromIdentitySpoofing(t *testing.T) {
	for _, test := range []struct {
		name   string
		edit   func([]byte)
		reason denialReason
	}{
		{"neighbor", func(p []byte) { p[27] = 3 }, frameNeighbor},
		{"unsupported operation", func(p []byte) { p[7] = 3 }, frameProtocol},
		{"sender hardware", func(p []byte) { p[8] = 4 }, frameIdentity},
		{"sender address", func(p []byte) { p[17] = 3 }, frameIdentity},
	} {
		t.Run(test.name, func(t *testing.T) {
			frame := make([]byte, 42)
			copy(frame[6:12], guestHardware)
			binary.BigEndian.PutUint16(frame[12:14], 0x0806)
			payload := frame[14:]
			copy(payload, []byte{0, 1, 8, 0, 6, 4, 0, 1})
			copy(payload[8:14], guestHardware)
			copy(payload[14:18], guestAddress)
			copy(payload[24:28], gatewayAddress)
			if _, valid := frameRejection(frame); !valid {
				t.Fatal("valid gateway ARP was rejected")
			}
			test.edit(payload)
			if reason, valid := frameRejection(frame); valid || reason != test.reason {
				t.Fatal("ARP rejection misclassified", reason, test.reason)
			}
		})
	}
}
