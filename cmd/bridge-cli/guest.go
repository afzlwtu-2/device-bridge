package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"devicebridge/internal/bootstrap"
	"devicebridge/internal/storage"
)

func guestCommand(store *storage.Store, options bootstrap.TailnetOptions, args []string) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if args[0] == "local-terminal" {
		if len(args) != 2 || args[1] != "-" {
			return errors.New("local-terminal - (reads a session request followed by terminal input frames)")
		}
		frames := bufio.NewScanner(os.Stdin)
		frames.Buffer(make([]byte, 4096), 64<<10)
		var request bootstrap.LocalTerminalRequest
		if !frames.Scan() || json.Unmarshal(frames.Bytes(), &request) != nil {
			return errors.New("invalid local terminal session request")
		}
		return bootstrap.RunLocalTerminal(ctx, options.StateDir, request, frames, os.Stdout)
	}
	if args[0] == "guest-terminal" {
		if len(args) != 2 || args[1] != "-" {
			return errors.New("guest-terminal - (reads a session request followed by terminal input frames)")
		}
		frames := bufio.NewScanner(os.Stdin)
		frames.Buffer(make([]byte, 4096), 64<<10)
		var request bootstrap.TerminalRequest
		if !frames.Scan() || json.Unmarshal(frames.Bytes(), &request) != nil {
			return errors.New("invalid terminal session request")
		}
		return bootstrap.RunGuestTerminal(ctx, options, store, request, frames, os.Stdout)
	}
	if args[0] == "guest-terminal-approve" || args[0] == "guest-terminal-revoke" {
		if len(args) != 2 {
			return errors.New("guest-terminal-approve SESSION_ID | guest-terminal-revoke SESSION_ID")
		}
		operation := "approve"
		if args[0] == "guest-terminal-revoke" {
			operation = "revoke"
		}
		if err := store.SetGuestTerminal(ctx, args[1], operation, ""); err != nil {
			return err
		}
		return output(map[string]string{"status": operation})
	}
	duration := 15 * time.Second
	if args[0] == "guest-pull" {
		duration = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, duration)
	defer cancel()
	if args[0] == "guest-close" {
		if len(args) != 2 {
			return errors.New("guest-close SESSION_ID")
		}
		if err := store.RevokeGuest(ctx, args[1]); err != nil {
			return err
		}
		return output(map[string]string{"status": "closed"})
	}
	if len(args) != 2 || args[1] != "-" {
		return errors.New("guest-open - | guest-list - | guest-pull - (reads JSON from stdin)")
	}
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, (64<<10)+1))
	if err != nil {
		return err
	}
	if len(raw) > 64<<10 {
		return errors.New("guest session request exceeds 64 KiB")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if args[0] == "guest-open" {
		var request bootstrap.GuestOpenRequest
		if err := dec.Decode(&request); err != nil || dec.Decode(new(any)) != io.EOF {
			return errors.New("invalid guest host request")
		}
		grant, err := bootstrap.OpenGuest(ctx, options, store, request)
		if err != nil {
			return err
		}
		return output(grant)
	}
	var request bootstrap.GuestRequest
	if err := dec.Decode(&request); err != nil || dec.Decode(new(any)) != io.EOF {
		return errors.New("invalid guest file request")
	}
	if args[0] == "guest-list" {
		entries, err := bootstrap.ListGuest(ctx, options, store, request)
		if err != nil {
			return err
		}
		return output(entries)
	}
	receipt, err := bootstrap.PullGuest(ctx, options, store, request)
	if err != nil {
		return err
	}
	return output(receipt)
}
