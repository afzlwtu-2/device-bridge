package syncthing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/syncproviders"
	"devicebridge/internal/transfer"
	"devicebridge/protocol"

	"github.com/cespare/xxhash/v2"
	"golang.org/x/sys/unix"
)

var groupPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

const (
	SendOnly    = "sendonly"
	ReceiveOnly = "receiveonly"

	// ModeNonGit syncs a filtered projection; ModeFull syncs the registered
	// source folder directly, including hidden files and Git metadata, by
	// explicit user opt-in.
	ModeNonGit = "non-git"
	ModeFull   = "full"

	// FilterUntracked stages only approved persistent untracked/ignored files;
	// FilterWorking stages every working file except .git at any depth.
	FilterUntracked = "untracked"
	FilterWorking   = "working"
)

type Registration struct {
	Group      string   `json:"group"`
	PeerID     string   `json:"peer_id"`
	Role       string   `json:"role"`
	Path       string   `json:"path"`
	Activity   string   `json:"activity,omitempty"`
	BridgePeer string   `json:"devicebridge_peer,omitempty"`
	Mode       string   `json:"mode,omitempty"`
	Filter     string   `json:"filter,omitempty"`
	Source     string   `json:"source,omitempty"`
	Excludes   []string `json:"excludes,omitempty"`
}

// Different projections must not inherit each other's engine index vectors.
// Keep the legacy signed-project folder ID stable for existing installations.
func (r Registration) engineFolderID() string {
	if r.Mode == ModeFull {
		return "devicebridge-v1.full." + r.Group
	}
	if r.Filter == FilterWorking {
		return "devicebridge-v1.working." + r.Group
	}
	return r.Group
}

func (r Registration) valid() bool {
	if !groupPattern.MatchString(r.Group) || !devicePattern.MatchString(r.PeerID) ||
		(r.Role != SendOnly && r.Role != ReceiveOnly) {
		return false
	}
	if r.Source != "" && !filepath.IsAbs(r.Source) {
		return false
	}
	if len(r.Excludes) > 0 {
		if _, err := files.ValidateExclusions(r.Excludes); err != nil {
			return false
		}
	}
	switch r.Mode {
	case "", ModeNonGit:
		return r.Filter == "" || r.Filter == FilterUntracked || r.Filter == FilterWorking
	case ModeFull:
		return r.Filter == "" && r.Source != ""
	default:
		return false
	}
}

func normalizeMode(mode, filter string) (string, string, error) {
	switch mode {
	case "", ModeNonGit:
		switch filter {
		case "", FilterUntracked:
			return ModeNonGit, FilterUntracked, nil
		case FilterWorking:
			return ModeNonGit, FilterWorking, nil
		default:
			return "", "", errors.New("the non-git filter must be untracked or working")
		}
	case ModeFull:
		if filter != "" {
			return "", "", errors.New("full folder sync does not use a filter")
		}
		return ModeFull, "", nil
	default:
		return "", "", errors.New("the sync mode must be non-git or full")
	}
}

func validateSource(source string) (string, error) {
	if source == "" {
		return "", nil
	}
	if !filepath.IsAbs(source) {
		return "", errors.New("the sync source folder must be an absolute path")
	}
	canonical, err := filepath.EvalSymlinks(source)
	if err != nil {
		return "", errors.New("the sync source folder must exist")
	}
	info, err := os.Lstat(canonical)
	if err != nil || !info.IsDir() {
		return "", errors.New("the sync source must be a directory")
	}
	return canonical, nil
}

func (p Profile) checkSourceOutsideProfile(source string) error {
	if source != "" && (source == p.dir || strings.HasPrefix(source, p.dir+string(os.PathSeparator))) {
		return errors.New("the sync source cannot live inside the managed Syncthing profile")
	}
	return nil
}

func (p Profile) BindProject(group, peer string) (Registration, error) {
	lock, err := p.lock()
	if err != nil {
		return Registration{}, err
	}
	defer lock.Close()
	entry, err := p.Registration(group)
	if err != nil {
		return entry, err
	}
	if peer == "" || (entry.BridgePeer != "" && entry.BridgePeer != peer) {
		return entry, errors.New("this project is already bound to a different DeviceBridge peer")
	}
	entry.BridgePeer = peer
	return entry, p.saveRegistration(entry, "paused")
}

func (p Profile) SetProjectRole(group, role string) (Registration, error) {
	lock, err := p.lock()
	if err != nil {
		return Registration{}, err
	}
	defer lock.Close()
	entry, err := p.Registration(group)
	if err != nil {
		return entry, err
	}
	if entry.BridgePeer == "" || (role != SendOnly && role != ReceiveOnly) {
		return entry, errors.New("a bound project and valid role are required")
	}
	if entry.Role == role {
		return entry, nil
	}
	entry.Role = role
	return entry, p.saveRegistration(entry, "paused")
}

func (p Profile) lock() (*os.File, error) {
	lock, err := os.OpenFile(filepath.Join(p.dir, ".lock"), os.O_RDWR|os.O_CREATE|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lock.Close()
		return nil, fmt.Errorf("a managed Syncthing operation holds this profile: %w", err)
	}
	return lock, nil
}

func (p Profile) Register(ctx context.Context, group, peerID, role, mode, filter, source string) (Registration, error) {
	mode, filter, err := normalizeMode(mode, filter)
	if err != nil {
		return Registration{}, err
	}
	source, err = validateSource(source)
	if err != nil {
		return Registration{}, err
	}
	if err := p.checkSourceOutsideProfile(source); err != nil {
		return Registration{}, err
	}
	if mode == ModeFull && source == "" {
		return Registration{}, errors.New("full folder sync needs the source folder path")
	}
	entry := Registration{Group: group, PeerID: peerID, Role: role, Mode: mode, Filter: filter, Source: source}
	if !entry.valid() {
		return entry, errors.New("provide a group ID, a Syncthing device ID and sendonly or receiveonly")
	}
	info, err := p.Inspect(ctx)
	if err != nil {
		return entry, err
	}
	if !info.Prepared || info.DeviceID == entry.PeerID {
		return entry, errors.New("prepare the managed profile first and approve a different peer")
	}
	lock, err := p.lock()
	if err != nil {
		return entry, err
	}
	defer lock.Close()
	folders := filepath.Join(p.dir, "folders")
	if mode == ModeFull {
		entry.Path = entry.Source
		if err := ensurePrivateDir(folders, true); err != nil {
			return entry, err
		}
	} else {
		entry.Path, err = filepath.Abs(filepath.Join(p.dir, "projections", group))
		if err != nil {
			return entry, err
		}
		for _, dir := range []string{folders, filepath.Dir(entry.Path), entry.Path} {
			if err := ensurePrivateDir(dir, true); err != nil {
				return entry, err
			}
		}
	}
	previous, err := p.Registration(group)
	if err == nil {
		if previous.PeerID == peerID && previous.Role == role &&
			previous.Mode == mode && previous.Filter == filter && previous.Source == source {
			return previous, nil
		}
		return entry, errors.New("this group is already registered; use syncthing mode to change its peer, role or sync mode")
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return entry, err
	}
	return entry, p.saveRegistration(entry, "paused")
}

// SetMode changes how a paused registration syncs. Full mode points Syncthing
// at the real source folder; non-git keeps the managed projection.
func (p Profile) SetMode(group, mode, filter, source string) (Registration, error) {
	mode, filter, err := normalizeMode(mode, filter)
	if err != nil {
		return Registration{}, err
	}
	source, err = validateSource(source)
	if err != nil {
		return Registration{}, err
	}
	if err := p.checkSourceOutsideProfile(source); err != nil {
		return Registration{}, err
	}
	lock, err := p.lock()
	if err != nil {
		return Registration{}, err
	}
	defer lock.Close()
	entry, err := p.Registration(group)
	if err != nil {
		return Registration{}, err
	}
	if entry.Activity == "running" {
		return entry, errors.New("stop the running session before changing the sync mode")
	}
	if mode == ModeFull && source == "" {
		return entry, errors.New("full folder sync needs the source folder path")
	}
	entry.Mode, entry.Filter = mode, filter
	if source != "" {
		entry.Source = source
	}
	if mode == ModeFull {
		entry.Path = entry.Source
	} else {
		entry.Path, err = filepath.Abs(filepath.Join(p.dir, "projections", group))
		if err != nil {
			return entry, err
		}
		for _, dir := range []string{filepath.Dir(entry.Path), entry.Path} {
			if err := ensurePrivateDir(dir, true); err != nil {
				return entry, err
			}
		}
	}
	return entry, p.saveRegistration(entry, "paused")
}

// SetExcludes records the relative subtrees the user opted to leave out of the
// verified sync contract. Exclusions never relax the symlink/special-file block
// for entries that remain in scope; they only remove whole subtrees from both
// the manifest and the engine transfer.
func (p Profile) SetExcludes(group string, excludes []string) (Registration, error) {
	normalized, err := files.ValidateExclusions(excludes)
	if err != nil {
		return Registration{}, err
	}
	lock, err := p.lock()
	if err != nil {
		return Registration{}, err
	}
	defer lock.Close()
	entry, err := p.Registration(group)
	if err != nil {
		return Registration{}, err
	}
	if entry.Activity == "running" {
		return entry, errors.New("stop the running session before changing exclusions")
	}
	entry.Excludes = normalized
	return entry, p.saveRegistration(entry, entry.Activity)
}

func (p Profile) Registration(group string) (Registration, error) {
	var registration Registration
	if !groupPattern.MatchString(group) {
		return registration, errors.New("invalid registered group ID")
	}
	if err := ensurePrivateDir(filepath.Join(p.dir, "folders"), false); err != nil {
		return registration, err
	}
	raw, err := os.ReadFile(filepath.Join(p.dir, "folders", group+".json"))
	if err != nil {
		return registration, err
	}
	if json.Unmarshal(raw, &registration) != nil || registration.Group != group || !registration.valid() {
		return registration, errors.New("invalid Sync registration")
	}
	if registration.Mode == "" {
		registration.Mode = ModeNonGit
	}
	if registration.Mode == ModeNonGit && registration.Filter == "" {
		registration.Filter = FilterUntracked
	}
	if registration.Mode == ModeFull {
		registration.Path = registration.Source
		return registration, nil
	}
	registration.Path, err = filepath.Abs(filepath.Join(p.dir, "projections", group))
	return registration, err
}

func (p Profile) List() ([]Registration, error) {
	result := []Registration{}
	if err := ensurePrivateDir(p.dir, false); errors.Is(err, fs.ErrNotExist) {
		return result, nil
	} else if err != nil {
		return nil, err
	}
	dir := filepath.Join(p.dir, "folders")
	if err := ensurePrivateDir(dir, false); errors.Is(err, fs.ErrNotExist) {
		return result, nil
	} else if err != nil {
		return nil, err
	}
	items, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	for _, item := range items {
		group, ok := strings.CutSuffix(item.Name(), ".json")
		if !ok || !item.Type().IsRegular() {
			continue
		}
		entry, err := p.Registration(group)
		if err != nil {
			return nil, err
		}
		if entry.Activity == "running" {
			if lock, err := p.lock(); err == nil {
				entry.Activity = "interrupted"
				lock.Close()
			}
		}
		result = append(result, entry)
	}
	return result, nil
}

func (p Profile) saveRegistration(r Registration, activity string) error {
	r.Activity = activity
	// Resolve the managed path on each read, so moving a state directory
	// cannot redirect Syncthing to the old projection.
	r.Path = ""
	raw, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(p.dir, "folders"), r.Group+".json", raw)
}

func (p Profile) Digest(ctx context.Context, group string) (syncproviders.Digest, error) {
	entry, err := p.Registration(group)
	if err != nil {
		return syncproviders.Digest{}, err
	}
	return digestFor(ctx, entry)
}

// digestFor verifies the folder this registration actually syncs. Only full
// mode tolerates Git metadata; managed projections stay Git-free.
func digestFor(ctx context.Context, entry Registration) (syncproviders.Digest, error) {
	return projectionDigest(ctx, entry.Path, entry.Mode == ModeFull, entry.Excludes)
}

func (p Profile) ManifestScoped(ctx context.Context, group, sourceLease string) (syncproviders.Digest, error) {
	entry, err := p.Registration(group)
	if err != nil {
		return syncproviders.Digest{}, err
	}
	if entry.Mode == ModeFull {
		entry.Path = sourceLease
	}
	return digestFor(ctx, entry)
}

func projectionDigest(ctx context.Context, source string, allowGit bool, excludes []string) (syncproviders.Digest, error) {
	digest, _, err := inspectProjection(ctx, source, allowGit, excludes)
	return digest, err
}

func (p Profile) UseVerifiedProjection(ctx context.Context, group, checksum string, action func(string, protocol.Manifest) error) error {
	lock, err := p.lock()
	if err != nil {
		return err
	}
	defer lock.Close()
	registration, err := p.Registration(group)
	if err != nil {
		return err
	}
	digest, manifest, err := inspectProjection(ctx, registration.Path, false, registration.Excludes)
	if err != nil {
		return err
	}
	if digest.XXH64 != checksum {
		return errors.New("the local projection differs from the signed checksum")
	}
	return action(registration.Path, manifest)
}

// managedIgnoreContent is the deterministic .stignore DeviceBridge writes for a
// registration's exclusions. Each relative subtree becomes a root-anchored
// Syncthing ignore pattern so the engine skips exactly what the manifest skips.
func managedIgnoreContent(excludes []string) string {
	lines := make([]string, 0, len(excludes))
	for _, exclude := range excludes {
		lines = append(lines, "/"+exclude)
	}
	return strings.Join(lines, "\n") + "\n"
}

func inspectProjection(ctx context.Context, source string, allowGit bool, excludes []string) (syncproviders.Digest, protocol.Manifest, error) {
	var empty protocol.Manifest
	// A full-mode source is the user's own folder and need not be private;
	// managed projections and their parents must stay private.
	if !allowGit {
		if err := ensurePrivateDir(filepath.Dir(source), false); err != nil {
			return syncproviders.Digest{}, empty, err
		}
		if err := ensurePrivateDir(source, false); err != nil {
			return syncproviders.Digest{}, empty, err
		}
	}
	provider, err := filesproviders.NewNative("managed-sync", source)
	if err != nil {
		return syncproviders.Digest{}, empty, err
	}
	defer provider.Close()
	walkExcludes := []string{".stfolder", ".stversions", ".stignore"}
	walkExcludes = append(walkExcludes, excludes...)
	// A .stignore is trusted only when it is exactly the managed ignore file
	// for these exclusions; any foreign .stignore still fails closed so engine
	// ignores can never hide entries the manifest claims to verify. It is always
	// excluded from the manifest so the verified hash is stable whether or not
	// the engine has written it yet.
	if raw, readErr := os.ReadFile(filepath.Join(source, ".stignore")); readErr == nil {
		if len(excludes) == 0 || string(raw) != managedIgnoreContent(excludes) {
			return syncproviders.Digest{}, empty, errors.New("the synced folder contains a Git or Syncthing control file that is not allowed in this mode")
		}
	} else if !errors.Is(readErr, fs.ErrNotExist) {
		return syncproviders.Digest{}, empty, readErr
	}
	manifest, err := files.Manifest(ctx, provider, ".", func(int64) error { return nil }, walkExcludes...)
	if err != nil {
		return syncproviders.Digest{}, empty, err
	}
	for _, entry := range manifest.Entries {
		if filepath.Base(entry.Path) == ".stignore" || (!allowGit && filepath.Base(entry.Path) == ".git") {
			return syncproviders.Digest{}, empty, errors.New("the synced folder contains a Git or Syncthing control file that is not allowed in this mode")
		}
	}
	slices.SortFunc(manifest.Entries[1:], func(a, b protocol.ManifestEntry) int { return strings.Compare(a.Path, b.Path) })
	if err := transfer.ValidateManifest(manifest); err != nil {
		return syncproviders.Digest{}, empty, err
	}
	data, err := json.Marshal(manifest)
	if err != nil {
		return syncproviders.Digest{}, empty, err
	}
	return syncproviders.Digest{XXH64: fmt.Sprintf("%016x", xxhash.Sum64(data)), Bytes: manifest.Bytes, Items: len(manifest.Entries) - 1}, manifest, nil
}
