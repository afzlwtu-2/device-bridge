"""XXH64 checksums compatible with xxhsum's default algorithm (seed zero)."""
import subprocess


def xxh64(path):
    # stdin keeps filenames (including whitespace/newlines) out of parsing.
    with open(path, 'rb') as source:
        return subprocess.check_output(['xxhsum', '-H1', '-q'], stdin=source).decode().split()[0]


def xxh64_bytes(data):
    return subprocess.check_output(['xxhsum', '-H1', '-q'], input=data).decode().split()[0]
