#!/usr/bin/env python3
"""A passing retry, reused execution, or producer lifecycle flag cannot fill a gap."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from tooling_test_paths import REPOSITORY_ROOT
import unittest

from darkrenamer_tooling.campaign.planning import (
    new_plan, validate_ledger, verify_process_job_cleanup, verify_process_lifecycle,
)
from darkrenamer_tooling.contracts.binding import Candidate
from darkrenamer_tooling.evidence.archive import EvidenceError


class CampaignTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads((REPOSITORY_ROOT / 'config/vm-automated-v1.json').read_text())
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

    def test_v2_keeps_full_first_attempt_plan_and_rejects_v1_ledger(self):
        self.profile = json.loads((REPOSITORY_ROOT / 'config/vm-automated-v2.json').read_text())
        self.plan = new_plan(self.profile, profile_sha256='d' * 64, candidate=self.candidate,
                             harness_sha='a' * 40, campaign_id='test-campaign',
                             created_at='2026-09-20T00:00:00Z')
        self.assertEqual(self.plan['schema'], 'darkrenamer-vm-automated-plan-v2')
        with self.assertRaises(EvidenceError):
            self.verify()
        self.campaign['schema'] = 'darkrenamer-vm-automated-campaign-v2'
        self.assertEqual(len(self.verify()), 30)
        for field, value in (('profile_id', 'unknown'), ('revision', 1),
                             ('revision', True), ('schema', 'darkrenamer-vm-automated-profile-v1')):
            saved = self.profile[field]
            self.profile[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(EvidenceError):
                self.verify()
            self.profile[field] = saved

    def test_v1_failed_attempt_cannot_be_relabelled_as_v2_success(self):
        self.profile = json.loads((REPOSITORY_ROOT / 'config/vm-automated-v2.json').read_text())
        # Even a relabelled plan cannot replace a retained failed first attempt.
        self.plan['schema'] = 'darkrenamer-vm-automated-plan-v2'
        self.campaign['schema'] = 'darkrenamer-vm-automated-campaign-v2'
        self.campaign['attempts'][0]['exit_code'] = 1
        with self.assertRaises(EvidenceError):
            self.verify()

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

    def test_forced_lifecycle_requires_random_job_nonce_receipt(self):
        lifecycle = {'pid': 1234, 'session_id': 2, 'start_time_utc_ticks': '639255840000000000',
                     'executable_path': 'C:\\owned\\DarkReNamer.exe', 'executable_sha256': 'b' * 64,
                     'start_observed': True, 'exit_observed': True, 'exit_code': 123456,
                     'exit_method': 'forced-termination'}
        self.assertEqual(verify_process_lifecycle(lifecycle, executable_sha256='b' * 64,
                                                  expected_exit_method='forced-termination'), (1234, 2))
        for exit_code in (0, 1, 259, 0x80000000):
            with self.subTest(exit_code=exit_code), self.assertRaises(EvidenceError):
                verify_process_lifecycle({**lifecycle, 'exit_code': exit_code},
                                         executable_sha256='b' * 64,
                                         expected_exit_method='forced-termination')

    def test_process_job_cleanup_requires_closed_unique_matching_identity(self):
        normal = {'pid': 1234, 'process_start_time_utc_ticks': '639255840000000000',
                  'job_empty': True, 'job_closed': True, 'capture_complete': True,
                  'active_processes_at_primary_exit': None, 'had_survivors': False,
                  'forced_termination': False, 'active_processes_at_close': 0,
                  'active_processes_at_stop': None, 'active_process_ids_at_stop': [],
                  'total_processes_at_stop': None, 'primary_process_active_at_stop': None,
                  'termination_exit_code': None, 'status': 'clean', 'error': None}
        self.assertEqual(verify_process_job_cleanup(
            [normal], expected_processes=[(1234, 639255840000000000)]), [normal])
        for change in ({'job_closed': False}, {'capture_complete': False}, {'had_survivors': True},
                       {'pid': 99}, {'status': 'failed'}):
            with self.subTest(change=change), self.assertRaises(EvidenceError):
                verify_process_job_cleanup([{**normal, **change}],
                                           expected_processes=[(1234, 639255840000000000)])
        forced = {**normal, 'forced_termination': True, 'active_processes_at_stop': 1,
                  'active_process_ids_at_stop': [1234], 'total_processes_at_stop': 1,
                  'primary_process_active_at_stop': True, 'termination_exit_code': 123456}
        self.assertEqual(verify_process_job_cleanup(
            [forced], expected_termination=(1234, 639255840000000000, 123456)), [forced])
        for code in (1, 259):
            with self.subTest(code=code), self.assertRaises(EvidenceError):
                verify_process_job_cleanup(
                    [{**forced, 'termination_exit_code': code}],
                    expected_termination=(1234, 639255840000000000, code))


if __name__ == '__main__':
    unittest.main()
