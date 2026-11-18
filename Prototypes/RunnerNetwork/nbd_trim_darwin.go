package main

import (
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

func punchNativeDisk(disk *os.File, offset, length int64) error {
	// Darwin's fpunchhole_t from sys/fcntl.h, with zero flags and reserved fields.
	hole := struct {
		flags, reserved uint32
		offset, length  int64
	}{offset: offset, length: length}
	_, _, errno := unix.Syscall(unix.SYS_FCNTL, disk.Fd(), unix.F_PUNCHHOLE, uintptr(unsafe.Pointer(&hole)))
	if errno != 0 {
		return errno
	}
	return nil
}
