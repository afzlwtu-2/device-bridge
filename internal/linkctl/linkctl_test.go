package linkctl

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseIwListCapabilitiesAndUSBADBSerials(t *testing.T) {
	iwSample := `
Wiphy phy0
	Supported interface modes:
		 * managed
		 * AP
		 * P2P-client
		 * P2P-GO
	Band 1:
		Frequencies:
			* 2412 MHz [1] (20.0 dBm)
		HE Iftypes: managed
	Band 2:
		Frequencies:
			* 5180 MHz [36] (20.0 dBm)
			* 5745 MHz [149] (20.0 dBm)
		HE PHY Capabilities: (0x04701e1f)
			HE40/HE80/5GHz
`
	w5, w6, w6g, p2p, ap, sta := ParseIwListCapabilities(iwSample)
	if !w5 || !w6 || w6g || !p2p || !ap || !sta {
		t.Fatalf("unexpected iw capabilities: 5g=%v 6=%v 6g=%v p2p=%v ap=%v sta=%v", w5, w6, w6g, p2p, ap, sta)
	}

	iw6gSample := `
	Band 3:
		Frequencies:
			* 5955 MHz [1]
			* 6115 MHz [33]
`
	_, _, has6g, _, _, _ := ParseIwListCapabilities(iw6gSample)
	if !has6g {
		t.Fatalf("expected 6GHz band detection")
	}

	adbOut := `List of devices attached
JBKJF6JFAAIZUGP7       device usb:1-2 product:duchamp_global model:2311DRK48G device:duchamp transport_id:4
192.168.1.10:5555      device product:duchamp_global model:2311DRK48G transport_id:5
adb-JBKJF6JFAAIZUGP7-xyz._adb-tls-connect._tcp device product:duchamp_global
offline-dev            offline usb:1-3
`
	serials := USBADBSerials(adbOut)
	if len(serials) != 1 || serials[0] != "JBKJF6JFAAIZUGP7" {
		t.Fatalf("expected only wired USB ADB serial JBKJF6JFAAIZUGP7, got %v", serials)
	}

	iwPK := `
	Band 2:
		Frequencies:
			* 5180.0 MHz [36] (disabled)
			* 5745.0 MHz [149] (30.0 dBm)
			* 5805.0 MHz [161] (30.0 dBm)
			* 5825.0 MHz [165] (30.0 dBm)
`
	usable5g, limited := ParseIwListDetails(iwPK)
	if !limited {
		t.Fatalf("expected reg5gLimited=true when 5180 MHz is disabled")
	}
	if len(usable5g) != 3 || usable5g[0] != 165 || usable5g[1] != 161 || usable5g[2] != 149 {
		t.Fatalf("unexpected usable 5GHz channels: %v", usable5g)
	}
	if got := FreqToChannel(5805); got != 161 {
		t.Fatalf("expected channel 161 for 5805 MHz, got %d", got)
	}
	if got := ChannelToFreq(161); got != 5805 {
		t.Fatalf("expected 5805 MHz for channel 161, got %d", got)
	}
	if c := ParseIwRegCountry("global\ncountry PK: DFS-UNSET\n"); c != "PK" {
		t.Fatalf("expected country PK, got %q", c)
	}
}

func TestFindADBPathFromAndroidHome(t *testing.T) {
	sdk := t.TempDir()
	pt := filepath.Join(sdk, "platform-tools")
	if err := os.MkdirAll(pt, 0o755); err != nil {
		t.Fatal(err)
	}
	fakeAdb := filepath.Join(pt, "adb")
	if err := os.WriteFile(fakeAdb, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", "")
	t.Setenv("ANDROID_HOME", sdk)
	t.Setenv("ANDROID_SDK_ROOT", "")
	if got := FindADBPath(); got != fakeAdb {
		t.Fatalf("FindADBPath() = %q, want %q", got, fakeAdb)
	}
}
