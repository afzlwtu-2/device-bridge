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
	"net"
	"os"
	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"unsafe"
)

// Android denies app UIDs netlink enumeration. Supply the OS-approved Wi-Fi
// LinkProperties through tsnet's public interface adapter, without root/TUN.
func configureNetworkMonitor() error {
	netns.SetAndroidBindToNetworkFunc(func(fd int) error { return platform.BindApprovedSocket(uintptr(fd)) })
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
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		return []netmon.Interface{{Interface: &net.Interface{Index: 1, Name: "lo", MTU: 65536, Flags: net.FlagUp | net.FlagLoopback}, AltAddrs: []net.Addr{&net.IPNet{IP: net.IPv4(127, 0, 0, 1), Mask: net.CIDRMask(8, 32)}}}, {Interface: &net.Interface{Index: int(index), Name: name, MTU: 1500, Flags: net.FlagUp | net.FlagRunning | net.FlagMulticast | net.FlagBroadcast}, AltAddrs: []net.Addr{prefix}}}, nil
	})
	netmon.UpdateLastKnownDefaultRouteInterface(name)
	return nil
}
