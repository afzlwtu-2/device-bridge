package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"devicebridge/internal/client"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/transfer"
	"devicebridge/protocol"
)

func pushTermuxFiles(ctx context.Context, cl *client.Client, args []string) error {
	if len(args) < 6 || (args[5] != "copy" && args[5] != "move") || filesproviders.ValidPath(args[3]) != nil {
		return errors.New("file-push PEER ROOT DESTINATION LOCAL_PATH copy|move [EXCLUSION...]")
	}
	source, err := filepath.Abs(args[4])
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	provider, err := filesproviders.NewNative("files", filepath.Dir(source))
	if err != nil {
		return err
	}
	defer provider.Close()
	name := filepath.Base(source)
	allow := func(int64) error { return nil }
	manifest, err := files.Manifest(ctx, provider, name, allow, args[6:]...)
	if err != nil {
		return err
	}
	expectedContent := files.ContentXXH64(manifest)
	// The archive already omits exclusions. Its receipt describes the exact
	// received tree, without any sender-side paths or file exclusions.
	packet := manifest
	packet.Path, packet.Excludes = ".", nil
	frame, expected, err := transfer.EncodeManagedTree(name, packet)
	if err != nil {
		return err
	}
	payload, pipe := io.Pipe()
	written := make(chan struct{})
	go func() {
		defer close(written)
		_, err := pipe.Write(frame)
		if err == nil {
			progress := &fileSendProgress{total: expected.Size}
			err = transfer.WriteTar(ctx, provider, name, "none", pipe, func(n int64) error {
				if n > progress.total-progress.sent {
					return errors.New("source changed during the copy")
				}
				progress.record(n)
				return nil
			}, manifest.Excludes...)
		}
		_ = pipe.CloseWithError(err)
	}()
	var receipt transfer.SharedFolder
	err = cl.SendManagedTree(ctx, args[2], args[3], name, payload, &receipt)
	_ = payload.Close()
	<-written
	if err != nil {
		return err
	}
	if receipt != expected {
		return errors.New("Termux returned an unexpected verification receipt")
	}
	remaining := true
	if args[5] == "move" {
		remaining, err = transfer.RemoveVerified(ctx, provider, name, expectedContent, manifest.Excludes, allow)
		if err != nil {
			return fmt.Errorf("copy verified; source removal stopped: %w", err)
		}
	}
	return output(struct {
		transfer.SharedFolder
		SourceRemaining bool `json:"source_remaining"`
	}{receipt, remaining})
}

func removeTermuxFiles(ctx context.Context, cl *client.Client, args []string) error {
	if len(args) < 5 {
		return errors.New("file-remove PEER ROOT SOURCE SOURCE_XXH64 [EXCLUSION...]")
	}
	excludes, err := files.ValidateExclusions(args[5:])
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	req := protocol.VerifiedRemoval{Root: args[2], Path: args[3], XXH64: args[4], Excludes: excludes}
	result, err := cl.RemoveVerifiedTermuxFiles(ctx, req)
	if err != nil {
		return fmt.Errorf("copy verified; Termux source removal stopped: %w", err)
	}
	return output(result)
}
