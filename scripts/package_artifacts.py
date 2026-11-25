#!/usr/bin/env python3
"""Package validated build outputs without building or installing an APK."""

import argparse
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path

from checksums import xxh64, xxh64_bytes
from go_notices import collect


def verify_android_core(apk, libraries):
    with zipfile.ZipFile(apk) as archive:
        for binary in libraries:
            member = f"lib/arm64-v8a/{binary.name}"
            try:
                included = archive.read(member)
            except KeyError as error:
                raise RuntimeError(f"{apk.name} is missing {member}") from error
            if xxh64_bytes(included) != xxh64(binary):
                raise RuntimeError(f"{apk.name} contains a stale {binary.name}")


def source_checksum(root):
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root,
    ).split(b"\0")
    records = bytearray()
    for name in sorted(set(names)):
        if not name:
            continue
        relative = os.fsdecode(name)
        source = root / relative
        if relative.startswith(("docs/", "artifacts/", ".work/")) or not source.is_file():
            continue
        records.extend(name + b"\0" + bytes.fromhex(xxh64(source)))
    return xxh64_bytes(records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug-apk", type=Path, help="debug APK from a completed Flutter run")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    artifacts = root / "artifacts"
    android = artifacts / "android-arm64"
    linux = artifacts / "linux"
    termux = artifacts / "termux-arm64"
    bundle = root / "app/build/linux/x64/release/bundle"
    linux_bundle = linux / "devicebridge-linux-x64.tar.gz"
    go_notices = artifacts / "THIRD_PARTY_NOTICES-GO.txt"
    linux_core = [linux / f"bridge-{role}" for role in ("agent", "cli")]
    termux_core = [termux / f"bridge-{role}" for role in ("agent", "cli")]
    android_core = [android / f"libbridge_{role}.so" for role in ("agent", "cli", "tailnet", "wg", "sync")]
    go_binaries = [*linux_core, linux / "bridge-sync", *(path for path in termux_core if path.exists()), *android_core]

    debug_output = android / "devicebridge-debug.apk"
    apks = {}
    if args.debug_apk is not None:
        apks[debug_output] = args.debug_apk.resolve()
    elif debug_output.exists():
        apks[debug_output] = debug_output
    if os.environ.get("DEVICEBRIDGE_BUILD_RELEASE") == "1":
        apks[android / "devicebridge.apk"] = root / "app/build/app/outputs/flutter-apk/app-release.apk"
    for source in apks.values():
        verify_android_core(source, android_core)

    notices = collect(go_binaries)
    filenames = [linux_bundle, go_notices, *go_binaries, *apks]
    with tempfile.TemporaryDirectory(prefix=".devicebridge-package-", dir=artifacts) as staging:
        stage = Path(staging)
        staged = {}
        for target, source in apks.items():
            if target != source:
                copy = stage / target.name
                shutil.copy2(source, copy)
                if xxh64(copy) != xxh64(source):
                    raise RuntimeError(f"Completed APK copy failed XXH64 verification: {source}")
                staged[target] = copy
        notice_copy = stage / go_notices.name
        notice_copy.write_text(notices, encoding="utf-8")
        staged[go_notices] = notice_copy
        linux_archive = stage / linux_bundle.name
        with tarfile.open(linux_archive, "w:gz") as archive:
            archive.add(bundle, arcname="devicebridge")
            archive.add(notice_copy, arcname="devicebridge/THIRD_PARTY_NOTICES-GO.txt")
            archive.add(root / "docs/THIRD_PARTY_NOTICES.md", arcname="devicebridge/THIRD_PARTY_NOTICES.md")
            archive.add(root / "docs/licenses", arcname="devicebridge/licenses")
            archive.add(
                root / "scripts/devicebridge_ssh.py",
                arcname="devicebridge/tools/devicebridge_ssh.py",
            )
        staged[linux_bundle] = linux_archive

        manifest = {
            "files": {
                str(path.relative_to(root)): {
                    "bytes": staged.get(path, path).stat().st_size,
                    "xxh64": xxh64(staged.get(path, path)),
                }
                for path in filenames
            },
            "android_signing": "development key",
            "android_builds": list(path.name for path in apks),
            "core_xxh64": xxh64(android / "libbridge_cli.so"),
            "source_xxh64_excluding_docs_artifacts": source_checksum(root),
            "termux_artifacts_not_built": [
                str(path.relative_to(root)) for path in termux_core if not path.exists()
            ],
        }
        manifest_text = json.dumps(manifest, indent=2) + "\n"
        for target, source in staged.items():
            os.replace(source, target)
        manifest_copy = stage / "MANIFEST.json"
        manifest_copy.write_text(manifest_text, encoding="utf-8")
        os.replace(manifest_copy, artifacts / "MANIFEST.json")
        evidence_dir = root / "docs/test-evidence"
        if evidence_dir.is_dir():
            (evidence_dir / "artifact-manifest.json").write_text(manifest_text, encoding="utf-8")
    print(manifest_text, end="")


if __name__ == "__main__":
    main()
