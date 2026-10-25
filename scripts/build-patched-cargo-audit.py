#!/usr/bin/env python3
"""Build the reviewed cargo-audit source with the reviewed TLS lockfile."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tomllib
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parent.parent
RECORD = ROOT / "config/release-tool-integrity.json"


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def reviewed_source() -> tuple[dict, Path]:
    record = json.loads(RECORD.read_text(encoding="utf-8"))
    tool = record["tools"][0]
    version = tool["version"]
    if tool["id"] != "cargo-audit" or version != "0.22.2":
        raise ValueError("Unsupported cargo-audit source selection")
    source = tool["source"]
    lock = tool["lock"]
    if source["url"] != f"https://static.crates.io/crates/cargo-audit/cargo-audit-{version}.crate":
        raise ValueError("Unsupported cargo-audit source URL")
    if lock["path"] != f"config/cargo-audit-{version}-patched.lock":
        raise ValueError("Unsupported cargo-audit lock path")
    if any(re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) is None for item in (source, lock)):
        raise ValueError("Invalid cargo-audit source or lock digest")
    lock_path = ROOT / lock["path"]
    if digest(lock_path) != lock["sha256"]:
        raise ValueError("SHA-256 mismatch for cargo-audit patched lockfile")
    packages = {package["name"]: package["version"] for package in tomllib.loads(lock_path.read_text(encoding="utf-8"))["package"]}
    if (packages.get("cargo-audit") != version or packages.get("rustls") != "0.23.46" or
            packages.get("rustls-webpki") != "0.103.16" or packages.get("h2") != "0.4.16"):
        raise ValueError("Unsupported cargo-audit TLS lockfile closure")
    return tool, lock_path


def build(destination: Path, work: Path, archive: Path | None, verify_only: bool) -> None:
    tool, lock_path = reviewed_source()
    source = tool["source"]
    work.mkdir(parents=True, exist_ok=False)
    if archive is None:
        archive = work / "cargo-audit.crate"
        with urlopen(source["url"], timeout=120) as response, archive.open("xb") as output:
            shutil.copyfileobj(response, output)
    if digest(archive) != source["sha256"]:
        raise ValueError("SHA-256 mismatch for cargo-audit source archive")
    if verify_only:
        return

    source_root = f"cargo-audit-{tool['version']}"
    with tarfile.open(archive, "r:gz") as package:
        for member in package:
            path = PurePosixPath(member.name)
            if (not path.parts or path.parts[0] != source_root or
                    path.is_absolute() or ".." in path.parts or "\\" in member.name or
                    not (member.isfile() or member.isdir())):
                raise ValueError(f"Unsupported cargo-audit source entry: {member.name}")
            output = work / "source" / Path(*path.parts)
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                stream = package.extractfile(member)
                if stream is None:
                    raise ValueError(f"Unreadable cargo-audit source entry: {member.name}")
                with stream, output.open("xb") as destination_stream:
                    shutil.copyfileobj(stream, destination_stream)
    source_dir = work / "source" / source_root
    manifest = tomllib.loads((source_dir / "Cargo.toml").read_text(encoding="utf-8"))
    if manifest["package"]["name"] != "cargo-audit" or manifest["package"]["version"] != tool["version"]:
        raise ValueError("Unexpected cargo-audit source manifest")
    shutil.copyfile(lock_path, source_dir / "Cargo.lock")
    environment = os.environ.copy()
    environment["CARGO_HOME"] = str(work / "cargo-home")
    environment["CARGO_TARGET_DIR"] = str(work / "target")
    subprocess.run(["cargo", "build", "--locked", "--release", "--manifest-path",
                    str(source_dir / "Cargo.toml"), "--bin", "cargo-audit"],
                   env=environment, check=True)
    binary = work / "target" / ("release/cargo-audit.exe" if os.name == "nt" else "release/cargo-audit")
    observed = subprocess.run([str(binary), "--version"], capture_output=True, text=True, check=True)
    if observed.stdout.strip() != f"cargo-audit {tool['version']}":
        raise ValueError(f"Unexpected cargo-audit executable version: {observed.stdout.strip()}")
    output = destination / binary.name
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError(f"cargo-audit output already exists: {output}")
    shutil.copyfile(binary, output)
    output.chmod(0o755)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    try:
        build(args.destination.resolve(), args.work.resolve(), args.archive, args.verify_only)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"cargo-audit source build failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
