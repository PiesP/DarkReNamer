#!/usr/bin/env python3
"""End-to-end checks for public CLI pins and staged module closures."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import tooling_bootstrap
from darkrenamer_tooling.contracts import tooling
from darkrenamer_tooling.evidence.errors import EvidenceError


REPOSITORY = Path(__file__).resolve().parent.parent
MANIFEST = REPOSITORY / "config" / "tooling-bundle.json"
ENTRYPOINTS = {
    "test-windows-vm.py": "vm-launcher",
    "run-gui-regression.py": "vm-gui",
    "run-vm-automated-campaign.py": "campaign-runner",
    "validate-gui-regression-evidence.py": "evidence-gui",
    "validate-vm-automated-evidence.py": "evidence-cli",
    "validate-vm-automated-authority.py": "contracts-authority",
}


class ToolingBundleTests(unittest.TestCase):
    def verified(self, role: str):
        data = MANIFEST.read_bytes()
        return tooling_bootstrap.verify_tooling(
            root=REPOSITORY,
            manifest_location="config/tooling-bundle.json",
            expected_manifest_sha256=hashlib.sha256(data).hexdigest(),
            mode="checkout",
            required_roles=(role,),
        )

    def stage(self, root: Path, name: str, role: str) -> Path:
        tooling.stage_verified_tooling(self.verified(role), root)
        entrypoint = root / name
        shutil.copyfile(REPOSITORY / "scripts" / name, entrypoint)
        return entrypoint

    def staged_record(self, root: Path) -> dict[str, object]:
        self.stage(root, "test-windows-vm.py", "vm-launcher")
        return json.loads((root / tooling.RECORD_NAME).read_bytes())

    def write_record(self, root: Path, record: dict[str, object]) -> None:
        (root / tooling.RECORD_NAME).write_text(
            json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    def test_every_public_cli_runs_from_its_flat_verified_bundle(self) -> None:
        for name, role in ENTRYPOINTS.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                entrypoint = self.stage(root, name, role)
                bundled = subprocess.run(
                    [sys.executable, str(entrypoint), "--help"],
                    check=True, capture_output=True,
                )
                checkout = subprocess.run(
                    [sys.executable, str(REPOSITORY / "scripts" / name), "--help"],
                    check=True, capture_output=True,
                )
                self.assertEqual(bundled.stdout, checkout.stdout)
                self.assertEqual(bundled.stderr, checkout.stderr)
                self.assertIn("tooling-bundle.json", tooling.staged_tooling_files(root))
                self.assertIn("tooling-loader.py", tooling.staged_tooling_files(root))

    def test_public_cli_rejects_tampered_manifest_and_loader_before_import(self) -> None:
        for target in ("tooling-bundle.json", "tooling-loader.py"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                entrypoint = self.stage(root, "test-windows-vm.py", "vm-launcher")
                with (root / target).open("ab") as stream:
                    stream.write(b"\n# tampered\n")
                completed = subprocess.run(
                    [sys.executable, str(entrypoint), "--help"], capture_output=True
                )
                self.assertEqual(completed.returncode, 1)
                self.assertNotIn(b"usage:", completed.stdout)

    def test_staged_reader_rejects_malformed_and_oversized_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.staged_record(root)
            (root / tooling.RECORD_NAME).write_bytes(b"{not-json")
            with self.assertRaisesRegex(EvidenceError, "malformed"):
                tooling.staged_tooling_files(root)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.staged_record(root)
            with mock.patch.object(tooling, "MAX_MANIFEST_BYTES", 32):
                with self.assertRaisesRegex(EvidenceError, "exceeds its bound"):
                    tooling.staged_tooling_files(root)

    def test_staged_reader_rejects_corrupt_and_oversized_modules(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = self.staged_record(root)
            name = record["modules"][0]["file"]
            with (root / name).open("ab") as stream:
                stream.write(b"tampered")
            with self.assertRaisesRegex(EvidenceError, "differs from its record"):
                tooling.staged_tooling_files(root)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = self.staged_record(root)
            row = record["modules"][0]
            row["size"] = 8
            row["sha256"] = hashlib.sha256((root / row["file"]).read_bytes()[:8]).hexdigest()
            record["modules"] = [row]
            self.write_record(root, record)
            with mock.patch.object(tooling, "MAX_MODULE_BYTES", 8):
                with self.assertRaisesRegex(EvidenceError, "exceeds its bound"):
                    tooling.staged_tooling_files(root)

    def test_staged_reader_rejects_nonportable_flat_names(self) -> None:
        unsafe = (
            "folder\\module.py",
            "module.py:stream",
            "CON.py",
            "..",
            "module.py.",
            "MODULE~1.PY",
        )
        for name in unsafe:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                record = self.staged_record(root)
                record["modules"][0]["file"] = name
                self.write_record(root, record)
                with self.assertRaisesRegex(EvidenceError, "filename"):
                    tooling.staged_tooling_files(root)

    def test_staged_reader_rejects_linked_modules(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = self.staged_record(root)
            name = record["modules"][0]["file"]
            path = root / name
            path.unlink()
            path.symlink_to(tooling.MANIFEST_NAME)
            with self.assertRaisesRegex(EvidenceError, "safely read|ordinary file"):
                tooling.staged_tooling_files(root)

    def test_generated_manifest_and_pins_are_current(self) -> None:
        subprocess.run(
            [sys.executable, str(REPOSITORY / "scripts" / "update-tooling-bundle.py"), "--check"],
            cwd=REPOSITORY, check=True,
        )


if __name__ == "__main__":
    unittest.main()
