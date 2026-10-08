package main

import (
	"bytes"
	"encoding/binary"
	"net"
)

const (
	guestIP    = "192.168.127.2"
	guestMAC   = "02:00:00:00:00:02"
	gatewayIP  = "192.168.127.1"
	gatewayMAC = "02:00:00:00:00:01"
)

var guestHardware = []byte{2, 0, 0, 0, 0, 2}
var guestAddress = []byte{192, 168, 127, 2}
var gatewayAddress = []byte{192, 168, 127, 1}

// Bound packets and identities before upstream's Ethernet switch learns them.
// This prototype deliberately has no IPv6, VLAN, IP options, or fragments.
func validFrame(frame []byte) bool {
	_, valid := frameRejection(frame)
	return valid
}

func frameRejection(frame []byte) (denialReason, bool) {
	if len(frame) < 14 || len(frame) > 1514 {
		return frameMalformed, false
	}
	if !bytes.Equal(frame[6:12], guestHardware) {
		return frameIdentity, false
	}
	payload := frame[14:]
	switch binary.BigEndian.Uint16(frame[12:14]) {
	case 0x0806:
		if len(payload) < 28 || !bytes.Equal(payload[:6], []byte{0, 1, 8, 0, 6, 4}) {
			return frameMalformed, false
		}
		op := binary.BigEndian.Uint16(payload[6:8])
		return frameIdentity, (op == 1 || op == 2) && bytes.Equal(payload[8:14], guestHardware) &&
			(bytes.Equal(payload[14:18], guestAddress) || bytes.Equal(payload[14:18], []byte{0, 0, 0, 0})) &&
			(bytes.Equal(payload[24:28], gatewayAddress) || bytes.Equal(payload[24:28], guestAddress))
	case 0x0800:
		if len(payload) < 20 {
			return frameMalformed, false
		}
		if payload[0] != 0x45 {
			return frameOptions, false
		}
		if binary.BigEndian.Uint16(payload[6:8])&0xbfff != 0 {
			return frameFragment, false
		}
		size := int(binary.BigEndian.Uint16(payload[2:4]))
		if size < 20 || size > len(payload) {
			return frameMalformed, false
		}
		if bytes.Equal(payload[12:16], guestAddress) {
			return frameProtocol, payload[9] == 6 || payload[9] == 17
		}
		return frameIdentity, bytes.Equal(payload[12:16], []byte{0, 0, 0, 0}) && payload[9] == 17 && size >= 28 &&
			binary.BigEndian.Uint16(payload[20:22]) == 68 && binary.BigEndian.Uint16(payload[22:24]) == 67 &&
			bytes.Equal(payload[16:20], []byte{255, 255, 255, 255})
	case 0x86dd:
		return frameIPv6, false
	default:
		return frameProtocol, false
	}
}

type filteredConn struct {
	net.Conn
	counts *denialCounters
}

func (c filteredConn) Read(buffer []byte) (int, error) {
	for {
		n, err := c.Conn.Read(buffer)
		if err != nil {
			return 0, err
		}
		reason, valid := frameRejection(buffer[:n])
		if valid {
			return n, nil
		}
		c.counts.record(reason, buffer[:n])
	}
}
