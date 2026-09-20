#!/usr/bin/env python3
"""Negative environment/input/cleanup facts cannot pass a required VM cell."""

from copy import deepcopy
import unittest

from vm_automated_evidence import EvidenceError
from vm_automated_platform import verify_environment, verify_cleanup, verify_keyboard_events


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
                {"scheduled_task_present": False, "guest_root_present": False, "owned_processes_after": []})

    def test_cleanup_requires_each_owned_resource_absent_and_clean_journal(self):
        verify_cleanup(*self.clean())
        guest, host = self.clean()
        for field in ("scheduled_task_present", "guest_root_present"):
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
