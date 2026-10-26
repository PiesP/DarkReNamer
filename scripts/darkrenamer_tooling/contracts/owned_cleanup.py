"""Independent verifier for a preserved strict VM failure and its owned cleanup."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import stat

from darkrenamer_tooling.contracts.platform import (
    V1_PROFILE_ID, V2_PROFILE_ID, HISTORICAL_V2_PROFILE_SHA256, _v2_matches_owned_lifetime,
    _v2_process_rows, _v3_process_rows, _v3_anchor, _v2_task_rows,
    _verify_v2_owned_resources, verify_current_protected_anchor_binding,
    require_fixture_root,
)
from darkrenamer_tooling.campaign.planning import verify_process_job_cleanup
from darkrenamer_tooling.evidence.archive import EvidenceError, require_exact_keys


HEX32 = re.compile(r"[0-9a-f]{32}\Z")
HEX48 = re.compile(r"[0-9a-f]{48}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
RUN = re.compile(r"DarkReNamerTests-[0-9a-f]{32}\Z")
OWNED_PERFORMANCE_PROFILE_SHA256 = "11ce058fdbb51614ac519fabe37fa587fde284fcba4e76ea5e423570243c494f"
OWNED_PERFORMANCE_RUN = re.compile(
    r"performance-sample-v2-owned-r3-1366x768-96-text100-(hidden-visible|visible-hidden)\Z")
PICKER_RUN_ID = "picker-identity-observation-v1-1366x768-96-text100"
PICKER_PLAN = {"ordinary_rows": [100], "idle_ms": 1000, "picker_settle_ms": 350,
               "sample_interval_ms": 200, "maximum_seconds": 120,
               "command_timeout_ms": 5000, "fixture_file_limit": 100,
               "full_performance_sample": False}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def _unalias(path: Path) -> None:
    for component in (path, *path.parents):
        # st_file_attributes is available on Windows before Path.is_junction.
        metadata = component.lstat()
        require(not stat.S_ISLNK(metadata.st_mode) and
                not (getattr(metadata, "st_file_attributes", 0) & 0x400),
                f"Evidence path traverses an alias: {path.name}.")


def _read_file(path: Path, limit: int) -> bytes:
    _unalias(path)
    require(path.is_file() and stat.S_ISREG(path.stat().st_mode),
            f"Evidence file is missing or not ordinary: {path.name}.")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(0 < len(data) <= limit, f"Evidence file exceeds its bound: {path.name}.")
    return data


def _json(data: bytes, label: str) -> dict:
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, f"Duplicate {label} JSON key: {key}.")
            value[key] = item
        return value
    try:
        value = json.loads(data.decode("utf-8-sig"), object_pairs_hook=unique)
    except (UnicodeError, ValueError) as error:
        raise EvidenceError(f"{label} is not bounded UTF-8 JSON.") from error
    require(type(value) is dict, f"{label} must be a JSON object.")
    return value


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _verify_large_file(root: Path, name: str, row: dict, remaining: int) -> None:
    path = root.joinpath(*name.split("/"))
    require(type(row["bytes"]) is int and 0 <= row["bytes"] <= remaining,
            "Preserved file exceeds the remaining aggregate byte bound.")
    _unalias(path)
    require(path.is_file() and stat.S_ISREG(path.stat().st_mode) and
            path.stat().st_size == row["bytes"],
            "Preserved file is missing, changed, or not ordinary.")
    hasher = hashlib.sha256()
    count = 0
    with path.open("rb") as stream:
        while chunk := stream.read(min(1024 * 1024, remaining - count + 1)):
            count += len(chunk)
            require(count <= row["bytes"], "Preserved file changed while reading.")
            hasher.update(chunk)
    require(count == row["bytes"] and row["sha256"] == hasher.hexdigest(),
            "Preserved file digest differs from the receipt.")


def _reference(value: object, filename: str, data: bytes, label: str) -> None:
    row = require_exact_keys(value, {"file", "bytes", "sha256"}, label)
    require(row["file"] == filename and type(row["bytes"]) is int and
            row["bytes"] == len(data) and row["sha256"] == _digest(data),
            f"{label} does not bind the preserved bytes.")


def _snapshot(value: object, label: str, *, final: bool, schema: int = 2) -> dict:
    fields = {"complete", "processes", "tasks", "owned_processes"}
    if final:
        fields.add("owned_tasks")
    row = require_exact_keys(value, fields, label)
    require(row["complete"] is True and all(type(row[key]) is list for key in fields - {"complete"}),
            f"{label} inventory is incomplete.")
    require(not row["owned_processes"] and (not final or not row["owned_tasks"]),
            f"{label} retains an owned process or task.")
    for key, binding in (("processes", "executable_path"), ("tasks", "definition_sha256")):
        known = set()
        require(len(row[key]) <= 20_000, f"{label} inventory exceeds its bound.")
        for item in row[key]:
            process = key == "processes" and schema == 3
            require(type(item) is dict and type(item.get("identity")) is str and
                    bool(item["identity"]) and
                    (process or (type(item.get(binding)) is str and bool(item[binding]))) and
                    item["identity"] not in known,
                    f"{label} has an unknown or duplicate {key} identity.")
            known.add(item["identity"])
            if binding == "definition_sha256":
                require(HEX64.fullmatch(item[binding]) is not None,
                        f"{label} task definition digest is invalid.")
    return row


def _subset(current: dict, frozen: dict, label: str) -> None:
    for key, binding in (("processes", "executable_path"), ("tasks", "definition_sha256")):
        prior = {row["identity"]: row[binding] for row in frozen[key]}
        require(all(prior.get(row["identity"]) == row[binding] for row in current[key]),
                f"{label} contains a new or changed {key} identity.")


def _reject_owned_entries(snapshot: dict, roots: dict, run_name: str) -> None:
    prefixes = tuple(row["path"].rstrip("\\").casefold() + "\\" for row in roots.values())
    require(not any((row.get("native_image_path") if row.get("kind") == "protected_pre_name"
                     else row["executable_path"]).casefold().startswith(prefixes)
                    for row in snapshot["processes"]) and
            not any(row["identity"].casefold() == ("\\" + run_name).casefold()
                    for row in snapshot["tasks"]),
            "Raw inventory retains an owned process or scheduled task.")


def _process_jobs(result: dict, task_kind: str, root: Path | None = None,
                  files: list[dict] | None = None) -> None:
    identities = set()
    starts = []

    def visit(value: object, depth: int = 0) -> None:
        require(depth <= 32, "Result process evidence exceeds its nesting bound.")
        if type(value) is list:
            for item in value:
                visit(item, depth + 1)
        elif type(value) is dict:
            if value.get("boundary") == "started" and "sha256" in value:
                starts.append(value)
            if value.get("process_lifecycle") is not None:
                lifecycle = value["process_lifecycle"]
                require(type(lifecycle) is dict and type(lifecycle.get("pid")) is int and
                        0 < lifecycle["pid"] <= 0xFFFFFFFF and
                        type(lifecycle.get("start_time_utc_ticks")) is str and
                        re.fullmatch(r"[1-9][0-9]{0,18}", lifecycle["start_time_utc_ticks"]) is not None,
                        "Result process lifecycle identity is unavailable.")
                identities.add((lifecycle["pid"], int(lifecycle["start_time_utc_ticks"])))
            for key, item in value.items():
                if key != "process_lifecycle":
                    visit(item, depth + 1)

    visit(result)
    if task_kind == "recovery":
        require(root is not None and files is not None and 1 <= len(starts) <= 14,
                "Recovery process-start references are missing or unbounded.")
        identities.clear()
        for reference in starts:
            require(type(reference.get("bytes")) is int and
                    0 < reference["bytes"] <= 1024 * 1024 and
                    type(reference.get("sha256")) is str and
                    HEX64.fullmatch(reference["sha256"]) is not None,
                    "Recovery process-start reference is invalid.")
            matches = [row for row in files if row["bytes"] == reference["bytes"] and
                       row["sha256"] == reference["sha256"]]
            require(len(matches) == 1, "Recovery process-start bytes are missing or ambiguous.")
            data = _read_file(root.joinpath(*matches[0]["file"].split("/")), 1024 * 1024)
            _reference(matches[0], matches[0]["file"], data, "Recovery process start")
            start = _json(data, "Recovery process start")
            binding = start.get("binding")
            require(start.get("boundary") == "started" and type(binding) is dict and
                    type(binding.get("pid")) is int and 0 < binding["pid"] <= 0xFFFFFFFF and
                    type(binding.get("start_time_utc_ticks")) is str and
                    re.fullmatch(r"[1-9][0-9]{0,18}", binding["start_time_utc_ticks"]) is not None,
                    "Recovery process-start identity is unavailable.")
            identity = (binding["pid"], int(binding["start_time_utc_ticks"]))
            require(identity not in identities, "Recovery repeats a process-start identity.")
            identities.add(identity)
    ledger = result.get("process_job_cleanup")
    if ledger == [] and task_kind == "core" and not identities:
        gui = result.get("gui")
        require(type(gui) is dict and gui.get("status") == "failed" and
                gui.get("job_cleanup") is True and gui.get("process_id") is None and
                "process_lifecycle" not in gui and gui.get("failure_reason") == "gui_error" and
                type(gui.get("error_detail")) is dict and
                set(gui["error_detail"]) == {"exception_type", "message", "native_error"},
                "Empty process ledger does not prove the process never started.")
        return
    require(bool(identities), "Result lacks raw process lifecycle identities.")
    verify_process_job_cleanup(ledger, expected_processes=sorted(identities))


def _roots(value: object, run_name: str) -> dict:
    roots = require_exact_keys(value, {"guest", "trusted"}, "Owned root records")
    for role, suffix in (("guest", ""), ("trusted", "-trusted")):
        row = require_exact_keys(roots[role],
                                 {"path", "base_file_id", "file_id", "owner_sid", "acl_sddl"},
                                 f"{role} root record")
        path = require_fixture_root(row["path"])
        require(path.lower().endswith("\\darkrenamervmruns\\" + (run_name + suffix).lower()) and
                HEX48.fullmatch(row["base_file_id"]) is not None and
                HEX48.fullmatch(row["file_id"]) is not None and
                row["owner_sid"] == "S-1-5-32-544" and
                type(row["acl_sddl"]) is str and 0 < len(row["acl_sddl"]) <= 16_384,
                f"{role} root identity or descriptor is unavailable.")
    require(roots["guest"]["base_file_id"] == roots["trusted"]["base_file_id"] and
            roots["guest"]["file_id"] != roots["trusted"]["file_id"],
            "Owned roots do not share the recorded base or have distinct identities.")
    return roots


def _source_sha(document: dict) -> object:
    product = document.get("product")
    return product.get("source_sha") if type(product) is dict else document.get("source_sha")


def _observer_finished(original: dict, result: dict, kind: str) -> None:
    if kind == "core":
        return
    process = require_exact_keys(original.get("observer_process"), {"state", "exit_code"},
                                 "Original observer termination")
    require(process["state"] == "exited" and type(process["exit_code"]) is int,
            "Original observer lifetime is not terminal.")
    ambiguous = {"execution_state_restore_failed", "desktop_lock_release_failed"}
    ambiguous.update({
        "runtime_cleanup_failed", "raw_cleanup_failed", "raw_cleanup_observation_failed",
    } if kind == "ui" else {
        "owned_process_cleanup_observation_failed", "journal_cleanup_observation_failed",
        "process_job_cleanup_failed", "runtime_cleanup_refused",
        "runtime_cleanup_observation_failed", "candidate_export_cleanup_observation_failed",
    })
    allowed = {"review_required", "failed", "environment_blocked", "unsupported", "not_run"}
    if kind == "recovery":
        allowed = {"passed", "failed"}
    require(result.get("status") in allowed and result.get("failure_reason") not in ambiguous,
            "Original observer result cannot establish desktop restoration or owned closure.")


def _setting_snapshot(value: dict, kind: str) -> None:
    if kind == "high-contrast":
        row = require_exact_keys(value, {"flags", "scheme", "colors", "visual_style"},
                                 "High Contrast settings")
        require(type(row["flags"]) is int and 0 <= row["flags"] <= 0xFFFFFFFF and
                (row["scheme"] is None or type(row["scheme"]) is str),
                "High Contrast flags or scheme are unavailable.")
        colors = require_exact_keys(row["colors"], {
            "window", "window_text", "button_face", "button_text", "highlight",
            "highlight_text", "gray_text", "hot_light",
        }, "High Contrast colors")
        require(all(type(color) is int and 0 <= color <= 0xFFFFFFFF for color in colors.values()),
                "High Contrast color observations are incomplete.")
        style = require_exact_keys(row["visual_style"], {"path", "color", "size"},
                                   "High Contrast visual style")
        require(all(type(item) is str and bool(item.strip()) and
                    not any(ord(unit) < 32 for unit in item) for item in style.values()) and
                len(style["path"]) <= 510 and
                re.match(r"^(?:[A-Za-z]:\\|\\\\)", style["path"]) is not None and
                len(style["color"]) <= 126 and len(style["size"]) <= 126,
                "High Contrast visual style is unavailable.")
    else:
        row = require_exact_keys(value, {
            "registry_key_existed", "registry_value_existed", "registry_value_kind",
            "registry_value", "ui_settings_raw_factor", "ui_settings_percent",
        }, "Text scale settings")
        require(type(row["registry_key_existed"]) is bool and
                type(row["registry_value_existed"]) is bool and
                row["registry_key_existed"],
                "Text scale registry presence is unavailable.")
        require(type(row["ui_settings_raw_factor"]) in (int, float) and
                math.isfinite(row["ui_settings_raw_factor"]) and
                1.0 <= row["ui_settings_raw_factor"] <= 2.25 and
                type(row["ui_settings_percent"]) is int and
                row["ui_settings_percent"] == round(row["ui_settings_raw_factor"] * 100),
                "Text scale UISettings observations are unavailable.")
        if not row["registry_value_existed"]:
            require(row["registry_value_kind"] is None and row["registry_value"] is None,
                    "Absent text scale value retains an unexplained registry observation.")
        else:
            kind_name, observed = row["registry_value_kind"], row["registry_value"]
            valid = (kind_name == "DWord" and type(observed) is int and
                     0 <= observed <= 0xFFFFFFFF)
            require(valid, "Text scale registry value kind or raw value is unknown.")


def verify_owned_performance_text_scale(observations: object) -> dict:
    """Verify actual coherent 100% registry/UISettings snapshots for the owned route."""
    require(type(observations) is dict, "Owned performance observations are unavailable.")
    proof = require_exact_keys(observations.get("text_scale_restoration"),
                               {"schema_version", "baseline", "final", "snapshot_equal"},
                               "Owned performance restoration")
    require(type(proof["schema_version"]) is int and proof["schema_version"] == 1 and
            proof["snapshot_equal"] is True,
            "Owned performance restoration is not terminal and equal.")
    fields = {"registry_key_existed", "registry_value_existed", "registry_value_kind",
              "registry_value", "ui_settings_raw_factor", "ui_settings_percent"}
    normalized = []
    for label in ("baseline", "final"):
        row = require_exact_keys(proof[label], fields, f"Owned performance {label}")
        require(type(row["registry_key_existed"]) is bool and
                type(row["registry_value_existed"]) is bool and
                (not row["registry_value_existed"] or row["registry_key_existed"]) and
                type(row["ui_settings_raw_factor"]) is float and
                math.isfinite(row["ui_settings_raw_factor"]) and
                abs(row["ui_settings_raw_factor"] - 1.0) < 0.000001 and
                type(row["ui_settings_percent"]) is int and
                row["ui_settings_percent"] == round(row["ui_settings_raw_factor"] * 100) == 100,
                f"Owned performance {label} effective text scale is incoherent.")
        if row["registry_value_existed"]:
            require(row["registry_value_kind"] == "DWord" and
                    type(row["registry_value"]) is int and row["registry_value"] == 100,
                    f"Owned performance {label} registry text scale is not DWord 100.")
        else:
            require(row["registry_value_kind"] is None and row["registry_value"] is None,
                    f"Owned performance {label} registry absence was not observed.")
        normalized.append(row)
    before, after = normalized
    require(all(before[key] == after[key] for key in fields - {"ui_settings_raw_factor"}) and
            abs(before["ui_settings_raw_factor"] - after["ui_settings_raw_factor"]) < 0.000001,
            "Owned performance text scale differs after the workload.")
    return proof


def _owned_performance_predelete(root: Path, original: dict, receipt: dict,
                                 proof: dict, indexed: dict[str, dict],
                                 receipt_bytes: bytes, signal_bytes: bytes,
                                 lease_bytes: bytes) -> None:
    path = root / "owned-performance-predelete.json"
    require(path.exists(), "Owned performance pre-delete receipt is missing.")
    data = _read_file(path, 64 * 1024)
    frozen = require_exact_keys(_json(data, "Owned performance pre-delete receipt"), {
        "schema_version", "kind", "run_name", "run_id", "vm_id", "nonce",
        "desktop_lease_id", "source_sha", "bundle_sha256", "profile_id",
        "profile_sha256", "roots", "files",
    }, "Owned performance pre-delete receipt")
    context = original["owned_cleanup_failure_context"]
    run_id = frozen["run_id"]
    match = OWNED_PERFORMANCE_RUN.fullmatch(run_id) if type(run_id) is str else None
    picker = run_id == PICKER_RUN_ID
    require(frozen["schema_version"] == 1 and
            frozen["kind"] == "owned_performance_predelete_restoration" and (match is not None or picker) and
            frozen["run_name"] == receipt["run_name"] and
            frozen["vm_id"] == receipt["vm_id"] and
            frozen["nonce"] == receipt["nonce"] and
            frozen["desktop_lease_id"] == receipt["desktop_lease_id"] and
            frozen["source_sha"] == context["source_sha"] and
            frozen["bundle_sha256"] == context["bundle"]["sha256"] and
            frozen["profile_id"] == V2_PROFILE_ID and
            frozen["profile_sha256"] == OWNED_PERFORMANCE_PROFILE_SHA256 and
            frozen["roots"] == receipt["root_records"] and
            proof["predelete_sha256"] == _digest(data),
            "Owned performance pre-delete identity or proof hash differs.")
    required = ("original-transport.json", "acceptance-result.json",
                "acceptance-observations.json", "owned-performance-input-manifest.json",
                "owned-performance-profile.json", "bundle.json")
    require(all(name in indexed for name in required),
            "Owned performance frozen source files are missing.")
    expected = {name: indexed[name] for name in required}
    for name, blob in (("owned-cleanup-strict-failure-preservation.json", receipt_bytes),
                       ("owned-cleanup-desktop-closed.json", signal_bytes),
                       ("desktop-lease.json", lease_bytes)):
        expected[name] = {"file": name, "bytes": len(blob), "sha256": _digest(blob)}
    require(type(frozen["files"]) is dict and set(frozen["files"]) == set(expected) and
            all(require_exact_keys(frozen["files"][name], {"file", "bytes", "sha256"}, name)
                == row for name, row in expected.items()) and
            context["source_result"] == expected["acceptance-result.json"] and
            receipt["original_transport"] == expected["original-transport.json"],
            "Owned performance pre-delete file bindings differ.")
    def document(name: str) -> dict:
        return _json(_read_file(root / name, 4 * 1024 * 1024), name)
    manifest = document("owned-performance-input-manifest.json")
    profile = document("owned-performance-profile.json")
    result = document("acceptance-result.json")
    observations = document("acceptance-observations.json")
    require(expected["owned-performance-profile.json"]["sha256"] ==
            OWNED_PERFORMANCE_PROFILE_SHA256 and
            profile.get("schema") == "darkrenamer-vm-automated-profile-v3" and
            profile.get("profile_id") == V2_PROFILE_ID and profile.get("revision") == 3 and
            manifest.get("run_id") == observations.get("run_id") == run_id and
            manifest.get("source_sha") == result.get("source_sha") == frozen["source_sha"] and
            manifest.get("acceptance_profile_id") == V2_PROFILE_ID and
            manifest.get("acceptance_profile_sha256") == OWNED_PERFORMANCE_PROFILE_SHA256 and
            manifest.get("acceptance_profile", {}).get("sha256") ==
                OWNED_PERFORMANCE_PROFILE_SHA256 and
            manifest.get("bundle_manifest", {}).get("sha256") == frozen["bundle_sha256"] and
            manifest.get("request", {}).get("mode") ==
                ("picker-identity-observation" if picker else "performance-sample") and
            context.get("acceptance_mode") == manifest.get("request", {}).get("mode") and
            ((manifest.get("request", {}).get("picker_identity_plan") == PICKER_PLAN and
              "performance_plan" not in manifest.get("request", {})) if picker else
             manifest.get("request", {}).get("performance_plan", {}).get("long_path_order") ==
                match.group(1)) and
            result.get("application", {}).get("sha256") ==
                manifest.get("artifacts", {}).get("application", {}).get("sha256") and
            result.get("observations", {}).get("sha256") ==
                expected["acceptance-observations.json"]["sha256"] and
            result.get("acceptance_observations") == observations,
            "Owned performance frozen input, profile, result, or observations differ.")
    verify_owned_performance_text_scale(observations)


def _restoration(root: Path, result: dict, context: dict, listed: set[str]) -> None:
    if context["task_kind"] != "ui":
        return
    for kind, required in (("high-contrast", context["high_contrast_requested"]),
                           ("text-scale", context["acceptance_mode"] == "text-scale")):
        if not required:
            continue
        name = "high-contrast-restore.json" if kind == "high-contrast" else "text-scale-snapshot.json"
        require(name in listed, f"Required {kind} restoration document is missing.")
        data = _read_file(root / name, 1024 * 1024)
        snapshot = require_exact_keys(_json(data, f"{kind} restoration"), {
            "schema_version", "source_sha", "acceptance_script_sha256",
            "restoration_required", "restoration_verified", "original", "restored",
        }, f"{kind} restoration")
        expected_schema = 2 if kind == "high-contrast" else 1
        require(type(snapshot["schema_version"]) is int and
                snapshot["schema_version"] == expected_schema and
                snapshot["source_sha"] == context["source_sha"] and
                snapshot["acceptance_script_sha256"] == context["observer_sha256"] and
                snapshot["restoration_required"] is (kind == "text-scale") and
                snapshot["restoration_verified"] is True and
                type(snapshot["original"]) is dict and type(snapshot["restored"]) is dict,
                f"{kind} restoration observation is incomplete or unbound.")
        original, restored = dict(snapshot["original"]), dict(snapshot["restored"])
        _setting_snapshot(original, kind)
        _setting_snapshot(restored, kind)
        if kind == "high-contrast":
            require((original.get("scheme") or "") == (restored.get("scheme") or ""),
                    "High Contrast scheme was not restored.")
            restored["scheme"] = original.get("scheme")
        else:
            before, after = original.get("ui_settings_raw_factor"), restored.get("ui_settings_raw_factor")
            require(type(before) in (int, float) and type(after) in (int, float) and
                    abs(before - after) < 0.000001,
                    "Text scale factor was not restored.")
            restored["ui_settings_raw_factor"] = before
        require(original == restored, f"{kind} settings differ after restoration.")
        reference = (result.get("high_contrast") if kind == "high-contrast" else
                     result.get("text_scale"))
        rescue_name = kind + "-rescue-result.json"
        if rescue_name in listed:
            rescue = _json(_read_file(root / rescue_name, 1024 * 1024), f"{kind} rescue")
            require(rescue.get("status") == "passed" and
                    rescue.get("restoration_verified") is True and
                    rescue.get("source_sha") == context["source_sha"] and
                    rescue.get("acceptance_script_sha256") == context["observer_sha256"] and
                    rescue.get("snapshot_sha256") == _digest(data),
                    f"{kind} rescue does not bind restored state.")
        else:
            require(type(reference) is dict and type(reference.get("snapshot")) is dict and
                    reference["snapshot"].get("file") == name and
                    reference["snapshot"].get("sha256") == _digest(data),
                    f"{kind} result does not bind the copied restoration document.")


def _source_result(root: Path, original: dict, receipt: dict,
                   listed: set[str]) -> tuple[dict, dict]:
    raw_context = original.get("owned_cleanup_failure_context")
    bounded_ui = (type(raw_context) is dict and raw_context.get("task_kind") == "ui" and
                  raw_context.get("acceptance_mode") in
                  ("appearance-pair", "performance-sample", "first-clear-observation"))
    context = require_exact_keys(raw_context, {
        "failed_snapshot", "root_records", "source_result", "bundle", "source_sha",
        "observer_sha256", "acceptance_mode", "high_contrast_requested",
        "output_preservation_verified", "task_kind",
    } | ({"acceptance_text_scale_percent"} if bounded_ui else set()), "Original failure context")
    require(context["failed_snapshot"] == receipt["failed_snapshot"] and
            context["root_records"] == receipt["root_records"] and
            context["task_kind"] == original.get("task_kind") and
            context["task_kind"] in ("core", "ui", "recovery") and
            context["output_preservation_verified"] is True and
            type(context["source_sha"]) is str and
            re.fullmatch(r"[0-9a-f]{40}", context["source_sha"]) is not None,
            "Frozen inventory, root creation, or output preservation differs from the original failure.")
    source = require_exact_keys(context["source_result"], {"file", "bytes", "sha256"},
                                "Original source result")
    result_name = source["file"]
    expected = {"core": "original-result.json", "ui": "acceptance-result.json"}
    require(type(result_name) is str and result_name in listed and
            (result_name == expected[context["task_kind"]] if context["task_kind"] != "recovery"
             else bool(re.fullmatch(r"[^/]+/summary\.json", result_name))),
            "Copied source result is unavailable.")
    result_data = _read_file(root.joinpath(*result_name.split("/")), 8 * 1024 * 1024)
    _reference(source, result_name, result_data, "Original source result")
    bundle_reference = require_exact_keys(context["bundle"], {"file", "bytes", "sha256"},
                                          "Source bundle reference")
    require(bundle_reference["file"] == "bundle.json", "Source bundle path differs.")
    frozen_here = context["task_kind"] == "core" or "bundle.json" in listed
    bundle_path = root / "bundle.json" if frozen_here else root.parent / "bundle.json"
    require(frozen_here or not (root / "bundle.json").exists(),
            "Unlisted output bundle conflicts with the historical parent layout.")
    bundle_data = _read_file(bundle_path, 4 * 1024 * 1024)
    _reference(context["bundle"], "bundle.json", bundle_data, "Source bundle")
    result = _json(result_data, "Original source result")
    bundle = _json(bundle_data, "Source bundle")
    require(_source_sha(result) == _source_sha(bundle) == context["source_sha"],
            "Copied result, bundle, and source commit differ.")
    _observer_finished(original, result, context["task_kind"])
    _process_jobs(result, context["task_kind"], root, receipt["files"])
    if context["task_kind"] != "core":
        require(type(context["observer_sha256"]) is str and
                HEX64.fullmatch(context["observer_sha256"]) is not None,
                "Copied observer digest is unavailable.")
        if context["task_kind"] == "ui":
            require(context["observer_sha256"] == result.get("acceptance_script_sha256"),
                    "Copied acceptance observer differs from the original context.")
        else:
            observer = result.get("observer")
            require(type(observer) is dict and observer.get("sha256") == context["observer_sha256"],
                    "Copied recovery observer differs from the original context.")
    require(type(context["high_contrast_requested"]) is bool and
            (context["acceptance_mode"] in
             ("current-dpi", "full-context", "standard", "text-scale", "tooltip") or
             (context["acceptance_mode"] in
              ("appearance-pair", "performance-sample", "first-clear-observation") and
              type(context["acceptance_text_scale_percent"]) is int and
              context["acceptance_text_scale_percent"] == 100 and
              context["high_contrast_requested"] is False)
             if context["task_kind"] == "ui" else context["acceptance_mode"] is None),
            "Original acceptance mode is unavailable.")
    _restoration(root, result, context, listed)
    return result, bundle


def _v2_finalizer_inventory(frozen: dict, before: dict, after: dict,
                            raw: dict, roots: dict, run_name: str, *, schema: int = 2,
                            final_anchor: dict | None = None) -> None:
    evidence = raw["owned_resource_evidence"]
    sid, session = evidence["runner_sid"], evidence["runner_session_id"]
    baseline_tasks = _v2_task_rows(evidence["baseline_tasks"], "V2 baseline")
    identities: dict[int, dict] = {}
    for label, snapshot in (("frozen", frozen), ("before", before), ("after", after)):
        require(_v2_task_rows(snapshot["tasks"], f"V2 finalizer {label}") == baseline_tasks,
                f"V2 finalizer {label} task definition changed.")
        rows = (_v3_process_rows(snapshot["processes"], sid, session,
                                 f"V2 finalizer {label}", final_anchor)
                if schema == 3 else
                _v2_process_rows(snapshot["processes"], sid, session, f"V2 finalizer {label}"))
        for row in rows.values():
            prior = identities.get(row["pid"])
            require(prior is None or prior == row,
                    "V2 finalizer process lifetime changed or PID was reused.")
            identities[row["pid"]] = row
    owned_starts: dict[int, list[int]] = {}
    lifetimes = [*evidence["declared_processes"], evidence["preflight_child"],
                 evidence["engine_child"], evidence["task_execution"]["observer_lifecycle"],
                 *(row["task_execution"]["observer_lifecycle"]
                   for row in evidence["rescue_executions"])]
    for lifetime in lifetimes:
        owned_starts.setdefault(lifetime["pid"], []).append(int(lifetime["start_time_utc_ticks"]))
    paths = tuple(row["path"].casefold() for row in roots.values())
    for row in identities.values():
        scope = ((row["native_image_path"] if schema == 3 and
                  row["kind"] == "protected_pre_name" else
                  row["executable_path"] + " " + row["command_line"])).casefold()
        require(not _v2_matches_owned_lifetime(row, owned_starts) and
                run_name.casefold() not in scope and not any(path in scope for path in paths),
                "V2 finalizer retained a protected process scope.")


def verify_preserved_owned_cleanup(root: Path | str, *, profile_id: str = V1_PROFILE_ID,
                                   profile_sha256: str | None = None) -> dict[str, str]:
    """Verify a failed run directly; never turn strict environment failure into acceptance."""
    root = Path(root)
    require(root.is_dir() and not root.is_symlink(), "Owned cleanup evidence root is unavailable.")
    original_bytes = _read_file(root / "original-transport.json", 4 * 1024 * 1024)
    receipt_bytes = _read_file(root / "owned-cleanup-strict-failure-preservation.json", 1024 * 1024)
    proof_bytes = _read_file(root / "owned-cleanup-after-strict-failure.json", 1024 * 1024)
    signal_bytes = _read_file(root / "owned-cleanup-desktop-closed.json", 64 * 1024)
    lease_path = root / "desktop-lease.json"
    if not lease_path.is_file():
        lease_path = root.parent / "desktop-lease.json"
    lease_bytes = _read_file(lease_path, 64 * 1024)
    original = _json(original_bytes, "Original transport")
    v2 = profile_id == V2_PROFILE_ID
    schema = (2 if profile_sha256 == HISTORICAL_V2_PROFILE_SHA256 else 3) if v2 else 1
    possible_owned_performance = v2 and profile_sha256 == OWNED_PERFORMANCE_PROFILE_SHA256
    require(v2 or profile_id == V1_PROFILE_ID, "Unknown VM cleanup profile.")
    profile_fields = {"profile_id", "profile_sha256"} if v2 else set()
    receipt = require_exact_keys(_json(receipt_bytes, "Preservation receipt"), {
        "schema_version", "kind", "run_name", "vm_id", "nonce", "desktop_lease_id", "original_transport",
        "files", "failed_snapshot", "root_records",
    } | profile_fields, "Preservation receipt")
    proof = require_exact_keys(_json(proof_bytes, "Owned cleanup proof"), {
        "schema_version", "kind", "run_name", "vm_id", "status", "pre", "post", "roots",
        "observed_roots_before", "observed_roots_after", "errors", "preservation_sha256",
        "desktop_lease_sha256", "original_transport_sha256", "nonce",
    } | profile_fields | ({"protected_anchor"} if schema == 3 else set()) |
        ({"predelete_sha256"} if possible_owned_performance and
         "predelete_sha256" in _json(proof_bytes, "Owned cleanup proof") else set()),
        "Owned cleanup proof")
    signal = require_exact_keys(_json(signal_bytes, "Desktop closure signal"), {
        "schema_version", "nonce", "preservation_sha256", "desktop_lease_sha256",
    } | profile_fields, "Desktop closure signal")
    lease = _json(lease_bytes, "Desktop lease")
    require(all(type(document["schema_version"]) is int and
                document["schema_version"] == schema
                for document in (receipt, proof, signal)) and
            receipt["kind"] == "owned_cleanup_strict_failure_preservation" and
            proof["kind"] == "owned_cleanup_after_strict_failure" and
            type(receipt["run_name"]) is str and RUN.fullmatch(receipt["run_name"]) is not None and
            proof["run_name"] == receipt["run_name"] and
            type(receipt["vm_id"]) is str and
            re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", receipt["vm_id"]) is not None and
            proof["vm_id"] == receipt["vm_id"] == original.get("vm_id") and
            type(receipt["nonce"]) is str and HEX32.fullmatch(receipt["nonce"]) is not None and
            type(receipt["desktop_lease_id"]) is str and
            HEX32.fullmatch(receipt["desktop_lease_id"]) is not None and
            proof["nonce"] == signal["nonce"] == receipt["nonce"],
            "Owned cleanup run, VM, or nonce binding differs.")
    if v2:
        require(type(profile_sha256) is str and HEX64.fullmatch(profile_sha256) is not None and
                all(document["profile_id"] == V2_PROFILE_ID and
                    document["profile_sha256"] == profile_sha256
                    for document in (receipt, proof, signal)) and
                type(original.get("raw_cleanup")) is dict and
                original["raw_cleanup"].get("profile_id") == V2_PROFILE_ID and
                original["raw_cleanup"].get("profile_sha256") == profile_sha256,
                "V2 preserved cleanup is not bound to the selected profile bytes.")
    _reference(receipt["original_transport"], "original-transport.json", original_bytes,
               "Original transport reference")
    require(proof["original_transport_sha256"] == _digest(original_bytes) and
            proof["preservation_sha256"] == signal["preservation_sha256"] == _digest(receipt_bytes) and
            proof["desktop_lease_sha256"] == signal["desktop_lease_sha256"] == _digest(lease_bytes) and
            lease.get("mode") == "managed-rdp" and lease.get("stop_status") == "stopped" and
            lease.get("cleanup_observed") is True and
            lease.get("lease_id") == receipt["desktop_lease_id"],
            "Owned cleanup evidence or desktop closure hash differs.")
    require(original.get("status") == "failed" and original.get("guest_cleanup") is False and
            type(original.get("raw_cleanup")) is dict, "Original strict failure is unavailable.")
    raw = original["raw_cleanup"]
    if v2:
        _verify_v2_owned_resources(raw, profile_sha256=profile_sha256,
                                   deleted=False, schema=schema)
        require(raw.get("scheduled_task_present") is False and
                raw.get("guest_root_present") is True and
                raw.get("trusted_task_root_present") is True and
                raw.get("process_jobs_closed") is True and
                raw.get("owned_processes_after") == [] and
                raw.get("terminated_runner_processes") == [],
                "Original V2 failure was rewritten or retained an owned resource.")
    else:
        for key, binding in (("unexpected_runner_tasks", "definition_sha256"),
                             ("unexpected_runner_tasks_after_intervention", "definition_sha256"),
                             ("unexpected_runner_processes", "executable_path"),
                             ("unexpected_runner_processes_after_intervention", "executable_path")):
            rows = raw.get(key)
            require(type(rows) is list and all(
                type(row) is dict and type(row.get("identity")) is str and row["identity"] and
                type(row.get(binding)) is str and row[binding] for row in rows),
                f"Original strict failure has an unknown {key} identity or binding.")
        require(raw.get("unexpected_runner_tasks_after_delete") is None and
                raw.get("unexpected_runner_processes_after_delete") is None and
                raw.get("scheduled_task_present") is False and
                raw.get("guest_root_present") is True and
                raw.get("trusted_task_root_present") is True and
                raw.get("process_jobs_closed") is True and
                raw.get("runner_process_inventory_complete") is True and
                raw.get("owned_processes_after") == [] and
                raw.get("removed_runner_tasks") == [] and
                raw.get("terminated_runner_processes") == [] and
                raw.get("resource_cleanup_errors") == [] and
                type(raw.get("runner_process_natural_exit")) is dict and
                any(bool(raw[key]) for key in (
                    "unexpected_runner_tasks", "unexpected_runner_processes",
                    "unexpected_runner_tasks_after_intervention",
                    "unexpected_runner_processes_after_intervention")),
                "Original strict OS failure was rewritten or is not classified.")
    files = receipt["files"]
    require(type(files) is list and 1 <= len(files) <= 1024,
            "Preserved file inventory is unavailable or oversized.")
    listed = set()
    total = 0
    for item in files:
        row = require_exact_keys(item, {"file", "bytes", "sha256"}, "Preserved file")
        name = row["file"]
        require(type(name) is str and name not in listed and
                PurePosixPath(name).as_posix() == name and
                all(part not in ("", ".", "..") for part in name.split("/")) and
                "\\" not in name and not name.startswith("/"),
                "Preserved file path is aliased or duplicated.")
        listed.add(name)
        _verify_large_file(root, name, row, 512 * 1024 * 1024 - total)
        total += row["bytes"]
    require(total <= 512 * 1024 * 1024 and "original-transport.json" in listed,
            "Preserved files exceed their bound or omit the original transport.")
    result, bundle = _source_result(root, original, receipt, listed)
    if possible_owned_performance:
        context = original["owned_cleanup_failure_context"]
        embedded = result.get("acceptance_observations")
        run_id = embedded.get("run_id") if type(embedded) is dict else None
        candidate = (context["acceptance_mode"] in {"performance-sample", "picker-identity-observation"} or
                     type(run_id) is str and
                     run_id.startswith("performance-sample-v2-owned-r3-") or run_id == PICKER_RUN_ID or
                     any(name.startswith("owned-performance-") for name in listed) or
                     "predelete_sha256" in proof or
                     (root / "owned-performance-predelete.json").exists())
        if candidate:
            require(type(run_id) is str and
                    ((context["acceptance_mode"] == "performance-sample" and
                      OWNED_PERFORMANCE_RUN.fullmatch(run_id) is not None) or
                     (context["acceptance_mode"] == "picker-identity-observation" and
                      run_id == PICKER_RUN_ID)) and
                    "predelete_sha256" in proof,
                    "Owned performance route lacks its frozen restoration gate.")
            _owned_performance_predelete(root, original, receipt, proof,
                                         {row["file"]: row for row in files},
                                         receipt_bytes, signal_bytes, lease_bytes)
    if schema == 3:
        source = (bundle["harness"]["source_sha"] if bundle["schema_version"] == 2
                  else bundle["source_sha"])
        verify_current_protected_anchor_binding(
            original, source_sha=source,
            bundle_sha256=original["owned_cleanup_failure_context"]["bundle"]["sha256"])
    if v2:
        require(result.get("process_job_cleanup") ==
                raw["owned_resource_evidence"]["process_job_cleanup"] and
                result.get("observer_lifecycle") ==
                raw["owned_resource_evidence"]["task_execution"]["observer_lifecycle"],
                "V2 preserved cleanup lifetimes differ from the original result.")
        for rescue in raw["owned_resource_evidence"]["rescue_executions"]:
            name = rescue["result_file"]
            require(name in listed, "V2 rescue output is missing from the preserved inventory.")
            data = _read_file(root / name, 4 * 1024 * 1024)
            require(_digest(data) == rescue["result_sha256"],
                    "V2 rescue output differs from its execution receipt.")
            document = _json(data, "V2 rescue result")
            require(document.get("status") == "passed" and
                    document.get("observer_lifecycle") ==
                    rescue["task_execution"]["observer_lifecycle"],
                    "V2 rescue result is unbound to its exact task lifetime.")
    frozen = _snapshot(receipt["failed_snapshot"], "Frozen failure", final=False, schema=schema)
    roots = _roots(receipt["root_records"], receipt["run_name"])
    require(proof["roots"] == roots, "Finalizer root records differ from creation.")
    observed = require_exact_keys(proof["observed_roots_before"], {"guest", "trusted"},
                                  "Observed roots before deletion")
    for role in ("guest", "trusted"):
        require(type(observed[role]) is dict and observed[role] == {
            **roots[role], "ordinary_directory": True},
            f"{role} root was replaced, reparse, or changed its descriptor.")
    before = _snapshot(proof["pre"], "Finalizer pre-inventory", final=True, schema=schema)
    after = _snapshot(proof["post"], "Finalizer post-inventory", final=True, schema=schema)
    for inventory in (frozen, before, after):
        _reject_owned_entries(inventory, roots, receipt["run_name"])
    if v2:
        require(raw["owned_resource_evidence"]["root_records"] == roots,
                "V2 root creation differs from the original raw evidence.")
        final_anchor = None
        if schema == 3:
            evidence = raw["owned_resource_evidence"]
            final_anchor = _v3_anchor(proof["protected_anchor"],
                                      name=receipt["run_name"], sid=evidence["runner_sid"],
                                      session=evidence["runner_session_id"],
                                      profile_sha256=profile_sha256, closed=True)
            held_anchor = evidence["protected_anchor"]
            require(all(final_anchor[key] == held_anchor[key] for key in (
                "run_name", "vm_id", "source_sha", "bundle_sha256", "profile_sha256",
                "anchor_nonce", "pre_name_utc", "pre_name_snapshot", "anchor_present")),
                "Finalizer protected anchor differs from its original held context.")
            if final_anchor["anchor_present"]:
                require(all(final_anchor["proof"][key] == held_anchor["proof"][key]
                            for key in held_anchor["proof"] if key not in (
                                "handle_closed", "parent_handle_closed", "child_path_closed",
                                "parent_path_closed", "accepted_snapshot_count")),
                        "Finalizer protected lifetime changed after original preservation.")
                require(final_anchor["proof"]["accepted_snapshot_count"] >=
                        held_anchor["proof"]["accepted_snapshot_count"] + 2,
                        "Finalizer did not recheck the held protected lifetime in both inventories.")
        _v2_finalizer_inventory(frozen, before, after, raw, roots, receipt["run_name"],
                                schema=schema, final_anchor=final_anchor)
    else:
        _subset(before, frozen, "Finalizer pre-inventory")
        _subset(after, frozen, "Finalizer post-inventory")
    presence = require_exact_keys(proof["observed_roots_after"],
                                  {"guest_present", "trusted_present"}, "Observed roots after deletion")
    require(presence == {"guest_present": False, "trusted_present": False} and
            proof["errors"] == [] and proof["status"] == "owned-clean",
            "Owned roots or task/process resources remain after finalization.")
    return {"environment": "strict-failed", "owned_cleanup": "owned-clean",
            "acceptance": "rejected"}
