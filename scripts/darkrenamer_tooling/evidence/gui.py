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
import sys

from darkrenamer_tooling.evidence.errors import EvidenceError
from darkrenamer_tooling.evidence.png import DecodedPixelBudget, decode_png


SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_LEAF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_ARTIFACT_BYTES = 128 * 1024 * 1024
MAX_COLLECTION_BYTES = 512 * 1024 * 1024
REFERENCE_SCOPE = ["full-context-semantics-v1"]
RUN_MODES = {"full-context", "standard", "text-scale", "tooltip"}
PAIR_MODE = "appearance-pair"
PAIR_RUN_ID = "appearance-pair-light-dark-light"
PAIR_CONFIGURATIONS = {
    "appearance-pair-base-1920x1080-96-text100": ("light", 1920, 1080, 96, 100, False),
    "appearance-pair-fractional-1920x1080-144-text100": ("light", 1920, 1080, 144, 100, False),
    "appearance-pair-high-1920x1080-192-text100": ("light", 1920, 1080, 192, 100, False),
    "appearance-pair-text150-1920x1080-96-text150": ("light", 1920, 1080, 96, 150, False),
    "appearance-pair-forced-colors-1920x1080-96-text100": ("system", 1920, 1080, 96, 100, True),
}
PAIR_SCENES = ("empty", "unchanged", "overflow", "changed", "collision", "warning",
               "selected-active", "selected-inactive")
PAIR_PHASES = ("light-before", "dark", "light-after")
PAIR_SCROLL_AXES = ("horizontal", "vertical")
PAIR_SCROLL_STAGES = ("held", "moving", "released")
PAIR_BUTTON_STATES = ("normal", "disabled", "hover", "pressed", "keyboard-focus")
PAIR_MODAL_SURFACES = {"native-menu": "native-menu", "advanced": "advanced-appearance",
                       "input-prompt": "input-prompt"}
PAIR_SCENE_ROWS = {"empty": 0, "unchanged": 1, **{scene: 60 for scene in PAIR_SCENES[2:]}}


def pair_capture_specs(high_contrast: bool = False) -> dict[str, str]:
    return {
        **({f"appearance-system-{phase}.png": "main-workbench"
            for phase in ("before", "forced-colors", "after")} if high_contrast else {}),
        **{f"appearance-{scene}-{phase}.png": "main-workbench"
           for scene in PAIR_SCENES for phase in PAIR_PHASES},
        **{f"appearance-button-{state}-{phase}.png": "main-workbench"
           for state in PAIR_BUTTON_STATES for phase in PAIR_PHASES},
        **{f"appearance-scroll-{axis}-{stage}-{phase}.png": "main-workbench"
           for axis in PAIR_SCROLL_AXES for stage in PAIR_SCROLL_STAGES for phase in PAIR_PHASES},
        **{f"appearance-{kind}-{phase}.png": surface
           for kind, surface in PAIR_MODAL_SURFACES.items() for phase in PAIR_PHASES},
    }

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
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
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
    fields = {"mode", "appearance", "desktop", "text_scale_percent"}
    if isinstance(value, dict) and value.get("mode") == PAIR_MODE and "high_contrast" in value:
        fields.add("high_contrast")
    request = exact_keys(value, fields, "request")
    require(request["mode"] in RUN_MODES | {PAIR_MODE}, "request.mode is invalid.")
    require(request["appearance"] in ({"light", "dark", "system"} if request["mode"] == PAIR_MODE else {"light", "dark"}), "request.appearance is invalid.")
    desktop = exact_keys(request["desktop"], {"width", "height", "dpi"}, "request.desktop")
    checked_int(desktop["width"], 800, 8192, "request.desktop.width")
    checked_int(desktop["height"], 600, 4320, "request.desktop.height")
    checked_int(desktop["dpi"], 96, 480, "request.desktop.dpi")
    text = checked_int(request["text_scale_percent"], 100, 225, "request.text_scale_percent")
    if request["mode"] == PAIR_MODE:
        high_contrast = request.get("high_contrast", False)
        require(type(high_contrast) is bool and
                request["appearance"] == ("system" if high_contrast else "light") and
                text in {100, 150} and (not high_contrast or text == 100) and
                800 <= desktop["width"] <= 1920 and 600 <= desktop["height"] <= 1080 and
                desktop["dpi"] in {96, 120, 144, 192},
                "Appearance pair request is outside its bounded display configurations.")
    else:
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
    if isinstance(value, dict) and isinstance(value.get("request"), dict) and value["request"].get("mode") == PAIR_MODE:
        required.add("acceptance_profile_id")
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
    if request["mode"] == PAIR_MODE:
        require(manifest["acceptance_profile_id"] == "vm-automated-v1-win11-ntfs",
                "Appearance pair acceptance profile differs from its declared v1 contract.")
    validate_host_platform(manifest["host_preflight"], "input manifest host_preflight")
    validate_guest_platform(manifest["guest_preflight"], "input manifest guest_preflight")
    command = manifest["command"]
    require(isinstance(command, list) and 1 <= len(command) <= 128 and
            all(isinstance(item, str) and 0 < len(item) <= 4096 for item in command),
            "input manifest command must be a bounded argv string array.")
    if request["mode"] == PAIR_MODE:
        run_id = manifest["run_id"]
        desktop = request["desktop"]
        requested = (request["appearance"], desktop["width"], desktop["height"], desktop["dpi"],
                     request["text_scale_percent"], request.get("high_contrast", False))
        require((run_id == PAIR_RUN_ID and request["text_scale_percent"] == 100 and
                 request.get("high_contrast", False) is False or
                 run_id in PAIR_CONFIGURATIONS and requested == PAIR_CONFIGURATIONS[run_id]) and
                command[0:3] == ["python3", "-I", "scripts/run-gui-regression.py"] and
                command.count("--diagnostic") == 1 and command.count(PAIR_MODE) == 1,
                "Appearance pair manifest identity or command is invalid.")
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
        "acceptance-result.json", "acceptance-observations.json", "controller.stdout.txt",
        "controller.stderr.txt", "cleanup.json", "platform-preflight.json", "platform-postlaunch.json",
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


def menu_element_valid(value: object, expected_name: str, *, contains: bool = False) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "automation_id", "name", "control_type", "enabled", "keyboard_focusable",
        "offscreen", "native_handle", "bounds",
    }:
        return False
    name = value.get("name")
    if not isinstance(value.get("automation_id"), str) or not isinstance(name, str) or \
            (expected_name not in name if contains else name != expected_name) or \
            value.get("control_type") != "ControlType.MenuItem" or \
            value.get("enabled") is not True or type(value.get("keyboard_focusable")) is not bool or \
            value.get("offscreen") is not False or type(value.get("native_handle")) is not int:
        return False
    bounds = value.get("bounds")
    return isinstance(bounds, dict) and set(bounds) == {"x", "y", "width", "height"} and \
        all(type(bounds.get(field)) in (int, float) and math.isfinite(bounds[field])
            for field in ("x", "y", "width", "height")) and \
        bounds["width"] > 0 and bounds["height"] > 0


def physical_target_valid(value: object, bounds: object) -> bool:
    if not isinstance(value, dict) or set(value) != {"x", "y", "hit_window", "root_window"} or \
            not isinstance(bounds, dict) or \
            not all(type(value.get(field)) is int for field in ("x", "y", "hit_window", "root_window")):
        return False
    return value["hit_window"] != 0 and value["root_window"] != 0 and \
        bounds["x"] <= value["x"] < bounds["x"] + bounds["width"] and \
        bounds["y"] <= value["y"] < bounds["y"] + bounds["height"]


def valid_apply_entry(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {"input", "menu_entry"}:
        return False
    if value["input"] == "visible-command-rail":
        return value["menu_entry"] is None
    if value["input"] != "physical-mouse-file-menu-public-apply":
        return False
    menu = value["menu_entry"]
    if not isinstance(menu, dict) or set(menu) != {"file", "file_target", "apply", "apply_target"} or \
            not menu_element_valid(menu["file"], "파일(F)") or \
            not menu_element_valid(menu["apply"], "변경 사항 적용", contains=True):
        return False
    return physical_target_valid(menu["file_target"], menu["file"]["bounds"]) and \
        physical_target_valid(menu["apply_target"], menu["apply"]["bounds"])


def valid_tooltip_apply_entry(value: object) -> bool:
    return isinstance(value, dict) and set(value) == {"input", "menu_entry"} and \
        value["input"] == "keyboard-ctrl-s-with-visible-listview-infotip" and value["menu_entry"] is None


def reachability_valid(value: object) -> bool:
    return isinstance(value, dict) and value.get("status") == "reachable" and \
        value.get("inside_work_area") is True and \
        type(nested(value, "physical_mouse_target", "hit_window")) is int and \
        nested(value, "physical_mouse_target", "hit_window") != 0


def control_visible(value: object, work_area: dict) -> bool:
    if not isinstance(value, dict) or value.get("enabled") is not True or value.get("offscreen") is not False:
        return False
    bounds = value.get("bounds")
    return isinstance(bounds, dict) and all(
        type(bounds.get(name)) in (int, float) and math.isfinite(bounds[name])
        for name in ("x", "y", "width", "height")
    ) and \
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
            "public_apply_entered": valid_tooltip_apply_entry(apply_entry) and
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
    observation_binding = exact_keys(raw_value.get("observations"), {"file", "sha256"},
                                     "raw observer observations binding")
    require(observation_binding["file"] == "acceptance-observations.json" and
            observation_binding["sha256"] == sha256_bytes(observation_bytes),
            "Protected observer result does not bind the raw observations file.")
    require(typed_equal(raw_value.get("acceptance_observations"), observations),
            "Raw observations differ from the observations embedded in the protected result.")
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
    decode_budget = DecodedPixelBudget()
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
        target_window = target["window"]["rect"]
        width, height, rgba = decode_png(
            image_data,
            image_name,
            expected_dimensions=(target_window["width"], target_window["height"]),
            budget=decode_budget,
        )
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


def pair_region_luma(rgba: bytes, image_width: int, image_height: int,
                     rect: dict, point: str) -> float:
    left, top = int(rect["left"]), int(rect["top"])
    right, bottom = int(rect["right"]), int(rect["bottom"])
    require(0 <= left < right <= image_width and 0 <= top < bottom <= image_height,
            f"Appearance {point} region lies outside its original PNG.")
    x = min(right - 3, max(left + 2, (left + right) // 2))
    y = min(bottom - 3, max(top + 2, (top + bottom) // 2))
    samples = []
    for row in range(y - 2, y + 3):
        for column in range(x - 2, x + 3):
            offset = (row * image_width + column) * 4
            pixel = rgba[offset:offset + 4]
            require(pixel[3] == 255, "Appearance raster region contains transparent pixels.")
            samples.append((pixel[0] * 2126 + pixel[1] * 7152 + pixel[2] * 722) / 10000)
    return sum(samples) / len(samples)


def pair_count_near_color(rgba: bytes, image_width: int, image_height: int,
                          rect: dict, rgb: tuple[int, int, int], tolerance: int = 12) -> int:
    left, top = max(0, int(rect["left"])), max(0, int(rect["top"]))
    right, bottom = min(image_width, int(rect["right"])), min(image_height, int(rect["bottom"]))
    require(right - left >= 8 and bottom - top >= 8,
            "Appearance semantic raster region is clipped or missing.")
    count = 0
    for row in range(top + 2, bottom - 2):
        for column in range(left + 2, right - 2):
            offset = (row * image_width + column) * 4
            pixel = rgba[offset:offset + 4]
            if pixel[3] == 255 and all(abs(pixel[i] - rgb[i]) <= tolerance for i in range(3)):
                count += 1
    return count


def pair_pixel_delta(left: bytes, right: bytes, width: int, height: int, rect: dict) -> int:
    x0, y0 = max(0, int(rect["left"])), max(0, int(rect["top"]))
    x1, y1 = min(width, int(rect["right"])), min(height, int(rect["bottom"]))
    require(x1 - x0 >= 8 and y1 - y0 >= 8, "Appearance interaction raster region is missing.")
    return sum(1 for y in range(y0, y1) for x in range(x0, x1)
               if max(abs(left[(y * width + x) * 4 + channel] -
                          right[(y * width + x) * 4 + channel]) for channel in range(3)) >= 10)


def pair_flat_region(rgba: bytes, width: int, height: int, rect: dict,
                     colors: tuple[tuple[int, int, int], ...], label: str) -> int:
    x0, y0, x1, y1 = (int(rect[key]) for key in ("left", "top", "right", "bottom"))
    require(0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height,
            f"Appearance {label} flat region lies outside its original PNG.")
    counts = [0] * len(colors)
    for y in range(y0, y1):
        for x in range(x0, x1):
            offset = (y * width + x) * 4
            pixel = rgba[offset:offset + 4]
            require(pixel[3] == 255, f"Appearance {label} contains transparent pixels.")
            for index, color in enumerate(colors):
                if all(abs(pixel[channel] - color[channel]) <= 2 for channel in range(3)):
                    counts[index] += 1
    matched = max(counts)
    require(matched * 100 >= (x1 - x0) * (y1 - y0) * 95,
            f"Appearance {label} palette raster violation.")
    return matched


def pair_button_outline(rgba: bytes, width: int, height: int, rect: dict, outline: tuple,
                        fill: tuple, *, shares_top: bool, default: bool = False) -> None:
    x0, y0, x1, y1 = (int(rect[key]) for key in ("left", "top", "right", "bottom"))
    for inset in range(2 if default else 1):
        edges = [(x0 + inset, y0 + inset, x0 + inset + 1, y1 - inset),
                 (x1 - inset - 1, y0 + inset, x1 - inset, y1 - inset),
                 (x0 + inset, y1 - inset - 1, x1 - inset, y1 - inset)]
        if not shares_top:
            edges.append((x0 + inset, y0 + inset, x1 - inset, y0 + inset + 1))
        for left, top, right, bottom in edges:
            pair_flat_region(rgba, width, height, dict(left=left, top=top, right=right, bottom=bottom),
                             (outline,), "button physical outline")
    inset = 2 if default else 1
    # A second outline line is allowed only for the native default cue.
    for left, top, right, bottom in ((x0 + inset + 1, y0 + inset, x1 - inset - 1, y0 + inset + 1),
                                     (x0 + inset + 1, y1 - inset - 1, x1 - inset - 1, y1 - inset),
                                     (x0 + inset, y0 + inset + 1, x0 + inset + 1, y1 - inset - 1),
                                     (x1 - inset - 1, y0 + inset + 1, x1 - inset, y1 - inset - 1)):
        pair_flat_region(rgba, width, height, dict(left=left, top=top, right=right, bottom=bottom),
                         (fill,), "button outline thickness")
    if shares_top:
        pair_flat_region(rgba, width, height, dict(left=x0 + 1, top=y0, right=x1 - 1, bottom=y0 + 1),
                         (fill,), "button shared top seam")


def pair_button_ink(rgba: bytes, width: int, height: int, rect: dict, rgb: tuple) -> set[tuple[int, int]]:
    x0, y0, x1, y1 = (int(rect[key]) for key in ("left", "top", "right", "bottom"))
    require(0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height, "Appearance button ink rectangle is invalid.")
    ink = {(x, y) for y in range(y0 + 2, y1 - 2) for x in range(x0 + 2, x1 - 2)
           if all(abs(rgba[(y * width + x) * 4 + channel] - rgb[channel]) <= 2 for channel in range(3))}
    require(len(ink) >= 8, "Appearance button text has no readable palette-qualified ink.")
    require(all(x0 + 2 < x < x1 - 3 and y0 + 2 < y < y1 - 3 for x, y in ink),
            "Appearance button text touches a clipping edge.")
    return ink


def validate_pair_rendering_environment(value: object, actual: dict) -> dict:
    row = exact_keys(value, {"hwnd", "process_id", "hwnd_dpi", "awareness", "client", "client_query", "system_font_recipe"},
                     "appearance target rendering environment")
    require(int_equals(row["hwnd"], actual["target"]["hwnd"]) and
            int_equals(row["process_id"], actual["target"]["process_id"]) and
            int_equals(row["hwnd_dpi"], actual["hwnd_dpi"]),
            "Appearance rendering environment target identity differs.")
    awareness = exact_keys(row["awareness"], {"query", "context", "value", "per_monitor_v2"},
                           "appearance target DPI awareness")
    require(awareness["query"] == "GetWindowDpiAwarenessContext+GetAwarenessFromDpiAwarenessContext+AreDpiAwarenessContextsEqual" and
            type(awareness["context"]) is int and awareness["context"] != 0 and
            int_equals(awareness["value"], 2) and awareness["per_monitor_v2"] is True,
            "Appearance target DPI awareness is not observed Per-Monitor-V2.")
    client = validate_rectangle(row["client"], "appearance client bounds")
    window = actual["target"]["window_rect"]
    require(row["client_query"] == "GetClientRect+ClientToScreen" and
            window["left"] <= client["left"] < client["right"] <= window["right"] and
            window["top"] <= client["top"] < client["bottom"] <= window["bottom"],
            "Appearance observed client lies outside its bound window.")
    recipe = exact_keys(row["system_font_recipe"], {"query", "dpi", "fonts", "scope"},
                        "appearance system font recipe")
    require(recipe["query"] == "SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS)" and
            int_equals(recipe["dpi"], actual["hwnd_dpi"]) and
            recipe["scope"] == "system LOGFONT recipe; not a dereferenced application HFONT",
            "Appearance system font recipe query or DPI differs.")
    fonts = exact_keys(recipe["fonts"], {"MessageFont", "StatusFont"}, "appearance system font roles")
    for role, font in fonts.items():
        font = exact_keys(font, {"family", "height", "width", "weight", "charset", "quality", "italic", "underline", "strikeout"},
                          f"appearance {role} descriptor")
        require(isinstance(font["family"], str) and 1 <= len(font["family"]) <= 31 and
                type(font["height"]) is int and 0 < abs(font["height"]) <= 512 and
                type(font["width"]) is int and abs(font["width"]) <= 512 and
                type(font["weight"]) is int and 0 <= font["weight"] <= 1000 and
                all(type(font[key]) is int and 0 <= font[key] <= 255
                    for key in ("charset", "quality", "italic", "underline", "strikeout")),
                "Appearance system font descriptor is invalid.")
    return row


def validate_pair_scenes(run_root: Path, raw: dict, collection_files: dict[str, dict],
                         actual: dict, high_contrast: bool = False) -> dict:
    scenario = nested(raw, "assertions", "scenario")
    require(isinstance(scenario, dict) and scenario.get("appearance") == "light-dark-light" and
            scenario.get("process_id") == actual["target"]["process_id"] and
            scenario.get("normal_exit_code") == 0 and
            nested(scenario, "fixture", "disk_unchanged") is True and
            nested(scenario, "fixture", "journal_residue_count") == 0,
            "Appearance scenario identity, safe fixture, or normal exit is missing.")
    preference = nested(scenario, "fixture", "column_preferences")
    require(isinstance(preference, dict) and preference.get("source") == "isolated-persisted-user-settings" and
            int_equals(preference.get("format_version"), 1) and preference.get("primary_width_dip") == [900, 900, 260] and
            isinstance(preference.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", preference["sha256"]),
            "Appearance persisted column fixture is missing.")
    scenes = scenario.get("scenes")
    require(isinstance(scenes, dict) and set(scenes) == set(PAIR_SCENES),
            "Appearance pair scene set is incomplete.")
    expected_captures = pair_capture_specs(high_contrast)
    require(isinstance(raw.get("screenshots"), list) and len(raw["screenshots"]) == len(expected_captures),
            f"Appearance pair requires exactly {len(expected_captures)} original captures.")
    captures = {row.get("file"): row for row in raw["screenshots"] if isinstance(row, dict)}
    require(set(captures) == set(expected_captures), "Appearance pair captures are duplicated or invalid.")
    require({name for name in collection_files if name.endswith(".png")} == set(expected_captures),
            "Appearance pair collected PNG inventory differs from its captures.")
    rendering = validate_pair_rendering_environment(nested(scenario, "environment", "target_rendering"), actual)
    installed = exact_keys(nested(scenario, "environment", "installed_fonts"),
                           {"query", "count", "family_names_sha256", "encoding", "scope"}, "appearance installed font environment")
    require(installed["query"] == "System.Drawing.Text.InstalledFontCollection" and
            installed["encoding"] == "UTF-8 ordinal sorted names joined by LF" and
            installed["scope"] == "installed family environment; glyph fallback is observed in original rasters" and
            checked_int(installed["count"], 1, 4096, "appearance installed family count") and
            checked_digest(installed["family_names_sha256"], "appearance installed font family digest"),
            "Appearance installed font environment is missing.")
    diagnostics = {}
    for scene in PAIR_SCENES:
        steps = scenes[scene]
        require(isinstance(steps, list) and len(steps) == 3 and
                [step.get("phase") for step in steps if isinstance(step, dict)] == list(PAIR_PHASES),
                f"Appearance {scene} Light-Dark-Light phases are incomplete.")
        stable = None
        measurements = []
        endpoint_rasters = {}
        for step in steps:
            phase = step["phase"]
            appearance = "dark" if phase == "dark" else "light"
            require(step.get("appearance") == appearance, f"Appearance {scene} phase theme differs.")
            state = step.get("state")
            require(isinstance(state, dict) and state.get("row_count") == PAIR_SCENE_ROWS[scene] and
                    state.get("apply_enabled") is (scene in {"changed", "warning"}) and
                    state.get("focus_automation_id") == ("32773" if scene == "selected-inactive" else "1000"),
                    f"Appearance {scene} data, Apply, or settled focus differs.")
            observed_rendering = validate_pair_rendering_environment(state.get("target_rendering"), actual)
            require(typed_equal(observed_rendering, rendering),
                    "Appearance client, awareness, or font recipe changed with theme.")
            focus = state.get("native_focus")
            require(isinstance(focus, list) and len(focus) == 3 and
                    all(type(value) is int for value in focus) and focus[0] > 0 and
                    focus[1] == 0 and str(focus[2]) == state["focus_automation_id"] and
                    (scene == "selected-inactive" or focus[0] == state.get("list", {}).get("native_handle")),
                    f"Appearance {scene} native focus differs from the keyboard target.")
            selected = state.get("selection")
            require(isinstance(selected, dict) and type(selected.get("count")) is int and
                    selected["count"] in (0, 1) and
                    ((selected["count"] == 0 and selected.get("name") is None) or
                     (selected["count"] == 1 and isinstance(selected.get("name"), str) and selected["name"])),
                    f"Appearance {scene} native selection observation is invalid.")
            if scene in {"changed", "collision", "warning", "selected-active", "selected-inactive"}:
                require(selected["count"] == 1, f"Appearance {scene} selected row was lost.")
            selected_cell = state.get("selected_row_cell")
            if scene in {"selected-active", "selected-inactive"}:
                require(isinstance(selected_cell, dict) and selected_cell.get("offscreen") is False and
                        isinstance(selected_cell.get("bounds"), dict),
                        f"Appearance {scene} selected cell is missing.")
            else:
                require(selected_cell is None, f"Appearance {scene} unexpectedly claims a selected cell.")
            if scene in {"collision", "warning"}:
                expected_status = "대상 경로 충돌" if scene == "collision" else "이름 본체가 비어 있는 항목"
                require(expected_status in state.get("status", ""),
                        f"Appearance {scene} semantic warning is missing.")
            proposed = state.get("proposed_cell")
            if scene in {"changed", "collision", "warning"}:
                require(isinstance(proposed, dict) and proposed.get("name") == state.get("proposed_name") and
                        proposed.get("offscreen") is False and
                        isinstance(proposed.get("bounds"), dict) and
                        proposed["bounds"].get("width", 0) >= 20 and
                        selected["name"] != state["current_names"][0],
                        f"Appearance {scene} proposed-name observation is missing or selected.")
                if scene == "collision":
                    require(state["proposed_name"] == "paired-collision.txt", "Appearance collision proposal differs.")
                elif scene == "warning":
                    require(state["proposed_name"] == ".txt", "Appearance invalid proposal differs.")
                else:
                    require(state["proposed_name"] == "paired-change-00.txt", "Appearance changed proposal differs.")
            else:
                require(proposed is None and state.get("proposed_name") is None,
                        f"Appearance {scene} unexpectedly claims a proposed cell.")
            menu = state.get("appearance_menu")
            require(isinstance(menu, dict) and menu.get("hwnd") == actual["target"]["hwnd"] and
                    menu.get("pid") == actual["target"]["process_id"] and
                    menu.get("menu_checked") == [
                        {"command_id": 0x9010, "checked": False},
                        {"command_id": 0x9011, "checked": appearance == "light"},
                        {"command_id": 0x9012, "checked": appearance == "dark"},
                    ], f"Appearance {scene} menu did not confirm the observed theme.")
            require(isinstance(state.get("current_names"), list) and len(state["current_names"]) == state["row_count"] and
                    all(isinstance(name, str) and name for name in state["current_names"]),
                    f"Appearance {scene} row names are incomplete.")
            require(state.get("column_preference_sha256") == preference["sha256"],
                    "Appearance column preference changed.")
            overlay = state.get("overlay")
            require(isinstance(overlay, dict) and set(overlay) ==
                    {"visible_tooltip_count", "neutral_cursor", "dismissed_tooltip_count"} and
                    int_equals(overlay.get("visible_tooltip_count"), 0) and
                    overlay.get("neutral_cursor") is True and
                    type(overlay.get("dismissed_tooltip_count")) is int and
                    0 <= overlay["dismissed_tooltip_count"] <= 3,
                    "Appearance capture has an unsettled or visible tooltip.")
            dpi = actual["hwnd_dpi"]
            expected_widths = [(width * dpi + 48) // 96 for width in preference["primary_width_dip"]]
            require(state.get("columns") == expected_widths,
                    "Appearance column widths differ from persisted settings.")
            proposal_viewport = state.get("proposal_viewport")
            if scene in {"changed", "collision", "warning"}:
                scroll = state.get("horizontal_scroll")
                require(isinstance(scroll, list) and len(scroll) == 5 and
                        all(type(value) is int for value in scroll) and scroll[2] > 0 and
                        scroll[1] - scroll[0] - scroll[2] + 1 > 0,
                        "Appearance proposal lacks a native horizontal viewport.")
                requested = scroll[0] + ((scroll[1] - scroll[0] - scroll[2] + 1) * 45 + 50) // 100
                require(typed_equal(proposal_viewport, {
                    "query": "LVM_SCROLL horizontal scalar pixels after focus", "percent": 45,
                    "requested": requested, "observed": requested,
                }) and scroll[3] == scroll[4] == requested,
                        "Appearance proposal viewport differs from exact native pixel request.")
            else:
                require(proposal_viewport is None, "Appearance non-proposal scene changed the proposal viewport.")
            invariant = {key: state.get(key) for key in (
                "row_count", "current_names", "columns", "horizontal_scroll", "vertical_scroll",
                "horizontal_scrollbar_bounds", "vertical_scrollbar_bounds", "native_list", "native_header",
                "apply_enabled", "status", "selection", "selected_row_cell", "proposed_name", "proposed_cell", "current_name_cell",
                "focus_automation_id", "native_focus", "focused_uia", "list_physical_target", "list", "window", "target_rendering", "proposal_viewport")}
            physical = state.get("list_physical_target")
            require(isinstance(physical, dict) and type(physical.get("hit_window")) is int and
                    physical["hit_window"] > 0 and physical.get("root_window") == actual["target"]["hwnd"],
                    f"Appearance {scene} list was obscured during capture.")
            if stable is None:
                stable = invariant
            else:
                require(typed_equal(invariant, stable),
                        f"Appearance {scene} data, geometry, selection, focus, or scroll state changed with theme.")
            if scene == "overflow":
                for axis in ("horizontal_scroll", "vertical_scroll"):
                    scroll = state.get(axis)
                    require(isinstance(scroll, list) and len(scroll) == 5 and
                            all(type(value) is int for value in scroll) and
                            scroll[1] - scroll[0] + 1 > scroll[2],
                            f"Appearance overflow lacks a native {axis} range.")
                for axis in ("horizontal_scrollbar_bounds", "vertical_scrollbar_bounds"):
                    bounds = state.get(axis)
                    require(isinstance(bounds, list) and len(bounds) == 7 and
                            all(type(value) is int for value in bounds) and
                            bounds[0] < bounds[2] and bounds[1] < bounds[3] and
                            bounds[6] & 0x8000 == 0,
                            f"Appearance overflow lacks a visible native {axis} rectangle.")
            capture = step.get("capture")
            name = f"appearance-{scene}-{phase}.png"
            require(isinstance(capture, dict) and capture.get("file") == name and
                    captures[name].get("sha256") == capture.get("sha256") == collection_files[name]["sha256"] and
                    captures[name].get("appearance") == appearance and
                    captures[name].get("surface") == expected_captures[name],
                    f"Appearance {scene} {phase} capture binding differs.")
            png = read_bytes(run_root / "output", Path(name), MAX_ARTIFACT_BYTES, "appearance PNG")
            width, height, rgba = decode_png(png, name)
            require(width == capture.get("width") == captures[name].get("width") and
                    height == capture.get("height") == captures[name].get("height"),
                    f"Appearance {scene} PNG dimensions differ from observation.")
            if phase != "dark":
                endpoint_rasters[phase] = (width, height, rgba)
            observed_window = state.get("window", {})
            window = observed_window.get("rect", {}) if isinstance(observed_window, dict) else {}
            require(window.get("width") == width and window.get("height") == height,
                    f"Appearance {scene} PNG differs from its captured window bounds.")
            require(observed_window.get("hwnd") == actual["target"]["hwnd"] and
                    observed_window.get("process_id") == actual["target"]["process_id"] and
                    observed_window.get("hwnd_dpi") == actual["hwnd_dpi"] and
                    typed_equal(window, actual["target"]["window_rect"]),
                    f"Appearance {scene} window differs from independent postlaunch bounds.")
            native_list = state.get("native_list", {})
            native_rect = native_list.get("rect", {}) if isinstance(native_list, dict) else {}
            require(native_list.get("hwnd") == state.get("list", {}).get("native_handle") and
                    native_list.get("process_id") == actual["target"]["process_id"] and
                    native_list.get("hwnd_dpi") == actual["hwnd_dpi"] and
                    all(type(native_rect.get(key)) is int for key in ("left", "top", "right", "bottom")) and
                    window["left"] <= native_rect["left"] < native_rect["right"] <= window["right"] and
                    window["top"] <= native_rect["top"] < native_rect["bottom"] <= window["bottom"],
                    f"Appearance {scene} native ListView bounds differ.")
            header = state.get("native_header", {})
            header_rect = validate_rectangle(header.get("rect"), "appearance native header")
            require(type(header.get("hwnd")) is int and header["hwnd"] > 0 and
                    header.get("process_id") == actual["target"]["process_id"] and
                    header.get("hwnd_dpi") == actual["hwnd_dpi"] and
                    native_rect["top"] <= header_rect["top"] < header_rect["bottom"] < native_rect["bottom"],
                    "Appearance native header identity or vertical geometry differs.")
            divider = (217, 221, 227) if appearance == "light" else (55, 60, 67)
            for label, region in (
                ("rail/list divider", {"left": native_rect["left"] - window["left"] - 1,
                                       "right": native_rect["left"] - window["left"],
                                       "top": native_rect["top"] - window["top"] + 8,
                                       "bottom": native_rect["bottom"] - window["top"] - 8}),
                ("header/body divider", {"left": native_rect["left"] - window["left"] + 8,
                                         "right": native_rect["left"] - window["left"] + 40,
                                         "top": header_rect["bottom"] - window["top"] - 1,
                                         "bottom": header_rect["bottom"] - window["top"]}),
                ("status divider", {"left": native_rect["left"] - window["left"] + 8,
                                    "right": native_rect["left"] - window["left"] + 40,
                                    "top": native_rect["bottom"] - window["top"],
                                    "bottom": native_rect["bottom"] - window["top"] + 1}),
            ):
                pair_flat_region(rgba, width, height, region, (divider,), label)
            bounds = state.get("list", {}).get("bounds", {})
            require(all(type(bounds.get(key)) in {int, float} for key in ("x", "y", "width", "height")),
                    f"Appearance {scene} list bounds are missing.")
            x = round(bounds["x"] - window["left"])
            y = round(bounds["y"] - window["top"])
            list_width = round(bounds["width"])
            list_height = round(bounds["height"])
            interior = {"left": x + 8, "right": x + min(40, list_width - 8),
                        "top": y + list_height // 2, "bottom": y + list_height // 2 + 8}
            body_luma = pair_region_luma(rgba, width, height, interior, "list interior")
            sample = {"phase": phase, "body_luma": round(body_luma, 2)}
            if scene in {"changed", "collision", "warning"}:
                proposed_bounds = state["proposed_cell"]["bounds"]
                proposed_rect = {
                    "left": max(native_rect["left"], proposed_bounds["x"]) - window["left"],
                    "top": proposed_bounds["y"] - window["top"],
                    "right": min(native_rect["right"], proposed_bounds["x"] + proposed_bounds["width"]) - window["left"],
                    "bottom": proposed_bounds["y"] + proposed_bounds["height"] - window["top"],
                }
                role_rgb = {
                    "changed": {"light": (35, 83, 151), "dark": (133, 183, 255)},
                    "collision": {"light": (169, 22, 33), "dark": (255, 137, 145)},
                    "warning": {"light": (142, 83, 0), "dark": (255, 194, 92)},
                }[scene][appearance]
                semantic_pixels = pair_count_near_color(rgba, width, height, proposed_rect, role_rgb)
                require(semantic_pixels >= 4,
                        f"Appearance {scene} proposed-name semantic raster violation.")
                sample["proposed_semantic_pixels"] = semantic_pixels
                current = state.get("current_name_cell", {})
                require(isinstance(current, dict) and current.get("name") == state["current_names"][0] and
                        current.get("offscreen") is False, "Appearance current-name cell identity differs.")
                current_bounds = current.get("bounds", {})
                require(all(type(current_bounds.get(key)) in {int, float} for key in ("x", "y", "width", "height")),
                        "Appearance current-name cell bounds are missing.")
                require(current_bounds["width"] == state["columns"][0] and
                        proposed_bounds["width"] == state["columns"][1] and
                        proposed_bounds["x"] - current_bounds["x"] == state["columns"][0] and
                        current_bounds["y"] == proposed_bounds["y"] and current_bounds["height"] == proposed_bounds["height"],
                        "Appearance native name cells differ from their persisted columns.")
                current_region = {
                    "left": max(native_rect["left"], round(current_bounds["x"])) - window["left"],
                    "top": round(current_bounds["y"]) - window["top"],
                    "right": min(native_rect["right"], round(current_bounds["x"] + current_bounds["width"])) - window["left"],
                    "bottom": round(current_bounds["y"] + current_bounds["height"]) - window["top"],
                }
                require(pair_count_near_color(rgba, width, height, current_region, role_rgb, tolerance=8) == 0,
                        "Appearance proposal semantic color leaked into current-name column.")
            if scene == "overflow":
                horizontal_bounds = state["horizontal_scrollbar_bounds"]
                vertical_bounds = state["vertical_scrollbar_bounds"]
                h = {"left": horizontal_bounds[0] - window["left"],
                     "top": horizontal_bounds[1] - window["top"],
                     "right": horizontal_bounds[2] - window["left"],
                     "bottom": horizontal_bounds[3] - window["top"]}
                v = {"left": vertical_bounds[0] - window["left"],
                     "top": vertical_bounds[1] - window["top"],
                     "right": vertical_bounds[2] - window["left"],
                     "bottom": vertical_bounds[3] - window["top"]}
                intersection_left = native_rect["right"] - window["left"] - (v["right"] - v["left"])
                intersection_top = native_rect["bottom"] - window["top"] - (h["bottom"] - h["top"])
                for label, region in {
                    "horizontal_scrollbar": {"left": (h["left"] + h["right"]) // 2 - 4,
                                             "right": (h["left"] + h["right"]) // 2 + 4,
                                             "top": h["top"] + 3, "bottom": h["bottom"] - 3},
                    "vertical_scrollbar": {"left": v["left"] + 3, "right": v["right"] - 3,
                                           "top": (v["top"] + v["bottom"]) // 2 - 4,
                                           "bottom": (v["top"] + v["bottom"]) // 2 + 4},
                    "scrollbar_intersection": {"left": intersection_left + 3,
                                               "right": intersection_left + (v["right"] - v["left"]) - 3,
                                               "top": intersection_top + 3,
                                               "bottom": intersection_top + (h["bottom"] - h["top"]) - 3},
                }.items():
                    sample[label] = round(pair_region_luma(rgba, width, height, region, label), 2)
                    if appearance == "dark" and label == "scrollbar_intersection":
                        sample["intersection_palette_pixels"] = pair_flat_region(
                            rgba, width, height, region, ((20, 22, 25),), "dark scrollbar intersection")
            measurements.append(sample)
        if scene in {"empty", "unchanged"}:
            require(measurements[0]["body_luma"] > 150 and measurements[1]["body_luma"] < 130 and
                    measurements[2]["body_luma"] > 150 and
                    abs(measurements[0]["body_luma"] - measurements[2]["body_luma"]) <= 15,
                    f"Appearance {scene} light/dark/light interior raster violation.")
        before_width, before_height, before_rgba = endpoint_rasters["light-before"]
        after_width, after_height, after_rgba = endpoint_rasters["light-after"]
        require((before_width, before_height) == (after_width, after_height),
                "Appearance Light endpoint raster dimensions differ.")
        client, window = rendering["client"], actual["target"]["window_rect"]
        endpoint_region = {edge: client[edge] - window["left" if edge in ("left", "right") else "top"]
                           for edge in ("left", "top", "right", "bottom")}
        endpoint_delta = pair_pixel_delta(before_rgba, after_rgba, before_width, before_height, endpoint_region)
        require(endpoint_delta == 0, f"Appearance {scene} Light endpoint client raster did not restore.")
        measurements[-1]["light_endpoint_changed_pixels"] = endpoint_delta
        diagnostics[scene] = measurements
    for phase in PAIR_PHASES:
        active_step = scenes["selected-active"][PAIR_PHASES.index(phase)]
        inactive_step = scenes["selected-inactive"][PAIR_PHASES.index(phase)]
        active_image = read_bytes(run_root / "output", Path(active_step["capture"]["file"]),
                                  MAX_ARTIFACT_BYTES, "active selection PNG")
        inactive_image = read_bytes(run_root / "output", Path(inactive_step["capture"]["file"]),
                                    MAX_ARTIFACT_BYTES, "inactive selection PNG")
        active_width, active_height, active_rgba = decode_png(active_image, "active selection")
        inactive_width, inactive_height, inactive_rgba = decode_png(inactive_image, "inactive selection")
        require((active_width, active_height) == (inactive_width, inactive_height),
                "Appearance selection capture geometry changed.")
        active_state = active_step["state"]
        inactive_state = inactive_step["state"]
        require(typed_equal(active_state["selection"], inactive_state["selection"]) and
                typed_equal(active_state["selected_row_cell"], inactive_state["selected_row_cell"]),
                "Appearance active/inactive selection changed native row geometry.")
        selected_bounds = active_state["selected_row_cell"]["bounds"]
        window = active_state["window"]["rect"]
        selected_rect = {"left": selected_bounds["x"] - window["left"],
                         "top": selected_bounds["y"] - window["top"],
                         "right": selected_bounds["x"] + selected_bounds["width"] - window["left"],
                         "bottom": selected_bounds["y"] + selected_bounds["height"] - window["top"]}
        difference = pair_pixel_delta(active_rgba, inactive_rgba, active_width, active_height,
                                      selected_rect)
        require(difference >= 8, "Appearance active/inactive selection raster did not change.")
        diagnostics.setdefault("selection_transition", []).append({"phase": phase, "changed_pixels": difference})

    interactions = scenario.get("interactions")
    require(isinstance(interactions, list) and len(interactions) == len(PAIR_PHASES) and
            [row.get("phase") for row in interactions if isinstance(row, dict)] == list(PAIR_PHASES),
            "Appearance paired interaction phases are incomplete.")

    def capture_pixels(capture: dict, name: str, appearance: str,
                       expected_surface: str) -> tuple[int, int, bytes]:
        require(isinstance(capture, dict) and capture.get("file") == name and
                captures[name].get("sha256") == capture.get("sha256") == collection_files[name]["sha256"] and
                captures[name].get("appearance") == appearance and
                captures[name].get("surface") == expected_surface,
                f"Appearance interaction {name} capture binding differs.")
        width, height, rgba = decode_png(read_bytes(run_root / "output", Path(name),
                                               MAX_ARTIFACT_BYTES, "appearance interaction PNG"), name)
        require(width == capture.get("width") == captures[name].get("width") and
                height == capture.get("height") == captures[name].get("height"),
                f"Appearance interaction {name} dimensions differ.")
        return width, height, rgba

    for interaction in interactions:
        phase = interaction["phase"]
        appearance = "dark" if phase == "dark" else "light"
        require(interaction.get("appearance") == appearance and
                interaction.get("column_preference_sha256") == preference["sha256"] and
                interaction.get("selected") == scenes["selected-inactive"][2]["state"]["selection"],
                "Appearance interaction theme, settings, or selection differs.")
        menu_state = interaction.get("appearance_menu")
        require(isinstance(menu_state, dict) and menu_state.get("hwnd") == actual["target"]["hwnd"] and
                menu_state.get("pid") == actual["target"]["process_id"] and
                menu_state.get("menu_checked") == [
                    {"command_id": 0x9010, "checked": False},
                    {"command_id": 0x9011, "checked": appearance == "light"},
                    {"command_id": 0x9012, "checked": appearance == "dark"},
                ], "Appearance interaction menu theme differs.")
        buttons = interaction.get("buttons")
        require(isinstance(buttons, dict) and set(buttons) == set(PAIR_BUTTON_STATES),
                "Appearance button state set is incomplete.")
        button_rasters = {}
        button_ink = {}
        prefix_bounds = None
        for button_state in PAIR_BUTTON_STATES:
            entry = buttons[button_state]
            require(isinstance(entry, dict) and isinstance(entry.get("control"), dict) and
                    isinstance(entry.get("target"), dict),
                    f"Appearance {button_state} native/UIA button observation is missing.")
            control, target = entry["control"], entry["target"]
            expected_id = "32771" if button_state == "disabled" else "32773"
            expected_focus = "32773" if button_state in {"pressed", "keyboard-focus"} else "1000"
            require(control.get("automation_id") == expected_id and
                    control.get("enabled") is (button_state != "disabled") and
                    control.get("offscreen") is False and
                    entry.get("focus_automation_id") == expected_focus and
                    type(entry.get("native_button_state")) is int and
                    bool(entry["native_button_state"] & 4) is (button_state == "pressed") and
                    bool(entry["native_button_state"] & 8) is (button_state in {"pressed", "keyboard-focus"}) and
                    target.get("root_window") == actual["target"]["hwnd"] and
                    type(target.get("hit_window")) is int and target["hit_window"] > 0,
                    f"Appearance {button_state} button native/UIA state differs.")
            bounds = control.get("bounds", {})
            window = actual["target"]["window_rect"]
            require(all(type(bounds.get(key)) in (int, float) for key in ("x", "y", "width", "height")) and
                    bounds["width"] >= 20 and bounds["height"] >= 16 and
                    bounds["x"] <= target["x"] <= bounds["x"] + bounds["width"] and
                    bounds["y"] <= target["y"] <= bounds["y"] + bounds["height"],
                    f"Appearance {button_state} button bounds differ from its physical target.")
            cursor = entry.get("cursor")
            require(isinstance(cursor, list) and len(cursor) == 4 and all(type(value) is int for value in cursor) and
                    cursor[2] > 0 and cursor[3] == actual["target"]["hwnd"], "Appearance button cursor identity differs.")
            inside = bounds["x"] <= cursor[0] < bounds["x"] + bounds["width"] and bounds["y"] <= cursor[1] < bounds["y"] + bounds["height"]
            require((inside and cursor[2] == control.get("native_handle")) if button_state in {"hover", "pressed"} else not inside,
                    "Appearance button cursor does not match its declared mouse or keyboard state.")
            rect = {"left": bounds["x"] - window["left"], "top": bounds["y"] - window["top"],
                    "right": bounds["x"] + bounds["width"] - window["left"],
                    "bottom": bounds["y"] + bounds["height"] - window["top"]}
            name = f"appearance-button-{button_state}-{phase}.png"
            width, height, rgba = capture_pixels(entry.get("capture"), name, appearance, "main-workbench")
            require((width, height) == (window["width"], window["height"]),
                    f"Appearance {button_state} PNG differs from main window geometry.")
            role_rgb = {
                "light": {"normal": (255, 255, 255), "disabled": (235, 237, 240),
                          "hover": (240, 244, 250), "pressed": (226, 232, 240)},
                "dark": {"normal": (42, 45, 50), "disabled": (34, 37, 41),
                         "hover": (52, 57, 64), "pressed": (32, 35, 40)},
            }[appearance].get(button_state)
            if role_rgb is not None:
                require(pair_count_near_color(rgba, width, height, rect, role_rgb) >= 20,
                        f"Appearance {button_state} button fill raster violation.")
            fill = role_rgb or ((255, 255, 255) if appearance == "light" else (42, 45, 50))
            outline = (177, 183, 192) if appearance == "light" else (83, 89, 99)
            pair_button_outline(rgba, width, height, rect, outline, fill, shares_top=button_state != "disabled")
            text_rgb = ((110, 117, 127) if appearance == "light" else (150, 157, 167)) if button_state == "disabled" else (
                (27, 29, 32) if appearance == "light" else (242, 244, 247))
            button_ink[button_state] = pair_button_ink(rgba, width, height, rect, text_rgb)
            if button_state != "disabled":
                require(prefix_bounds is None or typed_equal(prefix_bounds, bounds),
                        "Appearance prefix button geometry changed with interaction state.")
                prefix_bounds = bounds
            button_rasters[button_state] = (rgba, rect)
        require(pair_pixel_delta(button_rasters["normal"][0], button_rasters["hover"][0],
                                 window["width"], window["height"], button_rasters["normal"][1]) >= 20 and
                pair_pixel_delta(button_rasters["hover"][0], button_rasters["pressed"][0],
                                 window["width"], window["height"], button_rasters["normal"][1]) >= 20 and
                pair_pixel_delta(button_rasters["normal"][0], button_rasters["keyboard-focus"][0],
                                 window["width"], window["height"], button_rasters["normal"][1]) >= 8,
                "Appearance hover, pressed, or keyboard-focus raster state did not change.")
        offset = (actual["hwnd_dpi"] + 48) // 96
        translated = {(x + offset, y + offset) for x, y in button_ink["normal"]}
        require(len(translated & button_ink["pressed"]) >= len(translated) * .85 and
                abs(len(translated) - len(button_ink["pressed"])) <= len(translated) * .15,
                "Appearance pressed text did not retain its one-DIP translation without clipping.")
        normal, rect = button_rasters["normal"]
        focused = button_rasters["keyboard-focus"][0]
        inset = (3 * actual["hwnd_dpi"] + 48) // 96
        x0, y0, x1, y1 = (int(rect[key]) for key in ("left", "top", "right", "bottom"))
        cue = {(x, y) for y in range(y0, y1) for x in range(x0, x1)
               if max(abs(normal[(y * width + x) * 4 + channel] - focused[(y * width + x) * 4 + channel])
                      for channel in range(3)) >= 10}
        require(len(cue) >= 8 and all(
            x0 + inset <= x < x1 - inset and y0 + inset <= y < y1 - inset and
            (x in {x0 + inset, x1 - inset - 1} or y in {y0 + inset, y1 - inset - 1}) for x, y in cue),
            "Appearance keyboard-focus cue differs from its three-DIP inset.")

        for kind, surface in PAIR_MODAL_SURFACES.items():
            field = {"native-menu": "native_menu", "advanced": "advanced_appearance",
                     "input-prompt": "input_prompt"}[kind]
            entry = interaction.get(field)
            require(isinstance(entry, dict), f"Appearance {kind} observation is missing.")
            name = f"appearance-{kind}-{phase}.png"
            width, height, rgba = capture_pixels(entry.get("capture"), name, appearance, surface)
            if kind == "native-menu":
                popup = entry.get("popup", {})
                require(entry.get("popup_hwnd") == popup.get("native_handle") and
                        type(entry.get("popup_hwnd")) is int and entry["popup_hwnd"] > 0 and
                        isinstance(popup.get("bounds"), dict) and
                        popup["bounds"].get("width", 0) > 30 and popup["bounds"].get("height", 0) > 20,
                        "Appearance native menu popup binding differs.")
                popup_bounds = popup["bounds"]
                main_window = actual["target"]["window_rect"]
                union_width = max(main_window["right"], round(popup_bounds["x"] + popup_bounds["width"])) - min(main_window["left"], round(popup_bounds["x"]))
                union_height = max(main_window["bottom"], round(popup_bounds["y"] + popup_bounds["height"])) - min(main_window["top"], round(popup_bounds["y"]))
                require(abs(width - union_width) <= 2 and abs(height - union_height) <= 2,
                        "Appearance native menu PNG differs from observed popup geometry.")
                diagnostics.setdefault("native_menu", []).append({"phase": phase, "popup_bounds": popup_bounds})
            else:
                native = entry.get("native_window", {})
                observed = entry.get("window", {})
                rect = native.get("rect", {}) if isinstance(native, dict) else {}
                require(native.get("hwnd") == observed.get("native_handle") and
                        native.get("process_id") == actual["target"]["process_id"] and
                        native.get("hwnd_dpi") == actual["hwnd_dpi"] and
                        rect.get("width") == width and rect.get("height") == height,
                        f"Appearance {kind} native window or raster dimensions differ.")
                dialog_rgb = (247, 248, 250) if appearance == "light" else (26, 28, 32)
                require(pair_count_near_color(rgba, width, height,
                                              {"left": 0, "top": 0, "right": width, "bottom": height},
                                              dialog_rgb) >= 100,
                        f"Appearance {kind} dialog surface raster violation.")
                if kind == "input-prompt":
                    edit = entry.get("edit", {})
                    default = entry.get("default_button", {})
                    require(edit.get("automation_id") == "1004" and edit.get("name") == "붙일 문자열" and
                            default.get("automation_id") == "1" and default.get("enabled") is True and
                            entry.get("default_button_id") == 1 and
                            entry.get("default_button_query") ==
                            "WM_GETDLGCODE(DLGC_BUTTON|DLGC_DEFPUSHBUTTON)+GetDlgCtrlID",
                            "Appearance prompt label or native default button differs.")
                    bounds = default.get("bounds", {})
                    require(all(type(bounds.get(key)) in {int, float} for key in ("x", "y", "width", "height")),
                            "Appearance default button bounds are missing.")
                    default_rect = {"left": bounds["x"] - rect["left"], "top": bounds["y"] - rect["top"],
                                    "right": bounds["x"] + bounds["width"] - rect["left"],
                                    "bottom": bounds["y"] + bounds["height"] - rect["top"]}
                    pair_button_outline(rgba, width, height, default_rect,
                        (177, 183, 192) if appearance == "light" else (83, 89, 99),
                        (255, 255, 255) if appearance == "light" else (42, 45, 50), shares_top=False, default=True)
                    label = exact_keys(entry.get("same_glyph_label"),
                                       {"control", "native_window", "native_class", "text_sha256", "query"},
                                       "appearance same-glyph label")
                    control = label["control"]
                    label_window = label["native_window"]
                    label_rect = validate_rectangle(label_window.get("rect"), "appearance label rectangle")
                    label_bounds = exact_keys(control.get("bounds"), {"x", "y", "width", "height"}, "appearance label UIA bounds")
                    require(label["native_class"].lower() == "static" and
                            label["query"] == "bound STATIC/WM_GETTEXT original prompt raster" and
                            label["text_sha256"] == sha256_bytes("붙일 문자열".encode("utf-8")) and
                            control.get("automation_id") == "1002" and control.get("name") == "붙일 문자열" and
                            control.get("control_type") == "ControlType.Text" and control.get("offscreen") is False and
                            label_window.get("hwnd") == control.get("native_handle") and
                            label_window.get("process_id") == actual["target"]["process_id"] and
                            label_window.get("hwnd_dpi") == actual["hwnd_dpi"] and
                            all(type(label_bounds[key]) in {int, float} and label_bounds[key] == expected
                                for key, expected in {"x": label_rect["left"], "y": label_rect["top"],
                                                      "width": label_rect["width"], "height": label_rect["height"]}.items()),
                            "Appearance same-glyph label identity differs.")
                    x0, y0 = label_rect["left"] - rect["left"], label_rect["top"] - rect["top"]
                    x1, y1 = x0 + label_rect["width"], y0 + label_rect["height"]
                    require(0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height,
                            "Appearance same-glyph label lies outside original prompt PNG.")
                    ink = [(x, y) for y in range(y0, y1) for x in range(x0, x1)
                           if (max(rgba[(y * width + x) * 4:(y * width + x) * 4 + 3]) < 120
                               if appearance == "light" else
                               min(rgba[(y * width + x) * 4:(y * width + x) * 4 + 3]) > 180)]
                    require(len(ink) >= 8, "Appearance same-glyph label has no readable raster ink.")
                    ink_x, ink_y = zip(*ink)
                    require(max(ink_x) < x1 - 1 and max(ink_y) < y1 - 1,
                            "Appearance same-glyph label touches a clipping edge.")
                    diagnostics.setdefault("same_glyph", []).append({
                        "phase": phase, "text_sha256": label["text_sha256"],
                        "width": max(ink_x) - min(ink_x) + 1, "height": max(ink_y) - min(ink_y) + 1,
                        "ink_pixels": len(ink), "control_rect": label_rect,
                    })
        scrollbars = interaction.get("scrollbars")
        require(isinstance(scrollbars, dict) and set(scrollbars) == set(PAIR_SCROLL_AXES),
                "Appearance scrollbar axis observations are incomplete.")
        for axis in PAIR_SCROLL_AXES:
            entry = scrollbars[axis]
            require(isinstance(entry, dict) and type(entry.get("list_hwnd")) is int and
                    entry["list_hwnd"] == scenes["overflow"][0]["state"]["native_focus"][0],
                    "Appearance scrollbar list identity differs.")
            target = entry.get("target", {})
            require(target.get("hit_window") == entry["list_hwnd"] and
                    target.get("root_window") == actual["target"]["hwnd"] and
                    all(type(target.get(key)) is int for key in ("x", "y")),
                    "Appearance scrollbar hit target differs.")
            initial, restored = entry.get("initial_scroll"), entry.get("restored_scroll")
            require(all(isinstance(value, list) and len(value) == 5 and
                        all(type(item) is int for item in value) for value in (initial, restored)) and
                    typed_equal(initial[:4], restored[:4]) and initial[3] == 0,
                    "Appearance scrollbar initial viewport was not restored.")
            steps = entry.get("steps")
            require(isinstance(steps, list) and len(steps) == 3 and
                    [step.get("stage") for step in steps if isinstance(step, dict)] == list(PAIR_SCROLL_STAGES),
                    "Appearance scrollbar tracking stages are incomplete.")
            for step in steps:
                stage = step["stage"]
                gui, bar, scroll = step.get("native_gui"), step.get("components"), step.get("scroll")
                require(isinstance(gui, list) and len(gui) == 3 and
                        all(type(item) is int for item in gui) and gui[0] == entry["list_hwnd"] and
                        gui[1] == (0 if stage == "released" else entry["list_hwnd"]) and gui[2] == 1000,
                        "Appearance scrollbar native capture state differs.")
                require(isinstance(bar, list) and len(bar) == 13 and
                        all(type(item) is int for item in bar) and not (bar[7] & 0x18000),
                        "Appearance scrollbar component observation differs.")
                length = bar[2] - bar[0] if axis == "horizontal" else bar[3] - bar[1]
                require(bar[0] < bar[2] and bar[1] < bar[3] and bar[4] >= 1 and
                        bar[4] <= bar[5] < bar[6] <= length - bar[4],
                        "Appearance scrollbar thumb geometry differs.")
                require(isinstance(scroll, list) and len(scroll) == 5 and
                        all(type(item) is int for item in scroll) and typed_equal(scroll[:3], initial[:3]) and
                        (stage != "released" or scroll[3] > initial[3]),
                        "Appearance scrollbar native drag did not advance the viewport.")
                if stage == "held":
                    require(bar[0] <= target["x"] < bar[2] and bar[1] <= target["y"] < bar[3] and
                            bar[5] <= (target["x"] - bar[0] if axis == "horizontal" else target["y"] - bar[1]) < bar[6],
                            "Appearance scrollbar press missed the native thumb.")
                name = f"appearance-scroll-{axis}-{stage}-{phase}.png"
                width, height, rgba = capture_pixels(step.get("capture"), name, appearance, "main-workbench")
                require((width, height) == (window["width"], window["height"]),
                        "Appearance scrollbar capture dimensions differ.")
                rect = {"left": bar[0] - window["left"], "top": bar[1] - window["top"],
                        "right": bar[2] - window["left"], "bottom": bar[3] - window["top"]}
                palette_pixels = None
                if appearance == "dark":
                    axis_start = rect["left"] if axis == "horizontal" else rect["top"]
                    thumb = dict(rect)
                    thumb["left" if axis == "horizontal" else "top"] = axis_start + bar[5]
                    thumb["right" if axis == "horizontal" else "bottom"] = axis_start + bar[6]
                    thumb = {key: value + (2 if key in ("left", "top") else -2)
                             for key, value in thumb.items()}
                    thumb_colors = (((55, 60, 67),) if bar[10] & 1 else
                                    ((83, 89, 99), (150, 157, 167), (184, 190, 199)))
                    thumb_pixels = pair_flat_region(rgba, width, height, thumb, thumb_colors,
                                                   f"dark {axis} {stage} scrollbar thumb")
                    gaps = ((bar[4], bar[5]), (bar[6], length - bar[4]))
                    start, end = max(gaps, key=lambda gap: gap[1] - gap[0])
                    require(end - start >= 5, "Appearance scrollbar track is too small to observe.")
                    track = dict(rect)
                    track["left" if axis == "horizontal" else "top"] = axis_start + start
                    track["right" if axis == "horizontal" else "bottom"] = axis_start + end
                    track = {key: value + (2 if key in ("left", "top") else -2)
                             for key, value in track.items()}
                    track_pixels = pair_flat_region(rgba, width, height, track, ((20, 22, 25),),
                                                   f"dark {axis} {stage} scrollbar track")
                    palette_pixels = {"thumb": thumb_pixels, "track": track_pixels}
                diagnostics.setdefault("scrollbar_tracking", []).append({
                    "phase": phase, "axis": axis, "stage": stage, "components": bar,
                    "scroll": scroll, "palette_pixels": palette_pixels, "bar_luma": pair_region_luma(rgba, width, height, rect, f"{axis}-{stage}")})
        diagnostics.setdefault("interactions", []).append({"phase": phase, "buttons": list(buttons)})
    if high_contrast:
        diagnostics["system_and_forced_colors"] = validate_pair_high_contrast(run_root, raw, collection_files, actual, capture_pixels)
    else:
        require(scenario.get("high_contrast") is None, "Appearance normal pair contains an unrequested High Contrast probe.")
    return diagnostics


def validate_pair_restoration(run_root: Path, raw: dict, files: dict, reference: object,
                             name: str, version: int) -> dict:
    reference = exact_keys(reference, {"file", "sha256"}, "appearance restoration reference")
    require(reference["file"] == name and name in files and
            reference["sha256"] == files[name]["sha256"], "Appearance restoration artifact binding differs.")
    document, data = read_json(run_root / "output", Path(name), "appearance restoration document")
    require(sha256_bytes(data) == reference["sha256"], "Appearance restoration document changed.")
    document = exact_keys(document, {"schema_version", "source_sha", "acceptance_script_sha256",
        "restoration_required", "restoration_verified", "original", "restored"}, "appearance restoration document")
    require(int_equals(document["schema_version"], version) and
            document["source_sha"] == raw["source_sha"] and
            document["acceptance_script_sha256"] == raw["acceptance_script_sha256"] and
            type(document["restoration_required"]) is bool and document["restoration_verified"] is True and
            isinstance(document["original"], dict) and typed_equal(document["original"], document["restored"]),
            "Appearance restoration scope or original state did not restore exactly.")
    return document


def validate_pair_high_contrast(run_root: Path, raw: dict, files: dict, actual: dict,
                                capture_pixels) -> list[dict]:
    scenario = raw["assertions"]["scenario"]
    contrast = exact_keys(scenario.get("high_contrast"),
        {"snapshot", "restoration_verified", "original_enabled", "acceptance_enabled", "before", "active", "after"},
        "appearance High Contrast probe")
    require(contrast["restoration_verified"] is True and contrast["original_enabled"] is False and
            contrast["acceptance_enabled"] is True and
            nested(raw, "high_contrast", "requested") is True and
            nested(raw, "high_contrast", "restoration") == "verified" and
            typed_equal(nested(raw, "high_contrast", "snapshot"), contrast["snapshot"]),
            "Appearance High Contrast activation or restoration is missing.")
    document = validate_pair_restoration(run_root, raw, files, contrast["snapshot"], "high-contrast-restore.json", 2)
    require(document["restoration_required"] is False, "Appearance High Contrast rescue is still pending.")
    original = exact_keys(document["original"], {"flags", "scheme", "colors", "visual_style"}, "High Contrast original")
    require(type(original["flags"]) is int and 0 <= original["flags"] <= 0xFFFFFFFF and original["flags"] & 0x1001 == 0,
            "Appearance original High Contrast flags are invalid.")
    rows = []
    rasters = {}
    for key, phase in (("before", "before"), ("active", "forced-colors"), ("after", "after")):
        state = contrast[key]
        require(isinstance(state, dict) and state.get("phase") == phase and state.get("appearance") == "system" and
                int_equals(state.get("row_count"), 60) and isinstance(state.get("current_names"), list) and
                len(state["current_names"]) == 60 and all(isinstance(name, str) and name for name in state["current_names"]),
                "Appearance System probe phase or fixture differs.")
        resolution = exact_keys(state.get("resolution"), {"query", "foreground_argb", "resolved_theme", "system_visual_style"},
                                "appearance System resolution")
        color = resolution["foreground_argb"]
        require(resolution["query"] == "UISettings.GetColorValue(UIColorType.Foreground)+SPI_GETHIGHCONTRAST" and
                isinstance(color, list) and len(color) == 4 and
                all(type(value) is int and 0 <= value <= 255 for value in color) and color[0] == 255 and
                nested(resolution, "system_visual_style", "forced_colors") is (key == "active"),
                "Appearance System foreground or Forced Colors observation differs.")
        theme = "native" if key == "active" else "dark" if color[1] * 299 + color[2] * 587 + color[3] * 114 >= 128000 else "light"
        require(resolution["resolved_theme"] == theme, "Appearance System theme resolution differs from observed foreground.")
        menu = state.get("appearance_menu", {})
        require(menu.get("hwnd") == actual["target"]["hwnd"] and menu.get("pid") == actual["target"]["process_id"] and
                menu.get("menu_checked") == [{"command_id": 0x9010, "checked": True},
                    {"command_id": 0x9011, "checked": False}, {"command_id": 0x9012, "checked": False}],
                "Appearance System menu did not remain selected.")
        native = state.get("native_window", {})
        rect = validate_rectangle(native.get("rect"), "appearance System window")
        require(native.get("hwnd") == actual["target"]["hwnd"] and native.get("process_id") == actual["target"]["process_id"] and
                native.get("hwnd_dpi") == actual["hwnd_dpi"], "Appearance System window identity changed.")
        rendering = validate_pair_rendering_environment(state.get("target_rendering"),
            {**actual, "target": {**actual["target"], "window_rect": rect}})
        native_list = state.get("native_list", {})
        list_rect = validate_rectangle(native_list.get("rect"), "appearance System ListView")
        focus = state.get("native_focus")
        require(native_list.get("process_id") == actual["target"]["process_id"] and
                native_list.get("hwnd_dpi") == actual["hwnd_dpi"] and
                typed_equal(focus, [native_list.get("hwnd"), 0, 1000]) and
                nested(state, "overlay", "visible_tooltip_count") == 0 and nested(state, "overlay", "neutral_cursor") is True,
                "Appearance System native focus or tooltip differs.")
        width, height, rgba = capture_pixels(state.get("capture"), f"appearance-system-{phase}.png", "system", "main-workbench")
        require((width, height) == (rect["width"], rect["height"]), "Appearance System PNG geometry differs.")
        colors = exact_keys(state.get("colors"), {"window", "window_text", "button_face", "button_text", "highlight", "highlight_text", "gray_text", "hot_light"}, "appearance System colors")
        require(all(type(value) is int and 0 <= value <= 0xFFFFFF for value in colors.values()), "Appearance System colors are invalid.")
        rgb = lambda value: (value & 255, value >> 8 & 255, value >> 16 & 255)
        cells = exact_keys(state.get("semantic_cells"), {"selected", "unselected"}, "appearance System semantic cells")
        for selected, leaf in ((True, ".txt"), (False, ".log")):
            cell = cells["selected" if selected else "unselected"]
            require(isinstance(cell, dict) and cell.get("name") == leaf and cell.get("offscreen") is False,
                    "Appearance System warning proposal differs.")
            bounds = cell.get("bounds", {})
            require(all(type(bounds.get(field)) in {int, float} for field in ("x", "y", "width", "height")), "Appearance System cell geometry is missing.")
            region = {"left": max(list_rect["left"], round(bounds["x"])) - rect["left"],
                      "top": round(bounds["y"]) - rect["top"],
                      "right": min(list_rect["right"] - 20, round(bounds["x"] + bounds["width"])) - rect["left"],
                      "bottom": round(bounds["y"] + bounds["height"]) - rect["top"]}
            expected = rgb(colors["highlight_text"] if selected else colors["window_text"]) if theme == "native" else (
                rgb(colors["highlight_text"]) if selected else (142, 83, 0) if theme == "light" else (255, 194, 92))
            require(pair_count_near_color(rgba, width, height, region, expected, tolerance=8) >= 3,
                    "Appearance System warning or native selection color precedence failed.")
        rasters[key] = (width, height, rgba, rendering)
        rows.append({"phase": phase, "resolved_theme": theme, "warning_and_selection_precedence": "passed"})
    before, after = contrast["before"], contrast["after"]
    require(typed_equal(original["colors"], before["colors"]) and
            not typed_equal(before["colors"], contrast["active"]["colors"]),
            "Appearance High Contrast did not bind or change the original system palette.")
    require(all(typed_equal(before.get(field), after.get(field)) for field in
                ("resolution", "current_names", "selection", "semantic_cells", "proposal_viewport", "native_focus", "target_rendering", "native_window", "native_list", "horizontal_scroll", "vertical_scroll", "horizontal_components", "vertical_components", "colors")) and
            all(typed_equal(before.get(field), contrast["active"].get(field)) for field in ("current_names", "selection")),
            "Appearance System restoration changed fixture, geometry, focus, or original theme.")
    width, height, before_pixels, rendering = rasters["before"]
    after_width, after_height, after_pixels, _ = rasters["after"]
    window = before["native_window"]["rect"]
    region = {edge: rendering["client"][edge] - window["left" if edge in ("left", "right") else "top"]
              for edge in ("left", "top", "right", "bottom")}
    require((width, height) == (after_width, after_height) and
            pair_pixel_delta(before_pixels, after_pixels, width, height, region) == 0,
            "Appearance System endpoint client raster did not restore.")
    return rows


def validate_pair_run(root: Path, run_id: str, source_sha: str) -> dict:
    require(run_id == PAIR_RUN_ID or run_id in PAIR_CONFIGURATIONS, "Appearance pair run id is invalid.")
    run_root = root / run_id
    require(run_root.is_dir() and not run_root.is_symlink(), "Appearance pair run directory is missing or unsafe.")
    manifest, input_bytes = validate_input_manifest(run_root, source_sha)
    require(manifest["request"]["mode"] == PAIR_MODE, "Appearance pair request mode is missing.")
    input_hash = sha256_bytes(input_bytes)
    _, cleanup_bytes = validate_cleanup(run_root, input_hash)
    _, collection_bytes, files = validate_collection(run_root, input_hash)
    require(sum(row["bytes"] for row in files.values()) <= 120 * 1024 * 1024,
            "Appearance pair exceeds its declared 120 MiB output budget.")
    preflight, postlaunch = validate_platform_preflight(run_root, manifest, input_hash)
    result, result_bytes = read_json(run_root / "output", Path("run-result.json"), "appearance result")
    result = exact_keys(result, {"schema_version", "diagnostic", "run_id", "input_manifest_sha256",
        "collection_sha256", "cleanup_sha256", "source_sha", "application_sha256", "runner_sha256",
        "observer_sha256", "observer_result_sha256", "host_platform", "guest_platform", "actual",
        "status", "exit_code"}, "appearance result")
    artifacts = manifest["artifacts"]
    require(result["schema_version"] == 1 and result["diagnostic"] == PAIR_MODE and
            result["run_id"] == run_id and result["input_manifest_sha256"] == input_hash and
            result["collection_sha256"] == sha256_bytes(collection_bytes) and
            result["cleanup_sha256"] == sha256_bytes(cleanup_bytes) and
            result["source_sha"] == source_sha and
            result["application_sha256"] == artifacts["application"]["sha256"] and
            result["runner_sha256"] == artifacts["runner"]["sha256"] and
            result["observer_sha256"] == artifacts["observer"]["sha256"] and
            result["guest_platform"] == preflight["guest_platform"] and
            result["host_platform"] == manifest["host_preflight"] and
            result["status"] == "review_required" and result["exit_code"] == 0,
            "Appearance result binding or terminal status differs.")
    actual = result["actual"]
    target = validate_target(actual.get("target"), "appearance target")
    require(typed_equal(target, postlaunch["target"]) and
            actual.get("hwnd_dpi") == manifest["request"]["desktop"]["dpi"] and
            actual.get("text_scale_percent") == manifest["request"]["text_scale_percent"],
            "Appearance target or display differs from request and postlaunch observation.")
    monitor = validate_rectangle(actual["monitor"], "appearance monitor")
    work = validate_rectangle(actual["work_area"], "appearance work area")
    require((monitor["width"], monitor["height"]) ==
            (manifest["request"]["desktop"]["width"], manifest["request"]["desktop"]["height"]),
            "Appearance observed monitor geometry differs from requested geometry.")
    window = target["window_rect"]
    require(monitor["left"] <= work["left"] < work["right"] <= monitor["right"] and
            monitor["top"] <= work["top"] < work["bottom"] <= monitor["bottom"] and
            work["left"] <= window["left"] < window["right"] <= work["right"] and
            work["top"] <= window["top"] < window["bottom"] <= work["bottom"],
            "Appearance work area or target window lies outside its monitor.")
    validate_transport_exit(run_root, files, result["exit_code"])
    raw, raw_bytes = read_json(run_root / "output", Path("acceptance-result.json"), "appearance observer")
    observations, observation_bytes = read_json(run_root / "output", Path("acceptance-observations.json"), "appearance observations")
    require(result["observer_result_sha256"] == sha256_bytes(raw_bytes) == files["acceptance-result.json"]["sha256"] and
            files["acceptance-observations.json"]["sha256"] == sha256_bytes(observation_bytes) and
            raw.get("source_sha") == source_sha and
            raw.get("application", {}).get("sha256") == artifacts["application"]["sha256"] and
            raw.get("runner_sha256") == artifacts["runner"]["sha256"] and
            raw.get("acceptance_script_sha256") == artifacts["observer"]["sha256"] and
            raw.get("observations", {}).get("sha256") == sha256_bytes(observation_bytes) and
            typed_equal(raw.get("acceptance_observations"), observations) and
            typed_equal(raw.get("assertions", {}).get("scenario"), observations.get("scenario")) and
            raw.get("status") == "review_required" and raw.get("guest_cleanup") is True and
            raw.get("assertions", {}).get("overall") == "passed" and
            raw.get("assertions", {}).get("scope") == "appearance-pair-main-and-interactions-v2" and
            nested(raw, "keyboard", "status") == "not_run" and
            nested(raw, "accessibility", "status") == "not_run" and
            nested(raw, "capture", "status") == "passed",
            "Appearance observer source, executable, observation, or cleanup binding differs.")
    environment = observations.get("environment")
    style = environment.get("system_visual_style") if isinstance(environment, dict) else None
    require(isinstance(environment, dict) and environment.get("hwnd_dpi") == actual["hwnd_dpi"] and
            environment.get("text_scale_factor_percent") == manifest["request"]["text_scale_percent"] and
            environment.get("physical_screen") == monitor and
            environment.get("work_area") == actual["work_area"] and
            isinstance(style, dict) and style.get("forced_colors") is False and
            isinstance(style.get("theme_color"), str) and style.get("theme_color") and
            isinstance(style.get("theme_size"), str) and style.get("theme_size") and
            checked_digest(style.get("theme_path_sha256"), "appearance system theme path") and
            observations.get("scenario", {}).get("environment") == environment,
            "Appearance raw and normalized environment binding differs.")
    diagnostics = validate_pair_scenes(run_root, raw, files, actual, manifest["request"].get("high_contrast", False))
    if manifest["request"]["text_scale_percent"] == 150:
        text = raw.get("text_scale", {})
        require(all(int_equals(text.get(field), 150) for field in ("requested_percent", "registry_percent", "acceptance_percent")) and
                text.get("restoration") == "verified", "Appearance Text150 activation or restoration is missing.")
        restored = validate_pair_restoration(run_root, raw, files, text.get("snapshot"), "text-scale-snapshot.json", 1)
        original = exact_keys(restored["original"], {"registry_key_existed", "registry_value_existed", "registry_value_kind", "registry_value", "ui_settings_raw_factor", "ui_settings_percent"}, "appearance original text scale")
        require(original["registry_key_existed"] is True and type(original["registry_value_existed"]) is bool and
                type(original["ui_settings_raw_factor"]) in {int, float} and original["ui_settings_raw_factor"] == 1.0 and
                int_equals(original["ui_settings_percent"], 100) and
                ((original["registry_value_existed"] and original["registry_value_kind"] == "DWord" and
                  type(original["registry_value"]) is int and 0 <= original["registry_value"] <= 0xFFFFFFFF) or
                 (original["registry_value_existed"] is False and original["registry_value"] is None and original["registry_value_kind"] is None)),
                "Appearance Text150 original setting is invalid or differs from the baseline.")
    return {"run_id": run_id, "mode": PAIR_MODE, "input_manifest_sha256": input_hash,
            "result_sha256": sha256_bytes(result_bytes), "status": "passed",
            "application_sha256": artifacts["application"]["sha256"],
            "build_identity": {"source_tree": manifest["source_tree"],
                               "bundle_manifest_sha256": manifest["bundle_manifest"]["sha256"],
                               "artifact_sha256": {name: artifact["sha256"] for name, artifact in artifacts.items()}},
            "font_environment": {"installed_fonts": environment["installed_fonts"],
                                 "system_fonts": environment["target_rendering"]["system_font_recipe"]["fonts"]},
            "raster_regions": diagnostics, "native_scrollbar_theme": "dark-tracking-and-intersection-validated"}


def validate_focused_pair_results(pairs: list[dict]) -> None:
    require(len(pairs) == len(PAIR_CONFIGURATIONS) and {pair["run_id"] for pair in pairs} == set(PAIR_CONFIGURATIONS),
            "Appearance focused configuration set is incomplete or duplicated.")
    require(len({pair["application_sha256"] for pair in pairs}) == 1,
            "Appearance focused configurations did not use the same executable.")
    require(all(typed_equal(pair["build_identity"], pairs[0]["build_identity"]) for pair in pairs[1:]),
            "Appearance focused configurations did not use the same build bundle.")
    baseline = next(pair for pair in pairs if pair["run_id"] == "appearance-pair-base-1920x1080-96-text100")
    enlarged = next(pair for pair in pairs if pair["run_id"] == "appearance-pair-text150-1920x1080-96-text150")
    require(typed_equal(baseline["font_environment"]["installed_fonts"], enlarged["font_environment"]["installed_fonts"]) and
            all(typed_equal(before[field], enlarged["font_environment"]["system_fonts"][role][field])
                for role, before in baseline["font_environment"]["system_fonts"].items()
                for field in ("family", "weight", "charset", "quality", "italic", "underline", "strikeout")),
            "Appearance Text150 font family environment differs from baseline.")
    require(all([sample.get("phase") for sample in pair["raster_regions"]["same_glyph"]] == list(PAIR_PHASES)
                for pair in (baseline, enlarged)), "Appearance Text150 same-glyph phase set is incomplete.")
    for before, after in zip(baseline["raster_regions"]["same_glyph"], enlarged["raster_regions"]["same_glyph"], strict=True):
        require(before["phase"] == after["phase"] and before["text_sha256"] == after["text_sha256"] and
                after["width"] > before["width"] * 1.15 and after["height"] > before["height"] * 1.15,
                "Appearance Text150 did not enlarge both dimensions of the same glyphs.")


def parse_arguments(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-root", required=True, type=Path)
    parser.add_argument("--expected-source-sha", required=True)
    parser.add_argument("--run", action="append", required=True, dest="runs")
    parser.add_argument("--require-complete-set", action="store_true")
    parser.add_argument("--diagnostic", choices=[PAIR_MODE])
    parser.add_argument("--configuration-set", choices=["focused"])
    return parser.parse_args(argv)


def main(repo: Path, argv=None) -> int:
    del repo
    args = parse_arguments(argv)
    require(SHA1.fullmatch(args.expected_source_sha) is not None,
            "--expected-source-sha must be a full lowercase Git SHA.")
    root = checked_root(args.result_root)
    require(len(args.runs) == len(set(args.runs)), "Run ids must be unique.")
    if args.diagnostic == PAIR_MODE:
        focused = args.configuration_set == "focused"
        require(not args.require_complete_set and
                (set(args.runs) == set(PAIR_CONFIGURATIONS) if focused else args.runs == [PAIR_RUN_ID]),
                "Appearance pair requires its declared opt-in run set and cannot complete the four-cell set.")
        pairs = [validate_pair_run(root, run_id, args.expected_source_sha) for run_id in args.runs]
        require(len({pair["application_sha256"] for pair in pairs}) == 1,
                "Appearance focused configurations did not use the same executable.")
        if focused:
            validate_focused_pair_results(pairs)
        print(json.dumps({
            "schema_version": 1, "diagnostic": PAIR_MODE, "status": "passed",
            "source_sha": args.expected_source_sha, "runs": pairs,
            "configuration_set": "focused" if focused else "standalone", "same_executable": "passed",
            "state_invariance": "passed", "raster_regions": "passed",
            "native_scrollbar_theme": "dark-tracking-and-intersection-validated",
            "rendering_conformance": "passed-for-declared-scenes", "design_approval": "not-assessed",
            "omitted_scenes": ["normal OS Light/Dark transitions"] if focused else ["forced-colors", "system-theme-following"],
            "full_four_run_regression": "not-run", "release_campaign": "not-run",
        }, ensure_ascii=False, indent=2))
        return 0
    require(args.configuration_set is None, "Focused configurations require appearance-pair diagnostic mode.")
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


def cli(repo: Path, argv=None, tooling=None) -> int:
    del tooling
    try:
        return main(repo, argv)
    except (EvidenceError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1
