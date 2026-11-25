package bootstrap

import (
	"errors"
	"fmt"
	"net/netip"
	"path"
	"strings"
)

const termuxCompanionPort = 18733

// Termux denies unprivileged netlink on recent Android versions. The address
// observed by SSH is usable when it belongs to the controller's approved LAN.
func termuxLAN(localCIDR, remoteAddress string) (string, error) {
	prefix, e1 := netip.ParsePrefix(localCIDR)
	remote, e2 := netip.ParseAddr(remoteAddress)
	if e1 != nil || e2 != nil || !remote.Is4() || !remote.IsPrivate() ||
		!prefix.Addr().Is4() || !prefix.Contains(remote) {
		return "", errors.New("connect to Termux SSH using its Wi-Fi address on the approved LAN")
	}
	return netip.PrefixFrom(remote, prefix.Bits()).String(), nil
}

func termuxCompanionState(home string) (string, error) {
	clean := path.Clean(home)
	if clean != "/data/data/com.termux/files/home" && clean != "/data/user/0/com.termux/files/home" {
		return "", errors.New("expected the private home of the Termux app")
	}
	return path.Join(path.Dir(clean), "usr", "var", "lib", "devicebridge-companion"), nil
}

func termuxStartCommand(state, agent, iface, cidr string, port int) string {
	// State outside Home keeps companion keys and Syncthing configuration
	// outside the shared Home root. Only this installation's saved PID is
	// stopped, after checking its executable and exact state flag.
	script := fmt.Sprintf(`set -eu
umask 077
state=%s
agent=%s
iface=%s
cidr=%s
mkdir -p "$state"
exec 9>"$state/launch.lock"
flock -w 5 9
pidfile="$state/agent.pid"
if [ -r "$pidfile" ]; then
  read -r pid < "$pidfile" || true
  case "${pid:-}" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$pid" -gt 1 ] && [ -r "/proc/$pid/cmdline" ]; then
      mapfile -d '' -t previous < "/proc/$pid/cmdline"
      if [ "${previous[0]:-}" = "$agent" ] && [ "${previous[1]:-}" = "--state" ] && [ "${previous[2]:-}" = "$state" ]; then
        kill -TERM "$pid"
        for ((n=0; n<40; n++)); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then echo "Previous companion is still stopping" >&2; exit 1; fi
      fi
    fi
    ;;
  esac
fi
engine="$state/bin/bridge-sync"
if [ ! -x "$engine" ]; then engine=$(command -v syncthing || true); fi
if [ -z "$engine" ]; then echo "Use a DeviceBridge build that includes the Termux sync engine, or install Syncthing in Termux" >&2; exit 1; fi
"$engine" --version >/dev/null
export DEVICEBRIDGE_SYNCTHING_BINARY="$engine"
export DEVICEBRIDGE_SYNC_INTERFACE="$iface" DEVICEBRIDGE_SYNC_CIDR="$cidr"
nohup "$agent" --state "$state" --interface "$iface" --lan-cidr "$cidr" --port %d --loopback-port -1 --no-remote-actions --termux-home-files </dev/null >"$state/agent.log" 2>&1 9>&- &
pid=$!
printf '%%s\n' "$pid" > "$pidfile.tmp"
mv -f "$pidfile.tmp" "$pidfile"
for ((n=0; n<40; n++)); do
  if ! kill -0 "$pid" 2>/dev/null; then tail -n 4 "$state/agent.log" >&2; exit 1; fi
  if grep -q '"endpoint":' "$state/agent.log"; then echo running; exit 0; fi
  sleep 0.1
done
echo "Termux companion did not announce a ready listener" >&2
exit 1
`, shellQuote(state), shellQuote(agent), shellQuote(iface), shellQuote(cidr), port)
	return "bash -c " + shellQuote(strings.TrimSpace(script))
}
