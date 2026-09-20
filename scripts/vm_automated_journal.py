#!/usr/bin/env python3
"""Strict DarkReNamer v2 journal codec and pure replay primitives.

The codec preserves exact UTF-16 code units and full filesystem identities.  It
does not inspect the filesystem, derive an acceptance verdict, or treat a
Prepared record as proof that a rename was or was not applied.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, IntEnum
import hmac
import struct
from typing import Sequence, TypeAlias
import zlib


MAGIC = b"DRJ1"
VERSION = 2
HEADER_BYTES = 24
MAX_JOURNAL_STEPS = 10_000
MAX_JOURNAL_FRAMES = MAX_JOURNAL_STEPS * 4 + 4
MAX_JOURNAL_FRAME_BYTES = 16 * 1024 * 1024
MAX_JOURNAL_FILE_BYTES = 64 * 1024 * 1024
MAX_PATH_UNITS = 32_767
VM_AUTOMATED_PROFILE_STEPS = 4_096


class ErrorKind(str, Enum):
    FILE_TOO_LARGE = "file-too-large"
    TOO_MANY_FRAMES = "too-many-frames"
    TOO_MANY_STEPS = "too-many-steps"
    PATH_TOO_LONG = "path-too-long"
    TRUNCATED_FRAME = "truncated-frame"
    INVALID_MAGIC = "invalid-magic"
    UNSUPPORTED_VERSION = "unsupported-version"
    INVALID_FLAGS = "invalid-flags"
    SEQUENCE_MISMATCH = "sequence-mismatch"
    FRAME_TOO_LARGE = "frame-too-large"
    CHECKSUM_MISMATCH = "checksum-mismatch"
    UNKNOWN_RECORD_KIND = "unknown-record-kind"
    UNKNOWN_FIELD_VALUE = "unknown-field-value"
    INVALID_PAYLOAD = "invalid-payload"
    INVALID_TRANSITIONS = "invalid-transitions"


class JournalCodecError(ValueError):
    def __init__(self, frame: int, kind: ErrorKind, detail: str = "") -> None:
        self.frame = frame
        self.kind = kind
        self.detail = detail
        suffix = f": {detail}" if detail else ""
        super().__init__(f"journal frame {frame}: {kind.value}{suffix}")


class JournalProfileError(ValueError):
    """Raised when a valid journal does not match the fixed VM profile."""


class RecordKind(IntEnum):
    INTENT = 1
    PREPARED = 2
    COMPLETED = 3
    NOT_APPLIED = 4
    TERMINAL = 5


class Direction(str, Enum):
    FORWARD = "forward"
    ROLLBACK = "rollback"


class EntryKind(str, Enum):
    FILE = "file"
    DIRECTORY = "directory"


class MoveScope(str, Enum):
    SAME_PARENT = "same-parent"
    SAME_VOLUME_FILES_ONLY = "same-volume-files-only"


class TemporaryPhase(str, Enum):
    NONE = "none"
    INTO_TEMPORARY = "into-temporary"
    FROM_TEMPORARY = "from-temporary"


class Terminal(str, Enum):
    COMMITTED = "committed"
    ROLLED_BACK = "rolled-back"


class TailIssue(str, Enum):
    TRUNCATED_HEADER = "truncated-header"
    TRUNCATED_PAYLOAD = "truncated-payload"


class ReplayStatus(str, Enum):
    CLEAN = "clean"
    RECOVERY_REQUIRED = "recovery-required"


class RecoveryReason(str, Enum):
    INCOMPLETE = "incomplete"
    PREPARED_ONLY = "prepared-only"
    MISSING_INTENT = "missing-intent"
    STEP_OUT_OF_BOUNDS = "step-out-of-bounds"
    INVALID_ORDER = "invalid-order"
    RECORDS_AFTER_TERMINAL = "records-after-terminal"
    INVALID_TERMINAL = "invalid-terminal"


@dataclass(frozen=True)
class Utf16Text:
    units: tuple[int, ...]

    def __post_init__(self) -> None:
        if len(self.units) > MAX_PATH_UNITS:
            raise ValueError("UTF-16 text exceeds the journal path limit")
        if any(type(unit) is not int or not 0 <= unit <= 0xFFFF for unit in self.units):
            raise ValueError("UTF-16 text contains a non-u16 unit")


@dataclass(frozen=True)
class EntryIdentity:
    volume: int
    file_id: int

    def __post_init__(self) -> None:
        if type(self.volume) is not int or not 0 <= self.volume <= 0xFFFFFFFFFFFFFFFF:
            raise ValueError("volume must be one u64")
        if type(self.file_id) is not int or not 0 <= self.file_id <= (1 << 128) - 1:
            raise ValueError("file_id must be one u128")


@dataclass(frozen=True)
class JournalStep:
    entry: int
    source: Utf16Text
    destination: Utf16Text
    expected_source: EntryIdentity
    expected_source_parent: EntryIdentity
    expected_destination_parent: EntryIdentity
    entry_kind: EntryKind
    scope: MoveScope
    temporary_phase: TemporaryPhase


@dataclass(frozen=True)
class IntentRecord:
    plan: int
    steps: tuple[JournalStep, ...]


@dataclass(frozen=True)
class TransitionRecord:
    kind: RecordKind
    step: int
    direction: Direction

    def __post_init__(self) -> None:
        if self.kind not in {
            RecordKind.PREPARED,
            RecordKind.COMPLETED,
            RecordKind.NOT_APPLIED,
        }:
            raise ValueError("transition record has a non-transition kind")


@dataclass(frozen=True)
class TerminalRecord:
    terminal: Terminal


JournalRecord: TypeAlias = IntentRecord | TransitionRecord | TerminalRecord


@dataclass(frozen=True)
class Frame:
    index: int
    offset: int
    end: int
    kind: RecordKind
    sequence: int
    payload_bytes: int
    checksum: int


@dataclass(frozen=True)
class Transition:
    frame: int
    kind: RecordKind
    step: int
    direction: Direction


@dataclass(frozen=True)
class ReplayState:
    status: ReplayStatus
    plan: int | None = None
    completed_forward: int = 0
    completed_rollback: int = 0
    reason: RecoveryReason | None = None
    prepared_step: int | None = None
    prepared_direction: Direction | None = None

    @property
    def prepared_mutation_possibilities(self) -> tuple[str, ...]:
        """Return the only safe interpretation of an unresolved Prepared frame."""

        if self.reason is RecoveryReason.PREPARED_ONLY:
            return ("unapplied", "applied")
        return ()


@dataclass(frozen=True)
class JournalInspection:
    frames: tuple[Frame, ...]
    records: tuple[JournalRecord, ...]
    intent_bytes: bytes | None
    transitions: tuple[Transition, ...]
    replay: ReplayState
    valid_bytes: int
    tail_issue: TailIssue | None
    raw_bytes: int


@dataclass(frozen=True)
class DirectStepBinding:
    entry: int
    source: Utf16Text
    destination: Utf16Text
    expected_source: EntryIdentity
    expected_source_parent: EntryIdentity
    expected_destination_parent: EntryIdentity


@dataclass(frozen=True)
class DirectSameParentProfile:
    plan: int
    bindings: tuple[DirectStepBinding, ...]


class _Decoder:
    def __init__(self, payload: bytes, frame: int) -> None:
        self.payload = payload
        self.frame = frame
        self.offset = 0

    def take(self, count: int) -> bytes:
        end = self.offset + count
        if end > len(self.payload):
            raise JournalCodecError(self.frame, ErrorKind.INVALID_PAYLOAD)
        result = self.payload[self.offset:end]
        self.offset = end
        return result

    def u8(self) -> int:
        return self.take(1)[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def u128(self) -> int:
        return int.from_bytes(self.take(16), "little")

    def identity(self) -> EntryIdentity:
        return EntryIdentity(self.u64(), self.u128())

    def text(self) -> Utf16Text:
        count = self.u32()
        if count > MAX_PATH_UNITS:
            raise JournalCodecError(self.frame, ErrorKind.PATH_TOO_LONG)
        encoded = self.take(count * 2)
        return Utf16Text(tuple(unit[0] for unit in struct.iter_unpack("<H", encoded)))

    def finish(self) -> None:
        if self.offset != len(self.payload):
            raise JournalCodecError(self.frame, ErrorKind.INVALID_PAYLOAD)


def _enum_value(value: int, values: tuple[Enum, ...], frame: int) -> Enum:
    if value >= len(values):
        raise JournalCodecError(frame, ErrorKind.UNKNOWN_FIELD_VALUE)
    return values[value]


def _decode_record(kind: RecordKind, payload: bytes, frame: int) -> JournalRecord:
    decoder = _Decoder(payload, frame)
    if kind is RecordKind.INTENT:
        plan = decoder.u64()
        count = decoder.u32()
        if count > MAX_JOURNAL_STEPS:
            raise JournalCodecError(frame, ErrorKind.TOO_MANY_STEPS)
        steps: list[JournalStep] = []
        for _ in range(count):
            entry = decoder.u32()
            source = decoder.text()
            destination = decoder.text()
            expected_source = decoder.identity()
            expected_source_parent = decoder.identity()
            expected_destination_parent = decoder.identity()
            entry_kind = _enum_value(
                decoder.u8(), (EntryKind.FILE, EntryKind.DIRECTORY), frame)
            scope = _enum_value(
                decoder.u8(), (MoveScope.SAME_PARENT, MoveScope.SAME_VOLUME_FILES_ONLY), frame)
            temporary_phase = _enum_value(
                decoder.u8(),
                (TemporaryPhase.NONE, TemporaryPhase.INTO_TEMPORARY,
                 TemporaryPhase.FROM_TEMPORARY),
                frame,
            )
            steps.append(JournalStep(
                entry=entry,
                source=source,
                destination=destination,
                expected_source=expected_source,
                expected_source_parent=expected_source_parent,
                expected_destination_parent=expected_destination_parent,
                entry_kind=entry_kind,
                scope=scope,
                temporary_phase=temporary_phase,
            ))
        record: JournalRecord = IntentRecord(plan=plan, steps=tuple(steps))
    elif kind in {RecordKind.PREPARED, RecordKind.COMPLETED, RecordKind.NOT_APPLIED}:
        step = decoder.u32()
        direction = _enum_value(decoder.u8(), (Direction.FORWARD, Direction.ROLLBACK), frame)
        record = TransitionRecord(kind=kind, step=step, direction=direction)
    else:
        terminal = _enum_value(decoder.u8(), (Terminal.COMMITTED, Terminal.ROLLED_BACK), frame)
        record = TerminalRecord(terminal=terminal)
    decoder.finish()
    return record


def _recovery(
    plan: int | None,
    completed_forward: set[int],
    completed_rollback: set[int],
    reason: RecoveryReason,
    *,
    prepared_step: int | None = None,
    prepared_direction: Direction | None = None,
) -> ReplayState:
    return ReplayState(
        status=ReplayStatus.RECOVERY_REQUIRED,
        plan=plan,
        completed_forward=len(completed_forward),
        completed_rollback=len(completed_rollback),
        reason=reason,
        prepared_step=prepared_step,
        prepared_direction=prepared_direction,
    )


def replay_records(records: Sequence[JournalRecord]) -> ReplayState:
    """Mirror Rust's pure journal state machine without filesystem access."""

    if not records:
        return ReplayState(status=ReplayStatus.CLEAN)
    first = records[0]
    if type(first) is not IntentRecord:
        return _recovery(None, set(), set(), RecoveryReason.MISSING_INTENT)

    plan = first.plan
    step_count = len(first.steps)
    forward_prepared: int | None = None
    rollback_prepared: int | None = None
    next_forward = 0
    completed_forward: set[int] = set()
    completed_rollback: set[int] = set()
    rollback_started = False
    terminal: Terminal | None = None

    def corrupt(reason: RecoveryReason) -> ReplayState:
        return _recovery(plan, completed_forward, completed_rollback, reason)

    for record in records[1:]:
        if terminal is not None:
            return corrupt(RecoveryReason.RECORDS_AFTER_TERMINAL)
        if type(record) is IntentRecord:
            return corrupt(RecoveryReason.INVALID_ORDER)
        if type(record) is TerminalRecord:
            terminal = record.terminal
            continue
        if type(record) is not TransitionRecord:
            return corrupt(RecoveryReason.INVALID_ORDER)
        if record.step >= step_count:
            return corrupt(RecoveryReason.STEP_OUT_OF_BOUNDS)

        if record.kind is RecordKind.PREPARED:
            if (record.direction is Direction.FORWARD and not rollback_started and
                    forward_prepared is None and record.step == next_forward):
                forward_prepared = record.step
            elif (record.direction is Direction.ROLLBACK and rollback_prepared is None and
                  forward_prepared is None):
                rollback_started = True
                remaining = sorted(completed_forward - completed_rollback, reverse=True)
                if not remaining or remaining[0] != record.step:
                    return corrupt(RecoveryReason.INVALID_ORDER)
                rollback_prepared = record.step
            else:
                return corrupt(RecoveryReason.INVALID_ORDER)
        elif record.kind is RecordKind.COMPLETED:
            if record.direction is Direction.FORWARD and forward_prepared == record.step:
                forward_prepared = None
                completed_forward.add(record.step)
                next_forward += 1
            elif record.direction is Direction.ROLLBACK and rollback_prepared == record.step:
                rollback_prepared = None
                completed_rollback.add(record.step)
            else:
                return corrupt(RecoveryReason.INVALID_ORDER)
        elif record.kind is RecordKind.NOT_APPLIED:
            if record.direction is Direction.FORWARD and forward_prepared == record.step:
                forward_prepared = None
                rollback_started = True
                next_forward += 1
            elif record.direction is Direction.ROLLBACK and rollback_prepared == record.step:
                rollback_prepared = None
            else:
                return corrupt(RecoveryReason.INVALID_ORDER)

    if terminal is not None:
        valid = (
            terminal is Terminal.COMMITTED and
            len(completed_forward) == step_count and
            not completed_rollback and
            forward_prepared is None and rollback_prepared is None
        ) or (
            terminal is Terminal.ROLLED_BACK and
            completed_forward == completed_rollback and
            forward_prepared is None and rollback_prepared is None
        )
        return (ReplayState(
            status=ReplayStatus.CLEAN,
            plan=plan,
            completed_forward=len(completed_forward),
            completed_rollback=len(completed_rollback),
        ) if valid else corrupt(RecoveryReason.INVALID_TERMINAL))
    if forward_prepared is not None:
        return _recovery(
            plan, completed_forward, completed_rollback, RecoveryReason.PREPARED_ONLY,
            prepared_step=forward_prepared, prepared_direction=Direction.FORWARD)
    if rollback_prepared is not None:
        return _recovery(
            plan, completed_forward, completed_rollback, RecoveryReason.PREPARED_ONLY,
            prepared_step=rollback_prepared, prepared_direction=Direction.ROLLBACK)
    return _recovery(plan, completed_forward, completed_rollback, RecoveryReason.INCOMPLETE)


_CORRUPT_REASONS = {
    RecoveryReason.MISSING_INTENT,
    RecoveryReason.STEP_OUT_OF_BOUNDS,
    RecoveryReason.INVALID_ORDER,
    RecoveryReason.RECORDS_AFTER_TERMINAL,
    RecoveryReason.INVALID_TERMINAL,
}


def parse_journal_bytes(data: bytes, *, allow_torn_final: bool) -> JournalInspection:
    """Decode a bounded v2 journal, optionally retaining one final torn frame."""

    if type(data) is not bytes:
        raise TypeError("journal data must be bytes")
    if type(allow_torn_final) is not bool:
        raise TypeError("allow_torn_final must be a boolean")
    if len(data) > MAX_JOURNAL_FILE_BYTES:
        raise JournalCodecError(0, ErrorKind.FILE_TOO_LARGE)

    frames: list[Frame] = []
    records: list[JournalRecord] = []
    transitions: list[Transition] = []
    offset = 0
    tail_issue: TailIssue | None = None
    valid_bytes = 0
    intent_bytes: bytes | None = None

    while offset < len(data):
        frame = len(records)
        if frame >= MAX_JOURNAL_FRAMES:
            raise JournalCodecError(frame, ErrorKind.TOO_MANY_FRAMES)
        if len(data) - offset < HEADER_BYTES:
            tail_issue = TailIssue.TRUNCATED_HEADER
            break
        header = data[offset:offset + HEADER_BYTES]
        if header[:4] != MAGIC:
            raise JournalCodecError(frame, ErrorKind.INVALID_MAGIC)
        version = struct.unpack_from("<H", header, 4)[0]
        if version != VERSION:
            raise JournalCodecError(frame, ErrorKind.UNSUPPORTED_VERSION)
        try:
            kind = RecordKind(header[6])
        except ValueError as error:
            raise JournalCodecError(frame, ErrorKind.UNKNOWN_RECORD_KIND) from error
        if header[7] != 0:
            raise JournalCodecError(frame, ErrorKind.INVALID_FLAGS)
        sequence = struct.unpack_from("<Q", header, 8)[0]
        if sequence != frame:
            raise JournalCodecError(frame, ErrorKind.SEQUENCE_MISMATCH)
        payload_size = struct.unpack_from("<I", header, 16)[0]
        if payload_size > MAX_JOURNAL_FRAME_BYTES:
            raise JournalCodecError(frame, ErrorKind.FRAME_TOO_LARGE)
        end = offset + HEADER_BYTES + payload_size
        if end > len(data):
            tail_issue = TailIssue.TRUNCATED_PAYLOAD
            break
        payload = data[offset + HEADER_BYTES:end]
        checksum = struct.unpack_from("<I", header, 20)[0]
        actual_checksum = zlib.crc32(header[4:20] + payload) & 0xFFFFFFFF
        if checksum != actual_checksum:
            raise JournalCodecError(frame, ErrorKind.CHECKSUM_MISMATCH)
        record = _decode_record(kind, payload, frame)
        records.append(record)
        frames.append(Frame(
            index=frame,
            offset=offset,
            end=end,
            kind=kind,
            sequence=sequence,
            payload_bytes=payload_size,
            checksum=checksum,
        ))
        if type(record) is IntentRecord and frame == 0:
            intent_bytes = data[offset:end]
        if type(record) is TransitionRecord:
            transitions.append(Transition(
                frame=frame,
                kind=record.kind,
                step=record.step,
                direction=record.direction,
            ))
        offset = end
        valid_bytes = end

    if tail_issue is not None:
        if not allow_torn_final or not records:
            raise JournalCodecError(len(records), ErrorKind.TRUNCATED_FRAME)
    replay = replay_records(records)
    if replay.reason in _CORRUPT_REASONS:
        raise JournalCodecError(max(0, len(records) - 1), ErrorKind.INVALID_TRANSITIONS)
    return JournalInspection(
        frames=tuple(frames),
        records=tuple(records),
        intent_bytes=intent_bytes,
        transitions=tuple(transitions),
        replay=replay,
        valid_bytes=valid_bytes,
        tail_issue=tail_issue,
        raw_bytes=len(data),
    )


def decode_complete_journal(data: bytes) -> JournalInspection:
    """Decode a complete journal; every partial final frame is an error."""

    return parse_journal_bytes(data, allow_torn_final=False)


def intent_frame_is_byte_identical(inspection: JournalInspection, candidate: bytes) -> bool:
    """Compare an injected candidate to the authentic first frame, byte for byte."""

    if type(inspection) is not JournalInspection or type(candidate) is not bytes:
        raise TypeError("inspection and candidate have invalid types")
    return inspection.intent_bytes is not None and hmac.compare_digest(
        inspection.intent_bytes, candidate)


def _direct_path_parts(text: Utf16Text, label: str) -> tuple[tuple[int, ...], str]:
    units = text.units
    if not units or 0 in units or 0x2F in units:
        raise JournalProfileError(f"{label} is not one supported drive-rooted path")

    drive = lambda value: 0x41 <= value <= 0x5A or 0x61 <= value <= 0x7A
    if (len(units) >= 3 and drive(units[0]) and units[1:3] == (0x3A, 0x5C)):
        root_end = 3
    elif (len(units) >= 7 and units[:4] == (0x5C, 0x5C, 0x3F, 0x5C)
          and drive(units[4]) and units[5:7] == (0x3A, 0x5C)):
        root_end = 7
    else:
        raise JournalProfileError(f"{label} is not one supported drive-rooted path")

    components = units[root_end:]
    if not components or components[-1] == 0x5C:
        raise JournalProfileError(f"{label} has an empty leaf")
    split_components: list[tuple[int, ...]] = []
    start = 0
    for index, unit in enumerate(components):
        if unit == 0x5C:
            component = components[start:index]
            if not component:
                raise JournalProfileError(f"{label} has an empty path component")
            split_components.append(component)
            start = index + 1
    split_components.append(components[start:])
    if any(component in {(0x2E,), (0x2E, 0x2E)} for component in split_components):
        raise JournalProfileError(f"{label} contains a dot path component")

    leaf_units = split_components[-1]
    if any(unit > 0x7F for unit in leaf_units):
        raise JournalProfileError(f"{label} leaf is not canonical ASCII")
    separator = len(units) - len(leaf_units) - 1
    parent = units[:separator] if separator >= root_end - 1 else units[:root_end - 1]
    leaf = bytes(leaf_units).decode("ascii")
    return parent, leaf


def require_vm_automated_direct_profile(
    inspection: JournalInspection,
) -> DirectSameParentProfile:
    """Bind the fixed 4,096-step direct-file manifest for later raw joins.

    This checks only immutable Intent structure.  It does not compare filesystem
    snapshots or authorize a target verdict.
    """

    if type(inspection) is not JournalInspection:
        raise TypeError("inspection must be JournalInspection")
    if not inspection.records or type(inspection.records[0]) is not IntentRecord:
        raise JournalProfileError("journal has no complete first Intent")
    intent = inspection.records[0]
    if len(intent.steps) != VM_AUTOMATED_PROFILE_STEPS:
        raise JournalProfileError("Intent does not contain exactly 4,096 steps")

    entries: set[int] = set()
    sources: set[str] = set()
    destinations: set[str] = set()
    source_identities: set[EntryIdentity] = set()
    common_parent: tuple[int, ...] | None = None
    common_parent_identity: EntryIdentity | None = None
    bindings: list[DirectStepBinding] = []
    for index, step in enumerate(intent.steps):
        if step.entry_kind is not EntryKind.FILE:
            raise JournalProfileError(f"step {index} is not a file")
        if step.scope is not MoveScope.SAME_PARENT:
            raise JournalProfileError(f"step {index} is not same-parent")
        if step.temporary_phase is not TemporaryPhase.NONE:
            raise JournalProfileError(f"step {index} is not a direct schedule step")
        source_parent, source_leaf = _direct_path_parts(step.source, f"step {index} source")
        destination_parent, destination_leaf = _direct_path_parts(
            step.destination, f"step {index} destination")
        if source_parent != destination_parent:
            raise JournalProfileError(f"step {index} path parents differ")
        if step.expected_source_parent != step.expected_destination_parent:
            raise JournalProfileError(f"step {index} identity parents differ")
        if common_parent is None:
            common_parent = source_parent
            common_parent_identity = step.expected_source_parent
        elif (source_parent != common_parent or
              step.expected_source_parent != common_parent_identity):
            raise JournalProfileError(f"step {index} differs from the global parent")
        if step.expected_source.volume != step.expected_source_parent.volume:
            raise JournalProfileError(f"step {index} source and parent volumes differ")
        if step.entry in entries:
            raise JournalProfileError(f"step {index} repeats entry {step.entry}")
        folded_source = source_leaf.lower()
        folded_destination = destination_leaf.lower()
        if folded_source == folded_destination:
            raise JournalProfileError(f"step {index} source and destination are the same path")
        if folded_source in sources:
            raise JournalProfileError(f"step {index} repeats a source path")
        if folded_destination in destinations:
            raise JournalProfileError(f"step {index} repeats a destination path")
        if folded_source in destinations or folded_destination in sources:
            raise JournalProfileError(f"step {index} source and destination sets overlap")
        expected_source_leaf = f"item-{step.entry:05d}.txt"
        expected_destination_leaf = f"vm-recovered-{expected_source_leaf}"
        if source_leaf != expected_source_leaf or destination_leaf != expected_destination_leaf:
            raise JournalProfileError(f"step {index} does not use canonical synthetic leaves")
        if step.expected_source in source_identities:
            raise JournalProfileError(f"step {index} repeats a source identity")
        entries.add(step.entry)
        sources.add(folded_source)
        destinations.add(folded_destination)
        source_identities.add(step.expected_source)
        bindings.append(DirectStepBinding(
            entry=step.entry,
            source=step.source,
            destination=step.destination,
            expected_source=step.expected_source,
            expected_source_parent=step.expected_source_parent,
            expected_destination_parent=step.expected_destination_parent,
        ))
    if entries != set(range(VM_AUTOMATED_PROFILE_STEPS)):
        raise JournalProfileError("Intent entries are not exactly 0 through 4,095")
    return DirectSameParentProfile(plan=intent.plan, bindings=tuple(bindings))
