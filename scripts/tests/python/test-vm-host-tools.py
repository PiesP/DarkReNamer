"""Offline host executable trust and bounded VM child environment tests."""

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from darkrenamer_tooling.vm import connection, host_tools, launcher


class HostToolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=Path.home())
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.marker = self.root / "marker"
        for name in ("pwsh", "wslpath"):
            tool = self.root / name
            tool.write_text("#!/bin/sh\n: > '" + str(self.marker) + "'\n")
            tool.chmod(0o700)

    def test_hostile_path_is_ignored_before_probe_preflight_and_conversion(self):
        environment = {**os.environ, "PATH": str(self.root) + os.pathsep + os.environ["PATH"]}
        environment.pop(host_tools.OVERRIDES["pwsh"], None)
        environment.pop(host_tools.OVERRIDES["wslpath"], None)
        with mock.patch.dict(os.environ, environment, clear=True):
            self.assertEqual(launcher.require_pwsh74(), "/usr/bin/pwsh")
            self.assertEqual(launcher.winpath(Path("/mnt/c")), "C:\\")
            self.assertEqual(host_tools.resolve_tool("wslpath"), "/usr/bin/wslpath")
            remote = {"system": "windows", "os_version": "Windows NT 10.0.26200.0",
                      "build": "26200", "architecture": "X64",
                      "product_caption": "Microsoft Windows 11 Pro",
                      "vm_id": "12345678-1234-5678-9abc-1234567890ab"}
            with mock.patch.object(connection.subprocess, "check_output",
                                   side_effect=["7.4.0\n", json.dumps(remote)]) as run:
                connection.guest_preflight({"ssh_host": "vm-alias", "expected_vm_id": remote["vm_id"]})
                self.assertEqual([call.args[0][0] for call in run.call_args_list],
                                 ["/usr/bin/pwsh", "/usr/bin/pwsh"])
                self.assertEqual(run.call_args.kwargs["env"]["PATH"], "/usr/bin:/bin")
            (self.root / "bundle.json").write_text("{}")
            args = launcher.parse_arguments(["--ssh-host", "vm-alias", "--desktop-mode", "existing",
                                             "--acceptance-profile-id", launcher.V1_PROFILE_ID])
            command = launcher.controller_invocation(self.root, args)
            self.assertEqual(command[0], "/usr/bin/pwsh")
        self.assertFalse(self.marker.exists())

    def test_explicit_trusted_installation_and_symlink_target(self):
        installed = self.root / "installed"
        installed.write_bytes((self.root / "pwsh").read_bytes())
        installed.chmod(0o700)
        link = self.root / "link"
        link.symlink_to(installed)
        self.assertEqual(host_tools.resolve_tool("pwsh", {"DARKRENAMER_PWSH_PATH": str(link)}), str(link))
        self.assertEqual(host_tools.trusted_path(link, executable=True), installed)
        installed.chmod(0o722)
        with self.assertRaisesRegex(RuntimeError, "write permission"):
            host_tools.resolve_tool("pwsh", {"DARKRENAMER_PWSH_PATH": str(link)})
        self.assertFalse(self.marker.exists())

    def test_missing_relative_writable_parent_and_unsafe_symlink_fail_closed(self):
        for selected in (str(self.root / "missing"), "pwsh", ""):
            with self.subTest(selected=selected), self.assertRaises(RuntimeError):
                host_tools.resolve_tool("pwsh", {"DARKRENAMER_PWSH_PATH": selected})
        writable = self.root / "writable"
        writable.mkdir()
        writable.chmod(0o777)
        target = writable / "pwsh"
        target.write_bytes((self.root / "pwsh").read_bytes())
        target.chmod(0o700)
        link = self.root / "unsafe-link"
        link.symlink_to(target)
        for selected in (target, link):
            with self.subTest(selected=selected), self.assertRaisesRegex(RuntimeError, "write permission"):
                host_tools.resolve_tool("pwsh", {"DARKRENAMER_PWSH_PATH": str(selected)})
        self.assertFalse(self.marker.exists())

    def test_non_executable_and_out_of_scope_owner_fail_closed(self):
        target = self.root / "installed"
        target.write_bytes(b"inert")
        target.chmod(0o600)
        with self.assertRaisesRegex(RuntimeError, "executable regular file"):
            host_tools.resolve_tool("pwsh", {"DARKRENAMER_PWSH_PATH": str(target)})
        target.chmod(0o700)
        if os.geteuid() != 0:
            with mock.patch.object(host_tools.os, "geteuid", return_value=os.geteuid() + 1):
                with self.assertRaisesRegex(RuntimeError, "owner"):
                    host_tools.resolve_tool("pwsh", {"DARKRENAMER_PWSH_PATH": str(target)})

    def test_child_environment_keeps_ssh_wsl_inputs_and_drops_injection_inputs(self):
        result = host_tools.child_environment({
            "PATH": str(self.root), "HOME": "/home/tester", "SSH_AUTH_SOCK": "/run/user/1/agent",
            "WSL_INTEROP": "/run/WSL/1_interop", "WSL_DISTRO_NAME": "Ubuntu",
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "LD_PRELOAD": "/tmp/private.so",
            "PSModulePath": str(self.root), "PRIVATE_TOKEN": "private-value",
        }, DARKRENAMER_GUI_SSH_HOST="vm-alias")
        self.assertEqual(result["PATH"], "/usr/bin:/bin")
        self.assertEqual(result["HOME"], "/home/tester")
        self.assertEqual(result["SSH_AUTH_SOCK"], "/run/user/1/agent")
        self.assertEqual(result["WSL_INTEROP"], "/run/WSL/1_interop")
        self.assertEqual(result["DARKRENAMER_GUI_SSH_HOST"], "vm-alias")
        for key in ("PRIVATE_TOKEN", "LD_PRELOAD", "PSModulePath"):
            self.assertNotIn(key, result)

    def test_version_probe_uses_approved_path_and_bounded_environment(self):
        with mock.patch.object(host_tools, "resolve_tool", return_value="/usr/bin/pwsh"), \
                mock.patch.object(host_tools.subprocess, "check_output", return_value="7.3.9\n") as probe:
            with self.assertRaisesRegex(RuntimeError, "7.4 or newer"):
                host_tools.require_pwsh74({"PATH": str(self.root), "SECRET": "private"})
            self.assertEqual(probe.call_args.args[0][0], "/usr/bin/pwsh")
            self.assertEqual(probe.call_args.kwargs["env"]["PATH"], "/usr/bin:/bin")
            self.assertNotIn("SECRET", probe.call_args.kwargs["env"])


if __name__ == "__main__":
    unittest.main()
