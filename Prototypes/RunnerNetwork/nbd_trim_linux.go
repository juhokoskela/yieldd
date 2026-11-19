package main

import (
	"os"

	"golang.org/x/sys/unix"
)

func punchNativeDisk(disk *os.File, offset, length int64) error {
	return unix.Fallocate(int(disk.Fd()), unix.FALLOC_FL_KEEP_SIZE|unix.FALLOC_FL_PUNCH_HOLE, offset, length)
}
