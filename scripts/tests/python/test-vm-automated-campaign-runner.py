#!/usr/bin/env python3
"""Focused tests for the fixed VM-automated campaign launcher."""

from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
from tooling_test_paths import REPOSITORY_ROOT
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZIP_STORED, ZipFile

from controller_cleanup_fixture import clean_controller_cleanup
from darkrenamer_tooling.campaign import runner
from darkrenamer_tooling.vm import launcher

REPOSITORY = REPOSITORY_ROOT


CANDIDATE_SHA = "2" * 40
HARNESS_SHA = CANDIDATE_SHA
VM_ID = "11111111-2222-3333-4444-555555555555"


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


class FakeGuiRunner:
    plan_path = None

    @staticmethod
    def load_connection_profile(path: Path):
        value = json.loads(path.read_text(encoding="utf-8"))
        return value, hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def guest_preflight(profile: dict) -> dict:
        if FakeGuiRunner.plan_path is not None:
            assert FakeGuiRunner.plan_path.is_file()
        return {
            "system": "windows",
            "product_caption": "Microsoft Windows 11 Pro",
            "os_version": "Microsoft Windows NT 10.0.26100.0",
            "build": "26100",
            "architecture": "x86_64",
            "vm_identity_kind": "hyper-v-guest-parameters-virtual-machine-id-v1",
            "vm_identity_sha256": hashlib.sha256(
                profile["expected_vm_id"].encode("utf-8")
            ).hexdigest(),
        }


class FakeNativeRunner:
    @staticmethod
    def verify_result(_root, _manifest, _result, *_args):
        return True


class CampaignRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = REPOSITORY
        self.output = self.root / "campaign"
        self.archive = self.root / "campaign.zip"
        self.connection = self.root / "connection.json"
        write_json(self.connection, {
            "schema_version": 1,
            "ssh_host": "fixture-vm",
            "desktop_helper": "C:\\Private\\desktop-session.ps1",
            "expected_vm_id": VM_ID,
        })
        self.handoff = self.root / "handoff"
        self.handoff.mkdir()
        (self.handoff / "release-handoff.json").write_text("{}", encoding="utf-8")
        (self.handoff / "DarkReNamer.exe").write_bytes(b"candidate executable")
        self.application_sha = hashlib.sha256(b"candidate executable").hexdigest()
        self.source = self.root / "source"
        self.source.mkdir()
        self.run_metadata = self.root / "run.json"
        self.artifact_metadata = self.root / "artifact.json"
        self.run_metadata.write_text("{}", encoding="utf-8")
        self.artifact_metadata.write_text("{}", encoding="utf-8")
        self.backend = self.root / "backend-source"
        self.backend.mkdir()
        required = json.loads(
            (self.repo / "config" / "vm-automated-v1.json").read_text(encoding="utf-8")
        )["required_backend_test_names"]
        tests = []
        binaries = []
        process_jobs = []

        def clean_job(lifecycle: dict) -> dict:
            return {"pid": lifecycle["pid"],
                    "process_start_time_utc_ticks": lifecycle["start_time_utc_ticks"],
                    "job_empty": True, "job_closed": True, "capture_complete": True,
                    "active_processes_at_primary_exit": None, "had_survivors": False,
                    "forced_termination": False, "active_processes_at_close": 0,
                    "active_processes_at_stop": None, "active_process_ids_at_stop": [],
                    "total_processes_at_stop": None, "primary_process_active_at_stop": None,
                    "termination_exit_code": None, "status": "clean", "error": None}

        for index, name in enumerate(required):
            stdout = f"test-{index}.stdout.txt"
            stderr = f"test-{index}.stderr.txt"
            (self.backend / stdout).write_text(f"test native::{name} ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s\n", encoding="utf-8")
            (self.backend / stderr).write_text("", encoding="utf-8")
            lifecycle = {"pid": 20_000 + index,
                         "start_time_utc_ticks": str(639100000000000000 + index)}
            process_jobs.append(clean_job(lifecycle))
            tests.append({
                "name": f"native-binary-{index}", "file": f"test-{index}.exe",
                "sha256": hashlib.sha256(b"large executable").hexdigest(), "exit_code": 0, "passed": 1, "failed": 0, "ignored": 0,
                "process_lifecycle": lifecycle,
                "stdout": {"file": stdout, "sha256": hashlib.sha256((self.backend / stdout).read_bytes()).hexdigest(),
                           "bytes": (self.backend / stdout).stat().st_size},
                "stderr": {"file": stderr, "sha256": hashlib.sha256(b"").hexdigest(), "bytes": 0},
            })
            binaries.append({"name": name, "file": f"test-{index}.exe", "sha256": hashlib.sha256(b"large executable").hexdigest()})
            (self.backend / f"test-{index}.exe").write_bytes(b"large executable")
        write_json(self.backend / "bundle.json", {
            "schema_version": 1,
            "source_sha": HARNESS_SHA,
            "source_state": "clean",
            "target": "x86_64-pc-windows-msvc",
            "cargo_lock_sha256": "d" * 64,
            "test_binaries": binaries,
            "application": {"file": "DarkReNamer.exe", "sha256": "e" * 64},
            "runner": {"file": "windows-vm-guest.ps1", "sha256": "f" * 64},
        })
        backend_cleanup = clean_controller_cleanup()
        gui_lifecycle = {"pid": 20_000 + len(tests),
                         "start_time_utc_ticks": str(639100000000000000 + len(tests))}
        process_jobs.append(clean_job(gui_lifecycle))
        write_json(self.backend / "result.json", {"schema_version": 1, "source_sha": HARNESS_SHA,
            "source_state": "clean", "target": "x86_64-pc-windows-msvc", "tests": tests,
            "gui": {"process_lifecycle": gui_lifecycle},
            "process_job_cleanup": process_jobs,
            "failure_reason": None, "transport": {
                "guest_cleanup": True, "raw_cleanup": backend_cleanup}})
        result_path = self.backend / "result.json"
        result_path.write_bytes(b"\xef\xbb\xbf" + result_path.read_bytes())
        write_json(self.backend / "transport.json", {
            "guest_cleanup": True, "raw_cleanup": backend_cleanup})

    def args(self) -> argparse.Namespace:
        return argparse.Namespace(
            profile=self.repo / "config" / "vm-automated-v1.json",
            connection_profile=self.connection,
            output_root=self.output,
            archive=self.archive,
            backend_root=self.backend,
            campaign_id="campaign-fixture",
            candidate_handoff_root=self.handoff,
            candidate_source_root=self.source,
            candidate_run_metadata=self.run_metadata,
            candidate_artifact_metadata=self.artifact_metadata,
            candidate_source_sha=CANDIDATE_SHA,
            candidate_workflow_run="10",
            candidate_run_attempt="2",
            candidate_artifact_id="30",
            candidate_executable_sha256=self.application_sha,
            test_timeout_seconds=300,
        )

    def fake_command(self, return_codes=None):
        calls = []
        codes = iter(return_codes or [])

        def invoke(command, *, cwd, text, stdout, stderr, check):
            self.assertTrue((self.output / "plan.json").is_file())
            self.assertFalse((self.output / "campaign.json").exists())
            calls.append(list(command))
            stdout.write("controller stdout\n")
            stderr.write("controller stderr\n")
            self.assertEqual(command[1], "-I", "Campaign subprocess must start isolated.")
            bundle = Path(command[command.index("--output") + 1])
            bundle.mkdir()
            write_json(bundle / "bundle.json", {"schema_version": 2})
            write_json(bundle / "desktop-lease.json", {
                "schema_version": 1, "lease_id": f"{len(calls):032x}"[-32:]
            })
            task = command[command.index("--task-kind") + 1]
            if task == "core":
                write_json(bundle / "result.json", {"status": "passed"})
                write_json(bundle / "transport.json", {"status": "collected"})
            elif task == "ui":
                write_json(bundle / "observer-output" / "acceptance-result.json", {
                    "status": "review_required"
                })
                write_json(bundle / "observer-output" / "transport.json", {
                    "status": "collected"
                })
            else:
                write_json(bundle / "observer-output" / "recovery-raw-abc" / "summary.json", {
                    "status": "passed"
                })
                write_json(bundle / "observer-output" / "transport.json", {
                    "status": "collected"
                })
            try:
                code = next(codes)
            except StopIteration:
                code = 0
            return subprocess.CompletedProcess(command, code)

        return calls, invoke

    def execute(self, args, command):
        def source_sha(path):
            return CANDIDATE_SHA if Path(path) == self.source else HARNESS_SHA
        FakeGuiRunner.plan_path = self.output / "plan.json"
        try:
            with patch.object(runner, "launcher", FakeNativeRunner), \
                    patch.object(runner, "vm_connection", FakeGuiRunner), \
                    patch.object(runner, "staged_tooling_files", return_value=[]), \
                    patch.object(runner, "clean_source_sha", side_effect=source_sha), \
                    patch.object(runner.subprocess, "run", side_effect=command):
                return runner.execute(args, repo=self.repo)
        finally:
            FakeGuiRunner.plan_path = None

    def test_full_fixed_campaign_writes_plan_first_and_stored_indexed_archive(self) -> None:
        calls, command = self.fake_command()
        status = self.execute(self.args(), command)
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 30)
        self.assertEqual(sum("--task-kind" in call and call[call.index("--task-kind") + 1] == "core"
                             for call in calls), 11)
        self.assertEqual(sum(call[call.index("--task-kind") + 1] == "ui" for call in calls), 16)
        self.assertEqual(sum(call[call.index("--task-kind") + 1] == "recovery" for call in calls), 3)
        campaign = json.loads((self.output / "campaign.json").read_text(encoding="utf-8"))
        self.assertEqual(len(campaign["attempts"]), 30)
        self.assertEqual([row["attempt"] for row in campaign["attempts"]], [1] * 30)
        self.assertEqual(len({row["desktop_lease"] for row in campaign["attempts"]}), 30)
        self.assertTrue(any(path.suffix.lower() == ".exe"
                             for path in (self.output / "backend").iterdir()))
        with ZipFile(self.archive) as archive:
            self.assertTrue(all(row.compress_type == ZIP_STORED for row in archive.infolist()))
            names = [row.filename for row in archive.infolist()]
            self.assertIn("evidence-index.json", names)
            self.assertIn("campaign.json", names)
            self.assertIn("plan.json", names)
            self.assertNotIn("canonical-statement.json", names)
            index = json.loads(archive.read("evidence-index.json"))
            self.assertNotIn("evidence-index.json", index["files"])
            self.assertIn("campaign.json", index["files"])
        text_command = "\n".join(" ".join(call) for call in calls)
        for flag in (
            "--candidate-handoff-root", "--candidate-source-root",
            "--candidate-run-metadata", "--candidate-artifact-metadata",
            "--candidate-source-sha", "--candidate-workflow-run",
            "--candidate-run-attempt", "--candidate-artifact-id",
            "--candidate-executable-sha256",
        ):
            self.assertIn(flag, text_command)
        text150 = next(call for call in calls if "layout-small-text150-100" in " ".join(call))
        self.assertEqual(text150[text150.index("--acceptance-mode") + 1], "text-scale")
        manifest = json.loads(Path(text150[text150.index("--acceptance-manifest") + 1]).read_text())
        self.assertEqual(manifest["request"]["desktop"], {"width": 800, "height": 600, "dpi": 96})
        self.assertEqual(manifest["request"]["layout_variant"], "native-menu-only")
        self.assertEqual(manifest["guest_preflight"]["build"], "26100")
        for call in calls:
            if "--acceptance-manifest" not in call or call == text150:
                continue
            ordinary = json.loads(Path(call[call.index("--acceptance-manifest") + 1]).read_text())
            self.assertEqual(ordinary["request"]["layout_variant"], "command-rails")

    def test_backend_files_accept_current_output_contract_and_empty_stderr(self) -> None:
        result = json.loads((self.backend / "result.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(runner.backend_files(result), [
            name for row in result["tests"]
            for name in (row["file"], row["stdout"]["file"], row["stderr"]["file"])
        ])
        self.assertTrue(all(row["stderr"]["bytes"] == 0 for row in result["tests"]))

    def test_backend_files_reject_invalid_output_contract(self) -> None:
        original = json.loads((self.backend / "result.json").read_text(encoding="utf-8-sig"))
        mutations = [
            ("missing-bytes", lambda ref: ref.pop("bytes")),
            ("extra-field", lambda ref: ref.update(extra=True)),
            ("invalid-digest", lambda ref: ref.update(sha256="invalid")),
            ("non-string-digest", lambda ref: ref.update(sha256=None)),
            ("non-leaf-name", lambda ref: ref.update(file="../stdout.txt")),
        ] + [(str(value), lambda ref, value=value: ref.update(bytes=value))
             for value in (True, None, "0", 0.5, -1,
                           launcher.TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES + 1)]
        for label, mutate in mutations:
            with self.subTest(label=label):
                result = deepcopy(original)
                mutate(result["tests"][0]["stdout"])
                with self.assertRaises(ValueError):
                    runner.backend_files(result)

    def test_backend_files_enforce_aggregate_output_bound(self) -> None:
        maximum = launcher.TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES
        rows = launcher.TEST_OUTPUT_AGGREGATE_MAXIMUM_BYTES // (2 * maximum)
        result = {"tests": [{
            "file": f"test-{index}.exe",
            **{channel: {"file": f"test-{index}.{channel}.txt", "sha256": "a" * 64,
                         "bytes": maximum} for channel in ("stdout", "stderr")},
        } for index in range(rows)]}
        self.assertEqual(len(runner.backend_files(result)), rows * 3)
        result["tests"].append({"file": "overflow.exe",
                                "stdout": {"file": "overflow.txt", "sha256": "a" * 64, "bytes": 1},
                                "stderr": {"file": "empty.txt", "sha256": "a" * 64, "bytes": 0}})
        with self.assertRaisesRegex(ValueError, "size bound"):
            runner.backend_files(result)

    def test_prepare_backend_rejects_byte_mismatch_with_real_native_validator(self) -> None:
        result_path = self.backend / "result.json"
        result = json.loads(result_path.read_text(encoding="utf-8-sig"))
        result["tests"][0]["stdout"]["bytes"] += 1
        write_json(result_path, result)
        profile = json.loads((self.repo / "config" / "vm-automated-v1.json").read_text())
        with self.assertRaisesRegex(ValueError, "recorded byte count"):
            runner.prepare_backend(self.backend, self.root / "prepared-backend", profile,
                                   HARNESS_SHA, launcher)
        self.assertFalse((self.root / "prepared-backend").exists())

    def test_backend_external_cleanup_must_match_embedded_raw_observation(self) -> None:
        transport_path = self.backend / "transport.json"
        transport = json.loads(transport_path.read_text(encoding="utf-8"))
        transport["raw_cleanup"]["runner_process_natural_exit"]["runner_session_id"] = 3
        write_json(transport_path, transport)
        profile = json.loads((self.repo / "config" / "vm-automated-v1.json").read_text())
        with patch.object(runner, "staged_tooling_files", return_value=[]), \
                self.assertRaisesRegex(ValueError, "embedded and external"):
            runner.prepare_backend(
                self.backend, self.root / "prepared-backend", profile,
                HARNESS_SHA, FakeNativeRunner)

    def test_failed_first_attempt_is_retained_and_stops_without_retry(self) -> None:
        calls, command = self.fake_command([7])
        status = self.execute(self.args(), command)
        self.assertEqual(status, 1)
        self.assertEqual(len(calls), 1)
        campaign = json.loads((self.output / "campaign.json").read_text(encoding="utf-8"))
        self.assertEqual(len(campaign["attempts"]), 1)
        self.assertEqual(campaign["attempts"][0]["exit_code"], 7)
        self.assertEqual(campaign["attempts"][0]["attempt"], 1)
        self.assertEqual(sum(row["slot_id"] == campaign["attempts"][0]["slot_id"]
                             for row in campaign["attempts"]), 1)
        self.assertTrue(self.archive.is_file())

    def test_archive_rejects_case_alias_symlink_and_mutation(self) -> None:
        package = self.root / "package"
        package.mkdir()
        (package / "campaign.json").write_text("{}", encoding="utf-8")
        (package / "plan.json").write_text("{}", encoding="utf-8")
        (package / "A.txt").write_text("a", encoding="utf-8")
        (package / "a.txt").write_text("b", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "case"):
            runner.package_evidence(package, self.root / "case.zip")
        (package / "a.txt").unlink()
        (package / "link.txt").symlink_to(package / "A.txt")
        with self.assertRaisesRegex(ValueError, "ordinary"):
            runner.package_evidence(package, self.root / "link.zip")
        (package / "link.txt").unlink()
        original = runner.read_frozen_file

        def mutate(path, frozen):
            if path.name == "A.txt":
                path.write_text("changed", encoding="utf-8")
            return original(path, frozen)

        with patch.object(runner, "read_frozen_file", side_effect=mutate), \
                self.assertRaisesRegex(ValueError, "changed"):
            runner.package_evidence(package, self.root / "changed.zip")

    def test_output_and_archive_must_be_fresh(self) -> None:
        self.output.mkdir()
        calls, command = self.fake_command()
        with self.assertRaisesRegex(ValueError, "new"):
            self.execute(self.args(), command)
        self.assertEqual(calls, [])

    def test_harness_source_mismatch_fails_before_inputs_output_or_vm(self) -> None:
        calls, command = self.fake_command()
        args = self.args()
        args.profile = self.root / "unread-profile.json"
        args.connection_profile = self.root / "unread-connection.json"

        def source_sha(path):
            return CANDIDATE_SHA if Path(path) == self.source else "1" * 40

        with patch.object(runner, "launcher", FakeNativeRunner), \
                patch.object(runner, "vm_connection", FakeGuiRunner), \
                patch.object(runner, "staged_tooling_files", return_value=[]), \
                patch.object(runner, "clean_source_sha", side_effect=source_sha), \
                patch.object(FakeGuiRunner, "load_connection_profile",
                             side_effect=AssertionError("connection input reached")), \
                patch.object(runner.subprocess, "run", side_effect=command):
            with self.assertRaisesRegex(ValueError, "harness source"):
                runner.execute(args, repo=self.repo)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.archive.exists())
        self.assertEqual(calls, [])

    def test_backend_source_mismatch_fails_after_plan_and_before_vm(self) -> None:
        manifest = json.loads((self.backend / "bundle.json").read_text(encoding="utf-8"))
        manifest["source_sha"] = "9" * 40
        write_json(self.backend / "bundle.json", manifest)
        calls, command = self.fake_command()
        with self.assertRaisesRegex(ValueError, "source-bound"):
            self.execute(self.args(), command)
        self.assertTrue((self.output / "plan.json").is_file())
        self.assertEqual(calls, [])

    def test_duplicate_connection_key_fails_before_output_or_vm(self) -> None:
        self.connection.write_text(
            '{"schema_version":1,"schema_version":1,"ssh_host":"fixture-vm",'
            '"desktop_helper":"C:\\\\Private\\\\desktop-session.ps1",'
            f'"expected_vm_id":"{VM_ID}"}}', encoding="utf-8"
        )
        calls, command = self.fake_command()
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.execute(self.args(), command)
        self.assertFalse(self.output.exists())
        self.assertEqual(calls, [])


class CampaignLockTests(unittest.TestCase):
    def test_lock_is_canonical_and_non_reentrant(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            with runner.campaign_lock(VM_ID, state):
                expected = state / (VM_ID + ".lock")
                self.assertTrue(expected.is_file())
                with self.assertRaisesRegex(RuntimeError, "already running"):
                    with runner.campaign_lock(VM_ID, state):
                        self.fail("Concurrent campaign lock was accepted")


if __name__ == "__main__":
    unittest.main()
