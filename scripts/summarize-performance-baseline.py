#!/usr/bin/env python3
"""Summarize six accepted DarkReNamer #219 observations per fixed scope.

Input is a path-free, sanitized transcription of records already accepted by
the native and GUI evidence verifiers. This reducer checks the transcription's
shape, pins, independent process identities, and arithmetic. It does not
authenticate the underlying VM receipts or turn a transcription into runtime
evidence. Keep the raw validation receipts and their hashes separately.

Input schema (all listed fields are required; extra fields are rejected):

  {"schema":"darkrenamer-baseline-records-v1", "source_sha":"40 hex",
   "source_tree":"40 hex", "harness_sha":"40 hex",
   "frozen_plan_sha256":"64 hex", "scopes":[SCOPE, ...],
   "unavailable_scopes":[{"id":"scope", "reason":"specific cause"}, ...],
   "unavailable_metrics":[{"scope":"scope", "id":"metric", "reason":"cause"}, ...]}

  v2 retains the v1 fields and uses schema darkrenamer-baseline-records-v2.
  It additionally requires product_input_sha256, provenance_amendment_sha256,
  and scope_provenance, a map of available scope IDs to SOURCE_PROVENANCE.
  SOURCE_PROVENANCE = {"source_sha":"40 hex", "source_tree":"40 hex",
                       "harness_sha":"40 hex", "product_input_sha256":"64 hex"}
  The top source pins identify the original native reference. V2 must be paired
  with --provenance-amendment, whose exact bytes match the declared digest.
  The amendment declares all four scope provenances, the common product-input
  digest, the original plan digest, a UTC declaration time, and a specific reason.

  SCOPE = {"id":"runtime-baseline|performance-sample|runtime-model|refresh-stages",
           "artifact_sha256":"64 hex", "pdb_sha256":"64 hex",
           "profile_sha256":"64 hex", "fixture_sha256":"64 hex",
           "environment_sha256":"64 hex", "metrics":[METRIC, ...],
           "runs":[RUN, RUN, RUN, RUN, RUN, RUN]}
  METRIC = {"id":"fixed metric id", "unit":"ms|MiB", "budget":number,
            "endpoint":"specific measured endpoint",
            "within_process_estimator":"specific per-process reduction",
            "process_cell":"cell name"}
  RUN = {"index":1..6, "source_sha":"40 hex", "source_tree":"40 hex",
         "harness_sha":"40 hex", "artifact_sha256":"64 hex",
         "pdb_sha256":"64 hex", "profile_sha256":"64 hex",
         "fixture_sha256":"64 hex", "environment_sha256":"64 hex",
         "started_at":"UTC ISO-8601", "ended_at":"UTC ISO-8601",
         "processes":{"cell name":{"pid":positive integer,
                         "creation_utc_ticks":positive integer}},
         "validation_receipt_sha256":"64 hex",
         "observation_receipt_sha256":"64 hex", "validity":"accepted",
         "cleanup":"owned-clean", "unknown_probe_failures":0,
         "metrics":{"fixed metric id":{"value":number,
                  "process_cell":"cell name", "brackets":[BRACKET, ...]}}}
  BRACKET = {"qpc_frequency":positive integer,
             "last_negative_begin_ticks":integer|null,
             "last_negative_end_ticks":integer|null,
             "first_positive_begin_ticks":integer,
             "first_positive_end_ticks":integer}

CPU metric samples additionally require cpu_window with qpc_frequency and
before/after objects containing begin_ticks, end_ticks and cpu_total_ticks.
These raw values independently reproduce the CPU delta and the actual idle
duration bracket. Startup/import metrics require their query brackets.

An unavailable scope or metric needs its own specific reason. Complete input
must cover the fixed metric inventory below; omission is not a passing value.
"""

import sys

if __name__ == "__main__" and not sys.flags.isolated:
    _platform_os = __import__("nt" if sys.platform == "win32" else "posix")
    _platform_os.execv(sys.executable, [sys.executable, "-I", __file__, *sys.argv[1:]])

import argparse
from datetime import datetime, timedelta
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
from statistics import median

HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
MAX_INPUT_BYTES = 2 * 1024 * 1024
SCOPES = {
    "runtime-baseline": {
        "fresh_system_ready_ms": ("ms", 750, "fresh-system"),
        "saved_system_ready_ms": ("ms", 350, "saved-system"),
        "saved_english_ready_ms": ("ms", 350, "saved-english"),
        "empty_idle_cpu_delta_ms": ("ms", 100, "fresh-system"),
        "populated_idle_cpu_delta_ms": ("ms", 150, "fresh-system"),
        "empty_idle_private_mib": ("MiB", 6, "fresh-system"),
        "populated_idle_private_mib": ("MiB", 20, "fresh-system"),
    },
    "performance-sample": {
        "ordinary_100_ms": ("ms", 800, "product"),
        "ordinary_1000_ms": ("ms", 1200, "product"),
        "ordinary_10000_ms": ("ms", 4500, "product"),
        "long_hidden_1000_ms": ("ms", 1000, "product"),
        "long_visible_1000_ms": ("ms", 1000, "product"),
        "workload_private_peak_mib": ("MiB", 64, "product"),
        "workload_private_post_mib": ("MiB", 24, "product"),
    },
    "runtime-model": {
        "model_preview_10000_ms": ("ms", 10, "model-test"),
        "model_sort_10000_ms": ("ms", 20, "model-test"),
    },
    "refresh-stages": {
        "timestamp_unchanged_10000_hidden_ms": ("ms", 35, "hidden-visible"),
        "timestamp_unchanged_10000_visible_ms": ("ms", 35, "visible-hidden"),
    },
}
SCOPE_KEYS = {"id", "artifact_sha256", "pdb_sha256", "profile_sha256",
              "fixture_sha256", "environment_sha256", "metrics", "runs"}
RUN_KEYS = {"index", "source_sha", "source_tree", "harness_sha",
            "artifact_sha256", "pdb_sha256", "profile_sha256", "fixture_sha256",
            "environment_sha256", "started_at", "ended_at", "processes",
            "validation_receipt_sha256", "observation_receipt_sha256",
            "validity", "cleanup", "unknown_probe_failures", "metrics"}
PIN_KEYS = ("source_sha", "source_tree", "harness_sha", "artifact_sha256",
            "pdb_sha256", "profile_sha256", "fixture_sha256", "environment_sha256")
SOURCE_KEYS = ("source_sha", "source_tree", "harness_sha")
PROVENANCE_KEYS = set(SOURCE_KEYS) | {"product_input_sha256"}
DOCUMENT_KEYS = {"schema", *SOURCE_KEYS, "frozen_plan_sha256", "scopes",
                 "unavailable_scopes", "unavailable_metrics"}
V2_KEYS = DOCUMENT_KEYS | {"product_input_sha256", "provenance_amendment_sha256",
                           "scope_provenance"}
BRACKET_KEYS = {"qpc_frequency", "last_negative_begin_ticks",
                "last_negative_end_ticks", "first_positive_begin_ticks",
                "first_positive_end_ticks"}
CPU_METRICS = {"empty_idle_cpu_delta_ms", "populated_idle_cpu_delta_ms"}
READINESS_COUNTS = {
    "fresh_system_ready_ms": 1, "saved_system_ready_ms": 1,
    "saved_english_ready_ms": 1, "ordinary_100_ms": 1,
    "ordinary_1000_ms": 1, "ordinary_10000_ms": 4,
    "long_hidden_1000_ms": 1, "long_visible_1000_ms": 1,
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def exact(value, fields, label):
    require(type(value) is dict and set(value) == fields,
            f"{label} has missing or unexpected fields")
    return value


def digest(value, pattern, label):
    require(type(value) is str and pattern.fullmatch(value) is not None,
            f"{label} is not a lowercase digest")
    return value


def number(value, label):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0,
            f"{label} is not a finite nonnegative number")
    return value


def positive_int(value, label):
    require(type(value) is int and value > 0, f"{label} is not a positive integer")
    return value


def utc(value, label):
    require(type(value) is str and (value.endswith("Z") or value.endswith("+00:00")),
            f"{label} must be an explicit UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{label} is invalid") from error
    require(parsed.utcoffset() == timedelta(0), f"{label} is not UTC")
    return parsed


def brief(value, label):
    require(type(value) is str and 4 <= len(value) <= 240 and
            value.strip() == value and "\n" not in value and "\r" not in value and
            "\x00" not in value and
            re.search(r"(^|[\s(])(/|[A-Za-z]:\\|\\\\)", value) is None,
            f"{label} needs one specific line")
    return value


def bracket(value):
    exact(value, BRACKET_KEYS, "QPC bracket")
    positive_int(value["qpc_frequency"], "QPC frequency")
    first_begin = positive_int(value["first_positive_begin_ticks"], "positive query begin")
    first_end = positive_int(value["first_positive_end_ticks"], "positive query end")
    require(first_begin <= first_end, "positive query has reversed timestamps")
    last_begin, last_end = value["last_negative_begin_ticks"], value["last_negative_end_ticks"]
    require((last_begin is None) == (last_end is None), "negative query boundary is partial")
    if last_begin is not None:
        positive_int(last_begin, "negative query begin")
        positive_int(last_end, "negative query end")
        require(last_begin <= last_end <= first_begin,
                "negative and positive queries are reversed or overlap")


def cpu_window(value, reported_delta):
    exact(value, {"qpc_frequency", "before", "after"}, "CPU window")
    frequency = positive_int(value["qpc_frequency"], "CPU QPC frequency")
    for key in ("before", "after"):
        snapshot = exact(value[key], {"begin_ticks", "end_ticks", "cpu_total_ticks"},
                         "CPU snapshot")
        begin = positive_int(snapshot["begin_ticks"], "CPU snapshot begin")
        end = positive_int(snapshot["end_ticks"], "CPU snapshot end")
        require(type(snapshot["cpu_total_ticks"]) is int and
                snapshot["cpu_total_ticks"] >= 0 and begin <= end,
                "CPU snapshot has invalid ordering or total")
    before, after = value["before"], value["after"]
    require((after["begin_ticks"] - before["end_ticks"]) * 1000 / frequency >= 30000,
            "CPU window does not cover an actual 30-second idle interval")
    delta_ticks = after["cpu_total_ticks"] - before["cpu_total_ticks"]
    require(delta_ticks >= 0 and abs(reported_delta - delta_ticks / 10000) <= 0.00051,
            "CPU delta differs from the raw process totals")


def scope_summary(scope, source, unavailable, seen_processes, receipt_hashes,
                  include_provenance=False):
    exact(scope, SCOPE_KEYS, "scope")
    sid = scope["id"]
    require(sid in SCOPES, "unknown scope")
    for key in SCOPE_KEYS.intersection(PIN_KEYS):
        digest(scope[key], HEX64, key)
    require(type(scope["metrics"]) is list and type(scope["runs"]) is list,
            "scope metrics and runs must be lists")
    require(len(scope["runs"]) == 6, "scope needs six independent invocations")
    definitions = {}
    for metric in scope["metrics"]:
        exact(metric, {"id", "unit", "budget", "endpoint", "within_process_estimator",
                       "process_cell"}, "metric definition")
        mid = metric["id"]
        require(mid in SCOPES[sid] and mid not in definitions, "unknown or duplicated metric")
        unit, budget, cell = SCOPES[sid][mid]
        require(metric["unit"] == unit and metric["budget"] == budget and
                metric["process_cell"] == cell, "metric budget, unit, or process cell drifted")
        brief(metric["endpoint"], "metric endpoint")
        brief(metric["within_process_estimator"], "within-process estimator")
        definitions[mid] = metric
    require(set(definitions) | unavailable == set(SCOPES[sid]) and
            not (set(definitions) & unavailable),
            "scope metric inventory is incomplete or contradicts unavailable metrics")
    require(definitions, "an available scope needs at least one measured metric")
    run_rows = []
    for expected_index, run in enumerate(scope["runs"], 1):
        exact(run, RUN_KEYS, "run")
        require(type(run["index"]) is int and run["index"] == expected_index,
                "run index must cover 1..6 in order")
        for key in PIN_KEYS:
            expected = source[key] if key in source else scope[key]
            require(run[key] == expected, f"run {expected_index} {key} drifted")
        require(utc(run["started_at"], "run start") <= utc(run["ended_at"], "run end"),
                "run ended before it started")
        for key in ("validation_receipt_sha256", "observation_receipt_sha256"):
            digest(run[key], HEX64, key)
            require(run[key] not in receipt_hashes[key],
                    f"{key} was reused for a different invocation")
            receipt_hashes[key].add(run[key])
        require(run["validity"] == "accepted" and run["cleanup"] == "owned-clean" and
                type(run["unknown_probe_failures"]) is int and
                run["unknown_probe_failures"] == 0,
                "run evidence quality or owned cleanup is incomplete")
        require(type(run["processes"]) is dict and type(run["metrics"]) is dict and
                set(run["metrics"]) == set(definitions), "run metric inventory differs")
        require(set(run["processes"]) ==
                {m["process_cell"] for m in definitions.values()},
                "run process-cell inventory differs")
        for cell, identity in run["processes"].items():
            exact(identity, {"pid", "creation_utc_ticks"}, "process identity")
            pair = (positive_int(identity["pid"], "PID"),
                    positive_int(identity["creation_utc_ticks"], "process creation ticks"))
            require(pair not in seen_processes, "process identity was reused")
            seen_processes.add(pair)
        for mid, sample in run["metrics"].items():
            fields = {"value", "process_cell", "brackets"}
            if mid in CPU_METRICS:
                fields.add("cpu_window")
            exact(sample, fields, "metric sample")
            require(sample["process_cell"] == definitions[mid]["process_cell"],
                    "metric points at the wrong process")
            number(sample["value"], "metric value")
            require(type(sample["brackets"]) is list and len(sample["brackets"]) <= 4,
                    "metric has an invalid bracket set")
            require(len(sample["brackets"]) >= READINESS_COUNTS.get(mid, 0),
                    "readiness metric lacks its observed query brackets")
            for item in sample["brackets"]:
                bracket(item)
            if mid in CPU_METRICS:
                cpu_window(sample["cpu_window"], sample["value"])
        run_rows.append(run)
    results = []
    for mid, metric in definitions.items():
        values = [row["metrics"][mid]["value"] for row in run_rows]
        center = median(values)
        low, high = min(values), max(values)
        spread = (high - low) / center if center else (0 if low == high else None)
        results.append({**metric, "values": values, "median": center, "minimum": low,
                        "maximum": high, "spread_range_over_median": spread,
                        "spread_status": "defined" if spread is not None else "undefined-zero-median",
                        "bracket_counts": [len(row["metrics"][mid]["brackets"]) for row in run_rows],
                        "disposition": "accepted" if center <= metric["budget"] else "exceeded"})
    result = {"id": sid, "artifact_sha256": scope["artifact_sha256"],
              "pdb_sha256": scope["pdb_sha256"], "metrics": results,
              "runs": run_rows}
    if include_provenance:
        result["scope_provenance"] = source.copy()
    return result


def v2_provenance(document, plan_hash, amendment, amendment_hash, available_ids):
    require(amendment is not None and amendment_hash is not None,
            "v2 records require a provenance amendment and its exact digest")
    digest(amendment_hash, HEX64, "provenance amendment digest")
    digest(document["product_input_sha256"], HEX64, "product_input_sha256")
    digest(document["provenance_amendment_sha256"], HEX64,
           "provenance_amendment_sha256")
    require(document["provenance_amendment_sha256"] == amendment_hash,
            "provenance amendment digest differs from records")
    exact(amendment, {"schema", "original_frozen_plan_sha256", "product_input_sha256",
                      "scope_provenance", "declared_at", "reason"},
          "provenance amendment")
    require(amendment["schema"] == "darkrenamer-baseline-provenance-amendment-v1",
            "unsupported provenance amendment schema")
    require(amendment["original_frozen_plan_sha256"] == plan_hash,
            "provenance amendment differs from the frozen plan")
    require(amendment["product_input_sha256"] == document["product_input_sha256"],
            "provenance amendment product input differs")
    declared_at = utc(amendment["declared_at"], "provenance amendment declaration")
    brief(amendment["reason"], "provenance amendment reason")
    exact(amendment["scope_provenance"], set(SCOPES), "amendment scope provenance")
    exact(document["scope_provenance"], available_ids, "record scope provenance")
    for sid, provenance in amendment["scope_provenance"].items():
        exact(provenance, PROVENANCE_KEYS, f"{sid} source provenance")
        for key in SOURCE_KEYS:
            digest(provenance[key], HEX40, f"{sid} {key}")
        digest(provenance["product_input_sha256"], HEX64,
               f"{sid} product_input_sha256")
        require(provenance["product_input_sha256"] == document["product_input_sha256"],
                f"{sid} product input differs from the common fingerprint")
        if sid in available_ids:
            require(document["scope_provenance"][sid] == provenance,
                    f"{sid} scope provenance differs from amendment")
    for sid in ("runtime-model", "refresh-stages"):
        require(all(amendment["scope_provenance"][sid][key] == document[key]
                    for key in SOURCE_KEYS),
                f"{sid} native reference source differs from the frozen baseline")
    for scope in document["scopes"]:
        if scope["id"] in ("runtime-baseline", "performance-sample"):
            for run in scope["runs"]:
                require(declared_at <= utc(run["started_at"], "GUI run start"),
                        "provenance amendment was declared after a GUI run")


def summarize(document, plan_hash, amendment=None, amendment_hash=None):
    require(type(document) is dict and document.get("schema") in
            ("darkrenamer-baseline-records-v1", "darkrenamer-baseline-records-v2"),
            "unsupported baseline record schema")
    v2 = document["schema"] == "darkrenamer-baseline-records-v2"
    exact(document, V2_KEYS if v2 else DOCUMENT_KEYS, "baseline document")
    require(v2 or (amendment is None and amendment_hash is None),
            "v1 records forbid a provenance amendment")
    for key in SOURCE_KEYS:
        digest(document[key], HEX40, key)
    require(document["frozen_plan_sha256"] == plan_hash,
            "records are not bound to the selected frozen plan")
    require(type(document["scopes"]) is list and type(document["unavailable_scopes"]) is list and
            type(document["unavailable_metrics"]) is list, "scope inventories must be lists")
    for row in document["scopes"]:
        exact(row, SCOPE_KEYS, "scope")
        require(type(row["id"]) is str and row["id"] in SCOPES,
                "unknown scope")
    scope_ids = [row["id"] for row in document["scopes"]]
    unavailable_scopes = {}
    for row in document["unavailable_scopes"]:
        exact(row, {"id", "reason"}, "unavailable scope")
        require(row["id"] in SCOPES and row["id"] not in unavailable_scopes,
                "unknown or duplicated unavailable scope")
        unavailable_scopes[row["id"]] = brief(row["reason"], "unavailable scope reason")
    require(len(scope_ids) == len(document["scopes"]) and len(set(scope_ids)) == len(scope_ids) and
            set(scope_ids) | set(unavailable_scopes) == set(SCOPES) and
            not (set(scope_ids) & set(unavailable_scopes)),
            "all four scopes need one available or unavailable disposition")
    if v2:
        v2_provenance(document, plan_hash, amendment, amendment_hash, set(scope_ids))
    missing_metrics = {}
    for row in document["unavailable_metrics"]:
        exact(row, {"scope", "id", "reason"}, "unavailable metric")
        key = (row["scope"], row["id"])
        require(row["scope"] in scope_ids and row["id"] in SCOPES[row["scope"]] and
                key not in missing_metrics, "unknown or duplicated unavailable metric")
        missing_metrics[key] = brief(row["reason"], "unavailable metric reason")
    seen_processes = set()
    receipt_hashes = {"validation_receipt_sha256": set(),
                      "observation_receipt_sha256": set()}
    results = [scope_summary(scope, document["scope_provenance"][scope["id"]]
                             if v2 else document,
                             {mid for sid, mid in missing_metrics if sid == scope["id"]},
                             seen_processes, receipt_hashes, v2)
               for scope in document["scopes"]]
    product = {row["id"]: row for row in document["scopes"]}
    if "runtime-baseline" in product and "performance-sample" in product:
        if v2:
            require(all(document["scope_provenance"]["runtime-baseline"][key] ==
                        document["scope_provenance"]["performance-sample"][key]
                        for key in SOURCE_KEYS),
                    "the two product GUI scopes used different source provenance")
        for key in ("artifact_sha256", "pdb_sha256"):
            require(product["runtime-baseline"][key] == product["performance-sample"][key],
                    "the two product GUI scopes used different executable pairs")
    exceeded = any(metric["disposition"] == "exceeded"
                   for scope in results for metric in scope["metrics"])
    incomplete = bool(unavailable_scopes or missing_metrics)
    result = {"schema": "darkrenamer-baseline-summary-v2" if v2 else
             "darkrenamer-baseline-summary-v1",
            "source_sha": document["source_sha"], "source_tree": document["source_tree"],
            "harness_sha": document["harness_sha"],
            "frozen_plan_sha256": plan_hash,
            "status": "incomplete" if incomplete else
                      "complete-with-exceeded-budgets" if exceeded else "complete",
            "scope_results": results,
            "unavailable_scopes": document["unavailable_scopes"],
            "unavailable_metrics": document["unavailable_metrics"],
            "pending_separate_scope": ["#220 list attribution or candidate decision",
                                       "#221 real GUI Apply, feedback and idle close"],
            "evidence_boundary": "Arithmetic and declared pins only; original VM receipts require their canonical independent verifiers. No p95, equivalence, or release claim."}
    if v2:
        result["product_input_sha256"] = document["product_input_sha256"]
        result["provenance_amendment_sha256"] = amendment_hash
        result["scope_provenance"] = document["scope_provenance"]
    return result


def no_duplicates(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "JSON has a duplicate key")
        value[key] = item
    return value


def read_regular(path, label):
    flags = (os.O_RDONLY | getattr(os, "O_BINARY", 0) |
             getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_INPUT_BYTES,
                f"{label} is not a bounded ordinary file")
        data = os.read(descriptor, MAX_INPUT_BYTES + 1)
        require(len(data) == info.st_size, f"{label} changed while read")
        return data
    finally:
        os.close(descriptor)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, type=Path,
                        help="sanitized records already checked against raw evidence")
    parser.add_argument("--plan", required=True, type=Path,
                        help="frozen prospective issue #219 plan")
    parser.add_argument("--provenance-amendment", type=Path,
                        help="required exact amendment file for v2 records; forbidden for v1")
    parser.add_argument("--output", required=True, type=Path,
                        help="new summary file; never overwrites")
    args = parser.parse_args(argv)
    plan_bytes = read_regular(args.plan, "prospective plan")
    plan = json.loads(plan_bytes, object_pairs_hook=no_duplicates,
                      parse_constant=lambda _: require(False, "nonfinite JSON constant"))
    require(type(plan) is dict and plan.get("schema") == "darkrenamer-baseline-prospective-plan-v1"
            and plan.get("issue") == 219, "selected prospective plan differs")
    plan_hash = hashlib.sha256(plan_bytes).hexdigest()
    records = json.loads(read_regular(args.input, "sanitized input"),
                         object_pairs_hook=no_duplicates,
                         parse_constant=lambda _: require(False, "nonfinite JSON constant"))
    amendment_bytes = (read_regular(args.provenance_amendment, "provenance amendment")
                       if args.provenance_amendment is not None else None)
    amendment = (json.loads(amendment_bytes, object_pairs_hook=no_duplicates,
                            parse_constant=lambda _: require(False, "nonfinite JSON constant"))
                 if amendment_bytes is not None else None)
    result = summarize(records, plan_hash, amendment,
                       hashlib.sha256(amendment_bytes).hexdigest()
                       if amendment_bytes is not None else None)
    payload = (json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode()
    require(len(payload) <= MAX_INPUT_BYTES, "summary exceeds the bounded output size")
    flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0) |
             getattr(os, "O_NOFOLLOW", 0))
    descriptor = os.open(args.output, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        # Preserve a partial write for diagnosis; the caller must use a new path.
        raise
    print(json.dumps({"status": result["status"], "output": str(args.output),
                      "plan_sha256": plan_hash}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
