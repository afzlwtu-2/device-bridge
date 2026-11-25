// Package protocol defines the backwards-compatible DeviceBridge JSON wire schema.
package protocol

import (
	"strings"
	"time"
)

const Version = 1
const GoCoreVersion = "1.4.0"

// ManifestVersion 2 uses XXH64 (seed zero), matching xxhsum -H1.
const ManifestVersion = 2
const Service = "_devicebridge._tcp"

// DeviceDisplayName expands a known factory model name without changing a device ID.
func DeviceDisplayName(name string) string {
	if strings.EqualFold(strings.TrimSpace(name), "V2427") {
		return "Vivo V50"
	}
	return name
}

type WifiLinkInfo struct {
	Interface    string `json:"interface,omitempty"`
	Band         string `json:"band,omitempty"`
	Channel      int    `json:"channel,omitempty"`
	FrequencyMHz int    `json:"frequency_mhz,omitempty"`
	BandwidthMHz int    `json:"bandwidth_mhz,omitempty"`
	WifiStandard string `json:"wifi_standard,omitempty"`
	SSID         string `json:"ssid,omitempty"`
}

type DeviceCapabilities struct {
	OS                 string        `json:"os,omitempty"`
	Wifi5GHz           bool          `json:"wifi_5ghz,omitempty"`
	Wifi6              bool          `json:"wifi_6,omitempty"`
	Wifi6GHz           bool          `json:"wifi_6ghz,omitempty"`
	WifiDirect         bool          `json:"wifi_direct,omitempty"`
	WifiDirectGO       bool          `json:"wifi_direct_go,omitempty"`
	HotspotAP          bool          `json:"hotspot_ap,omitempty"`
	Hotspot5GHzAP      bool          `json:"hotspot_5ghz_ap,omitempty"`
	HotspotSTA         bool          `json:"hotspot_sta,omitempty"`
	USBAdb             bool          `json:"usb_adb,omitempty"`
	Usable5GHz         []int         `json:"usable_5ghz_channels,omitempty"`
	RegCountry         string        `json:"reg_country,omitempty"`
	Reg5GHzLimited     bool          `json:"reg_5ghz_limited,omitempty"`
	CanSetRegdom       bool          `json:"can_set_regdom,omitempty"`
	TailnetEndpoint    string        `json:"tailnet_endpoint,omitempty"`
	WireGuardEndpoints []string      `json:"wireguard_endpoints,omitempty"`
	Link               *WifiLinkInfo `json:"link,omitempty"`
	CheckedAt          int64         `json:"checked_at_utc,omitempty"`
}

type ConnectionPrepareRequest struct {
	OperationID  string `json:"operation_id,omitempty"`
	LeaseSeconds int    `json:"lease_seconds,omitempty"`
	Kind         string `json:"kind"` // adb_usb | hotspot | wifi_direct | wifi_join | link_status | restore
	Mode         string `json:"mode,omitempty"`
	SSID         string `json:"ssid,omitempty"`
	Passphrase   string `json:"passphrase,omitempty"`
	BSSID        string `json:"bssid,omitempty"`
	Band         string `json:"band,omitempty"` // 6ghz | 5ghz | 2ghz | auto
	Channel      int    `json:"channel,omitempty"`
	FrequencyMHz int    `json:"frequency_mhz,omitempty"`
	BandwidthMHz int    `json:"bandwidth_mhz,omitempty"`
	PeerIP       string `json:"peer_ip,omitempty"`
	PeerCIDR     string `json:"peer_cidr,omitempty"`
	Serial       string `json:"serial,omitempty"`
}

type ConnectionPrepareResult struct {
	OK                 bool                `json:"ok"`
	Kind               string              `json:"kind"`
	Transport          string              `json:"transport,omitempty"`
	Endpoint           string              `json:"endpoint,omitempty"`
	Interface          string              `json:"interface,omitempty"`
	IP                 string              `json:"ip,omitempty"`
	CIDR               string              `json:"cidr,omitempty"`
	SSID               string              `json:"ssid,omitempty"`
	Passphrase         string              `json:"passphrase,omitempty"`
	Band               string              `json:"band,omitempty"`
	Channel            int                 `json:"channel,omitempty"`
	FrequencyMHz       int                 `json:"frequency_mhz,omitempty"`
	BandwidthMHz       int                 `json:"bandwidth_mhz,omitempty"`
	WifiStandard       string              `json:"wifi_standard,omitempty"`
	Serial             string              `json:"serial,omitempty"`
	PreviousConnection string              `json:"previous_connection,omitempty"`
	Status             string              `json:"status,omitempty"`
	Message            string              `json:"message,omitempty"`
	Capabilities       *DeviceCapabilities `json:"capabilities,omitempty"`
}

type Device struct {
	Version      int                 `json:"version"`
	ID           string              `json:"id"`
	Name         string              `json:"name"`
	Features     []string            `json:"features"`
	Capabilities *DeviceCapabilities `json:"capabilities,omitempty"`
}
type Invitation struct {
	Version     int       `json:"version"`
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Token       string    `json:"token"`
	Expires     time.Time `json:"expires"`
	LANEndpoint string    `json:"lan_endpoint,omitempty"`
}
type PairRequest struct {
	Token string `json:"token"`
	Name  string `json:"name"`
}
type PairStatus struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

const TermuxFilesFeature = "termux-files-v1"

type VerifiedRemoval struct {
	Root     string   `json:"root"`
	Path     string   `json:"path"`
	XXH64    string   `json:"xxh64"`
	Excludes []string `json:"excludes,omitempty"`
}

type Root struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Writable bool   `json:"writable"`
}
type Entry struct {
	Name     string    `json:"name"`
	Path     string    `json:"path"`
	Kind     string    `json:"kind"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
}
type Listing struct {
	Entries []Entry `json:"entries"`
	Next    string  `json:"next,omitempty"`
}
type ManifestEntry struct {
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	XXH64     string `json:"xxh64"`
	Directory bool   `json:"directory"`
}
type Manifest struct {
	Excludes []string        `json:"excludes,omitempty"`
	Version  int             `json:"version"`
	Root     string          `json:"root"`
	Path     string          `json:"path"`
	Entries  []ManifestEntry `json:"entries"`
	Bytes    int64           `json:"bytes"`
}
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

const MaxSharedTextBytes = 4096
const TextShareFeature = "quick-share-text-v1"

type TextShareRequest struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

type TextShareMessage struct {
	ID           string `json:"id"`
	PeerID       string `json:"peer_id"`
	PeerName     string `json:"peer_name"`
	Text         string `json:"text"`
	ReceivedUnix int64  `json:"received_unix"` // milliseconds
}
