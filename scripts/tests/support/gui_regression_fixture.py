"""Synthetic GUI regression evidence for producer and validator suites."""

from __future__ import annotations

import hashlib
import json
from functools import lru_cache
from pathlib import Path
import struct
import zlib

from tooling_test_paths import SCRIPT_ROOT


SCRIPT = (SCRIPT_ROOT / "validate-gui-regression-evidence.py")
SOURCE = "a" * 40
TREE = "b" * 40

# Frozen producer sample values. Validation uses the independent evidence module.
FIXTURE_MODE_SEMANTICS = {
    'full-context': frozenset({
        'journal_clean',
        'mixed_default_enter_cancelled',
        'mixed_disk_unchanged',
        'mixed_examples_exclude_third_move',
        'mixed_expanded_bottom_reached_or_fits',
        'mixed_plan_identity_stable',
        'mixed_reentry_default_cancel',
        'mixed_reentry_full_details_end_visible',
        'mixed_reentry_full_details_exact_document',
        'mixed_scope_exact',
        'mixed_third_details_closed',
        'mixed_third_details_end_visible',
        'mixed_third_details_exact_document',
        'movement_applied',
        'movement_cancelled',
        'movement_content_preserved',
        'movement_destination_reached',
        'movement_identity_preserved',
        'movement_journal_clean',
        'normal_exit',
        'repeated_cancel_disk_unchanged',
        'repeated_default_cancel',
        'repeated_full_details_end_visible',
        'repeated_full_details_exact_document',
        'repeated_return_default_cancel',
        'repeated_scope_exact',
    }),
    'standard': frozenset({
        'application_confirmed',
        'content_preserved',
        'destination_reached',
        'full_details_text_observed',
        'identity_preserved',
        'input_text_observed',
        'journal_clean',
        'normal_exit',
        'scope_exact',
        'total_3_selected_1_changed_2',
    }),
    'text-scale': frozenset({
        'application_confirmed',
        'content_preserved',
        'destination_reached',
        'full_details_text_enlarged',
        'full_details_text_observed',
        'identity_preserved',
        'input_text_enlarged',
        'input_text_observed',
        'journal_clean',
        'normal_exit',
        'required_controls_reachable',
        'scope_exact',
        'settings_restored',
        'taskdialog_limit_recorded',
        'text_scale_observed_150',
        'text_scale_requested_150',
        'total_3_selected_1_changed_2',
    }),
    'tooltip': frozenset({
        'cancellation_returned_to_preview',
        'cancelled_disk_unchanged',
        'cancelled_fixture_identity_unchanged',
        'destination_context_visible',
        'expanded_bottom_reached',
        'full_details_end_visible',
        'full_details_exact_document',
        'full_details_return_default_cancel',
        'journal_clean',
        'long_row_tooltip_visible_before_apply',
        'normal_exit',
        'public_apply_entered',
        'tooltip_hidden_after_details_return',
        'tooltip_hidden_after_expansion',
        'tooltip_hidden_after_neutral',
        'tooltip_hidden_on_entry',
        'tooltip_hidden_settled',
        'tooltip_restored_after_cancel',
    }),
}
FIXTURE_PAIR_MODE = 'appearance-pair'
FIXTURE_FOCUSED_CLEAR_MODE = 'focused-10k-clear'
FIXTURE_PAIR_RUN_ID = 'appearance-pair-light-dark-light'
FIXTURE_PAIR_SCENES = ('empty', 'unchanged', 'overflow', 'changed', 'collision', 'warning', 'selected-active', 'selected-inactive')
FIXTURE_PAIR_PHASES = ('light-before', 'dark', 'light-after')
FIXTURE_PAIR_SCROLL_AXES = ('horizontal', 'vertical')
FIXTURE_PAIR_SCROLL_STAGES = ('held', 'moving', 'released')
FIXTURE_PAIR_BUTTON_STATES = ('normal', 'disabled', 'hover', 'pressed', 'keyboard-focus')
FIXTURE_PAIR_SCOPE = 'appearance-pair-main-and-interactions-v3'
FIXTURE_PAIR_TRANSITION_PHASES = ('before_dark', 'after_dark', 'before_light', 'after_light')
FIXTURE_REFERENCE_SCOPE = ('full-context-semantics-v1',)
FIXTURE_PAIR_SCENE_ROWS = {
    'empty': 0,
    'unchanged': 1,
    'overflow': 60,
    'changed': 60,
    'collision': 60,
    'warning': 60,
    'selected-active': 60,
    'selected-inactive': 60,
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def write_json(path: Path, value: object) -> None:
    path.write_bytes(json_bytes(value))


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def rgba_pixels(width: int, height: int, ink_height: int, ink_width: int,
                *, transparent: bool = False) -> bytes:
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            ink = 10 <= x < 10 + ink_width and 5 <= y < 5 + ink_height
            alpha = 0 if transparent and x == 0 and y == 0 else 255
            pixels.extend((0, 0, 0, alpha) if ink else (255, 255, 255, alpha))
    return bytes(pixels)


def png(width: int = 80, height: int = 30, ink_height: int = 8, ink_width: int = 20,
        *, transparent: bool = False) -> bytes:
    rgba = rgba_pixels(width, height, ink_height, ink_width, transparent=transparent)
    pixels = b"".join(b"\x00" + rgba[y * width * 4:(y + 1) * width * 4]
                      for y in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", zlib.compress(pixels)) + png_chunk(b"IEND", b"")


@lru_cache(maxsize=64)
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
            ink_height = 12 if mode == "text-scale" else 8
            ink_width = 28 if mode == "text-scale" else 20
            rgba = rgba_pixels(80, 30, ink_height, ink_width)
            crop_hash = digest(bytes(value for index, value in enumerate(rgba) if index % 4 != 3))
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
        if manifest["request"]["mode"] == FIXTURE_FOCUSED_CLEAR_MODE:
            active = json.loads((run / "inputs" / "bundle.json").read_text())
            raw.pop("source_sha")
            raw["schema_version"] = 2
            raw["lane"] = raw.get("lane", active["lane"])
            raw["product"] = raw.get("product", active["product"])
            raw["harness"] = raw.get("harness", active["harness"])
            raw["observer_role"] = raw.get("observer_role", "ui")
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
                "semantics": {name: True for name in sorted(FIXTURE_MODE_SEMANTICS.get(request["mode"], ()))},
            },
            "status": "review_required",
        }
        if request["mode"] == FIXTURE_PAIR_MODE:
            result = {
                "schema_version": 1, "diagnostic": FIXTURE_PAIR_MODE, "run_id": run.name,
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
        run = self.build(FIXTURE_PAIR_RUN_ID, "standard")
        output = run / "output"
        manifest = json.loads((run / "input-manifest.json").read_text())
        manifest["request"]["mode"] = FIXTURE_PAIR_MODE
        manifest["acceptance_profile_id"] = "vm-automated-v1-win11-ntfs"
        manifest["command"] = ["python3", "-I", "scripts/run-gui-regression.py", "--diagnostic", FIXTURE_PAIR_MODE]
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
        for scene in FIXTURE_PAIR_SCENES:
            count = FIXTURE_PAIR_SCENE_ROWS[scene]
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
            for phase in FIXTURE_PAIR_PHASES:
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
        for phase in FIXTURE_PAIR_PHASES:
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
            for button_state in FIXTURE_PAIR_BUTTON_STATES:
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
            for axis in FIXTURE_PAIR_SCROLL_AXES:
                bar = ([40, 432, 620, 449, 17, 17, 117] if axis == "horizontal" else
                       [623, 125, 640, 432, 17, 17, 77]) + [0] * 6
                initial = [0, 1000, 100, 0, 0]
                steps = []
                for stage in FIXTURE_PAIR_SCROLL_STAGES:
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
        raw["assertions"]["scope"] = FIXTURE_PAIR_SCOPE
        transition_names = [f"{index:02d}-한국어-日本語.txt" for index in range(60)]
        transition_samples = []
        for phase, appearance in zip(FIXTURE_PAIR_TRANSITION_PHASES,
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
        for phase in FIXTURE_PAIR_PHASES:
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
                "snapshot_order": list(FIXTURE_PAIR_TRANSITION_PHASES),
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
            "scope": list(FIXTURE_REFERENCE_SCOPE),
        }
