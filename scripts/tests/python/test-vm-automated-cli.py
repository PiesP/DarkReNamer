#!/usr/bin/env python3
"""Full CLI joins for the indexed private VM campaign evidence."""

from argparse import Namespace
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import hashlib
import io
from pathlib import Path
from tooling_test_paths import REPOSITORY_ROOT
import sys
import tempfile
import unittest
from unittest.mock import patch

from cli_fixture import CliFixture
from darkrenamer_tooling.contracts.binding import COMPONENTS
from darkrenamer_tooling.evidence import cli
from darkrenamer_tooling.evidence.archive import EvidenceError, parse_canonical_statement_bytes


class VmAutomatedCliTests(unittest.TestCase):
    def test_cli_profile_defaults_to_v2_and_rejects_unknown(self):
        self.assertEqual(cli.parser().parse_args([
            '--profile-id', 'vm-automated-v1-win11-ntfs',
            *self._required_cli_args(),
        ]).profile_id, 'vm-automated-v1-win11-ntfs')
        self.assertEqual(cli.parser().parse_args(self._required_cli_args()).profile_id,
                         'vm-automated-v2-owned-resources')
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            cli.parser().parse_args(['--profile-id', 'unknown', *self._required_cli_args()])

    @staticmethod
    def _required_cli_args():
        return [item for name in (
            'archive', 'candidate-handoff-root', 'trusted-source-root', 'gate-metadata',
            'output', 'archive-sha256', 'archive-size', 'candidate-run-id',
            'candidate-run-attempt', 'candidate-artifact-id', 'candidate-source-sha',
            'expected-exe-sha256', 'release-id', 'asset-id', 'validation-run-id',
            'validation-run-attempt',
        ) for item in ('--' + name, 'fixture')]

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

    def test_v2_archive_emits_selected_canonical_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = CliFixture(Path(directory), revision=2)
            statement = parse_canonical_statement_bytes(cli.validate(fixture.args()))
            self.assertEqual(statement["schema"], "darkrenamer-vm-automated-statement-v2")
            self.assertEqual(statement["profile"], {
                "id": fixture.profile["profile_id"], "revision": 2,
                "sha256": hashlib.sha256(fixture.profile_bytes).hexdigest()})
            args = fixture.args()
            args.profile_id = "vm-automated-v1-win11-ntfs"
            with self.assertRaises(EvidenceError):
                cli.validate(args)

            args = fixture.args()
            del args.profile_id
            statement = parse_canonical_statement_bytes(cli.validate(args))
            self.assertEqual(statement['profile']['revision'], 2)

    def test_omitted_profile_rejects_v1_archive_before_extraction(self):
        args = self.fixture.args()
        del args.profile_id
        with patch.object(cli, 'open_indexed_evidence_archive',
                          side_effect=AssertionError('archive extraction was reached')):
            with self.assertRaises(EvidenceError):
                cli.validate(args)

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
