package storage

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

func TestInterruptedLinkOperationNeedsExplicitRecovery(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	peer := strings.Repeat("c", 64)
	if _, err = s.DB.Exec("INSERT INTO peers(id,name,status,expires) VALUES(?,?,?,0)", peer, "fixture", "paired"); err != nil {
		t.Fatal(err)
	}
	op, err := s.LinkOperation(ctx, peer, "begin", "hotspot", "phone", "")
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	recovered, err := s.LinkOperation(ctx, peer, "", "", "", "")
	if err != nil || recovered.ID != op.ID || recovered.Stage != "preparing" {
		t.Fatal("interrupted operation lost")
	}
	if _, err = s.LinkOperation(ctx, peer, "begin", "wifi_direct", "phone", ""); err == nil {
		t.Fatal("new operation replaced pending recovery")
	}
	if _, err = s.LinkOperation(ctx, peer, "restored", "", "", "wrong-id"); err == nil {
		t.Fatal("stale cleanup accepted")
	}
	if _, err = s.LinkOperation(ctx, peer, "restored", "", "", op.ID); err != nil {
		t.Fatal(err)
	}
	next, err := s.LinkOperation(ctx, peer, "begin", "wifi_direct", "laptop", "")
	if err != nil || next.ID == op.ID {
		t.Fatal("recovered operation could not restart")
	}
}
