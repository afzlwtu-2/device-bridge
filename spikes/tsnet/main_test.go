package main

import (
	"context"
	"testing"
)

func TestConfigPersistenceAndDeferredLifecycle(t *testing.T) {
	tmp := t.TempDir()
	b := &broker{
		stateDir:            tmp,
		socksEnabled:        true,
		socksPort:           1055,
		exitNodeID:          "node-exit-1",
		tailscaleSSHEnabled: true,
	}
	b.mu.Lock()
	b.saveConfigLocked()
	b.mu.Unlock()

	reloaded := &broker{stateDir: tmp, socksPort: 1055, tailscaleSSHEnabled: true}
	reloaded.loadSavedConfig()
	if !reloaded.socksEnabled || reloaded.socksPort != 1055 || reloaded.exitNodeID != "node-exit-1" || !reloaded.tailscaleSSHEnabled || reloaded.openSSHEnabled {
		t.Fatalf("unexpected reloaded config: %+v", reloaded)
	}
	reloaded.mu.Lock()
	reloaded.tailscaleSSHEnabled = false
	reloaded.openSSHEnabled = true
	reloaded.saveConfigLocked()
	reloaded.mu.Unlock()

	reloaded2 := &broker{stateDir: tmp, socksPort: 1055, tailscaleSSHEnabled: true}
	reloaded2.loadSavedConfig()
	if reloaded2.tailscaleSSHEnabled || !reloaded2.openSSHEnabled {
		t.Fatalf("expected reloaded tailscaleSSH=false and openSSH=true, got %+v", reloaded2)
	}
	if err := b.applyExitNode(context.Background(), "node-exit-1"); err != nil {
		t.Fatalf("expected applyExitNode to no-op cleanly while logged out / uninitialized, got: %v", err)
	}
	if err := b.applyRunSSH(context.Background(), true); err != nil {
		t.Fatalf("expected applyRunSSH to no-op cleanly while uninitialized, got: %v", err)
	}
}
