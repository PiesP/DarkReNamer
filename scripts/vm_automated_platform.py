"""Typed environment, keyboard delivery and cleanup predicates for fixed cells."""

from __future__ import annotations

import re

from vm_automated_evidence import EvidenceError, require_exact_keys, require_int
from vm_automated_state import Identity, clean_journal_inventory


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


def verify_cleanup(guest: object, transport: object) -> None:
    """Require actual post-cleanup inventories, not only producer pass flags."""
    guest = require_exact_keys(guest, {"owned_processes_after", "runtime_root_after", "journal_after"}, "Guest cleanup")
    host = require_exact_keys(transport, {"scheduled_task_present", "guest_root_present", "owned_processes_after"},
                              "Controller cleanup")
    for rows in (guest["owned_processes_after"], host["owned_processes_after"]):
        require(type(rows) is list and not rows, "Owned test processes remain after cleanup.")
    root = require_exact_keys(guest["runtime_root_after"], {"exists", "entries"}, "Runtime root cleanup")
    require(root["exists"] is False and type(root["entries"]) is list and not root["entries"],
            "Owned runtime root remains or its inventory is unavailable.")
    journal = require_exact_keys(guest["journal_after"], {"entries"}, "Final journal inventory")
    clean_journal_inventory(journal["entries"])
    require(host["scheduled_task_present"] is False and host["guest_root_present"] is False,
            "Owned scheduled task or guest root remains after cleanup.")


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
