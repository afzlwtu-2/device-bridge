package bootstrap

import (
	"context"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"strings"
)

//go:embed uninstall_linux.sh
var uninstallLinux string

type UninstallRequest struct {
	Host            string         `json:"host"`
	Port            int            `json:"port"`
	User            string         `json:"user"`
	Password        string         `json:"password,omitempty"`
	PrivateKeyPEM   string         `json:"private_key_pem,omitempty"`
	KeyPassphrase   string         `json:"key_passphrase,omitempty"`
	ExpectedHostKey string         `json:"expected_host_key"`
	SudoPassword    string         `json:"sudo_password,omitempty"`
	Tailnet         TailnetOptions `json:"-"`
}

// Uninstall removes the standard Linux SSH bootstrap installation on an
// authenticated host after verifying its locally stored DeviceBridge identity.
func Uninstall(ctx context.Context, peerID string, req UninstallRequest) error {
	if _, err := hex.DecodeString(peerID); len(peerID) != 64 || err != nil {
		return errors.New("invalid paired device ID")
	}
	cl, _, _, _, err := dialSSHParams(ctx, req.Tailnet, req.Host, req.Port, req.User, req.Password, req.PrivateKeyPEM, req.KeyPassphrase, req.ExpectedHostKey)
	if err != nil {
		return err
	}
	defer cl.Close()
	stop := context.AfterFunc(ctx, func() { _ = cl.Close() })
	defer stop()

	const inspect = `set -eu
if [ "$(uname -s)" != Linux ] || [ "$(uname -o 2>/dev/null || true)" = Android ] ||
   [ -e /system/bin/getprop ]; then
    echo 'Agent uninstall is only supported on Linux laptops.' >&2
    exit 1
fi
cd -P -- "$HOME"
printf '%s\n' "$PWD" "$(id -un)"
state="$PWD/.local/share/devicebridge"
if [ ! -L "$state" ] && [ ! -e "$state" ]; then
    echo absent
    exit
fi
if [ "$(realpath -e -- "$state")" != "$state" ] ||
   [ "$(realpath -e -- "$state/bin/bridge-cli")" != "$state/bin/bridge-cli" ]; then
    echo 'The DeviceBridge installation is outside its managed directory.' >&2
    exit 1
fi
"$state/bin/bridge-cli" --state "$state" identity
`
	raw, stderr, err := runSSH(cl, "bash -s", inspect)
	if err != nil {
		return fmt.Errorf("verify laptop installation: %w (%s)", err, stderr)
	}
	parts := strings.SplitN(raw, "\n", 3)
	if len(parts) != 3 || !path.IsAbs(parts[0]) || path.Clean(parts[0]) != parts[0] || parts[0] == "/" || parts[1] == "" {
		return errors.New("could not identify the laptop's installation directory")
	}
	present := parts[2] != "absent"
	if present {
		var identity struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal([]byte(parts[2]), &identity); err != nil || identity.ID != peerID {
			return errors.New("the laptop's DeviceBridge identity does not match this pairing")
		}
	}
	script := "set -- " + shellQuote(parts[0]) + " " + shellQuote(parts[1]) + " "
	if present {
		script += "present\n"
	} else {
		script += "absent\n"
	}
	script += uninstallLinux
	if _, stderr, err := runRemoteRoot(cl, parts[1], req.SudoPassword, script); err != nil {
		return fmt.Errorf("uninstall DeviceBridge (root or sudo required): %w (%s)", err, stderr)
	}
	return nil
}
