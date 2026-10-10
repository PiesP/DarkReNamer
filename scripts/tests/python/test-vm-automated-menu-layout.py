#!/usr/bin/env python3
"""Unit tests for the frozen native-menu-only layout predicate."""

from copy import deepcopy
import unittest
from unittest.mock import patch

from darkrenamer_tooling.contracts import menu_layout as menu_contract
from darkrenamer_tooling.contracts.menu_layout import verify_native_menu_layout
from darkrenamer_tooling.evidence.archive import EvidenceError
from menu_layout_fixture import RECT, environment, fixture_state, layout


class NativeMenuLayoutTests(unittest.TestCase):
    def test_fixture_does_not_follow_changed_verifier_inventory(self):
        observations = layout()
        state = fixture_state()
        with patch.object(menu_contract, "ENABLED_COMMANDS", frozenset()):
            self.assertEqual(layout(), observations)
            with self.assertRaises(EvidenceError):
                verify_native_menu_layout(observations, environment())

        changed_files = dict(menu_contract._FIXTURE_FILES)
        path = next(iter(changed_files))
        changed_files[path] = b"changed fixture expectation\n"
        with patch.object(menu_contract, "_FIXTURE_FILES", changed_files):
            self.assertEqual(fixture_state(), state)
            with self.assertRaises(EvidenceError):
                verify_native_menu_layout(observations, environment())

    def test_complete_native_menu_transcript_passes(self):
        verify_native_menu_layout(layout(), environment())
        verify_native_menu_layout(layout(opener_highlights=True), environment())

    def test_disabled_highlights_preserve_navigation_and_enabled_coverage(self):
        for mutation in ("wrong-opener", "skipped-disabled-row", "missing-enabled-command"):
            changed = layout(opener_highlights=True)
            events = changed["native_menu_only"]["events"]
            if mutation == "wrong-opener":
                opener = next(event for event in events if event["input"] == "alt-e")
                opener["highlighted"].update(position=1, command_id=65535)
            else:
                position = 1 if mutation == "skipped-disabled-row" else 5
                events[:] = [event for event in events if not (
                    event["input"] == "down" and event["highlighted"]["menu_path"] == [1]
                    and event["highlighted"]["position"] == position)]
                for sequence, event in enumerate(events, 1):
                    event["sequence"] = sequence
            expected = "enabled required command" if mutation == "missing-enabled-command" else "keyboard"
            with self.subTest(mutation=mutation), self.assertRaisesRegex(EvidenceError, expected):
                verify_native_menu_layout(changed, environment())

    def test_identity_tree_state_and_replay_fail_closed(self):
        mutations = {
            "hidden-visible": lambda row: row["native_menu_only"]["hidden_rail_controls"][0].update(visible=True),
            "hidden-foreign-parent": lambda row: row["native_menu_only"]["hidden_rail_controls"][0].update(parent_hwnd=99),
            "hidden-control-id": lambda row: row["native_menu_only"]["hidden_rail_controls"][0].update(control_id=1),
            "wrong-command-path": lambda row: row["native_menu_only"]["menu_tree"][8].update(command_id=32772),
            "flags-lie": lambda row: row["native_menu_only"]["menu_tree"][8].update(enabled=True),
            "foreign-popup": lambda row: row["native_menu_only"]["events"][0]["popups"][0].update(pid=99),
            "clipped-highlight": lambda row: row["native_menu_only"]["events"][4]["highlighted"]["item_rect"].update(right=700),
            "fake-key": lambda row: row["native_menu_only"]["events"][0].update(input="enter", virtual_keys=[13]),
            "array-key": lambda row: row["native_menu_only"]["events"][0].update(input=[]),
            "object-key": lambda row: row["native_menu_only"]["events"][0].update(input={}),
            "array-item-type": lambda row: row["native_menu_only"]["menu_tree"][0].update(item_type=[]),
            "object-item-type": lambda row: row["native_menu_only"]["menu_tree"][0].update(item_type={}),
            "wrong-key-code": lambda row: row["native_menu_only"]["events"][0].update(virtual_keys=[70]),
            "foreign-foreground": lambda row: row["native_menu_only"]["events"][0]["foreground"].update(process_id=99),
            "fixture-mutation": lambda row: row["native_menu_only"]["state_after"]["fixture_entries"][2].update(bytes=24),
            "open-final-popup": lambda row: row["native_menu_only"]["final"].update(open_menu_paths=[[0]]),
        }
        for name, mutate in mutations.items():
            changed = layout()
            mutate(changed)
            with self.subTest(name=name), self.assertRaises(EvidenceError):
                verify_native_menu_layout(changed, environment())

    def test_menu_bar_exit_requires_exact_second_escape(self):
        def first_root_bar(row: dict) -> dict:
            return next(event for event in row["native_menu_only"]["events"]
                        if event["highlighted"] is not None and
                        event["highlighted"]["menu_path"] == [])

        def remove_second_escape(row: dict) -> None:
            events = row["native_menu_only"]["events"]
            first = events.index(first_root_bar(row))
            del events[first + 1]
            for sequence, event in enumerate(events, 1):
                event["sequence"] = sequence

        mutations = {
            "missing-second-escape": remove_second_escape,
            "wrong-root-path": lambda row: first_root_bar(row)["highlighted"].update(position=1),
            "wrong-root-flags": lambda row: first_root_bar(row)["highlighted"].update(state_flags=0x80),
            "root-command": lambda row: first_root_bar(row)["highlighted"].update(command_id=32791),
            "closed-submenu-highlight": lambda row: first_root_bar(row)["highlighted"].update(
                menu_path=[0], position=0, command_id=32791),
            "outside-main-window": lambda row: first_root_bar(row)["highlighted"]["item_rect"].update(
                right=RECT["right"] + 1),
        }
        for name, mutate in mutations.items():
            changed = layout()
            mutate(changed)
            with self.subTest(name=name), self.assertRaises(EvidenceError):
                verify_native_menu_layout(changed, environment())

    def test_recursive_standard_fixture_fails_closed(self):
        def entries(row: dict, phase: str = "state_before") -> list[dict]:
            return row["native_menu_only"][phase]["fixture_entries"]

        mutations = {
            "missing-directory": lambda row: entries(row).pop(0),
            "missing-file": lambda row: entries(row).pop(),
            "foreign-root": lambda row: row["native_menu_only"]["state_before"].update(
                fixture_root=r"D:\fixture"),
            "foreign-volume": lambda row: entries(row)[0]["file_identity"].update(
                volume_serial="9" * 16),
            "alias-path": lambda row: entries(row)[1].update(
                relative_path=entries(row)[0]["relative_path"].swapcase()),
            "backslash-path": lambda row: entries(row)[2].update(
                relative_path=entries(row)[2]["relative_path"].replace("/", "\\")),
            "reparse-kind": lambda row: entries(row)[0].update(kind="reparse"),
            "content-mutation": lambda row: entries(row)[2].update(content_sha256="f" * 64),
            "root-identity-alias": lambda row: entries(row)[0].update(
                file_identity=deepcopy(row["native_menu_only"]["state_before"]["root_identity"])),
            "duplicate-identity": lambda row: entries(row)[1].update(
                file_identity=deepcopy(entries(row)[0]["file_identity"])),
            "noncanonical-order": lambda row: entries(row).reverse(),
        }
        for name, mutate in mutations.items():
            changed = layout()
            mutate(changed)
            with self.subTest(name=name), self.assertRaises(EvidenceError):
                verify_native_menu_layout(changed, environment())

    def test_missing_enabled_command_coverage_fails(self):
        changed = layout()
        events = changed["native_menu_only"]["events"]
        fifth_transform = [index for index, event in enumerate(events)
                           if event["input"] == "alt-t"][4]
        del events[fifth_transform:]
        with self.assertRaises(EvidenceError):
            verify_native_menu_layout(changed, environment())


if __name__ == "__main__":
    unittest.main()
