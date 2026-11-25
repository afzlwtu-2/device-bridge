package main

import (
	"context"
	"errors"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"devicebridge/internal/bootstrap"
)

func detachedTerminalCommand(state string, args []string) error {
	if len(args) != 6 || (args[0] != "launch" && args[0] != "serve") {
		return errors.New("invalid detached terminal operation")
	}
	uid, uidErr := strconv.Atoi(args[2])
	gid, gidErr := strconv.Atoi(args[3])
	groups, err := bootstrap.ParseTerminalGroups(args[4])
	if uidErr != nil || gidErr != nil || err != nil {
		return errors.New("invalid detached terminal identity")
	}
	if err := bootstrap.CheckDetachedTerminalIdentity(uid, gid, groups, args[5]); err != nil {
		return err
	}
	if args[0] == "launch" {
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		return bootstrap.LaunchDetachedTerminal(executable,
			append([]string{"--state", state, "local-terminal-detached", "serve"}, args[1:]...))
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return bootstrap.ServeDetachedTerminal(ctx, state, args[1])
}
