#!/usr/bin/env python3
"""Offline negative fixtures for GUI regression evidence validation."""

from __future__ import annotations

import hashlib
import io
import json
from contextlib import redirect_stdout
from copy import deepcopy
from functools import cached_property
from pathlib import Path
from tooling_test_paths import SCRIPT_ROOT
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

from controller_cleanup_fixture import (
    clean_controller_cleanup, clean_controller_cleanup_v2,
    clean_controller_cleanup_v3,
)
from darkrenamer_tooling.evidence import gui as evidence
from darkrenamer_tooling.evidence.import_trace import EVENTS as IMPORT_TRACE_EVENTS
from darkrenamer_tooling.vm import gui as vm_gui
from gui_regression_fixture import (
    SCRIPT, SOURCE, TREE, digest, json_bytes, write_json, pair_png,
    physical_menu_apply_entry, scenario, Fixture, first_clear_product_tree,
)


class ReadinessBracketTests(unittest.TestCase):
    def test_only_verified_prechange_lineage_may_omit_contract(self):
        # Hosted diagnostic checks use shallow source checkouts. Exercise the
        # actual ancestry policy in an independent history rather than assuming
        # that a particular historical production object exists locally.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            def commit(message):
                subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test',
                    '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty',
                    '-qm', message], check=True)
                return subprocess.check_output(['git', '-C', str(root),
                    'rev-parse', 'HEAD'], text=True).strip()
            old = commit('old')
            current = commit('current')
            with mock.patch.object(evidence, 'READINESS_LEGACY_TIP', old):
                self.assertFalse(evidence.requires_readiness_brackets(old, root))
                self.assertTrue(evidence.requires_readiness_brackets(current, root))
                self.assertTrue(evidence.requires_readiness_brackets('f' * 40, root))
        with mock.patch.object(evidence.subprocess, 'run',
                               return_value=SimpleNamespace(returncode=1)):
            self.assertTrue(evidence.requires_readiness_brackets('b' * 40))

    def record(self, probes):
        return [
            {'operation': 'startup-main-window', 'predicate': 'bound-main-window',
             'observation': 'opaque-observer-envelope', 'qpc_frequency': 10000000,
             'process_id': 41, 'process_start_utc_ticks': 638965440000000000,
             'main_window_handle': 900, 'begin_ticks': 100, 'end_ticks': 200},
            {'operation': 'startup', 'predicate': 'import-command-enabled',
             'observation': 'polled-monotonic-predicate', 'qpc_frequency': 10000000,
             'process_id': 41, 'process_start_utc_ticks': 638965440000000000,
             'main_window_handle': 900, 'probes': probes},
        ]

    def validate(self, records, end):
        return evidence.validate_readiness_brackets(
            records, process_id=41, process_start_utc_ticks=638965440000000000,
            main_window_handle=900, expected_frequency=10000000,
            operations=[('startup', 'import-command-enabled', end)],
            startup_ready_ticks=end, expected_main_bound_ticks=200)

    def test_last_false_to_first_true_and_actual_query_gaps(self):
        probes = [{'begin_ticks': 300, 'end_ticks': 310, 'ready': False},
                  {'begin_ticks': 1000310, 'end_ticks': 1000320, 'ready': False},
                  {'begin_ticks': 2000320, 'end_ticks': 2000340, 'ready': True}]
        receipt = self.validate(self.record(probes), 2000340)['observations'][1]
        self.assertEqual(receipt['last_false_begin_ticks'], 1000310)
        self.assertEqual(receipt['first_true_end_ticks'], 2000340)
        self.assertEqual(len(receipt['actual_intervals_ms']), 2)
        self.assertAlmostEqual(receipt['uncertainty_ms'], 100.003)

    def test_first_query_true_retains_only_its_query_uncertainty(self):
        receipt = self.validate(self.record([
            {'begin_ticks': 300, 'end_ticks': 320, 'ready': True}]), 320)['observations'][1]
        self.assertIsNone(receipt['last_false_begin_ticks'])
        self.assertAlmostEqual(receipt['uncertainty_ms'], 0.002)

    def test_rejects_identity_drift_premature_true_and_inverted_queries(self):
        valid = self.record([{'begin_ticks': 300, 'end_ticks': 310, 'ready': False},
                             {'begin_ticks': 1000310, 'end_ticks': 1000320, 'ready': True}])
        changes = (
            lambda rows: rows[1].__setitem__('process_id', 42),
            lambda rows: rows[1].__setitem__('process_start_utc_ticks', 638965440000000001),
            lambda rows: rows[1].__setitem__('main_window_handle', 901),
            lambda rows: rows[1]['probes'][0].__setitem__('ready', True),
            lambda rows: rows[1]['probes'][1].__setitem__('begin_ticks', 309),
            lambda rows: rows[1]['probes'][1].__setitem__('end_ticks', 300),
            lambda rows: rows[0].__setitem__('end_ticks', 201),
            lambda rows: [row.__setitem__('qpc_frequency', 20000000) for row in rows],
            lambda rows: rows[1].pop('probes'),
        )
        for change in changes:
            rows = deepcopy(valid)
            change(rows)
            with self.subTest(change=change), self.assertRaises(evidence.EvidenceError):
                self.validate(rows, 1000320)
        with self.assertRaises(evidence.EvidenceError):
            self.validate(valid, 1000321)

    def test_exact_idle_cpu_windows_require_30s_and_same_owned_process(self):
        def snapshot(begin, end, cpu):
            return {'begin_ticks': begin, 'end_ticks': end, 'process_id': 41,
                    'process_start_utc_ticks': 638965440000000000,
                    'main_window_handle': 900, 'cpu_total_ticks': cpu}
        windows = [
            {'phase': 'empty-idle', 'before': snapshot(100, 110, 1000000),
             'after': snapshot(300000110, 300000120, 1500000)},
            {'phase': 'populated-idle', 'before': snapshot(400000100, 400000110, 2000000),
             'after': snapshot(700000110, 700000120, 3000000)},
        ]
        result = evidence.validate_idle_cpu_windows(
            windows, process_id=41, process_start_utc_ticks=638965440000000000,
            main_window_handle=900, frequency=10000000, startup_ready_ticks=50)
        self.assertEqual([row['cpu_delta_ms'] for row in result], [50.0, 100.0])
        self.assertEqual([row['elapsed_lower_ms'] for row in result], [30000.0, 30000.0])
        for change in (
            lambda rows: rows[0]['after'].__setitem__('begin_ticks', 300000109),
            lambda rows: rows[1]['before'].__setitem__('process_id', 42),
            lambda rows: rows[1]['after'].__setitem__('cpu_total_ticks', 100),
        ):
            rows = deepcopy(windows)
            change(rows)
            with self.subTest(change=change), self.assertRaises(evidence.EvidenceError):
                evidence.validate_idle_cpu_windows(
                    rows, process_id=41, process_start_utc_ticks=638965440000000000,
                    main_window_handle=900, frequency=10000000, startup_ready_ticks=50)


class SyntheticFixtureTestCase(unittest.TestCase):
    def setUp(self):
        # Synthetic SOURCE is not a Git commit; each fixture models the historical
        # pre-bracket producer unless an individual test overrides this boundary.
        lineage = mock.patch.object(evidence, 'requires_readiness_brackets', return_value=False)
        lineage.start()
        self.addCleanup(lineage.stop)
        self.temporary = None
        self.addCleanup(self.cleanup_fixture)
        self.reset_fixture()

    def cleanup_fixture(self):
        if self.temporary is not None:
            self.temporary.cleanup()

    def reset_fixture(self):
        """Replace only synthetic test data, including partially built fixtures."""
        self.cleanup_fixture()
        for name in ("full", "standard", "text", "tooltip", "pair_run"):
            self.__dict__.pop(name, None)
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.fixture = Fixture(self.root)


class GuiEvidenceTests(SyntheticFixtureTestCase):
    def test_picker_source_selects_historical_and_custom_popup_schemas(self):
        marker = '$script:PickerFailureSchemaVersion = {}\n' \
                 'Failure.SchemaVersion -ne $script:PickerFailureSchemaVersion\n' \
                 'sampler_failure\n'
        native = b'knownHiddenInactive ? "owned-hidden-inactive"\n' \
                 b'SchemaVersion = {}, Phase = phase'
        for version in (1, 2, 3):
            with self.subTest(version=version):
                responses = [SimpleNamespace(returncode=0, stdout=marker.format(version).encode())]
                if version in (2, 3):
                    responses.append(SimpleNamespace(returncode=0,
                        stdout=b'popup_diagnostic_schema_version'))
                    # The marker belongs to the scenario producer, while state emission is native.
                    responses[0].stdout += b'popup_diagnostic_schema_version'
                    responses[1].stdout = native.replace(b'{}', str(version).encode())
                    if version == 3:
                        responses[1].stdout += b'\ndiagnostic.PopupClass == "DarkReNamerInputWindow"'
                with mock.patch.object(evidence.subprocess, 'run', side_effect=responses):
                    self.assertEqual(evidence.selected_picker_failure_schema(
                        SCRIPT_ROOT.parent, 'a' * 40), version)
        with mock.patch.object(evidence.subprocess, 'run', return_value=SimpleNamespace(
                returncode=0, stdout=marker.format(2).encode())):
            with self.assertRaises(evidence.EvidenceError):
                evidence.selected_picker_failure_schema(SCRIPT_ROOT.parent, 'a' * 40)
        responses = [SimpleNamespace(returncode=0, stdout=(marker.format(3) +
            'popup_diagnostic_schema_version').encode()),
            SimpleNamespace(returncode=0, stdout=native.replace(b'{}', b'3'))]
        with mock.patch.object(evidence.subprocess, 'run', side_effect=responses):
            with self.assertRaises(evidence.EvidenceError):
                evidence.selected_picker_failure_schema(SCRIPT_ROOT.parent, 'a' * 40)

    @staticmethod
    def picker_popup():
        return {"stage": "before-probe", "begin_ticks": 100, "end_ticks": 110,
                "raw_popup_handle": 900, "accepted_popup_handle": 900,
                "popup_lookup": "popup", "popup_process_id": 42, "popup_thread_id": 7,
                "thread_lookup": "complete", "thread_lookup_error": None,
                "popup_class": "#32770", "class_lookup": "complete", "class_lookup_error": None,
                "popup_visible": True, "main_enabled_at_lookup": False,
                "visibility_lookup": "visible", "direct_owner": 800,
                "owner_lookup": "returned", "owner_lookup_error": None,
                "owner_chain": [800], "owner_chain_lookup": "main-reached",
                "owner_chain_lookup_error": None, "disposition": "owned-popup",
                "observed_predicates": [], "failed_predicates": []}

    def test_picker_popup_independently_binds_pid_thread_owner_and_inactive_policy(self):
        popup = self.picker_popup()
        self.assertEqual(evidence.validate_picker_popup(popup, "before-probe", 800, 42, 7), popup)
        for field, value in (("popup_process_id", 43), ("popup_thread_id", 8),
                             ("direct_owner", 801), ("owner_chain", [801]),
                             ("owner_chain_lookup", "ended"), ("popup_visible", False)):
            with self.subTest(field=field):
                changed = deepcopy(popup)
                changed[field] = value
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_picker_popup(changed, "before-probe", 800, 42, 7)
        ignored = deepcopy(popup)
        ignored.update(popup_visible=False, main_enabled_at_lookup=True,
                       visibility_lookup="hidden", accepted_popup_handle=0,
                       disposition="inactive-ignored", observed_predicates=["hidden"])
        self.assertEqual(evidence.validate_picker_popup(ignored, "before-probe", 800, 42, 7), ignored)
        ignored["main_enabled_at_lookup"] = False
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_picker_popup(ignored, "before-probe", 800, 42, 7)

    def test_picker_hidden_owned_state_requires_source_selected_class_and_complete_identity(self):
        hidden = self.picker_popup()
        hidden.update(accepted_popup_handle=0, popup_visible=False,
                      visibility_lookup="hidden", disposition="owned-hidden-inactive",
                      observed_predicates=["hidden"])
        self.assertEqual(evidence.validate_picker_popup(
            hidden, "before-probe", 800, 42, 7, schema_version=2), hidden)
        self.assertEqual(evidence.validate_picker_popup(
            hidden, "before-probe", 800, 42, 7, schema_version=3), hidden)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_picker_popup(hidden, "before-probe", 800, 42, 7,
                                           schema_version=1)
        custom = {**hidden, "popup_class": "DarkReNamerInputWindow"}
        self.assertEqual(evidence.validate_picker_popup(
            custom, "before-probe", 800, 42, 7, schema_version=3), custom)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_picker_popup(custom, "before-probe", 800, 42, 7,
                                           schema_version=2)
        for changes in (
            {"popup_process_id": 43, "observed_predicates": ["process-mismatch", "hidden"]},
            {"popup_thread_id": 8, "observed_predicates": ["thread-mismatch", "hidden"]},
            {"popup_class": "Other"},
            {"direct_owner": 801, "owner_chain": [801, 800],
             "observed_predicates": ["direct-owner-mismatch", "hidden"]},
            {"owner_chain": [801, 800]},
            {"owner_lookup": "null-with-error", "owner_lookup_error": 5,
             "direct_owner": 0, "owner_chain": [], "owner_chain_lookup": "ended",
             "observed_predicates": ["direct-owner-mismatch", "hidden"]},
            {"class_lookup": "failed", "class_lookup_error": 5,
             "popup_class": "", "observed_predicates": ["hidden", "class-lookup", "class-unavailable"]},
            {"main_enabled_at_lookup": True},
            {"failed_predicates": ["hidden"]},
        ):
            with self.subTest(changes=changes):
                changed = {**hidden, **changes}
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_picker_popup(changed, "before-probe", 800, 42, 7,
                                                   schema_version=2)
        for changes in (
            {"popup_process_id": 43, "observed_predicates": ["process-mismatch", "hidden"]},
            {"popup_thread_id": 8, "observed_predicates": ["thread-mismatch", "hidden"]},
            {"direct_owner": 801, "owner_chain": [801],
             "owner_chain_lookup": "ended", "owner_chain_lookup_error": 0,
             "observed_predicates": ["direct-owner-mismatch", "hidden"]},
            {"owner_chain": [801, 800]},
            {"thread_lookup": "failed", "thread_lookup_error": 1400,
             "popup_thread_id": 0,
             "observed_predicates": ["thread-lookup", "thread-mismatch", "hidden"]},
            {"class_lookup": "failed", "class_lookup_error": 1400,
             "popup_class": "", "observed_predicates": ["hidden", "class-lookup", "class-unavailable"]},
            {"popup_class": "UnknownWindow"},
            {"main_enabled_at_lookup": True},
            {"failed_predicates": ["hidden"]},
            {"raw_popup_handle": 0, "popup_lookup": "zero",
             "observed_predicates": ["popup-zero"]},
        ):
            with self.subTest(changes=changes):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_picker_popup({**custom, **changes}, "before-probe",
                                                   800, 42, 7, schema_version=3)

    def test_picker_failure_rejects_schema_downgrade_and_missing_transition(self):
        popup = self.picker_popup()
        main = {"handle": 800, "process_id": 42, "process_start_utc_ticks": 500,
                "thread_id": 7, "class": "DarkReNamerWindow", "enabled": False,
                "lookup": "complete", "thread_lookup_error": None,
                "class_lookup_error": None}
        rejected = deepcopy(popup)
        rejected.update(disposition="rejected", accepted_popup_handle=900,
                        popup_process_id=43, observed_predicates=["process-mismatch"],
                        failed_predicates=["process-mismatch"])
        failure = {"schema_version": 1, "phase": "ordinary-100",
                   "error_type": "InvalidOperationException",
                   "message": "Sampler active owned popup identity changed.",
                   "sample_begin_ticks": 90, "sample_end_ticks": 130,
                   "probe_begin_ticks": 111, "probe_end_ticks": 120,
                   "probe_error_code": 0, "qpc_frequency": 1000000,
                   "main_before": main, "main_after": main,
                   "popup_before": popup, "popup_after": {**rejected,
                       "stage": "after-probe", "begin_ticks": 121, "end_ticks": 129}}
        self.assertEqual(evidence.validate_picker_failure(failure, main_handle=800,
            process_id=42, process_start_utc_ticks=500)["failed_predicates"],
            ["process-mismatch"])
        for field, value in (("schema_version", 0), ("popup_before", None),
                             ("main_before", None), ("popup_after", None)):
            with self.subTest(field=field):
                changed = deepcopy(failure)
                changed[field] = value
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_picker_failure(changed, main_handle=800,
                        process_id=42, process_start_utc_ticks=500)

    def test_picker_disabled_no_popup_nested_owner_missing_lookup_and_teardown(self):
        base = self.picker_popup()
        no_popup = deepcopy(base)
        no_popup.update(raw_popup_handle=800, accepted_popup_handle=0,
            popup_lookup="main", popup_process_id=0, popup_thread_id=0,
            thread_lookup="not-run", popup_class="", class_lookup="not-run",
            popup_visible=False, main_enabled_at_lookup=False,
            visibility_lookup="not-run", direct_owner=0, owner_lookup="not-run",
            owner_chain=[], owner_chain_lookup="not-run", disposition="main")
        self.assertEqual(evidence.validate_picker_popup(no_popup, "before-probe", 800, 42, 7), no_popup)
        nested = deepcopy(base)
        nested.update(direct_owner=801, owner_chain=[801, 800],
                      disposition="rejected", observed_predicates=["direct-owner-mismatch"],
                      failed_predicates=["direct-owner-mismatch"])
        self.assertEqual(evidence.validate_picker_popup(nested, "before-probe", 800, 42, 7), nested)
        no_owner = deepcopy(nested)
        no_owner.update(direct_owner=0, owner_chain=[], owner_chain_lookup="ended",
                        owner_lookup="null-with-error", owner_lookup_error=5)
        self.assertEqual(evidence.validate_picker_popup(no_owner, "before-probe", 800, 42, 7), no_owner)
        no_owner["owner_lookup_error"] = 0
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_picker_popup(no_owner, "before-probe", 800, 42, 7)
        no_owner.update(owner_lookup="none", owner_lookup_error=0)
        self.assertEqual(evidence.validate_picker_popup(no_owner, "before-probe", 800, 42, 7), no_owner)
        ended_chain = deepcopy(nested)
        ended_chain.update(owner_chain=[801], owner_chain_lookup="ended",
                           owner_chain_lookup_error=0)
        self.assertEqual(evidence.validate_picker_popup(ended_chain, "before-probe", 800, 42, 7), ended_chain)
        ended_chain["owner_chain_lookup_error"] = None
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_picker_popup(ended_chain, "before-probe", 800, 42, 7)
        for field, value in (("disposition", "owned-popup"), ("thread_lookup", "not-run"),
                             ("owner_chain", [800]), ("popup_process_id", 43)):
            with self.subTest(field=field):
                altered = deepcopy(nested)
                altered[field] = value
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_picker_popup(altered, "before-probe", 800, 42, 7)
        main_before = {"handle": 800, "process_id": 42, "process_start_utc_ticks": 500,
                       "thread_id": 7, "class": "DarkReNamerWindow", "enabled": False,
                       "lookup": "complete", "thread_lookup_error": None,
                       "class_lookup_error": None}
        after = deepcopy(no_popup)
        after.update(stage="after-probe", begin_ticks=121, end_ticks=129)
        failure = {"schema_version": 1, "phase": "ordinary-100",
            "error_type": "InvalidOperationException", "message": "Sampler target identity changed after probe.",
            "sample_begin_ticks": 90, "sample_end_ticks": 130,
            "probe_begin_ticks": 111, "probe_end_ticks": 120,
            "probe_error_code": 0, "qpc_frequency": 1000000,
            "main_before": main_before, "main_after": {**main_before,
                "lookup": "process-exited"}, "popup_before": base,
            "popup_after": after}
        self.assertEqual(evidence.validate_picker_failure(failure, main_handle=800,
            process_id=42, process_start_utc_ticks=500)["main_identity_after"], "process-exited")
        failure["popup_after"] = None
        self.assertEqual(evidence.validate_picker_failure(failure, main_handle=800,
            process_id=42, process_start_utc_ticks=500)["probe_executed"], True)

    @staticmethod
    def bind_v2_fixture_vm(run: Path, manifest: dict, transport: dict) -> None:
        """Make the synthetic preflight, postlaunch and transport one VM identity."""
        vm_id = transport["vm_id"]
        vm_hash = digest(vm_id.encode("ascii"))
        manifest["guest_preflight"]["vm_identity_sha256"] = vm_hash
        write_json(run / "input-manifest.json", manifest)
        preflight_path = run / "output/platform-preflight.json"
        preflight = json.loads(preflight_path.read_text())
        preflight["guest_platform"]["vm_identity_sha256"] = vm_hash
        write_json(preflight_path, preflight)
        postlaunch_path = run / "output/platform-postlaunch.json"
        postlaunch = json.loads(postlaunch_path.read_text())
        postlaunch["vm_identity_sha256"] = vm_hash
        write_json(postlaunch_path, postlaunch)
        transport["vm_identity_kind"] = manifest["guest_preflight"]["vm_identity_kind"]
        transport["vm_identity_sha256"] = vm_hash

    def test_fixture_semantics_do_not_follow_changed_verifier_expectations(self):
        baseline = json.loads((self.fixture.build("stable-standard", "standard") /
                               "output" / "run-result.json").read_text())
        with mock.patch.dict(evidence.MODE_SEMANTICS, {"standard": {"unexpected-semantic"}}):
            changed = json.loads((self.fixture.build("drift-standard", "standard") /
                                  "output" / "run-result.json").read_text())
            self.assertEqual(changed["assertions"]["semantics"],
                             baseline["assertions"]["semantics"])
            with self.assertRaisesRegex(evidence.EvidenceError, "semantic assertion set"):
                evidence.validate_semantics(changed, "standard")

    @cached_property
    def full(self):
        return self.fixture.build("01-full-context-light-800x600-96-text100", "full-context")

    @cached_property
    def standard(self):
        return self.fixture.build("02-standard-light-800x600-96-text100", "standard")

    @cached_property
    def text(self):
        return self.fixture.build("03-standard-light-800x600-96-text150", "text-scale")

    @cached_property
    def tooltip(self):
        return self.fixture.build("04-tooltip-dark-1366x768-144-text100", "tooltip",
                                  reference=self.fixture.reference(self.full))

    def validate(self, run: Path):
        return evidence.validate_run(self.root, run.name, SOURCE)

    def fixed_v2_run(self, mode: str, reference: dict | None = None):
        run = self.fixture.build(evidence.FIXED_V2_RUN_IDS[mode], mode, reference=reference)
        profile = (SCRIPT_ROOT.parent / "config" / "vm-automated-v2.json").read_bytes()
        profile_hash = digest(profile)
        (run / "inputs" / "vm-automated-v2.json").write_bytes(profile)
        manifest_path = run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["acceptance_profile_id"] = evidence.V2_PROFILE_ID
        manifest["acceptance_profile_sha256"] = profile_hash
        manifest["acceptance_profile"] = {
            "file": "inputs/vm-automated-v2.json", "bytes": len(profile), "sha256": profile_hash,
        }
        manifest["command"] = ["python3", "-I", "scripts/run-gui-regression.py", "--output-root",
                               "<external-output-root>", "--connection-profile",
                               "<private-connection-profile>", "--acceptance-profile-id",
                               evidence.V2_PROFILE_ID]
        write_json(manifest_path, manifest)
        output = run / "output"
        raw_path = output / "acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        jobs = []
        lifecycles = []
        for index in range(3 if mode == "full-context" else 1):
            job = deepcopy(clean_controller_cleanup_v2()["owned_resource_evidence"]["process_job_cleanup"][0])
            job["pid"] = 4242 + index
            job["process_start_time_utc_ticks"] = str(134041000000000000 + index)
            jobs.append(job)
            lifecycles.append({"process_lifecycle": {
                "pid": job["pid"], "session_id": 2,
                "start_time_utc_ticks": job["process_start_time_utc_ticks"],
                "executable_path": r"C:\fixture\DarkReNamer.exe",
                "executable_sha256": manifest["artifacts"]["application"]["sha256"],
                "start_observed": True, "exit_observed": True,
                "exit_method": "normal-close", "exit_code": 0,
            }})
        cleanup = clean_controller_cleanup_v3(
            profile_sha256=profile_hash, process_jobs=jobs, source_sha=manifest["source_sha"],
            bundle_sha256=manifest["bundle_manifest"]["sha256"])
        raw["process_lifecycles"] = lifecycles
        raw["process_job_cleanup"] = cleanup["owned_resource_evidence"]["process_job_cleanup"]
        raw["observer_lifecycle"] = cleanup["owned_resource_evidence"]["task_execution"]["observer_lifecycle"]
        write_json(raw_path, raw)
        transport_path = output / "transport.json"
        transport = json.loads(transport_path.read_text())
        transport["raw_cleanup"] = cleanup
        transport["vm_id"] = cleanup["owned_resource_evidence"]["protected_anchor"]["vm_id"]
        self.bind_v2_fixture_vm(run, manifest, transport)
        write_json(transport_path, transport)
        self.fixture.refresh(run)
        return run, profile_hash

    def test_fixed_v2_complete_set_accepts_bound_ambient_processes(self):
        full, profile_hash = self.fixed_v2_run("full-context")
        standard, _ = self.fixed_v2_run("standard")
        text, _ = self.fixed_v2_run("text-scale")
        tooltip, _ = self.fixed_v2_run("tooltip", reference=self.fixture.reference(full))
        runs = (full, standard, text, tooltip)
        for run in runs:
            self.assertEqual(evidence.validate_run(self.root, run.name, SOURCE,
                             expected_profile_sha256=profile_hash)["result"]["status"], "review_required")
        argv = ["--result-root", str(self.root), "--expected-source-sha", SOURCE,
                "--require-complete-set", "--acceptance-profile-id", evidence.V2_PROFILE_ID]
        for run in runs:
            argv += ["--run", run.name]
        with mock.patch.object(evidence.subprocess, "run",
                               return_value=SimpleNamespace(returncode=0,
                                                            stdout=(SCRIPT_ROOT.parent / "config" / "vm-automated-v2.json").read_bytes())), \
             redirect_stdout(io.StringIO()):
            self.assertEqual(evidence.main(SCRIPT_ROOT.parent, argv), 0)

    def test_current_v2_rejects_coherent_foreign_transport_vm(self):
        run, profile_hash = self.fixed_v2_run("standard")
        self.assertEqual(evidence.validate_run(self.root, run.name, SOURCE,
                         expected_profile_sha256=profile_hash)["result"]["status"], "review_required")
        transport_path = run / "output/transport.json"
        transport = json.loads(transport_path.read_text())
        foreign_id = "87654321-4321-4321-4321-cba987654321"
        transport["vm_id"] = foreign_id
        transport["vm_identity_sha256"] = digest(foreign_id.encode("ascii"))
        owned = transport["raw_cleanup"]["owned_resource_evidence"]
        owned["protected_anchor_initial"]["vm_id"] = foreign_id
        owned["protected_anchor"]["vm_id"] = foreign_id
        write_json(transport_path, transport)
        self.fixture.refresh(run)
        with self.assertRaisesRegex(evidence.EvidenceError, "VM identity differs"):
            evidence.validate_run(self.root, run.name, SOURCE,
                                  expected_profile_sha256=profile_hash)

    def test_fixed_v2_selection_rejects_historical_single_v1_run(self):
        profile = (SCRIPT_ROOT.parent / "config" / "vm-automated-v2.json").read_bytes()
        with mock.patch.object(evidence.subprocess, "run",
                               return_value=SimpleNamespace(returncode=0, stdout=profile)):
            with self.assertRaisesRegex(evidence.EvidenceError, "selection differs"):
                evidence.main(SCRIPT_ROOT.parent, ["--result-root", str(self.root),
                             "--expected-source-sha", SOURCE, "--run", self.full.name,
                             "--acceptance-profile-id", evidence.V2_PROFILE_ID])

    def test_fixed_v2_rejects_profile_and_incomplete_candidate_lifetimes(self):
        full, profile_hash = self.fixed_v2_run("full-context")
        self.assertTrue(json.loads((full / "output/transport.json").read_text())["raw_cleanup"]["unexpected_runner_processes"])
        manifest_path = full / "input-manifest.json"
        original_manifest = json.loads(manifest_path.read_text())
        for mutate in (
            lambda m: m.pop("acceptance_profile_id"),
            lambda m: m.__setitem__("acceptance_profile_sha256", "0" * 64),
            lambda m: m["command"].remove("--acceptance-profile-id"),
        ):
            with self.subTest(manifest_mutation=mutate):
                manifest = deepcopy(original_manifest)
                mutate(manifest)
                write_json(manifest_path, manifest)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_input_manifest(full, SOURCE,
                                                     expected_profile_sha256=profile_hash)
        write_json(manifest_path, original_manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "source blob"):
            evidence.validate_input_manifest(full, SOURCE, expected_profile_sha256="0" * 64)
        profile_path = full / "inputs/vm-automated-v2.json"
        profile_path.write_bytes(profile_path.read_bytes() + b" ")
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_input_manifest(full, SOURCE,
                                             expected_profile_sha256=profile_hash)
        profile_path.write_bytes((SCRIPT_ROOT.parent / "config" / "vm-automated-v2.json").read_bytes())
        raw_path = full / "output/acceptance-result.json"
        original_raw = json.loads(raw_path.read_text())
        mutations = (
            lambda r: r["process_lifecycles"].pop(),
            lambda r: r["process_job_cleanup"].pop(),
            lambda r: r["process_lifecycles"][1]["process_lifecycle"].__setitem__("pid", 9999),
            lambda r: r["process_lifecycles"][1]["process_lifecycle"].__setitem__("exit_observed", False),
            lambda r: r["process_lifecycles"][1]["process_lifecycle"].__setitem__("exit_code", 1),
            lambda r: r["process_lifecycles"][1]["process_lifecycle"].__setitem__("executable_sha256", "0" * 64),
            lambda r: r.pop("observer_lifecycle"),
        )
        for mutate in mutations:
            with self.subTest(lifetime_mutation=mutate):
                changed = deepcopy(original_raw)
                mutate(changed)
                write_json(raw_path, changed)
                self.fixture.refresh(full)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_run(self.root, full.name, SOURCE,
                                          expected_profile_sha256=profile_hash)
        write_json(raw_path, original_raw)
        transport_path = full / "output/transport.json"
        original_transport = json.loads(transport_path.read_text())
        for mutate in (
            lambda t: t.__setitem__("raw_cleanup", clean_controller_cleanup()),
            lambda t: t["raw_cleanup"].__setitem__("process_jobs_closed", False),
            lambda t: t["raw_cleanup"]["owned_resource_evidence"]["process_snapshots"]["after_delete"].__setitem__("complete", False),
            lambda t: t["raw_cleanup"]["owned_resource_evidence"]["observed_roots_after"].__setitem__("guest_present", True),
            lambda t: t["raw_cleanup"]["owned_resource_evidence"]["task_snapshots"]["after_delete"].append({"name": "unexpected"}),
        ):
            with self.subTest(cleanup_mutation=mutate):
                changed = deepcopy(original_transport)
                mutate(changed)
                write_json(transport_path, changed)
                self.fixture.refresh(full)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_run(self.root, full.name, SOURCE,
                                          expected_profile_sha256=profile_hash)

    def assert_rejected_by_module_and_cli(self, run: Path, diagnostic: str):
        with self.assertRaisesRegex(evidence.EvidenceError, diagnostic):
            self.validate(run)
        completed = subprocess.run(
            ["python3", str(SCRIPT), "--result-root", str(self.root),
             "--expected-source-sha", SOURCE, "--run", run.name],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertRegex(completed.stderr, diagnostic)
        self.assertEqual(completed.stdout, "")

    def test_complete_representative_set_and_direct_reference_pass(self):
        runs = [self.validate(path) for path in (self.full, self.standard, self.text, self.tooltip)]
        evidence.validate_text_pair(runs)
        command = ["python3", str(SCRIPT), "--result-root", str(self.root),
                   "--expected-source-sha", SOURCE, "--require-complete-set"]
        for run in (self.full, self.standard, self.text, self.tooltip):
            command += ["--run", run.name]
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["status"], "passed")

    def test_missing_and_failed_references_are_rejected(self):
        missing = json.loads((self.tooltip / "input-manifest.json").read_text())
        missing["full_context_reference"]["run_id"] = "missing-run"
        write_json(self.tooltip / "input-manifest.json", missing)
        self.fixture.refresh(self.tooltip)
        with self.assertRaisesRegex(evidence.EvidenceError, "missing"):
            self.validate(self.tooltip)

        self.reset_fixture()
        result = json.loads((self.full / "output/run-result.json").read_text())
        result["status"] = "failed"
        write_json(self.full / "output/run-result.json", result)
        current = json.loads((self.tooltip / "input-manifest.json").read_text())
        current["full_context_reference"]["result_sha256"] = digest((self.full / "output/run-result.json").read_bytes())
        write_json(self.tooltip / "input-manifest.json", current)
        self.fixture.refresh(self.tooltip)
        with self.assertRaisesRegex(evidence.EvidenceError, "review_required|raw GUI evidence"):
            self.validate(self.tooltip)

    def test_other_source_sha_and_executable_are_rejected(self):
        manifest = json.loads((self.full / "input-manifest.json").read_text())
        manifest["source_sha"] = "c" * 40
        write_json(self.full / "input-manifest.json", manifest)
        self.fixture.refresh(self.full)
        with self.assertRaisesRegex(evidence.EvidenceError, "exact source SHA"):
            self.validate(self.full)

        self.reset_fixture()
        manifest = json.loads((self.full / "input-manifest.json").read_text())
        app = self.full / manifest["artifacts"]["application"]["file"]
        app.write_bytes(b"another executable")
        manifest["artifacts"]["application"]["bytes"] = app.stat().st_size
        manifest["artifacts"]["application"]["sha256"] = digest(app.read_bytes())
        write_json(self.full / "input-manifest.json", manifest)
        self.fixture.refresh(self.full)
        reference = json.loads((self.tooltip / "input-manifest.json").read_text())
        reference["full_context_reference"] = self.fixture.reference(self.full)
        write_json(self.tooltip / "input-manifest.json", reference)
        self.fixture.refresh(self.tooltip)
        with self.assertRaisesRegex(evidence.EvidenceError, "another executable"):
            self.validate(self.tooltip)

    def test_missing_or_tampered_log_capture_and_observer_are_rejected(self):
        (self.standard / "output/controller.stdout.txt").unlink()
        with self.assertRaisesRegex(evidence.EvidenceError, "missing"):
            self.validate(self.standard)

        self.reset_fixture()
        (self.standard / "output/screen.png").write_bytes(b"changed")
        with self.assertRaisesRegex(evidence.EvidenceError, "receipt"):
            self.validate(self.standard)

        self.reset_fixture()
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        observer = self.standard / manifest["artifacts"]["observer"]["file"]
        observer.write_bytes(b"tampered observer")
        with self.assertRaisesRegex(evidence.EvidenceError, "input manifest"):
            self.validate(self.standard)

    def test_each_controller_stream_is_required_with_a_matching_collection(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                run = self.fixture.build(f"missing-controller-{stream}", "standard")
                (run / "output" / f"controller.{stream}.txt").unlink()
                self.fixture.refresh(run)
                self.assert_rejected_by_module_and_cli(
                    run, rf"missing required raw evidence:.*controller\.{stream}\.txt"
                )

    def test_each_controller_stream_receipt_detects_tampering(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                run = self.fixture.build(f"tampered-controller-{stream}", "standard")
                (run / "output" / f"controller.{stream}.txt").write_bytes(b"tampered stream")
                self.assert_rejected_by_module_and_cli(
                    run, rf"does not match its receipt: controller\.{stream}\.txt"
                )

    def test_observer_streams_cannot_replace_controller_streams(self):
        run = self.fixture.build("observer-only-streams", "standard")
        for stream in ("stdout", "stderr"):
            (run / "output" / f"controller.{stream}.txt").rename(
                run / "output" / f"observer.{stream}.txt"
            )
        self.fixture.refresh(run)
        self.assert_rejected_by_module_and_cli(
            run, r"missing required raw evidence:.*controller\.stderr\.txt.*controller\.stdout\.txt"
        )

    def test_each_controller_stream_rejects_symlinks_even_with_matching_bytes(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                run = self.fixture.build(f"linked-controller-{stream}", "standard")
                target = run / "output" / f"controller.{stream}.txt"
                outside = self.root / f"outside-{stream}.txt"
                outside.write_bytes(target.read_bytes())
                target.unlink()
                target.symlink_to(outside)
                self.assert_rejected_by_module_and_cli(run, "symlink")

    def test_cleanup_and_prelaunch_identity_fail_closed(self):
        cleanup = json.loads((self.standard / "output/cleanup.json").read_text())
        cleanup["guest"] = False
        write_json(self.standard / "output/cleanup.json", cleanup)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "cleanup.guest"):
            self.validate(self.standard)

        self.reset_fixture()
        (self.standard / "output/platform-preflight.json").unlink()
        with self.assertRaisesRegex(evidence.EvidenceError, "missing"):
            self.validate(self.standard)

    def test_actual_platform_and_requested_environment_must_match(self):
        platform = json.loads((self.standard / "output/platform-preflight.json").read_text())
        platform["guest_platform"]["system"] = "linux"
        write_json(self.standard / "output/platform-preflight.json", platform)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "Windows x86_64"):
            self.validate(self.standard)

        self.reset_fixture()
        result = json.loads((self.standard / "output/run-result.json").read_text())
        result["actual"]["monitor"]["width"] = 801
        write_json(self.standard / "output/run-result.json", result)
        with self.assertRaisesRegex(evidence.EvidenceError, "actual.monitor dimensions"):
            self.validate(self.standard)

    def test_boolean_numeric_and_nonfinite_json_are_rejected(self):
        result = json.loads((self.standard / "output/run-result.json").read_text())
        result["actual"]["monitor"]["width"] = True
        write_json(self.standard / "output/run-result.json", result)
        with self.assertRaisesRegex(evidence.EvidenceError, "must be an integer"):
            self.validate(self.standard)

        self.reset_fixture()
        raw = (self.standard / "output/run-result.json").read_text()
        (self.standard / "output/run-result.json").write_text(raw.replace('"exit_code": 0', '"exit_code": NaN'))
        with self.assertRaisesRegex(evidence.EvidenceError, "non-finite"):
            self.validate(self.standard)

        self.reset_fixture()
        raw_path = self.standard / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["schema_version"] = True
        write_json(raw_path, raw)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "schema_version must be integer"):
            self.validate(self.standard)

    def test_duplicate_json_fields_are_rejected(self):
        path = self.standard / "output/run-result.json"
        raw = path.read_text()
        path.write_text(raw.replace('{\n  "schema_version": 1,', '{\n  "schema_version": 1,\n  "schema_version": 1,'))
        with self.assertRaisesRegex(evidence.EvidenceError, "duplicate field"):
            self.validate(self.standard)

    def test_traversal_self_reference_and_cycle_are_rejected(self):
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        manifest["artifacts"]["observer"]["file"] = "../observer.ps1"
        write_json(self.standard / "input-manifest.json", manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "unsafe path"):
            self.validate(self.standard)

        self.reset_fixture()
        manifest = json.loads((self.tooltip / "input-manifest.json").read_text())
        manifest["full_context_reference"]["run_id"] = self.tooltip.name
        write_json(self.tooltip / "input-manifest.json", manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "reference itself"):
            self.validate(self.tooltip)

        self.reset_fixture()
        manifest = json.loads((self.full / "input-manifest.json").read_text())
        manifest["full_context_reference"] = self.fixture.reference(self.tooltip)
        write_json(self.full / "input-manifest.json", manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "Only the tooltip"):
            self.validate(self.full)

    def test_reference_manifest_and_result_digests_are_enforced(self):
        manifest = json.loads((self.tooltip / "input-manifest.json").read_text())
        manifest["full_context_reference"]["result_sha256"] = "0" * 64
        write_json(self.tooltip / "input-manifest.json", manifest)
        self.fixture.refresh(self.tooltip)
        with self.assertRaisesRegex(evidence.EvidenceError, "result digest"):
            self.validate(self.tooltip)

        self.reset_fixture()
        manifest = json.loads((self.tooltip / "input-manifest.json").read_text())
        manifest["full_context_reference"]["input_manifest_sha256"] = "0" * 64
        write_json(self.tooltip / "input-manifest.json", manifest)
        self.fixture.refresh(self.tooltip)
        with self.assertRaisesRegex(evidence.EvidenceError, "input manifest digest"):
            self.validate(self.tooltip)

    def test_collection_and_cleanup_are_transitively_pinned(self):
        result = json.loads((self.full / "output/run-result.json").read_text())
        result["collection_sha256"] = "0" * 64
        write_json(self.full / "output/run-result.json", result)
        with self.assertRaisesRegex(evidence.EvidenceError, "collection.json"):
            self.validate(self.full)

        self.reset_fixture()
        result = json.loads((self.full / "output/run-result.json").read_text())
        result["cleanup_sha256"] = "0" * 64
        write_json(self.full / "output/run-result.json", result)
        with self.assertRaisesRegex(evidence.EvidenceError, "cleanup.json"):
            self.validate(self.full)

    def test_text_metrics_bind_png_bytes_and_compare_the_same_glyphs(self):
        baseline = self.validate(self.standard)
        enlarged = self.validate(self.text)
        evidence.validate_text_pair([baseline, enlarged])

        metrics = json.loads((self.text / "output/text-raster-metrics.json").read_text())
        metrics["samples"][0]["ink_bounds"]["height"] += 1
        write_json(self.text / "output/text-raster-metrics.json", metrics)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "ink bounds"):
            self.validate(self.text)

        self.reset_fixture()
        metrics = json.loads((self.text / "output/text-raster-metrics.json").read_text())
        metrics["samples"][0]["text_sha256"] = "f" * 64
        metrics["samples"][0]["observed_target"]["text_sha256"] = "f" * 64
        write_json(self.text / "output/text-raster-metrics.json", metrics)
        observations = json.loads((self.text / "output/acceptance-observations.json").read_text())
        observations["text_raster_targets"][0]["text_sha256"] = "f" * 64
        write_json(self.text / "output/acceptance-observations.json", observations)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "exact observed control text"):
            self.validate(self.text)

    def test_unexpected_output_file_is_rejected(self):
        (self.standard / "output/unreceipted.log").write_text("unexpected")
        with self.assertRaisesRegex(evidence.EvidenceError, "inventory"):
            self.validate(self.standard)

    def test_all_true_summary_cannot_hide_failed_deep_raw_evidence(self):
        raw_path = self.standard / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        normalized = json.loads((self.standard / "output/run-result.json").read_text())
        self.assertTrue(all(normalized["assertions"]["semantics"].values()))
        self.assertNotIn("semantic_assertions", raw["assertions"]["scenario"])
        raw["assertions"]["scenario"]["actual_apply"]["content_and_identity_preserved"] = False
        write_json(raw_path, raw)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "Raw scenario evidence.*content_preserved"):
            self.validate(self.standard)

        self.reset_fixture()
        raw_path = self.standard / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["assertions"]["scenario"]["journal_residue_count"] = False
        raw["assertions"]["scenario"]["normal_exit_code"] = False
        write_json(raw_path, raw)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "journal_clean|normal_exit"):
            self.validate(self.standard)

    def test_apply_entry_requires_a_real_public_ui_path(self):
        self.validate(self.standard)
        self.validate(self.tooltip)

        raw_path = self.standard / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["assertions"]["scenario"]["actual_apply"]["apply_entry"] = physical_menu_apply_entry()
        write_json(raw_path, raw)
        self.fixture.refresh(self.standard)
        self.validate(self.standard)

        physical_without_target = physical_menu_apply_entry()
        del physical_without_target["menu_entry"]["apply_target"]
        physical_with_extra = physical_menu_apply_entry()
        physical_with_extra["menu_entry"]["unexpected"] = True
        physical_with_bool_coordinate = physical_menu_apply_entry()
        physical_with_bool_coordinate["menu_entry"]["file_target"]["x"] = True
        physical_with_bool_element = physical_menu_apply_entry()
        physical_with_bool_element["menu_entry"]["apply"]["enabled"] = 1
        physical_out_of_bounds = physical_menu_apply_entry()
        physical_out_of_bounds["menu_entry"]["apply_target"]["x"] = 900
        invalid_entries = {
            "unknown input": {"input": "unknown-public-path", "menu_entry": None},
            "old arbitrary strings": {"input": "physical-mouse", "menu_entry": "public-apply"},
            "rail with menu": {"input": "visible-command-rail", "menu_entry": {}},
            "physical without menu": {"input": "physical-mouse-file-menu-public-apply", "menu_entry": None},
            "missing menu field": physical_without_target,
            "extra menu field": physical_with_extra,
            "boolean target coordinate": physical_with_bool_coordinate,
            "non-boolean element state": physical_with_bool_element,
            "target outside paired bounds": physical_out_of_bounds,
        }
        for label, entry in invalid_entries.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = Fixture(root)
                run = fixture.build("02-standard-light-800x600-96-text100", "standard")
                path = run / "output/acceptance-result.json"
                value = json.loads(path.read_text())
                value["assertions"]["scenario"]["actual_apply"]["apply_entry"] = entry
                write_json(path, value)
                fixture.refresh(run)
                with self.assertRaisesRegex(evidence.EvidenceError, "application_confirmed"):
                    evidence.validate_run(root, run.name, SOURCE)

        tooltip_path = self.tooltip / "output/acceptance-result.json"
        tooltip = json.loads(tooltip_path.read_text())
        tooltip["assertions"]["scenario"]["surface"]["confirmation"]["apply_entry"] = {
            "input": "visible-command-rail", "menu_entry": None,
        }
        write_json(tooltip_path, tooltip)
        self.fixture.refresh(self.tooltip)
        with self.assertRaisesRegex(evidence.EvidenceError, "public_apply_entered"):
            self.validate(self.tooltip)

    def test_raw_observation_mirror_is_type_sensitive(self):
        observations_path = self.standard / "output/acceptance-observations.json"
        observations = json.loads(observations_path.read_text())
        observations["scenario"]["journal_residue_count"] = False
        write_json(observations_path, observations)
        self.fixture.refresh(self.standard, sync_observations=False)
        with self.assertRaisesRegex(evidence.EvidenceError, "do not exactly mirror"):
            self.validate(self.standard)

    def test_fixed_tuple_windows11_and_complete_set_bindings_are_enforced(self):
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        manifest["request"]["desktop"]["width"] = 900
        write_json(self.standard / "input-manifest.json", manifest)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "fixed four-cell"):
            self.validate(self.standard)

        self.reset_fixture()
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        manifest["guest_preflight"]["product_caption"] = "Microsoft Windows 10 Pro"
        manifest["guest_preflight"]["build"] = "19045"
        write_json(self.standard / "input-manifest.json", manifest)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "Windows 11"):
            self.validate(self.standard)

        self.reset_fixture()
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        app = self.standard / manifest["artifacts"]["application"]["file"]
        app.write_bytes(b"different-standard-application")
        manifest["artifacts"]["application"].update(bytes=app.stat().st_size, sha256=digest(app.read_bytes()))
        write_json(self.standard / "input-manifest.json", manifest)
        self.fixture.refresh(self.standard)
        command = ["python3", str(SCRIPT), "--result-root", str(self.root),
                   "--expected-source-sha", SOURCE, "--require-complete-set"]
        for run in (self.full, self.standard, self.text, self.tooltip):
            command += ["--run", run.name]
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("different executables", completed.stderr)

    def test_tooltip_requires_full_canonical_lifecycle(self):
        raw_path = self.tooltip / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        del raw["assertions"]["scenario"]["surface"]["confirmation"]["full_details"]
        write_json(raw_path, raw)
        self.fixture.refresh(self.tooltip)
        with self.assertRaisesRegex(evidence.EvidenceError, "full_details_exact_document"):
            self.validate(self.tooltip)

    def test_text_reachability_and_native_crop_binding_are_enforced(self):
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        for row in raw["assertions"]["scenario"]["confirmation"]["tree"]:
            if row.get("automation_id") in {
                    "CommandLink_1101", "CommandLink_1102", "ExpandoButton", "CommandButton_2"}:
                row["bounds"] = {"x": 10.25, "y": 10.5, "width": 40.25, "height": 20.5}
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        self.validate(self.text)

        self.reset_fixture()
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["assertions"]["scenario"]["confirmation"]["reachability"]["apply"]["physical_mouse_target"]["hit_window"] = 0
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "required_controls_reachable"):
            self.validate(self.text)

        self.reset_fixture()
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        tree = raw["assertions"]["scenario"]["confirmation"]["tree"]
        next(row for row in tree if row.get("automation_id") == "CommandLink_1101")["bounds"]["width"] = True
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "required_controls_reachable"):
            self.validate(self.text)

        self.reset_fixture()
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        tree = raw["assertions"]["scenario"]["confirmation"]["tree"]
        next(row for row in tree if row.get("automation_id") == "CommandLink_1101")["bounds"]["x"] = float("inf")
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "non-finite"):
            self.validate(self.text)

        self.reset_fixture()
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        tree = raw["assertions"]["scenario"]["confirmation"]["tree"]
        next(row for row in tree if row.get("automation_id") == "CommandLink_1101")["bounds"]["x"] = -0.5
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "required_controls_reachable"):
            self.validate(self.text)

        self.reset_fixture()
        metrics_path = self.text / "output/text-raster-metrics.json"
        metrics = json.loads(metrics_path.read_text())
        target = metrics["samples"][0]["observed_target"]
        target["control_rect"] = {"left": 40, "top": 0, "right": 80, "bottom": 30,
                                  "width": 40, "height": 30}
        write_json(metrics_path, metrics)
        observations = json.loads((self.text / "output/acceptance-observations.json").read_text())
        observations["text_raster_targets"][0] = target
        write_json(self.text / "output/acceptance-observations.json", observations)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "crop lies outside"):
            self.validate(self.text)

    def test_result_root_symlink_ancestor_is_rejected(self):
        actual_parent = self.root / "actual-parent"
        actual_root = actual_parent / "evidence"
        actual_root.mkdir(parents=True)
        alias = self.root / "alias-parent"
        alias.symlink_to(actual_parent, target_is_directory=True)
        with self.assertRaisesRegex(evidence.EvidenceError, "symlink ancestor"):
            evidence.checked_root(alias / "evidence")

    def test_deep_json_reports_a_validation_error(self):
        with self.assertRaisesRegex(evidence.EvidenceError, "not strict UTF-8 JSON"):
            evidence.parse_json_bytes(b"[" * 20000 + b"0" + b"]" * 20000, "deep")

    def test_vm_identity_kind_and_independent_postlaunch_receipt_are_enforced(self):
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        manifest["guest_preflight"]["vm_identity_kind"] = "win32-computersystemproduct-uuid"
        write_json(self.standard / "input-manifest.json", manifest)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "VM identity source"):
            self.validate(self.standard)

        self.reset_fixture()
        (self.standard / "output/platform-postlaunch.json").unlink()
        with self.assertRaisesRegex(evidence.EvidenceError, "missing"):
            self.validate(self.standard)

        self.reset_fixture()
        post = json.loads((self.standard / "output/platform-postlaunch.json").read_text())
        post["vm_identity_sha256"] = "f" * 64
        write_json(self.standard / "output/platform-postlaunch.json", post)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "postlaunch VM identity differs"):
            self.validate(self.standard)

        self.reset_fixture()
        post = json.loads((self.standard / "output/platform-postlaunch.json").read_text())
        post["target"]["process_id"] = 5252
        post["identity_observation"]["target_process_id"] = 5252
        write_json(self.standard / "output/platform-postlaunch.json", post)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "Normalized target differs"):
            self.validate(self.standard)

    def test_transport_requires_collection_bound_terminal_zero_exit(self):
        (self.standard / "output/transport.json").unlink()
        with self.assertRaisesRegex(evidence.EvidenceError, "missing"):
            self.validate(self.standard)

        for field, value, error in (("status", "failed", "transport status"),
                                    ("guest_cleanup", False, "guest cleanup")):
            self.reset_fixture()
            transport_path = self.standard / "output/transport.json"
            transport = json.loads(transport_path.read_text())
            transport[field] = value
            write_json(transport_path, transport)
            self.fixture.refresh(self.standard)
            with self.assertRaisesRegex(evidence.EvidenceError, error):
                self.validate(self.standard)

        self.reset_fixture()
        transport_path = self.standard / "output/transport.json"
        transport = json.loads(transport_path.read_text())
        del transport["observer_process"]
        write_json(transport_path, transport)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "observer_process"):
            self.validate(self.standard)

        self.reset_fixture()
        transport_path = self.standard / "output/transport.json"
        transport = json.loads(transport_path.read_text())
        transport["observer_process"]["state"] = "running"
        write_json(transport_path, transport)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "terminal state"):
            self.validate(self.standard)

        for exit_code in (False, 7):
            self.reset_fixture()
            transport_path = self.standard / "output/transport.json"
            transport = json.loads(transport_path.read_text())
            transport["observer_process"]["exit_code"] = exit_code
            write_json(transport_path, transport)
            self.fixture.refresh(self.standard)
            normalized = json.loads((self.standard / "output/run-result.json").read_text())
            self.assertEqual(normalized["exit_code"], 0)
            with self.assertRaisesRegex(evidence.EvidenceError, "terminal exit code"):
                self.validate(self.standard)


class AppearancePairEvidenceTests(SyntheticFixtureTestCase):
    def test_pair_fixture_does_not_follow_changed_verifier_scene_inventory(self):
        with mock.patch.object(evidence, "PAIR_SCENES", ("unexpected-scene",)):
            run = self.pair_run
            raw = json.loads((run / "output" / "acceptance-result.json").read_text())
            self.assertEqual(set(raw["assertions"]["scenario"]["scenes"]), {
                "empty", "unchanged", "overflow", "changed", "collision", "warning",
                "selected-active", "selected-inactive",
            })
            with self.assertRaises(evidence.EvidenceError):
                self.validate()

    @cached_property
    def pair_run(self):
        return self.fixture.build_pair()

    def validate(self):
        return evidence.validate_pair_run(self.root, self.pair_run.name, SOURCE)

    def v2_transport(self):
        """Bind a synthetic V2 cleanup record to the paired observer result."""
        manifest_path = self.pair_run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        profile = (SCRIPT_ROOT.parent / "config" / "vm-automated-v2.json").read_bytes()
        profile_path = self.pair_run / "inputs" / "vm-automated-v2.json"
        profile_path.write_bytes(profile)
        profile_hash = digest(profile)
        manifest["acceptance_profile_id"] = "vm-automated-v2-owned-resources"
        manifest["acceptance_profile_sha256"] = profile_hash
        manifest["acceptance_profile"] = {
            "file": "inputs/vm-automated-v2.json", "bytes": len(profile), "sha256": profile_hash,
        }
        manifest["command"] += ["--acceptance-profile-id", "vm-automated-v2-owned-resources"]
        write_json(manifest_path, manifest)
        raw_path = self.pair_run / "output" / "acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        jobs = clean_controller_cleanup_v2()["owned_resource_evidence"]["process_job_cleanup"]
        jobs[0]["pid"] = raw["assertions"]["scenario"]["process_id"]
        second_job = deepcopy(jobs[0])
        second_job["pid"] = raw["assertions"]["scenario"]["default_columns"]["process_id"]
        second_job["process_start_time_utc_ticks"] = "134041000000000005"
        jobs.append(second_job)
        cleanup = clean_controller_cleanup_v3(
            profile_sha256=profile_hash, process_jobs=jobs, source_sha=manifest["source_sha"],
            bundle_sha256=manifest["bundle_manifest"]["sha256"])
        owned = cleanup["owned_resource_evidence"]
        raw["process_job_cleanup"] = owned["process_job_cleanup"]
        raw["observer_lifecycle"] = owned["task_execution"]["observer_lifecycle"]
        write_json(raw_path, raw)
        transport_path = self.pair_run / "output" / "transport.json"
        transport = json.loads(transport_path.read_text())
        transport["raw_cleanup"] = cleanup
        transport["vm_id"] = cleanup["owned_resource_evidence"]["protected_anchor"]["vm_id"]
        GuiEvidenceTests.bind_v2_fixture_vm(self.pair_run, manifest, transport)
        write_json(transport_path, transport)
        self.fixture.refresh(self.pair_run)
        return manifest, transport, raw

    def check_v2_transport(self, manifest, transport, raw):
        transport_path = self.pair_run / "output" / "transport.json"
        write_json(transport_path, transport)
        receipt = {"bytes": len(transport_path.read_bytes()),
                   "sha256": digest(transport_path.read_bytes())}
        evidence.validate_pair_transport(self.pair_run, {"transport.json": receipt}, 0, manifest, raw)

    def test_fixture_reset_and_same_path_edits_remain_independent(self):
        command = ["python3", "-I", str(SCRIPT), "--result-root", str(self.root),
                   "--expected-source-sha", SOURCE, "--diagnostic", evidence.PAIR_MODE,
                   "--run", self.pair_run.name]
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["status"], "passed")
        path = self.pair_run / "output/acceptance-result.json"
        original = path.read_bytes()
        raw = json.loads(original)
        raw["assertions"]["scenario"]["default_columns"]["fixture"]["settings_absent_before_launch"] = False
        write_json(path, raw)
        self.fixture.refresh(self.pair_run)
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertRegex(completed.stderr, "preseeded")
        self.assertEqual(completed.stdout, "")
        path.write_bytes(original)
        self.fixture.refresh(self.pair_run)
        self.assertEqual(self.validate()["status"], "passed")
        old_root = self.root
        for label in ("dark", "light", "dark"):
            with self.subTest(reset=label):
                image = pair_png((36, 36, 36) if label == "dark" else (245, 245, 245))
                (self.pair_run / "output/appearance-native-menu-light-before.png").write_bytes(b"poisoned")
                self.reset_fixture()
                self.assertFalse(old_root.exists())
                self.assertEqual(pair_png((36, 36, 36) if label == "dark" else (245, 245, 245)), image)
                self.assertEqual(self.validate()["status"], "passed")
                old_root = self.root

    def test_v2_pair_accepts_bound_owned_cleanup_with_ambient_processes(self):
        manifest, transport, raw = self.v2_transport()
        self.assertTrue(transport["raw_cleanup"]["unexpected_runner_processes"])
        self.check_v2_transport(manifest, transport, raw)
        self.assertEqual(self.validate()["status"], "passed")

    def test_v2_pair_rejects_unbound_profile_artifact_and_selection(self):
        manifest, _, _ = self.v2_transport()
        profile_path = self.pair_run / "inputs" / "vm-automated-v2.json"
        manifest_path = self.pair_run / "input-manifest.json"
        original_profile = profile_path.read_bytes()
        mutations = (
            lambda value: value.pop("acceptance_profile_sha256"),
            lambda value: value.pop("acceptance_profile"),
            lambda value: value.__setitem__("acceptance_profile_sha256", "0" * 64),
            lambda value: value["command"].remove("--acceptance-profile-id"),
            lambda value: value.__setitem__("acceptance_profile_id", "unknown-profile"),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                current = deepcopy(manifest)
                mutate(current)
                write_json(manifest_path, current)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_input_manifest(self.pair_run, SOURCE)
        write_json(manifest_path, manifest)
        profile_path.write_bytes(original_profile + b" ")
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_input_manifest(self.pair_run, SOURCE)
        original_document = json.loads(original_profile)
        for field, value in (("profile_id", "unexpected-v2"), ("revision", 2)):
            with self.subTest(profile_field=field):
                changed = {**original_document, field: value}
                changed_bytes = json_bytes(changed)
                profile_path.write_bytes(changed_bytes)
                current = deepcopy(manifest)
                current["acceptance_profile_sha256"] = digest(changed_bytes)
                current["acceptance_profile"] = {
                    **current["acceptance_profile"], "bytes": len(changed_bytes),
                    "sha256": digest(changed_bytes),
                }
                write_json(manifest_path, current)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_input_manifest(self.pair_run, SOURCE)

    def test_v2_pair_rejects_wrong_profile_hash_and_incomplete_owned_cleanup(self):
        manifest, transport, raw = self.v2_transport()
        mutations = (
            lambda m, t, r: m.__setitem__("acceptance_profile_sha256", "0" * 64),
            lambda m, t, r: t["raw_cleanup"].__setitem__("owned_processes_after", [3001]),
            lambda m, t, r: t["raw_cleanup"]["owned_resource_evidence"]["process_snapshots"]["after_delete"].__setitem__("complete", False),
            lambda m, t, r: t["raw_cleanup"]["owned_resource_evidence"]["task_snapshots"]["after_delete"].append({"name": "unexpected-task"}),
            lambda m, t, r: r.__setitem__("process_job_cleanup", []),
            lambda m, t, r: r.__setitem__("observer_lifecycle", {"pid": 9999}),
            lambda m, t, r: r["assertions"]["scenario"].__setitem__("process_id", 9999),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                current_manifest, current_transport, current_raw = (deepcopy(manifest), deepcopy(transport), deepcopy(raw))
                mutate(current_manifest, current_transport, current_raw)
                with self.assertRaises(ValueError):
                    self.check_v2_transport(current_manifest, current_transport, current_raw)

    def test_focused_pair_rejects_mixed_acceptance_profiles(self):
        pairs = [
            {"run_id": run_id, "application_sha256": "a" * 64,
             "build_identity": {"acceptance_profile_id": evidence.V2_PROFILE_ID,
                                "acceptance_profile_sha256": "b" * 64}}
            for run_id in evidence.PAIR_CONFIGURATIONS
        ]
        for key, value in (("acceptance_profile_id", evidence.V1_PROFILE_ID),
                           ("acceptance_profile_sha256", "c" * 64)):
            with self.subTest(key=key):
                changed = deepcopy(pairs)
                changed[-1]["build_identity"][key] = value
                with self.assertRaisesRegex(evidence.EvidenceError, "same build bundle"):
                    evidence.validate_focused_pair_results(changed)

    def high_contrast_probe(self):
        """Exercise three bound System captures without decoding the 66-scene pair."""
        actual = json.loads((self.pair_run / "output/run-result.json").read_text())["actual"]
        base = json.loads((self.pair_run / "output/acceptance-result.json").read_text())
        base_state = base["assertions"]["scenario"]["scenes"]["warning"][0]["state"]
        colors = {"window": 0xFFFFFF, "window_text": 0x000000, "button_face": 0xF0F0F0,
                  "button_text": 0, "highlight": 0x006080, "highlight_text": 0xFFFFFF,
                  "gray_text": 0x808080, "hot_light": 0x808080}
        active_colors = {**colors, "window": 0, "window_text": 0x00FFFF,
                         "highlight_text": 0}
        original = {"flags": 0, "scheme": "fixture-scheme", "colors": colors,
                    "visual_style": {"path": "fixture-theme", "color": "NormalColor", "size": "NormalSize"}}
        document = {"schema_version": 2, "source_sha": SOURCE,
                    "acceptance_script_sha256": base["acceptance_script_sha256"],
                    "restoration_required": False, "restoration_verified": True,
                    "original": original, "restored": json.loads(json.dumps(original))}
        name = "high-contrast-restore.json"
        path = self.pair_run / "output" / name
        def bind_document():
            write_json(path, document)
            reference = {"file": name, "sha256": digest(path.read_bytes())}
            base["high_contrast"] = {"requested": True, "restoration": "verified", "snapshot": reference}
            base["assertions"]["scenario"]["high_contrast"]["snapshot"] = reference
            return {name: {"sha256": reference["sha256"]}}

        pixels = {}
        def raster(selected, unselected):
            width, height = 800, 552
            data = bytearray(bytes((245, 245, 245, 255)) * (width * height))
            for left, top, right, bottom, rgb in ((265, 146, 282, 154, selected),
                                                   (325, 176, 342, 184, unselected)):
                for y in range(top, bottom):
                    data[(y * width + left) * 4:(y * width + right) * 4] = bytes((*rgb, 255)) * (right - left)
            return bytes(data)

        for key, phase in (("before", "before"), ("active", "forced-colors"), ("after", "after")):
            active = key == "active"
            state = {
                "phase": phase, "appearance": "system", "row_count": 60,
                "current_names": base_state["current_names"],
                "resolution": {"query": "UISettings.GetColorValue(UIColorType.Foreground)+SPI_GETHIGHCONTRAST",
                               "foreground_argb": [255, 0, 0, 0],
                               "resolved_theme": "native" if active else "light",
                               "system_visual_style": {"forced_colors": active}},
                "appearance_menu": {"hwnd": 1001, "pid": 4242, "menu_checked": [
                    {"command_id": 0x9010, "checked": True},
                    {"command_id": 0x9011, "checked": False},
                    {"command_id": 0x9012, "checked": False}]},
                "native_window": base_state["window"], "native_list": base_state["native_list"],
                "native_focus": [2001, 0, 1000], "target_rendering": base_state["target_rendering"],
                "overlay": {"visible_tooltip_count": 0, "neutral_cursor": True},
                "selection": {"count": 1, "name": base_state["current_names"][0]},
                "semantic_cells": {
                    "selected": {"name": ".txt", "offscreen": False,
                                 "bounds": {"x": 260, "y": 140, "width": 40, "height": 20}},
                    "unselected": {"name": ".log", "offscreen": False,
                                   "bounds": {"x": 320, "y": 170, "width": 40, "height": 20}}},
                "proposal_viewport": base_state["proposal_viewport"],
                "horizontal_scroll": base_state["horizontal_scroll"],
                "vertical_scroll": base_state["vertical_scroll"],
                "horizontal_components": [1, 2], "vertical_components": [3, 4],
                "colors": active_colors if active else colors,
                "capture": {"file": f"appearance-system-{phase}.png"},
            }
            base["assertions"]["scenario"].setdefault("high_contrast", {})[key] = state
            pixels[state["capture"]["file"]] = raster((0, 0, 0) if active else (255, 255, 255),
                                                       (255, 255, 0) if active else (142, 83, 0))
        contrast = base["assertions"]["scenario"]["high_contrast"]
        contrast.update({"snapshot": None, "restoration_verified": True,
                         "original_enabled": False, "acceptance_enabled": True})
        files = bind_document()
        def capture_pixels(receipt, expected_name, appearance, surface):
            self.assertEqual((receipt["file"], appearance, surface),
                             (expected_name, "system", "main-workbench"))
            return 800, 552, pixels[expected_name]
        return base, files, actual, capture_pixels, document, bind_document, pixels

    def test_high_contrast_probe_binds_original_system_restoration(self):
        raw, files, actual, capture_pixels, _, _, _ = self.high_contrast_probe()
        rows = evidence.validate_pair_high_contrast(self.pair_run, raw, files, actual, capture_pixels)
        self.assertEqual([row["resolved_theme"] for row in rows], ["light", "native", "light"])

    def test_high_contrast_probe_rejects_wrong_snapshot_identity_and_pending_rescue(self):
        for field, value, diagnostic in (
            ("source_sha", "f" * 40, "scope or original state"),
            ("acceptance_script_sha256", "f" * 64, "scope or original state"),
            ("restoration_verified", False, "scope or original state"),
            ("restoration_required", True, "rescue is still pending"),
        ):
            with self.subTest(field=field):
                raw, files, actual, capture_pixels, document, bind_document, _ = self.high_contrast_probe()
                document[field] = value
                files = bind_document()
                with self.assertRaisesRegex(evidence.EvidenceError, diagnostic):
                    evidence.validate_pair_high_contrast(self.pair_run, raw, files, actual, capture_pixels)

    def test_high_contrast_probe_rejects_unchanged_palette_and_native_selection_override(self):
        raw, files, actual, capture_pixels, _, _, pixels = self.high_contrast_probe()
        active = raw["assertions"]["scenario"]["high_contrast"]["active"]
        active["colors"] = raw["assertions"]["scenario"]["high_contrast"]["before"]["colors"]
        active_pixels = bytearray(pixels["appearance-system-before.png"])
        for y in range(176, 184):
            active_pixels[(y * 800 + 325) * 4:(y * 800 + 342) * 4] = b"\x00\x00\x00\xff" * 17
        pixels["appearance-system-forced-colors.png"] = bytes(active_pixels)
        with self.assertRaisesRegex(evidence.EvidenceError, "did not bind or change"):
            evidence.validate_pair_high_contrast(self.pair_run, raw, files, actual, capture_pixels)

        raw, files, actual, capture_pixels, _, _, pixels = self.high_contrast_probe()
        name = "appearance-system-forced-colors.png"
        pixels[name] = pixels["appearance-system-before.png"]
        with self.assertRaisesRegex(evidence.EvidenceError, "warning or native selection color precedence"):
            evidence.validate_pair_high_contrast(self.pair_run, raw, files, actual, capture_pixels)

    def test_high_contrast_probe_rejects_system_endpoint_raster_change(self):
        raw, files, actual, capture_pixels, _, _, pixels = self.high_contrast_probe()
        changed = bytearray(pixels["appearance-system-after.png"])
        offset = (240 * 800 + 400) * 4
        changed[offset:offset + 3] = b"\x00\x00\x00"
        pixels["appearance-system-after.png"] = bytes(changed)
        with self.assertRaisesRegex(evidence.EvidenceError, "endpoint client raster did not restore"):
            evidence.validate_pair_high_contrast(self.pair_run, raw, files, actual, capture_pixels)

    def test_focused_configuration_set_requires_five_runs_one_executable_and_same_glyph_scale(self):
        font = {"family": "Segoe UI", "weight": 400, "charset": 1, "quality": 5,
                "italic": 0, "underline": 0, "strikeout": 0, "height": -12}
        environment = {"installed_fonts": {"family_names_sha256": "a" * 64},
                       "system_fonts": {"MessageFont": font, "StatusFont": font}}
        phases = ("light-before", "dark", "light-after")
        pairs = []
        for run_id in evidence.PAIR_CONFIGURATIONS:
            enlarged = "text150" in run_id
            pairs.append({"run_id": run_id, "application_sha256": "e" * 64,
                          "build_identity": {"source_tree": "a" * 40, "bundle_manifest_sha256": "b" * 64,
                                             "artifact_sha256": {"observer": "c" * 64, "application": "e" * 64}},
                          "font_environment": deepcopy(environment),
                          "raster_regions": {"same_glyph": [
                              {"phase": phase, "text_sha256": "f" * 64,
                               "width": 24 if enlarged else 20, "height": 12 if enlarged else 10}
                              for phase in phases]}})
        evidence.validate_focused_pair_results(pairs)
        baseline = next(row for row in pairs if "base-" in row["run_id"])
        text150 = next(row for row in pairs if "text150" in row["run_id"])
        for label, mutate, diagnostic in (
            ("missing run", lambda rows: rows.pop(), "incomplete or duplicated"),
            ("duplicate run", lambda rows: rows[-1].update(run_id=rows[0]["run_id"]), "incomplete or duplicated"),
            ("executable", lambda rows: rows[-1].update(application_sha256="0" * 64), "same executable"),
            ("bundle", lambda rows: rows[-1]["build_identity"].update(bundle_manifest_sha256="0" * 64), "same build bundle"),
            ("artifact", lambda rows: rows[-1]["build_identity"]["artifact_sha256"].update(observer="0" * 64), "same build bundle"),
            ("tree", lambda rows: rows[-1]["build_identity"].update(source_tree="0" * 40), "same build bundle"),
            ("installed fonts", lambda rows: next(row for row in rows if "text150" in row["run_id"])
             ["font_environment"]["installed_fonts"].update(family_names_sha256="0" * 64), "font family environment"),
            ("font identity", lambda rows: next(row for row in rows if "text150" in row["run_id"])
             ["font_environment"]["system_fonts"]["MessageFont"].update(family="Other"), "font family environment"),
            ("glyph digest", lambda rows: next(row for row in rows if "text150" in row["run_id"])
             ["raster_regions"]["same_glyph"][1].update(text_sha256="0" * 64), "same glyphs"),
            ("width", lambda rows: next(row for row in rows if "text150" in row["run_id"])
             ["raster_regions"]["same_glyph"][0].update(width=23), "both dimensions"),
            ("height", lambda rows: next(row for row in rows if "text150" in row["run_id"])
             ["raster_regions"]["same_glyph"][2].update(height=11), "both dimensions"),
            ("missing phase", lambda rows: [row["raster_regions"]["same_glyph"].pop()
             for row in rows if row["run_id"] in {baseline["run_id"], text150["run_id"]}], "phase set"),
        ):
            with self.subTest(label=label):
                changed = deepcopy(pairs)
                mutate(changed)
                with self.assertRaisesRegex(evidence.EvidenceError, diagnostic):
                    evidence.validate_focused_pair_results(changed)

    def test_pair_has_69_bound_captures_and_distinct_verdict(self):
        raw = json.loads((self.pair_run / "output/acceptance-result.json").read_text())
        scenes = raw["assertions"]["scenario"]["scenes"]
        self.assertIs(scenes["selected-active"][0]["state"]["selected_row_cell"]["keyboard_focusable"], True)
        self.assertIs(scenes["selected-inactive"][0]["state"]["selected_row_cell"]["keyboard_focusable"], False)
        result = self.validate()
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["native_scrollbar_theme"], "dark-tracking-and-intersection-validated")
        self.assertEqual(result["transition_preservation"]["status"], "passed")
        self.assertEqual(result["clean_default_columns"]["status"], "passed")
        self.assertEqual(set(result["raster_regions"]),
                         set(evidence.PAIR_SCENES) | {"selection_transition", "native_menu", "interactions", "scrollbar_tracking", "same_glyph"})

    def test_transition_rejects_raw_axis_resets_and_changed_row_values(self):
        raw = json.loads((self.pair_run / "output/acceptance-result.json").read_text())
        actual = json.loads((self.pair_run / "output/run-result.json").read_text())["actual"]
        scenario = raw["assertions"]["scenario"]
        self.assertEqual(evidence.validate_pair_transition(scenario, raw, actual)["status"], "passed")
        def reset_axis(probe, index, axis):
            sample = probe["observations"][index]
            for receipt in (sample, sample["observer_read_native_after"], sample["settlement"]):
                receipt[axis][3] = 0
        cases = (
            ("horizontal reset", lambda probe: reset_axis(probe, 1, "horizontal_scroll"), "non-minimum"),
            ("vertical reset", lambda probe: reset_axis(probe, 3, "vertical_scroll"), "non-minimum"),
            ("missing snapshot", lambda probe: probe["observations"].pop(), "missing or reordered"),
            ("reordered snapshot", lambda probe: probe["observations"].reverse(), "missing or reordered"),
            ("different process", lambda probe: probe["observations"][1].__setitem__("process_id", 9000), "scene state changed"),
            ("changed proposed value", lambda probe: probe["observations"][1]["row_values"][0].__setitem__(1, "changed"), "scene state changed"),
            ("changed order", lambda probe: probe["observations"][1]["column_order"].reverse(), "scene state changed"),
            ("changed client", lambda probe: probe["observations"][1]["list_client_bounds"].__setitem__(2, 620), "scene state changed"),
            ("missing reread", lambda probe: probe["observations"][1].pop("observer_read_native_after"), "snapshot"),
            ("observer induced scroll", lambda probe: probe["observations"][1]["observer_read_native_after"]["horizontal_scroll"].__setitem__(3, 541), "observer changed"),
            ("missing settlement", lambda probe: probe["observations"][1].pop("settlement"), "snapshot"),
        )
        for label, mutate, message in cases:
            with self.subTest(label=label):
                changed = deepcopy(scenario)
                mutate(changed["transition_preservation"])
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    evidence.validate_pair_transition(changed, raw, actual)
        old = deepcopy(scenario)
        del old["transition_preservation"]
        with self.assertRaisesRegex(evidence.EvidenceError, "transition preservation"):
            evidence.validate_pair_transition(old, raw, actual)

    def test_whole_pair_rejects_raw_reset_even_with_matching_normalized_scenes(self):
        path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        sample = raw["assertions"]["scenario"]["transition_preservation"]["observations"][1]
        for receipt in (sample, sample["observer_read_native_after"], sample["settlement"]):
            receipt["horizontal_scroll"][3] = 0
        write_json(path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "non-minimum committed position"):
            self.validate()

    def test_clean_default_rejects_custom_input_missing_phase_and_changed_column(self):
        raw = json.loads((self.pair_run / "output/acceptance-result.json").read_text())
        actual = json.loads((self.pair_run / "output/run-result.json").read_text())["actual"]
        files = {row["relative_path"]: row for row in json.loads((self.pair_run / "collection.json").read_text())["files"]}
        self.assertEqual(evidence.validate_pair_default_columns(self.pair_run, raw, files, actual)["status"], "passed")
        steps = raw["assertions"]["scenario"]["default_columns"]["steps"]
        self.assertEqual([step["state"]["overlay"]["dismissed_tooltip_count"]
                          for step in steps], [0, 1, 0])
        # The dark native file icon shares the text color inside column zero.
        # A whole-cell ink bound is wider even though the text itself is stable.
        state = steps[0]["state"]
        bounds = state["current_name_cell"]["bounds"]
        window = state["window"]["rect"]
        visible = {"left": round(bounds["x"]) - window["left"],
                   "right": round(bounds["x"] + bounds["width"]) - window["left"],
                   "top": round(bounds["y"]) - window["top"],
                   "bottom": round(bounds["y"] + bounds["height"]) - window["top"]}
        footprints = []
        for step, ink in ((steps[0], (27, 29, 32)), (steps[1], (242, 244, 247))):
            image = (self.pair_run / "output" / step["capture"]["file"]).read_bytes()
            width, height, rgba = evidence.decode_png(image, step["phase"])
            footprints.append(evidence.pair_ink_footprint(rgba, width, height, visible, ink, "current_name_cell"))
        self.assertGreater(footprints[0]["left"] - footprints[1]["left"], 5)
        self.assertEqual(evidence.default_primary_widths(300, 112, 96), [120, 120, 80])
        cases = (
            ("preseeded", lambda item: item["fixture"].__setitem__("settings_absent_before_launch", False), "preseeded"),
            ("custom startup", lambda item: item["fixture"]["startup_columns"].__setitem__(0, 900), "clean startup columns"),
            ("missing phase", lambda item: item["steps"].pop(), "phases are missing"),
            ("theme changed width", lambda item: item["steps"][1]["state"]["columns"].__setitem__(0, 188), "allocation differs"),
            ("theme changed name", lambda item: item["steps"][1]["state"].__setitem__("proposed_name", "changed"), "row, Apply"),
            ("reused process", lambda item: item.__setitem__("process_id", 4242), "reused"),
            ("visible overlay", lambda item: item["steps"][1]["state"]["overlay"].__setitem__("visible_tooltip_count", 1), "unsettled overlay"),
        )
        for label, mutate, message in cases:
            with self.subTest(label=label):
                changed = deepcopy(raw)
                mutate(changed["assertions"]["scenario"]["default_columns"])
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    evidence.validate_pair_default_columns(self.pair_run, changed, files, actual)

    def test_whole_pair_rejects_preseeded_default_columns(self):
        path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        raw["assertions"]["scenario"]["default_columns"]["fixture"]["settings_absent_before_launch"] = False
        write_json(path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "preseeded"):
            self.validate()

    def test_default_original_dark_text_fragments_fail_after_receipts_are_rebound(self):
        for label in ("header", "current-name"):
            with self.subTest(label=label):
                self.reset_fixture()
                path = self.pair_run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                dark_name = "appearance-default-columns-dark.png"
                divider = (55, 60, 67)
                ink = (242, 244, 247)
                header = (55, 105, 61 if label == "header" else 105, 112, ink)
                current = (75, 144, 81 if label == "current-name" else 145, 151, ink)
                proposed = (245, 144, 251 if label == "proposed-name" else 315, 151, ink)
                changed_png = pair_png((36, 36, 36), patches=(
                    (48, 124, 80, 125, divider), header,
                    (52, 143, 68, 151, ink), current, proposed))
                (self.pair_run / "output" / dark_name).write_bytes(changed_png)
                changed_hash = digest(changed_png)
                receipt = next(item for item in raw["screenshots"] if item["file"] == dark_name)
                receipt["sha256"] = changed_hash
                dark = raw["assertions"]["scenario"]["default_columns"]["steps"][1]
                dark["capture"]["sha256"] = changed_hash
                write_json(path, raw)
                self.fixture.refresh(self.pair_run)
                collection = json.loads((self.pair_run / "collection.json").read_text())
                self.assertEqual(next(item["sha256"] for item in collection["files"]
                                      if item["relative_path"] == dark_name), changed_hash)
                with self.assertRaisesRegex(evidence.EvidenceError, "text ink was clipped or changed"):
                    self.validate()

    def test_pair_selection_cell_identity_and_geometry_stay_bound_across_focus(self):
        for field, expected in (("bounds", "native row geometry"),
                                ("name", "native row geometry"),
                                ("keyboard_focusable", "focusability is invalid")):
            with self.subTest(field=field):
                self.reset_fixture()
                path = self.pair_run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                for step in raw["assertions"]["scenario"]["scenes"]["selected-inactive"]:
                    cell = step["state"]["selected_row_cell"]
                    if field == "bounds":
                        cell["bounds"]["x"] += 1
                    elif field == "name":
                        cell["name"] += "-other"
                    else:
                        cell["keyboard_focusable"] = "false"
                write_json(path, raw)
                self.fixture.refresh(self.pair_run)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    self.validate()

    def test_pair_preference_and_tooltip_changes_rejected(self):
        for key, value, expected in (
            ("column_preference_sha256", "f" * 64, "column preference changed"),
            ("native_focus", [2001, 0, 32773], "native focus differs"),
            ("overlay", {"visible_tooltip_count": 1, "neutral_cursor": True}, "visible tooltip"),
        ):
            with self.subTest(key=key):
                self.reset_fixture()
                path = self.pair_run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                raw["assertions"]["scenario"]["scenes"]["empty"][0]["state"][key] = value
                write_json(path, raw)
                self.fixture.refresh(self.pair_run)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    self.validate()

    def test_missing_pair_capture_rejected(self):
        raw_path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["screenshots"].pop()
        write_json(raw_path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "exactly 69 original captures"):
            self.validate()

    def test_proposal_viewport_must_match_exact_native_request(self):
        for key in ("proposal_viewport", "horizontal_scroll"):
            with self.subTest(key=key):
                self.reset_fixture()
                path = self.pair_run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                state = raw["assertions"]["scenario"]["scenes"]["changed"][0]["state"]
                if key == "proposal_viewport":
                    state[key]["observed"] += 6
                else:
                    state[key][3] += 6
                    state[key][4] += 6
                write_json(path, raw)
                self.fixture.refresh(self.pair_run)
                with self.assertRaisesRegex(evidence.EvidenceError, "exact native pixel request"):
                    self.validate()

    def test_pair_source_executable_and_environment_bindings_rejected(self):
        manifest_path = self.pair_run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["source_sha"] = "f" * 40
        write_json(manifest_path, manifest)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "source_sha"):
            self.validate()

        self.reset_fixture()
        manifest_path = self.pair_run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["artifacts"]["application"]["sha256"] = "f" * 64
        write_json(manifest_path, manifest)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "artifacts.application bytes"):
            self.validate()

        self.reset_fixture()
        raw_path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["assertions"]["scenario"]["environment"]["hwnd_dpi"] = 144
        write_json(raw_path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "environment binding"):
            self.validate()

    def test_pair_interaction_native_state_and_cancel_settings_rejected(self):
        for field, value, message in (
            ("pressed", 8, "button native/UIA state"),
            ("default_button_id", 0, "native default button"),
            ("default_button_query", "DM_GETDEFID", "native default button"),
            ("column_preference_sha256", "f" * 64, "interaction theme, settings"),
        ):
            with self.subTest(field=field):
                self.reset_fixture()
                path = self.pair_run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                interaction = raw["assertions"]["scenario"]["interactions"][1]
                if field == "pressed":
                    interaction["buttons"]["pressed"]["native_button_state"] = value
                elif field in {"default_button_id", "default_button_query"}:
                    interaction["input_prompt"][field] = value
                else:
                    interaction[field] = value
                write_json(path, raw)
                self.fixture.refresh(self.pair_run)
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    self.validate()

    def test_pair_keyboard_focus_cannot_claim_mouse_hover(self):
        path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        focus = raw["assertions"]["scenario"]["interactions"][1]["buttons"]["keyboard-focus"]
        focus["cursor"] = [715, 216, 3001, 1001]
        write_json(path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "cursor does not match"):
            self.validate()

    def test_pair_target_client_awareness_and_font_bindings_rejected(self):
        for field, message in (("awareness", "DPI awareness"), ("client", "client bounds"),
                               ("font", "font descriptor")):
            with self.subTest(field=field):
                self.reset_fixture()
                path = self.pair_run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                rendering = raw["assertions"]["scenario"]["scenes"]["empty"][1]["state"]["target_rendering"]
                if field == "awareness":
                    rendering["awareness"]["per_monitor_v2"] = False
                elif field == "client":
                    rendering["client"]["width"] += 1
                else:
                    rendering["system_font_recipe"]["fonts"]["MessageFont"]["height"] = 0
                write_json(path, raw)
                self.fixture.refresh(self.pair_run)
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    self.validate()

    def test_pair_scroll_tracking_binding_and_restoration_rejected(self):
        for field, message in (("capture", "native capture state"),
                               ("geometry", "thumb geometry"),
                               ("drag", "did not advance"),
                               ("restore", "was not restored")):
            with self.subTest(field=field):
                self.reset_fixture()
                path = self.pair_run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                bar = raw["assertions"]["scenario"]["interactions"][1]["scrollbars"]["horizontal"]
                if field == "capture":
                    bar["steps"][0]["native_gui"][1] = 0
                elif field == "geometry":
                    bar["steps"][0]["components"][6] = 0
                elif field == "drag":
                    bar["steps"][2]["scroll"][3] = 0
                else:
                    bar["restored_scroll"][3] = 1
                write_json(path, raw)
                self.fixture.refresh(self.pair_run)
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    self.validate()

    def test_pair_bright_dark_scrollbar_rejected_with_matching_receipts(self):
        path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        step = raw["assertions"]["scenario"]["interactions"][1]["scrollbars"]["horizontal"]["steps"][1]
        name = step["capture"]["file"]
        image = pair_png((36, 36, 36), patches=((40, 432, 620, 449, (255, 255, 255)),))
        (self.pair_run / "output" / name).write_bytes(image)
        step["capture"]["sha256"] = digest(image)
        for capture in raw["screenshots"]:
            if capture["file"] == name:
                capture["sha256"] = digest(image)
        write_json(path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "scrollbar thumb palette raster violation"):
            self.validate()

    def test_pair_light_endpoint_state_loss_rejected_with_matching_receipts(self):
        path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        step = raw["assertions"]["scenario"]["scenes"]["unchanged"][2]
        name = step["capture"]["file"]
        image = pair_png((245, 245, 245), patches=((100, 250, 200, 260, (23, 25, 28)),
            (39, 108, 40, 442, (217, 221, 227)), (48, 124, 80, 125, (217, 221, 227)), (48, 450, 80, 451, (217, 221, 227))))
        (self.pair_run / "output" / name).write_bytes(image)
        step["capture"]["sha256"] = digest(image)
        for capture in raw["screenshots"]:
            if capture["file"] == name:
                capture["sha256"] = digest(image)
        write_json(path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "Light endpoint client raster did not restore"):
            self.validate()

    def test_pair_region_visual_violation_rejected_with_matching_receipt(self):
        name = "appearance-empty-dark.png"
        image = pair_png((245, 245, 245), patches=((39, 108, 40, 442, (55, 60, 67)),
            (48, 124, 80, 125, (55, 60, 67)), (48, 450, 80, 451, (55, 60, 67))))
        (self.pair_run / "output" / name).write_bytes(image)
        raw_path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        for capture in raw["screenshots"]:
            if capture["file"] == name:
                capture["sha256"] = digest(image)
        raw["assertions"]["scenario"]["scenes"]["empty"][1]["capture"]["sha256"] = digest(image)
        write_json(raw_path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "interior raster violation"):
            self.validate()

    def test_pair_proposal_semantic_color_cannot_leak_into_current_name(self):
        name = "appearance-changed-dark.png"
        image = pair_png((36, 36, 36), patches=(
            (300, 148, 330, 156, (133, 183, 255)),
            (100, 148, 120, 156, (133, 183, 255)),
            (39, 108, 40, 442, (55, 60, 67)),
            (48, 124, 80, 125, (55, 60, 67)),
            (48, 450, 80, 451, (55, 60, 67)),
        ))
        (self.pair_run / "output" / name).write_bytes(image)
        raw_path = self.pair_run / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        for receipt in raw["screenshots"]:
            if receipt["file"] == name:
                receipt["sha256"] = digest(image)
        raw["assertions"]["scenario"]["scenes"]["changed"][1]["capture"]["sha256"] = digest(image)
        write_json(raw_path, raw)
        self.fixture.refresh(self.pair_run)
        with self.assertRaisesRegex(evidence.EvidenceError, "semantic color leaked into current-name"):
            self.validate()


class PerformanceSampleEvidenceTests(SyntheticFixtureTestCase):
    def test_selected_source_schema_rejects_downgrade_and_unknown_versions(self):
        producer = ("$script:PerformanceResponseTimelineSchemaVersion = 1\n"
                    "schema_version=$script:PerformanceResponseTimelineSchemaVersion\n")
        with mock.patch.object(evidence.subprocess, "run",
                               return_value=SimpleNamespace(returncode=0, stdout=producer.encode())):
            self.assertEqual(evidence.selected_performance_response_schema(self.root, SOURCE), 1)
        legacy_sha = next(iter(evidence.LEGACY_PERFORMANCE_RESPONSE_SOURCE_SHAS))
        with mock.patch.object(evidence.subprocess, "run",
                               return_value=SimpleNamespace(returncode=0, stdout=b"legacy producer")):
            self.assertEqual(evidence.selected_performance_response_schema(self.root, legacy_sha), 0)
            with self.assertRaisesRegex(evidence.EvidenceError, "approved response schema marker"):
                evidence.selected_performance_response_schema(self.root, SOURCE)
        for altered in (producer.replace("= 1", "= 2"),
                        producer.replace("schema_version=$script:PerformanceResponseTimelineSchemaVersion", "schema_version=1")):
            with mock.patch.object(evidence.subprocess, "run",
                                   return_value=SimpleNamespace(returncode=0, stdout=altered.encode())):
                with self.assertRaisesRegex(evidence.EvidenceError, "schema marker"):
                    evidence.selected_performance_response_schema(self.root, SOURCE)

    def timed_scenario(self):
        scenario = self.sample_scenario()
        scenario.update(process_id=4242, process_start_utc_ticks=134041000000000000,
                        environment={"main_window": {"hwnd": 1001}})
        base = 100_000_000_000
        frequency = 10_000_000
        for index, row in enumerate(scenario["samples"]):
            begin = base + index * 2_000_000
            row.update(probe_begin_ticks=begin, probe_end_ticks=begin + 20_000,
                       process_id=4242, process_start_utc_ticks=134041000000000000,
                       main_window_handle=1001, main_thread_id=42,
                       main_class="DarkReNamerMain", main_enabled=True,
                       main_enabled_before=True,
                       owned_popup_handle=0, owned_popup_thread_id=0,
                       owned_popup_class="", owned_popup_handle_before=0,
                       owned_popup_thread_id_before=0, owned_popup_class_before="")
        order = ("long-hidden", "long-visible")
        operations = ("ordinary-100", "ordinary-1000") + tuple(
            f"ordinary-10000-{index}" for index in range(1, 5)) + order + (
            "extensions", "cycle-1", "cycle-2", "cycle-3")
        events = []
        for operation in operations:
            if operation == order[0]:
                events.extend(("full-preview", step) for step in
                              evidence.PERFORMANCE_PREVIEW_BOUNDARIES)
            events.extend((operation, step) for step in evidence.PERFORMANCE_IMPORT_BOUNDARIES)
        window_steps = {"picker_found", "open_invoke", "dialog_closed",
                        "prompt_found", "commit_invoke", "prompt_closed"}
        phase_sample = {phase: next(index for index, row in enumerate(scenario["samples"])
                              if row["phase"] == phase)
                        for phase in evidence.PERFORMANCE_PHASES}
        phase_operations = {}
        event_rows = []
        for operation, step in events:
            phase = "ordinary-10000" if operation.startswith("ordinary-10000-") else operation
            if operation not in phase_operations:
                phase_operations[operation] = sum(
                    key.startswith("ordinary-10000-") if phase == "ordinary-10000" else key == phase
                    for key in phase_operations)
            step_index = (evidence.PERFORMANCE_PREVIEW_BOUNDARIES if operation == "full-preview"
                          else evidence.PERFORMANCE_IMPORT_BOUNDARIES).index(step)
            ticks = (base + phase_sample[phase] * 2_000_000 - 10_000 +
                     phase_operations[operation] * 200_000 + step_index * 20_000)
            event_rows.append({"operation": operation, "step": step, "ticks": ticks,
                               "window_handle": 3000 + operations.index(operation)
                               if step in window_steps and operation != "full-preview"
                               else 4000 if step in window_steps else 0})
        scenario["response_timeline"] = {"schema_version": 1, "qpc_frequency": frequency,
            "events": event_rows}
        return scenario

    def test_response_timeline_validates_qpc_dialog_and_main_identity(self):
        scenario = self.timed_scenario()
        metrics = evidence.validate_performance_metrics(scenario)
        self.assertEqual(metrics["response_timeline"]["boundary_count"], 81)
        self.assertEqual(metrics["response_timeline"]["import_count"], 12)
        scenario["samples"][151].update(main_enabled=False, owned_popup_handle=4000,
                                         owned_popup_thread_id=42, owned_popup_class="#32770")
        scenario["samples"][151].update(probe_status="timeout", probe_error_code=1460)
        metrics = evidence.validate_performance_metrics(scenario)
        self.assertEqual(metrics["sample_count"], len(scenario["samples"]))
        self.assertEqual(metrics["response_timeline"]["timeout_endpoint_snapshot_transition_or_other"], 1)
        scenario["samples"][151].update(main_enabled_before=False,
                                         owned_popup_handle_before=4000,
                                         owned_popup_thread_id_before=42,
                                         owned_popup_class_before="#32770")
        self.assertEqual(evidence.validate_performance_metrics(scenario)["response_timeline"]["timeout_endpoint_snapshot_stable_modal"], 1)

    def test_response_timeline_joins_operation_phase_and_probe_interval_boundaries(self):
        scenario = self.timed_scenario()
        probe = scenario["samples"][151]
        probe.update(probe_status="timeout", probe_error_code=1460)
        intervals = evidence.validate_performance_metrics(scenario)["response_timeline"]["operation_intervals"]
        picker = next(row for row in intervals if row["operation"] == "ordinary-10000-1"
                      and row["segment"] == "picker")
        self.assertEqual(picker["phase"], "ordinary-10000")
        self.assertEqual(picker["phase_sample_count"], 1)
        self.assertEqual(picker["phase_join_status"], "sampled")
        self.assertEqual(picker["timeout_probe_overlap_count"], 1)
        self.assertIn("no modal causation", evidence.validate_performance_metrics(scenario)["response_timeline"]["interpretation"])
        for event in scenario["response_timeline"]["events"]:
            if event["operation"] == "ordinary-10000-1":
                event["ticks"] += 30_000
        intervals = evidence.validate_performance_metrics(scenario)["response_timeline"]["operation_intervals"]
        picker = next(row for row in intervals if row["operation"] == "ordinary-10000-1"
                      and row["segment"] == "picker")
        self.assertEqual(picker["begin_ticks"], probe["probe_end_ticks"])
        self.assertEqual(picker["timeout_probe_overlap_count"], 0)

    def test_disabled_owner_without_active_popup_is_a_transition_snapshot(self):
        scenario = self.timed_scenario()
        probe = scenario["samples"][150]
        probe.update(main_enabled_before=False, main_enabled=False,
                     probe_status="timeout", probe_error_code=1460)
        metrics = evidence.validate_performance_metrics(scenario)["response_timeline"]
        self.assertEqual(metrics["timeout_endpoint_snapshot_stable_modal"], 0)
        self.assertEqual(metrics["timeout_endpoint_snapshot_stable_nonmodal"], 0)
        self.assertEqual(metrics["timeout_endpoint_snapshot_transition_or_other"], 1)
        probe["main_enabled"] = True
        metrics = evidence.validate_performance_metrics(scenario)["response_timeline"]
        self.assertEqual(metrics["timeout_endpoint_snapshot_transition_or_other"], 1)

    def test_response_timeline_rejects_wrong_sample_phase_and_source_downgrade(self):
        scenario = self.timed_scenario()
        with self.assertRaisesRegex(evidence.EvidenceError, "selected source schema"):
            evidence.validate_performance_metrics(self.sample_scenario(),
                                                  expected_response_schema_version=1)
        with self.assertRaisesRegex(evidence.EvidenceError, "selected source schema"):
            evidence.validate_performance_metrics(scenario, expected_response_schema_version=0)
        scenario["samples"][149]["phase"] = "ordinary-1000"
        with self.assertRaisesRegex(evidence.EvidenceError, "operation/sample phase"):
            evidence.validate_performance_metrics(scenario, expected_response_schema_version=1)

    def test_response_timeline_rejects_lost_or_ambiguous_boundaries(self):
        scenario = self.timed_scenario()
        malformed = deepcopy(scenario)
        malformed["response_timeline"]["events"].pop(10)
        with self.assertRaisesRegex(evidence.EvidenceError, "incomplete"):
            evidence.validate_performance_metrics(malformed)
        malformed = deepcopy(scenario)
        malformed["response_timeline"]["events"][8]["ticks"] = malformed["response_timeline"]["events"][7]["ticks"]
        with self.assertRaisesRegex(evidence.EvidenceError, "QPC time regressed"):
            evidence.validate_performance_metrics(malformed)
        malformed = deepcopy(scenario)
        malformed["response_timeline"]["events"][2]["window_handle"] += 1
        with self.assertRaisesRegex(evidence.EvidenceError, "dialog identity changed"):
            evidence.validate_performance_metrics(malformed)
        malformed = deepcopy(scenario)
        malformed["response_timeline"]["schema_version"] = 2
        with self.assertRaisesRegex(evidence.EvidenceError, "schema version"):
            evidence.validate_performance_metrics(malformed)

    def test_response_timeline_rejects_unbound_or_unknown_samples(self):
        scenario = self.timed_scenario()
        for mutation, error in (
            (lambda row: row.pop("probe_begin_ticks"), "performance sample"),
            (lambda row: row.update(main_window_handle=999), "main HWND"),
            (lambda row: row.update(main_enabled=0), "modal identity"),
            (lambda row: row.update(owned_popup_handle=100, owned_popup_thread_id=99,
                                    owned_popup_class="#32770"), "modal identity"),
            (lambda row: row.update(owned_popup_thread_id=42), "modal identity"),
            (lambda row: row.update(probe_end_ticks=row["probe_begin_ticks"]), "probe QPC"),
            (lambda row: row.update(probe_status="failure_unknown", probe_error_code=5), "modal identity"),
        ):
            malformed = deepcopy(scenario)
            mutation(malformed["samples"][150])
            with self.assertRaisesRegex(evidence.EvidenceError, error):
                evidence.validate_performance_metrics(malformed)
        legacy = deepcopy(scenario)
        legacy.pop("response_timeline")
        with self.assertRaisesRegex(evidence.EvidenceError, "performance sample"):
            evidence.validate_performance_metrics(legacy)

    def test_producer_wrapped_lifecycle_requires_exact_normal_exit(self):
        scenario = {"process_id": 42, "process_start_utc_ticks": "123456"}
        lifecycle = {"pid": 42, "start_time_utc_ticks": "123456",
                     "executable_sha256": "a" * 64, "start_observed": True,
                     "exit_observed": True, "exit_method": "normal-close", "exit_code": 0}
        evidence.validate_performance_lifecycle([{"process_lifecycle": lifecycle}], scenario, "a" * 64)
        for field, value in (("pid", 43), ("start_time_utc_ticks", "123457"),
                             ("executable_sha256", "b" * 64), ("start_observed", False),
                             ("exit_observed", False), ("exit_method", "forced-termination"),
                             ("exit_code", 1)):
            bad = dict(lifecycle, **{field: value})
            with self.assertRaisesRegex(evidence.EvidenceError, "exact process lifecycle"):
                evidence.validate_performance_lifecycle([{"process_lifecycle": bad}], scenario, "a" * 64)
        for bad in ([], [lifecycle], [{"process_lifecycle": lifecycle}] * 2):
            with self.assertRaisesRegex(evidence.EvidenceError, "exact process lifecycle"):
                evidence.validate_performance_lifecycle(bad, scenario, "a" * 64)

    def sample_scenario(self):
        rows = []
        for index, phase in enumerate(evidence.PERFORMANCE_PHASES):
            count = 149 if index == 0 else 1
            for _ in range(count):
                elapsed = len(rows) * 200
                rows.append({"phase": phase, "elapsed_ms": elapsed, "cpu_ms": elapsed // 2,
                             "private_bytes": 1024 + elapsed, "working_set_bytes": 2048 + elapsed,
                             "threads": 4, "handles": 20, "gdi_objects": 6,
                             "ui_response_ms": 2, "probe_status": "success",
                             "probe_error_code": 0, "resource_collection_ms": 3,
                             "sample_gap_ms": 0 if not rows else 200})
        rows[149]["elapsed_ms"] = 30000
        for index in range(150, len(rows)):
            rows[index]["elapsed_ms"] += 200
        phase_summary = [{"phase": phase, "sample_count": sum(row["phase"] == phase for row in rows),
                          "max_sample_gap_ms": max(row["sample_gap_ms"] for row in rows if row["phase"] == phase),
                          "max_resource_collection_ms": 3}
                         for phase in evidence.PERFORMANCE_PHASES]
        return {
            "plan": {key: evidence.PERFORMANCE_PLAN[key] for key in (
                "ordinary_rows", "long_path_rows", "extension_classes", "add_remove_reset_cycles",
                "idle_seconds", "sample_interval_ms")} | {"long_path_order": "hidden-visible"},
            "timing_definitions": deepcopy(evidence.PERFORMANCE_TIMING_DEFINITIONS),
            "startup": {"launch_request_to_ready_ms": 120, "process_start_to_ready_lower_ms": 100,
                        "process_start_to_ready_upper_ms": 110, "main_hwnd_bound": True,
                        "empty_grid": True, "import_command_enabled": True},
            "timings": [{"id": name, "elapsed_ms": 10.5,
                         "rows": {"ordinary-100": 100, "ordinary-1000": 1000,
                                  "ordinary-10000": 10000, "full-preview": 10000}.get(name, 1000),
                         "observed_rows": {"ordinary-100": 100, "ordinary-1000": 1000,
                                           "ordinary-10000": 10000, "full-preview": 10000}.get(name, 1000),
                         **({"batch_rows": [2250] * 4} if name == "ordinary-10000" else {}),
                         **({"batch_command_ready_after_rows_ms": [0.5] * 4}
                            if name == "ordinary-10000" else {}),
                         **({"command_ready_after_rows_ms": 0.5}
                            if name not in ("ordinary-10000", "full-preview") and
                            not name.startswith("cycle-") else {}),
                         **({"import_command_ready_after_rows_ms": 0.5}
                            if name.startswith("cycle-") else {}),
                         **({"command_elapsed_ms": 5.0} if name == "full-preview" else {}),
                         **({"import_elapsed_ms": 5.0} if name.startswith("cycle-") else {})}
                        for name in evidence.PERFORMANCE_TIMINGS],
            "clear_row_counts": [0] * 7,
            "ordinary_representatives": [{"index": index, "name": f"ordinary-{index:05d}.txt"}
                                         for index in (0, 4999, 9999)],
            "long_representatives": {mode: [{"index": index, "name": f"long-{index:04d}.txt"}
                                             for index in (0, 499, 999)]
                                     for mode in ("long-hidden", "long-visible")},
            "extension_representatives": [
                {"index": 0, "name": "extension-0000.e000"},
                {"index": 499, "name": "recurring-0499.txt"},
                {"index": 999, "name": "recurring-0999.txt"}],
            "full_preview_rows": [
                {"index": index, "source": f"ordinary-{index:05d}.txt",
                 "prefixed": f"sample-ordinary-{index:05d}.txt",
                 "reset": f"ordinary-{index:05d}.txt"}
                for index in (0, 2499, 4999, 7499, 9999)],
            "samples": rows,
            "phase_summary": phase_summary,
            "columns": {"hidden_widths": [0] * 4, "visible_widths": [120] * 4,
                        "extension_widths": [120] * 4,
                        "first_values": [r"C:\fixture\long-0000.txt", "10", "date", "date"]},
            "wakeups": {"status": "not_run", "reason": "no-supported-process-wakeup-counter"},
            "disk_unchanged": True, "journal_residue_count": 0, "normal_exit_code": 0,
        }

    def test_fixed_request_and_source_binding(self):
        run = self.fixture.build(evidence.performance_run_id("hidden-visible"), "standard")
        path = run / "input-manifest.json"
        manifest = json.loads(path.read_text())
        manifest["request"] = {"mode": evidence.PERFORMANCE_MODE, "appearance": "light",
                               "desktop": {"width": 1366, "height": 768, "dpi": 96},
                               "text_scale_percent": 100,
                               "performance_plan": {**deepcopy(evidence.PERFORMANCE_PLAN),
                                                    "long_path_order": "hidden-visible"}}
        manifest["command"] = ["python3", "-I", "scripts/run-gui-regression.py",
                               "--output-root", "<external-output-root>",
                               "--connection-profile", "<private-connection-profile>",
                               "--diagnostic", evidence.PERFORMANCE_MODE,
                               "--performance-column-order", "hidden-visible"]
        write_json(path, manifest)
        evidence.validate_input_manifest(run, SOURCE)
        with self.assertRaisesRegex(evidence.EvidenceError, "expected exact source SHA"):
            evidence.validate_input_manifest(run, "f" * 40)
        manifest["command"][-1] = "visible-hidden"
        write_json(path, manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "manifest identity or command"):
            evidence.validate_input_manifest(run, SOURCE)
        manifest["command"][-1] = "hidden-visible"
        manifest["run_id"] = "performance-sample-1366x768-96-text100"
        write_json(path, manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "run_id differs from its directory"):
            evidence.validate_input_manifest(run, SOURCE)
        manifest["run_id"] = evidence.performance_run_id("hidden-visible")
        manifest["request"]["performance_plan"]["idle_seconds"] = 0
        write_json(path, manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "fixed plan"):
            evidence.validate_input_manifest(run, SOURCE)

    def test_prepared_bundle_provenance_requires_matching_copied_inputs_and_command(self):
        run = self.fixture.build(evidence.performance_run_id("hidden-visible"), "standard")
        path = run / "input-manifest.json"
        manifest = json.loads(path.read_text())
        manifest["request"] = {"mode": evidence.PERFORMANCE_MODE, "appearance": "light",
                               "desktop": {"width": 1366, "height": 768, "dpi": 96},
                               "text_scale_percent": 100,
                               "performance_plan": {**deepcopy(evidence.PERFORMANCE_PLAN),
                                                    "long_path_order": "hidden-visible"}}
        manifest["command"] = ["python3", "-I", "scripts/run-gui-regression.py",
                               "--output-root", "<external-output-root>",
                               "--connection-profile", "<private-connection-profile>",
                               "--diagnostic", evidence.PERFORMANCE_MODE,
                               "--performance-column-order", "hidden-visible"]
        app_hash = manifest["artifacts"]["application"]["sha256"]
        manifest["prepared_bundle"] = {
            "origin": "external-prepared-source-built-bundle",
            "bundle_manifest_sha256": manifest["bundle_manifest"]["sha256"],
            "application_sha256": app_hash,
        }
        manifest["command"] += ["--prepared-bundle-root", "<external-prepared-bundle-root>",
                                "--expected-prepared-application-sha256", app_hash]
        write_json(path, manifest)
        evidence.validate_input_manifest(run, SOURCE)
        manifest["prepared_bundle"]["application_sha256"] = "f" * 64
        write_json(path, manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "provenance differs"):
            evidence.validate_input_manifest(run, SOURCE)
        manifest["prepared_bundle"]["application_sha256"] = app_hash
        manifest["command"][-1] = "f" * 64
        write_json(path, manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "manifest identity or command"):
            evidence.validate_input_manifest(run, SOURCE)

    def test_probe_timeout_and_unknown_failure_remain_distinct(self):
        scenario = self.sample_scenario()
        scenario["samples"][150].update(probe_status="timeout", probe_error_code=1460)
        scenario["samples"][151].update(probe_status="failure_unknown", probe_error_code=5)
        metrics = evidence.validate_performance_metrics(scenario)
        self.assertEqual((metrics["probe_timeout_count"], metrics["probe_failure_unknown_count"]), (1, 1))
        scenario["samples"][151]["probe_error_code"] = 1460
        with self.assertRaisesRegex(evidence.EvidenceError, "probe status"):
            evidence.validate_performance_metrics(scenario)

    def test_v1_fields_and_unbound_column_order_are_rejected(self):
        scenario = self.sample_scenario()
        scenario["samples"][150]["ui_responsive"] = False
        with self.assertRaisesRegex(evidence.EvidenceError, "performance sample 150"):
            evidence.validate_performance_metrics(scenario)
        scenario = self.sample_scenario()
        scenario["plan"]["long_path_order"] = "visible-hidden"
        with self.assertRaisesRegex(evidence.EvidenceError, "timing order"):
            evidence.validate_performance_metrics(scenario)

    def test_visible_then_hidden_order_has_its_own_valid_metric_sequence(self):
        scenario = self.sample_scenario()
        scenario["plan"]["long_path_order"] = "visible-hidden"
        scenario["timings"][4], scenario["timings"][5] = scenario["timings"][5], scenario["timings"][4]
        for row in scenario["samples"]:
            if row["phase"] == "long-hidden":
                row["phase"] = "long-visible"
            elif row["phase"] == "long-visible":
                row["phase"] = "long-hidden"
        scenario["phase_summary"][6], scenario["phase_summary"][7] = (
            scenario["phase_summary"][7], scenario["phase_summary"][6])
        self.assertEqual(evidence.validate_performance_metrics(scenario)["sample_count"],
                         len(scenario["samples"]))

    def test_sampled_peak_and_missing_or_duplicate_metric_rejected(self):
        scenario = self.sample_scenario()
        metrics = evidence.validate_performance_metrics(scenario)
        self.assertEqual(metrics["sample_count"], len(scenario["samples"]))
        self.assertEqual(metrics["private_peak_bytes"], max(row["private_bytes"] for row in scenario["samples"]))
        missing = deepcopy(scenario)
        del missing["samples"][150]["private_bytes"]
        with self.assertRaisesRegex(evidence.EvidenceError, "performance sample 150"):
            evidence.validate_performance_metrics(missing)
        duplicate = deepcopy(scenario)
        duplicate["timings"][1]["id"] = duplicate["timings"][0]["id"]
        with self.assertRaisesRegex(evidence.EvidenceError, "timing order"):
            evidence.validate_performance_metrics(duplicate)

    def test_cleanup_and_unmeasured_wakeups_cannot_be_promoted(self):
        scenario = self.sample_scenario()
        scenario["disk_unchanged"] = False
        with self.assertRaisesRegex(evidence.EvidenceError, "fixture, journal, or normal exit"):
            evidence.validate_performance_metrics(scenario)
        scenario["disk_unchanged"] = True
        scenario["wakeups"] = {"status": "passed", "reason": "estimated"}
        with self.assertRaisesRegex(evidence.EvidenceError, "not_run"):
            evidence.validate_performance_metrics(scenario)

    def test_last_preview_probe_and_cycle_total_are_required(self):
        scenario = self.sample_scenario()
        scenario["full_preview_rows"][-1]["prefixed"] = "ordinary-09999.txt"
        with self.assertRaisesRegex(evidence.EvidenceError, "representative row"):
            evidence.validate_performance_metrics(scenario)
        scenario = self.sample_scenario()
        cycle = next(row for row in scenario["timings"] if row["id"] == "cycle-2")
        cycle["elapsed_ms"] = cycle["import_elapsed_ms"] - 0.1
        with self.assertRaisesRegex(evidence.EvidenceError, "full-operation timing"):
            evidence.validate_performance_metrics(scenario)

    def owned_run(self):
        run_id = evidence.owned_performance_run_id('hidden-visible')
        run = self.fixture.build(run_id, 'standard')
        output = run / 'output'
        profile = (SCRIPT_ROOT.parent / 'config/vm-automated-v2.json').read_bytes()
        profile_sha = digest(profile)
        (run / 'inputs/vm-automated-v2.json').write_bytes(profile)
        manifest_path = run / 'input-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest.update(acceptance_profile_id=evidence.V2_PROFILE_ID,
                        acceptance_profile_sha256=profile_sha,
                        acceptance_profile={'file': 'inputs/vm-automated-v2.json',
                                            'bytes': len(profile), 'sha256': profile_sha})
        manifest['request'] = {'mode': evidence.PERFORMANCE_MODE, 'appearance': 'light',
            'desktop': {'width': 1366, 'height': 768, 'dpi': 96}, 'text_scale_percent': 100,
            'performance_plan': {**deepcopy(evidence.PERFORMANCE_PLAN),
                                 'long_path_order': 'hidden-visible'}}
        manifest['command'] = ['python3', '-I', 'scripts/run-gui-regression.py',
            '--output-root', '<external-output-root>', '--connection-profile',
            '<private-connection-profile>', '--diagnostic', evidence.PERFORMANCE_MODE,
            '--performance-column-order', 'hidden-visible', '--acceptance-profile-id',
            evidence.V2_PROFILE_ID]
        write_json(manifest_path, manifest)
        (output / 'screen.png').rename(output / 'performance-empty.png')
        (output / 'text-raster-metrics.json').unlink()
        ticks = 638965440000000000
        filetime = ticks - 504911232000000000
        job = deepcopy(clean_controller_cleanup_v2()['owned_resource_evidence']['process_job_cleanup'][0])
        job.update(pid=4242, process_start_time_utc_ticks=str(ticks))
        cleanup = clean_controller_cleanup_v3(profile_sha256=profile_sha,
            process_jobs=[job], source_sha=SOURCE,
            bundle_sha256=manifest['bundle_manifest']['sha256'])
        transport_path = output / 'transport.json'
        transport = json.loads(transport_path.read_text())
        transport.update(raw_cleanup=cleanup,
                         vm_id=cleanup['owned_resource_evidence']['protected_anchor']['vm_id'],
                         desktop_lease_id='a' * 32)
        GuiEvidenceTests.bind_v2_fixture_vm(run, manifest, transport)
        write_json(transport_path, transport)
        raw_path = output / 'acceptance-result.json'
        raw = json.loads(raw_path.read_text())
        baseline = raw['assertions']['scenario']
        baseline['environment']['main_window'] = {'hwnd': 1001, 'process_id': 4242}
        scenario = self.sample_scenario()
        scenario.update(mode=evidence.PERFORMANCE_MODE, appearance='light',
            process_id=4242, process_start_utc_ticks=ticks,
            executable_sha256=manifest['artifacts']['application']['sha256'],
            executable_bytes=849408, environment=baseline['environment'],
            native_process_lifetime={'pid': 4242, 'creation_filetime': filetime,
                'checkpoints': [{'phase': phase, 'creation_filetime': filetime}
                    for phase in ('pre-work', 'idle', 'ordinary-10000', 'post')],
                'terminal_exit_filetime': filetime + 5_000_000})
        raw.update(assertions={'overall': 'passed', 'scope': 'performance-sample-p1-p3-v2',
                               'scenario': scenario},
                   process_cleanup=True,
                   process_lifecycles=[{'process_lifecycle': {
                       'pid': 4242, 'session_id': 2, 'start_time_utc_ticks': str(ticks),
                       'creation_filetime': filetime, 'executable_path': r'C:\fixture\DarkReNamer.exe',
                       'executable_sha256': manifest['artifacts']['application']['sha256'],
                       'start_observed': True, 'exit_observed': True,
                       'exit_method': 'normal-close', 'exit_code': 0}}],
                   process_job_cleanup=cleanup['owned_resource_evidence']['process_job_cleanup'],
                   observer_lifecycle=cleanup['owned_resource_evidence']['task_execution']['observer_lifecycle'],
                   screenshots=[{'file': 'performance-empty.png',
                       'sha256': digest((output / 'performance-empty.png').read_bytes())}])
        write_json(raw_path, raw)
        observations_path = output / 'acceptance-observations.json'
        observations = json.loads(observations_path.read_text())
        text_snapshot = {'registry_key_existed': True, 'registry_value_existed': True,
            'registry_value_kind': 'DWord', 'registry_value': 100,
            'ui_settings_raw_factor': 1.0, 'ui_settings_percent': 100}
        observations['text_scale_restoration'] = {'schema_version': 1,
            'baseline': text_snapshot, 'final': deepcopy(text_snapshot), 'snapshot_equal': True}
        write_json(observations_path, observations)
        lease = {'schema_version': 1, 'mode': 'managed-rdp', 'lease_id': 'a' * 32,
            'requested_scale': 100, 'requested_width': 1366, 'requested_height': 768,
            'expected_dpi': 96, 'start_status': 'ready', 'stop_status': 'stopped',
            'cleanup_observed': True}
        write_json(output / 'desktop-lease.json', lease)
        write_json(output / 'desktop-start-response.json', {'status': 'ready',
            'leaseId': 'a' * 32, 'processId': 9001,
            'expectedGuestSid': cleanup['owned_resource_evidence']['runner_sid'],
            'expectedDpi': 96, 'expectedDesktopWidth': 1366,
            'expectedDesktopHeight': 768})
        write_json(output / 'desktop-stop-response.json', {'status': 'stopped',
            'lifecycleStatus': 'closed', 'leaseId': 'a' * 32, 'processId': 9001})
        self.refresh_owned(run)
        return run, profile_sha

    def refresh_owned(self, run):
        output = run / 'output'
        manifest_path = run / 'input-manifest.json'
        self.fixture.refresh(run)
        manifest = json.loads(manifest_path.read_text())
        raw_path = output / 'acceptance-result.json'
        result = {'schema_version': 1, 'diagnostic': evidence.PERFORMANCE_MODE,
            'run_id': run.name, 'input_manifest_sha256': digest(manifest_path.read_bytes()),
            'collection_sha256': digest((run / 'collection.json').read_bytes()),
            'cleanup_sha256': digest((output / 'cleanup.json').read_bytes()),
            'source_sha': SOURCE,
            'application_sha256': manifest['artifacts']['application']['sha256'],
            'observer_sha256': manifest['artifacts']['observer']['sha256'],
            'observer_result_sha256': digest(raw_path.read_bytes()),
            'status': 'review_required', 'exit_code': 0}
        write_json(output / 'run-result.json', result)

    def picker_run(self):
        run, profile_sha = self.owned_run()
        run = run.rename(self.root / evidence.PICKER_RUN_ID)
        output = run / 'output'
        manifest_path = run / 'input-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['run_id'] = evidence.PICKER_RUN_ID
        manifest['request'] = {'mode': evidence.PICKER_MODE, 'appearance': 'light',
            'desktop': {'width': 1366, 'height': 768, 'dpi': 96}, 'text_scale_percent': 100,
            'picker_identity_plan': deepcopy(evidence.PICKER_PLAN)}
        manifest['prepared_bundle'] = {'origin': 'external-prepared-source-built-bundle',
            'bundle_manifest_sha256': manifest['bundle_manifest']['sha256'],
            'application_sha256': manifest['artifacts']['application']['sha256']}
        manifest['command'] = ['python3', '-I', 'scripts/run-gui-regression.py',
            '--output-root', '<external-output-root>', '--connection-profile',
            '<private-connection-profile>', '--diagnostic', evidence.PICKER_MODE,
            '--prepared-bundle-root', '<external-prepared-bundle-root>',
            '--expected-prepared-application-sha256', manifest['artifacts']['application']['sha256'],
            '--acceptance-profile-id', evidence.V2_PROFILE_ID]
        write_json(manifest_path, manifest)
        for name in ('cleanup.json', 'platform-preflight.json', 'platform-postlaunch.json'):
            path = output / name
            document = json.loads(path.read_text())
            document['run_id'] = evidence.PICKER_RUN_ID
            write_json(path, document)
        (output / 'performance-empty.png').rename(output / 'picker-100-after.png')
        raw_path = output / 'acceptance-result.json'
        raw = json.loads(raw_path.read_text())
        original = raw['assertions']['scenario']
        filetime = original['native_process_lifetime']['creation_filetime']
        def popup(stage, begin, end, active):
            if not active:
                return {'stage': stage, 'begin_ticks': begin, 'end_ticks': end,
                    'raw_popup_handle': 1001, 'accepted_popup_handle': 0,
                    'popup_lookup': 'main', 'popup_process_id': 0, 'popup_thread_id': 0,
                    'thread_lookup': 'not-run', 'thread_lookup_error': None,
                    'popup_class': '', 'class_lookup': 'not-run', 'class_lookup_error': None,
                    'popup_visible': False, 'main_enabled_at_lookup': True,
                    'visibility_lookup': 'not-run', 'direct_owner': 0,
                    'owner_lookup': 'not-run', 'owner_lookup_error': None,
                    'owner_chain': [], 'owner_chain_lookup': 'not-run',
                    'owner_chain_lookup_error': None, 'disposition': 'main',
                    'observed_predicates': [], 'failed_predicates': []}
            return {'stage': stage, 'begin_ticks': begin, 'end_ticks': end,
                'raw_popup_handle': 900, 'accepted_popup_handle': 900,
                'popup_lookup': 'popup', 'popup_process_id': 4242, 'popup_thread_id': 7,
                'thread_lookup': 'complete', 'thread_lookup_error': None,
                'popup_class': '#32770', 'class_lookup': 'complete', 'class_lookup_error': None,
                'popup_visible': True, 'main_enabled_at_lookup': False,
                'visibility_lookup': 'visible', 'direct_owner': 1001,
                'owner_lookup': 'returned', 'owner_lookup_error': None,
                'owner_chain': [1001], 'owner_chain_lookup': 'main-reached',
                'owner_chain_lookup_error': None, 'disposition': 'owned-popup',
                'observed_predicates': [], 'failed_predicates': []}
        def sample(phase, begin, end, active):
            before = popup('before-probe', begin - 10, begin - 1, active)
            after = popup('after-probe', end + 1, end + 10, active)
            return {'phase': phase, 'process_id': 4242,
                'process_start_utc_ticks': original['process_start_utc_ticks'],
                'main_window_handle': 1001, 'main_thread_id': 7,
                'main_class': 'DarkReNamerWindow', 'main_enabled_before': not active,
                'main_enabled': not active, 'probe_status': 'success',
                'probe_begin_ticks': begin, 'probe_end_ticks': end,
                'owned_popup_handle_before': before['accepted_popup_handle'],
                'owned_popup_handle': after['accepted_popup_handle'],
                'popup_before': before, 'popup_after': after}
        samples = [sample('empty-idle', 20, 30, False),
                   sample('ordinary-100', 200, 210, True),
                   sample('post', 400, 410, False)]
        events = [{'operation': 'ordinary-100', 'step': step, 'ticks': tick,
                   'window_handle': 900 if step in {'picker_found', 'open_invoke', 'dialog_closed'} else 0}
                  for step, tick in zip(evidence.PERFORMANCE_IMPORT_BOUNDARIES,
                                        (150, 175, 220, 250, 280, 310), strict=True)]
        scenario = {'mode': evidence.PICKER_MODE, 'plan': deepcopy(evidence.PICKER_PLAN),
            'appearance': 'light', 'process_id': 4242,
            'process_start_utc_ticks': original['process_start_utc_ticks'],
            'executable_sha256': manifest['artifacts']['application']['sha256'],
            'environment': original['environment'],
            'native_process_lifetime': {'pid': 4242, 'creation_filetime': filetime,
                'checkpoints': [{'phase': phase, 'creation_filetime': filetime}
                    for phase in ('pre-work', 'idle', 'post')],
                'terminal_exit_filetime': filetime + 5_000_000},
            'response_timeline': {'schema_version': 1, 'qpc_frequency': 1000000,
                                  'events': events}, 'samples': samples,
            'timings': [{'id': 'ordinary-100', 'rows': 100, 'observed_rows': 100,
                         'elapsed_ms': 10.0, 'command_ready_after_rows_ms': 1.0}],
            'picker': {'expected_rows': 100, 'observed_rows': 100,
                       'import_command_ready': True, 'picker_closed': True,
                       'import_elapsed_ms': 10.0, 'fixture_files': 100},
            'disk_unchanged': True, 'journal_residue_count': 0, 'normal_exit_code': 0}
        raw['assertions'] = {'overall': 'passed', 'scope': evidence.PICKER_SCOPE,
                             'scenario': scenario}
        raw['screenshots'] = [{'file': 'picker-100-after.png',
            'sha256': digest((output / 'picker-100-after.png').read_bytes())}]
        write_json(raw_path, raw)
        observations_path = output / 'acceptance-observations.json'
        observations = json.loads(observations_path.read_text())
        observations['run_id'] = evidence.PICKER_RUN_ID
        write_json(observations_path, observations)
        self.refresh_owned(run)
        result_path = output / 'run-result.json'
        result = json.loads(result_path.read_text())
        result.update(diagnostic=evidence.PICKER_MODE, run_id=evidence.PICKER_RUN_ID,
                      input_manifest_sha256=digest(manifest_path.read_bytes()),
                      collection_sha256=digest((run / 'collection.json').read_bytes()),
                      cleanup_sha256=digest((output / 'cleanup.json').read_bytes()),
                      observer_result_sha256=digest(raw_path.read_bytes()))
        write_json(result_path, result)
        return run

    def picker_v2_run(self):
        run = self.picker_run()
        raw_path = run / 'output/acceptance-result.json'
        raw = json.loads(raw_path.read_text())
        scenario = raw['assertions']['scenario']
        scenario['popup_diagnostic_schema_version'] = 2
        visible = scenario['samples'][1]
        hidden = deepcopy(visible)
        hidden.update(probe_begin_ticks=160, probe_end_ticks=170,
                      owned_popup_handle_before=0, owned_popup_handle=0,
                      owned_popup_thread_id_before=0, owned_popup_thread_id=0,
                      owned_popup_class_before='', owned_popup_class='')
        for key, begin, end in (('popup_before', 150, 159), ('popup_after', 171, 180)):
            hidden[key].update(begin_ticks=begin, end_ticks=end, accepted_popup_handle=0,
                               popup_visible=False, visibility_lookup='hidden',
                               disposition='owned-hidden-inactive',
                               observed_predicates=['hidden'])
        scenario['samples'].insert(1, hidden)
        write_json(raw_path, raw)
        self.refresh_picker(run)
        return run

    def refresh_picker(self, run):
        self.refresh_owned(run)
        result_path = run / 'output/run-result.json'
        result = json.loads(result_path.read_text())
        result['diagnostic'] = (evidence.CUSTOM_MODE if run.name == evidence.CUSTOM_RUN_ID
                                else evidence.PICKER_MODE)
        write_json(result_path, result)

    def custom_run(self):
        run = self.picker_v2_run().rename(self.root / evidence.CUSTOM_RUN_ID)
        output = run / 'output'
        manifest_path = run / 'input-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['run_id'] = evidence.CUSTOM_RUN_ID
        manifest['request']['mode'] = evidence.CUSTOM_MODE
        manifest['request'].pop('picker_identity_plan')
        manifest['request']['custom_input_plan'] = deepcopy(evidence.CUSTOM_PLAN)
        manifest['command'][manifest['command'].index(evidence.PICKER_MODE)] = evidence.CUSTOM_MODE
        write_json(manifest_path, manifest)
        for name in ('cleanup.json', 'platform-preflight.json', 'platform-postlaunch.json',
                     'acceptance-observations.json'):
            path = output / name
            document = json.loads(path.read_text())
            document['run_id'] = evidence.CUSTOM_RUN_ID
            write_json(path, document)
        (output / 'picker-100-after.png').rename(output / 'custom-100-after.png')
        raw_path = output / 'acceptance-result.json'
        raw = json.loads(raw_path.read_text())
        scenario = raw['assertions']['scenario']
        scenario['mode'] = evidence.CUSTOM_MODE
        scenario['plan'] = deepcopy(evidence.CUSTOM_PLAN)
        scenario['popup_diagnostic_schema_version'] = 3
        scenario.pop('picker')
        scenario['custom_input'] = {'expected_rows': 100, 'observed_rows': 100,
            'import_command_ready': True, 'picker_closed': True, 'fixture_files': 100,
            'confirmed_prompt_handle': 901, 'confirmed_prompt_class': 'DarkReNamerInputWindow',
            'confirmed_prompt_visible': True, 'confirmed_prompt_enabled': True,
            'confirmed_preview': 'confirmed-ordinary-00000.txt',
            'cancelled_prompt_handle': 902, 'cancelled_prompt_class': 'DarkReNamerInputWindow',
            'cancelled_prompt_visible': True, 'cancelled_prompt_enabled': True,
            'cancelled_preview': 'ordinary-00000.txt', 'confirmed_then_reset': True,
            'cancellation_retired': True}
        scenario['controlled_hidden_input'] = {'schema_version': 1, 'prompt_handle': 901,
            'hide_request_ticks': 1020000, 'hidden_observed_ticks': 1030000,
            'restore_request_ticks': 1730000, 'restored_observed_ticks': 1740000}
        events = scenario['response_timeline']['events']
        events.extend({'operation': operation, 'step': step, 'ticks': tick,
                       'window_handle': handle}
                      for operation, step, tick, handle in (
                          ('full-preview', 'prompt_request', 1000000, 0),
                          ('full-preview', 'prompt_found', 1010000, 901),
                          ('full-preview', 'commit_invoke', 1900000, 901),
                          ('full-preview', 'prompt_closed', 1910000, 901),
                          ('full-preview', 'first_row_observed', 1920000, 0),
                          ('custom-cancel', 'prompt_request', 2000000, 0),
                          ('custom-cancel', 'prompt_found', 2010000, 902),
                          ('custom-cancel', 'cancel_invoke', 2500000, 902),
                          ('custom-cancel', 'prompt_closed', 2510000, 902)))
        def custom_sample(phase, begin, end, handle, hidden=False):
            row = deepcopy(scenario['samples'][2])
            row.update(phase=phase, probe_begin_ticks=begin, probe_end_ticks=end,
                       owned_popup_handle_before=0 if hidden else handle,
                       owned_popup_handle=0 if hidden else handle,
                       main_enabled_before=False, main_enabled=False)
            for key, start, stop in (('popup_before', begin - 10, begin - 1),
                                     ('popup_after', end + 1, end + 10)):
                row[key].update(begin_ticks=start, end_ticks=stop, raw_popup_handle=handle,
                                accepted_popup_handle=0 if hidden else handle,
                                popup_class='DarkReNamerInputWindow',
                                popup_visible=not hidden,
                                visibility_lookup='hidden' if hidden else 'visible',
                                disposition='owned-hidden-inactive' if hidden else 'owned-popup',
                                observed_predicates=['hidden'] if hidden else [])
            if hidden:
                row.update(owned_popup_thread_id_before=0, owned_popup_thread_id=0,
                           owned_popup_class_before='', owned_popup_class='')
            return row
        scenario['samples'].insert(3, custom_sample('custom-confirm', 1200000, 1200010, 901, True))
        scenario['samples'].insert(4, custom_sample('custom-confirm', 1800000, 1800010, 901))
        scenario['samples'].insert(5, custom_sample('custom-cancel', 2200000, 2200010, 902))
        scenario['samples'][-1]['probe_begin_ticks'] = 2700000
        scenario['samples'][-1]['probe_end_ticks'] = 2700010
        for key, start, stop in (('popup_before', 2699990, 2699999),
                                 ('popup_after', 2700011, 2700020)):
            scenario['samples'][-1][key].update(begin_ticks=start, end_ticks=stop)
        for row in scenario['samples']:
            row['probe_error_code'] = 0
            row['ui_response_ms'] = (row['probe_end_ticks'] - row['probe_begin_ticks']) / 1000
        raw['assertions']['scope'] = evidence.CUSTOM_SCOPE
        raw['screenshots'] = [{'file': 'custom-100-after.png',
            'sha256': digest((output / 'custom-100-after.png').read_bytes())}]
        write_json(raw_path, raw)
        self.refresh_picker(run)
        return run

    def test_custom_input_lifecycle_is_independently_bound_to_popup_samples(self):
        run = self.custom_run()
        raw_path = run / 'output/acceptance-result.json'
        with mock.patch.object(evidence, 'selected_picker_failure_schema', return_value=3):
            self.assertTrue(evidence.validate_picker_run(
                self.root, run.name, SOURCE, SCRIPT_ROOT.parent)['custom_prompt_intervals_sampled'])
            collection = vm_gui.collection_document(
                run, digest((run / 'input-manifest.json').read_bytes()), run.name)
            self.assertIn('custom-100-after.png',
                          {row['relative_path'] for row in collection['files']})
            profile = (SCRIPT_ROOT.parent / 'config/vm-automated-v2.json').read_bytes()
            with mock.patch.object(evidence.subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout=profile)), redirect_stdout(io.StringIO()) as report:
                self.assertEqual(evidence.main(SCRIPT_ROOT.parent, [
                    '--result-root', str(self.root), '--expected-source-sha', SOURCE,
                    '--run', run.name, '--diagnostic', evidence.CUSTOM_MODE,
                    '--acceptance-profile-id', evidence.V2_PROFILE_ID]), 0)
                self.assertEqual(json.loads(report.getvalue())['status'], 'observed')
            original = raw_path.read_bytes()
            reused = json.loads(original)
            reused_scenario = reused['assertions']['scenario']
            reused_scenario['custom_input']['cancelled_prompt_handle'] = 901
            for event in reused_scenario['response_timeline']['events'][12:15]:
                event['window_handle'] = 901
            reused_sample = reused_scenario['samples'][5]
            reused_sample['owned_popup_handle_before'] = 901
            reused_sample['owned_popup_handle'] = 901
            for key in ('popup_before', 'popup_after'):
                reused_sample[key]['raw_popup_handle'] = 901
                reused_sample[key]['accepted_popup_handle'] = 901
            write_json(raw_path, reused)
            self.refresh_picker(run)
            self.assertEqual(evidence.validate_picker_run(
                self.root, run.name, SOURCE, SCRIPT_ROOT.parent)['status'], 'observed')
            for index, mutation in enumerate((
                lambda s: s['samples'][3]['popup_after'].__setitem__('popup_process_id', 4243),
                lambda s: s['samples'][4]['popup_before'].__setitem__('direct_owner', 999),
                lambda s: [s['samples'][4][key].__setitem__('popup_class', '#32770')
                           for key in ('popup_before', 'popup_after')],
                lambda s: s['samples'][3]['popup_before'].__setitem__('class_lookup', 'failed'),
                lambda s: s['samples'][3]['popup_before'].__setitem__('disposition', 'main'),
                lambda s: s['controlled_hidden_input'].__setitem__('restore_request_ticks', 1200005),
                lambda s: s['samples'][4].__setitem__('probe_error_code', 5),
                lambda s: s['samples'][4].__setitem__('probe_status', 'failure_unknown'),
                lambda s: s['samples'][4].update(probe_status='timeout', probe_error_code=0),
                lambda s: s['samples'][4].__setitem__('ui_response_ms', 50.0),
                lambda s: s.__setitem__('sample_transfer_failure', {
                    'schema_version': 1, 'stage': 'convert-stopped-samples',
                    'reported_raw_sample_count': 7,
                    'reported_last_probe_end_ticks': 2700010}),
                lambda s: s['custom_input'].__setitem__('cancellation_retired', False),
                lambda s: s['samples'].pop(4),
            )):
                with self.subTest(index=index):
                    raw = json.loads(original)
                    mutation(raw['assertions']['scenario'])
                    write_json(raw_path, raw)
                    self.refresh_picker(run)
                    with self.assertRaises(evidence.EvidenceError):
                        evidence.validate_picker_run(self.root, run.name, SOURCE, SCRIPT_ROOT.parent)
            raw_path.write_bytes(original)
            self.refresh_picker(run)

    def custom_completed_failed_run(self, failure_kind):
        run = self.custom_run()
        output = run / 'output'
        raw_path = output / 'acceptance-result.json'
        raw = json.loads(raw_path.read_text())
        scenario = raw['assertions']['scenario']
        if failure_kind in {'post-stop-observer', 'owned-dispose'}:
            raw['status'] = 'failed'
            raw['failure_reason'] = 'gui_regression_observer_failed'
            raw['assertions']['overall'] = 'failed'
            if failure_kind == 'post-stop-observer':
                scenario['native_process_lifetime']['terminal_exit_filetime'] = None
                scenario.pop('custom_input')
                raw['screenshots'] = []
                (output / 'custom-100-after.png').unlink()
            scenario['post_stop_failure'] = {'schema_version': 1,
                'stage': 'capture' if failure_kind == 'post-stop-observer' else 'owned-dispose',
                'sample_count': len(scenario['samples']),
                'last_probe_end_ticks': scenario['samples'][-1]['probe_end_ticks']}
        elif failure_kind == 'observer-cleanup':
            raw['status'] = 'failed'
            raw['failure_reason'] = 'runtime_cleanup_failed'
        elif failure_kind != 'controller-cleanup':
            raise AssertionError(failure_kind)
        write_json(raw_path, raw)
        transport_path = output / 'transport.json'
        transport = json.loads(transport_path.read_text())
        transport.update(status='failed', guest_cleanup=False)
        write_json(transport_path, transport)
        cleanup_path = output / 'cleanup.json'
        cleanup = json.loads(cleanup_path.read_text())
        cleanup.update(status='failed', guest=False, controller_exit_code=1)
        write_json(cleanup_path, cleanup)
        if failure_kind != 'controller-cleanup':
            (output / 'platform-postlaunch.json').unlink()
        self.fixture.refresh(run)
        (output / 'run-result.json').unlink()
        return run

    def test_custom_completed_failures_retain_samples_and_require_cleanup_proof(self):
        proof = {'environment': 'strict-failed', 'owned_cleanup': 'owned-clean',
                 'acceptance': 'rejected'}
        for kind in ('post-stop-observer', 'owned-dispose', 'observer-cleanup',
                     'controller-cleanup'):
            with self.subTest(kind=kind):
                self.reset_fixture()
                run = self.custom_completed_failed_run(kind)
                with mock.patch.object(evidence, 'selected_picker_failure_schema', return_value=3), \
                     mock.patch.object(evidence, 'verify_preserved_owned_cleanup',
                                       return_value=proof):
                    verdict = evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                           SCRIPT_ROOT.parent)
                    self.assertEqual(verdict['status'], 'failure-observed')
                    self.assertEqual(verdict['failure']['kind'],
                                     'post-stop-observer' if kind == 'owned-dispose' else kind)
                    self.assertEqual(verdict['retained_samples'], 7)
                    self.assertEqual(verdict['acceptance'], 'rejected')
                with mock.patch.object(evidence, 'selected_picker_failure_schema', return_value=3), \
                     mock.patch.object(evidence, 'verify_preserved_owned_cleanup',
                                       side_effect=evidence.EvidenceError('missing cleanup proof')):
                    with self.assertRaisesRegex(evidence.EvidenceError, 'missing cleanup proof'):
                        evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                     SCRIPT_ROOT.parent)
                if kind == 'post-stop-observer':
                    raw_path = run / 'output/acceptance-result.json'
                    original = raw_path.read_bytes()
                    altered = json.loads(original)
                    altered['assertions']['scenario']['post_stop_failure']['stage'] = 'sampler'
                    write_json(raw_path, altered)
                    self.fixture.refresh(run)
                    with mock.patch.object(evidence, 'selected_picker_failure_schema', return_value=3), \
                         mock.patch.object(evidence, 'verify_preserved_owned_cleanup',
                                           return_value=proof):
                        with self.assertRaises(evidence.EvidenceError):
                            evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                         SCRIPT_ROOT.parent)
                    raw_path.write_bytes(original)

    def test_custom_sample_transfer_failure_is_rejected_without_verified_sample_coverage(self):
        run = self.custom_completed_failed_run('post-stop-observer')
        raw_path = run / 'output/acceptance-result.json'
        raw = json.loads(raw_path.read_text())
        scenario = raw['assertions']['scenario']
        stopped_samples = scenario.pop('samples')
        scenario.pop('post_stop_failure')
        scenario['sample_transfer_failure'] = {
            'schema_version': 1, 'stage': 'convert-stopped-samples',
            'reported_raw_sample_count': len(stopped_samples),
            'reported_last_probe_end_ticks': stopped_samples[-1]['probe_end_ticks']}
        self.assertNotIn('sampler_failure', scenario)
        write_json(raw_path, raw)
        self.fixture.refresh(run)
        (run / 'output/run-result.json').unlink(missing_ok=True)
        proof = {'environment': 'strict-failed', 'owned_cleanup': 'owned-clean',
                 'acceptance': 'rejected'}
        with mock.patch.object(evidence, 'selected_picker_failure_schema', return_value=3), \
             mock.patch.object(evidence, 'verify_preserved_owned_cleanup', return_value=proof):
            verdict = evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                   SCRIPT_ROOT.parent)
            self.assertEqual(verdict['failure']['kind'], 'sample-transfer')
            self.assertEqual(verdict['sample_coverage'], 'unverified')
            self.assertEqual(verdict['retained_samples'], 0)
            self.assertEqual(verdict['acceptance'], 'rejected')
            original = raw_path.read_bytes()
            for mutation in (
                lambda s: s['sample_transfer_failure'].__setitem__('schema_version', True),
                lambda s: s['sample_transfer_failure'].__setitem__('reported_raw_sample_count', 0),
                lambda s: s['sample_transfer_failure'].__setitem__('reported_last_probe_end_ticks', 2**63),
                lambda s: s['sample_transfer_failure'].__setitem__('stage', 'sampler'),
                lambda s: s.__setitem__('samples', stopped_samples),
                lambda s: s.__setitem__('sampler_failure', None),
                lambda s: s.__setitem__('post_stop_failure', {'schema_version': 1}),
            ):
                with self.subTest(mutation=mutation):
                    altered = json.loads(original)
                    mutation(altered['assertions']['scenario'])
                    write_json(raw_path, altered)
                    self.fixture.refresh(run)
                    (run / 'output/run-result.json').unlink(missing_ok=True)
                    with self.assertRaises(evidence.EvidenceError):
                        evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                     SCRIPT_ROOT.parent)
            raw_path.write_bytes(original)
            self.fixture.refresh(run)
            (run / 'output/run-result.json').unlink(missing_ok=True)
        with mock.patch.object(evidence, 'selected_picker_failure_schema', return_value=3), \
             mock.patch.object(evidence, 'verify_preserved_owned_cleanup',
                               side_effect=evidence.EvidenceError('missing cleanup proof')):
            with self.assertRaisesRegex(evidence.EvidenceError, 'missing cleanup proof'):
                evidence.validate_picker_run(self.root, run.name, SOURCE, SCRIPT_ROOT.parent)

    def test_picker_v2_success_requires_visible_bound_picker_and_postlaunch(self):
        run = self.picker_v2_run()
        with mock.patch.object(evidence, 'selected_picker_failure_schema', return_value=2):
            self.assertEqual(evidence.validate_picker_run(
                self.root, run.name, SOURCE, SCRIPT_ROOT.parent)['status'], 'observed')
            profile = (SCRIPT_ROOT.parent / 'config/vm-automated-v2.json').read_bytes()
            with mock.patch.object(evidence.subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout=profile)), redirect_stdout(io.StringIO()) as report:
                self.assertEqual(evidence.main(SCRIPT_ROOT.parent, [
                    '--result-root', str(self.root), '--expected-source-sha', SOURCE,
                    '--run', run.name, '--diagnostic', evidence.PICKER_MODE,
                    '--acceptance-profile-id', evidence.V2_PROFILE_ID]), 0)
                self.assertEqual(json.loads(report.getvalue())['status'], 'observed')
            raw_path = run / 'output/acceptance-result.json'
            original = raw_path.read_bytes()
            def alter_visible(scenario, field, value):
                for key in ('popup_before', 'popup_after'):
                    scenario['samples'][2][key][field] = value
            for mutate in (
                lambda s: alter_visible(s, 'raw_popup_handle', 901),
                lambda s: alter_visible(s, 'popup_class', 'Other'),
                lambda s: s.__setitem__('popup_diagnostic_schema_version', 1),
                lambda s: s['samples'][1]['popup_after'].__setitem__('popup_process_id', 4243),
            ):
                with self.subTest(mutate=mutate):
                    raw = json.loads(original)
                    mutate(raw['assertions']['scenario'])
                    write_json(raw_path, raw)
                    self.refresh_picker(run)
                    with self.assertRaises(evidence.EvidenceError):
                        evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                     SCRIPT_ROOT.parent)
            raw_path.write_bytes(original)
            self.refresh_picker(run)
            postlaunch = run / 'output/platform-postlaunch.json'
            postlaunch.unlink()
            self.refresh_picker(run)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_picker_run(self.root, run.name, SOURCE, SCRIPT_ROOT.parent)

    def test_picker_collection_precheck_bounds_png_count_and_bytes(self):
        run = self.picker_run()
        output = run / 'output'
        input_hash = digest((run / 'input-manifest.json').read_bytes())
        self.assertEqual(vm_gui.collection_document(run, input_hash, run.name)['run_id'], run.name)
        extra = output / 'unexpected.png'
        extra.write_bytes((output / 'picker-100-after.png').read_bytes())
        with self.assertRaises(ValueError):
            vm_gui.collection_document(run, input_hash, run.name)
        extra.unlink()
        oversized = output / 'oversized.bin'
        with oversized.open('wb') as stream:
            stream.truncate(32 * 1024 * 1024)
        with self.assertRaises(ValueError):
            vm_gui.collection_document(run, input_hash, run.name)

    def picker_failed_run(self, schema_version=2):
        run = self.picker_v2_run()
        output = run / 'output'
        raw_path = output / 'acceptance-result.json'
        raw = json.loads(raw_path.read_text())
        scenario = raw['assertions']['scenario']
        if schema_version == 1:
            scenario.pop('popup_diagnostic_schema_version')
        samples = scenario.pop('samples')
        scenario['partial_samples'] = samples[:1 if schema_version == 1 else 2]
        scenario['native_process_lifetime']['terminal_exit_filetime'] = None
        main = {'handle': 1001, 'process_id': 4242,
            'process_start_utc_ticks': scenario['process_start_utc_ticks'],
            'thread_id': 7, 'class': 'DarkReNamerWindow', 'enabled': False,
            'lookup': 'complete', 'thread_lookup_error': None,
            'class_lookup_error': None}
        rejected = deepcopy(samples[1]['popup_before'])
        rejected.update(begin_ticks=510, end_ticks=520, disposition='rejected',
                        accepted_popup_handle=900, failed_predicates=['hidden'])
        scenario['sampler_failure'] = {'schema_version': schema_version,
            'phase': 'ordinary-100', 'error_type': 'InvalidOperationException',
            'message': 'Sampler active owned popup identity changed.',
            'sample_begin_ticks': 500, 'sample_end_ticks': 530,
            'probe_begin_ticks': 0, 'probe_end_ticks': 0, 'probe_error_code': None,
            'qpc_frequency': 1000000, 'main_before': main, 'main_after': main,
            'popup_before': rejected, 'popup_after': None}
        raw['status'] = 'failed'
        raw['assertions']['overall'] = 'failed'
        write_json(raw_path, raw)
        transport_path = output / 'transport.json'
        transport = json.loads(transport_path.read_text())
        transport.update(status='failed', guest_cleanup=False)
        write_json(transport_path, transport)
        cleanup_path = output / 'cleanup.json'
        cleanup = json.loads(cleanup_path.read_text())
        cleanup.update(status='failed', guest=False, controller_exit_code=1)
        write_json(cleanup_path, cleanup)
        (output / 'platform-postlaunch.json').unlink()
        self.fixture.refresh(run)
        (output / 'run-result.json').unlink()
        return run

    def test_picker_failed_preflight_only_preserves_v1_and_rejects_v2_downgrade(self):
        for version in (1, 2):
            with self.subTest(version=version):
                self.reset_fixture()
                run = self.picker_failed_run(version)
                proof = {'environment': 'strict-failed', 'owned_cleanup': 'owned-clean',
                         'acceptance': 'rejected'}
                with mock.patch.object(evidence, 'selected_picker_failure_schema',
                                       return_value=version), \
                     mock.patch.object(evidence, 'verify_preserved_owned_cleanup',
                                       return_value=proof) as verified:
                    verdict = evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                           SCRIPT_ROOT.parent)
                    self.assertEqual(verdict['status'], 'failure-observed')
                    self.assertEqual(verdict['postlaunch'], 'unavailable')
                    self.assertEqual(verdict['acceptance'], 'rejected')
                    verified.assert_called_once_with(run / 'output', profile_id=evidence.V2_PROFILE_ID,
                        profile_sha256=evidence.OWNED_PERFORMANCE_PROFILE_SHA256)
                    profile = (SCRIPT_ROOT.parent / 'config/vm-automated-v2.json').read_bytes()
                    with mock.patch.object(evidence.subprocess, 'run', return_value=SimpleNamespace(
                            returncode=0, stdout=profile)), redirect_stdout(io.StringIO()) as report:
                        self.assertEqual(evidence.main(SCRIPT_ROOT.parent, [
                            '--result-root', str(self.root), '--expected-source-sha', SOURCE,
                            '--run', run.name, '--diagnostic', evidence.PICKER_MODE,
                            '--acceptance-profile-id', evidence.V2_PROFILE_ID]), 1)
                        self.assertEqual(json.loads(report.getvalue())['status'], 'failure-observed')
                    with mock.patch.object(evidence, 'verify_preserved_owned_cleanup',
                                           side_effect=evidence.EvidenceError('missing owned proof')):
                        with self.assertRaisesRegex(evidence.EvidenceError, 'missing owned proof'):
                            evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                         SCRIPT_ROOT.parent)
                    raw_path = run / 'output/acceptance-result.json'
                    raw = json.loads(raw_path.read_text())
                    raw['assertions']['scenario']['partial_samples'] = []
                    write_json(raw_path, raw)
                    self.fixture.refresh(run)
                    (run / 'output/run-result.json').unlink()
                    with self.assertRaises(evidence.EvidenceError):
                        evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                     SCRIPT_ROOT.parent)
                if version == 2:
                    self.reset_fixture()
                    run = self.picker_failed_run(1)
                    with mock.patch.object(evidence, 'selected_picker_failure_schema',
                                           return_value=2):
                        with self.assertRaises(evidence.EvidenceError):
                            evidence.validate_picker_run(self.root, run.name, SOURCE,
                                                         SCRIPT_ROOT.parent)

    def test_picker_one_import_collection_and_cli_reject_downgrade_and_missing_lease(self):
        run = self.picker_run()
        with mock.patch.object(evidence, 'selected_picker_failure_schema', return_value=1):
            verdict = evidence.validate_picker_run(self.root, run.name, SOURCE, SCRIPT_ROOT.parent)
            self.assertEqual(verdict['status'], 'observed')
            profile = (SCRIPT_ROOT.parent / 'config/vm-automated-v2.json').read_bytes()
            with mock.patch.object(evidence.subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout=profile)):
                with redirect_stdout(io.StringIO()) as report:
                    exit_code = evidence.main(SCRIPT_ROOT.parent, [
                        '--result-root', str(self.root), '--expected-source-sha', SOURCE,
                        '--run', run.name, '--diagnostic', evidence.PICKER_MODE,
                        '--acceptance-profile-id', evidence.V2_PROFILE_ID])
                self.assertEqual(exit_code, 0)
                self.assertEqual(json.loads(report.getvalue())['status'], 'observed')
                with self.assertRaises(evidence.EvidenceError):
                    evidence.main(SCRIPT_ROOT.parent, [
                        '--result-root', str(self.root), '--expected-source-sha', SOURCE,
                        '--run', run.name, '--diagnostic', evidence.PICKER_MODE,
                        '--acceptance-profile-id', evidence.V1_PROFILE_ID])
            for leaf, mutate in (
                ('input-manifest.json', lambda d: d['request']['picker_identity_plan'].__setitem__('idle_ms', 30000)),
                ('input-manifest.json', lambda d: d.__setitem__('acceptance_profile_sha256', '0' * 64)),
                ('input-manifest.json', lambda d: d.__setitem__('acceptance_profile_id', evidence.V1_PROFILE_ID)),
                ('output/desktop-stop-response.json', lambda d: d.__setitem__('lifecycleStatus', 'pending')),
            ):
                with self.subTest(leaf=leaf, mutate=mutate):
                    path = run / leaf
                    saved = path.read_bytes()
                    changed = json.loads(saved)
                    mutate(changed)
                    write_json(path, changed)
                    if leaf.startswith('output/'):
                        self.fixture.refresh(run)
                    with self.assertRaises(evidence.EvidenceError):
                        evidence.validate_picker_run(self.root, run.name, SOURCE, SCRIPT_ROOT.parent)
                    path.write_bytes(saved)
                    if leaf.startswith('output/'):
                        self.fixture.refresh(run)
            raw_path = run / 'output/acceptance-result.json'
            raw = json.loads(raw_path.read_text())
            raw['assertions']['scenario']['samples'] = []
            write_json(raw_path, raw)
            self.refresh_owned(run)
            result_path = run / 'output/run-result.json'
            result = json.loads(result_path.read_text())
            result['diagnostic'] = evidence.PICKER_MODE
            write_json(result_path, result)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_picker_run(self.root, run.name, SOURCE, SCRIPT_ROOT.parent)

    def test_owned_legacy_receipt_cannot_downgrade_selected_timeline_source(self):
        run, profile_sha = self.owned_run()
        with self.assertRaisesRegex(evidence.EvidenceError, "selected source schema"):
            evidence.validate_performance_run(
                self.root, run.name, SOURCE,
                expected_profile_sha256=profile_sha,
                expected_response_schema_version=1)

    def test_owned_run_requires_exact_profile_lifetime_job_desktop_and_text(self):
        run, profile_sha = self.owned_run()
        verdict = evidence.validate_performance_run(self.root, run.name, SOURCE,
                                                     expected_profile_sha256=profile_sha)
        self.assertEqual(verdict['owned_cleanup'], 'owned-clean')
        self.assertEqual(verdict['observation'], 'complete')
        cleanup = json.loads((run / 'output/transport.json').read_text())['raw_cleanup']
        for phase, suffix in (('before', ''), ('after_intervention', '_after_intervention'),
                              ('after_delete', '_after_delete')):
            ledger = verdict['ambient_delta_ledger'][phase]
            self.assertEqual(ledger['processes'], cleanup['unexpected_runner_processes' + suffix])
            self.assertEqual(ledger['tasks'], cleanup['unexpected_runner_tasks' + suffix])
            self.assertEqual(verdict['ambient_delta_counts'][phase],
                             {kind: len(rows) for kind, rows in ledger.items()})

    def test_owned_adapter_rejects_rehashed_lifetime_job_lease_text_and_cleanup_mutations(self):
        mutations = (
            ('native-filetime', 'acceptance-result.json',
             lambda d: d['assertions']['scenario']['native_process_lifetime'].__setitem__(
                 'creation_filetime', d['assertions']['scenario']['native_process_lifetime'][
                     'creation_filetime'] + 1)),
            ('native-terminal', 'acceptance-result.json',
             lambda d: d['assertions']['scenario']['native_process_lifetime'].__setitem__(
                 'terminal_exit_filetime', 0)),
            ('candidate-job', 'acceptance-result.json',
             lambda d: d['process_job_cleanup'][0].__setitem__('forced_termination', True)),
            ('extra-job', 'acceptance-result.json',
             lambda d: d['process_job_cleanup'].append(deepcopy(d['process_job_cleanup'][0]))),
            ('observer-lifetime', 'acceptance-result.json',
             lambda d: d['observer_lifecycle'].__setitem__('pid', 9)),
            ('desktop-stop', 'desktop-stop-response.json',
             lambda d: d.__setitem__('lifecycleStatus', 'pending')),
            ('desktop-lease', 'desktop-lease.json',
             lambda d: d.__setitem__('lease_id', 'f' * 32)),
            ('desktop-start', 'desktop-start-response.json',
             lambda d: d.__setitem__('processId', 9002)),
            ('text-registry', 'acceptance-observations.json',
             lambda d: d['text_scale_restoration']['final'].__setitem__('registry_value', 150)),
            ('text-integer-factor', 'acceptance-observations.json',
             lambda d: d['text_scale_restoration']['final'].__setitem__('ui_settings_raw_factor', 1)),
            ('text-missing-final', 'acceptance-observations.json',
             lambda d: d['text_scale_restoration'].__setitem__('final', None)),
            ('root-survivor', 'transport.json',
             lambda d: d['raw_cleanup'].__setitem__('guest_root_present', True)),
            ('ambient-duplicate', 'transport.json',
             lambda d: d['raw_cleanup']['owned_resource_evidence']['process_snapshots'][
                 'after_delete']['processes'].append(deepcopy(d['raw_cleanup'][
                     'owned_resource_evidence']['process_snapshots']['after_delete']['processes'][0]))),
        )
        for label, leaf, mutate in mutations:
            with self.subTest(label=label):
                self.reset_fixture()
                run, profile_sha = self.owned_run()
                path = run / 'output' / leaf
                document = json.loads(path.read_text())
                mutate(document)
                write_json(path, document)
                self.refresh_owned(run)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_performance_run(self.root, run.name, SOURCE,
                        expected_profile_sha256=profile_sha)

    def test_owned_manifest_rejects_cross_route_plan_and_profile(self):
        mutations = (
            lambda d: d['request']['performance_plan'].__setitem__('idle_seconds', 29),
            lambda d: d['request']['performance_plan'].__setitem__('long_path_order', 'visible-hidden'),
            lambda d: d['request']['desktop'].__setitem__('dpi', 120),
            lambda d: d.__setitem__('acceptance_profile_sha256', '0' * 64),
            lambda d: d['command'].remove('--acceptance-profile-id'),
            lambda d: d.__setitem__('run_id', evidence.performance_run_id('hidden-visible')),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                self.reset_fixture()
                run, profile_sha = self.owned_run()
                manifest_path = run / 'input-manifest.json'
                manifest = json.loads(manifest_path.read_text())
                mutate(manifest)
                write_json(manifest_path, manifest)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_performance_run(self.root, run.name, SOURCE,
                        expected_profile_sha256=profile_sha)

    def test_owned_new_id_enforces_collection_budget_and_one_png(self):
        for extra_name, size in (('second.png', 1), ('oversize.bin', 33 * 1024 * 1024)):
            with self.subTest(extra_name=extra_name):
                self.reset_fixture()
                run, profile_sha = self.owned_run()
                with (run / 'output' / extra_name).open('wb') as stream:
                    stream.truncate(size)
                self.refresh_owned(run)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_performance_run(self.root, run.name, SOURCE,
                        expected_profile_sha256=profile_sha)

    def test_owned_missing_desktop_stop_cannot_be_promoted_by_cleanup_boolean(self):
        run, profile_sha = self.owned_run()
        (run / 'output/desktop-stop-response.json').unlink()
        self.refresh_owned(run)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_performance_run(self.root, run.name, SOURCE,
                expected_profile_sha256=profile_sha)


class FocusedClearEvidenceTests(SyntheticFixtureTestCase):
    TOOLING_SOURCE = "c" * 40
    TOOLING_TREE = "d" * 40

    @cached_property
    def focused_run(self):
        run = self.fixture.build(evidence.FOCUSED_CLEAR_RUN_ID, "standard")
        output = run / "output"
        manifest_path = run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        names = {"application": "DarkReNamer.exe", "launcher": "run-gui-regression.py",
                 "builder": "test-windows-vm.py", "controller": "run-windows-vm-tests.ps1",
                 "runner": "windows-vm-guest.ps1", "observer": "windows-vm-acceptance.ps1",
                 "lockfile": "Cargo.lock"}
        for key, name in names.items():
            row = manifest["artifacts"][key]
            (run / row["file"]).rename(run / "inputs" / name)
            row["file"] = "inputs/" + name
        self.original_harness_bytes = {
            "scripts/" + names[key]: (run / "inputs" / names[key]).read_bytes()
            for key in ("launcher", "builder", "controller", "runner", "observer")}
        original = {"schema_version": 1, "source_sha": SOURCE, "source_state": "clean",
                    "target": "x86_64-pc-windows-msvc",
                    "application": {"file": "DarkReNamer.exe",
                                    "sha256": manifest["artifacts"]["application"]["sha256"]},
                    "cargo_lock_sha256": manifest["artifacts"]["lockfile"]["sha256"],
                    "test_binaries": [{"file": "original-test.exe", "sha256": "e" * 64}]}
        write_json(run / "inputs" / "original-bundle.json", original)
        self.original_hash = digest((run / "inputs" / "original-bundle.json").read_bytes())
        self.application_hash = manifest["artifacts"]["application"]["sha256"]
        self.tooling_record = {"schema_version": 1, "manifest": {}, "modules": [
            {"role": role, "file": role + ".py"} for role in
            ("vm-launcher", "powershell-controller-entry", "powershell-ui-entry",
             "powershell-guest-entry", "evidence-gui")]}
        write_json(run / "inputs" / "tooling-record.json", self.tooling_record)
        tooling_hash = digest((run / "inputs" / "tooling-record.json").read_bytes())
        def active_row(name):
            data = (run / "inputs" / name).read_bytes()
            return {"file": name, "sha256": digest(data)}
        active = {"schema_version": 2, "lane": evidence.FOCUSED_PRESERVED_LANE,
                  "target": original["target"], "test_binaries": [],
                  "product": {"source_sha": SOURCE, "source_tree": TREE,
                      "source_state": "clean", "application": active_row("DarkReNamer.exe"),
                      "provenance": {"kind": "preserved-source-built-bundle",
                          "reference_source_sha": evidence.FOCUSED_PRODUCT_REFERENCE_SHA,
                          "original_bundle_manifest": active_row("original-bundle.json"),
                          "non_tooling_entries_sha256": evidence.FOCUSED_PRODUCT_ENTRIES_SHA256,
                          "non_tooling_entries_count": 104,
                          "cargo_lock_sha256": original["cargo_lock_sha256"]}},
                  "harness": {"source_sha": self.TOOLING_SOURCE,
                      "source_tree": self.TOOLING_TREE, "source_state": "clean",
                      "launcher": active_row("run-gui-regression.py"),
                      "builder": active_row("test-windows-vm.py"),
                      "controller": active_row("run-windows-vm-tests.ps1"),
                      "runner": active_row("windows-vm-guest.ps1"),
                      "observers": {"ui": active_row("windows-vm-acceptance.ps1")},
                      "tooling_record": active_row("tooling-record.json")}}
        write_json(run / "inputs" / "bundle.json", active)
        manifest["bundle_manifest"] = {"file": "inputs/bundle.json",
            "bytes": (run / "inputs" / "bundle.json").stat().st_size,
            "sha256": digest((run / "inputs" / "bundle.json").read_bytes())}
        manifest["tooling_source_sha"] = self.TOOLING_SOURCE
        manifest["tooling_source_tree"] = self.TOOLING_TREE
        manifest["request"] = {"mode": evidence.FOCUSED_CLEAR_MODE, "appearance": "light",
            "desktop": {"width": 1366, "height": 768, "dpi": 96},
            "text_scale_percent": 100,
            "focused_clear_plan": deepcopy(evidence.FOCUSED_CLEAR_PLAN)}
        app_hash = manifest["artifacts"]["application"]["sha256"]
        manifest["prepared_bundle"] = {"origin": "preserved-source-built-product-current-tooling",
            "bundle_manifest_sha256": manifest["bundle_manifest"]["sha256"],
            "application_sha256": app_hash,
            "original_bundle_manifest_sha256": self.original_hash,
            "tooling_record_sha256": tooling_hash,
            "product_source_sha": SOURCE, "tooling_source_sha": self.TOOLING_SOURCE}
        manifest["command"] = ["python3", "-I", "scripts/run-gui-regression.py",
            "--output-root", "<external-output-root>", "--connection-profile",
            "<private-connection-profile>", "--diagnostic", evidence.FOCUSED_CLEAR_MODE,
            "--preserved-product-bundle-root", "<external-preserved-product-bundle-root>",
            "--expected-original-bundle-sha256", self.original_hash,
            "--expected-product-source-sha", SOURCE,
            "--expected-tooling-source-sha", self.TOOLING_SOURCE,
            "--expected-prepared-application-sha256", app_hash]
        write_json(manifest_path, manifest)
        (output / "screen.png").rename(output / "performance-empty.png")
        (output / "text-raster-metrics.json").unlink()
        raw_path = output / "acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        scenario = PerformanceSampleEvidenceTests.sample_scenario(self)
        for field in ("columns", "long_representatives", "extension_representatives"):
            scenario.pop(field)
        scenario["plan"] = deepcopy(evidence.FOCUSED_CLEAR_PLAN)
        scenario["timings"] = scenario["timings"][:4]
        scenario["clear_row_counts"] = [0]
        phases = ("empty-idle", "ordinary-100", "ordinary-1000", "ordinary-10000",
                  "single-row", "full-preview", "post")
        scenario["samples"] = [row for row in scenario["samples"] if row["phase"] in phases]
        scenario["phase_summary"] = [{"phase": phase,
            "sample_count": sum(row["phase"] == phase for row in scenario["samples"]),
            "max_sample_gap_ms": max((row["sample_gap_ms"] for row in scenario["samples"]
                                      if row["phase"] == phase), default=0),
            "max_resource_collection_ms": max((row["resource_collection_ms"]
                for row in scenario["samples"] if row["phase"] == phase), default=0)}
            for phase in phases]
        scenario.update(mode=evidence.FOCUSED_CLEAR_MODE, appearance="light",
            process_id=4242, process_start_utc_ticks=134041000000000000,
            executable_sha256=app_hash, executable_bytes=849408,
            first_clear={"stage": "verified-empty", "command_id": 0x800E,
                "process_id": 4242, "main_handle": 1001, "pre_clear_rows": 10000,
                "preview_reset": [f"ordinary-{index:05d}.txt"
                                  for index in (0, 2499, 4999, 7499, 9999)],
                "post_clear_rows": 0},
            command_sends=[{"command_id": 0x800E, "scenario_phase": "full-preview-clear",
                "native_return": 1, "message_result": 0, "error_code": 0,
                "elapsed_ms": 4.5, "status": "success"}])
        scenario["environment"] = {"hwnd_dpi": 96, "text_scale_factor_percent": 100,
            "main_window": {"hwnd": 1001, "process_id": 4242}}
        raw["assertions"] = {"overall": "passed", "scope": evidence.FOCUSED_CLEAR_SCOPE,
                             "scenario": scenario}
        raw["keyboard"]["status"] = "not_run"
        raw["accessibility"]["status"] = "not_run"
        raw["process_cleanup"] = True
        raw["process_lifecycles"] = [{"process_lifecycle": {
            "pid": 4242, "start_time_utc_ticks": str(scenario["process_start_utc_ticks"]),
            "executable_sha256": app_hash, "start_observed": True,
            "exit_observed": True, "exit_method": "normal-close", "exit_code": 0}}]
        raw["screenshots"] = [{"file": "performance-empty.png",
            "sha256": digest((output / "performance-empty.png").read_bytes())}]
        write_json(raw_path, raw)
        transport_path = output / "transport.json"
        transport = json.loads(transport_path.read_text())
        transport["raw_cleanup"] = clean_controller_cleanup()
        write_json(transport_path, transport)
        self.refresh_focused(run)
        return run

    def refresh_focused(self, run):
        self.fixture.refresh(run)
        output = run / "output"
        manifest = json.loads((run / "input-manifest.json").read_text())
        raw_bytes = (output / "acceptance-result.json").read_bytes()
        result = {"schema_version": 1, "diagnostic": evidence.FOCUSED_CLEAR_MODE,
            "run_id": run.name, "input_manifest_sha256": digest((run / "input-manifest.json").read_bytes()),
            "collection_sha256": digest((run / "collection.json").read_bytes()),
            "cleanup_sha256": digest((output / "cleanup.json").read_bytes()),
            "source_sha": manifest["source_sha"],
            "application_sha256": manifest["artifacts"]["application"]["sha256"],
            "observer_sha256": manifest["artifacts"]["observer"]["sha256"],
            "observer_result_sha256": digest(raw_bytes), "status": "review_required",
            "exit_code": 0}
        write_json(output / "run-result.json", result)

    def validate(self):
        run = self.focused_run
        def tree_command(command, **_kwargs):
            text_output = _kwargs.get("text", False)
            if command[1] == "rev-parse":
                value = (self.TOOLING_TREE if command[2] == "HEAD^{tree}" else TREE) + "\n"
            elif command[1] == "ls-tree":
                path = command[-1]
                data = self.original_harness_bytes[path]
                value = f"100644 blob {hashlib.sha1(data).hexdigest()}\t{path}\n"
            elif command[1] == "cat-file":
                by_oid = {hashlib.sha1(data).hexdigest(): data
                          for data in self.original_harness_bytes.values()}
                value = str(len(by_oid[command[-1]])) + "\n"
            elif command[1] == "show":
                path = command[-1].split(":", 1)[1]
                value = self.original_harness_bytes[path]
            else:
                raise AssertionError("Unexpected focused Git command: " + repr(command))
            return value if text_output or isinstance(value, bytes) else value.encode()
        with mock.patch.object(evidence, "FOCUSED_PRODUCT_SOURCE_SHA", SOURCE), \
             mock.patch.object(evidence, "FOCUSED_ORIGINAL_BUNDLE_SHA256", self.original_hash), \
             mock.patch.object(evidence, "FOCUSED_APPLICATION_SHA256", self.application_hash), \
             mock.patch.object(evidence, "trusted_tooling_inventory", return_value={k: v for k, v in self.tooling_record.items() if k != "schema_version"}), \
             mock.patch.object(evidence, "verify_focused_product_inventory", return_value=TREE), \
             mock.patch.object(evidence, "staged_tooling_files", return_value=[
                 "tooling-record.json", "tooling-bundle.json",
                 *(row["file"] for row in self.tooling_record["modules"])]), \
             mock.patch.object(evidence.subprocess, "check_output", side_effect=tree_command):
            return evidence.validate_focused_clear_run(self.root, run.name, SOURCE, SCRIPT_ROOT.parent)

    def test_focused_run_is_observed_without_full_batch_metrics(self):
        result = self.validate()
        self.assertEqual(result["bundle_mode"], "preserved-product-current-tooling")
        self.assertEqual(result["performance_batch"], "not-run")
        self.assertEqual(result["observation"]["first_clear_status"], "success")
        with self.assertRaisesRegex(evidence.EvidenceError, "Performance run id is invalid"):
            evidence.validate_performance_run(self.root, self.focused_run.name, SOURCE)

    def test_self_consistent_altered_harness_is_rejected_by_git_blob(self):
        run = self.focused_run
        script_path = run / "inputs" / "run-windows-vm-tests.ps1"
        script_path.write_bytes(script_path.read_bytes() + b"\nchanged after source commit\n")
        changed_hash = digest(script_path.read_bytes())
        active_path = run / "inputs" / "bundle.json"
        active = json.loads(active_path.read_text())
        active["harness"]["controller"]["sha256"] = changed_hash
        write_json(active_path, active)
        manifest_path = run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["artifacts"]["controller"]["sha256"] = changed_hash
        manifest["artifacts"]["controller"]["bytes"] = script_path.stat().st_size
        manifest["bundle_manifest"]["sha256"] = digest(active_path.read_bytes())
        manifest["bundle_manifest"]["bytes"] = active_path.stat().st_size
        manifest["prepared_bundle"]["bundle_manifest_sha256"] = manifest["bundle_manifest"]["sha256"]
        write_json(manifest_path, manifest)
        raw_path = run / "output" / "acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["harness"] = active["harness"]
        write_json(raw_path, raw)
        self.refresh_focused(run)
        with self.assertRaisesRegex(evidence.EvidenceError, "selected tooling Git blob"):
            self.validate()

    def test_missing_binding_first_clear_lifecycle_and_cleanup_are_rejected(self):
        cases = (
            ("prepared", lambda m, t, r: m["prepared_bundle"].__setitem__("application_sha256", "f" * 64),
             "preserved product provenance"),
            ("tooling-source", lambda m, t, r: m.__setitem__("tooling_source_sha", "f" * 40),
             "preserved product provenance"),
            ("origin", lambda m, t, r: m["prepared_bundle"].__setitem__(
                "origin", "external-prepared-source-built-bundle"),
             "preserved product provenance"),
            ("lane", lambda m, t, r: r.__setitem__("lane", "candidate-gui-only"),
             "Focused observer source"),
            ("original", lambda m, t, r: m["prepared_bundle"].__setitem__(
                "original_bundle_manifest_sha256", "f" * 64), "preserved product provenance"),
            ("plan", lambda m, t, r: m["request"]["focused_clear_plan"].__setitem__(
                "stop_after_first_clear", 1), "fixed plan"),
            ("preview", lambda m, t, r: r["assertions"]["scenario"]["full_preview_rows"].pop(),
             "preview/reset observations"),
            ("first-clear", lambda m, t, r: r["assertions"]["scenario"].pop("first_clear"),
             "focused first clear"),
            ("command", lambda m, t, r: r["assertions"]["scenario"]["command_sends"][0].__setitem__(
                "status", "timeout"), "successful bounded native send"),
            ("normal-exit", lambda m, t, r: r["process_lifecycles"][0]["process_lifecycle"].__setitem__(
                "exit_method", "forced-termination"), "exact process lifecycle"),
            ("jobs", lambda m, t, r: t["raw_cleanup"].__setitem__("process_jobs_closed", False),
             "closed process jobs"),
            ("guest", lambda m, t, r: t.__setitem__("guest_cleanup", False),
             "transport guest cleanup"),
            ("scope", lambda m, t, r: r["assertions"].__setitem__("scope",
                "performance-sample-p1-p3-v2"), "scope, or cleanup"),
        )
        for label, mutate, expected in cases:
            with self.subTest(label=label):
                self.reset_fixture()
                self.__dict__.pop("focused_run", None)
                run = self.focused_run
                manifest_path = run / "input-manifest.json"
                transport_path = run / "output" / "transport.json"
                raw_path = run / "output" / "acceptance-result.json"
                manifest = json.loads(manifest_path.read_text())
                transport = json.loads(transport_path.read_text())
                raw = json.loads(raw_path.read_text())
                mutate(manifest, transport, raw)
                write_json(manifest_path, manifest)
                write_json(transport_path, transport)
                write_json(raw_path, raw)
                self.refresh_focused(run)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    self.validate()


class FirstClearObservationEvidenceTests(FocusedClearEvidenceTests):
    def test_independent_current_product_inventory_rejects_claimed_hash_mutation(self):
        from darkrenamer_tooling.vm import gui as producer
        repo = SCRIPT_ROOT.parent
        source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo,
                                             text=True).strip()
        historical_query = ["git", "ls-tree", "-rz", "--full-tree",
                            evidence.FIRST_CLEAR_PRODUCT_REFERENCE_SHA]
        current_query = ["git", "ls-tree", "-rz", "--full-tree", source_sha]
        frozen_tree = first_clear_product_tree()
        real_check_output = subprocess.check_output
        def offline_tree(command, **kwargs):
            return frozen_tree if command in (historical_query, current_query) else \
                real_check_output(command, **kwargs)
        with mock.patch.object(subprocess, "check_output", side_effect=offline_tree):
            manifest = {"source_sha": source_sha,
                        "product_inputs": producer.first_clear_product_inputs(repo, source_sha)}
            evidence.verify_first_clear_product_inputs(repo, manifest)
            original_product_inputs = dict(manifest["product_inputs"])
            manifest["product_inputs"]["entries_sha256"] = "0" * 64
            with self.assertRaisesRegex(evidence.EvidenceError, "product/build inputs"):
                evidence.verify_first_clear_product_inputs(repo, manifest)
        manifest["product_inputs"] = original_product_inputs
        altered_tree = frozen_tree.replace(b"100644 blob", b"100755 blob", 1)
        self.assertNotEqual(altered_tree, frozen_tree)
        for changed_query in (current_query, historical_query):
            with self.subTest(changed_query=changed_query[-1]), \
                 mock.patch.object(subprocess, "check_output",
                                   side_effect=lambda command, **kwargs:
                                   altered_tree if command == changed_query else
                                   frozen_tree if command in (historical_query, current_query) else
                                   real_check_output(command, **kwargs)):
                with self.assertRaisesRegex(evidence.EvidenceError, "product/build inputs"):
                    evidence.verify_first_clear_product_inputs(repo, manifest)

    def make_failed_observation(self):
        run = self.focused_run
        renamed = run.with_name(evidence.FIRST_CLEAR_RUN_ID)
        run.rename(renamed)
        output = renamed / "output"
        (output / "run-result.json").unlink()
        (output / "platform-postlaunch.json").unlink()
        manifest_path = renamed / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["run_id"] = evidence.FIRST_CLEAR_RUN_ID
        manifest["request"] = {"mode": evidence.FIRST_CLEAR_MODE, "appearance": "light",
            "desktop": {"width": 1366, "height": 768, "dpi": 96},
            "text_scale_percent": 100,
            "first_clear_observation_plan": deepcopy(evidence.FIRST_CLEAR_PLAN)}
        manifest["acceptance_profile_id"] = evidence.V1_PROFILE_ID
        manifest["acceptance_profile_sha256"] = digest(
            (SCRIPT_ROOT.parent / "config/vm-automated-v1.json").read_bytes())
        vm_id = "18338a47-f647-45c4-98b8-6107331e2602"
        manifest["guest_preflight"]["vm_identity_kind"] = "hyper-v-guest-parameters-virtual-machine-id-v1"
        manifest["guest_preflight"]["vm_identity_sha256"] = digest(vm_id.encode("ascii"))
        write_json(manifest_path, manifest)
        preflight_path = output / "platform-preflight.json"
        preflight = json.loads(preflight_path.read_text())
        preflight.update(run_id=renamed.name,
                         input_manifest_sha256=digest(manifest_path.read_bytes()),
                         phase="pre-launch", source_sha=SOURCE,
                         application_sha256=manifest["artifacts"]["application"]["sha256"],
                         runner_sha256=manifest["artifacts"]["runner"]["sha256"],
                         observer_sha256=manifest["artifacts"]["observer"]["sha256"],
                         guest_platform=manifest["guest_preflight"])
        write_json(preflight_path, preflight)
        observations_path = output / "acceptance-observations.json"
        observations = json.loads(observations_path.read_text())
        observations["environment"] = None
        text_snapshot = {"registry_key_existed": True, "registry_value_existed": True,
                         "registry_value_kind": "DWord", "registry_value": 100,
                         "ui_settings_raw_factor": 1.0, "ui_settings_percent": 100}
        observations["text_scale_restoration"] = {
            "schema_version": 1, "baseline": deepcopy(text_snapshot),
            "final": deepcopy(text_snapshot), "snapshot_equal": True}
        scenario = observations["scenario"]
        scenario["mode"] = evidence.FIRST_CLEAR_MODE
        scenario["plan"] = deepcopy(evidence.FIRST_CLEAR_PLAN)
        scenario["environment"]["physical_screen"] = {"left": 0, "top": 0,
            "right": 1366, "bottom": 768, "width": 1366, "height": 768}
        scenario["startup"] = {"empty_grid": True, "main_hwnd_bound": True,
            "import_command_enabled": True}
        scenario["ordinary_representatives"] = [
            {"index": index, "name": f"ordinary-{index:05d}.txt"}
            for index in (0, 4999, 9999)]
        scenario["full_preview_rows"] = [
            {"index": index, "source": f"ordinary-{index:05d}.txt",
             "prefixed": f"sample-ordinary-{index:05d}.txt",
             "reset": f"ordinary-{index:05d}.txt"}
            for index in (0, 2499, 4999, 7499, 9999)]
        scenario["partial_samples"] = [row for row in scenario.pop("samples")
                                       if row["phase"] != "post"]
        for field in ("phase_summary", "wakeups", "disk_unchanged",
                      "journal_residue_count", "normal_exit_code"):
            scenario.pop(field, None)
        scenario["process_start_utc_ticks"] = 639277610271308143
        scenario["first_clear"] = {"schema_version": 1, "stage": "send-failed",
            "command_id": 32782, "process_id": 4242, "main_handle": 1001,
            "pre_clear_rows": 10000, "post_clear_rows": None,
            "preview_reset": [f"ordinary-{index:05d}.txt"
                              for index in (0, 2499, 4999, 7499, 9999)],
            "native_identity": {"process_id": 4242, "creation_filetime": 134366378271308143,
                "main_handle": 1001, "list_handle": 1002, "main_thread_id": 20,
                "list_thread_id": 20, "main_class": "DarkReNamerWindow", "list_class": "SysListView32",
                "list_parent": 1001, "list_control_id": 1000},
            "polls": [{"index": index, "elapsed_ms": index * 200 + 100, "status": "identity-bound",
                "creation_filetime": 134366378271308143, "count_status": "failed",
                "count_error": 1460, "count_elapsed_ms": 49.0,
                "row_count": None, "response_status": "failed",
                "response_error": 1460, "response_elapsed_ms": 49.0}
                for index in range(50)], "poll_status": "poll-limit",
            "poll_elapsed_ms": 9900}
        scenario["command_sends"] = [{"command_id": 32782,
            "scenario_phase": "full-preview-clear", "native_return": 0,
            "message_result": None, "error_code": 1460, "elapsed_ms": 5006.0,
            "status": "timeout"}]
        write_json(observations_path, observations)
        raw_path = output / "acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["source_sha"] = SOURCE
        raw["status"] = "failed"
        raw["failure_reason"] = "gui_regression_observer_failed"
        raw["process_lifecycles"] = [{"process_lifecycle": {
            "pid": 4242, "start_time_utc_ticks": "639277610271308143",
            "executable_sha256": manifest["artifacts"]["application"]["sha256"],
            "start_observed": True, "exit_observed": False}}]
        raw["process_job_cleanup"] = [{"pid": 4242,
            "process_start_time_utc_ticks": "639277610271308143",
            "job_empty": True, "job_closed": True, "capture_complete": True,
            "active_processes_at_close": 0, "forced_termination": True,
            "primary_process_active_at_stop": True, "termination_exit_code": 1,
            "status": "clean"}]
        raw["assertions"] = {"scope": evidence.FIRST_CLEAR_SCOPE, "scenario": scenario}
        raw["observations"] = {"file": "acceptance-observations.json",
                               "sha256": digest(observations_path.read_bytes())}
        raw["acceptance_observations"] = observations
        write_json(raw_path, raw)
        transport_path = output / "transport.json"
        transport = json.loads(transport_path.read_text())
        transport["observer_process"] = {"state": "exited", "exit_code": 1}
        transport["guest_cleanup"] = True
        transport["status"] = "collected"
        transport["host_platform"] = "Unix"
        transport["vm_id"] = vm_id
        transport["vm_identity_kind"] = manifest["guest_preflight"]["vm_identity_kind"]
        transport["vm_identity_sha256"] = manifest["guest_preflight"]["vm_identity_sha256"]
        write_json(transport_path, transport)
        cleanup_path = output / "cleanup.json"
        cleanup = json.loads(cleanup_path.read_text())
        cleanup.update(run_id=renamed.name, input_manifest_sha256=digest(manifest_path.read_bytes()),
                       controller_exit_code=1, status="passed", fixture=True, process=True,
                       guest=True, desktop_restore=True, text_scale_restore=True)
        write_json(cleanup_path, cleanup)
        self.refresh_first_clear_collection(renamed)
        return renamed, manifest

    @staticmethod
    def refresh_first_clear_collection(run):
        output = run / "output"
        rows = [{"relative_path": path.name, "bytes": path.stat().st_size,
                 "sha256": digest(path.read_bytes())}
                for path in sorted(output.iterdir()) if path.is_file()]
        write_json(run / "collection.json", {"schema_version": 1, "run_id": run.name,
            "input_manifest_sha256": digest((run / "input-manifest.json").read_bytes()),
            "files": rows})

    def validate_first_clear(self, run, manifest):
        with mock.patch.object(evidence, "validate_input_manifest",
                               return_value=(manifest, (run / "input-manifest.json").read_bytes())), \
             mock.patch.object(evidence, "verify_first_clear_product_inputs"):
            return evidence.validate_first_clear_run(self.root, run.name, SOURCE, SCRIPT_ROOT.parent)

    def test_failed_command_remains_failed_and_complete_cleanup_is_separate(self):
        run, manifest = self.make_failed_observation()
        result = self.validate_first_clear(run, manifest)
        self.assertEqual(result["status"], "failure-observed")
        self.assertEqual(result["command_status"], "timeout")
        self.assertEqual(result["performance_acceptance"], "not-run")
        self.assertIsNone(result["final_row_count"])
        observation_path = run / "output/acceptance-observations.json"
        raw_path = run / "output/acceptance-result.json"
        original_observations = observation_path.read_bytes()
        original_raw = raw_path.read_bytes()
        observations = json.loads(original_observations)
        observations["scenario"]["first_clear"]["polls"].pop()
        observations["scenario"]["first_clear"]["poll_status"] = "budget-exhausted"
        write_json(observation_path, observations)
        raw = json.loads(original_raw)
        raw["assertions"]["scenario"] = observations["scenario"]
        raw["acceptance_observations"] = observations
        raw["observations"]["sha256"] = digest(observation_path.read_bytes())
        write_json(raw_path, raw)
        self.refresh_first_clear_collection(run)
        self.assertEqual(self.validate_first_clear(run, manifest)["status"], "incomplete")
        observation_path.write_bytes(original_observations)
        raw_path.write_bytes(original_raw)
        self.refresh_first_clear_collection(run)
        observations = json.loads(original_observations)
        observations["scenario"]["first_clear"]["poll_elapsed_ms"] = 10001
        write_json(observation_path, observations)
        raw = json.loads(original_raw)
        raw["assertions"]["scenario"] = observations["scenario"]
        raw["acceptance_observations"] = observations
        raw["observations"]["sha256"] = digest(observation_path.read_bytes())
        write_json(raw_path, raw)
        self.refresh_first_clear_collection(run)
        self.assertEqual(self.validate_first_clear(run, manifest)["status"], "incomplete")
        observation_path.write_bytes(original_observations)
        raw_path.write_bytes(original_raw)
        self.refresh_first_clear_collection(run)
        cleanup = json.loads((run / "output/cleanup.json").read_text())
        cleanup["guest"] = False
        cleanup["status"] = "failed"
        write_json(run / "output/cleanup.json", cleanup)
        self.refresh_first_clear_collection(run)
        self.assertEqual(self.validate_first_clear(run, manifest)["status"], "incomplete")

    def test_first_clear_text_scale_proof_is_required_and_recomputed(self):
        run, manifest = self.make_failed_observation()
        observations_path = run / "output/acceptance-observations.json"
        raw_path = run / "output/acceptance-result.json"
        original = json.loads(observations_path.read_text())
        self.assertEqual(self.validate_first_clear(run, manifest)["status"], "failure-observed")
        for mutation in ("missing", "final-missing", "registry-kind", "registry-value",
                         "ui-factor", "ui-percent", "inconsistent-pair", "malformed-factor",
                         "claimed-unequal", "malformed"):
            observations = deepcopy(original)
            proof = observations["text_scale_restoration"]
            if mutation == "missing":
                observations.pop("text_scale_restoration")
            elif mutation == "final-missing":
                proof["final"] = None
            elif mutation == "registry-kind":
                proof["final"]["registry_value_kind"] = "QWord"
            elif mutation == "registry-value":
                proof["final"]["registry_value"] = 101
            elif mutation == "ui-factor":
                proof["final"]["ui_settings_raw_factor"] = 1.001
            elif mutation == "ui-percent":
                proof["final"]["ui_settings_percent"] = 101
            elif mutation == "inconsistent-pair":
                for key in ("baseline", "final"):
                    proof[key]["ui_settings_raw_factor"] = 1.5
            elif mutation == "malformed-factor":
                proof["final"]["ui_settings_raw_factor"] = "1.0"
            elif mutation == "claimed-unequal":
                proof["snapshot_equal"] = False
            else:
                proof["final"]["registry_value"] = "100"
            write_json(observations_path, observations)
            raw = json.loads(raw_path.read_text())
            raw["acceptance_observations"] = observations
            raw["observations"]["sha256"] = digest(observations_path.read_bytes())
            write_json(raw_path, raw)
            self.refresh_first_clear_collection(run)
            with self.subTest(mutation=mutation):
                self.assertEqual(self.validate_first_clear(run, manifest)["status"], "incomplete")

    def test_extra_command_and_lifetime_or_hash_mutations_refuse(self):
        run, manifest = self.make_failed_observation()
        raw_path = run / "output/acceptance-result.json"
        observation_path = run / "output/acceptance-observations.json"
        for mutate in ("second-command", "window-lifetime", "poll-invalid",
                       "reclassified-command", "raw-hash"):
            original_raw = raw_path.read_bytes()
            original_observations = observation_path.read_bytes()
            raw = json.loads(original_raw)
            observations = json.loads(original_observations)
            if mutate == "second-command":
                observations["scenario"]["command_sends"].append(
                    deepcopy(observations["scenario"]["command_sends"][0]))
            elif mutate == "window-lifetime":
                observations["scenario"]["first_clear"]["polls"][0]["creation_filetime"] += 1
            elif mutate == "poll-invalid":
                observations["scenario"]["first_clear"]["poll_elapsed_ms"] = 600001
            elif mutate == "reclassified-command":
                observations["scenario"]["command_sends"][0]["status"] = "success"
            else:
                raw["source_sha"] = "f" * 40
            write_json(observation_path, observations)
            raw["assertions"]["scenario"] = observations["scenario"]
            raw["acceptance_observations"] = observations
            raw["observations"]["sha256"] = digest(observation_path.read_bytes())
            write_json(raw_path, raw)
            self.refresh_first_clear_collection(run)
            with self.subTest(mutate=mutate), self.assertRaises(evidence.EvidenceError):
                self.validate_first_clear(run, manifest)
            raw_path.write_bytes(original_raw)
            observation_path.write_bytes(original_observations)
            self.refresh_first_clear_collection(run)


class IconSettlementEvidenceTests(SyntheticFixtureTestCase):
    @staticmethod
    def status(generation, *, settled=True, bootstrap=1, pending=0, demand_remaining=0,
               unavailable_or_retiring=False, worker_joined=False):
        return {"version": 1, "session": "41", "generation": str(generation),
                "bootstrap": bootstrap, "queued": pending, "inflight": 0,
                "undrained": 0, "unresolved_rows": 0, "cursor": 1000,
                "settled": settled, "worker_joined": worker_joined, "reconcile_rows": 0,
                "batch_ack": 0, "status_revision": "8", "demand_exhausted": demand_remaining == 0,
                "demand_remaining": demand_remaining, "model_revision": str(generation),
                "unavailable_or_retiring": unavailable_or_retiring}

    def scenario(self):
        phases = []
        for index, names in enumerate((
                ["ordinary-0000.txt", "ordinary-0499.txt", "ordinary-0999.txt"],
                ["extension-0000.e000", "recurring-0401.txt", "recurring-0999.txt"])):
            generation = index + 2
            phases.append({"id": ("ordinary-cached", "interleaved-churn")[index],
                           "rows": 1000, "data_ready_ms": 25.0,
                           "icon_settled_observed_ms": 125.0,
                           "first_status": self.status(generation, settled=False, pending=2),
                           "settled_status": self.status(generation),
                           "confirmation_status": self.status(generation),
                           "poll_count": 3, "unstable_query_attempts": 0,
                           "sampled_peak_pending": 2,
                           "sampled_peak_unresolved_rows": 0,
                           "representative_names": names})
        return {"mode": evidence.ICON_SETTLEMENT_MODE,
                "endpoint_method": evidence.ICON_SETTLEMENT_METHOD,
                "plan": deepcopy(evidence.ICON_SETTLEMENT_PLAN),
                "environment": {}, "process_id": 3001,
                "process_start_utc_ticks": "134041000000000000",
                "executable_sha256": "a" * 64, "phases": phases,
                "disk_unchanged": True, "journal_residue_count": 0,
                "worker_join_evidence": {"kind": "source-contract-inference", "observed": False},
                "normal_exit_code": 0, "appearance": "light"}

    def baseline_scenario(self):
        scenario = self.scenario()
        scenario["endpoint_method"] = evidence.ICON_BASELINE_METHOD
        scenario["endpoint_coverage"] = "source-derived-synchronous-lookup-completion-upper-bound"
        scenario["baseline_product_source_sha"] = evidence.ICON_BASELINE_PRODUCT_SOURCE_SHA
        del scenario["worker_join_evidence"]
        for phase in scenario["phases"]:
            ready = phase["data_ready_ms"]
            for name in ("icon_settled_observed_ms", "first_status", "settled_status",
                         "confirmation_status", "poll_count", "unstable_query_attempts",
                         "sampled_peak_pending", "sampled_peak_unresolved_rows"):
                del phase[name]
            phase["synchronous_lookup_completion_upper_bound_ms"] = ready
        return scenario

    def test_synchronous_baseline_is_only_a_row_count_upper_bound(self):
        metrics = evidence.validate_icon_baseline_metrics(self.baseline_scenario())
        self.assertEqual(metrics["actual_icon_visibility_endpoint"], "not-measured")
        self.assertEqual(metrics["worker_or_queue_endpoint"], "not-measured")
        for change in (
                lambda s: s["phases"][0].__setitem__(
                    "synchronous_lookup_completion_upper_bound_ms", 24.0),
                lambda s: s["phases"][0].__setitem__("settled_status", self.status(2)),
                lambda s: s.__setitem__("worker_join_evidence", {}),
                lambda s: s.__setitem__("baseline_product_source_sha", "c" * 40),
                lambda s: s.__setitem__("endpoint_method", evidence.ICON_SETTLEMENT_METHOD)):
            damaged = self.baseline_scenario()
            change(damaged)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_icon_baseline_metrics(damaged)

    def test_async_endpoint_requires_full_stable_generation_and_distinct_method(self):
        scenario = self.scenario()
        metrics = evidence.validate_icon_settlement_metrics(scenario)
        self.assertEqual(metrics["baseline_icon_endpoint"], "not-measured")
        for change in (
                lambda s: s.__setitem__("endpoint_method", "synchronous-row-count-upper-bound"),
                lambda s: s["phases"][0]["settled_status"].__setitem__("bootstrap", 2),
                lambda s: s["phases"][0]["confirmation_status"].__setitem__("demand_remaining", 1),
                lambda s: s["phases"][1]["settled_status"].__setitem__("generation", "2"),
                lambda s: s["phases"][0]["first_status"].__setitem__("queued", 65),
                lambda s: s["phases"][0]["first_status"].__setitem__("status_revision", "7"),
                lambda s: s["phases"][0]["settled_status"].update(
                    unavailable_or_retiring=True, worker_joined=False),
                lambda s: s["phases"][0]["settled_status"].update(
                    unavailable_or_retiring=True, worker_joined=True),
                lambda s: s["phases"][0]["settled_status"].update(worker_joined=True),
                lambda s: s["phases"][0]["confirmation_status"].update(
                    unavailable_or_retiring=True, worker_joined=True),
                lambda s: s["worker_join_evidence"].update(kind="observed", observed=True)):
            damaged = self.scenario()
            change(damaged)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_icon_settlement_metrics(damaged)

    def test_prepared_manifest_and_v2_owned_single_process_are_bound(self):
        run = self.fixture.build(evidence.ICON_SETTLEMENT_RUN_ID, "standard")
        manifest_path = run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        profile = (SCRIPT_ROOT.parent / "config" / "vm-automated-v2.json").read_bytes()
        profile_hash = digest(profile)
        (run / "inputs" / "vm-automated-v2.json").write_bytes(profile)
        manifest["acceptance_profile_id"] = evidence.V2_PROFILE_ID
        manifest["acceptance_profile_sha256"] = profile_hash
        manifest["acceptance_profile"] = {"file": "inputs/vm-automated-v2.json",
                                          "bytes": len(profile), "sha256": profile_hash}
        manifest["request"] = {"mode": evidence.ICON_SETTLEMENT_MODE,
            "appearance": "light", "desktop": {"width": 1366, "height": 768, "dpi": 96},
            "text_scale_percent": 100, "endpoint_method": evidence.ICON_SETTLEMENT_METHOD,
            "settlement_plan": deepcopy(evidence.ICON_SETTLEMENT_PLAN)}
        app_hash = manifest["artifacts"]["application"]["sha256"]
        manifest["prepared_bundle"] = {"origin": "external-prepared-source-built-bundle",
            "bundle_manifest_sha256": manifest["bundle_manifest"]["sha256"],
            "application_sha256": app_hash}
        manifest["command"] = ["python3", "-I", "scripts/run-gui-regression.py",
            "--output-root", "<external-output-root>", "--connection-profile",
            "<private-connection-profile>", "--diagnostic", evidence.ICON_SETTLEMENT_MODE,
            "--prepared-bundle-root", "<external-prepared-bundle-root>",
            "--expected-prepared-application-sha256", app_hash,
            "--acceptance-profile-id", evidence.V2_PROFILE_ID]
        write_json(manifest_path, manifest)
        evidence.validate_input_manifest(run, SOURCE)
        bad = deepcopy(manifest)
        bad["prepared_bundle"]["application_sha256"] = "f" * 64
        write_json(manifest_path, bad)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_input_manifest(run, SOURCE)

        cleanup = clean_controller_cleanup_v3(
            profile_sha256=profile_hash, source_sha=manifest["source_sha"],
            bundle_sha256=manifest["bundle_manifest"]["sha256"])
        owned = cleanup["owned_resource_evidence"]
        raw = {"process_job_cleanup": owned["process_job_cleanup"],
               "observer_lifecycle": owned["task_execution"]["observer_lifecycle"]}
        scenario = self.scenario()
        transport = {"raw_cleanup": cleanup,
                     "vm_id": cleanup["owned_resource_evidence"]["protected_anchor"]["vm_id"]}
        GuiEvidenceTests.bind_v2_fixture_vm(run, manifest, transport)
        evidence.validate_icon_owned_transport(transport, manifest, raw, scenario)
        for mutate in (
                lambda r, s: s.__setitem__("process_start_utc_ticks", "134041000000000001"),
                lambda r, s: r.__setitem__("process_job_cleanup", []),
                lambda r, s: r.__setitem__("observer_lifecycle", {})):
            copied_raw, copied_scenario = deepcopy(raw), deepcopy(scenario)
            mutate(copied_raw, copied_scenario)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_icon_owned_transport(transport, manifest,
                                                       copied_raw, copied_scenario)

    def test_synchronous_baseline_manifest_requires_explicit_method_and_original_ref(self):
        run = self.fixture.build(evidence.ICON_BASELINE_RUN_ID, "standard")
        manifest_path = run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        profile = (SCRIPT_ROOT.parent / "config" / "vm-automated-v2.json").read_bytes()
        profile_hash = digest(profile)
        (run / "inputs" / "vm-automated-v2.json").write_bytes(profile)
        manifest["acceptance_profile_id"] = evidence.V2_PROFILE_ID
        manifest["acceptance_profile_sha256"] = profile_hash
        manifest["acceptance_profile"] = {"file": "inputs/vm-automated-v2.json",
                                          "bytes": len(profile), "sha256": profile_hash}
        manifest["request"] = {"mode": evidence.ICON_SETTLEMENT_MODE,
            "appearance": "light", "desktop": {"width": 1366, "height": 768, "dpi": 96},
            "text_scale_percent": 100, "endpoint_method": evidence.ICON_BASELINE_METHOD,
            "baseline_product_source_sha": evidence.ICON_BASELINE_PRODUCT_SOURCE_SHA,
            "settlement_plan": deepcopy(evidence.ICON_SETTLEMENT_PLAN)}
        app_hash = manifest["artifacts"]["application"]["sha256"]
        manifest["prepared_bundle"] = {"origin": "external-prepared-source-built-bundle",
            "bundle_manifest_sha256": manifest["bundle_manifest"]["sha256"],
            "application_sha256": app_hash}
        manifest["command"] = ["python3", "-I", "scripts/run-gui-regression.py",
            "--output-root", "<external-output-root>", "--connection-profile",
            "<private-connection-profile>", "--diagnostic", evidence.ICON_SETTLEMENT_MODE,
            "--prepared-bundle-root", "<external-prepared-bundle-root>",
            "--expected-prepared-application-sha256", app_hash,
            "--acceptance-profile-id", evidence.V2_PROFILE_ID,
            "--icon-endpoint-method", evidence.ICON_BASELINE_METHOD,
            "--baseline-product-source-sha", evidence.ICON_BASELINE_PRODUCT_SOURCE_SHA,
            "--expected-run-source-sha", SOURCE]
        write_json(manifest_path, manifest)
        evidence.validate_input_manifest(run, SOURCE)
        for mutation in (
                lambda m: m["request"].pop("baseline_product_source_sha"),
                lambda m: m["request"].__setitem__("baseline_product_source_sha", "c" * 40),
                lambda m: m["command"].__delitem__(slice(-6, None)),
                lambda m: m["command"].__setitem__(-1, "c" * 40)):
            damaged = deepcopy(manifest)
            mutation(damaged)
            write_json(manifest_path, damaged)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_input_manifest(run, SOURCE)


class RuntimeBaselineEvidenceTests(SyntheticFixtureTestCase):
    owned_run = PerformanceSampleEvidenceTests.owned_run
    sample_scenario = PerformanceSampleEvidenceTests.sample_scenario
    refresh_owned = PerformanceSampleEvidenceTests.refresh_owned

    @staticmethod
    def saved_default_appearance():
        # Product DRAPPR v1: UiAppearance::DEFAULT + little-endian FNV-1a checksum.
        raw = bytes.fromhex('4452415050520000010800000000010101010000e950f7f9')
        return {'status': 'valid-saved', 'bytes': 24, 'bytes_hex': raw.hex(),
            'sha256': 'b4371b6a8cb9748700ca1b99c7bd6afdac28f08a53365031a70fc690b0b6d5b8',
            'value': {'theme': 0, 'density': 0, 'emphasis': 1, 'show_separators': True,
                      'show_preview_tint': True, 'show_empty_safety': True}}

    @staticmethod
    def rechecksum_appearance(raw):
        result = bytearray(raw)
        checksum = 2166136261
        for byte in result[:20]:
            checksum = ((checksum ^ byte) * 16777619) & 0xffffffff
        result[20:] = checksum.to_bytes(4, 'little')
        return bytes(result)

    def refresh_runtime(self, run):
        self.refresh_owned(run)
        path = run / 'output/run-result.json'
        result = json.loads(path.read_text())
        result['diagnostic'] = evidence.RUNTIME_BASELINE_MODE
        write_json(path, result)

    def runtime_run(self):
        run, profile_sha = self.owned_run()
        run = run.rename(self.root / evidence.RUNTIME_BASELINE_RUN_ID)
        output = run / 'output'
        manifest_path = run / 'input-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['run_id'] = run.name
        manifest['request'] = {'mode': evidence.RUNTIME_BASELINE_MODE, 'appearance': 'light',
            'desktop': {'width': 1366, 'height': 768, 'dpi': 96}, 'text_scale_percent': 100,
            'runtime_baseline_plan': deepcopy(evidence.RUNTIME_BASELINE_PLAN)}
        app_hash = manifest['artifacts']['application']['sha256']
        manifest['prepared_bundle'] = {'origin': 'external-prepared-source-built-bundle',
            'bundle_manifest_sha256': manifest['bundle_manifest']['sha256'],
            'application_sha256': app_hash}
        manifest['command'] = ['python3', '-I', 'scripts/run-gui-regression.py',
            '--output-root', '<external-output-root>', '--connection-profile',
            '<private-connection-profile>', '--diagnostic', evidence.RUNTIME_BASELINE_MODE,
            '--prepared-bundle-root', '<external-prepared-bundle-root>',
            '--expected-prepared-application-sha256', app_hash,
            '--acceptance-profile-id', evidence.V2_PROFILE_ID]
        write_json(manifest_path, manifest)
        for leaf in ('cleanup.json', 'platform-preflight.json', 'platform-postlaunch.json',
                     'acceptance-observations.json'):
            path = output / leaf
            document = json.loads(path.read_text())
            document['run_id'] = run.name
            write_json(path, document)
        (output / 'performance-empty.png').rename(output / 'runtime-baseline-populated.png')
        raw_path = output / 'acceptance-result.json'
        raw = json.loads(raw_path.read_text())
        environment = raw['assertions']['scenario']['environment']
        environment['physical_screen'].update(width=1366, height=768, right=1366, bottom=768)
        environment['region'] = {'culture': 'ko-KR', 'ui_culture': 'ko-KR',
                                 'timezone': 'Korea Standard Time'}
        cells, jobs, lives = [], [], []
        for index, name in enumerate(evidence.RUNTIME_BASELINE_PLAN['startup_cells']):
            ticks = 638965440000000000 + index * 1000000000
            pid = (8224, 956, 17280)[index]
            value = 0 if index < 2 else 2
            preference = {'status': 'valid-saved', 'value': value,
                          'sha256': evidence.runtime_language_preference_hash(value)}
            cell_environment = deepcopy(environment)
            cell_environment['main_window']['process_id'] = pid
            resolution = {'query': 'UISettings.GetColorValue(UIColorType.Foreground)+SPI_GETHIGHCONTRAST',
                'foreground_argb': [255, 0, 0, 0], 'resolved_theme': 'light',
                'system_visual_style': {'theme_path_sha256': 'a' * 64,
                    'theme_color': 'NormalColor', 'theme_size': 'NormalSize', 'forced_colors': False}}
            appearance_menu = {'hwnd': cell_environment['main_window']['hwnd'],
                'pid': pid, 'session_id': 2, 'menu_checked': [
                    {'command_id': 0x9010, 'checked': True},
                    {'command_id': 0x9011, 'checked': False},
                    {'command_id': 0x9012, 'checked': False}]}
            cell_environment['appearance'] = {'preference_before': 'absent',
                'preference_after': self.saved_default_appearance(),
                'pre_launch_resolution': deepcopy(resolution), 'ready_resolution': deepcopy(resolution),
                'pre_close_resolution': deepcopy(resolution), 'ready_menu': deepcopy(appearance_menu),
                'pre_close_menu': deepcopy(appearance_menu)}
            cell = {'id': name, 'preference_kind': 'absent' if index == 0 else 'valid-saved',
                'preference_value': value, 'resolved_language': 'ko' if index < 2 else 'en',
                'process_id': pid, 'process_start_utc_ticks': ticks,
                'startup': {'clock': {
                    'qpc_frequency': 10000000,
                    'launch_request_ticks': 1000000000 + index * 1000000000,
                    'process_create_begin_ticks': 1000100000 + index * 1000000000,
                    'process_create_end_ticks': 1000200000 + index * 1000000000,
                    'main_window_bound_ticks': 1001000000 + index * 1000000000,
                    'command_ready_ticks': 1002000000 + index * 1000000000},
                    'launch_request_to_main_bound_ms': 100.0,
                    'process_start_to_main_bound_lower_ms': 80.0,
                    'process_start_to_main_bound_upper_ms': 90.0,
                    'main_bound_to_ready_ms': 100.0,
                    'launch_request_to_ready_ms': 200.0,
                    'process_start_to_ready_lower_ms': 180.0,
                    'process_start_to_ready_upper_ms': 190.0,
                    'main_hwnd_bound': True, 'empty_grid': True, 'import_command_enabled': True},
                'preference_before': {'status': 'absent', 'value': None, 'sha256': None}
                                     if index == 0 else deepcopy(preference),
                'preference_after': {'status': 'absent', 'value': None, 'sha256': None}
                                    if index == 0 else deepcopy(preference),
                'menu': {'parent': '언어(&L) · 다음 실행부터' if index < 2 else '&Language · next startup',
                         'options': ['시스템 언어' if index < 2 else 'System language',
                                     '한국어', 'English', '日本語'], 'checked_command': 0x9020 + value},
                'empty_idle': None, 'import': None, 'icon_settlement': None,
                'populated_idle': None, 'transforms': None, 'samples': None, 'phase_summary': None,
                'normal_exit_code': 0, 'disk_unchanged': True, 'journal_residue_count': 0,
                'environment': cell_environment}
            cells.append(cell)
            job = deepcopy(raw['process_job_cleanup'][0])
            job.update(pid=pid, process_start_time_utc_ticks=str(ticks))
            jobs.append(job)
            life = deepcopy(raw['process_lifecycles'][0])
            life['process_lifecycle'].update(pid=pid, start_time_utc_ticks=str(ticks),
                creation_filetime=ticks - 504911232000000000)
            lives.append(life)
        rows = []
        for phase in evidence.RUNTIME_PHASES:
            for _ in range(150 if phase in {'empty-idle', 'populated-idle'} else 2):
                elapsed = len(rows) * 200
                probe_begin = (cells[0]['startup']['clock']['command_ready_ticks'] +
                               1000000 + elapsed * 10000)
                rows.append({'phase': phase, 'elapsed_ms': elapsed, 'cpu_ms': elapsed // 4,
                    'private_bytes': 10000000, 'working_set_bytes': 20000000,
                    'threads': 4, 'handles': 100, 'gdi_objects': 20, 'ui_response_ms': 2.0,
                    'probe_status': 'success', 'probe_error_code': 0,
                    'resource_collection_ms': 3.0, 'sample_gap_ms': 0 if not rows else 200.0,
                    'probe_begin_ticks': probe_begin, 'probe_end_ticks': probe_begin + 20000,
                    'process_id': cells[0]['process_id'],
                    'process_start_utc_ticks': cells[0]['process_start_utc_ticks'],
                    'main_window_handle': cells[0]['environment']['main_window']['hwnd'],
                    'main_thread_id': 42})
        terminal = IconSettlementEvidenceTests.status(2)
        receipt = {'data_ready_ms': 25.0, 'icon_settled_observed_ms': 125.0,
            'first_status': IconSettlementEvidenceTests.status(2, settled=False, pending=2),
            'settled_status': deepcopy(terminal), 'confirmation_status': deepcopy(terminal),
            'poll_count': 3, 'unstable_query_attempts': 0, 'sampled_peak_pending': 2,
            'sampled_peak_unresolved_rows': 0}
        cells[0].update(empty_idle={'elapsed_ms': 30000.0, 'rows': 0},
            populated_idle={'elapsed_ms': 30100.0, 'rows': 1000, 'end_status': terminal},
            icon_settlement=receipt, samples=rows)
        cells[0]['import'] = {'rows': 1000, 'observed_rows': 1000, 'data_ready_ms': 25.0,
                              'command_ready_after_rows_ms': 2.0}
        cells[0]['phase_summary'] = [{'phase': phase,
            'sample_count': sum(row['phase'] == phase for row in rows),
            'max_sample_gap_ms': 200.0, 'max_resource_collection_ms': 3.0}
            for phase in evidence.RUNTIME_PHASES]
        cells[0]['transforms'] = [{'id': name, 'source': 'ordinary-0000.txt',
            'proposal': target, 'reset': 'ordinary-0000.txt', 'edit_elapsed_ms': 100.0,
            'reset_elapsed_ms': 50.0 if name != 'no-op' else 0, 'reset_required': name != 'no-op'}
            for name, target in [('grow', 'expanded-ordinary-0000.txt'), ('shrink', 'x.txt'),
                                 ('no-op', 'ordinary-0000.txt')]]
        scenario = {'mode': evidence.RUNTIME_BASELINE_MODE,
            'plan': deepcopy(evidence.RUNTIME_BASELINE_PLAN),
            'system_resolution': {'language': 'ko', 'selected_tag': 'ko-KR',
                                  'preferred_tags': ['ko-KR', 'en-US']},
            'executable_sha256': app_hash, 'cells': cells, 'environment': deepcopy(cells[0]['environment']),
            'disk_unchanged': True, 'journal_residue_count': 0,
            'wakeups': {'status': 'not_run', 'reason': 'no-supported-process-wakeup-counter'},
            'appearance': 'light'}
        raw['assertions'] = {'overall': 'passed', 'scope': 'runtime-baseline-production-v2',
                             'scenario': scenario}
        raw.update(process_lifecycles=lives, process_job_cleanup=jobs,
            keyboard={'status': 'not_run'}, accessibility={'status': 'not_run'},
            screenshots=[{'file': 'runtime-baseline-populated.png',
                'sha256': digest((output / 'runtime-baseline-populated.png').read_bytes())}])
        transport_path = output / 'transport.json'
        transport = json.loads(transport_path.read_text())
        transport['raw_cleanup'] = clean_controller_cleanup_v3(profile_sha256=profile_sha,
            process_jobs=jobs, source_sha=SOURCE,
            bundle_sha256=manifest['bundle_manifest']['sha256'])
        transport['runtime_early_desktop_nonce'] = 'd' * 32
        owned = transport['raw_cleanup']['owned_resource_evidence']
        trusted_root = owned['root_records']['trusted']['path']
        trusted_bundle = trusted_root + r'\bundle'
        trusted_application = trusted_bundle + r'\DarkReNamer.exe'
        for life in lives:
            life['process_lifecycle']['executable_path'] = trusted_application
        task = owned['task_execution']
        task['action_arguments'] = task['action_arguments'].replace(
            ' -ElevatedObserver', f' -BundleRoot "{trusted_bundle}" -ElevatedObserver')
        task['observer_lifecycle']['command_line'] = (
            '"' + task['action_executable'] + '" ' + task['action_arguments'])
        raw['observer_lifecycle'] = deepcopy(task['observer_lifecycle'])
        write_json(raw_path, raw)
        write_json(output / 'runtime-baseline-early-host.json', {
            'schema_version': 1, 'kind': 'runtime_baseline_early_host_identity',
            'run_id': run.name, 'run_name': owned['run_name'],
            'host_output_root': str(output),
            'input_manifest_sha256': digest(manifest_path.read_bytes()),
            'source_sha': SOURCE, 'tooling_source_sha': SOURCE,
            'bundle_manifest_sha256': manifest['bundle_manifest']['sha256'],
            'application_sha256': app_hash,
            'vm_id': transport['vm_id'], 'runner_sid': owned['runner_sid'],
            'runner_session_id': owned['runner_session_id'],
            'guest_root': owned['root_records']['guest']['path'],
            'trusted_task_root': trusted_root,
            'trusted_application_path': trusted_application,
            'action_executable': task['action_executable'],
            'action_arguments_sha256': digest(task['action_arguments'].encode('utf-8')),
            'action_working_directory': trusted_root,
            'task_principal_sid': owned['runner_sid'],
            'desktop_lease_id': transport['desktop_lease_id'], 'desktop_nonce': 'd' * 32,
            'anchor_nonce': owned['protected_anchor_initial']['anchor_nonce'],
            'root_created_utc': '2026-09-29T00:00:01.0000000Z'})
        # The controller canonicalizes inventory identities, independently of launch order.
        declared = transport['raw_cleanup']['owned_resource_evidence']['declared_processes']
        declared.sort(key=lambda row: f"{row['pid']}|{row['start_time_utc_ticks']}")
        write_json(transport_path, transport)
        postlaunch_path = output / 'platform-postlaunch.json'
        postlaunch = json.loads(postlaunch_path.read_text())
        postlaunch['target']['process_id'] = cells[0]['process_id']
        postlaunch['identity_observation']['target_process_id'] = cells[0]['process_id']
        write_json(postlaunch_path, postlaunch)
        self.refresh_runtime(run)
        return run

    def test_current_source_manifest_cannot_delete_readiness_contract(self):
        run = self.runtime_run()
        path = run / 'input-manifest.json'
        manifest = json.loads(path.read_text())
        manifest['request']['readiness_bracket_contract'] = evidence.READINESS_BRACKET_CONTRACT
        write_json(path, manifest)
        with mock.patch.object(evidence, 'requires_readiness_brackets', return_value=True):
            evidence.validate_input_manifest(
                run, SOURCE, expected_profile_sha256=evidence.OWNED_PERFORMANCE_PROFILE_SHA256)
            manifest['request'].pop('readiness_bracket_contract')
            write_json(path, manifest)
            with self.assertRaisesRegex(evidence.EvidenceError, 'contract is missing'):
                evidence.validate_input_manifest(
                    run, SOURCE, expected_profile_sha256=evidence.OWNED_PERFORMANCE_PROFILE_SHA256)

    def test_declared_runtime_contract_rejects_missing_product_brackets(self):
        run = self.runtime_run()
        path = run / 'input-manifest.json'
        manifest = json.loads(path.read_text())
        manifest['request']['readiness_bracket_contract'] = evidence.READINESS_BRACKET_CONTRACT
        write_json(path, manifest)
        self.refresh_runtime(run)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)

    def test_complete_producer_shape_three_process_runtime_evidence(self):
        run = self.runtime_run()
        result = evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        self.assertEqual(len(result['metrics']['cells']), 3)
        self.assertEqual(result['metrics']['cells'][0]['populated_idle_samples'], 150)
        self.assertEqual(result['performance_batch'], 'not-run')
        profile = (SCRIPT_ROOT.parent / 'config/vm-automated-v2.json').read_bytes()
        with mock.patch.object(evidence.subprocess, 'run', return_value=SimpleNamespace(
                returncode=0, stdout=profile)), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(evidence.main(SCRIPT_ROOT.parent, ['--result-root', str(self.root),
                '--expected-source-sha', SOURCE, '--run', run.name,
                '--diagnostic', evidence.RUNTIME_BASELINE_MODE,
                '--acceptance-profile-id', evidence.V2_PROFILE_ID]), 0)
        self.assertEqual(json.loads(output.getvalue())['status'], 'measured')

    def test_runtime_early_host_receipt_requires_indexed_source_task_and_trusted_image(self):
        run = self.runtime_run()
        path = run / 'output/runtime-baseline-early-host.json'
        original = path.read_bytes()
        mutations = (
            ('schema', lambda r: r.__setitem__('schema_version', 2)),
            ('run', lambda r: r.__setitem__('run_name', 'DarkReNamerTests-' + 'f' * 32)),
            ('manifest', lambda r: r.__setitem__('input_manifest_sha256', 'f' * 64)),
            ('source', lambda r: r.__setitem__('source_sha', 'f' * 40)),
            ('bundle', lambda r: r.__setitem__('bundle_manifest_sha256', 'f' * 64)),
            ('application', lambda r: r.__setitem__('application_sha256', 'f' * 64)),
            ('vm', lambda r: r.__setitem__('vm_id', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')),
            ('sid', lambda r: r.__setitem__('runner_sid', 'S-1-5-21-1-1-1-1')),
            ('session', lambda r: r.__setitem__('runner_session_id', 3)),
            ('guest-root', lambda r: r.__setitem__('guest_root', r['trusted_task_root'])),
            ('trusted-root', lambda r: r.__setitem__('trusted_task_root', r['guest_root'])),
            ('guest-exe', lambda r: r.__setitem__(
                'trusted_application_path', r['guest_root'] + r'\bundle\DarkReNamer.exe')),
            ('action', lambda r: r.__setitem__('action_arguments_sha256', 'f' * 64)),
            ('action-root', lambda r: r.__setitem__('action_working_directory', r['guest_root'])),
            ('principal', lambda r: r.__setitem__('task_principal_sid', 'S-1-5-21-1-1-1-1')),
            ('lease', lambda r: r.__setitem__('desktop_lease_id', 'f' * 32)),
            ('anchor', lambda r: r.__setitem__('anchor_nonce', 'f' * 32)),
            ('root-time', lambda r: r.__setitem__('root_created_utc', '2020-01-01T00:00:00.0000000Z')),
            ('output-root', lambda r: r.__setitem__('host_output_root', '/wrong/output')),
            ('type', lambda r: r.__setitem__('trusted_application_path', 7)),
            ('extra', lambda r: r.__setitem__('unknown', True)),
            ('missing', lambda r: r.pop('anchor_nonce')),
        )
        for name, mutate in mutations:
            receipt = json.loads(original)
            mutate(receipt)
            write_json(path, receipt)
            self.refresh_runtime(run)
            with self.subTest(mutation=name), self.assertRaises(evidence.EvidenceError):
                evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        path.unlink()
        self.refresh_runtime(run)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)

    def test_canonical_inventory_is_unordered_but_cells_lifecycles_and_jobs_are_ordered(self):
        run = self.runtime_run()
        output = run / 'output'
        raw_path, transport_path = output / 'acceptance-result.json', output / 'transport.json'
        original_raw, original_transport = raw_path.read_bytes(), transport_path.read_bytes()
        raw, transport = json.loads(original_raw), json.loads(original_transport)
        owned = transport['raw_cleanup']['owned_resource_evidence']
        self.assertEqual([cell['process_id'] for cell in raw['assertions']['scenario']['cells']],
                         [8224, 956, 17280])
        self.assertEqual([row['pid'] for row in owned['declared_processes']], [17280, 8224, 956])
        evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        mutations = ('duplicate', 'missing', 'foreign', 'ticks', 'boolean-pid', 'integer-ticks',
                     'reordered-cells', 'reordered-lifecycles', 'reordered-jobs')
        for mutation in mutations:
            raw, transport = json.loads(original_raw), json.loads(original_transport)
            owned = transport['raw_cleanup']['owned_resource_evidence']
            declared = owned['declared_processes']
            if mutation == 'duplicate': declared[1] = deepcopy(declared[0])
            elif mutation == 'missing': declared.pop()
            elif mutation == 'foreign': declared[0]['pid'] = 27182
            elif mutation == 'ticks': declared[0]['start_time_utc_ticks'] = str(int(declared[0]['start_time_utc_ticks']) + 1)
            elif mutation == 'boolean-pid': declared[0]['pid'] = True
            elif mutation == 'integer-ticks': declared[0]['start_time_utc_ticks'] = int(declared[0]['start_time_utc_ticks'])
            elif mutation == 'reordered-cells': raw['assertions']['scenario']['cells'].reverse()
            elif mutation == 'reordered-lifecycles': raw['process_lifecycles'].reverse()
            else:
                raw['process_job_cleanup'].reverse()
                owned['process_job_cleanup'].reverse()
            write_json(raw_path, raw)
            write_json(transport_path, transport)
            self.refresh_runtime(run)
            with self.subTest(mutation=mutation), self.assertRaises(evidence.EvidenceError):
                evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        raw_path.write_bytes(original_raw)
        transport_path.write_bytes(original_transport)
        self.refresh_runtime(run)

    def test_rehashed_missing_endpoints_wrong_language_samples_and_exit_fail(self):
        run = self.runtime_run()
        path = run / 'output/acceptance-result.json'
        original = path.read_bytes()
        for mutate in (
            lambda r: r['assertions']['scenario']['cells'][0].__setitem__('icon_settlement', None),
            lambda r: r['assertions']['scenario']['cells'][0].__setitem__('populated_idle', None),
            lambda r: r['assertions']['scenario']['cells'][1].__setitem__('resolved_language', 'en'),
            lambda r: r['assertions']['scenario']['cells'][2]['menu'].__setitem__('parent', '언어'),
            lambda r: r['assertions']['scenario']['cells'][0]['samples'][1].__setitem__('cpu_ms', True),
            lambda r: r['assertions']['scenario']['cells'][0]['samples'][1].__setitem__('elapsed_ms', 0),
            lambda r: r['assertions']['scenario']['cells'][0]['startup'].__setitem__('launch_request_to_ready_ms', float('nan')),
            lambda r: r['assertions']['scenario']['cells'][1]['preference_before'].__setitem__('sha256', 'f' * 64),
            lambda r: r['assertions']['scenario']['cells'][1]['preference_before'].__setitem__('value', False),
            lambda r: r['assertions']['scenario']['cells'][2]['environment']['region'].__setitem__('culture', 'en-US'),
            lambda r: r['assertions']['scenario']['cells'][0]['empty_idle'].__setitem__('rows', False),
            lambda r: r['assertions']['scenario']['cells'][0]['transforms'][2].__setitem__('reset_elapsed_ms', False),
            lambda r: r['process_lifecycles'][2]['process_lifecycle'].__setitem__('exit_method', 'forced-termination'),
            lambda r: r['process_lifecycles'][2]['process_lifecycle'].__setitem__('executable_path', r'C:\other\DarkReNamer.exe'),
            lambda r: r['process_lifecycles'][2]['process_lifecycle'].__setitem__('creation_filetime', True),
            lambda r: r['assertions']['scenario']['system_resolution'].__setitem__('preferred_tags', ['en-US', 'ko-KR']),
            lambda r: r.__setitem__('process_job_cleanup', r['process_job_cleanup'][:2]),
            lambda r: r['assertions']['scenario']['cells'].__setitem__(1,
                deepcopy(r['assertions']['scenario']['cells'][0])),
        ):
            with self.subTest(mutate=mutate):
                changed = json.loads(original)
                mutate(changed)
                write_json(path, changed)
                self.refresh_runtime(run)
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        path.write_bytes(original)
        self.refresh_runtime(run)

    def test_runtime_startup_rounding_uses_raw_qpc_and_preserves_distinct_endpoints(self):
        run = self.runtime_run()
        raw = json.loads((run / 'output/acceptance-result.json').read_text())
        for cell in raw['assertions']['scenario']['cells']:
            startup = cell['startup']
            evidence.validate_runtime_startup(startup, 'fixture startup')
            self.assertEqual(startup['launch_request_to_main_bound_ms'], 100.0)
            self.assertEqual(startup['main_bound_to_ready_ms'], 100.0)
        startup = deepcopy(raw['assertions']['scenario']['cells'][0]['startup'])
        startup['clock']['command_ready_ticks'] += 5
        # A half-microsecond boundary may round differently in .NET/Python.
        for value in (200.0, 200.001):
            startup['launch_request_to_ready_ms'] = value
            evidence.validate_runtime_startup(startup, 'midpoint startup')
        startup['launch_request_to_ready_ms'] = 200.002
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_runtime_startup(startup, 'outside midpoint startup')

    def test_rehashed_raw_startup_clock_rejects_missing_types_order_and_derived_corruption(self):
        run = self.runtime_run()
        path = run / 'output/acceptance-result.json'
        original = path.read_bytes()
        mutations = []
        raw = json.loads(original)
        clock = raw['assertions']['scenario']['cells'][1]['startup']['clock']
        for name in clock:
            mutations.append((f'missing-{name}', lambda s, key=name: s['clock'].pop(key)))
            for bad in (False, 0, -1, 2**63, float(clock[name])):
                mutations.append((f'{name}-{bad!r}',
                    lambda s, key=name, value=bad: s['clock'].__setitem__(key, value)))
        boundaries = ('launch_request_ticks', 'process_create_begin_ticks', 'process_create_end_ticks',
                      'main_window_bound_ticks', 'command_ready_ticks')
        for earlier, later in zip(boundaries, boundaries[1:]):
            mutations.append((f'inverted-{earlier}-{later}',
                lambda s, left=earlier, right=later: s['clock'].__setitem__(right, s['clock'][left] - 1)))
        for name in evidence.RUNTIME_STARTUP_INTERVALS:
            mutations.extend(((f'missing-{name}', lambda s, key=name: s.pop(key)),
                (f'plus-.001-{name}', lambda s, key=name: s.__setitem__(key, s[key] + 0.001)),
                (f'bool-{name}', lambda s, key=name: s.__setitem__(key, True))))
        mutations.append(('main-bound-flag', lambda s: s.__setitem__('main_hwnd_bound', 1)))
        for name, mutate in mutations:
            changed = json.loads(original)
            mutate(changed['assertions']['scenario']['cells'][1]['startup'])
            write_json(path, changed)
            self.refresh_runtime(run)
            with self.subTest(mutation=name), self.assertRaises(evidence.EvidenceError):
                evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        path.write_bytes(original)
        self.refresh_runtime(run)

    def test_runtime_sample_clock_and_identity_reject_mixed_or_unbounded_rows(self):
        run = self.runtime_run()
        path = run / 'output/acceptance-result.json'
        original = path.read_bytes()
        mutations = (
            ('missing-clock', lambda rows, cell: rows[1].pop('probe_begin_ticks')),
            ('boolean-clock', lambda rows, cell: rows[1].__setitem__('probe_end_ticks', True)),
            ('before-ready', lambda rows, cell: rows[0].__setitem__(
                'probe_begin_ticks', cell['startup']['clock']['command_ready_ticks'] - 1)),
            ('after-deadline', lambda rows, cell: rows[-1].__setitem__(
                'probe_end_ticks', cell['startup']['clock']['launch_request_ticks'] +
                600 * cell['startup']['clock']['qpc_frequency'] + 1)),
            ('inverted-interval', lambda rows, cell: rows[1].__setitem__(
                'probe_end_ticks', rows[1]['probe_begin_ticks'] - 1)),
            ('overlap', lambda rows, cell: rows[1].__setitem__(
                'probe_begin_ticks', rows[0]['probe_end_ticks'] - 1)),
            ('probe-duration', lambda rows, cell: rows[1].__setitem__(
                'ui_response_ms', rows[1]['ui_response_ms'] + 1)),
            ('sample-gap', lambda rows, cell: rows[1].__setitem__('sample_gap_ms', 201.0)),
            ('pid', lambda rows, cell: rows[1].__setitem__('process_id', cell['process_id'] + 1)),
            ('start-time', lambda rows, cell: rows[1].__setitem__(
                'process_start_utc_ticks', cell['process_start_utc_ticks'] + 1)),
            ('window', lambda rows, cell: rows[1].__setitem__(
                'main_window_handle', cell['environment']['main_window']['hwnd'] + 1)),
            ('thread-drift', lambda rows, cell: rows[1].__setitem__('main_thread_id', 43)),
            ('thread-zero', lambda rows, cell: rows[0].__setitem__('main_thread_id', 0)),
            ('phase-regression', lambda rows, cell: rows[151].__setitem__('phase', 'empty-idle')),
        )
        for name, mutate in mutations:
            raw = json.loads(original)
            cell = raw['assertions']['scenario']['cells'][0]
            mutate(cell['samples'], cell)
            with self.subTest(mutation=name), self.assertRaises(evidence.EvidenceError):
                evidence.validate_runtime_baseline_metrics(raw['assertions']['scenario'])

    def test_rehashed_duplicate_raw_qpc_field_is_rejected(self):
        run = self.runtime_run()
        path = run / 'output/acceptance-result.json'
        original = path.read_text()
        target = '"qpc_frequency": 10000000'
        self.assertIn(target, original)
        changed = original.replace(target, target + ', "qpc_frequency": 10000000', 1).encode()
        path.write_bytes(changed)
        collection_path = run / 'collection.json'
        collection = json.loads(collection_path.read_text())
        for row in collection['files']:
            if row['relative_path'] == path.name:
                row.update(bytes=len(changed), sha256=digest(changed))
        write_json(collection_path, collection)
        result_path = run / 'output/run-result.json'
        result = json.loads(result_path.read_text())
        result.update(collection_sha256=digest(collection_path.read_bytes()),
                      observer_result_sha256=digest(changed))
        write_json(result_path, result)
        with self.assertRaisesRegex(evidence.EvidenceError, 'duplicate field: qpc_frequency'):
            evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)

    def test_product_appearance_golden_codec_and_strict_default_snapshot(self):
        record = self.saved_default_appearance()
        raw = bytes.fromhex(record['bytes_hex'])
        self.assertEqual(evidence.decode_runtime_appearance_preference(raw), record['value'])
        self.assertEqual(digest(raw), record['sha256'])
        evidence.validate_runtime_appearance_preference(record)
        evidence.validate_runtime_appearance_preference('absent')
        # Exact golden bytes from preferences.rs::both_formats_keep_independent_golden_bytes.
        dark = bytes([68, 82, 65, 80, 80, 82, 0, 0, 1, 8, 0, 0,
                      2, 2, 2, 0, 1, 0, 0, 0, 254, 181, 216, 140])
        self.assertEqual(evidence.decode_runtime_appearance_preference(dark),
            {'theme': 2, 'density': 2, 'emphasis': 2, 'show_separators': False,
             'show_preview_tint': True, 'show_empty_safety': False})
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_runtime_appearance_preference({**record, 'bytes_hex': dark.hex(),
                'sha256': digest(dark), 'value': evidence.decode_runtime_appearance_preference(dark)})
        for offset, value in ((0, 0), (8, 2), (9, 9), (10, 1), (11, 1), (12, 3),
                              (13, 4), (14, 3), (15, 2), (16, 2), (17, 2), (18, 1), (19, 1)):
            changed = bytearray(raw)
            changed[offset] = value
            with self.subTest(offset=offset), self.assertRaises(evidence.EvidenceError):
                evidence.decode_runtime_appearance_preference(self.rechecksum_appearance(changed))
        for changed in (raw[:-1], raw + b'\0', raw[:-1] + bytes([raw[-1] ^ 1])):
            with self.assertRaises(evidence.EvidenceError):
                evidence.decode_runtime_appearance_preference(changed)

    def test_rehashed_saved_appearance_rejects_explicit_theme_flags_hash_and_bool(self):
        run = self.runtime_run()
        path = run / 'output/acceptance-result.json'
        original = path.read_bytes()
        for mutation in ('light', 'dark', 'density', 'emphasis', 'separators', 'tint', 'safety',
                         'checksum', 'reserved', 'hash', 'bool-enum', 'int-flag', 'bool-length'):
            changed = json.loads(original)
            record = changed['assertions']['scenario']['cells'][1]['environment']['appearance']['preference_after']
            raw = bytearray.fromhex(record['bytes_hex'])
            if mutation in ('light', 'dark', 'density', 'emphasis', 'separators', 'tint', 'safety', 'reserved'):
                offset, value = {'light': (12, 1), 'dark': (12, 2), 'density': (13, 1),
                    'emphasis': (14, 2), 'separators': (15, 0), 'tint': (16, 0),
                    'safety': (17, 0), 'reserved': (18, 1)}[mutation]
                raw[offset] = value
                raw = self.rechecksum_appearance(raw)
                if mutation != 'reserved':
                    record['value'] = evidence.decode_runtime_appearance_preference(raw)
                record.update(bytes_hex=raw.hex(), sha256=digest(raw))
            elif mutation == 'checksum':
                raw[-1] ^= 1
                record.update(bytes_hex=raw.hex(), sha256=digest(raw))
            elif mutation == 'hash':
                record['sha256'] = 'f' * 64
            elif mutation == 'bool-enum':
                record['value']['theme'] = False
            elif mutation == 'int-flag':
                record['value']['show_separators'] = 1
            else:
                record['bytes'] = True
            write_json(path, changed)
            self.refresh_runtime(run)
            with self.subTest(mutation=mutation), self.assertRaises(evidence.EvidenceError):
                evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        changed = json.loads(original)
        changed['assertions']['scenario']['cells'][2]['environment']['appearance']['preference_after'] = 'absent'
        write_json(path, changed)
        self.refresh_runtime(run)
        self.assertEqual(len(evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)['metrics']['cells']), 3)

    def test_zero_sample_short_phase_preserves_real_powershell_double_zero_summary(self):
        run = self.runtime_run()
        path = run / 'output/acceptance-result.json'
        raw = json.loads(path.read_text())
        cell = raw['assertions']['scenario']['cells'][0]
        cell['samples'] = [row for row in cell['samples'] if row['phase'] != 'transform-no-op']
        # A real sub-200ms phase can occur entirely between timer callbacks.
        # Get-ObserverPerformancePhaseSummary emits [double]0 as JSON 0.0.
        previous_begin = None
        for row in cell['samples']:
            begin = row['probe_begin_ticks']
            row['sample_gap_ms'] = (0.0 if previous_begin is None else
                (begin - previous_begin) * 1000.0 / cell['startup']['clock']['qpc_frequency'])
            previous_begin = begin
        for summary in cell['phase_summary']:
            rows = [row for row in cell['samples'] if row['phase'] == summary['phase']]
            summary.update(sample_count=len(rows),
                max_sample_gap_ms=max((row['sample_gap_ms'] for row in rows), default=0.0),
                max_resource_collection_ms=max((row['resource_collection_ms'] for row in rows), default=0.0))
        write_json(path, raw)
        self.refresh_runtime(run)
        result = evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        self.assertEqual(result['metrics']['cells'][0]['sample_count'], 310)
        self.assertNotIn('transform-no-op', [row['phase'] for row in
            result['metrics']['cells'][0]['sampled_phase_resources']])
        short = next(row for row in cell['phase_summary'] if row['phase'] == 'transform-no-op')
        short['max_sample_gap_ms'] = False
        write_json(path, raw)
        self.refresh_runtime(run)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)

    def test_rehashed_dark_forced_missing_override_and_unbound_appearance_fail(self):
        run = self.runtime_run()
        path = run / 'output/acceptance-result.json'
        original = path.read_bytes()
        for mutation in ('dark-before', 'dark-ready', 'forced-close', 'missing', 'missing-resolution',
                         'override-before', 'override-after', 'wrong-pid', 'wrong-hwnd',
                         'wrong-session', 'explicit-light', 'missing-radio'):
            changed = json.loads(original)
            cell = changed['assertions']['scenario']['cells'][1]
            appearance = cell['environment']['appearance']
            if mutation.startswith('dark'):
                phase = 'pre_launch_resolution' if mutation == 'dark-before' else 'ready_resolution'
                # Even a forged Light label cannot conceal the actual dark foreground.
                appearance[phase]['foreground_argb'] = [255, 245, 245, 245]
            elif mutation == 'forced-close':
                appearance['pre_close_resolution']['system_visual_style']['forced_colors'] = True
            elif mutation == 'missing':
                del cell['environment']['appearance']
            elif mutation == 'missing-resolution':
                del appearance['ready_resolution']
            elif mutation.startswith('override'):
                appearance['preference_before' if mutation == 'override-before' else 'preference_after'] = 'present'
            elif mutation == 'wrong-pid':
                appearance['ready_menu']['pid'] += 1
            elif mutation == 'wrong-hwnd':
                appearance['pre_close_menu']['hwnd'] += 1
            elif mutation == 'wrong-session':
                appearance['ready_menu']['session_id'] = 3
                appearance['pre_close_menu']['session_id'] = 3
            elif mutation == 'explicit-light':
                appearance['ready_menu']['menu_checked'][0]['checked'] = False
                appearance['ready_menu']['menu_checked'][1]['checked'] = True
            else:
                del appearance['ready_menu']['menu_checked']
            write_json(path, changed)
            self.refresh_runtime(run)
            with self.subTest(mutation=mutation), self.assertRaises(evidence.EvidenceError):
                evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
        path.write_bytes(original)
        self.refresh_runtime(run)

    def test_runtime_cli_requires_one_fixed_run_and_diagnostic_only_plan(self):
        base = ['--result-root', str(self.root), '--expected-source-sha', SOURCE,
                '--diagnostic', evidence.RUNTIME_BASELINE_MODE,
                '--acceptance-profile-id', evidence.V2_PROFILE_ID]
        for extra in (['--run', evidence.RUNTIME_BASELINE_RUN_ID, '--require-complete-set'],
                      ['--run', evidence.RUNTIME_BASELINE_RUN_ID, '--configuration-set', 'focused'],
                      ['--run', evidence.PICKER_RUN_ID]):
            with self.subTest(extra=extra), self.assertRaises(evidence.EvidenceError):
                evidence.main(SCRIPT_ROOT.parent, base + extra)
        request = {'mode': evidence.RUNTIME_BASELINE_MODE, 'appearance': 'light',
            'desktop': {'width': 1366, 'height': 768, 'dpi': 96}, 'text_scale_percent': 100,
            'runtime_baseline_plan': deepcopy(evidence.RUNTIME_BASELINE_PLAN)}
        for plan in ('performance_plan', 'settlement_plan', 'picker_identity_plan'):
            changed = {**request, plan: {}}
            with self.subTest(plan=plan), self.assertRaises(evidence.EvidenceError):
                evidence.validate_request(changed)

    def test_manifest_hash_plan_and_incomplete_cleanup_fail_closed(self):
        run = self.runtime_run()
        for relative, mutate in (
            ('input-manifest.json', lambda d: d['prepared_bundle'].__setitem__('application_sha256', 'f' * 64)),
            ('input-manifest.json', lambda d: d['request']['runtime_baseline_plan'].__setitem__('idle_seconds', 29)),
            ('input-manifest.json', lambda d: d['request']['runtime_baseline_plan'].__setitem__('idle_seconds', True)),
            ('output/desktop-stop-response.json', lambda d: d.__setitem__('lifecycleStatus', 'pending')),
            ('output/transport.json', lambda d: d['raw_cleanup']['owned_resource_evidence']['process_job_cleanup'][2].__setitem__('job_closed', False)),
        ):
            path = run / relative
            original = path.read_bytes()
            changed = json.loads(original)
            mutate(changed)
            write_json(path, changed)
            self.refresh_runtime(run)
            with self.subTest(relative=relative, mutate=mutate), self.assertRaises(evidence.EvidenceError):
                evidence.validate_runtime_baseline_run(self.root, run.name, SOURCE)
            path.write_bytes(original)
            self.refresh_runtime(run)


class GuiApplyEndpointTests(unittest.TestCase):
    @staticmethod
    def fixture(count, cancelled):
        initial, final = [], []
        for index in range(count):
            name = f'ordinary-{index:05d}.txt'
            row = {'name': name,
                   'content_sha256': digest(f'gui-apply-{index:05d}'.encode('ascii')),
                   'identity': f'{index + 1:08x}:{index + 1:016x}'}
            initial.append(row)
            final.append({**row, 'name': name if cancelled else 'sample-' + name})
        return initial, final

    @staticmethod
    def icon(count):
        return {'version': 1, 'session': '1', 'generation': '1',
            'status_revision': '2', 'model_revision': '1', 'bootstrap': 1,
            'queued': 0, 'inflight': 0, 'undrained': 0, 'unresolved_rows': 0,
            'cursor': count, 'settled': True, 'worker_joined': False,
            'reconcile_rows': 0, 'batch_ack': 0, 'demand_exhausted': True,
            'demand_remaining': 0, 'unavailable_or_retiring': False}

    @classmethod
    def valid(cls, case='success-100'):
        count = int(case.split('-')[-1])
        cancelled = case.startswith('cancel-')
        initial, final = cls.fixture(count, cancelled)
        pid, start, hwnd, frequency = 41, 638965440000000000, 900, 10000000
        clock = 200
        brackets = [{'operation': 'startup-main-window',
            'predicate': 'bound-main-window', 'observation': 'opaque-observer-envelope',
            'qpc_frequency': frequency, 'process_id': pid,
            'process_start_utc_ticks': start, 'main_window_handle': hwnd,
            'begin_ticks': 100, 'end_ticks': 150}]

        def tick():
            nonlocal clock
            clock += 50
            return clock

        def probe(operation, predicate):
            begin = tick()
            row = {'operation': operation, 'predicate': predicate,
                'observation': 'polled-monotonic-predicate', 'qpc_frequency': frequency,
                'process_id': pid, 'process_start_utc_ticks': start,
                'main_window_handle': hwnd,
                'probes': [{'begin_ticks': begin, 'end_ticks': begin + 1,
                            'ready': True}]}
            brackets.append(row)
            return row

        imports = []
        previous_trace = None
        stages = [count] if count <= 1000 else [1000, 3250, 5500, 7750, 10000]
        def import_frame(revision, feedback=0):
            begin = tick()
            return {'query_begin_ticks': begin, 'query_end_ticks': begin + 1,
                'qpc_frequency': frequency, 'revision': revision,
                'import_feedback_ticks': feedback,
                'process_id': pid, 'process_start_utc_ticks': start,
                'main_window_handle': hwnd}

        for index, rows in enumerate(stages):
            stage = 'initial' if index == 0 else f'remainder-{index - 1}'
            feedback_before = import_frame(0) if index == 0 and count >= 1000 else None
            opened = tick()
            committed = opened + 8
            observed = probe('gui-apply-' + stage, 'expected-row-count')
            command = probe('gui-apply-' + stage, 'import-command-enabled')
            feedback = {'definition':
                'owner-thread-import-cancel-control-availability-committed',
                'before': feedback_before, 'after': import_frame(1, committed)} \
                if feedback_before is not None else None
            trace_before = deepcopy(previous_trace) if previous_trace else {
                'schema_version': 1, 'qpc_frequency': frequency, 'trace_revision': 0,
                'generation': 0, 'session_id': 0, 'initial_model_revision': 0,
                'final_model_revision': 0, 'flags': 0,
                'events': {name: 0 for name in IMPORT_TRACE_EVENTS},
                'process_id': pid, 'process_start_utc_ticks': start,
                'main_window_handle': hwnd, 'owner_thread_id': 12,
            }
            trace_before.update(query_begin_ticks=opened - 20, query_end_ticks=opened - 19)
            events = dict(zip(IMPORT_TRACE_EVENTS, (
                opened + 2, opened + 4, opened + 5, opened + 3, 0, 0, committed,
                opened + 6, opened + 7, opened + 9, opened + 10,
                opened + 11, opened + 12, opened + 13, 0, 0), strict=True))
            query_begin = tick()
            trace_after = {
                'schema_version': 1, 'qpc_frequency': frequency,
                'trace_revision': (index + 1) * 20, 'generation': index + 1,
                'session_id': index + 1, 'initial_model_revision': index,
                'final_model_revision': index + 1, 'flags': 121, 'events': events,
                'process_id': pid, 'process_start_utc_ticks': start,
                'main_window_handle': hwnd, 'owner_thread_id': 12,
                'query_begin_ticks': query_begin, 'query_end_ticks': query_begin + 1,
            }
            previous_trace = trace_after
            imports.append({'id': stage, 'expected_rows': rows, 'open_ticks': opened,
                'picker_request_ticks': opened - 10, 'dialog_closed_ticks': opened + 20,
                'rows_observed_ticks': observed['probes'][-1]['end_ticks'],
                'command_ready_ticks': command['probes'][-1]['end_ticks'],
                'first_feedback': feedback, 'product_trace': {
                    'schema_version': 1, 'before': trace_before, 'after': trace_after}})
        def frame(revision, initial=0, confirmation=0, cancel_ticks=0):
            begin = tick()
            return {'query_begin_ticks': begin, 'query_end_ticks': begin + 1,
                'qpc_frequency': frequency, 'revision': revision,
                'initial_apply_accepted_ticks': initial,
                'confirmation_accepted_ticks': confirmation,
                'cancel_accepted_ticks': cancel_ticks,
                'cancel_kind': 4 if cancel_ticks else 0,
                'process_id': pid, 'process_start_utc_ticks': start,
                'main_window_handle': hwnd}

        initial_before = frame(len(stages))
        requested = tick()
        planning = probe('apply-request', 'planning-status') if count >= 1000 else None
        confirmation = probe('apply-confirmation', 'bound-actionable-confirmation')
        initial_after = frame(len(stages) + 1, requested + 1)
        confirmation_before = frame(len(stages) + 1, requested + 1)
        invoked = tick()
        execution_feedback = probe('apply-accepted', 'execution-busy-status')
        confirmation_after = frame(len(stages) + 2, requested + 1, invoked + 1)
        cancel = None
        if cancelled:
            cancel_before = frame(len(stages) + 2, requested + 1, invoked + 1)
            cancel_requested = tick()
            ack = probe('active-apply-cancel', 'first-corresponding-cancel-feedback')
            cancel_after = frame(len(stages) + 3, requested + 1, invoked + 1, cancel_requested + 1)
            cancel = {'request_ticks': cancel_requested, 'first_feedback': ack,
                      'first_feedback_observation': {
                          'kind': 'intermediate-request-status',
                          'status': '적용 취소를 요청했습니다. 파일 처리 결과가 표시될 때까지 기다려 주세요.',
                          'cancel_enabled': False, 'cancel_offscreen': False,
                          'control_id': 1009, 'control_handle': 9009},
                      'intermediate_ack': 'observed',
                      'owner_thread_acceptance': {'before': cancel_before,
                                                  'after': cancel_after},
                      'control_id': 1009, 'control_handle': 9009,
                      'requested_from': 'active-apply-worker'}
        ready = probe('apply-result', 'cancelled-result-and-commands' if cancelled
                      else 'completed-result-rows-and-commands')
        ready_probe = ready['probes'][-1]
        native_sync = {'selector': 34, 'value': 1, 'qpc_frequency': frequency,
                       'query_begin_ticks': ready_probe['begin_ticks'],
                       'query_end_ticks': ready_probe['end_ticks'],
                       'process_id': pid, 'process_start_utc_ticks': start,
                       'main_window_handle': hwnd}
        verified_begin = tick()
        verified_end = tick()
        close_wait = probe('idle-close', 'close-readiness-mask31')
        query_begin, query_end, close_request, exit_observed = (tick() for _ in range(4))
        job = {'status': 'clean'}
        icon = cls.icon(count)
        scenario = {'mode': evidence.GUI_APPLY_MODE, 'case': case, 'count': count,
            'qpc_frequency': frequency, 'executable_sha256': 'a' * 64,
            'fixture_initial': {}, 'fixture_final': {}, 'native_process_lifetime': {},
            'process_id': pid, 'process_start_utc_ticks': start,
            'main_window_handle': hwnd, 'environment': {}, 'imports': imports,
            'icon_settlement': {'data_ready_ms': 1, 'icon_settled_observed_ms': 2,
                'first_status': icon, 'settled_status': icon, 'confirmation_status': icon,
                'poll_count': 2, 'unstable_query_attempts': 0,
                'sampled_peak_pending': 0, 'sampled_peak_unresolved_rows': 0},
            'apply_request': {'input': 'visible-command-rail', 'request_ticks': requested,
                'owner_thread_acceptance': {'before': initial_before,
                                            'after': initial_after},
                'planning_feedback': planning, 'confirmation_ready': confirmation,
                'confirmation_handle': 999, 'expected_changed_rows': count},
            'apply_execution': {'invocation_ticks': invoked,
                'owner_thread_acceptance': {'before': confirmation_before,
                                            'after': confirmation_after},
                'first_feedback': execution_feedback,
                'outcome': 'cancelled-rollback-unproven' if cancelled else 'completed',
                'operation_ready': ready,
                'native_preview_synchronization': native_sync,
                'result_status': '요청에 따라 변경을 취소했습니다.' if cancelled else
                    f'{count}개 변경 완료 · 목록에 실제 결과를 반영했습니다.',
                'rows': count, 'import_command_enabled': True,
                'apply_command_enabled': cancelled},
            'journal_residue_count': 0, 'verification_begin_ticks': verified_begin,
            'verification_end_ticks': verified_end,
            'samples': [{'process_id': pid, 'process_start_utc_ticks': start,
                         'main_window_handle': hwnd}],
            'close_readiness_wait': close_wait,
            'close_readiness': {'selector': 22, 'required_mask': 31, 'flags': 31,
                'query_begin_ticks': query_begin, 'query_end_ticks': query_end,
                'process_id': pid, 'process_start_utc_ticks': start,
                'main_window_handle': hwnd},
            'normal_close': {'request_ticks': close_request,
                'exit_observed_ticks': exit_observed, 'qpc_frequency': frequency,
                'process_id': pid, 'process_start_utc_ticks': start,
                'main_window_handle': hwnd, 'exit_code': 0, 'job_cleanup': job},
            'readiness_brackets': brackets, 'appearance': 'light'}
        if cancelled:
            scenario['cancel'] = cancel
        return scenario, initial, final

    def test_success_and_cancel_have_distinct_measured_endpoints(self):
        for case in ('success-100', 'success-1000', 'success-10000', 'cancel-10000'):
            with self.subTest(case=case):
                scenario, initial, final = self.valid(case)
                metrics = evidence.validate_gui_apply_metrics(scenario, initial, final)
                self.assertEqual(metrics['count'], int(case.split('-')[-1]))
                self.assertTrue(metrics['native_preview_synchronized'])
                self.assertEqual(metrics['presentation_latency'], 'not-measured')
                if metrics['count'] >= 1000:
                    feedback = scenario['imports'][0]['first_feedback']
                    self.assertEqual(metrics['import_first_feedback_committed_ms'],
                        (feedback['after']['import_feedback_ticks'] -
                         scenario['imports'][0]['open_ticks']) * 1000 /
                        scenario['qpc_frequency'])
                    self.assertGreater(metrics['import_feedback_clock_discovery_upper_ms'],
                                       metrics['import_first_feedback_committed_ms'])
                else:
                    self.assertEqual(metrics['import_first_feedback_committed_ms'],
                                     'not-measured')

    def test_import_trace_is_required_for_current_source_and_preserves_legacy_endpoint(self):
        scenario, initial, final = self.valid('success-10000')
        measured = evidence.validate_gui_apply_metrics(
            scenario, initial, final, require_product_trace=True)
        self.assertEqual(len(measured['import_product_traces']), 5)
        self.assertEqual(measured['four_addition_observer_inclusive_ms'], sum(
            (row['rows_observed_ticks'] - row['open_ticks']) * 1000 /
            scenario['qpc_frequency'] for row in scenario['imports'][1:]))
        for row in scenario['imports']:
            row.pop('product_trace')
            row.pop('picker_request_ticks')
            row.pop('dialog_closed_ticks')
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_gui_apply_metrics(
                scenario, initial, final, require_product_trace=True)
        self.assertEqual(evidence.validate_gui_apply_metrics(
            scenario, initial, final)['import_product_traces'], 'not-measured')

    def test_import_trace_cannot_disagree_with_cancel_clock_or_switch_owner_thread(self):
        scenario, initial, final = self.valid('success-10000')
        for mutate in (
            lambda s: s['imports'][0]['product_trace']['after']['events']
                .__setitem__('cancel_ready', s['imports'][0]['open_ticks'] + 9),
            lambda s: [s['imports'][1]['product_trace'][side]
                .__setitem__('owner_thread_id', 99) for side in ('before', 'after')],
            lambda s: s['imports'][0].__setitem__('dialog_closed_ticks',
                s['imports'][0]['rows_observed_ticks'] + 1),
            lambda s: s['imports'][0].__setitem__('picker_request_ticks',
                s['imports'][0]['open_ticks']),
        ):
            changed = deepcopy(scenario)
            mutate(changed)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_gui_apply_metrics(changed, initial, final)

    def test_import_trace_legacy_lineage_does_not_trust_missing_or_unrelated_commits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            def commit(message):
                subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test',
                    '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty',
                    '-qm', message], check=True)
                return subprocess.check_output(['git', '-C', str(root),
                    'rev-parse', 'HEAD'], text=True).strip()
            old = commit('old')
            current = commit('current')
            with mock.patch.object(evidence, 'IMPORT_TRACE_LEGACY_TIP', old):
                self.assertFalse(evidence.requires_import_trace(old, root))
                self.assertTrue(evidence.requires_import_trace(current, root))
                self.assertTrue(evidence.requires_import_trace('f' * 40, root))
                self.assertTrue(evidence.requires_import_trace('invalid', root))

    def test_rejects_missing_stale_foreign_or_late_import_control_feedback(self):
        scenario, initial, final = self.valid('success-1000')
        feedback = scenario['imports'][0]['first_feedback']
        changes = {
            'missing': lambda s: s['imports'][0].__setitem__('first_feedback', None),
            'wrong-definition': lambda s: s['imports'][0]['first_feedback']
                .__setitem__('definition', 'queued-status-text'),
            'prior-event': lambda s: s['imports'][0]['first_feedback']['before']
                .__setitem__('import_feedback_ticks', 1),
            'prior-revision': lambda s: s['imports'][0]['first_feedback']['before']
                .__setitem__('revision', 1),
            'skipped-revision': lambda s: s['imports'][0]['first_feedback']['after']
                .__setitem__('revision', 2),
            'event-before-open': lambda s: s['imports'][0]['first_feedback']['after']
                .__setitem__('import_feedback_ticks', s['imports'][0]['open_ticks']),
            'event-after-rows': lambda s: s['imports'][0]['first_feedback']['after']
                .__setitem__('import_feedback_ticks', s['imports'][0]['rows_observed_ticks']),
            'discovery-before-ready': lambda s: s['imports'][0]['first_feedback']['after']
                .__setitem__('query_begin_ticks', s['imports'][0]['command_ready_ticks']),
            'overlap-open': lambda s: s['imports'][0]['first_feedback']['before']
                .__setitem__('query_end_ticks', s['imports'][0]['open_ticks']),
            'wrong-frequency': lambda s: s['imports'][0]['first_feedback']['after']
                .__setitem__('qpc_frequency', 1),
            'foreign-process': lambda s: s['imports'][0]['first_feedback']['after']
                .__setitem__('process_start_utc_ticks', 1),
            'foreign-hwnd': lambda s: s['imports'][0]['first_feedback']['after']
                .__setitem__('main_window_handle', 1),
            'bool-tick': lambda s: s['imports'][0]['first_feedback']['after']
                .__setitem__('import_feedback_ticks', True),
        }
        self.assertEqual(feedback['before']['revision'], 0)
        for name, mutate in changes.items():
            changed = deepcopy(scenario)
            mutate(changed)
            with self.subTest(name=name), self.assertRaises(evidence.EvidenceError):
                evidence.validate_gui_apply_metrics(changed, initial, final)
        changed = deepcopy(scenario)
        changed['readiness_brackets'].insert(1, {
            'operation': 'import-open', 'predicate': 'bound-import-reading-status',
            'observation': 'polled-monotonic-predicate',
            'qpc_frequency': scenario['qpc_frequency'],
            'process_id': scenario['process_id'],
            'process_start_utc_ticks': scenario['process_start_utc_ticks'],
            'main_window_handle': scenario['main_window_handle'],
            'probes': [{'begin_ticks': scenario['imports'][0]['open_ticks'],
                        'end_ticks': scenario['imports'][0]['open_ticks'] + 1,
                        'ready': True}],
        })
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_gui_apply_metrics(changed, initial, final)

    def test_short_unmeasured_import_may_finish_without_a_laid_out_cancel_button(self):
        scenario, initial, final = self.valid('success-100')
        frames = [scenario['apply_request']['owner_thread_acceptance'][side]
                  for side in ('before', 'after')]
        frames.extend(scenario['apply_execution']['owner_thread_acceptance'][side]
                      for side in ('before', 'after'))
        for frame in frames:
            frame['revision'] -= 1
        self.assertEqual(evidence.validate_gui_apply_metrics(
            scenario, initial, final)['import_first_feedback_committed_ms'],
            'not-measured')

    def test_later_ten_thousand_row_stages_do_not_require_separate_feedback_events(self):
        scenario, initial, final = self.valid('success-10000')
        frames = [scenario['apply_request']['owner_thread_acceptance'][side]
                  for side in ('before', 'after')]
        frames.extend(scenario['apply_execution']['owner_thread_acceptance'][side]
                      for side in ('before', 'after'))
        for frame in frames:
            frame['revision'] -= 4
        self.assertGreater(evidence.validate_gui_apply_metrics(
            scenario, initial, final)['import_first_feedback_committed_ms'], 0)

    def test_rejects_native_preview_failure_or_late_or_foreign_query(self):
        scenario, initial, final = self.valid()
        for name, mutate in {
            'failed_fallback': lambda x: x['apply_execution']['native_preview_synchronization'].__setitem__('value', 0),
            'missing': lambda x: x['apply_execution'].pop('native_preview_synchronization'),
            'wrong_selector': lambda x: x['apply_execution']['native_preview_synchronization'].__setitem__('selector', 22),
            'foreign_process': lambda x: x['apply_execution']['native_preview_synchronization'].__setitem__('process_id', 42),
            'foreign_window': lambda x: x['apply_execution']['native_preview_synchronization'].__setitem__('main_window_handle', 901),
            'wrong_clock': lambda x: x['apply_execution']['native_preview_synchronization'].__setitem__('qpc_frequency', 9),
            'after_endpoint': lambda x: x['apply_execution']['native_preview_synchronization'].__setitem__(
                'query_begin_ticks', x['apply_execution']['operation_ready']['probes'][-1]['end_ticks'] + 1),
        }.items():
            changed = deepcopy(scenario)
            mutate(changed)
            with self.subTest(name=name), self.assertRaises(evidence.EvidenceError):
                evidence.validate_gui_apply_metrics(changed, initial, final)

    def test_rejects_identity_order_completion_command_journal_exit_and_survivors(self):
        scenario, initial, final = self.valid()
        changes = {
            'identity': lambda x: x['close_readiness'].__setitem__('process_id', 42),
            'frequency': lambda x: x['normal_close'].__setitem__('qpc_frequency', 9),
            'order': lambda x: x.__setitem__('verification_begin_ticks',
                x['apply_execution']['invocation_ticks']),
            'premature_rows': lambda x: x['imports'][0].__setitem__('rows_observed_ticks',
                x['imports'][0]['open_ticks']),
            'command': lambda x: x['apply_execution'].__setitem__('import_command_enabled', False),
            'journal': lambda x: x.__setitem__('journal_residue_count', 1),
            'exit': lambda x: x['normal_close'].__setitem__('exit_code', 1),
            'survivors': lambda x: x['normal_close']['job_cleanup'].__setitem__('status', 'failed'),
            'preference_ack': lambda x: x['close_readiness'].__setitem__('flags', 27),
        }
        for name, mutate in changes.items():
            changed = deepcopy(scenario)
            mutate(changed)
            with self.subTest(name=name), self.assertRaises(evidence.EvidenceError):
                evidence.validate_gui_apply_metrics(changed, initial, final)
        missing = deepcopy(final)
        missing.pop()
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_gui_apply_metrics(scenario, initial, missing)

    def test_cancel_first_feedback_cannot_follow_ready_or_precede_request(self):
        scenario, initial, final = self.valid('cancel-10000')
        for mutate in (
            lambda x: x['cancel']['first_feedback']['probes'][-1].__setitem__(
                'end_ticks', x['apply_execution']['operation_ready']['probes'][-1]['end_ticks']),
            lambda x: x['cancel'].__setitem__('request_ticks',
                x['apply_execution']['invocation_ticks']),
            lambda x: x.pop('cancel'),
        ):
            changed = deepcopy(scenario)
            mutate(changed)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_gui_apply_metrics(changed, initial, final)

    def test_terminal_first_is_feedback_without_intermediate_ack(self):
        scenario, initial, final = self.valid('cancel-10000')
        observation = scenario['cancel']['first_feedback_observation']
        observation.update(kind='terminal-cancel-status',
                           status=scenario['apply_execution']['result_status'],
                           cancel_enabled=False, cancel_offscreen=True)
        scenario['cancel']['intermediate_ack'] = 'not-observed'
        metrics = evidence.validate_gui_apply_metrics(scenario, initial, final)
        self.assertEqual(metrics['cancel_first_corresponding_feedback_kind'],
                         'terminal-cancel-status')
        self.assertEqual(metrics['cancel_intermediate_ack_upper_ms'], 'not-observed')
        self.assertGreater(metrics['cancel_first_corresponding_feedback_upper_ms'], 0)
        for mutate in (
            lambda x: x['cancel']['first_feedback_observation'].__setitem__(
                'status', '10000개 변경 완료 · 목록에 실제 결과를 반영했습니다.'),
            lambda x: x['cancel']['first_feedback_observation'].__setitem__(
                'status', '요청에 따라 변경을 취소하고 원래 상태로 복원했습니다.'),
            lambda x: x['cancel'].__setitem__('intermediate_ack', 'observed'),
            lambda x: x['cancel']['first_feedback_observation'].__setitem__(
                'kind', 'unknown'),
            lambda x: x['cancel']['first_feedback_observation'].pop('status'),
        ):
            changed = deepcopy(scenario)
            mutate(changed)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_gui_apply_metrics(changed, initial, final)

    def test_intermediate_first_requires_visible_disabled_cancel(self):
        scenario, initial, final = self.valid('cancel-10000')
        metrics = evidence.validate_gui_apply_metrics(scenario, initial, final)
        self.assertGreater(metrics['cancel_intermediate_ack_upper_ms'], 0)
        for key, value in (('cancel_enabled', True), ('cancel_offscreen', True),
                           ('status', '10000개 변경 완료 · 목록에 실제 결과를 반영했습니다.'),
                           ('control_handle', 999)):
            changed = deepcopy(scenario)
            changed['cancel']['first_feedback_observation'][key] = value
            with self.subTest(key=key), self.assertRaises(evidence.EvidenceError):
                evidence.validate_gui_apply_metrics(changed, initial, final)

    def test_owner_acceptance_rejects_preinput_stale_or_drifting_clock(self):
        scenario, initial, final = self.valid('cancel-10000')
        changes = {
            'preinput': lambda x: x['apply_execution']['owner_thread_acceptance']
                ['after'].__setitem__('confirmation_accepted_ticks',
                    x['apply_execution']['invocation_ticks'] - 1),
            'stale_revision': lambda x: x['cancel']['owner_thread_acceptance']
                ['after'].__setitem__('revision',
                    x['cancel']['owner_thread_acceptance']['before']['revision']),
            'skipped_revision': lambda x: x['cancel']['owner_thread_acceptance']
                ['after'].__setitem__('revision',
                    x['cancel']['owner_thread_acceptance']['before']['revision'] + 2),
            'overlapping_clock_query': lambda x: x['cancel']['owner_thread_acceptance']
                ['before'].__setitem__('query_begin_ticks',
                    x['apply_execution']['owner_thread_acceptance']['after']
                     ['query_end_ticks'] - 1),
            'stale_event': lambda x: x['cancel']['owner_thread_acceptance']
                ['before'].__setitem__('cancel_accepted_ticks', 1),
            'frequency': lambda x: x['apply_request']['owner_thread_acceptance']
                ['after'].__setitem__('qpc_frequency', 9),
            'process': lambda x: x['cancel']['owner_thread_acceptance']
                ['after'].__setitem__('process_start_utc_ticks', 1),
            'wrong_cancel_kind': lambda x: x['cancel']['owner_thread_acceptance']
                ['after'].__setitem__('cancel_kind', 0),
            'bool_cancel_kind': lambda x: x['cancel']['owner_thread_acceptance']
                ['after'].__setitem__('cancel_kind', True),
        }
        for name, mutate in changes.items():
            changed = deepcopy(scenario)
            mutate(changed)
            with self.subTest(name=name), self.assertRaises(evidence.EvidenceError):
                evidence.validate_gui_apply_metrics(changed, initial, final)

    def test_cancel_terminal_disposition_is_derived_from_status(self):
        scenario, initial, final = self.valid('cancel-10000')
        statuses = {
            '파일 변경을 시작하기 전에 취소했습니다.': 'cancelled-before-mutation',
            '요청에 따라 변경을 취소하고 원래 상태로 복원했습니다.': 'rolled-back',
            '요청에 따라 변경을 취소했습니다.': 'cancelled-rollback-unproven',
        }
        for status, outcome in statuses.items():
            changed = deepcopy(scenario)
            changed['apply_execution'].update(result_status=status, outcome=outcome)
            with self.subTest(outcome=outcome):
                self.assertEqual(evidence.validate_gui_apply_metrics(
                    changed, initial, final)['outcome'], outcome)
                changed['apply_execution']['outcome'] = 'rolled-back' \
                    if outcome != 'rolled-back' else 'cancelled-before-mutation'
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate_gui_apply_metrics(changed, initial, final)


class GuiApplyCampaignTests(unittest.TestCase):
    @staticmethod
    def payload(base):
        order = ['success-100', 'success-1000', 'success-10000',
                 *(['success-1000'] * 5), 'cancel-10000']
        source = 'a' * 40
        receipts = {key: 'b' * 64 for key in (
            'input_manifest_sha256', 'collection_sha256', 'cleanup_sha256',
            'observer_result_sha256')}
        metrics = {key: 100.0 for key in (
            'import_first_feedback_committed_ms', 'apply_planning_feedback_upper_ms',
            'apply_execution_feedback_upper_ms', 'idle_close_to_exit_upper_ms',
            'apply_request_to_confirmation_upper_ms',
            'confirm_to_operation_ready_upper_ms',
            'cancel_owner_acceptance_ms',
            'cancel_first_corresponding_feedback_upper_ms',
            'cancel_owner_to_first_feedback_upper_ms',
            'cancel_intermediate_ack_upper_ms',
            'cancel_to_operation_ready_upper_ms')}
        rows, measured = [], []
        for index, case in enumerate(order):
            root = base / f'run-{index + 1}'
            root.mkdir()
            rows.append({'case': case, 'result_root': str(root), **receipts})
            measured.append({'run_id': evidence.GUI_APPLY_RUN_PREFIX + case,
                'source_sha': source, 'application_sha256': 'c' * 64,
                'observer_sha256': 'd' * 64, 'runner_sha256': 'e' * 64,
                'profile_sha256': evidence.OWNED_PERFORMANCE_PROFILE_SHA256,
                'bundle_manifest_sha256': 'f' * 64,
                'process_id': index + 1,
                'process_start_utc_ticks': index + 1,
                **receipts, 'metrics': {**metrics,
                    'cancel_first_corresponding_feedback_kind':
                        'intermediate-request-status' if index == 8 else 'not-measured',
                    'outcome': 'cancelled-rollback-unproven' if index == 8 else 'completed'}})
        return {'schema_version': 1, 'diagnostic': 'gui-apply-feedback-campaign-v1',
                'source_sha': source, 'runs': rows}, measured

    def test_nine_canonical_runs_and_median_dispositions(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            index, measured = self.payload(base)
            path = base / 'campaign.json'
            path.write_text(json.dumps(index), encoding='utf-8')
            with mock.patch.object(evidence, 'validate_gui_apply_run', side_effect=measured):
                report = evidence.validate_gui_apply_campaign_index(path, 'a' * 40)
            self.assertEqual(report['run_count'], 9)
            self.assertEqual(report['representative_count'], 6)
            self.assertEqual(report['representative_summaries']
                ['idle_close_to_exit_upper_ms']['median_ms'], 100.0)
            self.assertEqual(report['cancel_case_first_feedback_kind'],
                             'intermediate-request-status')
            self.assertEqual(report['cancel_case_intermediate_ack_upper_ms'], 100.0)
            self.assertEqual(report['p95'], 'not-estimated')

    def test_terminal_first_campaign_does_not_grade_intermediate_ack(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            index, measured = self.payload(base)
            measured[-1]['metrics'].update(
                cancel_first_corresponding_feedback_kind='terminal-cancel-status',
                cancel_intermediate_ack_upper_ms='not-observed')
            path = base / 'campaign.json'
            path.write_text(json.dumps(index), encoding='utf-8')
            with mock.patch.object(evidence, 'validate_gui_apply_run', side_effect=measured):
                report = evidence.validate_gui_apply_campaign_index(path, 'a' * 40)
            self.assertEqual(report['cancel_case_first_feedback_kind'],
                             'terminal-cancel-status')
            self.assertTrue(report['cancel_case_first_feedback_within_200_ms'])
            self.assertEqual(report['cancel_case_intermediate_ack_upper_ms'],
                             'not-observed')
            self.assertEqual(report['cancel_case_intermediate_ack_within_200_ms'],
                             'inconclusive')

    def test_discloses_values_range_and_goal_exceedances_without_sla_claim(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            index, measured = self.payload(base)
            values = (100.0, 210.0, 220.0, 230.0, 240.0, 250.0)
            for row, value in zip([measured[1], *measured[3:8]], values, strict=True):
                row['metrics']['apply_execution_feedback_upper_ms'] = value
            path = base / 'campaign.json'
            path.write_text(json.dumps(index), encoding='utf-8')
            with mock.patch.object(evidence, 'validate_gui_apply_run', side_effect=measured):
                report = evidence.validate_gui_apply_campaign_index(path, 'a' * 40)
            summary = report['representative_summaries']['apply_execution_feedback_upper_ms']
            self.assertEqual(summary['values_ms'], list(values))
            self.assertEqual(summary['range_ms'], [100.0, 250.0])
            self.assertEqual(summary['median_ms'], 225.0)
            self.assertEqual(summary['exceedance_runs'], [2, 3, 4, 5, 6])
            self.assertFalse(summary['median_within_goal'])

    def test_rejects_missing_duplicate_or_reordered_representatives(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            index, measured = self.payload(base)
            path = base / 'campaign.json'
            cases = (
                (lambda i, m: i['runs'].pop(3)),
                (lambda i, m: m[3].update(process_id=m[2]['process_id'],
                    process_start_utc_ticks=m[2]['process_start_utc_ticks'])),
                (lambda i, m: i['runs'][3].update(case='success-10000')),
                (lambda i, m: i['runs'][3].update(collection_sha256='0' * 64)),
                (lambda i, m: m[3].update(application_sha256='0' * 64)),
            )
            for change in cases:
                bad_index, bad_measured = deepcopy(index), deepcopy(measured)
                change(bad_index, bad_measured)
                path.write_text(json.dumps(bad_index), encoding='utf-8')
                with mock.patch.object(evidence, 'validate_gui_apply_run',
                                       side_effect=bad_measured):
                    with self.assertRaises(evidence.EvidenceError):
                        evidence.validate_gui_apply_campaign_index(path, 'a' * 40)


if __name__ == "__main__":
    unittest.main()
