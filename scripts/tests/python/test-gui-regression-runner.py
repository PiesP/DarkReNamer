"""Offline contract tests for the tracked GUI regression runner."""

import hashlib
import importlib.util
import json
import os
import struct
import zlib
from pathlib import Path
import tempfile
import unittest
from contextlib import contextmanager
from types import SimpleNamespace
from unittest import mock

from darkrenamer_tooling.vm import gui as runner
from darkrenamer_tooling.evidence import png as evidence
from darkrenamer_tooling.formats import png as codec


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_chunk(kind, payload, *, checksum=None):
    if checksum is None:
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def png_bytes(width, height, color_type, filtered, *, compressed=None,
              before_idat=(), after_idat=(), include_iend=True,
              iend_payload=b"", trailing=b""):
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    payload = zlib.compress(filtered) if compressed is None else compressed
    result = PNG_SIGNATURE + png_chunk(b"IHDR", ihdr)
    result += b"".join(before_idat) + png_chunk(b"IDAT", payload) + b"".join(after_idat)
    if include_iend:
        result += png_chunk(b"IEND", iend_payload)
    return result + trailing


class GuiRegressionRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    @staticmethod
    def write_json(path, value):
        path.write_text(json.dumps(value) + "\n")

    def write_png(self, name, value):
        path = self.root / name
        path.write_bytes(value)
        return path

    def test_appearance_pair_selects_one_bounded_run_and_explicit_v1_profile(self):
        pair = runner.appearance_pair_run(1366, 768, 96)
        self.assertEqual(pair["mode"], "appearance-pair")
        self.assertEqual(pair["run_id"], runner.APPEARANCE_PAIR_ID)
        self.assertEqual(len(runner.RUNS), 4)
        with mock.patch.object(runner.shutil, "which", return_value="/usr/bin/pwsh"):
            command = runner.controller_command(
                self.root, self.root / "bundle", self.root / "pair", pair,
                {"ssh_host": "fixture-vm", "expected_vm_id": "fixture-id"},
                {"expectedGuestSid": "S-1-5-21-1-2-3-4"},
            )
        self.assertEqual(command[command.index("-AcceptanceMode") + 1], "appearance-pair")
        self.assertEqual(command[command.index("-AcceptanceProfileId") + 1],
                         "vm-automated-v1-win11-ntfs")
        self.assertEqual(command[command.index("-TestTimeoutSeconds") + 1], "600")

    def test_appearance_pair_v2_pins_profile_hash_in_controller_command(self):
        run_root = self.root / "pair"
        (run_root / "inputs").mkdir(parents=True)
        profile = b'{"schema":"darkrenamer-vm-automated-profile-v2"}\n'
        (run_root / "inputs" / runner.V2_PROFILE_FILE).write_bytes(profile)
        profile_hash = hashlib.sha256(profile).hexdigest()
        self.write_json(run_root / "input-manifest.json", {
            "acceptance_profile_id": runner.V2_PROFILE_ID,
            "acceptance_profile_sha256": profile_hash,
            "acceptance_profile": {"sha256": profile_hash},
        })
        pair = {**runner.appearance_pair_run(1366, 768, 96),
                "acceptance_profile_id": runner.V2_PROFILE_ID,
                "acceptance_profile_sha256": profile_hash}
        with mock.patch.object(runner.shutil, "which", return_value="/usr/bin/pwsh"):
            command = runner.controller_command(
                self.root, self.root / "bundle", run_root, pair,
                {"ssh_host": "fixture-vm", "expected_vm_id": "fixture-id"},
                {"expectedGuestSid": "S-1-5-21-1-2-3-4"},
            )
        self.assertEqual(command[command.index("-AcceptanceProfileId") + 1], runner.V2_PROFILE_ID)
        self.assertEqual(command[command.index("-AcceptanceProfileSha256") + 1], profile_hash)
        (run_root / "inputs" / runner.V2_PROFILE_FILE).write_bytes(profile + b" ")
        with mock.patch.object(runner.shutil, "which", return_value="/usr/bin/pwsh"):
            with self.assertRaisesRegex(ValueError, "immutable staged manifest"):
                runner.controller_command(
                    self.root, self.root / "bundle", run_root, pair,
                    {"ssh_host": "fixture-vm", "expected_vm_id": "fixture-id"},
                    {"expectedGuestSid": "S-1-5-21-1-2-3-4"},
                )

    def test_v2_profile_is_pair_only(self):
        with self.assertRaisesRegex(ValueError, "requires --diagnostic appearance-pair"):
            runner.main(self.root, ["--connection-profile", str(self.root / "missing.json"),
                                    "--output-root", str(self.root / "unused"),
                                    "--acceptance-profile-id", runner.V2_PROFILE_ID])

    def test_focused_manifest_command_replays_without_desktop_overrides(self):
        inputs = {"bundle_manifest": {}, "artifacts": {}, "source_sha": "a" * 40,
                  "source_tree": "b" * 40}
        with mock.patch.object(runner, "run_input_artifacts", return_value=({}, inputs)):
            manifest = runner.input_manifest(self.root, self.root / "bundle", self.root / "run",
                                             runner.FOCUSED_PAIR_RUNS[0], "c" * 64, {}, {})
        command = manifest["command"]
        self.assertEqual(command[command.index("--configuration-set") + 1], "focused")
        self.assertNotIn("--desktop-width", command)
        self.assertNotIn("--desktop-height", command)
        self.assertNotIn("--desktop-dpi", command)

    def test_focused_pair_configurations_reuse_one_bounded_run_shape(self):
        runs = runner.FOCUSED_PAIR_RUNS
        self.assertEqual(len(runs), 5)
        self.assertEqual(len({row["run_id"] for row in runs}), 5)
        self.assertEqual([(row["dpi"], row["text_scale_percent"], row["high_contrast"])
                          for row in runs],
                         [(96, 100, False), (144, 100, False), (192, 100, False),
                          (96, 150, False), (96, 100, True)])
        self.assertTrue(all((row["width"], row["height"]) == (1920, 1080) for row in runs))
        self.assertEqual(runs[-1]["appearance"], "system")
        with mock.patch.object(runner.shutil, "which", return_value="/usr/bin/pwsh"):
            command = runner.controller_command(
                self.root, self.root / "bundle", self.root / "forced", runs[-1],
                {"ssh_host": "fixture-vm", "expected_vm_id": "fixture-id"},
                {"expectedGuestSid": "S-1-5-21-1-2-3-4"},
            )
        self.assertIn("-AcceptanceHighContrast", command)
        self.assertEqual(command[command.index("-AcceptanceAppearance") + 1], "system")
        self.assertEqual(command[command.index("-AcceptanceTextScalePercent") + 1], "100")

    def test_focused_pair_manifest_records_replayable_set_selection(self):
        run = runner.FOCUSED_PAIR_RUNS[0]
        inputs = {"source_sha": "a" * 40, "source_tree": "b" * 40,
                  "bundle_manifest": {"sha256": "c" * 64}, "artifacts": {}}
        with mock.patch.object(runner, "run_input_artifacts", return_value=({}, inputs)):
            manifest = runner.input_manifest(
                self.root, self.root, self.root, run, "d" * 64, {}, {},
            )
        self.assertEqual(manifest["command"].count("--configuration-set"), 1)
        self.assertEqual(manifest["command"][-2:], ["--configuration-set", "focused"])
        self.assertNotIn("--desktop-width", manifest["command"])
        self.assertNotIn("--desktop-height", manifest["command"])
        self.assertNotIn("--desktop-dpi", manifest["command"])

    def test_consumer_policies_preserve_formats_alpha_and_axis_limits(self):
        grayscale = png_bytes(1, 1, 0, b"\0\x12")
        self.assertEqual(evidence.decode_png(grayscale, "gray"), (1, 1, b"\x12\x12\x12\xff"))
        with self.assertRaisesRegex(ValueError, "fixed raster contract"):
            runner.decode_png(self.write_png("gray.png", grayscale))
        transparent = png_bytes(2, 1, 6, b"\0\x12\x34\x56\xff\x12\x34\x56\x00")
        self.assertEqual(runner.decode_png(self.write_png("alpha.png", transparent))[2][-1], 0)
        with self.assertRaisesRegex(evidence.EvidenceError, "non-opaque"):
            evidence.decode_png(transparent, "alpha")
        wide = png_bytes(8193, 1, 0, b"\0" + b"\x12" * 8193)
        self.assertEqual(evidence.decode_png(wide, "wide")[:2], (8193, 1))
        wide_rgb = png_bytes(8193, 1, 2, b"\0" + b"\x12" * (8193 * 3))
        with mock.patch.object(codec.zlib, "decompressobj") as inflate:
            with self.assertRaisesRegex(ValueError, "fixed raster contract"):
                runner.decode_png(self.write_png("wide.png", wide_rgb))
            inflate.assert_not_called()

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

    def test_apply_entry_accepts_only_observed_public_entry_variants(self):
        rail = {"input": "visible-command-rail", "menu_entry": None}
        file_element = {
            "automation_id": "menu", "name": "파일(F)", "control_type": "ControlType.MenuItem",
            "enabled": True, "keyboard_focusable": True, "offscreen": False,
            "native_handle": 0,
            "bounds": {"x": 10.0, "y": 20.0, "width": 100.0, "height": 30.0},
        }
        apply_element = {**file_element, "name": "변경 사항 적용"}
        target = {"x": 60, "y": 35, "hit_window": 101, "root_window": 202}
        menu = {
            "input": "physical-mouse-file-menu-public-apply",
            "menu_entry": {
                "file": file_element, "file_target": target,
                "apply": apply_element, "apply_target": dict(target),
            },
        }
        for entry in (rail, menu):
            self.assertTrue(runner.valid_apply_entry(entry), entry)

        invalid = [
            {"input": "visible-command-rail", "menu_entry": {}},
            {"input": "physical-mouse-file-menu-public-apply", "menu_entry": None},
            {"input": "physical-mouse", "menu_entry": "public-apply"},
            {"input": "keyboard-ctrl-s-with-visible-listview-infotip", "menu_entry": None},
            {**rail, "extra": True},
            {**menu, "menu_entry": {**menu["menu_entry"], "extra": True}},
            {**menu, "menu_entry": {**menu["menu_entry"], "file_target": {
                **target, "x": 111,
            }}},
            {**menu, "menu_entry": {**menu["menu_entry"], "apply": {
                **apply_element, "enabled": False,
            }}},
            {**menu, "menu_entry": {**menu["menu_entry"], "apply_target": {
                **target, "hit_window": True,
            }}},
        ]
        for entry in invalid:
            self.assertFalse(runner.valid_apply_entry(entry), entry)

    def test_visible_control_accepts_finite_uia_double_bounds_only_inside_work_area(self):
        work_area = {"left": 0, "top": 0, "right": 800, "bottom": 552}

        def tree(bounds):
            return [{
                "automation_id": "CommandLink_1101", "enabled": True, "offscreen": False,
                "bounds": bounds,
            }]

        integral = {"x": 203.0, "y": 411.0, "width": 478.0, "height": 41.0}
        fractional = {"x": 203.25, "y": 410.5, "width": 478.5, "height": 41.25}
        self.assertTrue(runner.visible_control(tree(integral), "CommandLink_1101", work_area))
        self.assertTrue(runner.visible_control(tree(fractional), "CommandLink_1101", work_area))
        for invalid in (
            {**integral, "x": True},
            {**integral, "width": float("inf")},
            {**integral, "height": float("nan")},
            {**integral, "width": 0.0},
            {**integral, "x": -0.25},
            {**integral, "y": 540.0, "height": 12.25},
        ):
            self.assertFalse(
                runner.visible_control(tree(invalid), "CommandLink_1101", work_area),
                invalid,
            )

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
        observations = {
            "environment": {
                "hwnd_dpi": 96, "text_scale_factor_percent": 100,
                "physical_screen": {"left": 0, "top": 0, "right": 800, "bottom": 600, "width": 800, "height": 600},
                "work_area": {"left": 0, "top": 0, "right": 800, "bottom": 552, "width": 800, "height": 552},
            },
        }
        self.write_json(output / "acceptance-observations.json", observations)
        self.write_json(output / "acceptance-result.json", {
            "status": "review_required",
            "assertions": {
                "overall": "passed",
                "scenario": {
                    "appearance": "light",
                    "semantic_assertions": {
                        name: True for name in runner.MODE_SEMANTICS["standard"]
                    },
                },
            },
            "guest_cleanup": True,
            "acceptance_observations": observations,
            "observations": {
                "file": "acceptance-observations.json",
                "sha256": runner.digest(output / "acceptance-observations.json"),
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
        self.assertEqual(result["actual"]["appearance"], "light")

    def test_pair_collection_requires_all_69_original_captures(self):
        run_root = self.root / runner.APPEARANCE_PAIR_ID
        output = run_root / "output"
        output.mkdir(parents=True)
        for index in range(69):
            (output / f"capture-{index:02}.png").write_bytes(b"original-fixture")
        self.assertEqual(len(runner.collection_document(run_root, "a" * 64, runner.APPEARANCE_PAIR_ID)["files"]), 69)
        (output / "capture-65.png").unlink()
        with self.assertRaisesRegex(ValueError, "exactly 69 original PNGs"):
            runner.collection_document(run_root, "a" * 64, runner.APPEARANCE_PAIR_ID)

    def test_focused_forced_colors_requires_three_additional_captures(self):
        run_id = runner.FOCUSED_PAIR_RUNS[-1]["run_id"]
        run_root = self.root / run_id
        output = run_root / "output"
        output.mkdir(parents=True)
        for index in range(72):
            (output / f"capture-{index:02}.png").write_bytes(b"original-fixture")
        self.assertEqual(len(runner.collection_document(run_root, "a" * 64, run_id)["files"]), 72)
        (output / "capture-68.png").unlink()
        with self.assertRaisesRegex(ValueError, "exactly 72 original PNGs"):
            runner.collection_document(run_root, "a" * 64, run_id)

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

        with mock.patch.object(runner, "source_identity", return_value=(source, "b" * 40)), \
                mock.patch.object(runner, "staged_tooling_files", return_value=[]):
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
            observations = {
                "environment": {"text_scale_factor_percent": 100},
            }
            self.write_json(output / "acceptance-observations.json", observations)
            self.write_json(output / "acceptance-result.json", {
                "status": "review_required", "guest_cleanup": True,
                "acceptance_observations": observations,
                "observations": {
                    "file": "acceptance-observations.json",
                    "sha256": runner.digest(output / "acceptance-observations.json"),
                },
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

    def test_cleanup_summary_requires_all_resource_results_independent_of_controller_exit(self):
        cases = (
            ("all-clean", True, True, True, 0, "passed"),
            ("fixture-failed", False, True, True, 0, "failed"),
            ("process-failed", True, False, True, 0, "failed"),
            ("process-unreported", True, None, True, 0, "failed"),
            ("guest-failed", True, True, False, 0, "failed"),
            ("transport-missing", True, True, None, 0, "failed"),
            ("operation-failed-resources-clean", True, True, True, 1, "passed"),
        )
        for name, fixture, process, guest, exit_code, expected_status in cases:
            with self.subTest(name=name):
                run_root = self.root / name
                run_root.mkdir()
                output = run_root / "output"
                self.write_json(run_root / "input-manifest.json", {"run_id": name})

                @contextmanager
                def desktop(_arguments):
                    yield {"expectedGuestSid": "S-1-5-21-1-2-3-4"}

                def controller(*_arguments, **_keywords):
                    self.write_json(output / "acceptance-observations.json", {
                        "environment": {"text_scale_factor_percent": 100},
                    })
                    self.write_json(output / "acceptance-result.json", {
                        "guest_cleanup": fixture, "process_cleanup": process,
                    })
                    if guest is not None:
                        self.write_json(output / "transport.json", {"guest_cleanup": guest})
                    return SimpleNamespace(returncode=exit_code)

                with mock.patch.object(runner, "controller_command", return_value=["controller"]), \
                        mock.patch.object(runner.subprocess, "run", side_effect=controller), \
                        mock.patch.object(runner, "finalize_run") as finalize:
                    arguments = (
                        self.root, self.root, run_root,
                        {"run_id": name, "mode": "full-context", "text_scale_percent": 100,
                         "dpi": 96, "width": 800, "height": 600},
                        {"ssh_host": "fixture", "desktop_helper": "C:\\fixture.ps1"},
                        SimpleNamespace(managed_desktop=desktop),
                    )
                    if exit_code:
                        with self.assertRaisesRegex(ValueError, "transport failed"):
                            runner.execute_run(*arguments)
                        finalize.assert_not_called()
                    else:
                        runner.execute_run(*arguments)
                        finalize.assert_called_once_with(run_root)
                cleanup = json.loads((output / "cleanup.json").read_text())
                self.assertEqual(cleanup["status"], expected_status)
                self.assertEqual(cleanup["controller_exit_code"], exit_code)
                self.assertEqual(cleanup["fixture"], fixture)
                self.assertEqual(cleanup["process"], process is True)
                self.assertEqual(cleanup["guest"], guest is True)
                self.assertTrue(cleanup["desktop_restore"])
                self.assertTrue(cleanup["text_scale_restore"])

    def test_four_finalized_producer_fixtures_pass_independent_validator_cli(self):
        default = Path(__file__).with_name("test-gui-regression-evidence.py")
        fixture_script = Path(os.environ.get("GUI_REGRESSION_EVIDENCE_TEST", default))
        self.assertTrue(fixture_script.is_file(), "independent evidence fixture script is required")
        spec = importlib.util.spec_from_file_location("gui_evidence_fixture", fixture_script)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        evidence_fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(evidence_fixture)
        validator = evidence_fixture.SCRIPT
        self.assertTrue(validator.is_file(), "independent evidence validator is required")
        runs_root = self.root / "runs"
        runs_root.mkdir()
        fixture = evidence_fixture.Fixture(runs_root)

        def finalize(run_root):
            output = run_root / "output"
            observations = json.loads((output / "acceptance-observations.json").read_text())
            environment = dict(observations["scenario"]["environment"])
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
            result_path = output / "acceptance-result.json"
            protected_result = json.loads(result_path.read_text())
            protected_result["acceptance_observations"] = observations
            protected_result["observations"] = {
                "file": "acceptance-observations.json",
                "sha256": runner.digest(output / "acceptance-observations.json"),
            }
            self.write_json(result_path, protected_result)
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
            runner.validate_all(validator.parent.parent, runs_root, self.root)
        report = json.loads((self.root / "validation-result.json").read_text())
        self.assertEqual(report["status"], "passed")
        self.assertEqual(
            [row["run_id"] for row in report["runs"]],
            [path.name for path in (full, standard, text_scale, tooltip)],
        )


if __name__ == "__main__":
    unittest.main()
