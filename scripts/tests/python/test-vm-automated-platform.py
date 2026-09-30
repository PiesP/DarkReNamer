#!/usr/bin/env python3
"""Negative environment/input/cleanup facts cannot pass a required VM cell."""

import base64
from copy import deepcopy
from datetime import datetime
import hashlib
import unittest

from darkrenamer_tooling.contracts.platform import (
    verify_cleanup, verify_controller_cleanup, verify_controller_owned_cleanup, verify_environment,
    verify_keyboard_events,
)
from darkrenamer_tooling.evidence.archive import EvidenceError
from controller_cleanup_fixture import V2_PROFILE_SHA256, clean_controller_cleanup_v2


class PlatformTests(unittest.TestCase):
    def setUp(self):
        self.target = {"hwnd_dpi": 96, "text_scale_percent": 100, "contrast": "normal",
                       "desktop_width": 800, "desktop_height": 600}
        self.environment = {
            "schema_version": 1,
            "platform": {"os_product_name": "Windows 10 Pro", "display_version": "25H2",
                         "build_number": 26200, "architecture": "x86_64", "product_type": 1},
            "process": {"pid": 1234, "session_id": 2, "is_elevated": False},
            "desktop": {"input_desktop_active": True, "locked": False},
            "fixture_volume": {"filesystem": "NTFS", "root_path": r"C:\fixture",
                               "root_identity": {"volume_serial": "1" * 16, "file_id": "2" * 32}},
            "target_display": {"hwnd": 12, "process_id": 1234, "session_id": 2, "dpi_x": 96, "dpi_y": 96,
                               "text_scale_percent": 100, "high_contrast_flags": 0,
                               "monitor_rect": {"left": 0, "top": 0, "right": 800, "bottom": 600},
                               "work_rect": {"left": 0, "top": 0, "right": 800, "bottom": 560},
                               "window_rect": {"left": 0, "top": 0, "right": 790, "bottom": 550}},
        }

    def verify(self, value=None, target=None):
        verify_environment(self.environment if value is None else value,
                           self.target if target is None else target, candidate_pid=1234, session_id=2)

    def test_actual_build_allows_legacy_productname_but_not_windows10_build(self):
        self.verify()
        self.environment["platform"]["build_number"] = 19045
        with self.assertRaises(EvidenceError):
            self.verify()

    def test_server_build_cannot_satisfy_client_profile(self):
        self.environment["platform"].update(os_product_name="Windows Server 2025", build_number=26100, product_type=3)
        with self.assertRaises(EvidenceError):
            self.verify()

    def test_fixture_root_requires_canonical_local_directory(self):
        for path in ("xxx", "C:relative", "C:\\", "C:\\foo\\", "C:\\a\\..\\b", "C:\\a.\\b", "C:\\NUL", "\\\\host\\share", "\\\\.\\C:\\a"):
            self.environment["fixture_volume"]["root_path"] = path
            with self.subTest(path=path), self.assertRaises(EvidenceError):
                self.verify()
        self.environment["fixture_volume"]["root_path"] = "\\\\?\\C:\\fixture"
        self.verify()

    def test_requested_dpi_or_monitor_size_cannot_replace_actual_cell(self):
        for field, value in (("dpi_x", 192), ("dpi_y", 192), ("text_scale_percent", 150)):
            changed = deepcopy(self.environment)
            changed["target_display"][field] = value
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                self.verify(changed)
        self.environment["target_display"]["monitor_rect"]["right"] = 3840
        with self.assertRaises(EvidenceError):
            self.verify()

    def test_elevated_foreign_process_locked_desktop_or_wrong_filesystem_fails(self):
        mutations = (("process", "is_elevated", True), ("process", "pid", 99),
                     ("process", "session_id", 3), ("desktop", "locked", True),
                     ("desktop", "input_desktop_active", False), ("fixture_volume", "filesystem", "ReFS"))
        for section, field, value in mutations:
            changed = deepcopy(self.environment)
            changed[section][field] = value
            with self.subTest(section=section, field=field), self.assertRaises(EvidenceError):
                self.verify(changed)

    def test_observed_hc_flag_and_text_scale_must_match(self):
        target = {**self.target, "contrast": "high-contrast", "text_scale_percent": 150}
        with self.assertRaises(EvidenceError):
            self.verify(target=target)
        self.environment["target_display"].update(high_contrast_flags=1, text_scale_percent=150)
        self.verify(target=target)

    def test_boolean_coordinates_and_unknown_fields_fail(self):
        self.environment["target_display"]["work_rect"]["left"] = False
        with self.assertRaises(EvidenceError):
            self.verify()
        self.environment["target_display"]["work_rect"]["left"] = 0
        self.environment["passed"] = True
        with self.assertRaises(EvidenceError):
            self.verify()

    def clean(self):
        return ({"owned_processes_after": [], "runtime_root_after": {"exists": False, "entries": []},
                 "journal_after": {"entries": []}},
                {"scheduled_task_present": False, "guest_root_present": False,
                 "trusted_task_root_present": False, "process_jobs_closed": True,
                 "runner_process_inventory_complete": True,
                 "unexpected_runner_tasks": [], "unexpected_runner_processes": [],
                 "unexpected_runner_tasks_after_intervention": [],
                 "unexpected_runner_processes_after_intervention": [],
                 "unexpected_runner_tasks_after_delete": [],
                 "unexpected_runner_processes_after_delete": [],
                 "removed_runner_tasks": [], "terminated_runner_processes": [],
                 "resource_cleanup_errors": [], "runner_process_natural_exit": self.not_required_smart_screen(),
                 "owned_processes_after": []})

    @staticmethod
    def not_required_smart_screen():
        return {"schema_version": 2, "status": "not-required",
                "process_class": None, "native_exit": None, "initial_native_observations": [],
                "runner_sid": "S-1-5-21-1000-1000-1000-1001", "runner_session_id": 2,
                "candidate_identity": None, "broker": None, "timeout_ms": 0,
                "elapsed_ms": 0, "polls": [], "natural_exit_observed": False,
                "final_inventory_complete": True,
                "final_runner_process_delta_identities": [],
                "final_runner_task_delta_identities": []}

    @staticmethod
    def natural_exit_smart_screen():
        identity = "9008|2026-09-27T18:34:27.0489960Z"
        directory = r"C:\Windows"
        process_path = directory + r"\System32\smartscreen.exe"
        parent_path = directory + r"\System32\svchost.exe"
        broker = {
            "windows_directory": directory,
            "process_identity": identity,
            "process_pid": 9008,
            "process_creation_time_utc": "2026-09-27T18:34:27.0489960Z",
            "process_session_id": 2,
            "process_owner_sid": "S-1-5-21-1000-1000-1000-1001",
            "process_executable_path": process_path,
            "process_path_verified": True,
            "process_command_line_arguments": [process_path, "-Embedding"],
            "process_signature_status": "Valid",
            "process_signer_subject": "CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US",
            "process_signer_thumbprint": "A" * 40,
            "parent_identity": "1000|2026-09-27T18:00:00.0000000Z",
            "parent_pid": 1000,
            "parent_creation_time_utc": "2026-09-27T18:00:00.0000000Z",
            "parent_session_id": 0,
            "parent_owner_sid": "S-1-5-18",
            "parent_executable_path": parent_path,
            "parent_path_verified": True,
            "parent_command_line_arguments": [parent_path, "-k", "DcomLaunch", "-p"],
            "parent_signature_status": "Valid",
            "parent_signer_subject": "CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US",
            "parent_signer_thumbprint": "B" * 40,
            "service_name": "DcomLaunch",
            "service_process_id": 1000,
            "service_state": "Running",
        }
        return {
            "schema_version": 2, "status": "natural-exit",
            "process_class": "smart-screen", "native_exit": None, "initial_native_observations": [],
            "runner_sid": "S-1-5-21-1000-1000-1000-1001", "runner_session_id": 2,
            "candidate_identity": identity, "broker": broker,
            "timeout_ms": 360000, "elapsed_ms": 81,
            "polls": [
                {"elapsed_ms": 0, "inventory_complete": True,
                 "process_delta_identities": [identity], "task_delta_identities": [],
                 "owned_root_process_count": 0},
                {"elapsed_ms": 81, "inventory_complete": True,
                 "process_delta_identities": [], "task_delta_identities": [],
                 "owned_root_process_count": 0},
            ],
            "natural_exit_observed": True, "final_inventory_complete": True,
            "final_runner_process_delta_identities": [],
            "final_runner_task_delta_identities": [],
        }

    @staticmethod
    def filetime(stamp):
        whole, fraction = stamp[:-1].split(".")
        elapsed = datetime.fromisoformat(whole) - datetime(1601, 1, 1)
        return (elapsed.days * 86400 + elapsed.seconds) * 10_000_000 + int(fraction)

    @staticmethod
    def replace_manifest(proof, data):
        manifest = proof["broker"]["manifest"]
        manifest.update(byte_length=len(data), sha256=hashlib.sha256(data).hexdigest(),
                        data_base64=base64.b64encode(data).decode("ascii"))

    def spotlight(self):
        guest, host = self.clean()
        proof = self.natural_exit_smart_screen()
        proof["process_class"] = "desktop-spotlight"
        broker = proof["broker"]
        path = r"C:\Windows\System32\backgroundTaskHost.exe"
        broker.update(process_executable_path=path, process_command_line_arguments=[
            path, "-ServerName:Global.DesktopSpotlight.AppXz2j21w56bgxkgsjhtn7zkjsepq96erz2.mca"])
        full_name = "MicrosoftWindows.Client.CBS_1000.26100.372.0_x64__cw5n1h2txyewy"
        family = "MicrosoftWindows.Client.CBS_cw5n1h2txyewy"
        package_path = r"C:\Windows\SystemApps" + "\\" + family
        created = self.filetime(broker["process_creation_time_utc"]) + 7

        def native(pid, stamp, owner, session, image):
            return {"pid": pid, "creation_filetime_100ns": str(stamp), "owner_sid": owner,
                    "session_id": session, "image_path": image, "open_error": 0, "pid_error": 0,
                    "times_error": 0, "image_error": 0, "token_error": 0,
                    "token_sid_error": 0, "token_session_error": 0}

        child = native(9008, created, proof["runner_sid"], 2, path)
        child.update(package_first_status=122, package_status=0, aumid_first_status=122,
                     aumid_status=0, package_full_name=full_name,
                     aumid=family + "!Global.DesktopSpotlight")
        broker["native_identity"] = child
        broker["parent_native_identity"] = native(
            1000, self.filetime(broker["parent_creation_time_utc"]) + 3,
            "S-1-5-18", 0, broker["parent_executable_path"])
        package = {"name": "MicrosoftWindows.Client.CBS", "package_full_name": full_name,
                   "package_family_name": family, "publisher": broker["process_signer_subject"],
                   "publisher_id": "cw5n1h2txyewy", "version": "1000.26100.372.0",
                   "architecture": "x64", "resource_id": ""}
        broker["registration"] = {
            "preflight": {**package, "runner_sid": proof["runner_sid"],
                          "install_location": package_path, "signature_kind": "System", "status": "Ok",
                          "is_development_mode": False,
                          "child_lifecycle": {"pid": 2222, "start_time_utc_ticks": str(
                              self.filetime("2026-09-27T17:00:00.0000000Z") + 504_911_232_000_000_000),
                              "exit_code": 0, "exited": True, "streams_complete": True,
                              "exact_lifetime_absent": True, "process_job_closed": True}},
            "current": {**package, "resource_id": None, "caller_sid": proof["runner_sid"], "path": package_path,
                        "open_status": 0, "first_status": 122, "second_status": 0, "close_status": 0,
                        "required_bytes": 512, "returned_bytes": 512, "count": 1,
                        "request_flags": 0x110, "property_flags": 0},
        }
        declarations = "".join(
            f'<Extension Category="windows.backgroundTasks" EntryPoint="DesktopSpotlight.BackgroundTask.{entry}">'
            f'<BackgroundTasks><Task Type="{kind}"/></BackgroundTasks></Extension>'
            for entry, kind in (("UpdateTimer", "timer"), ("RegistrationStatusCheck", "systemEvent"),
                                ("OnlineIdChange", "systemEvent"), ("Maintenance", "systemEvent")))
        data = (
            '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" '
            'xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" '
            'xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3">'
            '<Identity Name="MicrosoftWindows.Client.CBS" '
            f'Publisher="{package["publisher"]}" Version="1000.26100.372.0" ProcessorArchitecture="x64"/>'
            '<Applications><Application Id="Global.DesktopSpotlight"><Extensions>' + declarations +
            '<uap:Extension Category="windows.appService" EntryPoint="DesktopSpotlight.BackgroundTask.AppService">'
            '<uap3:AppService Name="com.microsoft.desktopspotlight"/></uap:Extension>'
            '</Extensions></Application></Applications></Package>').encode()
        manifest_path = package_path + r"\AppxManifest.xml"
        objects = [{"path": object_path, "is_directory": index < 4,
                    "attributes": 16 if index < 4 else 32, "owner_sid": "S-1-5-18",
                    "dacl_present": True, "aces": [
                        {"ace_type": 0, "ace_flags": 0, "access_mask": 0x1F01FF, "sid": "S-1-5-18"},
                        {"ace_type": 9, "ace_flags": 0, "access_mask": 0x1200A9, "sid": "S-1-5-32-545"},
                    ]} for index, object_path in enumerate([
                        "C:\\", r"C:\Windows", r"C:\Windows\SystemApps", package_path, manifest_path])]
        objects[0]["aces"].extend([
            {"ace_type": 0, "ace_flags": 0, "access_mask": 4, "sid": "S-1-5-11"},
            {"ace_type": 0, "ace_flags": 8, "access_mask": 0x10000000, "sid": "S-1-5-11"}])
        broker["manifest"] = {"path": manifest_path, "path_objects": objects}
        self.replace_manifest(proof, data)
        proof["native_exit"] = {"pid": 9008, "creation_filetime_100ns": str(created),
                                "exit_filetime_100ns": str(created + 10_000_000), "wait_result": 0,
                                "times_succeeded": True, "times_win32_error": 0,
                                "exit_code_succeeded": True, "exit_code_win32_error": 0,
                                "exit_code": 1, "handle_closed": True, "close_win32_error": 0}
        initial = {"identity": proof["candidate_identity"], "pid": 9008, "session_id": 2,
                   "creation_time_utc": broker["process_creation_time_utc"], "executable_path": path}
        proof["initial_native_observations"] = [
            {"attempt": 1, "cim_row": deepcopy(initial), "native_identity": deepcopy(child), "capture_error": None}]
        host["unexpected_runner_processes"] = [initial]
        host["runner_process_natural_exit"] = proof
        return guest, host

    def test_spotlight_requires_same_handle_identity_exit_and_sticky_initial_capture(self):
        guest, host = self.spotlight()
        verify_cleanup(guest, host)
        mutations = (
            ("unknown class", lambda p: p.update(process_class="background-host")),
            ("missing exit", lambda p: p.update(native_exit=None)),
            ("no initial capture", lambda p: p.update(initial_native_observations=[])),
            ("two captures", lambda p: p["initial_native_observations"].append(deepcopy(p["initial_native_observations"][0]))),
            ("capture failure", lambda p: p["initial_native_observations"][0].update(capture_error={"error_type": "Error", "hresult": -1})),
            ("foreign capture", lambda p: p["initial_native_observations"][0]["native_identity"].update(pid=9009)),
            ("native token", lambda p: p["broker"]["native_identity"].update(owner_sid="S-1-5-18")),
            ("native session", lambda p: p["broker"]["native_identity"].update(session_id=True)),
            ("open failed", lambda p: p["broker"]["native_identity"].update(open_error=5)),
            ("package absent", lambda p: p["broker"]["native_identity"].update(package_status=15700)),
            ("wrong application", lambda p: p["broker"]["native_identity"].update(aumid="MicrosoftWindows.Client.CBS_cw5n1h2txyewy!Other")),
            ("server alias", lambda p: p["broker"]["process_command_line_arguments"].__setitem__(1, "-ServerName:Global.DesktopSpotlight")),
            ("foreign native parent", lambda p: p["broker"]["parent_native_identity"].update(pid=1001)),
            ("reopened exit lifetime", lambda p: p["native_exit"].update(creation_filetime_100ns=str(int(p["native_exit"]["creation_filetime_100ns"]) + 1))),
            ("exit before creation", lambda p: p["native_exit"].update(exit_filetime_100ns="1")),
            ("wait timeout", lambda p: p["native_exit"].update(wait_result=258)),
            ("times failed", lambda p: p["native_exit"].update(times_succeeded=False)),
            ("exit-code failed", lambda p: p["native_exit"].update(exit_code_win32_error=5)),
            ("boolean exit-code", lambda p: p["native_exit"].update(exit_code=True)),
            ("live handle", lambda p: p["native_exit"].update(handle_closed=False)),
            ("close failed", lambda p: p["native_exit"].update(close_win32_error=6)),
            ("poll after receipt", lambda p: p["polls"][-1].update(elapsed_ms=p["elapsed_ms"] + 1)),
            ("final survivor", lambda p: p["final_runner_process_delta_identities"].append(p["candidate_identity"])),
        )
        for label, mutate in mutations:
            guest, host = self.spotlight()
            mutate(host["runner_process_natural_exit"])
            with self.subTest(label=label), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)

    def test_native_time_normalization_retains_exact_submicrosecond_exit_lifetime(self):
        for fraction in range(10):
            guest, host = self.spotlight()
            proof = host["runner_process_natural_exit"]
            native = proof["broker"]["native_identity"]
            native["creation_filetime_100ns"] = str(self.filetime(proof["broker"]["process_creation_time_utc"]) + fraction)
            proof["initial_native_observations"][0]["native_identity"] = deepcopy(native)
            proof["native_exit"]["creation_filetime_100ns"] = native["creation_filetime_100ns"]
            with self.subTest(fraction=fraction):
                verify_cleanup(guest, host)
        for value in (True, 134_350_940_670_489_967, "0134350940670489967", "-1",
                      "0", "18446744073709551615", "2650467744000000000"):
            guest, host = self.spotlight()
            host["runner_process_natural_exit"]["broker"]["native_identity"]["creation_filetime_100ns"] = value
            with self.subTest(value=value), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)
        guest, host = self.spotlight()
        proof = host["runner_process_natural_exit"]
        proof["broker"]["native_identity"]["creation_filetime_100ns"] = str(
            self.filetime(proof["broker"]["process_creation_time_utc"]) + 10)
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)

    def test_spotlight_registration_rejects_unsigned_development_foreign_or_incomplete_queries(self):
        cases = (
            ("preflight", "signature_kind", "Developer"), ("preflight", "status", "Modified"),
            ("preflight", "is_development_mode", True), ("preflight", "runner_sid", "S-1-5-18"),
            ("preflight", "install_location", r"C:\Users\TestUser\SystemApps"),
            ("preflight", "version", "1000.26100.65536.0"),
            ("current", "open_status", 1168), ("current", "first_status", 0),
            ("current", "second_status", 122), ("current", "close_status", 5),
            ("current", "caller_sid", "S-1-5-18"), ("current", "count", 2),
            ("current", "request_flags", 0x10), ("current", "returned_bytes", 513),
            ("current", "required_bytes", 65537), ("current", "publisher", "CN=Other"),
            ("current", "resource_id", ""), ("current", "resource_id", "resources"),
        ) + tuple(("current", "property_flags", flag) for flag in (1, 2, 4, 8, 0x10000))
        for section, field, value in cases:
            guest, host = self.spotlight()
            registration = host["runner_process_natural_exit"]["broker"]["registration"]
            registration[section][field] = value
            with self.subTest(section=section, field=field, value=value), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)
        for field in ("exited", "streams_complete", "exact_lifetime_absent", "process_job_closed"):
            guest, host = self.spotlight()
            host["runner_process_natural_exit"]["broker"]["registration"]["preflight"]["child_lifecycle"][field] = False
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)

    def test_spotlight_raw_manifest_rejects_hash_tampering_and_semantic_substitution(self):
        guest, host = self.spotlight()
        proof = host["runner_process_natural_exit"]
        original = base64.b64decode(proof["broker"]["manifest"]["data_base64"])
        replacements = (
            original.replace(b'Name="MicrosoftWindows.Client.CBS"', b'Name="Other"'),
            original.replace(b'Id="Global.DesktopSpotlight"', b'Id="Other"'),
            original.replace(b'Global.DesktopSpotlight', b'Global.DesktopSpotlightOther'),
            original.replace(b'Version="1000.26100.372.0"', b'Version="1000.26100.373.0"'),
            original.replace(b'foundation/windows10', b'foundation/other'),
            original.replace(b'Type="timer"', b'Type="systemEvent"'),
            original.replace(b'com.microsoft.desktopspotlight', b'com.microsoft.other'),
            original.replace(b'<Applications>', b'<Applications><Application Id="Global.DesktopSpotlight"/>'),
            original.replace(b'<BackgroundTasks>', b'<BackgroundTasks ServerName="fake">'),
            b'<!DOCTYPE Package [<!ENTITY injected "other">]>' + original,
            original[:-1],
        )
        for data in replacements:
            guest, host = self.spotlight()
            self.replace_manifest(host["runner_process_natural_exit"], data)
            with self.subTest(data=data[:50]), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)
        for field, value in (("sha256", "0" * 64), ("byte_length", 1),
                             ("data_base64", "!"), ("byte_length", 1048577)):
            guest, host = self.spotlight()
            host["runner_process_natural_exit"]["broker"]["manifest"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)

    def test_spotlight_acl_rejects_reparse_null_dacl_and_untrusted_replacement_grants(self):
        for index, mask in ((0, 2), (0, 0x40), (0, 0x40000), (1, 4), (2, 0x10),
                            (3, 0x100), (4, 2), (4, 0x10000), (4, 0x80000),
                            (4, 0x10000000), (4, 0x40000000)):
            guest, host = self.spotlight()
            objects = host["runner_process_natural_exit"]["broker"]["manifest"]["path_objects"]
            objects[index]["aces"].append({"ace_type": 9, "ace_flags": 0,
                                           "access_mask": mask, "sid": "S-1-5-11"})
            with self.subTest(index=index, mask=mask), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)
        for field, value in (("owner_sid", "S-1-5-11"), ("dacl_present", False),
                             ("aces", []), ("attributes", 0x410), ("is_directory", False),
                             ("path", r"C:\Windows\SystemApps\..")):
            guest, host = self.spotlight()
            objects = host["runner_process_natural_exit"]["broker"]["manifest"]["path_objects"]
            objects[3][field] = value
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)
        guest, host = self.spotlight()
        objects = host["runner_process_natural_exit"]["broker"]["manifest"]["path_objects"]
        objects[0]["aces"][-1]["ace_flags"] = 0
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)

    def test_spotlight_five_path_inventory_cannot_omit_a_nested_windows_ancestor(self):
        def relocate(value):
            if type(value) is str and value.startswith(r"C:\Windows"):
                return r"C:\Parent\Windows" + value[len(r"C:\Windows"):]
            if type(value) is list:
                return [relocate(item) for item in value]
            if type(value) is dict:
                return {key: relocate(item) for key, item in value.items()}
            return value

        guest, host = self.spotlight()
        nested = relocate(host)
        paths = nested["runner_process_natural_exit"]["broker"]["manifest"]["path_objects"]
        self.assertEqual(len(paths), 5)
        self.assertNotIn(r"C:\Parent", [row["path"] for row in paths])
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, nested)

        # The new path constraint belongs only to the package manifest contract.
        guest, host = self.clean()
        proof = self.natural_exit_smart_screen()
        host["runner_process_natural_exit"] = proof
        host["unexpected_runner_processes"] = [{
            "identity": proof["candidate_identity"], "pid": 9008, "session_id": 2,
            "creation_time_utc": proof["broker"]["process_creation_time_utc"],
            "executable_path": proof["broker"]["process_executable_path"],
        }]
        verify_cleanup(guest, relocate(host))

    def test_process_classes_cannot_mix_optional_proofs_or_accept_multiple_initial_processes(self):
        guest, host = self.spotlight()
        host["unexpected_runner_processes"].append(deepcopy(host["unexpected_runner_processes"][0]))
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)
        for field, value in (("process_class", "smart-screen"), ("native_exit", {}),
                             ("initial_native_observations", [{}])):
            guest, host = self.clean()
            host["runner_process_natural_exit"][field] = value
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)

    def test_spotlight_does_not_pin_package_version_or_infer_failure_from_exit_code(self):
        for version, exit_code in (("1.0.0.0", 259), ("65535.65535.65535.65535", 0xFFFFFFFF)):
            guest, host = self.spotlight()
            proof = host["runner_process_natural_exit"]
            broker = proof["broker"]
            data = base64.b64decode(broker["manifest"]["data_base64"])
            self.replace_manifest(proof, data.replace(b"1000.26100.372.0", version.encode()))
            full_name = f"MicrosoftWindows.Client.CBS_{version}_x64__cw5n1h2txyewy"
            broker["native_identity"]["package_full_name"] = full_name
            proof["initial_native_observations"][0]["native_identity"]["package_full_name"] = full_name
            for registration in broker["registration"].values():
                registration.update(version=version, package_full_name=full_name)
            proof["native_exit"]["exit_code"] = exit_code
            with self.subTest(version=version, exit_code=exit_code):
                verify_cleanup(guest, host)

    def test_closed_schema_and_acl_types_cannot_hide_extra_or_unsupported_evidence(self):
        for section in ("root", "native", "registration", "manifest", "path", "ace", "exit"):
            guest, host = self.spotlight()
            proof = host["runner_process_natural_exit"]
            broker = proof["broker"]
            rows = {"root": proof, "native": broker["native_identity"],
                    "registration": broker["registration"]["current"], "manifest": broker["manifest"],
                    "path": broker["manifest"]["path_objects"][4],
                    "ace": broker["manifest"]["path_objects"][4]["aces"][0], "exit": proof["native_exit"]}
            rows[section]["unverified"] = True
            with self.subTest(section=section), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)
        for kind in (True, 2, 5, 11):
            guest, host = self.spotlight()
            host["runner_process_natural_exit"]["broker"]["manifest"]["path_objects"][4]["aces"][1]["ace_type"] = kind
            with self.subTest(kind=kind), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)
        guest, host = self.spotlight()
        aces = host["runner_process_natural_exit"]["broker"]["manifest"]["path_objects"][4]["aces"]
        aces.extend([{"ace_type": 1, "ace_flags": 0, "access_mask": 2, "sid": "S-1-5-11"},
                     {"ace_type": 0, "ace_flags": 0, "access_mask": 2, "sid": "S-1-5-11"}])
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)
        guest, host = self.clean()
        host["smart_screen_natural_exit"] = host.pop("runner_process_natural_exit")
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)

    def test_owned_cleanup_does_not_reclassify_environment_failure(self):
        guest, host = self.clean()
        delta = [{"identity": "unclassified-os-lifetime"}]
        host["unexpected_runner_processes"] = delta
        host["unexpected_runner_processes_after_intervention"] = delta
        host["unexpected_runner_processes_after_delete"] = delta
        host["runner_process_natural_exit"]["status"] = "rejected"
        before = deepcopy(host)
        self.assertEqual(verify_controller_owned_cleanup(host), before)
        with self.assertRaises(EvidenceError):
            verify_controller_cleanup(host)
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)
        self.assertEqual(host, before)

    def test_owned_cleanup_requires_complete_observations_and_no_intervention(self):
        _, clean = self.clean()
        for field, value in (
                ("runner_process_inventory_complete", False),
                ("unexpected_runner_processes_after_delete", None),
                ("unexpected_runner_tasks_after_delete", None),
                ("runner_process_natural_exit", None),
                ("process_jobs_closed", False),
                ("guest_root_present", True),
                ("trusted_task_root_present", True),
                ("scheduled_task_present", True),
                ("owned_processes_after", [{"pid": 123}]),
                ("resource_cleanup_errors", ["restoration uncertain"]),
                ("terminated_runner_processes", [{"exit_observed": True}])):
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_controller_owned_cleanup({**clean, field: value})

    def test_cleanup_requires_each_owned_resource_absent_and_clean_journal(self):
        verify_cleanup(*self.clean())
        guest, host = self.clean()
        for field in ("scheduled_task_present", "guest_root_present", "trusted_task_root_present"):
            with self.assertRaises(EvidenceError):
                verify_cleanup(guest, {**host, field: True})
        guest["owned_processes_after"] = [{"pid": 1234}]
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)
        guest, host = self.clean()
        guest["runtime_root_after"]["entries"] = ["fixture.txt"]
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)
        guest, host = self.clean()
        guest["journal_after"]["entries"] = [{"name": "active.drj", "kind": "file", "bytes": 42}]
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)

    def test_recovery_cleanup_requires_candidate_export_root_absent(self):
        guest, host = self.clean()
        guest["candidate_export_root_after"] = {
            "exists": False, "ordinary_directory": True, "entries": []}
        verify_cleanup(guest, host, require_candidate_export=True)
        for mutation in (
                {"exists": True, "ordinary_directory": True, "entries": []},
                {"exists": False, "ordinary_directory": False, "entries": []},
                {"exists": False, "ordinary_directory": True, "entries": ["residue"]}):
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_cleanup({**guest, "candidate_export_root_after": mutation}, host,
                               require_candidate_export=True)
        guest, host = self.clean()
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host, require_candidate_export=True)

    def test_controller_cleanup_rejects_unexpected_after_intervention_or_delete(self):
        for field in ("unexpected_runner_tasks_after_intervention",
                      "unexpected_runner_processes_after_intervention",
                      "unexpected_runner_tasks_after_delete",
                      "unexpected_runner_processes_after_delete",
                      "removed_runner_tasks"):
            guest, host = self.clean()
            host[field] = [{"identity": "unexpected"}]
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_cleanup(guest, host)

    def test_controller_cleanup_accepts_only_exact_natural_smartscreen_exit(self):
        guest, host = self.clean()
        proof = self.natural_exit_smart_screen()
        host["unexpected_runner_processes"] = [{
            "identity": proof["candidate_identity"], "pid": 9008, "session_id": 2,
            "creation_time_utc": proof["broker"]["process_creation_time_utc"],
            "executable_path": proof["broker"]["process_executable_path"],
        }]
        host["runner_process_natural_exit"] = proof
        verify_cleanup(guest, host)
        verify_controller_cleanup(host)
        case_variant = deepcopy(host)
        case_variant["runner_process_natural_exit"]["broker"]["parent_command_line_arguments"] = [
            proof["broker"]["parent_command_line_arguments"][0],
            "-K", "dcomlaunch", "-P",
        ]
        verify_controller_cleanup(case_variant)

        mutations = (
            ("runner owner", lambda row: row["broker"].update(process_owner_sid="S-1-5-18")),
            ("signature", lambda row: row["broker"].update(process_signature_status="NotSigned")),
            ("path proof", lambda row: row["broker"].update(parent_path_verified=False)),
            ("command line", lambda row: row["broker"]["process_command_line_arguments"].append("-other")),
            ("service pid", lambda row: row["broker"].update(service_process_id=1001)),
            ("second process", lambda row: row["polls"][0]["process_delta_identities"].append("9010|2026-09-27T18:35:00.0000000Z")),
            ("new task", lambda row: row["polls"][0]["task_delta_identities"].append(r"\User\NewTask")),
            ("natural exit", lambda row: row.update(natural_exit_observed=False)),
            ("deadline", lambda row: row.update(elapsed_ms=360001)),
            ("initial poll", lambda row: row["polls"][0].update(process_delta_identities=[])),
        )
        for label, mutate in mutations:
            changed_guest, changed_host = self.clean()
            changed = self.natural_exit_smart_screen()
            changed_host["unexpected_runner_processes"] = deepcopy(host["unexpected_runner_processes"])
            mutate(changed)
            changed_host["runner_process_natural_exit"] = changed
            with self.subTest(label=label), self.assertRaises(EvidenceError):
                verify_cleanup(changed_guest, changed_host)

    def test_controller_cleanup_requires_smart_screen_evidence_and_exact_after_deltas(self):
        guest, host = self.clean()
        del host["runner_process_natural_exit"]
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)
        guest, host = self.clean()
        proof = self.natural_exit_smart_screen()
        host["unexpected_runner_processes"] = [{
            "identity": proof["candidate_identity"], "pid": 9008, "session_id": 2,
            "creation_time_utc": proof["broker"]["process_creation_time_utc"],
            "executable_path": proof["broker"]["process_executable_path"],
        }]
        host["runner_process_natural_exit"] = proof
        host["unexpected_runner_processes_after_delete"] = [
            deepcopy(host["unexpected_runner_processes"][0])]
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)

    def events(self):
        return [{"action": action, "input_method": "keyboard",
                 "target": {"hwnd": 20, "pid": 1234, "session_id": 2, "class": "#32770"},
                 "focused_before": {"hwnd": 21, "root_hwnd": 20, "pid": 1234, "session_id": 2, "class": "Button",
                                    "automation_id": button, "control_type": "ControlType.Button"},
                 "foreground_before": {"hwnd": 20, "process_id": 1234, "session_id": 2, "window_class": "#32770"},
                 "foreground_after": {"hwnd": 12, "process_id": 1234, "session_id": 2, "window_class": "DarkReNamerWindow"}}
                for action, button in (("escape", "CommandButton_2"), ("enter", "CommandLink_1101"))]

    def test_keyboard_binds_real_focus_foreground_and_target(self):
        verify_keyboard_events(self.events(), candidate_pid=1234, session_id=2, main_workbench_hwnd=12)
        mutations = (("focused_before", "automation_id", "CommandLink_1101"),
                     ("focused_before", "pid", 99), ("focused_before", "root_hwnd", 99),
                     ("foreground_after", "hwnd", 99), ("foreground_before", "hwnd", 77),
                     ("foreground_before", "process_id", 99), ("foreground_after", "session_id", 3))
        for section, field, value in mutations:
            events = self.events()
            events[0][section][field] = value
            with self.subTest(section=section, field=field), self.assertRaises(EvidenceError):
                verify_keyboard_events(events, candidate_pid=1234, session_id=2, main_workbench_hwnd=12)

    def test_uia_or_missing_actual_input_cannot_pass_keyboard(self):
        for events in (self.events()[:1], self.events() * 2):
            with self.assertRaises(EvidenceError):
                verify_keyboard_events(events, candidate_pid=1234, session_id=2, main_workbench_hwnd=12)
        events = self.events()
        events[1]["input_method"] = "uia"
        with self.assertRaises(EvidenceError):
            verify_keyboard_events(events, candidate_pid=1234, session_id=2, main_workbench_hwnd=12)


class V2OwnedResourceTests(unittest.TestCase):
    def verify(self, cleanup):
        verify_controller_cleanup(cleanup, profile_id="vm-automated-v2-owned-resources",
                                  profile_sha256=V2_PROFILE_SHA256)

    def test_multiple_new_ambient_processes_can_remain_live(self):
        self.verify(clean_controller_cleanup_v2())

    def test_task_execution_must_exit_zero_for_normal_acceptance(self):
        cleanup = clean_controller_cleanup_v2()
        cleanup["owned_resource_evidence"]["task_execution"]["exit_code"] = 1
        with self.assertRaises(EvidenceError):
            self.verify(cleanup)

    def test_unknown_or_reused_lifetime_and_owned_scope_fail(self):
        for mutation in ("pid-reuse", "owned-command", "owner", "missing-process", "task-change"):
            cleanup = clean_controller_cleanup_v2()
            evidence = cleanup["owned_resource_evidence"]
            if mutation == "pid-reuse":
                row = evidence["process_snapshots"]["after_delete"]["processes"][1]
                row["pid"] = 4001
                row["identity"] = "4001|2026-09-30T01:02:04.0000000Z"
            elif mutation == "owned-command":
                evidence["process_snapshots"]["after_delete"]["processes"][1]["command_line"] += (
                    " " + evidence["run_name"])
            elif mutation == "owner":
                evidence["process_snapshots"]["after_delete"]["processes"][1]["owner_sid"] = "S-1-5-18"
            elif mutation == "missing-process":
                evidence["process_snapshots"]["after_delete"]["complete"] = False
            else:
                evidence["task_snapshots"]["after_delete"] = [{
                    "identity": "\\Unrelated", "task_path": "\\", "task_name": "Unrelated",
                    "definition_sha256": "1" * 64}]
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                self.verify(cleanup)

    def test_profile_and_observer_lifetime_must_be_bound(self):
        for mutation in ("digest", "observer", "schema", "unregistered-action"):
            cleanup = clean_controller_cleanup_v2()
            if mutation == "digest":
                cleanup["profile_sha256"] = "b" * 64
            elif mutation == "observer":
                cleanup["owned_resource_evidence"]["task_execution"]["observer_lifetime_absent"] = False
            elif mutation == "schema":
                cleanup["owned_resource_evidence"]["schema_version"] = 2.0
            else:
                cleanup["owned_resource_evidence"]["task_execution"]["action_arguments"] = (
                    '-NoProfile -File "C:\\ProgramData\\DarkReNamerVmRuns\\' +
                    cleanup["owned_resource_evidence"]["run_name"] +
                    '\\windows-vm-guest.ps1" -AcceptanceProfileId vm-automated-v2-owned-resources')
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                self.verify(cleanup)

    def test_second_rescue_task_requires_its_own_exact_lifetime(self):
        cleanup = clean_controller_cleanup_v2()
        evidence = cleanup["owned_resource_evidence"]
        evidence["rescue_attempts"] = 1
        with self.assertRaises(EvidenceError):
            self.verify(cleanup)
        execution = deepcopy(evidence["task_execution"])
        execution["registered_last_run_time_ticks"] += 10
        execution["completed_last_run_time_ticks"] += 20
        execution["action_arguments"] += " -RestoreTextScaleOnly"
        execution["observer_lifecycle"]["pid"] = 3100
        execution["observer_lifecycle"]["start_time_utc_ticks"] = "134041000000000020"
        execution["observer_lifecycle"]["command_line"] += " -RestoreTextScaleOnly"
        evidence["rescue_executions"] = [{
            "kind": "text-scale", "task_execution": execution,
            "result_file": "text-scale-rescue-result.json", "result_sha256": "c" * 64}]
        self.verify(cleanup)
        execution["observer_lifetime_absent"] = False
        with self.assertRaises(EvidenceError):
            self.verify(cleanup)


if __name__ == "__main__":
    unittest.main()
