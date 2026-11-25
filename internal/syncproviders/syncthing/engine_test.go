package syncthing

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestExplicitEngineWithoutPATHAndInvalidOverride(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "libbridge_sync.so")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\nprintf 'syncthing v2.1.7\\n'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", t.TempDir())
	t.Setenv("DEVICEBRIDGE_SYNCTHING_BINARY", bin)
	info, err := Open(t.TempDir()).Inspect(context.Background())
	if err != nil || !info.Installed || info.Version != "v2.1.7" {
		t.Fatalf("explicit app engine: %+v %v", info, err)
	}
	t.Setenv("DEVICEBRIDGE_SYNCTHING_BINARY", "relative-engine")
	if _, err := engineBinary(); err == nil {
		t.Fatal("accepted a relative engine override")
	}
	t.Setenv("DEVICEBRIDGE_SYNCTHING_BINARY", filepath.Join(t.TempDir(), "missing"))
	if _, err := engineBinary(); err == nil {
		t.Fatal("invalid override silently fell back to PATH")
	}
}
