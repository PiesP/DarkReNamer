#!/usr/bin/env python3
"""End-to-end checks for public CLI pins and staged module closures."""

from __future__ import annotations

import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import tooling_bootstrap
from darkrenamer_tooling.contracts.tooling import stage_verified_tooling, staged_tooling_files


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
        stage_verified_tooling(self.verified(role), root)
        entrypoint = root / name
        shutil.copyfile(REPOSITORY / "scripts" / name, entrypoint)
        return entrypoint

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
                self.assertIn("tooling-bundle.json", staged_tooling_files(root))
                self.assertIn("tooling-loader.py", staged_tooling_files(root))

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

    def test_generated_manifest_and_pins_are_current(self) -> None:
        subprocess.run(
            [sys.executable, str(REPOSITORY / "scripts" / "update-tooling-bundle.py"), "--check"],
            cwd=REPOSITORY, check=True,
        )


if __name__ == "__main__":
    unittest.main()
