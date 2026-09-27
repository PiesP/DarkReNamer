"""Typed environment, keyboard delivery and cleanup predicates for fixed cells."""

from __future__ import annotations

import re

from darkrenamer_tooling.contracts.state import Identity, clean_journal_inventory
from darkrenamer_tooling.evidence.archive import EvidenceError, require_exact_keys, require_int


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def rectangle(value: object) -> dict:
    row = require_exact_keys(value, {"left", "top", "right", "bottom"}, "Display rectangle")
    for coordinate in row.values():
        require_int(coordinate, -65_536, 65_536, "Display coordinate")
    require(row["right"] > row["left"] and row["bottom"] > row["top"],
            "Display rectangle is empty or inverted.")
    return row


def contains(outer: dict, inner: dict) -> bool:
    return (outer["left"] <= inner["left"] < inner["right"] <= outer["right"] and
            outer["top"] <= inner["top"] < inner["bottom"] <= outer["bottom"])


def require_fixture_root(value: object) -> str:
    require(type(value) is str and 3 <= len(value) <= 32_767,
            "Fixture root path observation is unavailable.")
    path = value[4:] if value.startswith("\\\\?\\") else value
    require(re.match(r"^[A-Za-z]:\\", path) is not None,
            "Fixture root must be a local drive-absolute directory.")
    parts = path[3:].split("\\")
    require(all(part and part not in {".", ".."} and not part.endswith((".", " "))
                and not any(ord(char) < 32 or char in '<>:"/|?*' for char in part)
                for part in parts), "Fixture root contains an aliased or invalid component.")
    require(all(re.fullmatch(r"(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])", part.split(".")[0]) is None
                for part in parts), "Fixture root contains a device component.")
    return value


SMART_SCREEN_NATURAL_EXIT_TIMEOUT_MS = 360_000
SMART_SCREEN_MAXIMUM_POLLS = 362
_WINDOWS_UTC_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$")
_WINDOWS_RUNNER_SID = re.compile(r"^S-1-5-21-(?:\d+-){3}\d+$")
_MICROSOFT_WINDOWS_SUBJECT = re.compile(
    r"^CN=Microsoft Windows(?: Publisher)?, O=Microsoft Corporation(?:,|$)", re.IGNORECASE)


def _process_identity(value: object, label: str) -> tuple[int, str]:
    require(type(value) is str and len(value) <= 256,
            f"{label} is unavailable or too long.")
    match = re.fullmatch(
        r"([1-9][0-9]{0,9})\|(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z)",
        value)
    require(match is not None, f"{label} is malformed.")
    pid = int(match.group(1))
    require(1 <= pid <= 0xFFFFFFFF, f"{label} PID is out of range.")
    return pid, match.group(2)


def _windows_system_path(directory: str, leaf: str) -> str:
    return directory.rstrip("\\") + "\\System32\\" + leaf


def verify_smart_screen_natural_exit(value: object, initial_processes: object) -> None:
    """Validate the single-process exception to an otherwise empty cleanup delta."""
    row = require_exact_keys(value, {
        "schema_version", "status", "runner_sid", "runner_session_id",
        "candidate_identity", "broker", "timeout_ms", "elapsed_ms", "polls",
        "natural_exit_observed", "final_inventory_complete",
        "final_runner_process_delta_identities", "final_runner_task_delta_identities",
    }, "SmartScreen natural-exit evidence")
    require_int(row["schema_version"], 1, 1, "SmartScreen evidence schema")
    require(type(row["runner_sid"]) is str and len(row["runner_sid"]) <= 184 and
            _WINDOWS_RUNNER_SID.fullmatch(row["runner_sid"]) is not None,
            "SmartScreen runner SID is invalid.")
    runner_session = require_int(row["runner_session_id"], 1, 0xFFFFFFFF,
                                 "SmartScreen runner session")
    require(type(initial_processes) is list and len(initial_processes) <= 1,
            "Initial unexpected runner process inventory is malformed.")
    require(type(row["polls"]) is list and len(row["polls"]) <= SMART_SCREEN_MAXIMUM_POLLS,
            "SmartScreen poll inventory is unavailable or exceeds its bound.")
    require(type(row["final_runner_process_delta_identities"]) is list and
            type(row["final_runner_task_delta_identities"]) is list,
            "SmartScreen final delta inventories are unavailable.")
    require(type(row["natural_exit_observed"]) is bool and
            type(row["final_inventory_complete"]) is bool,
            "SmartScreen completion flags are not strict booleans.")
    timeout = require_int(row["timeout_ms"], 0, SMART_SCREEN_NATURAL_EXIT_TIMEOUT_MS,
                          "SmartScreen wait timeout")
    elapsed = require_int(row["elapsed_ms"], 0, 2_147_483_647,
                          "SmartScreen wait duration")
    if row["status"] == "not-required":
        require(not initial_processes and row["candidate_identity"] is None and
                row["broker"] is None and timeout == 0 and elapsed == 0 and
                row["polls"] == [] and row["natural_exit_observed"] is False and
                row["final_inventory_complete"] is True and
                row["final_runner_process_delta_identities"] == [] and
                row["final_runner_task_delta_identities"] == [],
                "Unneeded SmartScreen evidence contains a process or wait observation.")
        return

    require(row["status"] == "natural-exit",
            "Controller cleanup has no verified SmartScreen natural-exit result.")
    require(timeout == SMART_SCREEN_NATURAL_EXIT_TIMEOUT_MS and elapsed <= timeout and
            row["natural_exit_observed"] is True and
            row["final_inventory_complete"] is True,
            "SmartScreen natural-exit wait exceeded its deadline or lacks a complete final inventory.")
    require(type(row["candidate_identity"]) is str,
            "SmartScreen candidate identity is unavailable.")
    candidate_pid, candidate_created = _process_identity(
        row["candidate_identity"], "SmartScreen candidate identity")
    require(type(initial_processes) is list and len(initial_processes) == 1,
            "SmartScreen must account for exactly one initial process delta.")
    initial = require_exact_keys(initial_processes[0], {
        "identity", "pid", "session_id", "creation_time_utc", "executable_path",
    }, "Initial SmartScreen process delta")
    require_int(initial["pid"], candidate_pid, candidate_pid, "Initial SmartScreen PID")
    require_int(initial["session_id"], runner_session, runner_session,
                "Initial SmartScreen session")
    require(type(initial["creation_time_utc"]) is str and
            _WINDOWS_UTC_TIMESTAMP.fullmatch(initial["creation_time_utc"]) is not None and
            initial["creation_time_utc"] == candidate_created and
            initial["identity"] == row["candidate_identity"] and
            type(initial["executable_path"]) is str and
            len(initial["executable_path"]) <= 32_767,
            "Initial SmartScreen process lifetime or path is malformed.")

    broker = require_exact_keys(row["broker"], {
        "windows_directory", "process_identity", "process_pid", "process_creation_time_utc",
        "process_session_id", "process_owner_sid", "process_executable_path",
        "process_path_verified", "process_command_line_arguments",
        "process_signature_status", "process_signer_subject", "process_signer_thumbprint",
        "parent_identity", "parent_pid", "parent_creation_time_utc", "parent_session_id",
        "parent_owner_sid", "parent_executable_path", "parent_path_verified",
        "parent_command_line_arguments", "parent_signature_status", "parent_signer_subject",
        "parent_signer_thumbprint", "service_name", "service_process_id", "service_state",
    }, "SmartScreen broker identity")
    directory = broker["windows_directory"]
    require(type(directory) is str and len(directory) <= 260 and
            re.fullmatch(r"[A-Za-z]:\\[^\\/:*?\"<>|]+(?:\\[^\\/:*?\"<>|]+)*", directory),
            "SmartScreen Windows directory is not canonical drive-absolute syntax.")
    directory_parts = directory[3:].split("\\")
    require(all(part and part not in {".", ".."} and not part.endswith((".", " "))
                for part in directory_parts),
            "SmartScreen Windows directory contains an aliased component.")
    process_path = _windows_system_path(directory, "smartscreen.exe")
    parent_path = _windows_system_path(directory, "svchost.exe")
    require(broker["process_identity"] == row["candidate_identity"] and
            require_int(broker["process_pid"], candidate_pid, candidate_pid,
                        "SmartScreen broker PID") == candidate_pid and
            broker["process_creation_time_utc"] == candidate_created and
            require_int(broker["process_session_id"], runner_session, runner_session,
                        "SmartScreen broker session") == runner_session and
            broker["process_owner_sid"] == row["runner_sid"] and
            type(broker["process_path_verified"]) is bool and
            broker["process_path_verified"] is True and
            type(broker["process_executable_path"]) is str and
            broker["process_executable_path"].casefold() == process_path.casefold() and
            initial["executable_path"].casefold() == process_path.casefold(),
            "SmartScreen candidate path, owner or lifetime differs from its initial delta.")
    require(type(broker["process_creation_time_utc"]) is str and
            _WINDOWS_UTC_TIMESTAMP.fullmatch(broker["process_creation_time_utc"]) is not None,
            "SmartScreen process creation time is malformed.")
    for prefix in ("process", "parent"):
        require(broker[f"{prefix}_signature_status"] == "Valid" and
                type(broker[f"{prefix}_signer_subject"]) is str and
                len(broker[f"{prefix}_signer_subject"]) <= 512 and
                _MICROSOFT_WINDOWS_SUBJECT.match(broker[f"{prefix}_signer_subject"]) is not None and
                type(broker[f"{prefix}_signer_thumbprint"]) is str and
                re.fullmatch(r"(?i:[0-9a-f]{40})", broker[f"{prefix}_signer_thumbprint"]) is not None,
                f"SmartScreen {prefix} Authenticode evidence is invalid.")
    process_arguments = broker["process_command_line_arguments"]
    require(type(process_arguments) is list and len(process_arguments) == 2 and
            all(type(argument) is str and len(argument) <= 4096 for argument in process_arguments) and
            process_arguments[0].casefold() == process_path.casefold() and
            process_arguments[1].casefold() == "-embedding",
            "SmartScreen command-line arguments are not exact.")

    parent_pid, parent_created = _process_identity(
        broker["parent_identity"], "SmartScreen parent identity")
    require_int(broker["parent_pid"], parent_pid, parent_pid, "SmartScreen parent PID")
    require(type(broker["parent_creation_time_utc"]) is str and
            broker["parent_creation_time_utc"] == parent_created and
            _WINDOWS_UTC_TIMESTAMP.fullmatch(parent_created) is not None and
            parent_created <= candidate_created and
            require_int(broker["parent_session_id"], 0, 0xFFFFFFFF,
                        "SmartScreen parent session") == 0 and
            broker["parent_owner_sid"] == "S-1-5-18" and
            type(broker["parent_path_verified"]) is bool and
            broker["parent_path_verified"] is True and
            type(broker["parent_executable_path"]) is str and
            broker["parent_executable_path"].casefold() == parent_path.casefold(),
            "SmartScreen parent is not the exact SYSTEM service-host process.")
    parent_arguments = broker["parent_command_line_arguments"]
    require(type(parent_arguments) is list and 3 <= len(parent_arguments) <= 6 and
            all(type(argument) is str and len(argument) <= 4096 for argument in parent_arguments) and
            parent_arguments[0].casefold() == parent_path.casefold() and
            parent_arguments[1].casefold() == "-k" and
            parent_arguments[2].casefold() == "dcomlaunch",
            "SmartScreen parent command line is not an exact DcomLaunch invocation.")
    parent_tail = tuple(argument.casefold() for argument in parent_arguments[3:])
    require(parent_tail in ((), ("-p",), ("-s", "dcomlaunch"),
                            ("-s", "dcomlaunch", "-p")),
            "SmartScreen parent command line is not an exact DcomLaunch invocation.")
    require(broker["service_name"] == "DcomLaunch" and
            require_int(broker["service_process_id"], parent_pid, parent_pid,
                        "DcomLaunch service PID") == parent_pid and
            broker["service_state"] == "Running",
            "DcomLaunch is not bound to the exact running parent process.")

    polls = row["polls"]
    require(type(polls) is list and 1 <= len(polls) <= SMART_SCREEN_MAXIMUM_POLLS,
            "SmartScreen natural-exit poll series is incomplete or oversized.")
    previous_elapsed = -1
    for poll_index, raw_poll in enumerate(polls):
        poll = require_exact_keys(raw_poll, {
            "elapsed_ms", "inventory_complete", "process_delta_identities",
            "task_delta_identities", "owned_root_process_count",
        }, "SmartScreen natural-exit poll")
        poll_elapsed = require_int(poll["elapsed_ms"], 0, timeout,
                                   "SmartScreen poll duration")
        require(poll_elapsed >= previous_elapsed and poll["inventory_complete"] is True,
                "SmartScreen poll time regressed or inventory was incomplete.")
        previous_elapsed = poll_elapsed
        process_ids = poll["process_delta_identities"]
        task_ids = poll["task_delta_identities"]
        require(type(process_ids) is list and len(process_ids) <= 1 and
                all(identity == row["candidate_identity"] for identity in process_ids) and
                type(task_ids) is list and not task_ids and
                require_int(poll["owned_root_process_count"], 0, 0,
                            "Owned-root processes during SmartScreen wait") == 0,
                "SmartScreen wait observed another process, task or owned-root process.")
        if poll_index == 0:
            require(process_ids == [row["candidate_identity"]],
                    "SmartScreen poll series does not start with the classified process.")
        elif poll_index < len(polls) - 1:
            require(process_ids == [row["candidate_identity"]],
                    "SmartScreen process disappeared before the final natural-exit poll.")
    require(polls[-1]["process_delta_identities"] == [] and
            polls[-1]["task_delta_identities"] == [] and
            row["final_runner_process_delta_identities"] == [] and
            row["final_runner_task_delta_identities"] == [],
            "SmartScreen final inventory still contains a process or task delta.")


def verify_environment(value: object, target: dict, *, candidate_pid: int, session_id: int) -> None:
    """Compare observed platform/display facts to a target from the trusted profile."""
    require_int(candidate_pid, 1, 0xFFFFFFFF, "Candidate PID")
    require_int(session_id, 1, 0xFFFFFFFF, "Desktop session")
    row = require_exact_keys(value, {"schema_version", "platform", "process", "desktop",
                                     "fixture_volume", "target_display"}, "Environment")
    require_int(row["schema_version"], 1, 1, "Environment schema")
    platform = require_exact_keys(row["platform"], {"os_product_name", "display_version",
                                                  "build_number", "architecture", "product_type"}, "Platform")
    for field in ("os_product_name", "display_version"):
        require(type(platform[field]) is str and 0 < len(platform[field]) <= 128,
                "Windows version observation is unavailable.")
    # ProductName may retain Windows 10 on Windows 11; the numeric build matters.
    require_int(platform["build_number"], 22_000, 999_999, "Windows build")
    require_int(platform["product_type"], 1, 1, "Windows client product type")
    require(platform["architecture"] == "x86_64", "Observed OS architecture is unsupported.")
    process = require_exact_keys(row["process"], {"pid", "session_id", "is_elevated"}, "Candidate process")
    require_int(process["pid"], candidate_pid, candidate_pid, "Candidate process PID")
    require_int(process["session_id"], session_id, session_id, "Candidate process session")
    require(process["is_elevated"] is False, "Candidate token is elevated or unobserved.")
    desktop = require_exact_keys(row["desktop"], {"input_desktop_active", "locked"}, "Desktop")
    require(desktop["input_desktop_active"] is True and desktop["locked"] is False,
            "Input desktop is unavailable or locked.")
    volume = require_exact_keys(row["fixture_volume"], {"filesystem", "root_path", "root_identity"}, "Fixture volume")
    require(volume["filesystem"] == "NTFS", "Fixture volume is not the supported filesystem.")
    require_fixture_root(volume["root_path"])
    Identity.parse(volume["root_identity"])
    display = require_exact_keys(row["target_display"], {"hwnd", "process_id", "session_id",
                                                        "dpi_x", "dpi_y", "monitor_rect", "work_rect",
                                                        "window_rect", "text_scale_percent", "high_contrast_flags"},
                                 "Candidate display")
    require_int(display["hwnd"], 1, (1 << 63) - 1, "Candidate HWND")
    require_int(display["process_id"], candidate_pid, candidate_pid, "Window PID")
    require_int(display["session_id"], session_id, session_id, "Window session")
    for axis in ("dpi_x", "dpi_y"):
        require_int(display[axis], target["hwnd_dpi"], target["hwnd_dpi"], "Actual window DPI")
    require_int(display["text_scale_percent"], target["text_scale_percent"],
                target["text_scale_percent"], "Actual text scale")
    flags = require_int(display["high_contrast_flags"], 0, 0xFFFFFFFF, "High Contrast flags")
    require(bool(flags & 1) == (target["contrast"] == "high-contrast"),
            "Actual High Contrast mode differs from the required cell.")
    monitor, work, window = (rectangle(display[key]) for key in ("monitor_rect", "work_rect", "window_rect"))
    require(monitor["right"] - monitor["left"] == target["desktop_width"] and
            monitor["bottom"] - monitor["top"] == target["desktop_height"],
            "Observed monitor geometry differs from the required cell.")
    require(contains(monitor, work), "Work area is outside the observed monitor.")
    require(window["left"] < work["right"] and window["right"] > work["left"] and
            window["top"] < work["bottom"] and window["bottom"] > work["top"],
            "Candidate window does not intersect its observed work area.")


def verify_cleanup(guest: object, transport: object, *, require_candidate_export: bool = False) -> None:
    """Require actual post-cleanup inventories, not only producer pass flags."""
    guest_fields = {"owned_processes_after", "runtime_root_after", "journal_after"}
    if require_candidate_export:
        guest_fields.add("candidate_export_root_after")
    guest = require_exact_keys(guest, guest_fields, "Guest cleanup")
    host = verify_controller_cleanup(transport)
    for rows in (guest["owned_processes_after"], host["owned_processes_after"]):
        require(type(rows) is list and not rows, "Owned test processes remain after cleanup.")
    root = require_exact_keys(guest["runtime_root_after"], {"exists", "entries"}, "Runtime root cleanup")
    require(root["exists"] is False and type(root["entries"]) is list and not root["entries"],
            "Owned runtime root remains or its inventory is unavailable.")
    if require_candidate_export:
        export_root = require_exact_keys(
            guest["candidate_export_root_after"],
            {"exists", "ordinary_directory", "entries"},
            "Candidate export root cleanup",
        )
        require(export_root["exists"] is False and export_root["ordinary_directory"] is True and
                type(export_root["entries"]) is list and not export_root["entries"],
                "Candidate export root remains or its inventory is unavailable.")
    journal = require_exact_keys(guest["journal_after"], {"entries"}, "Final journal inventory")
    clean_journal_inventory(journal["entries"])
    for key in ("scheduled_task_present", "guest_root_present", "trusted_task_root_present"):
        require(host[key] is False, f"Owned VM resource remains after cleanup: {key}.")


def verify_controller_cleanup(transport: object) -> dict:
    """Validate controller raw cleanup evidence before trusting its pass flag."""
    host = require_exact_keys(transport, {
        "scheduled_task_present", "guest_root_present", "trusted_task_root_present",
        "process_jobs_closed", "runner_process_inventory_complete",
        "unexpected_runner_tasks", "unexpected_runner_processes",
        "unexpected_runner_tasks_after_intervention",
        "unexpected_runner_processes_after_intervention",
        "unexpected_runner_tasks_after_delete",
        "unexpected_runner_processes_after_delete",
        "removed_runner_tasks", "terminated_runner_processes",
        "resource_cleanup_errors", "smart_screen_natural_exit", "owned_processes_after",
    }, "Controller cleanup")
    for key in ("scheduled_task_present", "guest_root_present", "trusted_task_root_present"):
        require(host[key] is False, f"Owned VM resource remains after cleanup: {key}.")
    require(host["process_jobs_closed"] is True and
            host["runner_process_inventory_complete"] is True,
            "Controller did not confirm closed process jobs and a complete runner inventory.")
    for key in ("unexpected_runner_tasks", "unexpected_runner_tasks_after_intervention",
                "unexpected_runner_processes_after_intervention",
                "unexpected_runner_tasks_after_delete",
                "unexpected_runner_processes_after_delete",
                "removed_runner_tasks", "terminated_runner_processes",
                "resource_cleanup_errors", "owned_processes_after"):
        require(type(host[key]) is list and not host[key],
                f"Controller cleanup retained or changed unrelated runner resources: {key}.")
    require(type(host["unexpected_runner_processes"]) is list,
            "Initial runner process inventory is unavailable.")
    verify_smart_screen_natural_exit(
        host["smart_screen_natural_exit"], host["unexpected_runner_processes"])
    return host


def verify_keyboard_events(value: object, *, candidate_pid: int, session_id: int,
                           main_workbench_hwnd: int) -> None:
    require_int(candidate_pid, 1, 0xFFFFFFFF, "Candidate PID")
    require_int(session_id, 1, 0xFFFFFFFF, "Desktop session")
    require_int(main_workbench_hwnd, 1, (1 << 63) - 1, "Expected workbench HWND")
    require(type(value) is list and len(value) == 2,
            "Core keyboard flow needs exactly Escape and explicit Apply Enter observations.")
    for raw, action, focused_id in zip(value, ("escape", "enter"),
                                      ("CommandButton_2", "CommandLink_1101"), strict=True):
        event = require_exact_keys(raw, {"action", "input_method", "target", "focused_before",
                                        "foreground_before", "foreground_after"}, "Keyboard event")
        require(event["action"] == action and event["input_method"] == "keyboard",
                "UIA invocation cannot satisfy actual keyboard delivery.")
        target = require_exact_keys(event["target"], {"hwnd", "pid", "session_id", "class"}, "Keyboard target")
        require_int(target["hwnd"], 1, (1 << 63) - 1, "Keyboard target HWND")
        require_int(target["pid"], candidate_pid, candidate_pid, "Keyboard target PID")
        require_int(target["session_id"], session_id, session_id, "Keyboard target session")
        require(target["class"] == "#32770", "Keyboard target is not the candidate confirmation dialog.")
        focused = require_exact_keys(event["focused_before"], {"hwnd", "pid", "session_id", "class",
                                                              "automation_id", "control_type", "root_hwnd"}, "Focused confirmation control")
        require_int(focused["hwnd"], 1, (1 << 63) - 1, "Focused control HWND")
        require_int(focused["root_hwnd"], target["hwnd"], target["hwnd"], "Focused control root HWND")
        require_int(focused["pid"], candidate_pid, candidate_pid, "Focused control PID")
        require_int(focused["session_id"], session_id, session_id, "Focused control session")
        require(focused["class"] == "Button" and focused["control_type"] == "ControlType.Button" and
                focused["automation_id"] == focused_id,
                "Escape must observe default Cancel; Enter must observe explicitly selected Apply.")
        for phase in ("foreground_before", "foreground_after"):
            observed = require_exact_keys(event[phase], {"hwnd", "process_id", "session_id", "window_class"}, "Keyboard foreground")
            require_int(observed["hwnd"], 1, (1 << 63) - 1, "Foreground HWND")
            require_int(observed["process_id"], candidate_pid, candidate_pid, "Foreground PID")
            require_int(observed["session_id"], session_id, session_id, "Foreground session")
            if phase == "foreground_before":
                require(observed["hwnd"] == target["hwnd"] and observed["window_class"] == "#32770",
                        "Keyboard input was not directed to the candidate confirmation.")
            else:
                require(observed["hwnd"] == main_workbench_hwnd and observed["window_class"] == "DarkReNamerWindow",
                        "Keyboard confirmation did not return to the candidate workbench.")
