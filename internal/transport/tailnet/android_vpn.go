package tailnet

import (
	"context"
	"devicebridge/internal/platform"
	"net"
	"net/netip"
	"syscall"
	"time"
)

var tailnetIPv4 = netip.MustParsePrefix("100.64.0.0/10")

// AndroidVPN uses the app-visible Android VPN Network without reading its private state.
type AndroidVPN struct {
	handle string
	ip     netip.Addr
}

func NewAndroidVPN(handle, address string) *AndroidVPN {
	ip, err := netip.ParseAddr(address)
	if handle == "" || err != nil || !tailnetIPv4.Contains(ip) {
		return nil
	}
	return &AndroidVPN{handle: handle, ip: ip}
}

func (v *AndroidVPN) canReach(endpoint string) bool {
	address, err := netip.ParseAddrPort(endpoint)
	return v != nil && err == nil && address.Port() == 8731 &&
		address.Addr() != v.ip && tailnetIPv4.Contains(address.Addr())
}

func (v *AndroidVPN) dial(ctx context.Context, endpoint string) (net.Conn, error) {
	dialer := net.Dialer{
		Timeout:   5 * time.Second,
		LocalAddr: &net.TCPAddr{IP: net.IP(v.ip.AsSlice())},
		Control: func(_, _ string, conn syscall.RawConn) error {
			var bindErr error
			if err := conn.Control(func(fd uintptr) { bindErr = platform.BindSocketToNetwork(fd, v.handle) }); err != nil {
				return err
			}
			return bindErr
		},
	}
	return dialer.DialContext(ctx, "tcp4", endpoint)
}
