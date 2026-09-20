#!/usr/bin/env python3
"""Run and package the fixed VM-automated v1 campaign through the common VM CLI."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import importlib.util
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

from vm_automated_binding import Candidate
from vm_automated_campaign import new_plan, validate_ledger
from vm_automated_evidence import EvidenceError, load_bounded_json


MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_FILES = 1024
MAX_ENTRIES = 2048
MAX_INDEX_BYTES = 1024 * 1024
SAFE_SEGMENT = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
WINDOWS_RESERVED = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}


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


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, "Required campaign module is unavailable.")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_common_modules(repo: Path):
    return (
        load_module(repo / "scripts" / "test-windows-vm.py", "darkrenamer_common_vm_runner"),
        load_module(repo / "scripts" / "run-gui-regression.py", "darkrenamer_gui_preflight"),
    )


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
    parent = ordinary_directory(requested.parent, "Campaign output parent")
    target = parent / safe_segment(requested.name)
    resolved_repo = repo.resolve(strict=True)
    require(not target.is_relative_to(resolved_repo) and not resolved_repo.is_relative_to(target),
            "Campaign output root must be external to the checkout.")
    target.mkdir(mode=0o700)
    return target


def new_archive_path(repo: Path, requested: Path, output: Path) -> Path:
    requested = Path(requested)
    require(requested.is_absolute() and requested.suffix.lower() == ".zip",
            "Campaign archive must be an absolute ZIP path.")
    require(not requested.exists() and not requested.is_symlink(), "Campaign archive must be new.")
    parent = ordinary_directory(requested.parent, "Campaign archive parent")
    target = parent / safe_segment(requested.name)
    require(not target.is_relative_to(repo.resolve(strict=True)) and
            not repo.resolve(strict=True).is_relative_to(target) and
            not target.is_relative_to(output),
            "Campaign archive must remain outside the checkout and package root.")
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
    for row in result["tests"]:
        require(type(row) is dict, "Backend test row is invalid.")
        binary = safe_segment(row.get("file"))
        require(binary.endswith(".exe"), "Backend test artifact is not an executable leaf.")
        names.append(binary)
        for channel in ("stdout", "stderr"):
            reference = row.get(channel)
            require(type(reference) is dict and set(reference) == {"file", "sha256"},
                    "Backend test output reference is invalid.")
            name = safe_segment(reference["file"])
            require(re.fullmatch(r"[0-9a-f]{64}", reference["sha256"]) is not None,
                    "Backend test output digest is invalid.")
            names.append(name)
    require(len(names) == len(set(name.casefold() for name in names)),
            "Backend test output names collide.")
    return names


def prepare_backend(source: Path, destination: Path, profile: dict,
                    harness_sha: str, native_runner) -> dict:
    source = ordinary_directory(source, "Backend evidence root")
    # Native PowerShell records may contain one UTF-8 BOM. Freeze their exact
    # bytes before parsing and independently derive required test functions
    # from each binary's complete stdout transcript.
    from vm_automated_evidence import ExtractedEvidence, FileReference
    from vm_automated_verifier import EvidenceReader, verify_backend_execution
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
                             required_tests=profile["required_backend_test_names"])
    require(transport.get("guest_cleanup") is True, "Backend controller cleanup did not finish.")
    require(native_runner.verify_result(source, manifest, result),
            "Backend native runner result did not pass its existing validator.")
    destination.mkdir()
    selected = ["bundle.json", "result.json", "transport.json", *backend_files(result)]
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
        sys.executable, str(repo / "scripts" / "test-windows-vm.py"),
        "--ssh-host", connection["ssh_host"],
        "--expected-vm-id", connection["expected_vm_id"],
        "--desktop-mode", "rdp",
        "--desktop-helper", connection["desktop_helper"],
        "--desktop-scale", str(runtime["scale_percent"]),
        "--desktop-width", str(runtime["desktop_width"]),
        "--desktop-height", str(runtime["desktop_height"]),
        "--output", str(bundle),
        "--task-kind", runtime["kind"],
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
                    connection: dict, gui_runner, previous_end: datetime) -> tuple[dict, datetime]:
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
                guest = gui_runner.guest_preflight(connection)
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


def package_evidence(root: Path, archive_path: Path) -> dict[str, object]:
    root = ordinary_directory(root, "Evidence package root")
    archive_path = Path(archive_path)
    require(archive_path.is_absolute() and not archive_path.exists() and not archive_path.is_symlink(),
            "Evidence archive must be a new absolute path.")
    ordinary_directory(archive_path.parent, "Evidence archive parent")
    files = freeze_tree(root)
    index = {
        "schema": "darkrenamer-vm-automated-index-v1",
        "files": {name: {"sha256": frozen["sha256"], "size": frozen["size"]}
                  for name, (_path, frozen) in sorted(files.items())},
    }
    index_bytes = (json.dumps(index, sort_keys=True, separators=(",", ":")) + "\n").encode()
    require(0 < len(index_bytes) <= MAX_INDEX_BYTES and
            sum(frozen["size"] for _path, frozen in files.values()) + len(index_bytes) <= MAX_TOTAL_BYTES,
            "Evidence index or aggregate bytes exceed their bound.")
    temporary = archive_path.parent / ("." + archive_path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with ZipFile(temporary, "x", compression=ZIP_STORED, allowZip64=False) as archive:
            for name, (path, frozen) in sorted(files.items()):
                archive.writestr(zip_info(name), read_frozen_file(path, frozen))
            archive.writestr(zip_info("evidence-index.json"), index_bytes)
        for path, frozen in files.values():
            require(frozen_file(path) == frozen, "Evidence changed after archive creation.")
        temporary_frozen = frozen_file(temporary, MAX_TOTAL_BYTES)
        require(temporary_frozen["size"] <= MAX_TOTAL_BYTES,
                "Evidence archive exceeds its total byte bound.")
        os.link(temporary, archive_path)
    finally:
        temporary.unlink(missing_ok=True)
    frozen_archive = frozen_file(archive_path, MAX_TOTAL_BYTES)
    require(frozen_archive == temporary_frozen,
            "Evidence archive changed while being published.")
    return {"file": str(archive_path), "sha256": frozen_archive["sha256"],
            "size": frozen_archive["size"]}


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


def execute(args, *, connection_loaded=None) -> int:
    """Execute one campaign while the caller holds campaign_lock for the VM."""
    repo = Path(__file__).resolve().parent.parent
    native_runner, gui_runner = load_common_modules(repo)
    harness_sha = clean_source_sha(repo)
    product_sha = clean_source_sha(Path(args.candidate_source_root))
    require(product_sha == args.candidate_source_sha,
            "Candidate source checkout differs from the selected source SHA.")
    require(harness_sha == args.candidate_source_sha,
            "Campaign harness source differs from the selected candidate source SHA.")
    profile_path = ordinary_file(Path(args.profile), "VM-automated profile", MAX_INDEX_BYTES)
    profile_frozen = frozen_file(profile_path)
    profile = load_bounded_json(profile_path, max_bytes=MAX_INDEX_BYTES, label="VM-automated profile")
    require(type(profile) is dict and profile.get("schema") == "darkrenamer-vm-automated-profile-v1",
            "VM-automated profile schema is invalid.")
    connection_path = ordinary_file(Path(args.connection_profile), "Private connection profile", 16 * 1024)
    connection_frozen = frozen_file(connection_path)
    load_bounded_json(connection_path, max_bytes=16 * 1024, label="Private connection profile")
    if connection_loaded is None:
        connection, connection_sha = gui_runner.load_connection_profile(connection_path)
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
                              harness_sha, native_runner)
    (output / "runs").mkdir()
    attempts = []
    previous_end = created
    for slot in plan["slots"]:
        runtime = slot_runtime(slot, profile)
        attempt, previous_end = execute_attempt(
            repo, output, slot, runtime, args, connection, gui_runner, previous_end
        )
        attempts.append(attempt)
        if attempt["exit_code"] != 0:
            break
    campaign = {
        "schema": "darkrenamer-vm-automated-campaign-v1",
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
    archive_reference = package_evidence(output, archive)
    print(json.dumps({
        "status": "complete" if valid else "failed",
        "campaign_id": args.campaign_id,
        "output_root": str(output),
        "archive": archive_reference,
    }, sort_keys=True))
    return 0 if valid else 1


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path,
                        default=Path(__file__).resolve().parent.parent / "config" / "vm-automated-v1.json")
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


def parse_arguments(argv=None):
    args = argument_parser().parse_args(argv)
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,95}", args.campaign_id) is not None,
            "Campaign identifier is not a bounded token.")
    require(10 <= args.test_timeout_seconds <= 600,
            "Campaign observer timeout must be between 10 and 600 seconds.")
    Candidate(
        args.candidate_source_sha, args.candidate_workflow_run, args.candidate_run_attempt,
        args.candidate_artifact_id, args.candidate_executable_sha256, "0" * 64,
    )
    return args


def main(argv=None) -> int:
    args = parse_arguments(argv)
    repo = Path(__file__).resolve().parent.parent
    _native, gui_runner = load_common_modules(repo)
    connection = gui_runner.load_connection_profile(Path(args.connection_profile))
    with campaign_lock(connection[0]["expected_vm_id"]):
        return execute(args, connection_loaded=connection)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (EvidenceError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
