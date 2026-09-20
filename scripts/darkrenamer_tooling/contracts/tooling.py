"""Stage and independently verify authenticated tooling module closures."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

from darkrenamer_tooling.evidence.errors import EvidenceError


MANIFEST_NAME = "tooling-bundle.json"
RECORD_NAME = "tooling-record.json"
MAX_MANIFEST_BYTES = 512 * 1024
MAX_MODULE_BYTES = 8 * 1024 * 1024
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _write_new(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)


def _reference(name: str, data: bytes) -> dict[str, object]:
    return {"file": name, "sha256": _digest(data), "size": len(data)}


def stage_verified_tooling(verified, destination: Path) -> dict[str, object]:
    """Copy one already frozen closure without reopening any source member."""
    destination = Path(destination)
    _require(destination.is_dir() and not destination.is_symlink(),
             "Tooling destination must be an existing ordinary directory.")
    manifest = bytes(verified.manifest_bytes)
    _require(_digest(manifest) == verified.manifest_sha256,
             "Frozen tooling manifest digest is inconsistent.")
    manifest_path = destination / MANIFEST_NAME
    _write_new(manifest_path, manifest)
    modules = []
    for entry in verified.entries:
        data = verified.bytes_for_role(entry.role)
        _require(_digest(data) == entry.sha256,
                 "Frozen tooling module digest is inconsistent: " + entry.role)
        _write_new(destination / entry.bundle, data)
        modules.append({"role": entry.role, **_reference(entry.bundle, data)})
    record = {
        "schema_version": 1,
        "manifest": _reference(MANIFEST_NAME, manifest),
        "modules": modules,
    }
    _write_new(
        destination / RECORD_NAME,
        (json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode(),
    )
    return record


def staged_tooling_files(root: Path) -> list[str]:
    """Validate a staged record and return its complete flat file inventory."""
    root = Path(root)
    record_path = root / RECORD_NAME
    _require(record_path.is_file() and not record_path.is_symlink(),
             "Tooling record is unavailable.")
    data = record_path.read_bytes()
    _require(len(data) <= MAX_MANIFEST_BYTES, "Tooling record exceeds its bound.")
    try:
        record = json.loads(data)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise EvidenceError("Tooling record is malformed.") from error
    _require(type(record) is dict and set(record) == {"schema_version", "manifest", "modules"}
             and record["schema_version"] == 1 and type(record["modules"]) is list,
             "Tooling record schema is invalid.")
    rows = [record["manifest"], *record["modules"]]
    names = [RECORD_NAME]
    for raw in rows:
        row = raw if type(raw) is dict else {}
        required = {"file", "sha256", "size"}
        if "role" in row:
            required.add("role")
        _require(set(row) == required and type(row.get("file")) is str
                 and PurePosixPath(row["file"]).name == row["file"]
                 and SHA256.fullmatch(row.get("sha256", "")) is not None
                 and type(row.get("size")) is int and 0 <= row["size"] <= MAX_MODULE_BYTES,
                 "Tooling record member is invalid.")
        path = root / row["file"]
        _require(path.is_file() and not path.is_symlink(),
                 "Staged tooling member is unavailable: " + row["file"])
        member = path.read_bytes()
        _require(len(member) == row["size"] and _digest(member) == row["sha256"],
                 "Staged tooling member differs from its record: " + row["file"])
        names.append(row["file"])
    _require(len(names) == len(set(name.casefold() for name in names)),
             "Staged tooling filenames collide by case.")
    return names


def trusted_tooling_inventory(
    checkout: Path, source_sha: str, required_roles: tuple[str, ...]
) -> dict[str, object]:
    """Read the manifest and every declared module from trusted Git blobs."""
    _require(re.fullmatch(r"[0-9a-f]{40}", source_sha) is not None,
             "Trusted tooling source SHA is invalid.")
    checkout = Path(checkout).resolve(strict=True)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    _require(head == source_sha, "Trusted tooling checkout does not match the selected source.")

    def blob(path: str, maximum: int) -> bytes:
        tree = subprocess.check_output(
            ["git", "ls-tree", source_sha, "--", path], cwd=checkout, text=True
        ).strip()
        _require(tree.startswith(("100644 blob ", "100755 blob ")) and tree.endswith("\t" + path),
                 "Trusted tooling member is not one tracked ordinary blob: " + path)
        data = subprocess.check_output(["git", "show", source_sha + ":" + path], cwd=checkout)
        _require(len(data) <= maximum, "Trusted tooling member exceeds its bound: " + path)
        return data

    manifest = blob("config/tooling-bundle.json", MAX_MANIFEST_BYTES)
    try:
        parsed = json.loads(manifest)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise EvidenceError("Trusted tooling manifest is malformed.") from error
    _require(type(parsed) is dict and set(parsed) == {"schema_version", "modules"}
             and parsed["schema_version"] == 1 and type(parsed["modules"]) is list,
             "Trusted tooling manifest schema is invalid.")
    by_role = {}
    for entry in parsed["modules"]:
        _require(type(entry) is dict and set(entry) == {
            "role", "source", "bundle", "kind", "module", "sha256", "dependencies"
        }, "Trusted tooling manifest entry is invalid.")
        source = entry["source"]
        bundle = entry["bundle"]
        _require(type(source) is str and source.startswith("scripts/")
                 and type(bundle) is str and PurePosixPath(bundle).name == bundle,
                 "Trusted tooling manifest path is invalid.")
        _require(type(entry["role"]) is str and type(entry["dependencies"]) is list
                 and all(type(role) is str for role in entry["dependencies"]),
                 "Trusted tooling dependency declaration is invalid.")
        _require(entry["role"] not in by_role,
                 "Trusted tooling manifest contains a duplicate role.")
        by_role[entry["role"]] = entry
    _require(type(required_roles) is tuple and required_roles
             and len(required_roles) == len(set(required_roles))
             and all(role in by_role for role in required_roles),
             "Trusted tooling required roles are invalid.")
    selected = set()
    visiting = set()

    def select(role: str) -> None:
        _require(role not in visiting, "Trusted tooling dependencies contain a cycle.")
        if role in selected:
            return
        visiting.add(role)
        for dependency in by_role[role]["dependencies"]:
            _require(dependency in by_role, "Trusted tooling dependency is unknown.")
            select(dependency)
        visiting.remove(role)
        selected.add(role)

    for role in required_roles:
        select(role)
    modules = []
    for entry in parsed["modules"]:
        if entry["role"] not in selected:
            continue
        data = blob(entry["source"], MAX_MODULE_BYTES)
        _require(_digest(data) == entry["sha256"],
                 "Trusted tooling module differs from its manifest: " + entry["role"])
        modules.append({"role": entry["role"], **_reference(entry["bundle"], data)})
    return {
        "manifest": _reference(MANIFEST_NAME, manifest),
        "modules": modules,
    }


def verify_retained_tooling(reader, prefix: str, trusted: dict[str, object]) -> str:
    """Bind one retained flat closure to independently read trusted Git blobs."""
    _require(type(prefix) is str and (not prefix or prefix.endswith("/")),
             "Retained tooling prefix is invalid.")
    expected_rows = [trusted["manifest"], *trusted["modules"]]
    expected_names = {row["file"] for row in expected_rows}
    parent = prefix.rstrip("/") or "."
    observed_names = {
        PurePosixPath(path).name
        for path in reader.evidence.files
        if str(PurePosixPath(path).parent) == parent
        and PurePosixPath(path).name.startswith("tooling-")
        and PurePosixPath(path).suffix in {".py", ".ps1", ".psm1"}
    }
    _require(observed_names == expected_names - {MANIFEST_NAME},
             "Retained tooling module inventory is incomplete or unexpected.")
    for row in expected_rows:
        path = prefix + row["file"]
        _require(path in reader.evidence.files
                 and reader.evidence.files[path].sha256 == row["sha256"]
                 and reader.evidence.files[path].size == row["size"],
                 "Retained tooling bytes differ from trusted source: " + row["file"])
    return _digest((json.dumps(trusted, sort_keys=True, separators=(",", ":")) + "\n").encode())
