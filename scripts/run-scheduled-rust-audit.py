#!/usr/bin/env python3
"""Run fresh Rust dependency checks and summarize their actual outcomes."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


DENY_CHECKS = ("advisories", "bans", "licenses", "sources")
SCANNER_RECORD = Path(__file__).resolve().parent.parent / "config" / "release-tool-integrity.json"
SCANNER_IDS = ("cargo-audit", "cargo-deny")
# Parser semantics and negative fixtures are reviewed for these tool versions.
# This is a compatibility gate, not an independent installation selection.
SCANNER_REPORT_COMPATIBILITY = {"cargo-audit": "0.22.2", "cargo-deny": "0.20.2"}
# cargo-audit 0.22.2 auditor.rs logs these failures outside its JSON report.
AUDIT_INDEX_FAILURES = (
    "warning: couldn't update crates.io index:",
    "warning: couldn't open crates.io index:",
    "error: couldn't check if the package is yanked:",
)


def scanner_pins(record_path: Path = SCANNER_RECORD) -> dict[str, str]:
    """Read reviewed scanner selections as data, without executable workflow text."""

    def unique_object(pairs: list[tuple[str, object]]) -> dict:
        result = {}
        folded = set()
        for key, value in pairs:
            if key.casefold() in folded:
                raise ValueError(f"duplicate metadata key: {key}")
            folded.add(key.casefold())
            result[key] = value
        return result

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-JSON numeric constant: {value}")

    record = json.loads(
        record_path.read_text(encoding="utf-8"),
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )
    if (
        not isinstance(record, dict)
        or type(record.get("schemaVersion")) is not int
        or record["schemaVersion"] != 1
        or record.get("platform") != "x86_64-pc-windows-msvc"
    ):
        raise ValueError("unsupported scanner metadata schema or platform")
    tools = record.get("tools")
    expected_tools = ["cargo-audit", "cargo-deny", "cargo-about", "cargo-cyclonedx"]
    if (
        not isinstance(tools, list)
        or len(tools) != len(expected_tools)
        or [tool.get("id") if isinstance(tool, dict) else None for tool in tools] != expected_tools
    ):
        raise ValueError("missing or ambiguous scanner metadata")
    pins = {}
    for tool in tools[:2]:
        name = tool["id"]
        version = tool.get("version")
        if not isinstance(version, str) or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None:
            raise ValueError(f"invalid {name} version")
        if version != SCANNER_REPORT_COMPATIBILITY[name]:
            raise ValueError(f"unreviewed {name} report compatibility for {version}")
        if name == "cargo-audit":
            expected_url = f"https://github.com/rustsec/rustsec/releases/download/cargo-audit/v{version}/cargo-audit-x86_64-pc-windows-msvc-v{version}.zip"
            expected_path = f"cargo-audit-x86_64-pc-windows-msvc-v{version}/cargo-audit.exe"
        else:
            expected_url = f"https://github.com/EmbarkStudios/cargo-deny/releases/download/{version}/cargo-deny-{version}-x86_64-pc-windows-msvc.tar.gz"
            expected_path = f"cargo-deny-{version}-x86_64-pc-windows-msvc/cargo-deny.exe"
        if tool.get("url") != expected_url or tool.get("archivePath") != expected_path:
            raise ValueError(f"unsupported {name} artifact identity")
        digest = tool.get("sha256")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise ValueError(f"missing or invalid {name} artifact digest")
        pins[name] = version
    return pins


def command(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(arguments, capture_output=True, text=True, check=False)
    except OSError as error:
        return subprocess.CompletedProcess(arguments, 127, "", str(error))


def load_report_json(output: str) -> object:
    """Reject ambiguous scanner fields without applying metadata's case-folded key rule."""

    def unique_fields(pairs: list[tuple[str, object]]) -> dict[str, object]:
        fields = {}
        for name, value in pairs:
            if name in fields:
                raise ValueError("duplicate JSON field")
            fields[name] = value
        return fields

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-JSON numeric constant: {value}")

    return json.loads(output, object_pairs_hook=unique_fields, parse_constant=reject_constant)


def audit_result(process: subprocess.CompletedProcess[str]) -> str:
    try:
        report = load_report_json(process.stdout)
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

    index_errors = sum(
        line.strip().startswith(AUDIT_INDEX_FAILURES) for line in process.stderr.splitlines()
    )
    warning_count = sum(len(entries) for entries in warnings.values())
    if count or warning_count:
        findings = f"findings ({count} vulnerabilities, {warning_count} warnings)"
        return f"{findings}; cargo-audit registry-index data unavailable" if index_errors else findings
    if index_errors:
        return f"tool or advisory-data failure ({index_errors} cargo-audit registry-index errors)"
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
            if check not in DENY_CHECKS or not isinstance(counts, dict):
                return "invalid summary check"
            if set(counts) != {"errors", "warnings", "notes", "helps"}:
                return "missing or invalid summary count"
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
    summaries: list[dict] = []

    for stream, output in (("stdout", process.stdout), ("stderr", process.stderr)):
        for number, line in enumerate(output.splitlines(), 1):
            if not line.strip():
                continue
            try:
                item = load_report_json(line)
                reason = deny_record_error(item)
            except ValueError:
                reason = "invalid JSON"
            if reason:
                return f"tool or output-validation failure (malformed cargo-deny output: {stream} line {number}: {reason})"
            fields = item["fields"]
            if item["type"] == "diagnostic":
                code = fields.get("code", "")
                if code.rsplit(":", 1)[-1] in ("index-failure", "index-cache-load-failure"):
                    data_errors += 1
                elif fields["severity"] == "bug":
                    tool_errors += 1
                elif fields["severity"] == "error":
                    errors += 1
            elif item["type"] == "log":
                tool_errors += fields["level"] == "ERROR"
            else:
                summaries.append(fields)
                summary_errors += sum(counts["errors"] for counts in fields.values())
    if data_errors:
        return f"tool or advisory-data failure ({data_errors} cargo-deny index errors)"
    if tool_errors:
        return f"tool or advisory-data failure ({tool_errors} cargo-deny error logs or bug diagnostics)"
    if errors:
        return f"policy violations ({errors} error diagnostics)"
    if len(summaries) > 1:
        return "tool or output-validation failure (ambiguous cargo-deny completion summaries)"
    if summary_errors:
        return "tool or advisory-data failure (cargo-deny summary errors without error diagnostics)"
    if process.returncode:
        return "tool or advisory-data failure (cargo-deny exited without policy diagnostics)"
    if not summaries:
        return "tool or output-validation failure (missing cargo-deny completion summary)"
    # The pinned full-check invocation emits exactly one summary of all four checks.
    if set(summaries[0]) != set(DENY_CHECKS):
        return "tool or output-validation failure (incomplete cargo-deny completion summary)"
    return "clean"


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cargo-audit", type=Path, help="Verified absolute cargo-audit executable path")
    parser.add_argument("--cargo-deny", type=Path, help="Verified absolute cargo-deny executable path")
    parser.add_argument("--emit-pins", action="store_true", help="Write reviewed scanner versions to GITHUB_OUTPUT")
    options = parser.parse_args(arguments)
    if options.emit_pins:
        if options.cargo_audit is not None or options.cargo_deny is not None:
            parser.error("--emit-pins cannot be combined with scanner paths")
        try:
            pins = scanner_pins()
            with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                output.write(f"audit-version={pins['cargo-audit']}\ndeny-version={pins['cargo-deny']}\n")
        except (OSError, KeyError, ValueError, TypeError, json.JSONDecodeError) as error:
            print(f"Scanner pin setup failed: {error}", file=sys.stderr)
            return 1
        return 0
    summary_path = Path(os.environ["GITHUB_STEP_SUMMARY"])
    source_sha = os.environ["GITHUB_SHA"]
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
    try:
        pins = scanner_pins()
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        results.append(("Setup", f"tool or source failure (invalid scanner metadata: {error})"))
        return finish()
    if (options.cargo_audit is None) != (options.cargo_deny is None):
        results.append(("Setup", "tool failure (both verified scanner paths are required)"))
        return finish()
    if options.cargo_audit is not None:
        scanners = {"cargo-audit": options.cargo_audit, "cargo-deny": options.cargo_deny}
    else:
        tools_root = os.environ.get("SECURITY_TOOLS_ROOT")
        if not tools_root:
            results.append(("Setup", "tool failure (verified scanner root is missing)"))
            return finish()
        scanners = {binary: Path(tools_root) / "bin" / binary for binary in ("cargo-audit", "cargo-deny")}
    for binary in SCANNER_IDS:
        expected = f"{binary} {pins[binary]}"
        path = scanners[binary]
        if path is None or not path.is_absolute():
            results.append(("Setup", f"tool failure ({binary} path must be absolute)"))
            return finish()
        version = command([str(path), "--version"])
        if version.returncode or version.stdout.strip() != expected:
            results.append(("Setup", f"tool failure ({binary} version mismatch or validation error)"))
            return finish()

    with tempfile.TemporaryDirectory(prefix="darkrenamer-rust-audit-", dir=runner_temp) as temporary:
        audit_db = str(Path(temporary) / "advisory-db")
        audit = command([
            str(scanners["cargo-audit"]),
            "audit", "--db", audit_db, "--deny", "warnings", "--file", "Cargo.lock", "--format", "json",
        ])
        results.append(("cargo-audit", audit_result(audit)))
        if audit.stderr:
            print(audit.stderr, file=sys.stderr, end="")

        deny = str(scanners["cargo-deny"])
        refresh = command([deny, "fetch", "db"])
        if refresh.returncode:
            results.append(("cargo-deny", "advisory-data failure (database refresh failed)"))
            if refresh.stderr:
                print(refresh.stderr, file=sys.stderr, end="")
        else:
            check = command([deny, "--format", "json", "--locked", "check"])
            result = deny_result(check)
            results.append(("cargo-deny", result))
            print(check.stdout, file=sys.stdout, end="")
            print(check.stderr, file=sys.stderr, end="")

    return finish()


if __name__ == "__main__":
    raise SystemExit(main())
