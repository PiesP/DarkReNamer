#!/usr/bin/env python3
"""Full CLI joins for the indexed private VM campaign evidence."""

from argparse import Namespace
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
from tooling_test_paths import REPOSITORY_ROOT
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZIP_STORED, ZipFile

from darkrenamer_tooling.contracts.binding import COMPONENTS, Candidate
from darkrenamer_tooling.evidence import cli
from darkrenamer_tooling.evidence.archive import EvidenceError, parse_canonical_statement_bytes


def load_script(filename: str, name: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


campaign_test = load_script(
    "test-vm-automated-campaign-verifier.py", "complete_campaign_fixture_for_cli")


def compact(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode()


class CliFixture:
    def __init__(self, root: Path):
        self.root = root
        self.scratch = root / "private-scratch"
        self.handoff_root = root / "candidate-handoff"
        self.trusted_root = root / "trusted-source"
        self.raw_root = root / "raw-campaign"
        self.output_root = root / "public"
        for path in (self.scratch, self.handoff_root, self.trusted_root,
                     self.raw_root, self.output_root):
            path.mkdir()

        source_profile = REPOSITORY_ROOT / "config/vm-automated-v1.json"
        self.profile_bytes = source_profile.read_bytes()
        self.profile = json.loads(self.profile_bytes)
        component_bytes = self._create_trusted_checkout()
        self.source_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=self.trusted_root, text=True).strip()
        self.components = {
            role: hashlib.sha256(component_bytes[role]).hexdigest() for role in COMPONENTS
        }

        self.executable_bytes = b"MZ\x00trusted immutable candidate executable"
        self.executable_sha = hashlib.sha256(self.executable_bytes).hexdigest()
        (self.handoff_root / "DarkReNamer.exe").write_bytes(self.executable_bytes)
        self.handoff = {
            "schema_version": 1, "source_sha": self.source_sha, "workflow_run": 12,
            "executable": {"filename": "DarkReNamer.exe", "sha256": self.executable_sha},
        }
        self.handoff_bytes = compact(self.handoff)
        (self.handoff_root / "release-handoff.json").write_bytes(self.handoff_bytes)
        self.candidate = Candidate(
            self.source_sha, "12", "1", "34", self.executable_sha,
            hashlib.sha256(self.handoff_bytes).hexdigest(),
        )
        self.campaign = campaign_test.CampaignFixture(
            self.raw_root, profile=self.profile,
            profile_sha256=hashlib.sha256(self.profile_bytes).hexdigest(),
            candidate=self.candidate, components=self.components,
        )
        self._add_tooling_evidence()
        self.archive = self.scratch / "evidence.zip"
        self.write_archive(self.archive)
        self.gate_metadata = root / "gate-metadata.json"
        self.gate_metadata.write_bytes(compact(self._gate_facts()))

    def _create_trusted_checkout(self) -> dict[str, bytes]:
        repository = REPOSITORY_ROOT
        (self.trusted_root / "config").mkdir()
        (self.trusted_root / "scripts").mkdir()
        (self.trusted_root / "config/vm-automated-v1.json").write_bytes(self.profile_bytes)
        tooling_manifest = (repository / "config/tooling-bundle.json").read_bytes()
        (self.trusted_root / "config/tooling-bundle.json").write_bytes(tooling_manifest)
        for entry in json.loads(tooling_manifest)["modules"]:
            destination = self.trusted_root / entry["source"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((repository / entry["source"]).read_bytes())
        component_bytes = {}
        for role, filename in COMPONENTS.items():
            data = ("trusted component " + role + "\n").encode()
            (self.trusted_root / "scripts" / filename).write_bytes(data)
            component_bytes[role] = data
        subprocess.run(["git", "init", "-q"], cwd=self.trusted_root, check=True)
        subprocess.run(["git", "config", "user.name", "VM Evidence Test"],
                       cwd=self.trusted_root, check=True)
        subprocess.run(["git", "config", "user.email", "vm-evidence@example.invalid"],
                       cwd=self.trusted_root, check=True)
        subprocess.run(["git", "config", "commit.gpgsign", "false"],
                       cwd=self.trusted_root, check=True)
        subprocess.run(["git", "add", "config", "scripts"], cwd=self.trusted_root, check=True)
        subprocess.run(["git", "commit", "-q", "--no-gpg-sign", "-m", "test fixture"],
                       cwd=self.trusted_root, check=True)
        return component_bytes

    def _add_tooling_evidence(self) -> None:
        manifest = (self.trusted_root / "config/tooling-bundle.json").read_bytes()
        parsed = json.loads(manifest)
        by_role = {entry["role"]: entry for entry in parsed["modules"]}
        selected = set()

        def select(role: str) -> None:
            if role in selected:
                return
            for dependency in by_role[role]["dependencies"]:
                select(dependency)
            selected.add(role)

        select("vm-launcher")
        retained = {"tooling-bundle.json": manifest}
        for entry in parsed["modules"]:
            if entry["role"] in selected:
                retained[entry["bundle"]] = (self.trusted_root / entry["source"]).read_bytes()
        prefixes = {
            str(Path(attempt["bundle"]).parent).replace("\\", "/") + "/"
            for attempt in self.campaign.campaign["attempts"]
        } | {"backend/"}
        for prefix in prefixes:
            for name, data in retained.items():
                reference = self.campaign.add_bytes(prefix + name, data)
                if prefix == "backend/":
                    self.campaign.campaign["backend"]["files"].append({
                        "file": prefix + name,
                        "sha256": reference.sha256,
                        "size": reference.size,
                    })
        self.campaign.add_json("campaign.json", self.campaign.campaign)

    def _gate_facts(self) -> dict:
        def run(identifier: int, path: str, event: str) -> dict:
            return {
                "id": identifier, "run_attempt": 1, "path": path, "event": event,
                "head_branch": "master", "head_sha": self.source_sha,
                "status": "completed", "conclusion": "success", "repository_id": 45,
            }

        def jobs(names: list[str]) -> list[dict]:
            return [{"name": name, "status": "completed", "conclusion": "success"}
                    for name in names]

        return {
            "schema_version": 1,
            "repository": {"full_name": "PiesP/DarkReNamer", "id": 45,
                           "owner": {"login": "PiesP", "id": 56, "type": "User"}},
            "candidate": {
                "run": run(12, ".github/workflows/release.yaml", "workflow_dispatch"),
                "jobs": jobs(["candidate/build-windows"]),
                "artifact_sha256": "d" * 64,
                "artifact": {
                    "id": 34, "name": "DarkReNamer-dry-run-12-1-windows",
                    "digest": "sha256:" + "d" * 64, "size": 1234, "expired": False,
                    "workflow_run": {"id": 12, "head_sha": self.source_sha},
                },
            },
            "ci": {
                "run": run(78, ".github/workflows/ci.yaml", "push"),
                "jobs": jobs(["pr-gate/quality", "pr-gate/unit", "pr-gate/security",
                              "pr-gate/windows"]),
            },
        }

    def write_archive(self, destination: Path, *, campaign: dict | None = None,
                      replacements: dict[str, bytes] | None = None,
                      omitted: set[str] | None = None) -> None:
        overrides = dict(replacements or {})
        omitted = set(omitted or ())
        if campaign is not None:
            overrides["campaign.json"] = compact(campaign)
        pins = {}
        for path, reference in self.campaign.files.items():
            if path in omitted:
                continue
            data = overrides.get(path)
            pins[path] = {
                "sha256": (hashlib.sha256(data).hexdigest() if data is not None else reference.sha256),
                "size": len(data) if data is not None else reference.size,
            }
        index = compact({"schema": "darkrenamer-vm-automated-index-v1", "files": pins})
        with ZipFile(destination, "w", compression=ZIP_STORED, allowZip64=False) as archive:
            archive.writestr("evidence-index.json", index)
            for path in self.campaign.files:
                if path in omitted:
                    continue
                archive.writestr(path, overrides.get(path, (self.raw_root / path).read_bytes()))

    def args(self, archive: Path | None = None, output: Path | None = None) -> Namespace:
        selected = archive or self.archive
        data = selected.read_bytes()
        return Namespace(
            archive=selected,
            archive_sha256=hashlib.sha256(data).hexdigest(), archive_size=str(len(data)),
            candidate_handoff_root=self.handoff_root, trusted_source_root=self.trusted_root,
            gate_metadata=self.gate_metadata, output=output or self.output_root / "statement.json",
            candidate_run_id="12", candidate_run_attempt="1", candidate_artifact_id="34",
            candidate_source_sha=self.source_sha, expected_exe_sha256=self.executable_sha,
            release_id="37", asset_id="41", validation_run_id="90",
            validation_run_attempt="1",
        )


class VmAutomatedCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.fixture = CliFixture(Path(cls.temporary.name))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_main(self, args: Namespace) -> int:
        argv = ["validate-vm-automated-evidence.py"]
        for name, value in vars(args).items():
            argv.extend(["--" + name.replace("_", "-"), str(value)])
        with patch.object(sys, "argv", argv), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return cli.main(REPOSITORY_ROOT)

    def test_validate_and_main_emit_one_canonical_path_free_statement(self):
        direct = cli.validate(self.fixture.args())
        statement = parse_canonical_statement_bytes(direct)
        self.assertEqual(statement["result"], "passed")
        self.assertEqual(len(statement["targets"]), 22)
        self.assertEqual(len(statement["required_gates"]), 5)
        self.assertEqual({row["role"] for row in statement["harness"]["components"]},
                         set(COMPONENTS))
        self.assertEqual(statement["candidate"]["source_sha"], self.fixture.source_sha)
        self.assertEqual(statement["ingress"]["sha256"],
                         hashlib.sha256(self.fixture.archive.read_bytes()).hexdigest())
        self.assertEqual(statement["validation"], {"run_id": 90, "run_attempt": 1})
        self.assertNotIn(str(self.fixture.root), direct.decode())

        output = self.fixture.output_root / "created-statement.json"
        self.assertEqual(self.run_main(self.fixture.args(output=output)), 0)
        self.assertEqual(output.read_bytes(), direct)
        self.assertFalse(any(path.name.startswith(".darkrenamer-vm-evidence-")
                             for path in self.fixture.scratch.iterdir()))

    def test_archive_hash_or_size_mismatch_fails_closed(self):
        for field, value in (("archive_sha256", "0" * 64),
                             ("archive_size", str(self.fixture.archive.stat().st_size + 1))):
            args = self.fixture.args()
            setattr(args, field, value)
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                cli.validate(args)

    def test_wrong_trusted_source_or_candidate_fails(self):
        for field, value in (("candidate_source_sha", "f" * 40), ("candidate_run_id", "13")):
            args = self.fixture.args()
            setattr(args, field, value)
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                cli.validate(args)

    def test_omitted_or_tampered_retained_tooling_fails_source_binding(self):
        module = next(
            path for path in self.fixture.campaign.files
            if path.endswith("/tooling-vm-launcher.py")
        )
        for mode in ("omitted", "tampered"):
            archive = self.fixture.scratch / (mode + "-tooling.zip")
            options = ({"omitted": {module}} if mode == "omitted" else
                       {"replacements": {module: b"TOOLING_EXECUTED = True\n"}})
            self.fixture.write_archive(archive, **options)
            with self.subTest(mode=mode), self.assertRaises(EvidenceError):
                cli.validate(self.fixture.args(archive=archive))

    def test_incomplete_campaign_fails_and_main_removes_private_extraction(self):
        incomplete = deepcopy(self.fixture.campaign.campaign)
        incomplete["attempts"].pop()
        archive = self.fixture.scratch / "incomplete.zip"
        self.fixture.write_archive(archive, campaign=incomplete)
        output = self.fixture.output_root / "incomplete-statement.json"
        self.assertEqual(self.run_main(self.fixture.args(archive, output)), 1)
        self.assertFalse(output.exists())
        self.assertFalse(any(path.name.startswith(".darkrenamer-vm-evidence-")
                             for path in self.fixture.scratch.iterdir()))

    def test_existing_output_is_preserved(self):
        output = self.fixture.output_root / "existing-statement.json"
        output.write_bytes(b"sentinel")
        self.assertEqual(self.run_main(self.fixture.args(output=output)), 1)
        self.assertEqual(output.read_bytes(), b"sentinel")


if __name__ == "__main__":
    unittest.main()
