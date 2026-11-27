package bootstrap

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTermuxBootstrapVerifiesAndPublishesCompletePrefix(t *testing.T) {
	root := t.TempDir()
	prefix := filepath.Join(root, "usr")
	if err := os.Mkdir(prefix, 0700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(prefix, "previous")
	if err := os.WriteFile(marker, []byte("keep until publish"), 0600); err != nil {
		t.Fatal(err)
	}
	var contents bytes.Buffer
	archive := zip.NewWriter(&contents)
	for name, data := range map[string]string{
		"bin/bash": "bash", "bin/apt-get": "apt", "SYMLINKS.txt": "bash←bin/sh\n",
	} {
		out, err := archive.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := out.Write([]byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "bootstrap.zip")
	if err := os.WriteFile(file, contents.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if err := installTermuxBase(t.Context(), file, strings.Repeat("0", 64), prefix); err == nil {
		t.Fatal("accepted a bootstrap that failed verification")
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal(err)
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(contents.Bytes()))
	if err := installTermuxBase(t.Context(), file, digest, prefix); err != nil {
		t.Fatal(err)
	}
	if !termuxBasePresent(prefix) {
		t.Fatal("published prefix is incomplete")
	}
	if link, err := os.Readlink(filepath.Join(prefix, "bin", "sh")); err != nil || link != "bash" {
		t.Fatalf("bootstrap link = %q, %v", link, err)
	}
	saved, err := filepath.Glob(filepath.Join(root, ".devicebridge-bootstrap-*", "previous"))
	if err != nil || len(saved) != 1 {
		t.Fatalf("previous prefix should be retained: %v, %v", saved, err)
	}
}

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
