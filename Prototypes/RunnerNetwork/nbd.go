package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	nbdMagic       = uint64(0x4e42444d41474943)
	nbdOptionMagic = uint64(0x49484156454f5054)
	nbdReplyMagic  = uint64(0x3e889045565a9)
	nbdRequest     = uint32(0x25609513)
	nbdReply       = uint32(0x67446698)

	nbdOptExport  = 1
	nbdOptAbort   = 2
	nbdOptInfo    = 6
	nbdOptGo      = 7
	nbdAck        = 1
	nbdInfo       = 3
	nbdErrUnsup   = 0x80000001
	nbdErrInvalid = 0x80000003
	nbdErrUnknown = 0x80000006

	nbdRead       = 0
	nbdWrite      = 1
	nbdDisconnect = 2
	nbdFlush      = 3

	// HAS_FLAGS, SEND_FLUSH and SEND_FUA. A disk has exactly one writer.
	nbdExportFlags = uint16(1 | 4 | 8)
	nbdMaxRequest  = 32 << 20
)

var nbdOrder = binary.BigEndian

// The listener belongs to one guest's isolated network. Only its host can place
// the marker after authorizing the job. No wire field selects a host pathname.
func serveNativeDisk(ctx context.Context, listener net.Listener, directory string) error {
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()
	defer listener.Close()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		cancelConn := context.AfterFunc(ctx, func() { conn.Close() })
		consumed, sessionErr := nativeDiskConnection(conn, directory)
		cancelConn()
		conn.Close()
		if !consumed {
			continue
		}
		// Never accept another writer, even on a lost disconnect or failed sync.
		if sessionErr != nil {
			return nil
		}
		// The host checks the exact confirmation before publishing the checkout.
		marker, err := os.OpenFile(filepath.Join(directory, "native-disk-closed"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		_, err = marker.WriteString("closed")
		return errors.Join(err, marker.Close())
	}
}

func nativeDiskConnection(conn net.Conn, directory string) (bool, error) {
	marker, _, err := openNativeDiskFile(filepath.Join(directory, "native-disk"), os.O_RDONLY, 4096)
	if err != nil {
		return false, err
	}
	path, readErr := io.ReadAll(io.LimitReader(marker, 4097))
	if err := errors.Join(readErr, marker.Close()); err != nil {
		return false, err
	}
	if len(path) > 4096 || !utf8.Valid(path) || !filepath.IsAbs(string(path)) {
		return false, errors.New("invalid cache disk marker")
	}
	disk, size, err := openNativeDiskFile(string(path), os.O_RDWR, 8<<30)
	if err != nil {
		return false, err
	}
	if size%512 != 0 {
		disk.Close()
		return false, errors.New("unaligned cache disk")
	}
	if err := conn.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		disk.Close()
		return false, err
	}
	selected, err := negotiateNativeDisk(conn, uint64(size))
	if selected && err == nil {
		if err = conn.SetDeadline(time.Time{}); err == nil {
			err = transmitNativeDisk(conn, disk, uint64(size))
		}
	}
	return selected, errors.Join(err, disk.Close())
}

func openNativeDiskFile(path string, flags int, maximum int64) (*os.File, int64, error) {
	file, err := os.OpenFile(path, flags|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, 0, err
	}
	info, err := file.Stat()
	if err == nil {
		st := info.Sys().(*syscall.Stat_t)
		if info.Mode().IsRegular() && info.Mode().Perm() == 0600 && st.Uid == uint32(os.Geteuid()) &&
			st.Nlink == 1 && info.Size() > 0 && info.Size() <= maximum {
			return file, info.Size(), nil
		}
		err = errors.New("invalid private cache file")
	}
	file.Close()
	return nil, 0, err
}

func negotiateNativeDisk(conn net.Conn, size uint64) (bool, error) {
	hello := nbdOrder.AppendUint64(nil, nbdMagic)
	hello = nbdOrder.AppendUint64(hello, nbdOptionMagic)
	hello = nbdOrder.AppendUint16(hello, 3) // FIXED_NEWSTYLE, NO_ZEROES
	if _, err := conn.Write(hello); err != nil {
		return false, err
	}
	var flags uint32
	if err := binary.Read(conn, nbdOrder, &flags); err != nil {
		return false, err
	}
	if flags&1 == 0 || flags&^3 != 0 {
		return false, errors.New("invalid NBD client flags")
	}

	for {
		var header struct {
			Magic          uint64
			Option, Length uint32
		}
		if err := binary.Read(conn, nbdOrder, &header); err != nil {
			return false, err
		}
		if header.Magic != nbdOptionMagic || header.Length > 4096 {
			return false, errors.New("invalid NBD option")
		}
		payload := make([]byte, header.Length)
		if _, err := io.ReadFull(conn, payload); err != nil {
			return false, err
		}
		reply := func(kind uint32, data []byte) error {
			buf := nbdOrder.AppendUint64(nil, nbdReplyMagic)
			buf = nbdOrder.AppendUint32(buf, header.Option)
			buf = nbdOrder.AppendUint32(buf, kind)
			buf = nbdOrder.AppendUint32(buf, uint32(len(data)))
			_, err := conn.Write(append(buf, data...))
			return err
		}
		switch header.Option {
		case nbdOptExport:
			if len(payload) != 0 {
				return false, errors.New("unknown cache export")
			}
			buf := nbdOrder.AppendUint64(nil, size)
			buf = nbdOrder.AppendUint16(buf, nbdExportFlags)
			if flags&2 == 0 {
				buf = append(buf, make([]byte, 124)...)
			}
			_, err := conn.Write(buf)
			return true, err
		case nbdOptInfo, nbdOptGo:
			if len(payload) < 6 || uint64(nbdOrder.Uint32(payload)) > uint64(len(payload)-6) {
				return false, reply(nbdErrInvalid, nil)
			}
			if nbdOrder.Uint32(payload) != 0 {
				return false, reply(nbdErrUnknown, nil)
			}
			if len(payload) != 6+2*int(nbdOrder.Uint16(payload[4:])) {
				return false, reply(nbdErrInvalid, nil)
			}
			info := nbdOrder.AppendUint16(nil, 0) // NBD_INFO_EXPORT
			info = nbdOrder.AppendUint64(info, size)
			if err := reply(nbdInfo, nbdOrder.AppendUint16(info, nbdExportFlags)); err != nil {
				return false, err
			}
			if header.Option == nbdOptGo {
				return true, reply(nbdAck, nil)
			}
			if err := reply(nbdAck, nil); err != nil {
				return false, err
			}
		case nbdOptAbort:
			return false, reply(nbdAck, nil)
		default:
			if err := reply(nbdErrUnsup, nil); err != nil {
				return false, err
			}
		}
	}
}

func transmitNativeDisk(conn net.Conn, disk *os.File, size uint64) error {
	var req struct {
		Magic          uint32
		Flags, Command uint16
		Handle, Offset uint64
		Length         uint32
	}
	buf := make([]byte, 128<<10)
	for {
		if err := binary.Read(conn, nbdOrder, &req); err != nil {
			return err
		}
		if req.Magic != nbdRequest || req.Length > nbdMaxRequest {
			return errors.New("invalid NBD request")
		}
		if req.Offset > size || uint64(req.Length) > size-req.Offset {
			return errors.New("NBD request outside cache disk")
		}
		if req.Flags != 0 && !(req.Flags == 1 && req.Command == nbdWrite) {
			return errors.New("unsupported NBD request flags")
		}
		if (req.Command == nbdFlush || req.Command == nbdDisconnect) && (req.Offset != 0 || req.Length != 0) {
			return errors.New("invalid NBD control request")
		}

		var operationErr error
		switch req.Command {
		case nbdRead:
		case nbdWrite:
			target := io.NewOffsetWriter(disk, int64(req.Offset))
			var written int64
			written, operationErr = io.CopyBuffer(target, io.LimitReader(conn, int64(req.Length)), buf)
			if operationErr == nil && written != int64(req.Length) {
				return io.ErrUnexpectedEOF
			}
			if operationErr == nil && req.Flags == 1 {
				operationErr = disk.Sync()
			}
		case nbdFlush:
			operationErr = disk.Sync()
		case nbdDisconnect:
			return disk.Sync()
		default:
			return errors.New("unsupported NBD command")
		}
		status := uint32(0)
		if operationErr != nil {
			status = 5
		} // NBD_EIO
		header := nbdOrder.AppendUint32(nil, nbdReply)
		header = nbdOrder.AppendUint32(header, status)
		if _, err := conn.Write(nbdOrder.AppendUint64(header, req.Handle)); err != nil {
			return err
		}
		if operationErr != nil {
			return operationErr
		}
		if req.Command == nbdRead {
			n, err := io.CopyBuffer(conn, io.NewSectionReader(disk, int64(req.Offset), int64(req.Length)), buf)
			if err != nil {
				return err
			}
			if n != int64(req.Length) {
				return io.ErrUnexpectedEOF
			}
		}
	}
}
