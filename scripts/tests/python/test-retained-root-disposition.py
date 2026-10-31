#!/usr/bin/env python3
"""Focused contract tests for the separately collected retained-root proof."""

from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from darkrenamer_tooling.contracts import retained_disposition as contract
from darkrenamer_tooling.evidence.errors import EvidenceError


class RetainedCollectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "collection.json"
        self.vm_id = "11111111-2222-3333-4444-555555555555"
        self.run_name = "DarkReNamerTests-" + "a" * 32
        self.roots = {
            role: {
                "path": "C:\\ProgramData\\DarkReNamerVmRuns\\" + self.run_name +
                        ("-trusted" if role == "trusted" else ""),
                "base_file_id": "a" * 48,
                "file_id": ("b" if role == "guest" else "c") * 48,
                "owner_sid": "S-1-5-32-544",
                "acl_sddl": "O:BAG:BAD:P(A;;FA;;;SY)",
            }
            for role in contract.ROOT_KEYS
        }
        self.target = {"roots": self.roots, "vm_id": self.vm_id,
                       "run_name": self.run_name, "runner_sid": "S-1-5-21-1-2-3-1001",
                       "declared_pids": [101, 102, 103, 104]}
        self.collection = self.make_collection()

    def make_collection(self) -> dict:
        nonce = "d" * 32
        xml = '<Task><Actions><Exec><Command>notepad.exe</Command></Exec></Actions></Task>'
        task = {
            "identity": "\\Example\\Task",
            "principal_user_id": "S-1-5-21-1-2-3-1001",
            "principal_group_id": "",
            "definition_sha256": hashlib.sha256(xml.encode("utf-8")).hexdigest(),
            "definition_xml": xml,
            "resolved_user_sid": "S-1-5-21-1-2-3-1001",
        }
        process = {"pid": 42, "creation_date": "2026-10-31T01:00:00Z", "name": "notepad.exe",
                   "executable_path": "C:\\Windows\\notepad.exe", "command_line": "notepad.exe",
                   "owner_sid": "S-1-5-21-1-2-3-1001"}
        return {
            "schema_version": 1,
            "kind": "maintained_retained_root_collection",
            "operation_nonce": nonce,
            "original_transport_sha256": contract.ORIGINAL_TRANSPORT_SHA256,
            "original_preservation_sha256": contract.ORIGINAL_PRESERVATION_SHA256,
            "vm_id": self.vm_id,
            "run_name": self.run_name,
            "tooling_manifest_sha256": "e" * 64,
            "status": "collected", "errors": [],
            "current": {
                "vm_id": self.vm_id, "operation_nonce": nonce,
                "principal_sid": "S-1-5-21-1-2-3-1001", "principal_name": "TEST\\User",
                "roots": {role: {**row, "index": [
                    {"components_utf16_hex": ["66006f006f00"], "file_id": "f" * 48,
                     "kind": "file", "bytes": 3, "sha256": "0" * 64},
                ]} for role, row in self.roots.items()},
                "process_inventory_complete": True, "task_inventory_complete": True,
                "processes": [process], "tasks": [task],
                "owned_processes": [], "owned_tasks": [], "opaque_processes": [],
                "principal_task_map": [{"identity": task["identity"],
                                        "definition_sha256": task["definition_sha256"]}],
            },
        }

    def verify(self, value: dict) -> dict:
        self.path.write_text(json.dumps(value), encoding="utf-8")
        with mock.patch.object(contract, "verify_original_target", return_value=self.target):
            return contract.verify_current_collection(self.directory.name, self.path,
                                                      tooling_manifest_sha256="e" * 64)

    def test_valid_collection_still_does_not_authorize_deletion_or_admission(self) -> None:
        result = self.verify(self.collection)
        self.assertEqual(result["root_entries"], 2)
        self.assertFalse(result["deletion_authorized"])
        self.assertFalse(result["admission_authorized"])
        self.assertEqual(result["historical_status"], "rejected")

    def test_opaque_authority_encoding_agrees_with_powershell_and_rejects_substitution(self) -> None:
        roots = copy.deepcopy(self.roots)
        roots["guest"]["acl_sddl"] += "Ω"
        expected = contract.authority_digest(self.vm_id, self.run_name, roots)
        changed = copy.deepcopy(roots)
        changed["trusted"]["file_id"] = "d" * 48
        self.assertNotEqual(contract.authority_digest(self.vm_id, self.run_name, changed), expected)
        self.assertNotEqual(contract.authority_digest(self.vm_id, self.run_name + "x", roots), expected)
        changed = copy.deepcopy(roots)
        changed["guest"]["path"] += "\0"
        with self.assertRaises(EvidenceError):
            contract.authority_digest(self.vm_id, self.run_name, changed)
        powershell = shutil.which("pwsh")
        if powershell is None:
            self.skipTest("PowerShell is unavailable for cross-runtime authority encoding")
        source = Path(__file__).resolve().parents[2] / "modules/powershell/controller-retained-disposition.ps1"
        script = (". $env:DR_MAINTAINED_MODULE; "
                  "$p = [Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 20; "
                  "Get-DrMaintainedAuthorityDigest -VmId $p.vm_id -RunName $p.run_name -Roots $p.roots")
        environment = {**os.environ, "DR_MAINTAINED_MODULE": str(source)}
        payload = {"vm_id": self.vm_id, "run_name": self.run_name, "roots": roots}
        result = subprocess.run([powershell, "-NoProfile", "-Command", script],
                                input=json.dumps(payload), text=True, capture_output=True,
                                env=environment, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), expected)
        payload["roots"] = changed
        result = subprocess.run([powershell, "-NoProfile", "-Command", script],
                                input=json.dumps(payload), text=True, capture_output=True,
                                env=environment, timeout=30, check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_target_and_current_binding_fail_closed(self) -> None:
        changes = (
            lambda x: x.update(vm_id="11111111-2222-3333-4444-555555555556"),
            lambda x: x.update(tooling_manifest_sha256="f" * 64),
            lambda x: x["current"]["roots"]["guest"].update(file_id="f" * 48),
            lambda x: x["current"]["roots"]["trusted"].update(acl_sddl="changed"),
            lambda x: x["current"]["roots"]["guest"].pop("index"),
            lambda x: x["current"].update(task_inventory_complete=False),
            lambda x: x["current"].update(owned_processes=[{"pid": 42}]),
            lambda x: x["current"]["tasks"][0].update(definition_sha256="0" * 64),
            lambda x: x["current"]["processes"][0].update(
                command_line=self.run_name),
        )
        for change in changes:
            with self.subTest(change=change):
                value = copy.deepcopy(self.collection)
                change(value)
                with self.assertRaises(EvidenceError):
                    self.verify(value)

    def test_duplicate_or_unbounded_index_fails_closed(self) -> None:
        duplicate = copy.deepcopy(self.collection)
        duplicate["current"]["roots"]["guest"]["index"].append(
            copy.deepcopy(duplicate["current"]["roots"]["guest"]["index"][0]))
        with self.assertRaises(EvidenceError):
            self.verify(duplicate)
        oversized = copy.deepcopy(self.collection)
        oversized["current"]["roots"]["guest"]["index"][0]["bytes"] = 512 * 1024 * 1024 + 1
        with self.assertRaises(EvidenceError):
            self.verify(oversized)

    def test_classification_requires_source_pin_and_every_indexed_entry(self) -> None:
        self.verify(self.collection)
        collection_hash = hashlib.sha256(self.path.read_bytes()).hexdigest()
        plan = {
            "schema_version": 1, "kind": "maintained_retained_root_classification",
            "original_transport_sha256": contract.ORIGINAL_TRANSPORT_SHA256,
            "original_preservation_sha256": contract.ORIGINAL_PRESERVATION_SHA256,
            "collection_sha256": collection_hash,
            "collection_nonce": self.collection["operation_nonce"],
            "vm_id": self.vm_id, "run_name": self.run_name,
            "bounds": {"maximum_seconds": 600, "maximum_entries": 2,
                       "maximum_content_bytes": 6,
                       "rationale": "Two exact indexed files, three bytes per root."},
            "classified_entries": {
                role: [{"components_utf16_hex": ["66006f006f00"], "file_id": "f" * 48,
                        "kind": "file", "classification": "exact_run_disposable",
                        "reason": "Reviewed run-owned fixture file."}]
                for role in contract.ROOT_KEYS
            },
        }
        plan_path = Path(self.directory.name) / "reviewed-plan.json"
        plan_path.write_text(json.dumps(plan), encoding="utf-8")
        digest = hashlib.sha256(plan_path.read_bytes()).hexdigest()
        with self.assertRaises(EvidenceError):
            contract.verify_reviewed_classification(self.path, plan_path)
        reviewed = contract.verify_reviewed_classification(
            self.path, plan_path, approved_sha256=digest)
        self.assertEqual(reviewed["entries"], 2)
        self.assertFalse(reviewed["deletion_authorized"])
        for mutation in (
            lambda x: x["classified_entries"]["guest"].clear(),
            lambda x: x["classified_entries"]["guest"][0].update(file_id="0" * 48),
            lambda x: x["bounds"].update(maximum_content_bytes=5),
        ):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(plan)
                mutation(changed)
                plan_path.write_text(json.dumps(changed), encoding="utf-8")
                with self.assertRaises(EvidenceError):
                    contract.verify_reviewed_classification(
                        self.path, plan_path, approved_sha256=hashlib.sha256(
                            plan_path.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
