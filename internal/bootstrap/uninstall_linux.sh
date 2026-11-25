# Invoked through confirmed SSH and sudo, with a verified installation identity.
set -euo pipefail
export LC_ALL=C
home=$1
owner=$2
presence=$3
state="$home/.local/share/devicebridge"
unit=devicebridge-agent.service
system_unit="/etc/systemd/system/$unit"
user_units="$home/.config/systemd/user"
user_unit="$user_units/$unit"
sudoers=/etc/sudoers.d/devicebridge-net
polkit=/etc/polkit-1/rules.d/49-devicebridge-nm.rules

fail() { printf '%s\n' "$*" >&2; exit 1; }

port=8731
check_unit() {
    local file=$1 line prefix configured_port
    [[ ! -L "$file" ]] || fail "Refusing a linked unit at $file."
    [[ -e "$file" ]] || return 0
    [[ -f "$file" ]] || fail "Unexpected service file at $file."
    line=$(grep '^ExecStart=' "$file") || fail "Missing ExecStart in $file."
    prefix="ExecStart=$state/bin/bridge-agent --state $state "
    [[ "$line" == "$prefix"* && "$line" != *$'\n'* ]] ||
        fail "The service at $file uses a different installation."
    configured_port=$(sed -nE 's/.* --port ([0-9]{1,5})( |$).*/\1/p' <<<"$line")
    if [[ -n "$configured_port" ]]; then port=$configured_port; fi
}

check_unit "$user_unit"
check_unit "$system_unit"
for file in "$sudoers" "$polkit"; do
    [[ ! -L "$file" ]] || fail "Refusing a linked configuration at $file."
done
if [[ -e "$sudoers" ]]; then
    [[ -f "$sudoers" ]] && grep -Fq "$owner ALL=(root) NOPASSWD:" "$sudoers" &&
        grep -Fq 'reg set *,' "$sudoers" || fail "Unexpected DeviceBridge sudoers configuration."
fi
if [[ -e "$polkit" ]]; then
    [[ -f "$polkit" ]] && grep -Fq "subject.user == \"$owner\"" "$polkit" &&
        grep -Fq 'org.freedesktop.NetworkManager.' "$polkit" || fail "Unexpected DeviceBridge Polkit configuration."
fi
rules=''
if command -v ufw >/dev/null; then
    rules=$(ufw show added)
fi
rule="ufw allow $port/tcp comment 'DeviceBridge agent'"
if [[ "$presence" == absent ]]; then
    [[ ! -e "$state" && ! -L "$state" && ! -e "$system_unit" && ! -e "$user_unit" &&
       ! -e "$sudoers" && ! -e "$polkit" ]] &&
        ! grep -Fxq -- "$rule" <<<"$rules" || fail "Installation identity is missing and managed files or rules remain."
    exit 0
fi

[[ ! -L "$state" && "$(realpath -e -- "$state")" == "$state" ]] ||
    fail "The installation directory changed."
if [[ -e "$user_unit" ]]; then
    [[ "$(realpath -e -- "$user_units")" == "$user_units" ]] ||
        fail "The user service directory is redirected."
    uid=$(id -u "$owner")
    user_systemctl() {
        runuser -u "$owner" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user "$@"
    }
    if [[ -S "/run/user/$uid/bus" ]]; then
        user_systemctl disable --now "$unit"
    else
        rm -f -- "$user_units/default.target.wants/$unit"
    fi
fi
if [[ -e "$system_unit" ]]; then
    systemctl disable --now "$unit"
fi

# Only managed units are stopped. Refuse to remove a binary that is still running.
for exe in /proc/[0-9]*/exe; do
    target=$(readlink "$exe" 2>/dev/null) || continue
    [[ "$target" != "$state/bin/bridge-agent" && "$target" != "$state/bin/bridge-agent (deleted)" ]] ||
        fail "A DeviceBridge agent is still running outside the managed service."
done

if grep -Fxq -- "$rule" <<<"$rules"; then
    ufw --force delete allow "$port/tcp" comment 'DeviceBridge agent'
fi
if command -v nmcli >/dev/null &&
   nmcli --get-values connection.id connection show id DeviceBridge-Direct 2>/dev/null | grep -Fxq DeviceBridge-Direct; then
    nmcli --wait 8 connection delete id DeviceBridge-Direct
fi
if [[ -e "$system_unit" ]]; then
    rm -f -- "$system_unit"
    rm -rf --one-file-system -- "$system_unit.d"
    systemctl daemon-reload
fi
if [[ -e "$user_unit" ]]; then
    rm -f -- "$user_unit"
    rm -rf --one-file-system -- "$user_unit.d"
    if [[ -S "/run/user/$uid/bus" ]]; then user_systemctl daemon-reload; fi
fi
rm -f -- "$sudoers" "$polkit"

# Anchor deletion to the verified parent. Do not follow symlinks or mount points.
cd -P -- "$home/.local/share"
[[ "$PWD" == "$home/.local/share" && ! -L devicebridge ]] ||
    fail "The installation directory changed."
if command -v mountpoint >/dev/null && mountpoint -q -- devicebridge; then
    fail "The installation directory is a mount point."
fi
rm -rf --one-file-system -- devicebridge
