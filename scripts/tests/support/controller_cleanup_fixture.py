"""Synthetic clean controller evidence shared by tooling contract tests."""

from copy import deepcopy
import base64
from datetime import datetime
import struct


def clean_controller_cleanup():
    return {
        "scheduled_task_present": False,
        "guest_root_present": False,
        "trusted_task_root_present": False,
        "process_jobs_closed": True,
        "runner_process_inventory_complete": True,
        "unexpected_runner_tasks": [],
        "unexpected_runner_processes": [],
        "unexpected_runner_tasks_after_intervention": [],
        "unexpected_runner_processes_after_intervention": [],
        "unexpected_runner_tasks_after_delete": [],
        "unexpected_runner_processes_after_delete": [],
        "removed_runner_tasks": [],
        "terminated_runner_processes": [],
        "resource_cleanup_errors": [],
        "runner_process_natural_exit": {
            "schema_version": 2,
            "status": "not-required",
            "process_class": None, "native_exit": None, "initial_native_observations": [],
            "runner_sid": "S-1-5-21-1000-1000-1000-1001",
            "runner_session_id": 2,
            "candidate_identity": None,
            "broker": None,
            "timeout_ms": 0,
            "elapsed_ms": 0,
            "polls": [],
            "natural_exit_observed": False,
            "final_inventory_complete": True,
            "final_runner_process_delta_identities": [],
            "final_runner_task_delta_identities": [],
        },
        "owned_processes_after": [],
    }


V2_PROFILE_SHA256 = "10b034dd27a1a950be280d848e7f985d6820295e0970c6fafd6f49a50985efc7"


def clean_controller_cleanup_v2(*, profile_sha256=V2_PROFILE_SHA256, process_jobs=None,
                                observer_lifecycle=None,
                                run_name="DarkReNamerTests-" + "b" * 32,
                                ambient_processes=None):
    """A closed v2 run with two new, typed ambient process lifetimes."""
    name = run_name
    sid = "S-1-5-21-1000-1000-1000-1001"
    base = r"C:\ProgramData\DarkReNamerVmRuns"
    roots = {
        role: {"path": base + "\\" + name + suffix,
               "base_file_id": "1" * 48, "file_id": identity * 48,
               "owner_sid": "S-1-5-32-544", "acl_sddl": "O:BAG:BAD:(A;;FA;;;BA)"}
        for role, suffix, identity in (("guest", "", "2"), ("trusted", "-trusted", "3"))
    }
    ambient = [
        {"identity": f"{pid}|2026-09-30T01:02:03.0000000Z", "pid": pid,
         "session_id": 2, "creation_time_utc": "2026-09-30T01:02:03.0000000Z",
         "executable_path": rf"C:\Windows\System32\{image}.exe",
         "command_line": rf"C:\Windows\System32\{image}.exe -Embedding",
         "parent_pid": 100, "owner_sid": sid}
        for pid, image in ((4001, "smartscreen"), (4002, "TextInputHost"))
    ]
    job = {"pid": 3001, "process_start_time_utc_ticks": "134041000000000000",
           "job_empty": True, "job_closed": True, "capture_complete": True,
           "active_processes_at_primary_exit": 0, "had_survivors": False,
           "forced_termination": False, "active_processes_at_close": 0,
           "active_processes_at_stop": 0, "active_process_ids_at_stop": [],
           "total_processes_at_stop": 1, "primary_process_active_at_stop": False,
           "termination_exit_code": None, "status": "clean", "error": None}
    jobs = deepcopy([job] if process_jobs is None else process_jobs)
    if ambient_processes is not None:
        ambient = deepcopy(ambient_processes)
    action = r"C:\Program Files\PowerShell\7\pwsh.exe"
    args = (f'-NoProfile -File "{roots["trusted"]["path"]}\\windows-vm-guest.ps1" '
            f'-AcceptanceProfileId vm-automated-v2-owned-resources '
            f'-ElevatedObserver -TrustedResultPath "{roots["trusted"]["path"]}\\out\\core-result.json"')
    lifecycle = deepcopy(observer_lifecycle) if observer_lifecycle is not None else {
        "pid": 3003, "start_time_utc_ticks": "134041000000000003",
        "session_id": 2, "image_path": action,
        "command_line": '"' + action + '" ' + args, "owner_sid": sid}
    evidence = {
        "schema_version": 2, "run_name": name, "runner_sid": sid, "runner_session_id": 2,
        "root_records": roots, "baseline_processes": [], "baseline_tasks": [],
        "process_snapshots": {
            phase: {"complete": True, "processes": deepcopy(ambient[:count])}
            for phase, count in (("before", min(1, len(ambient))),
                                 ("after_intervention", len(ambient)),
                                 ("after_delete", len(ambient)))
        },
        "task_snapshots": {phase: [] for phase in ("before", "after_intervention", "after_delete")},
        "declared_processes": [{"pid": row["pid"],
                                "start_time_utc_ticks": row["process_start_time_utc_ticks"]}
                               for row in jobs],
        "process_job_cleanup": jobs,
        "preflight_child": {"pid": 3002, "start_time_utc_ticks": "134041000000000001",
                            "exit_code": 0, "exited": True, "streams_complete": True,
                            "exact_lifetime_absent": True, "process_job_closed": True},
        "engine_child": {"pid": 3004, "start_time_utc_ticks": "134041000000000004",
                         "exit_code": 0, "exited": True, "streams_complete": True,
                         "exact_lifetime_absent": True, "process_job_closed": True},
        "task_execution": {"task_name": name, "terminal": True, "exit_code": 0,
                           "registered_last_run_time_ticks": 134041000000000000,
                           "completed_last_run_time_ticks": 134041000000000002,
                           "action_executable": lifecycle["image_path"], "action_arguments": args,
                           "observer_lifecycle": lifecycle,
                           "observer_lifetime_absent": True},
        "rescue_attempts": 0, "rescue_executions": [],
        "observed_roots_before": {role: {**row, "ordinary_directory": True}
                                  for role, row in roots.items()},
        "observed_roots_after": {"guest_present": False, "trusted_present": False},
    }
    cleanup = clean_controller_cleanup()
    cleanup.update(schema_version=2, profile_id="vm-automated-v2-owned-resources",
                   profile_sha256=profile_sha256, owned_resource_evidence=evidence,
                   runner_process_natural_exit={"schema_version": 2,
                                                "status": "v2-owned-resources"})
    for phase, key in (("before", "unexpected_runner_processes"),
                       ("after_intervention", "unexpected_runner_processes_after_intervention"),
                       ("after_delete", "unexpected_runner_processes_after_delete")):
        cleanup[key] = list(evidence["process_snapshots"][phase]["processes"])
    return cleanup


def clean_controller_cleanup_v3(*, profile_sha256="a" * 64,
                                source_sha="a" * 40, bundle_sha256="b" * 64,
                                vm_id="12345678-1234-1234-1234-123456789abc",
                                **kwargs):
    """Production-shaped revision-3 cleanup with no opaque lifetime present."""
    cleanup = clean_controller_cleanup_v2(profile_sha256=profile_sha256, **kwargs)
    evidence = cleanup["owned_resource_evidence"]
    cleanup["schema_version"] = evidence["schema_version"] = 3
    cleanup["runner_process_natural_exit"]["schema_version"] = 3
    for phase in evidence["process_snapshots"].values():
        for row in phase["processes"]:
            row["kind"] = "full"
    for phase, key in (("before", "unexpected_runner_processes"),
                       ("after_intervention", "unexpected_runner_processes_after_intervention"),
                       ("after_delete", "unexpected_runner_processes_after_delete")):
        cleanup[key] = deepcopy(evidence["process_snapshots"][phase]["processes"])
    pre_name = {"complete": True, "processes": [], "attempts": 1}
    initial = {"schema_version": 3, "run_name": evidence["run_name"],
               "vm_id": vm_id, "source_sha": source_sha,
               "bundle_sha256": bundle_sha256, "profile_sha256": profile_sha256,
               "anchor_nonce": "c" * 32, "pre_name_utc": "2026-09-29T00:00:00.0000000Z",
               "pre_name_snapshot": pre_name, "anchor_present": False,
               "all_handles_closed": False, "errors": [], "proof": None}
    evidence["pre_name_snapshot"] = deepcopy(pre_name)
    evidence["protected_anchor_initial"] = deepcopy(initial)
    evidence["protected_anchor"] = {**deepcopy(initial), "all_handles_closed": True}
    return cleanup


def _v3_sid(value):
    parts = [int(part) for part in value.split("-")[1:]]
    return bytes((parts[0], len(parts) - 2)) + parts[1].to_bytes(6, "big") + b"".join(
        struct.pack("<I", part) for part in parts[2:])


def _v3_descriptor(owner, aces):
    owner_bytes = _v3_sid(owner)
    entries = b"".join(struct.pack("<BBHI", ace["type"], ace["flags"],
                                   8 + len(_v3_sid(ace["sid"])), ace["mask"]) +
                       _v3_sid(ace["sid"]) for ace in aces)
    dacl = struct.pack("<BBHHH", 2, 0, 8 + len(entries), len(aces), 0) + entries
    header = struct.pack("<BBHIIII", 1, 0, 0x8004, 20, 0, 0, 20 + len(owner_bytes))
    return base64.b64encode(header + owner_bytes + dacl).decode("ascii")


def _v3_filetime(value):
    created = datetime.strptime(value[:-2], "%Y-%m-%dT%H:%M:%S.%f")
    delta = created - datetime(1601, 1, 1)
    return str((delta.days * 86_400 + delta.seconds) * 10_000_000 +
               delta.microseconds * 10)


def clean_controller_cleanup_v3_protected(**kwargs):
    """A held pre-name AntiMalware-Light lifetime in every production phase."""
    cleanup = clean_controller_cleanup_v3(**kwargs)
    evidence = cleanup["owned_resource_evidence"]
    sid = evidence["runner_sid"]
    child_time = "2026-09-30T01:02:03.0000000Z"
    parent_time = "2026-09-29T01:02:03.0000000Z"
    base = r"C:\ProgramData\Microsoft\Windows Defender\Platform\4.18.26090.9-0"
    child_path = base + r"\DefenderSessionHelper.exe"
    parent_path = base + r"\MsMpEng.exe"
    system_ace = {"type": 0, "flags": 0, "mask": 0x1F01FF, "sid": "S-1-5-18"}
    users_ace = {"type": 0, "flags": 2, "mask": 278, "sid": "S-1-5-32-545"}

    def ancestry(path, leaf_id):
        drive, *parts = path.split("\\")
        nodes = [drive + "\\"]
        for part in parts:
            nodes.append(nodes[-1].rstrip("\\") + "\\" + part)
        result = []
        for index, node in enumerate(nodes):
            aces = [system_ace] + ([users_ace] if index == 1 else [])
            result.append({"path": node, "is_directory": index < 6,
                           "file_id": (leaf_id if index == 6 else str(index + 1)) * 48,
                           "owner_sid": "S-1-5-18", "aces": deepcopy(aces),
                           "security_descriptor_base64": _v3_descriptor("S-1-5-18", aces)})
        return result

    def native(pid, created, owner, session, image):
        return {"pid": pid, "creation_filetime_100ns": _v3_filetime(created),
                "owner_sid": owner, "session_id": session, "image_path": image,
                **{key: 0 for key in ("open_error", "pid_error", "times_error",
                                      "image_error", "token_error", "token_sid_error",
                                      "token_session_error")}}

    proof = {"schema_version": 1, "identity": "4900|" + child_time, "pid": 4900,
             "creation_time_utc": child_time, "parent_creation_time_utc": parent_time,
             "parent_pid": 499, "runner_sid": sid, "runner_session_id": 2,
             "profile_sha256": cleanup["profile_sha256"],
             "source_sha": evidence["protected_anchor"]["source_sha"],
             "bundle_sha256": evidence["protected_anchor"]["bundle_sha256"],
             "vm_id": evidence["protected_anchor"]["vm_id"],
             "pre_name_utc": evidence["protected_anchor"]["pre_name_utc"],
             "anchor_nonce": evidence["protected_anchor"]["anchor_nonce"],
             "cim_executable_path": None, "cim_command_line": None,
             "child_native_identity": native(4900, child_time, sid, 2, child_path),
             "parent_native_identity": native(499, parent_time, "S-1-5-18", 0, parent_path),
             "provenance": {"child_ancestry": ancestry(child_path, "e"),
                            "parent_ancestry": ancestry(parent_path, "f"),
                            "child_signature": {"status": "Valid",
                                                "signer_subject": "CN=Microsoft Corporation",
                                                "signer_thumbprint": "A" * 40},
                            "parent_signature": {"status": "Valid",
                                                 "signer_subject": "CN=Microsoft Corporation",
                                                 "signer_thumbprint": "B" * 40},
                            "service": {"name": "WinDefend", "state": "Running",
                                        "start_name": "LocalSystem", "process_id": 499,
                                        "path_name": '"' + parent_path + '"'},
                            "protection_level": 3, "parent_protection_level": 3},
             "run_name": evidence["run_name"],
             "run_name_created_utc": "2026-09-30T01:02:04.0000000Z",
             "handle_closed": False, "parent_handle_closed": False,
             "child_path_closed": False, "parent_path_closed": False,
             "accepted_snapshot_count": 1}
    row = {"kind": "protected_pre_name", "identity": proof["identity"],
           "pid": proof["pid"], "session_id": 2, "creation_time_utc": child_time,
           "executable_path": None, "command_line": None,
           "native_image_path": child_path, "protection_level": 3,
           "parent_pid": 499, "owner_sid": sid}
    evidence["pre_name_snapshot"]["processes"] = [deepcopy(row)]
    evidence["baseline_processes"] = [deepcopy(row)]
    for phase in evidence["process_snapshots"].values():
        phase["processes"].insert(0, deepcopy(row))
    for anchor in (evidence["protected_anchor_initial"], evidence["protected_anchor"]):
        anchor["anchor_present"] = True
        anchor["pre_name_snapshot"] = deepcopy(evidence["pre_name_snapshot"])
        anchor["proof"] = deepcopy(proof)
    evidence["protected_anchor"]["proof"].update(
        handle_closed=True, parent_handle_closed=True,
        child_path_closed=True, parent_path_closed=True,
        accepted_snapshot_count=5)
    return cleanup
