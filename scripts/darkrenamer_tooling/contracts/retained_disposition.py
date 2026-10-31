"""Issue 236: immutable target validation for a separately admitted root disposition.

This reader has no filesystem mutation or VM transport capability. The pinned
originals identify one failed run; a caller cannot substitute a convenient run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import sys

from darkrenamer_tooling.evidence.errors import EvidenceError


ORIGINAL_TRANSPORT_SHA256 = "eae10bc051efaace0f2de7f4d25a4ea0a413adb44c4cd226e746b6226858312c"
ORIGINAL_PRESERVATION_SHA256 = "a02ae4237ca0c0b3887117ace9498c04fea788af07f6b4e53827dcc312ff6226"
ORIGINAL_PROFILE_SHA256 = "11ce058fdbb51614ac519fabe37fa587fde284fcba4e76ea5e423570243c494f"
ORIGINAL_BUNDLE_SHA256 = "e01797d6dfaa69f989565eb3afdbc2d2da4708b98c2e24ccbd4df1ce5fd3ced6"
ORIGINAL_SOURCE_SHA = "4fb282cd357fca8f7eecc4c8d97fa803f1ca68be"
ORIGINAL_RUN_ID = "gui-apply-feedback-v1-owned-r3-1366x768-96-text100-success-10000"
# SHA-256 of the length-prefixed, UTF-8 authority tuple below. The verified
# originals supply private identity fields; this pin prevents substitution.
ORIGINAL_AUTHORITY_SHA256 = "c5ee37c55a8dc80020d0781de62b424148da968f36e2a9c0d6e35184e220129b"
ORIGINAL_EXTRA_FILES = {
    "owned-cleanup-desktop-closed.json": "2f5efbd0c83e33fb08bb65cc6f5268a2345817c5641d213932b2d66505302049",
    "desktop-lease.json": "fb039b93500295bac05c6b15043cdf753083af57325d38e176c1f90c5736c145",
    "owned-performance-predelete.json": "844a6d9441221e6d64ef4f50c54be74ba2d8da3beb11768ce1dd36eadcea58df",
    "desktop-stop-response.json": "6406f08bf3ffbbeb7fd3a72e0cfa6b36d51b8a36d942c902e419033ca5209f3a",
}
MAX_ORIGINAL_BYTES = 512 * 1024 * 1024
MAX_ORIGINAL_ENTRIES = 1024
ROOT_KEYS = ("guest", "trusted")
FILE_ID = re.compile(r"[0-9a-f]{48}\Z")
VM_ID = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\Z")
RUN_NAME = re.compile(r"DarkReNamerTests-[0-9a-f]{32}\Z")
# Deliberately unset until the complete current index has been reviewed and a
# concrete exact-run classification has been bound by a source change.
REVIEWED_CLASSIFICATION_SHA256: str | None = None


def _require(value: bool, message: str) -> None:
    if not value:
        raise EvidenceError(message)


def authority_digest(vm_id: str, run_name: str, roots: dict) -> str:
    """SHA-256 over schema, source, profile, bundle, VM, run ID/name, then
    guest and trusted path/base ID/root ID/owner/SDDL, in that exact order.
    Each strict UTF-8 field has a four-byte big-endian length prefix; the fixed
    domain prefix ends in NUL. Fields themselves must contain no NUL.
    """
    fields = ["1", ORIGINAL_SOURCE_SHA, ORIGINAL_PROFILE_SHA256,
              ORIGINAL_BUNDLE_SHA256, vm_id, ORIGINAL_RUN_ID, run_name]
    _require(type(roots) is dict and set(roots) == set(ROOT_KEYS),
             "Original authority root roles are incomplete.")
    for role in ROOT_KEYS:
        row = roots[role]
        _require(type(row) is dict, "Original authority root record is invalid.")
        fields.extend(row.get(key) for key in (
            "path", "base_file_id", "file_id", "owner_sid", "acl_sddl"))
    encoded = bytearray(b"DarkReNamer-236-authority-v1\0")
    for field in fields:
        _require(type(field) is str and "\0" not in field,
                 "Original authority field is missing or contains NUL.")
        try:
            data = field.encode("utf-8", errors="strict")
        except UnicodeError as error:
            raise EvidenceError("Original authority field is not UTF-8.") from error
        _require(len(data) <= 1024 * 1024, "Original authority field is oversized.")
        encoded.extend(len(data).to_bytes(4, "big"))
        encoded.extend(data)
    return hashlib.sha256(encoded).hexdigest()


def _ordinary(path: Path, *, directory: bool = False) -> None:
    for node in (path, *path.parents):
        mode = node.lstat().st_mode
        _require(not stat.S_ISLNK(mode) and
                 not (getattr(node.lstat(), "st_file_attributes", 0) & 0x400),
                 "Original evidence traverses a link or reparse point.")
    mode = path.stat().st_mode
    _require(stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode),
             "Original evidence entry is not ordinary.")


def _read(path: Path, limit: int, digest: str | None = None) -> bytes:
    _ordinary(path)
    _require(0 < path.stat().st_size <= limit, "Original evidence file is missing or oversized.")
    data = path.read_bytes()
    _require(0 < len(data) <= limit and
             (digest is None or hashlib.sha256(data).hexdigest() == digest),
             "Original evidence bytes differ from the frozen digest.")
    return data


def _json(data: bytes) -> dict:
    def unique(pairs: list[tuple[str, object]]) -> dict:
        result = {}
        for key, value in pairs:
            _require(key not in result, "Original JSON repeats a key.")
            result[key] = value
        return result

    try:
        result = json.loads(data.decode("utf-8-sig"), object_pairs_hook=unique)
    except (UnicodeError, ValueError) as error:
        raise EvidenceError("Original evidence is not UTF-8 JSON.") from error
    _require(type(result) is dict, "Original evidence is not a JSON object.")
    return result


def _reference(row: dict, name: str, data: bytes) -> None:
    _require(type(row) is dict and set(row) == {"file", "bytes", "sha256"} and
             row["file"] == name and type(row["bytes"]) is int and
             row["bytes"] == len(data) and row["sha256"] == hashlib.sha256(data).hexdigest(),
             "Original evidence reference differs from its file.")


def verify_original_target(root: Path | str) -> dict:
    """Return frozen target facts only after all original evidence is checked."""
    root = Path(root)
    _ordinary(root, directory=True)
    transport_data = _read(root / "original-transport.json", 4 * 1024 * 1024,
                           ORIGINAL_TRANSPORT_SHA256)
    preservation_data = _read(root / "owned-cleanup-strict-failure-preservation.json",
                              1024 * 1024, ORIGINAL_PRESERVATION_SHA256)
    transport, preservation = _json(transport_data), _json(preservation_data)
    vm_id = transport.get("vm_id")
    run_name = preservation.get("run_name")
    _require(transport.get("status") == "failed" and transport.get("guest_cleanup") is False and
             type(vm_id) is str and VM_ID.fullmatch(vm_id) is not None and
             type(run_name) is str and RUN_NAME.fullmatch(run_name) is not None and
             preservation.get("kind") == "owned_cleanup_strict_failure_preservation" and
             preservation.get("vm_id") == vm_id and
             preservation.get("profile_id") == "vm-automated-v2-owned-resources" and
             preservation.get("profile_sha256") == ORIGINAL_PROFILE_SHA256,
             "Original failure, run, VM, or profile binding differs.")
    _reference(preservation.get("original_transport"), "original-transport.json", transport_data)
    context = transport.get("owned_cleanup_failure_context")
    _require(type(context) is dict and context.get("acceptance_mode") == "gui-apply-feedback" and
             context.get("source_sha") == ORIGINAL_SOURCE_SHA and
             context.get("bundle", {}).get("sha256") == ORIGINAL_BUNDLE_SHA256 and
             context.get("output_preservation_verified") is True and
             context.get("root_records") == preservation.get("root_records"),
             "Original source, bundle, preservation, or root binding differs.")
    roots = preservation["root_records"]
    _require(type(roots) is dict and set(roots) == set(ROOT_KEYS),
             "Original root records are incomplete.")
    base_id = None
    for role in ROOT_KEYS:
        row = roots[role]
        expected = "C:\\ProgramData\\DarkReNamerVmRuns\\" + run_name
        if role == "trusted":
            expected += "-trusted"
        _require(type(row) is dict and row.get("path") == expected and
                 type(row.get("file_id")) is str and FILE_ID.fullmatch(row["file_id"]) is not None and
                 type(row.get("base_file_id")) is str and
                 FILE_ID.fullmatch(row["base_file_id"]) is not None and
                 row.get("owner_sid") == "S-1-5-32-544" and
                 type(row.get("acl_sddl")) is str and row["acl_sddl"].startswith("O:BA") and
                 (base_id is None or base_id == row["base_file_id"]),
                 "Original root identity or descriptor is unavailable.")
        base_id = row["base_file_id"]
    _require(authority_digest(vm_id, run_name, roots) == ORIGINAL_AUTHORITY_SHA256,
             "Original private target authority differs from the source pin.")
    files = preservation.get("files")
    _require(type(files) is list and 1 <= len(files) <= MAX_ORIGINAL_ENTRIES,
             "Original preserved output index is incomplete.")
    checked = {}
    total = 0
    for row in files:
        _require(type(row) is dict and set(row) == {"file", "bytes", "sha256"},
                 "Original output index row is invalid.")
        name = row["file"]
        _require(type(name) is str and name not in checked and name and
                 all(part not in ("", ".", "..") for part in name.split("/")) and
                 "\\" not in name and not name.startswith("/"),
                 "Original output index contains an alias or duplicate.")
        _require(type(row["bytes"]) is int and 0 < row["bytes"] <= MAX_ORIGINAL_BYTES - total,
                 "Original output index exceeds its byte bound.")
        data = _read(root.joinpath(*name.split("/")), row["bytes"], row["sha256"])
        _reference(row, name, data)
        checked[name] = data
        total += len(data)
    required = {"original-transport.json", "acceptance-result.json", "acceptance-observations.json",
                "owned-performance-input-manifest.json", "owned-performance-profile.json", "bundle.json"}
    _require(required <= checked.keys() and checked["original-transport.json"] == transport_data and
             hashlib.sha256(checked["bundle.json"]).hexdigest() == ORIGINAL_BUNDLE_SHA256 and
             hashlib.sha256(checked["owned-performance-profile.json"]).hexdigest() == ORIGINAL_PROFILE_SHA256,
             "Original required source or result output is absent.")
    _reference(context["bundle"], "bundle.json", checked["bundle.json"])
    _reference(context["source_result"], "acceptance-result.json", checked["acceptance-result.json"])
    extras = {"owned-cleanup-strict-failure-preservation.json": preservation_data}
    for name, digest in ORIGINAL_EXTRA_FILES.items():
        location = root / name
        if name == "desktop-lease.json" and not location.is_file():
            location = root.parent / name
        extras[name] = _read(location, 1024 * 1024, digest)
    signal, lease = _json(extras["owned-cleanup-desktop-closed.json"]), _json(extras["desktop-lease.json"])
    predelete, stop = _json(extras["owned-performance-predelete.json"]), _json(extras["desktop-stop-response.json"])
    _require(signal.get("preservation_sha256") == ORIGINAL_PRESERVATION_SHA256 and
             signal.get("desktop_lease_sha256") == hashlib.sha256(extras["desktop-lease.json"]).hexdigest() and
             signal.get("nonce") == preservation.get("nonce") and
             lease.get("mode") == "managed-rdp" and lease.get("stop_status") == "stopped" and
             lease.get("cleanup_observed") is True and lease.get("lease_id") == preservation.get("desktop_lease_id") and
             stop.get("status") == "stopped" and stop.get("finalChildStatus") == "closed" and
             stop.get("leaseId") == lease["lease_id"],
             "Original desktop lease or closure is unavailable.")
    _require(predelete.get("kind") == "owned_performance_predelete_restoration" and
             predelete.get("run_name") == run_name and
             predelete.get("run_id") == ORIGINAL_RUN_ID and
             predelete.get("vm_id") == vm_id and
             predelete.get("nonce") == preservation.get("nonce") and
             predelete.get("roots") == roots and
             predelete.get("source_sha") == ORIGINAL_SOURCE_SHA and
             predelete.get("bundle_sha256") == ORIGINAL_BUNDLE_SHA256 and
             predelete.get("profile_sha256") == ORIGINAL_PROFILE_SHA256 and
             type(predelete.get("files")) is dict and
             set(predelete["files"]) == required | {"owned-cleanup-strict-failure-preservation.json",
                                                   "owned-cleanup-desktop-closed.json", "desktop-lease.json"},
             "Original pre-delete restoration binding differs.")
    for name, row in predelete["files"].items():
        _reference(row, name, checked.get(name, extras.get(name)))
    observations = _json(checked["acceptance-observations.json"])
    restoration = observations.get("text_scale_restoration")
    _require(observations.get("run_id") == ORIGINAL_RUN_ID and
             type(restoration) is dict and restoration.get("snapshot_equal") is True and
             restoration.get("baseline") == restoration.get("final") and
             restoration["final"].get("ui_settings_percent") == 100,
             "Original text-scale restoration is unavailable.")
    raw = transport.get("raw_cleanup")
    _require(type(raw) is dict and raw.get("scheduled_task_present") is False and
             raw.get("guest_root_present") is True and raw.get("trusted_task_root_present") is True and
             raw.get("process_jobs_closed") is True and raw.get("owned_processes_after") == [] and
             raw.get("terminated_runner_processes") == [] and
             raw.get("owned_resource_evidence", {}).get("root_records") == roots,
             "Original owned lifetime or root scope differs.")
    owned = raw["owned_resource_evidence"]
    _require(type(owned.get("runner_sid")) is str and
             re.fullmatch(r"S-1-5-21-(?:\d+-){3}\d+", owned["runner_sid"]) is not None and
             type(owned.get("runner_session_id")) is int and owned["runner_session_id"] > 0 and
             owned.get("task_execution", {}).get("task_name") == run_name and
             owned["task_execution"].get("observer_lifetime_absent") is True and
             owned.get("preflight_child", {}).get("exact_lifetime_absent") is True and
             owned.get("engine_child", {}).get("exact_lifetime_absent") is True and
             type(owned.get("declared_processes")) is list and
             len(owned["declared_processes"]) == 1,
             "Original declared owned process or task scope is incomplete.")
    declared_pids = [entry.get("pid") for entry in owned["declared_processes"]]
    declared_pids += [owned["task_execution"].get("observer_lifecycle", {}).get("pid"),
                      owned["preflight_child"].get("pid"),
                      owned["engine_child"].get("pid")]
    _require(len(declared_pids) == 4 and
             all(type(pid) is int and pid > 0 for pid in declared_pids),
             "Original declared process identities are incomplete.")
    return {
        "kind": "issue236_original_target_verified",
        "transport_sha256": ORIGINAL_TRANSPORT_SHA256,
        "preservation_sha256": ORIGINAL_PRESERVATION_SHA256,
        "vm_id": vm_id,
        "run_name": run_name,
        "authority_sha256": ORIGINAL_AUTHORITY_SHA256,
        "source_sha": ORIGINAL_SOURCE_SHA,
        "bundle_sha256": ORIGINAL_BUNDLE_SHA256,
        "profile_sha256": ORIGINAL_PROFILE_SHA256,
        "roots": roots,
        "runner_sid": owned["runner_sid"],
        "declared_pids": declared_pids,
        "preserved_file_count": len(checked),
        "preserved_bytes": total,
        "historical_status": "rejected",
    }


def verify_current_collection(original_root: Path | str, collection_path: Path | str,
                              *, tooling_manifest_sha256: str) -> dict:
    """Check a current read-only collection; it never grants deletion or admission."""
    target = verify_original_target(original_root)
    collection = _json(_read(Path(collection_path), 16 * 1024 * 1024))
    nonce = collection.get("operation_nonce")
    _require(collection.get("kind") == "maintained_retained_root_collection" and
             collection.get("schema_version") == 1 and
             type(nonce) is str and re.fullmatch(r"[0-9a-f]{32}", nonce) is not None and
             collection.get("original_transport_sha256") == ORIGINAL_TRANSPORT_SHA256 and
             collection.get("original_preservation_sha256") == ORIGINAL_PRESERVATION_SHA256 and
             collection.get("vm_id") == target["vm_id"] and
             collection.get("run_name") == target["run_name"] and
             collection.get("tooling_manifest_sha256") == tooling_manifest_sha256 and
             collection.get("status") == "collected" and collection.get("errors") == [],
             "Current collection is incomplete or bound to different original/tooling bytes.")
    current = collection.get("current")
    _require(type(current) is dict and current.get("vm_id") == target["vm_id"] and
             current.get("operation_nonce") == nonce and
             type(current.get("principal_sid")) is str and
             re.fullmatch(r"S-1-5-21-(?:\d+-){3}\d+", current["principal_sid"]) is not None and
             current.get("process_inventory_complete") is True and
             current.get("task_inventory_complete") is True,
             "Current principal, VM, nonce, or complete inventories are unavailable.")
    _require(current["principal_sid"] == target["runner_sid"],
             "Current controller principal differs from original runner scope.")
    observed = current.get("roots")
    _require(type(observed) is dict and set(observed) == set(ROOT_KEYS),
             "Both current held root observations are required.")
    total_entries = 0
    total_bytes = 0
    for role in ROOT_KEYS:
        frozen = target["roots"][role]
        row = observed[role]
        _require(type(row) is dict and all(row.get(key) == frozen[key] for key in (
            "path", "base_file_id", "file_id", "owner_sid", "acl_sddl")),
            "A current held root differs from the immutable original.")
        index = row.get("index")
        _require(type(index) is list, "Current held content index is missing.")
        seen = {}
        for entry in index:
            _require(type(entry) is dict and entry.get("kind") in {"file", "directory"} and
                     type(entry.get("file_id")) is str and FILE_ID.fullmatch(entry["file_id"]) is not None,
                     "Current content entry has invalid identity or kind.")
            components = entry.get("components_utf16_hex")
            _require(type(components) is list and 1 <= len(components) <= 64 and
                     all(type(part) is str and 0 < len(part) <= 510 and len(part) % 4 == 0 and
                         re.fullmatch(r"[0-9a-f]+", part) is not None for part in components),
                     "Current content index has an invalid raw UTF-16 path.")
            path = tuple(components)
            _require(path not in seen,
                     "Current content index repeats or aliases an entry.")
            seen[path] = entry["kind"]
            if entry["kind"] == "file":
                size, digest = entry.get("bytes"), entry.get("sha256")
                _require(type(size) is int and 0 <= size <= 512 * 1024 * 1024 - total_bytes and
                         type(digest) is str and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
                         "Current indexed file has incomplete bounded content proof.")
                total_bytes += size
            else:
                _require("bytes" not in entry and "sha256" not in entry,
                         "Current indexed directory has file content fields.")
            total_entries += 1
            _require(total_entries <= 20000, "Current index exceeds the native guard entry bound.")
        _require(all(seen.get(path[:depth]) == "directory"
                     for path in seen for depth in range(1, len(path))),
                 "Current content index omits a parent directory.")
    processes = current.get("processes")
    tasks = current.get("tasks")
    _require(type(processes) is list and type(tasks) is list and
             len(processes) <= 65536 and len(tasks) <= 4096 and
             current.get("owned_processes") == [] and current.get("owned_tasks") == [],
             "Current owned lifetimes or complete inventory rows are unavailable.")
    seen_processes = set()
    opaque = []
    references = (target["run_name"].lower(), *(row["path"].lower() for row in target["roots"].values()))
    for row in processes:
        _require(type(row) is dict and type(row.get("pid")) is int and row["pid"] > 0 and
                 type(row.get("creation_date")) is str and row["creation_date"] and
                 type(row.get("owner_sid")) is str and row["owner_sid"] and
                 type(row.get("executable_path")) is str and type(row.get("command_line")) is str,
                 "Current process inventory has an incomplete lifetime.")
        identity = (row["pid"], row["creation_date"])
        _require(identity not in seen_processes, "Current process lifetime repeats.")
        _require(row["pid"] not in target["declared_pids"],
                 "A declared original owned process PID is still present or reused.")
        seen_processes.add(identity)
        binding = (row["executable_path"] + "\n" + row["command_line"]).lower()
        _require(not any(value in binding for value in references),
                 "Current process inventory still references the original run or roots.")
        if not row["executable_path"] or not row["command_line"]:
            opaque.append(identity)
    _require(current.get("opaque_processes") == [row for row in processes if
             not row["executable_path"] or not row["command_line"]],
             "Current opaque process classification differs from raw rows.")
    seen_tasks = set()
    principal = []
    for row in tasks:
        _require(type(row) is dict and type(row.get("identity")) is str and
                 row["identity"].startswith("\\") and
                 type(row.get("definition_xml")) is str and
                 type(row.get("definition_sha256")) is str and
                 row["definition_sha256"] == hashlib.sha256(
                     row["definition_xml"].encode("utf-8")).hexdigest() and
                 type(row.get("principal_user_id")) is str and
                 type(row.get("principal_group_id")) is str and
                 type(row.get("resolved_user_sid")) is str and
                 (row["principal_user_id"] or row["principal_group_id"]),
                 "Current task inventory has an invalid identity or XML hash.")
        _require(row["identity"] not in seen_tasks and
                 not any(value in (row["identity"] + "\n" + row["definition_xml"]).lower()
                         for value in references),
                 "A current task repeats or references the original run or roots.")
        seen_tasks.add(row["identity"])
        if (row["resolved_user_sid"] == current["principal_sid"] or
                row["principal_group_id"]):
            principal.append({"identity": row["identity"],
                              "definition_sha256": row["definition_sha256"]})
    _require(current.get("principal_task_map") == principal,
             "Current principal task XML-hash map differs from full task inventory.")
    return {
        "kind": "issue236_current_collection_verified",
        "collection_sha256": hashlib.sha256(_read(Path(collection_path), 16 * 1024 * 1024)).hexdigest(),
        "operation_nonce": nonce,
        "root_entries": total_entries,
        "root_file_bytes": total_bytes,
        "opaque_process_count": len(opaque),
        "historical_status": "rejected",
        "deletion_authorized": False,
        "admission_authorized": False,
    }


def verify_reviewed_classification(collection_path: Path | str, plan_path: Path | str,
                                   *, approved_sha256: str | None = REVIEWED_CLASSIFICATION_SHA256) -> dict:
    """Check one source-pinned classification; no caller-selected hash authorizes it."""
    _require(type(approved_sha256) is str and
             re.fullmatch(r"[0-9a-f]{64}", approved_sha256) is not None,
             "No reviewed retained-root classification is pinned in this source.")
    collection_bytes = _read(Path(collection_path), 16 * 1024 * 1024)
    collection = _json(collection_bytes)
    plan_bytes = _read(Path(plan_path), 16 * 1024 * 1024, approved_sha256)
    plan = _json(plan_bytes)
    _require(plan.get("schema_version") == 1 and
             plan.get("kind") == "maintained_retained_root_classification" and
             plan.get("original_transport_sha256") == ORIGINAL_TRANSPORT_SHA256 and
             plan.get("original_preservation_sha256") == ORIGINAL_PRESERVATION_SHA256 and
             plan.get("collection_sha256") == hashlib.sha256(collection_bytes).hexdigest() and
             plan.get("vm_id") == collection.get("vm_id") and
             plan.get("run_name") == collection.get("run_name") and
             plan.get("collection_nonce") == collection.get("operation_nonce"),
             "Reviewed classification differs from its exact collection or original run.")
    bounds = plan.get("bounds")
    _require(type(bounds) is dict and set(bounds) == {
        "maximum_seconds", "maximum_entries", "maximum_content_bytes", "rationale"} and
        type(bounds["maximum_seconds"]) is int and 1 <= bounds["maximum_seconds"] <= 900 and
        type(bounds["maximum_entries"]) is int and 1 <= bounds["maximum_entries"] <= 20000 and
        type(bounds["maximum_content_bytes"]) is int and
        0 <= bounds["maximum_content_bytes"] <= 512 * 1024 * 1024 and
        type(bounds["rationale"]) is str and 20 <= len(bounds["rationale"]) <= 2000,
        "Reviewed classification lacks a bounded, explained attempt plan.")
    current = collection.get("current")
    _require(type(current) is dict and type(current.get("roots")) is dict and
             type(plan.get("classified_entries")) is dict and
             set(plan["classified_entries"]) == set(ROOT_KEYS),
             "Reviewed classification omits a current root or entry inventory.")
    count, total = 0, 0
    for role in ROOT_KEYS:
        index = current["roots"][role].get("index")
        classified = plan["classified_entries"][role]
        _require(type(index) is list and type(classified) is list and
                 len(index) == len(classified),
                 "Reviewed classification does not cover every indexed entry.")
        expected = {tuple(row["components_utf16_hex"]): row for row in index}
        seen = set()
        for row in classified:
            _require(type(row) is dict and set(row) == {
                "components_utf16_hex", "file_id", "kind", "classification", "reason"},
                "Reviewed classification entry is incomplete.")
            name = tuple(row["components_utf16_hex"])
            _require(name not in seen and name in expected and
                     row["file_id"] == expected[name]["file_id"] and
                     row["kind"] == expected[name]["kind"] and
                     row["classification"] == "exact_run_disposable" and
                     type(row["reason"]) is str and 8 <= len(row["reason"]) <= 256,
                     "Reviewed classification has an unindexed or unexplained entry.")
            seen.add(name)
        count += len(index)
        total += sum(row.get("bytes", 0) for row in index)
    _require(count <= bounds["maximum_entries"] and total <= bounds["maximum_content_bytes"],
             "Reviewed classification bounds do not cover its exact content index.")
    return {"kind": "issue236_classification_reviewed", "plan_sha256": approved_sha256,
            "collection_sha256": hashlib.sha256(collection_bytes).hexdigest(),
            "entries": count, "content_bytes": total, "bounds": bounds,
            "deletion_authorized": False, "admission_authorized": False}


def cli(_repo: Path, argv: list[str] | None = None, tooling=None) -> int:
    parser = argparse.ArgumentParser(description="Verify the immutable #236 target and current read-only collection.")
    parser.add_argument("--original-output", type=Path, required=True)
    parser.add_argument("--collection", type=Path)
    parser.add_argument("--plan", type=Path)
    args = parser.parse_args(argv)
    try:
        _require(not args.plan or args.collection is not None,
                 "Reviewed classification requires a current collection.")
        if args.collection:
            result = verify_current_collection(args.original_output, args.collection,
                                               tooling_manifest_sha256=tooling.manifest_sha256)
            if args.plan:
                result = verify_reviewed_classification(args.collection, args.plan)
        else:
            result = verify_original_target(args.original_output)
            result = {key: value for key, value in result.items()
                      if key not in {"roots", "runner_sid", "declared_pids"}}
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, KeyError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
