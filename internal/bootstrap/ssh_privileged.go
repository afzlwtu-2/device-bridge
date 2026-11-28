package bootstrap

import (
	"context"
	"devicebridge/internal/transport"
	"fmt"
	"net"

	"golang.org/x/crypto/ssh"
	"regexp"
)

var linuxAccountName = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}\$?$`)

func validServiceAccount(user string) bool {
	return user != "root" && linuxAccountName.MatchString(user)
}

func commandAsSSHAccount(user, command string) string {
	return "runuser -u " + shellQuote(user) + " -- bash -c " + shellQuote(command)
}

// Elevation only prepares systemd's persistent user manager. The service unit,
// state, binaries and all subsequent commands belong to that unprivileged user.
func enableSSHAgentUserManager(user string, uid int) string {
	return fmt.Sprintf(`set -e
user=%s
uid=%d
test "$(id -u -- "$user")" = "$uid"
test "$uid" -gt 0
loginctl enable-linger -- "$user"
systemctl start "user@$uid.service"
`, shellQuote(user), uid)
}

// The setup stream exists only for the lifetime of the verified SSH connection.
type sshPairRoute struct{ connection *ssh.Client }

func (sshPairRoute) ID() string { return "ssh-setup" }

func (r sshPairRoute) Dial(ctx context.Context, candidate transport.Candidate) (net.Conn, error) {
	return r.connection.DialContext(ctx, "tcp", candidate.Endpoint)
}
