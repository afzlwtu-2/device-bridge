package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	"devicebridge/internal/auth"
	"devicebridge/internal/discovery"
	"devicebridge/internal/projectsync"
	"devicebridge/internal/storage"
	"devicebridge/internal/syncproviders"
	"devicebridge/internal/syncproviders/syncthing"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/protocol"

	"golang.org/x/sys/unix"
)

var projectGroup = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

type projectCommands struct {
	state                 string
	journal               projectsync.Journal
	profile               syncthing.Profile
	iface, cidr, endpoint string
}

func runProject(args []string, state string, store *storage.Store, id *auth.Identity, iface, cidr, endpoint string, approved bool) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if len(args) == 0 {
		return errors.New("project preflight|stage|bind|status|export|prepare|follow|run|import|offer|accept|finalize|reject|cancel")
	}
	project := projectCommands{
		state: state, journal: projectsync.Journal{Store: store, Identity: id},
		profile: syncthing.Open(state), iface: iface, cidr: cidr, endpoint: endpoint,
	}
	switch args[0] {
	case "preflight":
		if len(args) != 2 {
			return errors.New("project preflight WORKTREE")
		}
		_, evidence, err := projectsync.Preflight(ctx, args[1])
		if err != nil {
			return err
		}
		return output(evidence)
	case "stage":
		if len(args) < 4 {
			return errors.New("project stage WORKTREE NEW_PROJECTION APPROVED_PATH...")
		}
		projection, err := projectsync.Build(ctx, args[1], args[2], args[3:])
		if err != nil {
			return err
		}
		return output(projection)
	case "follow", "accept", "finalize", "reject":
		return project.receive(ctx, args)
	case "cancel":
		return project.cancel(ctx, args)
	}
	if len(args) < 2 || !projectGroup.MatchString(args[1]) {
		return errors.New("provide a registered project group ID")
	}
	group := args[1]
	if args[0] == "status" || args[0] == "export" {
		current, err := project.journal.State(ctx, group)
		if err != nil {
			return err
		}
		if args[0] == "export" {
			return output(current)
		}
		return output(struct {
			Revision projectsync.Revision `json:"revision"`
			Writable bool                 `json:"writable"`
			Handoff  bool                 `json:"handoff_pending"`
		}{current.Current(), current.CanWrite(id.ID), current.Pending != nil})
	}
	lock, err := project.lock(group)
	if err != nil {
		return err
	}
	defer lock.Close()
	switch args[0] {
	case "bind":
		if len(args) != 3 {
			return errors.New("project bind GROUP PAIRED_DEVICEBRIDGE_ID")
		}
		if err := project.checkPair(args[2]); err != nil {
			return err
		}
		entry, err := project.profile.BindProject(group, args[2])
		if err != nil {
			return err
		}
		return output(entry)
	case "prepare":
		if len(args) < 4 {
			return errors.New("project prepare GROUP WORKTREE [--snapshot] APPROVED_PATH...")
		}
		return project.prepare(ctx, group, args[2], args[3:])
	case "offer":
		if len(args) != 3 {
			return errors.New("project offer GROUP WORKTREE")
		}
		entry, err := project.bound(group)
		if err != nil {
			return err
		}
		if entry.Mode == syncthing.ModeFull || entry.Filter == syncthing.FilterWorking {
			return errors.New("ownership handoff applies to the signed untracked project projection")
		}
		_, git, err := projectsync.Preflight(ctx, args[2])
		if err != nil {
			return err
		}
		digest, err := project.profile.Digest(ctx, group)
		if err != nil {
			return err
		}
		if err := project.verifyPeer(ctx, entry.BridgePeer); err != nil {
			return err
		}
		offer, err := project.journal.Offer(ctx, group, entry.BridgePeer, git, digest.XXH64)
		if err != nil {
			return err
		}
		return output(offer)
	case "run":
		if len(args) != 5 || !approved {
			return errors.New("use --approve-sync project run GROUP WORKTREE LOCAL_IP:PORT PEER_IP:PORT")
		}
		return project.run(ctx, group, args[2], iface, cidr, args[3], args[4])
	case "import":
		if len(args) < 4 {
			return errors.New("project import GROUP WORKTREE APPROVED_PATH...")
		}
		return project.apply(ctx, group, args[2], args[3:])
	default:
		return errors.New("unknown project operation")
	}
}

func (p projectCommands) lock(group string) (*os.File, error) {
	file, err := os.OpenFile(filepath.Join(p.state, ".project-"+group+".lock"), os.O_RDWR|os.O_CREATE|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		file.Close()
		return nil, errors.New("a project operation is already active")
	}
	return file, nil
}

func (p projectCommands) checkPair(remote string) error {
	peer, err := p.journal.Store.Peer(remote)
	if err != nil || peer.Status != "paired" {
		return errors.New("pair with the other DeviceBridge device first")
	}
	return nil
}

func (p projectCommands) verifyPeer(ctx context.Context, remote string) error {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	lan, err := direct.NewCIDR(p.iface, p.cidr)
	if err != nil {
		return errors.New("select the reachable direct LAN before handing off a project")
	}
	lan.Discovery = func(ctx context.Context) ([]transport.Candidate, error) {
		return discovery.Browse(ctx, lan)
	}
	link := &command{
		ctx: ctx, identity: p.journal.Identity, state: p.journal.Store,
		provider: lan, selectedTransport: "lan", endpoint: p.endpoint,
	}
	client, _, err := link.connect(remote, true)
	if err != nil {
		return errors.Join(errors.New("the paired project peer needs to be reachable for a new handoff"), err)
	}
	client.Close()
	return nil
}

func (p projectCommands) bound(group string) (syncthing.Registration, error) {
	entry, err := p.profile.Registration(group)
	if err != nil {
		return entry, err
	}
	if entry.BridgePeer == "" {
		return entry, errors.New("bind this group to its paired DeviceBridge peer first")
	}
	return entry, p.checkPair(entry.BridgePeer)
}

func (p projectCommands) prepare(ctx context.Context, group, worktree string, names []string) error {
	entry, err := p.bound(group)
	if err != nil {
		return err
	}
	if entry.Mode == syncthing.ModeFull || entry.Filter == syncthing.FilterWorking {
		return errors.New("full and working-folder sync use syncthing build/run, not the signed project projection")
	}
	current, err := p.journal.State(ctx, group)
	if err != nil && !errors.Is(err, projectsync.ErrNotRegistered) {
		return err
	}
	first := errors.Is(err, projectsync.ErrNotRegistered)
	if (!first && !current.CanWrite(p.journal.Identity.ID)) || (first && entry.Role != syncthing.SendOnly) {
		return projectsync.ErrReadOnly
	}
	snapshot := len(names) > 0 && names[0] == "--snapshot"
	if snapshot {
		names = names[1:]
	}
	var projection projectsync.Projection
	staged, err := p.profile.ReplaceProjection(ctx, group, snapshot, func(path string) error {
		var err error
		projection, err = projectsync.Build(ctx, worktree, path, names)
		return err
	})
	if err != nil {
		return err
	}
	if first {
		current, err = p.journal.Initialize(ctx, group, projection.Git, staged.XXH64)
	} else {
		current, err = p.journal.Advance(ctx, group, projection.Git, staged.XXH64)
	}
	if err != nil {
		return err
	}
	return output(struct {
		projectsync.JournalState
		Snapshot string `json:"snapshot,omitempty"`
	}{current, staged.Snapshot})
}

func readProjectJSON(result any) error {
	data, err := io.ReadAll(io.LimitReader(os.Stdin, projectsync.MaxChainBytes+1))
	if err != nil {
		return err
	}
	if len(data) > projectsync.MaxChainBytes {
		return errors.New("project revision bundle exceeds the supported size")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(result); err != nil || decoder.Decode(new(any)) != io.EOF {
		return errors.New("invalid project revision bundle")
	}
	return nil
}

func (p projectCommands) apply(ctx context.Context, group, worktree string, approved []string) error {
	entry, err := p.bound(group)
	if err != nil {
		return err
	}
	current, err := p.journal.State(ctx, group)
	if err != nil {
		return err
	}
	revision := current.Current()
	if current.Pending != nil || (revision.Owner != entry.BridgePeer && revision.Owner != p.journal.Identity.ID) {
		return projectsync.ErrReadOnly
	}
	var receipt projectsync.ImportReceipt
	err = p.profile.UseVerifiedProjection(ctx, group, revision.Manifest, func(source string, manifest protocol.Manifest) error {
		var applyErr error
		receipt, applyErr = projectsync.Apply(ctx, worktree, source, manifest, revision, approved)
		return applyErr
	})
	if err != nil {
		return err
	}
	return output(receipt)
}

func (p projectCommands) receive(ctx context.Context, args []string) error {
	want := 2
	if args[0] == "accept" {
		want = 3
	}
	if len(args) != want || args[len(args)-1] != "-" {
		return errors.New("project follow - | project accept WORKTREE - | project finalize - | project reject -")
	}
	var bundle struct {
		projectsync.JournalState
		Snapshot string `json:"snapshot,omitempty"`
	}
	if err := readProjectJSON(&bundle); err != nil {
		return err
	}
	incoming := bundle.JournalState
	if err := incoming.Validate(); err != nil {
		return err
	}
	group := incoming.Current().Group
	lock, err := p.lock(group)
	if err != nil {
		return err
	}
	defer lock.Close()
	entry, err := p.bound(group)
	if err != nil {
		return err
	}
	var state projectsync.JournalState
	switch args[0] {
	case "follow":
		if incoming.Current().Owner != entry.BridgePeer {
			return errors.New("the revision owner differs from this project's paired peer")
		}
		state, err = p.journal.Follow(ctx, incoming)
	case "accept":
		if incoming.Current().Owner != entry.BridgePeer {
			return errors.New("the current owner differs from this project's paired peer")
		}
		_, git, preErr := projectsync.Preflight(ctx, args[1])
		if preErr != nil {
			return preErr
		}
		digest, digestErr := p.profile.Digest(ctx, group)
		if digestErr != nil {
			return digestErr
		}
		if incoming.Pending == nil {
			return errors.New("a pending signed handoff is required")
		}
		local, localErr := p.journal.State(ctx, group)
		if localErr != nil || local.Current().Hash() != incoming.Pending.Revision.Hash() {
			if err := p.verifyPeer(ctx, entry.BridgePeer); err != nil {
				return err
			}
		}
		state, err = p.journal.Accept(ctx, incoming, git, digest.XXH64)
	case "finalize":
		state, err = p.journal.Finalize(ctx, incoming)
	case "reject":
		if incoming.Current().Owner != entry.BridgePeer {
			return errors.New("the current owner differs from this project's paired peer")
		}
		rejection, err := p.journal.Reject(ctx, incoming)
		if err != nil {
			return err
		}
		return output(rejection)
	}
	if err != nil {
		return err
	}
	return output(state)
}

func (p projectCommands) cancel(ctx context.Context, args []string) error {
	if len(args) != 2 || args[1] != "-" {
		return errors.New("project cancel - (reads the other device's signed rejection)")
	}
	var rejection projectsync.Rejection
	if err := readProjectJSON(&rejection); err != nil {
		return err
	}
	if !projectGroup.MatchString(rejection.Group) {
		return errors.New("invalid project group ID")
	}
	lock, err := p.lock(rejection.Group)
	if err != nil {
		return err
	}
	defer lock.Close()
	if _, err := p.bound(rejection.Group); err != nil {
		return err
	}
	state, err := p.journal.Cancel(ctx, rejection)
	if err != nil {
		return err
	}
	return output(state)
}

type revisionSyncApproval struct {
	terminalSyncApproval
	project  projectCommands
	revision string
}

func (a revisionSyncApproval) Validate(ctx context.Context, plan syncproviders.Plan) error {
	if err := a.terminalSyncApproval.Validate(ctx, plan); err != nil {
		return err
	}
	current, err := a.project.journal.State(ctx, plan.Group)
	if err != nil {
		return err
	}
	if current.Pending != nil || current.Current().Hash() != a.revision {
		return errors.New("the approved project revision changed or a handoff is pending")
	}
	_, err = a.project.bound(plan.Group)
	return err
}

func (p projectCommands) run(ctx context.Context, group, worktree, iface, cidr, local, remote string) error {
	entry, err := p.bound(group)
	if err != nil {
		return err
	}
	if entry.Mode == syncthing.ModeFull || entry.Filter == syncthing.FilterWorking {
		return errors.New("full and working-folder sync use syncthing run with an approved manifest")
	}
	current, err := p.journal.State(ctx, group)
	if err != nil {
		return err
	}
	r := current.Current()
	_, git, err := projectsync.Preflight(ctx, worktree)
	if err != nil {
		return err
	}
	if current.Pending != nil || r.Branch != git.Branch || r.Head != git.Head {
		return errors.New("resolve the ownership handoff and match the approved Git branch and HEAD")
	}
	role := syncthing.ReceiveOnly
	if current.CanWrite(p.journal.Identity.ID) {
		role = syncthing.SendOnly
	} else if r.Owner != entry.BridgePeer {
		return projectsync.ErrReadOnly
	}
	entry, err = p.profile.SetProjectRole(group, role)
	if err != nil {
		return err
	}
	info, err := p.profile.Inspect(ctx)
	if err != nil || !info.Prepared {
		return errors.Join(errors.New("prepare the local Syncthing profile before syncing"), err)
	}
	engineOwner := entry.PeerID
	if role == syncthing.SendOnly {
		engineOwner = info.DeviceID
	}
	plan, err := makeSyncPlan(group, engineOwner, r.Manifest, iface, cidr, local, remote, 5*time.Minute)
	if err != nil {
		return err
	}
	plan.Epoch = r.Epoch
	receipt, err := runApprovedSync(ctx, p.profile, plan, revisionSyncApproval{terminalSyncApproval{plan}, p, r.Hash()})
	if err != nil {
		return err
	}
	return output(receipt)
}
