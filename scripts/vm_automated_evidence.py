#!/usr/bin/env python3
"""Transport primitives for private VM-automated evidence.

This module deliberately does not derive target or gate verdicts.  A trusted
raw-evidence verifier must do that before calling the canonical statement
serializer.  The functions here only provide bounded JSON/file transport, safe
archive ingress, and deterministic statement serialization.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import tempfile
from typing import BinaryIO, Iterator, Mapping
import zlib
from zipfile import BadZipFile, ZIP_DEFLATED, ZIP_STORED, ZipFile, ZipInfo


SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_TOKEN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
SAFE_SEGMENT = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")

MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_JSON_DEPTH = 64
MAX_JSON_NODES = 250_000

# The largest inspected DarkReNamer raw-evidence archive had 362 files,
# a 7,752,704-byte largest member, and 190,211,655 decompressed bytes.  These
# bounds leave room for the 22-target profile while staying finite.  The member
# bound also matches the separately designed 64 MiB raw-journal ceiling.
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 2_048
MAX_ARCHIVE_FILES = 1_024
MAX_MEMBER_BYTES = 64 * 1024 * 1024
MAX_DECOMPRESSED_BYTES = 512 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
COPY_CHUNK_BYTES = 1024 * 1024

_EXTRACTION_PREFIX = ".darkrenamer-vm-evidence-"
_WINDOWS_RESERVED = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}
_SUPPORTED_COMPRESSION = {ZIP_STORED, ZIP_DEFLATED}

REQUIRED_TARGET_IDS = frozenset({
    "core-uia-flow",
    "core-keyboard-flow",
    "layout-normal-100",
    "layout-high-contrast-100",
    "layout-normal-125",
    "layout-high-contrast-125",
    "layout-normal-150",
    "layout-high-contrast-150",
    "layout-normal-200",
    "layout-high-contrast-200",
    "layout-normal-250",
    "layout-high-contrast-250",
    "layout-normal-300",
    "layout-high-contrast-300",
    "layout-small-normal-100",
    "layout-small-high-contrast-100",
    "layout-small-text150-100",
    "process-crash",
    "recovery-export",
    "intent-only-discard",
    "worker-cancellation",
    "worker-close",
})
REQUIRED_GATE_IDS = frozenset({
    "locked-host-gate",
    "windows-backend-source-bound",
    "candidate-package-and-provenance",
    "profile-raw-evidence-verifier",
    "immutable-promotion-binding",
})


class EvidenceError(ValueError):
    """Raised when evidence transport or canonical encoding fails closed."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def require_exact_keys(value: object, expected: set[str], label: str) -> dict[str, object]:
    _require(type(value) is dict, f"{label} must be an object.")
    typed = value
    actual = set(typed)
    _require(actual == expected, f"{label} fields are invalid: {sorted(actual ^ expected)}")
    return typed


def require_int(value: object, minimum: int, maximum: int, label: str) -> int:
    _require(type(value) is int, f"{label} must be an integer, not a boolean or other type.")
    _require(minimum <= value <= maximum, f"{label} is outside its allowed range.")
    return value


def require_bool(value: object, label: str) -> bool:
    _require(type(value) is bool, f"{label} must be a boolean.")
    return value


def require_string(value: object, label: str, *, maximum_bytes: int = 512) -> str:
    _require(type(value) is str, f"{label} must be a string.")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise EvidenceError(f"{label} is not valid UTF-8 text.") from error
    _require(0 < len(encoded) <= maximum_bytes, f"{label} has an invalid encoded length.")
    return value


def _strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"JSON contains a duplicate field: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> object:
    raise EvidenceError(f"JSON contains a non-finite number: {value}")


def _validate_json_shape(value: object) -> None:
    remaining = MAX_JSON_NODES
    stack: list[tuple[object, int]] = [(value, 1)]
    while stack:
        current, depth = stack.pop()
        remaining -= 1
        _require(remaining >= 0, "JSON contains too many values.")
        _require(depth <= MAX_JSON_DEPTH, "JSON nesting is too deep.")
        if type(current) is dict:
            stack.extend((child, depth + 1) for child in current.values())
        elif type(current) is list:
            stack.extend((child, depth + 1) for child in current)
        elif type(current) is int:
            _require(-(1 << 63) <= current <= (1 << 64) - 1,
                     "JSON integer is outside the supported 64-bit range.")
        elif type(current) is float:
            _require(math.isfinite(current), "JSON contains a non-finite number.")
        elif current is not None and type(current) not in {str, bool}:
            raise EvidenceError(f"JSON contains unsupported type: {type(current).__name__}")


def parse_bounded_json_bytes(
    data: bytes,
    *,
    max_bytes: int = MAX_JSON_BYTES,
    label: str = "JSON",
) -> object:
    """Parse one bounded UTF-8 JSON value with duplicate/non-finite rejection."""

    require_int(max_bytes, 1, MAX_JSON_BYTES, "max_bytes")
    _require(type(data) is bytes, f"{label} input must be bytes.")
    _require(len(data) <= max_bytes, f"{label} exceeds the {max_bytes}-byte limit.")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceError(f"{label} is not valid UTF-8.") from error
    try:
        value = json.loads(
            text,
            object_pairs_hook=_strict_object,
            parse_constant=_reject_constant,
        )
    except EvidenceError:
        raise
    except (json.JSONDecodeError, RecursionError) as error:
        raise EvidenceError(f"{label} is not valid bounded JSON: {error}") from error
    _validate_json_shape(value)
    return value


def _open_absolute_regular(path: Path) -> BinaryIO:
    try:
        before = os.lstat(path)
    except OSError as error:
        raise EvidenceError(f"File is unavailable: {path.name}") from error
    _require(stat.S_ISREG(before.st_mode), f"File must be an ordinary file: {path.name}")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceError(f"File could not be opened safely: {path.name}") from error
    try:
        after = os.fstat(descriptor)
        _require(stat.S_ISREG(after.st_mode), f"File must be an ordinary file: {path.name}")
        _require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino),
                 f"File changed while opening: {path.name}")
        return os.fdopen(descriptor, "rb", closefd=True)
    except Exception:
        os.close(descriptor)
        raise


def load_bounded_json(
    path: Path | str,
    *,
    max_bytes: int = MAX_JSON_BYTES,
    label: str = "JSON",
) -> object:
    """Read and strictly parse one bounded ordinary JSON file."""

    require_int(max_bytes, 1, MAX_JSON_BYTES, "max_bytes")
    with _open_absolute_regular(Path(path)) as stream:
        data = stream.read(max_bytes + 1)
        _require(len(data) <= max_bytes, f"{label} exceeds the {max_bytes}-byte limit.")
        _require(stream.read(1) == b"", f"{label} grew while it was being read.")
    return parse_bounded_json_bytes(data, max_bytes=max_bytes, label=label)


@dataclass(frozen=True)
class FileReference:
    sha256: str
    size: int

    def __post_init__(self) -> None:
        _require(type(self.sha256) is str and SHA256.fullmatch(self.sha256) is not None,
                 "File reference sha256 must be lowercase hexadecimal.")
        require_int(self.size, 0, MAX_ARCHIVE_BYTES, "File reference size")

    @classmethod
    def from_json(cls, value: object, label: str = "file reference") -> "FileReference":
        fields = require_exact_keys(value, {"sha256", "size"}, label)
        return cls(fields["sha256"], fields["size"])


@dataclass(frozen=True)
class ArchiveLimits:
    max_entries: int = MAX_ARCHIVE_ENTRIES
    max_files: int = MAX_ARCHIVE_FILES
    max_member_bytes: int = MAX_MEMBER_BYTES
    max_total_bytes: int = MAX_DECOMPRESSED_BYTES
    max_compression_ratio: int = MAX_COMPRESSION_RATIO

    def __post_init__(self) -> None:
        for name, hard_maximum in (
            ("max_entries", MAX_ARCHIVE_ENTRIES),
            ("max_files", MAX_ARCHIVE_FILES),
            ("max_member_bytes", MAX_MEMBER_BYTES),
            ("max_total_bytes", MAX_DECOMPRESSED_BYTES),
            ("max_compression_ratio", MAX_COMPRESSION_RATIO),
        ):
            require_int(getattr(self, name), 1, hard_maximum, f"ArchiveLimits.{name}")


@dataclass(frozen=True)
class ExtractedEvidence:
    """A temporary verified tree valid only inside its context manager."""

    root: Path
    files: Mapping[str, FileReference]


def _validate_relative_path(value: object, label: str) -> str:
    path = require_string(value, label, maximum_bytes=512)
    try:
        path.encode("ascii")
    except UnicodeEncodeError as error:
        raise EvidenceError(f"{label} must use ASCII only.") from error
    _require("\\" not in path, f"{label} must use forward slashes.")
    _require(not path.startswith("/"), f"{label} must be relative.")
    _require(not path.endswith("/"), f"{label} must name a file, not a directory.")
    parts = path.split("/")
    _require(len(parts) <= 16 and all(parts), f"{label} has an invalid path shape.")
    for part in parts:
        _require(part not in {".", ".."}, f"{label} contains traversal.")
        _require(not part.endswith((".", " ")),
                 f"{label} contains a Windows-aliased trailing character.")
        _require(SAFE_SEGMENT.fullmatch(part) is not None,
                 f"{label} contains an unsafe path segment: {part!r}")
        stem = part.split(".", 1)[0].upper()
        _require(stem not in _WINDOWS_RESERVED,
                 f"{label} uses a Windows-reserved name: {part!r}")
    _require(str(PurePosixPath(*parts)) == path, f"{label} is not canonical.")
    return path


def _open_relative_regular(root: Path, relative_path: str) -> BinaryIO:
    safe_path = _validate_relative_path(relative_path, "relative_path")
    try:
        root_before = os.lstat(root)
    except OSError as error:
        raise EvidenceError("Evidence root is unavailable.") from error
    _require(stat.S_ISDIR(root_before.st_mode), "Evidence root must be an ordinary directory.")

    supports_openat = os.open in os.supports_dir_fd and hasattr(os, "O_DIRECTORY")
    if supports_openat:
        directory_flags = (os.O_RDONLY | os.O_DIRECTORY |
                           getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        file_flags = (os.O_RDONLY | getattr(os, "O_BINARY", 0) |
                      getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        descriptors: list[int] = []
        file_descriptor = -1
        try:
            current = os.open(root, directory_flags)
            descriptors.append(current)
            opened_root = os.fstat(current)
            _require((root_before.st_dev, root_before.st_ino) ==
                     (opened_root.st_dev, opened_root.st_ino),
                     "Evidence root changed while opening.")
            parts = safe_path.split("/")
            for part in parts[:-1]:
                current = os.open(part, directory_flags, dir_fd=current)
                descriptors.append(current)
            file_descriptor = os.open(parts[-1], file_flags, dir_fd=current)
            file_stat = os.fstat(file_descriptor)
            _require(stat.S_ISREG(file_stat.st_mode),
                     f"Referenced path is not an ordinary file: {safe_path}")
            stream = os.fdopen(file_descriptor, "rb", closefd=True)
            file_descriptor = -1
            return stream
        except OSError as error:
            raise EvidenceError(f"Referenced file could not be opened safely: {safe_path}") from error
        finally:
            if file_descriptor >= 0:
                os.close(file_descriptor)
            for descriptor in reversed(descriptors):
                os.close(descriptor)

    resolved_root = root.resolve(strict=True)
    candidate = resolved_root.joinpath(*safe_path.split("/"))
    for parent in candidate.parents:
        if parent == resolved_root:
            break
        _require(not parent.is_symlink(), f"Referenced path traverses a link: {safe_path}")
    try:
        candidate_metadata = os.lstat(candidate)
        _require(stat.S_ISREG(candidate_metadata.st_mode),
                 f"Referenced path is not an ordinary file: {safe_path}")
        resolved_candidate = candidate.resolve(strict=True)
        resolved_candidate.relative_to(resolved_root)
    except (OSError, ValueError) as error:
        raise EvidenceError(f"Referenced path escapes its root: {safe_path}") from error
    return _open_absolute_regular(resolved_candidate)


def _consume_reference(
    stream: BinaryIO,
    reference: FileReference,
    *,
    max_bytes: int,
    capture: bool,
    label: str,
) -> bytes | None:
    require_int(max_bytes, 0, MAX_ARCHIVE_BYTES, "max_bytes")
    _require(reference.size <= max_bytes, f"{label} exceeds its allowed byte limit.")
    hasher = hashlib.sha256()
    result = bytearray() if capture else None
    total = 0
    while True:
        chunk = stream.read(min(COPY_CHUNK_BYTES, max_bytes - total + 1))
        if not chunk:
            break
        total += len(chunk)
        _require(total <= max_bytes and total <= reference.size,
                 f"{label} produced more bytes than declared.")
        hasher.update(chunk)
        if result is not None:
            result.extend(chunk)
    _require(total == reference.size, f"{label} size does not match its reference.")
    _require(hasher.hexdigest() == reference.sha256,
             f"{label} SHA-256 does not match its reference.")
    return bytes(result) if result is not None else None


def verify_referenced_file(
    root: Path | str,
    relative_path: str,
    reference: FileReference,
    *,
    max_bytes: int = MAX_MEMBER_BYTES,
) -> None:
    """Verify a root-contained ordinary file without returning its host path."""

    _require(type(reference) is FileReference, "reference must be a FileReference.")
    with _open_relative_regular(Path(root), relative_path) as stream:
        _consume_reference(stream, reference, max_bytes=max_bytes, capture=False,
                           label=relative_path)


def read_referenced_file(
    root: Path | str,
    relative_path: str,
    reference: FileReference,
    *,
    max_bytes: int = MAX_MEMBER_BYTES,
) -> bytes:
    """Read a verified root-contained ordinary file within an explicit limit."""

    _require(type(reference) is FileReference, "reference must be a FileReference.")
    with _open_relative_regular(Path(root), relative_path) as stream:
        result = _consume_reference(stream, reference, max_bytes=max_bytes, capture=True,
                                    label=relative_path)
    assert result is not None
    return result


def load_referenced_json(
    root: Path | str,
    relative_path: str,
    reference: FileReference,
    *,
    max_bytes: int = MAX_JSON_BYTES,
    label: str = "referenced JSON",
) -> object:
    data = read_referenced_file(root, relative_path, reference, max_bytes=max_bytes)
    return parse_bounded_json_bytes(data, max_bytes=max_bytes, label=label)


def _coerce_inventory(
    allowed_files: Mapping[str, FileReference | Mapping[str, object]],
    limits: ArchiveLimits,
) -> dict[str, FileReference]:
    _require(isinstance(allowed_files, Mapping), "allowed_files must be a mapping.")
    _require(0 < len(allowed_files) <= limits.max_files,
             "allowed_files has an invalid file count.")
    result: dict[str, FileReference] = {}
    folded: set[str] = set()
    for raw_path, raw_reference in allowed_files.items():
        path = _validate_relative_path(raw_path, "allowed file path")
        lowered = path.casefold()
        _require(lowered not in folded, f"Allowed file paths collide by case: {path}")
        folded.add(lowered)
        reference = (raw_reference if type(raw_reference) is FileReference else
                     FileReference.from_json(raw_reference, f"allowed_files[{path!r}]"))
        _require(reference.size <= limits.max_member_bytes,
                 f"Allowed file exceeds the per-file limit: {path}")
        result[path] = reference
    _require(sum(reference.size for reference in result.values()) <= limits.max_total_bytes,
             "Allowed files exceed the aggregate byte limit.")
    folded_prefixes: dict[str, str] = {}
    folded_files = {path.casefold() for path in result}
    for path in result:
        parts = path.split("/")
        for index in range(1, len(parts) + 1):
            prefix = "/".join(parts[:index])
            folded = prefix.casefold()
            previous = folded_prefixes.setdefault(folded, prefix)
            _require(previous == prefix,
                     f"Allowed file path components collide by case: {previous}, {prefix}")
            if index < len(parts):
                _require(folded not in folded_files,
                         f"Allowed path is both a file and directory: {prefix}")
    return result


def _zip_entry_kind(info: ZipInfo) -> str:
    dos_attributes = info.external_attr & 0xFFFF
    _require(not (dos_attributes & 0x0400),
             f"ZIP entry is a reparse point: {info.filename}")
    _require(not (dos_attributes & 0x0040),
             f"ZIP entry is a device: {info.filename}")
    unix_mode = info.external_attr >> 16
    file_type = stat.S_IFMT(unix_mode)
    if info.is_dir():
        _require(file_type in {0, stat.S_IFDIR},
                 f"ZIP directory has an unsafe file type: {info.filename}")
        return "directory"
    _require(file_type in {0, stat.S_IFREG},
             f"ZIP entry is a link, device, or other non-file: {info.filename}")
    return "file"


def _preflight_zip_directory(stream: BinaryIO) -> None:
    """Bound central-directory allocation before Python constructs ZipInfo rows.

    Evidence bounds are below classic ZIP limits; split and ZIP64 archives
    have no supported use here. Scan the bounded directory ourselves because
    ZipFile does not use the EOCD entry count to bound its allocations.
    """
    stream.seek(0, io.SEEK_END)
    size = stream.tell()
    tail_start = max(0, size - 65_557)
    stream.seek(tail_start)
    tail = stream.read(65_557)
    offset = tail.rfind(b"PK\x05\x06")
    _require(offset >= 0 and offset + 22 <= len(tail), "ZIP end record is unavailable.")
    fields = struct.unpack_from("<4s4H2IH", tail, offset)
    _, disk, directory_disk, disk_entries, entries, directory_size, directory_offset, comment = fields
    end_offset = tail_start + offset
    _require(offset + 22 + comment == len(tail), "ZIP end record has trailing or inconsistent bytes.")
    _require(disk == directory_disk == 0 and disk_entries == entries,
             "Split ZIP archives are unsupported.")
    _require(entries != 0xFFFF and directory_size != 0xFFFFFFFF and directory_offset != 0xFFFFFFFF,
             "ZIP64 evidence archives are unsupported.")
    _require(0 < entries <= MAX_ARCHIVE_ENTRIES, "ZIP contains too many or no entries.")
    _require(0 < directory_size <= 4 * 1024 * 1024,
             "ZIP central directory exceeds its allocation bound.")
    _require(directory_offset + directory_size == end_offset,
             "ZIP central directory range is inconsistent or uses ZIP64.")
    stream.seek(directory_offset)
    consumed = 0
    count = 0
    while consumed < directory_size:
        _require(count < MAX_ARCHIVE_ENTRIES, "ZIP contains too many entries.")
        header = stream.read(46)
        _require(len(header) == 46 and header[:4] == b"PK\x01\x02",
                 "ZIP central directory entry is malformed.")
        compressed, expanded = struct.unpack_from("<II", header, 20)
        name_size, extra_size, comment_size, start_disk = struct.unpack_from("<4H", header, 28)
        local_offset = struct.unpack_from("<I", header, 42)[0]
        _require(start_disk == 0 and 0xFFFFFFFF not in (compressed, expanded, local_offset),
                 "ZIP64 or split member is unsupported.")
        row_size = 46 + name_size + extra_size + comment_size
        _require(name_size > 0 and consumed + row_size <= directory_size,
                 "ZIP central directory member range is inconsistent.")
        stream.seek(row_size - 46, io.SEEK_CUR)
        consumed += row_size
        count += 1
    _require(count == entries, "ZIP end record entry count differs from its directory.")
    stream.seek(0)


def _preflight_archive(
    archive: ZipFile,
    archive_stream: BinaryIO,
    inventory: Mapping[str, FileReference],
    limits: ArchiveLimits,
) -> list[tuple[ZipInfo, str, FileReference]]:
    infos = archive.infolist()
    _require(len(infos) <= limits.max_entries, "ZIP contains too many entries.")
    expected_directories = {
        "/".join(parts[:index])
        for path in inventory
        for parts in [path.split("/")]
        for index in range(1, len(parts))
    }
    seen_names: set[str] = set()
    seen_folded: set[str] = set()
    files: list[tuple[ZipInfo, str, FileReference]] = []
    directories: list[tuple[ZipInfo, str]] = []
    total = 0
    for info in infos:
        _require(info.orig_filename == info.filename,
                 "ZIP entry name contains an embedded NUL.")
        raw_name = info.filename
        directory_hint = raw_name.endswith("/")
        canonical_name = raw_name[:-1] if directory_hint else raw_name
        name = _validate_relative_path(canonical_name, "ZIP entry path")
        _require(name not in seen_names, f"ZIP contains a duplicate entry: {name}")
        folded = name.casefold()
        _require(folded not in seen_folded, f"ZIP entries collide by case: {name}")
        seen_names.add(name)
        seen_folded.add(folded)
        _require(info.flag_bits & 0x1 == 0, f"ZIP entry is encrypted: {name}")
        _require(info.compress_type in _SUPPORTED_COMPRESSION,
                 f"ZIP entry uses unsupported compression: {name}")
        kind = _zip_entry_kind(info)
        if kind == "directory":
            _require(directory_hint and name in expected_directories,
                     f"ZIP contains an unexpected directory: {name}")
            _require(info.file_size == 0, f"ZIP directory is not empty: {name}")
            directories.append((info, name))
            continue
        _require(not directory_hint, f"ZIP file has a directory name: {name}")
        _require(name in inventory, f"ZIP contains an unexpected file: {name}")
        reference = inventory[name]
        _require(info.file_size == reference.size,
                 f"ZIP member size does not match its reference: {name}")
        _require(info.file_size <= limits.max_member_bytes,
                 f"ZIP member exceeds the per-file limit: {name}")
        if info.file_size:
            _require(info.compress_size > 0, f"ZIP member has an invalid compressed size: {name}")
            _require(info.file_size <= info.compress_size * limits.max_compression_ratio,
                     f"ZIP member exceeds the compression-ratio limit: {name}")
        total += info.file_size
        _require(total <= limits.max_total_bytes,
                 "ZIP exceeds the aggregate decompressed-byte limit.")
        files.append((info, name, reference))
    _require(len(files) <= limits.max_files, "ZIP contains too many files.")
    actual_files = {name for _, name, _ in files}
    _require(actual_files == set(inventory),
             f"ZIP file inventory differs from the allowlist: {sorted(actual_files ^ set(inventory))}")

    empty_reference = FileReference(hashlib.sha256(b"").hexdigest(), 0)
    for info, name in directories:
        _verify_raw_member(archive_stream, archive, info, name, empty_reference,
                           member_limit=0, aggregate_remaining=0)
    actual_total = 0
    for info, name, reference in files:
        actual_total += _verify_raw_member(
            archive_stream,
            archive,
            info,
            name,
            reference,
            member_limit=limits.max_member_bytes,
            aggregate_remaining=limits.max_total_bytes - actual_total,
        )
    return files


def _local_payload_offset(
    archive_stream: BinaryIO,
    archive: ZipFile,
    info: ZipInfo,
    name: str,
) -> int:
    archive_stream.seek(info.header_offset)
    header = archive_stream.read(30)
    _require(len(header) == 30, f"ZIP local header is truncated: {name}")
    try:
        (signature, _version, flags, compression, _time, _date, crc,
         compressed_size, file_size, name_length, extra_length) = struct.unpack(
            "<4s5H3I2H", header)
    except struct.error as error:
        raise EvidenceError(f"ZIP local header is malformed: {name}") from error
    _require(signature == b"PK\x03\x04", f"ZIP local header signature is invalid: {name}")
    _require(flags == info.flag_bits, f"ZIP local and central flags differ: {name}")
    _require(compression == info.compress_type,
             f"ZIP local and central compression differ: {name}")
    _require(compressed_size != 0xFFFFFFFF and file_size != 0xFFFFFFFF,
             f"ZIP64 members are not supported: {name}")
    raw_name = archive_stream.read(name_length)
    extra = archive_stream.read(extra_length)
    _require(len(raw_name) == name_length and len(extra) == extra_length,
             f"ZIP local header fields are truncated: {name}")
    _require(raw_name == ((name + "/") if info.is_dir() else name).encode("ascii"),
             f"ZIP local and central names differ: {name}")
    offset = 0
    while offset < len(extra):
        _require(offset + 4 <= len(extra), f"ZIP extra field is truncated: {name}")
        field_id, field_size = struct.unpack_from("<HH", extra, offset)
        offset += 4
        _require(offset + field_size <= len(extra), f"ZIP extra field is truncated: {name}")
        _require(field_id != 0x0001, f"ZIP64 members are not supported: {name}")
        offset += field_size
    if flags & 0x08:
        _require(crc in {0, info.CRC} and compressed_size in {0, info.compress_size} and
                 file_size in {0, info.file_size},
                 f"ZIP local descriptor placeholders are inconsistent: {name}")
    else:
        _require((crc, compressed_size, file_size) ==
                 (info.CRC, info.compress_size, info.file_size),
                 f"ZIP local and central metadata differ: {name}")
    payload_offset = info.header_offset + 30 + name_length + extra_length
    _require(payload_offset + info.compress_size <= archive.start_dir,
             f"ZIP member overlaps the central directory: {name}")
    return payload_offset


def _verify_raw_member(
    archive_stream: BinaryIO,
    archive: ZipFile,
    info: ZipInfo,
    name: str,
    reference: FileReference,
    *,
    member_limit: int,
    aggregate_remaining: int,
) -> int:
    """Measure the complete compressed stream instead of trusting file_size."""

    payload_offset = _local_payload_offset(archive_stream, archive, info, name)
    archive_stream.seek(payload_offset)
    remaining = info.compress_size
    decompressor = zlib.decompressobj(-15) if info.compress_type == ZIP_DEFLATED else None
    hasher = hashlib.sha256()
    checksum = 0
    total = 0

    def accept(output: bytes) -> None:
        nonlocal checksum, total
        total += len(output)
        _require(total <= member_limit and total <= aggregate_remaining and
                 total <= reference.size,
                 f"ZIP member produced more bytes than declared: {name}")
        hasher.update(output)
        checksum = zlib.crc32(output, checksum)

    while remaining:
        compressed = archive_stream.read(min(COPY_CHUNK_BYTES, remaining))
        _require(compressed, f"ZIP compressed stream is truncated: {name}")
        remaining -= len(compressed)
        if decompressor is None:
            accept(compressed)
        else:
            budget = min(member_limit, aggregate_remaining, reference.size) - total + 1
            output = decompressor.decompress(compressed, max(1, budget))
            accept(output)
            _require(not decompressor.unconsumed_tail,
                     f"ZIP member produced more bytes than declared: {name}")
    if decompressor is not None:
        budget = min(member_limit, aggregate_remaining, reference.size) - total + 1
        accept(decompressor.flush(max(1, budget)))
        _require(decompressor.eof and not decompressor.unused_data and
                 not decompressor.unconsumed_tail,
                 f"ZIP deflate stream is incomplete or has trailing data: {name}")
    _require(total == reference.size, f"ZIP member size changed while reading: {name}")
    _require(checksum & 0xFFFFFFFF == info.CRC, f"ZIP member CRC does not match: {name}")
    _require(hasher.hexdigest() == reference.sha256,
             f"ZIP member SHA-256 does not match its reference: {name}")
    return total


def _copy_stream(
    source: BinaryIO,
    destination: BinaryIO,
    reference: FileReference,
    *,
    member_limit: int,
    aggregate_remaining: int,
    label: str,
) -> int:
    """Copy one member while enforcing actual, not only declared, byte counts."""

    hasher = hashlib.sha256()
    total = 0
    while True:
        chunk = source.read(min(COPY_CHUNK_BYTES, member_limit - total + 1,
                                aggregate_remaining - total + 1))
        if not chunk:
            break
        total += len(chunk)
        _require(total <= member_limit and total <= aggregate_remaining and
                 total <= reference.size,
                 f"ZIP member produced more bytes than declared: {label}")
        destination.write(chunk)
        hasher.update(chunk)
    _require(total == reference.size, f"ZIP member size changed while reading: {label}")
    _require(hasher.hexdigest() == reference.sha256,
             f"ZIP member SHA-256 does not match its reference: {label}")
    return total


def _owned_root_identity(path: Path) -> tuple[int, int]:
    metadata = os.lstat(path)
    _require(stat.S_ISDIR(metadata.st_mode), "Owned extraction root is not a directory.")
    return metadata.st_dev, metadata.st_ino


def _cleanup_owned_root(path: Path, identity: tuple[int, int]) -> None:
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return
    _require(path.name.startswith(_EXTRACTION_PREFIX),
             "Refusing to clean an unrecognized extraction root.")
    _require(stat.S_ISDIR(metadata.st_mode) and
             (metadata.st_dev, metadata.st_ino) == identity,
             "Refusing to clean a replaced extraction root.")
    shutil.rmtree(path)


@contextmanager
def open_verified_evidence_archive(
    archive_path: Path | str,
    archive_reference: FileReference,
    private_parent: Path | str,
    allowed_files: Mapping[str, FileReference | Mapping[str, object]],
    *,
    limits: ArchiveLimits = ArchiveLimits(),
) -> Iterator[ExtractedEvidence]:
    """Verify and temporarily extract an exact evidence-only ZIP inventory.

    The returned root exists only inside the ``with`` block.  Every member is
    non-executable (0600), directories are private (0700), and archive content
    is never executed.  The allowlist and its per-file hashes must come from a
    separately authenticated/validated manifest; this function does not assign
    authority to producer metadata or verdicts.
    """

    _require(type(archive_reference) is FileReference,
             "archive_reference must be a FileReference.")
    _require(type(limits) is ArchiveLimits, "limits must be ArchiveLimits.")
    _require(archive_reference.size <= MAX_ARCHIVE_BYTES,
             "Archive exceeds the compressed-byte limit.")
    inventory = _coerce_inventory(allowed_files, limits)
    archive_file = Path(archive_path)
    parent = Path(private_parent)
    try:
        parent_metadata = os.lstat(parent)
    except OSError as error:
        raise EvidenceError("Private extraction parent is unavailable.") from error
    _require(stat.S_ISDIR(parent_metadata.st_mode),
             "Private extraction parent must be an ordinary directory.")

    root: Path | None = None
    identity: tuple[int, int] | None = None
    try:
        with _open_absolute_regular(archive_file) as archive_stream:
            _consume_reference(archive_stream, archive_reference,
                               max_bytes=MAX_ARCHIVE_BYTES, capture=False,
                               label="evidence archive")
            archive_stream.seek(0)
            _preflight_zip_directory(archive_stream)
            with ZipFile(archive_stream, "r") as archive:
                plan = _preflight_archive(archive, archive_stream, inventory, limits)
                root = Path(tempfile.mkdtemp(prefix=_EXTRACTION_PREFIX, dir=parent))
                os.chmod(root, 0o700)
                identity = _owned_root_identity(root)
                actual_total = 0
                for info, name, reference in plan:
                    destination_path = root.joinpath(*name.split("/"))
                    destination_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    os.chmod(destination_path.parent, 0o700)
                    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
                    descriptor = os.open(destination_path, flags, 0o600)
                    try:
                        with os.fdopen(descriptor, "wb", closefd=True) as destination:
                            descriptor = -1
                            with archive.open(info, "r") as source:
                                actual_total += _copy_stream(
                                    source,
                                    destination,
                                    reference,
                                    member_limit=limits.max_member_bytes,
                                    aggregate_remaining=limits.max_total_bytes - actual_total,
                                    label=name,
                                )
                        os.chmod(destination_path, 0o600)
                    finally:
                        if descriptor >= 0:
                            os.close(descriptor)
            archive_stream.seek(0)
            _consume_reference(archive_stream, archive_reference,
                               max_bytes=MAX_ARCHIVE_BYTES, capture=False,
                               label="evidence archive after extraction")
            yield ExtractedEvidence(root=root, files=dict(inventory))
    except EvidenceError:
        raise
    except (BadZipFile, NotImplementedError, OSError, RuntimeError, zlib.error) as error:
        raise EvidenceError(f"Evidence archive is invalid: {error}") from error
    finally:
        if root is not None and identity is not None:
            _cleanup_owned_root(root, identity)


@contextmanager
def open_indexed_evidence_archive(
    archive_path: Path | str,
    archive_reference: FileReference,
    private_parent: Path | str,
) -> Iterator[ExtractedEvidence]:
    """Bootstrap the fixed evidence index from an independently pinned archive.

    The index is untrusted inventory, never a verdict or an execution plan.
    Only ``evidence-index.json`` is read before full archive verification; its
    bytes and every indexed member are then checked by the normal extractor.
    The index excludes itself to avoid a circular digest.  The caller must
    semantically validate campaign.json and all of its references afterwards.
    """
    index_name = "evidence-index.json"
    index_limit = 1024 * 1024
    _require(type(archive_reference) is FileReference,
             "Archive pin must be an independently established FileReference.")
    try:
        with _open_absolute_regular(Path(archive_path)) as stream:
            _consume_reference(stream, archive_reference, max_bytes=MAX_ARCHIVE_BYTES,
                               capture=False, label="indexed evidence archive")
            stream.seek(0)
            _preflight_zip_directory(stream)
            with ZipFile(stream, "r") as archive:
                infos = archive.infolist()
                _require(len(infos) <= MAX_ARCHIVE_ENTRIES, "ZIP contains too many entries.")
                matches = [info for info in infos if info.filename == index_name]
                _require(len(matches) == 1, "ZIP needs one fixed evidence index.")
                info = matches[0]
                _require(info.orig_filename == index_name and _zip_entry_kind(info) == "file",
                         "Evidence index is not an ordinary canonical member.")
                _require(info.flag_bits & 1 == 0 and info.compress_type in _SUPPORTED_COMPRESSION,
                         "Evidence index uses unsupported encryption or compression.")
                _require(0 < info.file_size <= index_limit and info.compress_size > 0 and
                         info.file_size <= info.compress_size * MAX_COMPRESSION_RATIO,
                         "Evidence index exceeds its byte or compression bound.")
                with archive.open(info) as member:
                    index_bytes = member.read(index_limit + 1)
                _require(len(index_bytes) == info.file_size and len(index_bytes) <= index_limit,
                         "Evidence index size is inconsistent.")
                index_reference = FileReference(hashlib.sha256(index_bytes).hexdigest(), len(index_bytes))
                # Raw DEFLATE measurement rejects hidden bytes after a forged
                # central-directory size before even parsing the bootstrap JSON.
                _verify_raw_member(stream, archive, info, index_name, index_reference,
                                   member_limit=index_limit, aggregate_remaining=index_limit)
                index = require_exact_keys(parse_bounded_json_bytes(index_bytes),
                                           {"schema", "files"}, "Evidence index")
                _require(index["schema"] == "darkrenamer-vm-automated-index-v1",
                         "Unsupported evidence index schema.")
                inventory = _coerce_inventory(index["files"], ArchiveLimits())
                _require(index_name not in inventory and "campaign.json" in inventory,
                         "Evidence index must exclude itself and include campaign.json.")
                inventory[index_name] = index_reference
                _coerce_inventory(inventory, ArchiveLimits())
        # Reopens and checks the exact external pin, rejecting substitution
        # between bootstrap and extraction. Nothing from the archive executes.
        with open_verified_evidence_archive(archive_path, archive_reference,
                                            private_parent, inventory) as extracted:
            yield extracted
    except EvidenceError:
        raise
    except (BadZipFile, NotImplementedError, OSError, RuntimeError, zlib.error) as error:
        raise EvidenceError(f"Indexed evidence archive is invalid: {error}") from error


def _require_sha1(value: object, label: str) -> str:
    text = require_string(value, label, maximum_bytes=40)
    _require(SHA1.fullmatch(text) is not None, f"{label} must be lowercase hexadecimal SHA-1.")
    return text


def _require_sha256(value: object, label: str) -> str:
    text = require_string(value, label, maximum_bytes=64)
    _require(SHA256.fullmatch(text) is not None, f"{label} must be lowercase hexadecimal SHA-256.")
    return text


def _require_token(value: object, label: str) -> str:
    text = require_string(value, label, maximum_bytes=128)
    _require(SAFE_TOKEN.fullmatch(text) is not None, f"{label} must be a safe identifier.")
    return text


def _validate_statement(statement: object) -> dict[str, object]:
    top = require_exact_keys(statement, {
        "schema", "result", "candidate", "harness", "profile", "environment",
        "targets", "required_gates", "ingress", "validation",
    }, "statement")
    _require(top["schema"] == "darkrenamer-vm-automated-statement-v1",
             "statement.schema is unsupported.")
    _require(type(top["result"]) is str and top["result"] in {"passed", "failed"},
             "statement.result is invalid.")

    candidate = require_exact_keys(top["candidate"], {
        "repository", "source_sha", "run_id", "run_attempt", "artifact_id",
        "artifact_sha256", "executable_sha256", "handoff_sha256",
    }, "statement.candidate")
    repository = require_string(candidate["repository"], "statement.candidate.repository")
    _require(REPOSITORY.fullmatch(repository) is not None,
             "statement.candidate.repository is invalid.")
    _require_sha1(candidate["source_sha"], "statement.candidate.source_sha")
    for field in ("run_id", "run_attempt", "artifact_id"):
        require_int(candidate[field], 1, (1 << 63) - 1, f"statement.candidate.{field}")
    for field in ("artifact_sha256", "executable_sha256", "handoff_sha256"):
        _require_sha256(candidate[field], f"statement.candidate.{field}")

    harness = require_exact_keys(top["harness"], {
        "repository", "source_sha", "components",
    }, "statement.harness")
    harness_repository = require_string(harness["repository"], "statement.harness.repository")
    _require(REPOSITORY.fullmatch(harness_repository) is not None,
             "statement.harness.repository is invalid.")
    _require_sha1(harness["source_sha"], "statement.harness.source_sha")
    _require(type(harness["components"]) is list and harness["components"],
             "statement.harness.components must be a non-empty array.")
    component_roles: set[str] = set()
    for index, raw_component in enumerate(harness["components"]):
        component = require_exact_keys(raw_component, {"role", "sha256"},
                                       f"statement.harness.components[{index}]")
        role = _require_token(component["role"],
                              f"statement.harness.components[{index}].role")
        _require(role not in component_roles, f"Duplicate harness component role: {role}")
        component_roles.add(role)
        _require_sha256(component["sha256"],
                        f"statement.harness.components[{index}].sha256")

    profile = require_exact_keys(top["profile"], {"id", "revision", "sha256"},
                                 "statement.profile")
    _require(profile["id"] == "vm-automated-v1-win11-ntfs",
             "statement.profile.id differs from the fixed profile.")
    _require(require_int(profile["revision"], 1, 1, "statement.profile.revision") == 1,
             "statement.profile.revision differs from the fixed profile.")
    _require_sha256(profile["sha256"], "statement.profile.sha256")

    environment = require_exact_keys(top["environment"], {
        "os_family", "architecture", "filesystem", "desktop_mode", "elevated",
        "concurrency",
    }, "statement.environment")
    _require(environment["os_family"] == "Windows 11",
             "statement.environment.os_family differs from the fixed profile.")
    _require(environment["architecture"] == "x86_64",
             "statement.environment.architecture differs from the fixed profile.")
    _require(environment["filesystem"] == "NTFS",
             "statement.environment.filesystem differs from the fixed profile.")
    _require(environment["desktop_mode"] == "managed-rdp",
             "statement.environment.desktop_mode differs from the fixed profile.")
    _require(require_bool(environment["elevated"], "statement.environment.elevated") is False,
             "statement.environment.elevated differs from the fixed profile.")
    _require(require_int(environment["concurrency"], 1, 1,
                         "statement.environment.concurrency") == 1,
             "statement.environment.concurrency differs from the fixed profile.")

    _require(type(top["targets"]) is list, "statement.targets must be an array.")
    target_ids: set[str] = set()
    for index, raw_target in enumerate(top["targets"]):
        target = require_exact_keys(raw_target, {"id", "verdict"},
                                    f"statement.targets[{index}]")
        target_id = _require_token(target["id"], f"statement.targets[{index}].id")
        _require(target_id not in target_ids, f"Duplicate statement target: {target_id}")
        target_ids.add(target_id)
        _require(type(target["verdict"]) is str and
                 target["verdict"] in {"passed", "failed", "not-run"},
                 f"statement.targets[{index}].verdict is invalid.")
    _require(target_ids == REQUIRED_TARGET_IDS,
             f"statement target IDs differ from the full profile: {sorted(target_ids ^ REQUIRED_TARGET_IDS)}")

    _require(type(top["required_gates"]) is list,
             "statement.required_gates must be an array.")
    gate_ids: set[str] = set()
    for index, raw_gate in enumerate(top["required_gates"]):
        gate = require_exact_keys(raw_gate, {"id", "sha256"},
                                  f"statement.required_gates[{index}]")
        gate_id = _require_token(gate["id"], f"statement.required_gates[{index}].id")
        _require(gate_id not in gate_ids, f"Duplicate statement gate: {gate_id}")
        gate_ids.add(gate_id)
        _require_sha256(gate["sha256"], f"statement.required_gates[{index}].sha256")
    _require(gate_ids == REQUIRED_GATE_IDS,
             f"statement gate IDs differ from the profile: {sorted(gate_ids ^ REQUIRED_GATE_IDS)}")

    ingress = require_exact_keys(top["ingress"], {
        "release_id", "asset_id", "sha256", "size",
    }, "statement.ingress")
    require_int(ingress["release_id"], 1, (1 << 63) - 1, "statement.ingress.release_id")
    require_int(ingress["asset_id"], 1, (1 << 63) - 1, "statement.ingress.asset_id")
    _require_sha256(ingress["sha256"], "statement.ingress.sha256")
    require_int(ingress["size"], 1, MAX_ARCHIVE_BYTES, "statement.ingress.size")

    validation = require_exact_keys(top["validation"], {"run_id", "run_attempt"},
                                    "statement.validation")
    require_int(validation["run_id"], 1, (1 << 63) - 1, "statement.validation.run_id")
    require_int(validation["run_attempt"], 1, (1 << 31) - 1,
                "statement.validation.run_attempt")
    return top


def _normalized_statement(statement: object) -> dict[str, object]:
    validated = _validate_statement(statement)
    normalized = dict(validated)
    harness = dict(validated["harness"])
    harness["components"] = sorted(harness["components"], key=lambda item: item["role"])
    normalized["harness"] = harness
    normalized["targets"] = sorted(validated["targets"], key=lambda item: item["id"])
    normalized["required_gates"] = sorted(validated["required_gates"],
                                          key=lambda item: item["id"])
    return normalized


def serialize_canonical_statement(statement: object) -> bytes:
    """Serialize a statement without treating its submitted verdicts as proof.

    The future raw verifier is the only safe caller allowed to derive verdicts.
    This function validates the path-free public shape and emits sorted-key,
    compact UTF-8 JSON with LF plus one final newline.
    """

    normalized = _normalized_statement(statement)
    return (json.dumps(normalized, ensure_ascii=False, sort_keys=True,
                       separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def parse_canonical_statement_bytes(data: bytes) -> dict[str, object]:
    """Parse and require byte-for-byte canonical statement serialization."""

    value = parse_bounded_json_bytes(data, max_bytes=MAX_JSON_BYTES,
                                     label="canonical statement")
    canonical = serialize_canonical_statement(value)
    _require(data == canonical, "Statement bytes are not canonical.")
    return _normalized_statement(value)
