// Package pty provides zero-dependency Linux/Android PTY allocation and resize helpers.
package pty

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

type winsize struct {
	Row    uint16
	Col    uint16
	Xpixel uint16
	Ypixel uint16
}

// ClampSize bounds terminal dimensions to safe PTY limits.
func ClampSize(columns, rows int) (int, int) {
	return min(max(1, columns), 512), min(max(1, rows), 256)
}

// Open allocates a /dev/ptmx master/slave PTY pair initialized to cols x rows.
func Open(cols, rows int) (master *os.File, slave *os.File, err error) {
	ptmx, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, nil, fmt.Errorf("open /dev/ptmx: %w", err)
	}
	defer func() {
		if err != nil {
			_ = ptmx.Close()
		}
	}()

	var unlock int32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, ptmx.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); errno != 0 {
		return nil, nil, fmt.Errorf("unlockpt: %w", errno)
	}

	var ptn uint32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, ptmx.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&ptn))); errno != 0 {
		return nil, nil, fmt.Errorf("ptsname: %w", errno)
	}

	_ = SetSize(ptmx, cols, rows)

	slavePath := fmt.Sprintf("/dev/pts/%d", ptn)
	pts, err := os.OpenFile(slavePath, os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, nil, fmt.Errorf("open %s: %w", slavePath, err)
	}
	return ptmx, pts, nil
}

// SetSize updates the window dimensions on an open PTY master fd.
func SetSize(master *os.File, cols, rows int) error {
	c, r := ClampSize(cols, rows)
	ws := winsize{
		Row: uint16(r),
		Col: uint16(c),
	}
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, master.Fd(), syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws))); errno != 0 {
		return errno
	}
	return nil
}
