package synccontrol

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func (m *Manager) ownerStopped(id string) error {
	_, err := os.Lstat(filepath.Join(m.state, "sync-control-v1", "stop", id))
	if err == nil {
		return errors.New("sync stopped by this device's owner")
	}
	if !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (m *Manager) requestOwnerStop(id string) (bool, error) {
	if _, err := m.jobPath(id); err != nil {
		return false, err
	}
	dir := filepath.Join(m.state, "sync-control-v1", "stop")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return false, err
	}
	file, err := os.OpenFile(filepath.Join(dir, id), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if os.IsExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, file.Close()
}

// Local owners can stop their own device's jobs without inheriting or changing
// any remote controller's continuing permission. No peer-facing operation
// exposes this method; the private state directory supplies local ownership.
func (m *Manager) StopOwnedJobs(group string) (int, error) {
	if group != "" && !identifier.MatchString(group) {
		return 0, errors.New("invalid sync group")
	}
	entries, err := os.ReadDir(filepath.Join(m.state, "sync-control-v1", "jobs"))
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	count := 0
	for _, entry := range entries {
		id, ok := strings.CutSuffix(entry.Name(), ".json")
		if !ok {
			continue
		}
		job, err := m.readJob(id)
		if err != nil || job.State != "running" || (group != "" && job.Group != group) {
			continue
		}
		added, err := m.requestOwnerStop(id)
		if err != nil {
			return count, err
		}
		if added {
			count++
		}
	}
	return count, nil
}

func (m *Manager) watchApproval(ctx context.Context, cancel context.CancelFunc, controller, root, id string, remote bool) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			if m.ownerStopped(id) != nil || m.allowed(controller, root, remote) != nil {
				cancel()
				return
			}
		}
	}
}
