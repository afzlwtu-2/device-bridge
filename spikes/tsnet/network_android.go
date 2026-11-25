//go:build android && cgo

package main

/*
#include <net/if.h>
#include <stdlib.h>
*/
import "C"
import (
	"devicebridge/internal/platform"
	"errors"
	"golang.org/x/sys/unix"
	"net"
	"os"
	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"unsafe"
)

// Android denies app UIDs netlink enumeration. Supply the OS-approved Wi-Fi
// LinkProperties through tsnet's public interface adapter, without root/TUN.
func configureNetworkMonitor() error {
	extraIface, extraCidr := os.Getenv("DEVICEBRIDGE_EXTRA_INTERFACE"), os.Getenv("DEVICEBRIDGE_EXTRA_CIDR")
	netns.SetAndroidBindToNetworkFunc(func(fd int) error {
		if extraIface != "" && extraCidr != "" {
			if st, serr := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_TYPE); serr == nil && st == unix.SOCK_DGRAM {
				return nil
			}
		}
		return platform.BindApprovedSocket(uintptr(fd))
	})
	name, cidr := os.Getenv("DEVICEBRIDGE_INTERFACE"), os.Getenv("DEVICEBRIDGE_LAN_CIDR")
	if name == "" || cidr == "" {
		return errors.New("Android tsnet requires an approved Wi-Fi network")
	}
	ip, prefix, err := net.ParseCIDR(cidr)
	if err != nil {
		return err
	}
	prefix.IP = ip
	n := C.CString(name)
	defer C.free(unsafe.Pointer(n))
	index := C.if_nametoindex(n)
	if index == 0 {
		return errors.New("approved Wi-Fi interface unavailable")
	}
	ifaces := []netmon.Interface{
		{Interface: &net.Interface{Index: 1, Name: "lo", MTU: 65536, Flags: net.FlagUp | net.FlagLoopback}, AltAddrs: []net.Addr{&net.IPNet{IP: net.IPv4(127, 0, 0, 1), Mask: net.CIDRMask(8, 32)}}},
		{Interface: &net.Interface{Index: int(index), Name: name, MTU: 1500, Flags: net.FlagUp | net.FlagRunning | net.FlagMulticast | net.FlagBroadcast}, AltAddrs: []net.Addr{prefix}},
	}
	if extraIface != "" && extraCidr != "" {
		if eip, eprefix, perr := net.ParseCIDR(extraCidr); perr == nil {
			eprefix.IP = eip
			en := C.CString(extraIface)
			eidx := C.if_nametoindex(en)
			C.free(unsafe.Pointer(en))
			if eidx > 0 {
				ifaces = append(ifaces, netmon.Interface{
					Interface: &net.Interface{Index: int(eidx), Name: extraIface, MTU: 1500, Flags: net.FlagUp | net.FlagRunning | net.FlagMulticast | net.FlagBroadcast},
					AltAddrs:  []net.Addr{eprefix},
				})
			}
		}
	}
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		return ifaces, nil
	})
	netmon.UpdateLastKnownDefaultRouteInterface(name)
	return nil
}
