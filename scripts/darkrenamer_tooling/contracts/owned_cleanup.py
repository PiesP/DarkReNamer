"""Independent verifier for a preserved strict VM failure and its owned cleanup."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat

from darkrenamer_tooling.contracts.platform import require_fixture_root
from darkrenamer_tooling.campaign.planning import verify_process_job_cleanup
from darkrenamer_tooling.evidence.archive import EvidenceError, require_exact_keys


HEX32 = re.compile(r"[0-9a-f]{32}\Z")
HEX48 = re.compile(r"[0-9a-f]{48}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
RUN = re.compile(r"DarkReNamerTests-[0-9a-f]{32}\Z")


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


def _snapshot(value: object, label: str, *, final: bool) -> dict:
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
            require(type(item) is dict and type(item.get("identity")) is str and
                    bool(item["identity"]) and type(item.get(binding)) is str and
                    bool(item[binding]) and item["identity"] not in known,
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
    require(not any(row["executable_path"].casefold().startswith(prefixes)
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
        require(snapshot["schema_version"] == expected_schema and
                snapshot["source_sha"] == context["source_sha"] and
                snapshot["acceptance_script_sha256"] == context["observer_sha256"] and
                snapshot["restoration_required"] is (kind == "text-scale") and
                snapshot["restoration_verified"] is True and
                type(snapshot["original"]) is dict and type(snapshot["restored"]) is dict,
                f"{kind} restoration observation is incomplete or unbound.")
        original, restored = dict(snapshot["original"]), dict(snapshot["restored"])
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


def _source_result(root: Path, original: dict, receipt: dict, listed: set[str]) -> None:
    context = require_exact_keys(original.get("owned_cleanup_failure_context"), {
        "failed_snapshot", "root_records", "source_result", "bundle", "source_sha",
        "observer_sha256", "acceptance_mode", "high_contrast_requested",
        "output_preservation_verified", "task_kind",
    }, "Original failure context")
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
    bundle_root = root if context["task_kind"] == "core" else root.parent
    bundle_data = _read_file(bundle_root / "bundle.json", 4 * 1024 * 1024)
    _reference(context["bundle"], "bundle.json", bundle_data, "Source bundle")
    result = _json(result_data, "Original source result")
    bundle = _json(bundle_data, "Source bundle")
    require(_source_sha(result) == _source_sha(bundle) == context["source_sha"],
            "Copied result, bundle, and source commit differ.")
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
             ("current-dpi", "full-context", "standard", "text-scale", "tooltip")
             if context["task_kind"] == "ui" else context["acceptance_mode"] is None),
            "Original acceptance mode is unavailable.")
    _restoration(root, result, context, listed)


def verify_preserved_owned_cleanup(root: Path | str) -> dict[str, str]:
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
    receipt = require_exact_keys(_json(receipt_bytes, "Preservation receipt"), {
        "schema_version", "kind", "run_name", "vm_id", "nonce", "desktop_lease_id", "original_transport",
        "files", "failed_snapshot", "root_records",
    }, "Preservation receipt")
    proof = require_exact_keys(_json(proof_bytes, "Owned cleanup proof"), {
        "schema_version", "kind", "run_name", "vm_id", "status", "pre", "post", "roots",
        "observed_roots_before", "observed_roots_after", "errors", "preservation_sha256",
        "desktop_lease_sha256", "original_transport_sha256", "nonce",
    }, "Owned cleanup proof")
    signal = require_exact_keys(_json(signal_bytes, "Desktop closure signal"), {
        "schema_version", "nonce", "preservation_sha256", "desktop_lease_sha256",
    }, "Desktop closure signal")
    lease = _json(lease_bytes, "Desktop lease")
    require(receipt["schema_version"] == proof["schema_version"] == signal["schema_version"] == 1 and
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
    _source_result(root, original, receipt, listed)
    frozen = _snapshot(receipt["failed_snapshot"], "Frozen failure", final=False)
    roots = _roots(receipt["root_records"], receipt["run_name"])
    require(proof["roots"] == roots, "Finalizer root records differ from creation.")
    observed = require_exact_keys(proof["observed_roots_before"], {"guest", "trusted"},
                                  "Observed roots before deletion")
    for role in ("guest", "trusted"):
        require(type(observed[role]) is dict and observed[role] == {
            **roots[role], "ordinary_directory": True},
            f"{role} root was replaced, reparse, or changed its descriptor.")
    before = _snapshot(proof["pre"], "Finalizer pre-inventory", final=True)
    after = _snapshot(proof["post"], "Finalizer post-inventory", final=True)
    for inventory in (frozen, before, after):
        _reject_owned_entries(inventory, roots, receipt["run_name"])
    _subset(before, frozen, "Finalizer pre-inventory")
    _subset(after, frozen, "Finalizer post-inventory")
    presence = require_exact_keys(proof["observed_roots_after"],
                                  {"guest_present", "trusted_present"}, "Observed roots after deletion")
    require(presence == {"guest_present": False, "trusted_present": False} and
            proof["errors"] == [] and proof["status"] == "owned-clean",
            "Owned roots or task/process resources remain after finalization.")
    return {"environment": "strict-failed", "owned_cleanup": "owned-clean",
            "acceptance": "rejected"}
