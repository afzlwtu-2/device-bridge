package projectsync

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"

	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/protocol"

	"golang.org/x/sys/unix"
)

// BuildWorking stages every regular working file except Git metadata at any
// depth. It deliberately does not require a clean worktree: tracked,
// uncommitted, untracked and hidden content is included by explicit user
// choice. Symlinks and special files block the projection, and the verified
// copy/read-back rules match the untracked projection.
func BuildWorking(ctx context.Context, worktree, destination string) (Projection, error) {
	out := Projection{Files: []protocol.ManifestEntry{}}
	root, err := filepath.EvalSymlinks(worktree)
	if err != nil {
		return out, errors.New("the working folder must exist")
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return out, err
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() {
		return out, errors.New("the working source must be a directory")
	}
	// Best-effort Git evidence only; the working filter never gates on it.
	if branch, e := git(ctx, root, "symbolic-ref", "--quiet", "--short", "HEAD"); e == nil {
		out.Git.Branch = strings.TrimSuffix(string(branch), "\n")
	}
	if head, e := git(ctx, root, "rev-parse", "--verify", "HEAD^{commit}"); e == nil {
		out.Git.Head = strings.TrimSuffix(string(head), "\n")
	}
	dest, err := filepath.Abs(destination)
	if err != nil {
		return out, err
	}
	parentPath, err := filepath.EvalSymlinks(filepath.Dir(dest))
	if err != nil {
		return out, err
	}
	inside, err := filepath.Rel(root, filepath.Join(parentPath, filepath.Base(dest)))
	if err != nil || (inside != ".." && !strings.HasPrefix(inside, "../")) {
		return out, errors.New("the projection destination must be outside the working folder")
	}
	parent, err := os.OpenRoot(parentPath)
	if err != nil {
		return out, err
	}
	defer parent.Close()
	fd, err := parent.Open(".")
	if err != nil {
		return out, err
	}
	defer fd.Close()
	stage, err := os.MkdirTemp(fmt.Sprintf("/proc/self/fd/%d", fd.Fd()), ".devicebridge-working-")
	if err != nil {
		return out, err
	}
	defer parent.RemoveAll(filepath.Base(stage))
	target, err := parent.OpenRoot(filepath.Base(stage))
	if err != nil {
		return out, err
	}
	defer target.Close()
	source, err := filesproviders.NewNative("project-working", worktree)
	if err != nil {
		return out, err
	}
	defer source.Close()
	var walk func(rel string) error
	walk = func(rel string) error {
		token := ""
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			page, err := source.List(ctx, rel, token, 200)
			if err != nil {
				return err
			}
			for _, child := range page.Entries {
				switch child.Name {
				case ".git", ".stfolder", ".stversions", ".stignore":
					continue
				}
				if workingControl(child.Name) {
					continue
				}
				name := path.Join(rel, child.Name)
				switch child.Kind {
				case "directory":
					if err := target.MkdirAll(name, 0700); err != nil {
						return err
					}
					if err := walk(name); err != nil {
						return err
					}
				case "file":
					if len(out.Files) >= files.MaxManifestEntries {
						return errors.New("too many working files")
					}
					entry, err := stageFile(ctx, source, target, name, files.MaxManifestBytes-out.Bytes)
					if err != nil {
						return err
					}
					out.Bytes += entry.Size
					out.Files = append(out.Files, entry)
				default:
					return errors.New("the working folder contains a symlink or special file; projection blocked")
				}
			}
			if page.Next == "" {
				return nil
			}
			token = page.Next
		}
	}
	if err := walk("."); err != nil {
		return out, err
	}
	if err := ctx.Err(); err != nil {
		return out, err
	}
	if err := unix.Renameat2(int(fd.Fd()), filepath.Base(stage), int(fd.Fd()), filepath.Base(dest), unix.RENAME_NOREPLACE); err != nil {
		return out, fmt.Errorf("publish a new projection without replacing an existing path: %w", err)
	}
	return out, fd.Sync()
}
