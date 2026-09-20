#!/usr/bin/env python3
"""Candidate and trusted-source binding failure injection."""

from copy import deepcopy
import hashlib
from pathlib import Path
from tooling_test_paths import REPOSITORY_ROOT
from unittest import TestCase, main
from unittest.mock import patch

from darkrenamer_tooling.contracts.binding import (
    COMPONENTS, Candidate, trusted_component_hashes, verify_candidate_bundle,
    verify_result_binding,
)
from darkrenamer_tooling.evidence.archive import EvidenceError


class BindingTests(TestCase):
    def setUp(self):
        self.candidate = Candidate("a" * 40, "10", "1", "20", "e" * 64, "f" * 64)
        self.hashes = {role: hashlib.sha256(role.encode()).hexdigest() for role in COMPONENTS}
        self.bundle = {
            "schema_version": 2, "lane": "candidate-gui-only", "target": "x86_64-pc-windows-msvc", "test_binaries": [],
            "product": {
                "source_sha": "a" * 40, "source_state": "clean",
                "candidate": {"workflow_run": "10", "run_attempt": "1", "artifact_id": "20",
                              "artifact_name": "DarkReNamer-dry-run-10-1-windows", "origin_authentication": "pending-hosted"},
                "application": {"file": "DarkReNamer.exe", "sha256": "e" * 64},
                "provenance": {key: {"file": name, "sha256": "f" * 64} for key, name in (
                    ("release_handoff", "release-handoff.json"), ("run_metadata", "candidate-run.json"),
                    ("artifact_metadata", "candidate-artifact.json"))},
            },
            "harness": {"source_sha": "a" * 40, "source_state": "clean", "validators": {}, "observers": {}},
        }
        for role, name in COMPONENTS.items():
            parts = role.split(".")
            parent = self.bundle["harness"] if len(parts) == 1 else self.bundle["harness"][parts[0]]
            parent[parts[-1]] = {"file": name, "sha256": self.hashes[role]}

    def verify(self, bundle=None, **kwargs):
        verify_candidate_bundle(self.bundle if bundle is None else bundle, expected=self.candidate,
                                harness_sha=kwargs.get("harness_sha", "a" * 40),
                                component_hashes=self.hashes, release=kwargs.get("release", True))

    def test_exact_authenticated_candidate_and_trusted_blobs(self):
        self.verify()

    def test_each_candidate_identity_mismatch_and_numeric_alias_fails(self):
        for field in ("workflow_run", "run_attempt", "artifact_id"):
            for value in ("99", "01", 1, True, "1/attempts/2"):
                changed = deepcopy(self.bundle)
                changed["product"]["candidate"][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(EvidenceError):
                    self.verify(changed)

    def test_local_origin_claim_is_not_authentication(self):
        self.bundle["product"]["candidate"]["origin_authentication"] = "authenticated"
        with self.assertRaises(EvidenceError):
            self.verify()

    def test_mismatched_product_and_harness_is_trial_only(self):
        self.bundle["harness"]["source_sha"] = "b" * 40
        self.verify(harness_sha="b" * 40, release=False)
        with self.assertRaises(EvidenceError):
            self.verify(harness_sha="b" * 40)

    def test_each_observer_and_validator_is_pinned_to_trusted_blob(self):
        for role in COMPONENTS:
            changed = deepcopy(self.bundle)
            parts = role.split(".")
            row = changed["harness"][parts[0]] if len(parts) == 1 else changed["harness"][parts[0]][parts[1]]
            row["sha256"] = "0" * 64
            with self.subTest(role=role), self.assertRaises(EvidenceError):
                self.verify(changed)

    def test_extra_missing_and_unsafe_component_filenames_fail(self):
        for field in ("launcher", "controller", "runner"):
            changed = deepcopy(self.bundle)
            changed["harness"][field]["file"] = "../" + changed["harness"][field]["file"]
            with self.assertRaises(EvidenceError):
                self.verify(changed)
        self.bundle["harness"]["observers"]["unknown"] = self.bundle["harness"]["observers"]["ui"]
        with self.assertRaises(EvidenceError):
            self.verify()

    def test_handoff_and_executable_hashes_are_independent_pins(self):
        for row in (self.bundle["product"]["application"], self.bundle["product"]["provenance"]["release_handoff"]):
            old = row["sha256"]
            row["sha256"] = "0" * 64
            with self.assertRaises(EvidenceError):
                self.verify()
            row["sha256"] = old

    def test_candidate_lane_never_supplies_backend_evidence(self):
        self.bundle["test_binaries"] = [{"file": "tests.exe", "sha256": "1" * 64}]
        with self.assertRaises(EvidenceError):
            self.verify()

    def test_returned_result_cannot_select_different_product_or_role(self):
        for observer in ("core", "ui", "recovery"):
            result = deepcopy(self.bundle)
            if observer != "core":
                result.update(observer_role=observer, runner_sha256=self.hashes["runner"],
                              application=self.bundle["product"]["application"])
                if observer == "ui":
                    result["acceptance_script_sha256"] = self.hashes["observers.ui"]
                else:
                    result["observer"] = self.bundle["harness"]["observers"]["recovery"]
                    result.pop("target")
            verify_result_binding(result, self.bundle, observer=observer)
            result["product"]["source_sha"] = "b" * 40
            with self.assertRaises(EvidenceError):
                verify_result_binding(result, self.bundle, observer=observer)

    def test_trusted_blobs_are_fixed_git_paths_not_archive_script_paths(self):
        calls = []

        def output(argv, **kwargs):
            calls.append(argv)
            if argv[1] == "rev-parse":
                return "a" * 40 + "\n"
            if argv[1] == "ls-tree":
                return "100644 blob " + "b" * 40 + "\t" + argv[-1] + "\n"
            return argv[-1].encode()

        with patch("darkrenamer_tooling.contracts.binding.subprocess.check_output", side_effect=output):
            hashes = trusted_component_hashes(REPOSITORY_ROOT, "a" * 40)
        self.assertEqual(set(hashes), set(COMPONENTS))
        self.assertEqual({call[-1] for call in calls if call[1] == "show"},
                         {"a" * 40 + ":scripts/" + name for name in COMPONENTS.values()})

    def test_symlink_git_blob_is_rejected(self):
        with patch("darkrenamer_tooling.contracts.binding.subprocess.check_output", side_effect=[
            "a" * 40 + "\n", "120000 blob " + "b" * 40 + "\tscripts/test-windows-vm.py\n",
        ]), self.assertRaises(EvidenceError):
            trusted_component_hashes(REPOSITORY_ROOT, "a" * 40)


if __name__ == "__main__":
    main()
