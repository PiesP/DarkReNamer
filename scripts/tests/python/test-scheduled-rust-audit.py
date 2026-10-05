#!/usr/bin/env python3
"""Synthetic scheduled Rust audit behavior and workflow policy checks."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tooling_test_paths import REPOSITORY_ROOT


SCAN = REPOSITORY_ROOT / "scripts" / "run-scheduled-rust-audit.py"
SPEC = importlib.util.spec_from_file_location("scheduled_rust_audit", SCAN)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)

# cargo-deny 0.20.2 producers: src/cargo-deny/main.rs (log),
# src/diag/grapher.rs (diagnostic), and src/cargo-deny/stats.rs (summary).
LOGGER = {"type": "log", "fields": {
    "timestamp": "2026-10-05T00:00:00Z", "level": "WARN", "message": "ordinary warning",
}}
NONERROR = {"type": "diagnostic", "fields": {"severity": "warning", "message": "ordinary diagnostic"}}
SUMMARY = {"type": "summary", "fields": {
    check: {"errors": 0, "warnings": 1, "notes": 0, "helps": 0}
    for check in ("advisories", "bans", "licenses", "sources")
}}
MALFORMED = (
    "not-json",
    '{"type":"diagnostic",',
    "[]", "null", '"text"', "0", "true", "{}", "NaN", "Infinity",
    '{"type":"unknown","fields":{}}',
    '{"type":"diagnostic","fields":[]}',
    '{"type":"diagnostic","fields":{}}',
    '{"type":"diagnostic","fields":{"severity":null,"message":"bad"}}',
    '{"type":"diagnostic","fields":{"severity":[],"message":"bad"}}',
    '{"type":"diagnostic","fields":{"severity":"ERROR","message":"bad"}}',
    '{"type":"diagnostic","fields":{"severity":"warning","message":1}}',
    '{"type":"diagnostic","fields":{"severity":"warning"}}',
    '{"type":"diagnostic","fields":{"severity":"error","message":"bad","code":[]}}',
    '{"type":"log","fields":[]}',
    '{"type":"log","fields":{}}',
    '{"type":"log","fields":{"level":"invalid","timestamp":"now","message":"bad"}}',
    '{"type":"log","fields":{"level":"INFO","timestamp":null,"message":"bad"}}',
    '{"type":"summary","fields":[]}',
    '{"type":"summary","fields":{"unknown":{}}}',
    '{"type":"summary","fields":{"bans":{}}}',
    '{"type":"summary","fields":{"bans":{"errors":true,"warnings":0,"notes":0,"helps":0}}}',
    '{"type":"summary","fields":{"bans":{"errors":-1,"warnings":0,"notes":0,"helps":0}}}',
    '{"type":"summary","fields":{"bans":{"errors":4294967296,"warnings":0,"notes":0,"helps":0}}}',
)

MOCK_SCANNER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
arguments = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a", encoding="utf-8") as calls:
    calls.write(json.dumps({"name": name, "arguments": arguments}) + "\n")
if arguments == ["--version"]:
    expected = "cargo-audit 0.22.2" if name == "cargo-audit" else "cargo-deny 0.20.2"
    print("wrong version" if os.environ.get("MOCK_VERSION") == name else expected)
elif name == "cargo-audit":
    mode = os.environ.get("MOCK_AUDIT", "clean")
    if mode == "unavailable":
        print("advisory network unavailable", file=sys.stderr)
        sys.exit(1)
    if mode == "malformed":
        print("{}")
    else:
        count = 1 if mode == "finding" else 0
        entries = [{}] if mode in ("finding", "inconsistent") else []
        warnings = {"unmaintained": [{}]} if mode == "warning" else {}
        print(json.dumps({"vulnerabilities": {"found": bool(count), "count": count, "list": entries}, "warnings": warnings}))
        if count or warnings:
            sys.exit(1)
elif arguments == ["fetch", "db"]:
    if os.environ.get("MOCK_DENY_FETCH") == "unavailable":
        print("database refresh failed", file=sys.stderr)
        sys.exit(1)
elif arguments == ["--format", "json", "--locked", "check"]:
    if "MOCK_DENY_STDOUT" in os.environ or "MOCK_DENY_STDERR" in os.environ:
        sys.stdout.write(os.environ.get("MOCK_DENY_STDOUT", ""))
        sys.stderr.write(os.environ.get("MOCK_DENY_STDERR", ""))
        sys.exit(int(os.environ.get("MOCK_DENY_EXIT", "0")))
    mode = os.environ.get("MOCK_DENY", "clean")
    if mode in ("policy", "hidden-policy"):
        print(json.dumps({"type": "diagnostic", "fields": {"severity": "error", "message": "policy violation"}}))
        if mode == "policy":
            sys.exit(1)
    if mode == "unavailable":
        print("scanner failure", file=sys.stderr)
        sys.exit(1)
    if mode == "index-failure":
        print(json.dumps({"type": "diagnostic", "fields": {"severity": "error", "code": "index-failure", "message": "registry unavailable"}}))
        sys.exit(1)
else:
    raise SystemExit("unexpected scanner command")
'''


class DenyResultTests(unittest.TestCase):
    def result(self, stdout: str = "", stderr: str = "", returncode: int = 0) -> str:
        return AUDIT.deny_result(subprocess.CompletedProcess([], returncode, stdout, stderr))

    def test_supported_records_and_empty_output_are_clean(self) -> None:
        records = [LOGGER, SUMMARY, {"type": "summary", "fields": {}}]
        records.append({"type": "diagnostic", "fields": {
            **NONERROR["fields"], "code": "license-not-encountered", "graphs": [],
            "labels": [{"message": "label", "span": "MIT", "line": 1, "column": 1}],
            "notes": ["ordinary note"],
        }})
        records.extend({"type": "diagnostic", "fields": {"severity": severity, "message": "message"}}
                       for severity in ("warning", "note", "help"))
        records.extend({"type": "log", "fields": {**LOGGER["fields"], "level": level}}
                       for level in ("WARN", "INFO", "DEBUG", "TRACE"))
        for output in ("", "\n \t\n", *(json.dumps(record) for record in records),
                       "\n".join(json.dumps(record) for record in records)):
            for stream in ("stdout", "stderr"):
                with self.subTest(output=output, stream=stream):
                    self.assertEqual(self.result(**{stream: output}), "clean")

    def test_invalid_records_are_failures_in_either_stream_and_mixtures(self) -> None:
        valid = json.dumps(LOGGER) + "\n" + json.dumps(NONERROR)
        for output in MALFORMED:
            for stream in ("stdout", "stderr"):
                for mixed in (False, True):
                    with self.subTest(output=output, stream=stream, mixed=mixed):
                        result = self.result(**{stream: f"{valid}\n{output}\n{valid}" if mixed else output})
                        self.assertIn("tool or output-validation failure", result)
                        self.assertIn("malformed cargo-deny output", result)
                        self.assertIn(stream + " line ", result)
                        self.assertLess(len(result), 240)

    def test_malformed_output_takes_precedence_over_diagnostics(self) -> None:
        for code in ("policy", "index-failure"):
            diagnostic = json.dumps({"type": "diagnostic", "fields": {
                "severity": "error", "message": "failure", "code": code,
            }})
            for stdout, stderr in ((diagnostic, "not-json"), ("not-json", diagnostic)):
                with self.subTest(code=code, stdout=stdout):
                    self.assertIn("output-validation failure", self.result(stdout, stderr))

    def test_policy_index_and_nonzero_failures_are_preserved(self) -> None:
        for code in ("policy", "index-failure", "a:index-cache-load-failure"):
            for returncode in (0, 1):
                with self.subTest(code=code, returncode=returncode):
                    output = json.dumps({"type": "diagnostic", "fields": {
                        "severity": "error", "message": "failure", "code": code,
                    }})
                    expected = "index errors" if "index-" in code else "policy violations"
                    self.assertIn(expected, self.result(stderr=output, returncode=returncode))
        for output in ("", json.dumps(LOGGER), json.dumps(NONERROR)):
            self.assertIn("cargo-deny exited without policy diagnostics", self.result(output, returncode=1))

    def test_bug_logs_and_summary_errors_cannot_report_clean(self) -> None:
        records = (
            {"type": "diagnostic", "fields": {"severity": "bug", "message": "internal failure"}},
            {"type": "log", "fields": {**LOGGER["fields"], "level": "ERROR"}},
            {"type": "summary", "fields": {"bans": {"errors": 1, "warnings": 0, "notes": 0, "helps": 0}}},
        )
        for record in records:
            for stream in ("stdout", "stderr"):
                with self.subTest(record=record, stream=stream):
                    result = self.result(**{stream: json.dumps(record)})
                    self.assertIn("tool or advisory-data failure", result)
                    self.assertNotIn("policy violations", result)


class ScheduledRustAuditTests(unittest.TestCase):
    def run_fixture(self, **modes: str) -> tuple[subprocess.CompletedProcess[str], str, list[dict]]:
        with tempfile.TemporaryDirectory(prefix="darkrenamer-scheduled-audit-test-") as directory:
            root = Path(directory)
            bin_dir = root / "tools" / "bin"
            bin_dir.mkdir(parents=True)
            missing = modes.pop("MOCK_MISSING", None)
            for name in ("cargo-audit", "cargo-deny"):
                if name == missing:
                    continue
                path = bin_dir / name
                path.write_text(MOCK_SCANNER, encoding="utf-8")
                path.chmod(0o755)
            summary = root / "summary.md"
            calls = root / "calls.jsonl"
            environment = os.environ.copy()
            environment.update({
                "SECURITY_TOOLS_ROOT": str(root / "tools"),
                "RUNNER_TEMP": str(root),
                "GITHUB_STEP_SUMMARY": str(summary),
                "GITHUB_SHA": "a" * 40,
                "MOCK_CALLS": str(calls),
                **modes,
            })
            result = subprocess.run(
                [sys.executable, str(SCAN)],
                cwd=REPOSITORY_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            return result, summary.read_text(encoding="utf-8"), [
                json.loads(line) for line in calls.read_text(encoding="utf-8").splitlines()
            ]

    def test_clean_scan_uses_fresh_database_and_refreshes_deny(self) -> None:
        first, first_summary, first_calls = self.run_fixture()
        second, second_summary, second_calls = self.run_fixture()
        for result, summary, calls in ((first, first_summary, first_calls), (second, second_summary, second_calls)):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("- cargo-audit: clean", summary)
            self.assertIn("- cargo-deny: clean", summary)
            self.assertIn("Result: clean", summary)
            self.assertEqual([call["arguments"] for call in calls if call["name"] == "cargo-deny"], [
                ["--version"], ["fetch", "db"], ["--format", "json", "--locked", "check"],
            ])
        audit_arguments = [
            next(call["arguments"] for call in calls if call["name"] == "cargo-audit" and "audit" in call["arguments"])
            for calls in (first_calls, second_calls)
        ]
        for arguments in audit_arguments:
            self.assertEqual(arguments[:2], ["audit", "--db"])
            self.assertEqual(arguments[3:], ["--deny", "warnings", "--file", "Cargo.lock", "--format", "json"])
        self.assertNotEqual(audit_arguments[0][2], audit_arguments[1][2])

    def test_wrong_cached_tool_version_stops_before_scanning(self) -> None:
        for mode in ("MOCK_VERSION", "MOCK_MISSING"):
            with self.subTest(mode=mode):
                result, summary, calls = self.run_fixture(**{mode: "cargo-deny"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("tool failure (cargo-deny version mismatch", summary)
                self.assertNotIn("Result: clean", summary)
                expected = [["--version"], ["--version"]] if mode == "MOCK_VERSION" else [["--version"]]
                self.assertEqual([call["arguments"] for call in calls], expected)

    def test_findings_and_unavailable_data_never_report_clean(self) -> None:
        for mode, environment, expected in (
            ("advisory", {"MOCK_AUDIT": "finding"}, "cargo-audit: findings"),
            ("warning", {"MOCK_AUDIT": "warning"}, "cargo-audit: findings"),
            ("malformed", {"MOCK_AUDIT": "malformed"}, "malformed cargo-audit report"),
            ("inconsistent", {"MOCK_AUDIT": "inconsistent"}, "malformed cargo-audit report"),
            ("audit network", {"MOCK_AUDIT": "unavailable"}, "advisory-data failure"),
            ("refresh network", {"MOCK_DENY_FETCH": "unavailable"}, "database refresh failed"),
            ("deny policy", {"MOCK_DENY": "policy"}, "cargo-deny: policy violations"),
            ("hidden policy", {"MOCK_DENY": "hidden-policy"}, "cargo-deny: policy violations"),
            ("deny failure", {"MOCK_DENY": "unavailable"}, "tool or output-validation failure"),
            ("deny index", {"MOCK_DENY": "index-failure"}, "cargo-deny index errors"),
        ):
            with self.subTest(mode=mode):
                result, summary, calls = self.run_fixture(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, summary)
                self.assertIn("Result: failed or incomplete", summary)
                if mode == "refresh network":
                    self.assertNotIn(["--format", "json", "--locked", "check"], [
                        call["arguments"] for call in calls
                    ])

    def test_malformed_deny_output_never_reports_clean(self) -> None:
        valid = json.dumps(LOGGER) + "\n" + json.dumps(NONERROR) + "\n" + json.dumps(SUMMARY)
        for output in ("not-json", '{"type":"diagnostic","fields":[]}',
                       '{"type":"diagnostic","fields":{"message":"missing severity"}}', "[]"):
            for stream in ("STDOUT", "STDERR"):
                for mixed in (False, True):
                    with self.subTest(output=output, stream=stream, mixed=mixed):
                        other = "STDERR" if stream == "STDOUT" else "STDOUT"
                        result, summary, _ = self.run_fixture(**{
                            "MOCK_DENY_" + stream: f"{valid}\n{output}\n{valid}" if mixed else output,
                            "MOCK_DENY_" + other: valid if mixed else "",
                        })
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("cargo-deny: tool or output-validation failure", summary)
                        self.assertIn("malformed cargo-deny output", summary)
                        self.assertIn("Result: failed or incomplete", summary)
                        self.assertNotIn("Result: clean", summary)
                        self.assertNotIn(output, summary)

    def test_supported_deny_output_reports_clean(self) -> None:
        for output in ("", "\n \t\n", json.dumps(LOGGER), json.dumps(NONERROR), json.dumps(SUMMARY)):
            with self.subTest(output=output):
                result, summary, _ = self.run_fixture(MOCK_DENY_STDOUT=output, MOCK_DENY_STDERR=output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("cargo-deny: clean", summary)
                self.assertIn("Result: clean", summary)

    def test_nonzero_well_formed_deny_output_remains_failure(self) -> None:
        result, summary, _ = self.run_fixture(MOCK_DENY_STDERR=json.dumps(LOGGER), MOCK_DENY_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cargo-deny exited without policy diagnostics", summary)
        self.assertNotIn("Result: clean", summary)

    def test_bug_and_summary_errors_are_tool_failures(self) -> None:
        for record in (
            {"type": "diagnostic", "fields": {"severity": "bug", "message": "internal failure"}},
            {"type": "summary", "fields": {"licenses": {"errors": 2, "warnings": 0, "notes": 0, "helps": 0}}},
        ):
            with self.subTest(record=record):
                result, summary, _ = self.run_fixture(MOCK_DENY_STDERR=json.dumps(record))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cargo-deny: tool or advisory-data failure", summary)
                self.assertNotIn("Result: clean", summary)

    def test_workflow_limits_events_and_caches_only_pinned_tools(self) -> None:
        workflow = (REPOSITORY_ROOT / ".github/workflows/security.yaml").read_text(encoding="utf-8")
        job = workflow.split("  rust-dependency-audit:\n", 1)[1].split("  codeql:\n", 1)[0]
        ci = (REPOSITORY_ROOT / ".github/workflows/ci.yaml").read_text(encoding="utf-8")
        release = (REPOSITORY_ROOT / ".github/workflows/release.yaml").read_text(encoding="utf-8")
        self.assertIn('    - cron: "23 2 * * 1"', workflow)
        self.assertIn("  workflow_dispatch:\n", workflow)
        self.assertIn("github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'", job)
        self.assertIn("    timeout-minutes: 30", job)
        self.assertIn("    permissions:\n      contents: read\n", job)
        self.assertIn("persist-credentials: false", job)
        self.assertIn("path: ${{ runner.temp }}/darkrenamer-security-tools", job)
        self.assertIn("darkrenamer-security-tools-${{ runner.os }}-${{ runner.arch }}-rust-${{ hashFiles('rust-toolchain.toml') }}-audit-0.22.2-deny-0.20.2", job)
        self.assertIn("darkrenamer-security-tools-${{ runner.os }}-${{ runner.arch }}-rust-${{ hashFiles('rust-toolchain.toml') }}-audit-0.22.2-deny-0.20.2", ci)
        self.assertNotIn("restore-keys:", job)
        self.assertIn("if: steps.security-tools-cache.outputs.cache-hit != 'true'", job)
        self.assertIn('cargo install --locked --root "$SECURITY_TOOLS_ROOT" cargo-audit --version 0.22.2', job)
        self.assertIn('cargo install --locked --root "$SECURITY_TOOLS_ROOT" cargo-deny --version 0.20.2', job)
        scan_step = job.split("      - name: Refresh and audit Rust dependencies\n", 1)[1].split(
            "\n      - name:", 1
        )[0]
        self.assertIn("run: python3 scripts/run-scheduled-rust-audit.py", scan_step)
        self.assertNotIn("        if:", scan_step)
        self.assertEqual(job.count("uses: actions/cache@"), 1)
        self.assertIn("if: failure() && steps.audit.outcome == 'skipped'", job)
        self.assertNotIn("deep-success", job)
        self.assertIn("name: pr-gate/security", ci)
        self.assertIn('"$SECURITY_TOOLS_ROOT/bin/cargo-audit" audit --deny warnings', ci)
        self.assertIn('"$SECURITY_TOOLS_ROOT/bin/cargo-deny" check', ci)
        self.assertIn("cargo audit --deny warnings", release)
        self.assertIn("cargo deny check", release)
        self.assertIn("language: [rust, python, actions]", workflow)


if __name__ == "__main__":
    unittest.main()
