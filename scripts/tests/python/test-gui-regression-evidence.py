#!/usr/bin/env python3
"""Offline negative fixtures for GUI regression evidence validation."""

from __future__ import annotations

import hashlib
import json
from copy import deepcopy
from pathlib import Path
from tooling_test_paths import SCRIPT_ROOT
import struct
import subprocess
import tempfile
import unittest
import zlib

from darkrenamer_tooling.evidence import gui as evidence
from controller_cleanup_fixture import clean_controller_cleanup_v2

SCRIPT = (SCRIPT_ROOT / "validate-gui-regression-evidence.py")
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


def pair_png(rgb: tuple[int, int, int], *, width: int = 800, height: int = 552,
             patches: tuple[tuple[int, int, int, int, tuple[int, int, int]], ...] = ()) -> bytes:
    background = bytes((*rgb, 255))
    contrasting = b"\x00\x00\x00\xff" if rgb[0] > 128 else b"\xff\xff\xff\xff"
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        row = bytearray(background * width)
        if y < 8:
            row[:32] = contrasting * 8
        for left, top, right, bottom, color in patches:
            if top <= y < bottom:
                row[left * 4:right * 4] = bytes((*color, 255)) * (right - left)
        pixels.extend(row)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", zlib.compress(bytes(pixels))) + png_chunk(b"IEND", b"")


def physical_menu_apply_entry() -> dict:
    def menu_item(name: str, automation_id: str, x: float, y: float,
                  width: float, height: float) -> dict:
        return {
            "automation_id": automation_id,
            "name": name,
            "control_type": "ControlType.MenuItem",
            "enabled": True,
            "keyboard_focusable": True,
            "offscreen": False,
            "native_handle": 0,
            "bounds": {"x": x, "y": y, "width": width, "height": height},
        }

    return {
        "input": "physical-mouse-file-menu-public-apply",
        "menu_entry": {
            "file": menu_item("파일(F)", "Item 1", 125.0, 45.0, 99.0, 29.0),
            "file_target": {"x": 174, "y": 59, "hit_window": 26870924, "root_window": 26870924},
            "apply": menu_item("변경 사항 적용", "Item 32771", 128.0, 126.0, 385.0, 37.0),
            "apply_target": {"x": 320, "y": 144, "hit_window": 82903142, "root_window": 82903142},
        },
    }


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
                "scope": "3/1/2", "apply_entry": {"input": "visible-command-rail", "menu_entry": None},
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
                "apply_entry": {"input": "keyboard-ctrl-s-with-visible-listview-infotip", "menu_entry": None},
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
        (output / "controller.stdout.txt").write_bytes(b"controller completed\n")
        (output / "controller.stderr.txt").write_bytes(b"")
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
        raw["acceptance_observations"] = observations
        raw["observations"] = {
            "file": "acceptance-observations.json",
            "sha256": digest(observations_path.read_bytes()),
        }
        write_json(raw_path, raw)
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
                "semantics": {name: True for name in evidence.MODE_SEMANTICS.get(request["mode"], ())},
            },
            "status": "review_required",
        }
        if request["mode"] == evidence.PAIR_MODE:
            result = {
                "schema_version": 1, "diagnostic": evidence.PAIR_MODE, "run_id": run.name,
                "input_manifest_sha256": input_hash,
                "collection_sha256": digest((run / "collection.json").read_bytes()),
                "cleanup_sha256": digest(cleanup_bytes), "source_sha": manifest["source_sha"],
                "application_sha256": manifest["artifacts"]["application"]["sha256"],
                "runner_sha256": manifest["artifacts"]["runner"]["sha256"],
                "observer_sha256": manifest["artifacts"]["observer"]["sha256"],
                "observer_result_sha256": digest(raw_bytes),
                "host_platform": manifest["host_preflight"],
                "guest_platform": json.loads((output / "platform-preflight.json").read_text())["guest_platform"],
                "actual": {
                    "monitor": {"left": 0, "top": 0, "right": 800, "bottom": 600, "width": 800, "height": 600},
                    "work_area": {"left": 0, "top": 0, "right": 800, "bottom": 552, "width": 800, "height": 552},
                    "target": {"hwnd": 1001, "process_id": 4242, "window_rect":
                               {"left": 0, "top": 0, "right": 800, "bottom": 552, "width": 800, "height": 552}},
                    "hwnd_dpi": 96, "text_scale_percent": 100,
                },
                "status": "review_required", "exit_code": 0,
            }
        write_json(output / "run-result.json", result)

    def build_pair(self) -> Path:
        run = self.build(evidence.PAIR_RUN_ID, "standard")
        output = run / "output"
        manifest = json.loads((run / "input-manifest.json").read_text())
        manifest["request"]["mode"] = evidence.PAIR_MODE
        manifest["acceptance_profile_id"] = "vm-automated-v1-win11-ntfs"
        manifest["command"] = ["python3", "-I", "scripts/run-gui-regression.py", "--diagnostic", evidence.PAIR_MODE]
        write_json(run / "input-manifest.json", manifest)
        (output / "screen.png").unlink()
        (output / "text-raster-metrics.json").unlink()
        raw = json.loads((output / "acceptance-result.json").read_text())
        environment = raw["assertions"]["scenario"]["environment"]
        environment["system_visual_style"] = {
            "theme_path_sha256": "e" * 64, "theme_color": "NormalColor",
            "theme_size": "NormalSize", "forced_colors": False,
        }
        font = {"family": "Segoe UI", "height": -12, "width": 0, "weight": 400,
                "charset": 1, "quality": 5, "italic": 0, "underline": 0, "strikeout": 0}
        environment["target_rendering"] = {
            "hwnd": 1001, "process_id": 4242, "hwnd_dpi": 96,
            "awareness": {"query": "GetWindowDpiAwarenessContext+GetAwarenessFromDpiAwarenessContext+AreDpiAwarenessContextsEqual",
                          "context": -4, "value": 2, "per_monitor_v2": True},
            "client": {"left": 8, "top": 30, "right": 792, "bottom": 544, "width": 784, "height": 514},
            "client_query": "GetClientRect+ClientToScreen",
            "system_font_recipe": {"query": "SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS)", "dpi": 96,
                                   "fonts": {"MessageFont": font, "StatusFont": font},
                                   "scope": "system LOGFONT recipe; not a dereferenced application HFONT"}}
        environment["installed_fonts"] = {
            "query": "System.Drawing.Text.InstalledFontCollection", "count": 100, "family_names_sha256": "a" * 64,
            "encoding": "UTF-8 ordinal sorted names joined by LF",
            "scope": "installed family environment; glyph fallback is observed in original rasters"}
        captures = []
        scenes = {}
        def add_capture(name: str, image: bytes, appearance: str, surface: str,
                        width: int = 800, height: int = 552) -> dict:
            (output / name).write_bytes(image)
            receipt = {"file": name, "sha256": digest(image), "width": width, "height": height}
            captures.append({**receipt, "appearance": appearance, "surface": surface})
            return receipt

        def menu_state(appearance: str) -> dict:
            return {"hwnd": 1001, "pid": 4242, "menu_checked": [
                {"command_id": 0x9010, "checked": False},
                {"command_id": 0x9011, "checked": appearance == "light"},
                {"command_id": 0x9012, "checked": appearance == "dark"},
            ]}

        def control(automation_id: str, name: str, x: int, y: int, width: int,
                    height: int, enabled: bool = True, native_handle: int = 3001) -> dict:
            return {"automation_id": automation_id, "name": name,
                    "control_type": "ControlType.Button", "enabled": enabled,
                    "keyboard_focusable": True, "offscreen": False,
                    "native_handle": native_handle,
                    "bounds": {"x": x, "y": y, "width": width, "height": height}}

        main_window = {"hwnd": 1001, "process_id": 4242, "hwnd_dpi": 96,
                       "rect": {"left": 0, "top": 0, "right": 800, "bottom": 552,
                                "width": 800, "height": 552}}
        native_list = {"hwnd": 2001, "process_id": 4242, "hwnd_dpi": 96,
                       "rect": {"left": 40, "top": 100, "right": 640, "bottom": 450,
                                "width": 600, "height": 350}}
        current_cell = control("row-0", "00-한국어-日本語.txt", 45, 140, 160, 24,
                               native_handle=2001)
        proposed_cell = control("proposal-0", "", 260, 140, 900, 24,
                                native_handle=2001)
        proposed_cell["control_type"] = "ControlType.DataItem"
        for scene in evidence.PAIR_SCENES:
            count = evidence.PAIR_SCENE_ROWS[scene]
            names = [f"{index:02d}-한국어-日本語.txt" for index in range(count)]
            proposal_name = {"changed": "paired-change-00.txt",
                             "collision": "paired-collision.txt",
                             "warning": ".txt"}.get(scene)
            proposal = {**proposed_cell, "name": proposal_name} if proposal_name else None
            selected_name = names[0] if scene.startswith("selected-") else names[2] if proposal_name else None
            status = {"collision": "대상 경로 충돌", "warning": "이름 본체가 비어 있는 항목",
                      "changed": "변경 가능"}.get(scene, "변경 없음")
            state = {
                "target_rendering": environment["target_rendering"],
                "row_count": count, "current_names": names,
                "columns": [900, 900, 260],
                "column_preference_sha256": "c" * 64,
                "overlay": {"visible_tooltip_count": 0, "neutral_cursor": True, "dismissed_tooltip_count": 0},
                "horizontal_scroll": ([0, 2000, 800, 540, 540] if proposal_name else
                                      [0, 2000, 800, 0, 0] if scene == "overflow" else None),
                "proposal_viewport": ({"query": "LVM_SCROLL horizontal scalar pixels after focus",
                                      "percent": 45, "requested": 540, "observed": 540}
                                     if proposal_name else None),
                "vertical_scroll": [0, 59, 20, 0, 0] if scene == "overflow" else None,
                "horizontal_scrollbar_bounds": [40, 432, 620, 449, 0, 0, 0] if scene == "overflow" else None,
                "vertical_scrollbar_bounds": [623, 125, 640, 432, 0, 0, 0] if scene == "overflow" else None,
                "apply_enabled": scene in {"changed", "warning"}, "status": status,
                "focus_automation_id": "32773" if scene == "selected-inactive" else "1000",
                "native_focus": [3001 if scene == "selected-inactive" else 2001, 0,
                                 32773 if scene == "selected-inactive" else 1000],
                "focused_uia": None,
                "selection": {"count": 1 if selected_name else 0, "name": selected_name},
                "selected_row_cell": ({**current_cell, "keyboard_focusable": scene == "selected-active"}
                                      if scene.startswith("selected-") else None),
                "proposed_name": proposal_name, "proposed_cell": proposal,
                "current_name_cell": (control("current-0", names[0], 260 - 900, 140, 900, 24,
                                               native_handle=2001) if proposal_name else None),
                "list_physical_target": {"x": 340, "y": 275, "hit_window": 2001, "root_window": 1001},
                "list": {"native_handle": 2001, "bounds": {"x": 40, "y": 100, "width": 600, "height": 350}},
                "native_list": native_list, "window": main_window,
                "native_header": {"hwnd": 2002, "process_id": 4242, "hwnd_dpi": 96,
                                  "rect": {"left": 40, "top": 100, "right": 620, "bottom": 125, "width": 580, "height": 25}},
            }
            steps = []
            for phase in evidence.PAIR_PHASES:
                appearance = "dark" if phase == "dark" else "light"
                state["appearance_menu"] = menu_state(appearance)
                name = f"appearance-{scene}-{phase}.png"
                patches = ()
                if proposal_name:
                    semantic_rgb = {
                        "changed": {"light": (35, 83, 151), "dark": (133, 183, 255)},
                        "collision": {"light": (169, 22, 33), "dark": (255, 137, 145)},
                        "warning": {"light": (142, 83, 0), "dark": (255, 194, 92)},
                    }[scene][appearance]
                    patches = ((300, 148, 330, 156, semantic_rgb),)
                elif scene.startswith("selected-"):
                    color = ((51, 96, 160) if scene == "selected-active" else (170, 178, 189))
                    patches = ((45, 143, 180, 161, color),)
                if scene == "overflow" and appearance == "dark":
                    patches += ((623, 432, 640, 450, (20, 22, 25)),)
                divider = (55, 60, 67) if appearance == "dark" else (217, 221, 227)
                patches += ((39, 108, 40, 442, divider), (48, 124, 80, 125, divider), (48, 450, 80, 451, divider))
                image = pair_png((36, 36, 36) if appearance == "dark" else (245, 245, 245), patches=patches)
                capture = add_capture(name, image, appearance, "main-workbench")
                steps.append({"phase": phase, "appearance": appearance,
                              "state": json.loads(json.dumps(state)), "capture": capture})
            scenes[scene] = steps
        interactions = []
        for phase in evidence.PAIR_PHASES:
            appearance = "dark" if phase == "dark" else "light"
            base = (36, 36, 36) if appearance == "dark" else (245, 245, 245)
            button_colors = {
                "light": {"normal": (255, 255, 255), "disabled": (235, 237, 240),
                          "hover": (240, 244, 250), "pressed": (226, 232, 240),
                          "keyboard-focus": (255, 255, 255)},
                "dark": {"normal": (42, 45, 50), "disabled": (34, 37, 41),
                         "hover": (52, 57, 64), "pressed": (32, 35, 40),
                         "keyboard-focus": (42, 45, 50)},
            }[appearance]
            outline = (177, 183, 192) if appearance == "light" else (83, 89, 99)
            def outline_patches(x, y, right, bottom, shared_top=False, default=False):
                result = ()
                for inset in range(2 if default else 1):
                    result += ((x + inset, y + inset, x + inset + 1, bottom - inset, outline),
                               (right - inset - 1, y + inset, right - inset, bottom - inset, outline),
                               (x + inset, bottom - inset - 1, right - inset, bottom - inset, outline))
                    if not shared_top:
                        result += ((x + inset, y + inset, right - inset, y + inset + 1, outline),)
                return result
            buttons = {}
            for button_state in evidence.PAIR_BUTTON_STATES:
                disabled = button_state == "disabled"
                x, y = 660, 120 if disabled else 200
                rect = (x, y, 770, y + 32, button_colors[button_state])
                patches = (rect,)
                patches += outline_patches(x, y, 770, y + 32, shared_top=not disabled)
                text = ((110, 117, 127) if appearance == "light" else (150, 157, 167)) if disabled else (
                    (27, 29, 32) if appearance == "light" else (242, 244, 247))
                offset = 1 if button_state == "pressed" else 0
                patches += ((704 + offset, y + 8 + offset, 726 + offset, y + 22 + offset, text),)
                if button_state == "keyboard-focus":
                    cue = (0, 0, 0) if appearance == "light" else (255, 255, 255)
                    patches += ((663, 203, 767, 204, cue), (663, 228, 767, 229, cue),
                                (663, 203, 664, 229, cue), (766, 203, 767, 229, cue))
                name = f"appearance-button-{button_state}-{phase}.png"
                buttons[button_state] = {
                    "control": control("32771" if disabled else "32773",
                                       "적용" if disabled else "이름 앞에 문자열 붙이기",
                                       x, y, 110, 32, enabled=not disabled),
                    "focus_automation_id": "32773" if button_state in {"pressed", "keyboard-focus"} else "1000",
                    "native_button_state": (12 if button_state == "pressed" else
                                            8 if button_state == "keyboard-focus" else 0),
                    "target": {"x": 715, "y": y + 16, "hit_window": 3001, "root_window": 1001},
                    "cursor": ([715, y + 16, 3001, 1001] if button_state in {"hover", "pressed"}
                               else [20, 20, 1001, 1001]),
                    "capture": add_capture(name, pair_png(base, patches=patches), appearance, "main-workbench"),
                }
            menu_capture = add_capture(f"appearance-native-menu-{phase}.png", pair_png(base),
                                       appearance, "native-menu")
            popup = control("menu", "보기(V)", 100, 30, 200, 250, native_handle=4001)
            modal_rect = {"left": 200, "top": 120, "right": 500, "bottom": 320,
                          "width": 300, "height": 200}
            native_modal = {"hwnd": 5001, "process_id": 4242, "hwnd_dpi": 96, "rect": modal_rect}
            advanced = {"window": control("dialog", "DarkReNamer - 모양 설정 (미리보기)",
                                          200, 120, 300, 200, native_handle=5001),
                        "native_window": native_modal,
                        "capture": add_capture(f"appearance-advanced-{phase}.png",
                                               pair_png((26, 28, 32) if appearance == "dark" else (247, 248, 250),
                                                        width=300, height=200),
                                               appearance, "advanced-appearance", 300, 200)}
            prompt = {"window": control("dialog", "이름 앞에 문자열 붙이기", 200, 120, 300, 200,
                                         native_handle=5001),
                      "native_window": native_modal,
                      "edit": control("1004", "붙일 문자열", 230, 170, 180, 28, native_handle=5002),
                      "default_button": control("1", "확인", 350, 260, 100, 32, native_handle=5003),
                      "default_button_id": 1,
                      "default_button_query": "WM_GETDLGCODE(DLGC_BUTTON|DLGC_DEFPUSHBUTTON)+GetDlgCtrlID",
                      "same_glyph_label": {
                          "control": {**control("1002", "붙일 문자열", 230, 150, 120, 24, native_handle=5004), "control_type": "ControlType.Text"},
                          "native_window": {"hwnd": 5004, "process_id": 4242, "hwnd_dpi": 96,
                                            "rect": {"left": 230, "top": 150, "right": 350, "bottom": 174, "width": 120, "height": 24}},
                          "native_class": "Static", "text_sha256": digest("붙일 문자열".encode()),
                          "query": "bound STATIC/WM_GETTEXT original prompt raster",
                      },
                      "capture": add_capture(f"appearance-input-prompt-{phase}.png",
                                             pair_png((26, 28, 32) if appearance == "dark" else (247, 248, 250),
                                                      patches=((32, 32, 90, 44, (242, 244, 247) if appearance == "dark" else (27, 29, 32)),
                                                               (150, 140, 250, 172, button_colors['normal'])) + outline_patches(150, 140, 250, 172, default=True), width=300, height=200),
                                             appearance, "input-prompt", 300, 200)}
            scrollbars = {}
            for axis in evidence.PAIR_SCROLL_AXES:
                bar = ([40, 432, 620, 449, 17, 17, 117] if axis == "horizontal" else
                       [623, 125, 640, 432, 17, 17, 77]) + [0] * 6
                initial = [0, 1000, 100, 0, 0]
                steps = []
                for stage in evidence.PAIR_SCROLL_STAGES:
                    observed_bar = list(bar)
                    if stage != "held":
                        observed_bar[5] += 50
                        observed_bar[6] += 50
                    patches = ()
                    if appearance == "dark":
                        x0, y0, x1, y1 = observed_bar[:4]
                        thumb = ((x0 + observed_bar[5], y0, x0 + observed_bar[6], y1)
                                 if axis == "horizontal" else
                                 (x0, y0 + observed_bar[5], x1, y0 + observed_bar[6]))
                        patches = ((x0, y0, x1, y1, (20, 22, 25)), (*thumb, (150, 157, 167)))
                    steps.append({"stage": stage,
                                  "native_gui": [2001, 0 if stage == "released" else 2001, 1000],
                                  "components": observed_bar,
                                  "scroll": [0, 1000, 100, 0 if stage == "held" else 100, 100],
                                  "capture": add_capture(f"appearance-scroll-{axis}-{stage}-{phase}.png",
                                                         pair_png(base, patches=patches), appearance, "main-workbench")})
                scrollbars[axis] = {"list_hwnd": 2001, "initial_scroll": initial,
                                    "restored_scroll": initial, "steps": steps,
                                    "target": {"x": 100 if axis == "horizontal" else 630,
                                               "y": 440 if axis == "horizontal" else 160,
                                               "hit_window": 2001, "root_window": 1001}}
            interactions.append({"phase": phase, "appearance": appearance, "buttons": buttons,
                                 "native_menu": {"popup_hwnd": 4001, "popup": popup,
                                                 "capture": menu_capture},
                                 "advanced_appearance": advanced, "input_prompt": prompt, "scrollbars": scrollbars,
                                 "column_preference_sha256": "c" * 64,
                                 "selected": {"count": 1, "name": "00-한국어-日本語.txt"},
                                 "appearance_menu": menu_state(appearance)})
        raw["screenshots"] = captures
        raw["keyboard"]["status"] = "not_run"
        raw["accessibility"]["status"] = "not_run"
        raw["assertions"]["scope"] = evidence.PAIR_SCOPE
        transition_names = [f"{index:02d}-한국어-日本語.txt" for index in range(60)]
        transition_samples = []
        for phase, appearance in zip(evidence.PAIR_TRANSITION_PHASES,
                                     ("light", "dark", "dark", "light"), strict=True):
            transition_samples.append({
                "phase": phase, "appearance": appearance,
                "executable_sha256": manifest["artifacts"]["application"]["sha256"], "process_id": 4242,
                "main_handle": 1001, "list_handle": 2001,
                "client_bounds": environment["target_rendering"]["client"],
                "dpi": 96, "text_scale_percent": 100,
                "columns": [900, 900, 260, 0, 0, 0, 0, 112],
                "column_order": list(range(8)), "column_count": 8, "row_count": 60,
                "list_client_bounds": [40, 100, 640, 450],
                "current_names": transition_names,
                "row_values": [[name, name, "C:\\test", "", "", "", "", "변경 없음"]
                               for name in transition_names],
                "column_preference_sha256": "c" * 64,
                "selection": {"count": 1, "name": transition_names[20]},
                "horizontal_scroll": [0, 2000, 800, 540, 540],
                "vertical_scroll": [0, 59, 20, 18, 18], "top_index": 18,
                "native_focus": [2001, 0, 1000],
                "observer_read_native_after": {"horizontal_scroll": [0, 2000, 800, 540, 540],
                                               "vertical_scroll": [0, 59, 20, 18, 18],
                                               "top_index": 18},
                "observer_read_preserved": True,
                "appearance_menu": menu_state(appearance),
            })
            if phase.startswith("after_"):
                transition_samples[-1].update({
                    "settlement": {"horizontal_scroll": [0, 2000, 800, 540, 540],
                                   "vertical_scroll": [0, 59, 20, 18, 18], "top_index": 18},
                    "settled": True,
                    "command_focus_transfer": {"before_control_id": 1000, "after_control_id": 1000},
                })
        default_rendering = json.loads(json.dumps(environment["target_rendering"]))
        default_rendering.update(hwnd=1010, process_id=4343)
        default_window = {**main_window, "hwnd": 1010, "process_id": 4343}
        default_list = {**native_list, "hwnd": 2010, "process_id": 4343}
        default_header = {"hwnd": 2012, "process_id": 4343, "hwnd_dpi": 96,
                          "rect": {"left": 40, "top": 100, "right": 620, "bottom": 125,
                                   "width": 580, "height": 25}}
        default_name = "00-한국어-日本語.txt"
        default_steps = []
        for phase in evidence.PAIR_PHASES:
            appearance = "dark" if phase == "dark" else "light"
            divider = (55, 60, 67) if appearance == "dark" else (217, 221, 227)
            ink = (242, 244, 247) if appearance == "dark" else (27, 29, 32)
            image = pair_png((36, 36, 36) if appearance == "dark" else (245, 245, 245),
                             patches=((48, 124, 80, 125, divider),
                                      (55, 105, 105, 112, ink),
                                      (52, 143, 68, 151, ink if appearance == "dark" else (160, 165, 170)),
                                      (75, 144, 145, 151, ink),
                                      (245, 144, 315, 151, ink)))
            capture = add_capture(f"appearance-default-columns-{phase}.png", image,
                                  appearance, "main-workbench")
            default_steps.append({"phase": phase, "appearance": appearance,
                                  "capture": capture, "state": {
                "column_origin": "clean-start-default", "columns": [187, 187, 113],
                "runtime_columns": {"status_width_px": 112, "optional_widths": [0, 0, 0, 0]},
                "column_visibility": [True, True, True, False, False, False, False, True],
                "column_order": list(range(8)), "list_client_width": 600,
                "list_client_bounds": [40, 100, 640, 450],
                "row_count": 1, "current_names": [default_name],
                "proposed_name": default_name, "apply_enabled": False,
                "horizontal_scroll": [0, 600, 600, 0, 0],
                "vertical_scroll": [0, 0, 1, 0, 0],
                "native_header": default_header, "native_list": default_list,
                "window": default_window,
                "list": {"native_handle": 2010,
                         "bounds": {"x": 40, "y": 100, "width": 600, "height": 350}},
                "selection": {"count": 0, "name": None},
                "status": "변경 없음",
                "overlay": {"visible_tooltip_count": 0, "neutral_cursor": True,
                            "dismissed_tooltip_count": 1 if phase == "dark" else 0},
                "current_name_cell": {**current_cell, "name": default_name,
                                      "bounds": {"x": 45, "y": 140, "width": 187, "height": 24}},
                "proposed_name_cell": {**current_cell, "name": default_name,
                                       "bounds": {"x": 232, "y": 140, "width": 187, "height": 24}},
                "target_rendering": default_rendering,
                "appearance_menu": {"hwnd": 1010, "pid": 4343, "menu_checked": [
                    {"command_id": 0x9010, "checked": False},
                    {"command_id": 0x9011, "checked": appearance == "light"},
                    {"command_id": 0x9012, "checked": appearance == "dark"},
                ]},
            }})
        raw["assertions"]["scenario"] = {
            "environment": environment, "appearance": "light-dark-light", "process_id": 4242,
            "normal_exit_code": 0, "fixture": {"disk_unchanged": True, "journal_residue_count": 0,
                "column_preferences": {"source": "isolated-persisted-user-settings", "format_version": 1,
                                       "primary_width_dip": [900, 900, 260], "sha256": "c" * 64}},
            "scenes": scenes, "interactions": interactions,
            "transition_preservation": {
                "snapshot_order": list(evidence.PAIR_TRANSITION_PHASES),
                "fixture": {"source": "isolated-persisted-user-settings",
                            "column_preference_sha256": "c" * 64, "row_count": 60},
                "observations": transition_samples,
                "check": {"status": "passed", "reason": None},
            },
            "default_columns": {
                "fixture": {"source": "clean-start-default", "settings_absent_before_launch": True,
                            "settings_path_kind": "isolated-localappdata", "row_name": default_name,
                            "disk_unchanged": True, "journal_residue_count": 0,
                            "startup_columns": [187, 187, 113, 0, 0, 0, 0, 112]},
                "process_id": 4343, "main_handle": 1010,
                "executable_sha256": manifest["artifacts"]["application"]["sha256"],
                "steps": default_steps, "normal_exit_code": 0,
                "check": {"status": "passed", "reason": None},
            },
        }
        write_json(output / "acceptance-result.json", raw)
        observations = json.loads((output / "acceptance-observations.json").read_text())
        observations["environment"] = environment
        observations.pop("text_raster_targets", None)
        write_json(output / "acceptance-observations.json", observations)
        self.refresh(run)
        return run

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
        (self.standard / "output/controller.stdout.txt").unlink()
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

    def test_traversal_self_reference_and_cycle_are_rejected(self):
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
        for row in raw["assertions"]["scenario"]["confirmation"]["tree"]:
            if row.get("automation_id") in {
                    "CommandLink_1101", "CommandLink_1102", "ExpandoButton", "CommandButton_2"}:
                row["bounds"] = {"x": 10.25, "y": 10.5, "width": 40.25, "height": 20.5}
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        self.validate(self.text)

        self.setUp()
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["assertions"]["scenario"]["confirmation"]["reachability"]["apply"]["physical_mouse_target"]["hit_window"] = 0
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "required_controls_reachable"):
            self.validate(self.text)

        self.setUp()
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        tree = raw["assertions"]["scenario"]["confirmation"]["tree"]
        next(row for row in tree if row.get("automation_id") == "CommandLink_1101")["bounds"]["width"] = True
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "required_controls_reachable"):
            self.validate(self.text)

        self.setUp()
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        tree = raw["assertions"]["scenario"]["confirmation"]["tree"]
        next(row for row in tree if row.get("automation_id") == "CommandLink_1101")["bounds"]["x"] = float("inf")
        write_json(raw_path, raw)
        self.fixture.refresh(self.text)
        with self.assertRaisesRegex(evidence.EvidenceError, "non-finite"):
            self.validate(self.text)

        self.setUp()
        raw_path = self.text / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        tree = raw["assertions"]["scenario"]["confirmation"]["tree"]
        next(row for row in tree if row.get("automation_id") == "CommandLink_1101")["bounds"]["x"] = -0.5
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


class AppearancePairEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.fixture = Fixture(self.root)
        self.run = self.fixture.build_pair()

    def validate(self):
        return evidence.validate_pair_run(self.root, evidence.PAIR_RUN_ID, SOURCE)

    def v2_transport(self):
        """Bind a synthetic V2 cleanup record to the paired observer result."""
        manifest_path = self.run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        profile = (SCRIPT_ROOT.parent / "config" / "vm-automated-v2.json").read_bytes()
        profile_path = self.run / "inputs" / "vm-automated-v2.json"
        profile_path.write_bytes(profile)
        profile_hash = digest(profile)
        manifest["acceptance_profile_id"] = "vm-automated-v2-owned-resources"
        manifest["acceptance_profile_sha256"] = profile_hash
        manifest["acceptance_profile"] = {
            "file": "inputs/vm-automated-v2.json", "bytes": len(profile), "sha256": profile_hash,
        }
        manifest["command"] += ["--acceptance-profile-id", "vm-automated-v2-owned-resources"]
        write_json(manifest_path, manifest)
        raw_path = self.run / "output" / "acceptance-result.json"
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
        transport_path = self.run / "output" / "transport.json"
        transport = json.loads(transport_path.read_text())
        transport["raw_cleanup"] = cleanup
        write_json(transport_path, transport)
        self.fixture.refresh(self.run)
        return manifest, transport, raw

    def check_v2_transport(self, manifest, transport, raw):
        transport_path = self.run / "output" / "transport.json"
        write_json(transport_path, transport)
        receipt = {"bytes": len(transport_path.read_bytes()),
                   "sha256": digest(transport_path.read_bytes())}
        evidence.validate_pair_transport(self.run, {"transport.json": receipt}, 0, manifest, raw)

    def test_v2_pair_accepts_bound_owned_cleanup_with_ambient_processes(self):
        manifest, transport, raw = self.v2_transport()
        self.assertTrue(transport["raw_cleanup"]["unexpected_runner_processes"])
        self.check_v2_transport(manifest, transport, raw)
        self.assertEqual(self.validate()["status"], "passed")

    def test_v2_pair_rejects_unbound_profile_artifact_and_selection(self):
        manifest, _, _ = self.v2_transport()
        profile_path = self.run / "inputs" / "vm-automated-v2.json"
        manifest_path = self.run / "input-manifest.json"
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
                    evidence.validate_input_manifest(self.run, SOURCE)
        write_json(manifest_path, manifest)
        profile_path.write_bytes(original_profile + b" ")
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_input_manifest(self.run, SOURCE)
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
                    evidence.validate_input_manifest(self.run, SOURCE)

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
        actual = json.loads((self.run / "output/run-result.json").read_text())["actual"]
        base = json.loads((self.run / "output/acceptance-result.json").read_text())
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
        path = self.run / "output" / name
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
        rows = evidence.validate_pair_high_contrast(self.run, raw, files, actual, capture_pixels)
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
                    evidence.validate_pair_high_contrast(self.run, raw, files, actual, capture_pixels)

    def test_high_contrast_probe_rejects_unchanged_palette_and_native_selection_override(self):
        raw, files, actual, capture_pixels, _, _, pixels = self.high_contrast_probe()
        active = raw["assertions"]["scenario"]["high_contrast"]["active"]
        active["colors"] = raw["assertions"]["scenario"]["high_contrast"]["before"]["colors"]
        active_pixels = bytearray(pixels["appearance-system-before.png"])
        for y in range(176, 184):
            active_pixels[(y * 800 + 325) * 4:(y * 800 + 342) * 4] = b"\x00\x00\x00\xff" * 17
        pixels["appearance-system-forced-colors.png"] = bytes(active_pixels)
        with self.assertRaisesRegex(evidence.EvidenceError, "did not bind or change"):
            evidence.validate_pair_high_contrast(self.run, raw, files, actual, capture_pixels)

        raw, files, actual, capture_pixels, _, _, pixels = self.high_contrast_probe()
        name = "appearance-system-forced-colors.png"
        pixels[name] = pixels["appearance-system-before.png"]
        with self.assertRaisesRegex(evidence.EvidenceError, "warning or native selection color precedence"):
            evidence.validate_pair_high_contrast(self.run, raw, files, actual, capture_pixels)

    def test_high_contrast_probe_rejects_system_endpoint_raster_change(self):
        raw, files, actual, capture_pixels, _, _, pixels = self.high_contrast_probe()
        changed = bytearray(pixels["appearance-system-after.png"])
        offset = (240 * 800 + 400) * 4
        changed[offset:offset + 3] = b"\x00\x00\x00"
        pixels["appearance-system-after.png"] = bytes(changed)
        with self.assertRaisesRegex(evidence.EvidenceError, "endpoint client raster did not restore"):
            evidence.validate_pair_high_contrast(self.run, raw, files, actual, capture_pixels)

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
        raw = json.loads((self.run / "output/acceptance-result.json").read_text())
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
        raw = json.loads((self.run / "output/acceptance-result.json").read_text())
        actual = json.loads((self.run / "output/run-result.json").read_text())["actual"]
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
        path = self.run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        sample = raw["assertions"]["scenario"]["transition_preservation"]["observations"][1]
        for receipt in (sample, sample["observer_read_native_after"], sample["settlement"]):
            receipt["horizontal_scroll"][3] = 0
        write_json(path, raw)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "non-minimum committed position"):
            self.validate()

    def test_clean_default_rejects_custom_input_missing_phase_and_changed_column(self):
        raw = json.loads((self.run / "output/acceptance-result.json").read_text())
        actual = json.loads((self.run / "output/run-result.json").read_text())["actual"]
        files = {row["relative_path"]: row for row in json.loads((self.run / "collection.json").read_text())["files"]}
        self.assertEqual(evidence.validate_pair_default_columns(self.run, raw, files, actual)["status"], "passed")
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
            image = (self.run / "output" / step["capture"]["file"]).read_bytes()
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
                    evidence.validate_pair_default_columns(self.run, changed, files, actual)

    def test_whole_pair_rejects_preseeded_default_columns(self):
        path = self.run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        raw["assertions"]["scenario"]["default_columns"]["fixture"]["settings_absent_before_launch"] = False
        write_json(path, raw)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "preseeded"):
            self.validate()

    def test_default_original_dark_text_fragments_fail_after_receipts_are_rebound(self):
        for label in ("header", "current-name"):
            with self.subTest(label=label):
                self.setUp()
                path = self.run / "output/acceptance-result.json"
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
                (self.run / "output" / dark_name).write_bytes(changed_png)
                changed_hash = digest(changed_png)
                receipt = next(item for item in raw["screenshots"] if item["file"] == dark_name)
                receipt["sha256"] = changed_hash
                dark = raw["assertions"]["scenario"]["default_columns"]["steps"][1]
                dark["capture"]["sha256"] = changed_hash
                write_json(path, raw)
                self.fixture.refresh(self.run)
                collection = json.loads((self.run / "collection.json").read_text())
                self.assertEqual(next(item["sha256"] for item in collection["files"]
                                      if item["relative_path"] == dark_name), changed_hash)
                with self.assertRaisesRegex(evidence.EvidenceError, "text ink was clipped or changed"):
                    self.validate()

    def test_pair_selection_cell_identity_and_geometry_stay_bound_across_focus(self):
        for field, expected in (("bounds", "native row geometry"),
                                ("name", "native row geometry"),
                                ("keyboard_focusable", "focusability is invalid")):
            with self.subTest(field=field):
                self.setUp()
                path = self.run / "output/acceptance-result.json"
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
                self.fixture.refresh(self.run)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    self.validate()

    def test_pair_preference_and_tooltip_changes_rejected(self):
        for key, value, expected in (
            ("column_preference_sha256", "f" * 64, "column preference changed"),
            ("native_focus", [2001, 0, 32773], "native focus differs"),
            ("overlay", {"visible_tooltip_count": 1, "neutral_cursor": True}, "visible tooltip"),
        ):
            with self.subTest(key=key):
                self.setUp()
                path = self.run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                raw["assertions"]["scenario"]["scenes"]["empty"][0]["state"][key] = value
                write_json(path, raw)
                self.fixture.refresh(self.run)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    self.validate()

    def test_missing_pair_capture_rejected(self):
        raw_path = self.run / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["screenshots"].pop()
        write_json(raw_path, raw)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "exactly 69 original captures"):
            self.validate()

    def test_proposal_viewport_must_match_exact_native_request(self):
        for key in ("proposal_viewport", "horizontal_scroll"):
            with self.subTest(key=key):
                self.setUp()
                path = self.run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                state = raw["assertions"]["scenario"]["scenes"]["changed"][0]["state"]
                if key == "proposal_viewport":
                    state[key]["observed"] += 6
                else:
                    state[key][3] += 6
                    state[key][4] += 6
                write_json(path, raw)
                self.fixture.refresh(self.run)
                with self.assertRaisesRegex(evidence.EvidenceError, "exact native pixel request"):
                    self.validate()

    def test_pair_source_executable_and_environment_bindings_rejected(self):
        manifest_path = self.run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["source_sha"] = "f" * 40
        write_json(manifest_path, manifest)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "source_sha"):
            self.validate()

        self.setUp()
        manifest_path = self.run / "input-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["artifacts"]["application"]["sha256"] = "f" * 64
        write_json(manifest_path, manifest)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "artifacts.application bytes"):
            self.validate()

        self.setUp()
        raw_path = self.run / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        raw["assertions"]["scenario"]["environment"]["hwnd_dpi"] = 144
        write_json(raw_path, raw)
        self.fixture.refresh(self.run)
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
                self.setUp()
                path = self.run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                interaction = raw["assertions"]["scenario"]["interactions"][1]
                if field == "pressed":
                    interaction["buttons"]["pressed"]["native_button_state"] = value
                elif field in {"default_button_id", "default_button_query"}:
                    interaction["input_prompt"][field] = value
                else:
                    interaction[field] = value
                write_json(path, raw)
                self.fixture.refresh(self.run)
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    self.validate()

    def test_pair_keyboard_focus_cannot_claim_mouse_hover(self):
        path = self.run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        focus = raw["assertions"]["scenario"]["interactions"][1]["buttons"]["keyboard-focus"]
        focus["cursor"] = [715, 216, 3001, 1001]
        write_json(path, raw)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "cursor does not match"):
            self.validate()

    def test_pair_target_client_awareness_and_font_bindings_rejected(self):
        for field, message in (("awareness", "DPI awareness"), ("client", "client bounds"),
                               ("font", "font descriptor")):
            with self.subTest(field=field):
                self.setUp()
                path = self.run / "output/acceptance-result.json"
                raw = json.loads(path.read_text())
                rendering = raw["assertions"]["scenario"]["scenes"]["empty"][1]["state"]["target_rendering"]
                if field == "awareness":
                    rendering["awareness"]["per_monitor_v2"] = False
                elif field == "client":
                    rendering["client"]["width"] += 1
                else:
                    rendering["system_font_recipe"]["fonts"]["MessageFont"]["height"] = 0
                write_json(path, raw)
                self.fixture.refresh(self.run)
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    self.validate()

    def test_pair_scroll_tracking_binding_and_restoration_rejected(self):
        for field, message in (("capture", "native capture state"),
                               ("geometry", "thumb geometry"),
                               ("drag", "did not advance"),
                               ("restore", "was not restored")):
            with self.subTest(field=field):
                self.setUp()
                path = self.run / "output/acceptance-result.json"
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
                self.fixture.refresh(self.run)
                with self.assertRaisesRegex(evidence.EvidenceError, message):
                    self.validate()

    def test_pair_bright_dark_scrollbar_rejected_with_matching_receipts(self):
        path = self.run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        step = raw["assertions"]["scenario"]["interactions"][1]["scrollbars"]["horizontal"]["steps"][1]
        name = step["capture"]["file"]
        image = pair_png((36, 36, 36), patches=((40, 432, 620, 449, (255, 255, 255)),))
        (self.run / "output" / name).write_bytes(image)
        step["capture"]["sha256"] = digest(image)
        for capture in raw["screenshots"]:
            if capture["file"] == name:
                capture["sha256"] = digest(image)
        write_json(path, raw)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "scrollbar thumb palette raster violation"):
            self.validate()

    def test_pair_light_endpoint_state_loss_rejected_with_matching_receipts(self):
        path = self.run / "output/acceptance-result.json"
        raw = json.loads(path.read_text())
        step = raw["assertions"]["scenario"]["scenes"]["unchanged"][2]
        name = step["capture"]["file"]
        image = pair_png((245, 245, 245), patches=((100, 250, 200, 260, (23, 25, 28)),
            (39, 108, 40, 442, (217, 221, 227)), (48, 124, 80, 125, (217, 221, 227)), (48, 450, 80, 451, (217, 221, 227))))
        (self.run / "output" / name).write_bytes(image)
        step["capture"]["sha256"] = digest(image)
        for capture in raw["screenshots"]:
            if capture["file"] == name:
                capture["sha256"] = digest(image)
        write_json(path, raw)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "Light endpoint client raster did not restore"):
            self.validate()

    def test_pair_region_visual_violation_rejected_with_matching_receipt(self):
        name = "appearance-empty-dark.png"
        image = pair_png((245, 245, 245), patches=((39, 108, 40, 442, (55, 60, 67)),
            (48, 124, 80, 125, (55, 60, 67)), (48, 450, 80, 451, (55, 60, 67))))
        (self.run / "output" / name).write_bytes(image)
        raw_path = self.run / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        for capture in raw["screenshots"]:
            if capture["file"] == name:
                capture["sha256"] = digest(image)
        raw["assertions"]["scenario"]["scenes"]["empty"][1]["capture"]["sha256"] = digest(image)
        write_json(raw_path, raw)
        self.fixture.refresh(self.run)
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
        (self.run / "output" / name).write_bytes(image)
        raw_path = self.run / "output/acceptance-result.json"
        raw = json.loads(raw_path.read_text())
        for receipt in raw["screenshots"]:
            if receipt["file"] == name:
                receipt["sha256"] = digest(image)
        raw["assertions"]["scenario"]["scenes"]["changed"][1]["capture"]["sha256"] = digest(image)
        write_json(raw_path, raw)
        self.fixture.refresh(self.run)
        with self.assertRaisesRegex(evidence.EvidenceError, "semantic color leaked into current-name"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
