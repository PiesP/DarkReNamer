"""Fixed campaign planning and complete first-attempt ledger verification.

The ledger establishes coverage and ordering, never semantic pass verdicts.
Every returned execution still needs candidate, environment, raw state and
cleanup verification by the enclosing trusted verifier.
"""

from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
import re

from vm_automated_binding import Candidate
from vm_automated_evidence import EvidenceError, REQUIRED_TARGET_IDS, require_exact_keys, require_int


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def token(value: object) -> str:
    require(type(value) is str and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,95}", value) is not None,
            "Campaign identifier is not a bounded token.")
    return value


def timestamp(value: object) -> datetime:
    require(type(value) is str and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z", value) is not None,
            "Campaign timestamp must be canonical UTC.")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError("Campaign timestamp is invalid.") from error
    require(parsed.tzinfo == timezone.utc, "Campaign timestamp is not UTC.")
    return parsed


def execution_slots(profile: dict) -> list[dict]:
    """One fixed slot per target except the deliberate crash/export/Intent group."""
    targets = profile["required_targets"]
    require(type(targets) is list and len(targets) == len(REQUIRED_TARGET_IDS) and
            {row["id"] for row in targets} == REQUIRED_TARGET_IDS,
            "Trusted profile differs from the required target set.")
    slots = []
    for target in targets:
        name = target["id"]
        if name in {"recovery-export", "intent-only-discard"}:
            continue
        members = (["process-crash", "recovery-export", "intent-only-discard"]
                   if name == "process-crash" else [name])
        slots.append({"id": name, "targets": members, "stability_index": None})
    require_int(profile["stability"]["fresh_core_runs"], 10, 10, "Required stability executions")
    slots.extend({"id": f"stability-{index:02d}", "targets": ["core-uia-flow"], "stability_index": index}
                 for index in range(1, 11))
    return slots


def new_plan(profile: dict, *, profile_sha256: str, candidate: Candidate,
             harness_sha: str, campaign_id: str, created_at: str) -> dict:
    token(campaign_id)
    timestamp(created_at)
    require(type(profile_sha256) is str and re.fullmatch(r"[0-9a-f]{64}", profile_sha256) is not None,
            "Profile digest is invalid.")
    require(type(harness_sha) is str and re.fullmatch(r"[0-9a-f]{40}", harness_sha) is not None,
            "Harness source is invalid.")
    return {"schema": "darkrenamer-vm-automated-plan-v1", "campaign_id": campaign_id,
            "created_at": created_at, "profile_sha256": profile_sha256,
            "candidate": asdict(candidate), "harness_sha": harness_sha,
            "slots": execution_slots(profile)}


def validate_ledger(plan: object, campaign: object, *, profile: dict,
                    profile_sha256: str, candidate: Candidate, harness_sha: str) -> list[dict]:
    plan = require_exact_keys(plan, {"schema", "campaign_id", "created_at", "profile_sha256",
                                     "candidate", "harness_sha", "slots"}, "Campaign plan")
    expected = new_plan(profile, profile_sha256=profile_sha256, candidate=candidate,
                        harness_sha=harness_sha, campaign_id=plan["campaign_id"],
                        created_at=plan["created_at"])
    # Canonical integer fields need explicit type checks because bool == int.
    require(type(plan["slots"]) is list and len(plan["slots"]) == len(expected["slots"]),
            "Predeclared campaign slot count differs.")
    for actual, wanted in zip(plan["slots"], expected["slots"], strict=True):
        row = require_exact_keys(actual, {"id", "targets", "stability_index"}, "Plan slot")
        require(type(row["stability_index"]) is type(wanted["stability_index"]) and row == wanted,
                "Predeclared campaign slots differ from the fixed profile.")
    require(plan == expected, "Campaign plan differs from the independent source/candidate/profile.")
    campaign = require_exact_keys(campaign, {"schema", "campaign_id", "plan", "attempts", "backend"},
                                  "Campaign ledger")
    require(campaign["schema"] == "darkrenamer-vm-automated-campaign-v1" and
            campaign["campaign_id"] == plan["campaign_id"] and campaign["plan"] == "plan.json",
            "Campaign ledger does not match its frozen plan.")
    attempts = campaign["attempts"]
    require(type(attempts) is list and len(attempts) == len(expected["slots"]),
            "Every planned first attempt must be retained; retries cannot replace failures.")
    previous_end = timestamp(plan["created_at"])
    references = set()
    for execution, slot in zip(attempts, expected["slots"], strict=True):
        row = require_exact_keys(execution, {"slot_id", "attempt", "started_at", "ended_at", "exit_code",
                                            "bundle", "result", "transport", "desktop_lease"}, "Execution attempt")
        require(row["slot_id"] == slot["id"], "Execution order differs from the frozen plan.")
        require_int(row["attempt"], 1, 1, "First attempt number")
        require_int(row["exit_code"], 0, 0, "Controller exit code")
        started, ended = timestamp(row["started_at"]), timestamp(row["ended_at"])
        require(previous_end <= started < ended, "Executions overlap or precede their frozen plan.")
        previous_end = ended
        prefix = "runs/" + slot["id"] + "/"
        for field in ("bundle", "result", "transport", "desktop_lease"):
            path = row[field]
            require(type(path) is str and path.startswith(prefix) and path not in references,
                    "Raw execution references must belong to their unique planned run.")
            references.add(path)
    return attempts


def verify_process_lifecycle(value: object, *, executable_sha256: str,
                             expected_exit_method: str = "normal-close") -> tuple[int, int]:
    row = require_exact_keys(value, {"pid", "session_id", "start_time_utc_ticks", "executable_path",
                                     "executable_sha256", "start_observed", "exit_observed",
                                     "exit_code", "exit_method"}, "Process lifecycle")
    pid = require_int(row["pid"], 1, 0xFFFFFFFF, "Process PID")
    session = require_int(row["session_id"], 1, 0xFFFFFFFF, "Process session")
    ticks = row["start_time_utc_ticks"]
    require(type(ticks) is str and re.fullmatch(r"[1-9][0-9]{0,18}", ticks) is not None and
            int(ticks) <= 3_155_378_975_999_999_999, "Process creation ticks are invalid.")
    from vm_automated_platform import require_fixture_root
    require_fixture_root(row["executable_path"])
    require(row["executable_path"].endswith("\\DarkReNamer.exe") and
            row["executable_sha256"] == executable_sha256,
            "Process image differs from the exact candidate.")
    require(row["start_observed"] is True and row["exit_observed"] is True and
            row["exit_method"] == expected_exit_method,
            "Candidate process lifecycle is incomplete or exited by the wrong action.")
    if expected_exit_method == "normal-close":
        require_int(row["exit_code"], 0, 0, "Normal process exit code")
    else:
        require_int(row["exit_code"], -(1 << 31), (1 << 32) - 1, "Process exit code")
    return pid, session
