// Package projectsync builds private projections of explicitly approved,
// persistent project data and records authenticated writer ownership.
package projectsync

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type GitState struct {
	Branch   string `json:"branch"`
	Head     string `json:"head"`
	Upstream string `json:"upstream"`
}

const maxGitOutput = 32 << 20

type gitOutput struct{ buffer bytes.Buffer }

func (b *gitOutput) Write(p []byte) (int, error) {
	if len(p) > maxGitOutput-b.buffer.Len() {
		return 0, errors.New("Git inventory exceeds the supported size")
	}
	return b.buffer.Write(p)
}

func git(ctx context.Context, root string, args ...string) ([]byte, error) {
	child, cancel := context.WithTimeout(ctx, 40*time.Second)
	defer cancel()
	prefix := []string{"--no-optional-locks", "-c", "core.fsmonitor=false", "-C", root}
	command := exec.CommandContext(child, "git", append(prefix, args...)...)
	for _, value := range os.Environ() {
		key, _, _ := strings.Cut(value, "=")
		if strings.HasPrefix(key, "GIT_") || key == "LC_ALL" {
			continue
		}
		command.Env = append(command.Env, value)
	}
	command.Env = append(command.Env, "LC_ALL=C", "GIT_TERMINAL_PROMPT=0")
	var output gitOutput
	command.Stdout = &output
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("git %s: %w", args[0], err)
	}
	return output.buffer.Bytes(), nil
}

func Preflight(ctx context.Context, root string) (string, GitState, error) {
	var state GitState
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", state, err
	}
	root, err = filepath.Abs(resolved)
	if err != nil {
		return "", state, err
	}
	top, err := git(ctx, root, "rev-parse", "--show-toplevel")
	if err != nil || strings.TrimSuffix(string(top), "\n") != root {
		return "", state, errors.New("choose the root of a Git working tree")
	}
	status, err := git(ctx, root, "status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignore-submodules=none")
	if err != nil {
		return "", state, err
	}
	if len(status) != 0 {
		return "", state, errors.New("commit or resolve tracked changes before project sync")
	}
	branch, err := git(ctx, root, "symbolic-ref", "--quiet", "--short", "HEAD")
	if err != nil {
		return "", state, errors.New("project sync needs a checked-out branch")
	}
	upstream, err := git(ctx, root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
	if err != nil {
		return "", state, errors.New("configure an upstream branch for project sync")
	}
	head, err := git(ctx, root, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		return "", state, err
	}
	upstreamHead, err := git(ctx, root, "rev-parse", "--verify", "@{upstream}^{commit}")
	if err != nil {
		return "", state, err
	}
	if !bytes.Equal(head, upstreamHead) {
		return "", state, errors.New("reconcile the branch and its upstream in Git before project sync")
	}
	state = GitState{
		Branch:   strings.TrimSuffix(string(branch), "\n"),
		Head:     strings.TrimSuffix(string(head), "\n"),
		Upstream: strings.TrimSuffix(string(upstream), "\n"),
	}
	return root, state, nil
}
