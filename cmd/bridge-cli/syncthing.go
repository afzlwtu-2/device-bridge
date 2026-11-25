package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"devicebridge/internal/projectsync"
	"devicebridge/internal/syncproviders"
	"devicebridge/internal/syncproviders/syncthing"
)

type syncOptions struct {
	mode, filter, source string
	modeSet              bool
	excludes             []string
}

func parseSyncOptions(args []string) (syncOptions, error) {
	var opts syncOptions
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--exclude":
			if i+1 >= len(args) {
				return opts, fmt.Errorf("%s needs a value", args[i])
			}
			opts.excludes = append(opts.excludes, args[i+1])
			i++
		case "--mode", "--filter", "--source":
			if i+1 >= len(args) {
				return opts, fmt.Errorf("%s needs a value", args[i])
			}
			value := args[i+1]
			switch args[i] {
			case "--mode":
				opts.mode, opts.modeSet = value, true
			case "--filter":
				opts.filter = value
			case "--source":
				opts.source = value
			}
			i++
		default:
			return opts, fmt.Errorf("unknown sync option %s", args[i])
		}
	}
	return opts, nil
}

type terminalSyncApproval struct {
	plan syncproviders.Plan
}

func (a terminalSyncApproval) Validate(ctx context.Context, plan syncproviders.Plan) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if a.plan != plan || !time.Now().Before(plan.Expires) {
		return errors.New("the local Sync approval changed or expired")
	}
	return nil
}

func runSyncthing(args []string, state, iface, cidr string, approved bool) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	profile := syncthing.Open(state)
	if len(args) == 0 {
		return errors.New("syncthing status|prepare|register|mode|build|forget|manifest|run")
	}
	switch args[0] {
	case "status", "prepare":
		if len(args) != 1 {
			return errors.New("syncthing status|prepare")
		}
		var info syncthing.Info
		var err error
		if args[0] == "prepare" {
			info, err = profile.Prepare(ctx)
		} else {
			info, err = profile.Inspect(ctx)
		}
		if err != nil {
			return err
		}
		groups, err := profile.List()
		if err != nil {
			return err
		}
		return output(struct {
			syncthing.Info
			Registered []syncthing.Registration `json:"registered"`
		}{info, groups})
	case "register":
		if len(args) < 4 {
			return errors.New("syncthing register GROUP PEER_SYNCTHING_ID sendonly|receiveonly [--mode non-git|full] [--filter untracked|working] [--source PATH] [--exclude REL_PATH]…")
		}
		opts, err := parseSyncOptions(args[4:])
		if err != nil {
			return err
		}
		if _, err := profile.Register(ctx, args[1], args[2], args[3], opts.mode, opts.filter, opts.source); err != nil {
			return err
		}
		registration, err := profile.SetExcludes(args[1], opts.excludes)
		if err != nil {
			return err
		}
		return output(registration)
	case "mode":
		if len(args) < 2 {
			return errors.New("syncthing mode GROUP --mode non-git|full [--filter untracked|working] [--source PATH] [--exclude REL_PATH]…")
		}
		opts, err := parseSyncOptions(args[2:])
		if err != nil {
			return err
		}
		if !opts.modeSet {
			return errors.New("specify the new sync mode with --mode")
		}
		if _, err := profile.SetMode(args[1], opts.mode, opts.filter, opts.source); err != nil {
			return err
		}
		entry, err := profile.SetExcludes(args[1], opts.excludes)
		if err != nil {
			return err
		}
		return output(entry)
	case "build":
		if len(args) < 3 || len(args) > 4 {
			return errors.New("syncthing build GROUP WORKTREE [--snapshot]")
		}
		snapshot := len(args) == 4
		if snapshot && args[3] != "--snapshot" {
			return errors.New("syncthing build GROUP WORKTREE [--snapshot]")
		}
		entry, err := profile.Registration(args[1])
		if err != nil {
			return err
		}
		if entry.Mode != syncthing.ModeNonGit || entry.Filter != syncthing.FilterWorking {
			return errors.New("build applies to a non-git registration with the working filter")
		}
		staged, err := profile.ReplaceProjection(ctx, args[1], snapshot, func(path string) error {
			_, err := projectsync.BuildWorking(ctx, args[2], path)
			return err
		})
		if err != nil {
			return err
		}
		return output(staged)
	case "forget":
		if len(args) != 2 {
			return errors.New("syncthing forget GROUP")
		}
		if err := profile.Unregister(args[1]); err != nil {
			return err
		}
		return output(map[string]string{"status": "unregistered", "group": args[1]})
	case "manifest":
		if len(args) != 2 {
			return errors.New("syncthing manifest GROUP")
		}
		digest, err := profile.Digest(ctx, args[1])
		if err != nil {
			return err
		}
		return output(digest)
	case "run":
		if len(args) < 5 || len(args) > 6 || !approved {
			return errors.New("use --approve-sync syncthing run GROUP LOCAL_IP:PORT PEER_IP:PORT MANIFEST_XXH64 [DURATION]")
		}
		duration := 5 * time.Minute
		if len(args) == 6 {
			var err error
			duration, err = time.ParseDuration(args[5])
			if err != nil || duration < time.Second || duration > 15*time.Minute {
				return errors.New("choose a session duration from one second to 15 minutes")
			}
		}
		entry, err := profile.Registration(args[1])
		if err != nil {
			return err
		}
		if entry.BridgePeer != "" && entry.Mode != syncthing.ModeFull && entry.Filter != syncthing.FilterWorking {
			return errors.New("use project run for this project's signed revision")
		}
		info, err := profile.Inspect(ctx)
		if err != nil {
			return err
		}
		if !info.Prepared {
			return errors.New("prepare the managed Syncthing profile first")
		}
		owner := info.DeviceID
		if entry.Role == syncthing.ReceiveOnly {
			owner = entry.PeerID
		}
		plan, err := makeSyncPlan(entry.Group, owner, args[4], iface, cidr, args[2], args[3], duration)
		if err != nil {
			return err
		}
		receipt, err := runApprovedSync(ctx, profile, plan, terminalSyncApproval{plan})
		if err != nil {
			return err
		}
		return output(receipt)
	default:
		return errors.New("unknown Syncthing operation")
	}
}

func makeSyncPlan(group, owner, digest, iface, cidr, local, peer string, duration time.Duration) (syncproviders.Plan, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return syncproviders.Plan{}, err
	}
	return syncproviders.Plan{
		ID: hex.EncodeToString(nonce[:]), Group: group, Owner: owner,
		ManifestHash: strings.ToLower(digest), Expires: time.Now().Add(duration),
		Interface: iface, CIDR: cidr, Listen: local, PeerEndpoint: peer,
	}, nil
}

func runApprovedSync(ctx context.Context, profile syncthing.Profile, plan syncproviders.Plan, approval syncproviders.Approval) (syncproviders.Receipt, error) {
	registry := &syncproviders.Registry{}
	if err := registry.Register(profile); err != nil {
		return syncproviders.Receipt{}, err
	}
	engine, _ := registry.Get(syncthing.EngineID)
	return engine.Run(ctx, plan, approval)
}
