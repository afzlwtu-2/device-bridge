package bootstrap

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"devicebridge/internal/pty"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type LocalTerminalRequest struct {
	Columns int                   `json:"columns"`
	Rows    int                   `json:"rows"`
	Shell   string                `json:"shell,omitempty"`
	Remote  *RemoteTerminalTarget `json:"remote,omitempty"`
}

type RemoteTerminalTarget struct {
	Peer      string `json:"peer"`
	Name      string `json:"name"`
	Transport string `json:"transport,omitempty"`
	Endpoint  string `json:"endpoint,omitempty"`
	Interface string `json:"interface,omitempty"`
	CIDR      string `json:"cidr,omitempty"`
}

func extractBootstrapZipIfPresent(zipPath, prefix string) error {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer zr.Close()

	if err := os.MkdirAll(prefix, 0o755); err != nil {
		return err
	}
	var symlinksRaw string
	for _, f := range zr.File {
		if f.Name == "SYMLINKS.txt" {
			rc, err := f.Open()
			if err != nil {
				return err
			}
			b, _ := io.ReadAll(rc)
			_ = rc.Close()
			symlinksRaw = string(b)
			continue
		}
		clean := filepath.Clean(f.Name)
		if clean == "." || strings.HasPrefix(clean, "..") || filepath.IsAbs(clean) {
			continue
		}
		target := filepath.Join(prefix, clean)
		if f.FileInfo().IsDir() {
			_ = os.MkdirAll(target, 0o755)
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		mode := f.Mode()
		if mode == 0 {
			mode = 0o644
		}
		if strings.HasPrefix(clean, "bin/") || strings.HasPrefix(clean, "libexec/") || strings.HasPrefix(clean, "lib/apt/") || strings.HasSuffix(clean, ".so") || strings.Contains(clean, ".so.") {
			mode = 0o755
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
		if err != nil {
			_ = rc.Close()
			return err
		}
		_, copyErr := io.Copy(out, rc)
		closeErr := out.Close()
		_ = rc.Close()
		if err := errors.Join(copyErr, closeErr); err != nil {
			return err
		}
	}

	for _, line := range strings.Split(symlinksRaw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "←", 2)
		if len(parts) != 2 {
			continue
		}
		oldname := strings.ReplaceAll(strings.TrimSpace(parts[0]), "/data/data/com.termux/files/usr", prefix)
		relLink := filepath.Clean(strings.TrimSpace(parts[1]))
		if oldname == "" || relLink == "." || strings.HasPrefix(relLink, "..") || filepath.IsAbs(relLink) {
			continue
		}
		linkPath := filepath.Join(prefix, relLink)
		_ = os.MkdirAll(filepath.Dir(linkPath), 0o755)
		_ = os.Remove(linkPath)
		_ = os.Symlink(oldname, linkPath)
	}
	return nil
}

type termuxAdaptContext struct {
	AppRoot  string
	AppPkg   string
	TermRoot string
	Prefix   string
	Home     string
	CacheDir string
	AdaptSo  string
}

func resolveTermuxAdaptContext(stateDir, cliBin, termRoot, prefix, home, cacheDir string) termuxAdaptContext {
	appRoot := filepath.Dir(filepath.Dir(termRoot))
	appPkg := strings.TrimSpace(os.Getenv("DEVICEBRIDGE_APP_PACKAGE"))
	if appPkg == "" {
		base := filepath.Base(appRoot)
		if strings.Contains(base, ".") {
			appPkg = base
		}
	}
	adaptSo := ""
	var candidates []string
	if nativeDir := strings.TrimSpace(os.Getenv("DEVICEBRIDGE_NATIVE_LIB_DIR")); nativeDir != "" {
		candidates = append(candidates, filepath.Join(nativeDir, "libdb_termux_adapt.so"))
	}
	if cliBin != "" {
		candidates = append(candidates, filepath.Join(filepath.Dir(cliBin), "libdb_termux_adapt.so"))
	}
	if inherited := os.Getenv("DB_TERMUX_ADAPT_SO"); filepath.IsAbs(inherited) {
		candidates = append(candidates, inherited)
	}
	candidates = append(candidates, filepath.Join(prefix, "lib", "libdb_termux_adapt.so"))
	for _, cand := range candidates {
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			adaptSo = cand
			break
		}
	}
	return termuxAdaptContext{
		AppRoot:  appRoot,
		AppPkg:   appPkg,
		TermRoot: termRoot,
		Prefix:   prefix,
		Home:     home,
		CacheDir: cacheDir,
		AdaptSo:  adaptSo,
	}
}

func parseConfiguredSentinel(path string) (prefix, home, cacheDir, pkg string, ok bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", "", "", "", false
	}
	for _, line := range strings.Split(string(raw), "\n") {
		k, v, found := strings.Cut(strings.TrimSpace(line), "=")
		if !found {
			continue
		}
		switch k {
		case "prefix":
			prefix = v
		case "home":
			home = v
		case "cache":
			cacheDir = v
		case "pkg":
			pkg = v
		}
	}
	return prefix, home, cacheDir, pkg, prefix != "" && home != ""
}

func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func termuxFishAdapterBlock(adapter string) string {
	return fmt.Sprintf(`if not set -q DB_TERMUX_ADAPT_SO; or not test -r "$DB_TERMUX_ADAPT_SO"
    set -gx DB_TERMUX_ADAPT_SO %q
end
if test -r "$DB_TERMUX_ADAPT_SO"
    set -gx LD_PRELOAD "$DB_TERMUX_ADAPT_SO"
end
`, adapter)
}

func refreshTermuxFishConfig(path string, existing []byte, adapter string) error {
	original := string(existing)
	updated := strings.ReplaceAll(original, `set -gx APT_CONFIG "$PREFIX/etc/apt/apt.conf"`, `set -gx APT_CONFIG "$PREFIX/etc/devicebridge/apt.conf"`)
	if strings.HasPrefix(updated, "# DeviceBridge integrated Terminal") && adapter != "" {
		lines := strings.SplitAfter(updated, "\n")
		for i, line := range lines {
			if strings.HasPrefix(line, "    set -gx DB_TERMUX_ADAPT_SO ") {
				lines[i] = fmt.Sprintf("    set -gx DB_TERMUX_ADAPT_SO %q\n", adapter)
				break
			}
			if strings.HasPrefix(line, "set -gx LD_PRELOAD ") &&
				i+1 < len(lines) && strings.HasPrefix(lines[i+1], "set -gx DB_TERMUX_ADAPT_SO ") {
				lines[i], lines[i+1] = termuxFishAdapterBlock(adapter), ""
				break
			}
		}
		updated = strings.Join(lines, "")
	}
	if updated == original {
		return nil
	}
	return writeTermuxConfig(path, []byte(updated), 0o644)
}

func configureTermuxPrefix(stateDir, cliBin, termRoot, prefix, home, cacheDir string) error {
	_ = os.MkdirAll(filepath.Join(home, ".config", "fish", "conf.d"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, ".local", "bin"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, ".termux"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	_ = os.MkdirAll(filepath.Join(prefix, "bin"), 0o755)
	_ = os.MkdirAll(filepath.Join(prefix, "etc", "ssh"), 0o755)
	_ = os.MkdirAll(filepath.Join(prefix, "var", "empty"), 0o755)
	_ = os.MkdirAll(filepath.Join(prefix, "var", "run"), 0o755)

	ctx := resolveTermuxAdaptContext(stateDir, cliBin, termRoot, prefix, home, cacheDir)
	sentinel := filepath.Join(prefix, ".devicebridge-configured-v4")
	prevPrefix, prevHome, prevCache, prevPkg, hasSentinel := parseConfiguredSentinel(sentinel)
	pathChanged := !hasSentinel || prevPrefix != prefix || prevHome != home || prevCache != cacheDir || (ctx.AppPkg != "" && prevPkg != "" && prevPkg != ctx.AppPkg)

	tailnetSock := filepath.Join(stateDir, "tailnet", "control.sock")

	// Install shared tsnet / tailscale CLI wrappers that talk directly to DeviceBridge's shared tsnet sidecar.
	// Clear Termux LD_LIBRARY_PATH and LD_PRELOAD so Android's dynamic linker loads /system/lib64 for bridge-cli.
	tsnetScript := fmt.Sprintf(`#!/system/bin/sh
unset LD_LIBRARY_PATH LD_PRELOAD
STATE=${DEVICEBRIDGE_STATE:-%q}
FALLBACK_CLI=%q
CLI=${DEVICEBRIDGE_CLI:-$FALLBACK_CLI}
if [ ! -x "$CLI" ]; then
  CLI="$FALLBACK_CLI"
fi
if [ ! -x "$CLI" ]; then
  for cand in "$STATE"/hotbin/cli_*.bin; do
    if [ -x "$cand" ]; then
      CLI="$cand"
    fi
  done
fi
SOCK=${DEVICEBRIDGE_TAILNET_SOCKET:-%q}
CMD=${1:-status}
case "$CMD" in
  proxy|nc|dial)
    shift
    exec "$CLI" --state "$STATE" --tailnet-socket "$SOCK" tsnet-proxy "$@"
    ;;
  match-host|match)
    shift
    exec "$CLI" --state "$STATE" --tailnet-socket "$SOCK" tsnet-match "$@"
    ;;
  ping|probe)
    shift
    exec "$CLI" --state "$STATE" --tailnet-socket "$SOCK" tailnet probe "$@"
    ;;
  ip|ips)
    exec "$CLI" --state "$STATE" --tailnet-socket "$SOCK" tailnet status
    ;;
  status|login|logout|stop)
    shift
    exec "$CLI" --state "$STATE" --tailnet-socket "$SOCK" tailnet "$CMD" "$@"
    ;;
  *)
    exec "$CLI" --state "$STATE" --tailnet-socket "$SOCK" tailnet "$@"
    ;;
esac
`, stateDir, cliBin, tailnetSock)
	tsnetBin := filepath.Join(prefix, "bin", "tsnet")
	_ = os.WriteFile(tsnetBin, []byte(tsnetScript), 0o755)
	tailscaleBin := filepath.Join(prefix, "bin", "tailscale")
	_ = os.WriteFile(tailscaleBin, []byte(tsnetScript), 0o755)

	// Install package-adaptive sudo and tsu wrappers that preserve the current app's $PREFIX, $HOME, and LD_PRELOAD across Android su.
	installTermuxRootWrappers(ctx)

	// Configure shared OpenSSH client/server; only run Termux sshd on 127.0.0.1:8022 when explicitly enabled.
	configureTermuxSSH(stateDir, cliBin, termRoot, prefix, home, tsnetBin, pathChanged)

	// Configure ~/.tmux.conf ported from laptop ~/.tmux.conf for Android touchscreen ergonomics.
	tmuxCfgPath := filepath.Join(home, ".tmux.conf")
	fishBin := filepath.Join(prefix, "bin", "fish")
	bashBin := filepath.Join(prefix, "bin", "bash")
	defaultShell := "/system/bin/sh"
	defaultCmd := "/system/bin/sh -l"
	if isExecutableFile(fishBin) {
		defaultShell = fishBin
		defaultCmd = fishBin + " -l"
	} else if isExecutableFile(bashBin) {
		defaultShell = bashBin
		defaultCmd = bashBin + " -l"
	}
	tmpDir := filepath.Join(prefix, "tmp")
	ldPreloadLine := ""
	fishLdPreloadLine := ""
	if ctx.AdaptSo != "" {
		ldPreloadLine = fmt.Sprintf("set-environment -g LD_PRELOAD %q\nset-environment -g DB_TERMUX_ADAPT_SO %q\n", ctx.AdaptSo, ctx.AdaptSo)
		fishLdPreloadLine = termuxFishAdapterBlock(ctx.AdaptSo)
	}
	existingTmux, tmuxErr := os.ReadFile(tmuxCfgPath)
	expectedDefaultShellLine := fmt.Sprintf("set -g default-shell %q", defaultShell)
	if os.IsNotExist(tmuxErr) || pathChanged || !strings.Contains(string(existingTmux), "DEVICEBRIDGE_TMUX_V8") || !strings.Contains(string(existingTmux), expectedDefaultShellLine) || !strings.Contains(string(existingTmux), "STARSHIP_CONFIG") {
		tmuxCfg := fmt.Sprintf(`# DEVICEBRIDGE_TMUX_V8 (ported from laptop ~/.tmux.conf for Android touchscreen)
# -------------------------------------------------------------------
# 0. DeviceBridge / Termux Environment Propagation
# -------------------------------------------------------------------
set -g default-shell %q
set -g default-command %q
set-environment -g PREFIX %q
set-environment -g HOME %q
set-environment -g STARSHIP_CONFIG "%s/.config/starship.toml"
set-environment -g TMPDIR %q
set-environment -g TMUX_TMPDIR %q
set-environment -g TERMINFO "%s/share/terminfo"
set-environment -g LD_LIBRARY_PATH %q
%sset-environment -g TERMUX_CACHE_DIR %q
set-environment -g TERMUX__CACHE_DIR %q
set-environment -g TERMUX__PREFIX %q
set-environment -g TERMUX__HOME %q
set-environment -g TERMUX__ROOTFS %q
set-environment -g TERMUX_APP__DATA_DIR %q
set-environment -g TERMUX_APP__PACKAGE_NAME %q
set-environment -g APT_CONFIG %q
set-environment -g DPKG_ADMINDIR "%s/var/lib/dpkg"
set-environment -g SSL_CERT_FILE "%s/etc/tls/cert.pem"
set-environment -g CURL_CA_BUNDLE "%s/etc/tls/cert.pem"
set-environment -g PKG_CONFIG_PATH "%s/lib/pkgconfig:%s/share/pkgconfig"
set-environment -g XDG_CONFIG_HOME "%s/.config"
set-environment -g XDG_DATA_HOME "%s/.local/share"
set-environment -g XDG_CACHE_HOME %q
set-environment -g DEVICEBRIDGE_STATE %q
set-environment -g DEVICEBRIDGE_TAILNET_SOCKET %q
set-environment -g PATH "%s/.local/bin:%s/bin:/system/bin"

# -------------------------------------------------------------------
# 1. Terminal Performance, Colors & OSC 52 Bridge (xterm3)
# -------------------------------------------------------------------
set -g default-terminal "tmux-256color"
set -as terminal-features ",*:RGB:clipboard"
set -as terminal-overrides ",xterm*:Ms=\\E]52;%%p1%%s;%%p2%%s\\007"
set -s escape-time 0
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g status off

# -------------------------------------------------------------------
# 2. Touchscreen Ergonomics & Smooth Finger Scrolling
# -------------------------------------------------------------------
set -g mouse on

# Prevent accidental screen slides from triggering yellow copy-mode selection.
# Finger slides scroll via wheel events; use Prefix+[ (or Alt+v / Command Palette) to enter selection mode.
unbind-key -T root MouseDrag1Pane
unbind-key -T copy-mode-vi MouseDrag1Pane
unbind-key -T copy-mode-vi MouseDragEnd1Pane
bind-key -T root MouseDrag1Pane if-shell -F "#{||:#{pane_in_mode},#{mouse_any_flag}}" "send-keys -M" ""
bind-key -T copy-mode-vi MouseDown1Pane select-pane \; send-keys -X clear-selection
bind-key -T copy-mode-vi DoubleClick1Pane select-pane \; send-keys -X select-word \; send-keys -X copy-pipe-no-clear
bind-key -T copy-mode-vi TripleClick1Pane select-pane \; send-keys -X select-line \; send-keys -X copy-pipe-no-clear

# Smooth finger scrolling (2 lines per touch scroll tick instead of desktop wheel's 5)
bind-key -T copy-mode-vi WheelUpPane select-pane \; send-keys -X -N 2 scroll-up
bind-key -T copy-mode-vi WheelDownPane select-pane \; send-keys -X -N 2 scroll-down

# -------------------------------------------------------------------
# 3. Modal Selection & Clipboard (Local + SSH via OSC 52)
# -------------------------------------------------------------------
setw -g mode-keys vi
set -s set-clipboard on

# Selection activation & bindings (Prefix+[ or Alt+v enters copy-mode; v/V/C-v select; y yanks)
bind-key -n M-v copy-mode
bind-key Space copy-mode
bind-key -T copy-mode-vi v send-keys -X begin-selection
bind-key -T copy-mode-vi x send-keys -X select-line
bind-key -T copy-mode-vi V send-keys -X select-line
bind-key -T copy-mode-vi C-v send-keys -X rectangle-toggle
bind-key -T copy-mode-vi \; send-keys -X clear-selection

# Yanking
bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel

# Window navigation & pasting
bind-key p previous-window
bind-key n next-window
bind-key ] paste-buffer -p

# Exit / Cancel copy mode
bind-key -T copy-mode-vi Escape send-keys -X cancel
bind-key -T copy-mode-vi q send-keys -X cancel

# -------------------------------------------------------------------
# 4. Helix-Style 'goto' (g) Key Table
# -------------------------------------------------------------------
bind-key -T copy-mode-vi g switch-client -T helix-goto

bind-key -T helix-goto g send-keys -X history-top
bind-key -T helix-goto e send-keys -X history-bottom
bind-key -T helix-goto h send-keys -X start-of-line
bind-key -T helix-goto l send-keys -X end-of-line
bind-key -T helix-goto s send-keys -X back-to-indentation
bind-key -T helix-goto Escape switch-client -T copy-mode-vi

# -------------------------------------------------------------------
# Floating Scratchpad Popup (Zellij style)
# -------------------------------------------------------------------
# Prefix + f opens a persistent floating terminal popup
bind-key f display-popup -w 85%% -h 85%% -E "tmux new-session -A -s scratch"

# Forward terminal BEL from every pane/window to attached terminals.
set -g bell-action any
set -g visual-bell off
setw -g monitor-bell on
`, defaultShell, defaultCmd, prefix, home, home, tmpDir, tmpDir, prefix, termuxLDLibraryPath(prefix), ldPreloadLine,
			cacheDir, cacheDir, prefix, home, filepath.Join(termRoot, "files"), ctx.AppRoot, ctx.AppPkg,
			termuxAPTConfig(prefix), prefix, prefix, prefix, prefix, prefix, home, home, cacheDir, stateDir, tailnetSock, home, prefix)
		_ = os.WriteFile(tmuxCfgPath, []byte(tmuxCfg), 0o644)
	} else {
		oldLine := fmt.Sprintf("set-environment -g APT_CONFIG %q", filepath.Join(prefix, "etc", "apt", "apt.conf"))
		newLine := fmt.Sprintf("set-environment -g APT_CONFIG %q", termuxAPTConfig(prefix))
		if updated := strings.ReplaceAll(string(existingTmux), oldLine, newLine); updated != string(existingTmux) {
			if err := writeTermuxConfig(tmuxCfgPath, []byte(updated), 0o644); err != nil {
				return err
			}
		}
	}

	if err := configureTermuxShellExperience(prefix, home); err != nil {
		return err
	}

	fishCfg := filepath.Join(home, ".config", "fish", "config.fish")
	existingFish, fishErr := os.ReadFile(fishCfg)
	if os.IsNotExist(fishErr) || pathChanged || strings.Contains(string(existingFish), "# Commands to run in interactive sessions can go here") || !strings.Contains(string(existingFish), "TMUX_TMPDIR") || !strings.Contains(string(existingFish), "if not set -q DEVICEBRIDGE_CLI") || !strings.Contains(string(existingFish), "TERMUX_APP__PACKAGE_NAME") || (strings.HasPrefix(string(existingFish), "# DeviceBridge integrated Terminal") && !strings.Contains(string(existingFish), "DEVICEBRIDGE_FISH_V3")) {
		cfg := fmt.Sprintf(`# DeviceBridge integrated Terminal (DEVICEBRIDGE_FISH_V3: fish + starship + tmux + Nerd Fonts + shared tsnet & OpenSSH)
set -gx PREFIX %q
set -gx HOME %q
set -gx TMPDIR %q
set -gx TMUX_TMPDIR %q
set -gx TERMINFO "$PREFIX/share/terminfo"
set -gx SHELL "$PREFIX/bin/fish"
set -gx LD_LIBRARY_PATH %q
%sset -gx TERMUX_CACHE_DIR %q
set -gx TERMUX__CACHE_DIR %q
set -gx TERMUX__PREFIX "$PREFIX"
set -gx TERMUX__HOME "$HOME"
set -gx TERMUX__ROOTFS %q
set -gx TERMUX_APP__DATA_DIR %q
set -gx TERMUX_APP__PACKAGE_NAME %q
set -gx APT_CONFIG "$PREFIX/etc/devicebridge/apt.conf"
set -gx DPKG_ADMINDIR "$PREFIX/var/lib/dpkg"
set -gx SSL_CERT_FILE "$PREFIX/etc/tls/cert.pem"
set -gx CURL_CA_BUNDLE "$PREFIX/etc/tls/cert.pem"
set -gx PKG_CONFIG_PATH "$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
set -gx XDG_CONFIG_HOME "$HOME/.config"
set -gx XDG_DATA_HOME "$HOME/.local/share"
set -gx XDG_CACHE_HOME %q
set -gx STARSHIP_CONFIG "$HOME/.config/starship.toml"
set -gx DEVICEBRIDGE_STATE %q
if not set -q DEVICEBRIDGE_CLI
    set -gx DEVICEBRIDGE_CLI %q
end
set -gx DEVICEBRIDGE_TAILNET_SOCKET %q
set -gx fish_greeting ""

if not contains "$HOME/.local/bin" $PATH
    set -gx PATH "$HOME/.local/bin" $PATH
end
if not contains "$PREFIX/bin" $PATH
    set -gx PATH "$PREFIX/bin" /system/bin $PATH
end

if status is-interactive
    set -g fish_color_command cyan --bold
    set -g fish_color_param normal
    set -g fish_color_error red --bold
    set -g fish_color_autosuggestion brblack

    alias ll "ls -lh"
    alias la "ls -lha"
    alias cls "clear"

    if command -q fastfetch
        if test -f "$HOME/.config/fastfetch/config.jsonc"
            fastfetch --config "$HOME/.config/fastfetch/config.jsonc"
        else
            fastfetch
        end
    end
    if command -q starship
        starship init fish | source
    end
    if command -q zoxide
        zoxide init fish | source
    end
end

if not command -q starship
    function fish_prompt
        set -l last_status $status
        set -l cwd (prompt_pwd)
        set_color --bold cyan
        printf "\uf120 %%s" $cwd
        if test $last_status -ne 0
            set_color --bold red
            printf " [%%d]" $last_status
        end
        set_color --bold brgreen
        printf " ❯ "
        set_color normal
    end
end
`, prefix, home, tmpDir, tmpDir, termuxLDLibraryPath("$PREFIX"), fishLdPreloadLine, cacheDir, cacheDir, filepath.Join(termRoot, "files"), ctx.AppRoot, ctx.AppPkg, cacheDir, stateDir, cliBin, tailnetSock)
		_ = os.WriteFile(fishCfg, []byte(cfg), 0o644)
	} else if fishErr == nil {
		if err := refreshTermuxFishConfig(fishCfg, existingFish, ctx.AdaptSo); err != nil {
			return err
		}
	}

	// Reconcile shared sshd on 127.0.0.1:8022 (off by default unless enabled in tsnet settings)
	if isOpenSSHEnabled(stateDir) {
		startTermuxSSHDIfNeeded(prefix, home, ctx.AdaptSo)
	} else {
		stopTermuxSSHDIfRunning(prefix)
	}

	if err := configureTermuxAPT(stateDir, cliBin, ctx); err != nil {
		return err
	}
	if !pathChanged {
		return nil
	}

	adaptTermuxInstallation(ctx, prevPrefix, prevHome, prevCache)
	sentinelContent := fmt.Sprintf("prefix=%s\nhome=%s\ncache=%s\npkg=%s\ncli=%s\n", prefix, home, cacheDir, ctx.AppPkg, cliBin)
	return writeTermuxConfig(sentinel, []byte(sentinelContent), 0o644)
}

func installTermuxRootWrappers(ctx termuxAdaptContext) {
	localBin := filepath.Join(ctx.Home, ".local", "bin")
	_ = os.MkdirAll(localBin, 0o755)
	wrapper := fmt.Sprintf(`#!/system/bin/sh
# DeviceBridge adaptive sudo/tsu wrapper for non-com.termux package names.
set -u

TARGET_USER="root"
PRESERVE_HOME=1
LOGIN_SHELL=0
INTERACTIVE_SHELL=0
USER_SET=0
SHOW_HELP=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      SHOW_HELP=1
      shift
      ;;
    -E|--preserve-env)
      shift
      ;;
    -H|--set-home)
      PRESERVE_HOME=0
      shift
      ;;
    -i|--login)
      LOGIN_SHELL=1
      INTERACTIVE_SHELL=1
      shift
      ;;
    -s|--shell)
      INTERACTIVE_SHELL=1
      shift
      ;;
    -u|--user)
      if [ "$#" -lt 2 ]; then
        echo "sudo: $1 requires a user" >&2
        exit 2
      fi
      TARGET_USER="$2"
      USER_SET=1
      shift
      shift
      ;;
    --user=*)
      TARGET_USER="${1#--user=}"
      USER_SET=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "sudo: unsupported option $1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ "$SHOW_HELP" -eq 1 ]; then
  printf 'Usage: %%s [-E] [-H] [-i] [-s] [-u USER] [--] [COMMAND [ARGS...]]\n' "${0##*/}"
  exit 0
fi

SU_BIN=""
for cand in /debug_ramdisk/su /sbin/su /system/sbin/su /system/bin/su /system/xbin/su /su/bin/su /magisk/.core/bin/su; do
  if [ -x "$cand" ]; then
    SU_BIN="$cand"
    break
  fi
done
if [ -z "$SU_BIN" ]; then
  SU_BIN=$(command -v su 2>/dev/null || true)
fi
if [ -z "$SU_BIN" ]; then
  echo "sudo: su binary not found on this device" >&2
  exit 1
fi

REAL_PREFIX=${TERMUX__PREFIX:-${PREFIX:-%s}}
TERMINAL_HOME=${TERMUX__HOME:-%s}
REAL_HOME=${HOME:-"$TERMINAL_HOME"}
if [ "$PRESERVE_HOME" -eq 0 ]; then
  REAL_HOME=/data/local/tmp
fi
REAL_TMP=${TMPDIR:-"$REAL_PREFIX/tmp"}
REAL_CACHE=${TERMUX_CACHE_DIR:-%s}
REAL_ADAPT=${DB_TERMUX_ADAPT_SO:-%s}
REAL_TERM=${TERM:-xterm-256color}
REAL_PWD=$(pwd 2>/dev/null || printf '%%s' "$REAL_HOME")

append_quoted() {
  for value do
    INNER="$INNER '"
    while case "$value" in *"'"*) true;; *) false;; esac; do
      INNER="$INNER${value%%%%\'*}'\"'\"'"
      value=${value#*\'}
    done
    INNER="$INNER$value'"
  done
}

INNER="export"
append_quoted "PREFIX=$REAL_PREFIX" "HOME=$REAL_HOME" "TMPDIR=$REAL_TMP" "TMUX_TMPDIR=$REAL_TMP" \
  "TERMINFO=$REAL_PREFIX/share/terminfo" "TERM=$REAL_TERM" "LD_LIBRARY_PATH=` + termuxSystemLibDir() + `:$REAL_PREFIX/lib" \
  "TERMUX_CACHE_DIR=$REAL_CACHE" "TERMUX__CACHE_DIR=$REAL_CACHE" "TERMUX__PREFIX=$REAL_PREFIX" \
  "TERMUX__HOME=$TERMINAL_HOME" "TERMUX__ROOTFS=${REAL_PREFIX%%/*}" \
  TERMUX_APP__DATA_DIR=%s TERMUX_APP__PACKAGE_NAME=%s \
  "APT_CONFIG=$REAL_PREFIX/etc/devicebridge/apt.conf" "DPKG_ADMINDIR=$REAL_PREFIX/var/lib/dpkg" \
  "SSL_CERT_FILE=$REAL_PREFIX/etc/tls/cert.pem" "CURL_CA_BUNDLE=$REAL_PREFIX/etc/tls/cert.pem" \
  "PKG_CONFIG_PATH=$REAL_PREFIX/lib/pkgconfig:$REAL_PREFIX/share/pkgconfig" \
  "PATH=$TERMINAL_HOME/.local/bin:$REAL_PREFIX/bin:/system/bin:/system/xbin"
if [ -n "$REAL_ADAPT" ] && [ -r "$REAL_ADAPT" ]; then
  append_quoted "LD_PRELOAD=$REAL_ADAPT" "DB_TERMUX_ADAPT_SO=$REAL_ADAPT"
fi
INNER="$INNER; cd"
append_quoted "$REAL_PWD"
INNER="$INNER 2>/dev/null || true; exec"
# Android su starts a clean shell. Replace it with a shell that loaded the
# adapter so the first command path and its shebang can be translated too.
if [ -n "$REAL_ADAPT" ] && [ -r "$REAL_ADAPT" ]; then
  for command_shell in "$REAL_PREFIX/bin/sh" "$REAL_PREFIX/bin/bash"; do
    if [ -x "$command_shell" ]; then
      append_quoted "$command_shell" -c 'exec "$@"' sh
      break
    fi
  done
fi

if [ "$#" -eq 1 ] && [ "$1" = su ]; then
  INTERACTIVE_SHELL=1
  shift
fi
if [ "$#" -eq 0 ]; then
  if [ "$LOGIN_SHELL" -eq 1 ] || [ "$INTERACTIVE_SHELL" -eq 1 ] || [ "${0##*/}" = "tsu" ]; then
    SHELL_BIN=""
    for shc in "$REAL_PREFIX/bin/fish" "$REAL_PREFIX/bin/bash" /system/bin/sh; do
      if [ -x "$shc" ]; then
        SHELL_BIN="$shc"
        break
      fi
    done
    set -- "$SHELL_BIN" -l
  else
    echo "Usage: sudo [OPTIONS] COMMAND [ARGS...]" >&2
    exit 1
  fi
fi
append_quoted "$@"

# Pass user before -c when targeting non-root or explicit user; MagiskSU/KernelSU/APatch default to root (0).
unset LD_PRELOAD LD_LIBRARY_PATH
export PATH=/debug_ramdisk:/sbin:/su/bin:/system/bin:/system/xbin
if [ "$USER_SET" -eq 1 ] && [ "$TARGET_USER" != "root" ] && [ "$TARGET_USER" != "0" ]; then
  exec "$SU_BIN" "$TARGET_USER" -c "$INNER"
fi
exec "$SU_BIN" -c "$INNER"
`, shellSingleQuote(ctx.Prefix), shellSingleQuote(ctx.Home), shellSingleQuote(ctx.CacheDir),
		shellSingleQuote(ctx.AdaptSo), shellSingleQuote(ctx.AppRoot), shellSingleQuote(ctx.AppPkg))
	for _, name := range []string{"sudo", "tsu"} {
		localTarget := filepath.Join(localBin, name)
		existing, err := os.ReadFile(localTarget)
		if os.IsNotExist(err) || bytes.Contains(existing, []byte("# DeviceBridge adaptive sudo/tsu wrapper ")) {
			_ = writeTermuxConfig(localTarget, []byte(wrapper), 0o755)
		}
		// Also provide in $PREFIX/bin when not already installed by a Termux package.
		prefixTarget := filepath.Join(ctx.Prefix, "bin", name)
		existing, err = os.ReadFile(prefixTarget)
		if os.IsNotExist(err) || bytes.Contains(existing, []byte("# DeviceBridge adaptive sudo/tsu wrapper ")) {
			_ = writeTermuxConfig(prefixTarget, []byte(wrapper), 0o755)
		}
	}
}

func relocateNestedTermuxTree(srcDir, dstDir string) {
	info, err := os.Lstat(srcDir)
	if err != nil || !info.IsDir() {
		return
	}
	src, err := os.OpenRoot(srcDir)
	if err != nil {
		return
	}
	defer src.Close()
	dst, err := os.OpenRoot(dstDir)
	if err != nil {
		return
	}
	defer dst.Close()
	var dirs []string
	_ = filepath.WalkDir(srcDir, func(path string, d fs.DirEntry, werr error) error {
		rel, rerr := filepath.Rel(srcDir, path)
		if werr != nil || rerr != nil {
			return nil
		}
		if d.IsDir() {
			if rel != "." && dst.MkdirAll(rel, 0o755) != nil {
				return filepath.SkipDir
			}
			dirs = append(dirs, path)
			return nil
		}
		parent, name := filepath.Dir(rel), filepath.Base(rel)
		from, err := src.Open(parent)
		if err != nil {
			return nil
		}
		defer from.Close()
		to, err := dst.Open(parent)
		if err != nil {
			return nil
		}
		defer to.Close()
		// Conflicting or failed moves stay in the legacy tree for recovery.
		_ = unix.Renameat2(int(from.Fd()), name, int(to.Fd()), name, unix.RENAME_NOREPLACE)
		return nil
	})
	for i := len(dirs) - 1; i >= 0; i-- {
		_ = unix.Rmdir(dirs[i])
	}
}

func termuxAPTConfig(prefix string) string {
	return filepath.Join(prefix, "etc", "devicebridge", "apt.conf")
}

func writeTermuxConfig(path string, data []byte, mode fs.FileMode) error {
	if current, err := os.ReadFile(path); err == nil && bytes.Equal(current, data) {
		return nil
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".devicebridge-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if err := file.Chmod(mode); err != nil {
		_ = file.Close()
		return err
	}
	_, writeErr := file.Write(data)
	if err := errors.Join(writeErr, file.Close()); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

func configureTermuxAPT(stateDir, cliBin string, ctx termuxAdaptContext) error {
	prefix := ctx.Prefix
	cacheDir := ctx.CacheDir
	aptConf := termuxAPTConfig(prefix)
	for _, dir := range []string{
		filepath.Dir(aptConf),
		filepath.Join(prefix, "etc", "apt", "sources.list.d"),
		filepath.Join(prefix, "etc", "apt", "apt.conf.d"),
		filepath.Join(prefix, "var", "lib", "dpkg", "info"),
		filepath.Join(prefix, "var", "lib", "dpkg", "updates"),
		filepath.Join(prefix, "var", "lib", "apt", "lists", "partial"),
		filepath.Join(prefix, "var", "log", "apt"),
		filepath.Join(cacheDir, "apt", "archives", "partial"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}

	statusFile := filepath.Join(prefix, "var", "lib", "dpkg", "status")
	if _, err := os.Stat(statusFile); os.IsNotExist(err) {
		_ = os.WriteFile(statusFile, []byte(""), 0o644)
	}
	availFile := filepath.Join(prefix, "var", "lib", "dpkg", "available")
	if _, err := os.Stat(availFile); os.IsNotExist(err) {
		_ = os.WriteFile(availFile, []byte(""), 0o644)
	}

	sourcesList := filepath.Join(prefix, "etc", "apt", "sources.list")
	if _, err := os.Stat(sourcesList); os.IsNotExist(err) {
		_ = os.WriteFile(sourcesList, []byte("deb https://mirror.autkin.net/termux/termux-main stable main\n"), 0o644)
	}
	rootList := filepath.Join(prefix, "etc", "apt", "sources.list.d", "root.list")
	if _, err := os.Stat(rootList); os.IsNotExist(err) {
		_ = os.WriteFile(rootList, []byte("deb https://mirror.autkin.net/termux/termux-root root stable\n"), 0o644)
	}

	postInvoke := ""
	if cliBin != "" && stateDir != "" {
		// Android's extracted native library paths can contain '='. Invoke the
		// executable through the hook shell so env(1) cannot parse it as NAME=VALUE.
		command := "unset LD_LIBRARY_PATH LD_PRELOAD; exec " + shellSingleQuote(cliBin) +
			" --state " + shellSingleQuote(stateDir) + " termux-adapt"
		command = strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(command)
		postInvoke = fmt.Sprintf("DPkg::Post-Invoke { \"%s\"; };\n", command)
	}
	aptConfContent := fmt.Sprintf(`Dir "%s";
Dir::State "%s/var/lib/apt";
Dir::State::status "%s/var/lib/dpkg/status";
Dir::Cache "%s/apt";
Dir::Etc "%s/etc/apt";
Dir::Etc::trusted "%s/etc/apt/trusted.gpg";
Dir::Etc::trustedparts "%s/etc/apt/trusted.gpg.d";
Dir::Bin::dpkg "%s/bin/dpkg";
Dir::Bin::gpg "%s/bin/gpgv";
Dir::Bin::apt-key "%s/bin/apt-key";
Dir::Bin::Methods "%s/lib/apt/methods";
Dir::Log "%s/var/log/apt";
DPkg::Path "%s/bin:/system/bin";
Acquire::https::CaInfo "%s/etc/tls/cert.pem";
Acquire::AllowInsecureRepositories "false";
%s`, prefix, prefix, prefix, cacheDir, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, postInvoke)
	if err := writeTermuxConfig(aptConf, []byte(aptConfContent), 0o644); err != nil {
		return err
	}
	// Preserve user directives while removing the hook installed by older builds.
	legacy := filepath.Join(prefix, "etc", "apt", "apt.conf")
	if raw, err := os.ReadFile(legacy); err == nil {
		lines := strings.Split(string(raw), "\n")
		kept := lines[:0]
		for _, line := range lines {
			if !strings.HasPrefix(line, `DPkg::Post-Invoke { "env -u LD_LIBRARY_PATH -u LD_PRELOAD `) ||
				!strings.HasSuffix(line, ` termux-adapt || true"; };`) {
				kept = append(kept, line)
			}
		}
		return writeTermuxConfig(legacy, []byte(strings.Join(kept, "\n")), 0o644)
	} else if !os.IsNotExist(err) {
		return err
	}
	return nil
}

func adaptTermuxInstallation(ctx termuxAdaptContext, prevPrefix, prevHome, prevCache string) {
	prefix, home, cacheDir := ctx.Prefix, ctx.Home, ctx.CacheDir
	for _, base := range []string{"/data/data/com.termux", "/data/user/0/com.termux"} {
		relocateNestedTermuxTree(filepath.Join(prefix, strings.TrimPrefix(base, "/"), "files", "usr"), prefix)
		relocateNestedTermuxTree(filepath.Join(prefix, strings.TrimPrefix(base, "/"), "files", "home"), home)
	}

	// Rewrite hardcoded /data/{data,user/0}/com.termux and any previous package paths in symlinks and text files across $PREFIX.
	replacements := [][2]string{
		{"/data/data/com.termux/files/usr", prefix},
		{"/data/user/0/com.termux/files/usr", prefix},
		{"/data/data/com.termux/files/home", home},
		{"/data/user/0/com.termux/files/home", home},
		{"/data/data/com.termux/cache", cacheDir},
		{"/data/user/0/com.termux/cache", cacheDir},
	}
	if prevPrefix != "" && prevPrefix != prefix {
		replacements = append(replacements, [2]string{prevPrefix, prefix})
	}
	if prevHome != "" && prevHome != home {
		replacements = append(replacements, [2]string{prevHome, home})
	}
	if prevCache != "" && prevCache != cacheDir {
		replacements = append(replacements, [2]string{prevCache, cacheDir})
	}

	rewriteString := func(in string) string {
		out := in
		for _, pair := range replacements {
			if pair[0] != "" && pair[0] != pair[1] {
				out = strings.ReplaceAll(out, pair[0], pair[1])
			}
		}
		return out
	}

	for _, sub := range []string{"bin", "libexec", "lib", "etc", "share", "include", "var/lib/dpkg/info"} {
		root := filepath.Join(prefix, sub)
		_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, werr error) error {
			if werr != nil {
				return nil
			}
			if d.Type()&os.ModeSymlink != 0 {
				if target, lerr := os.Readlink(p); lerr == nil {
					if updated := rewriteString(target); updated != target {
						_ = os.Remove(p)
						_ = os.Symlink(updated, p)
					}
				}
				return nil
			}
			if !d.Type().IsRegular() {
				return nil
			}
			if sub == "var/lib/dpkg/info" {
				switch filepath.Ext(p) {
				case ".preinst", ".postinst", ".prerm", ".postrm", ".config":
				default:
					return nil
				}
			}
			if p == termuxAPTConfig(prefix) {
				return nil
			}
			info, ierr := d.Info()
			if ierr != nil || info.Size() == 0 || info.Size() > 1<<20 {
				return nil
			}
			// Avoid touching binary files outside known text scripts/configs/maintainer files.
			raw, rerr := os.ReadFile(p)
			if rerr != nil || len(raw) == 0 || bytes.HasPrefix(raw, []byte("\x7fELF")) || bytes.IndexByte(raw, 0) >= 0 {
				return nil
			}
			text := string(raw)
			if !strings.Contains(text, "com.termux") && (prevPrefix == "" || !strings.Contains(text, prevPrefix)) && (prevHome == "" || !strings.Contains(text, prevHome)) {
				return nil
			}
			if updated := rewriteString(text); updated != text {
				_ = os.WriteFile(p, []byte(updated), info.Mode())
			}
			return nil
		})
	}
}

// EnsureTermuxAdapted adapts the isolated Termux prefix (including newly installed apt/dpkg packages and sudo/tsu)
// to the current app package name.
func EnsureTermuxAdapted(stateDir, cliBin string) error {
	if strings.TrimSpace(stateDir) == "" {
		return errors.New("state directory required")
	}
	appFilesDir := filepath.Dir(filepath.Clean(stateDir))
	termRoot := filepath.Join(appFilesDir, "terminal")
	prefix := filepath.Join(termRoot, "files", "usr")
	home := filepath.Join(termRoot, "files", "home")
	cacheDir := filepath.Join(termRoot, "cache")
	if st, err := os.Stat(prefix); err != nil || !st.IsDir() {
		return nil
	}
	ctx := resolveTermuxAdaptContext(stateDir, cliBin, termRoot, prefix, home, cacheDir)
	sentinel := filepath.Join(prefix, ".devicebridge-configured-v4")
	prevPrefix, prevHome, prevCache, _, _ := parseConfiguredSentinel(sentinel)
	installTermuxRootWrappers(ctx)
	adaptTermuxInstallation(ctx, prevPrefix, prevHome, prevCache)
	if cliBin != "" {
		tsnetBin := filepath.Join(prefix, "bin", "tsnet")
		configureTermuxSSH(stateDir, cliBin, termRoot, prefix, home, tsnetBin, prevPrefix != "" && prevPrefix != prefix)
	}
	sentinelContent := fmt.Sprintf("prefix=%s\nhome=%s\ncache=%s\npkg=%s\ncli=%s\n", prefix, home, cacheDir, ctx.AppPkg, cliBin)
	return writeTermuxConfig(sentinel, []byte(sentinelContent), 0o644)
}

func patchFixedCString(filePath, oldStr, newStr string) {
	if len(newStr) > len(oldStr) {
		return
	}
	raw, err := os.ReadFile(filePath)
	if err != nil || !bytes.Contains(raw, []byte(oldStr)) {
		return
	}
	padded := make([]byte, len(oldStr))
	copy(padded, []byte(newStr))
	updated := bytes.ReplaceAll(raw, []byte(oldStr), padded)
	if info, stErr := os.Stat(filePath); stErr == nil {
		_ = os.WriteFile(filePath, updated, info.Mode())
	}
}

func configureTermuxSSH(stateDir, cliBin, termRoot, prefix, home, tsnetBin string, forceRewrite bool) {
	tailnetSock := filepath.Join(stateDir, "tailnet", "control.sock")
	cacheDir := filepath.Join(termRoot, "cache")
	ctx := resolveTermuxAdaptContext(stateDir, cliBin, termRoot, prefix, home, cacheDir)
	_ = os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	_ = os.MkdirAll(filepath.Join(prefix, "etc", "ssh"), 0o755)
	_ = os.MkdirAll(filepath.Join(prefix, "var", "empty"), 0o755)
	_ = os.MkdirAll(filepath.Join(prefix, "var", "run"), 0o755)

	sshClientCfg := filepath.Join(home, ".ssh", "config")
	if existingSSH, err := os.ReadFile(sshClientCfg); os.IsNotExist(err) || forceRewrite || !strings.Contains(string(existingSSH), "DEVICEBRIDGE_TSNET_SSH_V3") {
		var preserved []string
		inManaged := false
		for _, line := range strings.Split(string(existingSSH), "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "# Shared DeviceBridge tsnet") || strings.HasPrefix(trimmed, "# DEVICEBRIDGE_TSNET_SSH_") {
				inManaged = true
				continue
			}
			if trimmed == "# END DEVICEBRIDGE_TSNET_SSH" {
				inManaged = false
				continue
			}
			if inManaged {
				if trimmed == "" || strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") ||
					trimmed == "Host 100.* *.ts.net" || strings.HasPrefix(trimmed, "Host 100.* *.ts.net ") ||
					trimmed == "Host *" || strings.HasPrefix(trimmed, "Match host ") {
					continue
				}
				inManaged = false
			}
			preserved = append(preserved, line)
		}
		block := fmt.Sprintf(`# DEVICEBRIDGE_TSNET_SSH_V4 — Shared DeviceBridge agent & tsnet ProxyCommand
Host db.*
    ProxyCommand %q --state %q agent-ssh-proxy %%h
    StrictHostKeyChecking accept-new

Match host *,!*.*,!*:*,!localhost exec "%s --state %s agent-ssh-match %%h"
    ProxyCommand %q --state %q agent-ssh-proxy %%h
    StrictHostKeyChecking accept-new

Host 100.* *.ts.net fd7a:115c:a1e0:*
    ProxyCommand %q proxy %%h %%p

Match host *,!*.*,!*:*,!localhost exec "%s match-host %%h"
    ProxyCommand %q proxy %%h %%p

Host *
    IdentityFile %s/.ssh/id_ed25519
    IdentityFile %s/.ssh/id_rsa
    UserKnownHostsFile %s/.ssh/known_hosts
# END DEVICEBRIDGE_TSNET_SSH
`, cliBin, stateDir, cliBin, stateDir, cliBin, stateDir, tsnetBin, tsnetBin, tsnetBin, home, home, home)
		tail := strings.TrimSpace(strings.Join(preserved, "\n"))
		if tail != "" {
			block += "\n" + tail + "\n"
		}
		_ = os.WriteFile(sshClientCfg, []byte(block), 0o600)
	}

	globalSSHConfig := filepath.Join(prefix, "etc", "ssh", "ssh_config")
	if existingGlobal, err := os.ReadFile(globalSSHConfig); os.IsNotExist(err) || forceRewrite || !strings.Contains(string(existingGlobal), "DEVICEBRIDGE_TSNET_SSH_V4") {
		globalCfg := fmt.Sprintf(`# DEVICEBRIDGE_TSNET_SSH_V4 — DeviceBridge system OpenSSH config (Android ignores $HOME for pw_dir)
Include %s

Host db.*
    ProxyCommand %q --state %q agent-ssh-proxy %%h
    StrictHostKeyChecking accept-new

Match host *,!*.*,!*:*,!localhost exec "%s --state %s agent-ssh-match %%h"
    ProxyCommand %q --state %q agent-ssh-proxy %%h
    StrictHostKeyChecking accept-new

Host 100.* *.ts.net fd7a:115c:a1e0:*
    ProxyCommand %q proxy %%h %%p

Match host *,!*.*,!*:*,!localhost exec "%s match-host %%h"
    ProxyCommand %q proxy %%h %%p

Host *
    IdentityFile %s/.ssh/id_ed25519
    IdentityFile %s/.ssh/id_rsa
    UserKnownHostsFile %s/.ssh/known_hosts
`, sshClientCfg, cliBin, stateDir, cliBin, stateDir, cliBin, stateDir, tsnetBin, tsnetBin, tsnetBin, home, home, home)
		_ = os.WriteFile(globalSSHConfig, []byte(globalCfg), 0o644)
	}

	dbShellPreload := fmt.Sprintf(`adapt=%q
adapt="${DEVICEBRIDGE_SSH_ADAPT_SO:-$adapt}"
if [ -r "$adapt" ]; then
  export LD_PRELOAD="$adapt"
  export DB_TERMUX_ADAPT_SO="$adapt"
fi
`, ctx.AdaptSo)
	dbShellPath := filepath.Join(prefix, "bin", "db-ssh-shell")
	dbShell := fmt.Sprintf(`#!/system/bin/sh
export PREFIX=%q
export HOME=%q
export TMPDIR="%s/tmp"
export TMUX_TMPDIR="%s/tmp"
export TERMINFO="%s/share/terminfo"
export LD_LIBRARY_PATH=%q
%sexport TERMUX_CACHE_DIR=%q
export TERMUX__CACHE_DIR=%q
export TERMUX__PREFIX=%q
export TERMUX__HOME=%q
export TERMUX__ROOTFS=%q
export TERMUX_APP__DATA_DIR=%q
export TERMUX_APP__PACKAGE_NAME=%q
export APT_CONFIG=%q
export DPKG_ADMINDIR="%s/var/lib/dpkg"
export SSL_CERT_FILE="%s/etc/tls/cert.pem"
export CURL_CA_BUNDLE="%s/etc/tls/cert.pem"
export PKG_CONFIG_PATH="%s/lib/pkgconfig:%s/share/pkgconfig"
export XDG_CONFIG_HOME="%s/.config"
export XDG_DATA_HOME="%s/.local/share"
export XDG_CACHE_HOME=%q
export DEVICEBRIDGE_STATE=%q
export DEVICEBRIDGE_CLI=%q
export DEVICEBRIDGE_TAILNET_SOCKET=%q
export PATH="%s/.local/bin:%s/bin:/system/bin"
export TERM="${TERM:-xterm-256color}"
export LANG=en_US.UTF-8
cd "$HOME" || exit 1
SHELL="$PREFIX/bin/fish"
if [ ! -x "$SHELL" ]; then SHELL="$PREFIX/bin/bash"; fi
export SHELL
if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
  case "$SSH_ORIGINAL_COMMAND" in
    */sftp-server*|internal-sftp*)
      exec "%s/libexec/sftp-server"
      ;;
  esac
  exec "$SHELL" -c "$SSH_ORIGINAL_COMMAND"
fi
exec "$SHELL" -l
`, prefix, home, prefix, prefix, prefix, termuxLDLibraryPath(prefix), dbShellPreload,
		cacheDir, cacheDir, prefix, home, filepath.Join(termRoot, "files"), ctx.AppRoot, ctx.AppPkg,
		termuxAPTConfig(prefix), prefix, prefix, prefix, prefix, prefix, home, home, cacheDir,
		stateDir, cliBin, tailnetSock, home, prefix, prefix)
	_ = os.WriteFile(dbShellPath, []byte(dbShell), 0o755)

	sshdCfgPath := filepath.Join(prefix, "etc", "ssh", "sshd_config")
	var keyLines strings.Builder
	for _, k := range []string{"ssh_host_ed25519_key", "ssh_host_rsa_key", "ssh_host_ecdsa_key"} {
		kp := filepath.Join(prefix, "etc", "ssh", k)
		if _, statErr := os.Stat(kp); statErr == nil {
			_ = os.Chmod(kp, 0o600)
			fmt.Fprintf(&keyLines, "HostKey %s\n", kp)
		}
	}
	listenAddrs := nonLoopbackNonTailscaleListenAddrs()
	var listenLines strings.Builder
	for _, addr := range listenAddrs {
		fmt.Fprintf(&listenLines, "ListenAddress %s\n", addr)
	}
	if len(listenAddrs) == 0 {
		listenLines.WriteString("# No non-loopback non-Tailscale interface addresses active\n")
	}
	sshdCfg := fmt.Sprintf(`# DEVICEBRIDGE_SSHD_V5
Port 8022
%sStrictModes no
%sAuthorizedKeysFile %s/.ssh/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PidFile %s/var/run/sshd.pid
Subsystem sftp %s/libexec/sftp-server
ForceCommand %s
`, listenLines.String(), keyLines.String(), home, prefix, prefix, dbShellPath)
	existingSSHD, sshdErr := os.ReadFile(sshdCfgPath)
	if os.IsNotExist(sshdErr) || forceRewrite || !strings.Contains(string(existingSSHD), "DEVICEBRIDGE_SSHD_V5") || string(existingSSHD) != sshdCfg {
		if sshdErr == nil {
			stopTermuxSSHDIfRunning(prefix)
		}
		_ = os.WriteFile(sshdCfgPath, []byte(sshdCfg), 0o600)
	}

	// Ensure `ssh` in $HOME/.local/bin always applies globalSSHConfig even if OpenSSH is upgraded or appRoot is long.
	localBinDir := filepath.Join(home, ".local", "bin")
	_ = os.MkdirAll(localBinDir, 0o755)
	sshWrapperPath := filepath.Join(localBinDir, "ssh")
	sshWrapper := fmt.Sprintf(`#!/system/bin/sh
CFG=%q
REAL_SSH=%q
HAS_F=0
for arg in "$@"; do
  case "$arg" in
    -F|-F*) HAS_F=1; break ;;
  esac
done
if [ "$HAS_F" -eq 0 ] && [ -r "$CFG" ] && [ -x "$REAL_SSH" ]; then
  exec "$REAL_SSH" -F "$CFG" "$@"
fi
exec "$REAL_SSH" "$@"
`, globalSSHConfig, filepath.Join(prefix, "bin", "ssh"))
	_ = os.WriteFile(sshWrapperPath, []byte(sshWrapper), 0o755)

	// Patch hardcoded /data/data/com.termux paths in OpenSSH binaries using short symlinks in appRoot.
	// Re-check dynamically in case OpenSSH packages were installed or upgraded after initial setup.
	appRoot := filepath.Dir(filepath.Dir(termRoot))
	linkTargets := map[string]string{
		"s": filepath.Join(prefix, "libexec", "sshd-session"),
		"a": filepath.Join(prefix, "libexec", "sshd-auth"),
		"c": globalSSHConfig,
		"d": sshdCfgPath,
		"m": filepath.Join(prefix, "etc", "ssh", "moduli"),
		"p": filepath.Join(prefix, "var", "run", "sshd.pid"),
	}
	for shortName, dest := range linkTargets {
		linkPath := filepath.Join(appRoot, shortName)
		if cur, rErr := os.Readlink(linkPath); rErr != nil || cur != dest {
			_ = os.Remove(linkPath)
			_ = os.Symlink(dest, linkPath)
		}
	}
	replacements := [][2]string{
		{"/data/data/com.termux/files/usr/bin/bash", "/system/bin/sh"},
		{"/data/data/com.termux/files/usr/bin/sh", "/system/bin/sh"},
		{"/data/data/com.termux/files/usr/bin/login", "/system/bin/sh"},
		{"/data/data/com.termux/files/home", "/"},
	}
	if len(appRoot)+2 <= 46 {
		replacements = append(replacements,
			[2]string{"/data/data/com.termux/files/usr/libexec/sshd-session", filepath.Join(appRoot, "s")},
			[2]string{"/data/data/com.termux/files/usr/libexec/sshd-auth", filepath.Join(appRoot, "a")},
			[2]string{"/data/data/com.termux/files/usr/etc/ssh/ssh_config", filepath.Join(appRoot, "c")},
			[2]string{"/data/data/com.termux/files/usr/etc/ssh/sshd_config", filepath.Join(appRoot, "d")},
			[2]string{"/data/data/com.termux/files/usr/etc/ssh/moduli", filepath.Join(appRoot, "m")},
			[2]string{"/data/data/com.termux/files/usr/var/run/sshd.pid", filepath.Join(appRoot, "p")},
		)
	}
	sshBins := []string{
		filepath.Join(prefix, "bin", "ssh"),
		filepath.Join(prefix, "bin", "scp"),
		filepath.Join(prefix, "bin", "sftp"),
		filepath.Join(prefix, "bin", "sshd"),
		filepath.Join(prefix, "libexec", "sshd-session"),
		filepath.Join(prefix, "libexec", "sshd-auth"),
	}
	for _, bin := range sshBins {
		for _, rep := range replacements {
			patchFixedCString(bin, rep[0], rep[1])
		}
	}
}

func isOpenSSHEnabled(stateDir string) bool {
	cfgPath := filepath.Join(stateDir, "tailnet", "tsnet-config.json")
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return false
	}
	var cfg struct {
		OpenSSHEnabled bool `json:"openssh_enabled"`
	}
	if json.Unmarshal(raw, &cfg) != nil {
		return false
	}
	return cfg.OpenSSHEnabled
}

func stopTermuxSSHDIfRunning(prefix string) {
	pidPath := filepath.Join(prefix, "var", "run", "sshd.pid")
	raw, err := os.ReadFile(pidPath)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 1 {
		return
	}
	cmdline, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil || !bytes.Contains(cmdline, []byte(prefix)) {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
	for i := 0; i < 10; i++ {
		time.Sleep(50 * time.Millisecond)
		if err := syscall.Kill(pid, 0); err != nil {
			break
		}
	}
	_ = os.Remove(pidPath)
}

func isTailscaleAddr(ip netip.Addr) bool {
	cgnat := netip.MustParsePrefix("100.64.0.0/10")
	tsULA := netip.MustParsePrefix("fd7a:115c:a1e0::/48")
	return cgnat.Contains(ip) || tsULA.Contains(ip)
}

type sshdIfaceAddrs struct {
	name     string
	up       bool
	loopback bool
	addrs    []netip.Addr
}

func filterTermuxSSHDAddrs(ifaces []sshdIfaceAddrs) []string {
	seen := make(map[string]struct{})
	var v4s, v6s []string
	for _, n := range ifaces {
		if !n.up || n.loopback {
			continue
		}
		low := strings.ToLower(strings.TrimSpace(n.name))
		if strings.HasPrefix(low, "tailscale") {
			continue
		}
		for _, raw := range n.addrs {
			ip := raw.Unmap()
			if !ip.IsValid() || ip.IsLoopback() || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || isTailscaleAddr(ip) {
				continue
			}
			s := ip.String()
			if _, ok := seen[s]; ok {
				continue
			}
			seen[s] = struct{}{}
			if ip.Is4() {
				v4s = append(v4s, s)
			} else {
				v6s = append(v6s, s)
			}
		}
	}
	sort.Strings(v4s)
	sort.Strings(v6s)
	return append(v4s, v6s...)
}

func nonLoopbackNonTailscaleListenAddrs() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	items := make([]sshdIfaceAddrs, 0, len(ifaces))
	for _, n := range ifaces {
		addrs, aErr := n.Addrs()
		if aErr != nil {
			continue
		}
		parsed := make([]netip.Addr, 0, len(addrs))
		for _, a := range addrs {
			if ipNet, ok := a.(*net.IPNet); ok {
				if ip, ok2 := netip.AddrFromSlice(ipNet.IP); ok2 {
					parsed = append(parsed, ip)
				}
			}
		}
		items = append(items, sshdIfaceAddrs{
			name:     n.Name,
			up:       n.Flags&net.FlagUp != 0,
			loopback: n.Flags&net.FlagLoopback != 0,
			addrs:    parsed,
		})
	}
	return filterTermuxSSHDAddrs(items)
}

func isTermuxSSHDRunning(prefix string) bool {
	pidPath := filepath.Join(prefix, "var", "run", "sshd.pid")
	raw, err := os.ReadFile(pidPath)
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 1 {
		return false
	}
	cmdline, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil || !bytes.Contains(cmdline, []byte(prefix)) || !bytes.Contains(cmdline, []byte("sshd")) {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

func startTermuxSSHDIfNeeded(prefix, home, adaptSo string) {
	sshdBin := filepath.Join(prefix, "bin", "sshd")
	sshdCfgPath := filepath.Join(prefix, "etc", "ssh", "sshd_config")
	if st, err := os.Stat(sshdBin); err != nil || st.IsDir() {
		return
	}
	listenAddrs := nonLoopbackNonTailscaleListenAddrs()
	if len(listenAddrs) == 0 {
		stopTermuxSSHDIfRunning(prefix)
		return
	}
	if isTermuxSSHDRunning(prefix) {
		return
	}
	if c, dialErr := net.DialTimeout("tcp", net.JoinHostPort(listenAddrs[0], "8022"), 80*time.Millisecond); dialErr == nil {
		_ = c.Close()
		return
	}
	cmd := exec.Command(sshdBin, "-f", sshdCfgPath)
	cmd.Env = []string{
		"HOME=" + home,
		"PREFIX=" + prefix,
		"TMPDIR=" + filepath.Join(prefix, "tmp"),
		"LD_LIBRARY_PATH=" + termuxLDLibraryPath(prefix),
		"PATH=" + filepath.Join(home, ".local", "bin") + ":" + filepath.Join(prefix, "bin") + ":/system/bin",
	}
	if adaptSo != "" {
		cmd.Env = append(cmd.Env, "LD_PRELOAD="+adaptSo, "DB_TERMUX_ADAPT_SO="+adaptSo)
	}
	_ = cmd.Start()
}

// EnsureTermuxSSH configures and reconciles Termux OpenSSH client/server when the isolated prefix is present.
func EnsureTermuxSSH(stateDir, cliBin string) error {
	return EnsureTermuxSSHWithMode(stateDir, cliBin, nil)
}

// EnsureTermuxSSHWithMode configures Termux OpenSSH and starts or stops sshd according to enableSSHD (or tsnet-config.json when nil).
func EnsureTermuxSSHWithMode(stateDir, cliBin string, enableSSHD *bool) error {
	if runtime.GOOS != "android" {
		return nil
	}
	appFilesDir := filepath.Dir(filepath.Clean(stateDir))
	termRoot := filepath.Join(appFilesDir, "terminal")
	prefix := filepath.Join(termRoot, "files", "usr")
	home := filepath.Join(termRoot, "files", "home")
	cacheDir := filepath.Join(termRoot, "cache")
	if _, err := os.Stat(filepath.Join(prefix, "bin", "fish")); os.IsNotExist(err) {
		if _, err := os.Stat(filepath.Join(prefix, "bin", "bash")); os.IsNotExist(err) {
			return nil
		}
	}
	wantSSHD := isOpenSSHEnabled(stateDir)
	if enableSSHD != nil {
		wantSSHD = *enableSSHD
	}
	ctx := resolveTermuxAdaptContext(stateDir, cliBin, termRoot, prefix, home, cacheDir)
	tsnetBin := filepath.Join(prefix, "bin", "tsnet")
	if _, err := os.Stat(tsnetBin); os.IsNotExist(err) {
		if err := configureTermuxPrefix(stateDir, cliBin, termRoot, prefix, home, cacheDir); err != nil {
			return err
		}
		if enableSSHD != nil {
			if wantSSHD {
				startTermuxSSHDIfNeeded(prefix, home, ctx.AdaptSo)
			} else {
				stopTermuxSSHDIfRunning(prefix)
			}
		}
		return nil
	}
	prevPrefix, _, _, _, hasSentinel := parseConfiguredSentinel(filepath.Join(prefix, ".devicebridge-configured-v4"))
	configureTermuxSSH(stateDir, cliBin, termRoot, prefix, home, tsnetBin, !hasSentinel || prevPrefix != prefix)
	fishCfg := filepath.Join(home, ".config", "fish", "config.fish")
	if existing, err := os.ReadFile(fishCfg); err == nil {
		if err := refreshTermuxFishConfig(fishCfg, existing, ctx.AdaptSo); err != nil {
			return err
		}
	}
	if wantSSHD {
		startTermuxSSHDIfNeeded(prefix, home, ctx.AdaptSo)
	} else {
		stopTermuxSSHDIfRunning(prefix)
	}
	return nil
}

func PrepareLocalTerminalEnvironment(stateDir, requestedShell string) (shellPath string, shellArgs []string, homeDir string, env []string, err error) {
	if runtime.GOOS == "android" {
		appFilesDir := filepath.Dir(filepath.Clean(stateDir))
		termRoot := filepath.Join(appFilesDir, "terminal")
		prefix := filepath.Join(termRoot, "files", "usr")
		home := filepath.Join(termRoot, "files", "home")
		tmpDir := filepath.Join(prefix, "tmp")
		cacheDir := filepath.Join(termRoot, "cache")

		_ = os.MkdirAll(prefix, 0o755)
		_ = os.MkdirAll(home, 0o755)
		_ = os.MkdirAll(tmpDir, 0o755)
		_ = os.MkdirAll(cacheDir, 0o755)

		bashBin := filepath.Join(prefix, "bin", "bash")
		if _, statErr := os.Stat(bashBin); os.IsNotExist(statErr) {
			zipArch := "aarch64"
			if runtime.GOARCH == "amd64" {
				zipArch = "x86_64"
			}
			zipPath := "/data/local/tmp/db-bootstrap-" + zipArch + ".zip"
			if _, zipErr := os.Stat(zipPath); zipErr == nil {
				if err := extractBootstrapZipIfPresent(zipPath, prefix); err != nil {
					return "", nil, "", nil, fmt.Errorf("extract Termux bootstrap: %w", err)
				}
				// A previous shell-only launch may already have set up this prefix.
				sentinel := filepath.Join(prefix, ".devicebridge-configured-v4")
				if err := os.Remove(sentinel); err != nil && !os.IsNotExist(err) {
					return "", nil, "", nil, err
				}
			}
		}
		cliBin, _ := os.Executable()
		if cliBin == "" {
			cliBin = filepath.Join(stateDir, "hotbin", "cli.bin")
		}
		tailnetSock := filepath.Join(stateDir, "tailnet", "control.sock")
		if err := configureTermuxPrefix(stateDir, cliBin, termRoot, prefix, home, cacheDir); err != nil {
			return "", nil, "", nil, fmt.Errorf("configure Termux prefix: %w", err)
		}
		ctx := resolveTermuxAdaptContext(stateDir, cliBin, termRoot, prefix, home, cacheDir)

		fishBin := filepath.Join(prefix, "bin", "fish")
		tmuxBin := filepath.Join(prefix, "bin", "tmux")
		tmuxConf := filepath.Join(home, ".tmux.conf")

		env = []string{
			"HOME=" + home,
			"PREFIX=" + prefix,
			"TMPDIR=" + tmpDir,
			"TMUX_TMPDIR=" + tmpDir,
			"TERMINFO=" + filepath.Join(prefix, "share", "terminfo"),
			"SHELL=" + fishBin,
			"LD_LIBRARY_PATH=" + termuxLDLibraryPath(prefix),
			"TERMUX_CACHE_DIR=" + cacheDir,
			"TERMUX__CACHE_DIR=" + cacheDir,
			"TERMUX__PREFIX=" + prefix,
			"TERMUX__HOME=" + home,
			"TERMUX__ROOTFS=" + filepath.Join(termRoot, "files"),
			"TERMUX_APP__DATA_DIR=" + ctx.AppRoot,
			"TERMUX_APP__PACKAGE_NAME=" + ctx.AppPkg,
			"APT_CONFIG=" + termuxAPTConfig(prefix),
			"DPKG_ADMINDIR=" + filepath.Join(prefix, "var", "lib", "dpkg"),
			"SSL_CERT_FILE=" + filepath.Join(prefix, "etc", "tls", "cert.pem"),
			"CURL_CA_BUNDLE=" + filepath.Join(prefix, "etc", "tls", "cert.pem"),
			"PKG_CONFIG_PATH=" + filepath.Join(prefix, "lib", "pkgconfig") + ":" + filepath.Join(prefix, "share", "pkgconfig"),
			"XDG_CONFIG_HOME=" + filepath.Join(home, ".config"),
			"XDG_DATA_HOME=" + filepath.Join(home, ".local", "share"),
			"XDG_CACHE_HOME=" + cacheDir,
			"STARSHIP_CONFIG=" + filepath.Join(home, ".config", "starship.toml"),
			"DEVICEBRIDGE_STATE=" + stateDir,
			"DEVICEBRIDGE_CLI=" + cliBin,
			"DEVICEBRIDGE_TAILNET_SOCKET=" + tailnetSock,
			"PATH=" + filepath.Join(home, ".local", "bin") + ":" + filepath.Join(prefix, "bin") + ":/system/bin",
			"TERM=xterm-256color",
			"COLORTERM=truecolor",
			"LANG=en_US.UTF-8",
		}
		if ctx.AdaptSo != "" {
			env = append(env, "LD_PRELOAD="+ctx.AdaptSo, "DB_TERMUX_ADAPT_SO="+ctx.AdaptSo)
		}

		type shellCandidate struct {
			path string
			args []string
		}
		candidates := []shellCandidate{
			{tmuxBin, []string{"-f", tmuxConf, "new-session", "-A", "-s", "main"}},
			{fishBin, []string{"-l"}},
			{filepath.Join(prefix, "bin", "bash"), []string{"-l"}},
			{"/system/bin/sh", nil},
		}
		if requestedShell != "" && requestedShell != "tmux" {
			var explicit shellCandidate
			switch requestedShell {
			case "fish":
				explicit = shellCandidate{fishBin, []string{"-l"}}
			case "bash":
				explicit = shellCandidate{filepath.Join(prefix, "bin", "bash"), []string{"-l"}}
			default:
				explicit = shellCandidate{requestedShell, nil}
			}
			candidates = append([]shellCandidate{explicit}, candidates...)
		}
		for _, c := range candidates {
			if st, e := os.Stat(c.path); e == nil && !st.IsDir() {
				return c.path, c.args, home, env, nil
			}
		}
		return "/system/bin/sh", nil, home, env, nil
	}

	// Linux / Desktop fresh terminal workspace
	termRoot := filepath.Join(filepath.Clean(stateDir), "terminal")
	home := filepath.Join(termRoot, "home")
	tmpDir := filepath.Join(termRoot, "tmp")
	_ = os.MkdirAll(filepath.Join(home, ".config", "fish"), 0o755)
	_ = os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	_ = os.MkdirAll(tmpDir, 0o755)

	if exePath, exeErr := os.Executable(); exeErr == nil && exePath != "" {
		sshCfgPath := filepath.Join(home, ".ssh", "config")
		realUserSSH := ""
		if realHome, hErr := os.UserHomeDir(); hErr == nil && realHome != "" && realHome != home {
			cand := filepath.Join(realHome, ".ssh", "config")
			if _, stErr := os.Stat(cand); stErr == nil {
				realUserSSH = fmt.Sprintf("Include %q\n\n", cand)
			}
		}
		if existing, rErr := os.ReadFile(sshCfgPath); os.IsNotExist(rErr) || !strings.Contains(string(existing), "DEVICEBRIDGE_LINUX_TSNET_SSH_V2") {
			sshCfg := fmt.Sprintf(`# DEVICEBRIDGE_LINUX_TSNET_SSH_V2
%sHost db.*
    ProxyCommand %q --state %q agent-ssh-proxy %%h
    StrictHostKeyChecking accept-new

Match host *,!*.*,!*:*,!localhost exec "%s --state %s agent-ssh-match %%h"
    ProxyCommand %q --state %q agent-ssh-proxy %%h
    StrictHostKeyChecking accept-new

Host 100.* *.ts.net fd7a:115c:a1e0:*
    ProxyCommand %q --state %q tsnet-proxy %%h %%p

Match host *,!*.*,!*:*,!localhost exec "%s --state %s tsnet-match %%h"
    ProxyCommand %q --state %q tsnet-proxy %%h %%p
`, realUserSSH, exePath, stateDir, exePath, stateDir, exePath, stateDir, exePath, stateDir, exePath, stateDir, exePath, stateDir)
			_ = os.WriteFile(sshCfgPath, []byte(sshCfg), 0o600)
		}
	}

	_ = configureTermuxShellExperience("", home)
	fishCfg := filepath.Join(home, ".config", "fish", "config.fish")
	if existing, statErr := os.ReadFile(fishCfg); os.IsNotExist(statErr) || (strings.HasPrefix(string(existing), "# DeviceBridge integrated Ghostty-style terminal") && !strings.Contains(string(existing), "DEVICEBRIDGE_FISH_V2")) {
		cfg := `# DeviceBridge integrated Ghostty-style terminal (DEVICEBRIDGE_FISH_V2)
set -gx fish_greeting ""
set -gx STARSHIP_CONFIG "$HOME/.config/starship.toml"
if status is-interactive
    if command -q fastfetch
        if test -f "$HOME/.config/fastfetch/config.jsonc"
            fastfetch --config "$HOME/.config/fastfetch/config.jsonc"
        else
            fastfetch
        end
    end
    if command -q starship
        starship init fish | source
    end
    if command -q zoxide
        zoxide init fish | source
    end
end
if not command -q starship
    function fish_prompt
        set -l last_status $status
        set -l cwd (prompt_pwd)
        set_color --bold cyan
        printf "󰆍 %s" $cwd
        if test $last_status -ne 0
            set_color --bold red
            printf " [%d]" $last_status
        end
        set_color --bold brgreen
        printf " ❯ "
        set_color normal
    end
end
`
		_ = os.WriteFile(fishCfg, []byte(cfg), 0o644)
	}

	baseEnv := os.Environ()
	filtered := make([]string, 0, len(baseEnv)+4)
	for _, kv := range baseEnv {
		if strings.HasPrefix(kv, "HOME=") || strings.HasPrefix(kv, "TERM=") || strings.HasPrefix(kv, "COLORTERM=") {
			continue
		}
		filtered = append(filtered, kv)
	}
	filtered = append(filtered,
		"HOME="+home,
		"TERM=xterm-256color",
		"COLORTERM=truecolor",
	)

	var names []string
	if requestedShell != "" {
		names = append(names, requestedShell)
	}
	names = append(names, "fish", "bash", "sh")
	for _, name := range names {
		if resolved, lookErr := exec.LookPath(name); lookErr == nil {
			var args []string
			if strings.HasSuffix(resolved, "/fish") || strings.HasSuffix(resolved, "/bash") {
				args = []string{"-l"}
			}
			return resolved, args, home, filtered, nil
		}
	}
	return "/bin/sh", nil, home, filtered, nil
}

type localTerminalSink struct {
	mu      sync.Mutex
	encoder *json.Encoder
}

func (s *localTerminalSink) emit(frame TerminalFrame) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.encoder.Encode(frame)
}

func remoteTerminalCommand(ctx context.Context, stateDir, home string, env []string, target RemoteTerminalTarget) (string, []string, error) {
	if len(target.Peer) != 64 || strings.IndexFunc(target.Peer, func(r rune) bool {
		return !strings.ContainsRune("0123456789abcdef", r)
	}) >= 0 {
		return "", nil, errors.New("invalid paired device identity")
	}
	cli, err := os.Executable()
	if err != nil {
		return "", nil, err
	}
	var sshBin, tmuxBin string
	var tmuxConfig []string
	if runtime.GOOS == "android" {
		prefix := filepath.Join(filepath.Dir(home), "usr")
		sshBin = filepath.Join(prefix, "bin", "ssh")
		tmuxBin = filepath.Join(prefix, "bin", "tmux")
		tmuxConfig = []string{"-f", filepath.Join(home, ".tmux.conf")}
	} else {
		sshBin, _ = exec.LookPath("ssh")
		tmuxBin, _ = exec.LookPath("tmux")
		tmuxConfig = []string{"-L", "devicebridge"}
	}
	proxy := []string{cli, "--state", stateDir}
	for _, arg := range [][2]string{
		{"--transport", target.Transport}, {"--endpoint", target.Endpoint},
		{"--interface", target.Interface}, {"--lan-cidr", target.CIDR},
	} {
		if arg[1] != "" {
			proxy = append(proxy, arg[0], arg[1])
		}
	}
	proxy = append(proxy, "agent-ssh-proxy", target.Peer)
	if runtime.GOOS == "android" {
		// Bionic must load the native Go executable with Android libraries.
		// The surrounding OpenSSH and tmux processes still need Termux libraries.
		proxy = append([]string{"/system/bin/sh", "-c", `unset LD_LIBRARY_PATH LD_PRELOAD; exec "$@"`, "devicebridge"}, proxy...)
	}
	for i := range proxy {
		proxy[i] = shellQuote(strings.ReplaceAll(proxy[i], "%", "%%"))
	}
	if st, err := os.Stat(sshBin); err != nil || st.Mode()&0o111 == 0 {
		return "", nil, errors.New("OpenSSH is unavailable in the local terminal")
	}
	sshArgs := []string{"-tt", "-F", "/dev/null",
		"-o", "ProxyCommand=" + strings.Join(proxy, " "),
		"-o", "UserKnownHostsFile=" + strconv.Quote(filepath.Join(home, ".ssh", "known_hosts")),
		"-o", "HostKeyAlias=db." + target.Peer, "-o", "StrictHostKeyChecking=accept-new",
		"-o", "BatchMode=yes", "-o", "ConnectTimeout=12", "db." + target.Peer,
	}
	if st, err := os.Stat(tmuxBin); err != nil || st.Mode()&0o111 == 0 {
		return sshBin, sshArgs, nil
	}
	tmux := func(args ...string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, tmuxBin, append(append([]string{}, tmuxConfig...), args...)...)
		cmd.Dir, cmd.Env = home, env
		return cmd
	}
	if tmux("has-session", "-t", "=main").Run() != nil {
		if output, err := tmux("new-session", "-d", "-s", "main").CombinedOutput(); err != nil &&
			tmux("has-session", "-t", "=main").Run() != nil {
			return "", nil, fmt.Errorf("start terminal workspace: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}
	name := strings.Map(func(r rune) rune {
		if r < 32 || r == 127 || r == ';' {
			return -1
		}
		return r
	}, target.Name)
	if name == "" {
		name = "SSH"
	}
	shell := "/bin/sh"
	if runtime.GOOS == "android" {
		shell = "/system/bin/sh"
	}
	// Keep a failed connection's diagnostic visible instead of silently switching
	// the attached workspace back to its previous (local) window.
	const runSSH = `SHELL=$1; export SHELL; shift; "$@"; code=$?; if [ "$code" -ne 0 ]; then printf '\nSSH exited (%s). Press Enter to close this window.\n' "$code"; read -r reply; fi; exit "$code"`
	var paneEnv []string
	if runtime.GOOS == "android" {
		// A tmux server can outlive an APK update and retain the old native library path.
		for _, value := range env {
			paneEnv = append(paneEnv, "-e", value)
		}
	}
	args := append([]string{"new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=main:", "-n", name}, paneEnv...)
	args = append(args, "--", shell, "-c", runSSH, "devicebridge", shell, sshBin)
	args = append(args, sshArgs...)
	output, err := tmux(args...).CombinedOutput()
	if err != nil {
		return "", nil, fmt.Errorf("open SSH window: %w: %s", err, strings.TrimSpace(string(output)))
	}
	window := strings.TrimSpace(string(output))
	// Link the same window into a single-window session for the app's SSH view.
	// When SSH exits, that view detaches while the main workspace stays open.
	session := "devicebridge-ssh-" + strings.TrimPrefix(window, "@")
	args = append([]string{"new-session", "-d", "-P", "-F", "#{window_index}", "-s", session}, paneEnv...)
	args = append(args, "--", shell, "-c", "read -r line")
	output, err = tmux(args...).CombinedOutput()
	if err != nil {
		_ = tmux("kill-window", "-t", window).Run()
		return "", nil, fmt.Errorf("prepare SSH view: %w: %s", err, strings.TrimSpace(string(output)))
	}
	slot := "=" + session + ":" + strings.TrimSpace(string(output))
	if output, err = tmux("link-window", "-k", "-s", window, "-t", slot).CombinedOutput(); err != nil {
		_ = tmux("kill-session", "-t", "="+session).Run()
		_ = tmux("kill-window", "-t", window).Run()
		return "", nil, fmt.Errorf("link SSH window: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return tmuxBin, append(tmuxConfig, "attach-session", "-t", "="+session), nil
}

func RunLocalTerminal(ctx context.Context, stateDir string, request LocalTerminalRequest, input *bufio.Scanner, output io.Writer) error {
	if strings.TrimSpace(stateDir) == "" {
		return errors.New("state directory required")
	}
	shellPath, shellArgs, homeDir, env, err := PrepareLocalTerminalEnvironment(stateDir, request.Shell)
	if err != nil {
		return err
	}
	if request.Remote != nil {
		shellPath, shellArgs, err = remoteTerminalCommand(ctx, stateDir, homeDir, env, *request.Remote)
		if err != nil {
			return err
		}
	}
	master, slave, err := pty.Open(request.Columns, request.Rows)
	if err != nil {
		return err
	}
	defer master.Close()

	cmd := exec.CommandContext(ctx, shellPath, shellArgs...)
	cmd.Dir = homeDir
	cmd.Env = env
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid:  true,
		Setctty: true,
		Ctty:    0,
	}

	if err := cmd.Start(); err != nil {
		_ = slave.Close()
		return fmt.Errorf("start shell %s: %w", shellPath, err)
	}
	_ = slave.Close()

	sink := &localTerminalSink{encoder: json.NewEncoder(output)}
	if err := sink.emit(TerminalFrame{State: "ready"}); err != nil {
		_ = cmd.Process.Kill()
		return err
	}

	readDone := make(chan error, 1)
	go func() {
		buf := make([]byte, 8192)
		for {
			n, rerr := master.Read(buf)
			if n > 0 {
				chunk := make([]byte, n)
				copy(chunk, buf[:n])
				if e := sink.emit(TerminalFrame{Data: chunk}); e != nil {
					readDone <- e
					return
				}
			}
			if rerr != nil {
				if errors.Is(rerr, io.EOF) || errors.Is(rerr, syscall.EIO) {
					readDone <- nil
				} else {
					readDone <- rerr
				}
				return
			}
		}
	}()

	inputDone := make(chan error, 1)
	go func() {
		for input.Scan() {
			var frame TerminalFrame
			if err := json.Unmarshal(input.Bytes(), &frame); err != nil {
				inputDone <- err
				return
			}
			if len(frame.Data) > 0 {
				if _, err := master.Write(frame.Data); err != nil {
					inputDone <- err
					return
				}
			}
			if frame.Columns > 0 && frame.Rows > 0 {
				_ = pty.SetSize(master, frame.Columns, frame.Rows)
				if cmd.Process != nil {
					_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGWINCH)
				}
			}
		}
		inputDone <- input.Err()
	}()

	waitDone := make(chan error, 1)
	go func() {
		waitDone <- cmd.Wait()
	}()

	select {
	case <-waitDone:
		_ = master.Close()
		<-readDone
		return nil
	case err := <-readDone:
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
		return err
	case err := <-inputDone:
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
		return err
	case <-ctx.Done():
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
		return nil
	}
}
