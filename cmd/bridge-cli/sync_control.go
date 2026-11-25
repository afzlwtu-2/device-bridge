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
	"syscall"

	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/internal/synccontrol"
	"devicebridge/protocol"
)

func readSyncControl() (protocol.SyncControl, error) {
	var request protocol.SyncControl
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, 4097))
	if err != nil || len(raw) > 4096 {
		return request, errors.New("sync control metadata exceeds its size limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || decoder.Decode(new(any)) != io.EOF {
		return request, errors.New("invalid bounded sync control metadata")
	}
	return request, nil
}

func localSyncControl(state string, store *storage.Store, args []string, approved bool) error {
	if len(args) != 2 || args[1] != "-" {
		return errors.New("invalid local sync request")
	}
	request, err := readSyncControl()
	if err != nil {
		return err
	}
	if request.Operation == "start" && !approved {
		return errors.New("approve the sync session in the app first")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	manager := synccontrol.New(ctx, state, store, &filesproviders.Registry{})
	manager.WorkerProcess = true
	result, err := manager.Handle(ctx, "", request)
	if err != nil {
		return err
	}
	if request.Operation == "start" {
		result, err = manager.Wait(ctx, request.JobID)
	}
	if err != nil {
		return err
	}
	return output(result)
}

func delegatedSyncControl(state string, store *storage.Store, args []string) error {
	if len(args) != 3 || args[2] != "-" {
		return errors.New("invalid scoped sync worker request")
	}
	request, err := readSyncControl()
	if err != nil {
		return err
	}
	registry := &filesproviders.Registry{}
	defer registry.Close()
	exports, err := store.Exports()
	if err != nil {
		return err
	}
	for _, export := range exports {
		if filepath.IsAbs(export.Path) {
			if provider, e := filesproviders.NewNative(export.ID, export.Path); e == nil {
				_ = registry.Register(provider)
			}
		}
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	manager := synccontrol.New(ctx, state, store, registry)
	manager.WorkerProcess = true
	result, err := manager.Handle(ctx, args[1], request)
	if err != nil {
		return err
	}
	if err = output(result); err != nil {
		return err
	}
	if request.Operation == "start" {
		job, err := manager.Wait(ctx, request.JobID)
		if err != nil {
			return err
		}
		return output(job)
	}
	return nil
}

func stopOwnedSync(state string, store *storage.Store, args []string) error {
	if len(args) > 2 {
		return errors.New("invalid local sync stop")
	}
	group := ""
	if len(args) == 2 {
		group = args[1]
	}
	manager := synccontrol.New(context.Background(), state, store, &filesproviders.Registry{})
	count, err := manager.StopOwnedJobs(group)
	if err != nil {
		return err
	}
	return output(map[string]int{"stopping": count})
}

func localSyncPairs(store *storage.Store, args []string) error {
	if len(args) == 1 {
		pairs, err := store.SyncPairs()
		if err != nil {
			return err
		}
		return output(pairs)
	}
	if len(args) == 3 && args[1] == "forget" {
		if err := store.ForgetSyncPair(args[2]); err != nil {
			return err
		}
		return output(map[string]string{"state": "forgotten"})
	}
	if len(args) != 3 || args[1] != "save" || args[2] != "-" {
		return errors.New("invalid folder sync registry action")
	}
	var pair protocol.SyncPair
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, 8193))
	if err != nil || len(raw) > 8192 {
		return errors.New("folder sync registration exceeds its size limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&pair) != nil || decoder.Decode(new(any)) != io.EOF {
		return errors.New("invalid folder sync registration")
	}
	if err := store.SaveSyncPair(pair); err != nil {
		return err
	}
	return output(pair)
}
