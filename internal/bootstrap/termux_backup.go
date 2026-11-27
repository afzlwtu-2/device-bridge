package bootstrap

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"devicebridge/internal/platform"
	"github.com/cespare/xxhash/v2"
	"golang.org/x/sys/unix"
)

type TermuxBackupInfo struct {
	Version  int      `json:"version"`
	Home     string   `json:"source_home"`
	Packages []string `json:"packages"`
	Previous string   `json:"previous_home,omitempty"`
}

type TermuxBackupReport struct {
	XXH64    string `json:"xxh64"`
	Skipped  int    `json:"skipped"`
	BackedUp int    `json:"backed_up,omitempty"`
	Excluded int    `json:"excluded,omitempty"`
}

// DefaultTermuxBackupExcludes holds heavyweight cache and generated folder names
// skipped inside Termux Home unless explicitly overridden.
var DefaultTermuxBackupExcludes = []string{
	".cache",
	"node_modules",
	".node_modules",
	".npm",
	".pnpm-store",
	".pnpm",
	".yarn/cache",
	".yarn/unplugged",
	".yarn/install-state.gz",
	".next",
	".nuxt",
	".output",
	".vite",
	".turbo",
	".parcel-cache",
	"coverage",
	".cargo/registry",
	".cargo/git",
	"target",
	"go/pkg/mod",
	"go-build",
	"gocache",
	"__pycache__",
	"*.pyc",
	"*.pyo",
	"*.egg-info",
	".pytest_cache",
	".mypy_cache",
	".ruff_cache",
	".tox",
	".nox",
	".venv",
	"venv",
	"build",
	"dist",
	".gradle",
	".cxx",
	".dart_tool",
	".flutter-plugins",
	".flutter-plugins-dependencies",
	".Trash",
}

// TermuxBackupOptions controls which relative paths under Termux Home are archived
// and which folder/file patterns are excluded. Top-level and walked .env* files
// are always preserved regardless of exclude rules.
type TermuxBackupOptions struct {
	IncludePaths    []string  `json:"include_paths"`
	ExcludePatterns *[]string `json:"exclude_patterns,omitempty"`
}

// TermuxBackupEntry describes an item inside Termux Home for selection UIs.
type TermuxBackupEntry struct {
	Path              string `json:"path"`
	Name              string `json:"name"`
	IsDir             bool   `json:"is_dir"`
	SizeBytes         int64  `json:"size_bytes"`
	ExcludedByDefault bool   `json:"excluded_by_default"`
	AlwaysIncluded    bool   `json:"always_included"`
}

var termuxPackageName = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]+$`)

func termuxBackupHome(state string) string {
	return filepath.Join(filepath.Dir(filepath.Clean(state)), "terminal", "files", "home")
}

func lockTermuxBackup(parent string) (*os.File, error) {
	dir, err := os.Open(parent)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(dir.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		dir.Close()
		return nil, errors.New("another Termux backup operation is active")
	}
	return dir, nil
}

func termuxInstalledPackages(path string) ([]string, error) {
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	packages := make(map[string]bool)
	var name string
	var installed bool
	finish := func() {
		if installed && termuxPackageName.MatchString(name) {
			packages[name] = true
		}
		name, installed = "", false
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 8192), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		key, value, _ := strings.Cut(line, ":")
		switch key {
		case "":
			finish()
		case "Package":
			name = strings.TrimSpace(value)
		case "Status":
			fields := strings.Fields(value)
			installed = len(fields) == 3 && fields[1] == "ok" && fields[2] == "installed"
		}
	}
	finish()
	names := make([]string, 0, len(packages))
	for name := range packages {
		names = append(names, name)
	}
	sort.Strings(names)
	return names, scanner.Err()
}

func isTermuxEnvFile(name string) bool {
	return name == ".env" || strings.HasPrefix(name, ".env.")
}

func effectiveTermuxExcludes(opts TermuxBackupOptions) []string {
	raw := DefaultTermuxBackupExcludes
	if opts.ExcludePatterns != nil {
		raw = *opts.ExcludePatterns
	}
	out := make([]string, 0, len(raw))
	seen := make(map[string]bool, len(raw))
	for _, pat := range raw {
		pat = strings.TrimSpace(pat)
		pat = strings.Trim(filepath.ToSlash(pat), "/")
		if pat == "" || seen[pat] {
			continue
		}
		seen[pat] = true
		out = append(out, pat)
	}
	return out
}

func matchesTermuxExclude(relPath string, excludes []string) bool {
	if relPath == "." || relPath == "" {
		return false
	}
	rel := filepath.ToSlash(strings.Trim(relPath, "/"))
	base := filepath.Base(rel)
	for _, pat := range excludes {
		if strings.Contains(pat, "/") {
			for suffix := rel; suffix != ""; {
				if matched, _ := filepath.Match(pat, suffix); matched || strings.HasPrefix(suffix, pat+"/") {
					return true
				}
				_, suffix, _ = strings.Cut(suffix, "/")
			}
		} else {
			if base == pat || rel == pat {
				return true
			}
			if matched, _ := filepath.Match(pat, base); matched {
				return true
			}
		}
	}
	return false
}

func estimateTermuxEntrySize(fsys fs.FS, rel string, isDir bool) int64 {
	if !isDir {
		info, err := fs.Stat(fsys, rel)
		if err != nil {
			return 0
		}
		return info.Size()
	}
	var total int64
	visited := 0
	const maxEntries = 2000
	_ = fs.WalkDir(fsys, rel, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		visited++
		if visited > maxEntries {
			return fs.SkipAll
		}
		if p != rel && matchesTermuxExclude(p, DefaultTermuxBackupExcludes) &&
			(d.IsDir() || !isTermuxEnvFile(d.Name())) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		if info, err := d.Info(); err == nil && info.Mode().IsRegular() {
			total += info.Size()
		}
		return nil
	})
	return total
}

// ListTermuxBackupEntries returns the immediate entries inside Termux Home (or a valid
// relative subpath) with size estimates, default-exclude flags, and always-included .env* markers.
func ListTermuxBackupEntries(state string, subpath string) ([]TermuxBackupEntry, error) {
	home := termuxBackupHome(state)
	root, err := os.OpenRoot(home)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errors.New("open Termux once before backing up its Home")
		}
		return nil, err
	}
	defer root.Close()
	rel := "."
	if clean := strings.Trim(filepath.ToSlash(strings.TrimSpace(subpath)), "/"); clean != "" && clean != "." {
		if !fs.ValidPath(clean) {
			return nil, fmt.Errorf("invalid subpath: %q", subpath)
		}
		rel = clean
	}
	entries, err := fs.ReadDir(root.FS(), rel)
	if err != nil {
		return nil, err
	}
	out := make([]TermuxBackupEntry, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		childRel := name
		if rel != "." {
			childRel = rel + "/" + name
		}
		isDir := entry.IsDir()
		always := !isDir && isTermuxEnvFile(name)
		excl := !always && matchesTermuxExclude(childRel, DefaultTermuxBackupExcludes)
		var size int64
		if !excl {
			size = estimateTermuxEntrySize(root.FS(), childRel, isDir)
		}
		out = append(out, TermuxBackupEntry{
			Path:              childRel,
			Name:              name,
			IsDir:             isDir,
			SizeBytes:         size,
			ExcludedByDefault: excl,
			AlwaysIncluded:    always,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IsDir != out[j].IsDir {
			return out[i].IsDir
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

func WriteTermuxBackup(state string, output io.Writer) (report TermuxBackupReport, err error) {
	return WriteTermuxBackupWithOptions(state, output, TermuxBackupOptions{})
}

func WriteTermuxBackupWithOptions(state string, output io.Writer, opts TermuxBackupOptions) (report TermuxBackupReport, err error) {
	digest := xxhash.New()
	report.Skipped, report.BackedUp, report.Excluded, err = writeTermuxBackup(state, io.MultiWriter(output, digest), opts)
	if err == nil {
		report.XXH64 = fmt.Sprintf("%016x", digest.Sum64())
	}
	return report, err
}

func writeTermuxBackup(state string, output io.Writer, opts TermuxBackupOptions) (skipped int, backedUp int, excluded int, err error) {
	home := termuxBackupHome(state)
	guard, err := lockTermuxBackup(filepath.Dir(home))
	if os.IsNotExist(err) {
		return 0, 0, 0, errors.New("open Termux once before backing up its Home")
	}
	if err != nil {
		return 0, 0, 0, err
	}
	defer guard.Close()
	root, err := os.OpenRoot(home)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, 0, 0, errors.New("open Termux once before backing up its Home")
		}
		return 0, 0, 0, err
	}
	defer root.Close()
	packages, err := termuxInstalledPackages(filepath.Join(filepath.Dir(home), "usr", "var", "lib", "dpkg", "status"))
	if err != nil {
		return 0, 0, 0, err
	}
	manifest, err := json.Marshal(TermuxBackupInfo{Version: 1, Home: home, Packages: packages})
	if err != nil {
		return 0, 0, 0, err
	}
	compressed, err := gzip.NewWriterLevel(output, gzip.BestSpeed)
	if err != nil {
		return 0, 0, 0, err
	}
	archive := tar.NewWriter(compressed)
	writeRecord := func(name string, data []byte) error {
		if err := archive.WriteHeader(&tar.Header{Name: name, Mode: 0600, Size: int64(len(data))}); err != nil {
			return err
		}
		_, err := archive.Write(data)
		return err
	}
	if err := writeRecord("manifest.json", manifest); err != nil {
		return 0, 0, 0, err
	}
	digest := xxhash.New()
	buffer := make([]byte, 128*1024)
	fileOutput := io.MultiWriter(archive, digest)
	skipEntry := func(path string, err error) error {
		if path != "." && (errors.Is(err, fs.ErrPermission) || errors.Is(err, fs.ErrNotExist)) {
			skipped++
			return nil
		}
		return err
	}

	excludes := effectiveTermuxExcludes(opts)
	emitted := make(map[string]bool)
	emitEntry := func(path string, info fs.FileInfo) error {
		if emitted[path] {
			return nil
		}
		var link string
		switch {
		case info.IsDir(), info.Mode().IsRegular():
		case info.Mode()&os.ModeSymlink != 0:
			var linkErr error
			link, linkErr = root.Readlink(path)
			if linkErr != nil {
				return skipEntry(path, linkErr)
			}
		default:
			return nil // Live sockets, pipes and device nodes have no persistent contents.
		}
		header, err := tar.FileInfoHeader(info, link)
		if err != nil {
			return err
		}
		header.Name = "home/" + path
		if path == "." {
			header.Name = "home/"
		}
		emitted[path] = true
		if !info.Mode().IsRegular() {
			return archive.WriteHeader(header)
		}
		// Check that the file is readable before committing its header to the
		// stream. O_NONBLOCK also handles a file replaced by a FIFO mid-walk.
		file, err := root.OpenFile(path, os.O_RDONLY|unix.O_NONBLOCK, 0)
		if err != nil {
			return skipEntry(path, err)
		}
		defer file.Close()
		current, err := file.Stat()
		if err != nil {
			return err
		}
		if !os.SameFile(current, info) {
			return fmt.Errorf("file changed during backup: %s", path)
		}
		header.Size = current.Size()
		if err := archive.WriteHeader(header); err != nil {
			return err
		}
		// Read the initial extent. Appends by live log writers do not make
		// the archive invalid. A shortened source still fails the backup.
		size, err := io.CopyBuffer(fileOutput, io.LimitReader(file, header.Size), buffer)
		if err == nil && size != header.Size {
			return fmt.Errorf("file changed during backup: %s", path)
		}
		if err == nil {
			backedUp++
		}
		return err
	}

	var walkRoots []string
	if opts.IncludePaths == nil {
		walkRoots = []string{"."}
	} else {
		seenRoots := make(map[string]bool)
		addRoot := func(raw string) error {
			clean := strings.Trim(filepath.ToSlash(strings.TrimSpace(raw)), "/")
			if clean == "" {
				clean = "."
			}
			if !fs.ValidPath(clean) {
				return fmt.Errorf("invalid backup path: %q", raw)
			}
			if !seenRoots[clean] {
				seenRoots[clean] = true
				walkRoots = append(walkRoots, clean)
			}
			return nil
		}
		for _, p := range opts.IncludePaths {
			if err := addRoot(p); err != nil {
				return 0, 0, 0, err
			}
		}
		// Always preserve top-level .env* files in Termux Home even on selective folder backups.
		topEntries, err := fs.ReadDir(root.FS(), ".")
		if err != nil {
			return 0, 0, 0, err
		}
		for _, te := range topEntries {
			if !te.IsDir() && isTermuxEnvFile(te.Name()) {
				_ = addRoot(te.Name())
			}
		}
	}

	homeInfo, err := root.Stat(".")
	if err != nil {
		return 0, 0, 0, err
	}
	if err := emitEntry(".", homeInfo); err != nil {
		return 0, 0, 0, err
	}
	ensureAncestors := func(rel string) error {
		if rel == "." {
			return nil
		}
		parts := strings.Split(rel, "/")
		curr := ""
		for i := 0; i < len(parts)-1; i++ {
			if curr == "" {
				curr = parts[i]
			} else {
				curr += "/" + parts[i]
			}
			st, err := root.Lstat(curr)
			if err != nil {
				return err
			}
			if !st.IsDir() {
				return fmt.Errorf("backup selection traverses a non-directory: %s", curr)
			}
			if err := emitEntry(curr, st); err != nil {
				return err
			}
		}
		return nil
	}

	for _, walkRoot := range walkRoots {
		if walkRoot != "." {
			info, statErr := root.Lstat(walkRoot)
			if statErr != nil {
				if err := skipEntry(walkRoot, statErr); err != nil {
					return 0, 0, 0, err
				}
				continue
			}
			excludedPath := false
			for cursor := walkRoot; cursor != "."; cursor = filepath.Dir(cursor) {
				if cursor == walkRoot && !info.IsDir() && isTermuxEnvFile(info.Name()) {
					continue
				}
				if matchesTermuxExclude(cursor, excludes) {
					excluded++
					excludedPath = true
					break
				}
			}
			if excludedPath {
				continue
			}
			if !info.IsDir() {
				if err := ensureAncestors(walkRoot); err != nil {
					return 0, 0, 0, err
				}
				if err := emitEntry(walkRoot, info); err != nil {
					return 0, 0, 0, err
				}
				continue
			}
		}
		if err := ensureAncestors(walkRoot); err != nil {
			return 0, 0, 0, err
		}
		err = fs.WalkDir(root.FS(), walkRoot, func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				if err := skipEntry(path, walkErr); err != nil {
					return err
				}
				if entry != nil && entry.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			base := entry.Name()
			isDir := entry.IsDir()
			if !isDir && isTermuxEnvFile(base) {
				info, err := entry.Info()
				if err != nil {
					return skipEntry(path, err)
				}
				return emitEntry(path, info)
			}
			if path != "." && matchesTermuxExclude(path, excludes) {
				excluded++
				if isDir {
					return fs.SkipDir
				}
				return nil
			}
			info, err := entry.Info()
			if err != nil {
				return skipEntry(path, err)
			}
			return emitEntry(path, info)
		})
		if err != nil {
			return 0, 0, 0, err
		}
	}
	if err := writeRecord("content.xxh64", []byte(fmt.Sprintf("%016x", digest.Sum64()))); err != nil {
		return skipped, backedUp, excluded, err
	}
	if err := archive.Close(); err != nil {
		return skipped, backedUp, excluded, err
	}
	return skipped, backedUp, excluded, compressed.Close()
}

func RestoreTermuxBackup(state string, input io.Reader) (TermuxBackupInfo, error) {
	var backup TermuxBackupInfo
	home := termuxBackupHome(state)
	parent := filepath.Dir(home)
	if err := os.MkdirAll(parent, 0700); err != nil {
		return backup, err
	}
	guard, err := lockTermuxBackup(parent)
	if err != nil {
		return backup, err
	}
	defer guard.Close()
	homeGuard, err := platform.LockTermuxHome(home, true)
	if err != nil {
		return backup, err
	}
	defer homeGuard.Close()
	compressed, err := gzip.NewReader(input)
	if err != nil {
		return backup, err
	}
	defer compressed.Close()
	archive := tar.NewReader(compressed)
	header, err := archive.Next()
	if err != nil || header.Name != "manifest.json" || header.Typeflag != tar.TypeReg || header.Size > 128*1024 {
		return backup, errors.New("invalid Termux backup manifest")
	}
	if err := json.NewDecoder(archive).Decode(&backup); err != nil || backup.Version != 1 ||
		!filepath.IsAbs(backup.Home) || filepath.Base(backup.Home) != "home" {
		return backup, errors.New("unsupported Termux backup manifest")
	}
	backup.Previous = ""
	if backup.Packages == nil {
		backup.Packages = []string{}
	}
	for _, pkg := range backup.Packages {
		if !termuxPackageName.MatchString(pkg) {
			return backup, errors.New("invalid package name in Termux backup")
		}
	}

	stage, err := os.MkdirTemp(parent, "home-before-restore-")
	if err != nil {
		return backup, err
	}
	published := false
	defer func() {
		if !published {
			_ = os.RemoveAll(stage)
		}
	}()
	root, err := os.OpenRoot(stage)
	if err != nil {
		return backup, err
	}
	defer root.Close()

	type dirMetadata struct {
		name string
		mode fs.FileMode
		time time.Time
	}
	var dirs []dirMetadata
	type symlink struct{ name, target string }
	var links []symlink
	digest := xxhash.New()
	buffer := make([]byte, 128*1024)
	checksum := ""
	seen := make(map[string]bool)
	for {
		header, err = archive.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return backup, err
		}
		if checksum != "" {
			return backup, errors.New("data after the Termux backup checksum")
		}
		if header.Name == "content.xxh64" && header.Typeflag == tar.TypeReg && header.Size == 16 {
			raw, err := io.ReadAll(archive)
			if err != nil {
				return backup, err
			}
			checksum = string(raw)
			continue
		}
		name, ok := strings.CutPrefix(header.Name, "home/")
		name = strings.TrimSuffix(name, "/")
		if header.Name == "home/" && header.Typeflag == tar.TypeDir {
			name = "."
		}
		if !ok || !fs.ValidPath(name) || (name == "." && header.Name != "home/") {
			return backup, fmt.Errorf("unsafe path in Termux backup: %q", header.Name)
		}
		if seen[name] {
			return backup, fmt.Errorf("duplicate path in Termux backup: %q", name)
		}
		seen[name] = true
		mode := header.FileInfo().Mode().Perm()
		if err := root.MkdirAll(filepath.Dir(name), 0700); err != nil {
			return backup, err
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := root.MkdirAll(name, 0700); err != nil {
				return backup, err
			}
			dirs = append(dirs, dirMetadata{name, mode, header.ModTime})
		case tar.TypeReg:
			file, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
			if err != nil {
				return backup, err
			}
			_, copyErr := io.CopyBuffer(file, archive, buffer)
			if copyErr == nil {
				_, copyErr = file.Seek(0, io.SeekStart)
			}
			if copyErr == nil {
				_, copyErr = io.CopyBuffer(digest, file, buffer)
			}
			if err := errors.Join(copyErr, file.Chmod(mode), file.Close()); err != nil {
				return backup, err
			}
			if err := root.Chtimes(name, header.ModTime, header.ModTime); err != nil {
				return backup, err
			}
		case tar.TypeSymlink:
			target := header.Linkname
			oldRoot := filepath.Dir(backup.Home)
			if target == oldRoot || strings.HasPrefix(target, oldRoot+"/") {
				target = parent + strings.TrimPrefix(target, oldRoot)
			}
			links = append(links, symlink{name, target})
		default:
			return backup, fmt.Errorf("unsupported entry in Termux backup: %q", name)
		}
	}
	if checksum != fmt.Sprintf("%016x", digest.Sum64()) || len(dirs) == 0 || dirs[0].name != "." {
		return backup, errors.New("incomplete or corrupted Termux backup")
	}
	if n, err := io.Copy(io.Discard, compressed); n != 0 || err != nil {
		return backup, errors.New("invalid Termux backup trailer")
	}
	for _, link := range links {
		if err := root.Symlink(link.target, link.name); err != nil {
			return backup, err
		}
	}
	for i := len(dirs) - 1; i >= 0; i-- {
		dir := dirs[i]
		if err := root.Chtimes(dir.name, dir.time, dir.time); err != nil {
			return backup, err
		}
		// Android's app sandbox can trap fchmodat2, which Root.Chmod uses
		// with AT_SYMLINK_NOFOLLOW. Open the scoped directory and use fchmod.
		file, err := root.OpenFile(dir.name, os.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
		if err != nil {
			return backup, err
		}
		if err := errors.Join(file.Chmod(dir.mode), file.Close()); err != nil {
			return backup, err
		}
	}

	err = unix.Renameat2(unix.AT_FDCWD, stage, unix.AT_FDCWD, home, unix.RENAME_NOREPLACE)
	if errors.Is(err, fs.ErrExist) {
		current, statErr := os.Lstat(home)
		if statErr != nil {
			return backup, statErr
		}
		if !current.IsDir() {
			return backup, errors.New("existing Termux Home is not a directory")
		}
		err = unix.Renameat2(unix.AT_FDCWD, stage, unix.AT_FDCWD, home, unix.RENAME_EXCHANGE)
		if err == nil {
			backup.Previous = filepath.Base(stage)
		}
	}
	published = err == nil
	return backup, err
}
