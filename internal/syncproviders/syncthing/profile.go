// Package syncthing controls an external Syncthing executable in an isolated
// DeviceBridge profile. Its processes are bounded by explicit local requests.
package syncthing

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const homeName = "syncthing-v1"

var versionPattern = regexp.MustCompile(`(?m)^syncthing v([0-9]+)\.([0-9]+)\.[0-9]+[^\s]*`)
var devicePattern = regexp.MustCompile(`^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$`)

type Info struct {
	Installed bool   `json:"installed"`
	Version   string `json:"version,omitempty"`
	Prepared  bool   `json:"prepared"`
	DeviceID  string `json:"device_id,omitempty"`
	Dedicated bool   `json:"dedicated"`
}

type Profile struct {
	dir string
}

func Open(state string) Profile {
	dir := filepath.Join(state, homeName)
	if absolute, err := filepath.Abs(dir); err == nil {
		dir = absolute
	}
	return Profile{dir: dir}
}

// The app supplies its packaged engine explicitly. Desktop/Termux may continue
// to use an independently installed executable without changing PATH globally.
func engineBinary() (string, error) {
	if binary := os.Getenv("DEVICEBRIDGE_SYNCTHING_BINARY"); binary != "" {
		if !filepath.IsAbs(binary) {
			return "", errors.New("the Syncthing engine path must be absolute")
		}
		return exec.LookPath(binary)
	}
	if binary, err := exec.LookPath("syncthing"); err == nil {
		return binary, nil
	}
	if executable, err := os.Executable(); err == nil {
		binary := filepath.Join(filepath.Dir(executable), "bridge-sync")
		if found, err := exec.LookPath(binary); err == nil {
			return found, nil
		}
	}
	return "", exec.ErrNotFound
}

func (p Profile) Inspect(ctx context.Context) (Info, error) {
	info := Info{Dedicated: true}
	binary, err := engineBinary()
	if errors.Is(err, exec.ErrNotFound) {
		return info, nil
	}
	if err != nil {
		return info, err
	}
	version, err := detectVersion(ctx, binary)
	if err != nil {
		return info, err
	}
	info.Installed, info.Version = true, version
	if _, err := os.Lstat(p.dir); errors.Is(err, fs.ErrNotExist) {
		return info, nil
	} else if err != nil {
		return info, err
	}
	if err := ensurePrivateDir(p.dir, false); err != nil {
		return info, err
	}
	raw, err := os.ReadFile(filepath.Join(p.dir, "device-id"))
	if errors.Is(err, fs.ErrNotExist) {
		return info, nil
	}
	if err != nil {
		return info, err
	}
	info.DeviceID = strings.TrimSpace(string(raw))
	if !devicePattern.MatchString(info.DeviceID) {
		return info, errors.New("invalid managed Syncthing identity")
	}
	info.Prepared = true
	return info, nil
}

func detectVersion(ctx context.Context, binary string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := syncthingCommand(ctx, binary, "--version")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("cannot read installed Syncthing version: %w", err)
	}
	match := versionPattern.FindStringSubmatch(string(out))
	if match == nil {
		return "", errors.New("unrecognized Syncthing version")
	}
	major, _ := strconv.Atoi(match[1])
	minor, _ := strconv.Atoi(match[2])
	if major != 2 && (major != 1 || minor < 23) {
		return "", errors.New("the managed profile requires Syncthing 1.23 through 2.x")
	}
	return strings.TrimPrefix(match[0], "syncthing "), nil
}

func ensurePrivateDir(dir string, create bool) error {
	if create {
		if err := os.Mkdir(dir, 0700); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("the managed Syncthing directory must be private")
	}
	return nil
}

func (p Profile) Prepare(ctx context.Context) (Info, error) {
	info, err := p.Inspect(ctx)
	if err != nil {
		return info, err
	}
	if !info.Installed {
		return info, errors.New("install Syncthing separately before preparing synchronization")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	err = p.withDaemon(ctx, "tcp4://127.0.0.1:0", func(ctx context.Context, api *restClient, device string) error {
		info.DeviceID = device
		info.Prepared = true
		return writeAtomic(p.dir, "device-id", []byte(device+"\n"))
	})
	return info, err
}

func syncthingCommand(ctx context.Context, binary string, arguments ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, binary, arguments...)
	for _, variable := range os.Environ() {
		key, _, _ := strings.Cut(variable, "=")
		if strings.HasPrefix(key, "ST") || strings.HasSuffix(strings.ToUpper(key), "_PROXY") {
			continue
		}
		cmd.Env = append(cmd.Env, variable)
	}
	// Use the actual daemon as our child, with no intermediate restart monitor.
	cmd.Env = append(cmd.Env, "STNODEFAULTFOLDER=1", "STMONITORED=1")
	return cmd
}

type daemonConfig struct {
	XMLName xml.Name       `xml:"configuration"`
	Version int            `xml:"version,attr"`
	Folders []pausedFolder `xml:"folder"`
	Devices []pausedDevice `xml:"device"`
	GUI     struct {
		Enabled bool   `xml:"enabled,attr"`
		Address string `xml:"address"`
		Key     string `xml:"apikey"`
	} `xml:"gui"`
	Options struct {
		Listen         string `xml:"listenAddress"`
		Global         bool   `xml:"globalAnnounceEnabled"`
		Local          bool   `xml:"localAnnounceEnabled"`
		NAT            bool   `xml:"natEnabled"`
		Relays         bool   `xml:"relaysEnabled"`
		Browser        bool   `xml:"startBrowser"`
		CrashReports   bool   `xml:"crashReportingEnabled"`
		AnnounceLAN    bool   `xml:"announceLANAddresses"`
		STUNInterval   int    `xml:"stunKeepaliveStartS"`
		UpgradeHours   int    `xml:"autoUpgradeIntervalH"`
		UsageReporting int    `xml:"urAccepted"`
	} `xml:"options"`
}

type pausedFolder struct {
	ID          string               `xml:"id,attr"`
	Path        string               `xml:"path,attr"`
	Type        string               `xml:"type,attr"`
	IgnorePerms bool                 `xml:"ignorePerms,attr"`
	Paused      bool                 `xml:"paused"`
	Devices     []pausedFolderDevice `xml:"device"`
}
type pausedFolderDevice struct {
	ID string `xml:"id,attr"`
}
type pausedDevice struct {
	ID        string   `xml:"id,attr"`
	Paused    bool     `xml:"paused"`
	Addresses []string `xml:"address"`
	Networks  []string `xml:"allowedNetwork"`
}

func (p Profile) leaseAlias(group string) string { return filepath.Join(p.dir, "leases", group) }

// Keep the engine's configured folder path stable between bounded sessions,
// while the actual source is a freshly leased inode for the approved session.
func (p Profile) setLeaseAlias(group, target string) (string, error) {
	dir := filepath.Join(p.dir, "leases")
	if err := ensurePrivateDir(dir, true); err != nil {
		return "", err
	}
	alias := p.leaseAlias(group)
	if info, err := os.Lstat(alias); err == nil && info.Mode()&os.ModeSymlink == 0 {
		return "", errors.New("unsafe managed sync lease alias")
	}
	temporary, err := os.CreateTemp(dir, ".lease-")
	if err != nil {
		return "", err
	}
	name := temporary.Name()
	temporary.Close()
	os.Remove(name)
	defer os.Remove(name)
	if err = os.Symlink(target, name); err != nil {
		return "", err
	}
	if err = os.Rename(name, alias); err != nil {
		return "", err
	}
	return alias, nil
}

func (p Profile) withDaemon(ctx context.Context, listen string, action func(context.Context, *restClient, string) error) (runErr error) {
	binary, err := engineBinary()
	if err != nil {
		return err
	}
	if err := ensurePrivateDir(p.dir, true); err != nil {
		return err
	}
	// All callers use this lock before touching a profile or starting a process.
	lock, err := p.lock()
	if err != nil {
		return err
	}
	defer lock.Close()
	registered, err := p.List()
	if err != nil {
		return err
	}
	for _, entry := range registered {
		if entry.Activity == "running" {
			if err := p.saveRegistration(entry, "interrupted"); err != nil {
				return err
			}
		}
	}
	if _, err := detectVersion(ctx, binary); err != nil {
		return err
	}
	home, err := filepath.Abs(filepath.Join(p.dir, "daemon"))
	if err != nil {
		return err
	}
	if err := ensurePrivateDir(home, true); err != nil {
		return err
	}
	generate := syncthingCommand(ctx, binary, "generate", "--home="+home, "--no-port-probing")
	if err := generate.Run(); err != nil {
		return fmt.Errorf("cannot generate the isolated Syncthing profile: %w", err)
	}
	raw, err := os.ReadFile(filepath.Join(home, "config.xml"))
	if err != nil {
		return err
	}
	var schema struct {
		Version int `xml:"version,attr"`
	}
	if xml.Unmarshal(raw, &schema) != nil || schema.Version < 1 {
		return errors.New("cannot read Syncthing configuration version")
	}
	socketHome, err := os.MkdirTemp("", "devicebridge-sync-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(socketHome)
	socket := filepath.Join(socketHome, "gui.sock")
	if len(socket) > 107 {
		return errors.New("the DeviceBridge state path is too long for the private Syncthing socket")
	}
	var key [32]byte
	if _, err := rand.Read(key[:]); err != nil {
		return err
	}
	cfg := daemonConfig{Version: schema.Version}
	// Dropping these IDs at startup makes Syncthing erase their indexes and
	// falsely conflict on the next approved run. Keep all registrations paused;
	// none can scan, dial or transfer until the controller unpauses its session.
	peers := map[string]bool{}
	for _, entry := range registered {
		path := entry.Path
		if entry.Mode == ModeFull {
			parked := filepath.Join(p.dir, "parked", entry.Group)
			if err := ensurePrivateDir(filepath.Dir(parked), true); err != nil {
				return err
			}
			if err := ensurePrivateDir(parked, true); err != nil {
				return err
			}
			if _, err := p.setLeaseAlias(entry.Group, parked); err != nil {
				return err
			}
			path = p.leaseAlias(entry.Group)
		}
		cfg.Folders = append(cfg.Folders, pausedFolder{ID: entry.engineFolderID(), Path: path, Type: entry.Role, IgnorePerms: true, Paused: true, Devices: []pausedFolderDevice{{ID: entry.PeerID}}})
		if !peers[entry.PeerID] {
			peers[entry.PeerID] = true
			cfg.Devices = append(cfg.Devices, pausedDevice{ID: entry.PeerID, Paused: true, Addresses: []string{"tcp4://127.0.0.1:1"}, Networks: []string{"127.0.0.1/32"}})
		}
	}
	cfg.Options.Listen = listen
	cfg.Options.UsageReporting = -1
	cfg.GUI.Enabled, cfg.GUI.Address, cfg.GUI.Key = true, socket, hex.EncodeToString(key[:])
	writeConfig := func() error {
		clean, err := xml.MarshalIndent(cfg, "", "  ")
		if err != nil {
			return err
		}
		return writeAtomic(home, "config.xml", clean)
	}
	if err := writeConfig(); err != nil {
		return err
	}
	defer func() {
		cfg.GUI.Enabled, cfg.GUI.Address, cfg.GUI.Key = false, "127.0.0.1:0", ""
		cfg.Options.Listen = "tcp4://127.0.0.1:0"
		runErr = errors.Join(runErr, writeConfig())
	}()

	log, err := os.OpenFile(filepath.Join(p.dir, "session.log"), os.O_WRONLY|os.O_TRUNC|os.O_CREATE|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	cmd := syncthingCommand(ctx, binary, "serve", "--home="+home, "--no-browser", "--no-upgrade", "--no-restart")
	cmd.Stdout, cmd.Stderr = log, log
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	// Linux attaches the child death signal to the thread that starts it.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := cmd.Start(); err != nil {
		return err
	}
	exited := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(exited)
	}()
	api := newREST(socket, cfg.GUI.Key)
	defer api.http.CloseIdleConnections()
	defer func() {
		shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = api.call(shutdown, "POST", "/rest/system/shutdown", nil, nil)
		select {
		case <-exited:
		case <-shutdown.Done():
			_ = cmd.Process.Kill()
			<-exited
		}
	}()
	device, err := api.awaitReady(ctx, exited, listen)
	if err != nil {
		return err
	}
	return action(ctx, api, device)
}

func writeAtomic(dir, base string, data []byte) error {
	file, err := os.CreateTemp(dir, "."+base+".*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(file.Name(), filepath.Join(dir, base)); err != nil {
		return err
	}
	parent, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer parent.Close()
	return parent.Sync()
}
