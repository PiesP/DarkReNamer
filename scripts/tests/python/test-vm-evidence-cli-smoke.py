#!/usr/bin/env python3
"""Run the authenticated evidence CLI with portable success/failure fixtures."""

from copy import deepcopy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tooling_test_paths import REPOSITORY_ROOT
from cli_fixture import CliFixture
from darkrenamer_tooling.evidence.archive import parse_canonical_statement_bytes


class EvidenceCliSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Exercise argument and Git path handling on the hosted Windows path too.
        cls.temporary = tempfile.TemporaryDirectory(prefix="darkrenamer cli 한글 ")
        cls.fixture = CliFixture(Path(cls.temporary.name))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def invoke(self, args):
        command = [sys.executable, "-I", str(
            REPOSITORY_ROOT / "scripts/validate-vm-automated-evidence.py")]
        for name, value in vars(args).items():
            command.extend(["--" + name.replace("_", "-"), str(value)])
        return subprocess.run(
            command, cwd=self.fixture.root, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=90, check=False,
        )

    def assert_extraction_removed(self):
        self.assertFalse(any(
            path.name.startswith(".darkrenamer-vm-evidence-")
            for path in self.fixture.scratch.iterdir()
        ))

    def test_public_cli_creates_bound_canonical_statement(self):
        output = self.fixture.output_root / "cli-success.json"
        result = self.invoke(self.fixture.args(output=output))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = output.read_bytes()
        statement = parse_canonical_statement_bytes(data)
        self.assertEqual(statement["result"], "passed")
        self.assertEqual(statement["candidate"]["source_sha"], self.fixture.source_sha)
        self.assertEqual(statement["candidate"]["executable_sha256"],
                         self.fixture.executable_sha)
        self.assertEqual({row["id"] for row in statement["targets"]},
                         {row["id"] for row in self.fixture.profile["required_targets"]})
        self.assertNotIn(str(self.fixture.root), data.decode("utf-8"))
        self.assert_extraction_removed()

    def test_public_cli_rejects_incomplete_campaign_without_statement(self):
        incomplete = deepcopy(self.fixture.campaign.campaign)
        incomplete["attempts"].pop()
        archive = self.fixture.scratch / "incomplete-cli.zip"
        self.fixture.write_archive(archive, campaign=incomplete)
        output = self.fixture.output_root / "cli-rejected.json"
        result = self.invoke(self.fixture.args(archive=archive, output=output))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(output.exists())
        self.assertTrue(result.stderr.strip())
        self.assert_extraction_removed()


if __name__ == "__main__":
    unittest.main()
