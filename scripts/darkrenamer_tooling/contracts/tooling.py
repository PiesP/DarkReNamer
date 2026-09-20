"""Stage and independently verify authenticated tooling module closures."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess

from darkrenamer_tooling.evidence.errors import EvidenceError


MANIFEST_NAME = "tooling-bundle.json"
RECORD_NAME = "tooling-record.json"
MAX_MANIFEST_BYTES = 512 * 1024
MAX_MODULE_BYTES = 8 * 1024 * 1024
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_FLAT_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*\Z")
_WINDOWS_RESERVED = frozenset(
    {"CON", "PRN", "AUX", "NUL", "CLOCK$"}
    | {f"COM{index}" for index in range(1, 10)}
    | {f"LPT{index}" for index in range(1, 10)}
)
_REPARSE_POINT = 0x400


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


def _is_reparse_point(metadata: os.stat_result) -> bool:
    return bool(getattr(metadata, "st_file_attributes", 0) & _REPARSE_POINT)


def _identity(metadata: os.stat_result) -> tuple[int, int, int, int]:
    return metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_size


def _validate_root(root: Path) -> tuple[int, int]:
    try:
        metadata = os.lstat(root)
    except OSError as error:
        raise EvidenceError("Tooling staging directory is unavailable.") from error
    _require(stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode)
             and not _is_reparse_point(metadata),
             "Tooling staging root must be an ordinary directory.")
    return metadata.st_dev, metadata.st_ino


def _validate_flat_filename(value: object) -> str:
    _require(type(value) is str and value and "/" not in value and "\\" not in value
             and ":" not in value and "\x00" not in value
             and value not in {".", ".."} and not value.endswith((".", " "))
             and "~" not in value and _FLAT_NAME.fullmatch(value) is not None,
             "Tooling record member filename is invalid.")
    stem = value.split(".", 1)[0].upper()
    _require(stem not in _WINDOWS_RESERVED,
             "Tooling record member filename is reserved on Windows.")
    return value


def _read_descriptor_bounded(
    descriptor: int,
    maximum: int,
    expected_size: int | None,
    label: str,
) -> bytes:
    before = os.fstat(descriptor)
    _require(stat.S_ISREG(before.st_mode) and not _is_reparse_point(before),
             label + " is not an ordinary file.")
    _require(before.st_size <= maximum, label + " exceeds its bound.")
    if expected_size is not None:
        _require(before.st_size == expected_size, label + " differs from its record.")
    limit = maximum if expected_size is None else expected_size
    chunks: list[bytes] = []
    total = 0
    while total <= limit:
        chunk = os.read(descriptor, min(64 * 1024, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    _require(total <= limit, label + " exceeds its bound.")
    after = os.fstat(descriptor)
    _require(_identity(before) == _identity(after) and total == after.st_size,
             label + " changed while it was read.")
    return b"".join(chunks)


def _read_flat_posix(
    root: Path,
    root_identity: tuple[int, int],
    name: str,
    maximum: int,
    expected_size: int | None,
    label: str,
) -> bytes:
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    file_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NONBLOCK", 0)
    directory = -1
    descriptor = -1
    try:
        directory = os.open(root, directory_flags)
        directory_metadata = os.fstat(directory)
        _require(stat.S_ISDIR(directory_metadata.st_mode)
                 and not _is_reparse_point(directory_metadata)
                 and (directory_metadata.st_dev, directory_metadata.st_ino) == root_identity,
                 "Tooling staging root changed while it was read.")
        path_metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
        _require(stat.S_ISREG(path_metadata.st_mode)
                 and not stat.S_ISLNK(path_metadata.st_mode)
                 and not _is_reparse_point(path_metadata),
                 label + " is not an ordinary file.")
        descriptor = os.open(name, file_flags, dir_fd=directory)
        _require(_identity(os.fstat(descriptor)) == _identity(path_metadata),
                 label + " changed while it was opened.")
        data = _read_descriptor_bounded(descriptor, maximum, expected_size, label)
        final_metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
        _require(_identity(final_metadata) == _identity(path_metadata),
                 label + " path changed while it was read.")
        return data
    except EvidenceError:
        raise
    except OSError as error:
        raise EvidenceError("Could not safely read " + label + ".") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if directory >= 0:
            os.close(directory)


def _read_flat_portable(
    root: Path,
    root_identity: tuple[int, int],
    name: str,
    maximum: int,
    expected_size: int | None,
    label: str,
) -> bytes:
    path = root / name
    try:
        root_before = os.lstat(root)
        path_before = os.lstat(path)
        _require((root_before.st_dev, root_before.st_ino) == root_identity
                 and stat.S_ISDIR(root_before.st_mode)
                 and not stat.S_ISLNK(root_before.st_mode)
                 and not _is_reparse_point(root_before),
                 "Tooling staging root changed while it was read.")
        _require(stat.S_ISREG(path_before.st_mode) and not stat.S_ISLNK(path_before.st_mode)
                 and not _is_reparse_point(path_before),
                 label + " is not an ordinary file.")
        flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOINHERIT", 0) | getattr(os, "O_NONBLOCK", 0)
        descriptor = os.open(path, flags)
        try:
            _require(_identity(os.fstat(descriptor)) == _identity(path_before),
                     label + " changed while it was opened.")
            data = _read_descriptor_bounded(descriptor, maximum, expected_size, label)
        finally:
            os.close(descriptor)
        path_after = os.lstat(path)
        root_after = os.lstat(root)
        _require(_identity(path_after) == _identity(path_before)
                 and (root_after.st_dev, root_after.st_ino) == root_identity,
                 label + " path changed while it was read.")
        return data
    except EvidenceError:
        raise
    except OSError as error:
        raise EvidenceError("Could not safely read " + label + ".") from error


def _read_flat_member(
    root: Path,
    root_identity: tuple[int, int],
    name: str,
    maximum: int,
    expected_size: int | None,
    label: str,
) -> bytes:
    if os.name == "posix" and hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"):
        return _read_flat_posix(root, root_identity, name, maximum, expected_size, label)
    return _read_flat_portable(root, root_identity, name, maximum, expected_size, label)


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
    root_identity = _validate_root(root)
    data = _read_flat_member(
        root, root_identity, RECORD_NAME, MAX_MANIFEST_BYTES, None, "Tooling record"
    )
    try:
        record = json.loads(data)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise EvidenceError("Tooling record is malformed.") from error
    _require(type(record) is dict and set(record) == {"schema_version", "manifest", "modules"}
             and record["schema_version"] == 1 and type(record["modules"]) is list,
             "Tooling record schema is invalid.")
    rows = [record["manifest"], *record["modules"]]
    names = [RECORD_NAME]
    validated = []
    for index, raw in enumerate(rows):
        row = raw if type(raw) is dict else {}
        required = {"file", "sha256", "size"}
        if index:
            required.add("role")
        maximum = MAX_MODULE_BYTES if index else MAX_MANIFEST_BYTES
        _require(set(row) == required
                 and type(row.get("sha256")) is str
                 and SHA256.fullmatch(row["sha256"]) is not None
                 and type(row.get("size")) is int and 0 <= row["size"] <= maximum
                 and (not index or type(row.get("role")) is str and bool(row["role"])),
                 "Tooling record member is invalid.")
        name = _validate_flat_filename(row.get("file"))
        validated.append((row, name, maximum))
        names.append(name)
    _require(len(names) == len(set(name.casefold() for name in names)),
             "Staged tooling filenames collide by case.")
    for row, name, maximum in validated:
        member = _read_flat_member(
            root, root_identity, name, maximum, row["size"],
            "Staged tooling member " + name,
        )
        _require(len(member) == row["size"] and _digest(member) == row["sha256"],
                 "Staged tooling member differs from its record: " + name)
    _require(_validate_root(root) == root_identity,
             "Tooling staging root changed while it was read.")
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
        and PurePosixPath(path).name.startswith(
            ("tooling-", "guest-", "ui-", "recovery-", "controller-")
        )
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
