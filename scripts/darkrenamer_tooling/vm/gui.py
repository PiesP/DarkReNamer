"""Run fixed GUI cells or an opt-in appearance/performance diagnostic."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

from darkrenamer_tooling.vm import launcher
from darkrenamer_tooling.vm import host_tools
from darkrenamer_tooling.vm.connection import load_connection_profile, guest_preflight
from darkrenamer_tooling.formats.png import PngPolicy, decode_png_bytes
from darkrenamer_tooling.contracts.tooling import (
    RECORD_NAME, stage_verified_tooling, staged_tooling_files, trusted_tooling_inventory,
)


SAFE_LEAF = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,159}")
SHA256 = re.compile(r"[0-9a-f]{64}")
SOURCE_SHA = re.compile(r"[0-9a-f]{40}")
V1_PROFILE_ID = "vm-automated-v1-win11-ntfs"
V2_PROFILE_ID = "vm-automated-v2-owned-resources"
V2_PROFILE_FILE = "vm-automated-v2.json"
MAX_PNG_PIXELS = 32 * 1024 * 1024
MAX_PNG_DECODED_BYTES = 128 * 1024 * 1024
RUNS = (
    {
        "run_id": "01-full-context-light-800x600-96-text100",
        "mode": "full-context",
        "appearance": "light",
        "width": 800,
        "height": 600,
        "dpi": 96,
        "text_scale_percent": 100,
    },
    {
        "run_id": "02-standard-light-800x600-96-text100",
        "mode": "standard",
        "appearance": "light",
        "width": 800,
        "height": 600,
        "dpi": 96,
        "text_scale_percent": 100,
    },
    {
        "run_id": "03-standard-light-800x600-96-text150",
        "mode": "text-scale",
        "appearance": "light",
        "width": 800,
        "height": 600,
        "dpi": 96,
        "text_scale_percent": 150,
    },
    {
        "run_id": "04-tooltip-dark-1366x768-144-text100",
        "mode": "tooltip",
        "appearance": "dark",
        "width": 1366,
        "height": 768,
        "dpi": 144,
        "text_scale_percent": 100,
    },
)
V2_RUNS = tuple({**run, "run_id": f"{run['run_id']}-owned-v2"} for run in RUNS)
APPEARANCE_PAIR_ID = "appearance-pair-light-dark-light"
PERFORMANCE_RUN_ID = "performance-sample-v2-1366x768-96-text100"
FOCUSED_CLEAR_MODE = "focused-10k-clear"
FOCUSED_CLEAR_RUN_ID = "focused-10k-clear-v1-1366x768-96-text100"
FOCUSED_PRESERVED_LANE = "focused-preserved-source-built-product-v1"
FOCUSED_PRODUCT_SOURCE_SHA = "8248c73859e3a3ff0e524fd9448acfe965fa3f68"
FOCUSED_PRODUCT_REFERENCE_SHA = "b152761010b16ef74e2a3765241a253778b88e0b"
FOCUSED_ORIGINAL_BUNDLE_SHA256 = "23f42a2c2af9e7a9417e275e10b9415be46dc05a0ecf610527a89e632ec7f38e"
FOCUSED_APPLICATION_SHA256 = "06c5511e042714f5a343e541856f2dbdc3850d5d60eeb62c3c36c2dacfef2f0f"
FOCUSED_PRODUCT_ENTRIES_SHA256 = "7c4fc53698413bbab601629a5a56c1129ecd96aaac4a98af09530f87b4a25735"
FOCUSED_PRODUCT_ENTRIES_COUNT = 104
FOCUSED_CLEAR_PLAN = {
    "ordinary_rows": [100, 1000, 10000], "idle_seconds": 30,
    "sample_interval_ms": 200, "maximum_seconds": 600,
    "clear_command_id": 0x800E, "stop_after_first_clear": True,
    "full_performance_sample": False,
}
ICON_SETTLEMENT_MODE = "icon-settlement"
ICON_SETTLEMENT_RUN_ID = "icon-settlement-v1-1366x768-96-text100"
ICON_SETTLEMENT_METHOD = "async-status-v1"
ICON_BASELINE_RUN_ID = "icon-settlement-sync-upper-bound-v1-1366x768-96-text100"
ICON_BASELINE_METHOD = "synchronous-row-count-upper-bound-v1"
ICON_BASELINE_PRODUCT_SOURCE_SHA = "b152761010b16ef74e2a3765241a253778b88e0b"
ICON_SETTLEMENT_PLAN = {
    "ordinary_rows": 1000, "churn_rows": 1000, "extension_classes": 300,
    "poll_interval_ms": 100, "maximum_seconds": 600,
}
PERFORMANCE_ORDERS = ("hidden-visible", "visible-hidden")
PERFORMANCE_PLAN = {
    "iterations": 2, "idle_seconds": 30, "maximum_seconds": 600,
    "ordinary_rows": [100, 1000, 10000], "long_path_rows": 1000,
    "extension_classes": 300, "add_remove_reset_cycles": 3,
    "sample_interval_ms": 200,
    "long_path_order": "hidden-visible",
}


def performance_run(order: str = "hidden-visible") -> dict:
    if order not in PERFORMANCE_ORDERS:
        raise ValueError("Unsupported performance long-path order.")
    return {"run_id": f"{PERFORMANCE_RUN_ID}-{order}", "mode": "performance-sample",
            "appearance": "light", "width": 1366, "height": 768, "dpi": 96,
            "text_scale_percent": 100, "long_path_order": order}


def focused_clear_run() -> dict:
    return {"run_id": FOCUSED_CLEAR_RUN_ID, "mode": FOCUSED_CLEAR_MODE,
            "appearance": "light", "width": 1366, "height": 768, "dpi": 96,
            "text_scale_percent": 100}


def icon_settlement_run(endpoint_method: str = ICON_SETTLEMENT_METHOD) -> dict:
    require(endpoint_method in {ICON_SETTLEMENT_METHOD, ICON_BASELINE_METHOD},
            "Icon settlement endpoint method is unsupported.")
    return {"run_id": ICON_BASELINE_RUN_ID if endpoint_method == ICON_BASELINE_METHOD
            else ICON_SETTLEMENT_RUN_ID, "mode": ICON_SETTLEMENT_MODE,
            "appearance": "light", "width": 1366, "height": 768, "dpi": 96,
            "text_scale_percent": 100, "acceptance_profile_id": V2_PROFILE_ID,
            "endpoint_method": endpoint_method,
            **({"baseline_product_source_sha": ICON_BASELINE_PRODUCT_SOURCE_SHA}
               if endpoint_method == ICON_BASELINE_METHOD else {})}


def appearance_pair_run(width: int, height: int, dpi: int, *,
                        run_id: str = APPEARANCE_PAIR_ID,
                        text_scale_percent: int = 100,
                        high_contrast: bool = False) -> dict:
    return {
        "run_id": run_id, "mode": "appearance-pair",
        "appearance": "system" if high_contrast else "light",
        "width": width, "height": height, "dpi": dpi,
        "text_scale_percent": text_scale_percent, "high_contrast": high_contrast,
    }


FOCUSED_PAIR_RUNS = (
    appearance_pair_run(1920, 1080, 96, run_id="appearance-pair-base-1920x1080-96-text100"),
    appearance_pair_run(1920, 1080, 144, run_id="appearance-pair-fractional-1920x1080-144-text100"),
    appearance_pair_run(1920, 1080, 192, run_id="appearance-pair-high-1920x1080-192-text100"),
    appearance_pair_run(1920, 1080, 96, run_id="appearance-pair-text150-1920x1080-96-text150",
                        text_scale_percent=150),
    appearance_pair_run(1920, 1080, 96, run_id="appearance-pair-forced-colors-1920x1080-96-text100",
                        high_contrast=True),
)

FULL_CONTEXT_SEMANTICS = {
    "repeated_scope_exact", "repeated_default_cancel",
    "repeated_full_details_exact_document", "repeated_full_details_end_visible",
    "repeated_return_default_cancel", "repeated_cancel_disk_unchanged",
    "movement_cancelled", "movement_applied", "movement_destination_reached",
    "movement_content_preserved", "movement_identity_preserved", "movement_journal_clean",
    "mixed_scope_exact", "mixed_examples_exclude_third_move",
    "mixed_third_details_exact_document", "mixed_third_details_end_visible",
    "mixed_third_details_closed", "mixed_reentry_full_details_exact_document",
    "mixed_reentry_full_details_end_visible", "mixed_reentry_default_cancel",
    "mixed_expanded_bottom_reached_or_fits", "mixed_default_enter_cancelled",
    "mixed_disk_unchanged", "mixed_plan_identity_stable", "journal_clean", "normal_exit",
}
STANDARD_SEMANTICS = {
    "scope_exact", "total_3_selected_1_changed_2", "application_confirmed",
    "destination_reached", "content_preserved", "identity_preserved", "journal_clean",
    "input_text_observed", "full_details_text_observed", "normal_exit",
}
TEXT_SCALE_SEMANTICS = STANDARD_SEMANTICS | {
    "text_scale_requested_150", "text_scale_observed_150", "input_text_enlarged",
    "full_details_text_enlarged", "required_controls_reachable",
    "taskdialog_limit_recorded", "settings_restored",
}
TOOLTIP_SEMANTICS = {
    "long_row_tooltip_visible_before_apply", "tooltip_hidden_on_entry",
    "tooltip_hidden_settled", "tooltip_hidden_after_details_return",
    "tooltip_hidden_after_expansion", "tooltip_restored_after_cancel",
    "tooltip_hidden_after_neutral", "public_apply_entered", "destination_context_visible",
    "cancelled_disk_unchanged", "cancelled_fixture_identity_unchanged",
    "full_details_exact_document", "full_details_end_visible",
    "full_details_return_default_cancel", "expanded_bottom_reached",
    "cancellation_returned_to_preview", "journal_clean", "normal_exit",
}
MODE_SEMANTICS = {
    "full-context": FULL_CONTEXT_SEMANTICS,
    "standard": STANDARD_SEMANTICS,
    "text-scale": TEXT_SCALE_SEMANTICS,
    "tooltip": TOOLTIP_SEMANTICS,
}


def digest(path: Path) -> str:
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def digest_text(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    require(isinstance(value, dict), f"{path.name} must contain a JSON object.")
    return value


def write_json(path: Path, value: object, *, exclusive: bool = False) -> None:
    data = (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()
    if exclusive:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
    else:
        path.write_bytes(data)


GUI_PNG_POLICY = PngPolicy(
    color_types=frozenset({2, 6}), maximum_pixels=MAX_PNG_PIXELS,
    maximum_dimension=8192, maximum_decoded_bytes=MAX_PNG_DECODED_BYTES,
    maximum_compressed_bytes=128 * 1024 * 1024,
)


def decode_png(path: Path) -> tuple[int, int, bytes]:
    data = ordinary_file(path, 128 * 1024 * 1024, "Raster screenshot").read_bytes()
    return decode_png_bytes(data, policy=GUI_PNG_POLICY)


def write_text_raster_metrics(run_root: Path) -> None:
    output = run_root / "output"
    manifest_path = run_root / "input-manifest.json"
    manifest = read_json(manifest_path)
    observations = read_json(output / "acceptance-observations.json")
    targets = observations.get("text_raster_targets")
    require(isinstance(targets, list) and len(targets) == 2,
            "Observer must bind two native label raster targets.")
    samples = []
    for target in targets:
        require(isinstance(target, dict) and target.get("id") in {"prefix-input", "full-details"},
                "Observer returned an invalid raster target.")
        image_name = target.get("image")
        require(isinstance(image_name, str) and SAFE_LEAF.fullmatch(image_name) is not None
                and image_name.endswith(".png"), "Raster target image has an unsafe name.")
        width, height, rgba = decode_png(output / image_name)
        origin = target.get("screenshot_origin", {})
        rectangle = target.get("control_rect", {})
        require(all(type(origin.get(name)) is int for name in ("x", "y"))
                and all(type(rectangle.get(name)) is int for name in ("left", "top", "width", "height")),
                "Raster target geometry must use integer physical pixels.")
        crop = {
            "x": rectangle["left"] - origin["x"],
            "y": rectangle["top"] - origin["y"],
            "width": rectangle["width"],
            "height": rectangle["height"],
        }
        require(crop["x"] >= 0 and crop["y"] >= 0 and crop["width"] > 0 and crop["height"] > 0
                and crop["x"] + crop["width"] <= width and crop["y"] + crop["height"] <= height,
                "Native label rectangle lies outside its captured PNG.")
        rgb = bytearray()
        ink_x = []
        ink_y = []
        for row in range(crop["height"]):
            start = ((crop["y"] + row) * width + crop["x"]) * 4
            for column in range(crop["width"]):
                pixel = rgba[start + column * 4:start + (column + 1) * 4]
                require(pixel[3] == 255, "Raster proof requires an opaque screenshot.")
                rgb.extend(pixel[:3])
                if max(pixel[:3]) < 120:
                    ink_x.append(column)
                    ink_y.append(row)
        require(ink_x, "Native label crop contains no fixed-threshold ink.")
        samples.append({
            "id": target["id"], "text_sha256": target.get("text_sha256"),
            "image": image_name, "observed_target": target, "crop": crop,
            "raster_sha256": hashlib.sha256(rgb).hexdigest(),
            "ink_threshold_max_rgb": 120,
            "ink_bounds": {
                "x": min(ink_x), "y": min(ink_y),
                "width": max(ink_x) - min(ink_x) + 1,
                "height": max(ink_y) - min(ink_y) + 1,
            },
            "ink_pixel_count": len(ink_x),
        })
    require({sample["id"] for sample in samples} == {"prefix-input", "full-details"},
            "Raster target ids are missing or duplicated.")
    write_json(output / "text-raster-metrics.json", {
        "schema_version": 1, "run_id": manifest["run_id"],
        "input_manifest_sha256": digest(manifest_path), "samples": samples,
    }, exclusive=True)


def ordinary_file(path: Path, maximum: int, label: str) -> Path:
    require(path.is_file() and not path.is_symlink(), f"{label} must be an ordinary file.")
    require(path.stat().st_size <= maximum, f"{label} exceeds its size bound.")
    return path


def checked_new_root(path: Path, repo: Path) -> Path:
    require(path.is_absolute(), "--output-root must be absolute.")
    require(SAFE_LEAF.fullmatch(path.name) is not None, "Output root needs a safe leaf name.")
    parent = path.parent.resolve(strict=True)
    require(parent.is_dir() and not path.parent.is_symlink(), "Output parent must be an ordinary directory.")
    target = parent / path.name
    require(not target.exists(), "Output root must not already exist.")
    require(not target.is_relative_to(repo) and not repo.is_relative_to(target), "Output root must be outside the checkout.")
    return target


def artifact(path: Path, relative: str | None = None) -> dict:
    path = ordinary_file(path, 512 * 1024 * 1024, path.name)
    return {"file": relative or path.name, "sha256": digest(path), "bytes": path.stat().st_size}


def materialize_inputs(run_root: Path, sources: dict[str, Path]) -> dict[str, dict]:
    inputs = run_root / "inputs"
    require(not inputs.exists(), "Run inputs already exist.")
    inputs.mkdir()
    rows = {}
    for leaf, source in sources.items():
        require(SAFE_LEAF.fullmatch(leaf) is not None, "Run input has an unsafe leaf name.")
        source = ordinary_file(source, 512 * 1024 * 1024, f"Input {leaf}")
        destination = inputs / leaf
        with source.open("rb") as reader, destination.open("xb") as writer:
            shutil.copyfileobj(reader, writer, 1024 * 1024)
        rows[leaf] = artifact(destination, f"inputs/{leaf}")
    return rows


def semantic_assertions(assertions: dict, mode: str, projection: dict[str, bool]) -> dict:
    require(assertions.get("overall") == "passed", "Raw observer assertions did not pass.")
    expected = MODE_SEMANTICS[mode]
    require(set(projection) == expected and all(value is True for value in projection.values()),
            f"Derived {mode} semantic assertion set is incomplete or failed.")
    return {"overall": "passed", "semantics": {name: projection[name] for name in sorted(expected)}}


def nested(value: object, *parts: str) -> object:
    for part in parts:
        if not isinstance(value, dict):
            return None
        value = value.get(part)
    return value


def int_equals(value: object, expected: int) -> bool:
    return type(value) is int and value == expected


def default_cancel(value: object) -> bool:
    return isinstance(value, dict) and value.get("is_default_cancel") is True


def returned_to_preview(value: object, expected_input: str | None = None) -> bool:
    return isinstance(value, dict) and (
        expected_input is None or value.get("input") == expected_input
    ) and value.get("returned_to_preview") is True and value.get("default_cancel_preserved") is True


def valid_apply_entry(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {"input", "menu_entry"}:
        return False
    if value["input"] == "visible-command-rail":
        return value["menu_entry"] is None
    if value["input"] != "physical-mouse-file-menu-public-apply":
        return False
    menu = value["menu_entry"]
    if not isinstance(menu, dict) or set(menu) != {
        "file", "file_target", "apply", "apply_target",
    }:
        return False

    def valid_element(element: object, expected_name: str, contains: bool = False) -> bool:
        if not isinstance(element, dict) or set(element) != {
            "automation_id", "name", "control_type", "enabled", "keyboard_focusable",
            "offscreen", "native_handle", "bounds",
        }:
            return False
        name = element["name"]
        bounds = element["bounds"]
        return isinstance(element["automation_id"], str) and isinstance(name, str) and \
            ((expected_name in name) if contains else (name == expected_name)) and \
            element["control_type"] == "ControlType.MenuItem" and element["enabled"] is True and \
            type(element["keyboard_focusable"]) is bool and element["offscreen"] is False and \
            type(element["native_handle"]) is int and isinstance(bounds, dict) and \
            set(bounds) == {"x", "y", "width", "height"} and \
            all(type(bounds[key]) in {int, float} and math.isfinite(bounds[key])
                for key in bounds) and bounds["width"] > 0 and bounds["height"] > 0

    def valid_target(target: object, element: object) -> bool:
        if not isinstance(target, dict) or set(target) != {
            "x", "y", "hit_window", "root_window",
        } or not all(type(target[key]) is int for key in target):
            return False
        bounds = element["bounds"]
        return target["hit_window"] != 0 and target["root_window"] != 0 and \
            bounds["x"] <= target["x"] < bounds["x"] + bounds["width"] and \
            bounds["y"] <= target["y"] < bounds["y"] + bounds["height"]

    file_element = menu["file"]
    apply_element = menu["apply"]
    return valid_element(file_element, "파일(F)") and \
        valid_element(apply_element, "변경 사항 적용", contains=True) and \
        valid_target(menu["file_target"], file_element) and \
        valid_target(menu["apply_target"], apply_element)


def reachability_valid(value: object) -> bool:
    return isinstance(value, dict) and value.get("status") == "reachable" and \
        value.get("inside_work_area") is True and \
        type(nested(value, "physical_mouse_target", "hit_window")) is int and \
        nested(value, "physical_mouse_target", "hit_window") != 0


def visible_control(tree: object, automation_id: str, work_area: dict) -> bool:
    if not isinstance(tree, list):
        return False
    for value in tree:
        if not isinstance(value, dict) or value.get("automation_id") != automation_id or \
                value.get("enabled") is not True or value.get("offscreen") is not False:
            continue
        bounds = value.get("bounds")
        if isinstance(bounds, dict) and all(
                type(bounds.get(name)) in {int, float} and math.isfinite(bounds[name])
                for name in ("x", "y", "width", "height")) and \
                bounds["width"] > 0 and bounds["height"] > 0 and \
                work_area["left"] <= bounds["x"] and work_area["top"] <= bounds["y"] and \
                bounds["x"] + bounds["width"] <= work_area["right"] and \
                bounds["y"] + bounds["height"] <= work_area["bottom"]:
            return True
    return False


def text_metric_samples(path: Path) -> dict[str, dict]:
    document = read_json(path)
    samples = document.get("samples")
    require(isinstance(samples, list), "Text raster metrics lack samples.")
    by_id = {sample.get("id"): sample for sample in samples if isinstance(sample, dict)}
    require(set(by_id) == {"prefix-input", "full-details"}, "Text raster metrics have invalid sample ids.")
    return by_id


def project_raw_semantics(observer: dict, cleanup: dict, run_root: Path, mode: str) -> dict[str, bool]:
    scenario = nested(observer, "assertions", "scenario")
    require(isinstance(scenario, dict), "Raw observer scenario evidence is missing.")
    required_controls = ("cancel", "apply", "full_details", "expander")
    if mode == "full-context":
        repeated = nested(scenario, "repeated")
        movement = nested(scenario, "movement")
        mixed = nested(scenario, "mixed")
        zero = nested(repeated, "zero_deletion_and_a_insertion_confirmation")
        korean = nested(repeated, "korean_insertion_confirmation")
        actual_apply = nested(movement, "actual_apply")
        third = nested(mixed, "third_destination_diagnostic")
        reentry = nested(mixed, "reentry_confirmation")
        bottom = nested(reentry, "expanded", "bottom_scroll")
        default_enter = nested(mixed, "default_enter_cancellation")
        projection = {
            "repeated_scope_exact": all(nested(value, "scope_exact") is True for value in (zero, korean)) and all(reachability_valid(nested(zero, "reachability", name)) for name in required_controls),
            "repeated_default_cancel": default_cancel(nested(zero, "default_focus")),
            "repeated_full_details_exact_document": nested(zero, "full_details", "canonical_text", "exact_document") is True,
            "repeated_full_details_end_visible": nested(zero, "full_details", "native_end_scroll", "ending_visible") is True,
            "repeated_return_default_cancel": default_cancel(nested(zero, "full_details", "return_default_cancel")),
            "repeated_cancel_disk_unchanged": nested(repeated, "cancellation_disk_unchanged") is True,
            "movement_cancelled": returned_to_preview(nested(movement, "cancellation_confirmation", "cancellation")) and nested(movement, "cancellation_disk_unchanged") is True,
            "movement_applied": nested(actual_apply, "input") in {"physical-mouse", "keyboard-enter"} and reachability_valid(nested(actual_apply, "reachability")),
            "movement_destination_reached": nested(actual_apply, "destination_reached") is True,
            "movement_content_preserved": nested(actual_apply, "content_preserved") is True,
            "movement_identity_preserved": nested(actual_apply, "identity_preserved") is True,
            "movement_journal_clean": int_equals(nested(actual_apply, "journal_residue_count"), 0),
            "mixed_scope_exact": nested(reentry, "scope_exact") is True and all(reachability_valid(nested(reentry, "reachability", name)) for name in required_controls),
            "mixed_examples_exclude_third_move": nested(mixed, "two_of_three_examples_exclude_third_move") is True,
            "mixed_third_details_exact_document": nested(third, "presentation") == "read-only-multiline-edit" and nested(third, "canonical_text", "exact_document") is True,
            "mixed_third_details_end_visible": nested(third, "native_end_scroll", "ending_visible") is True,
            "mixed_third_details_closed": nested(third, "close", "closed") is True,
            "mixed_reentry_full_details_exact_document": nested(reentry, "full_details", "canonical_text", "exact_document") is True,
            "mixed_reentry_full_details_end_visible": nested(reentry, "full_details", "native_end_scroll", "ending_visible") is True,
            "mixed_reentry_default_cancel": default_cancel(nested(reentry, "full_details", "return_default_cancel")),
            "mixed_expanded_bottom_reached_or_fits": nested(bottom, "status") == "physically-scrolled-to-native-bottom" and nested(bottom, "range_value", "reached_maximum") is True,
            "mixed_default_enter_cancelled": nested(default_enter, "input") == "keyboard-enter-on-default-cancel" and default_cancel(nested(default_enter, "default_focus")) and nested(default_enter, "disk_unchanged") is True and int_equals(nested(default_enter, "journal_residue_count"), 0),
            "mixed_disk_unchanged": returned_to_preview(nested(reentry, "cancellation")) and nested(mixed, "cancellation_disk_unchanged") is True,
            "mixed_plan_identity_stable": nested(mixed, "expanded_plan_identity_stable") is True,
            "journal_clean": all(int_equals(nested(value, "journal_residue_count"), 0) for value in (repeated, mixed, actual_apply, default_enter)),
            "normal_exit": all(int_equals(nested(value, "normal_exit_code"), 0) for value in (repeated, movement, mixed)),
        }
        require(nested(repeated, "inputs_in_admission_order") == [
            "0 x101 -> 0 x100", "a x100 -> a x101", "가 x100 -> 가 x101"
        ], "Raw repeated admission order differs from the fixed scenario.")
    elif mode in {"standard", "text-scale"}:
        fixture = nested(scenario, "fixture")
        confirmation = nested(scenario, "confirmation")
        actual_apply = nested(scenario, "actual_apply")
        details = nested(confirmation, "full_details")
        work_area = nested(scenario, "environment", "work_area")
        require(isinstance(work_area, dict), "Raw standard work area is missing.")
        metrics = text_metric_samples(run_root / "output" / "text-raster-metrics.json")
        projection = {
            "scope_exact": nested(confirmation, "scope_3_1_2") is True and default_cancel(nested(confirmation, "default_focus")) and nested(actual_apply, "scope") == "3/1/2",
            "total_3_selected_1_changed_2": int_equals(nested(fixture, "count"), 3) and int_equals(nested(fixture, "selected"), 1) and int_equals(nested(fixture, "changed"), 2) and int_equals(nested(scenario, "selection", "selected_count"), 1),
            "application_confirmed": valid_apply_entry(nested(actual_apply, "apply_entry")) and nested(actual_apply, "scope") == "3/1/2" and returned_to_preview(nested(confirmation, "cancellation")),
            "destination_reached": nested(actual_apply, "destinations_reached") is True,
            "content_preserved": nested(actual_apply, "content_and_identity_preserved") is True and nested(actual_apply, "unchanged_row_preserved") is True,
            "identity_preserved": nested(actual_apply, "content_and_identity_preserved") is True and nested(actual_apply, "unchanged_row_preserved") is True,
            "journal_clean": int_equals(nested(actual_apply, "journal_residue_count"), 0) and int_equals(nested(scenario, "journal_residue_count"), 0) and nested(scenario, "cancellation_disk_unchanged") is True,
            "input_text_observed": "prefix-input" in metrics,
            "full_details_text_observed": "full-details" in metrics,
            "normal_exit": int_equals(nested(scenario, "normal_exit_code"), 0),
        }
        require(nested(details, "canonical_text", "exact_document") is True and nested(details, "copy_contention", "details_handle_preserved") is True and nested(details, "copy_all_retry", "exact") is True and nested(details, "native_end_scroll", "ending_visible") is True and default_cancel(nested(details, "escape_return_default_cancel")), "Raw standard full-details evidence is incomplete.")
        reachability = all(reachability_valid(nested(confirmation, "reachability", name)) for name in required_controls)
        controls = all(visible_control(nested(confirmation, "tree"), automation_id, work_area) for automation_id in ("CommandLink_1101", "CommandLink_1102", "ExpandoButton", "CommandButton_2"))
        if mode == "standard":
            blocking = nested(scenario, "blocking")
            require(isinstance(blocking, dict) and all(nested(blocking, name, "blocked") is True for name in ("no_change", "collision", "invalid_name")), "Raw text100 blocking evidence is incomplete.")
        else:
            current_manifest = read_json(run_root / "input-manifest.json")
            selected_profile = current_manifest.get("acceptance_profile_id", V1_PROFILE_ID)
            require(selected_profile in {V1_PROFILE_ID, V2_PROFILE_ID},
                    "Text150 acceptance profile is unsupported.")
            fixed_runs = V2_RUNS if selected_profile == V2_PROFILE_ID else RUNS
            require(run_root.name == fixed_runs[2]["run_id"] and
                    current_manifest.get("run_id") == run_root.name,
                    "Text150 run identity differs from its selected profile.")
            baseline_root = run_root.parent / fixed_runs[1]["run_id"]
            require(baseline_root.is_dir() and not baseline_root.is_symlink(),
                    "Text100 reference for the selected profile is missing or unsafe.")
            baseline_manifest = read_json(ordinary_file(
                baseline_root / "input-manifest.json", 2 * 1024 * 1024, "Text100 input manifest"))
            require(baseline_manifest.get("run_id") == baseline_root.name and
                    nested(baseline_manifest, "request", "mode") == "standard" and
                    baseline_manifest.get("acceptance_profile_id", V1_PROFILE_ID) == selected_profile and
                    baseline_manifest.get("acceptance_profile_sha256") ==
                    current_manifest.get("acceptance_profile_sha256") and
                    all(baseline_manifest.get(name) == current_manifest.get(name)
                        for name in ("source_sha", "source_tree", "private_profile_sha256")) and
                    nested(baseline_manifest, "artifacts", "application", "sha256") ==
                    nested(current_manifest, "artifacts", "application", "sha256"),
                    "Text100 reference differs from the Text150 run source or profile.")
            baseline = text_metric_samples(ordinary_file(
                baseline_root / "output" / "text-raster-metrics.json", 2 * 1024 * 1024,
                "Text100 raster metrics"))
            enlarged = all(
                baseline[name].get("text_sha256") == metrics[name].get("text_sha256") and
                nested(metrics[name], "ink_bounds", "width") >= nested(baseline[name], "ink_bounds", "width") * 1.25 and
                nested(metrics[name], "ink_bounds", "height") >= nested(baseline[name], "ink_bounds", "height") * 1.25
                for name in ("prefix-input", "full-details")
            )
            projection.update({
                "text_scale_requested_150": int_equals(nested(observer, "text_scale", "requested_percent"), 150) and int_equals(nested(observer, "text_scale", "registry_percent"), 150),
                "text_scale_observed_150": int_equals(nested(observer, "text_scale", "acceptance_percent"), 150) and int_equals(nested(scenario, "environment", "text_scale_factor_percent"), 150),
                "input_text_enlarged": enlarged,
                "full_details_text_enlarged": enlarged,
                "required_controls_reachable": reachability and controls,
                "taskdialog_limit_recorded": scenario.get("limitations") == ["native-taskdialog-text-scale-not-observed"],
                "settings_restored": cleanup.get("text_scale_restore") is True and nested(observer, "text_scale", "restoration") == "verified",
            })
            require(nested(scenario, "blocking", "status") == "not-run" and nested(scenario, "blocking", "reason") == "covered-by-paired-text100-standard-run", "Text150 blocking must bind the paired text100 run.")
    else:
        surface = nested(scenario, "surface")
        confirmation = nested(surface, "confirmation")
        overlay = nested(confirmation, "modal_overlay")
        details = nested(confirmation, "full_details")
        expanded = nested(confirmation, "expanded", "bottom_scroll")
        projection = {
            "long_row_tooltip_visible_before_apply": nested(overlay, "pre_modal", "visible_before_public_apply") is True and nested(overlay, "pre_modal", "window", "visible") is True,
            "tooltip_hidden_on_entry": nested(overlay, "owner_disabled") is True and nested(overlay, "at_entry_bound_tooltip_visible") is False,
            "tooltip_hidden_settled": nested(overlay, "persisted_visible_tooltip") is False and nested(overlay, "persisted_essential_overlap") is False,
            "tooltip_hidden_after_details_return": nested(overlay, "after_details_return", "bound_tooltip_visible") is False and nested(overlay, "after_details_return", "essential_overlap") is False,
            "tooltip_hidden_after_expansion": nested(overlay, "after_expansion", "bound_tooltip_visible") is False and nested(overlay, "after_expansion", "essential_overlap") is False,
            "tooltip_restored_after_cancel": nested(overlay, "after_cancel", "bound_tooltip_reexposed") is True and nested(overlay, "after_cancel", "window", "visible") is True,
            "tooltip_hidden_after_neutral": nested(overlay, "after_cancel", "neutral_hidden") is True,
            "public_apply_entered": nested(confirmation, "apply_entry") == {"input": "keyboard-ctrl-s-with-visible-listview-infotip", "menu_entry": None} and nested(confirmation, "scope_exact") is True and default_cancel(nested(confirmation, "default_focus")) and all(reachability_valid(nested(confirmation, "reachability", name)) for name in required_controls),
            "destination_context_visible": nested(confirmation, "destination_context_visible") is True,
            "cancelled_disk_unchanged": nested(surface, "cancellation_disk_unchanged") is True,
            "cancelled_fixture_identity_unchanged": nested(surface, "fixture_identity_unchanged") is True,
            "full_details_exact_document": nested(details, "canonical_text", "exact_document") is True,
            "full_details_end_visible": nested(details, "native_end_scroll", "ending_visible") is True,
            "full_details_return_default_cancel": default_cancel(nested(details, "return_default_cancel")),
            "expanded_bottom_reached": nested(expanded, "status") == "physically-scrolled-to-native-bottom" and nested(expanded, "range_value", "reached_maximum") is True,
            "cancellation_returned_to_preview": returned_to_preview(nested(confirmation, "cancellation")),
            "journal_clean": int_equals(nested(surface, "journal_residue_count"), 0),
            "normal_exit": int_equals(nested(surface, "normal_exit_code"), 0),
        }
        require(nested(scenario, "mode") == "context-surface" and nested(scenario, "full_context_coverage", "omitted") == ["second-repeated-fixture", "movement-actual-apply", "mixed-destination-third-unsampled-reentry", "default-enter-cancel", "alt-tab-roundtrip"], "Raw tooltip scope record differs from the fixed scenario.")
    require(set(projection) == MODE_SEMANTICS[mode], "Semantic projection keys differ from the fixed mode.")
    failed = sorted(name for name, value in projection.items() if value is not True)
    require(not failed, f"Raw evidence does not support semantic assertions: {', '.join(failed)}")
    return projection


def source_identity(repo: Path) -> tuple[str, str]:
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True).strip():
        raise RuntimeError("GUI regression evidence requires a clean checkout.")
    source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    source_tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=repo, text=True).strip()
    require(SOURCE_SHA.fullmatch(source_sha) is not None and SOURCE_SHA.fullmatch(source_tree) is not None,
            "Git returned an invalid source identity.")
    return source_sha, source_tree


def audit_focused_product_blobs(repo: Path) -> str:
    """Compare every non-tooling tracked entry of the two frozen product sources."""
    def entries(source: str) -> list[dict]:
        raw = subprocess.check_output(["git", "ls-tree", "-rz", "--full-tree", source], cwd=repo)
        rows = []
        for entry in raw.split(b"\0"):
            if not entry:
                continue
            identity, name = entry.split(b"\t", 1)
            path = name.decode("utf-8")
            if path.startswith("scripts/") or path in {
                    "DEVELOPMENT.md", "config/tooling-bundle.json", "config/tooling-tests.json"}:
                continue
            mode, kind, oid = identity.decode("ascii").split(" ")
            require(kind == "blob", "Frozen product audit contains a non-blob entry.")
            rows.append({"path": path, "git_object": oid, "mode": mode})
        return rows

    original = entries(FOCUSED_PRODUCT_REFERENCE_SHA)
    prepared = entries(FOCUSED_PRODUCT_SOURCE_SHA)
    encoded = json.dumps(prepared, sort_keys=True, separators=(",", ":")).encode("utf-8")
    require(original == prepared and len(prepared) == FOCUSED_PRODUCT_ENTRIES_COUNT and
            hashlib.sha256(encoded).hexdigest() == FOCUSED_PRODUCT_ENTRIES_SHA256,
            "Frozen original product sources differ across the complete non-tooling Git inventory.")
    return subprocess.check_output(
        ["git", "rev-parse", FOCUSED_PRODUCT_SOURCE_SHA + "^{tree}"], cwd=repo, text=True
    ).strip()


def validate_focused_original_bundle(repo: Path, bundle: Path) -> dict:
    require(bundle.is_absolute() and bundle.is_dir() and not bundle.is_symlink() and
            bundle.resolve(strict=True) == bundle and not bundle.is_relative_to(repo),
            "Focused original bundle root must be an ordinary external absolute directory.")
    path = ordinary_file(bundle / "bundle.json", 2 * 1024 * 1024, "Focused original bundle manifest")
    require(digest(path) == FOCUSED_ORIGINAL_BUNDLE_SHA256,
            "Focused original bundle manifest differs from frozen A bytes.")
    manifest = read_json(path)
    require(manifest.get("schema_version") == 1 and manifest.get("source_sha") == FOCUSED_PRODUCT_SOURCE_SHA and
            manifest.get("source_state") == "clean" and manifest.get("target") == launcher.TARGET and
            manifest.get("application") == {"file": "DarkReNamer.exe", "sha256": FOCUSED_APPLICATION_SHA256} and
            manifest.get("runner", {}).get("file") == "windows-vm-guest.ps1" and
            isinstance(manifest.get("test_binaries"), list) and manifest["test_binaries"] and
            SHA256.fullmatch(manifest.get("cargo_lock_sha256", "")) is not None,
            "Focused original bundle is not the frozen source-built product.")
    for row in [manifest["application"], manifest["runner"], *manifest["test_binaries"]]:
        require(isinstance(row, dict) and isinstance(row.get("file"), str) and
                SAFE_LEAF.fullmatch(row["file"]) is not None and
                isinstance(row.get("sha256"), str) and SHA256.fullmatch(row["sha256"]) is not None,
                "Focused original bundle artifact record is invalid.")
        member = ordinary_file(bundle / row["file"], 256 * 1024 * 1024,
                               "Focused original bundle artifact")
        require(digest(member) == row["sha256"],
                "Focused original bundle artifact differs from its frozen manifest.")
    require(digest(repo / "Cargo.lock") == manifest["cargo_lock_sha256"],
            "Focused original product lockfile differs from the retained source-built bundle.")
    return manifest


def stage_focused_preserved_bundle(repo: Path, original: Path, active: Path, tooling) -> dict:
    """Create a truthful split-origin task bundle; leave the original untouched."""
    require(tooling is not None, "Focused preserved execution requires verified current tooling.")
    source_sha, source_tree = source_identity(repo)
    product_tree = audit_focused_product_blobs(repo)
    original_manifest = validate_focused_original_bundle(repo, original)
    active.mkdir()
    sources = {
        "DarkReNamer.exe": original / "DarkReNamer.exe",
        "original-bundle.json": original / "bundle.json",
        "run-gui-regression.py": repo / "scripts" / "run-gui-regression.py",
        "test-windows-vm.py": repo / "scripts" / "test-windows-vm.py",
        "run-windows-vm-tests.ps1": repo / "scripts" / "run-windows-vm-tests.ps1",
        "windows-vm-guest.ps1": repo / "scripts" / "windows-vm-guest.ps1",
        "windows-vm-acceptance.ps1": repo / "scripts" / "windows-vm-acceptance.ps1",
        "Cargo.lock": repo / "Cargo.lock",
    }
    for name, source in sources.items():
        source = ordinary_file(source, 256 * 1024 * 1024, "Focused staged input " + name)
        with source.open("rb") as reader, (active / name).open("xb") as writer:
            shutil.copyfileobj(reader, writer, 1024 * 1024)
        require(digest(active / name) == digest(source), "Focused staged input changed during copy.")
    record = stage_verified_tooling(tooling, active)
    roles = tuple(row["role"] for row in record["modules"])
    require({"vm-launcher", "powershell-controller-entry", "powershell-ui-entry",
             "powershell-guest-entry"}.issubset(roles) and
            record == {"schema_version": 1, **trusted_tooling_inventory(repo, source_sha, roles)} and
            set(staged_tooling_files(active)) == {
                "tooling-record.json", "tooling-bundle.json",
                *(row["file"] for row in record["modules"])},
            "Focused current tooling closure differs from the clean Git source.")
    require(source_identity(repo) == (source_sha, source_tree) and
            validate_focused_original_bundle(repo, original) == original_manifest,
            "Focused product or tooling source changed during staging.")
    def bundle_artifact(name: str) -> dict:
        return {"file": name, "sha256": digest(active / name)}

    active_manifest = {
        "schema_version": 2, "lane": FOCUSED_PRESERVED_LANE,
        "target": launcher.TARGET, "test_binaries": [],
        "product": {
            "source_sha": FOCUSED_PRODUCT_SOURCE_SHA, "source_tree": product_tree,
            "source_state": "clean", "application": bundle_artifact("DarkReNamer.exe"),
            "provenance": {
                "kind": "preserved-source-built-bundle", "reference_source_sha": FOCUSED_PRODUCT_REFERENCE_SHA,
                "original_bundle_manifest": bundle_artifact("original-bundle.json"),
                "non_tooling_entries_sha256": FOCUSED_PRODUCT_ENTRIES_SHA256,
                "non_tooling_entries_count": FOCUSED_PRODUCT_ENTRIES_COUNT,
                "cargo_lock_sha256": original_manifest["cargo_lock_sha256"],
            },
        },
        "harness": {
            "source_sha": source_sha, "source_tree": source_tree, "source_state": "clean",
            "launcher": bundle_artifact("run-gui-regression.py"),
            "builder": bundle_artifact("test-windows-vm.py"),
            "controller": bundle_artifact("run-windows-vm-tests.ps1"),
            "runner": bundle_artifact("windows-vm-guest.ps1"),
            "observers": {"ui": bundle_artifact("windows-vm-acceptance.ps1")},
            "tooling_record": bundle_artifact(RECORD_NAME),
        },
    }
    require(active_manifest["product"]["application"]["sha256"] == FOCUSED_APPLICATION_SHA256,
            "Focused preserved application differs from frozen A bytes.")
    write_json(active / "bundle.json", active_manifest, exclusive=True)
    return active_manifest


def validated_bundle_sources(repo: Path, bundle: Path,
                             acceptance_profile_id: str = V1_PROFILE_ID) -> tuple[dict, dict[str, Path]]:
    manifest = read_json(ordinary_file(bundle / "bundle.json", 2 * 1024 * 1024,
                                       "Native bundle manifest"))
    source_sha, _ = source_identity(repo)
    require(manifest.get("source_sha") == source_sha and manifest.get("source_state") == "clean",
            "Native bundle and checkout source differ.")
    application = ordinary_file(bundle / manifest["application"]["file"], 256 * 1024 * 1024,
                                "Native application")
    runner = ordinary_file(bundle / manifest["runner"]["file"], 8 * 1024 * 1024, "Native runner")
    test_binaries = manifest.get("test_binaries")
    require(isinstance(test_binaries, list) and test_binaries,
            "Native bundle must contain its real nonempty test binary set.")
    require(digest(application) == manifest["application"]["sha256"], "Application hash differs from bundle.json.")
    require(digest(runner) == manifest["runner"]["sha256"], "Runner hash differs from bundle.json.")
    require(digest(repo / "Cargo.lock") == manifest.get("cargo_lock_sha256"),
            "Cargo.lock differs from bundle.json.")
    scripts = repo / "scripts"
    sources = {
        "bundle.json": bundle / "bundle.json",
        application.name: application,
        runner.name: runner,
        "windows-vm-acceptance.ps1": scripts / "windows-vm-acceptance.ps1",
        "run-gui-regression.py": scripts / "run-gui-regression.py",
        "run-windows-vm-tests.ps1": scripts / "run-windows-vm-tests.ps1",
        "Cargo.lock": repo / "Cargo.lock",
        "test-windows-vm.py": scripts / "test-windows-vm.py",
    }
    if acceptance_profile_id == V2_PROFILE_ID:
        sources[V2_PROFILE_FILE] = ordinary_file(repo / "config" / V2_PROFILE_FILE, 1024 * 1024,
                                                 "V2 acceptance profile")
    for name in staged_tooling_files(bundle):
        require(name not in sources, "Tooling bundle member collides with a GUI input.")
        sources[name] = bundle / name
    for row in test_binaries:
        require(isinstance(row, dict) and isinstance(row.get("file"), str)
                and SAFE_LEAF.fullmatch(row["file"]) is not None,
                "Native bundle contains an invalid test binary entry.")
        require(row["file"] not in sources, "Native bundle contains a duplicate artifact name.")
        source = ordinary_file(bundle / row["file"], 256 * 1024 * 1024, "Native test binary")
        require(digest(source) == row.get("sha256"),
                f"Native test binary hash differs from bundle.json: {row['file']}")
        sources[row["file"]] = source
    return manifest, sources


def run_input_artifacts(repo: Path, bundle: Path, run_root: Path,
                        acceptance_profile_id: str = V1_PROFILE_ID,
                        focused_preserved: bool = False) -> tuple[dict, dict]:
    if focused_preserved:
        def bundle_artifact(name: str) -> dict:
            return {"file": name, "sha256": digest(bundle / name)}

        require(acceptance_profile_id == V1_PROFILE_ID,
                "Focused preserved product is bound to strict V1 cleanup.")
        manifest = read_json(ordinary_file(bundle / "bundle.json", 2 * 1024 * 1024,
                                           "Focused active bundle manifest"))
        source_sha, source_tree = source_identity(repo)
        product = manifest.get("product", {})
        harness = manifest.get("harness", {})
        provenance = product.get("provenance", {})
        require(manifest.get("schema_version") == 2 and
                manifest.get("lane") == FOCUSED_PRESERVED_LANE and
                manifest.get("target") == launcher.TARGET and manifest.get("test_binaries") == [] and
                product.get("source_sha") == FOCUSED_PRODUCT_SOURCE_SHA and
                product.get("source_tree") == audit_focused_product_blobs(repo) and
                product.get("source_state") == "clean" and
                provenance.get("kind") == "preserved-source-built-bundle" and
                provenance.get("reference_source_sha") == FOCUSED_PRODUCT_REFERENCE_SHA and
                provenance.get("non_tooling_entries_sha256") == FOCUSED_PRODUCT_ENTRIES_SHA256 and
                provenance.get("non_tooling_entries_count") == FOCUSED_PRODUCT_ENTRIES_COUNT and
                harness.get("source_sha") == source_sha and
                harness.get("source_tree") == source_tree and
                harness.get("source_state") == "clean",
                "Focused active bundle product or current tooling identity differs.")
        original = read_json(ordinary_file(bundle / "original-bundle.json", 2 * 1024 * 1024,
                                           "Focused retained original manifest"))
        require(digest(bundle / "original-bundle.json") == FOCUSED_ORIGINAL_BUNDLE_SHA256 and
                original.get("source_sha") == FOCUSED_PRODUCT_SOURCE_SHA and
                original.get("source_state") == "clean" and
                original.get("target") == launcher.TARGET and
                original.get("application") == {"file": "DarkReNamer.exe", "sha256": FOCUSED_APPLICATION_SHA256} and
                provenance.get("original_bundle_manifest") == bundle_artifact("original-bundle.json") and
                provenance.get("cargo_lock_sha256") == original.get("cargo_lock_sha256") == digest(repo / "Cargo.lock") and
                product.get("application") == bundle_artifact("DarkReNamer.exe") and
                product["application"]["sha256"] == FOCUSED_APPLICATION_SHA256,
                "Focused retained original bundle or executable binding differs.")
        artifacts = {"launcher": "run-gui-regression.py", "builder": "test-windows-vm.py",
                     "controller": "run-windows-vm-tests.ps1", "runner": "windows-vm-guest.ps1",
                     "observer": "windows-vm-acceptance.ps1"}
        for key, name in artifacts.items():
            recorded = harness["observers"]["ui"] if key == "observer" else harness[key]
            require(recorded == bundle_artifact(name) and
                    digest(bundle / name) == digest(repo / "scripts" / name),
                    "Focused current harness file differs from the clean checkout: " + name)
        record = read_json(ordinary_file(bundle / RECORD_NAME, 2 * 1024 * 1024,
                                         "Focused current tooling record"))
        roles = tuple(row["role"] for row in record["modules"])
        require(harness.get("tooling_record") == bundle_artifact(RECORD_NAME) and
                record == {"schema_version": 1, **trusted_tooling_inventory(repo, source_sha, roles)},
                "Focused staged tooling record differs from the current Git closure.")
        names = [*artifacts.values(), "DarkReNamer.exe", "original-bundle.json", "Cargo.lock",
                 *staged_tooling_files(bundle)]
        require(len(names) == len(set(names)), "Focused task bundle has colliding input names.")
        rows = materialize_inputs(run_root, {name: bundle / name for name in names} |
                                  {"bundle.json": bundle / "bundle.json"})
        return manifest, {
            "bundle_manifest": rows["bundle.json"],
            "original_bundle_manifest": rows["original-bundle.json"],
            "tooling_record": rows[RECORD_NAME],
            "artifacts": {
                "application": rows["DarkReNamer.exe"],
                **{key: rows[name] for key, name in artifacts.items()},
                "lockfile": rows["Cargo.lock"],
            },
            "source_sha": FOCUSED_PRODUCT_SOURCE_SHA,
            "source_tree": product["source_tree"],
            "tooling_source_sha": source_sha,
            "tooling_source_tree": source_tree,
        }
    manifest, sources = validated_bundle_sources(repo, bundle, acceptance_profile_id)
    source_sha, source_tree = source_identity(repo)
    test_binaries = manifest["test_binaries"]
    application = sources[manifest["application"]["file"]]
    runner = sources[manifest["runner"]["file"]]
    rows = materialize_inputs(run_root, sources)
    require(rows[application.name]["sha256"] == manifest["application"]["sha256"],
            "Copied application differs from the native bundle.")
    require(rows[runner.name]["sha256"] == manifest["runner"]["sha256"],
            "Copied guest runner differs from the native bundle.")
    require(rows["Cargo.lock"]["sha256"] == manifest["cargo_lock_sha256"],
            "Copied Cargo.lock differs from the native bundle.")
    for row in test_binaries:
        require(rows[row["file"]]["sha256"] == row["sha256"],
                f"Copied native test binary differs from bundle.json: {row['file']}")
    return manifest, {
        "bundle_manifest": rows["bundle.json"],
        "artifacts": {
            "application": rows[application.name],
            "runner": rows[runner.name],
            "observer": rows["windows-vm-acceptance.ps1"],
            "launcher": rows["run-gui-regression.py"],
            "controller": rows["run-windows-vm-tests.ps1"],
            "lockfile": rows["Cargo.lock"],
            "builder": rows["test-windows-vm.py"],
        },
        **({"acceptance_profile": rows[V2_PROFILE_FILE]} if acceptance_profile_id == V2_PROFILE_ID else {}),
        "source_sha": source_sha,
        "source_tree": source_tree,
    }


def validate_prepared_bundle(repo: Path, bundle: Path, expected_application_sha256: str) -> dict:
    """Bind a prepared native bundle to the current clean source before any VM work."""
    require(bundle.is_absolute() and bundle.is_dir() and not bundle.is_symlink() and
            bundle.resolve(strict=True) == bundle and not bundle.is_relative_to(repo),
            "Prepared bundle root must be an ordinary external absolute directory.")
    require(SHA256.fullmatch(expected_application_sha256) is not None,
            "Prepared application pin must be a lowercase SHA-256.")
    manifest, sources = validated_bundle_sources(repo, bundle)
    require(manifest.get("schema_version") == 1 and manifest.get("target") == launcher.TARGET and
            manifest["application"].get("file") == "DarkReNamer.exe" and
            manifest["runner"].get("file") == "windows-vm-guest.ps1" and
            manifest["application"]["sha256"] == expected_application_sha256,
            "Prepared native bundle identity or application pin differs.")
    require(digest(sources["windows-vm-guest.ps1"]) == digest(repo / "scripts" / "windows-vm-guest.ps1"),
            "Prepared native runner differs from current source.")
    record = read_json(ordinary_file(bundle / RECORD_NAME, 2 * 1024 * 1024,
                                     "Prepared tooling record"))
    roles = tuple(row["role"] for row in record["modules"])
    require({"vm-launcher", "powershell-controller-entry", "powershell-ui-entry",
             "powershell-guest-entry"}.issubset(roles),
            "Prepared tooling lacks the native GUI execution closure.")
    trusted = trusted_tooling_inventory(repo, manifest["source_sha"], roles)
    require(record.get("schema_version") == 1 and record.get("manifest") == trusted["manifest"] and
            {row["role"]: row for row in record["modules"]} ==
            {row["role"]: row for row in trusted["modules"]},
            "Prepared tooling closure differs from trusted source.")
    return manifest


def input_manifest(repo: Path, bundle: Path, run_root: Path, run: dict, profile_sha256: str,
                   host_preflight: dict, guest_preflight: dict,
                   reference: dict | None = None,
                   prepared_application_sha256: str | None = None) -> dict:
    require(prepared_application_sha256 is None or
            (run["mode"] in {"performance-sample", FOCUSED_CLEAR_MODE, ICON_SETTLEMENT_MODE} and
             SHA256.fullmatch(prepared_application_sha256) is not None),
            "Prepared bundle provenance is restricted to pinned performance runs.")
    require(run["mode"] != ICON_SETTLEMENT_MODE or prepared_application_sha256 is not None,
            "Icon settlement requires a pinned prepared executable.")
    require(run["mode"] != FOCUSED_CLEAR_MODE or prepared_application_sha256 is not None,
            "Focused clear requires a pinned prepared executable.")
    _, inputs = run_input_artifacts(repo, bundle, run_root,
                                    run.get("acceptance_profile_id", V1_PROFILE_ID),
                                    focused_preserved=run["mode"] == FOCUSED_CLEAR_MODE)
    if run["mode"] == ICON_SETTLEMENT_MODE and run["endpoint_method"] == ICON_BASELINE_METHOD:
        require(run["baseline_product_source_sha"] == ICON_BASELINE_PRODUCT_SOURCE_SHA and
                run["expected_run_source_sha"] == inputs["source_sha"],
                "Synchronous baseline reference or exact frozen run source differs.")
    require(prepared_application_sha256 is None or
            inputs["artifacts"]["application"]["sha256"] == prepared_application_sha256,
            "Prepared application pin differs from copied run input.")
    result = {
        "schema_version": 1,
        "run_id": run["run_id"],
        "source_sha": inputs["source_sha"],
        "source_tree": inputs["source_tree"],
        **({"tooling_source_sha": inputs["tooling_source_sha"],
            "tooling_source_tree": inputs["tooling_source_tree"]}
           if run["mode"] == FOCUSED_CLEAR_MODE else {}),
        "private_profile_sha256": profile_sha256,
        "host_preflight": host_preflight,
        "guest_preflight": guest_preflight,
        "bundle_manifest": inputs["bundle_manifest"],
        "artifacts": inputs["artifacts"],
        **({"prepared_bundle": {"origin": ("preserved-source-built-product-current-tooling"
                                           if run["mode"] == FOCUSED_CLEAR_MODE else
                                           "external-prepared-source-built-bundle"),
                "bundle_manifest_sha256": inputs["bundle_manifest"]["sha256"],
                "application_sha256": prepared_application_sha256,
                **({"original_bundle_manifest_sha256": inputs["original_bundle_manifest"]["sha256"],
                    "tooling_record_sha256": inputs["tooling_record"]["sha256"],
                    "product_source_sha": inputs["source_sha"],
                    "tooling_source_sha": inputs["tooling_source_sha"]}
                   if run["mode"] == FOCUSED_CLEAR_MODE else {})}}
           if prepared_application_sha256 is not None else {}),
        "request": {
            "mode": run["mode"],
            "appearance": run["appearance"],
            "desktop": {"width": run["width"], "height": run["height"], "dpi": run["dpi"]},
            "text_scale_percent": run["text_scale_percent"],
            **({"high_contrast": run["high_contrast"]} if run["mode"] == "appearance-pair" else {}),
            **({"performance_plan": {**PERFORMANCE_PLAN, "long_path_order": run["long_path_order"]}}
               if run["mode"] == "performance-sample" else {}),
            **({"focused_clear_plan": FOCUSED_CLEAR_PLAN}
               if run["mode"] == FOCUSED_CLEAR_MODE else {}),
            **({"settlement_plan": ICON_SETTLEMENT_PLAN,
                "endpoint_method": run["endpoint_method"],
                **({"baseline_product_source_sha": run["baseline_product_source_sha"]}
                   if run["endpoint_method"] == ICON_BASELINE_METHOD else {})}
               if run["mode"] == ICON_SETTLEMENT_MODE else {}),
        },
        "expected_guest_platform": "windows",
        "command": [
            "python3", "-I", "scripts/run-gui-regression.py", "--output-root",
            "<external-output-root>", "--connection-profile", "<private-connection-profile>",
            *(["--diagnostic", run["mode"]] if run["mode"] in
              {"appearance-pair", "performance-sample", FOCUSED_CLEAR_MODE, ICON_SETTLEMENT_MODE} else []),
            *(["--performance-column-order", run["long_path_order"]]
              if run["mode"] == "performance-sample" else []),
            *(["--preserved-product-bundle-root", "<external-preserved-product-bundle-root>",
               "--expected-original-bundle-sha256", FOCUSED_ORIGINAL_BUNDLE_SHA256,
               "--expected-product-source-sha", FOCUSED_PRODUCT_SOURCE_SHA,
               "--expected-tooling-source-sha", inputs["tooling_source_sha"],
               "--expected-prepared-application-sha256", prepared_application_sha256]
              if run["mode"] == FOCUSED_CLEAR_MODE else []),
            *(["--prepared-bundle-root", "<external-prepared-bundle-root>",
               "--expected-prepared-application-sha256", prepared_application_sha256]
              if prepared_application_sha256 is not None and run["mode"] != FOCUSED_CLEAR_MODE else []),
            *(["--desktop-width", str(run["width"]),
               "--desktop-height", str(run["height"]), "--desktop-dpi", str(run["dpi"])]
              if run["mode"] == "appearance-pair" and run["run_id"] == APPEARANCE_PAIR_ID else []),
            *(["--acceptance-profile-id", V2_PROFILE_ID] if run.get("acceptance_profile_id") == V2_PROFILE_ID else []),
            *(["--icon-endpoint-method", ICON_BASELINE_METHOD,
               "--baseline-product-source-sha", ICON_BASELINE_PRODUCT_SOURCE_SHA,
               "--expected-run-source-sha", run["expected_run_source_sha"]]
              if run["mode"] == ICON_SETTLEMENT_MODE and
              run["endpoint_method"] == ICON_BASELINE_METHOD else []),
            *(["--configuration-set", "focused"] if run["mode"] == "appearance-pair"
              and run["run_id"] != APPEARANCE_PAIR_ID else []),
        ],
    }
    if reference is not None:
        result["full_context_reference"] = reference
    if run["mode"] in {"appearance-pair", ICON_SETTLEMENT_MODE} or run.get("acceptance_profile_id") == V2_PROFILE_ID:
        result["acceptance_profile_id"] = run.get("acceptance_profile_id", V1_PROFILE_ID)
        if result["acceptance_profile_id"] == V2_PROFILE_ID:
            require(run["acceptance_profile_sha256"] == inputs["acceptance_profile"]["sha256"],
                    "V2 acceptance profile changed between selection and immutable staging.")
            result["acceptance_profile"] = inputs["acceptance_profile"]
            result["acceptance_profile_sha256"] = inputs["acceptance_profile"]["sha256"]
    return result


def reference_for(run_root: Path) -> dict:
    input_path = run_root / "input-manifest.json"
    result_path = run_root / "output" / "run-result.json"
    manifest = read_json(input_path)
    require(manifest.get("request", {}).get("mode") == "full-context", "Reference target is not full-context.")
    ordinary_file(result_path, 2 * 1024 * 1024, "Referenced run result")
    return {
        "run_id": manifest["run_id"],
        "input_manifest_sha256": digest(input_path),
        "result_sha256": digest(result_path),
        "scope": ["full-context-semantics-v1"],
    }


def runtime_args(profile: dict, run: dict):
    return argparse.Namespace(
        ssh_host=profile["ssh_host"],
        vm_name=None,
        desktop_mode="rdp",
        desktop_helper=profile["desktop_helper"],
        desktop_scale=run["dpi"] * 100 // 96,
        desktop_width=run["width"],
        desktop_height=run["height"],
    )


def host_preflight() -> dict:
    architecture = platform.machine().lower()
    require(architecture in {"x86_64", "amd64"}, "GUI regression host must be x86_64 Linux.")
    require(platform.system().lower() == "linux", "GUI regression launcher must run on Linux/WSL.")
    return {"system": "linux", "release": platform.release(), "architecture": "x86_64"}


def controller_command(repo: Path, bundle: Path, run_root: Path, run: dict,
                       profile: dict, lease: dict) -> list[str]:
    pwsh = host_tools.require_pwsh74()
    command = [
        pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
        str(repo / "scripts" / "run-windows-vm-tests.ps1"),
        "-BundleRoot", str(bundle),
        "-SshHost", profile["ssh_host"],
        "-ExpectedDesktopSid", lease["expectedGuestSid"],
        "-ExpectedGuestVmId", profile["expected_vm_id"],
        "-AcceptanceOutputRoot", str(run_root / "output"),
        "-AcceptanceManifest", str(run_root / "input-manifest.json"),
        "-AcceptanceMode", run["mode"],
        "-AcceptanceAppearance", run["appearance"],
        "-AcceptanceTextScalePercent", str(run["text_scale_percent"]),
    ]
    if run["mode"] in {"appearance-pair", ICON_SETTLEMENT_MODE} or run.get("acceptance_profile_id") == V2_PROFILE_ID:
        if run["mode"] in {"appearance-pair", ICON_SETTLEMENT_MODE}:
            command += ["-TestTimeoutSeconds", "600", "-SuiteTimeoutSeconds", "1200"]
        command += ["-AcceptanceProfileId", run.get("acceptance_profile_id", V1_PROFILE_ID)]
        if run.get("acceptance_profile_id") == V2_PROFILE_ID:
            manifest = read_json(run_root / "input-manifest.json")
            staged = ordinary_file(run_root / "inputs" / V2_PROFILE_FILE, 1024 * 1024, "Staged V2 profile")
            require(manifest.get("acceptance_profile_id") == V2_PROFILE_ID and
                    manifest.get("acceptance_profile_sha256") == run["acceptance_profile_sha256"] == digest(staged) and
                    manifest.get("acceptance_profile", {}).get("sha256") == run["acceptance_profile_sha256"],
                    "V2 controller profile differs from its immutable staged manifest.")
            if run["mode"] in {"full-context", "standard", "text-scale", "tooltip"}:
                source_profile = ordinary_file(repo / "config" / V2_PROFILE_FILE, 1024 * 1024,
                                               "Source V2 profile")
                require(digest(source_profile) == run["acceptance_profile_sha256"],
                        "Fixed GUI V2 profile changed after its immutable staging.")
            command += ["-AcceptanceProfileSha256", manifest["acceptance_profile_sha256"]]
        if run["mode"] == "appearance-pair" and run["high_contrast"]:
            command += ["-AcceptanceHighContrast"]
    elif run["mode"] in {"performance-sample", FOCUSED_CLEAR_MODE}:
        command += ["-TestTimeoutSeconds", "600", "-SuiteTimeoutSeconds", "1200"]
    if run["mode"] == FOCUSED_CLEAR_MODE:
        manifest = read_json(run_root / "input-manifest.json")
        bundle_manifest = ordinary_file(bundle / "bundle.json", 2 * 1024 * 1024,
                                        "Focused controller bundle manifest")
        require(manifest["bundle_manifest"]["sha256"] == digest(bundle_manifest),
                "Focused controller bundle differs from its immutable input manifest.")
        command += ["-ExpectedBundleManifestSha256", manifest["bundle_manifest"]["sha256"]]
    return command


def collection_document(run_root: Path, input_sha256: str, run_id: str) -> dict:
    output = run_root / "output"
    files = []
    total_bytes = 0
    for path in sorted(output.rglob("*")):
        if not path.is_file() or path.name == "run-result.json":
            continue
        require(not path.is_symlink(), "Collected output must not contain symlinks.")
        files.append({
            "relative_path": path.relative_to(output).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": digest(path),
        })
        total_bytes += path.stat().st_size
    require(files, "A GUI regression run returned no raw output.")
    pair_ids = {APPEARANCE_PAIR_ID, *(run["run_id"] for run in FOCUSED_PAIR_RUNS)}
    if run_id in pair_ids:
        expected_pngs = 72 if run_id == FOCUSED_PAIR_RUNS[-1]["run_id"] else 69
        require(total_bytes <= 120 * 1024 * 1024 and
                sum(row["relative_path"].endswith(".png") for row in files) == expected_pngs,
                f"Appearance pair must stay within 120 MiB and exactly {expected_pngs} original PNGs.")
    if run_id in {performance_run(order)["run_id"] for order in PERFORMANCE_ORDERS} | {FOCUSED_CLEAR_RUN_ID, ICON_SETTLEMENT_RUN_ID}:
        require(total_bytes <= 32 * 1024 * 1024 and
                sum(row["relative_path"].endswith(".png") for row in files) == 1,
                "Performance diagnostic must stay within 32 MiB and one original PNG.")
    return {
        "schema_version": 1,
        "run_id": run_id,
        "input_manifest_sha256": input_sha256,
        "files": files,
    }


def normalize_run_result(run_root: Path, input_sha256: str) -> dict:
    manifest = read_json(run_root / "input-manifest.json")
    output = run_root / "output"
    observer = read_json(output / "acceptance-result.json")
    observations = read_json(output / "acceptance-observations.json")
    observation_binding = observer.get("observations")
    require(isinstance(observation_binding, dict)
            and observation_binding.get("file") == "acceptance-observations.json"
            and observation_binding.get("sha256") == digest(output / "acceptance-observations.json"),
            "Protected observer result does not bind the collected observations file.")
    require(observer.get("acceptance_observations") == observations,
            "Collected observations differ from the object embedded in the protected result.")
    preflight = read_json(output / "platform-preflight.json")
    cleanup = read_json(output / "cleanup.json")
    transport = read_json(output / "transport.json")
    observer_process = transport.get("observer_process")
    require(isinstance(observer_process, dict)
            and observer_process.get("state") == "exited"
            and type(observer_process.get("exit_code")) is int,
            "Transport lacks the actual terminal observer process result.")
    observer_exit = observer_process["exit_code"]
    require(observer_exit == 0, "GUI regression observer process returned a nonzero exit code.")
    collection = run_root / "collection.json"
    environment = observations.get("environment", {})
    main_window = environment.get("main_window", {})
    monitor = main_window.get("target_monitor", environment.get("physical_screen", {}))
    work = main_window.get("target_work_area", environment.get("work_area", {}))
    artifacts = manifest["artifacts"]
    projection = project_raw_semantics(
        observer, cleanup, run_root, manifest["request"]["mode"]
    )
    return {
        "schema_version": 1,
        "run_id": manifest["run_id"],
        "input_manifest_sha256": input_sha256,
        "collection_sha256": digest(collection),
        "cleanup_sha256": digest(output / "cleanup.json"),
        "source_sha": manifest["source_sha"],
        "application_sha256": artifacts["application"]["sha256"],
        "runner_sha256": artifacts["runner"]["sha256"],
        "observer_sha256": artifacts["observer"]["sha256"],
        "observer_result": {
            "file": "acceptance-result.json",
            "sha256": digest(output / "acceptance-result.json"),
            "bytes": (output / "acceptance-result.json").stat().st_size,
            "status": observer.get("status"),
        },
        "host_platform": manifest["host_preflight"],
        "guest_platform": preflight["guest_platform"],
        "actual": {
            "appearance": nested(observer, "assertions", "scenario", "appearance"),
            "monitor": monitor,
            "work_area": work,
            "hwnd_dpi": environment.get("hwnd_dpi", environment.get("dpi")),
            "text_scale_percent": environment.get("text_scale_factor_percent"),
            "target": {
                "hwnd": main_window.get("hwnd"),
                "process_id": main_window.get("process_id"),
                "window_rect": main_window.get("rect"),
            },
        },
        "exit_code": observer_exit,
        "status": observer.get("status"),
        "assertions": semantic_assertions(
            observer.get("assertions", {}), manifest["request"]["mode"], projection
        ),
    }


def finalize_run(run_root: Path) -> None:
    input_path = ordinary_file(run_root / "input-manifest.json", 2 * 1024 * 1024, "Input manifest")
    manifest = read_json(input_path)
    input_sha256 = digest(input_path)
    cleanup = read_json(run_root / "output" / "cleanup.json")
    require(cleanup.get("input_manifest_sha256") == input_sha256, "Cleanup does not bind the input manifest.")
    collection_path = run_root / "collection.json"
    require(not collection_path.exists(), "Collection receipt already exists.")
    write_json(collection_path, collection_document(run_root, input_sha256, manifest["run_id"]), exclusive=True)
    result_path = run_root / "output" / "run-result.json"
    require(not result_path.exists(), "Normalized run result already exists.")
    mode = manifest["request"]["mode"]
    normalized = (normalize_pair_result(run_root, input_sha256) if mode == "appearance-pair"
                  else normalize_performance_result(run_root, input_sha256) if mode in
                  {"performance-sample", FOCUSED_CLEAR_MODE, ICON_SETTLEMENT_MODE}
                  else normalize_run_result(run_root, input_sha256))
    write_json(result_path, normalized, exclusive=True)


def normalize_pair_result(run_root: Path, input_sha256: str) -> dict:
    manifest = read_json(run_root / "input-manifest.json")
    output = run_root / "output"
    observer = read_json(output / "acceptance-result.json")
    observations = read_json(output / "acceptance-observations.json")
    require(observer.get("observations", {}).get("sha256") == digest(output / "acceptance-observations.json")
            and observer.get("acceptance_observations") == observations,
            "Appearance observer result does not bind its collected observations.")
    transport = read_json(output / "transport.json")
    require(transport.get("observer_process") == {"state": "exited", "exit_code": 0},
            "Appearance observer process did not exit successfully.")
    preflight = read_json(output / "platform-preflight.json")
    environment = observations.get("environment", {})
    window = environment.get("main_window", {})
    artifacts = manifest["artifacts"]
    return {
        "schema_version": 1, "diagnostic": "appearance-pair", "run_id": manifest["run_id"],
        "input_manifest_sha256": input_sha256, "collection_sha256": digest(run_root / "collection.json"),
        "cleanup_sha256": digest(output / "cleanup.json"), "source_sha": manifest["source_sha"],
        "application_sha256": artifacts["application"]["sha256"],
        "runner_sha256": artifacts["runner"]["sha256"],
        "observer_sha256": artifacts["observer"]["sha256"],
        "observer_result_sha256": digest(output / "acceptance-result.json"),
        "host_platform": manifest["host_preflight"], "guest_platform": preflight["guest_platform"],
        "actual": {
            "monitor": window.get("target_monitor"), "work_area": window.get("target_work_area"),
            "hwnd_dpi": environment.get("hwnd_dpi"),
            "text_scale_percent": environment.get("text_scale_factor_percent"),
            "target": {"hwnd": window.get("hwnd"), "process_id": window.get("process_id"),
                       "window_rect": window.get("rect")},
        },
        "status": observer.get("status"), "exit_code": 0,
    }


def normalize_performance_result(run_root: Path, input_sha256: str) -> dict:
    manifest = read_json(run_root / "input-manifest.json")
    output = run_root / "output"
    raw = read_json(output / "acceptance-result.json")
    observations = read_json(output / "acceptance-observations.json")
    require(raw.get("observations", {}).get("file") == "acceptance-observations.json" and
            raw["observations"].get("sha256") == digest(output / "acceptance-observations.json") and
            raw.get("acceptance_observations") == observations,
            "Performance observer observations are not bound to the protected result.")
    transport = read_json(output / "transport.json")
    require(transport.get("observer_process") == {"state": "exited", "exit_code": 0},
            "Performance observer process did not exit successfully.")
    artifacts = manifest["artifacts"]
    return {
        "schema_version": 1, "diagnostic": manifest["request"]["mode"], "run_id": manifest["run_id"],
        "input_manifest_sha256": input_sha256,
        "collection_sha256": digest(run_root / "collection.json"),
        "cleanup_sha256": digest(output / "cleanup.json"),
        "source_sha": manifest["source_sha"],
        "application_sha256": artifacts["application"]["sha256"],
        "observer_sha256": artifacts["observer"]["sha256"],
        "observer_result_sha256": digest(output / "acceptance-result.json"),
        "status": raw.get("status"), "exit_code": 0,
    }


def execute_run(repo: Path, bundle: Path, run_root: Path, run: dict, profile: dict,
                native_runner) -> None:
    output = run_root / "output"
    output.mkdir()
    desktop_restored = False
    controller_exit = None
    controller_logs_bounded = True
    controller_stdout = run_root / "controller.stdout.txt"
    controller_stderr = run_root / "controller.stderr.txt"
    try:
        with controller_stdout.open("x", encoding="utf-8") as stdout, \
                controller_stderr.open("x", encoding="utf-8") as stderr:
            with native_runner.managed_desktop(runtime_args(profile, run)) as lease:
                completed = subprocess.run(
                    controller_command(repo, bundle, run_root, run, profile, lease),
                    cwd=repo,
                    env=host_tools.child_environment(),
                    text=True,
                    stdout=stdout,
                    stderr=stderr,
                    check=False,
                )
                controller_exit = completed.returncode
        desktop_restored = True
        if controller_exit == 0 and run["mode"] in {"standard", "text-scale"}:
            write_text_raster_metrics(run_root)
    finally:
        for path in (controller_stdout, controller_stderr):
            if path.is_file():
                controller_logs_bounded = controller_logs_bounded and path.stat().st_size <= 128 * 1024 * 1024
                os.replace(path, output / path.name)
        input_sha256 = digest(run_root / "input-manifest.json")
        observer_result_path = output / "acceptance-result.json"
        observer = read_json(observer_result_path) if observer_result_path.is_file() else {}
        observation_path = output / "acceptance-observations.json"
        observations = read_json(observation_path) if observation_path.is_file() else {}
        environment = observations.get("environment", {}) if isinstance(observations.get("environment"), dict) else {}
        text = observer.get("text_scale", {}) if isinstance(observer.get("text_scale"), dict) else {}
        text_scale_restored = (
            environment.get("text_scale_factor_percent") == 100
            if run["text_scale_percent"] == 100
            else text.get("restoration") == "verified"
        )
        cleanup = {
            "schema_version": 1,
            "run_id": run["run_id"],
            "input_manifest_sha256": input_sha256,
            "fixture": observer.get("guest_cleanup") is True,
            "process": observer.get("process_cleanup", observer.get("guest_cleanup")) is True,
            "guest": (output / "transport.json").is_file()
            and read_json(output / "transport.json").get("guest_cleanup") is True,
            "desktop_restore": desktop_restored,
            "text_scale_restore": text_scale_restored,
            "controller_exit_code": controller_exit,
        }
        cleanup["status"] = "passed" if all(
            cleanup[name] is True
            for name in ("fixture", "process", "guest", "desktop_restore", "text_scale_restore")
        ) else "failed"
        write_json(output / "cleanup.json", cleanup, exclusive=True)
    require(controller_exit == 0, "GUI regression transport failed; preserve and inspect the run output.")
    require(controller_logs_bounded, "GUI regression controller stream exceeds the raw size bound.")
    finalize_run(run_root)


def validate_all(repo: Path, result_root: Path, output_root: Path,
                 diagnostic: str | None = None, selected_runs: tuple[dict, ...] | None = None,
                 configuration_set: str | None = None) -> None:
    validator = repo / "scripts" / "validate-gui-regression-evidence.py"
    ordinary_file(validator, 2 * 1024 * 1024, "GUI regression evidence validator")
    source_sha, _ = source_identity(repo)
    if diagnostic == FOCUSED_CLEAR_MODE:
        source_sha = FOCUSED_PRODUCT_SOURCE_SHA
    command = [
        sys.executable, "-I", str(validator), "--result-root", str(result_root),
        "--expected-source-sha", source_sha,
    ]
    runs = selected_runs if selected_runs is not None else (
        (appearance_pair_run(1366, 768, 96),) if diagnostic == "appearance-pair" else
        (performance_run(),) if diagnostic == "performance-sample" else
        (focused_clear_run(),) if diagnostic == FOCUSED_CLEAR_MODE else
        (icon_settlement_run(),) if diagnostic == ICON_SETTLEMENT_MODE else RUNS)
    for run in runs:
        command += ["--run", run["run_id"]]
    if diagnostic in {"appearance-pair", "performance-sample", FOCUSED_CLEAR_MODE, ICON_SETTLEMENT_MODE}:
        command += ["--diagnostic", diagnostic]
        if configuration_set == "focused":
            command += ["--configuration-set", "focused"]
    else:
        command += ["--require-complete-set"]
        if runs[0].get("acceptance_profile_id") == V2_PROFILE_ID:
            command += ["--acceptance-profile-id", V2_PROFILE_ID]
    completed = subprocess.run(command, cwd=repo, check=True, capture_output=True)
    report = json.loads(completed.stdout)
    write_json(output_root / "validation-result.json", report, exclusive=True)


def main(repo: Path, argv: list[str] | None = None, tooling=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--connection-profile", type=Path, required=True)
    parser.add_argument("--diagnostic", choices=["appearance-pair", "performance-sample", FOCUSED_CLEAR_MODE, ICON_SETTLEMENT_MODE])
    parser.add_argument("--icon-endpoint-method", choices=[ICON_BASELINE_METHOD])
    parser.add_argument("--baseline-product-source-sha")
    parser.add_argument("--expected-run-source-sha")
    parser.add_argument("--performance-column-order", choices=PERFORMANCE_ORDERS)
    parser.add_argument("--prepared-bundle-root", type=Path)
    parser.add_argument("--preserved-product-bundle-root", type=Path)
    parser.add_argument("--expected-original-bundle-sha256")
    parser.add_argument("--expected-product-source-sha")
    parser.add_argument("--expected-tooling-source-sha")
    parser.add_argument("--expected-prepared-application-sha256")
    parser.add_argument("--configuration-set", choices=["focused"])
    parser.add_argument("--acceptance-profile-id", choices=[V1_PROFILE_ID, V2_PROFILE_ID])
    parser.add_argument("--desktop-width", type=int, default=1366)
    parser.add_argument("--desktop-height", type=int, default=768)
    parser.add_argument("--desktop-dpi", type=int, choices=[96, 120, 144, 192], default=96)
    args = parser.parse_args(argv)
    repo = Path(repo)
    require(args.desktop_width in range(800, 1921) and args.desktop_height in range(600, 1081),
            "Appearance pair desktop must be between 800x600 and 1920x1080.")
    require(args.diagnostic or (args.desktop_width, args.desktop_height, args.desktop_dpi) == (1366, 768, 96),
            "Desktop selection requires a diagnostic.")
    require(not args.configuration_set or args.diagnostic == "appearance-pair",
            "A configuration set requires --diagnostic appearance-pair.")
    require(args.acceptance_profile_id is None or args.diagnostic in {None, "appearance-pair", ICON_SETTLEMENT_MODE},
            "Acceptance profile selection requires fixed GUI, appearance-pair or icon-settlement.")
    require(args.diagnostic != ICON_SETTLEMENT_MODE or args.acceptance_profile_id == V2_PROFILE_ID,
            "Icon settlement requires explicit V2 owned-resource profile selection.")
    require(args.icon_endpoint_method is None or args.diagnostic == ICON_SETTLEMENT_MODE,
            "Icon endpoint selection requires the icon-settlement diagnostic.")
    baseline = args.icon_endpoint_method == ICON_BASELINE_METHOD
    require((baseline and args.baseline_product_source_sha == ICON_BASELINE_PRODUCT_SOURCE_SHA and
             isinstance(args.expected_run_source_sha, str) and
             SOURCE_SHA.fullmatch(args.expected_run_source_sha) is not None) or
            (not baseline and args.baseline_product_source_sha is None and
             args.expected_run_source_sha is None),
            "Synchronous baseline requires the original product reference and exact frozen run source.")
    require(args.performance_column_order is None or args.diagnostic == "performance-sample",
            "Long-path order selection requires --diagnostic performance-sample.")
    require(args.prepared_bundle_root is None or
            (args.expected_prepared_application_sha256 is not None and
             args.diagnostic in {"performance-sample", ICON_SETTLEMENT_MODE}),
            "Prepared bundle and pinned application hash require the performance diagnostic together.")
    focused = args.diagnostic == FOCUSED_CLEAR_MODE
    require((focused and args.preserved_product_bundle_root is not None and
             args.prepared_bundle_root is None and
             args.expected_original_bundle_sha256 == FOCUSED_ORIGINAL_BUNDLE_SHA256 and
             args.expected_product_source_sha == FOCUSED_PRODUCT_SOURCE_SHA and
             args.expected_prepared_application_sha256 == FOCUSED_APPLICATION_SHA256 and
             args.expected_tooling_source_sha == source_identity(repo)[0]) or
            (not focused and args.preserved_product_bundle_root is None and
             args.expected_original_bundle_sha256 is None and
             args.expected_product_source_sha is None and
             args.expected_tooling_source_sha is None and
             (args.expected_prepared_application_sha256 is None) ==
             (args.prepared_bundle_root is None)),
            "Focused preserved product requires exact separate product, bundle, and current tooling pins.")
    require(args.diagnostic != ICON_SETTLEMENT_MODE or args.prepared_bundle_root is not None,
            "Icon settlement requires a prepared bundle and pinned application hash.")
    require(not args.configuration_set or
            (args.desktop_width, args.desktop_height, args.desktop_dpi) == (1366, 768, 96),
            "Focused configuration set does not accept desktop overrides.")
    selected_runs = ((performance_run(args.performance_column_order or "hidden-visible"),) if args.diagnostic == "performance-sample" else
                     (focused_clear_run(),) if args.diagnostic == FOCUSED_CLEAR_MODE else
                     (icon_settlement_run(args.icon_endpoint_method or ICON_SETTLEMENT_METHOD),)
                     if args.diagnostic == ICON_SETTLEMENT_MODE else
                     FOCUSED_PAIR_RUNS if args.configuration_set == "focused" else
                     (appearance_pair_run(args.desktop_width, args.desktop_height, args.desktop_dpi),)
                     if args.diagnostic == "appearance-pair" else
                     V2_RUNS if args.acceptance_profile_id == V2_PROFILE_ID else RUNS)
    if (args.diagnostic is None and args.acceptance_profile_id == V2_PROFILE_ID or
            args.diagnostic in {"appearance-pair", ICON_SETTLEMENT_MODE}):
        selected_profile = args.acceptance_profile_id or V1_PROFILE_ID
        profile_digest = None
        if selected_profile == V2_PROFILE_ID:
            profile_file = ordinary_file(Path(repo) / "config" / V2_PROFILE_FILE, 1024 * 1024,
                                         "V2 acceptance profile")
            profile_document = read_json(profile_file)
            require(profile_document.get("schema") == "darkrenamer-vm-automated-profile-v2" and
                    profile_document.get("profile_id") == V2_PROFILE_ID and
                    type(profile_document.get("revision")) is int and
                    profile_document.get("revision") == 2,
                    "V2 acceptance profile definition is unavailable.")
            profile_digest = digest(profile_file)
        selected_runs = tuple({**run, "acceptance_profile_id": selected_profile,
                               **({"acceptance_profile_sha256": profile_digest} if profile_digest else {})}
                              for run in selected_runs)
    if baseline:
        selected_runs = tuple({**run, "expected_run_source_sha": args.expected_run_source_sha}
                              for run in selected_runs)
    root = checked_new_root(args.output_root, repo)
    if focused:
        audit_focused_product_blobs(repo)
        validate_focused_original_bundle(repo, args.preserved_product_bundle_root)
    prepared_manifest = None
    if args.prepared_bundle_root is not None:
        prepared_manifest = validate_prepared_bundle(
            repo, args.prepared_bundle_root, args.expected_prepared_application_sha256)
    if baseline:
        require(source_identity(repo)[0] == args.expected_run_source_sha and
                prepared_manifest is not None and
                prepared_manifest["source_sha"] == args.expected_run_source_sha,
                "Synchronous baseline exact run source differs from the clean checkout or prepared bundle.")
    profile, profile_sha256 = load_connection_profile(args.connection_profile)
    source_identity(repo)
    host = host_preflight()
    guest = guest_preflight(profile)
    root.mkdir()
    bundle = args.prepared_bundle_root if prepared_manifest is not None else root / "bundle"
    runs_root = root / "runs"
    runs_root.mkdir()
    if focused:
        stage_focused_preserved_bundle(repo, args.preserved_product_bundle_root, bundle, tooling)
    elif prepared_manifest is None:
        launcher.build_bundle(repo, bundle, tooling)
    reference = None
    for run in selected_runs:
        run_root = runs_root / run["run_id"]
        run_root.mkdir()
        if run["mode"] == "tooltip":
            reference = reference_for(runs_root / selected_runs[0]["run_id"])
        manifest_document = input_manifest(
            repo, bundle, run_root, run, profile_sha256, host, guest, reference,
            args.expected_prepared_application_sha256 if prepared_manifest is not None or focused else None)
        if prepared_manifest is not None:
            validate_prepared_bundle(repo, bundle, args.expected_prepared_application_sha256)
            require(manifest_document["artifacts"]["application"]["sha256"] ==
                    args.expected_prepared_application_sha256 and
                    manifest_document["bundle_manifest"]["sha256"] == digest(bundle / "bundle.json"),
                    "Prepared bundle changed while immutable run inputs were staged.")
        write_json(run_root / "input-manifest.json", manifest_document, exclusive=True)
        execute_run(repo, run_root / "inputs", run_root, run, profile, launcher)
    validate_all(repo, runs_root, root, args.diagnostic, selected_runs, args.configuration_set)
    print(json.dumps({
        "status": "diagnostic-validated" if args.diagnostic else "validated",
        "source_sha": (FOCUSED_PRODUCT_SOURCE_SHA if focused else
                       (prepared_manifest or read_json(bundle / "bundle.json"))["source_sha"]),
        **({"tooling_source_sha": source_identity(repo)[0]} if focused else {}),
        "runs": [run["run_id"] for run in selected_runs],
        "diagnostic": args.diagnostic,
        "bundle_mode": ("preserved-product-current-tooling" if focused else
                        "prepared" if prepared_manifest is not None else "built"),
        "configuration_set": args.configuration_set,
        "output_root": str(root),
    }))
    return 0


def cli(repo: Path, argv: list[str] | None = None, tooling=None) -> int:
    try:
        return main(repo, argv, tooling)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
