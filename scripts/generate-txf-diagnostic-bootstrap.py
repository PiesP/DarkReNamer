#!/usr/bin/env python3
"""Prepare, but never execute, a source-bound Win11 TxF diagnostic script."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid


MAX_SCRIPT_BYTES = 256 * 1024
HELPER = "scripts/modules/powershell/guest-process.ps1"
WRAPPER = "scripts/tests/support/headless-txf-bootstrap.ps1"
SOURCE_FILES = (
    HELPER,
    "scripts/modules/powershell/controller-owned-root-guard.ps1",
    "scripts/test-tooling.ps1",
    "scripts/tests/powershell/test-exact-manifest-txf-phase-b.ps1",
    "scripts/tests/powershell/test-exact-manifest-txf-phase-c.ps1",
    "scripts/tests/support/exact-manifest-phase-b-observer.cs",
    "scripts/tests/support/exact-manifest-phase-b-actors.cs",
    "scripts/tests/support/exact-manifest-phase-c-streams.cs",
    "config/tooling-tests.json",
    WRAPPER,
    "scripts/generate-txf-diagnostic-bootstrap.py",
)
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
GUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
GIT_EXECUTABLE: Path | None = None


def trusted_local_path(path: Path, *, private_leaf: bool = False) -> Path:
    if not path.is_absolute():
        raise ValueError("A trusted local path must be absolute")
    current = path
    while True:
        info = current.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("A trusted local path contains a symbolic link")
        if info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022:
            raise ValueError("A trusted local path has another owner or group/other write")
        if current == path:
            if private_leaf and (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                                 or stat.S_IMODE(info.st_mode) & 0o077):
                raise ValueError("Output parent must be a private current-user directory")
            if not private_leaf and (not stat.S_ISREG(info.st_mode) or
                                     not info.st_mode & stat.S_IXUSR):
                raise ValueError("Trusted Git is not an executable ordinary file")
        elif not stat.S_ISDIR(info.st_mode):
            raise ValueError("A trusted local ancestor is not an ordinary directory")
        if current == current.parent:
            return path
        current = current.parent


def guest_pin(sid: str, account: str, admin: str, build: int,
              git_path: str, git_sha256: str, git_file_version: str,
              git_product_version: str, pwsh_path: str, pwsh_sha256: str,
              pwsh_file_version: str, ps_version: str) -> dict:
    if (not re.fullmatch(r"S-1-5-21-(?:[0-9]+-){3}[0-9]+", sid) or
            not account or len(account) > 128 or any(ord(c) < 32 for c in account)):
        raise ValueError("Expected guest SID/account is invalid")
    if admin not in ("true", "false") or not 22000 <= build <= 99999:
        raise ValueError("Expected guest token or Windows 11 build is invalid")
    for path, sha in ((git_path, git_sha256), (pwsh_path, pwsh_sha256)):
        if (not re.fullmatch(r"[A-Za-z]:\\[^\x00-\x1f]+\.exe", path, re.I) or
                any(c in path[3:] for c in '<>:"|?*') or
                any(part in ("", ".", "..") or part.endswith((".", " "))
                    for part in path[3:].split("\\")) or not HEX64.fullmatch(sha)):
            raise ValueError("Expected guest tool path or digest is invalid")
    if git_path.casefold() == pwsh_path.casefold():
        raise ValueError("Guest Git and PowerShell cannot share an executable path")
    for version in (git_file_version, git_product_version, pwsh_file_version, ps_version):
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", version):
            raise ValueError("Expected guest tool version is invalid")
    return {"sid": sid, "account": account, "admin": admin == "true", "os_build": build,
            "ps_version": ps_version,
            "git": {"path": git_path, "sha256": git_sha256,
                    "file_version": git_file_version, "product_version": git_product_version},
            "pwsh": {"path": pwsh_path, "sha256": pwsh_sha256,
                     "file_version": pwsh_file_version}}


def run_git(repo: Path, *args: str) -> bytes:
    if GIT_EXECUTABLE is None:
        raise ValueError("Trusted local Git was not selected")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                        "GIT_NO_REPLACE_OBJECTS": "1", "GIT_OPTIONAL_LOCKS": "0"})
    completed = subprocess.run(
        [str(GIT_EXECUTABLE), "-c", "core.fsmonitor=false", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=10,
        check=False,
    )
    if completed.returncode:
        raise ValueError(f"Local Git identity failed: {args[0]}")
    return completed.stdout


def source_pin(repo: Path, expected_head: str) -> dict:
    head = run_git(repo, "rev-parse", "HEAD").decode("ascii").strip()
    tree = run_git(repo, "rev-parse", "HEAD^{tree}").decode("ascii").strip()
    if not HEX40.fullmatch(expected_head) or head != expected_head or not HEX40.fullmatch(tree):
        raise ValueError("The expected exact HEAD/tree differs or is malformed")
    if run_git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all"):
        raise ValueError("Source checkout is not clean; prepare after normal integration")
    index_flags = run_git(repo, "ls-files", "-v", "-z").split(b"\0")
    if any(entry and not entry.startswith(b"H ") for entry in index_flags):
        raise ValueError("Source index has hidden or unsupported worktree flags")
    tracked = set(run_git(repo, "ls-files", "-z").decode("utf-8").split("\0"))
    if not set(SOURCE_FILES).issubset(tracked):
        raise ValueError("A required bootstrap/runtime source file is not tracked")
    hashes = {}
    for relative in SOURCE_FILES:
        path = repo / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Source is not an ordinary file: {relative}")
        working = path.read_bytes()
        committed = run_git(repo, "show", f"HEAD:{relative}")
        if working != committed:
            raise ValueError(f"Source differs from committed blob: {relative}")
        hashes[relative] = hashlib.sha256(working).hexdigest()
    return {"head": head, "tree": tree, "files": hashes}


def git_route_pin(backend: str, origin: str) -> dict:
    # Bind only the independently observed installed Git system-config cohort.
    if backend != "schannel" or origin != "file:C:/Program Files/Git/etc/gitconfig":
        raise ValueError("Expected Git backend or origin is outside the reviewed route")
    return {"backend": backend, "origin": origin}


def assemble(repo: Path, pin: dict, vm_guid: str, guest: dict, git_route: dict) -> bytes:
    guid = vm_guid.lower()
    if not GUID.fullmatch(guid) or uuid.UUID(guid).int == 0:
        raise ValueError("Expected VM GUID must be a nonzero canonical GUID")
    if git_route != git_route_pin(git_route.get("backend"), git_route.get("origin")):
        raise ValueError("Git route pin differs")
    pinned = {"schema": "dark240-win11-headless-bootstrap-pin-v1", "vm_guid": guid,
              "guest": guest, "git_route": git_route, **pin}
    literal = base64.b64encode(json.dumps(pinned, sort_keys=True, separators=(",", ":")).encode()).decode()
    helper = (repo / HELPER).read_bytes()
    wrapper = (repo / WRAPPER).read_bytes()
    if b"__HEADLESS_PIN_BASE64__" not in wrapper or wrapper.count(b"__HEADLESS_PIN_BASE64__") != 1:
        raise ValueError("Bootstrap pin insertion point is missing or ambiguous")
    generated = helper + b"\r\n" + wrapper.replace(b"__HEADLESS_PIN_BASE64__", literal.encode("ascii"))
    if len(generated) > MAX_SCRIPT_BYTES:
        raise ValueError("Generated guest script exceeds 256 KiB")
    return generated


def prepare(repo: Path, expected_head: str, vm_guid: str, output_parent: Path,
            trusted_git: Path, guest: dict, git_route: dict) -> Path:
    global GIT_EXECUTABLE
    GIT_EXECUTABLE = trusted_local_path(trusted_git)
    repo = repo.resolve(strict=True)
    trusted_local_path(output_parent, private_leaf=True)
    output_parent = output_parent.resolve(strict=True)
    if repo == output_parent or repo in output_parent.parents or output_parent in repo.parents:
        raise ValueError("Prepared output must be outside the source checkout")
    pin = source_pin(repo, expected_head)
    script = assemble(repo, pin, vm_guid, guest, git_route)
    name = f"dark240-win11-headless-{uuid.uuid4().hex}"
    destination = output_parent / name
    destination.mkdir(mode=0o700)
    try:
        artifacts = {
            "bootstrap.ps1": script,
            "prepare-receipt.json": (json.dumps({
                "schema": "dark240-win11-headless-prepare-v1",
                "source": pin,
                "guest": guest,
                "git_route": git_route,
                "vm_guid": vm_guid.lower(),
                "bootstrap_sha256": hashlib.sha256(script).hexdigest(),
                "bootstrap_bytes": len(script),
                "execution": "not-run",
                "transport": "existing pinned-SSH guest-exec --apply only",
                "host_capture_cap": "unverified; guest payload bound is separate",
                "guest_exec_outer_timeout_floor_seconds": 780,
            }, sort_keys=True, indent=2) + "\n").encode(),
        }
        for leaf, data in artifacts.items():
            fd = os.open(destination / leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        return destination
    except Exception:
        # Preserve the failed preparation directory and any complete partial evidence.
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--expected-vm-guid", required=True)
    parser.add_argument("--private-output-parent", type=Path, required=True)
    parser.add_argument("--trusted-git", type=Path, required=True)
    parser.add_argument("--expected-guest-sid", required=True)
    parser.add_argument("--expected-guest-account", required=True)
    parser.add_argument("--expected-guest-admin", choices=("true", "false"), required=True)
    parser.add_argument("--expected-os-build", type=int, required=True)
    parser.add_argument("--expected-git-path", required=True)
    parser.add_argument("--expected-git-sha256", required=True)
    parser.add_argument("--expected-git-file-version", required=True)
    parser.add_argument("--expected-git-product-version", required=True)
    parser.add_argument("--expected-pwsh-path", required=True)
    parser.add_argument("--expected-pwsh-sha256", required=True)
    parser.add_argument("--expected-pwsh-file-version", required=True)
    parser.add_argument("--expected-ps-version", required=True)
    parser.add_argument("--expected-git-ssl-backend", required=True)
    parser.add_argument("--expected-git-ssl-backend-origin", required=True)
    args = parser.parse_args()
    try:
        guest = guest_pin(args.expected_guest_sid, args.expected_guest_account,
                          args.expected_guest_admin, args.expected_os_build,
                          args.expected_git_path, args.expected_git_sha256,
                          args.expected_git_file_version, args.expected_git_product_version,
                          args.expected_pwsh_path, args.expected_pwsh_sha256,
                          args.expected_pwsh_file_version, args.expected_ps_version)
        route = git_route_pin(args.expected_git_ssl_backend,
                              args.expected_git_ssl_backend_origin)
        destination = prepare(args.repo, args.expected_head, args.expected_vm_guid,
                              args.private_output_parent, args.trusted_git, guest, route)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f"Preparation refused: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
