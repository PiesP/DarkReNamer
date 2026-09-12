#!/usr/bin/env python3
"""Build and run the four source-bound DarkReNamer GUI regression cells."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import uuid
import zlib


SAFE_LEAF = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,159}")
SHA256 = re.compile(r"[0-9a-f]{64}")
SOURCE_SHA = re.compile(r"[0-9a-f]{40}")
WINDOWS_PATH = re.compile(r"[A-Za-z]:\\[^\r\n]+")
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


def decode_png(path: Path) -> tuple[int, int, bytes]:
    data = ordinary_file(path, 128 * 1024 * 1024, "Raster screenshot").read_bytes()
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), "Raster screenshot is not PNG.")
    offset = 8
    width = height = color_type = None
    compressed = bytearray()
    while offset < len(data):
        require(offset + 12 <= len(data), "PNG chunk header is truncated.")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(data), "PNG chunk is truncated.")
        payload = data[offset + 8:offset + 8 + length]
        require(zlib.crc32(kind + payload) & 0xffffffff == struct.unpack(">I", data[end - 4:end])[0],
                "PNG chunk checksum differs.")
        if kind == b"IHDR":
            require(length == 13 and width is None, "PNG has an invalid IHDR.")
            width, height, depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            require(1 <= width <= 8192 and 1 <= height <= 8192 and depth == 8
                    and color_type in {2, 6} and compression == filtering == interlace == 0,
                    "PNG format is outside the fixed raster contract.")
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
        offset = end
    require(width is not None and compressed, "PNG lacks image data.")
    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    require(len(raw) == (stride + 1) * height, "PNG decompressed size differs.")
    previous = bytearray(stride)
    rgba = bytearray()
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        scan = bytearray(raw[cursor:cursor + stride])
        cursor += stride
        require(filter_type <= 4, "PNG uses an unsupported row filter.")
        for index in range(stride):
            left = scan[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                scan[index] = (scan[index] + left) & 0xff
            elif filter_type == 2:
                scan[index] = (scan[index] + above) & 0xff
            elif filter_type == 3:
                scan[index] = (scan[index] + ((left + above) // 2)) & 0xff
            elif filter_type == 4:
                predictor = left + above - upper_left
                distances = (abs(predictor - left), abs(predictor - above), abs(predictor - upper_left))
                scan[index] = (scan[index] + (left, above, upper_left)[distances.index(min(distances))]) & 0xff
        for index in range(0, stride, channels):
            rgba.extend(scan[index:index + 3])
            rgba.append(scan[index + 3] if channels == 4 else 255)
        previous = scan
    return width, height, bytes(rgba)


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


def load_connection_profile(path: Path) -> tuple[dict, str]:
    original = path
    path = ordinary_file(path.resolve(strict=True), 16 * 1024, "Connection profile")
    require(not original.is_symlink(), "Connection profile must not be a symlink.")
    profile = read_json(path)
    require(
        set(profile) == {"schema_version", "ssh_host", "desktop_helper", "expected_vm_id"}
        and profile.get("schema_version") == 1,
        "Connection profile fields are invalid.",
    )
    require(
        isinstance(profile.get("ssh_host"), str)
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", profile["ssh_host"]) is not None,
        "Connection profile SSH alias is invalid.",
    )
    require(
        isinstance(profile.get("desktop_helper"), str)
        and WINDOWS_PATH.fullmatch(profile["desktop_helper"]) is not None,
        "Connection profile desktop helper path is invalid.",
    )
    try:
        identity = uuid.UUID(profile.get("expected_vm_id", ""))
    except (ValueError, AttributeError) as error:
        raise ValueError("Connection profile VM identity is invalid.") from error
    require(identity.int != 0, "Connection profile VM identity is invalid.")
    profile["expected_vm_id"] = str(identity)
    return profile, digest(path)


def load_native_runner(repo: Path):
    path = repo / "scripts" / "test-windows-vm.py"
    spec = importlib.util.spec_from_file_location("darkrenamer_native_vm", path)
    require(spec is not None and spec.loader is not None, "Cannot load the tracked native bundle builder.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
    return isinstance(value, dict) and all(
        isinstance(value.get(name), str) and bool(value[name]) for name in ("input", "menu_entry")
    )


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
        if isinstance(bounds, dict) and all(type(bounds.get(name)) is int for name in ("x", "y", "width", "height")) and \
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
            baseline = text_metric_samples(run_root.parent / RUNS[1]["run_id"] / "output" / "text-raster-metrics.json")
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
            "public_apply_entered": valid_apply_entry(nested(confirmation, "apply_entry")) and nested(confirmation, "scope_exact") is True and default_cancel(nested(confirmation, "default_focus")) and all(reachability_valid(nested(confirmation, "reachability", name)) for name in required_controls),
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


def run_input_artifacts(repo: Path, bundle: Path, run_root: Path) -> tuple[dict, dict]:
    manifest = read_json(bundle / "bundle.json")
    source_sha, source_tree = source_identity(repo)
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
    for row in test_binaries:
        require(isinstance(row, dict) and isinstance(row.get("file"), str)
                and SAFE_LEAF.fullmatch(row["file"]) is not None,
                "Native bundle contains an invalid test binary entry.")
        require(row["file"] not in sources, "Native bundle contains a duplicate artifact name.")
        source = ordinary_file(bundle / row["file"], 256 * 1024 * 1024, "Native test binary")
        require(digest(source) == row.get("sha256"),
                f"Native test binary hash differs from bundle.json: {row['file']}")
        sources[row["file"]] = source
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
        "source_sha": source_sha,
        "source_tree": source_tree,
    }


def input_manifest(repo: Path, bundle: Path, run_root: Path, run: dict, profile_sha256: str,
                   host_preflight: dict, guest_preflight: dict,
                   reference: dict | None = None) -> dict:
    _, inputs = run_input_artifacts(repo, bundle, run_root)
    result = {
        "schema_version": 1,
        "run_id": run["run_id"],
        "source_sha": inputs["source_sha"],
        "source_tree": inputs["source_tree"],
        "private_profile_sha256": profile_sha256,
        "host_preflight": host_preflight,
        "guest_preflight": guest_preflight,
        "bundle_manifest": inputs["bundle_manifest"],
        "artifacts": inputs["artifacts"],
        "request": {
            "mode": run["mode"],
            "appearance": run["appearance"],
            "desktop": {"width": run["width"], "height": run["height"], "dpi": run["dpi"]},
            "text_scale_percent": run["text_scale_percent"],
        },
        "expected_guest_platform": "windows",
        "command": [
            "python3", "scripts/run-gui-regression.py", "--output-root",
            "<external-output-root>", "--connection-profile", "<private-connection-profile>",
        ],
    }
    if reference is not None:
        result["full_context_reference"] = reference
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


def guest_preflight(profile: dict) -> dict:
    pwsh = shutil.which("pwsh")
    require(pwsh is not None, "GUI regression preflight requires PowerShell 7.4 or newer as pwsh.")
    script = r"""
$ErrorActionPreference = 'Stop'
$options = @{BatchMode='yes';StrictHostKeyChecking='yes';ForwardAgent='no'}
$session = New-PSSession -HostName $env:DARKRENAMER_GUI_SSH_HOST -Options $options
try {
    $value = Invoke-Command -Session $session -ScriptBlock {
        [ordered]@{
            system = 'windows'
            os_version = [Environment]::OSVersion.VersionString
            build = [Environment]::OSVersion.Version.Build.ToString()
            architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            product_caption = (Get-CimInstance Win32_OperatingSystem).Caption
            vm_id = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -Name VirtualMachineId).VirtualMachineId
        }
    }
    $value | ConvertTo-Json -Compress
}
finally { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
"""
    environment = dict(os.environ)
    environment["DARKRENAMER_GUI_SSH_HOST"] = profile["ssh_host"]
    raw = subprocess.check_output(
        [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
        env=environment, text=True,
    )
    value = json.loads(raw)
    require(isinstance(value, dict) and set(value) == {
        "system", "os_version", "build", "architecture", "product_caption", "vm_id"
    }, "Guest preflight returned an invalid document.")
    require(value["system"] == "windows" and value["architecture"].lower() in {"x64", "x86_64"},
            "Guest preflight did not reach Windows x86_64.")
    require(str(uuid.UUID(value["vm_id"])) == profile["expected_vm_id"],
            "Guest preflight VM identity differs from the private profile.")
    require(all(isinstance(value[name], str) and value[name] for name in ("product_caption", "os_version", "build")),
            "Guest preflight Windows version/build is missing.")
    require("Windows 11" in value["product_caption"] and value["build"].isdigit()
            and int(value["build"]) >= 22000,
            "Guest preflight must prove a supported Windows 11 build.")
    canonical_id = str(uuid.UUID(value["vm_id"]))
    return {
        "system": "windows", "product_caption": value["product_caption"],
        "os_version": value["os_version"],
        "build": value["build"], "architecture": "x86_64",
        "vm_identity_kind": "hyper-v-guest-parameters-virtual-machine-id-v1",
        "vm_identity_sha256": digest_text(canonical_id),
    }


def controller_command(repo: Path, bundle: Path, run_root: Path, run: dict,
                       profile: dict, lease: dict) -> list[str]:
    pwsh = shutil.which("pwsh")
    require(pwsh is not None, "GUI regression transport requires PowerShell 7.4 or newer as pwsh.")
    return [
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


def collection_document(run_root: Path, input_sha256: str, run_id: str) -> dict:
    output = run_root / "output"
    files = []
    for path in sorted(output.rglob("*")):
        if not path.is_file() or path.name == "run-result.json":
            continue
        require(not path.is_symlink(), "Collected output must not contain symlinks.")
        files.append({
            "relative_path": path.relative_to(output).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": digest(path),
        })
    require(files, "A GUI regression run returned no raw output.")
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
            "appearance": environment.get("appearance"),
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
    write_json(result_path, normalize_run_result(run_root, input_sha256), exclusive=True)


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
            "status": "passed" if (
                observer.get("guest_cleanup") is True
                and desktop_restored
                and text_scale_restored
            ) else "failed",
            "fixture": observer.get("guest_cleanup") is True,
            "process": observer.get("process_cleanup", observer.get("guest_cleanup")) is True,
            "guest": (output / "transport.json").is_file()
            and read_json(output / "transport.json").get("guest_cleanup") is True,
            "desktop_restore": desktop_restored,
            "text_scale_restore": text_scale_restored,
            "controller_exit_code": controller_exit,
        }
        write_json(output / "cleanup.json", cleanup, exclusive=True)
    require(controller_exit == 0, "GUI regression transport failed; preserve and inspect the run output.")
    require(controller_logs_bounded, "GUI regression controller stream exceeds the raw size bound.")
    finalize_run(run_root)


def validate_all(repo: Path, result_root: Path, output_root: Path) -> None:
    validator = repo / "scripts" / "validate-gui-regression-evidence.py"
    ordinary_file(validator, 2 * 1024 * 1024, "GUI regression evidence validator")
    source_sha, _ = source_identity(repo)
    command = [
        sys.executable, str(validator), "--result-root", str(result_root),
        "--expected-source-sha", source_sha,
    ]
    for run in RUNS:
        command += ["--run", run["run_id"]]
    command += ["--require-complete-set"]
    completed = subprocess.run(command, cwd=repo, check=True, capture_output=True)
    report = json.loads(completed.stdout)
    write_json(output_root / "validation-result.json", report, exclusive=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--connection-profile", type=Path, required=True)
    args = parser.parse_args(argv)
    repo = Path(__file__).resolve().parent.parent
    root = checked_new_root(args.output_root, repo)
    profile, profile_sha256 = load_connection_profile(args.connection_profile)
    source_identity(repo)
    host = host_preflight()
    guest = guest_preflight(profile)
    root.mkdir()
    bundle = root / "bundle"
    runs_root = root / "runs"
    runs_root.mkdir()
    native_runner = load_native_runner(repo)
    native_runner.build_bundle(repo, bundle)
    reference = None
    for run in RUNS:
        run_root = runs_root / run["run_id"]
        run_root.mkdir()
        if run["mode"] == "tooltip":
            reference = reference_for(runs_root / RUNS[0]["run_id"])
        write_json(
            run_root / "input-manifest.json",
            input_manifest(repo, bundle, run_root, run, profile_sha256, host, guest, reference),
            exclusive=True,
        )
        execute_run(repo, run_root / "inputs", run_root, run, profile, native_runner)
    validate_all(repo, runs_root, root)
    print(json.dumps({
        "status": "validated",
        "source_sha": read_json(bundle / "bundle.json")["source_sha"],
        "runs": [run["run_id"] for run in RUNS],
        "output_root": str(root),
    }))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
