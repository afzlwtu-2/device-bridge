// Package sshserver provides shared in-process SSH server session, PTY, exec, and SFTP handling.
package sshserver

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"devicebridge/internal/platform"
	"devicebridge/internal/pty"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"syscall"

	"golang.org/x/crypto/ssh"
)

// ResolveAppFilesDir returns the Android app files directory for a state/var root.
func ResolveAppFilesDir(varRoot string) string {
	cleaned := filepath.Clean(varRoot)
	candidates := []string{
		filepath.Dir(filepath.Dir(filepath.Dir(cleaned))), // <files>/devicebridge/tailnet/node -> <files>
		filepath.Dir(filepath.Dir(cleaned)),               // <files>/devicebridge/tailnet -> <files>
		filepath.Dir(cleaned),                             // <files>/devicebridge -> <files>
		cleaned,
	}
	for _, cand := range candidates {
		dbShell := filepath.Join(cand, "terminal", "files", "usr", "bin", "db-ssh-shell")
		if st, err := os.Stat(dbShell); err == nil && !st.IsDir() {
			return cand
		}
	}
	return candidates[0]
}

// ResolveShell picks the interactive shell and starting directory for varRoot/stateDir.
func ResolveShell(varRoot string) (string, string) {
	if runtime.GOOS == "android" {
		appFilesDir := ResolveAppFilesDir(varRoot)
		dbShell := filepath.Join(appFilesDir, "terminal", "files", "usr", "bin", "db-ssh-shell")
		prefix := filepath.Dir(filepath.Dir(dbShell))
		for _, shell := range []string{"fish", "bash"} {
			if st, err := os.Stat(filepath.Join(prefix, "bin", shell)); err == nil && st.Mode().IsRegular() && st.Mode()&0o111 != 0 {
				if st, err = os.Stat(dbShell); err == nil && st.Mode().IsRegular() && st.Mode()&0o111 != 0 {
					return dbShell, filepath.Join(appFilesDir, "terminal", "files", "home")
				}
				break
			}
		}
		return "", ""
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = "/"
	}
	if envShell := strings.TrimSpace(os.Getenv("SHELL")); envShell != "" {
		if st, err := os.Stat(envShell); err == nil && !st.IsDir() {
			return envShell, home
		}
	}
	for _, cand := range []string{"/bin/bash", "/bin/sh"} {
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			return cand, home
		}
	}
	return "/bin/sh", home
}

// LoadOrCreateHostKeys loads an existing Ed25519 SSH host key or generates one under varRoot/ssh.
func LoadOrCreateHostKeys(varRoot string) ([]ssh.Signer, error) {
	if runtime.GOOS == "android" && varRoot != "" {
		appFilesDir := ResolveAppFilesDir(varRoot)
		termKey := filepath.Join(appFilesDir, "terminal", "files", "usr", "etc", "ssh", "ssh_host_ed25519_key")
		if raw, err := os.ReadFile(termKey); err == nil {
			if signer, pErr := ssh.ParsePrivateKey(raw); pErr == nil {
				return []ssh.Signer{signer}, nil
			}
		}
	}
	if varRoot == "" {
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return nil, err
		}
		signer, err := ssh.NewSignerFromKey(priv)
		if err != nil {
			return nil, err
		}
		return []ssh.Signer{signer}, nil
	}
	keyDir := filepath.Join(varRoot, "ssh")
	if err := os.MkdirAll(keyDir, 0o700); err != nil {
		return nil, err
	}
	keyPath := filepath.Join(keyDir, "ssh_host_ed25519_key")
	if raw, err := os.ReadFile(keyPath); err == nil {
		if signer, pErr := ssh.ParsePrivateKey(raw); pErr == nil {
			return []ssh.Signer{signer}, nil
		}
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	block, err := ssh.MarshalPrivateKey(priv, "")
	if err != nil {
		return nil, err
	}
	pemBytes := pem.EncodeToMemory(block)
	if err := os.WriteFile(keyPath, pemBytes, 0o600); err != nil {
		return nil, err
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		return nil, err
	}
	return []ssh.Signer{signer}, nil
}

// AllowEnvKey returns true if key matches acceptEnv patterns or is a standard safe locale/terminal variable.
func AllowEnvKey(key string, acceptEnv []string, allowSafeDefaults bool) bool {
	for _, pat := range acceptEnv {
		if matched, err := filepath.Match(pat, key); err == nil && matched {
			return true
		}
	}
	if !allowSafeDefaults {
		return false
	}
	if slices.Contains([]string{"TERM", "LANG", "COLORTERM"}, key) {
		return true
	}
	return strings.HasPrefix(key, "LC_") && !strings.ContainsRune(key, '=')
}

func resolveSFTPServer() string {
	for _, cand := range []string{
		"/usr/lib/ssh/sftp-server",
		"/usr/libexec/sftp-server",
		"/usr/libexec/openssh/sftp-server",
	} {
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			return cand
		}
	}
	return ""
}

func buildCommand(ctx context.Context, shellPath, origCmd string) *exec.Cmd {
	base := filepath.Base(shellPath)
	if base == "db-ssh-shell" {
		return exec.CommandContext(ctx, shellPath)
	}
	if origCmd == "internal-sftp" {
		if sftpBin := resolveSFTPServer(); sftpBin != "" {
			return exec.CommandContext(ctx, sftpBin)
		}
	}
	if origCmd != "" {
		return exec.CommandContext(ctx, shellPath, "-c", origCmd)
	}
	return exec.CommandContext(ctx, shellPath, "-l")
}

// ServeSessionChannel handles an accepted SSH "session" channel with PTY, resize, env, shell, exec, and SFTP.
func ServeSessionChannel(
	ctx context.Context,
	ch ssh.Channel,
	in <-chan *ssh.Request,
	shellPath, homeDir string,
	acceptEnv []string,
	allowSafeDefaults bool,
) {
	defer ch.Close()
	var ptyMaster *os.File
	hasPTY := false
	cols, rows := 80, 24
	termEnv := "xterm-256color"
	extraEnv := []string{}
	started := false
	var homeGuard *os.File
	defer func() {
		if homeGuard != nil {
			_ = homeGuard.Close()
		}
	}()

	startSession := func(origCmd string) bool {
		if started {
			return false
		}
		started = true
		if shellPath == "" {
			_, _ = io.WriteString(ch.Stderr(), "On this device, open Networks → SSH and choose Set up Terminal.\r\n")
			return false
		}
		if runtime.GOOS == "android" {
			var err error
			homeGuard, err = platform.LockTermuxHome(homeDir, false)
			if err != nil {
				_, _ = io.WriteString(ch.Stderr(), "Terminal Home is busy. Try again after restore.\r\n")
				return false
			}
		}
		cmd := buildCommand(ctx, shellPath, origCmd)
		cmd.Dir = homeDir
		env := append(os.Environ(), "TERM="+termEnv)
		env = append(env, extraEnv...)
		if origCmd != "" || filepath.Base(shellPath) == "db-ssh-shell" {
			env = append(env, "SSH_ORIGINAL_COMMAND="+origCmd)
		}
		if runtime.GOOS == "android" && filepath.Base(shellPath) == "db-ssh-shell" {
			nativeDir := os.Getenv("DEVICEBRIDGE_NATIVE_LIB_DIR")
			if nativeDir == "" {
				if exe, err := os.Executable(); err == nil {
					nativeDir = filepath.Dir(exe)
				}
			}
			if nativeDir != "" {
				adapter := filepath.Join(nativeDir, "libdb_termux_adapt.so")
				if st, err := os.Stat(adapter); err == nil && st.Mode().IsRegular() {
					env = append(env, "DEVICEBRIDGE_SSH_ADAPT_SO="+adapter)
				}
			}
		}
		cmd.Env = env
		if hasPTY {
			master, slave, pErr := pty.Open(cols, rows)
			if pErr != nil {
				return false
			}
			ptyMaster = master
			cmd.Stdin = slave
			cmd.Stdout = slave
			cmd.Stderr = slave
			cmd.SysProcAttr = &syscall.SysProcAttr{
				Setsid:  true,
				Setctty: true,
				Ctty:    0,
			}
			if sErr := cmd.Start(); sErr != nil {
				_ = slave.Close()
				_ = master.Close()
				return false
			}
			_ = slave.Close()
			go func() {
				_, _ = io.Copy(master, ch)
				_ = master.Close()
			}()
			go func() {
				_, _ = io.Copy(ch, master)
			}()
			go func() {
				waitErr := cmd.Wait()
				code := uint32(0)
				if waitErr != nil {
					var exitErr *exec.ExitError
					if errors.As(waitErr, &exitErr) {
						code = uint32(exitErr.ExitCode())
					} else {
						code = 1
					}
				}
				_ = master.Close()
				var status [4]byte
				binary.BigEndian.PutUint32(status[:], code)
				_, _ = ch.SendRequest("exit-status", false, status[:])
				_ = ch.CloseWrite()
				_ = ch.Close()
			}()
			return true
		}

		stdin, errIn := cmd.StdinPipe()
		stdout, errOut := cmd.StdoutPipe()
		stderr, errErr := cmd.StderrPipe()
		if errIn != nil || errOut != nil || errErr != nil || cmd.Start() != nil {
			return false
		}
		go func() {
			_, _ = io.Copy(stdin, ch)
			_ = stdin.Close()
		}()
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); _, _ = io.Copy(ch, stdout) }()
		go func() { defer wg.Done(); _, _ = io.Copy(ch.Stderr(), stderr) }()
		go func() {
			wg.Wait()
			waitErr := cmd.Wait()
			code := uint32(0)
			if waitErr != nil {
				var exitErr *exec.ExitError
				if errors.As(waitErr, &exitErr) {
					code = uint32(exitErr.ExitCode())
				} else {
					code = 1
				}
			}
			var status [4]byte
			binary.BigEndian.PutUint32(status[:], code)
			_, _ = ch.SendRequest("exit-status", false, status[:])
			_ = ch.CloseWrite()
			_ = ch.Close()
		}()
		return true
	}

	for req := range in {
		ok := false
		switch req.Type {
		case "pty-req":
			if len(req.Payload) >= 4 {
				tLen := int(binary.BigEndian.Uint32(req.Payload[:4]))
				if len(req.Payload) >= 4+tLen+8 {
					termEnv = string(req.Payload[4 : 4+tLen])
					cols = int(binary.BigEndian.Uint32(req.Payload[4+tLen : 8+tLen]))
					rows = int(binary.BigEndian.Uint32(req.Payload[8+tLen : 12+tLen]))
				}
			}
			hasPTY = true
			ok = true
		case "window-change":
			if len(req.Payload) >= 8 {
				w := int(binary.BigEndian.Uint32(req.Payload[:4]))
				h := int(binary.BigEndian.Uint32(req.Payload[4:8]))
				cols, rows = w, h
				if ptyMaster != nil {
					_ = pty.SetSize(ptyMaster, w, h)
				}
			}
			ok = true
		case "env":
			if len(req.Payload) >= 4 {
				kLen := int(binary.BigEndian.Uint32(req.Payload[:4]))
				if len(req.Payload) >= 8+kLen {
					key := string(req.Payload[4 : 4+kLen])
					vLen := int(binary.BigEndian.Uint32(req.Payload[4+kLen : 8+kLen]))
					if len(req.Payload) >= 8+kLen+vLen {
						val := string(req.Payload[8+kLen : 8+kLen+vLen])
						if AllowEnvKey(key, acceptEnv, allowSafeDefaults) {
							extraEnv = append(extraEnv, key+"="+val)
							ok = true
						}
					}
				}
			}
		case "shell":
			ok = startSession("")
		case "exec":
			cmdStr := ""
			if len(req.Payload) >= 4 {
				cLen := int(binary.BigEndian.Uint32(req.Payload[:4]))
				if len(req.Payload) >= 4+cLen {
					cmdStr = string(req.Payload[4 : 4+cLen])
				}
			}
			ok = startSession(cmdStr)
		case "subsystem":
			sub := ""
			if len(req.Payload) >= 4 {
				sLen := int(binary.BigEndian.Uint32(req.Payload[:4]))
				if len(req.Payload) >= 4+sLen {
					sub = string(req.Payload[4 : 4+sLen])
				}
			}
			if sub == "sftp" {
				ok = startSession("internal-sftp")
			}
		}
		if req.WantReply {
			_ = req.Reply(ok, nil)
		}
	}
	if ptyMaster != nil {
		_ = ptyMaster.Close()
	}
}

// HandleMTLSConn runs an SSH server directly over an already-mTLS-authenticated connection.
// Callers MUST verify the TLS client certificate and peer pairing status before calling this function.
func HandleMTLSConn(ctx context.Context, nc net.Conn, varRoot string, peerID string) error {
	defer nc.Close()
	signers, err := LoadOrCreateHostKeys(varRoot)
	if err != nil || len(signers) == 0 {
		return fmt.Errorf("agent ssh: host keys unavailable: %w", err)
	}
	cfg := &ssh.ServerConfig{
		ServerVersion: "SSH-2.0-DeviceBridge-mTLS",
		NoClientAuth:  true,
		NoClientAuthCallback: func(ssh.ConnMetadata) (*ssh.Permissions, error) {
			return &ssh.Permissions{Extensions: map[string]string{"peer_id": peerID}}, nil
		},
		PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) {
			return &ssh.Permissions{Extensions: map[string]string{"peer_id": peerID}}, nil
		},
	}
	for _, signer := range signers {
		cfg.AddHostKey(signer)
	}
	sconn, chans, reqs, err := ssh.NewServerConn(nc, cfg)
	if err != nil {
		return nil
	}
	defer sconn.Close()
	sessCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		<-sessCtx.Done()
		_ = sconn.Close()
	}()
	go ssh.DiscardRequests(reqs)

	shellPath, homeDir := ResolveShell(varRoot)
	for newChan := range chans {
		if newChan.ChannelType() != "session" {
			_ = newChan.Reject(ssh.UnknownChannelType, "unknown channel type")
			continue
		}
		ch, requests, err := newChan.Accept()
		if err != nil {
			continue
		}
		go ServeSessionChannel(sessCtx, ch, requests, shellPath, homeDir, nil, true)
	}
	return nil
}
