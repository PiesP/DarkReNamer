"""Typed environment, keyboard delivery and cleanup predicates for fixed cells."""

from __future__ import annotations

import base64
import binascii
from datetime import datetime, timedelta
import hashlib
import re
import xml.etree.ElementTree as ET

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


RUNNER_PROCESS_NATURAL_EXIT_TIMEOUT_MS = 360_000
RUNNER_PROCESS_MAXIMUM_POLLS = 362
_WINDOWS_UTC_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$")
_WINDOWS_RUNNER_SID = re.compile(r"^S-1-5-21-(?:\d+-){3}\d+$")
_MICROSOFT_WINDOWS_SUBJECT = re.compile(
    r"^CN=Microsoft Windows(?: Publisher)?, O=Microsoft Corporation(?:,|$)", re.IGNORECASE)
_SPOTLIGHT_NAME = "MicrosoftWindows.Client.CBS"
_SPOTLIGHT_PUBLISHER_ID = "cw5n1h2txyewy"
_SPOTLIGHT_FAMILY = _SPOTLIGHT_NAME + "_" + _SPOTLIGHT_PUBLISHER_ID
_SPOTLIGHT_PUBLISHER = "CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"
_SPOTLIGHT_APPLICATION = "Global.DesktopSpotlight"
_SPOTLIGHT_AUMID = _SPOTLIGHT_FAMILY + "!" + _SPOTLIGHT_APPLICATION
_SPOTLIGHT_SERVER = "Global.DesktopSpotlight.AppXz2j21w56bgxkgsjhtn7zkjsepq96erz2.mca"
_FOUNDATION = "{http://schemas.microsoft.com/appx/manifest/foundation/windows10}"
_UAP = "{http://schemas.microsoft.com/appx/manifest/uap/windows10}"
_UAP3 = "{http://schemas.microsoft.com/appx/manifest/uap/windows10/3}"
_TRUSTED_PATH_OWNERS = {
    "S-1-5-18", "S-1-5-32-544",
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",
}
_PATH_WRITE_MASK = (0x2 | 0x4 | 0x10 | 0x40 | 0x100 | 0x10000 | 0x40000 |
                    0x80000 | 0x10000000 | 0x40000000)
_NATIVE_IDENTITY_FIELDS = {
    "pid", "creation_filetime_100ns", "owner_sid", "session_id", "image_path",
    "open_error", "pid_error", "times_error", "image_error", "token_error",
    "token_sid_error", "token_session_error",
}
_NATIVE_PACKAGE_FIELDS = {
    "package_first_status", "package_status", "aumid_first_status", "aumid_status",
    "package_full_name", "aumid",
}


def _filetime(value: object, label: str) -> int:
    # Keep the seventh fractional digit: float and datetime microseconds lose it.
    require(type(value) is str and re.fullmatch(r"[1-9][0-9]{0,18}", value) is not None,
            f"{label} is not a canonical positive FILETIME.")
    result = int(value)
    require(result <= 2_650_467_743_999_999_999, f"{label} exceeds the UTC calendar range.")
    return result


def _filetime_utc(value: int) -> str:
    seconds, fraction = divmod(value, 10_000_000)
    stamp = datetime(1601, 1, 1) + timedelta(seconds=seconds)
    return (f"{stamp.year:04d}-{stamp.month:02d}-{stamp.day:02d}T"
            f"{stamp.hour:02d}:{stamp.minute:02d}:{stamp.second:02d}.{fraction:07d}Z")


def _verify_native_identity(value: object, *, pid: int, created: str, owner: str,
                            session: int, path: str, spotlight: bool = False) -> dict:
    fields = _NATIVE_IDENTITY_FIELDS | (_NATIVE_PACKAGE_FIELDS if spotlight else set())
    row = require_exact_keys(value, fields, "Native process identity")
    for field in _NATIVE_IDENTITY_FIELDS:
        if field.endswith("_error"):
            require_int(row[field], 0, 0, f"Native {field}")
    require_int(row["pid"], pid, pid, "Native PID")
    require_int(row["session_id"], session, session, "Native token session")
    require(row["owner_sid"] == owner and type(row["image_path"]) is str and
            row["image_path"].casefold() == path.casefold(),
            "Native process image or token owner differs from the classified process.")
    native_created = _filetime(row["creation_filetime_100ns"], "Native creation time")
    require(created.endswith("0Z") and _filetime_utc(native_created // 10 * 10) == created,
            "Native creation time does not normalize to the original CIM microsecond lifetime.")
    if spotlight:
        for field in ("package_first_status", "aumid_first_status"):
            require_int(row[field], 122, 122, f"Native {field}")
        for field in ("package_status", "aumid_status"):
            require_int(row[field], 0, 0, f"Native {field}")
        require(type(row["package_full_name"]) is str and
                1 <= len(row["package_full_name"]) <= 127 and row["aumid"] == _SPOTLIGHT_AUMID,
                "Native DesktopSpotlight package or AUMID is unavailable or different.")
    return row


def _verify_spotlight_registration(value: object, *, runner_sid: str, directory: str,
                                    native: dict) -> dict:
    row = require_exact_keys(value, {"preflight", "current"}, "DesktopSpotlight registration")
    identity_fields = {"name", "package_full_name", "package_family_name", "publisher",
                       "publisher_id", "version", "architecture", "resource_id"}
    preflight = require_exact_keys(row["preflight"], identity_fields | {
        "runner_sid", "install_location", "signature_kind", "status",
        "is_development_mode", "child_lifecycle",
    }, "DesktopSpotlight preflight registration")
    version = preflight["version"]
    require(type(version) is str and len(version) <= 32 and
            re.fullmatch(r"(?:0|[1-9][0-9]{0,4})(?:\.(?:0|[1-9][0-9]{0,4})){3}", version) is not None and
            all(int(part) <= 65535 for part in version.split(".")),
            "DesktopSpotlight package version is not canonical.")
    package_name = f"{_SPOTLIGHT_NAME}_{version}_x64__{_SPOTLIGHT_PUBLISHER_ID}"
    package_path = directory + "\\SystemApps\\" + _SPOTLIGHT_FAMILY
    require(preflight["runner_sid"] == runner_sid and preflight["name"] == _SPOTLIGHT_NAME and
            preflight["package_family_name"] == _SPOTLIGHT_FAMILY and
            preflight["publisher"] == _SPOTLIGHT_PUBLISHER and
            preflight["publisher_id"] == _SPOTLIGHT_PUBLISHER_ID and
            preflight["architecture"] == "x64" and preflight["resource_id"] == "" and
            preflight["package_full_name"] == package_name == native["package_full_name"] and
            type(preflight["install_location"]) is str and
            preflight["install_location"].casefold() == package_path.casefold() and
            preflight["signature_kind"] == "System" and preflight["status"] == "Ok" and
            preflight["is_development_mode"] is False,
            "DesktopSpotlight is not the exact current-user system CBS registration.")
    child = require_exact_keys(preflight["child_lifecycle"], {
        "pid", "start_time_utc_ticks", "exit_code", "exited", "streams_complete",
        "exact_lifetime_absent", "process_job_closed",
    }, "DesktopSpotlight registration preflight child")
    require_int(child["pid"], 1, 0xFFFFFFFF, "Registration preflight child PID")
    require(type(child["start_time_utc_ticks"]) is str and
            re.fullmatch(r"[1-9][0-9]{0,18}", child["start_time_utc_ticks"]) is not None,
            "Registration preflight child creation ticks are unavailable.")
    child_ticks = int(child["start_time_utc_ticks"])
    require(504_911_232_000_000_000 < child_ticks <= 3_155_378_975_999_999_999 and
            child_ticks - 504_911_232_000_000_000 < int(native["creation_filetime_100ns"]),
            "Registration preflight did not precede the classified process.")
    require_int(child["exit_code"], 0, 0, "Registration preflight child exit code")
    require(all(child[field] is True for field in (
        "exited", "streams_complete", "exact_lifetime_absent", "process_job_closed")),
        "Registration preflight child did not complete and clean its exact lifetime/job.")
    current = require_exact_keys(row["current"], identity_fields | {
        "open_status", "first_status", "second_status", "close_status", "required_bytes",
        "returned_bytes", "count", "request_flags", "property_flags", "caller_sid", "path",
    }, "DesktopSpotlight current-user native registration")
    for field in ("open_status", "second_status", "close_status"):
        require_int(current[field], 0, 0, f"Native registration {field}")
    require_int(current["first_status"], 122, 122, "Native registration sizing status")
    required_bytes = require_int(current["required_bytes"], 80, 65536, "Native registration buffer")
    require_int(current["returned_bytes"], 80, required_bytes, "Native registration returned bytes")
    require_int(current["count"], 1, 1, "Native registration head count")
    require_int(current["request_flags"], 0x110, 0x110, "Native registration request flags")
    properties = require_int(current["property_flags"], 0, 0xFFFFFFFF, "Native package properties")
    require(properties & 0x1000F == 0 and current["caller_sid"] == runner_sid and
            all(current[field] == preflight[field] for field in identity_fields) and
            type(current["path"]) is str and current["path"].casefold() == package_path.casefold(),
            "Native registration differs from the preflight or has unsupported package properties.")
    return preflight


def _verify_spotlight_manifest(value: object, *, directory: str, registration: dict) -> None:
    row = require_exact_keys(value, {"path", "byte_length", "sha256", "data_base64", "path_objects"},
                             "DesktopSpotlight raw manifest")
    package_path = directory + "\\SystemApps\\" + _SPOTLIGHT_FAMILY
    path = package_path + "\\AppxManifest.xml"
    require(type(row["path"]) is str and row["path"].casefold() == path.casefold(),
            "DesktopSpotlight manifest path differs from its registered system package.")
    length = require_int(row["byte_length"], 1, 1_048_576, "DesktopSpotlight manifest length")
    require(type(row["sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", row["sha256"]) is not None and
            type(row["data_base64"]) is str and len(row["data_base64"]) <= 1_398_104,
            "DesktopSpotlight manifest bytes or digest are unavailable.")
    try:
        data = base64.b64decode(row["data_base64"], validate=True)
        text = data.decode("utf-8-sig")
    except (ValueError, binascii.Error, UnicodeError) as error:
        raise EvidenceError("DesktopSpotlight manifest is not bounded UTF-8 base64.") from error
    require(len(data) == length and base64.b64encode(data).decode("ascii") == row["data_base64"] and
            hashlib.sha256(data).hexdigest() == row["sha256"],
            "DesktopSpotlight manifest length, canonical base64 or digest differs from raw bytes.")
    require("\x00" not in text and "<!DOCTYPE" not in text.upper() and "<!ENTITY" not in text.upper(),
            "DesktopSpotlight manifest contains unsupported DTD/entity declarations or encoding.")
    try:
        root = ET.fromstring(data)
    except (ET.ParseError, ValueError) as error:
        raise EvidenceError("DesktopSpotlight manifest XML is malformed.") from error
    identities = root.findall(_FOUNDATION + "Identity")
    applications = root.findall(_FOUNDATION + "Applications")
    require(root.tag == _FOUNDATION + "Package" and len(identities) == 1 and len(applications) == 1,
            "DesktopSpotlight manifest has no unique namespace-correct package identity/applications.")
    identity = identities[0].attrib
    require(identity.get("Name") == registration["name"] and
            identity.get("Publisher") == registration["publisher"] and
            identity.get("Version") == registration["version"] and
            identity.get("ProcessorArchitecture") == registration["architecture"] and
            identity.get("ResourceId", "") == "",
            "DesktopSpotlight raw manifest identity differs from its live registration.")
    apps = applications[0].findall(_FOUNDATION + "Application")
    require(1 <= len(apps) <= 128 and len({app.get("Id") for app in apps}) == len(apps),
            "DesktopSpotlight manifest application IDs are ambiguous or oversized.")
    selected = [app for app in apps if app.get("Id") == _SPOTLIGHT_APPLICATION]
    require(len(selected) == 1, "DesktopSpotlight manifest has no exact unique Application.")
    extensions = selected[0].findall(_FOUNDATION + "Extensions")
    require(len(extensions) == 1, "DesktopSpotlight manifest extensions are ambiguous.")
    background = []
    services = []
    for extension in extensions[0]:
        if extension.get("Category") == "windows.backgroundTasks":
            require(extension.tag == _FOUNDATION + "Extension",
                    "DesktopSpotlight background-task declaration uses the wrong namespace.")
            tasks = extension.findall(_FOUNDATION + "BackgroundTasks")
            require(len(tasks) == 1 and tasks[0].attrib == {} and len(tasks[0]) == 1 and
                    tasks[0][0].tag == _FOUNDATION + "Task",
                    "DesktopSpotlight background task shape is unsupported.")
            background.append((extension.get("EntryPoint"), tasks[0][0].get("Type")))
        if extension.get("Category") == "windows.appService":
            service = extension.findall(_UAP3 + "AppService")
            require(extension.tag == _UAP + "Extension" and len(service) == 1,
                    "DesktopSpotlight app service uses the wrong namespace or shape.")
            services.append((extension.get("EntryPoint"), service[0].get("Name")))
    require(len(background) == 4 and set(background) == {
        ("DesktopSpotlight.BackgroundTask.UpdateTimer", "timer"),
        ("DesktopSpotlight.BackgroundTask.RegistrationStatusCheck", "systemEvent"),
        ("DesktopSpotlight.BackgroundTask.OnlineIdChange", "systemEvent"),
        ("DesktopSpotlight.BackgroundTask.Maintenance", "systemEvent"),
    } and services == [("DesktopSpotlight.BackgroundTask.AppService", "com.microsoft.desktopspotlight")],
        "DesktopSpotlight task/app-service declarations differ from the exact Application contract.")

    paths = [directory[:3], directory, directory + "\\SystemApps", package_path, path]
    require(type(row["path_objects"]) is list and len(row["path_objects"]) == 5,
            "DesktopSpotlight protected path inventory is incomplete.")
    for index, (raw, expected_path) in enumerate(zip(row["path_objects"], paths)):
        obj = require_exact_keys(raw, {"path", "is_directory", "attributes", "owner_sid", "dacl_present", "aces"},
                                 "DesktopSpotlight protected path object")
        attributes = require_int(obj["attributes"], 0, 0xFFFFFFFF, "Protected path attributes")
        require(type(obj["path"]) is str and obj["path"].casefold() == expected_path.casefold() and
                obj["is_directory"] is (index < 4) and bool(attributes & 0x10) == (index < 4) and
                attributes & 0x400 == 0 and type(obj["owner_sid"]) is str and
                obj["owner_sid"] in _TRUSTED_PATH_OWNERS and obj["dacl_present"] is True and
                type(obj["aces"]) is list and 1 <= len(obj["aces"]) <= 64,
                "DesktopSpotlight package path is aliased, unprotected or lacks a complete DACL.")
        mask = _PATH_WRITE_MASK & ~0x4 if index == 0 else _PATH_WRITE_MASK
        for raw_ace in obj["aces"]:
            ace = require_exact_keys(raw_ace, {"ace_type", "ace_flags", "access_mask", "sid"}, "Protected path ACE")
            kind = require_int(ace["ace_type"], 0, 10, "Path ACE type")
            flags = require_int(ace["ace_flags"], 0, 255, "Path ACE flags")
            rights = require_int(ace["access_mask"], 0, 0xFFFFFFFF, "Path ACE access mask")
            require(kind in {0, 1, 9, 10} and type(ace["sid"]) is str and len(ace["sid"]) <= 184 and
                    re.fullmatch(r"S-1-(?:[0-9]+-)*[0-9]+", ace["sid"]) is not None,
                    "DesktopSpotlight path ACE is unsupported or malformed.")
            require(kind not in {0, 9} or flags & 0x8 != 0 or rights & mask == 0 or
                    ace["sid"] in _TRUSTED_PATH_OWNERS,
                    "DesktopSpotlight package path permits an untrusted effective write grant.")


def _verify_native_exit(value: object, native: dict) -> None:
    row = require_exact_keys(value, {
        "pid", "creation_filetime_100ns", "exit_filetime_100ns", "wait_result",
        "times_succeeded", "times_win32_error", "exit_code_succeeded", "exit_code_win32_error",
        "exit_code", "handle_closed", "close_win32_error",
    }, "DesktopSpotlight same-handle exit")
    require_int(row["pid"], native["pid"], native["pid"], "Native exit PID")
    created = _filetime(row["creation_filetime_100ns"], "Native exit creation time")
    exited = _filetime(row["exit_filetime_100ns"], "Native exit time")
    require(row["creation_filetime_100ns"] == native["creation_filetime_100ns"] and exited >= created,
            "Native exit receipt does not bind the original exact process lifetime.")
    require_int(row["wait_result"], 0, 0, "Native process wait result")
    require_int(row["exit_code"], 0, 0xFFFFFFFF, "Native process exit code")
    for field in ("times_win32_error", "exit_code_win32_error", "close_win32_error"):
        require_int(row[field], 0, 0, f"Native exit {field}")
    require(row["times_succeeded"] is True and row["exit_code_succeeded"] is True and
            row["handle_closed"] is True, "Native process exit or handle closure was not observed.")


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


def verify_runner_process_natural_exit(value: object, initial_processes: object) -> None:
    """Validate the single-process exception to an otherwise empty cleanup delta."""
    row = require_exact_keys(value, {
        "schema_version", "status", "process_class", "native_exit", "initial_native_observations",
        "runner_sid", "runner_session_id",
        "candidate_identity", "broker", "timeout_ms", "elapsed_ms", "polls",
        "natural_exit_observed", "final_inventory_complete",
        "final_runner_process_delta_identities", "final_runner_task_delta_identities",
    }, "Runner process natural-exit evidence")
    require_int(row["schema_version"], 2, 2, "Runner process evidence schema")
    require(type(row["runner_sid"]) is str and len(row["runner_sid"]) <= 184 and
            _WINDOWS_RUNNER_SID.fullmatch(row["runner_sid"]) is not None,
            "Runner process runner SID is invalid.")
    runner_session = require_int(row["runner_session_id"], 1, 0xFFFFFFFF,
                                 "Runner process runner session")
    require(type(initial_processes) is list and len(initial_processes) <= 1,
            "Initial unexpected runner process inventory is malformed.")
    require(type(row["polls"]) is list and len(row["polls"]) <= RUNNER_PROCESS_MAXIMUM_POLLS,
            "Runner process poll inventory is unavailable or exceeds its bound.")
    require(type(row["final_runner_process_delta_identities"]) is list and
            type(row["final_runner_task_delta_identities"]) is list,
            "Runner process final delta inventories are unavailable.")
    require(type(row["natural_exit_observed"]) is bool and
            type(row["final_inventory_complete"]) is bool,
            "Runner process completion flags are not strict booleans.")
    timeout = require_int(row["timeout_ms"], 0, RUNNER_PROCESS_NATURAL_EXIT_TIMEOUT_MS,
                          "Runner process wait timeout")
    elapsed = require_int(row["elapsed_ms"], 0, 2_147_483_647,
                          "Runner process wait duration")
    if row["status"] == "not-required":
        require(not initial_processes and row["candidate_identity"] is None and
                row["broker"] is None and row["process_class"] is None and
                row["native_exit"] is None and row["initial_native_observations"] == [] and
                type(row["initial_native_observations"]) is list and timeout == 0 and elapsed == 0 and
                row["polls"] == [] and row["natural_exit_observed"] is False and
                row["final_inventory_complete"] is True and
                row["final_runner_process_delta_identities"] == [] and
                row["final_runner_task_delta_identities"] == [],
                "Unneeded Runner process evidence contains a process or wait observation.")
        return

    require(type(row["process_class"]) is str and
            row["process_class"] in {"smart-screen", "desktop-spotlight"},
            "Runner natural-exit process class is unsupported.")
    spotlight = row["process_class"] == "desktop-spotlight"
    if not spotlight:
        require(row["native_exit"] is None and type(row["initial_native_observations"]) is list and
                row["initial_native_observations"] == [],
                "Runner process evidence contains DesktopSpotlight native observations.")
    require(row["status"] == "natural-exit",
            "Controller cleanup has no verified Runner process natural-exit result.")
    require(timeout == RUNNER_PROCESS_NATURAL_EXIT_TIMEOUT_MS and elapsed <= timeout and
            row["natural_exit_observed"] is True and
            row["final_inventory_complete"] is True,
            "Runner process natural-exit wait exceeded its deadline or lacks a complete final inventory.")
    require(type(row["candidate_identity"]) is str,
            "Runner process candidate identity is unavailable.")
    candidate_pid, candidate_created = _process_identity(
        row["candidate_identity"], "Runner process candidate identity")
    require(type(initial_processes) is list and len(initial_processes) == 1,
            "Runner process must account for exactly one initial process delta.")
    initial = require_exact_keys(initial_processes[0], {
        "identity", "pid", "session_id", "creation_time_utc", "executable_path",
    }, "Initial Runner process process delta")
    require_int(initial["pid"], candidate_pid, candidate_pid, "Initial Runner process PID")
    require_int(initial["session_id"], runner_session, runner_session,
                "Initial Runner process session")
    require(type(initial["creation_time_utc"]) is str and
            _WINDOWS_UTC_TIMESTAMP.fullmatch(initial["creation_time_utc"]) is not None and
            initial["creation_time_utc"] == candidate_created and
            initial["identity"] == row["candidate_identity"] and
            type(initial["executable_path"]) is str and
            len(initial["executable_path"]) <= 32_767,
            "Initial Runner process process lifetime or path is malformed.")

    broker = require_exact_keys(row["broker"], {
        "windows_directory", "process_identity", "process_pid", "process_creation_time_utc",
        "process_session_id", "process_owner_sid", "process_executable_path",
        "process_path_verified", "process_command_line_arguments",
        "process_signature_status", "process_signer_subject", "process_signer_thumbprint",
        "parent_identity", "parent_pid", "parent_creation_time_utc", "parent_session_id",
        "parent_owner_sid", "parent_executable_path", "parent_path_verified",
        "parent_command_line_arguments", "parent_signature_status", "parent_signer_subject",
        "parent_signer_thumbprint", "service_name", "service_process_id", "service_state",
    } | ({"native_identity", "parent_native_identity", "registration", "manifest"}
         if spotlight else set()), "Runner process broker identity")
    directory = broker["windows_directory"]
    require(type(directory) is str and len(directory) <= 260 and
            re.fullmatch(r"[A-Za-z]:\\[^\\/:*?\"<>|]+(?:\\[^\\/:*?\"<>|]+)*", directory),
            "Runner process Windows directory is not canonical drive-absolute syntax.")
    directory_parts = directory[3:].split("\\")
    require(all(part and part not in {".", ".."} and not part.endswith((".", " "))
                for part in directory_parts),
            "Runner process Windows directory contains an aliased component.")
    process_path = _windows_system_path(directory, "backgroundTaskHost.exe" if spotlight else "smartscreen.exe")
    parent_path = _windows_system_path(directory, "svchost.exe")
    require(broker["process_identity"] == row["candidate_identity"] and
            require_int(broker["process_pid"], candidate_pid, candidate_pid,
                        "Runner process broker PID") == candidate_pid and
            broker["process_creation_time_utc"] == candidate_created and
            require_int(broker["process_session_id"], runner_session, runner_session,
                        "Runner process broker session") == runner_session and
            broker["process_owner_sid"] == row["runner_sid"] and
            type(broker["process_path_verified"]) is bool and
            broker["process_path_verified"] is True and
            type(broker["process_executable_path"]) is str and
            broker["process_executable_path"].casefold() == process_path.casefold() and
            initial["executable_path"].casefold() == process_path.casefold(),
            "Runner process candidate path, owner or lifetime differs from its initial delta.")
    require(type(broker["process_creation_time_utc"]) is str and
            _WINDOWS_UTC_TIMESTAMP.fullmatch(broker["process_creation_time_utc"]) is not None,
            "Runner process process creation time is malformed.")
    for prefix in ("process", "parent"):
        require(broker[f"{prefix}_signature_status"] == "Valid" and
                type(broker[f"{prefix}_signer_subject"]) is str and
                len(broker[f"{prefix}_signer_subject"]) <= 512 and
                _MICROSOFT_WINDOWS_SUBJECT.match(broker[f"{prefix}_signer_subject"]) is not None and
                type(broker[f"{prefix}_signer_thumbprint"]) is str and
                re.fullmatch(r"(?i:[0-9a-f]{40})", broker[f"{prefix}_signer_thumbprint"]) is not None,
                f"Runner process {prefix} Authenticode evidence is invalid.")
    process_arguments = broker["process_command_line_arguments"]
    require(type(process_arguments) is list and len(process_arguments) == 2 and
            all(type(argument) is str and len(argument) <= 4096 for argument in process_arguments) and
            process_arguments[0].casefold() == process_path.casefold() and
            (process_arguments[1] == "-ServerName:" + _SPOTLIGHT_SERVER if spotlight else
             process_arguments[1].casefold() == "-embedding"),
            "Runner process command-line arguments are not exact.")

    parent_pid, parent_created = _process_identity(
        broker["parent_identity"], "Runner process parent identity")
    require_int(broker["parent_pid"], parent_pid, parent_pid, "Runner process parent PID")
    require(type(broker["parent_creation_time_utc"]) is str and
            broker["parent_creation_time_utc"] == parent_created and
            _WINDOWS_UTC_TIMESTAMP.fullmatch(parent_created) is not None and
            parent_created <= candidate_created and
            require_int(broker["parent_session_id"], 0, 0xFFFFFFFF,
                        "Runner process parent session") == 0 and
            broker["parent_owner_sid"] == "S-1-5-18" and
            type(broker["parent_path_verified"]) is bool and
            broker["parent_path_verified"] is True and
            type(broker["parent_executable_path"]) is str and
            broker["parent_executable_path"].casefold() == parent_path.casefold(),
            "Runner process parent is not the exact SYSTEM service-host process.")
    parent_arguments = broker["parent_command_line_arguments"]
    require(type(parent_arguments) is list and 3 <= len(parent_arguments) <= 6 and
            all(type(argument) is str and len(argument) <= 4096 for argument in parent_arguments) and
            parent_arguments[0].casefold() == parent_path.casefold() and
            parent_arguments[1].casefold() == "-k" and
            parent_arguments[2].casefold() == "dcomlaunch",
            "Runner process parent command line is not an exact DcomLaunch invocation.")
    parent_tail = tuple(argument.casefold() for argument in parent_arguments[3:])
    require(parent_tail in ((), ("-p",), ("-s", "dcomlaunch"),
                            ("-s", "dcomlaunch", "-p")),
            "Runner process parent command line is not an exact DcomLaunch invocation.")
    require(broker["service_name"] == "DcomLaunch" and
            require_int(broker["service_process_id"], parent_pid, parent_pid,
                        "DcomLaunch service PID") == parent_pid and
            broker["service_state"] == "Running",
            "DcomLaunch is not bound to the exact running parent process.")

    if spotlight:
        native = _verify_native_identity(
            broker["native_identity"], pid=candidate_pid, created=candidate_created,
            owner=row["runner_sid"], session=runner_session, path=process_path, spotlight=True)
        parent_native = _verify_native_identity(
            broker["parent_native_identity"], pid=parent_pid, created=parent_created,
            owner="S-1-5-18", session=0, path=parent_path)
        require(int(parent_native["creation_filetime_100ns"]) <= int(native["creation_filetime_100ns"]),
                "Native parent creation follows its child.")
        observations = row["initial_native_observations"]
        require(type(observations) is list and len(observations) == 1,
                "DesktopSpotlight has missing, failed or multiple initial native observations.")
        observation = require_exact_keys(observations[0], {
            "attempt", "cim_row", "native_identity", "capture_error",
        }, "Initial DesktopSpotlight native observation")
        require_int(observation["attempt"], 1, 3, "Initial native capture attempt")
        _verify_native_identity(
            observation["native_identity"], pid=candidate_pid, created=candidate_created,
            owner=row["runner_sid"], session=runner_session, path=process_path, spotlight=True)
        observed_cim = require_exact_keys(observation["cim_row"], set(initial), "Initial native CIM row")
        require_int(observed_cim["pid"], candidate_pid, candidate_pid, "Observed initial PID")
        require_int(observed_cim["session_id"], runner_session, runner_session, "Observed initial session")
        require(observation["capture_error"] is None and observed_cim == initial and
                observation["native_identity"] == native,
                "DesktopSpotlight initial native observation differs from its classified lifetime.")
        registration = _verify_spotlight_registration(
            broker["registration"], runner_sid=row["runner_sid"], directory=directory, native=native)
        _verify_spotlight_manifest(broker["manifest"], directory=directory, registration=registration)
        _verify_native_exit(row["native_exit"], native)

    polls = row["polls"]
    require(type(polls) is list and 1 <= len(polls) <= RUNNER_PROCESS_MAXIMUM_POLLS,
            "Runner process natural-exit poll series is incomplete or oversized.")
    previous_elapsed = -1
    for poll_index, raw_poll in enumerate(polls):
        poll = require_exact_keys(raw_poll, {
            "elapsed_ms", "inventory_complete", "process_delta_identities",
            "task_delta_identities", "owned_root_process_count",
        }, "Runner process natural-exit poll")
        poll_elapsed = require_int(poll["elapsed_ms"], 0, timeout,
                                   "Runner process poll duration")
        require(poll_elapsed >= previous_elapsed and poll_elapsed <= elapsed and poll["inventory_complete"] is True,
                "Runner process poll time regressed or inventory was incomplete.")
        previous_elapsed = poll_elapsed
        process_ids = poll["process_delta_identities"]
        task_ids = poll["task_delta_identities"]
        require(type(process_ids) is list and len(process_ids) <= 1 and
                all(identity == row["candidate_identity"] for identity in process_ids) and
                type(task_ids) is list and not task_ids and
                require_int(poll["owned_root_process_count"], 0, 0,
                            "Owned-root processes during runner process wait") == 0,
                "Runner process wait observed another process, task or owned-root process.")
        if poll_index == 0:
            require(process_ids == [row["candidate_identity"]],
                    "Runner process poll series does not start with the classified process.")
        elif poll_index < len(polls) - 1:
            require(process_ids == [row["candidate_identity"]],
                    "Runner process process disappeared before the final natural-exit poll.")
    require(polls[-1]["process_delta_identities"] == [] and
            polls[-1]["task_delta_identities"] == [] and
            row["final_runner_process_delta_identities"] == [] and
            row["final_runner_task_delta_identities"] == [],
            "Runner process final inventory still contains a process or task delta.")


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
        "resource_cleanup_errors", "runner_process_natural_exit", "owned_processes_after",
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
    verify_runner_process_natural_exit(
        host["runner_process_natural_exit"], host["unexpected_runner_processes"])
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
