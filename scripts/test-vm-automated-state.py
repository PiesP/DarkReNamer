#!/usr/bin/env python3
"""Failure-injection tests for raw inventory predicates, without Windows."""

from copy import deepcopy
import unittest

from vm_automated_evidence import EvidenceError
from vm_automated_state import (
    Identity, clean_journal_inventory, core_rename_checkpoints, fixture_inventory,
    interrupted_inventory, restored_inventory,
)


def file_row(name="source.txt", index=1, *, full=False):
    row = {"name": name, "kind": "file", "bytes": 65, "content_sha256": "a" * 64}
    if full:
        row["file_identity"] = {"volume_serial": "aabbccdd11223344", "file_id": f"{index:032x}"}
    else:
        row["file_identity_sha256"] = f"{index:064x}"
    return row


def core():
    rows = []
    for phase in ("initial", "after_cancel", "after_apply", "post_close"):
        name = "destination.txt" if phase in {"after_apply", "post_close"} else "source.txt"
        rows.append({"phase": phase, "fixture_entries": [file_row(name)],
                     "journal_entries": [{"name": "runtime.lock", "kind": "file", "bytes": 0}]})
    return rows


class StateTests(unittest.TestCase):
    def validate_core(self, rows):
        return core_rename_checkpoints(rows, source_name="source.txt", destination_name="destination.txt")

    def test_core_complete_unchanged_cancel_and_renamed_apply(self):
        self.assertEqual(set(self.validate_core(core())), {"destination.txt"})

    def test_core_rejects_missing_duplicate_and_reordered_phases(self):
        for rows in (core()[:-1], core() + [core()[0]], list(reversed(core()))):
            with self.subTest(rows=rows), self.assertRaises(EvidenceError):
                self.validate_core(rows)

    def test_every_checkpoint_rejects_extra_files_and_content_or_identity_change(self):
        for checkpoint in range(4):
            for field, value in (("content_sha256", "b" * 64),
                                 ("file_identity_sha256", "c" * 64), ("bytes", 66)):
                rows = core()
                rows[checkpoint]["fixture_entries"][0][field] = value
                with self.subTest(checkpoint=checkpoint, field=field), self.assertRaises(EvidenceError):
                    self.validate_core(rows)
            rows = core()
            rows[checkpoint]["fixture_entries"].append(file_row("extra.txt", 2))
            with self.assertRaises(EvidenceError):
                self.validate_core(rows)

    def test_core_rejects_summary_only_and_boolean_sizes(self):
        rows = core()
        rows[1] = {"phase": "after_cancel", "unchanged": True}
        with self.assertRaises(EvidenceError):
            self.validate_core(rows)
        rows = core()
        rows[0]["fixture_entries"][0]["bytes"] = True
        with self.assertRaises(EvidenceError):
            self.validate_core(rows)

    def test_journal_requires_complete_ordinary_zero_byte_lock_inventory(self):
        self.assertEqual(clean_journal_inventory([]), ())
        lock = {"name": "runtime.lock", "kind": "file", "bytes": 0}
        for value in ([lock, lock], [{**lock, "bytes": False}], [{**lock, "bytes": 1}],
                      [{**lock, "kind": "directory"}], [{**lock, "name": "active.journal"}],
                      [{**lock, "name": "candidate.journal"}], {"residue_count": 0}):
            with self.subTest(value=value), self.assertRaises(EvidenceError):
                clean_journal_inventory(value)

    def test_cancel_requires_unchanged_runtime_lock_presence(self):
        rows = core()
        rows[1]["journal_entries"] = []
        with self.assertRaises(EvidenceError):
            self.validate_core(rows)

    def test_full_identity_preserves_upper_volume_and_file_id_bits(self):
        row = file_row(full=True)
        row["file_identity"]["file_id"] = "ffffffff000000000000000000000001"
        state = fixture_inventory([row], full_identity=True)["source.txt"]
        self.assertEqual(state.identity, Identity(0xaabbccdd11223344, 0xffffffff000000000000000000000001))
        for field, value in (("volume_serial", "11223344"), ("file_id", "0000000000000001"),
                             ("volume_serial", 1), ("file_id", "G" * 32)):
            changed = deepcopy(row)
            changed["file_identity"][field] = value
            with self.assertRaises(EvidenceError):
                fixture_inventory([changed], full_identity=True)

    def test_fixture_rejects_aliases_links_unsafe_names_and_shared_ids(self):
        for name in ("../source", "a/b", "a\\b", "x:stream", "NUL.txt", "file.", "file ", "\ud800"):
            with self.subTest(name=name), self.assertRaises(EvidenceError):
                fixture_inventory([file_row(name)], full_identity=False)
        for rows in ([file_row(), file_row("SOURCE.TXT", 2)],
                     [file_row(), file_row("other.txt")], [{**file_row(), "kind": "symlink"}]):
            with self.assertRaises(EvidenceError):
                fixture_inventory(rows, full_identity=False)

    def recovery(self):
        initial = [file_row(f"source-{i}.txt", i + 1, full=True) for i in range(3)]
        initial.append(file_row("sentinel.txt", 4, full=True))
        renames = [(f"source-{i}.txt", f"destination-{i}.txt") for i in range(3)]
        return initial, renames

    def partial(self, initial, count):
        partial = deepcopy(initial)
        for row in partial[:count]:
            row["name"] = row["name"].replace("source-", "destination-")
        return partial

    def test_pending_prepared_may_be_before_or_after_actual_rename(self):
        initial, renames = self.recovery()
        for count in (1, 2):
            self.assertEqual(interrupted_inventory(initial, self.partial(initial, count),
                             renames=renames, protected_names=("sentinel.txt",), completed=1, prepared=1), count)

    def test_completed_prefix_and_first_pending_actual_mutation(self):
        initial, renames = self.recovery()
        partial = self.partial(initial, 1)
        self.assertEqual(interrupted_inventory(initial, partial, renames=renames, protected_names=("sentinel.txt",),
                         completed=1, prepared=None), 1)
        self.assertEqual(interrupted_inventory(initial, partial, renames=renames, protected_names=("sentinel.txt",),
                         completed=0, prepared=0), 1)

    def test_partial_requires_real_incomplete_mutation_and_unchanged_sentinel(self):
        initial, renames = self.recovery()
        cases = [(initial, 0, None), (self.partial(initial, 3), 3, None),
                 (self.partial(initial, 2), 1, None)]
        altered = self.partial(initial, 1)
        altered[-1]["content_sha256"] = "b" * 64
        cases.append((altered, 1, None))
        for partial, completed, prepared in cases:
            with self.assertRaises(EvidenceError):
                interrupted_inventory(initial, partial, renames=renames, protected_names=("sentinel.txt",),
                                      completed=completed, prepared=prepared)

    def test_partial_rejects_boolean_counts_aliases_and_bad_pending_step(self):
        initial, renames = self.recovery()
        for schedule, completed, prepared in ((renames, True, None), (renames, 1, True),
                                            (renames, 1, 2), (renames[:1] * 3, 1, None),
                                            ([("source-0.txt", "sentinel.txt")] + renames[1:], 1, None)):
            with self.assertRaises(EvidenceError):
                interrupted_inventory(initial, self.partial(initial, 1), renames=schedule, protected_names=("sentinel.txt",),
                                      completed=completed, prepared=prepared)

    def test_sentinel_cannot_be_injected_into_journal_schedule(self):
        initial, renames = self.recovery()
        malicious = [("sentinel.txt", "renamed-sentinel.txt"), *renames[1:]]
        partial = deepcopy(initial)
        partial[-1]["name"] = "renamed-sentinel.txt"
        with self.assertRaises(EvidenceError):
            interrupted_inventory(initial, partial, renames=malicious, completed=1,
                                  prepared=None, protected_names=("sentinel.txt",))
        with self.assertRaises(EvidenceError):
            interrupted_inventory(initial, self.partial(initial, 1), renames=renames[:2],
                                  completed=1, prepared=None, protected_names=("sentinel.txt",))

    def test_rollback_checks_whole_inventory_and_high_identity_bits(self):
        initial, _ = self.recovery()
        self.assertEqual(len(restored_inventory(initial, initial, expected_count=4)), 4)
        changed = deepcopy(initial)
        changed[0]["file_identity"]["volume_serial"] = "0000000011223344"
        for rows in (initial[:-1], self.partial(initial, 1), changed):
            with self.assertRaises(EvidenceError):
                restored_inventory(initial, rows, expected_count=4)


if __name__ == "__main__":
    unittest.main()
