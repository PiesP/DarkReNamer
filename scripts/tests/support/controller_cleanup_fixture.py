"""Synthetic clean controller evidence shared by tooling contract tests."""


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
