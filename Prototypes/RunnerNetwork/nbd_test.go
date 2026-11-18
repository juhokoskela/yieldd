package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type nativeDiskFixture struct {
	listener         net.Listener
	directory, image string
	done             chan error
	cancel           context.CancelFunc
}

func newNativeDiskFixture(t *testing.T) nativeDiskFixture {
	t.Helper()
	directory := t.TempDir()
	image := filepath.Join(directory, "disk")
	if err := os.WriteFile(image, make([]byte, 4096), 0600); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- serveNativeDisk(ctx, listener, directory); close(done) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	})
	return nativeDiskFixture{listener, directory, image, done, cancel}
}

func (f nativeDiskFixture) bind(t *testing.T) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.directory, "native-disk"), []byte(f.image), 0600); err != nil {
		t.Fatal(err)
	}
}

func (f nativeDiskFixture) dial(t *testing.T) net.Conn {
	t.Helper()
	conn, err := net.DialTimeout("tcp", f.listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func nbdWriteBinary(t *testing.T, w io.Writer, fields ...any) {
	t.Helper()
	for _, field := range fields {
		if err := binary.Write(w, binary.BigEndian, field); err != nil {
			t.Fatal(err)
		}
	}
}

func nbdReadBytes(t *testing.T, r io.Reader, length int) []byte {
	t.Helper()
	data := make([]byte, length)
	if _, err := io.ReadFull(r, data); err != nil {
		t.Fatal(err)
	}
	return data
}

func nbdClientHeader(t *testing.T, conn net.Conn) {
	t.Helper()
	data := nbdReadBytes(t, conn, 18)
	if string(data[:16]) != "NBDMAGICIHAVEOPT" || binary.BigEndian.Uint16(data[16:]) != 3 {
		t.Fatalf("unexpected greeting %x", data)
	}
	nbdWriteBinary(t, conn, uint32(3))
}

func nbdClientOption(t *testing.T, conn net.Conn, option uint32, data []byte) {
	t.Helper()
	nbdWriteBinary(t, conn, nbdOptionMagic, option, uint32(len(data)), data)
}

func nbdClientRequest(t *testing.T, conn net.Conn, command, flags uint16, offset uint64, length uint32) {
	t.Helper()
	nbdWriteBinary(t, conn, nbdRequest, flags, command, uint64(17), offset, length)
}

func nbdClientReply(t *testing.T, conn net.Conn) {
	t.Helper()
	header := nbdReadBytes(t, conn, 16)
	if nbdOrder.Uint32(header) != nbdReply || nbdOrder.Uint32(header[4:]) != 0 || nbdOrder.Uint64(header[8:]) != 17 {
		t.Fatalf("bad simple reply %x", header)
	}
}

func TestNativeDiskSingleAuthorizedExport(t *testing.T) {
	f := newNativeDiskFixture(t)
	probe := f.dial(t)
	var b [1]byte
	if _, err := probe.Read(b[:]); !errors.Is(err, io.EOF) {
		t.Fatalf("unbound: %v", err)
	}
	f.bind(t)
	info := f.dial(t)
	nbdClientHeader(t, info)
	nbdClientOption(t, info, nbdOptInfo, make([]byte, 6))
	reply := nbdReadBytes(t, info, 32)
	if nbdOrder.Uint32(reply[12:]) != nbdInfo || nbdOrder.Uint64(reply[22:]) != 4096 {
		t.Fatalf("bad info %x", reply)
	}
	nbdReadBytes(t, info, 20)
	info.Close()

	conn := f.dial(t)
	nbdClientHeader(t, conn)
	nbdClientOption(t, conn, nbdOptGo, make([]byte, 6))
	nbdReadBytes(t, conn, 32)
	ack := nbdReadBytes(t, conn, 20)
	if nbdOrder.Uint32(ack[12:]) != nbdAck {
		t.Fatalf("bad go acknowledgement %x", ack)
	}
	data := bytes.Repeat([]byte{0xab}, 512)
	nbdClientRequest(t, conn, nbdWrite, 1, 3584, 512)
	nbdWriteBinary(t, conn, data)
	nbdClientReply(t, conn)
	nbdClientRequest(t, conn, nbdFlush, 0, 0, 0)
	nbdClientReply(t, conn)
	nbdClientRequest(t, conn, nbdRead, 0, 3584, 512)
	nbdClientReply(t, conn)
	if got := nbdReadBytes(t, conn, 512); !bytes.Equal(got, data) {
		t.Fatal("unexpected readback")
	}
	if _, err := os.Stat(filepath.Join(f.directory, "native-disk-closed")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("premature confirmation: %v", err)
	}
	nbdClientRequest(t, conn, nbdDisconnect, 0, 0, 0)
	if err := <-f.done; err != nil {
		t.Fatal(err)
	}
	marker, err := os.ReadFile(filepath.Join(f.directory, "native-disk-closed"))
	if err != nil || string(marker) != "closed" {
		t.Fatalf("missing close confirmation: %q %v", marker, err)
	}
	if conn, err := net.Dial("tcp", f.listener.Addr().String()); err == nil {
		conn.Close()
		t.Fatal("listener accepted second writer")
	}
	stored, err := os.ReadFile(f.image)
	if err != nil || len(stored) != 4096 || !bytes.Equal(stored[3584:], data) {
		t.Fatal("disk write was not retained")
	}
}

func TestNativeDiskDiscardsFailedTransmission(t *testing.T) {
	for _, name := range []string{"eof", "truncated", "sealed-truncated-header", "sealed-truncated-payload", "out-of-bounds", "overflow", "oversized", "cancel"} {
		t.Run(name, func(t *testing.T) {
			f := newNativeDiskFixture(t)
			f.bind(t)
			conn := f.dial(t)
			nbdClientHeader(t, conn)
			nbdClientOption(t, conn, nbdOptExport, nil)
			nbdReadBytes(t, conn, 10)
			if name == "sealed-truncated-header" || name == "sealed-truncated-payload" {
				if err := os.WriteFile(filepath.Join(f.directory, "native-disk-seal"), []byte("seal"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			switch name {
			case "eof":
				conn.Close()
			case "sealed-truncated-header":
				nbdWriteBinary(t, conn, nbdRequest)
				conn.Close()
			case "truncated", "sealed-truncated-payload":
				nbdClientRequest(t, conn, nbdWrite, 0, 0, 512)
				nbdWriteBinary(t, conn, []byte("partial"))
				conn.Close()
			case "out-of-bounds":
				nbdClientRequest(t, conn, nbdWrite, 0, 4096, 1)
			case "overflow":
				nbdClientRequest(t, conn, nbdWrite, 0, ^uint64(0), 2)
			case "oversized":
				nbdClientRequest(t, conn, nbdWrite, 0, 0, nbdMaxRequest+1)
			case "cancel":
				f.cancel()
			}
			select {
			case err := <-f.done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("disk server stalled")
			}
			if _, err := os.Stat(filepath.Join(f.directory, "native-disk-closed")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("unexpected confirmation: %v", err)
			}
			if info, err := os.Stat(f.image); err != nil || info.Size() != 4096 {
				t.Fatal("disk grew beyond its fixed size")
			}
		})
	}
}

func TestNativeDiskRequiresPrivateRegularFiles(t *testing.T) {
	f := newNativeDiskFixture(t)
	alias := filepath.Join(f.directory, "link")
	if err := os.Symlink(f.image, alias); err != nil {
		t.Fatal(err)
	}
	if _, _, err := openNativeDiskFile(alias, os.O_RDWR, 4096); err == nil {
		t.Fatal("followed symlink")
	}
	if _, _, err := openNativeDiskFile(f.image, os.O_RDWR, 1024); err == nil {
		t.Fatal("accepted oversized file")
	}
	if err := os.Chmod(f.image, 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := openNativeDiskFile(f.image, os.O_RDWR, 4096); err == nil {
		t.Fatal("accepted shared disk")
	}
}

func TestNativeDiskCleanEOFWithHostSeal(t *testing.T) {
	f := newNativeDiskFixture(t)
	f.bind(t)
	conn := f.dial(t)
	nbdClientHeader(t, conn)
	nbdClientOption(t, conn, nbdOptExport, nil)
	nbdReadBytes(t, conn, 10)
	if err := os.WriteFile(filepath.Join(f.directory, "native-disk-seal"), []byte("seal"), 0600); err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if err := <-f.done; err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(f.directory, "native-disk-closed"))
	if err != nil || string(got) != "closed" {
		t.Fatalf("sealed EOF not acknowledged: %q %v", got, err)
	}
}
