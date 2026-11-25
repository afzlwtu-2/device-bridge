package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"devicebridge/internal/transfer"
)

func writePullPolicy(t *testing.T, path, value string) {
	t.Helper()
	tmp := path + ".new"
	if err := os.WriteFile(tmp, []byte(value), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

func TestMeteredPullApprovalIsScopedToOneSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pull-a")
	policy := pullPolicy{snapshot: path}
	writePullPolicy(t, path, `{"tailnet_handle":"100","tailnet_cost":"metered"}`)
	if _, err := policy.allowTailnet(); !errors.Is(err, transfer.ErrMeteredPull) {
		t.Fatalf("unapproved mobile data should pause the download: %v", err)
	}
	writePullPolicy(t, path, `{"tailnet_handle":"100","tailnet_cost":"metered","metered_approved":true}`)
	if handle, err := policy.allowTailnet(); err != nil || handle != "100" {
		t.Fatalf("approved download should use the metered route: %s %v", handle, err)
	}
	next := pullPolicy{snapshot: filepath.Join(t.TempDir(), "pull-b")}
	writePullPolicy(t, next.snapshot, `{"tailnet_handle":"100","tailnet_cost":"metered","metered_approved":false}`)
	if _, err := next.allowTailnet(); !errors.Is(err, transfer.ErrMeteredPull) {
		t.Fatalf("a second download should need its own approval: %v", err)
	}
	writePullPolicy(t, next.snapshot, `{"metered_approved":true}`)
	if _, err := next.allowTailnet(); !errors.Is(err, transfer.ErrRouteChanged) {
		t.Fatalf("unknown network should remain unavailable even after approval: %v", err)
	}
}

func TestMeteredChangePausesAnOpenTailnetDownload(t *testing.T) {
	policy := pullPolicy{snapshot: filepath.Join(t.TempDir(), "pull")}
	writePullPolicy(t, policy.snapshot, `{"tailnet_handle":"100","tailnet_cost":"unmetered"}`)
	parent, stop := context.WithTimeout(context.Background(), 3*time.Second)
	defer stop()
	attempt, release, err := policy.guard(parent)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	writePullPolicy(t, policy.snapshot, `{"tailnet_handle":"101","tailnet_cost":"metered","metered_approved":false}`)
	<-attempt.Done()
	if err := context.Cause(attempt); !errors.Is(err, transfer.ErrMeteredPull) {
		t.Fatalf("expected the active stream to pause for approval, got %v", err)
	}
	writePullPolicy(t, policy.snapshot, `{"tailnet_handle":"102","tailnet_cost":"unmetered"}`)
	if handle, err := policy.allowTailnet(); err != nil || handle != "102" {
		t.Fatalf("Wi-Fi recovery should not require approval: %s %v", handle, err)
	}
}
