"""Run and package a selected fixed VM campaign through the common VM CLI."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import time
import uuid
from zipfile import ZIP_STORED, ZipFile, ZipInfo

from darkrenamer_tooling.campaign.planning import new_plan, validate_ledger
from darkrenamer_tooling.contracts.binding import Candidate
from darkrenamer_tooling.contracts.tooling import staged_tooling_files
from darkrenamer_tooling.evidence.archive import (
    EvidenceError, MAX_ARCHIVE_ENTRIES, MAX_ARCHIVE_FILES, load_bounded_json,
    profile_definition, validate_profile,
)
from darkrenamer_tooling.vm import connection as vm_connection, launcher
from darkrenamer_tooling.vm.launcher import (
    TEST_OUTPUT_AGGREGATE_MAXIMUM_BYTES, TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES,
)


MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_FILES = MAX_ARCHIVE_FILES
MAX_ENTRIES = MAX_ARCHIVE_ENTRIES
MAX_INDEX_BYTES = 1024 * 1024
SAFE_SEGMENT = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
WINDOWS_RESERVED = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}
_DIR_FD_FUNCTIONS = (os.open, os.stat, os.link, os.unlink, os.mkdir)
_NOFOLLOW_FUNCTIONS = (os.stat, os.link)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_segment(value: str) -> str:
    require(type(value) is str and SAFE_SEGMENT.fullmatch(value) is not None,
            "Evidence path contains an unsafe segment.")
    require(value not in {".", ".."} and not value.endswith((".", " ")),
            "Evidence path contains a Windows alias.")
    require(value.split(".", 1)[0].upper() not in WINDOWS_RESERVED,
            "Evidence path uses a Windows-reserved name.")
    return value


def safe_relative(value: str) -> str:
    require(type(value) is str and "\\" not in value and not value.startswith("/"),
            "Evidence path must be canonical and relative.")
    parts = value.split("/")
    require(1 <= len(parts) <= 16 and all(parts), "Evidence path depth is invalid.")
    for part in parts:
        safe_segment(part)
    require(PurePosixPath(*parts).as_posix() == value, "Evidence path is not canonical.")
    return value


def ordinary_directory(path: Path, label: str) -> Path:
    path = Path(path)
    require(path.is_absolute(), label + " must be absolute.")
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ValueError(label + " is unavailable.") from error
    require(stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
            label + " must be an ordinary directory.")
    return path.resolve(strict=True)


def _private_parent_state(descriptor: int, path: Path, label: str,
                          identity: tuple[int, int] | None = None) -> tuple[int, int]:
    """Check the opened POSIX directory and its selected pathname together."""
    opened = os.fstat(descriptor)
    selected = os.lstat(path)
    actual = (opened.st_dev, opened.st_ino)
    require(stat.S_ISDIR(opened.st_mode) and stat.S_ISDIR(selected.st_mode) and
            actual == (selected.st_dev, selected.st_ino) and
            (identity is None or actual == identity) and
            opened.st_uid == os.geteuid() and selected.st_uid == os.geteuid() and
            stat.S_IMODE(opened.st_mode) == 0o700 and
            stat.S_IMODE(selected.st_mode) == 0o700,
            label + " must remain an effective-user-owned private (0700) ordinary directory.")
    return actual


@contextmanager
def private_parent(path: Path, label: str):
    """Retain the validated packaging parent for relative filesystem operations."""
    path = Path(path)
    require(path.is_absolute(), label + " must be absolute.")
    required = ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC")
    require(os.name == "posix" and hasattr(os, "geteuid") and
            all(hasattr(os, name) for name in required) and
            all(function in os.supports_dir_fd for function in _DIR_FD_FUNCTIONS) and
            all(function in os.supports_follow_symlinks for function in _NOFOLLOW_FUNCTIONS),
            label + " requires POSIX directory-descriptor capabilities.")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY |
                             os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise ValueError(label + " must be an available ordinary directory.") from error
    try:
        identity = _private_parent_state(descriptor, path, label)
        yield descriptor, identity
    except BaseException as primary:
        try:
            os.close(descriptor)
        except BaseException as cleanup:
            raise RuntimeError(label + " failed: " + _bounded_error(primary) +
                               "; descriptor cleanup uncertain: " +
                               _bounded_error(cleanup)) from primary
        raise
    else:
        os.close(descriptor)


def ordinary_file(path: Path, label: str, maximum: int = MAX_FILE_BYTES) -> Path:
    path = Path(path)
    require(path.is_absolute(), label + " must be absolute.")
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ValueError(label + " is unavailable.") from error
    require(stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
            label + " must be an ordinary file.")
    require(metadata.st_size <= maximum, label + " exceeds its byte bound.")
    return path.resolve(strict=True)


def frozen_file(path: Path, maximum: int = MAX_FILE_BYTES) -> dict[str, object]:
    path = ordinary_file(path, "Frozen input", maximum)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode), "Frozen input must remain an ordinary file.")
        algorithm = hashlib.sha256()
        size = 0
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            size += len(block)
            require(size <= maximum, "Frozen input exceeds its byte bound.")
            algorithm.update(block)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) and size == before.st_size,
            "Frozen input changed while hashing.")
    return {
        "device": before.st_dev,
        "inode": before.st_ino,
        "size": size,
        "mtime_ns": before.st_mtime_ns,
        "sha256": algorithm.hexdigest(),
    }


def read_frozen_file(path: Path, frozen: dict[str, object]) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        identity = {
            "device": before.st_dev, "inode": before.st_ino, "size": before.st_size,
            "mtime_ns": before.st_mtime_ns,
        }
        require(all(identity[name] == frozen[name] for name in identity),
                "Frozen evidence file changed before packaging.")
        chunks = []
        size = 0
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            size += len(block)
            require(size <= MAX_FILE_BYTES,
                    "Frozen evidence file exceeds its packaging byte bound.")
            chunks.append(block)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    data = b"".join(chunks)
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) and
            len(data) == frozen["size"] and digest_bytes(data) == frozen["sha256"],
            "Frozen evidence file changed while packaging.")
    require(frozen_file(path) == frozen, "Frozen evidence file changed after packaging read.")
    return data


def write_json(path: Path, value: object, *, exclusive: bool = True) -> None:
    data = (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
    mode = "xb" if exclusive else "wb"
    with path.open(mode) as stream:
        stream.write(data)


def copy_frozen_file(source: Path, destination: Path) -> dict[str, object]:
    frozen = frozen_file(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("xb") as stream:
        stream.write(read_frozen_file(source, frozen))
    require(frozen_file(destination)["sha256"] == frozen["sha256"],
            "Copied evidence differs from its frozen source.")
    require(frozen_file(source) == frozen, "Evidence source changed during copy.")
    return frozen


def clean_source_sha(root: Path) -> str:
    root = ordinary_directory(root, "Source checkout")
    top = Path(subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True
    ).strip()).resolve(strict=True)
    require(top == root, "Source checkout must be an exact worktree root.")
    require(not subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain"], text=True
    ).strip(), "Source checkout must be clean.")
    source = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    require(re.fullmatch(r"[0-9a-f]{40}", source) is not None, "Source checkout HEAD is invalid.")
    return source


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def new_external_root(repo: Path, requested: Path) -> Path:
    requested = Path(requested)
    require(requested.is_absolute(), "Campaign output root must be absolute.")
    require(not requested.exists() and not requested.is_symlink(),
            "Campaign output root must be new.")
    with private_parent(requested.parent, "Campaign output parent") as (parent_fd, identity):
        target = requested.parent.resolve(strict=True) / safe_segment(requested.name)
        resolved_repo = repo.resolve(strict=True)
        require(not target.is_relative_to(resolved_repo) and not resolved_repo.is_relative_to(target),
                "Campaign output root must be external to the checkout.")
        _private_parent_state(parent_fd, requested.parent, "Campaign output parent", identity)
        os.mkdir(target.name, mode=0o700, dir_fd=parent_fd)
        _private_parent_state(parent_fd, requested.parent, "Campaign output parent", identity)
    return target


def new_archive_path(repo: Path, requested: Path, output: Path) -> Path:
    requested = Path(requested)
    require(requested.is_absolute() and requested.suffix.lower() == ".zip",
            "Campaign archive must be an absolute ZIP path.")
    require(not requested.exists() and not requested.is_symlink(), "Campaign archive must be new.")
    with private_parent(requested.parent, "Campaign archive parent") as (parent_fd, identity):
        target = requested.parent.resolve(strict=True) / safe_segment(requested.name)
        resolved_repo = repo.resolve(strict=True)
        require(not target.is_relative_to(resolved_repo) and
                not resolved_repo.is_relative_to(target) and
                not target.is_relative_to(output.resolve(strict=False)),
                "Campaign archive must remain outside the checkout and package root.")
        _private_parent_state(parent_fd, requested.parent, "Campaign archive parent", identity)
    return target


@contextmanager
def campaign_lock(expected_vm_id: str, state_root: Path | None = None):
    """Hold the one-VM campaign lock; callers of execute() hold this themselves."""
    try:
        identity = str(uuid.UUID(expected_vm_id))
    except (ValueError, AttributeError) as error:
        raise ValueError("Campaign VM identity is invalid.") from error
    require(uuid.UUID(identity).int != 0, "Campaign VM identity is invalid.")
    root = (Path.home() / ".local" / "state" / "hyperv-control"
            if state_root is None else Path(state_root))
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = os.lstat(root)
    require(stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode),
            "Campaign lock root must be an ordinary directory.")
    path = root / (identity + ".lock")
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(descriptor).st_mode), "Campaign lock must be an ordinary file.")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("A VM-automated campaign is already running for this VM.") from error
        os.ftruncate(descriptor, 0)
        os.write(descriptor, (str(os.getpid()) + "\n").encode())
        yield path
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def backend_files(result: dict) -> list[str]:
    require(type(result) is dict and type(result.get("tests")) is list,
            "Backend result lacks its native test rows.")
    names = []
    output_bytes = 0
    for row in result["tests"]:
        require(type(row) is dict, "Backend test row is invalid.")
        binary = safe_segment(row.get("file"))
        require(binary.endswith(".exe"), "Backend test artifact is not an executable leaf.")
        names.append(binary)
        for channel in ("stdout", "stderr"):
            reference = row.get(channel)
            require(type(reference) is dict and set(reference) == {"file", "sha256", "bytes"},
                    "Backend test output reference is invalid.")
            name = safe_segment(reference["file"])
            require(type(reference["sha256"]) is str and
                    re.fullmatch(r"[0-9a-f]{64}", reference["sha256"]) is not None,
                    "Backend test output digest is invalid.")
            require(type(reference["bytes"]) is int and 0 <= reference["bytes"] <=
                    TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES and output_bytes <=
                    TEST_OUTPUT_AGGREGATE_MAXIMUM_BYTES - reference["bytes"],
                    "Backend test output exceeds its size bound.")
            output_bytes += reference["bytes"]
            names.append(name)
    require(len(names) == len(set(name.casefold() for name in names)),
            "Backend test output names collide.")
    return names


def prepare_backend(source: Path, destination: Path, profile: dict,
                    harness_sha: str, native_runner, *, profile_sha256: str | None = None) -> dict:
    source = ordinary_directory(source, "Backend evidence root")
    # Native PowerShell records may contain one UTF-8 BOM. Freeze their exact
    # bytes before parsing and independently derive required test functions
    # from each binary's complete stdout transcript.
    from darkrenamer_tooling.campaign.verifier import EvidenceReader, verify_backend_execution
    from darkrenamer_tooling.contracts.platform import verify_controller_cleanup
    from darkrenamer_tooling.evidence.archive import ExtractedEvidence, FileReference
    pins = {}
    for name in ("bundle.json", "result.json", "transport.json"):
        frozen = frozen_file(source / name)
        pins[name] = FileReference(frozen["sha256"], frozen["size"])
    reader = EvidenceReader(ExtractedEvidence(source, pins))
    manifest, result, transport = (reader.json(name) for name in ("bundle.json", "result.json", "transport.json"))
    require(type(manifest) is dict and manifest.get("schema_version") == 1 and
            manifest.get("source_sha") == harness_sha and manifest.get("source_state") == "clean" and
            type(manifest.get("test_binaries")) is list and manifest["test_binaries"],
            "Backend evidence is not a clean source-bound native bundle.")
    for name in backend_files(result):
        frozen = frozen_file(source / name)
        pins[name] = FileReference(frozen["sha256"], frozen["size"])
    verify_backend_execution(reader, "bundle.json", "result.json", source_sha=harness_sha,
                             required_tests=profile["required_backend_test_names"],
                             profile_id=profile.get("profile_id", "vm-automated-v1-win11-ntfs"),
                             profile_sha256=profile_sha256)
    require(transport.get("guest_cleanup") is True, "Backend controller cleanup did not finish.")
    external_cleanup = verify_controller_cleanup(transport.get("raw_cleanup"),
        profile_id=profile.get("profile_id", "vm-automated-v1-win11-ntfs"),
        profile_sha256=profile_sha256)
    embedded_transport = result.get("transport")
    require(type(embedded_transport) is dict,
            "Backend result lacks its embedded controller transport.")
    embedded_cleanup = verify_controller_cleanup(embedded_transport.get("raw_cleanup"),
        profile_id=profile.get("profile_id", "vm-automated-v1-win11-ntfs"),
        profile_sha256=profile_sha256)
    require(external_cleanup == embedded_cleanup,
            "Backend embedded and external controller cleanup observations differ.")
    native_options = ({"profile_id": profile["profile_id"], "profile_sha256": profile_sha256}
                      if profile.get("profile_id") == "vm-automated-v2-owned-resources" else {})
    require(native_runner.verify_result(source, manifest, result, **native_options),
            "Backend native runner result did not pass its existing validator.")
    destination.mkdir()
    selected = [
        "bundle.json", "result.json", "transport.json", *backend_files(result),
        *staged_tooling_files(source),
    ]
    require(len(selected) == len(set(name.casefold() for name in selected)),
            "Backend evidence contains colliding selected files.")
    copied = []
    for name in selected:
        frozen = copy_frozen_file(source / name, destination / name)
        copied.append({"file": "backend/" + name,
                       "sha256": frozen["sha256"], "size": frozen["size"]})
    return {
        "source_sha": harness_sha,
        "bundle": "backend/bundle.json",
        "result": "backend/result.json",
        "transport": "backend/transport.json",
        "files": copied,
    }


def slot_runtime(slot: dict, profile: dict) -> dict:
    targets = {row["id"]: row for row in profile["required_targets"]}
    if slot["stability_index"] is not None or slot["id"] == "core-uia-flow":
        environment = profile["stability"]["environment"] if slot["stability_index"] else \
            profile["representative_core_environment"]
        return {"kind": "core", **environment}
    target = targets[slot["id"]]
    if target["executor"] == "windows-vm-recovery-acceptance":
        environment = profile["representative_core_environment"]
        return {"kind": "recovery", **environment, "mode": target["mode"],
                "fixture_count": target["fixture_count"],
                "recovery_export": bool(target.get("recovery_export")),
                "intent_discard": bool(target.get("intent_only_candidate_discard"))}
    if slot["id"] == "core-keyboard-flow":
        environment = profile["representative_core_environment"]
        return {"kind": "ui", **environment, "mode": "current-dpi",
                "appearance": "system", "high_contrast": False,
                "layout_variant": "command-rails"}
    return {
        "kind": "ui",
        "scale_percent": target["scale_percent"],
        "hwnd_dpi": target["hwnd_dpi"],
        "text_scale_percent": target["text_scale_percent"],
        "desktop_width": target["desktop_width"],
        "desktop_height": target["desktop_height"],
        "mode": "text-scale" if target["text_scale_percent"] == 150 else "current-dpi",
        "appearance": target["appearance"],
        "high_contrast": target["contrast"] == "high-contrast",
        "layout_variant": target.get("layout_variant", "command-rails"),
    }


def acceptance_manifest(slot: dict, runtime: dict, args, connection: dict,
                        guest_preflight: dict, repo: Path) -> dict:
    observer_sha = frozen_file(repo / "scripts" / "windows-vm-acceptance.ps1")["sha256"]
    runner_sha = frozen_file(repo / "scripts" / "windows-vm-guest.ps1")["sha256"]
    run_id = args.campaign_id + "-" + slot["id"]
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", run_id) is not None,
            "Campaign UI run identifier is too long.")
    return {
        "schema_version": 1,
        "run_id": run_id,
        "source_sha": args.candidate_source_sha,
        "guest_preflight": guest_preflight,
        "artifacts": {
            "application": {"file": "inputs/DarkReNamer.exe",
                            "sha256": args.candidate_executable_sha256},
            "runner": {"file": "inputs/windows-vm-guest.ps1", "sha256": runner_sha},
            "observer": {"file": "inputs/windows-vm-acceptance.ps1", "sha256": observer_sha},
        },
        "request": {
            "mode": runtime["mode"],
            "appearance": runtime["appearance"],
            "desktop": {"width": runtime["desktop_width"],
                        "height": runtime["desktop_height"], "dpi": runtime["hwnd_dpi"]},
            "text_scale_percent": runtime["text_scale_percent"],
            "layout_variant": runtime["layout_variant"],
        },
    }


def candidate_arguments(args) -> list[str]:
    return [
        "--candidate-handoff-root", str(args.candidate_handoff_root),
        "--candidate-source-root", str(args.candidate_source_root),
        "--candidate-run-metadata", str(args.candidate_run_metadata),
        "--candidate-artifact-metadata", str(args.candidate_artifact_metadata),
        "--candidate-source-sha", args.candidate_source_sha,
        "--candidate-workflow-run", args.candidate_workflow_run,
        "--candidate-run-attempt", args.candidate_run_attempt,
        "--candidate-artifact-id", args.candidate_artifact_id,
        "--candidate-executable-sha256", args.candidate_executable_sha256,
    ]


def run_command(repo: Path, bundle: Path, input_path: Path | None, runtime: dict,
                args, connection: dict) -> list[str]:
    command = [
        sys.executable, "-I", str(repo / "scripts" / "test-windows-vm.py"),
        "--ssh-host", connection["ssh_host"],
        "--expected-vm-id", connection["expected_vm_id"],
        "--desktop-mode", "rdp",
        "--desktop-helper", connection["desktop_helper"],
        "--desktop-scale", str(runtime["scale_percent"]),
        "--desktop-width", str(runtime["desktop_width"]),
        "--desktop-height", str(runtime["desktop_height"]),
        "--output", str(bundle),
        "--task-kind", runtime["kind"],
        "--acceptance-profile-id", getattr(args, "profile_id", "vm-automated-v1-win11-ntfs"),
        "--test-timeout-seconds", str(args.test_timeout_seconds),
        *candidate_arguments(args),
    ]
    if runtime["kind"] == "ui":
        require(input_path is not None, "UI task needs its frozen acceptance manifest.")
        command += [
            "--acceptance-manifest", str(input_path),
            "--acceptance-mode", runtime["mode"],
            "--acceptance-appearance", runtime["appearance"],
            "--acceptance-text-scale-percent", str(runtime["text_scale_percent"]),
        ]
        if runtime["high_contrast"]:
            command.append("--acceptance-high-contrast")
    elif runtime["kind"] == "recovery":
        command += [
            "--recovery-mode", runtime["mode"],
            "--recovery-fixture-count", str(runtime["fixture_count"]),
        ]
        if runtime["recovery_export"]:
            command.append("--recovery-export")
        if runtime["intent_discard"]:
            command.append("--recovery-intent-only-candidate-discard")
    return command


def result_references(output: Path, slot: dict, runtime: dict) -> tuple[str, str, str, str]:
    prefix = "runs/" + slot["id"] + "/bundle/"
    bundle = output / "runs" / slot["id"] / "bundle"
    if runtime["kind"] == "core":
        result = "result.json"
        transport = "transport.json"
    elif runtime["kind"] == "ui":
        result = "observer-output/acceptance-result.json"
        transport = "observer-output/transport.json"
    else:
        observer_root = bundle / "observer-output"
        inventory = freeze_tree(observer_root, require_campaign=False)
        summaries = [path for name, (path, _frozen) in inventory.items()
                     if name == "summary.json" or name.endswith("/summary.json")]
        require(len(summaries) == 1, "Recovery output must contain exactly one summary.json.")
        result = summaries[0].relative_to(bundle).as_posix()
        safe_relative(result)
        transport = "observer-output/transport.json"
    for relative in ("bundle.json", result, transport, "desktop-lease.json"):
        ordinary_file(bundle / relative, "Campaign run artifact")
    return (prefix + "bundle.json", prefix + result,
            prefix + transport, prefix + "desktop-lease.json")


def execute_attempt(repo: Path, output: Path, slot: dict, runtime: dict, args,
                    connection: dict, connection_helpers, previous_end: datetime) -> tuple[dict, datetime]:
    run_root = output / "runs" / slot["id"]
    run_root.mkdir(parents=True)
    stdout_path = run_root / "controller.stdout.txt"
    stderr_path = run_root / "controller.stderr.txt"
    started = max(utc_now(), previous_end)
    started_monotonic = time.monotonic_ns()
    code = 125
    command = None
    input_path = None
    with stdout_path.open("x", encoding="utf-8") as stdout, \
            stderr_path.open("x", encoding="utf-8") as stderr:
        try:
            if runtime["kind"] == "ui":
                guest = connection_helpers.guest_preflight(connection)
                document = acceptance_manifest(slot, runtime, args, connection, guest, repo)
                input_path = run_root / "acceptance-input.json"
                write_json(input_path, document)
            command = run_command(repo, run_root / "bundle", input_path, runtime, args, connection)
            completed = subprocess.run(command, cwd=repo, text=True, stdout=stdout, stderr=stderr,
                                       check=False)
            code = completed.returncode
        except Exception as error:
            stderr.write(type(error).__name__ + ": " + str(error) + "\n")
            code = 125
    ended = utc_now()
    if ended <= started:
        ended = started + timedelta(microseconds=1)
    elapsed_ms = max(0, (time.monotonic_ns() - started_monotonic) // 1_000_000)
    try:
        bundle_ref, result_ref, transport_ref, lease_ref = result_references(
            output, slot, runtime
        )
    except (OSError, ValueError) as error:
        if code == 0:
            code = 126
        with stderr_path.open("a", encoding="utf-8") as stderr:
            stderr.write(type(error).__name__ + ": " + str(error) + "\n")
        prefix = "runs/" + slot["id"] + "/bundle/"
        bundle_ref = prefix + "bundle.json"
        result_ref = prefix + "missing-result.json"
        transport_ref = prefix + "missing-transport.json"
        lease_ref = prefix + "desktop-lease.json"
    write_json(run_root / "execution.json", {
        "schema_version": 1,
        "started_at": timestamp(started),
        "ended_at": timestamp(ended),
        "elapsed_ms": elapsed_ms,
        "exit_code": code,
        "stdout": "controller.stdout.txt",
        "stderr": "controller.stderr.txt",
    })
    return ({
        "slot_id": slot["id"],
        "attempt": 1,
        "started_at": timestamp(started),
        "ended_at": timestamp(ended),
        "exit_code": code,
        "bundle": bundle_ref,
        "result": result_ref,
        "transport": transport_ref,
        "desktop_lease": lease_ref,
    }, ended)


def freeze_tree(root: Path, *, require_campaign: bool = True) -> dict[str, tuple[Path, dict[str, object]]]:
    root = ordinary_directory(root, "Evidence package root")
    files = {}
    aliases = set()
    entries = 0
    total = 0
    stack = [root]
    while stack:
        directory = stack.pop()
        for child in sorted(directory.iterdir(), key=lambda path: path.name):
            entries += 1
            require(entries <= MAX_ENTRIES, "Evidence package has too many entries.")
            metadata = os.lstat(child)
            relative = child.relative_to(root).as_posix()
            safe_relative(relative)
            alias = relative.casefold()
            require(alias not in aliases, "Evidence package contains a case alias.")
            aliases.add(alias)
            require(not stat.S_ISLNK(metadata.st_mode),
                    "Evidence package entries must be ordinary, not symlinks.")
            if stat.S_ISDIR(metadata.st_mode):
                stack.append(child)
                continue
            require(stat.S_ISREG(metadata.st_mode),
                    "Evidence package entries must be ordinary files or directories.")
            require(relative != "evidence-index.json",
                    "Package root must not pre-create its evidence index.")
            require(PurePosixPath(relative).name != "canonical-statement.json",
                    "Canonical statement must remain outside the raw evidence archive.")
            frozen = frozen_file(child)
            total += frozen["size"]
            require(total <= MAX_TOTAL_BYTES, "Evidence package exceeds its aggregate byte bound.")
            files[relative] = (child, frozen)
            require(len(files) < MAX_FILES, "Evidence package has too many files.")
    if require_campaign:
        require("campaign.json" in files and "plan.json" in files,
                "Evidence package must contain campaign.json and plan.json.")
    return files


def zip_info(name: str) -> ZipInfo:
    info = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = ZIP_STORED
    info.create_system = 3
    info.external_attr = 0o100600 << 16
    return info


def _archive_entry(parent_fd: int, name: str, created: os.stat_result,
                   expected_links: int) -> dict[str, object]:
    """Hash an archive member through the held parent, rejecting name replacement."""
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    flags = os.O_RDONLY | os.O_NOFOLLOW
    descriptor = os.open(name, flags, dir_fd=parent_fd)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(named.st_mode) and stat.S_ISREG(before.st_mode) and
                (named.st_dev, named.st_ino) == (created.st_dev, created.st_ino) ==
                (before.st_dev, before.st_ino) and
                named.st_uid == before.st_uid == os.geteuid() and
                stat.S_IMODE(named.st_mode) == stat.S_IMODE(before.st_mode) == 0o600 and
                named.st_nlink == before.st_nlink == expected_links,
                "Evidence archive entry changed while validating.")
        algorithm = hashlib.sha256()
        size = 0
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            size += len(block)
            require(size <= MAX_TOTAL_BYTES, "Evidence archive exceeds its total byte bound.")
            algorithm.update(block)
        after = os.fstat(descriptor)
        named_after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except BaseException as primary:
        try:
            os.close(descriptor)
        except BaseException as cleanup:
            raise RuntimeError("Evidence archive entry validation failed: " +
                               _bounded_error(primary) + "; descriptor cleanup uncertain: " +
                               _bounded_error(cleanup)) from primary
        raise
    else:
        os.close(descriptor)
    require(all((item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns,
                 item.st_uid, stat.S_IMODE(item.st_mode), item.st_nlink) ==
                (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
                 before.st_uid, stat.S_IMODE(before.st_mode), expected_links)
                for item in (after, named_after)) and size == before.st_size,
            "Evidence archive entry changed while hashing.")
    return {"device": before.st_dev, "inode": before.st_ino, "size": size,
            "mtime_ns": before.st_mtime_ns, "sha256": algorithm.hexdigest()}


def _cleanup_archive_entry(parent_fd: int, parent_path: Path,
                           parent_identity: tuple[int, int], name: str,
                           created_fd: int, created: os.stat_result, *,
                           required: bool) -> None:
    """Delete only a named entry that is still the held created inode."""
    _private_parent_state(parent_fd, parent_path, "Evidence archive parent", parent_identity)
    held = os.fstat(created_fd)
    require(stat.S_ISREG(held.st_mode) and held.st_uid == os.geteuid() and
            (held.st_dev, held.st_ino) == (created.st_dev, created.st_ino),
            "Evidence archive created descriptor changed during cleanup.")
    try:
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        if required:
            raise ValueError("Evidence archive created entry is missing during cleanup.")
        return
    if not (stat.S_ISREG(named.st_mode) and named.st_uid == os.geteuid() and
            (named.st_dev, named.st_ino) == (created.st_dev, created.st_ino)):
        if required:
            raise ValueError("Evidence archive created entry was replaced during cleanup.")
        return
    _private_parent_state(parent_fd, parent_path, "Evidence archive parent", parent_identity)
    os.unlink(name, dir_fd=parent_fd)


def _bounded_error(error: BaseException) -> str:
    return type(error).__name__ + ": " + str(error)[:400]


def package_evidence(root: Path, archive_path: Path, *,
                     profile_id: str = "vm-automated-v1-win11-ntfs") -> dict[str, object]:
    revision, _ = profile_definition(profile_id)
    root = ordinary_directory(root, "Evidence package root")
    archive_path = Path(archive_path)
    require(archive_path.is_absolute() and not archive_path.exists() and not archive_path.is_symlink(),
            "Evidence archive must be a new absolute path.")
    with private_parent(archive_path.parent, "Evidence archive parent") as (parent_fd, parent_id):
        files = freeze_tree(root)
        index = {
            "schema": f"darkrenamer-vm-automated-index-v{revision}",
            "files": {name: {"sha256": frozen["sha256"], "size": frozen["size"]}
                      for name, (_path, frozen) in sorted(files.items())},
        }
        index_bytes = (json.dumps(index, sort_keys=True, separators=(",", ":")) + "\n").encode()
        require(0 < len(index_bytes) <= MAX_INDEX_BYTES and
                sum(frozen["size"] for _path, frozen in files.values()) + len(index_bytes) <= MAX_TOTAL_BYTES,
                "Evidence index or aggregate bytes exceed their bound.")
        temporary_name = "." + archive_path.name + "." + uuid.uuid4().hex + ".tmp"
        descriptor = None
        created = None
        attempted_publication = False
        published = False
        receipt = None
        primary = None
        cleanup_errors = []
        post_cleanup_failure = False
        try:
            _private_parent_state(parent_fd, archive_path.parent,
                                  "Evidence archive parent", parent_id)
            descriptor = os.open(temporary_name, os.O_WRONLY | os.O_CREAT |
                                 os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 0o600, dir_fd=parent_fd)
            # Keep this descriptor open through cleanup, including after fdopen closes its duplicate.
            created = os.fstat(descriptor)
            require(stat.S_ISREG(created.st_mode) and created.st_uid == os.geteuid() and
                    stat.S_IMODE(created.st_mode) == 0o600 and created.st_nlink == 1,
                    "Evidence archive temporary file must be private at creation.")
            writer_fd = os.dup(descriptor)
            try:
                output = os.fdopen(writer_fd, "wb")
            except BaseException:
                try:
                    os.close(writer_fd)
                except BaseException as cleanup:
                    cleanup_errors.append(cleanup)
                raise
            with output:
                os.fchmod(output.fileno(), 0o600)
                with ZipFile(output, "w", compression=ZIP_STORED, allowZip64=False) as archive:
                    for name, (path, frozen) in sorted(files.items()):
                        archive.writestr(zip_info(name), read_frozen_file(path, frozen))
                    archive.writestr(zip_info("evidence-index.json"), index_bytes)
                written = os.fstat(output.fileno())
                require((written.st_dev, written.st_ino) == (created.st_dev, created.st_ino) and
                        stat.S_IMODE(written.st_mode) == 0o600 and written.st_nlink == 1,
                        "Evidence archive temporary file changed while writing.")
            for path, frozen in files.values():
                require(frozen_file(path) == frozen, "Evidence changed after archive creation.")
            temporary_frozen = _archive_entry(parent_fd, temporary_name, created, 1)
            _private_parent_state(parent_fd, archive_path.parent,
                                  "Evidence archive parent", parent_id)
            attempted_publication = True
            os.link(temporary_name, archive_path.name, src_dir_fd=parent_fd,
                    dst_dir_fd=parent_fd, follow_symlinks=False)
            published = True
            frozen_archive = _archive_entry(parent_fd, archive_path.name, created, 2)
            require(frozen_archive == temporary_frozen,
                    "Evidence archive changed while being published.")
            _private_parent_state(parent_fd, archive_path.parent,
                                  "Evidence archive parent", parent_id)
            receipt = {"file": str(archive_path), "sha256": frozen_archive["sha256"],
                       "size": frozen_archive["size"]}
        except BaseException as error:
            primary = error
        if descriptor is not None:
            if created is None:
                cleanup_errors.append(ValueError(
                    "Evidence archive temporary identity is unknown; entry left untouched."))
            else:
                if published and primary is not None:
                    try:
                        _cleanup_archive_entry(parent_fd, archive_path.parent, parent_id,
                                               archive_path.name, descriptor, created,
                                               required=True)
                    except BaseException as error:
                        cleanup_errors.append(error)
                elif attempted_publication and primary is not None:
                    # A failing link call gives no proof that this process created the final name.
                    try:
                        _private_parent_state(parent_fd, archive_path.parent,
                                              "Evidence archive parent", parent_id)
                        named = os.stat(archive_path.name, dir_fd=parent_fd,
                                        follow_symlinks=False)
                    except FileNotFoundError:
                        pass
                    except BaseException as error:
                        cleanup_errors.append(error)
                    else:
                        if (named.st_dev, named.st_ino) == (created.st_dev, created.st_ino):
                            cleanup_errors.append(ValueError(
                                "Evidence archive publication outcome is unknown; "
                                "final entry left untouched."))
                try:
                    _cleanup_archive_entry(parent_fd, archive_path.parent, parent_id,
                                           temporary_name, descriptor, created, required=True)
                except BaseException as error:
                    cleanup_errors.append(error)
                if published and primary is None and not cleanup_errors:
                    try:
                        _private_parent_state(parent_fd, archive_path.parent,
                                              "Evidence archive parent", parent_id)
                        after_cleanup = _archive_entry(parent_fd, archive_path.name, created, 1)
                        require(after_cleanup == temporary_frozen,
                                "Evidence archive changed after temporary cleanup.")
                        _private_parent_state(parent_fd, archive_path.parent,
                                              "Evidence archive parent", parent_id)
                    except BaseException as error:
                        primary = error
                        post_cleanup_failure = True
                if published and primary is None and cleanup_errors:
                    try:
                        _cleanup_archive_entry(parent_fd, archive_path.parent, parent_id,
                                               archive_path.name, descriptor, created,
                                               required=True)
                    except BaseException as error:
                        cleanup_errors.append(error)
                elif published and post_cleanup_failure and not cleanup_errors:
                    try:
                        _cleanup_archive_entry(parent_fd, archive_path.parent, parent_id,
                                               archive_path.name, descriptor, created,
                                               required=True)
                    except BaseException as error:
                        cleanup_errors.append(error)
            try:
                os.close(descriptor)
            except BaseException as error:
                cleanup_errors.append(error)
        if cleanup_errors:
            detail = "; ".join(_bounded_error(error) for error in cleanup_errors[:3])
            if primary is not None:
                raise RuntimeError("Evidence packaging failed: " + _bounded_error(primary) +
                                   "; cleanup uncertain: " + detail) from primary
            raise RuntimeError("Evidence archive cleanup uncertain: " + detail) from cleanup_errors[0]
        if primary is not None:
            raise primary
        require(receipt is not None, "Evidence archive receipt is unavailable.")
        return receipt


def candidate_from_args(args) -> Candidate:
    handoff = ordinary_file(
        Path(args.candidate_handoff_root) / "release-handoff.json", "Release handoff metadata"
    )
    return Candidate(
        source_sha=args.candidate_source_sha,
        workflow_run=args.candidate_workflow_run,
        run_attempt=args.candidate_run_attempt,
        artifact_id=args.candidate_artifact_id,
        executable_sha256=args.candidate_executable_sha256,
        handoff_sha256=frozen_file(handoff)["sha256"],
    )


def freeze_campaign_inputs(args) -> dict[Path, dict[str, object]]:
    paths = (
        Path(args.candidate_handoff_root) / "release-handoff.json",
        Path(args.candidate_handoff_root) / "DarkReNamer.exe",
        Path(args.candidate_run_metadata),
        Path(args.candidate_artifact_metadata),
    )
    frozen = {ordinary_file(path, "Candidate campaign input"): frozen_file(path)
              for path in paths}
    executable = Path(args.candidate_handoff_root) / "DarkReNamer.exe"
    executable = executable.resolve(strict=True)
    require(frozen[executable]["sha256"] == args.candidate_executable_sha256,
            "Candidate executable differs from its explicit digest.")
    return frozen


def execute(args, *, repo: Path, connection_loaded=None) -> int:
    """Execute one campaign while the caller holds campaign_lock for the VM."""
    repo = Path(repo)
    harness_sha = clean_source_sha(repo)
    product_sha = clean_source_sha(Path(args.candidate_source_root))
    require(product_sha == args.candidate_source_sha,
            "Candidate source checkout differs from the selected source SHA.")
    require(harness_sha == args.candidate_source_sha,
            "Campaign harness source differs from the selected candidate source SHA.")
    profile_path = ordinary_file(Path(args.profile), "VM-automated profile", MAX_INDEX_BYTES)
    profile_frozen = frozen_file(profile_path)
    profile = load_bounded_json(profile_path, max_bytes=MAX_INDEX_BYTES, label="VM-automated profile")
    revision = validate_profile(profile)
    args.profile_id = profile["profile_id"]
    _, trusted_profile_path = profile_definition(args.profile_id)
    trusted_profile_bytes = subprocess.check_output(
        ["git", "show", harness_sha + ":" + trusted_profile_path], cwd=repo)
    require(digest_bytes(trusted_profile_bytes) == profile_frozen["sha256"],
            "Selected profile differs from the same-SHA trusted source profile.")
    connection_path = ordinary_file(Path(args.connection_profile), "Private connection profile", 16 * 1024)
    connection_frozen = frozen_file(connection_path)
    load_bounded_json(connection_path, max_bytes=16 * 1024, label="Private connection profile")
    if connection_loaded is None:
        connection, connection_sha = vm_connection.load_connection_profile(connection_path)
    else:
        connection, connection_sha = connection_loaded
    require(connection_sha == connection_frozen["sha256"],
            "Connection profile loader did not bind its exact bytes.")
    candidate_inputs = freeze_campaign_inputs(args)
    candidate = candidate_from_args(args)
    requested_output = Path(args.output_root)
    archive = new_archive_path(repo, Path(args.archive), requested_output)
    output = new_external_root(repo, requested_output)
    created = utc_now()
    plan = new_plan(
        profile, profile_sha256=profile_frozen["sha256"], candidate=candidate,
        harness_sha=harness_sha, campaign_id=args.campaign_id, created_at=timestamp(created),
    )
    write_json(output / "plan.json", plan)
    backend = prepare_backend(Path(args.backend_root), output / "backend", profile,
                              harness_sha, launcher, profile_sha256=profile_frozen["sha256"])
    (output / "runs").mkdir()
    attempts = []
    previous_end = created
    for slot in plan["slots"]:
        runtime = slot_runtime(slot, profile)
        attempt, previous_end = execute_attempt(
            repo, output, slot, runtime, args, connection, vm_connection, previous_end
        )
        attempts.append(attempt)
        if attempt["exit_code"] != 0:
            break
    campaign = {
        "schema": f"darkrenamer-vm-automated-campaign-v{revision}",
        "campaign_id": args.campaign_id,
        "plan": "plan.json",
        "attempts": attempts,
        "backend": backend,
    }
    write_json(output / "campaign.json", campaign)
    valid = True
    try:
        validate_ledger(plan, campaign, profile=profile, profile_sha256=profile_frozen["sha256"],
                        candidate=candidate, harness_sha=harness_sha)
    except EvidenceError:
        valid = False
    require(frozen_file(profile_path) == profile_frozen, "Profile changed during the campaign.")
    require(frozen_file(connection_path) == connection_frozen,
            "Connection profile changed during the campaign.")
    for path, frozen in candidate_inputs.items():
        require(frozen_file(path) == frozen, "Candidate input changed during the campaign.")
    require(clean_source_sha(repo) == harness_sha, "Harness source changed during the campaign.")
    require(clean_source_sha(Path(args.candidate_source_root)) == product_sha,
            "Candidate source changed during the campaign.")
    archive_reference = package_evidence(output, archive, profile_id=args.profile_id)
    print(json.dumps({
        "status": "complete" if valid else "failed",
        "campaign_id": args.campaign_id,
        "output_root": str(output),
        "archive": archive_reference,
    }, sort_keys=True))
    return 0 if valid else 1


def argument_parser(repo: Path) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path,
                        default=Path(repo) / "config" / "vm-automated-v2.json",
                        help="Frozen campaign profile (default: v2 owned resources).")
    parser.add_argument("--connection-profile", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--backend-root", type=Path, required=True)
    parser.add_argument("--campaign-id", default="campaign-" + uuid.uuid4().hex)
    parser.add_argument("--candidate-handoff-root", type=Path, required=True)
    parser.add_argument("--candidate-source-root", type=Path, required=True)
    parser.add_argument("--candidate-run-metadata", type=Path, required=True)
    parser.add_argument("--candidate-artifact-metadata", type=Path, required=True)
    parser.add_argument("--candidate-source-sha", required=True)
    parser.add_argument("--candidate-workflow-run", required=True)
    parser.add_argument("--candidate-run-attempt", required=True)
    parser.add_argument("--candidate-artifact-id", required=True)
    parser.add_argument("--candidate-executable-sha256", required=True)
    parser.add_argument("--test-timeout-seconds", type=int, default=300)
    return parser


def parse_arguments(repo: Path, argv=None):
    args = argument_parser(repo).parse_args(argv)
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,95}", args.campaign_id) is not None,
            "Campaign identifier is not a bounded token.")
    require(10 <= args.test_timeout_seconds <= 600,
            "Campaign observer timeout must be between 10 and 600 seconds.")
    Candidate(
        args.candidate_source_sha, args.candidate_workflow_run, args.candidate_run_attempt,
        args.candidate_artifact_id, args.candidate_executable_sha256, "0" * 64,
    )
    return args


def main(repo: Path, argv=None) -> int:
    repo = Path(repo)
    args = parse_arguments(repo, argv)
    connection = vm_connection.load_connection_profile(Path(args.connection_profile))
    with campaign_lock(connection[0]["expected_vm_id"]):
        return execute(args, repo=repo, connection_loaded=connection)


def cli(repo: Path, argv=None, tooling=None) -> int:
    del tooling
    try:
        return main(repo, argv)
    except (EvidenceError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
