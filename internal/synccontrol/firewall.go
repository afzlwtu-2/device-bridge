package synccontrol

import (
	"context"
	"devicebridge/protocol"
	"errors"
	"net/netip"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// A user-approved job may open only its exact source/destination/port rule.
// Existing rules are never removed, and Android never invokes root here.
func openFirewall(ctx context.Context, request protocol.SyncControl) (func() error, error) {
	if !request.OpenFirewall || runtime.GOOS != "linux" {
		return nil, nil
	}
	ufw, err := exec.LookPath("ufw")
	if errors.Is(err, exec.ErrNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	run := func(ctx context.Context, args ...string) (string, error) {
		return privilegedOutput(ctx, ufw, args...)
	}
	limited, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	status, err := run(limited, "status")
	if err != nil {
		return nil, errors.New("cannot inspect the endpoint firewall; approve scoped firewall access during setup")
	}
	if !strings.Contains(status, "Status: active") {
		return nil, nil
	}
	local, e1 := netip.ParseAddrPort(request.Listen)
	peer, e2 := netip.ParseAddrPort(request.PeerEndpoint)
	if e1 != nil || e2 != nil {
		return nil, errors.New("invalid scoped firewall endpoints")
	}
	if !identifier.MatchString(request.JobID) || len(request.JobID) != 32 {
		return nil, errors.New("invalid job identity for scoped firewall cleanup")
	}
	systemdRun, e1 := exec.LookPath("systemd-run")
	systemctl, e2 := exec.LookPath("systemctl")
	if e1 != nil || e2 != nil {
		return nil, errors.New("the endpoint cannot arm automatic firewall cleanup; use an already-open sync route")
	}
	fields := []string{"from", peer.Addr().String(), "to", local.Addr().String(), "port", strconv.Itoa(int(local.Port())), "proto", "tcp"}
	existing, err := run(limited, "show", "added")
	if err != nil {
		return nil, errors.New("cannot check for an existing scoped firewall rule")
	}
	for _, line := range strings.Split(existing, "\n") {
		line = strings.SplitN(line, " comment ", 2)[0]
		if strings.HasSuffix(line, " "+strings.Join(fields, " ")) &&
			(!strings.Contains(line, " on ") || strings.Contains(line, " on "+request.Interface+" ")) {
			if strings.HasPrefix(line, "ufw allow ") {
				return nil, nil
			}
			if strings.HasPrefix(line, "ufw deny ") || strings.HasPrefix(line, "ufw reject ") || strings.HasPrefix(line, "ufw limit ") {
				return nil, errors.New("an existing firewall policy restricts this sync route")
			}
		}
	}
	comment := "DeviceBridge-sync-" + request.JobID
	rule := append(append([]string{"allow", "in", "on", request.Interface}, fields...), "comment", comment)
	remove := func() error {
		cleanupCtx, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		_, err := run(cleanupCtx, append([]string{"--force", "delete"}, rule...)...)
		return err
	}
	output, err := run(limited, rule...)
	if err != nil {
		return nil, errors.Join(errors.New("the endpoint could not open its scoped sync firewall rule"), remove())
	}
	if strings.Contains(output, "Skipping adding existing rule") {
		return nil, nil
	}
	// The restore runs locally if the agent or controller disconnects.
	seconds := request.Seconds
	if seconds == 0 {
		seconds = 300
	}
	unit := "devicebridge-syncfw-" + request.JobID
	timerCtx, stopTimer := context.WithTimeout(ctx, 5*time.Second)
	timerArgs := []string{"--quiet", "--collect", "--unit=" + unit, "--on-active=" + strconv.Itoa(seconds+30) + "s", "--timer-property=AccuracySec=1s", ufw, "--force", "delete"}
	timerArgs = append(timerArgs, rule...)
	_, err = privilegedOutput(timerCtx, systemdRun, timerArgs...)
	stopTimer()
	if err != nil {
		cleanupErr := remove()
		return nil, errors.Join(errors.New("automatic scoped firewall cleanup could not be armed"), cleanupErr)
	}
	return func() error {
		if err := remove(); err != nil {
			return errors.New("sync stopped but its scoped firewall rule still needs cleanup; the local restore timer remains armed")
		}
		cleanupCtx, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		_, err := privilegedOutput(cleanupCtx, systemctl, "stop", unit+".timer")
		if err != nil {
			return errors.New("the scoped firewall rule was removed but its restore timer did not stop cleanly")
		}
		return nil
	}, nil
}

func privilegedOutput(ctx context.Context, binary string, args ...string) (string, error) {
	program := binary
	if os.Geteuid() != 0 {
		sudo, err := exec.LookPath("sudo")
		if err != nil {
			return "", err
		}
		program = sudo
		args = append([]string{"-n", binary}, args...)
	}
	command := exec.CommandContext(ctx, program, args...)
	command.Env = append(os.Environ(), "LC_ALL=C")
	raw, err := command.CombinedOutput()
	return string(raw), err
}
