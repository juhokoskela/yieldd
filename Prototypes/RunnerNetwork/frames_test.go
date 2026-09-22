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
	if !validFrame(sampleFrame()) {
		t.Fatal("valid IPv4 frame denied")
	}
	for _, test := range []struct {
		name   string
		mutate func([]byte) []byte
	}{
		{"short", func(b []byte) []byte { return b[:13] }},
		{"oversize", func(b []byte) []byte { return append(b, make([]byte, 1514)...) }},
		{"spoofed MAC", func(b []byte) []byte { b[6] = 4; return b }},
		{"spoofed IP", func(b []byte) []byte { b[26] = 8; return b }},
		{"IPv6", func(b []byte) []byte { b[12] = 0x86; b[13] = 0xdd; return b }},
		{"VLAN", func(b []byte) []byte { b[12] = 0x81; b[13] = 0; return b }},
		{"fragment", func(b []byte) []byte { b[20] = 0x20; return b }},
		{"options", func(b []byte) []byte { b[14] = 0x46; return b }},
		{"ICMP", func(b []byte) []byte { b[23] = 1; return b }},
	} {
		t.Run(test.name, func(t *testing.T) {
			if validFrame(test.mutate(sampleFrame())) {
				t.Fatal("invalid frame permitted")
			}
		})
	}
}

func FuzzFrameBoundary(f *testing.F) {
	f.Add(sampleFrame())
	f.Add([]byte{})
	f.Fuzz(func(_ *testing.T, data []byte) { validFrame(data) })
}
