#!/usr/bin/env python3
"""End-to-end semantic verification of the fixed 30-slot VM campaign."""

from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from vm_automated_binding import COMPONENTS, Candidate
from vm_automated_campaign import execution_slots, new_plan
from vm_automated_evidence import EvidenceError, ExtractedEvidence, FileReference
from vm_automated_verifier import EvidenceReader, verify_complete_campaign


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
            (Path(__file__).resolve().parents[1] / "config/vm-automated-v1.json").read_text())
        self.profile_sha256 = profile_sha256
        self.candidate = candidate or Candidate(SOURCE_SHA, "12", "1", "34", EXE_SHA, HANDOFF_SHA)
        self.components = (dict(components) if components is not None else
                           {role: hashlib.sha256(role.encode()).hexdigest() for role in COMPONENTS})
        self.bundle = self._bundle()
        self.plan = new_plan(self.profile, profile_sha256=self.profile_sha256, candidate=self.candidate,
                             harness_sha=self.candidate.source_sha, campaign_id="complete-campaign",
                             created_at="2026-09-20T00:00:00Z")
        self.campaign = {"schema": "darkrenamer-vm-automated-campaign-v1",
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
        return EvidenceReader(ExtractedEvidence(self.root, self.files))

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
                {"scheduled_task_present": False, "guest_root_present": False,
                 "owned_processes_after": []})

    def lifecycle(self, index: int, *, pid: int | None = None) -> dict:
        return {"pid": 10_000 + index if pid is None else pid, "session_id": 2,
                "start_time_utc_ticks": str(639100000000000000 + index * 10_000),
                "executable_path": r"C:\bundle\DarkReNamer.exe",
                "executable_sha256": self.candidate.executable_sha256,
                "start_observed": True, "exit_observed": True, "exit_code": 0,
                "exit_method": "normal-close"}

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
        if not keyboard:
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

    def layout_observations(self, path: str, environment: dict) -> dict:
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
        transitions = [
            {"sequence": sequence, "input": "f6", "from": deepcopy(bindings[before]),
             "to": deepcopy(bindings[after])}
            for sequence, (before, after) in enumerate(zip(FOCUS_ORDER, FOCUS_ORDER[1:]), start=1)
        ]
        navigation_state = {"fixture_entries": [self.fixture("focus-sentinel.txt", 99)],
                            "journal_entries": []}
        image = self.add_bytes(str(Path(path).parent / "workbench.png"), tiny_png())
        return {"controls": controls, "focus": [deepcopy(controls[2])],
                "screenshots": [{"file": "workbench.png", "sha256": image.sha256,
                                 "width": 2, "height": 2}],
                "focus_reachability": {
                    "schema_version": 1, "input_method": "keyboard",
                    "initial": deepcopy(bindings[FOCUS_ORDER[0]]), "transitions": transitions,
                    "final": deepcopy(bindings[FOCUS_ORDER[-1]]),
                    "controls": reachability_controls,
                    "state_before": deepcopy(navigation_state),
                    "state_after": deepcopy(navigation_state),
                }}

    def restoration(self, path: str, result: dict, target: dict) -> None:
        prefix = str(Path(path).parent)
        observer_sha = self.bundle["harness"]["observers"]["ui"]["sha256"]
        if target["contrast"] == "high-contrast":
            colors = {key: index for index, key in enumerate(
                ("window", "window_text", "button_face", "button_text", "highlight",
                 "highlight_text", "gray_text", "hot_light"), start=1)}
            setting = {"flags": 1, "scheme": "High Contrast Black", "colors": colors,
                       "visual_style": {"path": "", "color": "", "size": ""}}
            snapshot = {"schema_version": 1, "source_sha": self.candidate.source_sha,
                        "acceptance_script_sha256": observer_sha,
                        "restoration_required": True, "restoration_verified": True,
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
            "layout_observations": self.layout_observations(result_path, environment),
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
        private_root = str(Path(private_index_path).parent)
        rows = []
        for path, data in sorted(raw_files.items()):
            if path == private_index_path:
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
        result = {"schema_version": 1, "source_sha": self.candidate.source_sha,
                  "source_state": "clean",
                  "target": "x86_64-pc-windows-msvc", "failure_reason": None,
                  "transport": {"guest_cleanup": True},
                  "tests": [{"file": "required-tests.exe", "sha256": binary.sha256,
                             "exit_code": 0, "passed": 5, "failed": 0, "ignored": 0,
                             "stdout": {"file": "stdout.txt", "sha256": stdout.sha256},
                             "stderr": {"file": "stderr.txt", "sha256": stderr.sha256}}]}
        self.add_json("backend/bundle.json", bundle)
        self.add_json("backend/result.json", result)
        self.add_json("backend/transport.json", {"guest_cleanup": True})
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


if __name__ == "__main__":
    unittest.main()
