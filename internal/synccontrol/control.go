// Package synccontrol supervises bounded endpoint-to-endpoint sync jobs.
// Controllers exchange metadata; they never accept or forward file streams.
package synccontrol

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"devicebridge/internal/auth"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/platform"
	"devicebridge/internal/projectsync"
	"devicebridge/internal/storage"
	"devicebridge/internal/syncproviders"
	"devicebridge/internal/syncproviders/syncthing"
	"devicebridge/protocol"

	"golang.org/x/sys/unix"
)

var identifier = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

type Binding struct {
	Controller   string `json:"controller"`
	Root         string `json:"root"`
	Path         string `json:"path"`
	Source       string `json:"source"`
	LastManifest string `json:"last_manifest,omitempty"`
}

type Job struct {
	ID         string                 `json:"id"`
	Group      string                 `json:"group"`
	State      string                 `json:"state"`
	Error      string                 `json:"error,omitempty"`
	Receipt    *syncproviders.Receipt `json:"receipt,omitempty"`
	Controller string                 `json:"-"`
	Cancel     context.CancelFunc     `json:"-"`
	Done       chan struct{}          `json:"-"`
}

type Manager struct {
	ctx           context.Context
	state         string
	store         *storage.Store
	files         *filesproviders.Registry
	profile       syncthing.Profile
	mu            sync.Mutex
	jobs          map[string]*Job
	SocketAdapter bool
	WorkerProcess bool
	worker        *workerIdentity
	workerError   error
	workerCleanup map[string]string
	workerActive  map[string]bool
	workerCancel  map[string]context.CancelFunc
}

func New(ctx context.Context, state string, store *storage.Store, files *filesproviders.Registry) *Manager {
	manager := &Manager{ctx: ctx, state: state, store: store, files: files, profile: syncthing.Open(state), jobs: map[string]*Job{}, SocketAdapter: runtime.GOOS == "android"}
	manager.workerCleanup = map[string]string{}
	manager.workerActive = map[string]bool{}
	manager.workerCancel = map[string]context.CancelFunc{}
	manager.worker, manager.workerError = stateWorker(state)
	return manager
}

func (m *Manager) allowed(controller, root string, remote bool) error {
	if controller == "" {
		return nil
	} // An explicit local GUI operation.
	allowed, err := m.store.SyncControlAccess(controller, nil)
	if err != nil || !allowed {
		return errors.New("allow this controller in Files > Synced folders on the endpoint first")
	}
	if err := m.store.Authorized(controller, root, "read", 0); err != nil {
		return storage.ErrDenied
	}
	if remote {
		allowed, err = m.store.SyncRemoteAccess(controller, nil)
		if err != nil || !allowed {
			return errors.New("allow remote sync routes for this controller on both endpoints first")
		}
	}
	return nil
}

func leasePath(file *os.File) string { return fmt.Sprintf("/proc/%d/fd/%d", os.Getpid(), file.Fd()) }

func (m *Manager) directory(ctx context.Context, controller string, req protocol.SyncControl) (*os.File, string, error) {
	if err := m.allowed(controller, req.Root, false); err != nil {
		return nil, "", err
	}
	var provider *filesproviders.Native
	var relative string
	if controller == "" {
		if !filepath.IsAbs(req.LocalPath) {
			return nil, "", errors.New("choose a local folder in Files")
		}
		var err error
		provider, err = filesproviders.NewNative("local-sync", filepath.Dir(req.LocalPath))
		if err != nil {
			return nil, "", err
		}
		defer provider.Close()
		relative = filepath.Base(req.LocalPath)
		if filepath.Clean(req.LocalPath) == string(os.PathSeparator) {
			relative = "."
		}
	} else {
		if req.LocalPath != "" {
			return nil, "", errors.New("remote controllers must use granted root-relative paths")
		}
		p, ok := m.files.Get(req.Root)
		if !ok {
			return nil, "", storage.ErrDenied
		}
		provider, ok = p.(*filesproviders.Native)
		if !ok {
			return nil, "", errors.New("this storage provider needs a sync adapter; select native phone or machine storage")
		}
		relative = req.Path
	}
	file, err := provider.OpenSyncDirectory(ctx, relative)
	if err != nil {
		return nil, "", err
	}
	canonical, err := filepath.EvalSymlinks(leasePath(file))
	if err != nil {
		file.Close()
		return nil, "", err
	}
	return file, canonical, nil
}

func (m *Manager) binding(group string) (Binding, error) {
	var binding Binding
	if !identifier.MatchString(group) {
		return binding, errors.New("invalid sync group")
	}
	raw, err := os.ReadFile(filepath.Join(m.state, "sync-control-v1", group+".json"))
	if err == nil {
		err = json.Unmarshal(raw, &binding)
	}
	return binding, err
}

func (m *Manager) saveBinding(group string, binding Binding) error {
	dir := filepath.Join(m.state, "sync-control-v1")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	raw, err := json.Marshal(binding)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".binding-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if _, err = f.Write(raw); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), filepath.Join(dir, group+".json"))
}

// The endpoint can have independent GUI workers and a server. Serialize
// changes to bindings and job IDs across those processes during preflight.
func (m *Manager) lockOperations() (*os.File, error) {
	directory := filepath.Join(m.state, "sync-control-v1")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(filepath.Join(directory, ".operations"), os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		file.Close()
		return nil, errors.New("another folder sync operation is preparing on this endpoint; retry shortly")
	}
	return file, nil
}

func (m *Manager) Handle(ctx context.Context, controller string, req protocol.SyncControl) (any, error) {
	if m.workerError != nil {
		return nil, m.workerError
	}
	if m.worker != nil && req.Operation != "status" && req.Operation != "stop" {
		return m.delegate(ctx, controller, req)
	}
	if err := m.allowed(controller, req.Root, req.RemoteApproved); err != nil {
		return nil, err
	}
	if req.Operation == "status" || req.Operation == "stop" {
		m.mu.Lock()
		defer m.mu.Unlock()
		job, ok := m.jobs[req.JobID]
		if !ok {
			var err error
			job, err = m.readJob(req.JobID)
			if req.Operation == "stop" && controller == "" && m.WorkerProcess && errors.Is(err, os.ErrNotExist) {
				binding, bindErr := m.binding(req.Group)
				if bindErr != nil || binding.Controller != "" || binding.Root != req.Root {
					return nil, storage.ErrDenied
				}
				// A local stop can arrive while the job is still preparing.
				_, err = m.requestOwnerStop(req.JobID)
				return Job{ID: req.JobID, Group: req.Group, State: "interrupted"}, err
			}
			ok = err == nil
		}
		if !ok || job.Controller != controller || job.Group != req.Group {
			return nil, errors.New("sync job is unavailable on this endpoint")
		}
		binding, err := m.binding(job.Group)
		if err != nil || binding.Controller != controller || binding.Root != req.Root {
			return nil, storage.ErrDenied
		}
		if req.Operation == "stop" && job.Cancel != nil {
			job.Cancel()
		}
		if req.Operation == "stop" && m.worker != nil {
			if cancel := m.workerCancel[req.JobID]; cancel != nil {
				cancel()
			}
		}
		if req.Operation == "stop" && job.Cancel == nil && job.State == "running" {
			if m.worker == nil {
				if err := m.stopSavedJob(req.JobID, controller); err != nil {
					return nil, err
				}
			}
		}
		result := *job
		if message := m.workerCleanup[req.JobID]; message != "" {
			result.State = "interrupted"
			result.Error = message
		} else if m.workerActive[req.JobID] && result.State != "running" {
			result.State = "running"
		}
		return result, nil
	}
	file, source, err := m.directory(ctx, controller, req)
	if err != nil {
		return nil, err
	}
	defer func() {
		if file != nil {
			file.Close()
		}
	}()
	if req.Operation == "mkdir" {
		if req.Name == "" || req.Name == "." || req.Name == ".." || strings.Contains(req.Name, "/") || len(req.Name) > 255 || filesproviders.ValidPath(req.Name) != nil {
			return nil, errors.New("choose a safe new folder name")
		}
		parent, err := os.OpenRoot(leasePath(file))
		if err != nil {
			return nil, err
		}
		defer parent.Close()
		if err = parent.Mkdir(req.Name, 0700); err != nil {
			return nil, errors.New("the new sync folder could not be created without overwriting an existing path")
		}
		path := req.Name
		if req.Path != "" && req.Path != "." {
			path = req.Path + "/" + req.Name
		}
		return map[string]string{"path": path}, nil
	}
	if req.Operation == "info" || req.Operation == "prepare" {
		var info syncthing.Info
		if req.Operation == "prepare" {
			info, err = m.profile.Prepare(ctx)
		} else {
			info, err = m.profile.Inspect(ctx)
		}
		if err != nil {
			return nil, err
		}
		return struct {
			syncthing.Info
			Networks []protocol.SyncNetwork `json:"networks"`
		}{info, Networks()}, nil
	}
	if req.Operation == "probe" {
		plan := syncproviders.Plan{Interface: req.Interface, CIDR: req.CIDR, Listen: req.Listen, PeerEndpoint: req.PeerEndpoint, Route: req.Route, RemoteApproved: req.RemoteApproved}
		if err := syncthing.ValidateRoute(plan); err != nil {
			return nil, err
		}
		identity, err := auth.Load(m.store, "")
		if err != nil {
			return nil, err
		}
		if decoded, err := hex.DecodeString(req.PeerDeviceID); err != nil || len(decoded) != 32 {
			return nil, errors.New("probe needs the paired destination device identity")
		}
		local, _ := netip.ParseAddrPort(req.Listen)
		probeCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		defer cancel()
		dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: 3 * time.Second, LocalAddr: &net.TCPAddr{IP: net.IP(local.Addr().AsSlice())}, Control: platform.SocketControl}, Config: identity.ClientTLS(req.PeerDeviceID)}
		started := time.Now()
		connection, err := dialer.DialContext(probeCtx, "tcp4", req.PeerEndpoint)
		if err != nil {
			return nil, errors.New("the endpoints could not authenticate each other on this route")
		}
		connection.Close()
		return map[string]any{"reachable": true, "handshake_ms": time.Since(started).Milliseconds()}, nil
	}
	if !identifier.MatchString(req.Group) {
		return nil, errors.New("invalid sync group")
	}
	switch req.Operation {
	case "register", "mode", "forget", "start":
		lock, err := m.lockOperations()
		if err != nil {
			return nil, err
		}
		defer lock.Close()
	}
	if req.Operation == "register" {
		binding, be := m.binding(req.Group)
		if be == nil && (binding.Controller != controller || binding.Root != req.Root || binding.Path != req.Path || binding.Source != source) {
			return nil, storage.ErrDenied
		}
		if be != nil && !errors.Is(be, os.ErrNotExist) {
			return nil, be
		}
		if req.Mode == "non-git" && req.Filter != "working" {
			return nil, errors.New("use the all-working-files filter for GUI folder sync; signed Git ownership uses the project workflow")
		}
		entry, existing := m.profile.Registration(req.Group)
		if existing == nil {
			if be != nil || entry.PeerID != req.PeerID || entry.Role != req.Role || entry.Source != source {
				return nil, errors.New("this group already belongs to another registration")
			}
			if _, err := m.profile.SetMode(req.Group, req.Mode, req.Filter, source); err != nil {
				return nil, err
			}
			return m.profile.SetExcludes(req.Group, req.Excludes)
		}
		if !errors.Is(existing, os.ErrNotExist) {
			return nil, existing
		}
		if be != nil {
			// Record the owner before creating the registration so a partial
			// attempt can always be retried or forgotten by that owner.
			if err := m.saveBinding(req.Group, Binding{Controller: controller, Root: req.Root, Path: req.Path, Source: source}); err != nil {
				return nil, err
			}
		}
		if _, err := m.profile.Register(ctx, req.Group, req.PeerID, req.Role, req.Mode, req.Filter, source); err != nil {
			return nil, err
		}
		return m.profile.SetExcludes(req.Group, req.Excludes)
	}
	binding, err := m.binding(req.Group)
	if req.Operation == "forget" && errors.Is(err, os.ErrNotExist) {
		if _, e := m.profile.Registration(req.Group); errors.Is(e, os.ErrNotExist) {
			return map[string]string{"state": "forgotten"}, nil
		}
	}
	if err != nil || binding.Controller != controller || binding.Root != req.Root || binding.Path != req.Path || binding.Source != source {
		return nil, storage.ErrDenied
	}
	entry, err := m.profile.Registration(req.Group)
	if req.Operation == "forget" && errors.Is(err, os.ErrNotExist) {
		return map[string]string{"state": "forgotten"}, os.Remove(filepath.Join(m.state, "sync-control-v1", req.Group+".json"))
	}
	if err != nil || entry.Source != source {
		return nil, errors.New("sync registration no longer matches this folder")
	}
	switch req.Operation {
	case "mode":
		if _, err := m.profile.SetMode(req.Group, req.Mode, req.Filter, source); err != nil {
			return nil, err
		}
		return m.profile.SetExcludes(req.Group, req.Excludes)
	case "manifest":
		if entry.Role == syncthing.SendOnly && entry.Mode == syncthing.ModeNonGit {
			_, err = m.profile.ReplaceProjection(ctx, req.Group, true, func(destination string) error {
				_, e := projectsync.BuildWorking(ctx, leasePath(file), destination)
				return e
			})
			if err != nil {
				return nil, err
			}
		}
		return m.profile.ManifestScoped(ctx, req.Group, leasePath(file))
	case "forget":
		if err := m.profile.Unregister(req.Group); err != nil {
			return nil, err
		}
		return map[string]string{"state": "forgotten"}, os.Remove(filepath.Join(m.state, "sync-control-v1", req.Group+".json"))
	case "start":
		m.mu.Lock()
		_, used := m.jobs[req.JobID]
		m.mu.Unlock()
		if name, e := m.jobPath(req.JobID); e == nil {
			if _, e = os.Stat(name); e == nil {
				used = true
			}
		}
		if used {
			return nil, errors.New("this sync approval was already used; inspect its job status")
		}
		if req.Bytes < 0 || req.Bytes > files.MaxManifestBytes {
			return nil, errors.New("invalid approved sync byte budget")
		}
		if _, err := hex.DecodeString(req.JobID); err != nil || len(req.JobID) != 32 {
			return nil, errors.New("invalid sync job identity")
		}
		if err := m.ownerStopped(req.JobID); err != nil {
			return nil, err
		}
		if req.Seconds == 0 {
			req.Seconds = 300
		}
		if req.Seconds < 5 || req.Seconds > 900 {
			return nil, errors.New("sync sessions must last 5 to 900 seconds")
		}
		if req.Route != "" && req.Route != "lan" && req.Route != "tailscale" && req.Route != "routed" {
			return nil, errors.New("unsupported sync route")
		}
		if req.Route != "" && req.Route != "lan" && !req.RemoteApproved {
			return nil, errors.New("approve the remote data route first")
		}
		for _, endpoint := range []string{req.Listen, req.PeerEndpoint} {
			address, e := netip.ParseAddrPort(endpoint)
			if e != nil || address.Port() < 22001 || address.Port() > 22010 {
				return nil, errors.New("use a dedicated sync port from 22001 to 22010")
			}
		}
		plan := syncproviders.Plan{ID: req.JobID, Group: req.Group, Owner: entry.PeerID, ManifestHash: req.Manifest,
			Expires: time.Now().Add(time.Duration(req.Seconds) * time.Second), Interface: req.Interface, CIDR: req.CIDR, Listen: req.Listen, PeerEndpoint: req.PeerEndpoint,
			Route: req.Route, RemoteApproved: req.RemoteApproved, SourcePath: leasePath(file)}
		if err := syncthing.ValidateRoute(plan); err != nil {
			return nil, err
		}
		if _, err := hex.DecodeString(plan.ManifestHash); err != nil || len(plan.ManifestHash) != 16 {
			return nil, errors.New("approve an exact source manifest before starting sync")
		}
		if entry.Role == syncthing.ReceiveOnly && entry.Mode == syncthing.ModeFull {
			current, e := m.profile.ManifestScoped(ctx, req.Group, leasePath(file))
			if e != nil {
				return nil, e
			}
			if current.Items > 1 && current.XXH64 != req.Manifest && current.XXH64 != binding.LastManifest {
				return nil, errors.New("the destination contains unverified local data or changed since its last sync; choose an empty folder or review those changes first")
			}
		}
		var baseline projectsync.WorkingState
		if entry.Role == syncthing.ReceiveOnly && entry.Mode == syncthing.ModeNonGit {
			baseline, err = projectsync.SnapshotWorking(ctx, leasePath(file))
			if err != nil {
				return nil, err
			}
		}
		if entry.Role == syncthing.SendOnly {
			info, e := m.profile.Inspect(ctx)
			if e != nil {
				return nil, e
			}
			plan.Owner = info.DeviceID
			digest, e := m.profile.ManifestScoped(ctx, req.Group, leasePath(file))
			if e != nil {
				return nil, e
			}
			if digest.XXH64 != req.Manifest {
				return nil, errors.New("the source changed after approval")
			}
			if digest.Bytes != req.Bytes {
				return nil, errors.New("the approved byte budget does not match the source manifest")
			}
			if controller != "" {
				if e = m.store.Authorized(controller, req.Root, "read", digest.Bytes); e != nil {
					return nil, e
				}
			}
		}
		if entry.Role == syncthing.ReceiveOnly && controller != "" {
			if err := m.store.Authorized(controller, req.Root, "read", req.Bytes); err != nil {
				return nil, err
			}
		}
		m.mu.Lock()
		if err := m.ownerStopped(req.JobID); err != nil {
			m.mu.Unlock()
			return nil, err
		}
		if job, ok := m.jobs[req.JobID]; ok {
			m.mu.Unlock()
			if job.Controller != controller || job.Group != req.Group {
				return nil, storage.ErrDenied
			}
			return nil, errors.New("this sync approval was already used; inspect its job status")
		}
		if len(m.jobs) >= 128 {
			for id, old := range m.jobs {
				if old.State != "running" {
					delete(m.jobs, id)
					if name, e := m.jobPath(id); e == nil {
						_ = os.Remove(name)
					}
					break
				}
			}
			if len(m.jobs) >= 128 {
				m.mu.Unlock()
				return nil, errors.New("too many active sync jobs; stop an existing session first")
			}
		}
		jobCtx, cancel := context.WithDeadline(m.ctx, plan.Expires)
		go m.watchApproval(jobCtx, cancel, controller, req.Root, req.JobID, req.RemoteApproved)
		job := &Job{ID: req.JobID, Group: req.Group, State: "running", Controller: controller, Cancel: cancel, Done: make(chan struct{})}
		if err := m.saveJob(*job); err != nil {
			cancel()
			m.mu.Unlock()
			return nil, err
		}
		m.jobs[req.JobID] = job
		m.mu.Unlock()
		ownedFile := file
		file = nil
		go func() {
			defer ownedFile.Close()
			defer cancel()
			cleanup, runErr := openFirewall(jobCtx, req)
			var adapter *endpointTunnel
			if runErr == nil && m.SocketAdapter {
				adapter, runErr = newEndpointTunnel(jobCtx, plan.Listen, plan.PeerEndpoint)
				if runErr == nil {
					defer adapter.Close()
					plan.EngineListen = adapter.EngineListen
					plan.EnginePeerEndpoint = adapter.EnginePeer
				}
			}
			var receipt syncproviders.Receipt
			if runErr == nil {
				receipt, runErr = m.profile.Run(jobCtx, plan, approval{m: m, controller: controller, root: req.Root, plan: plan})
			}
			if adapter != nil {
				adapter.Close()
			}
			if runErr == nil && receipt.Bytes != req.Bytes {
				runErr = errors.New("the receiver data exceeded or differed from its approved byte budget")
			}
			if cleanup != nil {
				runErr = errors.Join(runErr, cleanup())
			}
			if runErr == nil && baseline != nil {
				runErr = m.profile.UseVerifiedProjection(jobCtx, req.Group, req.Manifest, func(projection string, manifest protocol.Manifest) error {
					return projectsync.ApplyWorking(jobCtx, leasePath(ownedFile), projection, manifest, baseline)
				})
			}
			if runErr == nil {
				runErr = (approval{m: m, controller: controller, root: req.Root, plan: plan}).Validate(jobCtx, plan)
			}
			if runErr == nil {
				latest, e := m.binding(req.Group)
				if e == nil {
					latest.LastManifest = req.Manifest
					e = m.saveBinding(req.Group, latest)
				}
				if e != nil {
					runErr = e
				}
			}
			m.mu.Lock()
			defer m.mu.Unlock()
			job.State = "verified"
			job.Receipt = &receipt
			if runErr != nil {
				job.State = "interrupted"
				job.Error = runErr.Error()
				job.Receipt = nil
			}
			job.Cancel = nil
			if err := m.saveJob(*job); err != nil {
				job.State = "interrupted"
				job.Error = "Sync finished but its durable result could not be saved."
			}
			close(job.Done)
		}()
		return Job{ID: job.ID, Group: job.Group, State: "running"}, nil
	default:
		return nil, errors.New("unknown sync control operation")
	}
}

func (m *Manager) Wait(ctx context.Context, id string) (Job, error) {
	m.mu.Lock()
	job, ok := m.jobs[id]
	m.mu.Unlock()
	if !ok {
		return Job{}, errors.New("unknown local job")
	}
	select {
	case <-ctx.Done():
		m.mu.Lock()
		cancel := job.Cancel
		m.mu.Unlock()
		if cancel != nil {
			cancel()
		}
		<-job.Done
	case <-job.Done:
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return *job, nil
}

type approval struct {
	m                *Manager
	controller, root string
	plan             syncproviders.Plan
}

func (a approval) Validate(ctx context.Context, plan syncproviders.Plan) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if a.plan != plan || !time.Now().Before(plan.Expires) {
		return errors.New("sync approval changed or expired")
	}
	if err := a.m.ownerStopped(plan.ID); err != nil {
		return err
	}
	return a.m.allowed(a.controller, a.root, plan.RemoteApproved)
}

func Networks() []protocol.SyncNetwork {
	result := []protocol.SyncNetwork{}
	if iface, cidr := os.Getenv("DEVICEBRIDGE_SYNC_INTERFACE"), os.Getenv("DEVICEBRIDGE_SYNC_CIDR"); iface != "" && cidr != "" {
		if prefix, err := netip.ParsePrefix(cidr); err == nil && prefix.Addr().Is4() {
			result = append(result, protocol.SyncNetwork{Interface: iface, CIDR: cidr, Kind: "lan"})
		}
	}
	interfaces, _ := net.Interfaces()
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addresses, _ := iface.Addrs()
		for _, address := range addresses {
			duplicate := false
			for _, known := range result {
				if known.Interface == iface.Name && known.CIDR == address.String() {
					duplicate = true
				}
			}
			if duplicate {
				continue
			}
			prefix, err := netip.ParsePrefix(address.String())
			if err != nil || !prefix.Addr().Is4() {
				continue
			}
			kind := "routed"
			if prefix.Addr().IsPrivate() {
				kind = "lan"
			}
			if prefix.Addr().IsLoopback() {
				kind = "loopback"
			}
			if netip.MustParsePrefix("100.64.0.0/10").Contains(prefix.Addr()) {
				kind = "tailscale"
			}
			if strings.HasPrefix(iface.Name, "wg") {
				kind = "routed"
			}
			result = append(result, protocol.SyncNetwork{Interface: iface.Name, CIDR: address.String(), Kind: kind})
		}
	}
	return result
}
