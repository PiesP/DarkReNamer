#!/usr/bin/env python3
"""Negative environment/input/cleanup facts cannot pass a required VM cell."""

from copy import deepcopy
import unittest

from darkrenamer_tooling.contracts.platform import (
    verify_cleanup, verify_controller_cleanup, verify_environment,
    verify_keyboard_events,
)
from darkrenamer_tooling.evidence.archive import EvidenceError


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
                 "resource_cleanup_errors": [], "smart_screen_natural_exit": self.not_required_smart_screen(),
                 "owned_processes_after": []})

    @staticmethod
    def not_required_smart_screen():
        return {"schema_version": 1, "status": "not-required",
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
            "schema_version": 1, "status": "natural-exit",
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
        host["smart_screen_natural_exit"] = proof
        verify_cleanup(guest, host)
        verify_controller_cleanup(host)
        case_variant = deepcopy(host)
        case_variant["smart_screen_natural_exit"]["broker"]["parent_command_line_arguments"] = [
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
            changed_host["smart_screen_natural_exit"] = changed
            with self.subTest(label=label), self.assertRaises(EvidenceError):
                verify_cleanup(changed_guest, changed_host)

    def test_controller_cleanup_requires_smart_screen_evidence_and_exact_after_deltas(self):
        guest, host = self.clean()
        del host["smart_screen_natural_exit"]
        with self.assertRaises(EvidenceError):
            verify_cleanup(guest, host)
        guest, host = self.clean()
        proof = self.natural_exit_smart_screen()
        host["unexpected_runner_processes"] = [{
            "identity": proof["candidate_identity"], "pid": 9008, "session_id": 2,
            "creation_time_utc": proof["broker"]["process_creation_time_utc"],
            "executable_path": proof["broker"]["process_executable_path"],
        }]
        host["smart_screen_natural_exit"] = proof
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


if __name__ == "__main__":
    unittest.main()
