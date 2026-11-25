package bootstrap

import "testing"

func TestTermuxCompanionUsesApprovedLANAndPrivateState(t *testing.T) {
	state, err := termuxCompanionState("/data/data/com.termux/files/home")
	if err != nil || state != "/data/data/com.termux/files/usr/var/lib/devicebridge-companion" {
		t.Fatalf("companion state = %q, %v", state, err)
	}
	if _, err := termuxCompanionState("/root"); err == nil {
		t.Fatal("accepted a home outside the Termux sandbox")
	}
	cidr, err := termuxLAN("192.168.1.23/23", "192.168.0.10")
	if err != nil || cidr != "192.168.0.10/23" {
		t.Fatalf("companion CIDR = %q, %v", cidr, err)
	}
	for _, address := range []string{"127.0.0.1", "8.8.8.8", "192.168.2.10", ""} {
		if _, err := termuxLAN("192.168.1.23/23", address); err == nil {
			t.Fatalf("accepted unapproved SSH address %q", address)
		}
	}
}
