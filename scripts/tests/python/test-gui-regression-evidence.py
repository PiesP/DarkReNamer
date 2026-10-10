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

from controller_cleanup_fixture import clean_controller_cleanup, clean_controller_cleanup_v2
from darkrenamer_tooling.evidence import gui as evidence
from gui_regression_fixture import (
    SCRIPT, SOURCE, TREE, digest, json_bytes, write_json, pair_png,
    physical_menu_apply_entry, scenario, Fixture,
)


class SyntheticFixtureTestCase(unittest.TestCase):
    def setUp(self):
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
        cleanup = clean_controller_cleanup_v2(profile_sha256=profile_hash, process_jobs=jobs)
        raw["process_lifecycles"] = lifecycles
        raw["process_job_cleanup"] = cleanup["owned_resource_evidence"]["process_job_cleanup"]
        raw["observer_lifecycle"] = cleanup["owned_resource_evidence"]["task_execution"]["observer_lifecycle"]
        write_json(raw_path, raw)
        transport_path = output / "transport.json"
        transport = json.loads(transport_path.read_text())
        transport["raw_cleanup"] = cleanup
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
        cleanup = clean_controller_cleanup_v2(profile_sha256=profile_hash, process_jobs=jobs)
        owned = cleanup["owned_resource_evidence"]
        raw["process_job_cleanup"] = owned["process_job_cleanup"]
        raw["observer_lifecycle"] = owned["task_execution"]["observer_lifecycle"]
        write_json(raw_path, raw)
        transport_path = self.pair_run / "output" / "transport.json"
        transport = json.loads(transport_path.read_text())
        transport["raw_cleanup"] = cleanup
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
        for field, value in (("profile_id", "unexpected-v2"), ("revision", 3)):
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

        cleanup = clean_controller_cleanup_v2(profile_sha256=profile_hash)
        owned = cleanup["owned_resource_evidence"]
        raw = {"process_job_cleanup": owned["process_job_cleanup"],
               "observer_lifecycle": owned["task_execution"]["observer_lifecycle"]}
        scenario = self.scenario()
        evidence.validate_icon_owned_transport({"raw_cleanup": cleanup}, manifest, raw, scenario)
        for mutate in (
                lambda r, s: s.__setitem__("process_start_utc_ticks", "134041000000000001"),
                lambda r, s: r.__setitem__("process_job_cleanup", []),
                lambda r, s: r.__setitem__("observer_lifecycle", {})):
            copied_raw, copied_scenario = deepcopy(raw), deepcopy(scenario)
            mutate(copied_raw, copied_scenario)
            with self.assertRaises(evidence.EvidenceError):
                evidence.validate_icon_owned_transport({"raw_cleanup": cleanup}, manifest,
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


if __name__ == "__main__":
    unittest.main()
