package main

import (
	"net"
	"strings"
	"testing"
)

func TestResolveInterfaceCIDRAutoSkipsVirtualAndLoopback(t *testing.T) {
	t.Parallel()
	ifaceName, cidr, err := resolveInterfaceCIDR("auto")
	if err != nil {
		t.Skipf("no non-virtual IPv4 interface active in environment: %v", err)
	}
	if ifaceName == "" || cidr == "" {
		t.Fatalf("expected non-empty interface and cidr, got %q %q", ifaceName, cidr)
	}
	low := strings.ToLower(ifaceName)
	for _, excluded := range []string{"lo", "tailscale", "tun", "wg", "docker", "waydroid"} {
		if strings.HasPrefix(low, excluded) {
			t.Fatalf("auto resolver selected excluded interface %q (%q)", ifaceName, cidr)
		}
	}
	ip, _, err := net.ParseCIDR(cidr)
	if err != nil || ip.To4() == nil || ip.IsLoopback() {
		t.Fatalf("expected valid IPv4 non-loopback CIDR, got %q (err=%v)", cidr, err)
	}
}
