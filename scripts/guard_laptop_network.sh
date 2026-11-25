#!/usr/bin/env bash
# Arm a local NetworkManager restore independently of the session's internet.
set -euo pipefail

case "${1:-}" in
    inspect|arm)
        iface=${2:?current NetworkManager uplink interface required}
        delay=${3:-90}
        [[ "$delay" =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'Use a delay in seconds.' >&2; exit 2; }
        profile=$(nmcli --get-values GENERAL.CON-UUID device show "$iface")
        [[ "$profile" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "No active profile on $iface." >&2; exit 1; }
        nmcli_path=$(command -v nmcli)
        if [[ $1 == inspect ]]; then
            printf 'Uplink %s · active profile %s · restore after %s seconds\n' "$iface" "$profile" "$delay"
            exit
        fi
        unit="devicebridge-uplink-restore-$(date +%s)"
        systemd-run --user --quiet --unit="$unit" --on-active="${delay}s" \
            "$nmcli_path" --wait 45 connection up uuid "$profile" ifname "$iface"
        systemctl --user is-active --quiet "$unit.timer"
        printf '%s.timer\n' "$unit"
        ;;
    disarm)
        timer=${2:?owned timer name required}
        [[ "$timer" =~ ^devicebridge-uplink-restore-[0-9]+\.timer$ ]] || exit 2
        systemctl --user stop "$timer"
        ;;
    *)
        echo "Usage: $0 inspect|arm INTERFACE [SECONDS] or disarm TIMER" >&2
        exit 2
        ;;
esac
