package bootstrap

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	termuxStarshipSentinel  = "# DEVICEBRIDGE_STARSHIP_V2"
	termuxFastfetchSentinel = "// DEVICEBRIDGE_FASTFETCH_V2"
	termuxBashSentinel      = "# DEVICEBRIDGE_BASH_V2"
)

func termuxSystemLibDir() string {
	switch runtime.GOARCH {
	case "amd64", "arm64":
		return "/system/lib64"
	default:
		return "/system/lib"
	}
}

func termuxLDLibraryPath(prefix string) string {
	return termuxSystemLibDir() + ":" + filepath.Join(prefix, "lib")
}

func termuxStarshipConfig() string {
	return termuxStarshipSentinel + ` — DeviceBridge Terminal prompt (MesloLGS NF + theme-adaptive ANSI colors)
"$schema" = 'https://starship.rs/config-schema.json'

add_newline = true
command_timeout = 800
scan_timeout = 30

format = """
[╭─](bold cyan)$os$username$hostname$directory$git_branch$git_status$python$nodejs$golang$rust$cmd_duration$jobs
[╰─](bold cyan)$character"""

[os]
disabled = false
style = "bold cyan"
format = "[$symbol ]($style)"

[os.symbols]
Android = ""
Linux = ""

[username]
show_always = false
style_user = "bold blue"
format = "[$user]($style) "

[hostname]
ssh_only = true
ssh_symbol = "󰣀 "
style = "bold magenta"
format = "[@$ssh_symbol$hostname]($style) "

[directory]
truncation_length = 3
truncation_symbol = "…/"
home_symbol = " ~"
style = "bold cyan"
read_only = " 󰌾"
read_only_style = "red"
format = "[$path]($style)[$read_only]($read_only_style) "

[git_branch]
symbol = " "
style = "bold purple"
format = "[on $symbol$branch(:$remote_branch)]($style) "

[git_status]
style = "bold yellow"
format = '([\[$all_status$ahead_behind\]]($style) )'

[python]
symbol = " "
style = "yellow"
format = "[$symbol$pyenv_prefix($version )]($style)"

[nodejs]
symbol = " "
style = "green"
format = "[$symbol($version )]($style)"

[golang]
symbol = " "
style = "cyan"
format = "[$symbol($version )]($style)"

[rust]
symbol = " "
style = "red"
format = "[$symbol($version )]($style)"

[cmd_duration]
min_time = 2000
style = "bold yellow"
format = "[󱎫 $duration]($style) "

[jobs]
symbol = "✦"
style = "bold blue"
format = "[$symbol$number]($style) "

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vimcmd_symbol = "[❮](bold yellow)"
`
}

func termuxFastfetchConfig() string {
	diskFolders := "/"
	if runtime.GOOS == "android" {
		diskFolders = "/data"
	}
	const animeLogo = "     \x1b[38;5;213m▄█████▄ ▄████▄\x1b[0m\n" +
		"    \x1b[38;5;213m██\x1b[38;5;219m▓▓▓▓▓\x1b[38;5;213m███\x1b[38;5;219m▓▓▓▓\x1b[38;5;213m██\x1b[0m\n" +
		"   \x1b[38;5;213m█\x1b[38;5;223m ╭───────────╮ \x1b[38;5;213m█\x1b[0m\n" +
		"   \x1b[38;5;213m█\x1b[38;5;223m │ \x1b[38;5;45m◉\x1b[38;5;223m       \x1b[38;5;45m◉\x1b[38;5;223m │ \x1b[38;5;213m█\x1b[0m\n" +
		"   \x1b[38;5;213m█\x1b[38;5;223m │ \x1b[38;5;211m〃\x1b[38;5;223m  ╰─╯  \x1b[38;5;211m〃\x1b[38;5;223m │ \x1b[38;5;213m█\x1b[0m\n" +
		"    \x1b[38;5;147m╭┴─────────┴╮\x1b[0m\n" +
		"   \x1b[38;5;81m▄█│ \x1b[1;38;5;117mTermux\x1b[0;38;5;81m   │█▄\x1b[0m\n" +
		"   \x1b[38;5;81m▀ ╰───────────╯ ▀\x1b[0m"
	// Escape as JSON string literal for fastfetch inline data logo.
	escapedLogo := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\x1b", `\u001b`, "\n", `\n`).Replace(animeLogo)
	return termuxFastfetchSentinel + ` — 49-col portrait-safe layout (top ANSI logo + compact card)
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "data",
    "source": "` + escapedLogo + `",
    "position": "top",
    "padding": {
      "top": 0,
      "left": 2,
      "bottom": 1
    }
  },
  "display": {
    "separator": " "
  },
  "modules": [
    {
      "key": "╭──────────╮",
      "type": "custom"
    },
    {
      "key": "│ {#36} user   {#keys}│",
      "type": "title",
      "format": "{user-name}@{host-name}"
    },
    {
      "key": "│ {#34} os     {#keys}│",
      "type": "os",
      "format": "{name} {arch}"
    },
    {
      "key": "│ {#35} kernel {#keys}│",
      "type": "kernel",
      "format": "{release}"
    },
    {
      "key": "│ {#33}󰅐 uptime {#keys}│",
      "type": "uptime",
      "format": "{days}d {hours}h {minutes}m"
    },
    {
      "key": "│ {#32} shell  {#keys}│",
      "type": "shell",
      "format": "{process-name} {version}"
    },
    {
      "key": "│ {#36} term   {#keys}│",
      "type": "terminal",
      "format": "{pretty-name}"
    },
    {
      "key": "│ {#34}󰏖 pkgs   {#keys}│",
      "type": "packages"
    },
    {
      "key": "│ {#35} memory {#keys}│",
      "type": "memory",
      "format": "{used} / {total}"
    },
    {
      "key": "│ {#33}󰉉 disk   {#keys}│",
      "type": "disk",
      "folders": "` + diskFolders + `",
      "format": "{size-used} / {size-total}"
    },
    {
      "key": "│ {#32}󰩟 ip     {#keys}│",
      "type": "localip",
      "showPrefixLen": false,
      "format": "{ipv4}"
    },
    {
      "key": "├──────────┤",
      "type": "custom"
    },
    {
      "key": "│ {#39} colors {#keys}│",
      "type": "colors",
      "symbol": "circle"
    },
    {
      "key": "╰──────────╯",
      "type": "custom"
    }
  ]
}
`
}

func configureTermuxShellExperience(prefix, home string) error {
	configDir := filepath.Join(home, ".config")
	fastfetchDir := filepath.Join(configDir, "fastfetch")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(fastfetchDir, 0o755); err != nil {
		return err
	}

	starshipPath := filepath.Join(configDir, "starship.toml")
	if existing, err := os.ReadFile(starshipPath); os.IsNotExist(err) || strings.HasPrefix(string(existing), "# DEVICEBRIDGE_STARSHIP_V") {
		if err := writeTermuxConfig(starshipPath, []byte(termuxStarshipConfig()), 0o644); err != nil {
			return err
		}
	}

	fastfetchPath := filepath.Join(fastfetchDir, "config.jsonc")
	if existing, err := os.ReadFile(fastfetchPath); os.IsNotExist(err) || strings.HasPrefix(string(existing), "// DEVICEBRIDGE_FASTFETCH_V") {
		if err := writeTermuxConfig(fastfetchPath, []byte(termuxFastfetchConfig()), 0o644); err != nil {
			return err
		}
	}

	if prefix != "" {
		bashrcPath := filepath.Join(home, ".bashrc")
		if existing, err := os.ReadFile(bashrcPath); os.IsNotExist(err) || strings.HasPrefix(string(existing), "# DEVICEBRIDGE_BASH_V") {
			bashrc := fmt.Sprintf(`%s
export PREFIX=%q
export LD_LIBRARY_PATH=%q
export APT_CONFIG="$PREFIX/etc/devicebridge/apt.conf"
export DPKG_ADMINDIR="$PREFIX/var/lib/dpkg"
export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
export CURL_CA_BUNDLE="$PREFIX/etc/tls/cert.pem"
export STARSHIP_CONFIG="$HOME/.config/starship.toml"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PREFIX/bin:/system/bin:$PATH" ;;
esac
case $- in
  *i*)
    alias ll='ls -lh'
    alias la='ls -lha'
    alias cls='clear'
    if command -v fastfetch >/dev/null 2>&1; then
      if [ -f "$HOME/.config/fastfetch/config.jsonc" ]; then
        fastfetch --config "$HOME/.config/fastfetch/config.jsonc"
      else
        fastfetch
      fi
    fi
    if command -v starship >/dev/null 2>&1; then
      eval "$(starship init bash)"
    else
      PS1='\[\033[1;36m\]\w\[\033[0m\] \[\033[1;32m\]❯\[\033[0m\] '
    fi
    if command -v zoxide >/dev/null 2>&1; then
      eval "$(zoxide init bash)"
    fi
    ;;
esac
`, termuxBashSentinel, prefix, termuxLDLibraryPath("$PREFIX"))
			if err := writeTermuxConfig(bashrcPath, []byte(bashrc), 0o644); err != nil {
				return err
			}
		}

		bashProfilePath := filepath.Join(home, ".bash_profile")
		if existing, err := os.ReadFile(bashProfilePath); os.IsNotExist(err) || strings.HasPrefix(string(existing), "# DEVICEBRIDGE_BASH_V") {
			bashProfile := termuxBashSentinel + "\nif [ -r \"$HOME/.bashrc\" ]; then\n  . \"$HOME/.bashrc\"\nfi\n"
			if err := writeTermuxConfig(bashProfilePath, []byte(bashProfile), 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

func termuxBootstrapArch() string {
	switch runtime.GOARCH {
	case "amd64":
		return "x86_64"
	case "arm":
		return "arm"
	case "386":
		return "i686"
	default:
		return "aarch64"
	}
}

func isExecutableFile(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
}

// SetupTermuxEnvironment extracts a staged Termux bootstrap archive if needed,
// installs missing default terminal tools (fish, tmux, openssh, starship, fastfetch, zoxide),
// adapts paths to the app package, and writes fish/starship/fastfetch/bash configs.
func SetupTermuxEnvironment(ctx context.Context, stateDir, cliBin string, progress func(string)) error {
	if runtime.GOOS != "android" {
		return nil
	}
	emit := func(line string) {
		if progress != nil && strings.TrimSpace(line) != "" {
			progress(line)
		}
	}
	appFilesDir := filepath.Dir(filepath.Clean(stateDir))
	termRoot := filepath.Join(appFilesDir, "terminal")
	prefix := filepath.Join(termRoot, "files", "usr")
	home := filepath.Join(termRoot, "files", "home")
	tmpDir := filepath.Join(prefix, "tmp")
	cacheDir := filepath.Join(termRoot, "cache")

	for _, d := range []string{prefix, home, tmpDir, cacheDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}

	bashBin := filepath.Join(prefix, "bin", "bash")
	if !isExecutableFile(bashBin) {
		zipArch := termuxBootstrapArch()
		candidates := []string{
			strings.TrimSpace(os.Getenv("DEVICEBRIDGE_BOOTSTRAP_ZIP")),
			filepath.Join(cacheDir, "bootstrap-"+zipArch+".zip"),
			"/data/local/tmp/db-bootstrap-" + zipArch + ".zip",
		}
		var stagedZip string
		for _, cand := range candidates {
			if cand != "" {
				if st, err := os.Stat(cand); err == nil && !st.IsDir() && st.Size() > 0 {
					stagedZip = cand
					break
				}
			}
		}
		if stagedZip == "" {
			return errors.New("Termux bootstrap archive not found; download bootstrap-" + zipArch + ".zip first")
		}
		emit("Extracting Termux base environment...")
		if err := extractBootstrapZipIfPresent(stagedZip, prefix); err != nil {
			return fmt.Errorf("extract Termux bootstrap: %w", err)
		}
		if strings.HasPrefix(stagedZip, cacheDir+string(filepath.Separator)) {
			_ = os.Remove(stagedZip)
		}
		_ = os.Remove(filepath.Join(prefix, ".devicebridge-configured-v4"))
	}

	if err := configureTermuxPrefix(stateDir, cliBin, termRoot, prefix, home, cacheDir); err != nil {
		return fmt.Errorf("configure Termux prefix: %w", err)
	}

	// Ensure default shells and prompt/diagnostic packages are installed via APT.
	requiredBins := []struct {
		bin string
		pkg string
	}{
		{filepath.Join(prefix, "bin", "fish"), "fish"},
		{filepath.Join(prefix, "bin", "tmux"), "tmux"},
		{filepath.Join(prefix, "bin", "ssh"), "openssh"},
		{filepath.Join(prefix, "bin", "starship"), "starship"},
		{filepath.Join(prefix, "bin", "fastfetch"), "fastfetch"},
		{filepath.Join(prefix, "bin", "zoxide"), "zoxide"},
	}
	var missingPkgs []string
	for _, item := range requiredBins {
		if !isExecutableFile(item.bin) {
			missingPkgs = append(missingPkgs, item.pkg)
		}
	}

	aptGet := filepath.Join(prefix, "bin", "apt-get")
	if len(missingPkgs) > 0 && isExecutableFile(aptGet) {
		adaptCtx := resolveTermuxAdaptContext(stateDir, cliBin, termRoot, prefix, home, cacheDir)
		aptEnv := []string{
			"HOME=" + home,
			"PREFIX=" + prefix,
			"TMPDIR=" + tmpDir,
			"TERMUX_CACHE_DIR=" + cacheDir,
			"TERMUX__CACHE_DIR=" + cacheDir,
			"TERMUX__PREFIX=" + prefix,
			"TERMUX__HOME=" + home,
			"TERMUX__ROOTFS=" + filepath.Join(termRoot, "files"),
			"TERMUX_APP__DATA_DIR=" + adaptCtx.AppRoot,
			"TERMUX_APP__PACKAGE_NAME=" + adaptCtx.AppPkg,
			"APT_CONFIG=" + termuxAPTConfig(prefix),
			"DPKG_ADMINDIR=" + filepath.Join(prefix, "var", "lib", "dpkg"),
			"SSL_CERT_FILE=" + filepath.Join(prefix, "etc", "tls", "cert.pem"),
			"CURL_CA_BUNDLE=" + filepath.Join(prefix, "etc", "tls", "cert.pem"),
			"DEBIAN_FRONTEND=noninteractive",
			"LD_LIBRARY_PATH=" + termuxLDLibraryPath(prefix),
			"PATH=" + filepath.Join(home, ".local", "bin") + ":" + filepath.Join(prefix, "bin") + ":/system/bin",
			"LANG=en_US.UTF-8",
		}
		if adaptCtx.AdaptSo != "" {
			aptEnv = append(aptEnv, "LD_PRELOAD="+adaptCtx.AdaptSo, "DB_TERMUX_ADAPT_SO="+adaptCtx.AdaptSo)
		}

		runAPT := func(desc string, args ...string) error {
			emit(desc)
			cmd := exec.CommandContext(ctx, aptGet, args...)
			cmd.Dir = home
			cmd.Env = aptEnv
			pr, pw, err := os.Pipe()
			if err != nil {
				return err
			}
			cmd.Stdout = pw
			cmd.Stderr = pw
			if err := cmd.Start(); err != nil {
				_ = pr.Close()
				_ = pw.Close()
				return err
			}
			_ = pw.Close()
			scanner := bufio.NewScanner(pr)
			var tail []string
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if line == "" {
					continue
				}
				tail = append(tail, line)
				if len(tail) > 8 {
					tail = tail[1:]
				}
				if strings.HasPrefix(line, "Get:") || strings.HasPrefix(line, "Setting up ") ||
					strings.HasPrefix(line, "Unpacking ") || strings.HasPrefix(line, "Fetched ") ||
					strings.HasPrefix(line, "E:") {
					emit("  " + line)
				}
			}
			_, _ = io.Copy(io.Discard, pr)
			_ = pr.Close()
			if err := cmd.Wait(); err != nil {
				return fmt.Errorf("%w (%s)", err, strings.Join(tail, " | "))
			}
			return nil
		}

		if err := runAPT("Updating Termux package repositories...", "update"); err != nil {
			return fmt.Errorf("apt-get update: %w", err)
		}
		installArgs := append([]string{"install", "-y", "--no-install-recommends", "-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold"}, missingPkgs...)
		if err := runAPT("Installing "+strings.Join(missingPkgs, ", ")+"...", installArgs...); err != nil {
			return fmt.Errorf("apt-get install: %w", err)
		}
	}

	sshKeygen := filepath.Join(prefix, "bin", "ssh-keygen")
	hostKey := filepath.Join(prefix, "etc", "ssh", "ssh_host_ed25519_key")
	if isExecutableFile(sshKeygen) {
		if _, err := os.Stat(hostKey); os.IsNotExist(err) {
			emit("Generating OpenSSH host keys...")
			adaptCtx := resolveTermuxAdaptContext(stateDir, cliBin, termRoot, prefix, home, cacheDir)
			kg := exec.CommandContext(ctx, sshKeygen, "-A")
			kg.Dir = home
			kg.Env = []string{
				"PREFIX=" + prefix,
				"HOME=" + home,
				"LD_LIBRARY_PATH=" + termuxLDLibraryPath(prefix),
				"PATH=" + filepath.Join(prefix, "bin") + ":/system/bin",
			}
			if adaptCtx.AdaptSo != "" {
				kg.Env = append(kg.Env, "LD_PRELOAD="+adaptCtx.AdaptSo, "DB_TERMUX_ADAPT_SO="+adaptCtx.AdaptSo)
			}
			_ = kg.Run()
		}
	}

	if err := EnsureTermuxAdapted(stateDir, cliBin); err != nil {
		return fmt.Errorf("adapt Termux installation: %w", err)
	}
	if err := configureTermuxPrefix(stateDir, cliBin, termRoot, prefix, home, cacheDir); err != nil {
		return fmt.Errorf("finalize Termux config: %w", err)
	}
	emit("Termux environment ready.")
	return nil
}
