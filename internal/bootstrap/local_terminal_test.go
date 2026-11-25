package bootstrap

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestRunLocalTerminalRoundTrip(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stateDir := t.TempDir()
	inReader, inWriter := io.Pipe()
	outReader, outWriter := io.Pipe()

	done := make(chan error, 1)
	go func() {
		defer outWriter.Close()
		done <- RunLocalTerminal(ctx, stateDir, LocalTerminalRequest{
			Columns: 80,
			Rows:    24,
			Shell:   "/bin/sh",
		}, bufio.NewScanner(inReader), outWriter)
	}()

	scanner := bufio.NewScanner(outReader)
	if !scanner.Scan() {
		t.Fatalf("expected ready frame, err=%v", scanner.Err())
	}
	var first TerminalFrame
	if err := json.Unmarshal(scanner.Bytes(), &first); err != nil || first.State != "ready" {
		t.Fatalf("unexpected first frame: %s (%v)", scanner.Text(), err)
	}

	cmdFrame, _ := json.Marshal(TerminalFrame{
		Data:    []byte("echo LOCAL_PTY_OK_42; exit\n"),
		Columns: 100,
		Rows:    30,
	})
	if _, err := inWriter.Write(append(cmdFrame, '\n')); err != nil {
		t.Fatalf("write input frame: %v", err)
	}

	var output bytes.Buffer
	for scanner.Scan() {
		var f TerminalFrame
		if err := json.Unmarshal(scanner.Bytes(), &f); err != nil {
			t.Fatalf("decode output frame: %v", err)
		}
		output.Write(f.Data)
		if strings.Contains(output.String(), "LOCAL_PTY_OK_42") {
			break
		}
	}
	_ = inWriter.Close()
	if !strings.Contains(output.String(), "LOCAL_PTY_OK_42") {
		t.Fatalf("expected LOCAL_PTY_OK_42 in output, got %q", output.String())
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("RunLocalTerminal returned error: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for RunLocalTerminal exit")
	}
}

func TestConfigureTermuxPrefixUpgradesSSHConfigAndTsnetWrapper(t *testing.T) {
	tmp := t.TempDir()
	stateDir := filepath.Join(tmp, "state")
	termRoot := filepath.Join(tmp, "terminal")
	prefix := filepath.Join(termRoot, "files", "usr")
	home := filepath.Join(termRoot, "files", "home")
	cache := filepath.Join(termRoot, "cache")
	if err := os.MkdirAll(filepath.Join(home, ".ssh"), 0o700); err != nil {
		t.Fatal(err)
	}
	legacySSH := "# Shared DeviceBridge tsnet ProxyCommand for Tailscale peers\nHost 100.* *.ts.net\n    ProxyCommand \"/old/tsnet\" proxy %h %p\n\nHost custombox\n    User alice\n"
	if err := os.WriteFile(filepath.Join(home, ".ssh", "config"), []byte(legacySSH), 0o600); err != nil {
		t.Fatal(err)
	}
	configureTermuxPrefix(stateDir, "/app/cli.bin", termRoot, prefix, home, cache)

	tsnetRaw, err := os.ReadFile(filepath.Join(prefix, "bin", "tsnet"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(tsnetRaw), "unset LD_LIBRARY_PATH") || !strings.Contains(string(tsnetRaw), "tsnet-match") || !strings.Contains(string(tsnetRaw), `[ ! -x "$CLI" ]`) || !strings.Contains(string(tsnetRaw), "hotbin/cli_") {
		t.Fatalf("unexpected tsnet wrapper: %s", string(tsnetRaw))
	}

	sshWrapperRaw, err := os.ReadFile(filepath.Join(home, ".local", "bin", "ssh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(sshWrapperRaw), `-F "$CFG"`) || !strings.Contains(string(sshWrapperRaw), "REAL_SSH=") {
		t.Fatalf("unexpected ssh wrapper: %s", string(sshWrapperRaw))
	}

	fishRaw, err := os.ReadFile(filepath.Join(home, ".config", "fish", "config.fish"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(fishRaw), "if not set -q DEVICEBRIDGE_CLI") {
		t.Fatalf("expected guarded DEVICEBRIDGE_CLI in fish config: %s", string(fishRaw))
	}

	sshCfgRaw, err := os.ReadFile(filepath.Join(home, ".ssh", "config"))
	if err != nil {
		t.Fatal(err)
	}
	sshCfg := string(sshCfgRaw)
	if !strings.Contains(sshCfg, "DEVICEBRIDGE_TSNET_SSH_V4") || !strings.Contains(sshCfg, "agent-ssh-proxy") || !strings.Contains(sshCfg, "agent-ssh-match") || !strings.Contains(sshCfg, "*,!*.*,!*:*,!localhost") || !strings.Contains(sshCfg, "match-host %h") || !strings.Contains(sshCfg, "Host custombox") {
		t.Fatalf("unexpected ssh config upgrade: %s", sshCfg)
	}
	sshdCfgRaw, err := os.ReadFile(filepath.Join(prefix, "etc", "ssh", "sshd_config"))
	if err != nil {
		t.Fatal(err)
	}
	sshdCfg := string(sshdCfgRaw)
	if !strings.Contains(sshdCfg, "DEVICEBRIDGE_SSHD_V5") || !strings.Contains(sshdCfg, "Port 8022") || !strings.Contains(sshdCfg, "PasswordAuthentication no") || !strings.Contains(sshdCfg, "PubkeyAuthentication yes") || !strings.Contains(sshdCfg, "StrictModes no") || !strings.Contains(sshdCfg, "ForceCommand") || strings.Contains(sshdCfg, "ListenAddress 127.0.0.1") {
		t.Fatalf("unexpected sshd config: %s", sshdCfg)
	}
	if isOpenSSHEnabled(stateDir) {
		t.Fatal("expected OpenSSH disabled by default when tsnet-config.json is absent")
	}
	if err := os.MkdirAll(filepath.Join(stateDir, "tailnet"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "tailnet", "tsnet-config.json"), []byte(`{"openssh_enabled":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if !isOpenSSHEnabled(stateDir) {
		t.Fatal("expected OpenSSH enabled when tsnet-config.json sets openssh_enabled=true")
	}
	if _, err := os.Stat(filepath.Join(prefix, "bin", "db-ssh-shell")); err != nil {
		t.Fatalf("missing db-ssh-shell: %v", err)
	}
	tmuxRaw, err := os.ReadFile(filepath.Join(home, ".tmux.conf"))
	if err != nil {
		t.Fatal(err)
	}
	tmuxCfg := string(tmuxRaw)
	if !strings.Contains(tmuxCfg, "DEVICEBRIDGE_TMUX_V7") || !strings.Contains(tmuxCfg, "unbind-key -T root MouseDrag1Pane") || !strings.Contains(tmuxCfg, "bind-key -n M-v copy-mode") {
		t.Fatalf("unexpected tmux config: %s", tmuxCfg)
	}
}

func TestConfigureTermuxPrefixAdaptsPackagesSudoAndPackageRename(t *testing.T) {
	tmp := t.TempDir()
	appDir1 := filepath.Join(tmp, "data", "user", "0", "com.example.alpha")
	state1 := filepath.Join(appDir1, "files", "devicebridge")
	termRoot1 := filepath.Join(appDir1, "files", "terminal")
	prefix1 := filepath.Join(termRoot1, "files", "usr")
	home1 := filepath.Join(termRoot1, "files", "home")
	cache1 := filepath.Join(termRoot1, "cache")

	if err := os.MkdirAll(filepath.Join(prefix1, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(prefix1, "data", "data", "com.termux", "files", "usr", "share", "doc"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prefix1, "data", "data", "com.termux", "files", "usr", "share", "doc", "note.txt"), []byte("from /data/data/com.termux/files/usr"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prefix1, "bin", "pkg"), []byte("#!/data/data/com.termux/files/usr/bin/bash\nPREFIX=/data/data/com.termux/files/usr\nHOME=/data/data/com.termux/files/home\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/data/data/com.termux/files/usr/bin/pkg", filepath.Join(prefix1, "bin", "pkg-alias")); err != nil {
		t.Fatal(err)
	}

	t.Setenv("DEVICEBRIDGE_APP_PACKAGE", "com.example.alpha")
	if err := configureTermuxPrefix(state1, "/app/cli.bin", termRoot1, prefix1, home1, cache1); err != nil {
		t.Fatal(err)
	}

	pkgBytes, err := os.ReadFile(filepath.Join(prefix1, "bin", "pkg"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(pkgBytes), "com.termux") || !strings.Contains(string(pkgBytes), prefix1) || !strings.Contains(string(pkgBytes), home1) {
		t.Fatalf("pkg script was not adapted to %s: %s", prefix1, string(pkgBytes))
	}
	if linkTarget, err := os.Readlink(filepath.Join(prefix1, "bin", "pkg-alias")); err != nil || linkTarget != filepath.Join(prefix1, "bin", "pkg") {
		t.Fatalf("unexpected adapted symlink target: %q (%v)", linkTarget, err)
	}
	relocated, err := os.ReadFile(filepath.Join(prefix1, "share", "doc", "note.txt"))
	if err != nil || string(relocated) != "from "+prefix1 {
		t.Fatalf("unexpected relocated doc: %q (%v)", string(relocated), err)
	}
	aptConf, err := os.ReadFile(termuxAPTConfig(prefix1))
	if err != nil || !strings.Contains(string(aptConf), "DPkg::Post-Invoke") || !strings.Contains(string(aptConf), "termux-adapt") {
		t.Fatalf("expected DPkg::Post-Invoke termux-adapt in apt.conf: %s (%v)", string(aptConf), err)
	}
	sudoBytes, err := os.ReadFile(filepath.Join(home1, ".local", "bin", "sudo"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(sudoBytes), prefix1) || !strings.Contains(string(sudoBytes), `exec "$SU_BIN" "$TARGET_USER" -c "$INNER"`) {
		t.Fatalf("unexpected sudo wrapper: %s", string(sudoBytes))
	}

	// Simulate future app package rename (com.example.alpha -> com.example.beta) with migrated terminal dir.
	appDir2 := filepath.Join(tmp, "data", "user", "0", "com.example.beta")
	state2 := filepath.Join(appDir2, "files", "devicebridge")
	termRoot2 := filepath.Join(appDir2, "files", "terminal")
	prefix2 := filepath.Join(termRoot2, "files", "usr")
	home2 := filepath.Join(termRoot2, "files", "home")
	cache2 := filepath.Join(termRoot2, "cache")
	if err := os.MkdirAll(filepath.Join(appDir2, "files"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(termRoot1, termRoot2); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVICEBRIDGE_APP_PACKAGE", "com.example.beta")
	if err := configureTermuxPrefix(state2, "/app2/cli.bin", termRoot2, prefix2, home2, cache2); err != nil {
		t.Fatal(err)
	}

	pkgBytes2, err := os.ReadFile(filepath.Join(prefix2, "bin", "pkg"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(pkgBytes2), "com.example.alpha") || !strings.Contains(string(pkgBytes2), prefix2) {
		t.Fatalf("pkg script did not re-adapt after package rename: %s", string(pkgBytes2))
	}
	if linkTarget2, err := os.Readlink(filepath.Join(prefix2, "bin", "pkg-alias")); err != nil || linkTarget2 != filepath.Join(prefix2, "bin", "pkg") {
		t.Fatalf("symlink did not re-adapt after package rename: %q (%v)", linkTarget2, err)
	}
	fish2, err := os.ReadFile(filepath.Join(home2, ".config", "fish", "config.fish"))
	if err != nil || !strings.Contains(string(fish2), "com.example.beta") || strings.Contains(string(fish2), "com.example.alpha") {
		t.Fatalf("fish config did not re-adapt after package rename: %s (%v)", string(fish2), err)
	}
}

func TestTermuxAPTHookInvokesAndroidPathAndKeepsUserConfig(t *testing.T) {
	root := t.TempDir()
	ctx := termuxAdaptContext{
		Prefix:   filepath.Join(root, "files", "usr"),
		CacheDir: filepath.Join(root, "cache"),
	}
	state := filepath.Join(root, "device bridge's state")
	cli := filepath.Join(root, "~~test== cli")
	legacy := filepath.Join(ctx.Prefix, "etc", "apt", "apt.conf")
	if err := os.MkdirAll(filepath.Dir(legacy), 0o755); err != nil {
		t.Fatal(err)
	}
	const userConfig = "APT::Get::Assume-Yes \"true\";\n"
	oldHook := "DPkg::Post-Invoke { \"env -u LD_LIBRARY_PATH -u LD_PRELOAD /app/cli --state /app/state termux-adapt || true\"; };\n"
	if err := os.WriteFile(legacy, []byte(userConfig+oldHook), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cli, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := configureTermuxAPT(state, cli, ctx); err != nil {
		t.Fatal(err)
	}
	config, err := os.ReadFile(termuxAPTConfig(ctx.Prefix))
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(config), "\n") {
		if body, ok := strings.CutPrefix(line, "DPkg::Post-Invoke { "); ok {
			command, err := strconv.Unquote(strings.TrimSuffix(body, "; };"))
			if err != nil {
				t.Fatal(err)
			}
			out, err := exec.Command("sh", "-c", command).CombinedOutput()
			if want := "--state\n" + state + "\ntermux-adapt\n"; err != nil || string(out) != want {
				t.Fatalf("APT hook output %q (%v), want %q", out, err, want)
			}
			preserved, err := os.ReadFile(legacy)
			if err != nil || string(preserved) != userConfig {
				t.Fatalf("user config %q (%v), want %q", preserved, err, userConfig)
			}
			return
		}
	}
	t.Fatal("APT hook missing")
}

func TestTermuxSudoKeepsArgumentsAndTerminalHome(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("requires host Linux shell")
	}
	root := t.TempDir()
	ctx := termuxAdaptContext{
		AppPkg: "org.example.terminal",
		Prefix: filepath.Join(root, "files", "usr"),
		Home:   filepath.Join(root, "files", "home"),
	}
	bin := filepath.Join(ctx.Prefix, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "su"), []byte("#!/bin/sh\n[ \"$1\" = -c ] || exit 1\nexec /bin/sh -c \"$2\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	installTermuxRootWrappers(ctx)
	wrapper := filepath.Join(bin, "sudo")
	source, err := os.ReadFile(wrapper)
	if err != nil {
		t.Fatal(err)
	}
	// Route superuser through a fixture on the host. Android exercises discovery.
	script := strings.Replace(string(source), "/debug_ramdisk/su", shellSingleQuote(filepath.Join(bin, "su")), 1)
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	argument := "arg with 'quote' and trailing newline\n"
	cmd := exec.Command("sh", wrapper, "-H", "--", "/bin/sh", "-c",
		`printf '<%s>\n' "$1" "$HOME" "$TERMUX__HOME" "$TERMUX_APP__PACKAGE_NAME"`, "command", argument)
	cmd.Env = []string{"PATH=" + bin}
	out, err := cmd.CombinedOutput()
	want := fmt.Sprintf("<%s>\n</data/local/tmp>\n<%s>\n<%s>\n", argument, ctx.Home, ctx.AppPkg)
	if err != nil || string(out) != want {
		t.Fatalf("sudo output %q (%v), want %q", out, err, want)
	}
}

func TestPrepareLocalTerminalEnvironmentConfiguresLinuxSSH(t *testing.T) {
	stateDir := t.TempDir()
	_, _, homeDir, env, err := PrepareLocalTerminalEnvironment(stateDir, "/bin/sh")
	if err != nil {
		t.Fatalf("PrepareLocalTerminalEnvironment failed: %v", err)
	}
	if !strings.HasSuffix(homeDir, filepath.Join("terminal", "home")) {
		t.Fatalf("unexpected homeDir: %s", homeDir)
	}
	if len(env) == 0 {
		t.Fatal("expected non-empty terminal env")
	}
	sshCfgRaw, err := os.ReadFile(filepath.Join(homeDir, ".ssh", "config"))
	if err != nil {
		t.Fatalf("expected Linux terminal ssh config: %v", err)
	}
	sshCfg := string(sshCfgRaw)
	if !strings.Contains(sshCfg, "DEVICEBRIDGE_LINUX_TSNET_SSH_V2") ||
		!strings.Contains(sshCfg, "agent-ssh-proxy") ||
		!strings.Contains(sshCfg, "agent-ssh-match") ||
		!strings.Contains(sshCfg, "Host 100.* *.ts.net fd7a:115c:a1e0:*") ||
		!strings.Contains(sshCfg, "tsnet-match") ||
		!strings.Contains(sshCfg, "tsnet-proxy") {
		t.Fatalf("unexpected Linux terminal ssh config: %s", sshCfg)
	}
}

func TestFilterTermuxSSHDAddrsExcludesLoopbackAndTailscale(t *testing.T) {
	got := filterTermuxSSHDAddrs([]sshdIfaceAddrs{
		{name: "lo", up: true, loopback: true, addrs: []netip.Addr{netip.MustParseAddr("127.0.0.1"), netip.MustParseAddr("::1")}},
		{name: "tailscale0", up: true, addrs: []netip.Addr{netip.MustParseAddr("100.88.1.2"), netip.MustParseAddr("192.168.99.9")}},
		{name: "tun0", up: true, addrs: []netip.Addr{netip.MustParseAddr("100.100.10.2"), netip.MustParseAddr("fd7a:115c:a1e0::1234")}},
		{name: "eth0", up: true, addrs: []netip.Addr{netip.MustParseAddr("192.168.233.11"), netip.MustParseAddr("fe80::1")}},
		{name: "wlan0", up: true, addrs: []netip.Addr{netip.MustParseAddr("192.168.1.10")}},
		{name: "down0", up: false, addrs: []netip.Addr{netip.MustParseAddr("10.0.0.2")}},
	})
	want := []string{"192.168.1.10", "192.168.233.11"}
	if !slices.Equal(got, want) {
		t.Fatalf("filterTermuxSSHDAddrs = %v, want %v", got, want)
	}
}
