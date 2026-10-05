#!/usr/bin/env python3
"""Run fresh Rust dependency checks and summarize their actual outcomes."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def command(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(arguments, capture_output=True, text=True, check=False)
    except OSError as error:
        return subprocess.CompletedProcess(arguments, 127, "", str(error))


def audit_result(process: subprocess.CompletedProcess[str]) -> str:
    try:
        report = json.loads(process.stdout)
        vulnerabilities = report["vulnerabilities"]
        count = vulnerabilities["count"]
        vulnerability_list = vulnerabilities["list"]
        found = vulnerabilities.get("found")
        warnings = report["warnings"]
        if (
            not isinstance(count, int)
            or isinstance(count, bool)
            or count < 0
            or not isinstance(vulnerability_list, list)
            or count != len(vulnerability_list)
            or (found is not None and (not isinstance(found, bool) or found != (count > 0)))
            or not isinstance(warnings, dict)
            or any(not isinstance(entries, list) for entries in warnings.values())
        ):
            raise ValueError("invalid audit report fields")
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return "tool or advisory-data failure (missing or malformed cargo-audit report)"

    warning_count = sum(len(entries) for entries in warnings.values())
    if count or warning_count:
        return f"findings ({count} vulnerabilities, {warning_count} warnings)"
    if process.returncode:
        return "tool or advisory-data failure (cargo-audit exited without findings)"
    return "clean"


def deny_record_error(item: object) -> str | None:
    """Validate verdict fields emitted by the pinned cargo-deny 0.20.2."""
    # Producers: src/diag/grapher.rs, src/cargo-deny/main.rs and stats.rs.
    if not isinstance(item, dict):
        return "record is not an object"
    record_type = item.get("type")
    if record_type not in ("diagnostic", "log", "summary"):
        return "unsupported record type"
    fields = item.get("fields")
    if not isinstance(fields, dict):
        return "record fields are not an object"
    if record_type == "diagnostic":
        if fields.get("severity") not in ("error", "warning", "note", "help", "bug"):
            return "missing or invalid diagnostic severity"
        if not isinstance(fields.get("message"), str):
            return "missing or invalid diagnostic message"
        if "code" in fields and not isinstance(fields["code"], str):
            return "invalid diagnostic code"
    elif record_type == "log":
        if fields.get("level") not in ("ERROR", "WARN", "INFO", "DEBUG", "TRACE"):
            return "missing or invalid log level"
        if not isinstance(fields.get("timestamp"), str) or not isinstance(fields.get("message"), str):
            return "missing or invalid log timestamp or message"
    else:
        for check, counts in fields.items():
            if check not in ("advisories", "bans", "licenses", "sources") or not isinstance(counts, dict):
                return "invalid summary check"
            for name in ("errors", "warnings", "notes", "helps"):
                count = counts.get(name)
                if not isinstance(count, int) or isinstance(count, bool) or not 0 <= count <= 0xFFFFFFFF:
                    return "missing or invalid summary count"
    return None


def deny_result(process: subprocess.CompletedProcess[str]) -> str:
    errors = 0
    data_errors = 0
    tool_errors = 0
    summary_errors = 0

    def reject_constant(value: str) -> None:
        raise ValueError("non-JSON numeric constant")

    for stream, output in (("stdout", process.stdout), ("stderr", process.stderr)):
        for number, line in enumerate(output.splitlines(), 1):
            if not line.strip():
                continue
            try:
                item = json.loads(line, parse_constant=reject_constant)
                reason = deny_record_error(item)
            except ValueError:
                reason = "invalid JSON"
            if reason:
                return f"tool or output-validation failure (malformed cargo-deny output: {stream} line {number}: {reason})"
            fields = item["fields"]
            if item["type"] == "diagnostic":
                if fields["severity"] == "bug":
                    tool_errors += 1
                elif fields["severity"] == "error":
                    code = fields.get("code", "")
                    if code.rsplit(":", 1)[-1] in ("index-failure", "index-cache-load-failure"):
                        data_errors += 1
                    else:
                        errors += 1
            elif item["type"] == "log":
                tool_errors += fields["level"] == "ERROR"
            else:
                summary_errors += sum(counts["errors"] for counts in fields.values())
    if data_errors:
        return f"tool or advisory-data failure ({data_errors} cargo-deny index errors)"
    if tool_errors:
        return f"tool or advisory-data failure ({tool_errors} cargo-deny error logs or bug diagnostics)"
    if errors:
        return f"policy violations ({errors} error diagnostics)"
    if summary_errors:
        return "tool or advisory-data failure (cargo-deny summary errors without error diagnostics)"
    if process.returncode == 0:
        return "clean"
    return "tool or advisory-data failure (cargo-deny exited without policy diagnostics)"


def main() -> int:
    summary_path = Path(os.environ["GITHUB_STEP_SUMMARY"])
    source_sha = os.environ["GITHUB_SHA"]
    tools_root = Path(os.environ["SECURITY_TOOLS_ROOT"])
    runner_temp = Path(os.environ["RUNNER_TEMP"])
    results: list[tuple[str, str]] = []

    def finish() -> int:
        clean = len(results) == 2 and all(result == "clean" for _, result in results)
        lines = ["## Rust dependency audit", "", f"Source: `{source_sha}`", ""]
        for name, result in results:
            lines.append(f"- {name}: {result}")
        lines.extend(["", f"Result: {'clean' if clean else 'failed or incomplete'}", ""])
        with summary_path.open("a", encoding="utf-8") as summary:
            summary.write("\n".join(lines))
        return 0 if clean else 1

    if len(source_sha) != 40 or any(character not in "0123456789abcdef" for character in source_sha):
        results.append(("Setup", "tool or source failure (invalid full source SHA)"))
        return finish()
    for binary, expected in (("cargo-audit", "cargo-audit 0.22.2"), ("cargo-deny", "cargo-deny 0.20.2")):
        path = tools_root / "bin" / binary
        version = command([str(path), "--version"])
        if version.returncode or version.stdout.strip() != expected:
            results.append(("Setup", f"tool failure ({binary} version mismatch or validation error)"))
            return finish()

    with tempfile.TemporaryDirectory(prefix="darkrenamer-rust-audit-", dir=runner_temp) as temporary:
        audit_db = str(Path(temporary) / "advisory-db")
        audit = command([
            str(tools_root / "bin" / "cargo-audit"),
            "audit", "--db", audit_db, "--deny", "warnings", "--file", "Cargo.lock", "--format", "json",
        ])
        results.append(("cargo-audit", audit_result(audit)))
        if audit.stderr:
            print(audit.stderr, file=sys.stderr, end="")

        deny = str(tools_root / "bin" / "cargo-deny")
        refresh = command([deny, "fetch", "db"])
        if refresh.returncode:
            results.append(("cargo-deny", "advisory-data failure (database refresh failed)"))
            if refresh.stderr:
                print(refresh.stderr, file=sys.stderr, end="")
        else:
            check = command([deny, "--format", "json", "--locked", "check"])
            results.append(("cargo-deny", deny_result(check)))
            if check.returncode:
                print(check.stdout, file=sys.stdout, end="")
                print(check.stderr, file=sys.stderr, end="")

    return finish()


if __name__ == "__main__":
    raise SystemExit(main())
