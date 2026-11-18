package auth

import (
	"devicebridge/internal/storage"
	"path/filepath"
	"testing"
)

func TestLoadUpgradesPlaceholderAndroidName(t *testing.T) {
	s, err := storage.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	first, err := Load(s, "Android phone")
	if err != nil {
		t.Fatal(err)
	}
	if first.Name != "Android phone" {
		t.Fatalf("got %q want Android phone", first.Name)
	}

	upgraded, err := Load(s, "POCO X6 Pro 5G")
	if err != nil {
		t.Fatal(err)
	}
	if upgraded.Name != "POCO X6 Pro 5G" || upgraded.ID != first.ID {
		t.Fatalf("got name=%q id=%q want POCO X6 Pro 5G / %q", upgraded.Name, upgraded.ID, first.ID)
	}

	// Real device names are not overwritten by another name on re-init.
	kept, err := Load(s, "Other Name")
	if err != nil {
		t.Fatal(err)
	}
	if kept.Name != "POCO X6 Pro 5G" {
		t.Fatalf("got %q want POCO X6 Pro 5G", kept.Name)
	}
}
