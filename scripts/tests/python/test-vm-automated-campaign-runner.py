#!/usr/bin/env python3
"""Focused tests for the fixed VM-automated campaign launcher."""

from __future__ import annotations

import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import stat
from tooling_test_paths import REPOSITORY_ROOT
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from zipfile import ZIP_STORED, ZipFile

from controller_cleanup_fixture import clean_controller_cleanup
from darkrenamer_tooling.campaign import runner
from darkrenamer_tooling.vm import launcher
from darkrenamer_tooling.evidence.archive import EvidenceError

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
    def test_cli_profile_defaults_to_v2_and_retains_explicit_v1(self) -> None:
        parser = runner.argument_parser(REPOSITORY)
        self.assertEqual(parser.get_default("profile"),
                         REPOSITORY / "config" / "vm-automated-v2.json")
        selected = parser.parse_args([
            "--profile", str(REPOSITORY / "config" / "vm-automated-v1.json"),
            "--connection-profile", "connection.json", "--output-root", "output",
            "--archive", "archive.zip", "--backend-root", "backend",
            "--candidate-handoff-root", "handoff", "--candidate-source-root", "source",
            "--candidate-run-metadata", "run.json", "--candidate-artifact-metadata", "artifact.json",
            "--candidate-source-sha", CANDIDATE_SHA, "--candidate-workflow-run", "10",
            "--candidate-run-attempt", "2", "--candidate-artifact-id", "30",
            "--candidate-executable-sha256", "a" * 64,
        ])
        self.assertEqual(selected.profile, REPOSITORY / "config" / "vm-automated-v1.json")

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
                    patch.object(runner.subprocess, "check_output", return_value=Path(args.profile).read_bytes()), \
                    patch.object(runner.subprocess, "run", side_effect=command):
                return runner.execute(args, repo=self.repo)
        finally:
            FakeGuiRunner.plan_path = None

    def synthetic_package(self, name: str) -> Path:
        package = self.root / name
        package.mkdir()
        (package / "campaign.json").write_text("{}", encoding="utf-8")
        (package / "plan.json").write_text("{}", encoding="utf-8")
        return package

    def test_profile_identity_or_bytes_mismatch_fails_before_vm_and_plan(self) -> None:
        calls, command = self.fake_command()
        args = self.args()
        profile = json.loads(Path(args.profile).read_bytes())
        profile['profile_id'] = 'vm-automated-v2-owned-resources'
        changed = self.root / 'mixed-profile.json'
        write_json(changed, profile)
        args.profile = changed
        with self.assertRaisesRegex(EvidenceError, 'schema, identity and revision'):
            self.execute(args, command)
        self.assertFalse(self.output.exists())
        self.assertEqual(calls, [])

        args = self.args()
        profile = json.loads(Path(args.profile).read_bytes())
        profile['required_targets'].pop()
        write_json(changed, profile)
        args.profile = changed
        def source_sha(path):
            return CANDIDATE_SHA if Path(path) == self.source else HARNESS_SHA
        with patch.object(runner, 'clean_source_sha', side_effect=source_sha), \
                patch.object(runner.subprocess, 'check_output',
                             return_value=Path(self.args().profile).read_bytes()):
            with self.assertRaisesRegex(ValueError, 'same-SHA trusted source profile'):
                runner.execute(args, repo=self.repo)
        self.assertFalse(self.output.exists())

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

    def test_archive_is_private_during_write_and_after_publication(self) -> None:
        package = self.root / "private-package"
        package.mkdir()
        (package / "campaign.json").write_text("{}", encoding="utf-8")
        (package / "plan.json").write_text("{}", encoding="utf-8")
        archive_path = self.root / "private.zip"
        observed = []

        real_open = os.open

        def inspect_creation(path, flags, *args, **kwargs):
            descriptor = real_open(path, flags, *args, **kwargs)
            if flags & os.O_CREAT:
                created = os.fstat(descriptor)
                observed.append((stat.S_IMODE(created.st_mode), created.st_size,
                                 flags & os.O_EXCL, flags & os.O_NOFOLLOW))
            return descriptor

        previous_umask = os.umask(0)
        try:
            with patch.object(runner.os, "open", side_effect=inspect_creation):
                runner.package_evidence(package, archive_path)
        finally:
            os.umask(previous_umask)
        self.assertTrue(observed)
        self.assertEqual(observed, [(0o600, 0, os.O_EXCL, os.O_NOFOLLOW)])
        self.assertEqual(stat.S_IMODE(archive_path.stat().st_mode), 0o600)
        self.assertEqual(list(self.root.glob(".private.zip.*.tmp")), [])

    def test_archive_write_failure_removes_private_temporary_without_publication(self) -> None:
        package = self.root / "failed-package"
        package.mkdir()
        (package / "campaign.json").write_text("{}", encoding="utf-8")
        (package / "plan.json").write_text("{}", encoding="utf-8")
        archive_path = self.root / "failed.zip"

        def fail_during_write(_path, _frozen):
            temporary, = self.root.glob(".failed.zip.*.tmp")
            self.assertEqual(stat.S_IMODE(temporary.stat().st_mode), 0o600)
            raise RuntimeError("injected archive write failure")

        with patch.object(runner, "read_frozen_file", side_effect=fail_during_write), \
                self.assertRaisesRegex(RuntimeError, "injected archive write failure"):
            runner.package_evidence(package, archive_path)
        self.assertFalse(archive_path.exists())
        self.assertEqual(list(self.root.glob(".failed.zip.*.tmp")), [])

    def test_archive_rejects_permission_change_during_write(self) -> None:
        package = self.root / "changed-mode-package"
        package.mkdir()
        (package / "campaign.json").write_text("{}", encoding="utf-8")
        (package / "plan.json").write_text("{}", encoding="utf-8")
        archive_path = self.root / "changed-mode.zip"
        original = runner.read_frozen_file

        def expose_temporary(path, frozen):
            temporary, = self.root.glob(".changed-mode.zip.*.tmp")
            temporary.chmod(0o644)
            return original(path, frozen)

        with patch.object(runner, "read_frozen_file", side_effect=expose_temporary), \
                self.assertRaisesRegex(ValueError, "changed while writing"):
            runner.package_evidence(package, archive_path)
        self.assertFalse(archive_path.exists())
        self.assertEqual(list(self.root.glob(".changed-mode.zip.*.tmp")), [])

    def test_archive_temporary_name_collision_preserves_existing_file(self) -> None:
        package = self.root / "temporary-collision-package"
        package.mkdir()
        (package / "campaign.json").write_text("{}", encoding="utf-8")
        (package / "plan.json").write_text("{}", encoding="utf-8")
        temporary = self.root / ".temporary-collision.zip.fixed.tmp"
        temporary.write_bytes(b"existing temporary")

        class FixedToken:
            hex = "fixed"

        with patch.object(runner.uuid, "uuid4", return_value=FixedToken()), \
                self.assertRaises(FileExistsError):
            runner.package_evidence(package, self.root / "temporary-collision.zip")
        self.assertEqual(temporary.read_bytes(), b"existing temporary")
        self.assertFalse((self.root / "temporary-collision.zip").exists())

    def test_archive_rejects_permission_change_during_publication(self) -> None:
        package = self.root / "publish-mode-package"
        package.mkdir()
        (package / "campaign.json").write_text("{}", encoding="utf-8")
        (package / "plan.json").write_text("{}", encoding="utf-8")
        archive_path = self.root / "publish-mode.zip"
        original_link = os.link

        def expose_published_archive(source, destination, **kwargs):
            original_link(source, destination, **kwargs)
            archive_path.chmod(0o644)

        with patch.object(runner.os, "link", side_effect=expose_published_archive), \
                self.assertRaisesRegex(ValueError, "entry changed"):
            runner.package_evidence(package, archive_path)
        self.assertFalse(archive_path.exists())
        self.assertEqual(list(self.root.glob(".publish-mode.zip.*.tmp")), [])

    def test_archive_publication_cannot_replace_existing_file(self) -> None:
        package = self.root / "collision-package"
        package.mkdir()
        (package / "campaign.json").write_text("{}", encoding="utf-8")
        (package / "plan.json").write_text("{}", encoding="utf-8")
        archive_path = self.root / "collision.zip"

        def occupy_destination(_source, destination, **kwargs):
            os.close(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                             0o600, dir_fd=kwargs["dst_dir_fd"]))
            archive_path.write_bytes(b"existing archive")
            raise FileExistsError("injected publication collision")

        with patch.object(runner.os, "link", side_effect=occupy_destination), \
                self.assertRaisesRegex(FileExistsError, "injected publication collision"):
            runner.package_evidence(package, archive_path)
        self.assertEqual(archive_path.read_bytes(), b"existing archive")
        self.assertEqual(list(self.root.glob(".collision.zip.*.tmp")), [])

    def test_private_parent_success_keeps_archive_index_and_mode(self) -> None:
        package = self.synthetic_package("private-parent-package")
        archive_path = self.root / "private-parent.zip"
        receipt = runner.package_evidence(package, archive_path)
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(archive_path.stat().st_mode), 0o600)
        self.assertEqual(receipt["sha256"], hashlib.sha256(archive_path.read_bytes()).hexdigest())
        with ZipFile(archive_path) as archive:
            index = json.loads(archive.read("evidence-index.json"))
            self.assertEqual(set(index["files"]), {"campaign.json", "plan.json"})
            for name, details in index["files"].items():
                self.assertEqual(details["sha256"], hashlib.sha256(archive.read(name)).hexdigest())

    def test_unsafe_archive_parent_rejected_without_creating_temporary(self) -> None:
        package = self.synthetic_package("unsafe-parent-package")
        parent = self.root / "unsafe-parent"
        parent.mkdir(mode=0o700)
        for mode in (0o755, 0o770):
            with self.subTest(mode=oct(mode)):
                parent.chmod(mode)
                with self.assertRaisesRegex(ValueError, "private \\(0700\\)"):
                    runner.package_evidence(package, parent / "evidence.zip")
                self.assertEqual(list(parent.iterdir()), [])
                self.assertEqual(stat.S_IMODE(parent.stat().st_mode), mode)
        parent.chmod(0o700)
        linked = self.root / "linked-parent"
        linked.symlink_to(parent, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "ordinary directory"):
            runner.package_evidence(package, linked / "evidence.zip")
        self.assertEqual(list(parent.iterdir()), [])

        original_fstat = os.fstat

        def inject_wrong_owner(descriptor):
            metadata = original_fstat(descriptor)
            if stat.S_ISDIR(metadata.st_mode):
                return SimpleNamespace(st_mode=metadata.st_mode, st_dev=metadata.st_dev,
                                       st_ino=metadata.st_ino, st_uid=os.geteuid() + 1)
            return metadata

        with self.subTest(case="injected wrong effective owner"), \
                patch.object(runner.os, "fstat", side_effect=inject_wrong_owner), \
                self.assertRaisesRegex(ValueError, "effective-user-owned"):
            runner.package_evidence(package, parent / "evidence.zip")
        self.assertEqual(list(parent.iterdir()), [])

    def test_output_and_archive_parents_are_private_before_vm_work(self) -> None:
        unsafe = self.root / "unsafe-preflight"
        unsafe.mkdir(mode=0o700)
        calls, command = self.fake_command()
        try:
            for destination in ("archive", "output_root"):
                for mode in (0o755, 0o770):
                    with self.subTest(destination=destination, mode=oct(mode)):
                        unsafe.chmod(mode)
                        args = self.args()
                        setattr(args, destination, unsafe / ("campaign.zip" if destination == "archive"
                                                           else "campaign"))
                        with self.assertRaisesRegex(ValueError, "private \\(0700\\)"):
                            self.execute(args, command)
                        self.assertFalse(self.output.exists())
                        self.assertEqual(list(unsafe.iterdir()), [])
                        self.assertEqual(calls, [])
        finally:
            unsafe.chmod(0o700)
        linked = self.root / "linked-preflight"
        linked.symlink_to(unsafe, target_is_directory=True)
        for destination in ("archive", "output_root"):
            with self.subTest(destination=destination, case="linked parent"):
                args = self.args()
                setattr(args, destination, linked / ("campaign.zip" if destination == "archive"
                                                    else "campaign"))
                with self.assertRaisesRegex(ValueError, "ordinary directory"):
                    self.execute(args, command)
                self.assertEqual(calls, [])
        original_fstat = os.fstat

        def inject_wrong_owner(descriptor):
            metadata = original_fstat(descriptor)
            if stat.S_ISDIR(metadata.st_mode):
                return SimpleNamespace(st_mode=metadata.st_mode, st_dev=metadata.st_dev,
                                       st_ino=metadata.st_ino, st_uid=os.geteuid() + 1)
            return metadata

        for destination in ("archive", "output_root"):
            with self.subTest(destination=destination, case="injected wrong effective owner"):
                args = self.args()
                setattr(args, destination, unsafe / ("campaign.zip" if destination == "archive"
                                                    else "campaign"))
                with patch.object(runner.os, "fstat", side_effect=inject_wrong_owner), \
                        self.assertRaisesRegex(ValueError, "effective-user-owned"):
                    self.execute(args, command)
                self.assertEqual(list(unsafe.iterdir()), [])
                self.assertEqual(calls, [])

    def test_parent_ancestor_alias_cannot_bypass_checkout_containment(self) -> None:
        checkout = self.root / "checkout"
        checkout.mkdir(mode=0o700)
        private = checkout / "private"
        private.mkdir(mode=0o700)
        alias = self.root / "checkout-alias"
        alias.symlink_to(checkout, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "external to the checkout"):
            runner.new_external_root(checkout, alias / "private" / "campaign")
        with self.assertRaisesRegex(ValueError, "outside the checkout"):
            runner.new_archive_path(checkout, alias / "private" / "campaign.zip",
                                    self.root / "campaign")
        self.assertEqual(list(private.iterdir()), [])

    def test_missing_relative_nofollow_capability_refuses_packaging(self) -> None:
        package = self.synthetic_package("capability-package")
        with patch.object(runner.os, "supports_follow_symlinks", set()), \
                self.assertRaisesRegex(ValueError, "directory-descriptor capabilities"):
            runner.package_evidence(package, self.root / "unsupported.zip")
        self.assertEqual(list(self.root.glob(".unsupported.zip.*.tmp")), [])

    def test_early_identity_failure_closes_descriptor_without_guessing_name(self) -> None:
        package = self.synthetic_package("identity-failure-package")
        created_fd = None
        real_open = os.open
        real_fstat = os.fstat

        def capture_creation(path, flags, *args, **kwargs):
            nonlocal created_fd
            descriptor = real_open(path, flags, *args, **kwargs)
            if flags & os.O_CREAT:
                created_fd = descriptor
            return descriptor

        def fail_created_identity(descriptor):
            if descriptor == created_fd:
                raise OSError("injected identity capture failure")
            return real_fstat(descriptor)

        with patch.object(runner.os, "open", side_effect=capture_creation), \
                patch.object(runner.os, "fstat", side_effect=fail_created_identity), \
                self.assertRaisesRegex(RuntimeError, "identity capture failure.*cleanup uncertain"):
            runner.package_evidence(package, self.root / "identity-failure.zip")
        self.assertIsNotNone(created_fd)
        with self.assertRaises(OSError):
            os.fstat(created_fd)
        temporary, = self.root.glob(".identity-failure.zip.*.tmp")
        self.assertEqual(stat.S_IMODE(temporary.stat().st_mode), 0o600)
        self.assertFalse((self.root / "identity-failure.zip").exists())

    def test_fdopen_failure_closes_both_descriptors_and_cleans_owned_temporary(self) -> None:
        package = self.synthetic_package("fdopen-failure-package")
        created_fds = []
        real_open = os.open
        real_dup = os.dup

        def capture_creation(path, flags, *args, **kwargs):
            descriptor = real_open(path, flags, *args, **kwargs)
            if flags & os.O_CREAT:
                created_fds.append(descriptor)
            return descriptor

        def capture_duplicate(descriptor):
            duplicate = real_dup(descriptor)
            created_fds.append(duplicate)
            return duplicate

        with patch.object(runner.os, "open", side_effect=capture_creation), \
                patch.object(runner.os, "dup", side_effect=capture_duplicate), \
                patch.object(runner.os, "fdopen", side_effect=OSError("injected fdopen failure")), \
                self.assertRaisesRegex(OSError, "injected fdopen failure"):
            runner.package_evidence(package, self.root / "fdopen-failure.zip")
        self.assertEqual(len(created_fds), 2)
        for descriptor in created_fds:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        self.assertEqual(list(self.root.glob(".fdopen-failure.zip.*.tmp")), [])

    def test_fdopen_and_duplicate_close_failures_report_both_errors(self) -> None:
        package = self.synthetic_package("fdopen-close-package")
        original_dup = os.dup
        original_close = os.close
        writer_fd = None

        def capture_duplicate(descriptor):
            nonlocal writer_fd
            writer_fd = original_dup(descriptor)
            return writer_fd

        def close_then_fail(descriptor):
            original_close(descriptor)
            if descriptor == writer_fd:
                raise OSError("injected duplicate close failure")

        with patch.object(runner.os, "dup", side_effect=capture_duplicate), \
                patch.object(runner.os, "fdopen", side_effect=OSError("injected fdopen failure")), \
                patch.object(runner.os, "close", side_effect=close_then_fail), \
                self.assertRaisesRegex(RuntimeError,
                                       "fdopen failure.*cleanup uncertain.*duplicate close failure") as caught:
            runner.package_evidence(package, self.root / "fdopen-close.zip")
        self.assertIsInstance(caught.exception.__cause__, OSError)
        self.assertEqual(list(self.root.glob(".fdopen-close.zip.*.tmp")), [])
        with self.assertRaises(OSError):
            os.fstat(writer_fd)

    def test_private_parent_close_failure_preserves_primary_error(self) -> None:
        original_close = os.close
        parent_fd = None

        def close_then_fail(descriptor):
            original_close(descriptor)
            if descriptor == parent_fd:
                raise OSError("injected parent close failure")

        with patch.object(runner.os, "close", side_effect=close_then_fail), \
                self.assertRaisesRegex(RuntimeError,
                                       "injected primary failure.*descriptor cleanup uncertain.*"
                                       "parent close failure") as caught:
            with runner.private_parent(self.root, "Test private parent") as (descriptor, _identity):
                parent_fd = descriptor
                raise RuntimeError("injected primary failure")
        self.assertIsInstance(caught.exception.__cause__, RuntimeError)

    def test_parent_close_failure_after_valid_package_denies_receipt(self) -> None:
        package = self.synthetic_package("parent-close-package")
        original_open = os.open
        original_close = os.close
        parent_fd = None

        def capture_parent(path, flags, *args, **kwargs):
            nonlocal parent_fd
            descriptor = original_open(path, flags, *args, **kwargs)
            if flags & os.O_DIRECTORY:
                parent_fd = descriptor
            return descriptor

        def close_then_fail(descriptor):
            original_close(descriptor)
            if descriptor == parent_fd:
                raise OSError("injected parent close failure")

        with patch.object(runner.os, "open", side_effect=capture_parent), \
                patch.object(runner.os, "close", side_effect=close_then_fail), \
                self.assertRaisesRegex(OSError, "injected parent close failure"):
            runner.package_evidence(package, self.root / "parent-close.zip")
        self.assertTrue((self.root / "parent-close.zip").is_file())

    def test_archive_entry_close_failure_preserves_validation_error(self) -> None:
        entry = self.root / "entry-close.zip"
        entry.write_bytes(b"synthetic entry")
        entry.chmod(0o600)
        original_open = os.open
        original_close = os.close
        entry_fd = None

        def capture_entry(path, flags, *args, **kwargs):
            nonlocal entry_fd
            descriptor = original_open(path, flags, *args, **kwargs)
            if path == entry.name:
                entry_fd = descriptor
            return descriptor

        def close_then_fail(descriptor):
            original_close(descriptor)
            if descriptor == entry_fd:
                raise OSError("injected entry close failure")

        with runner.private_parent(self.root, "Test private parent") as (parent_fd, _identity):
            created = os.stat(entry.name, dir_fd=parent_fd, follow_symlinks=False)
            with patch.object(runner.os, "open", side_effect=capture_entry), \
                    patch.object(runner.os, "close", side_effect=close_then_fail), \
                    self.assertRaisesRegex(RuntimeError,
                                           "entry changed.*descriptor cleanup uncertain.*"
                                           "entry close failure") as caught:
                runner._archive_entry(parent_fd, entry.name, created, 2)
        self.assertIsInstance(caught.exception.__cause__, ValueError)
        with self.assertRaises(OSError):
            os.fstat(entry_fd)

    def test_temporary_replacement_survives_failed_publication_and_cleanup(self) -> None:
        package = self.synthetic_package("replace-temporary-package")
        archive_path = self.root / "replace-temporary.zip"
        original_read = runner.read_frozen_file
        saved = self.root / "saved-original-temporary"
        replaced = False
        replacement_identity = None

        def replace_temporary(path, frozen):
            nonlocal replaced, replacement_identity
            if not replaced:
                temporary, = self.root.glob(".replace-temporary.zip.*.tmp")
                temporary.rename(saved)
                temporary.write_bytes(b"replacement temporary")
                replacement_identity = (temporary.stat().st_dev, temporary.stat().st_ino)
                replaced = True
            return original_read(path, frozen)

        with patch.object(runner, "read_frozen_file", side_effect=replace_temporary), \
                self.assertRaisesRegex(RuntimeError, "entry changed.*cleanup uncertain.*replaced"):
            runner.package_evidence(package, archive_path)
        temporary, = self.root.glob(".replace-temporary.zip.*.tmp")
        self.assertEqual(temporary.read_bytes(), b"replacement temporary")
        self.assertEqual((temporary.stat().st_dev, temporary.stat().st_ino), replacement_identity)
        self.assertTrue(saved.is_file())
        self.assertFalse(archive_path.exists())

    def test_missing_temporary_entry_reports_uncertainty_without_searching(self) -> None:
        package = self.synthetic_package("missing-temporary-package")
        archive_path = self.root / "missing-temporary.zip"
        saved = self.root / "saved-missing-temporary"
        original_read = runner.read_frozen_file
        saved_identity = None

        def move_temporary(path, frozen):
            nonlocal saved_identity
            if saved_identity is None:
                temporary, = self.root.glob(".missing-temporary.zip.*.tmp")
                temporary.rename(saved)
                saved_identity = (saved.stat().st_dev, saved.stat().st_ino)
            return original_read(path, frozen)

        with patch.object(runner, "read_frozen_file", side_effect=move_temporary), \
                self.assertRaisesRegex(RuntimeError, "No such file.*cleanup uncertain.*missing"):
            runner.package_evidence(package, archive_path)
        self.assertEqual((saved.stat().st_dev, saved.stat().st_ino), saved_identity)
        self.assertFalse(archive_path.exists())
        self.assertEqual(list(self.root.glob(".missing-temporary.zip.*.tmp")), [])

    def test_parent_replacement_blocks_publication_and_preserves_old_directory(self) -> None:
        package = self.synthetic_package("replace-parent-package")
        parent = self.root / "replace-parent"
        parent.mkdir(mode=0o700)
        original_identity = (parent.stat().st_dev, parent.stat().st_ino)
        moved = self.root / "moved-parent"
        archive_path = parent / "evidence.zip"
        original_read = runner.read_frozen_file
        replaced = False

        def replace_parent(path, frozen):
            nonlocal replaced
            if not replaced:
                parent.rename(moved)
                parent.mkdir(mode=0o700)
                replaced = True
            return original_read(path, frozen)

        with patch.object(runner, "read_frozen_file", side_effect=replace_parent), \
                self.assertRaisesRegex(RuntimeError, "private.*cleanup uncertain"):
            runner.package_evidence(package, archive_path)
        self.assertEqual(list(parent.iterdir()), [])
        self.assertEqual((moved.stat().st_dev, moved.stat().st_ino), original_identity)
        self.assertEqual(len(list(moved.glob(".evidence.zip.*.tmp"))), 1)

    def test_parent_replacement_after_publication_leaves_original_names_untouched(self) -> None:
        package = self.synthetic_package("late-parent-package")
        parent = self.root / "late-parent"
        parent.mkdir(mode=0o700)
        original_identity = (parent.stat().st_dev, parent.stat().st_ino)
        moved = self.root / "late-parent-moved"
        archive_path = parent / "evidence.zip"
        original_entry = runner._archive_entry
        replaced = False

        def replace_parent_after_link(parent_fd, name, created, expected_links):
            nonlocal replaced
            result = original_entry(parent_fd, name, created, expected_links)
            if name == archive_path.name and not replaced:
                parent.rename(moved)
                parent.mkdir(mode=0o700)
                replaced = True
            return result

        with patch.object(runner, "_archive_entry", side_effect=replace_parent_after_link), \
                self.assertRaisesRegex(RuntimeError, "private.*cleanup uncertain"):
            runner.package_evidence(package, archive_path)
        self.assertEqual((moved.stat().st_dev, moved.stat().st_ino), original_identity)
        self.assertEqual(list(parent.iterdir()), [])
        self.assertTrue((moved / "evidence.zip").is_file())
        self.assertEqual(len(list(moved.glob(".evidence.zip.*.tmp"))), 1)

    def test_final_replacement_survives_failed_validation(self) -> None:
        package = self.synthetic_package("replace-final-package")
        archive_path = self.root / "replace-final.zip"
        saved = self.root / "saved-original-final.zip"
        original_entry = runner._archive_entry
        replacement_identity = None

        def replace_final(parent_fd, name, created, expected_links):
            nonlocal replacement_identity
            if name == archive_path.name:
                archive_path.rename(saved)
                archive_path.write_bytes(b"replacement final")
                replacement_identity = (archive_path.stat().st_dev, archive_path.stat().st_ino)
            return original_entry(parent_fd, name, created, expected_links)

        with patch.object(runner, "_archive_entry", side_effect=replace_final), \
                self.assertRaisesRegex(RuntimeError, "entry changed.*cleanup uncertain.*replaced"):
            runner.package_evidence(package, archive_path)
        self.assertEqual(archive_path.read_bytes(), b"replacement final")
        self.assertEqual((archive_path.stat().st_dev, archive_path.stat().st_ino),
                         replacement_identity)
        self.assertTrue(saved.is_file())
        self.assertEqual(list(self.root.glob(".replace-final.zip.*.tmp")), [])

    def test_cleanup_failure_reports_primary_error_and_keeps_owned_evidence(self) -> None:
        package = self.synthetic_package("cleanup-failure-package")
        archive_path = self.root / "cleanup-failure.zip"
        original_unlink = os.unlink

        def fail_temporary_unlink(path, *args, **kwargs):
            if str(path).startswith(".cleanup-failure.zip."):
                raise OSError("injected cleanup failure")
            return original_unlink(path, *args, **kwargs)

        with patch.object(runner, "read_frozen_file",
                          side_effect=RuntimeError("injected primary write failure")), \
                patch.object(runner.os, "unlink", side_effect=fail_temporary_unlink), \
                self.assertRaisesRegex(RuntimeError,
                                       "primary write failure.*cleanup uncertain.*cleanup failure"):
            runner.package_evidence(package, archive_path)
        temporary, = self.root.glob(".cleanup-failure.zip.*.tmp")
        self.assertEqual(stat.S_IMODE(temporary.stat().st_mode), 0o600)
        self.assertFalse(archive_path.exists())

    def test_cleanup_failure_after_valid_publication_returns_no_receipt(self) -> None:
        package = self.synthetic_package("cleanup-after-publish-package")
        archive_path = self.root / "cleanup-after-publish.zip"
        original_unlink = os.unlink

        def fail_temporary_unlink(path, *args, **kwargs):
            if str(path).startswith(".cleanup-after-publish.zip."):
                raise OSError("injected temporary cleanup failure")
            return original_unlink(path, *args, **kwargs)

        with patch.object(runner.os, "unlink", side_effect=fail_temporary_unlink), \
                self.assertRaisesRegex(RuntimeError,
                                       "cleanup uncertain.*temporary cleanup failure"):
            runner.package_evidence(package, archive_path)
        self.assertFalse(archive_path.exists())
        temporary, = self.root.glob(".cleanup-after-publish.zip.*.tmp")
        self.assertEqual(stat.S_IMODE(temporary.stat().st_mode), 0o600)

    def test_link_that_succeeds_then_reports_failure_leaves_uncertain_final(self) -> None:
        package = self.synthetic_package("uncertain-link-package")
        archive_path = self.root / "uncertain-link.zip"
        original_link = os.link

        def link_then_fail(source, destination, **kwargs):
            original_link(source, destination, **kwargs)
            raise OSError("injected link result failure")

        with patch.object(runner.os, "link", side_effect=link_then_fail), \
                self.assertRaisesRegex(RuntimeError,
                                       "link result failure.*cleanup uncertain.*outcome is unknown"):
            runner.package_evidence(package, archive_path)
        self.assertTrue(archive_path.is_file())
        self.assertEqual(stat.S_IMODE(archive_path.stat().st_mode), 0o600)
        self.assertEqual(list(self.root.glob(".uncertain-link.zip.*.tmp")), [])

    def test_final_replacement_after_temporary_cleanup_blocks_receipt(self) -> None:
        package = self.synthetic_package("after-cleanup-final-package")
        archive_path = self.root / "after-cleanup-final.zip"
        saved = self.root / "saved-after-cleanup-final.zip"
        original_unlink = os.unlink
        replacement_identity = None

        def replace_final_after_unlink(path, *args, **kwargs):
            nonlocal replacement_identity
            result = original_unlink(path, *args, **kwargs)
            if str(path).startswith(".after-cleanup-final.zip."):
                archive_path.rename(saved)
                archive_path.write_bytes(b"replacement after temp cleanup")
                metadata = archive_path.stat()
                replacement_identity = (metadata.st_dev, metadata.st_ino)
            return result

        with patch.object(runner.os, "unlink", side_effect=replace_final_after_unlink), \
                self.assertRaisesRegex(RuntimeError, "entry changed.*cleanup uncertain.*replaced"):
            runner.package_evidence(package, archive_path)
        self.assertEqual(archive_path.read_bytes(), b"replacement after temp cleanup")
        self.assertEqual((archive_path.stat().st_dev, archive_path.stat().st_ino),
                         replacement_identity)
        self.assertTrue(saved.is_file())
        self.assertEqual(list(self.root.glob(".after-cleanup-final.zip.*.tmp")), [])

    def test_parent_replacement_after_temporary_cleanup_blocks_receipt(self) -> None:
        package = self.synthetic_package("after-cleanup-parent-package")
        parent = self.root / "after-cleanup-parent"
        parent.mkdir(mode=0o700)
        original_identity = (parent.stat().st_dev, parent.stat().st_ino)
        moved = self.root / "after-cleanup-parent-moved"
        archive_path = parent / "evidence.zip"
        original_unlink = os.unlink

        def replace_parent_after_unlink(path, *args, **kwargs):
            result = original_unlink(path, *args, **kwargs)
            if str(path).startswith(".evidence.zip."):
                parent.rename(moved)
                parent.mkdir(mode=0o700)
            return result

        with patch.object(runner.os, "unlink", side_effect=replace_parent_after_unlink), \
                self.assertRaisesRegex(RuntimeError, "private.*cleanup uncertain"):
            runner.package_evidence(package, archive_path)
        self.assertEqual((moved.stat().st_dev, moved.stat().st_ino), original_identity)
        self.assertEqual(list(parent.iterdir()), [])
        self.assertTrue((moved / "evidence.zip").is_file())
        self.assertEqual(list(moved.glob(".evidence.zip.*.tmp")), [])

    def test_existing_file_and_dangling_link_destinations_survive(self) -> None:
        package = self.synthetic_package("existing-final-package")
        existing = self.root / "existing-final.zip"
        existing.write_bytes(b"existing evidence")
        dangling = self.root / "dangling-final.zip"
        dangling.symlink_to(self.root / "missing-target")
        for destination in (existing, dangling):
            with self.subTest(destination=destination.name), \
                    self.assertRaisesRegex(ValueError, "new absolute path"):
                runner.package_evidence(package, destination)
        self.assertEqual(existing.read_bytes(), b"existing evidence")
        self.assertTrue(dangling.is_symlink())
        self.assertEqual(list(self.root.glob(".existing-final.zip.*.tmp")), [])
        self.assertEqual(list(self.root.glob(".dangling-final.zip.*.tmp")), [])

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
