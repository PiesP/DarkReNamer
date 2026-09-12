#!/usr/bin/env python3
"""Validate source-bound raw GUI regression runs and direct references."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import sys
import zlib


SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_LEAF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_ARTIFACT_BYTES = 128 * 1024 * 1024
MAX_COLLECTION_BYTES = 512 * 1024 * 1024
MAX_PNG_PIXELS = 32 * 1024 * 1024
REFERENCE_SCOPE = ["full-context-semantics-v1"]
RUN_MODES = {"full-context", "standard", "text-scale", "tooltip"}

FULL_CONTEXT_SEMANTICS = {
    "repeated_scope_exact",
    "repeated_default_cancel",
    "repeated_full_details_exact_document",
    "repeated_full_details_end_visible",
    "repeated_return_default_cancel",
    "repeated_cancel_disk_unchanged",
    "movement_cancelled",
    "movement_applied",
    "movement_destination_reached",
    "movement_content_preserved",
    "movement_identity_preserved",
    "movement_journal_clean",
    "mixed_scope_exact",
    "mixed_examples_exclude_third_move",
    "mixed_third_details_exact_document",
    "mixed_third_details_end_visible",
    "mixed_third_details_closed",
    "mixed_reentry_full_details_exact_document",
    "mixed_reentry_full_details_end_visible",
    "mixed_reentry_default_cancel",
    "mixed_expanded_bottom_reached_or_fits",
    "mixed_default_enter_cancelled",
    "mixed_disk_unchanged",
    "mixed_plan_identity_stable",
    "journal_clean",
    "normal_exit",
}
STANDARD_SEMANTICS = {
    "scope_exact",
    "total_3_selected_1_changed_2",
    "application_confirmed",
    "destination_reached",
    "content_preserved",
    "identity_preserved",
    "journal_clean",
    "input_text_observed",
    "full_details_text_observed",
    "normal_exit",
}
TEXT_SCALE_SEMANTICS = STANDARD_SEMANTICS | {
    "text_scale_requested_150",
    "text_scale_observed_150",
    "input_text_enlarged",
    "full_details_text_enlarged",
    "required_controls_reachable",
    "taskdialog_limit_recorded",
    "settings_restored",
}
TOOLTIP_SEMANTICS = {
    "long_row_tooltip_visible_before_apply",
    "tooltip_hidden_on_entry",
    "tooltip_hidden_settled",
    "tooltip_hidden_after_details_return",
    "tooltip_hidden_after_expansion",
    "tooltip_restored_after_cancel",
    "tooltip_hidden_after_neutral",
    "public_apply_entered",
    "destination_context_visible",
    "cancelled_disk_unchanged",
    "cancelled_fixture_identity_unchanged",
    "full_details_exact_document",
    "full_details_end_visible",
    "full_details_return_default_cancel",
    "expanded_bottom_reached",
    "cancellation_returned_to_preview",
    "journal_clean",
    "normal_exit",
}
FIXED_REQUESTS = {
    "full-context": ("light", 800, 600, 96, 100),
    "standard": ("light", 800, 600, 96, 100),
    "text-scale": ("light", 800, 600, 96, 150),
    "tooltip": ("dark", 1366, 768, 144, 100),
}
FIXED_RUN_IDS = {
    "full-context": "01-full-context-light-800x600-96-text100",
    "standard": "02-standard-light-800x600-96-text100",
    "text-scale": "03-standard-light-800x600-96-text150",
    "tooltip": "04-tooltip-dark-1366x768-144-text100",
}
MODE_SEMANTICS = {
    "full-context": FULL_CONTEXT_SEMANTICS,
    "standard": STANDARD_SEMANTICS,
    "text-scale": TEXT_SCALE_SEMANTICS,
    "tooltip": TOOLTIP_SEMANTICS,
}


class EvidenceError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"JSON contains a duplicate field: {key}")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    raise EvidenceError(f"JSON contains a non-finite number: {value}")


def exact_keys(value: object, required: set[str], label: str) -> dict:
    require(isinstance(value, dict), f"{label} must be an object.")
    actual = set(value)
    require(actual == required, f"{label} fields are invalid: {sorted(actual ^ required)}")
    return value


def typed_equal(left: object, right: object) -> bool:
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return set(left) == set(right) and all(typed_equal(left[key], right[key]) for key in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(typed_equal(a, b) for a, b in zip(left, right))
    return left == right


def int_equals(value: object, expected: int) -> bool:
    return type(value) is int and value == expected


def validate_rectangle(value: object, label: str) -> dict:
    rectangle = exact_keys(value, {"left", "top", "right", "bottom", "width", "height"}, label)
    for edge in ("left", "top", "right", "bottom"):
        checked_int(rectangle[edge], -32768, 32767, f"{label}.{edge}")
    for dimension in ("width", "height"):
        checked_int(rectangle[dimension], 1, 8192, f"{label}.{dimension}")
    require(rectangle["right"] - rectangle["left"] == rectangle["width"] and
            rectangle["bottom"] - rectangle["top"] == rectangle["height"],
            f"{label} dimensions do not match its edges.")
    return rectangle


def validate_target(value: object, label: str) -> dict:
    target = exact_keys(value, {"hwnd", "process_id", "window_rect"}, label)
    checked_int(target["hwnd"], 1, (1 << 63) - 1, f"{label}.hwnd")
    checked_int(target["process_id"], 1, (1 << 31) - 1, f"{label}.process_id")
    validate_rectangle(target["window_rect"], f"{label}.window_rect")
    return target


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def checked_root(path: Path) -> Path:
    require(path.is_absolute(), "Result root must be absolute.")
    require(path == Path(os.path.normpath(path)), "Result root must not contain dot path components.")
    for ancestor in (path, *path.parents):
        try:
            ancestor_info = ancestor.lstat()
        except FileNotFoundError as error:
            raise EvidenceError("Result root ancestor does not exist.") from error
        require(not ancestor.is_symlink(), "Result root must not cross a symlink ancestor.")
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise EvidenceError("Result root does not exist.") from error
    require(stat.S_ISDIR(info.st_mode) and not path.is_symlink(),
            "Result root must be an ordinary directory, not a symlink.")
    return path


def safe_relative(value: object, label: str) -> Path:
    require(isinstance(value, str) and value != "", f"{label} must be a relative path.")
    require("\\" not in value, f"{label} must use forward slashes.")
    parts = value.split("/")
    require(all(SAFE_LEAF.fullmatch(part) is not None for part in parts),
            f"{label} contains an unsafe path component.")
    return Path(*parts)


def ordinary_path(root: Path, relative: Path, maximum: int, label: str) -> Path:
    current = root
    for part in relative.parts:
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError as error:
            raise EvidenceError(f"{label} is missing: {relative.as_posix()}") from error
        require(not current.is_symlink(), f"{label} crosses a symlink: {relative.as_posix()}")
    require(stat.S_ISREG(info.st_mode), f"{label} must be an ordinary file: {relative.as_posix()}")
    require(info.st_size <= maximum, f"{label} exceeds its size bound: {relative.as_posix()}")
    return current


def read_bytes(root: Path, relative: Path, maximum: int, label: str) -> bytes:
    path = ordinary_path(root, relative, maximum, label)
    data = path.read_bytes()
    require(len(data) <= maximum, f"{label} changed while it was read: {relative.as_posix()}")
    return data


def parse_json_bytes(data: bytes, label: str) -> object:
    try:
        text = data.decode("utf-8-sig")
        return json.loads(
            text,
            object_pairs_hook=strict_object,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} is not strict UTF-8 JSON: {error}") from error


def read_json(root: Path, relative: Path, label: str) -> tuple[object, bytes]:
    data = read_bytes(root, relative, MAX_JSON_BYTES, label)
    return parse_json_bytes(data, label), data


def checked_digest(value: object, label: str) -> str:
    require(isinstance(value, str) and SHA256.fullmatch(value) is not None,
            f"{label} must be a lowercase SHA-256 digest.")
    return value


def checked_int(value: object, minimum: int, maximum: int, label: str) -> int:
    require(type(value) is int and minimum <= value <= maximum,
            f"{label} must be an integer from {minimum} through {maximum}.")
    return value


def checked_number(value: object, minimum: float, maximum: float, label: str) -> float:
    require(type(value) in (int, float) and math.isfinite(value) and minimum <= value <= maximum,
            f"{label} must be a finite number from {minimum} through {maximum}.")
    return float(value)


def checked_artifact(run_root: Path, value: object, label: str) -> dict:
    row = exact_keys(value, {"file", "sha256", "bytes"}, label)
    relative = safe_relative(row["file"], f"{label}.file")
    expected_size = checked_int(row["bytes"], 0, MAX_ARTIFACT_BYTES, f"{label}.bytes")
    expected_hash = checked_digest(row["sha256"], f"{label}.sha256")
    data = read_bytes(run_root, relative, MAX_ARTIFACT_BYTES, label)
    require(len(data) == expected_size and sha256_bytes(data) == expected_hash,
            f"{label} bytes do not match the input manifest.")
    return row


def validate_host_platform(value: object, label: str) -> dict:
    platform = exact_keys(value, {"system", "release", "architecture"}, label)
    require(platform["system"] == "linux", f"{label}.system must be linux.")
    require(all(isinstance(platform[name], str) and 1 <= len(platform[name]) <= 128
                for name in ("release", "architecture")),
            f"{label} release and architecture are required.")
    return platform


def validate_guest_platform(value: object, label: str) -> dict:
    platform = exact_keys(
        value,
        {"system", "product_caption", "os_version", "build", "architecture", "vm_identity_kind", "vm_identity_sha256"},
        label,
    )
    require(platform["system"] == "windows" and platform["architecture"] == "x86_64",
            f"{label} must identify Windows x86_64.")
    require(all(isinstance(platform[name], str) and 1 <= len(platform[name]) <= 128
                for name in ("product_caption", "os_version", "build")),
            f"{label} Windows version/build proof is missing.")
    require("Windows 11" in platform["product_caption"] and platform["build"].isdigit() and
            int(platform["build"]) >= 22000,
            f"{label} must prove a supported Windows 11 build.")
    require(platform["vm_identity_kind"] == "hyper-v-guest-parameters-virtual-machine-id-v1",
            f"{label} VM identity source is invalid.")
    checked_digest(platform["vm_identity_sha256"], f"{label}.vm_identity_sha256")
    return platform


def validate_request(value: object) -> dict:
    request = exact_keys(value, {"mode", "appearance", "desktop", "text_scale_percent"}, "request")
    require(request["mode"] in RUN_MODES, "request.mode is invalid.")
    require(request["appearance"] in {"light", "dark"}, "request.appearance is invalid.")
    desktop = exact_keys(request["desktop"], {"width", "height", "dpi"}, "request.desktop")
    checked_int(desktop["width"], 800, 8192, "request.desktop.width")
    checked_int(desktop["height"], 600, 4320, "request.desktop.height")
    checked_int(desktop["dpi"], 96, 480, "request.desktop.dpi")
    text = checked_int(request["text_scale_percent"], 100, 225, "request.text_scale_percent")
    expected = FIXED_REQUESTS[request["mode"]]
    require((request["appearance"], desktop["width"], desktop["height"], desktop["dpi"], text) == expected,
            "Request does not match its fixed four-cell regression tuple.")
    return request


def validate_reference(value: object, run_id: str) -> dict:
    reference = exact_keys(
        value,
        {"run_id", "input_manifest_sha256", "result_sha256", "scope"},
        "full_context_reference",
    )
    require(isinstance(reference["run_id"], str) and SAFE_LEAF.fullmatch(reference["run_id"]),
            "full_context_reference.run_id is unsafe.")
    require(reference["run_id"] != run_id, "A run cannot reference itself.")
    checked_digest(reference["input_manifest_sha256"], "full_context_reference.input_manifest_sha256")
    checked_digest(reference["result_sha256"], "full_context_reference.result_sha256")
    require(reference["scope"] == REFERENCE_SCOPE,
            "full_context_reference.scope must be the fixed full-context semantic scope.")
    return reference


def validate_input_manifest(run_root: Path, expected_source_sha: str) -> tuple[dict, bytes]:
    value, data = read_json(run_root, Path("input-manifest.json"), "input manifest")
    required = {
        "schema_version", "run_id", "source_sha", "source_tree", "bundle_manifest",
        "artifacts", "private_profile_sha256", "host_preflight", "guest_preflight",
        "request", "expected_guest_platform", "command",
    }
    if isinstance(value, dict) and "full_context_reference" in value:
        required.add("full_context_reference")
    manifest = exact_keys(value, required, "input manifest")
    require(int_equals(manifest["schema_version"], 1), "input manifest schema_version must be integer 1.")
    require(isinstance(manifest["run_id"], str) and SAFE_LEAF.fullmatch(manifest["run_id"]),
            "input manifest run_id is unsafe.")
    require(manifest["run_id"] == run_root.name, "input manifest run_id differs from its directory.")
    require(manifest["source_sha"] == expected_source_sha,
            "input manifest source_sha does not match the expected exact source SHA.")
    require(isinstance(manifest["source_tree"], str) and SHA1.fullmatch(manifest["source_tree"]),
            "input manifest source_tree is invalid.")
    require(manifest["expected_guest_platform"] == "windows",
            "input manifest must expect a Windows guest.")
    checked_digest(manifest["private_profile_sha256"], "input manifest private_profile_sha256")
    checked_artifact(run_root, manifest["bundle_manifest"], "bundle_manifest")
    artifacts = exact_keys(
        manifest["artifacts"],
        {"application", "runner", "observer", "launcher", "controller", "lockfile", "builder"},
        "artifacts",
    )
    for name, row in artifacts.items():
        checked_artifact(run_root, row, f"artifacts.{name}")
    request = validate_request(manifest["request"])
    validate_host_platform(manifest["host_preflight"], "input manifest host_preflight")
    validate_guest_platform(manifest["guest_preflight"], "input manifest guest_preflight")
    command = manifest["command"]
    require(isinstance(command, list) and 1 <= len(command) <= 128 and
            all(isinstance(item, str) and 0 < len(item) <= 4096 for item in command),
            "input manifest command must be a bounded argv string array.")
    if request["mode"] == "tooltip":
        require("full_context_reference" in manifest,
                "The tooltip run requires a direct full-context reference.")
        validate_reference(manifest["full_context_reference"], manifest["run_id"])
    else:
        require("full_context_reference" not in manifest,
                "Only the tooltip run may contain a full-context reference.")
    return manifest, data


def validate_collection(run_root: Path, input_hash: str) -> tuple[dict, bytes, dict[str, dict]]:
    value, data = read_json(run_root, Path("collection.json"), "collection")
    collection = exact_keys(value, {"schema_version", "run_id", "input_manifest_sha256", "files"}, "collection")
    require(int_equals(collection["schema_version"], 1), "collection schema_version must be integer 1.")
    require(collection["run_id"] == run_root.name, "collection run_id mismatch.")
    require(collection["input_manifest_sha256"] == input_hash,
            "collection does not pin the input manifest bytes.")
    rows = collection["files"]
    require(isinstance(rows, list) and 1 <= len(rows) <= 256, "collection.files is invalid.")
    found: dict[str, dict] = {}
    total = 0
    for index, value in enumerate(rows):
        row = exact_keys(value, {"relative_path", "bytes", "sha256"}, f"collection.files[{index}]")
        relative = safe_relative(row["relative_path"], f"collection.files[{index}].relative_path")
        name = relative.as_posix()
        require(name not in found and name != "run-result.json", "collection contains a duplicate or normalized result path.")
        expected_size = checked_int(row["bytes"], 0, MAX_ARTIFACT_BYTES, f"collection.files[{index}].bytes")
        expected_hash = checked_digest(row["sha256"], f"collection.files[{index}].sha256")
        artifact = read_bytes(run_root / "output", relative, MAX_ARTIFACT_BYTES, "collected artifact")
        require(len(artifact) == expected_size and sha256_bytes(artifact) == expected_hash,
                f"Collected artifact does not match its receipt: {name}")
        if name.endswith(".png"):
            require(artifact.startswith(b"\x89PNG\r\n\x1a\n"), f"Collected PNG signature is invalid: {name}")
        found[name] = row
        total += len(artifact)
    require(total <= MAX_COLLECTION_BYTES, "Collected evidence exceeds its aggregate size bound.")
    mandatory = {
        "acceptance-result.json", "acceptance-observations.json", "observer.stdout.txt",
        "observer.stderr.txt", "cleanup.json", "platform-preflight.json", "platform-postlaunch.json",
        "transport.json",
    }
    require(mandatory <= set(found), f"Collection is missing required raw evidence: {sorted(mandatory - set(found))}")
    require(any(name.endswith(".png") for name in found), "Collection contains no original PNG evidence.")
    output = run_root / "output"
    require(output.is_dir() and not output.is_symlink(), "output must be an ordinary directory.")
    actual: set[str] = set()
    for path in output.rglob("*"):
        relative = path.relative_to(output)
        if path.is_dir() and not path.is_symlink():
            continue
        ordinary_path(output, relative, MAX_ARTIFACT_BYTES, "output inventory entry")
        actual.add(relative.as_posix())
    require(actual == set(found) | {"run-result.json"},
            "Output inventory differs from collection plus normalized run-result.json.")
    return collection, data, found


def validate_cleanup(run_root: Path, input_hash: str) -> tuple[dict, bytes]:
    value, data = read_json(run_root / "output", Path("cleanup.json"), "cleanup")
    cleanup = exact_keys(
        value,
        {"schema_version", "run_id", "input_manifest_sha256", "status", "controller_exit_code", "fixture", "process", "guest", "desktop_restore", "text_scale_restore"},
        "cleanup",
    )
    require(int_equals(cleanup["schema_version"], 1) and cleanup["run_id"] == run_root.name,
            "cleanup identity is invalid.")
    require(cleanup["input_manifest_sha256"] == input_hash,
            "cleanup does not pin the input manifest bytes.")
    require(cleanup["status"] == "passed", "cleanup.status must be passed.")
    require(type(cleanup["controller_exit_code"]) is int and cleanup["controller_exit_code"] == 0,
            "cleanup.controller_exit_code must be integer zero.")
    for name in ("fixture", "process", "guest", "desktop_restore", "text_scale_restore"):
        require(cleanup[name] is True, f"cleanup.{name} must be the boolean true.")
    return cleanup, data


def validate_platform_preflight(run_root: Path, manifest: dict, input_hash: str) -> tuple[dict, dict]:
    value, _ = read_json(run_root / "output", Path("platform-preflight.json"), "platform preflight")
    preflight = exact_keys(
        value,
        {"schema_version", "run_id", "input_manifest_sha256", "phase", "source_sha", "application_sha256", "runner_sha256", "observer_sha256", "guest_platform"},
        "platform preflight",
    )
    require(int_equals(preflight["schema_version"], 1) and preflight["run_id"] == run_root.name and preflight["phase"] == "pre-launch",
            "platform preflight identity or phase is invalid.")
    require(preflight["input_manifest_sha256"] == input_hash,
            "platform preflight does not pin the input manifest bytes.")
    artifacts = manifest["artifacts"]
    expected = {
        "source_sha": manifest["source_sha"],
        "application_sha256": artifacts["application"]["sha256"],
        "runner_sha256": artifacts["runner"]["sha256"],
        "observer_sha256": artifacts["observer"]["sha256"],
    }
    require(all(preflight[name] == value for name, value in expected.items()),
            "platform preflight source or executable inputs differ from the input manifest.")
    guest = validate_guest_platform(preflight["guest_platform"], "platform preflight guest_platform")
    require(guest == manifest["guest_preflight"],
            "Platform preflight guest differs from the immutable guest preflight.")
    post_value, _ = read_json(run_root / "output", Path("platform-postlaunch.json"), "platform postlaunch identity")
    post = exact_keys(
        post_value,
        {"schema_version", "run_id", "input_manifest_sha256", "phase", "vm_identity_kind", "vm_identity_sha256", "target", "identity_observation"},
        "platform postlaunch identity",
    )
    require(int_equals(post["schema_version"], 1) and post["run_id"] == run_root.name and
            post["input_manifest_sha256"] == input_hash and post["phase"] == "post-launch",
            "Platform postlaunch identity or manifest binding is invalid.")
    require(post["vm_identity_kind"] == guest["vm_identity_kind"] and
            post["vm_identity_sha256"] == guest["vm_identity_sha256"],
            "Platform postlaunch VM identity differs from immutable preflight identity.")
    target = validate_target(post["target"], "platform postlaunch target")
    observation = exact_keys(post["identity_observation"], {"source", "session", "target_process_id"},
                             "platform postlaunch identity_observation")
    require(observation["source"] == r"HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters::VirtualMachineId" and
            observation["session"] == "controller-pssession" and
            int_equals(observation["target_process_id"], target["process_id"]),
            "Platform postlaunch identity observation is not bound to the launched target.")
    return preflight, post


def nested(value: object, *path: str) -> object:
    current = value
    for part in path:
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def default_cancel(value: object) -> bool:
    return isinstance(value, dict) and value.get("is_default_cancel") is True


def returned_to_preview(value: object, expected_input: str | None = None) -> bool:
    if not isinstance(value, dict):
        return False
    return (expected_input is None or value.get("input") == expected_input) and \
        value.get("returned_to_preview") is True and value.get("default_cancel_preserved") is True


def valid_apply_entry(value: object) -> bool:
    return isinstance(value, dict) and isinstance(value.get("input"), str) and bool(value["input"]) and \
        isinstance(value.get("menu_entry"), str) and bool(value["menu_entry"])


def reachability_valid(value: object) -> bool:
    return isinstance(value, dict) and value.get("status") == "reachable" and \
        value.get("inside_work_area") is True and \
        type(nested(value, "physical_mouse_target", "hit_window")) is int and \
        nested(value, "physical_mouse_target", "hit_window") != 0


def control_visible(value: object, work_area: dict) -> bool:
    if not isinstance(value, dict) or value.get("enabled") is not True or value.get("offscreen") is not False:
        return False
    bounds = value.get("bounds")
    return isinstance(bounds, dict) and all(type(bounds.get(name)) is int for name in ("x", "y", "width", "height")) and \
        bounds["width"] > 0 and bounds["height"] > 0 and \
        work_area["left"] <= bounds["x"] and work_area["top"] <= bounds["y"] and \
        bounds["x"] + bounds["width"] <= work_area["right"] and \
        bounds["y"] + bounds["height"] <= work_area["bottom"]


def tree_has_visible_control(tree: object, automation_id: str, work_area: dict) -> bool:
    return isinstance(tree, list) and any(
        isinstance(item, dict) and item.get("automation_id") == automation_id and control_visible(item, work_area)
        for item in tree
    )


def validate_raw_environment(scenario: dict, manifest: dict, result: dict) -> None:
    request = manifest["request"]
    actual = result["actual"]
    require(scenario.get("appearance") == request["appearance"],
            "Raw scenario appearance differs from the request.")
    environment = nested(scenario, "environment")
    require(isinstance(environment, dict), "Raw scenario environment is missing.")
    require(typed_equal(environment.get("physical_screen"), actual["monitor"]) and
            typed_equal(environment.get("work_area"), actual["work_area"]),
            "Raw screen/work-area rectangles differ from normalized observed output.")
    require(type(environment.get("hwnd_dpi")) is int and
            environment.get("hwnd_dpi") == actual["hwnd_dpi"] and
            type(environment.get("text_scale_factor_percent")) is int and
            environment.get("text_scale_factor_percent") == actual["text_scale_percent"],
            "Raw DPI or text-scale observation differs from normalized output.")
    requested = environment.get("requested_small_workspace")
    require(isinstance(requested, dict) and type(requested.get("width")) is int and
            requested.get("width") == request["desktop"]["width"] and
            type(requested.get("height")) is int and requested.get("height") == request["desktop"]["height"] and
            requested.get("actual_screen_matches") is True and
            requested.get("display_mode_advertised") is True and
            requested.get("status") == "observed-exact" and
            requested.get("mutation_attempted") is False,
            "Raw requested-workspace proof is incomplete or mismatched.")


def derive_raw_semantics(raw: dict, mode: str, cleanup: dict, result: dict) -> dict[str, bool | None]:
    scenario = nested(raw, "assertions", "scenario")
    require(isinstance(scenario, dict), "Raw observer scenario evidence is missing.")

    if mode == "full-context":
        repeated = nested(scenario, "repeated")
        movement = nested(scenario, "movement")
        mixed = nested(scenario, "mixed")
        require(all(isinstance(value, dict) for value in (repeated, movement, mixed)),
                "Raw full-context scenario records are missing.")
        confirmations = [
            nested(repeated, "zero_deletion_and_a_insertion_confirmation"),
            nested(repeated, "korean_insertion_confirmation"),
        ]
        third = nested(mixed, "third_destination_diagnostic")
        reentry = nested(mixed, "reentry_confirmation")
        bottom = nested(reentry, "expanded", "bottom_scroll")
        default_enter = nested(mixed, "default_enter_cancellation")
        actual_apply = nested(movement, "actual_apply")
        zero = confirmations[0]
        required_controls = ("cancel", "apply", "full_details", "expander")
        require(nested(repeated, "inputs_in_admission_order") ==
                ["0 x101 -> 0 x100", "a x100 -> a x101", "가 x100 -> 가 x101"],
                "Raw repeated admission order differs from the fixed scenario.")
        derived = {
            "repeated_scope_exact": all(nested(value, "scope_exact") is True for value in confirmations) and
                                    all(reachability_valid(nested(zero, "reachability", name)) for name in required_controls),
            "repeated_default_cancel": default_cancel(nested(zero, "default_focus")),
            "repeated_full_details_exact_document": nested(zero, "full_details", "canonical_text", "exact_document") is True,
            "repeated_full_details_end_visible": nested(zero, "full_details", "native_end_scroll", "ending_visible") is True,
            "repeated_return_default_cancel": default_cancel(nested(zero, "full_details", "return_default_cancel")),
            "repeated_cancel_disk_unchanged": nested(repeated, "cancellation_disk_unchanged") is True,
            "movement_cancelled": returned_to_preview(nested(movement, "cancellation_confirmation", "cancellation")) and nested(movement, "cancellation_disk_unchanged") is True,
            "movement_applied": isinstance(actual_apply, dict) and actual_apply.get("input") in {"physical-mouse", "keyboard-enter"} and
                                reachability_valid(nested(actual_apply, "reachability")),
            "movement_destination_reached": nested(actual_apply, "destination_reached") is True,
            "movement_content_preserved": nested(actual_apply, "content_preserved") is True,
            "movement_identity_preserved": nested(actual_apply, "identity_preserved") is True,
            "movement_journal_clean": int_equals(nested(actual_apply, "journal_residue_count"), 0),
            "mixed_scope_exact": nested(reentry, "scope_exact") is True and
                                 all(reachability_valid(nested(reentry, "reachability", name)) for name in required_controls),
            "mixed_examples_exclude_third_move": nested(mixed, "two_of_three_examples_exclude_third_move") is True,
            "mixed_third_details_exact_document": nested(third, "presentation") == "read-only-multiline-edit" and nested(third, "canonical_text", "exact_document") is True,
            "mixed_third_details_end_visible": nested(third, "native_end_scroll", "ending_visible") is True,
            "mixed_third_details_closed": nested(third, "close", "closed") is True,
            "mixed_reentry_full_details_exact_document": nested(reentry, "full_details", "canonical_text", "exact_document") is True,
            "mixed_reentry_full_details_end_visible": nested(reentry, "full_details", "native_end_scroll", "ending_visible") is True,
            "mixed_reentry_default_cancel": default_cancel(nested(reentry, "full_details", "return_default_cancel")),
            "mixed_expanded_bottom_reached_or_fits": isinstance(bottom, dict) and bottom.get("status") == "physically-scrolled-to-native-bottom" and nested(bottom, "range_value", "reached_maximum") is True,
            "mixed_default_enter_cancelled": default_enter.get("input") == "keyboard-enter-on-default-cancel" and default_cancel(nested(default_enter, "default_focus")) and nested(default_enter, "disk_unchanged") is True and int_equals(nested(default_enter, "journal_residue_count"), 0),
            "mixed_disk_unchanged": returned_to_preview(nested(reentry, "cancellation")) and nested(mixed, "cancellation_disk_unchanged") is True,
            "mixed_plan_identity_stable": nested(mixed, "expanded_plan_identity_stable") is True,
            "journal_clean": all(int_equals(nested(value, "journal_residue_count"), 0) for value in (repeated, mixed, actual_apply, default_enter)),
            "normal_exit": all(int_equals(nested(value, "normal_exit_code"), 0) for value in (repeated, movement, mixed)),
        }
    elif mode in {"standard", "text-scale"}:
        fixture = nested(scenario, "fixture")
        confirmation = nested(scenario, "confirmation")
        apply = nested(scenario, "actual_apply")
        controls_reachable = all(tree_has_visible_control(nested(confirmation, "tree"), automation_id,
                                                          result["actual"]["work_area"])
                                 for automation_id in ("CommandLink_1101", "CommandLink_1102",
                                                       "ExpandoButton", "CommandButton_2")) and all(
            reachability_valid(nested(confirmation, "reachability", name))
            for name in ("cancel", "apply", "full_details", "expander")
        )
        full_details = nested(confirmation, "full_details")
        cancellation = nested(confirmation, "cancellation")
        derived = {
            "scope_exact": nested(confirmation, "scope_3_1_2") is True and default_cancel(nested(confirmation, "default_focus")) and nested(apply, "scope") == "3/1/2",
            "total_3_selected_1_changed_2": int_equals(nested(fixture, "count"), 3) and int_equals(nested(fixture, "selected"), 1) and int_equals(nested(fixture, "changed"), 2) and int_equals(nested(scenario, "selection", "selected_count"), 1),
            "application_confirmed": isinstance(apply, dict) and valid_apply_entry(nested(apply, "apply_entry")) and nested(apply, "scope") == "3/1/2" and returned_to_preview(cancellation),
            "destination_reached": nested(apply, "destinations_reached") is True,
            "content_preserved": nested(apply, "content_and_identity_preserved") is True and nested(apply, "unchanged_row_preserved") is True,
            "identity_preserved": nested(apply, "content_and_identity_preserved") is True and nested(apply, "unchanged_row_preserved") is True,
            "journal_clean": int_equals(nested(apply, "journal_residue_count"), 0) and int_equals(nested(scenario, "journal_residue_count"), 0) and nested(scenario, "cancellation_disk_unchanged") is True,
            "input_text_observed": None,
            "full_details_text_observed": None,
            "normal_exit": int_equals(nested(scenario, "normal_exit_code"), 0),
        }
        require(nested(full_details, "canonical_text", "exact_document") is True and
                nested(full_details, "copy_contention", "details_handle_preserved") is True and
                nested(full_details, "copy_all_retry", "exact") is True and
                nested(full_details, "native_end_scroll", "ending_visible") is True and
                default_cancel(nested(full_details, "escape_return_default_cancel")),
                "Raw standard full-details evidence is incomplete.")
        blocking = nested(scenario, "blocking")
        if mode == "standard":
            require(isinstance(blocking, dict) and all(nested(blocking, name, "blocked") is True
                    for name in ("no_change", "collision", "invalid_name")),
                    "Raw text100 blocking evidence is incomplete.")
        else:
            require(isinstance(blocking, dict) and blocking.get("status") == "not-run" and
                    blocking.get("reason") == "covered-by-paired-text100-standard-run",
                    "Text150 blocking must be explicitly not-run with the paired-text100 reason.")
        if mode == "text-scale":
            derived.update({
                "text_scale_requested_150": int_equals(nested(raw, "text_scale", "requested_percent"), 150) and int_equals(nested(raw, "text_scale", "registry_percent"), 150),
                "text_scale_observed_150": int_equals(nested(raw, "text_scale", "acceptance_percent"), 150) and int_equals(nested(scenario, "environment", "text_scale_factor_percent"), 150),
                "input_text_enlarged": None,
                "full_details_text_enlarged": None,
                "required_controls_reachable": controls_reachable,
                "taskdialog_limit_recorded": scenario.get("limitations") == ["native-taskdialog-text-scale-not-observed"],
                "settings_restored": cleanup.get("text_scale_restore") is True and nested(raw, "text_scale", "restoration") == "verified",
            })
    else:
        surface = nested(scenario, "surface")
        overlay = nested(surface, "confirmation", "modal_overlay")
        require(isinstance(surface, dict) and isinstance(overlay, dict),
                "Raw tooltip lifecycle evidence is missing.")
        confirmation = nested(surface, "confirmation")
        after_details = nested(overlay, "after_details_return")
        after_expansion = nested(overlay, "after_expansion")
        after_cancel = nested(overlay, "after_cancel")
        apply_entry = nested(confirmation, "apply_entry")
        details = nested(confirmation, "full_details")
        expanded = nested(confirmation, "expanded", "bottom_scroll")
        omissions = [
            "second-repeated-fixture", "movement-actual-apply",
            "mixed-destination-third-unsampled-reentry", "default-enter-cancel", "alt-tab-roundtrip",
        ]
        require(scenario.get("mode") == "context-surface" and
                nested(scenario, "full_context_coverage", "omitted") == omissions,
                "Raw tooltip mode or fixed full-context omissions are invalid.")
        derived = {
            "long_row_tooltip_visible_before_apply": nested(overlay, "pre_modal", "visible_before_public_apply") is True and nested(overlay, "pre_modal", "window", "visible") is True,
            "tooltip_hidden_on_entry": overlay.get("owner_disabled") is True and overlay.get("at_entry_bound_tooltip_visible") is False,
            "tooltip_hidden_settled": overlay.get("persisted_visible_tooltip") is False and overlay.get("persisted_essential_overlap") is False,
            "tooltip_hidden_after_details_return": isinstance(after_details, dict) and after_details.get("bound_tooltip_visible") is False and after_details.get("essential_overlap") is False,
            "tooltip_hidden_after_expansion": isinstance(after_expansion, dict) and after_expansion.get("bound_tooltip_visible") is False and after_expansion.get("essential_overlap") is False,
            "tooltip_restored_after_cancel": isinstance(after_cancel, dict) and after_cancel.get("bound_tooltip_reexposed") is True and nested(after_cancel, "window", "visible") is True,
            "tooltip_hidden_after_neutral": nested(after_cancel, "neutral_hidden") is True,
            "public_apply_entered": valid_apply_entry(apply_entry) and
                                    nested(confirmation, "scope_exact") is True and
                                    default_cancel(nested(confirmation, "default_focus")) and
                                    all(reachability_valid(nested(confirmation, "reachability", name))
                                        for name in ("cancel", "apply", "full_details", "expander")),
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
    require(set(derived) == MODE_SEMANTICS[mode], "Internal raw semantic mapping is incomplete.")
    return derived


def validate_raw_result(run_root: Path, manifest: dict, result: dict, collection_files: dict[str, dict]) -> dict:
    raw_value, raw_bytes = read_json(run_root / "output", Path("acceptance-result.json"), "raw observer result")
    require(isinstance(raw_value, dict), "raw observer result must be an object.")
    require(int_equals(raw_value.get("schema_version"), 1),
            "Raw observer result schema_version must be integer 1.")
    observer = exact_keys(result["observer_result"], {"file", "sha256", "bytes", "status"}, "observer_result")
    require(observer["file"] == "acceptance-result.json", "observer_result.file is invalid.")
    require(observer["bytes"] == len(raw_bytes) and observer["sha256"] == sha256_bytes(raw_bytes),
            "observer_result does not bind the raw result bytes.")
    receipt = collection_files["acceptance-result.json"]
    require(receipt["bytes"] == len(raw_bytes) and receipt["sha256"] == sha256_bytes(raw_bytes),
            "Raw observer result differs from the collection receipt.")
    require(observer["status"] == raw_value.get("status") == result["status"] == "review_required",
            "Passing raw GUI evidence must remain review_required pending human visual acceptance.")
    artifacts = manifest["artifacts"]
    require(raw_value.get("source_sha") == manifest["source_sha"], "Raw observer source SHA mismatch.")
    require(raw_value.get("application", {}).get("sha256") == artifacts["application"]["sha256"],
            "Raw observer executable SHA mismatch.")
    require(raw_value.get("runner_sha256") == artifacts["runner"]["sha256"], "Raw observer runner SHA mismatch.")
    require(raw_value.get("acceptance_script_sha256") == artifacts["observer"]["sha256"],
            "Raw observer script SHA mismatch.")
    require(raw_value.get("assertions", {}).get("overall") == "passed",
            "Raw observer assertions did not pass.")
    require(raw_value.get("guest_cleanup") is True, "Raw observer did not report clean guest fixtures.")
    for name in ("keyboard", "accessibility", "capture"):
        require(nested(raw_value, name, "status") == "passed",
                f"Raw observer {name} status did not pass.")
    observations, observation_bytes = read_json(
        run_root / "output", Path("acceptance-observations.json"), "raw acceptance observations"
    )
    observation_receipt = collection_files["acceptance-observations.json"]
    require(observation_receipt["bytes"] == len(observation_bytes) and
            observation_receipt["sha256"] == sha256_bytes(observation_bytes),
            "Raw acceptance observations differ from the collection receipt.")
    require(isinstance(observations, dict) and
            int_equals(observations.get("schema_version"), 1) and
            typed_equal(observations.get("scenario"), nested(raw_value, "assertions", "scenario")),
            "Raw acceptance observations do not exactly mirror the observer scenario.")
    return raw_value


def validate_transport_exit(run_root: Path, collection_files: dict[str, dict], normalized_exit: int) -> None:
    value, raw = read_json(run_root / "output", Path("transport.json"), "raw transport result")
    receipt = collection_files["transport.json"]
    require(receipt["bytes"] == len(raw) and receipt["sha256"] == sha256_bytes(raw),
            "Raw transport result differs from the collection receipt.")
    require(isinstance(value, dict), "Raw transport result must be an object.")
    require(value.get("status") == "collected", "Raw transport status must be collected.")
    require(value.get("guest_cleanup") is True, "Raw transport guest cleanup must be the boolean true.")
    observer = exact_keys(value.get("observer_process"), {"state", "exit_code"},
                          "transport observer_process")
    require(observer["state"] == "exited", "Transport observer process is not in its terminal state.")
    exit_code = observer["exit_code"]
    require(type(exit_code) is int and exit_code == 0 and exit_code == normalized_exit,
            "Transport observer terminal exit code must be integer zero and match the normalized result.")


def validate_raw_semantics(result: dict, raw: dict, mode: str, cleanup: dict,
                           text_metrics: dict[str, dict] | None) -> dict[str, bool | None]:
    derived = derive_raw_semantics(raw, mode, cleanup, result)
    if text_metrics is not None:
        derived["input_text_observed"] = "prefix-input" in text_metrics
        derived["full_details_text_observed"] = "full-details" in text_metrics
    for name, passed in derived.items():
        if passed is not None:
            require(passed is True, f"Raw scenario evidence does not support semantic assertion: {name}")
            require(result["assertions"]["semantics"][name] is True,
                    f"Normalized semantic assertion differs from raw evidence: {name}")
    return derived


def validate_semantics(result: dict, mode: str) -> None:
    assertions = exact_keys(result["assertions"], {"overall", "semantics"}, "assertions")
    require(assertions["overall"] == "passed", "Normalized assertions did not pass.")
    semantics = assertions["semantics"]
    require(isinstance(semantics, dict) and set(semantics) == MODE_SEMANTICS[mode],
            f"{mode} semantic assertion set is incomplete or unexpected.")
    for name, value in semantics.items():
        require(value is True, f"Semantic assertion did not pass: {name}")


def validate_run_result(
    run_root: Path,
    manifest: dict,
    input_hash: str,
    collection_bytes: bytes,
    cleanup_bytes: bytes,
    preflight: dict,
    postlaunch: dict,
    collection_files: dict[str, dict],
) -> tuple[dict, bytes, dict]:
    value, data = read_json(run_root / "output", Path("run-result.json"), "normalized run result")
    result = exact_keys(
        value,
        {
            "schema_version", "run_id", "input_manifest_sha256", "collection_sha256", "cleanup_sha256",
            "source_sha", "application_sha256", "runner_sha256", "observer_sha256", "observer_result",
            "host_platform", "guest_platform", "actual", "exit_code", "assertions", "status",
        },
        "normalized run result",
    )
    require(int_equals(result["schema_version"], 1) and result["run_id"] == run_root.name,
            "normalized run result identity is invalid.")
    require(result["input_manifest_sha256"] == input_hash,
            "normalized run result does not pin the input manifest bytes.")
    require(result["collection_sha256"] == sha256_bytes(collection_bytes),
            "normalized run result does not pin collection.json bytes.")
    require(result["cleanup_sha256"] == sha256_bytes(cleanup_bytes),
            "normalized run result does not pin cleanup.json bytes.")
    artifacts = manifest["artifacts"]
    expected = {
        "source_sha": manifest["source_sha"],
        "application_sha256": artifacts["application"]["sha256"],
        "runner_sha256": artifacts["runner"]["sha256"],
        "observer_sha256": artifacts["observer"]["sha256"],
    }
    require(all(result[name] == expected_value for name, expected_value in expected.items()),
            "normalized run result source or executable binding mismatch.")
    host = validate_host_platform(result["host_platform"], "host_platform")
    require(host == manifest["host_preflight"],
            "Run result host platform differs from the immutable host preflight.")
    require(result["guest_platform"] == preflight["guest_platform"],
            "Run result guest platform differs from pre-launch proof.")
    actual = exact_keys(
        result["actual"],
        {"appearance", "monitor", "work_area", "target", "hwnd_dpi", "text_scale_percent"},
        "actual",
    )
    request = manifest["request"]
    desktop = request["desktop"]
    require(actual["appearance"] == request["appearance"], "Requested and actual appearance differ.")
    rectangles = {}
    for name in ("monitor", "work_area"):
        rectangles[name] = validate_rectangle(actual[name], f"actual.{name}")
    monitor = rectangles["monitor"]
    work = rectangles["work_area"]
    require(monitor["width"] == desktop["width"] and monitor["height"] == desktop["height"],
            "Requested and actual monitor dimensions differ.")
    require(monitor["left"] <= work["left"] < work["right"] <= monitor["right"] and
            monitor["top"] <= work["top"] < work["bottom"] <= monitor["bottom"],
            "Actual work area lies outside the monitor.")
    target = validate_target(actual["target"], "actual.target")
    require(typed_equal(target, postlaunch["target"]),
            "Normalized target differs from the independent postlaunch target observation.")
    window = target["window_rect"]
    require(work["left"] <= window["left"] < window["right"] <= work["right"] and
            work["top"] <= window["top"] < window["bottom"] <= work["bottom"],
            "Observed launched application window lies outside the work area.")
    checked_int(actual["hwnd_dpi"], 96, 480, "actual.hwnd_dpi")
    require(actual["hwnd_dpi"] == desktop["dpi"], "Requested and actual HWND DPI differ.")
    checked_int(actual["text_scale_percent"], 100, 225, "actual.text_scale_percent")
    require(actual["text_scale_percent"] == request["text_scale_percent"],
            "Requested and actual text scale differ.")
    require(type(result["exit_code"]) is int and result["exit_code"] == 0,
            "Observer exit_code must be integer zero.")
    validate_transport_exit(run_root, collection_files, result["exit_code"])
    validate_semantics(result, request["mode"])
    raw = validate_raw_result(run_root, manifest, result, collection_files)
    return result, data, raw


def paeth(left: int, up: int, upper_left: int) -> int:
    prediction = left + up - upper_left
    left_distance = abs(prediction - left)
    up_distance = abs(prediction - up)
    upper_left_distance = abs(prediction - upper_left)
    if left_distance <= up_distance and left_distance <= upper_left_distance:
        return left
    if up_distance <= upper_left_distance:
        return up
    return upper_left


def decode_png(data: bytes, label: str) -> tuple[int, int, bytes]:
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), f"{label} has an invalid PNG signature.")
    offset = 8
    ihdr = None
    compressed = bytearray()
    saw_iend = False
    while offset < len(data):
        require(offset + 12 <= len(data), f"{label} has a truncated PNG chunk.")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(length <= MAX_ARTIFACT_BYTES and end <= len(data), f"{label} has an invalid PNG chunk length.")
        payload = data[offset + 8:offset + 8 + length]
        checksum = struct.unpack(">I", data[offset + 8 + length:end])[0]
        require((zlib.crc32(kind + payload) & 0xFFFFFFFF) == checksum, f"{label} has a PNG CRC mismatch.")
        require(kind != b"tRNS", f"{label} uses unsupported PNG transparency.")
        require(kind in {b"IHDR", b"IDAT", b"IEND"} or kind[0] & 0x20,
                f"{label} uses an unsupported critical PNG chunk.")
        if kind == b"IHDR":
            require(ihdr is None and length == 13 and offset == 8, f"{label} has an invalid IHDR.")
            ihdr = payload
        elif kind == b"IDAT":
            require(ihdr is not None and not saw_iend, f"{label} has IDAT in an invalid position.")
            compressed.extend(payload)
            require(len(compressed) <= MAX_ARTIFACT_BYTES, f"{label} has too much compressed raster data.")
        elif kind == b"IEND":
            require(length == 0 and not saw_iend, f"{label} has an invalid IEND.")
            saw_iend = True
            require(end == len(data), f"{label} has trailing bytes after IEND.")
        offset = end
    require(ihdr is not None and saw_iend and compressed, f"{label} is missing required PNG chunks.")
    width, height, depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", ihdr)
    require(width > 0 and height > 0 and width * height <= MAX_PNG_PIXELS, f"{label} dimensions are invalid.")
    require(depth == 8 and color_type in {0, 2, 4, 6} and compression == 0 and filtering == 0 and interlace == 0,
            f"{label} uses an unsupported PNG encoding.")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    stride = width * channels
    expected = (stride + 1) * height
    try:
        inflater = zlib.decompressobj()
        raw = inflater.decompress(bytes(compressed), expected + 1)
        require(len(raw) <= expected and not inflater.unconsumed_tail,
                f"{label} decoded raster exceeds its declared dimensions.")
        raw += inflater.flush(expected + 1 - len(raw))
    except zlib.error as error:
        raise EvidenceError(f"{label} has invalid compressed raster data.") from error
    require(len(raw) == expected and inflater.eof and not inflater.unused_data and
            not inflater.unconsumed_tail,
            f"{label} decoded raster stream or length is invalid.")
    previous = bytearray(stride)
    rgba = bytearray(width * height * 4)
    raw_offset = 0
    rgba_offset = 0
    for _ in range(height):
        filter_type = raw[raw_offset]
        require(filter_type <= 4, f"{label} uses an invalid PNG filter.")
        encoded = raw[raw_offset + 1:raw_offset + 1 + stride]
        decoded = bytearray(stride)
        for index, value in enumerate(encoded):
            left = decoded[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            predictor = (0, left, up, (left + up) // 2, paeth(left, up, upper_left))[filter_type]
            decoded[index] = (value + predictor) & 0xFF
        for column in range(width):
            pixel = decoded[column * channels:(column + 1) * channels]
            if color_type == 0:
                color = (pixel[0], pixel[0], pixel[0], 255)
            elif color_type == 2:
                color = (pixel[0], pixel[1], pixel[2], 255)
            elif color_type == 4:
                color = (pixel[0], pixel[0], pixel[0], pixel[1])
            else:
                color = tuple(pixel)
            require(color[3] == 255, f"{label} contains unsupported non-opaque pixels.")
            rgba[rgba_offset:rgba_offset + 4] = bytes(color)
            rgba_offset += 4
        previous = decoded
        raw_offset += stride + 1
    return width, height, bytes(rgba)


def validate_observed_text_targets(run_root: Path, collection_files: dict[str, dict], result: dict) -> dict[str, dict]:
    value, raw = read_json(run_root / "output", Path("acceptance-observations.json"), "raw acceptance observations")
    receipt = collection_files["acceptance-observations.json"]
    require(receipt["bytes"] == len(raw) and receipt["sha256"] == sha256_bytes(raw),
            "Raw acceptance observations differ from the collection receipt.")
    require(isinstance(value, dict), "Raw acceptance observations must be an object.")
    rows = value.get("text_raster_targets")
    require(isinstance(rows, list) and len(rows) == 2,
            "Raw acceptance observations require exactly two text raster targets.")
    targets: dict[str, dict] = {}
    for index, row_value in enumerate(rows):
        row = exact_keys(row_value, {"id", "image", "text_sha256", "control", "window", "screenshot_origin", "control_rect"},
                         f"text raster target {index}")
        sample_id = row["id"]
        require(sample_id in {"prefix-input", "full-details"} and sample_id not in targets,
                "Text raster target id is missing or duplicated.")
        image = safe_relative(row["image"], "text raster target image").as_posix()
        require(image in collection_files and image.endswith(".png"),
                "Text raster target image is not a receipt-covered PNG.")
        expected_controls = {
            "prefix-input": {"control_id": 1002, "text": "으로"},
            "full-details": {"control_id": 1001, "text": "전체 이름과 경로"},
        }
        control = exact_keys(row["control"], {"observation", "hwnd", "process_id", "control_id", "class_name", "text"},
                             "text raster target control")
        expected_control = expected_controls[sample_id]
        require(control["observation"] == "native-static-v1" and
                int_equals(control["control_id"], expected_control["control_id"]) and
                control["class_name"] == "Static" and control["text"] == expected_control["text"] and
                type(control["hwnd"]) is int and control["hwnd"] > 0 and
                int_equals(control["process_id"], result["actual"]["target"]["process_id"]),
                "Text raster target control identity is not the fixed native app-owned label.")
        expected_text_hash = sha256_bytes(control["text"].encode("utf-8"))
        require(row["text_sha256"] == expected_text_hash,
                "Text raster target digest does not match its exact observed control text.")
        origin = exact_keys(row["screenshot_origin"], {"x", "y"}, "text raster target screenshot_origin")
        checked_int(origin["x"], -32768, 32767, "text raster target screenshot_origin.x")
        checked_int(origin["y"], -32768, 32767, "text raster target screenshot_origin.y")
        rectangle = validate_rectangle(row["control_rect"], "text raster target control_rect")
        window = exact_keys(row["window"], {"hwnd", "process_id", "rect"}, "text raster target window")
        checked_int(window["hwnd"], 1, (1 << 63) - 1, "text raster target window.hwnd")
        checked_int(window["process_id"], 1, (1 << 31) - 1, "text raster target window.process_id")
        window_rect = validate_rectangle(window["rect"], "text raster target window.rect")
        require(window["process_id"] == result["actual"]["target"]["process_id"] and
                origin == {"x": window_rect["left"], "y": window_rect["top"]},
                "Text raster target window/origin is not bound to the launched application process.")
        require(window_rect["left"] <= rectangle["left"] < rectangle["right"] <= window_rect["right"] and
                window_rect["top"] <= rectangle["top"] < rectangle["bottom"] <= window_rect["bottom"],
                "Text raster target control lies outside its observed window.")
        targets[sample_id] = row
    return targets


def validate_text_scale_restoration(run_root: Path, input_hash: str, raw: dict,
                                    collection_files: dict[str, dict]) -> None:
    require("text-scale-restoration.json" in collection_files,
            "Text150 requires a collection-covered restoration record.")
    value, _ = read_json(run_root / "output", Path("text-scale-restoration.json"), "text scale restoration")
    record = exact_keys(
        value,
        {"schema_version", "run_id", "input_manifest_sha256", "status", "original", "restored", "snapshot", "activation_attempt"},
        "text scale restoration",
    )
    require(int_equals(record["schema_version"], 1) and record["run_id"] == run_root.name and
            record["input_manifest_sha256"] == input_hash and record["status"] == "verified",
            "Text scale restoration identity or status is invalid.")
    for name in ("original", "restored"):
        state = exact_keys(record[name], {"registry_value_present", "percent"}, f"text scale restoration {name}")
        require(type(state["registry_value_present"]) is bool,
                f"text scale restoration {name}.registry_value_present must be boolean.")
        if state["registry_value_present"]:
            checked_int(state["percent"], 100, 225, f"text scale restoration {name}.percent")
        else:
            require(state["percent"] is None,
                    f"text scale restoration absent {name} percent must be null.")
    require(record["restored"] == record["original"],
            "Text scale restored registry state differs from the recorded original.")
    raw_scale = nested(raw, "text_scale")
    require(isinstance(raw_scale, dict) and typed_equal(raw_scale.get("original"), record["original"]) and
            raw_scale.get("restoration") == "verified",
            "Raw text-scale record differs from the restoration record.")
    for name in ("snapshot", "activation_attempt"):
        row = exact_keys(record[name], {"file", "sha256"}, f"text scale restoration {name}")
        relative = safe_relative(row["file"], f"text scale restoration {name}.file").as_posix()
        checked_digest(row["sha256"], f"text scale restoration {name}.sha256")
        require(relative in collection_files and collection_files[relative]["sha256"] == row["sha256"],
                f"Text scale restoration {name} is not bound to collected bytes.")
        require(raw_scale.get(name) == row,
                f"Raw text-scale {name} differs from the restoration record.")


def validate_text_metrics(run_root: Path, input_hash: str, collection_files: dict[str, dict], result: dict) -> dict[str, dict]:
    require("text-raster-metrics.json" in collection_files,
            "Standard and text-scale runs require byte-backed text raster metrics.")
    value, _ = read_json(run_root / "output", Path("text-raster-metrics.json"), "text raster metrics")
    document = exact_keys(value, {"schema_version", "run_id", "input_manifest_sha256", "samples"}, "text raster metrics")
    require(int_equals(document["schema_version"], 1) and document["run_id"] == run_root.name,
            "text raster metric identity is invalid.")
    require(document["input_manifest_sha256"] == input_hash,
            "text raster metrics do not pin the input manifest bytes.")
    targets = validate_observed_text_targets(run_root, collection_files, result)
    samples = document["samples"]
    require(isinstance(samples, list) and len(samples) == 2, "Exactly two text raster samples are required.")
    result: dict[str, dict] = {}
    for index, value in enumerate(samples):
        sample = exact_keys(
            value,
            {"id", "text_sha256", "image", "observed_target", "crop", "raster_sha256", "ink_threshold_max_rgb", "ink_bounds", "ink_pixel_count"},
            f"text sample {index}",
        )
        require(sample["id"] in {"prefix-input", "full-details"} and sample["id"] not in result,
                "Text sample id is missing or duplicated.")
        checked_digest(sample["text_sha256"], "text sample text_sha256")
        target = targets[sample["id"]]
        require(sample["observed_target"] == target and sample["text_sha256"] == target["text_sha256"],
                "Text sample does not bind the raw observed control target and text.")
        image_relative = safe_relative(sample["image"], "text sample image")
        image_name = image_relative.as_posix()
        require(image_name == target["image"], "Text sample image differs from its raw observed target.")
        require(image_name in collection_files and image_name.endswith(".png"),
                "Text sample image is not a receipt-covered PNG.")
        image_data = read_bytes(run_root / "output", image_relative, MAX_ARTIFACT_BYTES, "text sample PNG")
        width, height, rgba = decode_png(image_data, image_name)
        target_window = target["window"]["rect"]
        require(width == target_window["width"] and height == target_window["height"],
                "Text sample PNG dimensions differ from its observed capture window.")
        crop = exact_keys(sample["crop"], {"x", "y", "width", "height"}, "text sample crop")
        x = checked_int(crop["x"], 0, width - 1, "text sample crop.x")
        y = checked_int(crop["y"], 0, height - 1, "text sample crop.y")
        crop_width = checked_int(crop["width"], 1, width, "text sample crop.width")
        crop_height = checked_int(crop["height"], 1, height, "text sample crop.height")
        rectangle = target["control_rect"]
        origin = target["screenshot_origin"]
        crop_left = origin["x"] + x
        crop_top = origin["y"] + y
        require(rectangle["left"] <= crop_left and rectangle["top"] <= crop_top and
                crop_left + crop_width <= rectangle["right"] and
                crop_top + crop_height <= rectangle["bottom"],
                "Text sample crop lies outside the observed native text control.")
        require(x + crop_width <= width and y + crop_height <= height, "Text sample crop exceeds the PNG.")
        threshold = checked_int(sample["ink_threshold_max_rgb"], 0, 254, "text sample ink_threshold_max_rgb")
        require(threshold == 120, "Text sample ink threshold must use the fixed value 120.")
        cropped_rgb = bytearray()
        ink_count = 0
        min_x = min_y = None
        max_x = max_y = None
        for row in range(crop_height):
            start = ((y + row) * width + x) * 4
            scan = rgba[start:start + crop_width * 4]
            for column in range(crop_width):
                pixel = scan[column * 4:(column + 1) * 4]
                cropped_rgb.extend(pixel[:3])
                if max(pixel[:3]) < threshold:
                    ink_count += 1
                    min_x = column if min_x is None else min(min_x, column)
                    max_x = column if max_x is None else max(max_x, column)
                    min_y = row if min_y is None else min(min_y, row)
                    max_y = row if max_y is None else max(max_y, row)
        checked_digest(sample["raster_sha256"], "text sample raster_sha256")
        require(sample["raster_sha256"] == sha256_bytes(bytes(cropped_rgb)),
                "Text sample raster digest differs from decoded PNG bytes.")
        require(ink_count > 0, "Text sample contains no threshold-qualified ink.")
        expected_bounds = {
            "x": min_x, "y": min_y,
            "width": max_x - min_x + 1,
            "height": max_y - min_y + 1,
        }
        ink_left = crop_left + expected_bounds["x"]
        ink_top = crop_top + expected_bounds["y"]
        require(rectangle["left"] <= ink_left and rectangle["top"] <= ink_top and
                ink_left + expected_bounds["width"] <= rectangle["right"] and
                ink_top + expected_bounds["height"] <= rectangle["bottom"],
                "Text sample ink lies outside the observed app-owned text control.")
        bounds = exact_keys(sample["ink_bounds"], {"x", "y", "width", "height"}, "text sample ink_bounds")
        for name, expected in expected_bounds.items():
            checked_int(bounds[name], 0 if name in {"x", "y"} else 1, max(width, height), f"ink_bounds.{name}")
            require(bounds[name] == expected, "Text sample ink bounds differ from decoded PNG bytes.")
        require(type(sample["ink_pixel_count"]) is int and sample["ink_pixel_count"] == ink_count,
                "Text sample ink pixel count differs from decoded PNG bytes.")
        result[sample["id"]] = sample
    require(set(result) == {"prefix-input", "full-details"}, "Required text samples are missing.")
    return result


def validate_direct_reference(root: Path, current: dict, expected_source_sha: str) -> None:
    reference = current["manifest"]["full_context_reference"]
    target_id = reference["run_id"]
    require(SAFE_LEAF.fullmatch(target_id) is not None, "Reference target is unsafe.")
    target = validate_run(root, target_id, expected_source_sha, allow_reference=False)
    require(target["manifest"]["request"]["mode"] == "full-context",
            "Referenced run is not a full-context run.")
    require(target["input_hash"] == reference["input_manifest_sha256"],
            "Referenced input manifest digest mismatch.")
    require(target["result_hash"] == reference["result_sha256"],
            "Referenced normalized result digest mismatch.")
    require(target["manifest"]["source_sha"] == current["manifest"]["source_sha"],
            "Referenced run uses another source SHA.")
    require(target["manifest"]["artifacts"]["application"]["sha256"] ==
            current["manifest"]["artifacts"]["application"]["sha256"],
            "Referenced run uses another executable.")
    require(target["result"]["status"] == "review_required" and
            target["result"]["assertions"]["overall"] == "passed",
            "Referenced full-context run did not pass its machine assertions.")
    require(all(target["result"]["assertions"]["semantics"][name] is True
                for name in FULL_CONTEXT_SEMANTICS),
            "Referenced full-context semantic scope is incomplete.")


def validate_run(root: Path, run_id: str, expected_source_sha: str, *, allow_reference: bool = True) -> dict:
    require(SAFE_LEAF.fullmatch(run_id) is not None, "Run id is unsafe.")
    run_root = root / run_id
    try:
        info = run_root.lstat()
    except FileNotFoundError as error:
        raise EvidenceError(f"Run directory is missing: {run_id}") from error
    require(stat.S_ISDIR(info.st_mode) and not run_root.is_symlink(), "Run directory must not be a symlink.")
    manifest, input_bytes = validate_input_manifest(run_root, expected_source_sha)
    input_hash = sha256_bytes(input_bytes)
    cleanup, cleanup_bytes = validate_cleanup(run_root, input_hash)
    collection, collection_bytes, collection_files = validate_collection(run_root, input_hash)
    preflight, postlaunch = validate_platform_preflight(run_root, manifest, input_hash)
    result, result_bytes, raw = validate_run_result(
        run_root, manifest, input_hash, collection_bytes, cleanup_bytes, preflight, postlaunch, collection_files
    )
    mode = manifest["request"]["mode"]
    text_metrics = None
    if mode in {"standard", "text-scale"}:
        text_metrics = validate_text_metrics(run_root, input_hash, collection_files, result)
        if mode == "text-scale":
            validate_text_scale_restoration(run_root, input_hash, raw, collection_files)
    else:
        require("text-raster-metrics.json" not in collection_files,
                "Text raster metrics are allowed only for standard and text-scale runs.")
    validate_raw_environment(nested(raw, "assertions", "scenario"), manifest, result)
    raw_semantics = validate_raw_semantics(result, raw, mode, cleanup, text_metrics)
    current = {
        "manifest": manifest,
        "input_hash": input_hash,
        "cleanup": cleanup,
        "collection": collection,
        "result": result,
        "result_hash": sha256_bytes(result_bytes),
        "text_metrics": text_metrics,
        "raw_semantics": raw_semantics,
    }
    if mode == "tooltip":
        require(allow_reference, "A referenced full-context run cannot contain another reference.")
        validate_direct_reference(root, current, expected_source_sha)
    return current


def validate_text_pair(runs: list[dict]) -> None:
    by_mode = {run["manifest"]["request"]["mode"]: run for run in runs}
    baseline = by_mode["standard"]["text_metrics"]
    enlarged = by_mode["text-scale"]["text_metrics"]
    for sample_id in ("prefix-input", "full-details"):
        before = baseline[sample_id]
        after = enlarged[sample_id]
        require(before["text_sha256"] == after["text_sha256"],
                f"Text sample changed between text100 and text150: {sample_id}")
        before_height = checked_number(before["ink_bounds"]["height"], 1, 10000, "baseline ink height")
        after_height = checked_number(after["ink_bounds"]["height"], 1, 10000, "enlarged ink height")
        before_width = checked_number(before["ink_bounds"]["width"], 1, 10000, "baseline ink width")
        after_width = checked_number(after["ink_bounds"]["width"], 1, 10000, "enlarged ink width")
        require(after_height >= before_height * 1.25 and after_width >= before_width * 1.25,
                f"Text150 did not visibly enlarge both dimensions of the same rasterized glyphs: {sample_id}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-root", required=True, type=Path)
    parser.add_argument("--expected-source-sha", required=True)
    parser.add_argument("--run", action="append", required=True, dest="runs")
    parser.add_argument("--require-complete-set", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    require(SHA1.fullmatch(args.expected_source_sha) is not None,
            "--expected-source-sha must be a full lowercase Git SHA.")
    root = checked_root(args.result_root)
    require(len(args.runs) == len(set(args.runs)), "Run ids must be unique.")
    runs = [validate_run(root, run_id, args.expected_source_sha) for run_id in args.runs]
    modes = [run["manifest"]["request"]["mode"] for run in runs]
    require(len(modes) == len(set(modes)), "Validated runs contain duplicate modes.")
    if {"standard", "text-scale"} <= set(modes):
        validate_text_pair(runs)
    if args.require_complete_set:
        require(set(modes) == RUN_MODES, "Complete validation requires exactly the four representative modes.")
        require(all(run["manifest"]["run_id"] == FIXED_RUN_IDS[run["manifest"]["request"]["mode"]]
                    for run in runs), "Complete validation run ids do not match the fixed four-cell leaves.")
        require(len({run["manifest"]["source_tree"] for run in runs}) == 1,
                "Complete validation runs use different source trees.")
        require(len({run["manifest"]["artifacts"]["application"]["sha256"] for run in runs}) == 1,
                "Complete validation runs use different executables.")
        require(len({run["manifest"]["artifacts"]["lockfile"]["sha256"] for run in runs}) == 1,
                "Complete validation runs use different Cargo.lock bytes.")
        validate_text_pair(runs)
    print(json.dumps({
        "schema_version": 1,
        "status": "passed",
        "source_sha": args.expected_source_sha,
        "runs": [
            {
                "run_id": run["manifest"]["run_id"],
                "mode": run["manifest"]["request"]["mode"],
                "input_manifest_sha256": run["input_hash"],
                "result_sha256": run["result_hash"],
                "status": run["result"]["status"],
            }
            for run in runs
        ],
        "visual_review": "required",
        "human_acceptance": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (EvidenceError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
