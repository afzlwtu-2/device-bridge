package syncthing

import (
	"context"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"devicebridge/internal/syncproviders"
	"devicebridge/internal/transport/direct"
)

const EngineID = "syncthing"

func (Profile) ID() string   { return EngineID }
func (Profile) Version() int { return syncproviders.ContractVersion }

type deviceConfig struct {
	ID         string   `json:"deviceID"`
	Addresses  []string `json:"addresses"`
	Networks   []string `json:"allowedNetworks"`
	Paused     bool     `json:"paused"`
	AutoAccept bool     `json:"autoAcceptFolders"`
	Introducer bool     `json:"introducer"`
}

type folderDevice struct {
	ID string `json:"deviceID"`
}

type folderConfig struct {
	ID      string         `json:"id"`
	Label   string         `json:"label"`
	Path    string         `json:"path"`
	Type    string         `json:"type"`
	Devices []folderDevice `json:"devices"`
	Paused  bool           `json:"paused"`
	// Android shared storage cannot preserve POSIX permissions. Content hashes,
	// scopes and ownership remain verified independently by DeviceBridge.
	IgnorePerms bool           `json:"ignorePerms"`
	Versioning  map[string]any `json:"versioning"`
}

func (p Profile) Run(ctx context.Context, plan syncproviders.Plan, approval syncproviders.Approval) (syncproviders.Receipt, error) {
	var receipt syncproviders.Receipt
	if approval == nil || plan.ID == "" || time.Until(plan.Expires) <= 0 || time.Until(plan.Expires) > 15*time.Minute {
		return receipt, errors.New("a live Sync approval of at most 15 minutes is required")
	}
	if _, err := hex.DecodeString(plan.ManifestHash); err != nil || len(plan.ManifestHash) != 16 {
		return receipt, errors.New("the approval needs an expected manifest XXH64")
	}
	local, remote, err := sessionRoute(plan)
	if err != nil {
		return receipt, err
	}
	if err := approval.Validate(ctx, plan); err != nil {
		return receipt, err
	}
	ctx, cancel := context.WithDeadline(ctx, plan.Expires)
	defer cancel()
	listen := "tcp4://" + local.String()
	engineRemote := remote.Addr()
	enginePeerEndpoint := remote.String()
	if plan.EngineListen != "" || plan.EnginePeerEndpoint != "" {
		inside, e1 := netip.ParseAddrPort(plan.EngineListen)
		outside, e2 := netip.ParseAddrPort(plan.EnginePeerEndpoint)
		if e1 != nil || e2 != nil || !inside.Addr().IsLoopback() || !outside.Addr().IsLoopback() || inside.Port() == 0 || outside.Port() == 0 {
			return receipt, errors.New("invalid host-owned sync socket adapter")
		}
		listen = "tcp4://" + inside.String()
		engineRemote = outside.Addr()
		enginePeerEndpoint = outside.String()
	}
	err = p.withDaemon(ctx, listen, func(ctx context.Context, api *restClient, selfID string) (sessionErr error) {
		entry, err := p.Registration(plan.Group)
		if err != nil {
			return err
		}
		if entry.Mode == ModeFull {
			source := entry.Source
			if plan.SourcePath != "" {
				source = plan.SourcePath
			}
			entry.Path, err = p.setLeaseAlias(entry.Group, source)
			if err != nil {
				return err
			}
		}
		owner := selfID
		if entry.Role == ReceiveOnly {
			owner = entry.PeerID
		}
		if owner != plan.Owner || selfID == entry.PeerID {
			return errors.New("the approved owner does not match the local registration")
		}
		digest, err := digestFor(ctx, entry)
		if err != nil {
			return err
		}
		if entry.Role == SendOnly && digest.XXH64 != plan.ManifestHash {
			return errors.New("the source projection changed after approval")
		}
		if err := p.saveRegistration(entry, "running"); err != nil {
			return err
		}
		defer func() {
			state := "paused"
			if sessionErr != nil {
				state = "interrupted"
			}
			sessionErr = errors.Join(sessionErr, p.saveRegistration(entry, state))
		}()
		// Mirror the verified exclusions into the engine so excluded subtrees
		// are neither sent nor pulled. The managed .stignore is trusted by the
		// digest only because it matches these exact exclusions.
		if len(entry.Excludes) > 0 {
			if err := os.WriteFile(filepath.Join(entry.Path, ".stignore"), []byte(managedIgnoreContent(entry.Excludes)), 0600); err != nil {
				return err
			}
		}
		device := deviceConfig{
			ID: entry.PeerID, Paused: true,
			Addresses: []string{"tcp4://" + enginePeerEndpoint},
			Networks:  []string{netip.PrefixFrom(engineRemote, 32).String()},
		}
		folder := folderConfig{
			ID: entry.engineFolderID(), Label: entry.Group, Path: entry.Path, Type: entry.Role, Paused: true,
			Devices: []folderDevice{{ID: selfID}, {ID: entry.PeerID}}, IgnorePerms: true,
			Versioning: map[string]any{"type": "simple", "params": map[string]string{"keep": "5", "cleanoutDays": "0"}},
		}
		if err := api.call(ctx, http.MethodPost, "/rest/config/devices", device, nil); err != nil {
			return err
		}
		if err := api.call(ctx, http.MethodPost, "/rest/config/folders", folder, nil); err != nil {
			return err
		}
		if err := api.checkPolicy(ctx, listen); err != nil {
			return err
		}
		folderPath, peerPath := "/rest/config/folders/"+entry.engineFolderID(), "/rest/config/devices/"+entry.PeerID
		pause := func() error {
			limited, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			return errors.Join(
				api.call(limited, http.MethodPatch, folderPath, map[string]bool{"paused": true}, nil),
				api.call(limited, http.MethodPatch, peerPath, map[string]bool{"paused": true}, nil),
			)
		}
		defer func() {
			if sessionErr != nil {
				sessionErr = errors.Join(sessionErr, pause())
			}
		}()
		if err := approval.Validate(ctx, plan); err != nil {
			return err
		}
		if err := api.call(ctx, http.MethodPatch, folderPath, map[string]bool{"paused": false}, nil); err != nil {
			return err
		}
		if err := api.call(ctx, http.MethodPatch, peerPath, map[string]bool{"paused": false}, nil); err != nil {
			return err
		}
		if err := api.waitForProjection(ctx, entry, plan, engineRemote, approval); err != nil {
			return err
		}
		if err := pause(); err != nil {
			return err
		}
		final, err := digestFor(ctx, entry)
		if err != nil || final.XXH64 != plan.ManifestHash {
			return errors.Join(errors.New("the paused folder did not match the approved manifest"), err)
		}
		receipt = syncproviders.Receipt{Group: entry.Group, Role: entry.Role, Activity: "paused", Digest: final}
		return nil
	})
	return receipt, err
}

func sessionRoute(plan syncproviders.Plan) (netip.AddrPort, netip.AddrPort, error) {
	var zero netip.AddrPort
	if plan.Route == "routed" || plan.Route == "tailscale" {
		if !plan.RemoteApproved {
			return zero, zero, errors.New("approve remote bulk sync on both endpoints before using a routed connection")
		}
		local, e1 := netip.ParseAddrPort(plan.Listen)
		remote, e2 := netip.ParseAddrPort(plan.PeerEndpoint)
		prefix, e3 := netip.ParsePrefix(plan.CIDR)
		if e1 != nil || e2 != nil || e3 != nil || local == remote || local.Port() == 0 || remote.Port() == 0 || local.Addr() != prefix.Addr() || !local.Addr().Is4() || !remote.Addr().Is4() || !remote.Addr().IsGlobalUnicast() || remote.Addr().IsLoopback() {
			return zero, zero, errors.New("invalid direct endpoint-to-endpoint sync route")
		}
		if plan.Route == "tailscale" {
			tailnet := netip.MustParsePrefix("100.64.0.0/10")
			if !tailnet.Contains(local.Addr()) || !tailnet.Contains(remote.Addr()) {
				return zero, zero, errors.New("Tailscale sync needs two tailnet addresses")
			}
		}
		iface, err := net.InterfaceByName(plan.Interface)
		if err != nil || iface.Flags&net.FlagUp == 0 {
			return zero, zero, errors.New("the approved sync interface is unavailable")
		}
		addresses, err := iface.Addrs()
		if err != nil {
			return zero, zero, err
		}
		for _, address := range addresses {
			if address.String() == plan.CIDR {
				return local, remote, nil
			}
		}
		return zero, zero, errors.New("the approved sync address changed")
	}
	lan, err := direct.NewCIDR(plan.Interface, plan.CIDR)
	if err != nil {
		return zero, zero, err
	}
	local, err := netip.ParseAddrPort(plan.Listen)
	if err != nil || local.Port() == 0 || local.Addr() != lan.Address {
		return zero, zero, errors.New("listen on the selected private LAN address and a fixed port")
	}
	if err := lan.Check(plan.PeerEndpoint); err != nil {
		return zero, zero, err
	}
	remote, err := netip.ParseAddrPort(plan.PeerEndpoint)
	if err != nil || remote == local || remote.Addr().IsLoopback() != local.Addr().IsLoopback() {
		return zero, zero, errors.New("use a distinct peer endpoint on the same approved LAN")
	}
	iface, err := net.InterfaceByName(plan.Interface)
	if runtime.GOOS == "android" && os.Getenv("DEVICEBRIDGE_SYNC_INTERFACE") == plan.Interface && os.Getenv("DEVICEBRIDGE_SYNC_CIDR") == plan.CIDR {
		return local, remote, nil
	}
	if err != nil || iface.Flags&net.FlagUp == 0 {
		return zero, zero, errors.New("the approved network interface is unavailable")
	}
	addresses, err := iface.Addrs()
	if err != nil {
		return zero, zero, err
	}
	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err == nil && prefix.Addr() == local.Addr() && prefix.Masked() == lan.Prefix {
			return local, remote, nil
		}
	}
	return zero, zero, errors.New("the approved LAN address changed")
}

func ValidateRoute(plan syncproviders.Plan) error { _, _, err := sessionRoute(plan); return err }

func (c *restClient) waitForProjection(ctx context.Context, entry Registration, plan syncproviders.Plan, remote netip.Addr, approval syncproviders.Approval) error {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	stable := 0
	receiverConnected := false
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
		}
		if err := approval.Validate(ctx, plan); err != nil {
			return err
		}
		if _, _, err := sessionRoute(plan); err != nil {
			return err
		}
		connected, ready, err := c.quiescent(ctx, entry, remote)
		if err != nil {
			return err
		}
		if entry.Role == ReceiveOnly {
			if connected {
				receiverConnected = true
				continue
			}
			if receiverConnected {
				receiverConnected = false
				// A sender can pause before a slow receiver polls the remote
				// state. A disconnected receiver proves completion from disk.
				digest, err := digestFor(ctx, entry)
				if err == nil && digest.XXH64 == plan.ManifestHash {
					return nil
				}
			}
			continue
		}
		if !ready {
			stable = 0
			continue
		}
		stable++
		if stable >= 3 {
			return nil
		}
	}
}

func (c *restClient) quiescent(ctx context.Context, entry Registration, remote netip.Addr) (connected, ready bool, err error) {
	var peers struct {
		Connections map[string]struct {
			Connected bool   `json:"connected"`
			Address   string `json:"address"`
			Type      string `json:"type"`
		} `json:"connections"`
	}
	if err := c.call(ctx, http.MethodGet, "/rest/system/connections", nil, &peers); err != nil {
		return false, false, err
	}
	peer := peers.Connections[entry.PeerID]
	if !peer.Connected {
		return false, false, nil
	}
	address, err := netip.ParseAddrPort(peer.Address)
	kind := strings.ToLower(peer.Type)
	if err != nil || address.Addr() != remote || !strings.HasPrefix(kind, "tcp") {
		return true, false, errors.New("Syncthing connected outside the approved direct TCP address")
	}
	query := url.Values{"folder": {entry.engineFolderID()}}
	var local struct {
		State      string `json:"state"`
		Need       *int   `json:"needTotalItems"`
		PullErrors int    `json:"pullErrors"`
	}
	if err := c.call(ctx, http.MethodGet, "/rest/db/status?"+query.Encode(), nil, &local); err != nil {
		return true, false, err
	}
	if local.PullErrors > 0 {
		return true, false, errors.New("Syncthing could not complete the projection")
	}
	if local.State != "idle" || local.Need == nil || *local.Need != 0 {
		return true, false, nil
	}
	query.Set("device", entry.PeerID)
	var complete struct {
		State   string  `json:"remoteState"`
		Percent float64 `json:"completion"`
		Need    *int    `json:"needItems"`
		Deletes int     `json:"needDeletes"`
	}
	if err := c.call(ctx, http.MethodGet, "/rest/db/completion?"+query.Encode(), nil, &complete); err != nil {
		return true, false, err
	}
	return true, complete.State == "valid" && complete.Percent == 100 &&
		complete.Need != nil && *complete.Need == 0 && complete.Deletes == 0, nil
}

func (p Profile) Unregister(group string) error {
	lock, err := p.lock()
	if err != nil {
		return err
	}
	defer lock.Close()
	entry, err := p.Registration(group)
	if err != nil {
		return err
	}
	if entry.BridgePeer != "" {
		return errors.New("the project ownership record still uses this registration")
	}
	return os.Remove(filepath.Join(p.dir, "folders", entry.Group+".json"))
}
