package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/transfer"
	"golang.org/x/sys/unix"
)

type localFileRef struct {
	Root string `json:"kind"`
	Path string `json:"path"`
}

type trashEntryMeta struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Kind         string `json:"kind"`
	Size         int64  `json:"size"`
	DeletedAt    int64  `json:"deleted_at"`
	OriginalKind string `json:"original_kind"`
	OriginalPath string `json:"original_path"`
	StoragePath  string `json:"storage_path"`
}

func localFiles(ctx context.Context, state string, args []string) error {
	if len(args) != 2 {
		return errors.New("invalid local Files operation")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	roots := map[string]string{"home": home, "filesystem": "/", "downloads": filepath.Join(state, "downloads")}
	if args[1] == "roots" {
		available := make([]map[string]any, 0, len(roots)+1)
		for _, root := range []struct{ id, name string }{
			{"home", "Home"}, {"downloads", "DeviceBridge Downloads"}, {"filesystem", "Filesystem"},
		} {
			path := roots[root.id]
			available = append(available, map[string]any{"id": root.id, "name": root.name, "native_path": path, "available": true})
		}
		available = append(available, map[string]any{"id": "recycle_bin", "name": "Recycle Bin", "available": true})
		return output(available)
	}
	var request struct {
		localFileRef
		ID, Name, Next string
		Source, Target localFileRef
		Excludes       []string
		Move           bool
	}
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, (16<<10)+1))
	if err != nil || len(raw) > 16<<10 || json.Unmarshal(raw, &request) != nil {
		return errors.New("invalid local Files request")
	}
	if args[1] == "empty-trash" {
		return withRecycleLock(state, func() error { return emptyLocalTrash(state) })
	}
	if args[1] == "restore" {
		id := request.ID
		if id == "" {
			id = request.Path
		}
		return withRecycleLock(state, func() error { return restoreLocalTrash(state, roots, id) })
	}
	ref := request.localFileRef
	if args[1] == "transfer" {
		ref = request.Source
	}
	if ref.Root == "recycle_bin" {
		switch args[1] {
		case "list":
			return withRecycleLock(state, func() error { return listLocalTrash(state) })
		case "delete":
			return withRecycleLock(state, func() error { return deleteLocalTrashItem(state, ref.Path) })
		default:
			return errors.New("unsupported Recycle Bin operation")
		}
	}
	base, ok := roots[ref.Root]
	if !ok {
		return errors.New("choose a local storage root")
	}
	if args[1] == "trash" {
		return withRecycleLock(state, func() error { return trashLocalFile(state, base, ref.Root, ref.Path) })
	}
	if args[1] == "delete" {
		return deleteLocalFile(base, ref.Path)
	}
	provider, err := filesproviders.NewNative(ref.Root, base)
	if err != nil {
		return err
	}
	defer provider.Close()
	switch args[1] {
	case "list":
		list, err := provider.List(ctx, ref.Path, request.Next, 500)
		if err != nil {
			return err
		}
		sort.Slice(list.Entries, func(i, j int) bool { return list.Entries[i].Name < list.Entries[j].Name })
		return output(list)
	case "upload-source":
		if ref.Path == "" || ref.Path == "." {
			return errors.New("select a file or folder")
		}
		entry, err := provider.Stat(ctx, ref.Path)
		if err != nil {
			return err
		}
		if entry.Kind != "file" && entry.Kind != "directory" {
			return errors.New("select a regular file or folder")
		}
		return output(map[string]string{"path": filepath.Join(base, ref.Path)})

	case "sync-location", "mkdir":
		folder, err := provider.OpenSyncDirectory(ctx, ref.Path)
		if err != nil {
			return err
		}
		defer folder.Close()
		lease := fmt.Sprintf("/proc/self/fd/%d", folder.Fd())
		if args[1] == "sync-location" {
			path, err := filepath.EvalSymlinks(lease)
			if err != nil {
				return err
			}
			return output(map[string]string{"path": path})
		}
		name := request.Name
		if name == "" || name == "." || name == ".." || filepath.Base(name) != name || filesproviders.ValidPath(name) != nil {
			return errors.New("choose a safe folder name")
		}
		root, err := os.OpenRoot(lease)
		if err != nil {
			return err
		}
		defer root.Close()
		if err := root.Mkdir(name, 0700); err != nil {
			return err
		}
		return output(true)
	case "preview", "open":
		file, err := provider.OpenRead(ctx, ref.Path)
		if err != nil {
			return err
		}
		defer file.Close()
		if args[1] == "open" {
			return output(map[string]string{"path": filepath.Join(base, ref.Path)})
		}
		const limit = 64 << 10
		data, err := io.ReadAll(io.LimitReader(file, limit+1))
		if err != nil {
			return err
		}
		truncated := len(data) > limit
		text := "Binary file. Use Open with to view it."
		if !bytes.ContainsRune(data, 0) {
			text = string(data[:min(len(data), limit)])
		}
		return output(map[string]any{"text": text, "truncated": truncated})
	case "transfer":
		targetRoot, ok := roots[request.Target.Root]
		if !ok || ref.Path == "" || ref.Path == "." {
			return errors.New("choose a local folder to copy or move the selected item into")
		}
		return copyLocalFile(ctx, provider, ref.Path, targetRoot, request.Target.Path, request.Move, request.Excludes)
	default:
		return errors.New("unknown local Files operation")
	}
}

func copyLocalFile(ctx context.Context, source *filesproviders.Native, sourcePath, targetRoot, targetPath string, move bool, excludes []string) error {
	target, err := filesproviders.NewNative("copy-target", targetRoot)
	if err != nil {
		return err
	}
	defer target.Close()
	folder, err := target.OpenSyncDirectory(ctx, targetPath)
	if err != nil {
		return err
	}
	defer folder.Close()
	destination := fmt.Sprintf("/proc/self/fd/%d", folder.Fd())
	targetName := filepath.Base(sourcePath)
	if ancestor, err := source.OpenSyncDirectory(ctx, sourcePath); err == nil {
		defer ancestor.Close()
		sourceDir, err := filepath.EvalSymlinks(fmt.Sprintf("/proc/self/fd/%d", ancestor.Fd()))
		if err != nil {
			return err
		}
		targetDir, err := filepath.EvalSymlinks(destination)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(sourceDir, targetDir)
		if err != nil || (rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator))) {
			return errors.New("choose a destination outside the selected source folder")
		}
	}
	allow := func(int64) error { return nil }
	manifest, err := files.Manifest(ctx, source, sourcePath, allow, excludes...)
	if err != nil {
		return err
	}
	expectedContent := files.ContentXXH64(manifest)
	pipeCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	reader, writer := io.Pipe()
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		writer.CloseWithError(transfer.WriteTar(pipeCtx, source, sourcePath, "none", writer, allow, excludes...))
	}()
	receipt, err := transfer.PullTar(pipeCtx, reader, "none", "local-files", manifest, filepath.Join(destination, targetName), nil)
	cancel()
	<-writerDone
	if err != nil {
		return err
	}
	remaining := true
	if move {
		remaining, err = transfer.RemoveVerified(ctx, source, sourcePath, expectedContent, manifest.Excludes, allow)
		if err != nil {
			return fmt.Errorf("copy verified; source removal stopped: %w", err)
		}
	}
	return output(map[string]any{
		"files":            receipt.Files,
		"bytes":            receipt.Bytes,
		"xxh64":            receipt.XXH64,
		"moved":            move,
		"source_remaining": remaining,
	})
}

func trashMetaPath(state string) string {
	return filepath.Join(state, "recycle-bin", "metadata.json")
}

func withRecycleLock(state string, action func() error) error {
	dir := filepath.Dir(trashMetaPath(state))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "metadata.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		return err
	}
	return action()
}

func readLocalTrash(state string) ([]trashEntryMeta, error) {
	raw, err := os.ReadFile(trashMetaPath(state))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil, nil
	}
	var entries []trashEntryMeta
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, err
	}
	return entries, nil
}

func writeLocalTrash(state string, entries []trashEntryMeta) error {
	metaPath := trashMetaPath(state)
	if err := os.MkdirAll(filepath.Dir(metaPath), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(entries)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(metaPath), ".metadata-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(data)
	if err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	directory, err := os.Open(filepath.Dir(metaPath))
	if err != nil {
		return err
	}
	defer directory.Close()
	if err := os.Rename(tmp.Name(), metaPath); err != nil {
		return err
	}
	return directory.Sync()
}

func openRecycleParent(base, rel string, create bool) (*os.File, error) {
	if rel == "" || rel == "." || filesproviders.ValidPath(rel) != nil {
		return nil, errors.New("choose a valid file or folder")
	}
	folder := filepath.Dir(rel)
	if create {
		root, err := os.OpenRoot(base)
		if err != nil {
			return nil, err
		}
		err = root.MkdirAll(folder, 0o755)
		root.Close()
		if err != nil {
			return nil, err
		}
	}
	provider, err := filesproviders.NewNative("local", base)
	if err != nil {
		return nil, err
	}
	defer provider.Close()
	return provider.OpenSyncDirectory(context.Background(), folder)
}

func trashLocalFile(state, base, rootKind, rel string) error {
	entries, err := readLocalTrash(state)
	if err != nil {
		return err
	}
	parent, err := openRecycleParent(base, rel, false)
	if err != nil {
		return err
	}
	defer parent.Close()
	name := filepath.Base(rel)
	info, err := os.Lstat(fmt.Sprintf("/proc/self/fd/%d/%s", parent.Fd(), name))
	if err != nil {
		return err
	}
	var rawID [16]byte
	if _, err := rand.Read(rawID[:]); err != nil {
		return err
	}
	id := hex.EncodeToString(rawID[:])
	wrapper := filepath.Join(state, "recycle-bin", "items", id)
	if err := os.MkdirAll(wrapper, 0o700); err != nil {
		return err
	}
	defer os.Remove(wrapper)
	destination, err := os.Open(wrapper)
	if err != nil {
		return err
	}
	defer destination.Close()
	dest := filepath.Join(wrapper, name)
	kind := "file"
	if info.IsDir() {
		kind = "directory"
	}
	entries = append(entries, trashEntryMeta{
		ID:           id,
		Name:         name,
		Kind:         kind,
		Size:         info.Size(),
		DeletedAt:    timeNowMillis(),
		OriginalKind: rootKind,
		OriginalPath: rel,
		StoragePath:  dest,
	})
	if err := writeLocalTrash(state, entries); err != nil {
		return err
	}
	// Record the destination first. An interrupted operation leaves either a
	// visible trash item or a missing-payload record that the UI filters out.
	if err := unix.Renameat2(int(parent.Fd()), name, int(destination.Fd()), name, unix.RENAME_NOREPLACE); err != nil {
		return errors.Join(err, writeLocalTrash(state, entries[:len(entries)-1]))
	}
	return output(map[string]any{"id": id, "name": name})
}

func timeNowMillis() int64 {
	return time.Now().UnixMilli()
}

func listLocalTrash(state string) error {
	entries, err := readLocalTrash(state)
	if err != nil {
		return err
	}
	out := make([]map[string]any, 0, len(entries))
	for _, item := range entries {
		if _, err := os.Lstat(item.StoragePath); err != nil {
			continue
		}
		out = append(out, map[string]any{
			"name":           item.Name,
			"path":           item.ID,
			"kind":           item.Kind,
			"size":           item.Size,
			"modified":       item.DeletedAt,
			"original_kind":  item.OriginalKind,
			"original_path":  item.OriginalPath,
			"original_label": item.OriginalKind + "/" + item.OriginalPath,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i]["modified"].(int64) > out[j]["modified"].(int64)
	})
	return output(map[string]any{"entries": out})
}

func restoreLocalTrash(state string, roots map[string]string, id string) error {
	if id == "" {
		return errors.New("Recycle Bin item ID is required")
	}
	entries, err := readLocalTrash(state)
	if err != nil {
		return err
	}
	idx := -1
	for i, item := range entries {
		if item.ID == id {
			idx = i
			break
		}
	}
	if idx < 0 {
		return errors.New("Recycle Bin item no longer exists")
	}
	item := entries[idx]
	base, ok := roots[item.OriginalKind]
	if !ok {
		return errors.New("original storage root is unavailable")
	}
	destination, err := openRecycleParent(base, item.OriginalPath, true)
	if err != nil {
		return err
	}
	defer destination.Close()
	err = unix.Renameat2(unix.AT_FDCWD, item.StoragePath, int(destination.Fd()),
		filepath.Base(item.OriginalPath), unix.RENAME_NOREPLACE)
	if errors.Is(err, unix.EEXIST) {
		return errors.New("Destination already exists; restore denied")
	}
	if err != nil {
		return err
	}
	_ = os.Remove(filepath.Dir(item.StoragePath))
	entries = append(entries[:idx], entries[idx+1:]...)
	if err := writeLocalTrash(state, entries); err != nil {
		return err
	}
	return output(map[string]any{"name": item.Name, "kind": item.OriginalKind, "path": item.OriginalPath})
}

func deleteLocalTrashItem(state, id string) error {
	if id == "" {
		return errors.New("Recycle Bin item ID is required")
	}
	entries, err := readLocalTrash(state)
	if err != nil {
		return err
	}
	idx := -1
	for i, item := range entries {
		if item.ID == id {
			idx = i
			break
		}
	}
	if idx < 0 {
		return errors.New("Recycle Bin item no longer exists")
	}
	item := entries[idx]
	if err := os.RemoveAll(item.StoragePath); err != nil {
		return err
	}
	_ = os.Remove(filepath.Dir(item.StoragePath))
	entries = append(entries[:idx], entries[idx+1:]...)
	if err := writeLocalTrash(state, entries); err != nil {
		return err
	}
	return output(true)
}

func deleteLocalFile(base, rel string) error {
	parent, err := openRecycleParent(base, rel, false)
	if err != nil {
		return err
	}
	defer parent.Close()
	root, err := os.OpenRoot(fmt.Sprintf("/proc/self/fd/%d", parent.Fd()))
	if err != nil {
		return err
	}
	defer root.Close()
	name := filepath.Base(rel)
	if _, err := root.Lstat(name); err != nil {
		return err
	}
	if err := root.RemoveAll(name); err != nil {
		return err
	}
	return output(true)
}

func emptyLocalTrash(state string) error {
	entries, err := readLocalTrash(state)
	if err != nil {
		return err
	}
	removed := 0
	var failures error
	remaining := entries[:0]
	for _, item := range entries {
		if err := os.RemoveAll(item.StoragePath); err != nil {
			failures = errors.Join(failures, err)
			remaining = append(remaining, item)
			continue
		}
		_ = os.Remove(filepath.Dir(item.StoragePath))
		removed++
	}
	if err := errors.Join(failures, writeLocalTrash(state, remaining)); err != nil {
		return err
	}
	return output(map[string]any{"removed": removed})
}
