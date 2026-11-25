#!/usr/bin/env python3
"""Validate signed APKs and the files required by each release build."""

import argparse
import re
import subprocess
import zipfile
from pathlib import Path

PACKAGE_ID = "dev.devicebridge.devicebridge"
# Public signing certificate from the v1.0.0 GitHub release, used by Android to
# accept in-place upgrades. Artifact content hashes use XXH64 separately.
RELEASE_SIGNER = "4791cf75e0a6ecc94b068f479cb342b35be458d0192752a52d569082aa42c3c9"
ABIS = {"arm64-v8a": "arm64", "armeabi-v7a": "arm", "x86_64": "amd64"}
NATIVE = {f"libbridge_{role}.so" for role in ("agent", "cli", "sync", "tailnet", "wg")}
NATIVE.update(("libdb_termux_adapt.so", "libflutter.so", "libapp.so"))
ASSETS = "assets/flutter_assets/assets/bin/"


def verify_apk(apk: Path, abis: set[str], version: str, code: str, tools: Path):
    badging = subprocess.check_output([tools / "aapt", "dump", "badging", apk], text=True)
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging, re.M)
    if package is None or package.groups() != (PACKAGE_ID, code, version):
        raise ValueError(f"{apk.name} has an unexpected package or Android version.")
    if "name='android.permission.REQUEST_INSTALL_PACKAGES'" not in badging:
        raise ValueError(f"{apk.name} lacks the permission for the system update installer.")

    signing = subprocess.check_output([tools / "apksigner", "verify", "--print-certs", apk], text=True)
    signers = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)$", signing, re.M)
    if [signer.lower() for signer in signers] != [RELEASE_SIGNER]:
        raise ValueError(f"{apk.name} does not match the published Android release signer.")

    with zipfile.ZipFile(apk) as archive:
        sizes = {entry.filename: entry.file_size for entry in archive.infolist()}
    actual_abis = {name.split("/")[1] for name in sizes if name.startswith("lib/") and name.endswith("/libflutter.so")}
    if actual_abis != abis:
        raise ValueError(f"{apk.name} supports {sorted(actual_abis)}, expected {sorted(abis)}.")
    required = {f"lib/{abi}/{name}" for abi in abis for name in NATIVE}
    required.update(f"assets/devicebridge-notices/GO-{arch}.txt" for arch in ABIS.values())
    required.update(
        f"assets/devicebridge-notices/{name}.txt"
        for name in ("syncthing-v2.1.7", "shizuku-api-v13.1.5")
    )
    required.update(f"{ASSETS}linux-x86_64-bridge-{role}.gzbin" for role in ("agent", "cli", "sync"))
    fallback = {f"{ASSETS}android-arm64-libbridge_{role}.gzbin" for role in ("agent", "cli", "sync")}
    if abis != {"arm64-v8a"}:
        required.update(fallback)
    elif fallback.intersection(sizes):
        raise ValueError(f"{apk.name} contains a second copy of its native Termux SSH binaries.")
    missing = sorted(name for name in required if not sizes.get(name))
    if missing:
        raise ValueError(f"{apk.name} lacks required contents: {missing}")
    if not 0 < apk.stat().st_size <= 1024**3:
        raise ValueError(f"{apk.name} exceeds the Android in-app update size limit.")
    print(f"{apk.name}: {apk.stat().st_size / 2**20:.2f} MiB, {version} ({code}), {', '.join(sorted(abis))}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("version")
    parser.add_argument("version_code")
    parser.add_argument("build_tools", type=Path)
    args = parser.parse_args()
    variants = {name: {name} for name in ABIS}
    variants["universal"] = set(ABIS)
    for name, abis in variants.items():
        apk = args.directory / f"devicebridge-android-{name}.apk"
        verify_apk(apk, abis, args.version, args.version_code, args.build_tools)


if __name__ == "__main__":
    main()
