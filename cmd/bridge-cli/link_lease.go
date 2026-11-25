package main

import (
	"context"
	"devicebridge/internal/linkctl"
	"devicebridge/internal/storage"
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// A desktop rollback watcher is independent of the GUI and network uplink.
func startLocalLinkLease(ctx context.Context, s *storage.Store, state, id string, seconds int) error {
	if id == "" {
		return nil
	}
	if _, err := s.ChangeLinkLease(ctx, "local", id, "begin", seconds); err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	child := exec.Command(executable, "--state", state, "link-lease-watch", id)
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = child.Start(); err != nil {
		_, _ = s.ChangeLinkLease(ctx, "local", id, "needs_recovery", 0)
		return err
	}
	return child.Process.Release()
}
func watchLocalLinkLease(ctx context.Context, s *storage.Store, state, id string) error {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		lease, err := s.LinkLease(ctx)
		if err != nil {
			return err
		}
		if lease.ID != id || lease.Peer != "local" || lease.Stage != "preparing" {
			return nil
		}
		if lease.Deadline <= time.Now().Unix() {
			claimed, err := s.ChangeLinkLease(ctx, "", "", "claim-expired", 0)
			if err != nil {
				return nil
			}
			restore, stop := context.WithTimeout(ctx, 20*time.Second)
			defer stop()
			result, err := linkctl.Restore(restore, state)
			stage := "needs_recovery"
			if err == nil && result.OK {
				stage = "restored"
			}
			_, saveErr := s.ChangeLinkLease(restore, claimed.Peer, claimed.ID, stage, 0)
			if err != nil {
				return err
			}
			return saveErr
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}
func commitLocalLink(ctx context.Context, s *storage.Store, id string) error {
	lease, err := s.LinkLease(ctx)
	if err != nil {
		return err
	}
	if lease.Peer != "local" {
		return errors.New("local link operation not owned by this GUI")
	}
	_, err = s.ChangeLinkLease(ctx, "local", id, "commit", 0)
	return err
}
