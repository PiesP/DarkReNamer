#!/usr/bin/env python3
"""Adversarial joins for the complete raw recovery profile."""

from copy import deepcopy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

from vm_automated_evidence import EvidenceError
from vm_automated_recovery_profile import verify_recovery_execution


ROOT = r"C:\fixture"
RUN_PREFIX = "runs/process-crash/"
PRIVATE_ROOT = RUN_PREFIX + "private/recovery-raw-test"
EMPTY_SHA = hashlib.sha256(b"").hexdigest()


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


class Reader:
    def __init__(self, files):
        self.files = files

    def bytes(self, path, maximum=64 * 1024 * 1024):
        if path not in self.files or len(self.files[path]) > maximum:
            raise EvidenceError("missing or oversized mock evidence")
        return self.files[path]

    def json(self, path):
        return json.loads(self.bytes(path))

    def digest_reference(self, reference, *, prefix):
        matches = [path for path, data in self.files.items()
                   if path.startswith(prefix) and len(data) == reference["bytes"] and
                   hashlib.sha256(data).hexdigest() == reference["sha256"]]
        if not matches:
            raise EvidenceError("mock digest reference is absent")
        return sorted(matches)[0]


class RawBuilder:
    def __init__(self, prefix=RUN_PREFIX):
        self.prefix = prefix
        self.root = prefix + "private/recovery-raw-test"
        self.files = {}
        self.rows = []

    def add(self, relative, value, boundary):
        data = value if type(value) is bytes else encode(value)
        self.files[self.root + "/" + relative] = data
        digest = hashlib.sha256(data).hexdigest()
        self.rows.append({"file": relative, "bytes": len(data), "sha256": digest})
        return {"bytes": len(data), "sha256": digest, "boundary": boundary}

    def finish(self, result):
        index = {"schema_version": 1,
                 "classification": "private-path-bearing-raw-recovery-evidence",
                 "files": sorted(self.rows, key=lambda row: row["file"])}
        data = encode(index)
        self.files[self.root + "/private-index.json"] = data
        result["private_evidence"] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                      "file_count": len(self.rows)}
        return Reader(self.files), result


def fixture_module():
    path = Path(__file__).with_name("test-vm-automated-recovery.py")
    spec = importlib.util.spec_from_file_location("existing_recovery_fixtures", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    module.RecoveryTests.setUpClass()
    return module.RecoveryTests


def target():
    return {"scale_percent": 200, "hwnd_dpi": 192, "text_scale_percent": 100,
            "contrast": "normal", "desktop_width": 3840, "desktop_height": 2160}


def bundle_and_result(mode):
    application = {"file": "DarkReNamer.exe", "sha256": "b" * 64}
    product = {"source_sha": "a" * 40, "source_state": "clean", "candidate": {},
               "application": application, "provenance": {}}
    harness = {"source_sha": "a" * 40, "source_state": "clean",
               "runner": {"file": "windows-vm-guest.ps1", "sha256": "c" * 64},
               "observers": {"ui": {}, "recovery": {"file": "windows-vm-recovery-acceptance.ps1",
                                                        "sha256": "d" * 64}},
               "launcher": {}, "controller": {}, "validators": {}}
    bundle = {"schema_version": 2, "lane": "candidate-gui-only", "target": "x86_64-pc-windows-msvc",
              "product": product, "harness": harness, "test_binaries": []}
    result = {"schema_version": 2, "lane": bundle["lane"], "product": product, "harness": harness,
              "observer_role": "recovery", "runner_sha256": harness["runner"]["sha256"],
              "application": application, "observer": harness["observers"]["recovery"],
              "selected_mode": mode,
              "process_crash": {}, "worker_cancellation": {}, "worker_close": {},
              "recovery_export": {}, "intent_only_candidate_discard": {},
              "raw_cleanup": {"owned_processes_after": [],
                              "runtime_root_after": {"exists": False, "entries": []},
                              "journal_after": {"entries": []}}}
    return bundle, result


def environment(pid, session, root_identity, hwnd):
    return {"schema_version": 1,
            "platform": {"os_product_name": "Windows 11 Pro", "display_version": "24H2",
                         "build_number": 26100, "architecture": "x86_64", "product_type": 1},
            "process": {"pid": pid, "session_id": session, "is_elevated": False},
            "desktop": {"input_desktop_active": True, "locked": False},
            "fixture_volume": {"filesystem": "NTFS", "root_path": ROOT,
                               "root_identity": root_identity},
            "target_display": {"hwnd": hwnd, "process_id": pid, "session_id": session,
                               "dpi_x": 192, "dpi_y": 192,
                               "monitor_rect": {"left": 0, "top": 0, "right": 3840, "bottom": 2160},
                               "work_rect": {"left": 0, "top": 0, "right": 3840, "bottom": 2100},
                               "window_rect": {"left": 10, "top": 10, "right": 1200, "bottom": 900},
                               "text_scale_percent": 100, "high_contrast_flags": 0}}


def state(builder, relative, boundary, entries, root_identity):
    return builder.add(relative, {"schema_version": 1, "boundary": boundary, "fixture_root": ROOT,
                                  "root_identity": root_identity,
                                  "fixture_entries": deepcopy(entries)}, boundary)


def journal_inventory(builder, relative, boundary, name=None, data=None):
    rows = [] if name is None else [{"name": name, "kind": "file", "bytes": len(data),
                                     "sha256": hashlib.sha256(data).hexdigest()}]
    return builder.add(relative, {"schema_version": 1, "boundary": boundary,
                                  "journal_entries": rows}, boundary)


def add_processes(builder, roles, methods, root_identity, first=1):
    refs = []
    facts = []
    for offset, (role, method) in enumerate(zip(roles, methods, strict=True)):
        sequence = first + offset
        pid, session = 4000 + sequence, 2
        creation = 639000000000000000 + sequence * 1000
        observed, exited = creation + 10, creation + 900
        binding = {"sequence": sequence, "role": role, "pid": pid, "session_id": session,
                   "start_time_utc_ticks": str(creation),
                   "executable_path": r"C:\bundle\DarkReNamer.exe",
                   "executable_sha256": "b" * 64}
        start_lifecycle = {key: binding[key] for key in ("pid", "session_id", "start_time_utc_ticks",
                                                         "executable_path", "executable_sha256")}
        start_lifecycle.update({"start_observed": True, "exit_observed": False,
                                "exit_method": None, "exit_code": None})
        start = {"schema_version": 1, "boundary": "started", "observed_utc_ticks": str(observed),
                 "binding": binding, "lifecycle": start_lifecycle,
                 "environment": environment(pid, session, root_identity, 10000 + pid)}
        refs.append(builder.add(f"process-{sequence:02d}-started.json", start, "started"))
        exit_boundary = "crash-stop" if method == "forced-termination" else "normal-exit"
        lifecycle = {**start_lifecycle, "exit_observed": True, "exit_method": method,
                     "exit_code": -1 if method == "forced-termination" else 0}
        exit_row = {"schema_version": 1, "boundary": exit_boundary,
                    "observed_utc_ticks": str(exited), "binding": binding, "lifecycle": lifecycle}
        refs.append(builder.add(f"process-{sequence:02d}-{exit_boundary}.json", exit_row, exit_boundary))
        facts.append({"pid": pid, "session": session, "start": observed, "exit": exited,
                      "hwnd": 10000 + pid})
    return refs, facts


def control(process, automation_id, control_id, *, enabled=True, visible=True):
    return {"pid": process["pid"], "session_id": process["session"],
            "hwnd": 50000 + control_id, "root_hwnd": process["hwnd"], "class": "Button",
            "control_id": control_id, "automation_id": automation_id,
            "control_type": "ControlType.Button", "enabled": enabled,
            "visible": visible, "focused": False}


def action(builder, relative, boundary, phase, name, process, automation_id, control_id):
    return builder.add(relative, {"schema_version": 1, "boundary": boundary, "phase": phase,
                                  "action": name, "dispatch_method": "uia-invoke",
                                  "target": control(process, automation_id, control_id),
                                  "observed_utc_ticks": str(process["start"] + 100),
                                  "completed_utc_ticks": str(process["start"] + 200)}, boundary)


def lock(builder, relative, boundary, phase, process, *, locked, observed_offset=50):
    return builder.add(relative, {"schema_version": 1, "boundary": boundary, "phase": phase,
                                  "process": {"pid": process["pid"], "session_id": process["session"]},
                                  "controls": {
                                      "apply": control(process, "32771", 32771,
                                                       enabled=False, visible=True),
                                      "add_files": control(process, "32791", 32791,
                                                           enabled=not locked, visible=not locked)},
                                  "observed_utc_ticks": str(process["start"] + observed_offset)}, boundary)


def foreground(builder, process, label):
    snapshot = {"hwnd": process["hwnd"], "process_id": process["pid"],
                "session_id": process["session"], "window_class": "DarkReNamerWindow"}
    row = {"label": label, "target_hwnd": snapshot["hwnd"], "initial": snapshot,
           "uia_set_focus": "succeeded", "set_foreground_window": True,
           "final": snapshot, "capture_change": None, "capture_complete": snapshot}
    return builder.add("foreground-observations.json",
                       {"schema_version": 1, "observations": [row]},
                       "screenshot-foreground-observations")


def build_crash():
    fixtures = fixture_module()
    initial = fixtures.initial
    partial = deepcopy(initial)
    partial[0]["name"] = "vm-recovered-" + partial[0]["name"]
    interrupted, intent = fixtures.prepared, fixtures.intent
    root_identity = fixtures.parent
    builder = RawBuilder()
    bundle, result = bundle_and_result("ProcessCrash")
    processes, process = add_processes(builder,
        ["rename-worker", "startup-default-cancel", "recovery-relaunch", "recovery-after-export"],
        ["forced-termination", "normal-close", "normal-close", "normal-close"], root_identity)
    specs = {
        "initial": ("state-initial.json", "initial", initial),
        "crash_partial": ("state-crash-partial.json", "crash-partial", partial),
        "startup_before_default_cancel": (
            "state-startup-before-cancel.json", "startup-before-default-cancel", partial),
        "default_cancel": ("state-default-cancel.json", "default-cancel", partial),
        "relaunch": ("state-relaunch.json", "recovery-relaunch", partial),
        "after_export": ("state-after-export.json", "recovery-after-export", partial),
        "export_relaunch": ("state-export-relaunch.json", "recovery-export-relaunch", partial),
        "restored": ("state-restored.json", "recovered", initial),
    }
    states = {key: state(builder, relative, boundary, entries, root_identity)
              for key, (relative, boundary, entries) in specs.items()}
    interrupted_ref = builder.add("interrupted-active.drj", interrupted, "crash-stop-active-journal")
    after_cancel = builder.add("active-after-default-cancel.drj", interrupted,
                               "default-cancel-normal-exit")
    after_export = builder.add("active-after-export.drj", interrupted,
                               "recovery-export-normal-exit")
    inventories = {
        "crash_stop": journal_inventory(builder, "journal-crash-stop.json", "crash-stop",
                                         "active.drj", interrupted),
        "after_default_cancel": journal_inventory(builder, "journal-after-default-cancel.json",
                                                   "default-cancel-normal-exit", "active.drj", interrupted),
        "after_export": journal_inventory(builder, "journal-after-export.json",
                                           "recovery-export-normal-exit", "active.drj", interrupted),
        "final_recovered": journal_inventory(builder, "journal-final-recovered.json",
                                              "recovered-normal-exit"),
    }
    default_action = action(builder, "startup-default-cancel-action.json",
                            "startup-default-cancel-action", "startup-default-cancel",
                            "cancel-startup-recovery", process[1], "CommandButton_2", 2)
    fg = foreground(builder, process[3], "startup recovery confirmation")
    mode = {"raw_states": states, "processes": processes,
            "actions": {"default_cancel": default_action},
            "journal": {"interrupted": interrupted_ref, "after_default_cancel": after_cancel,
                        "after_export": after_export},
            "journal_inventories": inventories, "foreground_observations": fg}
    result["process_crash"] = mode
    exported = builder.add("recovery-export/active.drj.retained", interrupted, "recovery-export")
    result["recovery_export"] = {"source_active_journal": interrupted_ref, "raw": exported}

    intent_processes, ip = add_processes(builder, ["intent-cancel", "intent-relaunch", "intent-discard"],
                                          ["normal-close"] * 3, root_identity, first=5)
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
    intent_states = {key: state(builder, relative, boundary, initial, root_identity)
                     for key, (relative, boundary) in intent_specs.items()}
    injected = builder.add("intent-authentic-source.drj", intent, "authentic-first-intent-frame")
    intent_after_cancel = builder.add("intent-after-cancel.drj", intent,
                                      "intent-post-cancel-normal-exit")
    intent_after_relaunch = builder.add("intent-after-relaunch.drj", intent,
                                        "intent-post-relaunch-normal-exit")
    intent_journals = {
        "pre_stage": journal_inventory(builder, "intent-journal-pre-stage.json", "intent-pre-stage"),
        "staged": journal_inventory(builder, "intent-journal-staged.json", "intent-staged",
                                     "candidate.drj", intent),
        "post_cancel_exit": journal_inventory(builder, "intent-journal-post-cancel-exit.json",
                                               "intent-post-cancel-normal-exit", "candidate.drj", intent),
        "relaunch_exit": journal_inventory(builder, "intent-journal-relaunch-exit.json",
                                            "intent-post-relaunch-normal-exit", "candidate.drj", intent),
        "final_exit": journal_inventory(builder, "intent-journal-final-exit.json",
                                         "intent-final-normal-exit"),
    }
    intent_actions = {
        "cancel_discard": action(builder, "intent-discard-cancel-action.json",
                                 "intent-discard-cancel-action", "intent-discard-cancel",
                                 "cancel-candidate-discard", ip[0], "CommandButton_2", 2),
        "confirm_discard": action(builder, "intent-discard-confirm-action.json",
                                  "intent-discard-confirm-action", "intent-discard-confirm",
                                  "confirm-candidate-discard", ip[2], "CommandLink_1201", 1201),
    }
    lock_specs = {
        "startup": ("intent-startup-lock.json", "intent-startup-lock", "intent-startup", ip[0], True, 50),
        "post_cancel": ("intent-post-cancel-lock.json", "intent-post-cancel-lock",
                        "intent-post-cancel", ip[0], True, 300),
        "relaunch": ("intent-relaunch-lock.json", "intent-relaunch-lock", "intent-relaunch", ip[1], True, 50),
        "discard_startup": ("intent-discard-startup-lock.json", "intent-discard-startup-lock",
                            "intent-discard-startup", ip[2], True, 50),
        "post_discard": ("intent-post-discard-unlock.json", "intent-post-discard-unlock",
                         "intent-post-discard", ip[2], False, 300),
    }
    locks = {key: lock(builder, relative, boundary, phase, proc, locked=locked,
                       observed_offset=observed_offset)
             for key, (relative, boundary, phase, proc, locked, observed_offset) in lock_specs.items()}
    result["intent_only_candidate_discard"] = {
        "candidate": {"source_active_journal": interrupted_ref, "injected_candidate": injected,
                      "after_cancel": intent_after_cancel, "after_relaunch": intent_after_relaunch},
        "states": intent_states, "journals": intent_journals, "processes": intent_processes,
        "actions": intent_actions, "lock_states": locks,
    }
    reader, result = builder.finish(result)
    transport = {"raw_cleanup": {"scheduled_task_present": False, "guest_root_present": False,
                                  "owned_processes_after": []}}
    return reader, result, bundle, transport


def build_worker(close):
    fixtures = fixture_module()
    initial, root_identity = fixtures.initial, fixtures.parent
    mode_name = "WorkerClose" if close else "WorkerCancellation"
    state_name = "workerclose" if close else "workercancellation"
    builder = RawBuilder(prefix="runs/" + ("worker-close" if close else "worker-cancellation") + "/")
    bundle, result = bundle_and_result(mode_name)
    refs, proc = add_processes(builder, ["rename-worker"],
                               ["worker-close" if close else "normal-close"], root_identity)
    initial_ref = state(builder, "state-initial.json", "initial", initial, root_identity)
    restored_ref = state(builder, f"state-{state_name}-restored.json",
                         f"{state_name}-restored-normal-exit", initial, root_identity)
    rows = []
    for role, actual, source, index, ticks in (
        ("first-destination", "vm-recovered-item-00000.txt", "item-00000.txt", 0, proc[0]["start"] + 100),
        ("last-original", "item-04095.txt", "item-04095.txt", 4095, proc[0]["start"] + 200),
    ):
        row = initial[index]
        rows.append({"role": role, "name": actual, "kind": "file", "bytes": row["bytes"],
                     "content_sha256": row["content_sha256"], "file_identity": row["file_identity"],
                     "observed_utc_ticks": str(ticks)})
    witness = builder.add(f"worker-{state_name}-partial-witness.json",
                          {"schema_version": 1, "boundary": "worker-partial",
                           "candidate_pid": proc[0]["pid"], "candidate_session_id": proc[0]["session"],
                           "fixture_root": ROOT, "root_identity": root_identity, "entries": rows},
                          "worker-partial")
    journal = journal_inventory(builder, f"journal-{state_name}-post-rollback.json",
                                f"{state_name}-post-rollback-normal-exit")
    mode = {"processes": refs, "raw_states": {"initial": initial_ref, "restored": restored_ref},
            "partial_witness": witness, "journal_inventory": journal,
            "foreground_observations": None}
    if not close:
        mode["actions"] = {"worker_cancel": action(builder, "worker-cancellation-action.json",
                                                     "worker-cancellation-action", "worker-cancellation",
                                                     "cancel-active-worker", proc[0], "1009", 1009)}
        mode["foreground_observations"] = foreground(builder, proc[0],
                                                       "worker cancellation restored state")
    result["worker_close" if close else "worker_cancellation"] = mode
    reader, result = builder.finish(result)
    transport = {"raw_cleanup": {"scheduled_task_present": False, "guest_root_present": False,
                                  "owned_processes_after": []}}
    return reader, result, bundle, transport, builder.prefix


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
        self.assertEqual(verify_recovery_execution(reader, result, bundle, transport, target(),
                                                   run_prefix=RUN_PREFIX),
                         {"process-crash", "recovery-export", "intent-only-discard"})

    def test_two_worker_modes_derive_only_their_own_targets(self):
        for fixture, expected in ((self.cancel, "worker-cancellation"), (self.close, "worker-close")):
            reader, result, bundle, transport, prefix = fixture
            with self.subTest(expected=expected):
                self.assertEqual(verify_recovery_execution(Reader(dict(reader.files)), deepcopy(result),
                                                           deepcopy(bundle), deepcopy(transport), target(),
                                                           run_prefix=prefix), {expected})

    def test_default_cancel_requires_raw_bound_action(self):
        reader, result, bundle, transport = self.crash_copy()
        result["process_crash"]["actions"]["default_cancel"]["boundary"] = "forged"
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX)

    def test_full_identity_state_mutation_fails_even_when_summary_is_unchanged(self):
        reader, result, bundle, transport = self.crash_copy()
        ref = result["process_crash"]["raw_states"]["default_cancel"]
        raw = reader.json(PRIVATE_ROOT + "/state-default-cancel.json")
        raw["fixture_entries"][0]["file_identity"]["file_id"] = "0" * 32
        resign(reader, result, "state-default-cancel.json", raw, [ref])
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX)

    def test_process_pair_role_and_exit_time_are_not_producer_flags(self):
        for mutation in ("role", "time"):
            reader, result, bundle, transport = self.crash_copy()
            ref = result["process_crash"]["processes"][1]
            raw = reader.json(PRIVATE_ROOT + "/process-01-crash-stop.json")
            if mutation == "role":
                raw["binding"]["role"] = "other"
            else:
                raw["observed_utc_ticks"] = "1"
            resign(reader, result, "process-01-crash-stop.json", raw, [ref])
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX)

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
                verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX)

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
                verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX)

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
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX)
        reader, result, bundle, transport = self.crash_copy()
        transport["raw_cleanup"]["scheduled_task_present"] = True
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX)

    def test_screenshot_capture_completion_is_bound_to_candidate_workbench(self):
        reader, result, bundle, transport = self.crash_copy()
        reference = result["process_crash"]["foreground_observations"]
        raw = reader.json(PRIVATE_ROOT + "/foreground-observations.json")
        raw["observations"][0]["capture_complete"]["hwnd"] += 1
        resign(reader, result, "foreground-observations.json", raw, [reference])
        with self.assertRaises(EvidenceError):
            verify_recovery_execution(reader, result, bundle, transport, target(), run_prefix=RUN_PREFIX)


if __name__ == "__main__":
    unittest.main()
