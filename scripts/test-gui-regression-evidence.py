#!/usr/bin/env python3
"""Offline negative fixtures for GUI regression evidence validation."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib


SCRIPT = Path(__file__).with_name("validate-gui-regression-evidence.py")
SPEC = importlib.util.spec_from_file_location("gui_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)

SOURCE = "a" * 40
TREE = "b" * 40


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def write_json(path: Path, value: object) -> None:
    path.write_bytes(json_bytes(value))


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def png(width: int = 80, height: int = 30, ink_height: int = 8, ink_width: int = 20,
        *, transparent: bool = False) -> bytes:
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            ink = 10 <= x < 10 + ink_width and 5 <= y < 5 + ink_height
            alpha = 0 if transparent and x == 0 and y == 0 else 255
            pixels.extend((0, 0, 0, alpha) if ink else (255, 255, 255, alpha))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", zlib.compress(bytes(pixels))) + png_chunk(b"IEND", b"")


def scenario(mode: str) -> dict:
    if mode == "full-context":
        def confirmation() -> dict:
            return {
                "scope_exact": True,
                "default_focus": {"is_default_cancel": True},
                "reachability": {name: {"status": "reachable", "inside_work_area": True,
                                        "physical_mouse_target": {"hit_window": 42}}
                                 for name in ("cancel", "apply", "full_details", "expander")},
                "full_details": {
                    "canonical_text": {"exact_document": True},
                    "native_end_scroll": {"ending_visible": True},
                    "return_default_cancel": {"is_default_cancel": True},
                },
            }
        return {
            "repeated": {
                "inputs_in_admission_order": ["0 x101 -> 0 x100", "a x100 -> a x101", "가 x100 -> 가 x101"],
                "zero_deletion_and_a_insertion_confirmation": confirmation(),
                "korean_insertion_confirmation": confirmation(),
                "cancellation_disk_unchanged": True,
                "journal_residue_count": 0,
                "normal_exit_code": 0,
            },
            "movement": {
                "cancellation_confirmation": {"cancellation": {
                    "input": "keyboard-escape", "returned_to_preview": True,
                    "default_cancel_preserved": True,
                }},
                "cancellation_disk_unchanged": True,
                "actual_apply": {
                    "input": "physical-mouse", "destination_reached": True,
                    "content_preserved": True, "identity_preserved": True,
                    "reachability": {"status": "reachable", "inside_work_area": True,
                                     "physical_mouse_target": {"hit_window": 42}},
                    "journal_residue_count": 0,
                },
                "normal_exit_code": 0,
            },
            "mixed": {
                "confirmation": {},
                "two_of_three_examples_exclude_third_move": True,
                "third_destination_diagnostic": {
                    "presentation": "read-only-multiline-edit",
                    "canonical_text": {"exact_document": True},
                    "native_end_scroll": {"ending_visible": True},
                    "close": {"closed": True},
                },
                "reentry_confirmation": {
                    "scope_exact": True,
                    "reachability": {name: {"status": "reachable", "inside_work_area": True,
                                            "physical_mouse_target": {"hit_window": 42}}
                                     for name in ("cancel", "apply", "full_details", "expander")},
                    "full_details": {
                        "canonical_text": {"exact_document": True},
                        "native_end_scroll": {"ending_visible": True},
                        "return_default_cancel": {"is_default_cancel": True},
                    },
                    "expanded": {"bottom_scroll": {
                        "status": "physically-scrolled-to-native-bottom",
                        "range_value": {"reached_maximum": True},
                    }},
                    "cancellation": {"input": "keyboard-escape", "returned_to_preview": True,
                                     "default_cancel_preserved": True},
                },
                "default_enter_cancellation": {
                    "input": "keyboard-enter-on-default-cancel",
                    "default_focus": {"is_default_cancel": True},
                    "cancellation": {"input": "keyboard-enter", "returned_to_preview": True,
                                     "default_cancel_preserved": True},
                    "disk_unchanged": True,
                    "journal_residue_count": 0,
                },
                "expanded_plan_identity_stable": True,
                "cancellation_disk_unchanged": True,
                "journal_residue_count": 0,
                "normal_exit_code": 0,
            },
        }
    if mode in {"standard", "text-scale"}:
        result = {
            "environment": {"text_scale_factor_percent": 150 if mode == "text-scale" else 100},
            "fixture": {"count": 3, "selected": 1, "changed": 2},
            "selection": {"selected_count": 1},
            "confirmation": {
                "scope_3_1_2": True,
                "default_focus": {"is_default_cancel": True},
                "tree": [{"automation_id": control_id, "enabled": True, "offscreen": False,
                          "bounds": {"x": 10, "y": 10, "width": 40, "height": 20}}
                         for control_id in ("CommandLink_1101", "CommandLink_1102",
                                            "ExpandoButton", "CommandButton_2")],
                "full_details": {
                    "canonical_text": {"exact_document": True},
                    "copy_contention": {"details_handle_preserved": True},
                    "copy_all_retry": {"exact": True},
                    "native_end_scroll": {"ending_visible": True},
                    "escape_return_default_cancel": {"is_default_cancel": True},
                },
                "cancellation": {"input": "keyboard-escape", "returned_to_preview": True,
                                 "default_cancel_preserved": True},
                "reachability": {name: {"status": "reachable", "inside_work_area": True,
                                        "physical_mouse_target": {"hit_window": 42}}
                                 for name in ("cancel", "apply", "full_details", "expander")},
            },
            "actual_apply": {
                "scope": "3/1/2", "apply_entry": {"input": "physical-mouse", "menu_entry": "public-apply"},
                "destinations_reached": True,
                "unchanged_row_preserved": True, "content_and_identity_preserved": True,
                "journal_residue_count": 0,
            },
            "journal_residue_count": 0,
            "cancellation_disk_unchanged": True,
            "normal_exit_code": 0,
        }
        if mode == "text-scale":
            result["limitations"] = ["native-taskdialog-text-scale-not-observed"]
            result["blocking"] = {"status": "not-run", "reason": "covered-by-paired-text100-standard-run"}
        else:
            result["blocking"] = {name: {"blocked": True} for name in ("no_change", "collision", "invalid_name")}
        return result
    return {
        "mode": "context-surface",
        "full_context_coverage": {"omitted": [
            "second-repeated-fixture", "movement-actual-apply",
            "mixed-destination-third-unsampled-reentry", "default-enter-cancel", "alt-tab-roundtrip",
        ]},
        "surface": {
            "confirmation": {
                "apply_entry": {"input": "physical-mouse", "menu_entry": "public-apply"},
                "scope_exact": True,
                "default_focus": {"is_default_cancel": True},
                "reachability": {name: {"status": "reachable", "inside_work_area": True,
                                        "physical_mouse_target": {"hit_window": 42}}
                                 for name in ("cancel", "apply", "full_details", "expander")},
                "destination_context_visible": True,
                "full_details": {
                    "canonical_text": {"exact_document": True},
                    "native_end_scroll": {"ending_visible": True},
                    "return_default_cancel": {"is_default_cancel": True},
                },
                "expanded": {"bottom_scroll": {
                    "status": "physically-scrolled-to-native-bottom",
                    "range_value": {"reached_maximum": True},
                }},
                "cancellation": {"input": "physical-mouse", "returned_to_preview": True,
                                 "default_cancel_preserved": True},
                "modal_overlay": {
                    "pre_modal": {"visible_before_public_apply": True, "window": {"visible": True}},
                    "owner_disabled": True,
                    "at_entry_bound_tooltip_visible": False,
                    "persisted_visible_tooltip": False,
                    "persisted_essential_overlap": False,
                    "after_details_return": {"bound_tooltip_visible": False, "essential_overlap": False},
                    "after_expansion": {"bound_tooltip_visible": False, "essential_overlap": False},
                    "after_cancel": {"bound_tooltip_reexposed": True, "window": {"visible": True},
                                     "neutral_hidden": True},
                },
            },
            "cancellation_disk_unchanged": True,
            "fixture_identity_unchanged": True,
            "journal_residue_count": 0,
            "normal_exit_code": 0,
        },
    }


class Fixture:
    def __init__(self, root: Path):
        self.root = root

    def build(self, run_id: str, mode: str, *, reference: dict | None = None) -> Path:
        run = self.root / run_id
        output = run / "output"
        inputs = run / "inputs"
        output.mkdir(parents=True)
        inputs.mkdir()
        artifacts = {}
        for name in ("application", "runner", "observer", "launcher", "controller", "lockfile", "builder"):
            filename = f"inputs/{name}.bin"
            data = (f"same-{name}-bytes".encode() if name in {"application", "lockfile"}
                    else f"{run_id}-{name}".encode())
            (run / filename).write_bytes(data)
            artifacts[name] = {"file": filename, "bytes": len(data), "sha256": digest(data)}
        bundle = b"bundle manifest bytes"
        (inputs / "bundle.json").write_bytes(bundle)
        text_percent = 150 if mode == "text-scale" else 100
        appearance = "dark" if mode == "tooltip" else "light"
        desktop = {"width": 1366, "height": 768, "dpi": 144} if mode == "tooltip" else {"width": 800, "height": 600, "dpi": 96}
        manifest = {
            "schema_version": 1,
            "run_id": run_id,
            "source_sha": SOURCE,
            "source_tree": TREE,
            "bundle_manifest": {"file": "inputs/bundle.json", "bytes": len(bundle), "sha256": digest(bundle)},
            "artifacts": artifacts,
            "private_profile_sha256": "d" * 64,
            "host_preflight": {"system": "linux", "release": "6.6.87.2-microsoft-standard-WSL2", "architecture": "x86_64"},
            "guest_preflight": {
                "system": "windows", "os_version": "10.0.26200", "build": "26200",
                "product_caption": "Microsoft Windows 11 Pro",
                "architecture": "x86_64",
                "vm_identity_kind": "hyper-v-guest-parameters-virtual-machine-id-v1",
                "vm_identity_sha256": "e" * 64,
            },
            "request": {
                "mode": mode,
                "appearance": appearance,
                "desktop": desktop,
                "text_scale_percent": text_percent,
            },
            "expected_guest_platform": "windows",
            "command": ["pwsh", "-File", "run.ps1"],
        }
        if reference is not None:
            manifest["full_context_reference"] = reference
        write_json(run / "input-manifest.json", manifest)
        input_hash = digest((run / "input-manifest.json").read_bytes())
        image = png(ink_height=12 if mode == "text-scale" else 8,
                    ink_width=28 if mode == "text-scale" else 20)
        (output / "screen.png").write_bytes(image)
        raw_scenario = scenario(mode)
        raw_scenario["appearance"] = appearance
        raw_scenario["environment"] = {
            **raw_scenario.get("environment", {}),
            "physical_screen": {"left": 0, "top": 0, "right": desktop["width"], "bottom": desktop["height"],
                                "width": desktop["width"], "height": desktop["height"]},
            "work_area": {"left": 0, "top": 0, "right": desktop["width"], "bottom": desktop["height"] - 48,
                          "width": desktop["width"], "height": desktop["height"] - 48},
            "hwnd_dpi": desktop["dpi"],
            "text_scale_factor_percent": text_percent,
            "requested_small_workspace": {
                "width": desktop["width"], "height": desktop["height"],
                "actual_screen_matches": True, "display_mode_advertised": True,
                "status": "observed-exact", "mutation_attempted": False,
            },
        }
        raw_result = {
            "schema_version": 1,
            "source_sha": SOURCE,
            "application": {"file": "application.bin", "sha256": artifacts["application"]["sha256"]},
            "runner_sha256": artifacts["runner"]["sha256"],
            "acceptance_script_sha256": artifacts["observer"]["sha256"],
            "status": "review_required",
            "visual_review": "required",
            "assertions": {"overall": "passed", "scenario": raw_scenario},
            "keyboard": {"status": "passed"},
            "accessibility": {"status": "passed"},
            "capture": {"status": "passed"},
            "guest_cleanup": True,
        }
        if mode == "text-scale":
            snapshot = b'{"registry_snapshot":"present"}\n'
            activation = b'{"activation_attempt":"completed"}\n'
            (output / "text-scale-snapshot.json").write_bytes(snapshot)
            (output / "text-scale-activation.json").write_bytes(activation)
            original = {"registry_value_present": True, "percent": 100}
            snapshot_row = {"file": "text-scale-snapshot.json", "sha256": digest(snapshot)}
            activation_row = {"file": "text-scale-activation.json", "sha256": digest(activation)}
            raw_result["text_scale"] = {
                "requested_percent": 150, "registry_percent": 150,
                "acceptance_percent": 150, "original": original, "restoration": "verified",
                "snapshot": snapshot_row, "activation_attempt": activation_row,
            }
            write_json(output / "text-scale-restoration.json", {
                "schema_version": 1, "run_id": run_id, "input_manifest_sha256": input_hash,
                "status": "verified", "original": original, "restored": original,
                "snapshot": snapshot_row, "activation_attempt": activation_row,
            })
        write_json(output / "acceptance-result.json", raw_result)
        observations = {"schema_version": 1, "run_id": run_id, "scenario": raw_scenario}
        (output / "observer.stdout.txt").write_text("observer completed\n", encoding="utf-8")
        (output / "observer.stderr.txt").write_bytes(b"")
        write_json(output / "transport.json", {
            "kind": "ssh",
            "status": "collected",
            "guest_cleanup": True,
            "observer_process": {"state": "exited", "exit_code": 0},
        })
        cleanup = {
            "schema_version": 1,
            "run_id": run_id,
            "input_manifest_sha256": input_hash,
            "status": "passed",
            "controller_exit_code": 0,
            "fixture": True,
            "process": True,
            "guest": True,
            "desktop_restore": True,
            "text_scale_restore": True,
        }
        write_json(output / "cleanup.json", cleanup)
        guest = manifest["guest_preflight"]
        preflight = {
            "schema_version": 1,
            "run_id": run_id,
            "input_manifest_sha256": input_hash,
            "phase": "pre-launch",
            "source_sha": SOURCE,
            "application_sha256": artifacts["application"]["sha256"],
            "runner_sha256": artifacts["runner"]["sha256"],
            "observer_sha256": artifacts["observer"]["sha256"],
            "guest_platform": guest,
        }
        write_json(output / "platform-preflight.json", preflight)
        write_json(output / "platform-postlaunch.json", {
            "schema_version": 1, "run_id": run_id, "input_manifest_sha256": input_hash,
            "phase": "post-launch", "vm_identity_kind": guest["vm_identity_kind"],
            "vm_identity_sha256": guest["vm_identity_sha256"],
            "target": {
                "hwnd": 1001, "process_id": 4242,
                "window_rect": {"left": 0, "top": 0, "right": desktop["width"],
                                "bottom": desktop["height"] - 48, "width": desktop["width"],
                                "height": desktop["height"] - 48},
            },
            "identity_observation": {
                "source": r"HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters::VirtualMachineId",
                "session": "controller-pssession", "target_process_id": 4242,
            },
        })
        if mode in {"standard", "text-scale"}:
            _, _, rgba = evidence.decode_png(image, "fixture")
            crop_hash = digest(bytes(value for index, value in enumerate(rgba) if index % 4 != 3))
            ink_height = 12 if mode == "text-scale" else 8
            ink_width = 28 if mode == "text-scale" else 20
            samples = []
            targets = []
            for sample_id in ("prefix-input", "full-details"):
                control = ({"control_id": 1002, "text": "으로"}
                           if sample_id == "prefix-input" else
                           {"control_id": 1001, "text": "전체 이름과 경로"})
                control = {"observation": "native-static-v1",
                           "hwnd": 3001 if sample_id == "prefix-input" else 3002,
                           "process_id": 4242, "class_name": "Static", **control}
                target = {
                    "id": sample_id,
                    "image": "screen.png",
                    "text_sha256": digest(control["text"].encode()),
                    "control": control,
                    "window": {"hwnd": 2001 if sample_id == "prefix-input" else 2002,
                               "process_id": 4242,
                               "rect": {"left": 0, "top": 0, "right": 80, "bottom": 30,
                                        "width": 80, "height": 30}},
                    "screenshot_origin": {"x": 0, "y": 0},
                    "control_rect": {"left": 0, "top": 0, "right": 80, "bottom": 30, "width": 80, "height": 30},
                }
                targets.append(target)
                samples.append({
                    "id": sample_id,
                    "text_sha256": target["text_sha256"],
                    "image": "screen.png",
                    "observed_target": target,
                    "crop": {"x": 0, "y": 0, "width": 80, "height": 30},
                    "raster_sha256": crop_hash,
                    "ink_threshold_max_rgb": 120,
                    "ink_bounds": {"x": 10, "y": 5, "width": ink_width, "height": ink_height},
                    "ink_pixel_count": ink_width * ink_height,
                })
            write_json(output / "text-raster-metrics.json", {
                "schema_version": 1,
                "run_id": run_id,
                "input_manifest_sha256": input_hash,
                "samples": samples,
            })
            observations["text_raster_targets"] = targets
        write_json(output / "acceptance-observations.json", observations)
        self.refresh(run)
        return run

    def refresh(self, run: Path, *, sync_observations: bool = True) -> None:
        manifest = json.loads((run / "input-manifest.json").read_text())
        input_hash = digest((run / "input-manifest.json").read_bytes())
        output = run / "output"
        for name in ("cleanup.json", "platform-preflight.json", "platform-postlaunch.json",
                     "text-raster-metrics.json", "text-scale-restoration.json"):
            path = output / name
            if path.exists():
                value = json.loads(path.read_text())
                value["input_manifest_sha256"] = input_hash
                if name == "platform-preflight.json":
                    value["source_sha"] = manifest["source_sha"]
                    for key in ("application", "runner", "observer"):
                        value[f"{key}_sha256"] = manifest["artifacts"][key]["sha256"]
                write_json(path, value)
        raw_path = output / "acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["source_sha"] = manifest["source_sha"]
        raw["application"]["sha256"] = manifest["artifacts"]["application"]["sha256"]
        raw["runner_sha256"] = manifest["artifacts"]["runner"]["sha256"]
        raw["acceptance_script_sha256"] = manifest["artifacts"]["observer"]["sha256"]
        write_json(raw_path, raw)
        observations_path = output / "acceptance-observations.json"
        observations = json.loads(observations_path.read_text())
        if sync_observations:
            observations["scenario"] = raw["assertions"]["scenario"]
        write_json(observations_path, observations)
        files = []
        for path in sorted(output.iterdir()):
            if path.name == "run-result.json":
                continue
            data = path.read_bytes()
            files.append({"relative_path": path.name, "bytes": len(data), "sha256": digest(data)})
        collection = {
            "schema_version": 1,
            "run_id": run.name,
            "input_manifest_sha256": input_hash,
            "files": files,
        }
        write_json(run / "collection.json", collection)
        cleanup_bytes = (output / "cleanup.json").read_bytes()
        raw_bytes = raw_path.read_bytes()
        request = manifest["request"]
        result = {
            "schema_version": 1,
            "run_id": run.name,
            "input_manifest_sha256": input_hash,
            "collection_sha256": digest((run / "collection.json").read_bytes()),
            "cleanup_sha256": digest(cleanup_bytes),
            "source_sha": manifest["source_sha"],
            "application_sha256": manifest["artifacts"]["application"]["sha256"],
            "runner_sha256": manifest["artifacts"]["runner"]["sha256"],
            "observer_sha256": manifest["artifacts"]["observer"]["sha256"],
            "observer_result": {
                "file": "acceptance-result.json",
                "sha256": digest(raw_bytes),
                "bytes": len(raw_bytes),
                "status": raw["status"],
            },
            "host_platform": manifest["host_preflight"],
            "guest_platform": json.loads((output / "platform-preflight.json").read_text())["guest_platform"],
            "actual": {
                "appearance": request["appearance"],
                "monitor": {
                    "left": 0, "top": 0,
                    "right": request["desktop"]["width"], "bottom": request["desktop"]["height"],
                    "width": request["desktop"]["width"], "height": request["desktop"]["height"],
                },
                "work_area": {
                    "left": 0, "top": 0,
                    "right": request["desktop"]["width"], "bottom": request["desktop"]["height"] - 48,
                    "width": request["desktop"]["width"], "height": request["desktop"]["height"] - 48,
                },
                "target": {
                    "hwnd": 1001, "process_id": 4242,
                    "window_rect": {"left": 0, "top": 0,
                                    "right": request["desktop"]["width"],
                                    "bottom": request["desktop"]["height"] - 48,
                                    "width": request["desktop"]["width"],
                                    "height": request["desktop"]["height"] - 48},
                },
                "hwnd_dpi": request["desktop"]["dpi"],
                "text_scale_percent": request["text_scale_percent"],
            },
            "exit_code": 0,
            "assertions": {
                "overall": "passed",
                "semantics": {name: True for name in evidence.MODE_SEMANTICS[request["mode"]]},
            },
            "status": "review_required",
        }
        write_json(output / "run-result.json", result)

    def reference(self, target: Path) -> dict:
        return {
            "run_id": target.name,
            "input_manifest_sha256": digest((target / "input-manifest.json").read_bytes()),
            "result_sha256": digest((target / "output/run-result.json").read_bytes()),
            "scope": list(evidence.REFERENCE_SCOPE),
        }


class GuiEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.fixture = Fixture(self.root)
        self.full = self.fixture.build("01-full-context-light-800x600-96-text100", "full-context")
        self.standard = self.fixture.build("02-standard-light-800x600-96-text100", "standard")
        self.text = self.fixture.build("03-standard-light-800x600-96-text150", "text-scale")
        self.tooltip = self.fixture.build("04-tooltip-dark-1366x768-144-text100", "tooltip", reference=self.fixture.reference(self.full))

    def validate(self, run: Path):
        return evidence.validate_run(self.root, run.name, SOURCE)

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

        self.setUp()
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

        self.setUp()
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
        (self.standard / "output/observer.stdout.txt").unlink()
        with self.assertRaisesRegex(evidence.EvidenceError, "missing"):
            self.validate(self.standard)

        self.setUp()
        (self.standard / "output/screen.png").write_bytes(b"changed")
        with self.assertRaisesRegex(evidence.EvidenceError, "receipt"):
            self.validate(self.standard)

        self.setUp()
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        observer = self.standard / manifest["artifacts"]["observer"]["file"]
        observer.write_bytes(b"tampered observer")
        with self.assertRaisesRegex(evidence.EvidenceError, "input manifest"):
            self.validate(self.standard)

    def test_cleanup_and_prelaunch_identity_fail_closed(self):
        cleanup = json.loads((self.standard / "output/cleanup.json").read_text())
        cleanup["guest"] = False
        write_json(self.standard / "output/cleanup.json", cleanup)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "cleanup.guest"):
            self.validate(self.standard)

        self.setUp()
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

        self.setUp()
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

        self.setUp()
        raw = (self.standard / "output/run-result.json").read_text()
        (self.standard / "output/run-result.json").write_text(raw.replace('"exit_code": 0', '"exit_code": NaN'))
        with self.assertRaisesRegex(evidence.EvidenceError, "non-finite"):
            self.validate(self.standard)

        self.setUp()
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

    def test_traversal_self_reference_cycle_and_symlink_are_rejected(self):
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        manifest["artifacts"]["observer"]["file"] = "../observer.ps1"
        write_json(self.standard / "input-manifest.json", manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "unsafe path"):
            self.validate(self.standard)

        self.setUp()
        manifest = json.loads((self.tooltip / "input-manifest.json").read_text())
        manifest["full_context_reference"]["run_id"] = self.tooltip.name
        write_json(self.tooltip / "input-manifest.json", manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "reference itself"):
            self.validate(self.tooltip)

        self.setUp()
        manifest = json.loads((self.full / "input-manifest.json").read_text())
        manifest["full_context_reference"] = self.fixture.reference(self.tooltip)
        write_json(self.full / "input-manifest.json", manifest)
        with self.assertRaisesRegex(evidence.EvidenceError, "Only the tooltip"):
            self.validate(self.full)

        self.setUp()
        target = self.standard / "output/observer.stdout.txt"
        outside = self.root / "outside.txt"
        outside.write_text("observer completed\n")
        target.unlink()
        target.symlink_to(outside)
        with self.assertRaisesRegex(evidence.EvidenceError, "symlink"):
            self.validate(self.standard)

    def test_reference_manifest_and_result_digests_are_enforced(self):
        manifest = json.loads((self.tooltip / "input-manifest.json").read_text())
        manifest["full_context_reference"]["result_sha256"] = "0" * 64
        write_json(self.tooltip / "input-manifest.json", manifest)
        self.fixture.refresh(self.tooltip)
        with self.assertRaisesRegex(evidence.EvidenceError, "result digest"):
            self.validate(self.tooltip)

        self.setUp()
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

        self.setUp()
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

        self.setUp()
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

        self.setUp()
        raw_path = self.standard / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["assertions"]["scenario"]["journal_residue_count"] = False
        raw["assertions"]["scenario"]["normal_exit_code"] = False
        write_json(raw_path, raw)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "journal_clean|normal_exit"):
            self.validate(self.standard)

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

        self.setUp()
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        manifest["guest_preflight"]["product_caption"] = "Microsoft Windows 10 Pro"
        manifest["guest_preflight"]["build"] = "19045"
        write_json(self.standard / "input-manifest.json", manifest)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "Windows 11"):
            self.validate(self.standard)

        self.setUp()
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
        raw["assertions"]["scenario"]["confirmation"]["reachability"]["apply"]["physical_mouse_target"]["hit_window"] = 0
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "required_controls_reachable"):
            self.validate(self.text)

        self.setUp()
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

    def test_png_decoder_rejects_bomb_transparency_and_unsupported_transparency_chunk(self):
        header = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
        bomb = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) +
                png_chunk(b"IDAT", zlib.compress(b"\0" + b"\0" * 1_000_000)) +
                png_chunk(b"IEND", b""))
        with self.assertRaisesRegex(evidence.EvidenceError, "exceeds its declared dimensions"):
            evidence.decode_png(bomb, "bomb")
        with self.assertRaisesRegex(evidence.EvidenceError, "non-opaque"):
            evidence.decode_png(png(transparent=True), "alpha")
        opaque = png()
        idat = opaque.index(b"IDAT") - 4
        with_trns = opaque[:idat] + png_chunk(b"tRNS", b"\x00\x00\x00\x00\x00\x00") + opaque[idat:]
        with self.assertRaisesRegex(evidence.EvidenceError, "unsupported PNG transparency"):
            evidence.decode_png(with_trns, "trns")

    def test_vm_identity_kind_and_independent_postlaunch_receipt_are_enforced(self):
        manifest = json.loads((self.standard / "input-manifest.json").read_text())
        manifest["guest_preflight"]["vm_identity_kind"] = "win32-computersystemproduct-uuid"
        write_json(self.standard / "input-manifest.json", manifest)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "VM identity source"):
            self.validate(self.standard)

        self.setUp()
        (self.standard / "output/platform-postlaunch.json").unlink()
        with self.assertRaisesRegex(evidence.EvidenceError, "missing"):
            self.validate(self.standard)

        self.setUp()
        post = json.loads((self.standard / "output/platform-postlaunch.json").read_text())
        post["vm_identity_sha256"] = "f" * 64
        write_json(self.standard / "output/platform-postlaunch.json", post)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "postlaunch VM identity differs"):
            self.validate(self.standard)

        self.setUp()
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
            self.setUp()
            transport_path = self.standard / "output/transport.json"
            transport = json.loads(transport_path.read_text())
            transport[field] = value
            write_json(transport_path, transport)
            self.fixture.refresh(self.standard)
            with self.assertRaisesRegex(evidence.EvidenceError, error):
                self.validate(self.standard)

        self.setUp()
        transport_path = self.standard / "output/transport.json"
        transport = json.loads(transport_path.read_text())
        del transport["observer_process"]
        write_json(transport_path, transport)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "observer_process"):
            self.validate(self.standard)

        self.setUp()
        transport_path = self.standard / "output/transport.json"
        transport = json.loads(transport_path.read_text())
        transport["observer_process"]["state"] = "running"
        write_json(transport_path, transport)
        self.fixture.refresh(self.standard)
        with self.assertRaisesRegex(evidence.EvidenceError, "terminal state"):
            self.validate(self.standard)

        for exit_code in (False, 7):
            self.setUp()
            transport_path = self.standard / "output/transport.json"
            transport = json.loads(transport_path.read_text())
            transport["observer_process"]["exit_code"] = exit_code
            write_json(transport_path, transport)
            self.fixture.refresh(self.standard)
            normalized = json.loads((self.standard / "output/run-result.json").read_text())
            self.assertEqual(normalized["exit_code"], 0)
            with self.assertRaisesRegex(evidence.EvidenceError, "terminal exit code"):
                self.validate(self.standard)


if __name__ == "__main__":
    unittest.main()
