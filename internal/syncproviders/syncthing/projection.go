package syncthing

import (
	"context"
	"errors"
	"os"
	"path/filepath"

	"devicebridge/internal/syncproviders"

	"golang.org/x/sys/unix"
)

type StagedProjection struct {
	syncproviders.Digest
	Snapshot string `json:"snapshot,omitempty"`
}

// ReplaceProjection serializes staging with the sync daemon. An optional
// snapshot retains the previous directory after the atomic exchange.
func (p Profile) ReplaceProjection(ctx context.Context, group string, snapshot bool, build func(string) error) (StagedProjection, error) {
	var result StagedProjection
	lock, err := p.lock()
	if err != nil {
		return result, err
	}
	defer lock.Close()
	entry, err := p.Registration(group)
	if err != nil {
		return result, err
	}
	if entry.Mode == ModeFull {
		return result, errors.New("full folder sync has no managed projection")
	}
	old, err := projectionDigest(ctx, entry.Path, false, entry.Excludes)
	if err != nil {
		return result, err
	}
	parent := filepath.Dir(entry.Path)
	root, err := os.OpenRoot(parent)
	if err != nil {
		return result, err
	}
	defer root.Close()
	fd, err := root.Open(".")
	if err != nil {
		return result, err
	}
	defer fd.Close()
	stage, err := os.MkdirTemp(parent, ".snapshot-"+group+"-")
	if err != nil {
		return result, err
	}
	base := filepath.Base(stage)
	defer func() {
		if result.Snapshot == "" {
			_ = root.RemoveAll(base)
		}
	}()
	projection := filepath.Join(stage, "projection")
	if err := build(projection); err != nil {
		return result, err
	}
	result.Digest, err = projectionDigest(ctx, projection, false, entry.Excludes)
	if err != nil {
		return result, err
	}
	if result.Digest == old {
		return result, nil
	}
	stageName := filepath.Join(base, "projection")
	handle := int(fd.Fd())
	if err := unix.Renameat2(handle, stageName, handle, group, unix.RENAME_EXCHANGE); err != nil {
		return result, err
	}
	if snapshot && old.Items > 0 {
		result.Snapshot = projection
	}
	return result, fd.Sync()
}
