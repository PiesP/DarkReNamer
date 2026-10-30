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
            for mid, sample in runs[-1]["metrics"].items():
                sample["brackets"] = [{
                    "qpc_frequency": 10000000,
                    "last_negative_begin_ticks": None,
                    "last_negative_end_ticks": None,
                    "first_positive_begin_ticks": 100 + probe * 20,
                    "first_positive_end_ticks": 110 + probe * 20,
                } for probe in range(baseline.READINESS_COUNTS.get(mid, 0))]
                if mid in baseline.CPU_METRICS:
                    sample["cpu_window"] = {
                        "qpc_frequency": 10000000,
                        "before": {"begin_ticks": 100, "end_ticks": 110,
                                   "cpu_total_ticks": 10000},
                        "after": {"begin_ticks": 300000110, "end_ticks": 300000120,
                                  "cpu_total_ticks": 10000 + int(sample["value"] * 10000)},
                    }
        scopes.append({"id": sid, **pins, "metrics": metrics, "runs": runs})
    return {"schema": "darkrenamer-baseline-records-v1", **SOURCE,
            "frozen_plan_sha256": PLAN_SHA, "scopes": scopes,
            "unavailable_scopes": [], "unavailable_metrics": []}


def v2_fixture(plan_hash=PLAN_SHA):
    records = fixture()
    records["schema"] = "darkrenamer-baseline-records-v2"
    records["frozen_plan_sha256"] = plan_hash
    records["product_input_sha256"] = "d" * 64
    original = {**SOURCE, "product_input_sha256": records["product_input_sha256"]}
    repaired = {"source_sha": "7" * 40, "source_tree": "8" * 40,
                "harness_sha": "9" * 40,
                "product_input_sha256": records["product_input_sha256"]}
    provenance = {sid: copy.deepcopy(repaired if sid in
                  {"runtime-baseline", "performance-sample"} else original)
                  for sid in baseline.SCOPES}
    records["scope_provenance"] = copy.deepcopy(provenance)
    for scope in records["scopes"]:
        for run in scope["runs"]:
            run.update({key: provenance[scope["id"]][key] for key in SOURCE})
            if scope["id"] in {"runtime-baseline", "performance-sample"}:
                run["started_at"] = run["started_at"].replace("2026-10-30", "2026-10-31")
                run["ended_at"] = run["ended_at"].replace("2026-10-30", "2026-10-31")
    amendment = {"schema": "darkrenamer-baseline-provenance-amendment-v1",
                 "original_frozen_plan_sha256": plan_hash,
                 "product_input_sha256": records["product_input_sha256"],
                 "scope_provenance": copy.deepcopy(provenance),
                 "declared_at": "2026-10-30T23:00:00Z",
                 "reason": "GUI observer request shape repair after first runtime admission failed."}
    amendment_bytes = json.dumps(amendment, separators=(",", ":")).encode()
    amendment_hash = hashlib.sha256(amendment_bytes).hexdigest()
    records["provenance_amendment_sha256"] = amendment_hash
    return records, amendment, amendment_bytes


class BaselineSummaryTests(unittest.TestCase):
    def test_v2_preserves_original_native_and_repaired_gui_source_bindings(self):
        records, amendment, amendment_bytes = v2_fixture()
        summary = baseline.summarize(records, PLAN_SHA, amendment,
                                     hashlib.sha256(amendment_bytes).hexdigest())
        self.assertEqual(summary["schema"], "darkrenamer-baseline-summary-v2")
        self.assertEqual(summary["status"], "complete")
        by_id = {scope["id"]: scope for scope in summary["scope_results"]}
        self.assertEqual(by_id["runtime-model"]["scope_provenance"],
                         {**SOURCE, "product_input_sha256": "d" * 64})
        self.assertEqual(by_id["runtime-baseline"]["scope_provenance"],
                         {**{key: "789"[index] * 40 for index, key in enumerate(SOURCE)},
                          "product_input_sha256": "d" * 64})
        self.assertEqual(summary["source_sha"], SOURCE["source_sha"])
        self.assertEqual([len(scope["runs"]) for scope in summary["scope_results"]],
                         [6, 6, 6, 6])

    def test_v2_rejects_implicit_source_and_product_or_amendment_drift(self):
        original, amendment, amendment_bytes = v2_fixture()
        amendment_hash = hashlib.sha256(amendment_bytes).hexdigest()
        cases = [
            (lambda records, _: records["scopes"][0]["runs"][0].update(source_sha="6" * 40),
             "source_sha drifted"),
            (lambda records, _: records["scope_provenance"]["runtime-baseline"].update(
                source_sha="6" * 40), "differs from amendment"),
            (lambda records, _: records["scope_provenance"]["runtime-model"].update(
                product_input_sha256="e" * 64), "differs from amendment"),
            (lambda records, amend: amend["scope_provenance"]["refresh-stages"].update(
                product_input_sha256="e" * 64), "product input differs"),
            (lambda records, _: records.update(provenance_amendment_sha256="e" * 64),
             "amendment digest differs"),
            (lambda records, _: records.pop("scope_provenance"), "missing or unexpected fields"),
            (lambda records, _: records["scope_provenance"]["runtime-model"].update(
                unreviewed_source="e" * 40), "differs from amendment"),
            (lambda records, amend: amend.update(unreviewed_source="e" * 40),
             "missing or unexpected fields"),
        ]
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                records, amended = copy.deepcopy((original, amendment))
                mutate(records, amended)
                with self.assertRaisesRegex(ValueError, expected):
                    baseline.summarize(records, PLAN_SHA, amended, amendment_hash)
        with self.assertRaisesRegex(ValueError, "require a provenance amendment"):
            baseline.summarize(original, PLAN_SHA)
        late_amendment = copy.deepcopy(amendment)
        late_amendment["declared_at"] = "2026-11-01T00:00:00Z"
        late_hash = hashlib.sha256(json.dumps(late_amendment).encode()).hexdigest()
        late_records = copy.deepcopy(original)
        late_records["provenance_amendment_sha256"] = late_hash
        with self.assertRaisesRegex(ValueError, "declared after a GUI run"):
            baseline.summarize(late_records, PLAN_SHA, late_amendment, late_hash)

    def test_v2_rejects_gui_source_or_executable_pair_drift(self):
        original, amendment, amendment_bytes = v2_fixture()
        amendment_hash = hashlib.sha256(amendment_bytes).hexdigest()
        cases = [
            (lambda records, amend: (records["scope_provenance"]["performance-sample"].update(
                source_sha="6" * 40), amend["scope_provenance"]["performance-sample"].update(
                source_sha="6" * 40), [run.update(source_sha="6" * 40) for run in
                                       records["scopes"][1]["runs"]]),
             "different source provenance"),
            (lambda records, _: (records["scopes"][1].update(pdb_sha256="e" * 64),
                                 [run.update(pdb_sha256="e" * 64) for run in
                                  records["scopes"][1]["runs"]]),
             "different executable pairs"),
        ]
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                records, amended = copy.deepcopy((original, amendment))
                mutate(records, amended)
                with self.assertRaisesRegex(ValueError, expected):
                    baseline.summarize(records, PLAN_SHA, amended, amendment_hash)

    def test_v1_forbids_amendment_and_retains_v1_output(self):
        records = fixture()
        self.assertEqual(baseline.summarize(records, PLAN_SHA)["schema"],
                         "darkrenamer-baseline-summary-v1")
        with self.assertRaisesRegex(ValueError, "forbid a provenance amendment"):
            baseline.summarize(records, PLAN_SHA, {"schema": "other"}, "0" * 64)

    def test_cli_requires_exact_amendment_bytes_for_v2_and_forbids_it_for_v1(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = root / "plan.json"
            plan.write_text(json.dumps({"schema": "darkrenamer-baseline-prospective-plan-v1",
                                        "issue": 219, "declared_at": "2026-10-30T00:00:00Z"}))
            plan_hash = hashlib.sha256(plan.read_bytes()).hexdigest()
            records, amendment, amendment_bytes = v2_fixture(plan_hash)
            input_path = root / "records.json"
            input_path.write_text(json.dumps(records))
            amendment_path = root / "amendment.json"
            amendment_path.write_bytes(amendment_bytes)
            command = [sys.executable, "-I", str(SCRIPT), "--input", str(input_path),
                       "--plan", str(plan), "--output", str(root / "summary.json")]
            missing = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("require a provenance amendment", missing.stderr)
            command.extend(["--provenance-amendment", str(amendment_path)])
            passed = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertEqual(json.loads((root / "summary.json").read_text())["schema"],
                             "darkrenamer-baseline-summary-v2")
            amendment_path.write_text(json.dumps(amendment, indent=2))
            command[command.index("--output") + 1] = str(root / "wrong-digest.json")
            mismatch = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("amendment digest differs", mismatch.stderr)
            self.assertFalse((root / "wrong-digest.json").exists())
            old_records = fixture()
            old_records["frozen_plan_sha256"] = plan_hash
            input_path.write_text(json.dumps(old_records))
            command[command.index("--output") + 1] = str(root / "v1-with-amendment.json")
            forbidden = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(forbidden.returncode, 0)
            self.assertIn("forbid a provenance amendment", forbidden.stderr)
            self.assertFalse((root / "v1-with-amendment.json").exists())

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

    def test_cpu_delta_and_idle_duration_are_recomputed_from_raw_queries(self):
        original = fixture()
        cases = [
            (lambda samples: samples["empty_idle_cpu_delta_ms"]["cpu_window"]["after"].update(
                begin_ticks=299000110), "actual 30-second"),
            (lambda samples: samples["empty_idle_cpu_delta_ms"].update(value=1),
             "CPU delta differs"),
            (lambda samples: samples["fresh_system_ready_ms"].update(brackets=[]),
             "lacks its observed query brackets"),
        ]
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                records = copy.deepcopy(original)
                mutate(records["scopes"][0]["runs"][0]["metrics"])
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
