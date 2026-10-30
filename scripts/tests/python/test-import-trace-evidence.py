"""Import trace admission rejects stale or mislabeled timing evidence."""

from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from darkrenamer_tooling.evidence.errors import EvidenceError
from darkrenamer_tooling.evidence import import_trace


FREQUENCY = 10_000_000
PID = 41
START = 638965440000000000
HWND = 900
OPENED = 100
OBSERVED = 350
COMMAND = 360


def frame(*, generation=0, session=0, initial=0, final=0, revision=0,
          flags=0, events=None, begin=50, end=80):
    return {
        "schema_version": 1, "qpc_frequency": FREQUENCY,
        "trace_revision": revision, "generation": generation,
        "session_id": session, "initial_model_revision": initial,
        "final_model_revision": final, "flags": flags,
        "events": events if events is not None else {name: 0 for name in import_trace.EVENTS},
        "process_id": PID, "process_start_utc_ticks": START,
        "main_window_handle": HWND, "owner_thread_id": 12,
        "query_begin_ticks": begin, "query_end_ticks": end,
    }


def valid_trace():
    events = {
        "accepted_import_start": 150,
        "read_result_published": 180,
        "read_owner_accepted": 200,
        "reading_status_queued": 170,
        "reading_status_committed": 175,
        "reading_status_visible": 176,
        "cancel_ready": 190,
        "admission_started": 220,
        "admission_result_published": 250,
        "admission_owner_accepted": 260,
        "model_committed": 270,
        "native_sync_started": 280,
        "native_sync_completed": 300,
        "import_command_ready": 310,
        "icons_settled": 330,
        "reading_status_attempt_started": 172,
    }
    return {"schema_version": 1, "before": frame(),
            "after": frame(generation=1, session=1, initial=0, final=1,
                           revision=16, flags=1 | 2 | 4 | 16 | 32 | 64 | 128,
                           events=events, begin=400, end=410)}


def validate(value, *, expected_generation=1, expected_initial_revision=0):
    return import_trace.validate_import_trace(
        value, opened=OPENED, observed=OBSERVED, command=COMMAND,
        frequency=FREQUENCY, pid=PID, start=START, hwnd=HWND,
        expected_generation=expected_generation,
        expected_initial_revision=expected_initial_revision)


class ImportTraceEvidenceTests(unittest.TestCase):
    def test_visible_status_wins_earliest_eligible_event(self):
        result = validate(valid_trace())
        self.assertEqual(result["first_functional_feedback_kind"],
                         "visible-native-reading-status")
        self.assertEqual(result["first_functional_feedback_tick"], 176)
        self.assertEqual(result["first_functional_feedback_interval"],
                         {"lower_ticks": 172, "upper_ticks": 176})
        self.assertEqual(result["events"]["read_result_published"], 180)
        self.assertAlmostEqual(result["intervals_ms"]["native_sync_ms"], 0.002)
        self.assertEqual(result["duration_resolution_uncertainty_ms"], 0.0002)
        self.assertEqual(result["pixel_presentation"], "not-measured")

    def test_cancel_wins_when_status_was_proven_coalesced(self):
        record = valid_trace()
        after = record["after"]
        after["events"]["reading_status_committed"] = 0
        after["events"]["reading_status_visible"] = 0
        after["events"]["reading_status_attempt_started"] = 0
        after["flags"] = 1 | 8 | 16 | 32 | 64 | 128
        result = validate(record)
        self.assertEqual(result["first_functional_feedback_kind"],
                         "layout-qualified-cancel-control")
        self.assertEqual(result["first_functional_feedback_tick"], 190)
        self.assertIsNone(result["first_functional_feedback_gap"])

    def test_reentrant_cancel_during_status_write_retains_uncertain_first_state(self):
        record = valid_trace()
        record['after']['events']['cancel_ready'] = 174
        result = validate(record)
        self.assertIsNone(result['first_functional_feedback_kind'])
        self.assertIsNone(result['first_functional_feedback_tick'])
        self.assertEqual(result['first_functional_feedback_gap'],
                         'status-write-and-cancel-order-overlap')
        self.assertEqual(result['first_functional_feedback_interval'],
                         {'lower_ticks': 172, 'upper_ticks': 174})
        self.assertAlmostEqual(result['intervals_ms'][
            'first_functional_feedback_state_uncertainty_ms'], 0.0002)

    def test_cancel_before_status_attempt_has_known_first_latch(self):
        record = valid_trace()
        record['after']['events']['cancel_ready'] = 171
        result = validate(record)
        self.assertEqual(result['first_functional_feedback_kind'],
                         'layout-qualified-cancel-control')
        self.assertEqual(result['first_functional_feedback_interval'],
                         {'lower_ticks': 171, 'upper_ticks': 171})

    def test_semantic_only_status_retains_feedback_gap(self):
        record = valid_trace()
        record["after"]["events"]["reading_status_visible"] = 0
        record["after"]["flags"] &= ~4
        result = validate(record)
        self.assertIsNone(result["first_functional_feedback_tick"])
        self.assertEqual(result["first_functional_feedback_gap"],
                         "reading-status-only-semantic-or-unobserved")

    def test_status_and_read_worker_order_can_overlap(self):
        record = valid_trace()
        record["after"]["events"]["read_result_published"] = 171
        result = validate(record)
        self.assertEqual(result["events"]["reading_status_committed"], 175)

    def test_rejects_foreign_or_stale_trace_and_invalid_clock(self):
        mutations = (
            lambda r: r["after"].__setitem__("process_id", PID + 1),
            lambda r: r["before"].__setitem__("process_start_utc_ticks", START + 1),
            lambda r: r["after"].__setitem__("main_window_handle", HWND + 1),
            lambda r: r["after"].__setitem__("owner_thread_id", 13),
            lambda r: r["after"].__setitem__("qpc_frequency", FREQUENCY + 1),
            lambda r: r["after"].__setitem__("generation", 2),
            lambda r: r["after"].__setitem__("trace_revision", 0),
            lambda r: r["after"].__setitem__("session_id", 0),
            lambda r: r["after"].__setitem__("final_model_revision", 0),
            lambda r: r["before"].__setitem__("query_end_ticks", OPENED),
            lambda r: r["after"].__setitem__("query_begin_ticks", COMMAND),
            lambda r: r["after"].__setitem__("flags", 256),
            lambda r: r["after"].__setitem__("generation", True),
            lambda r: r["after"].pop("owner_thread_id"),
            lambda r: r["after"]["events"].__setitem__("unexpected", 1),
        )
        for mutation in mutations:
            record = valid_trace()
            mutation(record)
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                validate(record)

    def test_rejects_missing_events_false_flags_and_premature_readiness(self):
        mutations = (
            lambda r: r["after"]["events"].__setitem__("admission_result_published", 0),
            lambda r: r["after"]["events"].__setitem__("native_sync_completed", 0),
            lambda r: r["after"]["events"].__setitem__("import_command_ready", 275),
            lambda r: r["after"]["events"].__setitem__("native_sync_started", 250),
            lambda r: r["after"]["events"].__setitem__("reading_status_queued", 0),
            lambda r: r["after"].__setitem__("flags", r["after"]["flags"] | 8),
            lambda r: r["after"].__setitem__("flags", r["after"]["flags"] & ~64),
            lambda r: r["after"]["events"].__setitem__("icons_settled", 0),
            lambda r: r["after"]["events"].__setitem__("cancel_ready", 315),
        )
        for mutation in mutations:
            record = valid_trace()
            mutation(record)
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                validate(record)

    def test_next_generation_reuses_expected_revision_not_old_timestamps(self):
        record = valid_trace()
        previous = record["before"]
        previous["generation"] = 1
        previous["session_id"] = 1
        previous["final_model_revision"] = 1
        previous["trace_revision"] = 16
        after = record["after"]
        after["generation"] = 2
        after["session_id"] = 3
        after["initial_model_revision"] = 1
        after["final_model_revision"] = 2
        after["trace_revision"] = 32
        self.assertEqual(validate(record, expected_generation=2,
                                  expected_initial_revision=1)["generation"], 2)
        previous["final_model_revision"] = 0
        with self.assertRaises(EvidenceError):
            validate(record, expected_generation=2, expected_initial_revision=1)


if __name__ == "__main__":
    unittest.main()
