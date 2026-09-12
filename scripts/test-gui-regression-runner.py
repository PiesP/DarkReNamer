"""Offline contract tests for the tracked GUI regression runner."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from types import SimpleNamespace
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "gui_regression", Path(__file__).with_name("run-gui-regression.py")
)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class GuiRegressionRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    @staticmethod
    def write_json(path, value):
        path.write_text(json.dumps(value) + "\n")

    def test_four_runs_are_fixed_and_ordered_for_reference_resolution(self):
        self.assertEqual(
            [(row["mode"], row["width"], row["height"], row["dpi"], row["text_scale_percent"])
             for row in runner.RUNS],
            [
                ("full-context", 800, 600, 96, 100),
                ("standard", 800, 600, 96, 100),
                ("text-scale", 800, 600, 96, 150),
                ("tooltip", 1366, 768, 144, 100),
            ],
        )

    def test_private_profile_is_explicit_bounded_and_not_returned_with_its_path(self):
        profile = self.root / "connection.json"
        value = {
            "schema_version": 1,
            "ssh_host": "vm-alias",
            "desktop_helper": "C:\\Private\\desktop-session.ps1",
            "expected_vm_id": "12345678-1234-5678-9abc-1234567890ab",
        }
        self.write_json(profile, value)
        loaded, profile_hash = runner.load_connection_profile(profile)
        self.assertEqual(loaded, value)
        self.assertEqual(profile_hash, runner.digest(profile))
        self.assertNotIn(str(profile), json.dumps(loaded))

        for key, changed in (
            ("extra", {**value, "extra": True}),
            ("alias", {**value, "ssh_host": "user@vm"}),
            ("helper", {**value, "desktop_helper": "relative.ps1"}),
            ("identity", {**value, "expected_vm_id": "not-a-guid"}),
        ):
            invalid = self.root / f"invalid-{key}.json"
            self.write_json(invalid, changed)
            with self.assertRaises(ValueError):
                runner.load_connection_profile(invalid)

    def test_guest_preflight_serializes_strict_document_inside_remote_boundary(self):
        profile = {
            "ssh_host": "vm-alias",
            "expected_vm_id": "12345678-1234-5678-9abc-1234567890ab",
        }
        remote = {
            "system": "windows",
            "os_version": "Microsoft Windows NT 10.0.26200.0",
            "build": "26200",
            "architecture": "X64",
            "product_caption": "Microsoft Windows 11 Pro",
            "vm_id": profile["expected_vm_id"],
        }

        def check_output(command, **keywords):
            script = command[-1]
            remote_boundary = script.index("\n    }\n    [Console]::Out.Write")
            self.assertLess(script.index("| ConvertTo-Json -Compress"), remote_boundary)
            self.assertNotIn("$value | ConvertTo-Json", script)
            self.assertEqual(keywords["env"]["DARKRENAMER_GUI_SSH_HOST"], "vm-alias")
            return json.dumps(remote, separators=(",", ":"))

        with mock.patch.object(runner.shutil, "which", return_value="/usr/bin/pwsh"), \
                mock.patch.object(runner.subprocess, "check_output", side_effect=check_output):
            observed = runner.guest_preflight(profile)
        self.assertEqual(observed["system"], "windows")
        self.assertEqual(observed["build"], "26200")
        self.assertEqual(observed["architecture"], "x86_64")
        self.assertEqual(
            observed["vm_identity_sha256"], runner.digest_text(profile["expected_vm_id"])
        )

    def test_guest_preflight_rejects_remoting_metadata(self):
        remote = {
            "system": "windows",
            "os_version": "Microsoft Windows NT 10.0.26200.0",
            "build": "26200",
            "architecture": "X64",
            "product_caption": "Microsoft Windows 11 Pro",
            "vm_id": "12345678-1234-5678-9abc-1234567890ab",
            "PSComputerName": "private-host",
            "RunspaceId": "00000000-0000-0000-0000-000000000000",
            "PSShowComputerName": True,
        }
        with mock.patch.object(runner.shutil, "which", return_value="/usr/bin/pwsh"), \
                mock.patch.object(runner.subprocess, "check_output", return_value=json.dumps(remote)):
            with self.assertRaisesRegex(ValueError, "invalid document"):
                runner.guest_preflight({
                    "ssh_host": "vm-alias",
                    "expected_vm_id": "12345678-1234-5678-9abc-1234567890ab",
                })

    def test_reference_pins_input_and_final_result_with_one_fixed_scope(self):
        run_root = self.root / runner.RUNS[0]["run_id"]
        (run_root / "output").mkdir(parents=True)
        self.write_json(run_root / "input-manifest.json", {
            "run_id": runner.RUNS[0]["run_id"],
            "request": {"mode": "full-context"},
        })
        self.write_json(run_root / "output" / "run-result.json", {"status": "review_required"})
        reference = runner.reference_for(run_root)
        self.assertEqual(reference["scope"], ["full-context-semantics-v1"])
        self.assertEqual(reference["input_manifest_sha256"], runner.digest(run_root / "input-manifest.json"))
        self.assertEqual(reference["result_sha256"], runner.digest(run_root / "output" / "run-result.json"))

    def test_finalize_uses_acyclic_input_raw_cleanup_collection_result_order(self):
        run_root = self.root / "run"
        output = run_root / "output"
        output.mkdir(parents=True)
        manifest = {
            "schema_version": 1,
            "run_id": "run",
            "source_sha": "a" * 40,
            "host_preflight": {"system": "linux", "release": "test", "architecture": "x86_64"},
            "request": {"mode": "standard"},
            "artifacts": {
                key: {"sha256": character * 64}
                for key, character in (("application", "b"), ("runner", "c"), ("observer", "d"))
            },
        }
        self.write_json(run_root / "input-manifest.json", manifest)
        input_hash = runner.digest(run_root / "input-manifest.json")
        self.write_json(output / "acceptance-result.json", {
            "status": "review_required",
            "assertions": {
                "overall": "passed",
                "scenario": {"semantic_assertions": {
                    name: True for name in runner.MODE_SEMANTICS["standard"]
                }},
            },
            "guest_cleanup": True,
        })
        self.write_json(output / "acceptance-observations.json", {
            "environment": {
                "appearance": "light", "hwnd_dpi": 96, "text_scale_factor_percent": 100,
                "physical_screen": {"left": 0, "top": 0, "right": 800, "bottom": 600, "width": 800, "height": 600},
                "work_area": {"left": 0, "top": 0, "right": 800, "bottom": 552, "width": 800, "height": 552},
            },
        })
        self.write_json(output / "platform-preflight.json", {
            "guest_platform": {"system": "windows", "os_version": "10.0", "build": "1", "architecture": "x86_64"},
        })
        self.write_json(output / "cleanup.json", {
            "input_manifest_sha256": input_hash,
            "status": "passed",
        })
        self.write_json(output / "transport.json", {
            "observer_process": {"state": "exited", "exit_code": 0},
        })
        with mock.patch.object(
            runner, "project_raw_semantics",
            return_value={name: True for name in runner.MODE_SEMANTICS["standard"]},
        ):
            runner.finalize_run(run_root)
        collection = json.loads((run_root / "collection.json").read_text())
        paths = {row["relative_path"] for row in collection["files"]}
        self.assertIn("cleanup.json", paths)
        self.assertNotIn("run-result.json", paths)
        result = json.loads((output / "run-result.json").read_text())
        self.assertEqual(result["input_manifest_sha256"], input_hash)
        self.assertEqual(result["collection_sha256"], runner.digest(run_root / "collection.json"))
        self.assertEqual(result["cleanup_sha256"], runner.digest(output / "cleanup.json"))

    def test_collection_rejects_symlinked_output(self):
        run_root = self.root / "symlink"
        output = run_root / "output"
        output.mkdir(parents=True)
        outside = self.root / "outside"
        outside.write_text("outside")
        (output / "link").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            runner.collection_document(run_root, "a" * 64, "symlink")

    def test_semantic_projection_requires_exact_true_raw_mode_fields(self):
        expected = runner.MODE_SEMANTICS["standard"]
        raw = {
            "overall": "passed",
            "scenario": {"semantic_assertions": {name: True for name in expected}},
        }
        self.assertEqual(
            runner.semantic_assertions(raw, "standard", raw["scenario"]["semantic_assertions"]),
            {"overall": "passed", "semantics": {name: True for name in sorted(expected)}},
        )
        raw["scenario"]["semantic_assertions"][next(iter(expected))] = False
        with self.assertRaisesRegex(ValueError, "incomplete or failed"):
            runner.semantic_assertions(raw, "standard", raw["scenario"]["semantic_assertions"])

    def test_materialized_inputs_are_run_relative_and_byte_bound(self):
        source = self.root / "source"
        source.mkdir()
        files = {}
        for name in (
            "bundle.json", "DarkReNamer.exe", "windows-vm-guest.ps1",
            "windows-vm-acceptance.ps1", "run-gui-regression.py",
            "run-windows-vm-tests.ps1", "Cargo.lock", "test-windows-vm.py",
        ):
            path = source / name
            path.write_bytes(name.encode())
            files[name] = path
        run_root = self.root / "run-inputs"
        run_root.mkdir()
        rows = runner.materialize_inputs(run_root, files)
        self.assertEqual(set(rows), set(files))
        for name, row in rows.items():
            self.assertEqual(row["file"], f"inputs/{name}")
            self.assertEqual(row["sha256"], hashlib.sha256(name.encode()).hexdigest())
            self.assertEqual((run_root / row["file"]).read_bytes(), name.encode())

    def test_runtime_inputs_preserve_and_verify_complete_native_bundle(self):
        repo = self.root / "repo"
        bundle = self.root / "bundle"
        (repo / "scripts").mkdir(parents=True)
        bundle.mkdir()
        for relative in (
            "scripts/windows-vm-acceptance.ps1", "scripts/run-gui-regression.py",
            "scripts/run-windows-vm-tests.ps1", "scripts/test-windows-vm.py", "Cargo.lock",
        ):
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode())
        for name in ("DarkReNamer.exe", "windows-vm-guest.ps1", "darkrenamer-core-tests.exe"):
            (bundle / name).write_bytes(name.encode())
        source = "a" * 40
        manifest = {
            "schema_version": 1,
            "source_sha": source,
            "source_state": "clean",
            "cargo_lock_sha256": runner.digest(repo / "Cargo.lock"),
            "application": runner.artifact(bundle / "DarkReNamer.exe"),
            "runner": runner.artifact(bundle / "windows-vm-guest.ps1"),
            "test_binaries": [runner.artifact(bundle / "darkrenamer-core-tests.exe")],
        }
        self.write_json(bundle / "bundle.json", manifest)

        with mock.patch.object(runner, "source_identity", return_value=(source, "b" * 40)):
            run_root = self.root / "complete"
            run_root.mkdir()
            runner.run_input_artifacts(repo, bundle, run_root)
            copied = run_root / "inputs" / "darkrenamer-core-tests.exe"
            self.assertEqual(copied.read_bytes(), b"darkrenamer-core-tests.exe")

            (bundle / "darkrenamer-core-tests.exe").unlink()
            missing_root = self.root / "missing"
            missing_root.mkdir()
            with self.assertRaisesRegex(ValueError, "ordinary file"):
                runner.run_input_artifacts(repo, bundle, missing_root)

            (bundle / "darkrenamer-core-tests.exe").write_bytes(b"tampered")
            tampered_root = self.root / "tampered"
            tampered_root.mkdir()
            with self.assertRaisesRegex(ValueError, "hash differs"):
                runner.run_input_artifacts(repo, bundle, tampered_root)

    def test_controller_streams_are_captured_outside_empty_output_then_collected(self):
        run_root = self.root / "stream-run"
        output = run_root / "output"
        run_root.mkdir()
        self.write_json(run_root / "input-manifest.json", {"run_id": "stream-run"})

        @contextmanager
        def desktop(_arguments):
            yield {"expectedGuestSid": "S-1-5-21-1-2-3-4"}

        native_runner = SimpleNamespace(managed_desktop=desktop)

        def controller(*_arguments, **keywords):
            self.assertEqual(list(output.iterdir()), [])
            keywords["stdout"].write("controller stdout\n")
            keywords["stderr"].write("controller stderr\n")
            self.write_json(output / "acceptance-result.json", {
                "status": "review_required", "guest_cleanup": True,
            })
            self.write_json(output / "acceptance-observations.json", {
                "environment": {"text_scale_factor_percent": 100},
            })
            self.write_json(output / "transport.json", {
                "status": "collected", "guest_cleanup": True,
                "observer_process": {"state": "exited", "exit_code": 0},
            })
            return SimpleNamespace(returncode=0)

        with mock.patch.object(runner, "controller_command", return_value=["controller"]), \
                mock.patch.object(runner.subprocess, "run", side_effect=controller), \
                mock.patch.object(runner, "finalize_run"):
            runner.execute_run(
                self.root, self.root, run_root,
                {"run_id": "stream-run", "mode": "full-context", "text_scale_percent": 100,
                 "dpi": 96, "width": 800, "height": 600},
                {"ssh_host": "fixture", "desktop_helper": "C:\\fixture.ps1"}, native_runner,
            )
        self.assertEqual((output / "controller.stdout.txt").read_text(), "controller stdout\n")
        self.assertEqual((output / "controller.stderr.txt").read_text(), "controller stderr\n")
        cleanup = json.loads((output / "cleanup.json").read_text())
        self.assertTrue(cleanup["desktop_restore"])
        self.assertEqual(cleanup["controller_exit_code"], 0)

    def test_four_finalized_producer_fixtures_pass_independent_validator_cli(self):
        default = Path(__file__).with_name("test-gui-regression-evidence.py")
        fixture_script = Path(os.environ.get("GUI_REGRESSION_EVIDENCE_TEST", default))
        validator = fixture_script.with_name("validate-gui-regression-evidence.py")
        self.assertTrue(fixture_script.is_file(), "independent evidence fixture script is required")
        self.assertTrue(validator.is_file(), "independent evidence validator is required")
        spec = importlib.util.spec_from_file_location("gui_evidence_fixture", fixture_script)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        evidence_fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(evidence_fixture)
        runs_root = self.root / "runs"
        runs_root.mkdir()
        fixture = evidence_fixture.Fixture(runs_root)

        def finalize(run_root):
            output = run_root / "output"
            observations = json.loads((output / "acceptance-observations.json").read_text())
            environment = dict(observations["scenario"]["environment"])
            environment["appearance"] = observations["scenario"]["appearance"]
            target = json.loads((output / "platform-postlaunch.json").read_text())["target"]
            environment["main_window"] = {
                "hwnd": target["hwnd"],
                "process_id": target["process_id"],
                "rect": target["window_rect"],
                "target_monitor": environment["physical_screen"],
                "target_work_area": environment["work_area"],
            }
            observations["environment"] = environment
            self.write_json(output / "acceptance-observations.json", observations)
            mode = json.loads((run_root / "input-manifest.json").read_text())["request"]["mode"]
            if mode in {"standard", "text-scale"}:
                (output / "text-raster-metrics.json").unlink()
                runner.write_text_raster_metrics(run_root)
            raw_hashes = {
                name: runner.digest(output / name)
                for name in ("acceptance-result.json", "acceptance-observations.json")
            }
            (run_root / "collection.json").unlink()
            (output / "run-result.json").unlink()
            runner.finalize_run(run_root)
            self.assertEqual(raw_hashes, {
                name: runner.digest(output / name)
                for name in ("acceptance-result.json", "acceptance-observations.json")
            })
            return run_root

        full = finalize(fixture.build(runner.RUNS[0]["run_id"], "full-context"))
        standard = finalize(fixture.build(runner.RUNS[1]["run_id"], "standard"))
        tampered = json.loads((standard / "output" / "acceptance-result.json").read_text())
        tampered["assertions"]["scenario"]["actual_apply"]["scope"] = "fabricated"
        cleanup = json.loads((standard / "output" / "cleanup.json").read_text())
        with self.assertRaisesRegex(ValueError, "does not support semantic assertions"):
            runner.project_raw_semantics(tampered, cleanup, standard, "standard")
        transport_path = standard / "output" / "transport.json"
        original_transport = transport_path.read_bytes()
        transport = json.loads(original_transport)
        transport["observer_process"]["exit_code"] = 7
        self.write_json(transport_path, transport)
        with self.assertRaisesRegex(ValueError, "nonzero exit code"):
            runner.normalize_run_result(
                standard, runner.digest(standard / "input-manifest.json")
            )
        transport["observer_process"]["exit_code"] = True
        self.write_json(transport_path, transport)
        with self.assertRaisesRegex(ValueError, "actual terminal observer"):
            runner.normalize_run_result(
                standard, runner.digest(standard / "input-manifest.json")
            )
        transport_path.write_bytes(original_transport)
        text_scale = finalize(fixture.build(runner.RUNS[2]["run_id"], "text-scale"))
        tooltip = finalize(fixture.build(
            runner.RUNS[3]["run_id"], "tooltip", reference=runner.reference_for(full)
        ))
        with mock.patch.object(
            runner, "source_identity", return_value=(evidence_fixture.SOURCE, evidence_fixture.TREE)
        ):
            runner.validate_all(fixture_script.parent.parent, runs_root, self.root)
        report = json.loads((self.root / "validation-result.json").read_text())
        self.assertEqual(report["status"], "passed")
        self.assertEqual(
            [row["run_id"] for row in report["runs"]],
            [path.name for path in (full, standard, text_scale, tooltip)],
        )


if __name__ == "__main__":
    unittest.main()
