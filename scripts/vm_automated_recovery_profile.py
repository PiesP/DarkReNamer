"""Derive the five recovery profile targets from private raw observations.

This module consumes transport-authenticated files through a narrow reader
protocol.  Producer status strings, classifications, counts and pass booleans
never authorize a target.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import PurePosixPath
import re
from typing import Protocol

from vm_automated_binding import verify_result_binding
from vm_automated_campaign import verify_process_lifecycle
from vm_automated_evidence import EvidenceError, require_exact_keys, require_int
from vm_automated_platform import require_fixture_root, verify_cleanup, verify_environment
from vm_automated_recovery import (
    verify_crash_prefix,
    verify_intent_candidate,
    verify_recovery_export,
    verify_recovery_invariance,
)
from vm_automated_state import Identity, clean_journal_inventory, fixture_inventory, restored_inventory


MAX_MEMBER_BYTES = 64 * 1024 * 1024
MAX_PRIVATE_BYTES = 512 * 1024 * 1024
MAX_PRIVATE_FILES = 240
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
DECIMAL_TICKS = re.compile(r"[1-9][0-9]{0,18}\Z")
SAFE_SEGMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
RECOVERY_TARGETS = {
    "process-crash", "recovery-export", "intent-only-discard",
    "worker-cancellation", "worker-close",
}


class EvidenceReader(Protocol):
    def json(self, path: str) -> object: ...
    def bytes(self, path: str, maximum: int = MAX_MEMBER_BYTES) -> bytes: ...
    def digest_reference(self, reference: object, *, prefix: str) -> str: ...


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def _mapping(value: object, label: str) -> dict:
    require(type(value) is dict, label + " must be an object.")
    return value


def _required_keys(value: object, keys: set[str], label: str) -> dict:
    row = _mapping(value, label)
    require(keys <= set(row), label + " is missing required fields.")
    return row


def _sha(value: object, label: str) -> str:
    require(type(value) is str and HEX64.fullmatch(value) is not None,
            label + " must be lowercase SHA-256.")
    return value


def _ticks(value: object, label: str) -> int:
    require(type(value) is str and DECIMAL_TICKS.fullmatch(value) is not None,
            label + " must be canonical decimal UTC ticks.")
    ticks = int(value)
    require(ticks <= 3_155_378_975_999_999_999, label + " exceeds the supported time range.")
    return ticks


def _safe_relative(value: object) -> str:
    require(type(value) is str and 0 < len(value) <= 512 and "\\" not in value,
            "Private index path is invalid.")
    parts = value.split("/")
    require(1 <= len(parts) <= 8 and all(SAFE_SEGMENT.fullmatch(part) for part in parts),
            "Private index path is not a bounded ordinary relative path.")
    require(all(part not in {".", ".."} for part in parts), "Private index path traverses its root.")
    return value


class PrivateEvidence:
    """Validate the producer index, resolve fixed raw files, and track all use."""

    def __init__(self, reader: EvidenceReader, result: dict, run_prefix: str):
        require(type(run_prefix) is str and 1 < len(run_prefix) <= 512 and
                run_prefix.endswith("/") and not run_prefix.endswith("//") and
                PurePosixPath(run_prefix).as_posix() == run_prefix.rstrip("/") and
                1 <= len(PurePosixPath(run_prefix).parts) <= 8 and
                all(SAFE_SEGMENT.fullmatch(part) for part in PurePosixPath(run_prefix).parts),
                "Recovery run prefix is not one canonical archive directory.")
        self.reader = reader
        self.run_prefix = run_prefix
        public = require_exact_keys(result.get("private_evidence"),
                                    {"bytes", "sha256", "file_count"}, "Private evidence reference")
        size = require_int(public["bytes"], 1, MAX_MEMBER_BYTES, "Private index bytes")
        digest = _sha(public["sha256"], "Private index digest")
        count = require_int(public["file_count"], 1, MAX_PRIVATE_FILES, "Private index file count")
        reference = {"bytes": size, "sha256": digest, "boundary": "private-index"}
        index_path = reader.digest_reference(reference, prefix=run_prefix)
        relative_index = index_path[len(run_prefix):] if index_path.startswith(run_prefix) else ""
        index_parts = relative_index.split("/")
        require(len(index_parts) == 3 and index_parts[0] == "private" and
                SAFE_SEGMENT.fullmatch(index_parts[1]) is not None and
                index_parts[2] == "private-index.json",
                "Private index reference resolves outside the recovery raw directory.")
        index = require_exact_keys(reader.json(index_path),
                                   {"schema_version", "classification", "files"}, "Private evidence index")
        require_int(index["schema_version"], 1, 1, "Private index schema")
        require(index["classification"] == "private-path-bearing-raw-recovery-evidence",
                "Private index classification differs from the recovery contract.")
        rows = index["files"]
        require(type(rows) is list and len(rows) == count, "Private index file count differs from its reference.")
        self.root = str(PurePosixPath(index_path).parent)
        self.rows: dict[str, tuple[int, str]] = {}
        folded: set[str] = set()
        total = 0
        for raw in rows:
            row = require_exact_keys(raw, {"file", "bytes", "sha256"}, "Private index row")
            relative = _safe_relative(row["file"])
            require(relative.casefold() not in folded, "Private index repeats or aliases a path.")
            item_size = require_int(row["bytes"], 0, MAX_MEMBER_BYTES, "Private member bytes")
            item_digest = _sha(row["sha256"], "Private member digest")
            path = self.root + "/" + relative
            data = reader.bytes(path, MAX_MEMBER_BYTES)
            require(len(data) == item_size and hashlib.sha256(data).hexdigest() == item_digest,
                    "Collected private member differs from the producer index.")
            folded.add(relative.casefold())
            self.rows[relative] = (item_size, item_digest)
            total += item_size
            require(total <= MAX_PRIVATE_BYTES, "Private evidence exceeds its aggregate bound.")
        self.used: set[str] = set()

    def _reference(self, reference: object) -> tuple[dict, str]:
        row = require_exact_keys(reference, {"bytes", "sha256", "boundary"}, "Private recovery reference")
        size = require_int(row["bytes"], 0, MAX_MEMBER_BYTES, "Private reference bytes")
        digest = _sha(row["sha256"], "Private reference digest")
        require(type(row["boundary"]) is str and
                re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", row["boundary"]) is not None,
                "Private reference boundary is invalid.")
        # The shared reader independently enforces membership in this run.
        self.reader.digest_reference(row, prefix=self.run_prefix)
        return row, digest

    def path(self, reference: object, relative: str, *, boundary: str) -> str:
        row, digest = self._reference(reference)
        require(row["boundary"] == boundary, "Private reference has the wrong semantic boundary.")
        relative = _safe_relative(relative)
        require(relative in self.rows and self.rows[relative] == (row["bytes"], digest),
                "Private reference differs from its fixed indexed member.")
        self.used.add(relative)
        return self.root + "/" + relative

    def any_path(self, reference: object, *, boundary: str, prefix: str) -> str:
        row, digest = self._reference(reference)
        require(row["boundary"] == boundary, "Private reference has the wrong semantic boundary.")
        matches = [relative for relative, pin in self.rows.items()
                   if relative.startswith(prefix) and pin == (row["bytes"], digest)]
        require(len(matches) == 1, "Private reference is ambiguous within its fixed boundary directory.")
        self.used.add(matches[0])
        return self.root + "/" + matches[0]

    def raw(self, reference: object, relative: str, *, boundary: str) -> bytes:
        return self.reader.bytes(self.path(reference, relative, boundary=boundary), MAX_MEMBER_BYTES)

    def json(self, reference: object, relative: str, *, boundary: str) -> object:
        return self.reader.json(self.path(reference, relative, boundary=boundary))

    def finish(self) -> None:
        require(self.used == set(self.rows),
                "Private recovery index contains missing, extra, or semantically unused evidence.")


@dataclass(frozen=True)
class State:
    fixture_root: str
    root_identity: Identity
    entries: list
    inventory: dict


@dataclass(frozen=True)
class Process:
    sequence: int
    role: str
    pid: int
    session: int
    start_ticks: int
    start_observed: int
    exit_observed: int
    environment: dict


def _state(private: PrivateEvidence, reference: object, relative: str, boundary: str) -> State:
    raw = require_exact_keys(private.json(reference, relative, boundary=boundary),
                             {"schema_version", "boundary", "fixture_root", "root_identity",
                              "fixture_entries"}, "Recovery state")
    require_int(raw["schema_version"], 1, 1, "Recovery state schema")
    require(raw["boundary"] == boundary, "Recovery state boundary differs from its reference.")
    root = require_fixture_root(raw["fixture_root"])
    identity = Identity.parse(raw["root_identity"])
    entries = raw["fixture_entries"]
    inventory = fixture_inventory(entries, full_identity=True)
    require(all(item.identity.volume == identity.volume for item in inventory.values()),
            "Recovery fixture file is on another observed volume.")
    return State(root, identity, entries, inventory)


def _same_root(states: list[State], processes: list[Process]) -> tuple[str, Identity]:
    require(bool(states) and bool(processes), "Recovery root binding is incomplete.")
    root, identity = states[0].fixture_root, states[0].root_identity
    require(all(state.fixture_root == root and state.root_identity == identity for state in states),
            "Recovery state snapshots belong to different fixture roots.")
    for process in processes:
        volume = process.environment["fixture_volume"]
        require(volume["root_path"] == root and Identity.parse(volume["root_identity"]) == identity,
                "Recovery process environment belongs to another fixture root.")
    return root, identity


def _profile_initial(state: State) -> None:
    expected = {f"item-{index:05}.txt" for index in range(4096)} | {"sentinel.bin"}
    require(set(state.inventory) == expected, "Recovery initial inventory differs from 4096 files plus sentinel.")


def _binding(value: object, expected_sequence: int, expected_role: str,
             executable_sha256: str) -> dict:
    row = require_exact_keys(value, {"sequence", "role", "pid", "session_id", "start_time_utc_ticks",
                                     "executable_path", "executable_sha256"}, "Recovery process binding")
    require_int(row["sequence"], expected_sequence, expected_sequence, "Recovery process sequence")
    require(row["role"] == expected_role, "Recovery process has the wrong lifecycle role.")
    require_int(row["pid"], 1, 0xFFFFFFFF, "Recovery process PID")
    require_int(row["session_id"], 1, 0xFFFFFFFF, "Recovery process session")
    _ticks(row["start_time_utc_ticks"], "Process creation")
    require_fixture_root(row["executable_path"])
    require(row["executable_path"].endswith("\\DarkReNamer.exe") and
            row["executable_sha256"] == executable_sha256,
            "Recovery process differs from the exact candidate executable.")
    return row


def _start_lifecycle(value: object, binding: dict) -> None:
    row = require_exact_keys(value, {"pid", "session_id", "start_time_utc_ticks", "executable_path",
                                     "executable_sha256", "start_observed", "exit_observed",
                                     "exit_method", "exit_code"}, "Recovery process start lifecycle")
    for field in ("pid", "session_id", "start_time_utc_ticks", "executable_path", "executable_sha256"):
        require(row[field] == binding[field], "Process start lifecycle differs from its immutable binding.")
    require(row["start_observed"] is True and row["exit_observed"] is False and
            row["exit_method"] is None and row["exit_code"] is None,
            "Process start lifecycle falsely asserts an exit.")


def _processes(private: PrivateEvidence, references: object, *, roles: list[str], methods: list[str],
               executable_sha256: str, target: dict, first_sequence: int) -> list[Process]:
    require(type(references) is list and len(references) == len(roles) * 2,
            "Recovery process references are incomplete or contain extras.")
    result = []
    for offset, (role, method) in enumerate(zip(roles, methods, strict=True)):
        sequence = first_sequence + offset
        start_relative = f"process-{sequence:02d}-started.json"
        exit_boundary = "crash-stop" if method == "forced-termination" else "normal-exit"
        exit_relative = f"process-{sequence:02d}-{exit_boundary}.json"
        start = require_exact_keys(private.json(references[offset * 2], start_relative, boundary="started"),
                                   {"schema_version", "boundary", "observed_utc_ticks", "binding",
                                    "lifecycle", "environment"}, "Recovery process start")
        require_int(start["schema_version"], 1, 1, "Process start schema")
        require(start["boundary"] == "started", "Process start boundary differs.")
        binding = _binding(start["binding"], sequence, role, executable_sha256)
        _start_lifecycle(start["lifecycle"], binding)
        start_observed = _ticks(start["observed_utc_ticks"], "Process start observation")
        creation = _ticks(binding["start_time_utc_ticks"], "Process creation")
        require(creation <= start_observed, "Process was observed before its creation time.")
        if result:
            require(result[-1].exit_observed <= start_observed,
                    "Recovery process observations overlap or are out of sequence.")
        environment = require_exact_keys(start["environment"],
                                         {"schema_version", "platform", "process", "desktop",
                                          "fixture_volume", "target_display"}, "Recovery environment")
        verify_environment(environment, target, candidate_pid=binding["pid"], session_id=binding["session_id"])
        exit_row = require_exact_keys(private.json(references[offset * 2 + 1], exit_relative,
                                                    boundary=exit_boundary),
                                      {"schema_version", "boundary", "observed_utc_ticks", "binding",
                                       "lifecycle"}, "Recovery process exit")
        require_int(exit_row["schema_version"], 1, 1, "Process exit schema")
        require(exit_row["boundary"] == exit_boundary and exit_row["binding"] == binding,
                "Process exit differs from its paired immutable start binding.")
        pid, session = verify_process_lifecycle(exit_row["lifecycle"],
                                                executable_sha256=executable_sha256,
                                                expected_exit_method=method)
        require((pid, session) == (binding["pid"], binding["session_id"]),
                "Process exit lifecycle belongs to another process.")
        exit_observed = _ticks(exit_row["observed_utc_ticks"], "Process exit observation")
        require(start_observed <= exit_observed, "Process exit was observed before its start observation.")
        result.append(Process(sequence, role, pid, session, creation, start_observed,
                              exit_observed, environment))
    return result


def _journal_rows(private: PrivateEvidence, reference: object, relative: str, boundary: str) -> list[dict]:
    raw = require_exact_keys(private.json(reference, relative, boundary=boundary),
                             {"schema_version", "boundary", "journal_entries"}, "Journal inventory")
    require_int(raw["schema_version"], 1, 1, "Journal inventory schema")
    require(raw["boundary"] == boundary, "Journal inventory boundary differs from its reference.")
    rows = raw["journal_entries"]
    require(type(rows) is list and len(rows) <= 3, "Journal inventory is unbounded.")
    result, seen = [], set()
    for value in rows:
        row = require_exact_keys(value, {"name", "kind", "bytes", "sha256"}, "Journal inventory row")
        require(row["name"] in {"active.drj", "candidate.drj", "runtime.lock"} and
                row["name"] not in seen and row["kind"] == "file",
                "Journal inventory contains an unknown, duplicate, or non-file entry.")
        require_int(row["bytes"], 0, MAX_MEMBER_BYTES, "Journal entry bytes")
        _sha(row["sha256"], "Journal entry digest")
        seen.add(row["name"])
        result.append(row)
    return result


def _journal_inventory(private: PrivateEvidence, reference: object, relative: str, boundary: str,
                       expected_name: str | None, expected: bytes | None) -> None:
    rows = _journal_rows(private, reference, relative, boundary)
    lock = [row for row in rows if row["name"] == "runtime.lock"]
    require(len(lock) <= 1 and all(row["bytes"] == 0 and
                                   row["sha256"] == hashlib.sha256(b"").hexdigest() for row in lock),
            "Journal runtime lock is not the observed zero-byte ordinary file.")
    data = [row for row in rows if row["name"] != "runtime.lock"]
    if expected_name is None:
        clean_journal_inventory([{key: row[key] for key in ("name", "kind", "bytes")} for row in rows])
        return
    require(expected is not None and len(data) == 1 and data[0]["name"] == expected_name and
            data[0]["bytes"] == len(expected) and
            data[0]["sha256"] == hashlib.sha256(expected).hexdigest(),
            "Journal inventory differs from the exact captured bytes.")


def _control(value: object, *, pid: int, session: int, automation_id: str, control_id: int) -> dict:
    row = require_exact_keys(value, {"pid", "session_id", "hwnd", "root_hwnd", "class", "control_id",
                                     "automation_id", "control_type", "enabled", "visible", "focused"},
                             "Recovery control observation")
    require_int(row["pid"], pid, pid, "Recovery control PID")
    require_int(row["session_id"], session, session, "Recovery control session")
    require_int(row["hwnd"], 1, (1 << 63) - 1, "Recovery control HWND")
    require_int(row["root_hwnd"], 1, (1 << 63) - 1, "Recovery control root HWND")
    require_int(row["control_id"], control_id, control_id, "Recovery native control ID")
    require(row["automation_id"] == automation_id and row["class"] == "Button" and
            row["control_type"] == "ControlType.Button" and
            type(row["enabled"]) is bool and type(row["visible"]) is bool and
            type(row["focused"]) is bool,
            "Recovery control identity or state is unavailable.")
    return row


def _action(private: PrivateEvidence, reference: object, relative: str, *, boundary: str,
            phase: str, action: str, process: Process, automation_id: str, control_id: int) -> tuple[int, int]:
    raw = require_exact_keys(private.json(reference, relative, boundary=boundary),
                             {"schema_version", "boundary", "phase", "action", "dispatch_method", "target",
                              "observed_utc_ticks", "completed_utc_ticks"}, "Recovery action")
    require_int(raw["schema_version"], 1, 1, "Recovery action schema")
    require(raw["boundary"] == boundary and raw["phase"] == phase and raw["action"] == action and
            raw["dispatch_method"] == "uia-invoke", "Recovery action differs from its fixed contract.")
    target = _control(raw["target"], pid=process.pid, session=process.session,
                      automation_id=automation_id, control_id=control_id)
    require(target["enabled"] is True and target["visible"] is True,
            "Recovery action target was not enabled and visible.")
    observed = _ticks(raw["observed_utc_ticks"], "Recovery action observation")
    completed = _ticks(raw["completed_utc_ticks"], "Recovery action completion")
    require(process.start_observed <= observed <= completed <= process.exit_observed,
            "Recovery action falls outside its exact process lifetime.")
    return observed, completed


def _lock_state(private: PrivateEvidence, reference: object, relative: str, *, boundary: str,
                phase: str, process: Process, locked: bool) -> int:
    raw = require_exact_keys(private.json(reference, relative, boundary=boundary),
                             {"schema_version", "boundary", "phase", "process", "controls",
                              "observed_utc_ticks"}, "Recovery lock state")
    require_int(raw["schema_version"], 1, 1, "Recovery lock schema")
    require(raw["boundary"] == boundary and raw["phase"] == phase,
            "Recovery lock phase differs from its fixed contract.")
    owner = require_exact_keys(raw["process"], {"pid", "session_id"}, "Recovery lock process")
    require_int(owner["pid"], process.pid, process.pid, "Recovery lock PID")
    require_int(owner["session_id"], process.session, process.session, "Recovery lock session")
    controls = require_exact_keys(raw["controls"], {"apply", "add_files"}, "Recovery lock controls")
    apply = _control(controls["apply"], pid=process.pid, session=process.session,
                     automation_id="32771", control_id=32771)
    add = _control(controls["add_files"], pid=process.pid, session=process.session,
                   automation_id="32791", control_id=32791)
    require(apply["root_hwnd"] == add["root_hwnd"] ==
            process.environment["target_display"]["hwnd"],
            "Recovery lock controls are not rooted in the bound candidate workbench.")
    if locked:
        require(apply["enabled"] is False and add["enabled"] is False and add["visible"] is False,
                "Recovery lock did not disable Apply and hide Add Files.")
    else:
        require(add["enabled"] is True and add["visible"] is True,
                "Explicit discard did not restore Add Files availability.")
    observed = _ticks(raw["observed_utc_ticks"], "Recovery lock observation")
    require(process.start_observed <= observed <= process.exit_observed,
            "Recovery lock observation falls outside its process lifetime.")
    return observed


def _foreground(private: PrivateEvidence, reference: object, *, process: Process,
                expected_label: str) -> None:
    raw = require_exact_keys(private.json(reference, "foreground-observations.json",
                                          boundary="screenshot-foreground-observations"),
                             {"schema_version", "observations"}, "Recovery foreground evidence")
    require_int(raw["schema_version"], 1, 1, "Foreground schema")
    observations = raw["observations"]
    require(type(observations) is list and len(observations) == 1,
            "Recovery mode must have one completed foreground capture observation.")
    row = require_exact_keys(observations[0], {"label", "target_hwnd", "initial", "uia_set_focus",
                                               "set_foreground_window", "final", "capture_change",
                                               "capture_complete"}, "Recovery foreground observation")
    require(row["label"] == expected_label and
            row["capture_change"] is None, "Recovery screenshot lacks exact foreground completion.")
    require_int(row["target_hwnd"], process.environment["target_display"]["hwnd"],
                process.environment["target_display"]["hwnd"], "Foreground target HWND")
    final = require_exact_keys(row["final"], {"hwnd", "process_id", "session_id", "window_class"},
                               "Final foreground window")
    require_int(final["hwnd"], row["target_hwnd"], row["target_hwnd"], "Final foreground HWND")
    require_int(final["process_id"], process.pid, process.pid, "Final foreground PID")
    require_int(final["session_id"], process.session, process.session, "Final foreground session")
    require(type(final["window_class"]) is str and 0 < len(final["window_class"]) <= 128,
            "Final foreground window class is unavailable.")
    complete = require_exact_keys(row["capture_complete"],
                                  {"hwnd", "process_id", "session_id", "window_class"},
                                  "Completed foreground capture")
    require(complete == final, "Foreground ownership changed during screenshot capture.")


def _worker(private: PrivateEvidence, result: dict, bundle: dict, target: dict, *, close: bool) -> set[str]:
    key = "worker_close" if close else "worker_cancellation"
    mode = _required_keys(result.get(key),
                          {"processes", "raw_states", "partial_witness", "journal_inventory",
                           "foreground_observations"}, "Worker recovery result")
    method = "worker-close" if close else "normal-close"
    process = _processes(private, mode["processes"], roles=["rename-worker"], methods=[method],
                         executable_sha256=bundle["product"]["application"]["sha256"],
                         target=target, first_sequence=1)[0]
    state_name = "workerclose" if close else "workercancellation"
    states = require_exact_keys(mode.get("raw_states"), {"initial", "restored"},
                                "Worker state references")
    initial = _state(private, states["initial"], "state-initial.json", "initial")
    restored = _state(private, states["restored"],
                      f"state-{state_name}-restored.json", f"{state_name}-restored-normal-exit")
    _profile_initial(initial)
    _same_root([initial, restored], [process])
    restored_inventory(initial.entries, restored.entries, expected_count=4097)
    witness = require_exact_keys(private.json(mode["partial_witness"],
                                              f"worker-{state_name}-partial-witness.json",
                                              boundary="worker-partial"),
                                 {"schema_version", "boundary", "candidate_pid", "candidate_session_id",
                                  "fixture_root", "root_identity", "entries"}, "Worker partial witness")
    require_int(witness["schema_version"], 1, 1, "Worker witness schema")
    require(witness["boundary"] == "worker-partial" and witness["fixture_root"] == initial.fixture_root and
            Identity.parse(witness["root_identity"]) == initial.root_identity,
            "Worker witness belongs to another fixture root.")
    require_int(witness["candidate_pid"], process.pid, process.pid, "Worker witness PID")
    require_int(witness["candidate_session_id"], process.session, process.session, "Worker witness session")
    entries = witness["entries"]
    require(type(entries) is list and len(entries) == 2, "Worker partial witness must contain two files.")
    expected = {"first-destination": ("vm-recovered-item-00000.txt", "item-00000.txt"),
                "last-original": ("item-04095.txt", "item-04095.txt")}
    seen = set()
    for value in entries:
        row = require_exact_keys(value, {"role", "name", "kind", "bytes", "content_sha256",
                                         "file_identity", "observed_utc_ticks"}, "Worker witness row")
        require(row["role"] in expected and row["role"] not in seen, "Worker witness role is invalid or repeated.")
        actual_name, initial_name = expected[row["role"]]
        before = initial.inventory[initial_name]
        require(row["name"] == actual_name and row["kind"] == "file" and
                require_int(row["bytes"], 0, MAX_MEMBER_BYTES, "Worker witness bytes") == before.size and
                _sha(row["content_sha256"], "Worker witness digest") == before.content_sha256 and
                Identity.parse(row["file_identity"]) == before.identity,
                "Worker partial witness does not join to the scheduled initial file.")
        observed = _ticks(row["observed_utc_ticks"], "Worker witness observation")
        require(process.start_observed <= observed <= process.exit_observed,
                "Worker partial witness falls outside the candidate lifetime.")
        seen.add(row["role"])
    _journal_inventory(private, mode["journal_inventory"],
                       f"journal-{state_name}-post-rollback.json",
                       f"{state_name}-post-rollback-normal-exit", None, None)
    if close:
        require(mode.get("foreground_observations") is None,
                "Worker-close unexpectedly substitutes screenshot metadata for its close lifecycle.")
        return {"worker-close"}
    actions = require_exact_keys(mode.get("actions"), {"worker_cancel"}, "Worker cancellation actions")
    _action(private, actions["worker_cancel"], "worker-cancellation-action.json",
            boundary="worker-cancellation-action", phase="worker-cancellation",
            action="cancel-active-worker", process=process, automation_id="1009", control_id=1009)
    _foreground(private, mode["foreground_observations"], process=process,
                expected_label="worker cancellation restored state")
    return {"worker-cancellation"}


def _process_crash(private: PrivateEvidence, result: dict, bundle: dict, target: dict) -> set[str]:
    mode = _required_keys(result.get("process_crash"),
                          {"processes", "raw_states", "journal", "journal_inventories", "actions",
                           "foreground_observations"}, "Process-crash result")
    processes = _processes(private, mode["processes"],
                           roles=["rename-worker", "startup-default-cancel", "recovery-relaunch",
                                  "recovery-after-export"],
                           methods=["forced-termination", "normal-close", "normal-close", "normal-close"],
                           executable_sha256=bundle["product"]["application"]["sha256"],
                           target=target, first_sequence=1)
    states = mode.get("raw_states")
    specs = {
        "initial": ("state-initial.json", "initial"),
        "crash_partial": ("state-crash-partial.json", "crash-partial"),
        "startup_before_default_cancel": ("state-startup-before-cancel.json", "startup-before-default-cancel"),
        "default_cancel": ("state-default-cancel.json", "default-cancel"),
        "relaunch": ("state-relaunch.json", "recovery-relaunch"),
        "after_export": ("state-after-export.json", "recovery-after-export"),
        "export_relaunch": ("state-export-relaunch.json", "recovery-export-relaunch"),
        "restored": ("state-restored.json", "recovered"),
    }
    require(type(states) is dict and set(states) == set(specs), "Crash state references are incomplete or extra.")
    loaded = {name: _state(private, states[name], *spec) for name, spec in specs.items()}
    _profile_initial(loaded["initial"])
    root, root_identity = _same_root(list(loaded.values()), processes)
    journal = _required_keys(mode.get("journal"),
                             {"interrupted", "after_default_cancel", "after_export"},
                             "Crash journal references")
    interrupted_ref = journal["interrupted"]
    interrupted = private.raw(interrupted_ref, "interrupted-active.drj", boundary="crash-stop-active-journal")
    after_cancel = private.raw(journal["after_default_cancel"], "active-after-default-cancel.drj",
                               boundary="default-cancel-normal-exit")
    after_export = private.raw(journal["after_export"], "active-after-export.drj",
                               boundary="recovery-export-normal-exit")
    prefix = verify_crash_prefix(interrupted, loaded["initial"].entries, loaded["crash_partial"].entries,
                                 fixture_root=root,
                                 root_identity={"volume_serial": f"{root_identity.volume:016x}",
                                                "file_id": f"{root_identity.file_id:032x}"})
    require(0 < prefix.changed_files < 4096, "Crash prefix is not a genuine partial mutation.")
    verify_recovery_invariance(loaded["initial"].entries, loaded["crash_partial"].entries,
                               loaded["startup_before_default_cancel"].entries,
                               loaded["default_cancel"].entries, loaded["relaunch"].entries,
                               loaded["restored"].entries)
    require(loaded["after_export"].inventory == loaded["crash_partial"].inventory and
            loaded["export_relaunch"].inventory == loaded["crash_partial"].inventory,
            "Recovery export or its relaunch changed the quiescent fixture.")
    actions = require_exact_keys(mode.get("actions"), {"default_cancel"}, "Crash recovery actions")
    _, cancel_completed = _action(private, actions["default_cancel"],
                                  "startup-default-cancel-action.json",
                                  boundary="startup-default-cancel-action", phase="startup-default-cancel",
                                  action="cancel-startup-recovery", process=processes[1],
                                  automation_id="CommandButton_2", control_id=2)
    require(cancel_completed <= processes[1].exit_observed,
            "Default cancel did not complete before the normal process exit.")
    inventories = require_exact_keys(mode.get("journal_inventories"),
                                     {"crash_stop", "after_default_cancel", "after_export",
                                      "final_recovered"}, "Crash journal inventory references")
    _journal_inventory(private, inventories["crash_stop"], "journal-crash-stop.json", "crash-stop",
                       "active.drj", interrupted)
    _journal_inventory(private, inventories["after_default_cancel"], "journal-after-default-cancel.json",
                       "default-cancel-normal-exit", "active.drj", interrupted)
    _journal_inventory(private, inventories["after_export"], "journal-after-export.json",
                       "recovery-export-normal-exit", "active.drj", interrupted)
    _journal_inventory(private, inventories["final_recovered"], "journal-final-recovered.json",
                       "recovered-normal-exit", None, None)
    verify_recovery_export(interrupted, interrupted, after_cancel)
    _foreground(private, mode["foreground_observations"], process=processes[3],
                expected_label="startup recovery confirmation")

    export = _required_keys(result.get("recovery_export"), {"source_active_journal", "raw"},
                            "Recovery export result")
    require(export["source_active_journal"] == interrupted_ref,
            "Recovery export does not reuse the exact interrupted-journal reference.")
    export_path = private.any_path(export["raw"], boundary="recovery-export", prefix="recovery-export/")
    exported = private.reader.bytes(export_path, MAX_MEMBER_BYTES)
    verify_recovery_export(interrupted, exported, after_export)

    intent = _required_keys(result.get("intent_only_candidate_discard"),
                            {"candidate", "states", "journals", "processes", "actions", "lock_states"},
                            "Intent-only result")
    candidate = _required_keys(intent.get("candidate"),
                               {"source_active_journal", "injected_candidate", "after_cancel",
                                "after_relaunch"}, "Intent candidate references")
    require(candidate["source_active_journal"] == interrupted_ref,
            "Intent injection does not reuse the exact interrupted-journal reference.")
    injected = private.raw(candidate["injected_candidate"], "intent-authentic-source.drj",
                           boundary="authentic-first-intent-frame")
    candidate_after_cancel = private.raw(candidate["after_cancel"], "intent-after-cancel.drj",
                                         boundary="intent-post-cancel-normal-exit")
    candidate_after_relaunch = private.raw(candidate["after_relaunch"], "intent-after-relaunch.drj",
                                           boundary="intent-post-relaunch-normal-exit")
    verify_intent_candidate(interrupted, injected, candidate_after_cancel, candidate_after_relaunch)
    intent_processes = _processes(private, intent["processes"],
                                  roles=["intent-cancel", "intent-relaunch", "intent-discard"],
                                  methods=["normal-close", "normal-close", "normal-close"],
                                  executable_sha256=bundle["product"]["application"]["sha256"],
                                  target=target, first_sequence=5)
    require(processes[-1].exit_observed <= intent_processes[0].start_observed,
            "Intent-only processes did not follow the completed crash recovery sequence.")
    intent_specs = {
        "pre_stage": ("intent-state-pre-stage.json", "intent-pre-stage"),
        "staged": ("intent-state-staged.json", "intent-staged"),
        "startup": ("intent-state-startup.json", "intent-startup"),
        "post_cancel": ("intent-state-post-cancel.json", "intent-post-cancel"),
        "post_cancel_exit": ("intent-state-post-cancel-exit.json", "intent-post-cancel-normal-exit"),
        "relaunch": ("intent-state-relaunch.json", "intent-relaunch"),
        "relaunch_exit": ("intent-state-relaunch-exit.json", "intent-post-relaunch-normal-exit"),
        "discard_startup": ("intent-state-discard-startup.json", "intent-discard-startup"),
        "discarded": ("intent-state-discarded.json", "intent-discarded"),
        "final_exit": ("intent-state-final-exit.json", "intent-final-normal-exit"),
    }
    require(type(intent["states"]) is dict and set(intent["states"]) == set(intent_specs),
            "Intent state references are incomplete or extra.")
    intent_states = {name: _state(private, intent["states"][name], *spec)
                     for name, spec in intent_specs.items()}
    _same_root(list(intent_states.values()), intent_processes)
    require(all(state.fixture_root == root and state.root_identity == root_identity and
                state.inventory == loaded["initial"].inventory for state in intent_states.values()),
            "Intent-only staging, cancel, relaunch, or discard changed the complete fixture.")
    intent_inventories = require_exact_keys(intent.get("journals"),
                                            {"pre_stage", "staged", "post_cancel_exit",
                                             "relaunch_exit", "final_exit"},
                                            "Intent journal inventory references")
    _journal_inventory(private, intent_inventories["pre_stage"], "intent-journal-pre-stage.json",
                       "intent-pre-stage", None, None)
    _journal_inventory(private, intent_inventories["staged"], "intent-journal-staged.json",
                       "intent-staged", "candidate.drj", injected)
    for key, relative, boundary in (
        ("post_cancel_exit", "intent-journal-post-cancel-exit.json", "intent-post-cancel-normal-exit"),
        ("relaunch_exit", "intent-journal-relaunch-exit.json", "intent-post-relaunch-normal-exit"),
    ):
        _journal_inventory(private, intent_inventories[key], relative, boundary, "candidate.drj", injected)
    _journal_inventory(private, intent_inventories["final_exit"], "intent-journal-final-exit.json",
                       "intent-final-normal-exit", None, None)
    intent_actions = require_exact_keys(intent.get("actions"), {"cancel_discard", "confirm_discard"},
                                        "Intent discard actions")
    cancel_observed, cancel_completed = _action(
        private, intent_actions["cancel_discard"], "intent-discard-cancel-action.json",
        boundary="intent-discard-cancel-action", phase="intent-discard-cancel",
        action="cancel-candidate-discard", process=intent_processes[0],
        automation_id="CommandButton_2", control_id=2)
    confirm_observed, confirm_completed = _action(
        private, intent_actions["confirm_discard"], "intent-discard-confirm-action.json",
        boundary="intent-discard-confirm-action", phase="intent-discard-confirm",
        action="confirm-candidate-discard", process=intent_processes[2],
        automation_id="CommandLink_1201", control_id=1201)
    locks = require_exact_keys(intent.get("lock_states"),
                              {"startup", "post_cancel", "relaunch", "discard_startup", "post_discard"},
                              "Intent recovery lock states")
    startup_lock = _lock_state(private, locks["startup"], "intent-startup-lock.json",
                               boundary="intent-startup-lock", phase="intent-startup",
                               process=intent_processes[0], locked=True)
    post_cancel_lock = _lock_state(private, locks["post_cancel"], "intent-post-cancel-lock.json",
                                   boundary="intent-post-cancel-lock", phase="intent-post-cancel",
                                   process=intent_processes[0], locked=True)
    _lock_state(private, locks["relaunch"], "intent-relaunch-lock.json",
                boundary="intent-relaunch-lock", phase="intent-relaunch",
                process=intent_processes[1], locked=True)
    discard_lock = _lock_state(private, locks["discard_startup"], "intent-discard-startup-lock.json",
                               boundary="intent-discard-startup-lock", phase="intent-discard-startup",
                               process=intent_processes[2], locked=True)
    post_discard = _lock_state(private, locks["post_discard"], "intent-post-discard-unlock.json",
                               boundary="intent-post-discard-unlock", phase="intent-post-discard",
                               process=intent_processes[2], locked=False)
    require(startup_lock <= cancel_observed <= cancel_completed <= post_cancel_lock and
            discard_lock <= confirm_observed <= confirm_completed <= post_discard,
            "Intent discard action ordering differs from the observed lock transitions.")
    return {"process-crash", "recovery-export", "intent-only-discard"}


def verify_recovery_execution(reader: EvidenceReader, result: dict, bundle: dict, transport: dict,
                              target: dict, *, run_prefix: str) -> set[str]:
    """Return only the fixed recovery targets derived from one complete execution."""
    require(type(reader) is not type(None) and all(hasattr(reader, name)
                                                   for name in ("json", "bytes", "digest_reference")),
            "Recovery evidence reader is unavailable.")
    require(type(result) is dict and type(bundle) is dict and type(transport) is dict and
            type(target) is dict, "Recovery execution inputs must be objects.")
    verify_result_binding(result, bundle, observer="recovery")
    require(result.get("selected_mode") in {"ProcessCrash", "WorkerCancellation", "WorkerClose"},
            "Recovery execution mode is unsupported or unavailable.")
    private = PrivateEvidence(reader, result, run_prefix)
    if result["selected_mode"] == "ProcessCrash":
        targets = _process_crash(private, result, bundle, target)
    elif result["selected_mode"] == "WorkerCancellation":
        targets = _worker(private, result, bundle, target, close=False)
    else:
        targets = _worker(private, result, bundle, target, close=True)
    verify_cleanup(result.get("raw_cleanup"), transport.get("raw_cleanup"))
    private.finish()
    require(targets <= RECOVERY_TARGETS, "Recovery verifier derived an unknown target.")
    return targets
