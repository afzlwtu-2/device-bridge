package main

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"

	"devicebridge/internal/client"
	"devicebridge/internal/files"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/transfer"
)

func sendSharedFolder(ctx context.Context, cl *client.Client, source, codec string) (transfer.SharedFolder, error) {
	var receipt transfer.SharedFolder
	if codec != "none" && codec != "gzip" {
		return receipt, errors.New("choose no compression or gzip")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	source, err := filepath.Abs(source)
	if err != nil {
		return receipt, err
	}
	info, err := os.Lstat(source)
	if err != nil {
		return receipt, err
	}
	if !info.IsDir() {
		return receipt, errors.New("choose a real directory")
	}
	p, err := filesproviders.NewNative("share", filepath.Dir(source))
	if err != nil {
		return receipt, err
	}
	defer p.Close()
	name := info.Name()
	manifest, err := files.ManifestWithin(ctx, p, name, transfer.MaxSharedFolderEntries, transfer.MaxSharedFolderBytes, func(int64) error { return nil })
	if err != nil {
		return receipt, err
	}
	manifest.Path = "."
	frame, expected, err := transfer.EncodeSharedFolder(name, manifest)
	if err != nil {
		return receipt, err
	}
	payload, pipe := io.Pipe()
	defer payload.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, err := pipe.Write(frame)
		if err == nil {
			progress := &fileSendProgress{total: expected.Size}
			entries := 0
			err = transfer.WriteTar(ctx, p, name, codec, pipe, func(n int64) error {
				if n == 0 {
					entries++
					if entries > len(manifest.Entries) {
						return errors.New("folder changed while streaming")
					}
					return nil
				}
				if n > progress.total-progress.sent {
					return errors.New("folder grew while streaming")
				}
				progress.record(n)
				return nil
			})
		}
		_ = pipe.CloseWithError(err)
	}()
	err = cl.SendSharedFolder(ctx, expected.Name, codec, payload, &receipt)
	_ = payload.Close()
	<-done
	if err != nil {
		return receipt, err
	}
	if receipt != expected {
		return receipt, errors.New("the peer returned unexpected folder verification")
	}
	return receipt, nil
}
