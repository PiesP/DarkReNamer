"""Validate bounded, source-bound product timestamps for one Paths import.

The owner-thread latches describe semantic/native state changes. They do not
establish pixel presentation, input response, or a subtractable observer cost.
"""

from __future__ import annotations

from darkrenamer_tooling.evidence.errors import EvidenceError


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


EVENTS = (
    "accepted_import_start", "read_result_published", "read_owner_accepted",
    "reading_status_queued", "reading_status_committed", "reading_status_visible",
    "cancel_ready", "admission_started", "admission_result_published",
    "admission_owner_accepted", "model_committed", "native_sync_started",
    "native_sync_completed", "import_command_ready", "icons_settled",
    "reading_status_attempt_started",
)
FRAME_FIELDS = {
    "schema_version", "qpc_frequency", "trace_revision", "generation",
    "session_id", "initial_model_revision", "final_model_revision", "flags",
    "events", "process_id", "process_start_utc_ticks", "main_window_handle",
    "owner_thread_id", "query_begin_ticks", "query_end_ticks",
}
READING_QUEUED = 1
READING_COMMITTED = 2
READING_VISIBLE = 4
READING_COALESCED = 8
ADMISSION_ACCEPTED = 16
PREVIEW_SYNCHRONIZED = 32
IMPORT_COMMAND_ENABLED = 64
ICONS_SETTLED = 128
KNOWN_FLAGS = 255
MAX_TICK = 2**63 - 1
MAX_U64 = 2**64 - 1


def _object(value: object, fields: set[str], label: str) -> dict:
    require(isinstance(value, dict) and set(value) == fields,
            f"{label} has missing, duplicate, or unsupported fields.")
    return value


def _integer(value: object, minimum: int, maximum: int, label: str) -> int:
    require(type(value) is int and minimum <= value <= maximum,
            f"{label} is not a bounded integer.")
    return value


def _frame(value: object, *, label: str, frequency: int, pid: int,
           start: int, hwnd: int) -> dict:
    frame = _object(value, FRAME_FIELDS, label)
    require(_integer(frame["schema_version"], 1, 1, f"{label} schema") == 1,
            "Unsupported import trace schema.")
    require(_integer(frame["qpc_frequency"], 1, 10**10, f"{label} frequency") == frequency,
            "Import trace QPC frequency differs from the bound observer.")
    for key, expected in (("process_id", pid),
                          ("process_start_utc_ticks", start),
                          ("main_window_handle", hwnd)):
        require(_integer(frame[key], 1, MAX_TICK, f"{label} {key}") == expected,
                f"{label} product identity differs.")
    _integer(frame["owner_thread_id"], 1, 2**32 - 1, f"{label} owner thread")
    for key in ("trace_revision", "generation", "session_id",
                "initial_model_revision", "final_model_revision"):
        _integer(frame[key], 0, MAX_U64, f"{label} {key}")
    flags = _integer(frame["flags"], 0, MAX_U64, f"{label} flags")
    require(flags & ~KNOWN_FLAGS == 0, f"{label} has unknown import trace flags.")
    begin = _integer(frame["query_begin_ticks"], 1, MAX_TICK,
                     f"{label} query begin")
    end = _integer(frame["query_end_ticks"], 1, MAX_TICK,
                   f"{label} query end")
    require(begin <= end and end - begin <= frequency,
            f"{label} query interval is inverted or unbounded.")
    events = _object(frame["events"], set(EVENTS), f"{label} events")
    for name in EVENTS:
        _integer(events[name], 0, MAX_TICK, f"{label} {name}")
    return frame


def _must_order(events: dict, earlier: str, later: str) -> None:
    require(events[earlier] and events[later] and events[earlier] < events[later],
            f"Import trace {earlier} must precede {later}.")


def _milliseconds(ticks: int, frequency: int) -> float:
    return ticks * 1000 / frequency


def validate_import_trace(value: object, *, opened: int, observed: int,
                          command: int, frequency: int, pid: int, start: int,
                          hwnd: int, expected_generation: int,
                          expected_initial_revision: int | None = None) -> dict:
    """Validate a complete product import with its pre/post observer query.

    `opened` is observer Open invocation. `observed` and `command` are distinct
    observer discoveries, so their delays are never subtracted from the product
    intervals below. A zero event remains unobserved, never zero latency.
    """
    pair = _object(value, {"schema_version", "before", "after"}, "import trace")
    _integer(pair["schema_version"], 1, 1, "import trace schema")
    for label, number in (("Open invocation", opened), ("row discovery", observed),
                          ("command discovery", command)):
        _integer(number, 1, MAX_TICK, label)
    _integer(frequency, 1, 10**10, "expected QPC frequency")
    _integer(expected_generation, 1, MAX_U64, "expected import generation")
    if expected_initial_revision is not None:
        _integer(expected_initial_revision, 0, MAX_U64,
                 "expected initial model revision")
    require(opened < observed <= command,
            "Import observer event order differs.")
    before = _frame(pair["before"], label="before", frequency=frequency,
                    pid=pid, start=start, hwnd=hwnd)
    after = _frame(pair["after"], label="after", frequency=frequency,
                   pid=pid, start=start, hwnd=hwnd)
    require(before["owner_thread_id"] == after["owner_thread_id"],
            "Import trace owner thread changed across the operation.")
    require(before["query_end_ticks"] < opened < after["query_begin_ticks"] and
            command < after["query_begin_ticks"],
            "Import trace queries do not bracket the observer operation.")
    require(before["generation"] + 1 == after["generation"] == expected_generation and
            before["trace_revision"] < after["trace_revision"] and
            before["session_id"] < after["session_id"],
            "Import trace has a stale, duplicated, or foreign request.")
    require(after["session_id"] > 0 and
            (expected_initial_revision is None or
             after["initial_model_revision"] == expected_initial_revision) and
            after["final_model_revision"] == after["initial_model_revision"] + 1,
            "Import trace model revision does not match the accepted batch.")
    require(before["generation"] == 0 or
            before["final_model_revision"] == after["initial_model_revision"],
            "Import trace prior completed model revision differs.")

    events = after["events"]
    flags = after["flags"]
    require(flags & (READING_QUEUED | ADMISSION_ACCEPTED |
                     PREVIEW_SYNCHRONIZED | IMPORT_COMMAND_ENABLED) ==
            (READING_QUEUED | ADMISSION_ACCEPTED |
             PREVIEW_SYNCHRONIZED | IMPORT_COMMAND_ENABLED),
            "Import trace lacks accepted reading, admission, sync, or command state.")
    for flag, event in ((READING_QUEUED, "reading_status_queued"),
                        (READING_COMMITTED, "reading_status_committed"),
                        (READING_VISIBLE, "reading_status_visible"),
                        (ADMISSION_ACCEPTED, "admission_owner_accepted"),
                        (PREVIEW_SYNCHRONIZED, "native_sync_completed"),
                        (IMPORT_COMMAND_ENABLED, "import_command_ready"),
                        (ICONS_SETTLED, "icons_settled")):
        require(bool(flags & flag) == bool(events[event]),
                f"Import trace flag disagrees with {event}.")
    require(not (flags & READING_VISIBLE) or flags & READING_COMMITTED,
            "Visible status lacks a native status commit.")
    require(not (flags & READING_COALESCED) or not (flags & READING_COMMITTED),
            "A committed reading status cannot also be coalesced.")
    for name, tick in events.items():
        require(tick == 0 or opened < tick < after["query_begin_ticks"],
                f"Import trace {name} is outside this Open/query boundary.")
    for earlier, later in (
        ("accepted_import_start", "read_result_published"),
        ("accepted_import_start", "reading_status_queued"),
        ("read_result_published", "read_owner_accepted"),
        ("read_owner_accepted", "admission_started"),
        ("admission_started", "admission_result_published"),
        ("admission_result_published", "admission_owner_accepted"),
        ("admission_owner_accepted", "model_committed"),
        ("model_committed", "native_sync_started"),
        ("native_sync_started", "native_sync_completed"),
        ("native_sync_completed", "import_command_ready"),
    ):
        _must_order(events, earlier, later)
    require(events["import_command_ready"] < command,
            "Import command was not ready before observer discovery.")
    if events["reading_status_committed"]:
        _must_order(events, "reading_status_attempt_started", "reading_status_committed")
        require(events["reading_status_committed"] < events["import_command_ready"],
                "Reading status committed after import completion.")
    if events["reading_status_attempt_started"]:
        _must_order(events, "reading_status_queued", "reading_status_attempt_started")
        require(not flags & READING_COALESCED,
                "A reading write attempt cannot be represented as unattempted coalescing.")
    if events["reading_status_visible"]:
        _must_order(events, "reading_status_committed", "reading_status_visible")
        require(events["reading_status_visible"] < events["import_command_ready"],
                "Visible reading status followed command readiness.")
    if events["cancel_ready"]:
        _must_order(events, "reading_status_queued", "cancel_ready")
        require(events["cancel_ready"] < events["import_command_ready"],
                "Cancel became ready after the import finished.")
    if events["icons_settled"]:
        _must_order(events, "import_command_ready", "icons_settled")
    require(events["native_sync_completed"] < after["query_begin_ticks"] and
            events["model_committed"] < after["query_begin_ticks"],
            "Import completion is outside the captured trace frame.")

    feedback_interval = None
    if events["reading_status_visible"]:
        lower = events["reading_status_attempt_started"]
        upper = events["reading_status_visible"]
        cancel = events["cancel_ready"]
        if cancel and lower <= cancel <= upper:
            feedback_kind, feedback_tick = None, None
            feedback_gap = "status-write-and-cancel-order-overlap"
            feedback_interval = {"lower_ticks": lower, "upper_ticks": cancel}
        elif cancel and cancel < lower:
            feedback_kind, feedback_tick = "layout-qualified-cancel-control", cancel
            feedback_gap = None
            feedback_interval = {"lower_ticks": cancel, "upper_ticks": cancel}
        else:
            feedback_kind, feedback_tick = "visible-native-reading-status", upper
            feedback_gap = None
            feedback_interval = {"lower_ticks": lower, "upper_ticks": upper}
    elif flags & READING_COALESCED and events["cancel_ready"]:
        feedback_kind, feedback_tick = "layout-qualified-cancel-control", events["cancel_ready"]
        feedback_gap = None
        feedback_interval = {"lower_ticks": feedback_tick, "upper_ticks": feedback_tick}
    else:
        feedback_kind, feedback_tick = None, None
        feedback_gap = ("reading-status-only-semantic-or-unobserved"
                        if flags & READING_COMMITTED else
                        "earlier-status-state-not-discriminated")

    intervals = {
        "open_to_accepted_ms": _milliseconds(events["accepted_import_start"] - opened, frequency),
        "accepted_to_read_publication_ms": _milliseconds(
            events["read_result_published"] - events["accepted_import_start"], frequency),
        "read_publication_to_owner_accept_ms": _milliseconds(
            events["read_owner_accepted"] - events["read_result_published"], frequency),
        "read_owner_to_admission_start_ms": _milliseconds(
            events["admission_started"] - events["read_owner_accepted"], frequency),
        "admission_start_to_publication_ms": _milliseconds(
            events["admission_result_published"] - events["admission_started"], frequency),
        "admission_publication_to_owner_accept_ms": _milliseconds(
            events["admission_owner_accepted"] - events["admission_result_published"], frequency),
        "admission_owner_to_model_commit_ms": _milliseconds(
            events["model_committed"] - events["admission_owner_accepted"], frequency),
        "model_commit_to_native_sync_start_ms": _milliseconds(
            events["native_sync_started"] - events["model_committed"], frequency),
        "native_sync_ms": _milliseconds(
            events["native_sync_completed"] - events["native_sync_started"], frequency),
        "native_sync_to_command_ready_ms": _milliseconds(
            events["import_command_ready"] - events["native_sync_completed"], frequency),
        "open_to_native_sync_end_ms": _milliseconds(
            events["native_sync_completed"] - opened, frequency),
        "open_to_product_command_ready_ms": _milliseconds(
            events["import_command_ready"] - opened, frequency),
        "open_to_rows_observed_ms": _milliseconds(observed - opened, frequency),
        "open_to_command_observed_ms": _milliseconds(command - opened, frequency),
    }
    for event in ("reading_status_queued", "reading_status_attempt_started", "reading_status_committed",
                  "reading_status_visible", "cancel_ready"):
        intervals[f"open_to_{event}_ms"] = (
            _milliseconds(events[event] - opened, frequency) if events[event] else None)
    if feedback_interval is not None:
        intervals["open_to_first_functional_feedback_lower_ms"] = _milliseconds(
            feedback_interval["lower_ticks"] - opened, frequency)
        intervals["open_to_first_functional_feedback_upper_ms"] = _milliseconds(
            feedback_interval["upper_ticks"] - opened, frequency)
        intervals["first_functional_feedback_state_uncertainty_ms"] = _milliseconds(
            feedback_interval["upper_ticks"] - feedback_interval["lower_ticks"], frequency)
    return {
        "schema_version": 1,
        "generation": after["generation"],
        "session_id": after["session_id"],
        "owner_thread_id": after["owner_thread_id"],
        "initial_model_revision": after["initial_model_revision"],
        "final_model_revision": after["final_model_revision"],
        "trace_revision": after["trace_revision"],
        "flags": flags,
        "events": {name: events[name] for name in EVENTS},
        "first_functional_feedback_kind": feedback_kind,
        "first_functional_feedback_tick": feedback_tick,
        "first_functional_feedback_interval": feedback_interval,
        "first_functional_feedback_gap": feedback_gap,
        "intervals_ms": intervals,
        "duration_resolution_uncertainty_ms": _milliseconds(2, frequency),
        "observer_query_duration_ms": {
            side: _milliseconds(frame["query_end_ticks"] - frame["query_begin_ticks"], frequency)
            for side, frame in (("before", before), ("after", after))
        },
        "pixel_presentation": "not-measured",
        "icon_settlement": "recorded" if events["icons_settled"] else "unobserved",
    }
