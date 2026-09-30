#!/usr/bin/env python3
"""End-to-end semantic verification of the fixed 30-slot VM campaign."""

from contextlib import contextmanager, ExitStack
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
from tooling_test_paths import REPOSITORY_ROOT
import struct
import tempfile
import unittest
import zlib

from controller_cleanup_fixture import clean_controller_cleanup
from darkrenamer_tooling.campaign.planning import execution_slots, new_plan
from darkrenamer_tooling.campaign.verifier import EvidenceReader, verify_complete_campaign
from darkrenamer_tooling.contracts.binding import COMPONENTS, Candidate
from darkrenamer_tooling.evidence.archive import EvidenceError, ExtractedEvidence, FileReference


SOURCE_SHA = "a" * 40
EXE_SHA = "b" * 64
HANDOFF_SHA = "c" * 64
PROFILE_SHA = "d" * 64
VM_ID = "12345678-1234-1234-1234-123456789abc"
VOLUME = "1111111111111111"
ROOT_ID = {"volume_serial": VOLUME, "file_id": "2" * 32}
ROOT = r"C:\fixture"
RAIL_IDS = {
    "32771", "32772", "32773", "32774", "32775", "32776", "32777", "32778", "32779",
    "32780", "32781", "32783", "65535", "32784", "32788", "32789", "32790", "32785",
    "32786",
}
FOCUS_ORDER = ["1000"] + [str(value) for value in range(32771, 32781)] + [
    "32781", "32783", "65535", "32784", "32788", "32789", "32790", "32785", "32786"]
FOCUS_GROUPS = [None, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 0, 1, 1, 1, 2, 2, 2, 3, 3]


def load_test_module(name: str):
    path = Path(__file__).with_name(name)
    spec = importlib.util.spec_from_file_location("campaign_fixture_" + name.replace("-", "_"), path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MENU_FIXTURE = load_test_module("test-vm-automated-menu-layout.py")


def encode(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def png_chunk(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def tiny_png() -> bytes:
    pixels = (b"\x00" + b"\xff\x00\x00\xff" + b"\x00\xff\x00\xff" +
              b"\x00" + b"\x00\x00\xff\xff" + b"\xff\xff\xff\xff")
    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0)) +
            png_chunk(b"IDAT", zlib.compress(pixels)) + png_chunk(b"IEND", b""))


class CampaignFixture:
    def __init__(self, root: Path, *, profile: dict | None = None,
                 profile_sha256: str = PROFILE_SHA, candidate: Candidate | None = None,
                 components: dict[str, str] | None = None):
        self.root = root
        self.files: dict[str, FileReference] = {}
        self.profile = deepcopy(profile) if profile is not None else json.loads(
            (REPOSITORY_ROOT / "config/vm-automated-v1.json").read_text())
        self.profile_sha256 = profile_sha256
        self.candidate = candidate or Candidate(SOURCE_SHA, "12", "1", "34", EXE_SHA, HANDOFF_SHA)
        self.components = (dict(components) if components is not None else
                           {role: hashlib.sha256(role.encode()).hexdigest() for role in COMPONENTS})
        self.bundle = self._bundle()
        self.plan = new_plan(self.profile, profile_sha256=self.profile_sha256, candidate=self.candidate,
                             harness_sha=self.candidate.source_sha, campaign_id="complete-campaign",
                             created_at="2026-09-20T00:00:00Z")
        self.campaign = {"schema": f"darkrenamer-vm-automated-campaign-v{self.profile['revision']}",
                         "campaign_id": "complete-campaign", "plan": "plan.json",
                         "attempts": [], "backend": {}}
        self._build_runs()
        self._build_backend()
        self.add_json("plan.json", self.plan)
        self.add_json("campaign.json", self.campaign)

    def add_bytes(self, path: str, data: bytes) -> FileReference:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        pin = FileReference(hashlib.sha256(data).hexdigest(), len(data))
        self.files[path] = pin
        return pin

    def add_json(self, path: str, value: object) -> FileReference:
        return self.add_bytes(path, encode(value))

    def reader(self) -> EvidenceReader:
        return EvidenceReader(ExtractedEvidence(
            self.root, self.files, f"darkrenamer-vm-automated-index-v{self.profile['revision']}"))

    def _bundle(self) -> dict:
        def component(role: str) -> dict:
            return {"file": COMPONENTS[role], "sha256": self.components[role]}

        product = {
            "source_sha": self.candidate.source_sha, "source_state": "clean",
            "candidate": {"workflow_run": "12", "run_attempt": "1", "artifact_id": "34",
                          "artifact_name": "DarkReNamer-dry-run-12-1-windows",
                          "origin_authentication": "pending-hosted"},
            "application": {"file": "DarkReNamer.exe", "sha256": self.candidate.executable_sha256},
            "provenance": {
                "release_handoff": {"file": "release-handoff.json", "sha256": self.candidate.handoff_sha256},
                "run_metadata": {"file": "candidate-run.json", "sha256": "e" * 64},
                "artifact_metadata": {"file": "candidate-artifact.json", "sha256": "f" * 64},
            },
        }
        harness = {
            "source_sha": self.candidate.source_sha, "source_state": "clean",
            "launcher": component("launcher"), "controller": component("controller"),
            "runner": component("runner"),
            "validators": {key: component("validators." + key)
                           for key in ("release_handoff", "candidate_metadata", "binary_measurement")},
            "observers": {key: component("observers." + key) for key in ("ui", "recovery")},
        }
        return {"schema_version": 2, "lane": "candidate-gui-only",
                "target": "x86_64-pc-windows-msvc", "product": product,
                "harness": harness, "test_binaries": []}

    @staticmethod
    def cleanup() -> tuple[dict, dict]:
        return ({"owned_processes_after": [],
                 "runtime_root_after": {"exists": False, "entries": []},
                 "journal_after": {"entries": []}},
                clean_controller_cleanup())

    def lifecycle(self, index: int, *, pid: int | None = None) -> dict:
        return {"pid": 10_000 + index if pid is None else pid, "session_id": 2,
                "start_time_utc_ticks": str(639100000000000000 + index * 10_000),
                "executable_path": r"C:\bundle\DarkReNamer.exe",
                "executable_sha256": self.candidate.executable_sha256,
                "start_observed": True, "exit_observed": True, "exit_code": 0,
                "exit_method": "normal-close"}

    @staticmethod
    def process_job_cleanup(lifecycle: dict) -> list[dict]:
        return [{
            "pid": lifecycle["pid"],
            "process_start_time_utc_ticks": lifecycle["start_time_utc_ticks"],
            "job_empty": True,
            "job_closed": True,
            "capture_complete": True,
            "active_processes_at_primary_exit": None,
            "had_survivors": False,
            "forced_termination": False,
            "active_processes_at_close": 0,
            "active_processes_at_stop": None,
            "active_process_ids_at_stop": [],
            "total_processes_at_stop": None,
            "primary_process_active_at_stop": None,
            "termination_exit_code": None,
            "status": "clean",
            "error": None,
        }]

    @staticmethod
    def environment(target: dict, lifecycle: dict) -> dict:
        flags = 1 if target["contrast"] == "high-contrast" else 0
        return {
            "schema_version": 1,
            "platform": {"os_product_name": "Windows 11 Pro", "display_version": "25H2",
                         "build_number": 26200, "architecture": "x86_64", "product_type": 1},
            "process": {"pid": lifecycle["pid"], "session_id": lifecycle["session_id"],
                        "is_elevated": False},
            "desktop": {"input_desktop_active": True, "locked": False},
            "fixture_volume": {"filesystem": "NTFS", "root_path": ROOT,
                               "root_identity": deepcopy(ROOT_ID)},
            "target_display": {
                "hwnd": 50_000 + lifecycle["pid"], "process_id": lifecycle["pid"],
                "session_id": lifecycle["session_id"], "dpi_x": target["hwnd_dpi"],
                "dpi_y": target["hwnd_dpi"], "text_scale_percent": target["text_scale_percent"],
                "high_contrast_flags": flags,
                "monitor_rect": {"left": 0, "top": 0, "right": target["desktop_width"],
                                 "bottom": target["desktop_height"]},
                "work_rect": {"left": 0, "top": 0, "right": target["desktop_width"],
                              "bottom": target["desktop_height"] - 40},
                "window_rect": {"left": 0, "top": 0, "right": 2, "bottom": 2},
            },
        }

    @staticmethod
    def fixture(name: str, file_id: int = 4) -> dict:
        return {"name": name, "kind": "file", "bytes": 5, "content_sha256": "3" * 64,
                "file_identity": {"volume_serial": VOLUME, "file_id": f"{file_id:032x}"}}

    def checkpoints(self, keyboard: bool) -> list[dict]:
        source = "acceptance-source.txt" if keyboard else "vm-flow-source.txt"
        destination = "accepted-acceptance-source.txt" if keyboard else "vm-confirmed-vm-flow-source.txt"
        initial, renamed = self.fixture(source), self.fixture(destination)
        return [{"phase": phase, "fixture_entries": [deepcopy(state)], "journal_entries": []}
                for phase, state in (("initial", initial), ("after_cancel", initial),
                                     ("after_apply", renamed), ("post_close", renamed))]

    @staticmethod
    def result_base(bundle: dict, observer: str) -> dict:
        row = {"schema_version": 2, "lane": bundle["lane"], "product": deepcopy(bundle["product"]),
               "harness": deepcopy(bundle["harness"]), "target": bundle["target"],
               "failure_reason": None}
        if observer != "core":
            row.update(observer_role=observer,
                       runner_sha256=bundle["harness"]["runner"]["sha256"],
                       application=deepcopy(bundle["product"]["application"]))
            if observer == "ui":
                row["acceptance_script_sha256"] = bundle["harness"]["observers"]["ui"]["sha256"]
            else:
                row["observer"] = deepcopy(bundle["harness"]["observers"]["recovery"])
        return row

    def core_result(self, index: int, target: dict, *, keyboard: bool) -> tuple[dict, dict]:
        lifecycle = self.lifecycle(index)
        environment = self.environment(target, lifecycle)
        guest, host = self.cleanup()
        raw = {"raw_environment": environment, "raw_checkpoints": self.checkpoints(keyboard)}
        result = self.result_base(self.bundle, "ui" if keyboard else "core")
        result["process_job_cleanup"] = self.process_job_cleanup(lifecycle)
        if not keyboard:
            raw['raw_prelaunch_checkpoints'] = [deepcopy(raw['raw_checkpoints'][0])]
            result.update(gui={"flow": raw, "process_lifecycle": lifecycle}, raw_cleanup=guest)
            return result, host
        result.update(raw, process_lifecycle=lifecycle, raw_cleanup=guest)
        main = environment["target_display"]["hwnd"]
        events = []
        for ordinal, (action, automation) in enumerate(
                (("escape", "CommandButton_2"), ("enter", "CommandLink_1101")), start=1):
            dialog = main + ordinal
            events.append({
                "action": action, "input_method": "keyboard",
                "target": {"hwnd": dialog, "pid": lifecycle["pid"], "session_id": 2,
                           "class": "#32770"},
                "focused_before": {"hwnd": dialog + 100, "pid": lifecycle["pid"],
                                   "session_id": 2, "class": "Button", "automation_id": automation,
                                   "control_type": "ControlType.Button", "root_hwnd": dialog},
                "foreground_before": {"hwnd": dialog, "process_id": lifecycle["pid"],
                                      "session_id": 2, "window_class": "#32770"},
                "foreground_after": {"hwnd": main, "process_id": lifecycle["pid"],
                                     "session_id": 2, "window_class": "DarkReNamerWindow"},
            })
        result["keyboard_events"] = events
        return result, host

    @staticmethod
    def control(environment: dict, automation_id: str, control_type: str, *, offset: int) -> dict:
        return {"automation_id": automation_id, "control_type": control_type,
                "visible": True, "enabled": True, "keyboard_focusable": True,
                "bounds": {"left": 10 + offset, "top": 10, "right": 20 + offset, "bottom": 20},
                "pid": environment["process"]["pid"], "session_id": environment["process"]["session_id"],
                "root_hwnd": environment["target_display"]["hwnd"]}

    def layout_observations(self, path: str, environment: dict, target: dict) -> dict:
        if target.get("layout_variant", "command-rails") == "native-menu-only":
            result = MENU_FIXTURE.layout_for_environment(environment)
            image = self.add_bytes(str(PurePosixPath(path).parent / "workbench.png"), tiny_png())
            result["screenshots"] = [{"file": "workbench.png", "sha256": image.sha256,
                                      "width": 2, "height": 2}]
            return result
        controls = [self.control(environment, "", "ControlType.Window", offset=0),
                    self.control(environment, "1000", "ControlType.DataGrid", offset=1)]
        controls.extend(self.control(environment, identifier, "ControlType.Button", offset=index + 2)
                        for index, identifier in enumerate(sorted(RAIL_IDS)))
        bindings = {
            identifier: self.control(
                environment, identifier,
                "ControlType.DataGrid" if identifier == "1000" else "ControlType.Button",
                offset=index + 1,
            )
            for index, identifier in enumerate(FOCUS_ORDER)
        }
        reachability_controls = []
        for identifier, group in zip(FOCUS_ORDER, FOCUS_GROUPS, strict=True):
            binding = deepcopy(bindings[identifier])
            binding.update(
                rail=("list" if identifier == "1000" else
                      "left" if identifier in FOCUS_ORDER[1:11] else "right"),
                rail_group=group, expected_reachable=True, exclusion_reason=None,
            )
            reachability_controls.append(binding)
        traversal = [("tab", FOCUS_ORDER[0], FOCUS_ORDER[1])]
        traversal.extend(("down", before, after)
                         for before, after in zip(FOCUS_ORDER[1:11], FOCUS_ORDER[2:11]))
        traversal.append(("tab", FOCUS_ORDER[10], FOCUS_ORDER[11]))
        traversal.extend(("down", before, after)
                         for before, after in zip(FOCUS_ORDER[11:], FOCUS_ORDER[12:]))
        traversal.append(("tab", FOCUS_ORDER[-1], FOCUS_ORDER[0]))
        transitions = [
            {"sequence": sequence, "input": input_name, "from": deepcopy(bindings[before]),
             "to": deepcopy(bindings[after])}
            for sequence, (input_name, before, after) in enumerate(traversal, start=1)
        ]
        navigation_state = {
            "fixture_root": environment["fixture_volume"]["root_path"],
            "root_identity": deepcopy(environment["fixture_volume"]["root_identity"]),
            "fixture_entries": [self.fixture("focus-sentinel.txt", 99)],
            "journal_entries": [],
        }
        image = self.add_bytes(str(PurePosixPath(path).parent / "workbench.png"), tiny_png())
        return {"controls": controls, "focus": [deepcopy(controls[2])],
                "screenshots": [{"file": "workbench.png", "sha256": image.sha256,
                                 "width": 2, "height": 2}],
                "focus_reachability": {
                    "schema_version": 1, "input_method": "keyboard",
                    "initial": deepcopy(bindings[FOCUS_ORDER[0]]), "transitions": transitions,
                    "final": deepcopy(bindings[FOCUS_ORDER[0]]),
                    "controls": reachability_controls,
                    "state_before": deepcopy(navigation_state),
                    "state_after": deepcopy(navigation_state),
                }}

    def restoration(self, path: str, result: dict, target: dict) -> None:
        prefix = str(PurePosixPath(path).parent)
        observer_sha = self.bundle["harness"]["observers"]["ui"]["sha256"]
        if target["contrast"] == "high-contrast":
            colors = {key: index for index, key in enumerate(
                ("window", "window_text", "button_face", "button_text", "highlight",
                 "highlight_text", "gray_text", "hot_light"), start=1)}
            setting = {"flags": 1, "scheme": "High Contrast Black", "colors": colors,
                       "visual_style": {"path": "", "color": "", "size": ""}}
            snapshot = {"schema_version": 2, "source_sha": self.candidate.source_sha,
                        "acceptance_script_sha256": observer_sha,
                        "restoration_required": False, "restoration_verified": True,
                        "original": setting, "restored": deepcopy(setting)}
            pin = self.add_json(prefix + "/high-contrast.json", snapshot)
            result["high_contrast"] = {"snapshot": {"file": "high-contrast.json",
                                                       "sha256": pin.sha256}}
        if target["text_scale_percent"] == 150:
            original = {"registry_key_existed": True, "registry_value_existed": True,
                        "registry_value_kind": "DWord", "registry_value": 100,
                        "ui_settings_raw_factor": 1.0, "ui_settings_percent": 100}
            active = {**original, "registry_value": 150, "ui_settings_raw_factor": 1.5,
                      "ui_settings_percent": 150}
            snapshot = {"schema_version": 1, "source_sha": self.candidate.source_sha,
                        "acceptance_script_sha256": observer_sha,
                        "restoration_required": True, "restoration_verified": True,
                        "original": original, "restored": deepcopy(original)}
            snapshot_pin = self.add_json(prefix + "/text-scale.json", snapshot)
            activation = self.add_json(prefix + "/text-scale-activation.json", {"observed": True})
            restored = self.add_json(prefix + "/text-scale-restoration.json", {"observed": True})
            result["raw_text_scale"] = {
                "original": original, "active": active, "active_winrt_percent": 150,
                "restored": deepcopy(original),
                "snapshot": {"file": "text-scale.json", "sha256": snapshot_pin.sha256},
                "activation": {"file": "text-scale-activation.json", "sha256": activation.sha256},
                "restoration": {"file": "text-scale-restoration.json", "sha256": restored.sha256},
            }

    def layout_result(self, index: int, target: dict, result_path: str) -> tuple[dict, dict]:
        lifecycle = self.lifecycle(index)
        environment = self.environment(target, lifecycle)
        guest, host = self.cleanup()
        result = self.result_base(self.bundle, "ui")
        result["process_job_cleanup"] = self.process_job_cleanup(lifecycle)
        result.update(raw_layout_runs=[{
            "raw_environment": environment,
            "raw_appearance": {
                "hwnd": environment["target_display"]["hwnd"], "pid": lifecycle["pid"],
                "session_id": lifecycle["session_id"],
                "menu_checked": [{"command_id": command,
                                  "checked": command == {"system": 0x9010, "light": 0x9011,
                                                          "dark": 0x9012}[target["appearance"]]}
                                 for command in (0x9010, 0x9011, 0x9012)],
            },
            "process_lifecycle": lifecycle,
            "layout_observations": self.layout_observations(result_path, environment, target),
        }], raw_cleanup=guest)
        self.restoration(result_path, result, target)
        return result, host

    @staticmethod
    def _shift_ticks(value: object, offset: int) -> object:
        if type(value) is dict:
            return {key: (str(int(item) + offset)
                          if key.endswith("utc_ticks") and type(item) is str else
                          CampaignFixture._shift_ticks(item, offset))
                    for key, item in value.items()}
        if type(value) is list:
            return [CampaignFixture._shift_ticks(item, offset) for item in value]
        return value

    @staticmethod
    def _replace_scalar(value: object, replacements: dict[str, str]) -> object:
        if type(value) is dict:
            return {key: CampaignFixture._replace_scalar(item, replacements)
                    for key, item in value.items()}
        if type(value) is list:
            return [CampaignFixture._replace_scalar(item, replacements) for item in value]
        return replacements.get(value, value) if type(value) is str else value

    @staticmethod
    def _replace_references(value: object, pins: dict[tuple[int, str], tuple[int, str]]) -> None:
        if type(value) is dict:
            if set(value) == {"bytes", "sha256", "boundary"}:
                key = (value["bytes"], value["sha256"])
                if key in pins:
                    value["bytes"], value["sha256"] = pins[key]
            for item in value.values():
                CampaignFixture._replace_references(item, pins)
        elif type(value) is list:
            for item in value:
                CampaignFixture._replace_references(item, pins)

    def recovery_result(self, slot: dict, index: int) -> tuple[dict, dict, dict[str, bytes]]:
        module = load_test_module("test-vm-automated-recovery-profile.py")
        if slot["id"] == "process-crash":
            source_reader, result, _, transport = module.build_crash()
        else:
            source_reader, result, _, transport, _ = module.build_worker(slot["id"] == "worker-close")
        result = deepcopy(result)
        source_prefix = f"runs/{slot['id']}/"
        observer_prefix = source_prefix + "bundle/observer-output/"
        raw_files = {
            observer_prefix + path[len(source_prefix):]: data
            for path, data in source_reader.files.items()
        }
        pins: dict[tuple[int, str], tuple[int, str]] = {}
        offset = index * 1_000_000
        private_index_path = next(path for path in raw_files if path.endswith("/private-index.json"))
        for path, old_data in list(raw_files.items()):
            if not path.endswith(".json") or path == private_index_path:
                continue
            shifted = self._shift_ticks(json.loads(old_data), offset)
            shifted = self._replace_scalar(
                shifted,
                {SOURCE_SHA: self.candidate.source_sha,
                 EXE_SHA: self.candidate.executable_sha256,
                 HANDOFF_SHA: self.candidate.handoff_sha256},
            )
            new_data = encode(shifted)
            if new_data != old_data:
                pins[(len(old_data), hashlib.sha256(old_data).hexdigest())] = (
                    len(new_data), hashlib.sha256(new_data).hexdigest())
                raw_files[path] = new_data
        self._replace_references(result, pins)
        private_root = str(PurePosixPath(private_index_path).parent)
        rows = []
        for path, data in sorted(raw_files.items()):
            if path == private_index_path or not path.startswith(private_root + "/"):
                continue
            rows.append({"file": path[len(private_root) + 1:], "bytes": len(data),
                         "sha256": hashlib.sha256(data).hexdigest()})
        index_data = encode({"schema_version": 1,
                             "classification": "private-path-bearing-raw-recovery-evidence",
                             "files": rows})
        raw_files[private_index_path] = index_data
        result["private_evidence"] = {"bytes": len(index_data),
                                      "sha256": hashlib.sha256(index_data).hexdigest(),
                                      "file_count": len(rows)}
        result["process_job_cleanup"] = self._shift_ticks(
            result["process_job_cleanup"], offset
        )
        result.update(lane=self.bundle["lane"], product=deepcopy(self.bundle["product"]),
                      harness=deepcopy(self.bundle["harness"]), failure_reason=None,
                      runner_sha256=self.bundle["harness"]["runner"]["sha256"],
                      application=deepcopy(self.bundle["product"]["application"]),
                      observer_role="recovery",
                      observer=deepcopy(self.bundle["harness"]["observers"]["recovery"]))
        transport = deepcopy(transport)
        return result, transport["raw_cleanup"], raw_files

    def _target(self, slot: dict) -> dict:
        targets = {row["id"]: row for row in self.profile["required_targets"]}
        target = dict(self.profile["representative_core_environment"])
        target.update(targets[slot["targets"][0]])
        if slot["stability_index"] is not None:
            target.update(self.profile["stability"]["environment"])
        return target

    def v2_cleanup(self, result: dict, index: int) -> dict:
        from controller_cleanup_fixture import clean_controller_cleanup_v2
        cleanup = clean_controller_cleanup_v2(
            profile_sha256=self.profile_sha256,
            process_jobs=result["process_job_cleanup"],
            run_name=f"DarkReNamerTests-{index:032x}")
        lifecycle = cleanup["owned_resource_evidence"]["task_execution"]["observer_lifecycle"]
        lifecycle["pid"] = 700_000 + index
        lifecycle["start_time_utc_ticks"] = str(134041000000100000 + index)
        # Keep synthetic ambient PIDs disjoint from every fixture-owned lifetime.
        for phase in cleanup["owned_resource_evidence"]["process_snapshots"].values():
            for row in phase["processes"]:
                row["pid"] += 900_000
                row["identity"] = str(row["pid"]) + "|" + row["creation_time_utc"]
        for phase, key in (("before", "unexpected_runner_processes"),
                           ("after_intervention", "unexpected_runner_processes_after_intervention"),
                           ("after_delete", "unexpected_runner_processes_after_delete")):
            cleanup[key] = deepcopy(cleanup["owned_resource_evidence"]["process_snapshots"][
                phase]["processes"])
        result.update(status="passed", failure_reason=None,
                      observer_lifecycle=deepcopy(cleanup["owned_resource_evidence"][
                          "task_execution"]["observer_lifecycle"]))
        return cleanup

    def _build_runs(self) -> None:
        start = datetime(2026, 9, 20, tzinfo=timezone.utc)
        for index, slot in enumerate(execution_slots(self.profile), start=1):
            prefix = "runs/" + slot["id"] + "/"
            result_path = prefix + "result.json"
            target = self._target(slot)
            if slot["id"] == "core-uia-flow" or slot["stability_index"] is not None:
                result, host_cleanup = self.core_result(index, target, keyboard=False)
            elif slot["id"] == "core-keyboard-flow":
                result, host_cleanup = self.core_result(index, target, keyboard=True)
            elif slot["id"].startswith("layout-"):
                result, host_cleanup = self.layout_result(index, target, result_path)
            else:
                result, host_cleanup, private_files = self.recovery_result(slot, index)
                for path, data in private_files.items():
                    self.add_bytes(path, data)
                observer_prefix = prefix + "bundle/observer-output/"
                result_path = observer_prefix + "recovery-acceptance-test/summary.json"
            if self.profile["revision"] == 2:
                host_cleanup = self.v2_cleanup(result, index)
            transport = {"raw_cleanup": host_cleanup, "vm_id": VM_ID,
                         "vm_identity_kind": "hyper-v-guest-parameters-virtual-machine-id-v1",
                         "vm_identity_sha256": hashlib.sha256(VM_ID.encode()).hexdigest()}
            lease = {"schema_version": 1, "mode": "managed-rdp", "lease_id": f"{index:032x}",
                     "requested_scale": target["scale_percent"],
                     "requested_width": target["desktop_width"],
                     "requested_height": target["desktop_height"], "expected_dpi": target["hwnd_dpi"],
                     "start_status": "ready", "stop_status": "stopped", "cleanup_observed": True}
            paths = {"bundle": prefix + "bundle.json", "result": result_path,
                     "transport": (observer_prefix + "transport.json"
                                   if slot["id"] in {"process-crash", "worker-cancellation", "worker-close"}
                                   else prefix + "transport.json"),
                     "desktop_lease": prefix + "desktop-lease.json"}
            self.add_json(paths["bundle"], self.bundle)
            self.add_json(paths["result"], result)
            self.add_json(paths["transport"], transport)
            self.add_json(paths["desktop_lease"], lease)
            begun = start + timedelta(minutes=index)
            self.campaign["attempts"].append({
                "slot_id": slot["id"], "attempt": 1, "exit_code": 0,
                "started_at": begun.isoformat().replace("+00:00", "Z"),
                "ended_at": (begun + timedelta(seconds=30)).isoformat().replace("+00:00", "Z"),
                **paths,
            })

    def _build_backend(self) -> None:
        names = self.profile["required_backend_test_names"]
        binary = self.add_bytes("backend/required-tests.exe", b"MZ complete campaign backend")
        transcript = "running 5 tests\n" + "".join(
            f"test engine::{name} ... ok\n" for name in names) + (
                "\ntest result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; "
                "0 filtered out; finished in 0.01s\n")
        stdout = self.add_bytes("backend/stdout.txt", transcript.encode())
        stderr = self.add_bytes("backend/stderr.txt", b"")
        bundle = {"schema_version": 1, "source_sha": self.candidate.source_sha,
                  "source_state": "clean",
                  "target": "x86_64-pc-windows-msvc",
                  "runner": deepcopy(self.bundle["harness"]["runner"]),
                  "test_binaries": [{"file": "required-tests.exe", "sha256": binary.sha256}]}
        backend_cleanup = clean_controller_cleanup()
        result = {"schema_version": 1, "source_sha": self.candidate.source_sha,
                  "source_state": "clean",
                  "target": "x86_64-pc-windows-msvc", "failure_reason": None,
                  "transport": {"guest_cleanup": True, "raw_cleanup": backend_cleanup},
                  "gui": {"process_lifecycle": {"pid": 80_001,
                                                  "start_time_utc_ticks": "639100001000000001"}},
                  "tests": [{"file": "required-tests.exe", "sha256": binary.sha256,
                             "exit_code": 0, "passed": 5, "failed": 0, "ignored": 0,
                             "process_lifecycle": {"pid": 80_000,
                                                   "start_time_utc_ticks": "639100001000000000"},
                             "stdout": {"file": "stdout.txt", "sha256": stdout.sha256, "bytes": stdout.size},
                             "stderr": {"file": "stderr.txt", "sha256": stderr.sha256, "bytes": stderr.size}}]}
        result["process_job_cleanup"] = [
            self.process_job_cleanup(lifecycle)[0] for lifecycle in
            (result["tests"][0]["process_lifecycle"], result["gui"]["process_lifecycle"])
        ]
        if self.profile["revision"] == 2:
            backend_cleanup = self.v2_cleanup(result, 31)
            result["transport"]["raw_cleanup"] = backend_cleanup
        self.add_json("backend/bundle.json", bundle)
        self.add_json("backend/result.json", result)
        self.add_json("backend/transport.json", {
            "guest_cleanup": True, "raw_cleanup": backend_cleanup})
        backend_paths = sorted(path for path in self.files if path.startswith("backend/"))
        self.campaign["backend"] = {
            "source_sha": self.candidate.source_sha, "bundle": "backend/bundle.json",
            "result": "backend/result.json",
            "transport": "backend/transport.json",
            "files": [{"file": path, "sha256": self.files[path].sha256,
                       "size": self.files[path].size} for path in backend_paths],
        }

    @contextmanager
    def change_json(self, path: str, mutation):
        original_data = (self.root / path).read_bytes()
        original_pin = self.files[path]
        value = json.loads(original_data)
        mutation(value)
        self.add_json(path, value)
        try:
            yield
        finally:
            (self.root / path).write_bytes(original_data)
            self.files[path] = original_pin

    @contextmanager
    def change_backend_file(self, path: str, mutation):
        original_data = (self.root / path).read_bytes()
        original_pin = self.files[path]
        campaign_data = (self.root / "campaign.json").read_bytes()
        campaign_pin = self.files["campaign.json"]
        original_campaign = deepcopy(self.campaign)
        value = json.loads(original_data)
        mutation(value)
        changed_pin = self.add_json(path, value)
        row = next(row for row in self.campaign["backend"]["files"] if row["file"] == path)
        row.update(sha256=changed_pin.sha256, size=changed_pin.size)
        self.add_json("campaign.json", self.campaign)
        try:
            yield
        finally:
            self.campaign.clear()
            self.campaign.update(original_campaign)
            (self.root / path).write_bytes(original_data)
            self.files[path] = original_pin
            (self.root / "campaign.json").write_bytes(campaign_data)
            self.files["campaign.json"] = campaign_pin



class OwnedResourceCampaignTests(unittest.TestCase):
    def test_v2_complete_campaign_accepts_observed_ambient_lifetimes(self):
        profile = json.loads((REPOSITORY_ROOT / "config/vm-automated-v2.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            fixture = CampaignFixture(Path(directory), profile=profile)
            verified = verify_complete_campaign(
                fixture.reader(), profile=fixture.profile,
                profile_sha256=fixture.profile_sha256, candidate=fixture.candidate,
                component_hashes=fixture.components)
            self.assertRegex(verified["profile_evidence_sha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(len(fixture.campaign["attempts"]), 30)
            path = "runs/core-uia-flow/transport.json"
            with fixture.change_json(path, lambda value: value["raw_cleanup"].update(
                    profile_sha256="0" * 64)):
                with self.assertRaises(EvidenceError):
                    verify_complete_campaign(
                        fixture.reader(), profile=fixture.profile,
                        profile_sha256=fixture.profile_sha256, candidate=fixture.candidate,
                        component_hashes=fixture.components)


    def test_v2_rejects_observer_and_owned_run_replay_between_fresh_product_slots(self):
        profile = json.loads((REPOSITORY_ROOT / "config/vm-automated-v2.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            fixture = CampaignFixture(Path(directory), profile=profile)
            first, second = fixture.campaign["attempts"][:2]
            original_first = json.loads((fixture.root / first["transport"]).read_text())
            original_second = json.loads((fixture.root / second["transport"]).read_text())
            original_result = json.loads((fixture.root / second["result"]).read_text())
            for mode in ("observer lifetime", "owned run name"):
                transport, result = deepcopy(original_second), deepcopy(original_result)
                owned = transport["raw_cleanup"]["owned_resource_evidence"]
                prior = original_first["raw_cleanup"]["owned_resource_evidence"]
                if mode == "observer lifetime":
                    lifecycle = owned["task_execution"]["observer_lifecycle"]
                    for key in ("pid", "start_time_utc_ticks"):
                        lifecycle[key] = prior["task_execution"]["observer_lifecycle"][key]
                else:
                    raw = deepcopy(original_first["raw_cleanup"])
                    replay = raw["owned_resource_evidence"]
                    replay["declared_processes"] = owned["declared_processes"]
                    replay["process_job_cleanup"] = owned["process_job_cleanup"]
                    lifecycle = replay["task_execution"]["observer_lifecycle"]
                    for key in ("pid", "start_time_utc_ticks"):
                        lifecycle[key] = owned["task_execution"]["observer_lifecycle"][key]
                    transport["raw_cleanup"] = raw
                result["observer_lifecycle"] = deepcopy(lifecycle)
                with self.subTest(mode=mode), ExitStack() as changes:
                    changes.enter_context(fixture.change_json(second["transport"], lambda value: value.update(transport)))
                    changes.enter_context(fixture.change_json(second["result"], lambda value: value.update(result)))
                    with self.assertRaisesRegex(EvidenceError, "prior v2 " + mode):
                        verify_complete_campaign(
                            fixture.reader(), profile=fixture.profile,
                            profile_sha256=fixture.profile_sha256, candidate=fixture.candidate,
                            component_hashes=fixture.components)


class CompleteCampaignTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.fixture = CampaignFixture(Path(cls.temporary.name))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def verify(self):
        return verify_complete_campaign(self.fixture.reader(), profile=self.fixture.profile,
                                        profile_sha256=self.fixture.profile_sha256,
                                        candidate=self.fixture.candidate,
                                        component_hashes=self.fixture.components)

    def test_complete_thirty_slot_campaign_derives_all_twenty_two_targets(self):
        result = self.verify()
        self.assertRegex(result["backend_sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(result["profile_evidence_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(len(self.fixture.campaign["attempts"]), 30)
        self.assertEqual(len(self.fixture.profile["required_targets"]), 22)

    def test_v1_archive_cannot_be_selected_as_v2(self):
        profile = json.loads((REPOSITORY_ROOT / 'config/vm-automated-v2.json').read_text())
        with self.assertRaisesRegex(EvidenceError, 'archive index'):
            verify_complete_campaign(self.fixture.reader(), profile=profile,
                                     profile_sha256=self.fixture.profile_sha256,
                                     candidate=self.fixture.candidate,
                                     component_hashes=self.fixture.components)

    def test_missing_failed_or_replacement_attempt_fails(self):
        for mode in ("missing", "failed", "replacement"):
            def mutate(campaign, mode=mode):
                if mode == "missing":
                    campaign["attempts"].pop()
                elif mode == "failed":
                    campaign["attempts"][0]["exit_code"] = 1
                else:
                    campaign["attempts"][0]["attempt"] = 2
            with self.subTest(mode=mode), self.fixture.change_json("campaign.json", mutate):
                with self.assertRaises(EvidenceError):
                    self.verify()

    def test_wrong_candidate_bundle_fails(self):
        path = "runs/core-uia-flow/bundle.json"
        with self.fixture.change_json(path, lambda value:
                                      value["product"]["candidate"].update(artifact_id="99")):
            with self.assertRaises(EvidenceError):
                self.verify()

    def test_cleanup_residue_fails(self):
        path = "runs/core-uia-flow/transport.json"
        with self.fixture.change_json(path, lambda value:
                                      value["raw_cleanup"].update(scheduled_task_present=True)):
            with self.assertRaises(EvidenceError):
                self.verify()

    def test_backend_transport_cleanup_is_verified_and_cross_bound(self):
        for label, mutation in (
                ("invalid raw cleanup", lambda value: value["raw_cleanup"].update(
                    scheduled_task_present=True)),
                ("different valid raw cleanup", lambda value: value["raw_cleanup"]
                    ["runner_process_natural_exit"].update(runner_session_id=3))):
            with self.subTest(label=label), self.fixture.change_backend_file(
                    "backend/transport.json", mutation):
                with self.assertRaises(EvidenceError):
                    self.verify()

    def test_backend_job_capture_failure_rejects_complete_campaign(self):
        with self.fixture.change_backend_file(
                "backend/result.json",
                lambda result: result["process_job_cleanup"][0].update(capture_complete=False)):
            with self.assertRaises(EvidenceError):
                self.verify()

    def test_reused_process_lifetime_fails(self):
        source = json.loads((self.fixture.root / "runs/core-uia-flow/result.json").read_bytes())
        with self.fixture.change_json("runs/stability-01/result.json",
                                      lambda value: (value.clear(), value.update(deepcopy(source)))):
            with self.assertRaises(EvidenceError):
                self.verify()

    def test_reused_desktop_lease_fails(self):
        source = json.loads((self.fixture.root / "runs/core-uia-flow/desktop-lease.json").read_bytes())
        with self.fixture.change_json("runs/stability-01/desktop-lease.json",
                                      lambda value: (value.clear(), value.update(deepcopy(source)))):
            with self.assertRaises(EvidenceError):
                self.verify()

    def test_profile_cell_environment_mismatch_fails(self):
        path = "runs/layout-normal-125/result.json"
        def mutate(value):
            value["raw_layout_runs"][0]["raw_environment"]["target_display"]["dpi_x"] = 96
        with self.fixture.change_json(path, mutate):
            with self.assertRaises(EvidenceError):
                self.verify()

    def test_menu_only_cell_requires_native_identity_and_profile_discriminator(self):
        path = "runs/layout-small-text150-100/result.json"
        def mutate(value):
            native = value["raw_layout_runs"][0]["layout_observations"]["native_menu_only"]
            native["hidden_rail_controls"][0]["parent_hwnd"] = 99
        with self.fixture.change_json(path, mutate):
            with self.assertRaises(EvidenceError):
                self.verify()

        target = next(row for row in self.fixture.profile["required_targets"]
                      if row["id"] == "layout-small-text150-100")
        original = target["layout_variant"]
        try:
            target["layout_variant"] = "command-rails"
            with self.assertRaises(EvidenceError):
                self.verify()
        finally:
            target["layout_variant"] = original


if __name__ == "__main__":
    unittest.main()
