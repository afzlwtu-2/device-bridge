//go:build linux && !android

package linkctl

import "testing"

func TestConcurrentWifiDirectRequiresStationAPAndGO(t *testing.T) {
	t.Parallel()
	const managed = "valid interface combinations:\n\t * #{ managed } <= 1, "
	if !supportsConcurrentWifiDirect(managed + "#{ AP, P2P-client, P2P-GO } <= 1, total <= 2, #channels <= 1") {
		t.Fatal("concurrent AP and GO modes were not recognized")
	}
	if supportsConcurrentWifiDirect(managed + "#{ P2P-GO } <= 1, total <= 2, #channels <= 2") {
		t.Fatal("private supplicant requires concurrent AP support during startup")
	}
}

func TestParseIwLinkDetails(t *testing.T) {
	t.Parallel()
	linkOut := `Connected to a8:41:f4:70:52:02 (on wlan0)
	SSID: DIRECT-DB-abbf
	freq: 5745.0
	RX: 20705941 bytes (17523 packets)
	TX: 4231090 bytes (6112 packets)
	tx bitrate: 1201.0 MBit/s 80MHz HE-MCS 11 HE-NSS 2
	rx bitrate: 860.4 MBit/s 80MHz HE-MCS 9 HE-NSS 2`
	infoOut := `Interface wlan0
	ifindex 3
	type managed
	channel 149 (5745 MHz), width: 80 MHz, center1: 5775 MHz`

	got := ParseIwLinkDetails("wlan0", linkOut, infoOut)
	if got == nil {
		t.Fatal("expected parsed link details")
	}
	if got.Band != "5 GHz" || got.FrequencyMHz != 5745 || got.BandwidthMHz != 80 || got.WifiStandard != "Wi-Fi 6 (802.11ax)" || got.SSID != "DIRECT-DB-abbf" {
		t.Fatalf("unexpected link details: %+v", got)
	}

	vht := ParseIwLinkDetails("wlan0", "freq: 5180\ntx bitrate: 866.7 MBit/s 80MHz VHT-MCS 9", "")
	if vht == nil || vht.Band != "5 GHz" || vht.WifiStandard != "Wi-Fi 5 (802.11ac)" {
		t.Fatalf("expected Wi-Fi 5 5 GHz, got %+v", vht)
	}

	ht := ParseIwLinkDetails("wlan0", "freq: 2437\ntx bitrate: 144.4 MBit/s MCS 15", "")
	if ht == nil || ht.Band != "2.4 GHz" || ht.WifiStandard != "Wi-Fi 4 (802.11n)" {
		t.Fatalf("expected Wi-Fi 4 2.4 GHz, got %+v", ht)
	}
}
