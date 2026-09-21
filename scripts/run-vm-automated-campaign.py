#!/usr/bin/env python3
"""Run and package the fixed VM-automated v1 campaign through the common VM CLI."""

import sys

# Adjacent files and PYTHONPATH must not supply bootstrap or stdlib imports.
# sys and the platform OS module are built-ins, so isolation precedes file imports.
if __name__ == "__main__" and not sys.flags.isolated:
    _platform_os = __import__("nt" if sys.platform == "win32" else "posix")
    _platform_os.execv(sys.executable, [sys.executable, "-I", __file__, *sys.argv[1:]])

import hashlib
import os
from pathlib import Path
import stat
import types

TOOLING_MANIFEST_SHA256 = "d0d5d46eb8629adc727fa66e761120ce7fbd4bcd277a1145b0979a600c01af4d"
TOOLING_LOADER_SHA256 = "cffb17faf73f0643b293dbe5c4a7cefe9475e8a19008b03f9ce45d8b3565497d"
IMPLEMENTATION_ROLE = "campaign-runner"


def _read_loader(path: Path) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or getattr(before, "st_file_attributes", 0) & 0x400:
            raise RuntimeError("Tooling loader is not an ordinary file.")
        chunks = []
        total = 0
        while total <= 1024 * 1024:
            chunk = os.read(descriptor, min(64 * 1024, 1024 * 1024 + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        if len(data) > 1024 * 1024 or (before.st_dev, before.st_ino, before.st_size) != (after.st_dev, after.st_ino, after.st_size) or len(data) != after.st_size:
            raise RuntimeError("Tooling loader changed while it was read.")
        return data
    finally:
        os.close(descriptor)


def _run(argv) -> int:
    script_dir = Path(__file__).absolute().parent
    checkout = (script_dir / "tooling_bootstrap.py").is_file() and (script_dir.parent / "config" / "tooling-bundle.json").is_file()
    bundle = (script_dir / "tooling-loader.py").is_file() and (script_dir / "tooling-bundle.json").is_file()
    if checkout == bundle:
        raise RuntimeError("Tooling CLI layout is missing or ambiguous.")
    root = script_dir.parent if checkout else script_dir
    manifest = "config/tooling-bundle.json" if checkout else "tooling-bundle.json"
    loader_path = script_dir / ("tooling_bootstrap.py" if checkout else "tooling-loader.py")
    source = _read_loader(loader_path)
    if hashlib.sha256(source).hexdigest() != TOOLING_LOADER_SHA256:
        raise RuntimeError("Tooling loader SHA-256 does not match the trusted CLI pin.")
    module = types.ModuleType("_darkrenamer_verified_loader")
    sys.modules[module.__name__] = module
    try:
        exec(compile(source, "verified-tooling-loader", "exec", dont_inherit=True), module.__dict__)
        verified = module.verify_tooling(root=root, manifest_location=manifest,
                                         expected_manifest_sha256=TOOLING_MANIFEST_SHA256,
                                         mode="checkout" if checkout else "bundle",
                                         required_roles=(IMPLEMENTATION_ROLE,))
    finally:
        del sys.modules[module.__name__]
    with verified.importer() as imports:
        implementation = imports.import_role(IMPLEMENTATION_ROLE)
        return implementation.cli(root, argv, verified)


if __name__ == "__main__":
    try:
        raise SystemExit(_run(sys.argv[1:]))
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
