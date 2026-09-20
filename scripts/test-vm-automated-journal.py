#!/usr/bin/env python3
"""Focused tests for the strict VM-automated journal codec."""

from __future__ import annotations

from dataclasses import replace
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import unittest
import zlib


SCRIPT = Path(__file__).with_name("vm_automated_journal.py")
REPOSITORY = SCRIPT.parent.parent
SPEC = importlib.util.spec_from_file_location("vm_automated_journal", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
journal = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = journal
SPEC.loader.exec_module(journal)


def text_payload(units: tuple[int, ...]) -> bytes:
    return struct.pack("<I", len(units)) + b"".join(
        struct.pack("<H", unit) for unit in units)


def text_units(value: str) -> tuple[int, ...]:
    encoded = value.encode("utf-16-le")
    return tuple(unit[0] for unit in struct.iter_unpack("<H", encoded))


def identity(volume: int, file_id: int) -> bytes:
    return struct.pack("<Q", volume) + file_id.to_bytes(16, "little")


def step_payload(
    entry: int,
    source: tuple[int, ...],
    destination: tuple[int, ...],
    *,
    source_identity: tuple[int, int] = (7, 10),
    source_parent: tuple[int, int] = (7, 1),
    destination_parent: tuple[int, int] = (7, 1),
    entry_kind: int = 0,
    scope: int = 0,
    phase: int = 0,
) -> bytes:
    return (
        struct.pack("<I", entry)
        + text_payload(source)
        + text_payload(destination)
        + identity(*source_identity)
        + identity(*source_parent)
        + identity(*destination_parent)
        + bytes((entry_kind, scope, phase))
    )


def intent_payload(steps: list[bytes], *, plan: int = 42,
                   declared_count: int | None = None) -> bytes:
    count = len(steps) if declared_count is None else declared_count
    return struct.pack("<QI", plan, count) + b"".join(steps)


def transition_payload(step: int, direction: int) -> bytes:
    return struct.pack("<IB", step, direction)


def frame(kind: int, payload: bytes, sequence: int, *, version: int = 2,
          flags: int = 0) -> bytes:
    header = bytearray(
        b"DRJ1"
        + struct.pack("<HBBQI", version, kind, flags, sequence, len(payload))
        + b"\0\0\0\0"
    )
    checksum = zlib.crc32(header[4:20] + payload) & 0xFFFFFFFF
    struct.pack_into("<I", header, 20, checksum)
    return bytes(header) + payload


def stream(records: list[tuple[int, bytes]]) -> bytes:
    return b"".join(
        frame(kind, payload, sequence)
        for sequence, (kind, payload) in enumerate(records)
    )


def one_step_intent(*, plan: int = 42, entry_kind: int = 0, scope: int = 0,
                    phase: int = 0) -> bytes:
    return frame(
        1,
        intent_payload([
            step_payload(
                0,
                text_units(r"C:\fixture\a.txt"),
                text_units(r"C:\fixture\b.txt"),
                entry_kind=entry_kind,
                scope=scope,
                phase=phase,
            )
        ], plan=plan),
        0,
    )


def profile_stream(count: int = journal.VM_AUTOMATED_PROFILE_STEPS,
                   *, parent: str = r"C:\fixture") -> bytes:
    steps = []
    for index in range(count):
        steps.append(step_payload(
            index,
            text_units(fr"{parent}\item-{index:05d}.txt"),
            text_units(fr"{parent}\vm-recovered-item-{index:05d}.txt"),
            source_identity=(0x0123456789ABCDEF, index + 0x100),
            source_parent=(0x0123456789ABCDEF, 0x10),
            destination_parent=(0x0123456789ABCDEF, 0x10),
        ))
    return frame(1, intent_payload(steps, plan=0xA5A5), 0)


class CodecTests(unittest.TestCase):
    def test_exact_v2_intent_and_full_identities(self) -> None:
        source_units = (0, 0xD800, 0x61, 0xDC00, 0xFFFF)
        destination_units = (0xD83D, 0xDE00, 0xAC00, 0x62)
        encoded = frame(1, intent_payload([
            step_payload(
                0xFFFFFFFF,
                source_units,
                destination_units,
                source_identity=(0xFFFFFFFFFFFFFFFF, (1 << 128) - 1),
                source_parent=(7, 1),
                destination_parent=(7, 2),
                entry_kind=1,
                scope=1,
                phase=2,
            )
        ], plan=0xFFFFFFFFFFFFFFFF), 0)
        inspected = journal.decode_complete_journal(encoded)
        intent = inspected.records[0]
        step = intent.steps[0]
        self.assertEqual(intent.plan, 0xFFFFFFFFFFFFFFFF)
        self.assertEqual(step.source.units, source_units)
        self.assertEqual(step.destination.units, destination_units)
        self.assertEqual(step.expected_source.volume, 0xFFFFFFFFFFFFFFFF)
        self.assertEqual(step.expected_source.file_id, (1 << 128) - 1)
        self.assertEqual(step.expected_destination_parent.file_id, 2)
        self.assertEqual(step.entry_kind, journal.EntryKind.DIRECTORY)
        self.assertEqual(step.scope, journal.MoveScope.SAME_VOLUME_FILES_ONLY)
        self.assertEqual(step.temporary_phase, journal.TemporaryPhase.FROM_TEMPORARY)
        self.assertEqual(inspected.intent_bytes, encoded)
        self.assertTrue(journal.intent_frame_is_byte_identical(inspected, encoded))
        self.assertFalse(journal.intent_frame_is_byte_identical(inspected, encoded + b"x"))

    def test_header_crc_sequence_and_declared_limits_fail_closed(self) -> None:
        valid = bytearray(one_step_intent())
        mutations = [
            ("magic", slice(0, 4), b"BAD!", journal.ErrorKind.INVALID_MAGIC),
            ("version", slice(4, 6), struct.pack("<H", 1),
             journal.ErrorKind.UNSUPPORTED_VERSION),
            ("flags", slice(7, 8), b"\x01", journal.ErrorKind.INVALID_FLAGS),
            ("sequence", slice(8, 16), struct.pack("<Q", 1),
             journal.ErrorKind.SEQUENCE_MISMATCH),
            ("kind", slice(6, 7), b"\xff", journal.ErrorKind.UNKNOWN_RECORD_KIND),
        ]
        for name, location, replacement, expected in mutations:
            with self.subTest(name=name):
                changed = bytearray(valid)
                changed[location] = replacement
                with self.assertRaises(journal.JournalCodecError) as raised:
                    journal.parse_journal_bytes(bytes(changed), allow_torn_final=True)
                self.assertEqual(raised.exception.kind, expected)

        checksum = bytearray(valid)
        checksum[-1] ^= 1
        with self.assertRaises(journal.JournalCodecError) as raised:
            journal.parse_journal_bytes(bytes(checksum), allow_torn_final=True)
        self.assertEqual(raised.exception.kind, journal.ErrorKind.CHECKSUM_MISMATCH)

        oversized = bytearray(valid[:journal.HEADER_BYTES])
        struct.pack_into("<I", oversized, 16, journal.MAX_JOURNAL_FRAME_BYTES + 1)
        with self.assertRaises(journal.JournalCodecError) as raised:
            journal.parse_journal_bytes(bytes(oversized), allow_torn_final=True)
        self.assertEqual(raised.exception.kind, journal.ErrorKind.FRAME_TOO_LARGE)

        with self.assertRaises(journal.JournalCodecError) as raised:
            journal.decode_complete_journal(b"\0" * (journal.MAX_JOURNAL_FILE_BYTES + 1))
        self.assertEqual(raised.exception.kind, journal.ErrorKind.FILE_TOO_LARGE)

    def test_crc_repaired_unknown_fields_payload_and_counts_are_rejected(self) -> None:
        cases = [
            (frame(1, intent_payload([
                step_payload(0, text_units(r"C:\a"), text_units(r"C:\b"), entry_kind=2)
            ]), 0), journal.ErrorKind.UNKNOWN_FIELD_VALUE),
            (frame(2, transition_payload(0, 2), 0), journal.ErrorKind.UNKNOWN_FIELD_VALUE),
            (frame(2, transition_payload(0, 0) + b"x", 0),
             journal.ErrorKind.INVALID_PAYLOAD),
            (frame(1, struct.pack("<QI", 1, journal.MAX_JOURNAL_STEPS + 1), 0),
             journal.ErrorKind.TOO_MANY_STEPS),
            (frame(1, struct.pack("<QI", 1, 1) + struct.pack("<II", 0,
                    journal.MAX_PATH_UNITS + 1), 0), journal.ErrorKind.PATH_TOO_LONG),
        ]
        for encoded, expected in cases:
            with self.subTest(expected=expected), self.assertRaises(
                    journal.JournalCodecError) as raised:
                journal.parse_journal_bytes(encoded, allow_torn_final=True)
            self.assertEqual(raised.exception.kind, expected)

    def test_transition_duplicates_order_terminal_and_frame_count_are_rejected(self) -> None:
        intent = (1, one_step_intent()[journal.HEADER_BYTES:])
        invalid_streams = [
            stream([intent, (3, transition_payload(0, 0))]),
            stream([intent, (2, transition_payload(0, 0)),
                    (2, transition_payload(0, 0))]),
            stream([intent, (5, b"\x00")]),
            stream([(1, struct.pack("<QI", 1, 0)), (5, b"\x00"), (5, b"\x00")]),
        ]
        for encoded in invalid_streams:
            with self.subTest(length=len(encoded)), self.assertRaises(
                    journal.JournalCodecError) as raised:
                journal.parse_journal_bytes(encoded, allow_torn_final=True)
            self.assertEqual(raised.exception.kind, journal.ErrorKind.INVALID_TRANSITIONS)

        too_many = b"".join(
            frame(5, b"\x00", sequence)
            for sequence in range(journal.MAX_JOURNAL_FRAMES + 1)
        )
        with self.assertRaises(journal.JournalCodecError) as raised:
            journal.decode_complete_journal(too_many)
        self.assertEqual(raised.exception.kind, journal.ErrorKind.TOO_MANY_FRAMES)

    def test_torn_final_frame_matches_rust_prefix_semantics_only(self) -> None:
        intent = one_step_intent()
        prepared = frame(2, transition_payload(0, 0), 1)
        complete = intent + prepared
        for cut in range(1, len(intent)):
            with self.subTest(first_frame_cut=cut), self.assertRaises(
                    journal.JournalCodecError) as raised:
                journal.parse_journal_bytes(intent[:cut], allow_torn_final=True)
            self.assertEqual(raised.exception.kind, journal.ErrorKind.TRUNCATED_FRAME)

        boundary = journal.decode_complete_journal(intent)
        self.assertIsNone(boundary.tail_issue)
        for cut in range(len(intent) + 1, len(complete)):
            with self.subTest(final_frame_cut=cut):
                inspected = journal.parse_journal_bytes(
                    complete[:cut], allow_torn_final=True)
                self.assertEqual(len(inspected.records), 1)
                self.assertEqual(inspected.valid_bytes, len(intent))
                expected = (journal.TailIssue.TRUNCATED_HEADER
                            if cut - len(intent) < journal.HEADER_BYTES
                            else journal.TailIssue.TRUNCATED_PAYLOAD)
                self.assertEqual(inspected.tail_issue, expected)
                with self.assertRaises(journal.JournalCodecError):
                    journal.decode_complete_journal(complete[:cut])

        corrupt = bytearray(complete)
        corrupt[-1] ^= 1
        with self.assertRaises(journal.JournalCodecError) as raised:
            journal.parse_journal_bytes(bytes(corrupt), allow_torn_final=True)
        self.assertEqual(raised.exception.kind, journal.ErrorKind.CHECKSUM_MISMATCH)

    def test_prepared_prefix_preserves_both_mutation_possibilities(self) -> None:
        intent = one_step_intent(plan=9)
        prepared = frame(2, transition_payload(0, 0), 1)
        inspected = journal.decode_complete_journal(intent + prepared)
        self.assertEqual(inspected.replay.status, journal.ReplayStatus.RECOVERY_REQUIRED)
        self.assertEqual(inspected.replay.reason, journal.RecoveryReason.PREPARED_ONLY)
        self.assertEqual(inspected.replay.prepared_step, 0)
        self.assertEqual(inspected.replay.completed_forward, 0)
        self.assertEqual(
            inspected.replay.prepared_mutation_possibilities,
            ("unapplied", "applied"),
        )
        self.assertEqual(
            inspected.transitions,
            (journal.Transition(1, journal.RecordKind.PREPARED, 0,
                                journal.Direction.FORWARD),),
        )


class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.inspection = journal.decode_complete_journal(profile_stream())

    def mutate_step(self, index: int, **changes: object) -> object:
        intent = self.inspection.records[0]
        steps = list(intent.steps)
        steps[index] = replace(steps[index], **changes)
        changed_intent = replace(intent, steps=tuple(steps))
        return replace(self.inspection, records=(changed_intent,))

    def test_fixed_profile_returns_full_crossbinding_material(self) -> None:
        profile = journal.require_vm_automated_direct_profile(self.inspection)
        self.assertEqual(profile.plan, 0xA5A5)
        self.assertEqual(len(profile.bindings), 4096)
        first = profile.bindings[0]
        last = profile.bindings[-1]
        self.assertEqual((first.entry, last.entry), (0, 4095))
        self.assertEqual(first.expected_source.volume, 0x0123456789ABCDEF)
        self.assertEqual(last.expected_source.file_id, 4095 + 0x100)
        self.assertEqual(first.expected_source_parent.file_id, 0x10)
        self.assertEqual(first.expected_destination_parent.file_id, 0x10)

        verbatim = journal.decode_complete_journal(
            profile_stream(parent=r"\\?\C:\fixture"))
        self.assertEqual(
            len(journal.require_vm_automated_direct_profile(verbatim).bindings),
            journal.VM_AUTOMATED_PROFILE_STEPS,
        )

    def test_profile_accepts_rust_supported_torn_tail_after_valid_prefix(self) -> None:
        intent = profile_stream()
        prefix = (
            intent
            + frame(2, transition_payload(0, 0), 1)
            + frame(3, transition_payload(0, 0), 2)
        )
        next_prepared = frame(2, transition_payload(1, 0), 3)
        tails = [
            (next_prepared[:10], journal.TailIssue.TRUNCATED_HEADER),
            (next_prepared[:journal.HEADER_BYTES + 2],
             journal.TailIssue.TRUNCATED_PAYLOAD),
        ]
        for tail, expected_issue in tails:
            with self.subTest(issue=expected_issue):
                raw = prefix + tail
                inspected = journal.parse_journal_bytes(raw, allow_torn_final=True)
                profile = journal.require_vm_automated_direct_profile(inspected)
                self.assertEqual(len(profile.bindings), 4096)
                self.assertEqual(inspected.valid_bytes, len(prefix))
                self.assertEqual(inspected.raw_bytes, len(raw))
                self.assertEqual(inspected.tail_issue, expected_issue)
                self.assertEqual(inspected.replay.completed_forward, 1)
                self.assertEqual(inspected.replay.reason, journal.RecoveryReason.INCOMPLETE)
                with self.assertRaises(journal.JournalCodecError):
                    journal.decode_complete_journal(raw)

    def test_profile_rejects_non_direct_alias_and_identity_splices(self) -> None:
        first = self.inspection.records[0].steps[0]
        cases = [
            {"entry_kind": journal.EntryKind.DIRECTORY},
            {"scope": journal.MoveScope.SAME_VOLUME_FILES_ONLY},
            {"temporary_phase": journal.TemporaryPhase.INTO_TEMPORARY},
            {"destination": journal.Utf16Text(text_units(r"C:\other\b.txt"))},
            {"expected_destination_parent": journal.EntryIdentity(7, 999)},
        ]
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(journal.JournalProfileError):
                journal.require_vm_automated_direct_profile(self.mutate_step(0, **changes))

        duplicate_cases = [
            {"entry": first.entry},
            {"source": first.source},
            {"destination": first.destination},
            {"expected_source": first.expected_source},
        ]
        for changes in duplicate_cases:
            with self.subTest(duplicate=changes), self.assertRaises(journal.JournalProfileError):
                journal.require_vm_automated_direct_profile(self.mutate_step(1, **changes))

        short = replace(
            self.inspection,
            records=(replace(self.inspection.records[0],
                             steps=self.inspection.records[0].steps[:-1]),),
        )
        with self.assertRaisesRegex(journal.JournalProfileError, "exactly 4,096"):
            journal.require_vm_automated_direct_profile(short)

    def test_profile_rejects_non_drive_and_noncanonical_paths(self) -> None:
        source_leaf = "item-00000.txt"
        invalid_sources = [
            fr"\\server\share\{source_leaf}",
            fr"\\.\C:\fixture\{source_leaf}",
            fr"C:fixture\{source_leaf}",
            fr"fixture\{source_leaf}",
            fr"C:\fixture\.\{source_leaf}",
            fr"C:\fixture\..\{source_leaf}",
            r"C:\fixture\source-00000.txt",
        ]
        for source in invalid_sources:
            with self.subTest(source=source), self.assertRaises(journal.JournalProfileError):
                journal.require_vm_automated_direct_profile(
                    self.mutate_step(0, source=journal.Utf16Text(text_units(source))))

    def test_profile_rejects_mixed_parent_text_identity_and_volume(self) -> None:
        other_parent_paths = {
            "source": journal.Utf16Text(text_units(r"D:\other\item-00001.txt")),
            "destination": journal.Utf16Text(
                text_units(r"D:\other\vm-recovered-item-00001.txt")),
        }
        cases = [
            other_parent_paths,
            {
                "expected_source_parent": journal.EntryIdentity(7, 999),
                "expected_destination_parent": journal.EntryIdentity(7, 999),
            },
            {"expected_source": journal.EntryIdentity(8, 0x101)},
        ]
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(journal.JournalProfileError):
                journal.require_vm_automated_direct_profile(self.mutate_step(1, **changes))

    def test_profile_rejects_case_aliases_cross_overlap_and_same_path(self) -> None:
        second = self.inspection.records[0].steps[1]
        cases = [
            {"source": journal.Utf16Text(text_units(r"C:\fixture\ITEM-00000.TXT"))},
            {"destination": journal.Utf16Text(
                text_units(r"C:\fixture\VM-RECOVERED-ITEM-00000.TXT"))},
            {"destination": journal.Utf16Text(text_units(r"C:\fixture\ITEM-00000.TXT"))},
            {"destination": second.source},
        ]
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(journal.JournalProfileError):
                journal.require_vm_automated_direct_profile(self.mutate_step(1, **changes))


class RustOracleCorpusTests(unittest.TestCase):
    def test_python_decodes_rust_generated_v2_corpus(self) -> None:
        command = [
            "cargo", "test", "-p", "darknamer-app", "--test",
            "vm_automated_journal_corpus", "emit_python_oracle_corpus", "--locked",
            "--", "--exact", "--nocapture",
        ]
        completed = subprocess.run(
            command,
            cwd=REPOSITORY,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
        )
        prefix = "DARKRENAMER_VM_JOURNAL_CORPUS\t"
        cases = {}
        for line in completed.stdout.splitlines():
            if line.startswith(prefix):
                _, name, encoded = line.split("\t")
                cases[name] = bytes.fromhex(encoded)
        self.assertEqual(
            set(cases),
            {"intent-extremes", "prepared-prefix", "rollback-prepared",
             "committed", "rollback-retry"},
        )

        extremes = journal.decode_complete_journal(cases["intent-extremes"])
        extreme_intent = extremes.records[0]
        self.assertEqual(extreme_intent.plan, 0xFFFFFFFFFFFFFFFF)
        self.assertEqual(extreme_intent.steps[0].source.units,
                         (0, 0xD800, 0x61, 0xDC00, 0xFFFF))
        self.assertEqual(extreme_intent.steps[0].expected_source.file_id, (1 << 128) - 1)
        self.assertEqual(extreme_intent.steps[1].entry, 0xFFFFFFFF)
        self.assertEqual(extreme_intent.steps[1].entry_kind, journal.EntryKind.DIRECTORY)

        prepared = journal.decode_complete_journal(cases["prepared-prefix"])
        self.assertEqual(prepared.replay.reason, journal.RecoveryReason.PREPARED_ONLY)
        self.assertEqual(prepared.replay.completed_forward, 2)
        self.assertEqual(prepared.replay.prepared_step, 2)
        self.assertEqual(prepared.replay.prepared_direction, journal.Direction.FORWARD)
        self.assertEqual(prepared.replay.prepared_mutation_possibilities,
                         ("unapplied", "applied"))
        self.assertTrue(journal.intent_frame_is_byte_identical(
            prepared, cases["prepared-prefix"][:prepared.frames[0].end]))

        rollback_prepared = journal.decode_complete_journal(cases["rollback-prepared"])
        self.assertEqual(rollback_prepared.replay.reason,
                         journal.RecoveryReason.PREPARED_ONLY)
        self.assertEqual(rollback_prepared.replay.completed_forward, 3)
        self.assertEqual(rollback_prepared.replay.completed_rollback, 1)
        self.assertEqual(rollback_prepared.replay.prepared_step, 1)
        self.assertEqual(rollback_prepared.replay.prepared_direction,
                         journal.Direction.ROLLBACK)

        committed = journal.decode_complete_journal(cases["committed"])
        self.assertEqual(committed.replay.status, journal.ReplayStatus.CLEAN)
        self.assertEqual(len(committed.frames), 6)
        self.assertEqual(committed.replay.completed_forward, 2)

        rollback = journal.decode_complete_journal(cases["rollback-retry"])
        self.assertEqual(rollback.replay.status, journal.ReplayStatus.CLEAN)
        self.assertEqual(len(rollback.transitions), 10)


if __name__ == "__main__":
    unittest.main()
