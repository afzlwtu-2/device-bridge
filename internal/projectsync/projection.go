package projectsync

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"

	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/protocol"

	"github.com/cespare/xxhash/v2"
	"golang.org/x/sys/unix"
)

type Projection struct {
	Git   GitState                 `json:"git"`
	Files []protocol.ManifestEntry `json:"files"`
	Bytes int64                    `json:"bytes"`
}

func (p Projection) Paths() []string {
	result := make([]string, 0, len(p.Files))
	for _, item := range p.Files {
		result = append(result, item.Path)
	}
	return result
}

func eligiblePaths(ctx context.Context, root string, approved []string) ([]string, error) {
	approved, err := files.ValidateExclusions(approved)
	if err != nil || len(approved) == 0 {
		return nil, errors.New("approve the specific paths that contain persistent project data")
	}
	tracked, submodules, err := trackedPaths(ctx, root)
	if err != nil {
		return nil, err
	}
	out := []string{}
	seen := map[string]bool{}
	anchor, err := os.OpenRoot(root)
	if err != nil {
		return nil, err
	}
	defer anchor.Close()
	for _, options := range [][]string{
		{"ls-files", "--others", "--exclude-standard", "-z"},
		{"ls-files", "--others", "--ignored", "--exclude-standard", "-z"},
	} {
		raw, err := git(ctx, root, options...)
		if err != nil {
			return nil, err
		}
		for _, name := range strings.Split(string(raw), "\x00") {
			if name == "" || strings.HasSuffix(name, "/") || seen[name] || tracked[name] || !files.Excluded(name, approved) ||
				files.Excluded(name, submodules) || excludedDataPath(name) {
				continue
			}
			if filesproviders.ValidPath(name) != nil {
				return nil, errors.New("an approved path cannot be represented safely")
			}
			nested, err := nestedGit(anchor, name)
			if err != nil {
				return nil, err
			}
			if nested {
				continue
			}
			info, err := anchor.Lstat(name)
			if err != nil {
				return nil, err
			}
			if !info.Mode().IsRegular() {
				return nil, errors.New("only regular files can enter a project projection")
			}
			if len(out) >= files.MaxManifestEntries {
				return nil, errors.New("too many approved project files")
			}
			seen[name] = true
			out = append(out, name)
		}
	}
	slices.Sort(out)
	return out, nil
}

func trackedPaths(ctx context.Context, root string) (map[string]bool, []string, error) {
	raw, err := git(ctx, root, "ls-files", "--stage", "-z")
	if err != nil {
		return nil, nil, err
	}
	tracked := map[string]bool{}
	var submodules []string
	for _, line := range strings.Split(string(raw), "\x00") {
		if line == "" {
			continue
		}
		meta, name, ok := strings.Cut(line, "\t")
		if !ok {
			return nil, nil, errors.New("invalid tracked Git inventory")
		}
		tracked[name] = true
		if strings.HasPrefix(meta, "160000 ") {
			submodules = append(submodules, name)
		}
	}
	return tracked, submodules, nil
}

func nestedGit(root *os.Root, name string) (bool, error) {
	for dir := path.Dir(name); dir != "."; dir = path.Dir(dir) {
		info, err := root.Lstat(dir)
		if err != nil {
			return false, err
		}
		if !info.IsDir() {
			return false, errors.New("an approved project path crosses an unsafe directory")
		}
		if _, err := root.Lstat(path.Join(dir, ".git")); err == nil {
			return true, nil
		} else if !errors.Is(err, fs.ErrNotExist) {
			return false, err
		}
	}
	return false, nil
}

func excludedDataPath(name string) bool {
	for _, part := range strings.Split(name, "/") {
		part = strings.ToLower(part)
		switch part {
		case ".git", ".ssh", ".gnupg", ".aws", ".kube", ".dart_tool", ".gradle",
			".cxx", "build", "deriveddata", "node_modules", ".cache", "gocache",
			".stfolder", ".stversions", ".stignore", "__pycache__", ".venv":
			return true
		}
		if part == ".env" || strings.HasPrefix(part, ".env.") || strings.HasSuffix(part, ".pem") ||
			strings.HasSuffix(part, ".key") || strings.HasSuffix(part, ".log") {
			return true
		}
	}
	return false
}

// Build publishes a new projection at an explicit, initially absent destination.
// It never links to or writes files inside the working tree.
func Build(ctx context.Context, worktree, destination string, approved []string) (Projection, error) {
	root, revision, err := Preflight(ctx, worktree)
	out := Projection{Git: revision, Files: []protocol.ManifestEntry{}}
	if err != nil {
		return out, err
	}
	names, err := eligiblePaths(ctx, root, approved)
	if err != nil {
		return out, err
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
		return out, errors.New("the projection destination must be outside the project worktree")
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
	stage, err := os.MkdirTemp(fmt.Sprintf("/proc/self/fd/%d", fd.Fd()), ".devicebridge-project-")
	if err != nil {
		return out, err
	}
	defer parent.RemoveAll(filepath.Base(stage))
	target, err := parent.OpenRoot(filepath.Base(stage))
	if err != nil {
		return out, err
	}
	defer target.Close()
	source, err := filesproviders.NewNative("project", root)
	if err != nil {
		return out, err
	}
	defer source.Close()
	for _, name := range names {
		entry, err := stageFile(ctx, source, target, name, files.MaxManifestBytes-out.Bytes)
		if err != nil {
			return out, err
		}
		out.Bytes += entry.Size
		out.Files = append(out.Files, entry)
	}
	_, final, err := Preflight(ctx, root)
	if err != nil || final != revision {
		return out, errors.Join(errors.New("Git state changed while staging the approved projection"), err)
	}
	if err := ctx.Err(); err != nil {
		return out, err
	}
	if err := unix.Renameat2(int(fd.Fd()), filepath.Base(stage), int(fd.Fd()), filepath.Base(dest), unix.RENAME_NOREPLACE); err != nil {
		return out, fmt.Errorf("publish a new projection without replacing an existing path: %w", err)
	}
	return out, fd.Sync()
}

func stageFile(ctx context.Context, source *filesproviders.Native, target *os.Root, name string, remaining int64) (protocol.ManifestEntry, error) {
	var result protocol.ManifestEntry
	before, err := source.Stat(ctx, name)
	if err != nil {
		return result, err
	}
	if before.Kind != "file" || before.Size < 0 || before.Size > remaining {
		return result, errors.New("approved project entry is not a supported file or exceeds the byte limit")
	}
	if dir := path.Dir(name); dir != "." {
		if err := target.MkdirAll(dir, 0700); err != nil {
			return result, err
		}
	}
	input, err := source.OpenRead(ctx, name)
	if err != nil {
		return result, err
	}
	defer input.Close()
	output, err := target.OpenFile(name, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return result, err
	}
	defer output.Close()
	sourceHash := xxhash.New()
	n, err := io.Copy(io.MultiWriter(output, sourceHash), io.LimitReader(contextReader{ctx, input}, before.Size+1))
	if err != nil {
		return result, err
	}
	after, err := source.Stat(ctx, name)
	if err != nil || n != before.Size || after != before {
		return result, errors.Join(errors.New("a project file changed while staging"), err)
	}
	if err := output.Sync(); err != nil {
		return result, err
	}
	if _, err := output.Seek(0, io.SeekStart); err != nil {
		return result, err
	}
	targetHash := xxhash.New()
	if _, err := io.Copy(targetHash, contextReader{ctx, output}); err != nil {
		return result, err
	}
	if targetHash.Sum64() != sourceHash.Sum64() {
		return result, errors.New("projection read-back XXH64 mismatch")
	}
	return protocol.ManifestEntry{Path: name, Size: n, XXH64: hex.EncodeToString(targetHash.Sum(nil))}, nil
}

type contextReader struct {
	ctx   context.Context
	input io.Reader
}

func (r contextReader) Read(buffer []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.input.Read(buffer)
}
