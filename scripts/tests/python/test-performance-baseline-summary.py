"""Independent arithmetic and evidence-admission checks for baseline summaries."""

import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "summarize-performance-baseline.py"
SPEC = importlib.util.spec_from_file_location("baseline_summary", SCRIPT)
baseline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(baseline)
PLAN_SHA = "f" * 64
SOURCE = {"source_sha": "a" * 40, "source_tree": "b" * 40,
          "harness_sha": "c" * 40}


def fixture():
    scopes = []
    for index, (sid, expected) in enumerate(baseline.SCOPES.items()):
        digest = "1" * 64 if sid in {"runtime-baseline", "performance-sample"} else str(index + 1) * 64
        pins = {"artifact_sha256": digest, "pdb_sha256": digest,
                "profile_sha256": "4" * 64, "fixture_sha256": "5" * 64,
                "environment_sha256": "6" * 64}
        metrics = [{"id": mid, "unit": unit, "budget": budget,
                    "endpoint": f"Observed {mid} endpoint", "within_process_estimator": "One process value",
                    "process_cell": cell}
                   for mid, (unit, budget, cell) in expected.items()]
        cells = sorted({item["process_cell"] for item in metrics})
        runs = []
        for n in range(1, 7):
            runs.append({"index": n, **SOURCE, **pins,
                         "started_at": f"2026-10-30T12:{n:02d}:00Z",
                         "ended_at": f"2026-10-30T12:{n:02d}:01Z",
                         "processes": {cell: {"pid": 1000 + n + cell_index * 10,
                                              "creation_utc_ticks": 1000000 + index * 1000 + n + cell_index * 10}
                                       for cell_index, cell in enumerate(cells)},
                         "validation_receipt_sha256": format(100 + index * 6 + n, "064x"),
                         "observation_receipt_sha256": format(200 + index * 6 + n, "064x"),
                         "validity": "accepted", "cleanup": "owned-clean",
                         "unknown_probe_failures": 0,
                         "metrics": {mid: {"value": budget / 2,
                                           "process_cell": cell, "brackets": []}
                                     for mid, (_, budget, cell) in expected.items()}})
        scopes.append({"id": sid, **pins, "metrics": metrics, "runs": runs})
    return {"schema": "darkrenamer-baseline-records-v1", **SOURCE,
            "frozen_plan_sha256": PLAN_SHA, "scopes": scopes,
            "unavailable_scopes": [], "unavailable_metrics": []}


class BaselineSummaryTests(unittest.TestCase):
    def test_six_independent_values_use_median_range_and_fixed_budget(self):
        records = fixture()
        metric = "ordinary_100_ms"
        for run, value in zip(records["scopes"][1]["runs"], [500, 600, 700, 900, 1000, 1100]):
            run["metrics"][metric]["value"] = value
        summary = baseline.summarize(records, PLAN_SHA)
        result = next(item for item in summary["scope_results"][1]["metrics"]
                      if item["id"] == metric)
        self.assertEqual(result["values"], [500, 600, 700, 900, 1000, 1100])
        self.assertEqual((result["median"], result["minimum"], result["maximum"]),
                         (800, 500, 1100))
        self.assertEqual(result["spread_range_over_median"], 0.75)
        self.assertEqual(result["disposition"], "accepted")
        records["scopes"][1]["runs"][2]["metrics"][metric]["value"] = 702
        summary = baseline.summarize(records, PLAN_SHA)
        result = next(item for item in summary["scope_results"][1]["metrics"]
                      if item["id"] == metric)
        self.assertEqual(result["median"], 801)
        self.assertEqual(result["disposition"], "exceeded")
        self.assertEqual(summary["status"], "complete-with-exceeded-budgets")

    def test_missing_scope_or_metric_requires_specific_unavailable_reason(self):
        records = fixture()
        records["scopes"].pop()
        with self.assertRaisesRegex(ValueError, "all four scopes"):
            baseline.summarize(records, PLAN_SHA)
        records["unavailable_scopes"] = [{"id": "refresh-stages",
                                           "reason": "No VM artifact was available after a failed build."}]
        self.assertEqual(baseline.summarize(records, PLAN_SHA)["status"], "incomplete")
        records = fixture()
        records["scopes"][0]["metrics"].pop()
        for run in records["scopes"][0]["runs"]:
            run["metrics"].pop("populated_idle_private_mib")
        with self.assertRaisesRegex(ValueError, "metric inventory"):
            baseline.summarize(records, PLAN_SHA)
        records["unavailable_metrics"] = [{"scope": "runtime-baseline",
                                            "id": "populated_idle_private_mib",
                                            "reason": "Existing sampler lacks a settled post-workload observation."}]
        self.assertEqual(baseline.summarize(records, PLAN_SHA)["status"], "incomplete")

    def test_rejects_drifted_artifact_reused_process_and_bad_quality(self):
        original = fixture()
        cases = [
            (lambda value: value["scopes"][1]["runs"][2].update(artifact_sha256="d" * 64),
             "artifact_sha256 drifted"),
            (lambda value: value["scopes"][0]["runs"][1]["processes"].update(
                {"fresh-system": copy.deepcopy(value["scopes"][0]["runs"][0]["processes"]["fresh-system"])}),
             "process identity was reused"),
            (lambda value: value["scopes"][0]["runs"][0]["processes"].update(
                {"saved-system": copy.deepcopy(value["scopes"][0]["runs"][0]["processes"]["fresh-system"])}),
             "process identity was reused"),
            (lambda value: value["scopes"][0]["runs"][1].update(
                validation_receipt_sha256=value["scopes"][0]["runs"][0]["validation_receipt_sha256"]),
             "validation_receipt_sha256 was reused"),
            (lambda value: value["scopes"][2]["runs"][0].update(cleanup="unknown"),
             "evidence quality"),
            (lambda value: value["scopes"][2]["runs"][0].update(unknown_probe_failures=1),
             "evidence quality"),
            (lambda value: value["scopes"][1]["metrics"][0].update(budget=900),
             "budget, unit, or process cell drifted"),
            (lambda value: value["scopes"][1]["runs"][0]["metrics"]["ordinary_100_ms"].update(value=True),
             "finite nonnegative"),
            (lambda value: value["scopes"][1]["runs"][0]["metrics"]["ordinary_100_ms"].update(value=float("nan")),
             "finite nonnegative"),
        ]
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                records = copy.deepcopy(original)
                mutate(records)
                with self.assertRaisesRegex(ValueError, expected):
                    baseline.summarize(records, PLAN_SHA)

    def test_query_brackets_require_order_and_complete_boundaries(self):
        records = fixture()
        sample = records["scopes"][0]["runs"][0]["metrics"]["fresh_system_ready_ms"]
        sample["brackets"] = [{"qpc_frequency": 10000000,
                               "last_negative_begin_ticks": 100,
                               "last_negative_end_ticks": 103,
                               "first_positive_begin_ticks": 110,
                               "first_positive_end_ticks": 115}]
        self.assertEqual(baseline.summarize(records, PLAN_SHA)["status"], "complete")
        sample["brackets"][0]["first_positive_begin_ticks"] = 102
        with self.assertRaisesRegex(ValueError, "overlap"):
            baseline.summarize(records, PLAN_SHA)
        sample["brackets"][0]["first_positive_begin_ticks"] = 110
        sample["brackets"][0]["last_negative_end_ticks"] = None
        with self.assertRaisesRegex(ValueError, "partial"):
            baseline.summarize(records, PLAN_SHA)

    def test_separate_command_scopes_cannot_reuse_one_product_process_or_receipt(self):
        original = fixture()
        runtime = original["scopes"][0]["runs"][0]
        cases = [
            (lambda run: run["processes"].update(
                product=copy.deepcopy(runtime["processes"]["fresh-system"])),
             "process identity was reused"),
            (lambda run: run.update(
                validation_receipt_sha256=runtime["validation_receipt_sha256"]),
             "validation_receipt_sha256 was reused"),
            (lambda run: run.update(
                observation_receipt_sha256=runtime["observation_receipt_sha256"]),
             "observation_receipt_sha256 was reused"),
        ]
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                records = copy.deepcopy(original)
                mutate(records["scopes"][1]["runs"][0])
                with self.assertRaisesRegex(ValueError, expected):
                    baseline.summarize(records, PLAN_SHA)

    def test_cli_reads_frozen_plan_and_writes_new_private_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = root / "plan.json"
            plan.write_text(json.dumps({"schema": "darkrenamer-baseline-prospective-plan-v1",
                                        "issue": 219, "declared_at": datetime.now(timezone.utc).isoformat()}))
            plan_hash = hashlib.sha256(plan.read_bytes()).hexdigest()
            records = fixture()
            records["frozen_plan_sha256"] = plan_hash
            input_path = root / "records.json"
            input_path.write_text(json.dumps(records))
            output = root / "summary.json"
            command = [sys.executable, "-I", str(SCRIPT), "--input", str(input_path),
                       "--plan", str(plan), "--output", str(output)]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(output.read_text())
            self.assertEqual(summary["status"], "complete")
            self.assertEqual(summary["frozen_plan_sha256"], plan_hash)
            self.assertEqual(len(summary["scope_results"]), 4)
            again = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(again.returncode, 0)
            self.assertIn("exists", again.stderr)
            self.assertEqual(json.loads(output.read_text()), summary)
            records["scopes"][0]["runs"][0]["cleanup"] = "unknown"
            input_path.write_text(json.dumps(records))
            failed_output = root / "failed-summary.json"
            command[-1] = str(failed_output)
            failed = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse(failed_output.exists())


if __name__ == "__main__":
    unittest.main()
