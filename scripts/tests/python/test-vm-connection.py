"""Default offline coverage for private VM connection contracts."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from darkrenamer_tooling.vm import connection as runner


class VmConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)


    @staticmethod
    def write_json(path, value):
        path.write_text(json.dumps(value) + "\n")

    def test_private_profile_is_explicit_bounded_and_not_returned_with_its_path(self):
        profile = self.root / "connection.json"
        value = {
            "schema_version": 1,
            "ssh_host": "vm-alias",
            "desktop_helper": "C:\\Private\\desktop-session.ps1",
            "expected_vm_id": "12345678-1234-5678-9abc-1234567890ab",
        }
        self.write_json(profile, value)
        loaded, profile_hash = runner.load_connection_profile(profile)
        self.assertEqual(loaded, value)
        self.assertEqual(profile_hash, runner.digest(profile))
        self.assertNotIn(str(profile), json.dumps(loaded))

        for key, changed in (
            ("extra", {**value, "extra": True}),
            ("alias", {**value, "ssh_host": "user@vm"}),
            ("helper", {**value, "desktop_helper": "relative.ps1"}),
            ("identity", {**value, "expected_vm_id": "not-a-guid"}),
        ):
            invalid = self.root / f"invalid-{key}.json"
            self.write_json(invalid, changed)
            with self.assertRaises(ValueError):
                runner.load_connection_profile(invalid)

    def test_guest_preflight_serializes_strict_document_inside_remote_boundary(self):
        profile = {
            "ssh_host": "vm-alias",
            "expected_vm_id": "12345678-1234-5678-9abc-1234567890ab",
        }
        remote = {
            "system": "windows",
            "os_version": "Microsoft Windows NT 10.0.26200.0",
            "build": "26200",
            "architecture": "X64",
            "product_caption": "Microsoft Windows 11 Pro",
            "vm_id": profile["expected_vm_id"],
        }

        def check_output(command, **keywords):
            script = command[-1]
            remote_boundary = script.index("\n    }\n    [Console]::Out.Write")
            self.assertLess(script.index("| ConvertTo-Json -Compress"), remote_boundary)
            self.assertNotIn("$value | ConvertTo-Json", script)
            self.assertIn("BatchMode='yes';StrictHostKeyChecking='yes';ForwardAgent='no'", script)
            self.assertEqual(keywords["env"]["DARKRENAMER_GUI_SSH_HOST"], "vm-alias")
            return json.dumps(remote, separators=(",", ":"))

        with mock.patch.object(runner.host_tools, "require_pwsh74", return_value="/usr/bin/pwsh"), \
                mock.patch.object(runner.subprocess, "check_output", side_effect=check_output):
            observed = runner.guest_preflight(profile)
        self.assertEqual(observed["system"], "windows")
        self.assertEqual(observed["build"], "26200")
        self.assertEqual(observed["architecture"], "x86_64")
        self.assertEqual(
            observed["vm_identity_sha256"], runner.digest_text(profile["expected_vm_id"])
        )

    def test_guest_preflight_rejects_remoting_metadata(self):
        remote = {
            "system": "windows",
            "os_version": "Microsoft Windows NT 10.0.26200.0",
            "build": "26200",
            "architecture": "X64",
            "product_caption": "Microsoft Windows 11 Pro",
            "vm_id": "12345678-1234-5678-9abc-1234567890ab",
            "PSComputerName": "private-host",
            "RunspaceId": "00000000-0000-0000-0000-000000000000",
            "PSShowComputerName": True,
        }
        with mock.patch.object(runner.host_tools, "require_pwsh74", return_value="/usr/bin/pwsh"), \
                mock.patch.object(runner.subprocess, "check_output", return_value=json.dumps(remote)):
            with self.assertRaisesRegex(ValueError, "invalid document"):
                runner.guest_preflight({
                    "ssh_host": "vm-alias",
                    "expected_vm_id": "12345678-1234-5678-9abc-1234567890ab",
                })

    def test_profile_rejects_symlinks_and_size_overflow(self):
        profile = self.root / "large.json"
        profile.write_bytes(b" " * (16 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, "size bound"):
            runner.load_connection_profile(profile)
        profile.write_text("{}")
        link = self.root / "link.json"
        link.symlink_to(profile)
        with self.assertRaisesRegex(ValueError, "symlink"):
            runner.load_connection_profile(link)

    def test_guest_preflight_rejects_wrong_guest_and_unsupported_windows(self):
        profile = {"ssh_host": "vm-alias", "expected_vm_id": "12345678-1234-5678-9abc-1234567890ab"}
        remote = {"system": "windows", "os_version": "Windows NT", "build": "26200",
                  "architecture": "X64", "product_caption": "Microsoft Windows 11 Pro",
                  "vm_id": profile["expected_vm_id"]}
        for changes, message in (({"architecture": "Arm64"}, "Windows x86_64"),
                                 ({"vm_id": "12345678-1234-5678-9abc-1234567890ac"}, "identity differs"),
                                 ({"product_caption": "Windows 10 Pro"}, "supported Windows 11"),
                                 ({"build": "21999"}, "supported Windows 11"),
                                 ({"build": ""}, "version/build is missing")):
            with self.subTest(changes=changes), mock.patch.object(runner.host_tools, "require_pwsh74", return_value="/usr/bin/pwsh"), \
                    mock.patch.object(runner.subprocess, "check_output", return_value=json.dumps({**remote, **changes})):
                with self.assertRaisesRegex(ValueError, message):
                    runner.guest_preflight(profile)


if __name__ == "__main__":
    unittest.main()
