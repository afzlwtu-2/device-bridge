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
	XXH64   string `json:"xxh64"`
	Skipped int    `json:"skipped"`
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

func WriteTermuxBackup(state string, output io.Writer) (report TermuxBackupReport, err error) {
	digest := xxhash.New()
	report.Skipped, err = writeTermuxBackup(state, io.MultiWriter(output, digest))
	if err == nil {
		report.XXH64 = fmt.Sprintf("%016x", digest.Sum64())
	}
	return report, err
}

func writeTermuxBackup(state string, output io.Writer) (skipped int, err error) {
	home := termuxBackupHome(state)
	guard, err := lockTermuxBackup(filepath.Dir(home))
	if os.IsNotExist(err) {
		return 0, errors.New("open Termux once before backing up its Home")
	}
	if err != nil {
		return 0, err
	}
	defer guard.Close()
	root, err := os.OpenRoot(home)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, errors.New("open Termux once before backing up its Home")
		}
		return 0, err
	}
	defer root.Close()
	packages, err := termuxInstalledPackages(filepath.Join(filepath.Dir(home), "usr", "var", "lib", "dpkg", "status"))
	if err != nil {
		return 0, err
	}
	manifest, err := json.Marshal(TermuxBackupInfo{Version: 1, Home: home, Packages: packages})
	if err != nil {
		return 0, err
	}
	compressed, err := gzip.NewWriterLevel(output, gzip.BestSpeed)
	if err != nil {
		return 0, err
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
		return 0, err
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
	err = fs.WalkDir(root.FS(), ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			if err := skipEntry(path, err); err != nil {
				return err
			}
			if entry != nil && entry.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return skipEntry(path, err)
		}
		var link string
		switch {
		case info.IsDir(), info.Mode().IsRegular():
		case info.Mode()&os.ModeSymlink != 0:
			link, err = root.Readlink(path)
			if err != nil {
				return skipEntry(path, err)
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
		return err
	})
	if err != nil {
		return skipped, err
	}
	if err := writeRecord("content.xxh64", []byte(fmt.Sprintf("%016x", digest.Sum64()))); err != nil {
		return skipped, err
	}
	if err := archive.Close(); err != nil {
		return skipped, err
	}
	return skipped, compressed.Close()
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
