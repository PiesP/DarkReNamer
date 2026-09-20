#!/usr/bin/env python3
"""Build and run the four source-bound DarkReNamer GUI regression cells."""

import hashlib
import os
from pathlib import Path
import stat
import sys
import types

TOOLING_MANIFEST_SHA256 = "0c16128dda6f98b0cbb0512d4434110d63aa2924a510cdef0cc9263cdc0112bc"
TOOLING_LOADER_SHA256 = "3df749e355d4580b6fd6d772b987fa59215742d4a64728bbe4f0fa46ac97a0da"
IMPLEMENTATION_ROLE = "vm-gui"


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
    checkout = script_dir.name == "scripts" and (script_dir.parent / "config" / "tooling-bundle.json").is_file()
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
