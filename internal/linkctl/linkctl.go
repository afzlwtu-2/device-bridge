// Package linkctl inspects wireless/USB capabilities and orchestrates wired USB ADB,
// 5GHz/6GHz Wi-Fi 6 Hotspot, and Wi-Fi Direct connections without routing or system edits.
package linkctl

import (
	"devicebridge/protocol"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	EnvCapabilitiesJSON = "DEVICEBRIDGE_CAPABILITIES_JSON"
	EnvLinkctlEndpoint  = "DEVICEBRIDGE_LINKCTL_ENDPOINT"
	EnvLinkctlToken     = "DEVICEBRIDGE_LINKCTL_TOKEN"
)

var iwFreqRe = regexp.MustCompile(`(\d{4})(?:\.\d+)?\s*MHz`)

// FreqToChannel converts a Wi-Fi center frequency in MHz to its channel number.
func FreqToChannel(freq int) int {
	switch {
	case freq == 2484:
		return 14
	case freq >= 2412 && freq <= 2472:
		return (freq - 2407) / 5
	case freq >= 5150 && freq <= 5925:
		return (freq - 5000) / 5
	case freq == 5935:
		return 2
	case freq >= 5955 && freq <= 7115:
		return (freq - 5950) / 5
	default:
		return 0
	}
}

// ChannelToFreq converts a 2.4 GHz or 5 GHz Wi-Fi channel number to its frequency in MHz.
func ChannelToFreq(ch int) int {
	switch {
	case ch == 14:
		return 2484
	case ch >= 1 && ch <= 13:
		return 2407 + ch*5
	case ch >= 32 && ch <= 177:
		return 5000 + ch*5
	default:
		return 0
	}
}

// ParseIwListDetails extracts enabled AP-capable 5 GHz channels (sorted descending)
// and whether any 5 GHz channels are disabled or restricted (e.g. awaiting `iw reg set US`).
func ParseIwListDetails(iwOutput string) (usable5gAP []int, reg5gLimited bool) {
	seen := map[int]bool{}
	for _, raw := range strings.Split(iwOutput, "\n") {
		t := strings.TrimSpace(raw)
		m := iwFreqRe.FindStringSubmatch(t)
		if len(m) != 2 {
			continue
		}
		f, err := strconv.Atoi(m[1])
		if err != nil || f < 5150 || f > 5925 {
			continue
		}
		lower := strings.ToLower(t)
		disabled := strings.Contains(lower, "disabled") ||
			strings.Contains(lower, "no ir") ||
			strings.Contains(lower, "radar detection")
		if disabled {
			reg5gLimited = true
			continue
		}
		if ch := FreqToChannel(f); ch > 0 && !seen[ch] {
			seen[ch] = true
			usable5gAP = append(usable5gAP, ch)
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(usable5gAP)))
	return usable5gAP, reg5gLimited
}

// ParseIwRegCountry extracts the active regulatory country code from `iw reg get` output.
func ParseIwRegCountry(regOut string) string {
	for _, raw := range strings.Split(regOut, "\n") {
		t := strings.TrimSpace(raw)
		if strings.HasPrefix(t, "country ") {
			rest := strings.TrimSpace(strings.TrimPrefix(t, "country "))
			code := strings.SplitN(rest, ":", 2)[0]
			code = strings.TrimSpace(code)
			if code != "" {
				return code
			}
		}
	}
	return ""
}

// ParseIwListCapabilities extracts supported Wi-Fi bands, 802.11ax (Wi-Fi 6),
// AP/STA, and P2P modes from `iw list` output.
func ParseIwListCapabilities(iwOutput string) (wifi5g, wifi6, wifi6g, wifiDirect, hotspotAP, hotspotSTA bool) {
	lines := strings.Split(iwOutput, "\n")
	inModes := false
	for _, raw := range lines {
		t := strings.TrimSpace(raw)
		if strings.HasPrefix(t, "Supported interface modes:") {
			inModes = true
			continue
		}
		if inModes {
			if strings.HasPrefix(t, "* ") {
				mode := strings.TrimSpace(strings.TrimPrefix(t, "* "))
				switch mode {
				case "managed":
					hotspotSTA = true
				case "AP":
					hotspotAP = true
				case "P2P-client", "P2P-GO":
					wifiDirect = true
				}
				continue
			}
			inModes = false
		}
		if strings.Contains(t, "HE Iftypes:") || strings.Contains(t, "HE PHY Capabilities:") {
			wifi6 = true
		}
		if m := iwFreqRe.FindStringSubmatch(t); len(m) == 2 {
			if f, err := strconv.Atoi(m[1]); err == nil {
				if f >= 5150 && f <= 5925 {
					wifi5g = true
				} else if f > 5925 && f <= 7125 {
					wifi6g = true
				}
			}
		}
		if strings.Contains(t, "/5GHz") {
			wifi5g = true
		}
		if strings.Contains(t, "/6GHz") {
			wifi6g = true
		}
	}
	return
}

// FindADBPath locates the host `adb` binary even when background systemd/agent
// services run with a minimal PATH that omits Android SDK platform-tools.
func FindADBPath() string {
	if runtime.GOOS != "linux" {
		return ""
	}
	root := os.Geteuid() == 0
	if path, err := exec.LookPath("adb"); err == nil {
		if !root {
			return path
		}
		// A root service must not execute binaries from a user's SDK or PATH.
		if system := rootOwnedADB(path); system != "" {
			return system
		}
	}
	var candidates []string
	if !root {
		for _, envVar := range []string{"ANDROID_HOME", "ANDROID_SDK_ROOT"} {
			if root := strings.TrimSpace(os.Getenv(envVar)); root != "" {
				candidates = append(candidates, filepath.Join(root, "platform-tools", "adb"))
			}
		}
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			candidates = append(candidates,
				filepath.Join(home, "Android", "Sdk", "platform-tools", "adb"),
				filepath.Join(home, "Android", "sdk", "platform-tools", "adb"),
			)
		}
	}
	candidates = append(candidates,
		"/usr/lib/android-sdk/platform-tools/adb",
		"/usr/local/bin/adb",
		"/usr/bin/adb",
	)
	for _, c := range candidates {
		if root {
			if system := rootOwnedADB(c); system != "" {
				return system
			}
			continue
		}
		if info, err := os.Stat(c); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return c
		}
	}
	return ""
}

func rootOwnedADB(path string) string {
	if !filepath.IsAbs(path) {
		return ""
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return ""
	}
	for candidate := resolved; ; candidate = filepath.Dir(candidate) {
		info, err := os.Stat(candidate)
		if err != nil {
			return ""
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 || info.Mode().Perm()&0o022 != 0 {
			return ""
		}
		if candidate == resolved && (!info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0) {
			return ""
		}
		if candidate == "/" {
			return resolved
		}
	}
}

// USBADBSerials parses `adb devices -l` and returns only wired USB serials,
// requiring the USB transport field reported by the host.
func USBADBSerials(adbDevicesOutput string) []string {
	var out []string
	for _, line := range strings.Split(adbDevicesOutput, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "List of devices") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[1] != "device" {
			continue
		}
		serial := fields[0]
		if strings.Contains(serial, ":") || strings.Contains(serial, "_adb-tls-connect") ||
			!slices.ContainsFunc(fields[2:], func(field string) bool { return strings.HasPrefix(field, "usb:") }) {
			continue
		}
		out = append(out, serial)
	}
	return out
}

func envCapabilities() *protocol.DeviceCapabilities {
	raw := strings.TrimSpace(os.Getenv(EnvCapabilitiesJSON))
	if raw == "" {
		return nil
	}
	var caps protocol.DeviceCapabilities
	if err := json.Unmarshal([]byte(raw), &caps); err != nil {
		return nil
	}
	if caps.CheckedAt == 0 {
		caps.CheckedAt = time.Now().Unix()
	}
	return &caps
}
