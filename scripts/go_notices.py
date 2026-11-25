"""Collect notices from exact Go module versions linked into packaged binaries."""

import json
import re
import subprocess
from pathlib import Path


NOTICE_NAME = re.compile(r"^(LICENSE|LICENCE|COPYING|NOTICE|PATENTS|COPYRIGHT)(?:$|[._-])", re.I)


def cache_name(module):
    return "".join(f"!{char.lower()}" if char.isascii() and char.isupper() else char
                   for char in module)


def linked_modules(binaries):
    modules = set()
    for binary in binaries:
        metadata = subprocess.check_output(["go", "version", "-m", binary], text=True)
        if "\n\tpath\t" not in metadata:
            raise RuntimeError(f"Go build metadata is missing in {binary}")
        for line in metadata.splitlines():
            fields = line.split("\t")
            if len(fields) >= 4 and fields[1] == "dep" and not fields[2].startswith("devicebridge"):
                modules.add((fields[2], fields[3]))
    return sorted(modules)


def resolve_module_dir(cache, root, module, version):
    source = cache / f"{cache_name(module)}@{cache_name(version)}"
    if source.is_dir():
        return source
    dl = subprocess.run(
        ["go", "mod", "download", "-json", f"{module}@{version}"],
        cwd=root,
        text=True,
        capture_output=True,
    )
    if dl.returncode == 0 and dl.stdout.strip():
        info = json.loads(dl.stdout)
        dl_dir = info.get("Dir")
        if dl_dir and Path(dl_dir).is_dir():
            return Path(dl_dir)
    for vendor_dir in (root / ".work/syncthing-native").glob("syncthing-*/vendor"):
        cand = vendor_dir / module
        if cand.is_dir():
            return cand
    raise RuntimeError(f"Module sources needed for notices are missing: {module}@{version}")


def collect(binaries):
    cache = Path(subprocess.check_output(["go", "env", "GOMODCACHE"], text=True).strip())
    root = Path(__file__).resolve().parent.parent
    standard_license = root / "docs/licenses/go-standard-library.txt"
    blocks = ["# Notices for linked Go dependencies\n", standard_license.read_text().rstrip()]
    for module, version in linked_modules(binaries):
        source = resolve_module_dir(cache, root, module, version)
        notices = sorted(path for path in source.iterdir()
                         if path.is_file() and NOTICE_NAME.match(path.name))
        if not any(re.match(r"^(LICEN[SC]E|COPYING)", path.name, re.I) for path in notices):
            raise RuntimeError(f"No upstream license found for {module}@{version}")
        for notice in notices:
            blocks += [f"## {module} {version} · {notice.name}",
                       notice.read_text(errors="strict").rstrip()]
    return "\n\n".join(blocks) + "\n"
