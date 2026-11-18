//go:build android && cgo

package discovery

/*
#include <net/if.h>
#include <stdlib.h>
*/
import "C"
import (
	"errors"
	"net"
	"unsafe"
)

// Android blocks unprivileged netlink enumeration on recent releases. libc's
// if_nametoindex obtains the index without enumerating protected route state.
func networkInterface(name string) (*net.Interface, error) {
	s := C.CString(name)
	defer C.free(unsafe.Pointer(s))
	index := C.if_nametoindex(s)
	if index == 0 {
		return nil, errors.New("LAN interface unavailable")
	}
	return &net.Interface{Index: int(index), Name: name, Flags: net.FlagUp | net.FlagMulticast}, nil
}
