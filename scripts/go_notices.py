"""Collect notices from exact Go module versions linked into packaged binaries."""

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
            if len(fields) >= 4 and fields[1] == "dep" and fields[2] != "devicebridge":
                modules.add((fields[2], fields[3]))
    return sorted(modules)


def collect(binaries):
    cache = Path(subprocess.check_output(["go", "env", "GOMODCACHE"], text=True).strip())
    root = Path(__file__).resolve().parent.parent
    standard_license = root / "docs/licenses/go-standard-library.txt"
    blocks = ["# Notices for linked Go dependencies\n", standard_license.read_text().rstrip()]
    for module, version in linked_modules(binaries):
        source = cache / f"{cache_name(module)}@{cache_name(version)}"
        if not source.is_dir():
            raise RuntimeError(f"Module sources needed for notices are missing: {module}@{version}")
        notices = sorted(path for path in source.iterdir()
                         if path.is_file() and NOTICE_NAME.match(path.name))
        if not any(re.match(r"^(LICEN[SC]E|COPYING)", path.name, re.I) for path in notices):
            raise RuntimeError(f"No upstream license found for {module}@{version}")
        for notice in notices:
            blocks += [f"## {module} {version} · {notice.name}",
                       notice.read_text(errors="strict").rstrip()]
    return "\n\n".join(blocks) + "\n"
