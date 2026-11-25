package main

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestWiredADBDiscoveryDoesNotCreateTunnels(t *testing.T) {
	if runtime.GOOS != "linux" || os.Geteuid() == 0 {
		t.Skip("test installs a temporary ADB fixture for an unprivileged Linux CLI")
	}
	sdk := t.TempDir()
	platformTools := filepath.Join(sdk, "platform-tools")
	if err := os.Mkdir(platformTools, 0o700); err != nil {
		t.Fatal(err)
	}
	mutations := filepath.Join(sdk, "unexpected-commands")
	t.Setenv("PATH", sdk)
	t.Setenv("ANDROID_HOME", sdk)
	t.Setenv("ADB_FIXTURE_MUTATIONS", mutations)
	const script = `#!/bin/sh
case "$*" in
  'devices -l') printf '%s\n' 'USB123 device usb:3-3 model:Vivo' 'SIM123 device product:virtual' ;;
  'forward --list') printf '%s\n' 'USB123 tcp:12345 tcp:8731' ;;
  *) printf '%s\n' "$*" >> "$ADB_FIXTURE_MUTATIONS"; exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(platformTools, "adb"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	got := discoverADBDevices(context.Background())
	if len(got) != 1 || got[0].Serial != "USB123" || got[0].Endpoint != "127.0.0.1:12345" {
		t.Fatalf("wired device or existing forward missing: %+v", got)
	}
	if _, err := os.Stat(mutations); !os.IsNotExist(err) {
		t.Fatalf("listing devices changed ADB forwards: %v", err)
	}
}
