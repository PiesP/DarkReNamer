#!/usr/bin/env python3
"""A passing retry, reused execution, or producer lifecycle flag cannot fill a gap."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import unittest

from vm_automated_binding import Candidate
from vm_automated_campaign import new_plan, validate_ledger, verify_process_lifecycle
from vm_automated_evidence import EvidenceError


class CampaignTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads((Path(__file__).resolve().parents[1] / 'config/vm-automated-v1.json').read_text())
        self.candidate = Candidate('a' * 40, '12', '1', '34', 'b' * 64, 'c' * 64)
        self.plan = new_plan(self.profile, profile_sha256='d' * 64, candidate=self.candidate,
                             harness_sha='a' * 40, campaign_id='test-campaign', created_at='2026-09-20T00:00:00Z')
        start = datetime(2026, 9, 20, tzinfo=timezone.utc)
        self.campaign = {'schema': 'darkrenamer-vm-automated-campaign-v1', 'campaign_id': 'test-campaign',
                         'plan': 'plan.json', 'backend': {}, 'attempts': []}
        for index, slot in enumerate(self.plan['slots']):
            prefix = 'runs/' + slot['id'] + '/'
            self.campaign['attempts'].append({
                'slot_id': slot['id'], 'attempt': 1, 'exit_code': 0,
                'started_at': (start + timedelta(seconds=index * 60)).isoformat().replace('+00:00', 'Z'),
                'ended_at': (start + timedelta(seconds=index * 60 + 30)).isoformat().replace('+00:00', 'Z'),
                **{field: prefix + field + '.json' for field in ('bundle', 'result', 'transport', 'desktop_lease')}})

    def verify(self):
        return validate_ledger(self.plan, self.campaign, profile=self.profile, profile_sha256='d' * 64,
                               candidate=self.candidate, harness_sha='a' * 40)

    def test_full_profile_has_twenty_cells_and_ten_fresh_stability_slots(self):
        self.assertEqual(len(self.verify()), 30)
        self.assertEqual(len([row for row in self.plan['slots'] if row['stability_index'] is not None]), 10)

    def test_menu_only_variant_cannot_move_to_another_cell_or_be_implicit(self):
        original = deepcopy(self.profile)
        for target_id, variant in (("layout-small-text150-100", None),
                                   ("layout-small-normal-100", "native-menu-only"),
                                   ("layout-normal-200", "adaptive")):
            self.profile = deepcopy(original)
            target = next(row for row in self.profile["required_targets"] if row["id"] == target_id)
            if variant is None:
                target.pop("layout_variant")
            else:
                target["layout_variant"] = variant
            with self.subTest(target=target_id), self.assertRaises(EvidenceError):
                self.verify()

    def test_retry_missing_or_duplicate_attempt_cannot_hide_first_failure(self):
        original = deepcopy(self.campaign)
        for mutation in ('failed', 'retry', 'missing', 'extra', 'duplicate'):
            self.campaign = deepcopy(original)
            rows = self.campaign['attempts']
            if mutation == 'failed': rows[0]['exit_code'] = 1
            elif mutation == 'retry': rows[0]['attempt'] = 2
            elif mutation == 'missing': rows.pop()
            elif mutation == 'extra': rows.append(deepcopy(rows[0]))
            else: rows[1] = deepcopy(rows[0])
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                self.verify()

    def test_reused_output_overlap_or_plan_rewrite_fails(self):
        original = deepcopy(self.campaign)
        for field, value in (('result', self.campaign['attempts'][0]['result']),
                             ('started_at', '2026-09-20T00:00:01Z'), ('exit_code', False)):
            self.campaign = deepcopy(original)
            self.campaign['attempts'][1][field] = value
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                self.verify()
        self.campaign = original
        self.plan['slots'][-1]['stability_index'] = True
        with self.assertRaises(EvidenceError): self.verify()

    def test_source_or_candidate_substitution_fails(self):
        self.plan['candidate']['executable_sha256'] = 'e' * 64
        with self.assertRaises(EvidenceError): self.verify()

    def test_lifecycle_requires_exact_image_normal_exit_and_real_numeric_identity(self):
        lifecycle = {'pid': 1234, 'session_id': 2, 'start_time_utc_ticks': '639255840000000000',
                     'executable_path': 'C:\\owned\\DarkReNamer.exe', 'executable_sha256': 'b' * 64,
                     'start_observed': True, 'exit_observed': True, 'exit_code': 0, 'exit_method': 'normal-close'}
        self.assertEqual(verify_process_lifecycle(lifecycle, executable_sha256='b' * 64), (1234, 2))
        for field, value in (('pid', True), ('session_id', 0), ('exit_observed', False),
                             ('exit_code', 1), ('exit_method', 'forced-termination'),
                             ('executable_sha256', 'e' * 64), ('start_time_utc_ticks', '01'),
                             ('executable_path', 'relative\\DarkReNamer.exe')):
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_process_lifecycle({**lifecycle, field: value}, executable_sha256='b' * 64)


if __name__ == '__main__':
    unittest.main()
