#!/usr/bin/env python3
"""Classify an exact Git tree comparison against the reviewed CI document list.

CI loads this file from the protected base commit, never from the proposed tree.
Any missing, malformed, or unexpected evidence selects the full verification path.
"""

import re
import subprocess
import sys


ALLOWED = frozenset(
    (
        b"README.ko.md",
        b"README.ja.md",
        b"docs/USER-GUIDE.md",
        b"docs/USER-GUIDE.ko.md",
        b"docs/history/WINDOWS-ACCEPTANCE.md",
    )
)
SHA = re.compile(r"[0-9a-f]{40}\Z", re.ASCII)
RAW_HEADER = re.compile(rb":100644 100644 [0-9a-f]{40} [0-9a-f]{40} M\Z")


def allowed_raw_diff(raw: bytes) -> bool:
    if not raw or not raw.endswith(b"\0"):
        return False
    fields = raw[:-1].split(b"\0")
    if len(fields) % 2 != 0:
        return False
    seen: set[bytes] = set()
    for header, path in zip(fields[::2], fields[1::2]):
        if not RAW_HEADER.fullmatch(header) or path not in ALLOWED or path in seen:
            return False
        seen.add(path)
    return bool(seen)


def git(*args: str) -> bytes:
    return subprocess.run(
        ("git", *args), check=True, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, timeout=30,
    ).stdout


def docs_only(base: str, head: str) -> bool:
    if not SHA.fullmatch(base) or not SHA.fullmatch(head) or base == head:
        return False
    try:
        if git("rev-parse", "HEAD").strip() != head.encode("ascii"):
            return False
        git("merge-base", "--is-ancestor", base, head)
        raw = git(
            "diff", "--raw", "-z", "--no-renames", "--no-ext-diff",
            "--no-textconv", "--abbrev=40", base, head, "--",
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    return allowed_raw_diff(raw)


def main() -> int:
    result = len(sys.argv) == 3 and docs_only(sys.argv[1], sys.argv[2])
    sys.stdout.write("true" if result else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
