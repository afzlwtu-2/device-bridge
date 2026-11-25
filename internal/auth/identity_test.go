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

func TestLoadUsesVivoRetailNameAndKeepsIdentity(t *testing.T) {
	s, err := storage.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	first, err := Load(s, "V2427")
	if err != nil {
		t.Fatal(err)
	}
	if first.Name != "Vivo V50" {
		t.Fatalf("new identity name = %q", first.Name)
	}
	if _, err := s.DB.Exec("UPDATE identity SET name='V2427' WHERE singleton=1"); err != nil {
		t.Fatal(err)
	}
	migrated, err := Load(s, "")
	if err != nil {
		t.Fatal(err)
	}
	if migrated.Name != "Vivo V50" || migrated.ID != first.ID {
		t.Fatalf("migrated identity = %q %q, want Vivo V50 %q", migrated.Name, migrated.ID, first.ID)
	}
	inv, err := migrated.Invite(s)
	if err != nil {
		t.Fatal(err)
	}
	if inv.Name != migrated.Name || inv.ID != first.ID {
		t.Fatal("invitation did not use the updated name and original fingerprint")
	}
}
