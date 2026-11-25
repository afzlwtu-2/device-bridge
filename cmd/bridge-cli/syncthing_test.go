package main

import (
	"strings"
	"testing"
)

func TestParseSyncOptions(t *testing.T) {
	opts, err := parseSyncOptions([]string{"--mode", "full", "--source", "/data"})
	if err != nil || opts.mode != "full" || !opts.modeSet || opts.source != "/data" || opts.filter != "" {
		t.Fatalf("full options: %+v %v", opts, err)
	}
	opts, err = parseSyncOptions([]string{"--filter", "working"})
	if err != nil || opts.filter != "working" || opts.modeSet {
		t.Fatalf("filter options: %+v %v", opts, err)
	}
	if _, err := parseSyncOptions([]string{"--mode"}); err == nil {
		t.Fatal("a flag without a value must fail")
	}
	if _, err := parseSyncOptions([]string{"--bogus", "x"}); err == nil {
		t.Fatal("unknown flags must fail")
	}
}

func TestSyncthingCommandGuards(t *testing.T) {
	if err := runSyncthing([]string{"register", "g"}, "", "", "", false); err == nil {
		t.Fatal("register needs group, peer and role")
	}
	err := runSyncthing([]string{"mode", "g"}, "", "", "", false)
	if err == nil || !strings.Contains(err.Error(), "--mode") {
		t.Fatalf("mode change must require --mode: %v", err)
	}
	if err := runSyncthing([]string{"build", "g"}, "", "", "", false); err == nil {
		t.Fatal("build needs a worktree")
	}
	if err := runSyncthing([]string{"build", "g", "/w", "--bogus"}, "", "", "", false); err == nil {
		t.Fatal("build only accepts --snapshot")
	}
}
