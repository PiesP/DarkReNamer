#!/usr/bin/env python3
"""Journal-to-filesystem joins, with adversarial full-identity mutations."""

from copy import deepcopy
import hashlib
import struct
import unittest
import zlib

from darkrenamer_tooling.evidence.archive import EvidenceError
from darkrenamer_tooling.evidence.recovery import (
    verify_crash_prefix, verify_recovery_invariance, verify_recovery_export,
    verify_intent_candidate,
)


VOLUME = 0xAABBCCDD11223344
PARENT = 1 << 120
ROOT = r"C:\fixture"


def identity(index):
    return struct.pack("<Q", VOLUME) + index.to_bytes(16, "little")


def text(value):
    encoded = value.encode("utf-16-le")
    return struct.pack("<I", len(encoded) // 2) + encoded


def frame(kind, sequence, payload):
    header = struct.pack("<HBBQI", 2, kind, 0, sequence, len(payload))
    return b"DRJ1" + header + struct.pack("<I", zlib.crc32(header + payload)) + payload


class RecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.initial = []
        steps = []
        for index in range(4096):
            name = f"item-{index:05}.txt"
            file_id = (1 << 96) + index
            steps.append(struct.pack("<I", index) + text(ROOT + "\\" + name) +
                         text(ROOT + "\\vm-recovered-" + name) + identity(file_id) +
                         identity(PARENT) * 2 + bytes((0, 0, 0)))
            cls.initial.append({"name": name, "kind": "file", "bytes": 65,
                                "content_sha256": hashlib.sha256(name.encode()).hexdigest(),
                                "file_identity": {"volume_serial": f"{VOLUME:016x}", "file_id": f"{file_id:032x}"}})
        cls.initial.append({"name": "sentinel.bin", "kind": "file", "bytes": 9,
                            "content_sha256": hashlib.sha256(b"sentinel\n").hexdigest(),
                            "file_identity": {"volume_serial": f"{VOLUME:016x}", "file_id": f"{PARENT + 1:032x}"}})
        cls.intent = frame(1, 0, struct.pack("<QI", 42, 4096) + b"".join(steps))
        cls.completed = cls.intent + frame(2, 1, struct.pack("<IB", 0, 0)) + frame(3, 2, struct.pack("<IB", 0, 0))
        cls.prepared = cls.completed + frame(2, 3, struct.pack("<IB", 1, 0))
        cls.parent = {"volume_serial": f"{VOLUME:016x}", "file_id": f"{PARENT:032x}"}

    def partial(self, count):
        rows = deepcopy(self.initial)
        for row in rows[:count]:
            row["name"] = "vm-recovered-" + row["name"]
        return rows

    def verify(self, raw=None, partial=None, **kwargs):
        return verify_crash_prefix(self.prepared if raw is None else raw,
                                   kwargs.get("initial", self.initial),
                                   self.partial(1) if partial is None else partial,
                                   fixture_root=kwargs.get("fixture_root", ROOT),
                                   root_identity=kwargs.get("root_identity", self.parent))

    def test_completed_and_pending_physical_states(self):
        self.assertEqual(self.verify(self.completed).changed_files, 1)
        self.assertEqual(self.verify(partial=self.partial(1)).changed_files, 1)
        self.assertEqual(self.verify(partial=self.partial(2)).changed_files, 2)

    def test_supported_tail_preserves_raw_length_valid_length_and_kind(self):
        following = frame(3, 4, struct.pack("<IB", 1, 0))
        for cut, kind in ((10, "truncated-header"), (26, "truncated-payload")):
            raw = self.prepared + following[:cut]
            result = self.verify(raw, self.partial(2))
            self.assertEqual((result.raw_bytes, result.valid_bytes, result.tail_kind),
                             (len(raw), len(self.prepared), kind))

    def test_root_path_and_all_128_identity_bits_are_bound(self):
        for kwargs in ({"fixture_root": r"C:\different"},
                       {"root_identity": {**self.parent, "file_id": "0" * 32}},
                       {"root_identity": {**self.parent, "volume_serial": "0000000011223344"}}):
            with self.assertRaises(EvidenceError):
                self.verify(**kwargs)
        altered = deepcopy(self.initial)
        altered[0]["file_identity"]["file_id"] = "0" * 31 + "1"
        with self.assertRaises(EvidenceError):
            self.verify(initial=altered)

    def test_source_identity_splice_cannot_be_hidden_in_both_snapshots(self):
        initial = deepcopy(self.initial)
        partial = self.partial(1)
        for snapshot in (initial, partial):
            snapshot[0]["file_identity"]["volume_serial"] = "0000000011223344"
        with self.assertRaises(EvidenceError):
            self.verify(initial=initial, partial=partial)

    def test_no_mutation_complete_mutation_and_sentinel_changes_fail(self):
        for partial in (self.initial, self.partial(4096)):
            with self.assertRaises(EvidenceError):
                self.verify(partial=partial)
        partial = self.partial(1)
        partial[-1]["name"] = "renamed-sentinel.bin"
        with self.assertRaises(EvidenceError):
            self.verify(partial=partial)

    def test_failure_and_rollback_history_cannot_pose_as_forward_crash(self):
        failed = self.intent + frame(2, 1, struct.pack("<IB", 0, 0)) + frame(4, 2, struct.pack("<IB", 0, 0))
        rollback = self.completed + frame(2, 3, struct.pack("<IB", 0, 1))
        for raw in (failed, rollback):
            with self.assertRaises(EvidenceError):
                self.verify(raw)

    def test_startup_and_default_cancel_preserve_partial_before_explicit_restore(self):
        partial = self.partial(1)
        verify_recovery_invariance(self.initial, partial, partial, partial, partial, self.initial)
        for index in range(3):
            snapshots = [partial, partial, partial]
            snapshots[index] = self.initial
            with self.assertRaises(EvidenceError):
                verify_recovery_invariance(self.initial, partial, *snapshots, self.initial)

    def test_export_preserves_torn_bytes_and_rejects_truncation(self):
        raw = self.prepared + b"DRJ1"
        verify_recovery_export(raw, raw, raw)
        for exported, retained in ((self.prepared, raw), (raw, self.prepared), (raw + b"x", raw)):
            with self.assertRaises(EvidenceError):
                verify_recovery_export(raw, exported, retained)

    def test_authentic_intent_frame_is_preserved_across_cancel_and_relaunch(self):
        verify_intent_candidate(self.prepared, self.intent, self.intent, self.intent)
        for index in range(3):
            values = [self.intent] * 3
            values[index] += b"x"
            with self.assertRaises(EvidenceError):
                verify_intent_candidate(self.prepared, *values)

    def test_clean_journal_cannot_source_an_interrupted_intent_candidate(self):
        rolled_back = self.intent + frame(5, 1, b"\x01")
        committed_frames = [self.intent]
        for index in range(4096):
            committed_frames.extend((frame(2, index * 2 + 1, struct.pack("<IB", index, 0)),
                                     frame(3, index * 2 + 2, struct.pack("<IB", index, 0))))
        committed_frames.append(frame(5, 8193, b"\x00"))
        for raw in (rolled_back, b"".join(committed_frames)):
            with self.assertRaises(EvidenceError):
                verify_intent_candidate(raw, self.intent, self.intent, self.intent)


if __name__ == "__main__":
    unittest.main()
