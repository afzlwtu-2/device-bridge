package bootstrap

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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

func TestTermuxFastfetchConfigUpgradesTo49ColTopLogo(t *testing.T) {
	home := t.TempDir()
	fastfetchDir := filepath.Join(home, ".config", "fastfetch")
	if err := os.MkdirAll(fastfetchDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(fastfetchDir, "config.jsonc")
	if err := os.WriteFile(cfgPath, []byte("// DEVICEBRIDGE_FASTFETCH_V1 old config\n{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := configureTermuxShellExperience("", home); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	if !strings.HasPrefix(text, "// DEVICEBRIDGE_FASTFETCH_V2") {
		t.Fatalf("expected upgrade to V2 sentinel, got %q", text[:min(len(text), 48)])
	}
	_, body, found := strings.Cut(text, "\n")
	if !found {
		t.Fatal("missing newline after header")
	}
	var parsed map[string]any
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		t.Fatalf("invalid fastfetch JSON config: %v", err)
	}
	logo := parsed["logo"].(map[string]any)
	if logo["type"] != "data" || logo["position"] != "top" {
		t.Fatalf("expected top data logo for 49-col layout, got %+v", logo)
	}
}
