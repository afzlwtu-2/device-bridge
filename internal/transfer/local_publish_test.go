package transfer

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocalPublishNeverOverwrites(t *testing.T) {
	parent := t.TempDir()
	stage := filepath.Join(parent, ".devicebridge-local-0123456789abcdef")
	if err := os.Mkdir(stage, 0700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(stage, "data")
	destination := filepath.Join(parent, "received")
	if err := os.WriteFile(source, []byte("verified"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := PublishLocal(source, destination); err == nil {
		t.Fatal("overwrote destination")
	}
	data, _ := os.ReadFile(destination)
	if string(data) != "original" {
		t.Fatal("destination changed")
	}
	other := filepath.Join(parent, "published")
	if err := PublishLocal(source, other); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(other)
	if string(data) != "verified" {
		t.Fatal("payload changed")
	}
	if err := PublishLocal(other, filepath.Join(parent, "unsafe")); err == nil {
		t.Fatal("accepted non-staging source")
	}
}
