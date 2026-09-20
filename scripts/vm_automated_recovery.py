"""Join strict journal replay to full observed NTFS fixture identities.

Input records remain private. Callers separately verify file references,
candidate/observer provenance, process lifecycle, desktop state and cleanup.
"""

from __future__ import annotations

from dataclasses import dataclass
import hmac

from vm_automated_evidence import EvidenceError
from vm_automated_journal import (
    Direction, JournalInspection, RecordKind, ReplayStatus, parse_journal_bytes,
    require_vm_automated_direct_profile, intent_frame_is_byte_identical,
)
from vm_automated_state import Identity, fixture_inventory, interrupted_inventory, restored_inventory


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


@dataclass(frozen=True)
class CrashPrefix:
    changed_files: int
    completed_forward: int
    prepared_step: int | None
    raw_bytes: int
    valid_bytes: int
    tail_kind: str | None


def journal_fixture_schedule(inspection: JournalInspection, initial: object, *,
                             fixture_root: str, root_identity: object) -> list[tuple[str, str]]:
    """Bind every Intent endpoint and all three identities to one observed root."""
    profile = require_vm_automated_direct_profile(inspection)
    files = fixture_inventory(initial, full_identity=True)
    require(type(fixture_root) is str and fixture_root and not fixture_root.endswith("\\"),
            "Fixture root must be the exact observed directory path.")
    try:
        prefix = (fixture_root + "\\").encode("utf-16-le")
    except UnicodeEncodeError as error:
        raise EvidenceError("Fixture root has invalid UTF-16.") from error
    parent = Identity.parse(root_identity)
    schedule = []
    for step in profile.bindings:
        names = []
        for endpoint in (step.source, step.destination):
            encoded = b"".join(unit.to_bytes(2, "little") for unit in endpoint.units)
            require(encoded.startswith(prefix), "Journal endpoint is outside the observed fixture root.")
            try:
                name = encoded[len(prefix):].decode("utf-16-le")
            except UnicodeDecodeError as error:
                raise EvidenceError("Journal fixture leaf has invalid UTF-16.") from error
            require("\\" not in name and "/" not in name, "Journal endpoint is not a direct fixture child.")
            names.append(name)
        source, destination = names
        require(source in files, "Journal source is absent from the complete initial inventory.")
        observed = files[source].identity
        require(observed == Identity(step.expected_source.volume, step.expected_source.file_id),
                "Journal source identity differs from the observed full FILE_ID_INFO.")
        for expected_parent in (step.expected_source_parent, step.expected_destination_parent):
            require(parent == Identity(expected_parent.volume, expected_parent.file_id),
                    "Journal parent identity differs from the observed fixture directory.")
        require(observed.volume == parent.volume, "Fixture and parent volume identities differ.")
        schedule.append((source, destination))
    return schedule


def verify_crash_prefix(raw_journal: bytes, initial: object, partial: object, *,
                        fixture_root: str, root_identity: object) -> CrashPrefix:
    """Require a real incomplete forward transaction, including a retained tear."""
    inspection = parse_journal_bytes(raw_journal, allow_torn_final=True)
    require(inspection.replay.status is ReplayStatus.RECOVERY_REQUIRED,
            "Crash trial has no incomplete transaction.")
    require(inspection.replay.completed_rollback == 0 and
            inspection.replay.prepared_direction in {None, Direction.FORWARD},
            "Crash witness was already rolling back.")
    require(all(item.direction is Direction.FORWARD and
                item.kind in {RecordKind.PREPARED, RecordKind.COMPLETED}
                for item in inspection.transitions),
            "Crash witness contains a failure or rollback transition.")
    schedule = journal_fixture_schedule(inspection, initial, fixture_root=fixture_root,
                                        root_identity=root_identity)
    changed = interrupted_inventory(initial, partial, renames=schedule,
                                    completed=inspection.replay.completed_forward,
                                    prepared=inspection.replay.prepared_step,
                                    protected_names=("sentinel.bin",))
    return CrashPrefix(changed, inspection.replay.completed_forward,
                       inspection.replay.prepared_step, len(raw_journal), inspection.valid_bytes,
                       None if inspection.tail_issue is None else inspection.tail_issue.value)


def verify_recovery_invariance(initial: object, partial: object, startup: object,
                               default_cancel: object, relaunched: object, restored: object) -> None:
    """Startup/default Cancel/relaunch cannot mutate before explicit recovery."""
    baseline = fixture_inventory(partial, full_identity=True)
    for name, snapshot in (("startup", startup), ("default Cancel", default_cancel),
                           ("relaunch", relaunched)):
        require(fixture_inventory(snapshot, full_identity=True) == baseline,
                "Recovery " + name + " changed files without explicit authorization.")
    restored_inventory(initial, restored, expected_count=4097)


def verify_recovery_export(raw_journal: bytes, exported: bytes, after_exit: bytes) -> None:
    """Export and retained journal must preserve every byte, including a tail."""
    inspection = parse_journal_bytes(raw_journal, allow_torn_final=True)
    require_vm_automated_direct_profile(inspection)
    require(inspection.replay.status is ReplayStatus.RECOVERY_REQUIRED,
            "Recovery export must belong to an incomplete transaction.")
    require(type(exported) is bytes and type(after_exit) is bytes,
            "Export evidence must contain raw byte streams.")
    require(hmac.compare_digest(raw_journal, exported) and hmac.compare_digest(raw_journal, after_exit),
            "Export or normal exit changed the interrupted journal bytes.")


def verify_intent_candidate(raw_journal: bytes, candidate: bytes, after_cancel: bytes,
                            after_relaunch: bytes) -> None:
    """Injected candidate remains the exact authentic first Intent frame."""
    inspection = parse_journal_bytes(raw_journal, allow_torn_final=True)
    require_vm_automated_direct_profile(inspection)
    require(inspection.replay.status is ReplayStatus.RECOVERY_REQUIRED,
            "Injected Intent must come from the interrupted transaction journal.")
    for value in (candidate, after_cancel, after_relaunch):
        require(intent_frame_is_byte_identical(inspection, value),
                "Injected candidate is not the byte-identical authentic Intent frame.")
