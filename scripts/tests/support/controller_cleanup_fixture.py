"""Synthetic clean controller evidence shared by tooling contract tests."""

from copy import deepcopy


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


V2_PROFILE_SHA256 = "a" * 64


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
        "command_line": action + " " + args, "owner_sid": sid}
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
