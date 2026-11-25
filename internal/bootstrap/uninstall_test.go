package bootstrap

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestUninstallManagedLinuxFiles(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	state := filepath.Join(home, ".local/share/devicebridge")
	system := filepath.Join(root, "system")
	unit := filepath.Join(system, "devicebridge-agent.service")
	sudoers := filepath.Join(root, "devicebridge-net")
	polkit := filepath.Join(root, "49-devicebridge-nm.rules")
	rules := filepath.Join(root, "ufw-rules")
	log := filepath.Join(root, "calls")
	bin := filepath.Join(root, "bin")
	owner := "owner"
	write := func(path, contents string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0700); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(state, "bin/bridge-agent"), "agent")
	write(filepath.Join(state, "state.db"), "state")
	write(filepath.Join(home, "unrelated"), "keep this file")
	write(unit, "ExecStart=/unrelated/bridge-agent --state /unrelated --port 8731\n")
	write(sudoers, owner+" ALL=(root) NOPASSWD: /usr/bin/iw reg set *, /usr/bin/nmcli *\n")
	write(polkit, `org.freedesktop.NetworkManager. subject.user == "owner"`)
	const unrelatedRule = "ufw allow 22/tcp comment 'SSH'"
	write(rules, "ufw allow 8731/tcp comment 'DeviceBridge agent'\n"+unrelatedRule+"\n")
	write(filepath.Join(bin, "systemctl"), "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$TEST_LOG\"\n")
	write(filepath.Join(bin, "nmcli"), "#!/bin/bash\nexit 1\n")
	write(filepath.Join(bin, "ufw"), `#!/bin/bash
if [[ "$*" == 'show added' ]]; then
    cat "$TEST_RULES"
elif [[ "$*" == '--force delete allow 8731/tcp comment DeviceBridge agent' ]]; then
    grep -v 'DeviceBridge agent' "$TEST_RULES" > "$TEST_RULES.next"
    mv "$TEST_RULES.next" "$TEST_RULES"
    printf '%s\n' "$*" >> "$TEST_LOG"
else
    exit 2
fi
`)
	script := strings.NewReplacer(
		"/etc/systemd/system", system,
		"/etc/sudoers.d/devicebridge-net", sudoers,
		"/etc/polkit-1/rules.d/49-devicebridge-nm.rules", polkit,
	).Replace(uninstallLinux)
	run := func(presence string) (string, error) {
		t.Helper()
		cmd := exec.Command("bash", "-c", script, "uninstall", home, owner, presence)
		cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"), "TEST_RULES="+rules, "TEST_LOG="+log)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	if out, err := run("present"); err == nil || !strings.Contains(out, "different installation") {
		t.Fatalf("unrecognized unit should block removal: %v %s", err, out)
	}
	if _, err := os.Stat(state); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatalf("unexpected system changes after rejected unit: %v", err)
	}
	write(unit, "ExecStart="+filepath.Join(state, "bin/bridge-agent")+" --state "+state+" --interface wlan0 --port 8731\n")
	for _, presence := range []string{"present", "absent"} {
		if out, err := run(presence); err != nil {
			t.Fatalf("%s: %v %s", presence, err, out)
		}
	}
	for _, removed := range []string{unit, sudoers, polkit, state} {
		if _, err := os.Stat(removed); !os.IsNotExist(err) {
			t.Fatalf("expected removal of %s: %v", removed, err)
		}
	}
	if data, err := os.ReadFile(rules); err != nil || strings.TrimSpace(string(data)) != unrelatedRule {
		t.Fatalf("unexpected firewall rules: %q, %v", data, err)
	}
	if data, err := os.ReadFile(filepath.Join(home, "unrelated")); err != nil || string(data) != "keep this file" {
		t.Fatalf("unrelated file changed: %q, %v", data, err)
	}
}
