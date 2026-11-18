package platform

import "syscall"

// SocketControl applies Android's public per-socket Network binding to sockets
// created by Go's syscall path as well as libc-created sockets.
func SocketControl(_, _ string, c syscall.RawConn) error {
	var bindErr error
	err := c.Control(func(fd uintptr) { bindErr = BindApprovedSocket(fd) })
	if err != nil {
		return err
	}
	return bindErr
}
