#!/usr/bin/env python3
"""Adversarial joins for the complete raw recovery profile."""

from copy import deepcopy
import hashlib
import json
import unittest

from darkrenamer_tooling.campaign.recovery import verify_recovery_execution
from darkrenamer_tooling.evidence.archive import EvidenceError
from recovery_profile_fixture import (
    RUN_PREFIX, PRIVATE_ROOT, RESULT_PATH, SCREENSHOT_PATH,
    encode, png, Reader, target, build_crash, build_worker,
)


def resign(reader, result, relative, value, references):
    path = PRIVATE_ROOT + "/" + relative
    data = value if type(value) is bytes else encode(value)
    reader.files[path] = data
    digest = hashlib.sha256(data).hexdigest()
    for reference in references:
        reference["bytes"], reference["sha256"] = len(data), digest
    index_path = PRIVATE_ROOT + "/private-index.json"
    index = json.loads(reader.files[index_path])
    row = next(row for row in index["files"] if row["file"] == relative)
    row["bytes"], row["sha256"] = len(data), digest
    index_data = encode(index)
    reader.files[index_path] = index_data
    result["private_evidence"]["bytes"] = len(index_data)
    result["private_evidence"]["sha256"] = hashlib.sha256(index_data).hexdigest()

class RecoveryProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.crash = build_crash()
        cls.cancel = build_worker(False)
        cls.close = build_worker(True)

    def crash_copy(self):
        reader, result, bundle, transport = self.crash
        return Reader(dict(reader.files)), deepcopy(result), deepcopy(bundle), deepcopy(transport)

    def test_complete_crash_group_derives_three_targets(self):
        reader, result, bundle, transport = self.crash_copy()
        for relative in ("interrupted-active.drj", "active-after-default-cancel.drj",
                         "active-after-export.drj"):
            self.assertEqual(reader.files[PRIVATE_ROOT + "/recovery-export.drj"],
                             reader.files[PRIVATE_ROOT + "/" + relative])
        self.assertEqual(verify_recovery_execution(reader, result, bundle, transport, target(),
                                                   run_prefix=RUN_PREFIX, result_path=RESULT_PATH),
                         {"process-crash", "recovery-export", "intent-only-discard"})

    def test_export_requires_fixed_indexed_member_and_reference_pins(self):
        reader, result, bundle, transport = self.crash_copy()
        fixed_path = PRIVATE_ROOT + "/recovery-export.drj"
        old_relative = "recovery-export/active.drj.retained"
        reader.files[PRIVATE_ROOT + "/" + old_relative] = reader.files.pop(fixed_path)
        index_path = PRIVATE_ROOT + "/private-index.json"
        index = reader.json(index_path)
        next(row for row in index["files"] if row["file"] == "recovery-export.drj")["file"] = old_relative
        index_data = encode(index)
        reader.files[index_path] = index_data
        result["private_evidence"]["bytes"] = len(index_data)
        result["private_evidence"]["sha256"] = hashlib.sha256(index_data).hexdigest()
        with self.assertRaisesRegex(EvidenceError, "fixed indexed member"):
            verify_recovery_execution(reader, result, bundle, transport, target(),
                                      run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

        for field, value, message in (
            ("boundary", "other", "wrong semantic boundary"),
            ("sha256", "0" * 64, "mock digest reference is absent"),
            ("bytes", 1, "mock digest reference is absent"),
        ):
            reader, result, bundle, transport = self.crash_copy()
            result["recovery_export"]["raw"][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(EvidenceError, message):
                verify_recovery_execution(reader, result, bundle, transport, target(),
                                          run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_crash_job_receipt_is_complete_private_and_lifecycle_bound(self):
        for mutation in ("missing-row", "wrong-pid", "wrong-nonce", "uncaptured"):
            reader, result, bundle, transport = self.crash_copy()
            if mutation == "missing-row":
                result["process_job_cleanup"].pop()
            elif mutation == "wrong-pid":
                result["process_job_cleanup"][0]["pid"] += 1
            elif mutation == "wrong-nonce":
                result["process_job_cleanup"][0]["termination_exit_code"] += 1
            else:
                result["process_job_cleanup"][0]["capture_complete"] = False
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(),
                                          run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

        reader, result, bundle, transport = self.crash_copy()
        relative = "process-01-crash-stop.json"
        path = PRIVATE_ROOT + "/" + relative
        changed = json.loads(reader.files[path])
        changed["termination"]["termination_exit_code"] += 1
        resign(reader, result, relative, changed, [result["process_crash"]["processes"][1]])
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(),
                                      run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_worker_lifecycle_must_match_the_complete_job_ledger(self):
        reader, result, bundle, transport, prefix = self.cancel
        result = deepcopy(result)
        result["process_job_cleanup"][0]["pid"] += 1
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(Reader(dict(reader.files)), result, deepcopy(bundle),
                                      deepcopy(transport), target(), run_prefix=prefix)

    def test_process_lifecycle_matches_every_immutable_field_and_type(self):
        mutations = {
            "pid": 9999,
            "session_id": 9999,
            "start_time_utc_ticks": "1",
            "executable_path": r"C:\other\DarkReNamer.exe",
            "executable_sha256": "0" * 64,
        }
        for boundary, reference_index in (("started", 0), ("crash-stop", 1)):
            for field, value in mutations.items():
                reader, result, bundle, transport = self.crash_copy()
                relative = f"process-01-{boundary}.json"
                raw = reader.json(PRIVATE_ROOT + "/" + relative)
                raw["lifecycle"][field] = value
                resign(reader, result, relative, raw, [result["process_crash"]["processes"][reference_index]])
                with self.subTest(boundary=boundary, field=field), self.assertRaises(EvidenceError):
                    verify_recovery_execution(reader, result, bundle, transport, target(),
                                              run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

        for boundary, section, reference_index in (
            ("started", "lifecycle", 0), ("crash-stop", "binding", 1),
        ):
            reader, result, bundle, transport = self.crash_copy()
            relative = f"process-01-{boundary}.json"
            raw = reader.json(PRIVATE_ROOT + "/" + relative)
            raw[section]["pid"] = float(raw[section]["pid"])
            resign(reader, result, relative, raw, [result["process_crash"]["processes"][reference_index]])
            with self.subTest(boundary=boundary, section=section), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(),
                                          run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_two_worker_modes_derive_only_their_own_targets(self):
        for fixture, expected in ((self.cancel, "worker-cancellation"), (self.close, "worker-close")):
            reader, result, bundle, transport, prefix = fixture
            with self.subTest(expected=expected):
                self.assertEqual(verify_recovery_execution(Reader(dict(reader.files)), deepcopy(result),
                                                           deepcopy(bundle), deepcopy(transport), target(),
                                                           run_prefix=prefix), {expected})

    def test_default_cancel_requires_actual_safe_focus(self):
        reader, result, bundle, transport = self.crash_copy()
        ref = result["process_crash"]["actions"]["default_cancel"]
        raw = reader.json(PRIVATE_ROOT + "/startup-default-cancel-action.json")
        raw["target"]["focused"] = False
        resign(reader, result, "startup-default-cancel-action.json", raw, [ref])
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_default_cancel_requires_raw_bound_action(self):
        reader, result, bundle, transport = self.crash_copy()
        result["process_crash"]["actions"]["default_cancel"]["boundary"] = "forged"
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_full_identity_state_mutation_fails_even_when_summary_is_unchanged(self):
        reader, result, bundle, transport = self.crash_copy()
        ref = result["process_crash"]["raw_states"]["default_cancel"]
        raw = reader.json(PRIVATE_ROOT + "/state-default-cancel.json")
        raw["fixture_entries"][0]["file_identity"]["file_id"] = "0" * 32
        resign(reader, result, "state-default-cancel.json", raw, [ref])
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_process_pair_role_and_exit_time_are_not_producer_flags(self):
        for mutation in ("role", "time", "exit-code"):
            reader, result, bundle, transport = self.crash_copy()
            ref = result["process_crash"]["processes"][1]
            raw = reader.json(PRIVATE_ROOT + "/process-01-crash-stop.json")
            if mutation == "role":
                raw["binding"]["role"] = "other"
            elif mutation == "time":
                raw["observed_utc_ticks"] = "1"
            else:
                raw["lifecycle"]["exit_code"] = 0
            resign(reader, result, "process-01-crash-stop.json", raw, [ref])
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_export_and_intent_must_reuse_interrupted_reference_and_bytes(self):
        for mutation in ("source", "candidate"):
            reader, result, bundle, transport = self.crash_copy()
            if mutation == "source":
                result["recovery_export"]["source_active_journal"] = {
                    **result["recovery_export"]["source_active_journal"], "boundary": "other"}
            else:
                ref = result["intent_only_candidate_discard"]["candidate"]["after_relaunch"]
                resign(reader, result, "intent-after-relaunch.drj",
                       reader.files[PRIVATE_ROOT + "/intent-after-relaunch.drj"] + b"x", [ref])
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_intent_lock_and_explicit_discard_observations_are_required(self):
        for mutation in ("locked", "action"):
            reader, result, bundle, transport = self.crash_copy()
            if mutation == "locked":
                ref = result["intent_only_candidate_discard"]["lock_states"]["post_cancel"]
                raw = reader.json(PRIVATE_ROOT + "/intent-post-cancel-lock.json")
                raw["controls"]["add_files"]["enabled"] = True
                resign(reader, result, "intent-post-cancel-lock.json", raw, [ref])
            else:
                ref = result["intent_only_candidate_discard"]["actions"]["confirm_discard"]
                raw = reader.json(PRIVATE_ROOT + "/intent-discard-confirm-action.json")
                raw["target"]["automation_id"] = "CommandButton_2"
                resign(reader, result, "intent-discard-confirm-action.json", raw, [ref])
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_worker_witness_requires_actual_names_full_identity_and_lifetime(self):
        reader0, result0, bundle0, transport0, prefix = self.cancel
        for mutation in ("name", "identity", "time"):
            reader = Reader(dict(reader0.files))
            result, bundle, transport = deepcopy(result0), deepcopy(bundle0), deepcopy(transport0)
            root = prefix + "private/recovery-raw-test"
            relative = "worker-workercancellation-partial-witness.json"
            raw = reader.json(root + "/" + relative)
            if mutation == "name": raw["entries"][0]["name"] = "item-00000.txt"
            elif mutation == "identity": raw["entries"][0]["file_identity"]["file_id"] = "f" * 32
            else: raw["entries"][0]["observed_utc_ticks"] = "1"
            data = encode(raw)
            reader.files[root + "/" + relative] = data
            ref = result["worker_cancellation"]["partial_witness"]
            ref["bytes"], ref["sha256"] = len(data), hashlib.sha256(data).hexdigest()
            index_path = root + "/private-index.json"
            index = reader.json(index_path)
            row = next(row for row in index["files"] if row["file"] == relative)
            row["bytes"], row["sha256"] = ref["bytes"], ref["sha256"]
            index_data = encode(index)
            reader.files[index_path] = index_data
            result["private_evidence"]["bytes"] = len(index_data)
            result["private_evidence"]["sha256"] = hashlib.sha256(index_data).hexdigest()
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=prefix)

    def test_private_index_extra_file_and_cleanup_residue_fail(self):
        reader, result, bundle, transport = self.crash_copy()
        index_path = PRIVATE_ROOT + "/private-index.json"
        index = reader.json(index_path)
        extra = b"unused"
        reader.files[PRIVATE_ROOT + "/unused.json"] = extra
        index["files"].append({"file": "unused.json", "bytes": len(extra),
                               "sha256": hashlib.sha256(extra).hexdigest()})
        data = encode(index)
        reader.files[index_path] = data
        result["private_evidence"] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                      "file_count": len(index["files"])}
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX, result_path=RESULT_PATH)
        reader, result, bundle, transport = self.crash_copy()
        transport["raw_cleanup"]["scheduled_task_present"] = True
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_recovery_screenshot_requires_stable_owned_task_dialog(self):
        for mutation in ("capture_hwnd", "foreign_class", "foreign_pid", "foreign_session"):
            reader, result, bundle, transport = self.crash_copy()
            reference = result["process_crash"]["foreground_observations"]
            raw = reader.json(PRIVATE_ROOT + "/foreground-observations.json")
            observation = raw["observations"][0]
            if mutation == "capture_hwnd":
                observation["capture_complete"]["hwnd"] += 1
            elif mutation == "foreign_class":
                observation["final"]["window_class"] = "DarkReNamerWindow"
                observation["capture_complete"]["window_class"] = "DarkReNamerWindow"
            elif mutation == "foreign_pid":
                observation["final"]["process_id"] += 1
                observation["capture_complete"]["process_id"] += 1
            else:
                observation["final"]["session_id"] += 1
                observation["capture_complete"]["session_id"] += 1
            resign(reader, result, "foreground-observations.json", raw, [reference])
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(),
                                          run_prefix=RUN_PREFIX, result_path=RESULT_PATH)

    def test_recovery_screenshot_requires_indexed_nonuniform_exact_dimensions(self):
        for mutation in ("missing_reference", "missing_file", "wrong_digest", "dimensions", "uniform"):
            reader, result, bundle, transport = self.crash_copy()
            screenshot = result["process_crash"]["recovery_screenshot"]
            if mutation == "missing_reference":
                del result["process_crash"]["recovery_screenshot"]
            elif mutation == "missing_file":
                del reader.files[SCREENSHOT_PATH]
            elif mutation == "wrong_digest":
                screenshot["sha256"] = "0" * 64
            elif mutation == "dimensions":
                screenshot["width"] += 1
            else:
                data = png(uniform=True)
                reader.files[SCREENSHOT_PATH] = data
                screenshot["sha256"] = hashlib.sha256(data).hexdigest()
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(),
                                          run_prefix=RUN_PREFIX, result_path=RESULT_PATH)


if __name__ == "__main__":
    unittest.main()
