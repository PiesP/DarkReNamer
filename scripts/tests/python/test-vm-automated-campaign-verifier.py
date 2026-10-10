#!/usr/bin/env python3
"""End-to-end semantic verification of the fixed 30-slot VM campaign."""

from contextlib import ExitStack
from copy import deepcopy
import json
from pathlib import Path
from tooling_test_paths import REPOSITORY_ROOT
import tempfile
import unittest

from campaign_fixture import CampaignFixture
from darkrenamer_tooling.campaign.verifier import verify_complete_campaign
from darkrenamer_tooling.evidence.archive import EvidenceError


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
