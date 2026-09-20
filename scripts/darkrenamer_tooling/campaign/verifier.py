"""Raw evidence joins used by the trusted VM-automated campaign verifier."""

from __future__ import annotations

import hashlib
import json
from pathlib import PurePosixPath
import re

from darkrenamer_tooling.campaign.planning import verify_process_lifecycle
from darkrenamer_tooling.contracts.binding import Candidate, verify_result_binding
from darkrenamer_tooling.contracts.menu_layout import verify_native_menu_layout
from darkrenamer_tooling.contracts.platform import (
    contains, rectangle, verify_cleanup, verify_environment, verify_keyboard_events,
)
from darkrenamer_tooling.contracts.state import Identity, core_rename_checkpoints
from darkrenamer_tooling.evidence.archive import (
    EvidenceError, ExtractedEvidence, MAX_JSON_BYTES, MAX_MEMBER_BYTES,
    parse_bounded_json_bytes, read_referenced_file, require_exact_keys, require_int,
)
from darkrenamer_tooling.evidence.png import decode_png


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def canonical_digest(value: object) -> str:
    return hashlib.sha256((json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=True, allow_nan=False) + "\n").encode()).hexdigest()


class EvidenceReader:
    """Resolve only the already verified archive inventory; never execute input."""

    def __init__(self, extracted: ExtractedEvidence):
        self.evidence = extracted

    def bytes(self, path: str, maximum: int = MAX_MEMBER_BYTES) -> bytes:
        require(type(path) is str and path in self.evidence.files, "Raw reference is absent from the exact archive index.")
        return read_referenced_file(self.evidence.root, path, self.evidence.files[path], max_bytes=maximum)

    def json(self, path: str) -> object:
        data = self.bytes(path, MAX_JSON_BYTES)
        # Historical PowerShell raw records use one UTF-8 BOM. Hash the complete
        # bytes first; canonical statement and archive index remain BOM-free.
        return parse_bounded_json_bytes(data.removeprefix(b"\xef\xbb\xbf"), label="raw observation")

    def sibling(self, document: str, reference: object) -> str:
        require(type(reference) is dict and type(reference.get("file")) is str and
                "/" not in reference["file"] and "\\" not in reference["file"],
                "Raw sibling reference must name a leaf.")
        path = str(PurePosixPath(document).parent / reference["file"])
        require(path in self.evidence.files and self.evidence.files[path].sha256 == reference.get("sha256"),
                "Raw sibling digest differs from its indexed bytes.")
        return path

    def digest_reference(self, reference: object, *, prefix: str) -> str:
        row = require_exact_keys(reference, {"bytes", "sha256", "boundary"}, "Private recovery reference")
        require_int(row["bytes"], 0, MAX_MEMBER_BYTES, "Raw recovery reference bytes")
        require(type(row["boundary"]) is str and 0 < len(row["boundary"]) <= 128,
                "Recovery boundary is unavailable.")
        matches = [path for path, pin in self.evidence.files.items()
                   if path.startswith(prefix) and pin.size == row["bytes"] and pin.sha256 == row["sha256"]]
        require(bool(matches), "Recovery reference has no byte-identical private member in its run.")
        # Equal byte references are interchangeable only within this execution.
        return sorted(matches)[0]


def verify_authenticated_gate_metadata(value: object, candidate: Candidate) -> dict:
    """Check facts fetched outside the ZIP by the authenticated hosted wrapper.

    This function cannot authenticate arbitrary caller JSON. Workflow routing
    and the wrapper must supply its own REST responses, never archive metadata.
    """
    top = require_exact_keys(value, {"schema_version", "repository", "candidate", "ci"}, "Hosted gate facts")
    require_int(top["schema_version"], 1, 1, "Gate schema")
    repository = require_exact_keys(top["repository"], {"full_name", "id", "owner"}, "Gate repository")
    repository_id = require_int(repository["id"], 1, (1 << 63) - 1, "Repository ID")
    owner = require_exact_keys(repository["owner"], {"login", "id", "type"}, "Repository owner")
    require_int(owner["id"], 1, (1 << 63) - 1, "Repository owner ID")
    require(repository["full_name"] == "PiesP/DarkReNamer" and owner["login"] == "PiesP" and owner["type"] == "User",
            "Hosted gate repository differs from the fixed profile.")

    def workflow(record: object, path: str, event: str, jobs: set[str]) -> dict:
        record = require_exact_keys(record, {"run", "jobs"}, "Hosted workflow gate")
        run = require_exact_keys(record["run"], {"id", "run_attempt", "path", "event", "head_branch", "head_sha",
                                                "status", "conclusion", "repository_id"}, "Hosted gate run")
        require_int(run["id"], 1, (1 << 63) - 1, "Gate run ID")
        require_int(run["run_attempt"], 1, (1 << 31) - 1, "Gate run attempt")
        require_int(run["repository_id"], repository_id, repository_id, "Gate run repository")
        require(run["path"] == path and run["event"] == event and run["head_branch"] == "master" and
                run["head_sha"] == candidate.source_sha and run["status"] == "completed" and
                run["conclusion"] == "success", "Required workflow did not succeed on the exact candidate source.")
        require(type(record["jobs"]) is list and len(record["jobs"]) == len(jobs), "Gate job inventory differs.")
        seen = set()
        for raw in record["jobs"]:
            job = require_exact_keys(raw, {"name", "status", "conclusion"}, "Hosted job")
            require(type(job["name"]) is str and job["name"] in jobs and job["name"] not in seen and
                    job["status"] == "completed" and job["conclusion"] == "success",
                    "Required hosted job is missing, duplicate, skipped or failed.")
            seen.add(job["name"])
        return {"run": run, "jobs": sorted(record["jobs"], key=lambda row: row["name"])}

    source = require_exact_keys(top["candidate"], {"run", "jobs", "artifact", "artifact_sha256"}, "Candidate gate")
    candidate_gate = workflow({"run": source["run"], "jobs": source["jobs"]},
                              ".github/workflows/release.yaml", "workflow_dispatch", {"candidate/build-windows"})
    require(source["run"]["id"] == int(candidate.workflow_run) and
            source["run"]["run_attempt"] == int(candidate.run_attempt), "Candidate gate belongs to another run attempt.")
    artifact = require_exact_keys(source["artifact"], {"id", "name", "digest", "size", "expired", "workflow_run"}, "Candidate artifact")
    require_int(artifact["id"], int(candidate.artifact_id), int(candidate.artifact_id), "Candidate artifact ID")
    require_int(artifact["size"], 1, 512 * 1024 * 1024, "Candidate artifact size")
    run = require_exact_keys(artifact["workflow_run"], {"id", "head_sha"}, "Artifact source")
    require_int(run["id"], int(candidate.workflow_run), int(candidate.workflow_run), "Artifact run")
    from darkrenamer_tooling.contracts.binding import sha
    artifact_digest = sha(source["artifact_sha256"], 64)
    require(artifact["name"] == f"DarkReNamer-dry-run-{candidate.workflow_run}-{candidate.run_attempt}-windows" and
            artifact["expired"] is False and artifact["digest"] == "sha256:" + artifact_digest and
            run["head_sha"] == candidate.source_sha, "Candidate artifact metadata differs from its exact origin.")
    ci = workflow(top["ci"], ".github/workflows/ci.yaml", "push",
                  {"pr-gate/quality", "pr-gate/unit", "pr-gate/security", "pr-gate/windows"})
    return {"artifact_sha256": artifact_digest, "locked_host_gate_sha256": canonical_digest(ci),
            "candidate_gate_sha256": canonical_digest({"workflow": candidate_gate, "artifact": artifact})}


def verify_core_execution(result: dict, bundle: dict, transport: dict, target: dict,
                           *, keyboard: bool) -> None:
    """Derive one UIA/keyboard rename trial without consuming its pass booleans."""
    observer = "ui" if keyboard else "core"
    verify_result_binding(result, bundle, observer=observer)
    raw = result if keyboard else result["gui"]["flow"]
    lifecycle = result["process_lifecycle"] if keyboard else result["gui"]["process_lifecycle"]
    pid, session = verify_process_lifecycle(lifecycle, executable_sha256=bundle["product"]["application"]["sha256"])
    environment = raw["raw_environment"]
    verify_environment(environment, target, candidate_pid=pid, session_id=session)
    source = "acceptance-source.txt" if keyboard else "vm-flow-source.txt"
    destination = "accepted-acceptance-source.txt" if keyboard else "vm-confirmed-vm-flow-source.txt"
    final = core_rename_checkpoints(raw["raw_checkpoints"], source_name=source,
                                    destination_name=destination, full_identity=True)
    root_identity = Identity.parse(environment["fixture_volume"]["root_identity"])
    require(all(row.identity.volume == root_identity.volume for row in final.values()),
            "Core fixture identities do not belong to the observed volume.")
    if keyboard:
        verify_keyboard_events(result["keyboard_events"], candidate_pid=pid, session_id=session,
                               main_workbench_hwnd=environment["target_display"]["hwnd"])
    verify_cleanup(result["raw_cleanup"], transport["raw_cleanup"])


RAIL_IDS = {"32771", "32772", "32773", "32774", "32775", "32776", "32777", "32778", "32779",
            "32780", "32781", "32783", "65535", "32784", "32788", "32789", "32790", "32785", "32786"}


def verify_layout_controls(layout: object, environment: dict, *, keyboard_focus: bool) -> None:
    row = require_exact_keys(layout, {"controls", "focus", "screenshots", "focus_reachability"}, "Layout observations")
    display = environment["target_display"]
    work = rectangle(display["work_rect"])
    require(type(row["controls"]) is list and len(row["controls"]) == 21,
            "Layout must enumerate the workbench, file list and all nineteen rail commands.")

    def control(raw: object, *, require_visible: bool) -> dict:
        item = require_exact_keys(raw, {"automation_id", "control_type", "visible", "enabled", "keyboard_focusable", "bounds",
                                        "pid", "session_id", "root_hwnd"}, "Layout control")
        require_int(item["pid"], display["process_id"], display["process_id"], "Control PID")
        require_int(item["session_id"], display["session_id"], display["session_id"], "Control session")
        require_int(item["root_hwnd"], display["hwnd"], display["hwnd"], "Control root HWND")
        require(type(item["enabled"]) is bool and type(item["visible"]) is bool and type(item["keyboard_focusable"]) is bool,
                "Control enabled/visible facts are unavailable.")
        bounds = rectangle(item["bounds"])
        if require_visible:
            require(item["visible"] is True and contains(work, bounds),
                    "Required control is offscreen or clipped by the current work area.")
        return item

    seen = set()
    for raw in row["controls"]:
        item = control(raw, require_visible=raw.get("control_type") != "ControlType.Window")
        identifier = item["automation_id"]
        require(type(identifier) is str and identifier not in seen, "Layout control is duplicated.")
        seen.add(identifier)
        expected_type = ("ControlType.Window" if identifier == "" else
                         "ControlType.DataGrid" if identifier == "1000" else "ControlType.Button")
        require(item["control_type"] == expected_type, "Layout control type differs from the workbench contract.")
    require(seen == RAIL_IDS | {"", "1000"}, "Layout command inventory differs from the workbench contract.")
    require(type(row["focus"]) is list and row["focus"], "Layout has no actual focused-control observation.")
    if not keyboard_focus:
        for raw in row["focus"]:
            focused = control(raw, require_visible=True)
            require(focused["enabled"] is True, "Observed focused control was disabled.")
    # Keyboard flows separately require the exact two actual confirmation key
    # deliveries with focus ownership. Metadata alone cannot replace that gate.


def verify_layout_raster(reader: EvidenceReader, document: str, layout: dict, environment: dict) -> None:
    images = layout["screenshots"]
    require(type(images) is list and 0 < len(images) <= 128, "Layout raster inventory is unavailable.")
    expected = environment["target_display"]["window_rect"]
    main_size = (expected["right"] - expected["left"], expected["bottom"] - expected["top"])
    matching = []
    seen = set()
    for image in images:
        require(type(image) is dict, "Raster reference must be an object.")
        path = reader.sibling(document, image)
        require(path not in seen and path.endswith(".png"), "Raster references are duplicated or have another format.")
        seen.add(path)
        width = require_int(image.get("width"), 1, 16_384, "Raster width")
        height = require_int(image.get("height"), 1, 16_384, "Raster height")
        if (width, height) == main_size:
            matching.append((path, width, height))
    require(bool(matching), "No captured raster matches the actual candidate workbench bounds.")
    # One complete workbench raster is required per fixed cell. Other captures
    # remain individually hash-bound artifacts, without claiming human review.
    path, width, height = matching[0]
    actual_width, actual_height, pixels = decode_png(reader.bytes(path), "workbench raster")
    require((actual_width, actual_height) == (width, height) and
            pixels != pixels[:4] * (width * height), "Workbench raster is empty, uniform or dimensionally inconsistent.")


def verify_backend_execution(reader: EvidenceReader, bundle_path: str, result_path: str,
                              *, source_sha: str, required_tests: list[str]) -> str:
    """Join source-bound native binaries to their complete Rust test transcripts."""
    bundle, result = reader.json(bundle_path), reader.json(result_path)
    require(type(bundle) is dict and type(result) is dict, "Backend records must be objects.")
    for row in (bundle, result):
        require_int(row.get("schema_version"), 1, 1, "Native backend schema")
        require(row.get("source_sha") == source_sha and row.get("source_state") == "clean" and
                row.get("target") == "x86_64-pc-windows-msvc", "Native backend source/target differs.")
    binaries = bundle.get("test_binaries")
    require(type(binaries) is list and 0 < len(binaries) <= 128, "Native backend binary inventory is unavailable.")
    expected = {}
    for binary in binaries:
        require(type(binary) is dict and type(binary.get("file")) is str and binary["file"] not in expected,
                "Backend binary inventory is duplicated or malformed.")
        require(binary["file"].endswith(".exe"), "Backend test artifact is not an executable member.")
        binary_path = reader.sibling(bundle_path, {"file": binary["file"], "sha256": binary["sha256"]})
        reader.bytes(binary_path)
        expected[binary["file"]] = binary["sha256"]
    tests = result.get("tests")
    require(type(tests) is list and len(tests) == len(expected), "Native backend executions are incomplete.")
    observed = set()
    executed_tests = set()
    total_passed = 0
    for test in tests:
        require(type(test) is dict and type(test.get("file")) is str and test["file"] not in observed and
                test["file"] in expected and test.get("sha256") == expected[test["file"]],
                "Native test result differs from its source-bound binary inventory.")
        observed.add(test["file"])
        require_int(test.get("exit_code"), 0, 0, "Native test exit code")
        output = reader.bytes(reader.sibling(result_path, test["stdout"]), MAX_JSON_BYTES).decode("utf-8", errors="strict")
        reader.bytes(reader.sibling(result_path, test["stderr"]), MAX_JSON_BYTES)
        # Crash tests spawn filtered child test processes whose summaries can
        # appear in this stream. The parent must finish with an unfiltered
        # successful summary; a child success cannot replace the parent result.
        summary = re.search(r"(?:^|\n)test result: ok\. (\d+) passed; 0 failed; (\d+) ignored; "
                            r"0 measured; 0 filtered out; finished in [0-9.]+s\s*\Z", output)
        require(summary is not None, "Native transcript lacks a final successful unfiltered parent summary.")
        passed, ignored = map(int, summary.groups())
        require_int(test.get("passed"), passed, passed, "Native transcript pass count")
        require_int(test.get("failed"), 0, 0, "Native transcript failed count")
        require_int(test.get("ignored"), ignored, ignored, "Native transcript ignored count")
        names = re.findall(r"(?m)^test ([A-Za-z0-9_:]+) \.\.\. ok\r?$", output)
        executed_tests.update(name.split("::")[-1] for name in names)
        total_passed += passed
    require(total_passed > 0 and set(required_tests) <= executed_tests,
            "Required no-overwrite/recovery backend regressions were not executed successfully.")
    require(result.get("failure_reason") is None and result.get("transport", {}).get("guest_cleanup") is True,
            "Backend runtime cleanup failed or was not observed.")
    return canonical_digest({"bundle_sha256": reader.evidence.files[bundle_path].sha256,
                             "result_sha256": reader.evidence.files[result_path].sha256,
                             "binary_sha256": dict(sorted(expected.items())),
                             "required_tests": sorted(required_tests)})


def verify_setting_restoration(reader: EvidenceReader, document: str, result: dict,
                                bundle: dict, target: dict) -> None:
    """Compare actual before/after setting snapshots, not restoration labels."""
    def bound_snapshot(reference: object, *, schema_version: int,
                       restoration_required: bool) -> dict:
        snapshot = require_exact_keys(
            reader.json(reader.sibling(document, reference)),
            {"schema_version", "source_sha", "acceptance_script_sha256", "restoration_required",
             "restoration_verified", "original", "restored"},
            "Setting restoration snapshot",
        )
        require(snapshot["source_sha"] == bundle["product"]["source_sha"] and
                snapshot["acceptance_script_sha256"] == bundle["harness"]["observers"]["ui"]["sha256"],
                "Setting snapshot belongs to another candidate or observer.")
        require_int(snapshot["schema_version"], schema_version, schema_version, "Setting snapshot schema")
        require(type(snapshot["restoration_required"]) is bool and
                snapshot["restoration_required"] is restoration_required and
                type(snapshot["restoration_verified"]) is bool and snapshot["restoration_verified"] is True,
                "Setting restoration observation is incomplete.")
        require(type(snapshot["original"]) is dict and type(snapshot["restored"]) is dict and
                canonical_digest(snapshot["original"]) == canonical_digest(snapshot["restored"]),
                "Actual restored setting differs from its original snapshot.")
        return snapshot

    if target["contrast"] == "high-contrast":
        snapshot = bound_snapshot(result["high_contrast"]["snapshot"], schema_version=2,
                                  restoration_required=False)
        for key in ("original", "restored"):
            row = require_exact_keys(snapshot[key], {"flags", "scheme", "colors", "visual_style"}, "High Contrast snapshot")
            require_int(row["flags"], 0, 0xFFFFFFFF, "High Contrast flags")
            require(type(row["scheme"]) is str, "High Contrast scheme observation is unavailable.")
            colors = require_exact_keys(row["colors"], {"window", "window_text", "button_face", "button_text",
                                                        "highlight", "highlight_text", "gray_text", "hot_light"}, "System colors")
            for color in colors.values(): require_int(color, 0, 0xFFFFFFFF, "System color")
            style = require_exact_keys(row["visual_style"], {"path", "color", "size"}, "Visual style")
            require(all(type(value) is str for value in style.values()), "Visual style restoration is unobserved.")
    if target["text_scale_percent"] == 150:
        raw = require_exact_keys(result["raw_text_scale"], {"original", "active", "active_winrt_percent", "restored",
                                                           "snapshot", "activation", "restoration"}, "Text scale observations")
        snapshot = bound_snapshot(raw["snapshot"], schema_version=1,
                                  restoration_required=True)
        require(canonical_digest(raw["original"]) == canonical_digest(snapshot["original"]) and
                canonical_digest(raw["restored"]) == canonical_digest(snapshot["restored"]),
                "Text-scale raw snapshots differ from their bound restoration document.")
        require_int(raw["active_winrt_percent"], 150, 150, "Active WinRT text scale")
        active = require_exact_keys(raw["active"], {"registry_key_existed", "registry_value_existed", "registry_value_kind",
                                                   "registry_value", "ui_settings_raw_factor", "ui_settings_percent"}, "Active text scale")
        require(active["registry_key_existed"] is True and active["registry_value_existed"] is True and
                active["registry_value_kind"] == "DWord", "Active text scale registry observation is unavailable.")
        require_int(active["registry_value"], 150, 150, "Active text scale registry value")
        require_int(active["ui_settings_percent"], 150, 150, "Active text scale UISettings")
        require(type(active["ui_settings_raw_factor"]) is float and active["ui_settings_raw_factor"] == 1.5,
                "Observed text scale factor is not 150 percent.")
        for field in ("activation", "restoration"):
            reader.json(reader.sibling(document, raw[field]))


def verify_desktop_lease(value: object, target: dict, seen: set[str]) -> None:
    row = require_exact_keys(value, {"schema_version", "mode", "lease_id", "requested_scale",
                                     "requested_width", "requested_height", "expected_dpi",
                                     "start_status", "stop_status", "cleanup_observed"}, "Desktop lease")
    require_int(row["schema_version"], 1, 1, "Desktop lease schema")
    lease = row["lease_id"]
    require(type(lease) is str and re.fullmatch(r"[0-9a-f]{32}", lease) is not None and lease not in seen,
            "Each execution requires a distinct managed desktop lease.")
    require(row["mode"] == "managed-rdp" and row["start_status"] == "ready" and
            row["stop_status"] == "stopped" and row["cleanup_observed"] is True,
            "Managed desktop lease was not both acquired and cleaned up.")
    for key, source in (("requested_scale", "scale_percent"), ("requested_width", "desktop_width"),
                        ("requested_height", "desktop_height"), ("expected_dpi", "hwnd_dpi")):
        require_int(row[key], target[source], target[source], "Desktop lease geometry")
    seen.add(lease)



def verify_appearance(value: object, environment: dict, target: dict) -> None:
    row = require_exact_keys(value, {"hwnd", "pid", "session_id", "menu_checked"}, "Appearance menu observation")
    display = environment["target_display"]
    for key, expected in (("hwnd", display["hwnd"]), ("pid", display["process_id"]),
                          ("session_id", display["session_id"])):
        require_int(row[key], expected, expected, "Appearance menu ownership")
    require(type(row["menu_checked"]) is list and len(row["menu_checked"]) == 3,
            "Appearance menu inventory is incomplete.")
    selected = {"system": 0x9010, "light": 0x9011, "dark": 0x9012}[target["appearance"]]
    for raw, command in zip(row["menu_checked"], (0x9010, 0x9011, 0x9012), strict=True):
        item = require_exact_keys(raw, {"command_id", "checked"}, "Appearance menu item")
        require_int(item["command_id"], command, command, "Appearance command")
        require(item["checked"] is (command == selected), "Actual selected appearance differs from the fixed cell.")



FOCUS_ORDER = ["1000"] + [str(value) for value in range(32771, 32781)] + [
    "32781", "32783", "65535", "32784", "32788", "32789", "32790", "32785", "32786"]
FOCUS_GROUPS = [None, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 0, 1, 1, 1, 2, 2, 2, 3, 3]


def verify_focus_reachability(value: object, environment: dict) -> None:
    from darkrenamer_tooling.contracts.state import clean_journal_inventory, fixture_inventory
    row = require_exact_keys(value, {"schema_version", "input_method", "initial", "transitions", "final",
                                     "controls", "state_before", "state_after"}, "Keyboard reachability")
    require_int(row["schema_version"], 1, 1, "Reachability schema")
    require(row["input_method"] == "keyboard", "Reachability must use actual keyboard navigation.")
    display = environment["target_display"]
    work = rectangle(display["work_rect"])
    binding_keys = {"automation_id", "control_type", "visible", "enabled", "keyboard_focusable",
                    "bounds", "pid", "session_id", "root_hwnd"}

    def binding(raw: object, *, focused: bool) -> dict:
        item = require_exact_keys(raw, binding_keys, "Focus binding")
        identifier = item["automation_id"]
        require(type(identifier) is str and identifier in set(FOCUS_ORDER) | {""},
                "Focus observation is outside the required workbench controls.")
        expected_type = "ControlType.Window" if identifier == "" else ("ControlType.DataGrid" if identifier == "1000" else "ControlType.Button")
        require(item["control_type"] == expected_type, "Focused control type differs from its fixed identity.")
        for key, expected in (("pid", display["process_id"]), ("session_id", display["session_id"]), ("root_hwnd", display["hwnd"])):
            require_int(item[key], expected, expected, "Focused control ownership")
        for field in ("visible", "enabled", "keyboard_focusable"):
            require(type(item[field]) is bool, "Focus availability is unobserved.")
        bounds = rectangle(item["bounds"])
        if focused:
            require(item["visible"] and item["enabled"] and item["keyboard_focusable"] and contains(work, bounds),
                    "Keyboard focus reached an unavailable or clipped control.")
        return item

    require(type(row["controls"]) is list and len(row["controls"]) == len(FOCUS_ORDER),
            "Reachability must inventory the list and every rail command.")
    required = set()
    catalog = {}
    for raw, identifier, group in zip(row["controls"], FOCUS_ORDER, FOCUS_GROUPS, strict=True):
        control = require_exact_keys(raw, binding_keys | {"rail", "rail_group", "expected_reachable", "exclusion_reason"}, "Reachability control")
        item = binding({key: control[key] for key in binding_keys}, focused=False)
        require(item["automation_id"] == identifier, "Reachability command order differs from the source catalog.")
        rail = "list" if identifier == "1000" else ("left" if identifier in FOCUS_ORDER[1:11] else "right")
        require(control["rail"] == rail and type(control["rail_group"]) is type(group) and control["rail_group"] == group,
                "Reachability rail grouping differs from the source catalog.")
        require(item["visible"] is True and contains(work, rectangle(item["bounds"])),
                "Required command is outside the observed work area.")
        # Roving rail peers may initially lack WS_TABSTOP. Every enabled command
        # remains required because the production arrow navigation can reach it.
        reachable = item["enabled"]
        require(control["expected_reachable"] is reachable and
                control["exclusion_reason"] == (None if reachable else "disabled"),
                "Reachability exclusions differ from actual command availability.")
        catalog[identifier] = item
        if reachable:
            required.add(identifier)
    require("1000" in required, "The production list must remain keyboard reachable.")
    def joined_binding(raw: object) -> dict:
        item = binding(raw, focused=True)
        identifier = item["automation_id"]
        if identifier in catalog:
            immutable = binding_keys - {"keyboard_focusable"}
            require({key: item[key] for key in immutable} ==
                    {key: catalog[identifier][key] for key in immutable},
                    "Focused binding differs from the observed control catalog.")
        else:
            require(identifier == "", "Focus belongs to an unknown command.")
        return item

    current = joined_binding(row["initial"])
    transitions = row["transitions"]
    require(type(transitions) is list and 0 < len(transitions) <= 256, "Keyboard transition inventory is missing or unbounded.")
    parsed = []
    for sequence, raw in enumerate(transitions, 1):
        transition = require_exact_keys(raw, {"sequence", "input", "from", "to"}, "Keyboard transition")
        require_int(transition["sequence"], sequence, sequence, "Transition sequence")
        require(transition["input"] in {"tab", "down"}, "Reachability used an action outside the frozen navigation contract.")
        before = joined_binding(transition["from"])
        after = joined_binding(transition["to"])
        require(after["automation_id"] != before["automation_id"], "Keyboard input did not move focus.")
        parsed.append((transition["input"], before, after))
    offset = 0

    def consume(expected_input: str) -> None:
        nonlocal offset, current
        require(offset < len(parsed), "Required navigation transition is missing.")
        action, before, after = parsed[offset]
        require(action == expected_input and before == current,
                "Keyboard transcript does not replay the frozen Tab/Down navigation state machine.")
        current = after
        offset += 1

    def move_to_scope(identifiers: set[str]) -> None:
        for _ in range(32):
            if current["automation_id"] in identifiers:
                return
            consume("tab")
        raise EvidenceError("Keyboard Tab did not reach the required scope within its bound.")

    visited = set()
    scopes = ({"1000"}, set(FOCUS_ORDER[1:11]), set(FOCUS_ORDER[11:]))
    for scope in scopes:
        members = required & scope
        if not members:
            continue
        move_to_scope(members)
        identifier = current["automation_id"]
        require(identifier not in visited, "Keyboard traversal revisited a rail before entering its required scope.")
        visited.add(identifier)
        if members != {"1000"}:
            while not members <= visited:
                consume("down")
                identifier = current["automation_id"]
                require(identifier in members and identifier not in visited,
                        "Keyboard arrow navigation left its rail or cycled before reaching every enabled command.")
                visited.add(identifier)
    move_to_scope({"1000"})
    require(offset == len(parsed) and joined_binding(row["final"]) == current and visited == required,
            "Keyboard transcript has unused transitions or incomplete required command coverage.")
    states = []
    environment_root = environment["fixture_volume"]
    root_identity = Identity.parse(environment_root["root_identity"])
    for name in ("state_before", "state_after"):
        state = require_exact_keys(row[name], {"fixture_root", "root_identity", "fixture_entries", "journal_entries"}, "Navigation state")
        require(state["fixture_root"] == environment_root["root_path"] and
                Identity.parse(state["root_identity"]) == root_identity,
                "Navigation state belongs to another observed fixture root.")
        inventory = fixture_inventory(state["fixture_entries"], full_identity=True)
        require(all(item.identity.volume == root_identity.volume for item in inventory.values()),
                "Navigation fixture file belongs to another observed volume.")
        states.append((inventory, clean_journal_inventory(state["journal_entries"])))
    require(states[0] == states[1], "Keyboard reachability changed files or journal state.")


def verify_execution_freshness(reader: EvidenceReader, result: dict, transport: dict, *,
                               run_prefix: str, seen: set[tuple], vm_ids: set[str]) -> None:
    vm_id = transport.get("vm_id")
    require(type(vm_id) is str and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", vm_id) is not None,
            "Execution VM identity is unavailable.")
    require(transport.get("vm_identity_kind") == "hyper-v-guest-parameters-virtual-machine-id-v1" and
            transport.get("vm_identity_sha256") == hashlib.sha256(vm_id.encode("ascii")).hexdigest(),
            "Execution VM identity digest differs from its actual guest observation.")
    require(not vm_ids or vm_id in vm_ids, "Required campaign executions changed VM identity.")
    vm_ids.add(vm_id)
    lifecycles = []
    if result.get("observer_role") == "recovery":
        modes = {"ProcessCrash": "process_crash", "WorkerCancellation": "worker_cancellation", "WorkerClose": "worker_close"}
        groups = [result[modes[result["selected_mode"]]]]
        if result["selected_mode"] == "ProcessCrash":
            groups.append(result["intent_only_candidate_discard"])
        for group in groups:
            for reference in group["processes"]:
                record = reader.json(reader.digest_reference(reference, prefix=run_prefix))
                if record["boundary"] == "started":
                    lifecycles.append(record["lifecycle"])
    elif "raw_layout_runs" in result:
        lifecycles = [row["process_lifecycle"] for row in result["raw_layout_runs"]]
    elif "process_lifecycle" in result:
        lifecycles = [result["process_lifecycle"]]
    else:
        lifecycles = [result["gui"]["process_lifecycle"]]
    require(bool(lifecycles), "Execution has no independently observed process lifetime.")
    for lifecycle in lifecycles:
        identity = (vm_id, lifecycle["pid"], lifecycle["start_time_utc_ticks"], lifecycle["executable_sha256"])
        require(identity not in seen, "A prior process lifetime was replayed as a fresh required execution.")
        seen.add(identity)

def verify_complete_campaign(reader: EvidenceReader, *, profile: dict, profile_sha256: str,
                              candidate: Candidate, component_hashes: dict[str, str]) -> dict:
    from darkrenamer_tooling.campaign.planning import execution_slots, validate_ledger
    from darkrenamer_tooling.campaign.recovery import verify_recovery_execution
    from darkrenamer_tooling.contracts.binding import verify_candidate_bundle

    campaign, plan = reader.json("campaign.json"), reader.json("plan.json")
    attempts = validate_ledger(plan, campaign, profile=profile, profile_sha256=profile_sha256,
                               candidate=candidate, harness_sha=candidate.source_sha)
    targets = {target["id"]: target for target in profile["required_targets"]}
    leases: set[str] = set()
    completed: set[str] = set()
    process_identities: set[tuple] = set()
    vm_ids: set[str] = set()
    execution_digests = []
    for attempt, slot in zip(attempts, execution_slots(profile), strict=True):
        identifier = slot["targets"][0]
        target = dict(profile["representative_core_environment"])
        target.update(targets[identifier])
        if slot["stability_index"] is not None:
            target.update(profile["stability"]["environment"])
        bundle, result, transport = (reader.json(attempt[field]) for field in ("bundle", "result", "transport"))
        require(type(result) is dict and type(transport) is dict, "Execution result and transport must be objects.")
        verify_candidate_bundle(bundle, expected=candidate, harness_sha=candidate.source_sha,
                                component_hashes=component_hashes, release=True)
        require(result.get("failure_reason") is None, "Observer reported an incomplete execution.")
        verify_desktop_lease(reader.json(attempt["desktop_lease"]), target, leases)
        if identifier == "core-uia-flow":
            verify_core_execution(result, bundle, transport, target, keyboard=False)
        elif identifier == "core-keyboard-flow":
            verify_core_execution(result, bundle, transport, target, keyboard=True)
        elif identifier.startswith("layout-"):
            verify_result_binding(result, bundle, observer="ui")
            keyboard = type(result.get("raw_environment")) is dict
            if keyboard:
                verify_core_execution(result, bundle, transport, target, keyboard=True)
                runs = [{"raw_environment": result["raw_environment"],
                         "raw_appearance": result["raw_appearance"],
                         "process_lifecycle": result["process_lifecycle"],
                         "layout_observations": result["layout_observations"]}]
            else:
                runs = result.get("raw_layout_runs")
                require(type(runs) is list and len(runs) == 1, "Fixed layout cell requires one complete workbench run.")
            for run in runs:
                require_exact_keys(run, {"raw_environment", "raw_appearance", "process_lifecycle", "layout_observations"}, "Layout run")
                pid, session = verify_process_lifecycle(run["process_lifecycle"], executable_sha256=candidate.executable_sha256)
                verify_environment(run["raw_environment"], target, candidate_pid=pid, session_id=session)
                verify_appearance(run["raw_appearance"], run["raw_environment"], target)
                layout_variant = target.get("layout_variant", "command-rails")
                require(layout_variant in {"command-rails", "native-menu-only"},
                        "Layout variant differs from the frozen profile contract.")
                require((identifier == "layout-small-text150-100") == (layout_variant == "native-menu-only"),
                        "Native menu-only evidence is authorized for exactly the fixed text-150 small cell.")
                if layout_variant == "native-menu-only":
                    verify_native_menu_layout(run["layout_observations"], run["raw_environment"])
                else:
                    verify_layout_controls(run["layout_observations"], run["raw_environment"], keyboard_focus=keyboard)
                    verify_focus_reachability(run["layout_observations"]["focus_reachability"], run["raw_environment"])
                verify_layout_raster(reader, attempt["result"], run["layout_observations"], run["raw_environment"])
            verify_setting_restoration(reader, attempt["result"], result, bundle, target)
            verify_cleanup(result["raw_cleanup"], transport["raw_cleanup"])
        else:
            verified = verify_recovery_execution(reader, result, bundle, transport, target,
                                                  run_prefix=str(PurePosixPath(attempt["transport"]).parent) + "/",
                                                  result_path=attempt["result"])
            require(verified == set(slot["targets"]), "Recovery raw observations do not satisfy the complete execution group.")
        verify_execution_freshness(reader, result, transport, run_prefix="runs/" + slot["id"] + "/",
                                   seen=process_identities, vm_ids=vm_ids)
        completed.update(slot["targets"])
        execution_digests.append({"slot": slot["id"], **{
            field: reader.evidence.files[attempt[field]].sha256
            for field in ("bundle", "result", "transport", "desktop_lease")}})
    require(completed == set(targets), "Required VM target coverage is incomplete.")
    backend = require_exact_keys(campaign["backend"], {"source_sha", "bundle", "result", "transport", "files"}, "Native backend evidence")
    require(backend["source_sha"] == candidate.source_sha, "Backend ledger source differs.")
    require(type(backend["files"]) is list and 0 < len(backend["files"]) <= 512, "Backend file inventory is unavailable.")
    seen_backend = set()
    for raw in backend["files"]:
        row = require_exact_keys(raw, {"file", "sha256", "size"}, "Backend file pin")
        path = row["file"]
        require(type(path) is str and path.startswith("backend/") and path not in seen_backend, "Backend pin is duplicate or outside its root.")
        require(path in reader.evidence.files and reader.evidence.files[path].sha256 == row["sha256"] and
                reader.evidence.files[path].size == row["size"] and type(row["size"]) is int, "Backend pin differs from indexed bytes.")
        seen_backend.add(path)
    require(seen_backend == {path for path in reader.evidence.files if path.startswith("backend/")},
            "Backend ledger does not cover its complete indexed inventory.")
    for path in (backend[field] for field in ("bundle", "result", "transport")):
        require(type(path) is str and path.startswith("backend/"), "Backend reference is outside its owned evidence root.")
    backend_bundle = reader.json(backend["bundle"])
    require(backend_bundle.get("runner", {}).get("sha256") == component_hashes["runner"],
            "Backend runner differs from the trusted source.")
    backend_transport = reader.json(backend["transport"])
    require(backend_transport.get("guest_cleanup") is True, "Backend controller did not finish guest cleanup.")
    backend_digest = verify_backend_execution(reader, backend["bundle"], backend["result"],
                                              source_sha=candidate.source_sha,
                                              required_tests=profile["required_backend_test_names"])
    return {"backend_sha256": backend_digest,
            "profile_evidence_sha256": canonical_digest({"profile_sha256": profile_sha256,
                "plan_sha256": reader.evidence.files["plan.json"].sha256,
                "campaign_sha256": reader.evidence.files["campaign.json"].sha256,
                "executions": execution_digests})}
