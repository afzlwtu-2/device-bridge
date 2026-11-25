#!/usr/bin/env python3
"""Open an SSH alias on the currently authenticated DeviceBridge LAN or system tailnet."""

import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


def core(cli, state, arguments):
    body = subprocess.check_output([cli, "--state", str(state), *arguments], timeout=12)
    return json.loads(body)


def resolve_host(cli, state, args):
    route = args.transport
    connection = core(cli, state, ["connection", args.peer])
    if route == "auto":
        route = connection.get("transport") or "lan"
    flags = ["--transport", route]
    if route == "lan":
        if args.lan_cidr is None:
            raise ValueError("Provide the active local interface and --lan-cidr for a LAN alias.")
        flags += ["--interface", args.interface, "--lan-cidr", args.lan_cidr]
        if (connection.get("transport") == "lan"
                and connection.get("active_link") in {"hotspot", "wifi_direct"}
                and connection.get("endpoint")):
            flags += ["--endpoint", connection["endpoint"], "--manual-lan-context"]
    elif route == "tailnet":
        flags += ["--tailnet-mode", "system"]
    else:
        raise ValueError("OpenSSH aliases use direct LAN or the laptop's system Tailscale.")
    verified = core(cli, state, [*flags, "resolve", args.peer])
    host = verified["endpoint"].rsplit(":", 1)[0].strip("[]")
    return str(ipaddress.ip_address(host))


def pinned_key(lines, fingerprint):
    for line in lines.splitlines():
        fields = line.split()
        if len(fields) != 3 or line.startswith("#"):
            continue
        _, key_type, encoded = fields
        if not re.fullmatch(r"[a-z0-9@._-]+", key_type):
            continue
        try:
            key = base64.b64decode(encoded, validate=True)
        except ValueError:
            continue
        digest = base64.b64encode(hashlib.sha256(key).digest()).decode().rstrip("=")
        if hmac.compare_digest("SHA256:" + digest, fingerprint):
            return key_type, encoded
    raise ValueError("The SSH server's public key does not match the supplied fingerprint.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("peer", help="paired device name or ID")
    parser.add_argument("--state", type=Path, default=Path.home() / ".local/share/devicebridge")
    parser.add_argument("--cli", help="path to bridge-cli, defaults to the managed state binary")
    parser.add_argument("--user", required=True, help="SSH account name")
    parser.add_argument("--fingerprint", required=True, help="verified SHA256 SSH host fingerprint")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--interface", default="wlan0")
    parser.add_argument("--lan-cidr", help="local address and CIDR on the selected LAN")
    parser.add_argument("--transport", choices=("auto", "lan", "tailnet"), default="auto")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", args.user) or not 0 < args.port <= 65535:
        parser.error("provide a valid SSH username and port")
    if not re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", args.fingerprint):
        parser.error("provide the verified SHA256 SSH host fingerprint")

    state = args.state.expanduser().resolve()
    cli = args.cli or str(state / "bin/bridge-cli")
    try:
        host = resolve_host(cli, state, args)
        scan = subprocess.run(
            ["ssh-keyscan", "-T", "4", "-p", str(args.port), host],
            capture_output=True, text=True, timeout=6, check=False,
        )
        key_type, public_key = pinned_key(scan.stdout, args.fingerprint)
        with tempfile.TemporaryDirectory(prefix="devicebridge-ssh-") as directory:
            pin = Path(directory) / "known_hosts"
            fd = os.open(pin, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="ascii") as writer:
                writer.write(f"devicebridge-pinned {key_type} {public_key}\n")
            algorithms = "rsa-sha2-512,rsa-sha2-256" if key_type == "ssh-rsa" else key_type
            command = [
                "ssh", "-F", "/dev/null",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", f"UserKnownHostsFile={pin}",
                "-o", "HostKeyAlias=devicebridge-pinned",
                "-o", f"HostKeyAlgorithms={algorithms}",
                "-l", args.user, "-p", str(args.port), host,
            ]
            return subprocess.run(command, check=False).returncode
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
