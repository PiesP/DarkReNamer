"""Independent preserved-failure and owned-cleanup evidence contracts."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from darkrenamer_tooling.contracts.owned_cleanup import (
    _observer_finished, _process_jobs, _reject_owned_entries, _restoration, _setting_snapshot,
    _v2_finalizer_inventory, _owned_performance_predelete,
    verify_owned_performance_text_scale, OWNED_PERFORMANCE_PROFILE_SHA256,
    verify_preserved_owned_cleanup,
)
from darkrenamer_tooling.evidence.archive import EvidenceError
from controller_cleanup_fixture import (
    V2_PROFILE_SHA256, clean_controller_cleanup_v2,
    clean_controller_cleanup_v3_protected,
)


RUN = 'DarkReNamerTests-' + 'a' * 32
VM = '11111111-2222-3333-4444-555555555555'


def write(path, value):
    data = (json.dumps(value, separators=(',', ':')) + '\n').encode()
    path.write_bytes(data)
    return data


def digest(data):
    return hashlib.sha256(data).hexdigest()


def process_result(source_sha):
    return {'source_sha': source_sha,
            'process_lifecycle': {'pid': 123, 'start_time_utc_ticks': '123456'},
            'process_job_cleanup': [{
                'pid': 123, 'process_start_time_utc_ticks': '123456',
                'job_empty': True, 'job_closed': True, 'capture_complete': True,
                'had_survivors': False, 'forced_termination': False,
                'active_processes_at_primary_exit': 0, 'active_processes_at_close': 0,
                'active_processes_at_stop': None, 'active_process_ids_at_stop': [],
                'total_processes_at_stop': None, 'primary_process_active_at_stop': None,
                'termination_exit_code': None, 'status': 'clean', 'error': None,
            }]}


def high_contrast_snapshot(scheme):
    return {'flags': 1, 'scheme': scheme,
            'colors': {key: 0 for key in ('window', 'window_text', 'button_face',
                       'button_text', 'highlight', 'highlight_text', 'gray_text', 'hot_light')},
            'visual_style': {'path': r'C:\Windows\Resources\Themes\aero.msstyles',
                             'color': 'NormalColor', 'size': 'NormalSize'}}


def text_scale_snapshot(factor):
    return {'registry_key_existed': True, 'registry_value_existed': True,
            'registry_value_kind': 'DWord', 'registry_value': 100,
            'ui_settings_raw_factor': factor, 'ui_settings_percent': round(factor * 100)}


class OwnedPerformanceRestorationTests(unittest.TestCase):
    def test_coherent_registry_presence_and_observed_absence(self):
        for present in (True, False):
            row = text_scale_snapshot(1.0)
            if not present:
                row.update(registry_key_existed=False, registry_value_existed=False,
                           registry_value_kind=None, registry_value=None)
            proof = {'text_scale_restoration': {'schema_version': 1, 'baseline': row,
                                                'final': deepcopy(row), 'snapshot_equal': True}}
            self.assertEqual(verify_owned_performance_text_scale(proof)['snapshot_equal'], True)
            for field, value in (('registry_value', 150), ('registry_value_kind', 'String'),
                                 ('ui_settings_raw_factor', 1.5), ('ui_settings_percent', 150)):
                broken = deepcopy(proof)
                broken['text_scale_restoration']['final'][field] = value
                with self.subTest(present=present, field=field), self.assertRaises(EvidenceError):
                    verify_owned_performance_text_scale(broken)
            broken = deepcopy(proof)
            broken['text_scale_restoration']['final'] = None
            with self.assertRaises(EvidenceError):
                verify_owned_performance_text_scale(broken)
            broken = deepcopy(proof)
            broken['text_scale_restoration']['final']['ui_settings_raw_factor'] = 1
            with self.assertRaises(EvidenceError):
                verify_owned_performance_text_scale(broken)

    def test_predelete_receipt_recomputes_frozen_bytes_and_rejects_forgery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_id = 'performance-sample-v2-owned-r3-1366x768-96-text100-hidden-visible'
            source = '9' * 40
            bundle_sha = 'b' * 64
            application_sha = 'c' * 64
            profile_bytes = Path(__file__).resolve().parents[3].joinpath(
                'config/vm-automated-v2.json').read_bytes()
            self.assertEqual(digest(profile_bytes), OWNED_PERFORMANCE_PROFILE_SHA256)
            (root / 'owned-performance-profile.json').write_bytes(profile_bytes)
            manifest = {'run_id': run_id, 'source_sha': source,
                        'acceptance_profile_id': 'vm-automated-v2-owned-resources',
                        'acceptance_profile_sha256': OWNED_PERFORMANCE_PROFILE_SHA256,
                        'acceptance_profile': {'sha256': OWNED_PERFORMANCE_PROFILE_SHA256},
                        'bundle_manifest': {'sha256': bundle_sha},
                        'request': {'mode': 'performance-sample',
                                    'performance_plan': {'long_path_order': 'hidden-visible'}},
                        'artifacts': {'application': {'sha256': application_sha}}}
            observations = {'run_id': run_id,
                            'text_scale_restoration': {'schema_version': 1,
                                'baseline': text_scale_snapshot(1.0),
                                'final': text_scale_snapshot(1.0), 'snapshot_equal': True}}
            observation_bytes = write(root / 'acceptance-observations.json', observations)
            result = {'source_sha': source, 'application': {'sha256': application_sha},
                      'observations': {'sha256': digest(observation_bytes)},
                      'acceptance_observations': observations}
            write(root / 'acceptance-result.json', result)
            write(root / 'owned-performance-input-manifest.json', manifest)
            write(root / 'bundle.json', {'source_sha': source})
            original_bytes = write(root / 'original-transport.json', {'status': 'failed'})
            receipt_bytes = b'{"preserved":true}\n'
            signal_bytes = b'{"closed":true}\n'
            lease_bytes = b'{"stopped":true}\n'
            indexed = {name: {'file': name, 'bytes': (root / name).stat().st_size,
                              'sha256': digest((root / name).read_bytes())}
                       for name in ('original-transport.json', 'acceptance-result.json',
                                    'acceptance-observations.json', 'owned-performance-input-manifest.json',
                                    'owned-performance-profile.json', 'bundle.json')}
            roots = {'guest': {'file_id': 'a' * 48}, 'trusted': {'file_id': 'b' * 48}}
            original = {'owned_cleanup_failure_context': {'source_sha': source,
                'acceptance_mode': 'performance-sample',
                'bundle': {'sha256': bundle_sha},
                'source_result': indexed['acceptance-result.json']}}
            receipt = {'run_name': RUN, 'vm_id': VM, 'nonce': 'f' * 32,
                       'desktop_lease_id': 'd' * 32, 'root_records': roots,
                       'original_transport': indexed['original-transport.json']}
            refs = dict(indexed)
            for name, blob in (('owned-cleanup-strict-failure-preservation.json', receipt_bytes),
                               ('owned-cleanup-desktop-closed.json', signal_bytes),
                               ('desktop-lease.json', lease_bytes)):
                refs[name] = {'file': name, 'bytes': len(blob), 'sha256': digest(blob)}
            frozen = {'schema_version': 1, 'kind': 'owned_performance_predelete_restoration',
                      'run_name': RUN, 'run_id': run_id, 'vm_id': VM, 'nonce': 'f' * 32,
                      'desktop_lease_id': 'd' * 32, 'source_sha': source,
                      'bundle_sha256': bundle_sha, 'profile_id': 'vm-automated-v2-owned-resources',
                      'profile_sha256': OWNED_PERFORMANCE_PROFILE_SHA256,
                      'roots': roots, 'files': refs}
            predelete_path = root / 'owned-performance-predelete.json'
            def verify():
                proof = {'predelete_sha256': (digest(predelete_path.read_bytes())
                                              if predelete_path.exists() else '0' * 64)}
                _owned_performance_predelete(root, original, receipt, proof, indexed,
                                             receipt_bytes, signal_bytes, lease_bytes)
            write(predelete_path, frozen)
            verify()
            for mutation in ('missing', 'stale-hash', 'wrong-root', 'wrong-observation',
                             'wrong-profile', 'wrong-lease'):
                with self.subTest(mutation=mutation):
                    altered = deepcopy(frozen)
                    if mutation == 'wrong-root':
                        altered['roots']['guest']['file_id'] = 'e' * 48
                    elif mutation == 'wrong-observation':
                        altered['files']['acceptance-observations.json']['sha256'] = 'e' * 64
                    elif mutation == 'wrong-profile':
                        altered['profile_sha256'] = 'e' * 64
                    elif mutation == 'wrong-lease':
                        altered['desktop_lease_id'] = 'e' * 32
                    if mutation == 'missing':
                        predelete_path.unlink()
                    elif mutation == 'stale-hash':
                        predelete_path.write_bytes(b'{"forged":true}\n')
                    else:
                        write(predelete_path, altered)
                    with self.assertRaises(EvidenceError):
                        verify()
                    write(predelete_path, frozen)
            # The new focused selector reuses the same source/profile/desktop gate.
            picker_id = 'picker-identity-observation-v1-1366x768-96-text100'
            picker_plan = {'ordinary_rows': [100], 'idle_ms': 1000,
                           'picker_settle_ms': 350, 'sample_interval_ms': 200,
                           'maximum_seconds': 120, 'command_timeout_ms': 5000,
                           'fixture_file_limit': 100, 'full_performance_sample': False}
            manifest['run_id'] = observations['run_id'] = frozen['run_id'] = picker_id
            manifest['request'] = {'mode': 'picker-identity-observation',
                                   'picker_identity_plan': picker_plan}
            original['owned_cleanup_failure_context']['acceptance_mode'] = 'picker-identity-observation'
            observation_bytes = write(root / 'acceptance-observations.json', observations)
            result['observations']['sha256'] = digest(observation_bytes)
            result['acceptance_observations'] = observations
            write(root / 'acceptance-result.json', result)
            write(root / 'owned-performance-input-manifest.json', manifest)
            for name in ('acceptance-observations.json', 'acceptance-result.json',
                         'owned-performance-input-manifest.json'):
                indexed[name] = {'file': name, 'bytes': (root / name).stat().st_size,
                                 'sha256': digest((root / name).read_bytes())}
                refs[name] = indexed[name]
            original['owned_cleanup_failure_context']['source_result'] = indexed['acceptance-result.json']
            write(predelete_path, frozen)
            verify()
            for mutation in ('wrong-mode', 'wrong-plan', 'wrong-profile', 'missing-observation'):
                with self.subTest(picker_mutation=mutation):
                    changed = deepcopy(manifest)
                    if mutation == 'wrong-mode': changed['request']['mode'] = 'performance-sample'
                    elif mutation == 'wrong-plan': changed['request']['picker_identity_plan']['idle_ms'] = 30000
                    elif mutation == 'wrong-profile': changed['acceptance_profile_sha256'] = 'e' * 64
                    else: changed['request'].pop('picker_identity_plan')
                    write(root / 'owned-performance-input-manifest.json', changed)
                    indexed['owned-performance-input-manifest.json'] = {
                        'file': 'owned-performance-input-manifest.json',
                        'bytes': (root / 'owned-performance-input-manifest.json').stat().st_size,
                        'sha256': digest((root / 'owned-performance-input-manifest.json').read_bytes())}
                    refs['owned-performance-input-manifest.json'] = indexed['owned-performance-input-manifest.json']
                    write(predelete_path, frozen)
                    with self.assertRaises(EvidenceError): verify()
                    write(root / 'owned-performance-input-manifest.json', manifest)
                    indexed['owned-performance-input-manifest.json'] = {
                        'file': 'owned-performance-input-manifest.json',
                        'bytes': (root / 'owned-performance-input-manifest.json').stat().st_size,
                        'sha256': digest((root / 'owned-performance-input-manifest.json').read_bytes())}
                    refs['owned-performance-input-manifest.json'] = indexed['owned-performance-input-manifest.json']
                    write(predelete_path, frozen)


class OwnedCleanupTests(unittest.TestCase):
    def test_v2_finalizer_distinguishes_reused_parent_from_owned_lifetime(self):
        cleanup = clean_controller_cleanup_v2()
        evidence = cleanup['owned_resource_evidence']
        evidence['declared_processes'][0]['pid'] = 9432
        evidence['declared_processes'][0]['start_time_utc_ticks'] = '639268888530000008'
        row = deepcopy(evidence['process_snapshots']['after_delete']['processes'][0])
        row.update(pid=3636, identity='3636|2025-10-05T13:31:43.0000000Z',
                   creation_time_utc='2025-10-05T13:31:43.0000000Z', parent_pid=9432)
        snapshot = {'tasks': [], 'processes': [row]}
        def verify():
            _v2_finalizer_inventory(snapshot, snapshot, snapshot, cleanup,
                                    evidence['root_records'], evidence['run_name'])

        verify()
        row['creation_time_utc'] = '2026-10-06T13:07:33.0000000Z'
        row['identity'] = '3636|' + row['creation_time_utc']
        with self.assertRaises(EvidenceError):
            verify()
        row['parent_pid'] = 100
        row['pid'] = 9432
        row['identity'] = '9432|' + row['creation_time_utc']
        with self.assertRaises(EvidenceError):
            verify()
        row['pid'] = 3636
        row['parent_pid'] = 9432
        row['creation_time_utc'] = '2025-10-05T13:31:43.0000000Z'
        row['identity'] = '3636|' + row['creation_time_utc']
        row['command_line'] += ' ' + evidence['root_records']['guest']['path']
        with self.assertRaises(EvidenceError):
            verify()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source_sha = '9' * 40
        bundle_bytes = write(self.root / 'bundle.json', {'source_sha': source_sha})
        result_bytes = write(self.root / 'original-result.json', process_result(source_sha))
        base = 'c' * 48
        self.roots = {
            role: {'path': 'C:\\ProgramData\\DarkReNamerVmRuns\\' + RUN + suffix,
                   'base_file_id': base, 'file_id': identifier * 48,
                   'owner_sid': 'S-1-5-32-544', 'acl_sddl': 'O:BAG:BAD:PAI'}
            for role, suffix, identifier in (('guest', '', 'd'), ('trusted', '-trusted', 'e'))
        }
        self.frozen = {'complete': True, 'processes': [], 'tasks': [], 'owned_processes': []}
        self.original = {'vm_id': VM, 'task_kind': 'core', 'status': 'failed',
                         'guest_cleanup': False,
                         'owned_cleanup_failure_context': {
            'task_kind': 'core', 'failed_snapshot': self.frozen, 'root_records': self.roots,
            'source_result': {'file': 'original-result.json', 'bytes': len(result_bytes),
                              'sha256': digest(result_bytes)},
            'bundle': {'file': 'bundle.json', 'bytes': len(bundle_bytes),
                       'sha256': digest(bundle_bytes)},
            'source_sha': source_sha, 'observer_sha256': None, 'acceptance_mode': None,
            'high_contrast_requested': False, 'output_preservation_verified': True,
        }, 'raw_cleanup': {
            'scheduled_task_present': False, 'owned_processes_after': [],
            'removed_runner_tasks': [], 'terminated_runner_processes': [],
            'resource_cleanup_errors': [],
            'guest_root_present': True, 'trusted_task_root_present': True,
            'process_jobs_closed': True, 'runner_process_inventory_complete': True,
            'unexpected_runner_tasks': [{'identity': 'unknown',
                                         'definition_sha256': 'a' * 64}],
            'unexpected_runner_processes': [],
            'unexpected_runner_tasks_after_intervention': [],
            'unexpected_runner_processes_after_intervention': [],
            'unexpected_runner_tasks_after_delete': None,
            'unexpected_runner_processes_after_delete': None,
            'runner_process_natural_exit': {'status': 'rejected'},
        }}
        original_bytes = write(self.root / 'original-transport.json', self.original)
        self.receipt = {
            'schema_version': 1, 'kind': 'owned_cleanup_strict_failure_preservation',
            'run_name': RUN, 'vm_id': VM, 'nonce': 'f' * 32,
            'desktop_lease_id': 'b' * 32,
            'original_transport': {'file': 'original-transport.json',
                                   'bytes': len(original_bytes), 'sha256': digest(original_bytes)},
            'files': [
                {'file': 'original-transport.json', 'bytes': len(original_bytes),
                 'sha256': digest(original_bytes)},
                {'file': 'original-result.json', 'bytes': len(result_bytes),
                 'sha256': digest(result_bytes)},
                {'file': 'bundle.json', 'bytes': len(bundle_bytes),
                 'sha256': digest(bundle_bytes)},
            ],
            'failed_snapshot': self.frozen, 'root_records': self.roots,
        }
        receipt_bytes = write(self.root / 'owned-cleanup-strict-failure-preservation.json', self.receipt)
        lease_bytes = write(self.root / 'desktop-lease.json', {
            'mode': 'managed-rdp', 'stop_status': 'stopped', 'cleanup_observed': True,
            'lease_id': 'b' * 32})
        self.signal = {'schema_version': 1, 'nonce': 'f' * 32,
                       'preservation_sha256': digest(receipt_bytes),
                       'desktop_lease_sha256': digest(lease_bytes)}
        write(self.root / 'owned-cleanup-desktop-closed.json', self.signal)
        observed = {role: {**row, 'ordinary_directory': True}
                    for role, row in self.roots.items()}
        inventory = {**self.frozen, 'owned_tasks': []}
        self.proof = {
            'schema_version': 1, 'kind': 'owned_cleanup_after_strict_failure',
            'run_name': RUN, 'vm_id': VM, 'nonce': 'f' * 32, 'status': 'owned-clean',
            'pre': inventory, 'post': inventory, 'roots': self.roots,
            'observed_roots_before': observed,
            'observed_roots_after': {'guest_present': False, 'trusted_present': False},
            'errors': [], 'preservation_sha256': digest(receipt_bytes),
            'desktop_lease_sha256': digest(lease_bytes),
            'original_transport_sha256': digest(original_bytes),
        }
        write(self.root / 'owned-cleanup-after-strict-failure.json', self.proof)

    def rebind_original(self):
        original_bytes = write(self.root / 'original-transport.json', self.original)
        reference = {'file': 'original-transport.json', 'bytes': len(original_bytes),
                     'sha256': digest(original_bytes)}
        self.receipt['original_transport'] = reference
        self.receipt['files'][0] = reference
        receipt_bytes = write(self.root / 'owned-cleanup-strict-failure-preservation.json', self.receipt)
        self.proof['original_transport_sha256'] = digest(original_bytes)
        self.proof['preservation_sha256'] = digest(receipt_bytes)
        self.signal['preservation_sha256'] = digest(receipt_bytes)
        write(self.root / 'owned-cleanup-after-strict-failure.json', self.proof)
        write(self.root / 'owned-cleanup-desktop-closed.json', self.signal)

    def test_independent_owned_cleanup_keeps_environment_rejected(self):
        self.assertEqual(verify_preserved_owned_cleanup(self.root), {
            'environment': 'strict-failed', 'owned_cleanup': 'owned-clean',
            'acceptance': 'rejected',
        })

    def test_first_clear_failed_ui_can_preserve_owned_cleanup_without_acceptance(self):
        source_sha = '9' * 40
        observer_sha = '8' * 64
        ui_root = self.root / 'ui'
        ui_root.mkdir()
        for path in tuple(self.root.iterdir()):
            if path != ui_root and path.name != 'bundle.json':
                path.rename(ui_root / path.name)
        (ui_root / 'bundle.json').write_bytes((self.root / 'bundle.json').read_bytes())
        (self.root / 'bundle.json').unlink()
        self.root = ui_root
        result_path = self.root / 'acceptance-result.json'
        result = process_result(source_sha)
        result.update(status='failed', failure_reason='gui_regression_observer_failed',
                      acceptance_script_sha256=observer_sha)
        result_bytes = write(result_path, result)
        (self.root / 'original-result.json').unlink()
        context = self.original['owned_cleanup_failure_context']
        context.update(task_kind='ui', observer_sha256=observer_sha,
                       acceptance_mode='first-clear-observation',
                       acceptance_text_scale_percent=100)
        context['source_result'] = {'file': result_path.name, 'bytes': len(result_bytes),
                                    'sha256': digest(result_bytes)}
        self.original['task_kind'] = 'ui'
        self.original['observer_process'] = {'state': 'exited', 'exit_code': 1}
        self.receipt['files'][1] = context['source_result']
        self.rebind_original()
        self.assertEqual(verify_preserved_owned_cleanup(self.root), {
            'environment': 'strict-failed', 'owned_cleanup': 'owned-clean',
            'acceptance': 'rejected',
        })
        for mode in ('performance-sample', 'appearance-pair'):
            context['acceptance_mode'] = mode
            if mode == 'appearance-pair':
                context['acceptance_text_scale_percent'] = 100
            self.rebind_original()
            with self.subTest(mode=mode):
                self.assertEqual(verify_preserved_owned_cleanup(self.root)['acceptance'], 'rejected')
        context['acceptance_mode'] = 'picker-identity-observation'
        self.rebind_original()
        with self.assertRaisesRegex(EvidenceError, 'reviewed V2 revision-3'):
            verify_preserved_owned_cleanup(self.root)
        context['acceptance_mode'] = 'appearance-pair'
        context['acceptance_text_scale_percent'] = 150
        self.rebind_original()
        with self.assertRaises(EvidenceError):
            verify_preserved_owned_cleanup(self.root)
        context['acceptance_text_scale_percent'] = 100
        context['high_contrast_requested'] = True
        self.rebind_original()
        with self.assertRaises(EvidenceError):
            verify_preserved_owned_cleanup(self.root)
        context['high_contrast_requested'] = False
        context.pop('acceptance_text_scale_percent')
        context['acceptance_mode'] = 'picker-identity-observation'
        self.rebind_original()
        with self.assertRaises(EvidenceError):
            verify_preserved_owned_cleanup(self.root)
        context['acceptance_mode'] = 'unrelated-mode'
        context['acceptance_text_scale_percent'] = 100
        self.rebind_original()
        with self.assertRaises(EvidenceError):
            verify_preserved_owned_cleanup(self.root)
        context['acceptance_mode'] = 'first-clear-observation'
        context['acceptance_text_scale_percent'] = 100
        # Old native UI roots can use the parent bundle when the frozen output
        # inventory never claimed a copied bundle at the output root.
        (self.root.parent / 'bundle.json').write_bytes((self.root / 'bundle.json').read_bytes())
        (self.root / 'bundle.json').unlink()
        self.receipt['files'] = [row for row in self.receipt['files'] if row['file'] != 'bundle.json']
        self.rebind_original()
        self.assertEqual(verify_preserved_owned_cleanup(self.root)['owned_cleanup'], 'owned-clean')

    def test_rejects_raw_owned_entries_despite_empty_owned_labels(self):
        for kind in ('process', 'task'):
            with self.subTest(kind=kind):
                inventory = deepcopy(self.frozen)
                if kind == 'process':
                    inventory['processes'] = [{'identity': '123|123456',
                                              'executable_path': self.roots['guest']['path'] + '\\app.exe'}]
                else:
                    inventory['tasks'] = [{'identity': '\\' + RUN,
                                           'definition_sha256': 'a' * 64}]
                with self.assertRaises(EvidenceError):
                    _reject_owned_entries(inventory, self.roots, RUN)

    def test_rejects_missing_unclosed_and_unbound_process_jobs(self):
        for change in ('missing', 'unclosed', 'unbound'):
            result = process_result('9' * 40)
            if change == 'missing':
                result.pop('process_job_cleanup')
            elif change == 'unclosed':
                result['process_job_cleanup'][0]['job_closed'] = False
            else:
                result['process_lifecycle']['pid'] = 456
            with self.subTest(change=change), self.assertRaises(EvidenceError):
                _process_jobs(result, 'core')

    def test_recovery_jobs_bind_digest_verified_private_start_identity(self):
        result = process_result('9' * 40)
        result.pop('process_lifecycle')
        start = {'boundary': 'started', 'binding': {'pid': 123, 'start_time_utc_ticks': '123456'}}
        data = write(self.root / 'started.json', start)
        row = {'file': 'started.json', 'bytes': len(data), 'sha256': digest(data)}
        result['process_crash'] = {'processes': [{'boundary': 'started', **row}]}
        _process_jobs(result, 'recovery', self.root, [row])
        with self.assertRaises(EvidenceError):
            _process_jobs(result, 'recovery', self.root, [])
        start['binding']['pid'] = 456
        data = write(self.root / 'started.json', start)
        row.update(bytes=len(data), sha256=digest(data))
        result['process_crash']['processes'][0].update(row)
        with self.assertRaises(EvidenceError):
            _process_jobs(result, 'recovery', self.root, [row])

    def test_core_job_ledger_includes_rust_binary_and_gui_lifetimes(self):
        result = process_result('9' * 40)
        result['gui'] = {'process_lifecycle': result.pop('process_lifecycle')}
        binary = {'file': 'native-test.exe', 'process_lifecycle': {
            'pid': 456, 'start_time_utc_ticks': '123457'}}
        result['tests'] = [binary, {'file': 'not-started.exe', 'status': 'failed'}]
        receipt = deepcopy(result['process_job_cleanup'][0])
        receipt.update(pid=456, process_start_time_utc_ticks='123457')
        result['process_job_cleanup'].append(receipt)
        _process_jobs(result, 'core')
        binary.pop('process_lifecycle')
        with self.assertRaises(EvidenceError):
            _process_jobs(result, 'core')

    def test_rejects_mutated_evidence_and_missing_raw_observations(self):
        for path, value in (
            ('original-transport.json', {**self.original, 'guest_cleanup': True}),
            ('owned-cleanup-after-strict-failure.json', {**self.proof, 'schema_version': True}),
            ('owned-cleanup-after-strict-failure.json', {**self.proof, 'status': 'incomplete'}),
            ('owned-cleanup-after-strict-failure.json', {**self.proof, 'post': None}),
            ('owned-cleanup-after-strict-failure.json', {
                **self.proof, 'observed_roots_after': {'guest_present': True,
                                                        'trusted_present': False}}),
        ):
            with self.subTest(path=path, value=value):
                target = self.root / path
                prior = target.read_bytes()
                write(target, value)
                with self.assertRaises(EvidenceError):
                    verify_preserved_owned_cleanup(self.root)
                target.write_bytes(prior)

    def test_rejects_new_process_and_changed_held_root_descriptor(self):
        for change in ('process', 'owner'):
            with self.subTest(change=change):
                modified = deepcopy(self.proof)
                if change == 'process':
                    modified['post']['processes'] = [
                        {'identity': 'new', 'executable_path': r'C:\\unknown.exe'}]
                else:
                    modified['observed_roots_before']['guest']['owner_sid'] = 'S-1-5-18'
                write(self.root / 'owned-cleanup-after-strict-failure.json', modified)
                with self.assertRaises(EvidenceError):
                    verify_preserved_owned_cleanup(self.root)

    def test_rejects_original_resource_error_and_unbound_frozen_inventory(self):
        self.original['raw_cleanup']['resource_cleanup_errors'] = ['handle cleanup failed']
        self.rebind_original()
        with self.assertRaisesRegex(EvidenceError, 'strict OS failure'):
            verify_preserved_owned_cleanup(self.root)
        self.original['raw_cleanup']['resource_cleanup_errors'] = []
        self.original['owned_cleanup_failure_context']['failed_snapshot'] = {
            **self.frozen, 'tasks': [{'identity': 'unbound', 'definition_sha256': 'a' * 64}]}
        self.rebind_original()
        with self.assertRaisesRegex(EvidenceError, 'Frozen inventory'):
            verify_preserved_owned_cleanup(self.root)

    def test_rejects_nested_inventory_symlink(self):
        path = self.root / 'original-result.json'
        target = self.root / 'parked-original-result.json'
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaisesRegex(EvidenceError, 'alias'):
            verify_preserved_owned_cleanup(self.root)

    def test_ui_restoration_uses_copied_raw_snapshot_equivalence(self):
        source_sha = '9' * 40
        observer_sha = '8' * 64
        context = {'task_kind': 'ui', 'source_sha': source_sha,
                   'observer_sha256': observer_sha,
                   'acceptance_mode': 'text-scale', 'high_contrast_requested': True}
        result = {}
        listed = set()
        for kind, filename, schema, required, original, restored in (
            ('high_contrast', 'high-contrast-restore.json', 2, False,
             high_contrast_snapshot(None), high_contrast_snapshot('')),
            ('text_scale', 'text-scale-snapshot.json', 1, True,
             text_scale_snapshot(1.0), text_scale_snapshot(1.0000005)),
        ):
            data = write(self.root / filename, {
                'schema_version': schema, 'source_sha': source_sha,
                'acceptance_script_sha256': observer_sha,
                'restoration_required': required, 'restoration_verified': True,
                'original': original, 'restored': restored,
            })
            result[kind] = {'snapshot': {'file': filename, 'sha256': digest(data)}}
            listed.add(filename)
        _restoration(self.root, result, context, listed)
        del result['text_scale']
        rescue_name = 'text-scale-rescue-result.json'
        write(self.root / rescue_name, {
            'status': 'passed', 'restoration_verified': True,
            'source_sha': source_sha, 'acceptance_script_sha256': observer_sha,
            'snapshot_sha256': digest((self.root / 'text-scale-snapshot.json').read_bytes()),
        })
        listed.add(rescue_name)
        _restoration(self.root, result, context, listed)
        listed.remove(rescue_name)
        result['text_scale'] = {'snapshot': {
            'file': 'text-scale-snapshot.json',
            'sha256': digest((self.root / 'text-scale-snapshot.json').read_bytes()),
        }}
        data = write(self.root / 'text-scale-snapshot.json', {
            'schema_version': 1, 'source_sha': source_sha,
            'acceptance_script_sha256': observer_sha,
            'restoration_required': True, 'restoration_verified': True,
            'original': text_scale_snapshot(1.0),
            'restored': text_scale_snapshot(1.01),
        })
        result['text_scale']['snapshot']['sha256'] = digest(data)
        with self.assertRaises(EvidenceError):
            _restoration(self.root, result, context, listed)

    def test_rejects_incomplete_and_unknown_settings_even_if_equal(self):
        for kind, snapshot in (('high-contrast', high_contrast_snapshot(None)),
                               ('text-scale', text_scale_snapshot(1.0))):
            _setting_snapshot(snapshot, kind)
            for key in snapshot:
                partial = {name: item for name, item in snapshot.items() if name != key}
                with self.subTest(kind=kind, missing=key), self.assertRaises(EvidenceError):
                    _setting_snapshot(partial, kind)
        unknown = text_scale_snapshot(1.0)
        unknown['registry_value_kind'] = 'QWord'
        with self.assertRaises(EvidenceError):
            _setting_snapshot(unknown, 'text-scale')

    def test_observer_exit_and_restore_errors_are_independently_checked(self):
        original = {'observer_process': {'state': 'exited', 'exit_code': 1}}
        result = {'status': 'failed', 'failure_reason': 'workload_failure'}
        _observer_finished(original, result, 'ui')
        for changed in ({}, {'state': 'running', 'exit_code': 1},
                        {'state': 'exited', 'exit_code': None}):
            with self.subTest(process=changed), self.assertRaises(EvidenceError):
                _observer_finished({'observer_process': changed}, result, 'ui')
        for kind, reason in (('ui', 'raw_cleanup_failed'),
                             ('recovery', 'candidate_export_cleanup_observation_failed'),
                             ('ui', 'execution_state_restore_failed')):
            with self.subTest(kind=kind, reason=reason), self.assertRaises(EvidenceError):
                _observer_finished(original, {**result, 'failure_reason': reason}, kind)


class V2OwnedCleanupTests(unittest.TestCase):
    def setUp(self):
        OwnedCleanupTests.setUp(self)
        clean = clean_controller_cleanup_v2()
        evidence = clean['owned_resource_evidence']
        self.roots = deepcopy(evidence['root_records'])
        self.frozen = {'complete': True,
                       'processes': deepcopy(evidence['process_snapshots']['after_intervention']['processes']),
                       'tasks': [], 'owned_processes': []}
        result = process_result('9' * 40)
        result['process_lifecycle'] = {'pid': 3001, 'start_time_utc_ticks': '134041000000000000'}
        result['process_job_cleanup'] = deepcopy(evidence['process_job_cleanup'])
        result['observer_lifecycle'] = deepcopy(evidence['task_execution']['observer_lifecycle'])
        result_bytes = write(self.root / 'original-result.json', result)
        raw = deepcopy(clean)
        raw.update(guest_root_present=True, trusted_task_root_present=True,
                   runner_process_inventory_complete=False,
                   unexpected_runner_processes_after_delete=None,
                   unexpected_runner_tasks_after_delete=None,
                   resource_cleanup_errors=['Original root deletion was deferred.'])
        resource = raw['owned_resource_evidence']
        resource['process_snapshots']['after_delete'] = None
        resource['task_snapshots']['after_delete'] = None
        resource['observed_roots_before'] = None
        resource['observed_roots_after'] = {'guest_present': True, 'trusted_present': True}
        self.original['raw_cleanup'] = raw
        self.original['owned_cleanup_failure_context']['failed_snapshot'] = self.frozen
        self.original['owned_cleanup_failure_context']['root_records'] = self.roots
        self.original['owned_cleanup_failure_context']['source_result'] = {
            'file': 'original-result.json', 'bytes': len(result_bytes), 'sha256': digest(result_bytes)}
        self.receipt.update(schema_version=2, run_name=evidence['run_name'],
                            profile_id='vm-automated-v2-owned-resources',
                            profile_sha256=V2_PROFILE_SHA256,
                            failed_snapshot=self.frozen, root_records=self.roots)
        self.receipt['files'][1] = {'file': 'original-result.json',
                                    'bytes': len(result_bytes), 'sha256': digest(result_bytes)}
        self.signal.update(schema_version=2, profile_id='vm-automated-v2-owned-resources',
                           profile_sha256=V2_PROFILE_SHA256)
        inventory = {**deepcopy(self.frozen), 'owned_tasks': []}
        self.proof.update(schema_version=2, run_name=evidence['run_name'],
                          profile_id='vm-automated-v2-owned-resources',
                          profile_sha256=V2_PROFILE_SHA256,
                          pre=inventory, post=deepcopy(inventory), roots=self.roots,
                          observed_roots_before={role: {**row, 'ordinary_directory': True}
                                                 for role, row in self.roots.items()})
        self.rebind_original()

    def rebind_original(self):
        OwnedCleanupTests.rebind_original(self)

    def verify_v2(self):
        return verify_preserved_owned_cleanup(self.root,
                                              profile_id='vm-automated-v2-owned-resources',
                                              profile_sha256=V2_PROFILE_SHA256)

    def test_v2_failure_cleanup_remains_rejected_even_with_ambient_processes(self):
        self.assertEqual(self.verify_v2()['acceptance'], 'rejected')

    def test_v2_original_nonzero_task_exit_can_have_owned_cleanup_proof(self):
        self.original['raw_cleanup']['owned_resource_evidence']['task_execution']['exit_code'] = 0xC0000005
        self.rebind_original()
        self.assertEqual(self.verify_v2()['owned_cleanup'], 'owned-clean')

    def test_v2_no_candidate_result_cannot_be_promoted_by_a_cleanup_proof(self):
        original_transport = (self.root / 'original-transport.json').read_bytes()
        (self.root / 'original-result.json').unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify_v2()
        self.assertEqual((self.root / 'original-transport.json').read_bytes(), original_transport)

    def test_v2_missing_helper_or_candidate_lifetime_refuses_owned_clean(self):
        original = deepcopy(self.original)
        for missing in ('preflight-job', 'engine-job', 'preflight-lifetime',
                        'engine-lifetime', 'candidate-task'):
            with self.subTest(missing=missing):
                self.original = deepcopy(original)
                evidence = self.original['raw_cleanup']['owned_resource_evidence']
                if missing == 'candidate-task':
                    evidence['task_execution'] = None
                else:
                    helper = 'preflight_child' if missing.startswith('preflight') else 'engine_child'
                    field = 'process_job_closed' if missing.endswith('job') else 'exact_lifetime_absent'
                    evidence[helper][field] = False
                self.rebind_original()
                with self.assertRaises(EvidenceError):
                    self.verify_v2()

    def test_v2_tampered_profile_task_or_process_scope_fails(self):
        original = deepcopy(self.original)
        proof = deepcopy(self.proof)
        for mutation in ('profile', 'task', 'process', 'observer'):
            with self.subTest(mutation=mutation):
                self.original = deepcopy(original)
                self.proof = deepcopy(proof)
                if mutation == 'profile':
                    self.proof['profile_sha256'] = 'c' * 64
                elif mutation == 'task':
                    self.proof['post']['tasks'] = [{'identity': '\\Other', 'task_path': '\\',
                                                    'task_name': 'Other', 'definition_sha256': '1' * 64}]
                elif mutation == 'process':
                    self.proof['post']['processes'][1]['command_line'] += self.receipt['run_name']
                else:
                    self.original['raw_cleanup']['owned_resource_evidence']['task_execution'][
                        'observer_lifecycle']['pid'] = 9999
                self.rebind_original()
                with self.assertRaises(EvidenceError):
                    self.verify_v2()


class V3OwnedCleanupTests(unittest.TestCase):
    def setUp(self):
        OwnedCleanupTests.setUp(self)
        bundle_bytes = write(self.root / 'bundle.json',
                             {'schema_version': 1, 'source_sha': '9' * 40})
        bundle_ref = {'file': 'bundle.json', 'bytes': len(bundle_bytes),
                      'sha256': digest(bundle_bytes)}
        self.original['owned_cleanup_failure_context']['bundle'] = bundle_ref
        self.receipt['files'][2] = bundle_ref
        raw = clean_controller_cleanup_v3_protected(
            profile_sha256='a' * 64, source_sha='9' * 40,
            bundle_sha256=digest(bundle_bytes), vm_id=VM, run_name=RUN)
        evidence = raw['owned_resource_evidence']
        job = evidence['process_job_cleanup'][0]
        result = process_result('9' * 40)
        result['process_lifecycle'] = {
            'pid': job['pid'],
            'start_time_utc_ticks': job['process_start_time_utc_ticks']}
        result['process_job_cleanup'] = deepcopy(evidence['process_job_cleanup'])
        result['observer_lifecycle'] = deepcopy(evidence['task_execution']['observer_lifecycle'])
        result_bytes = write(self.root / 'original-result.json', result)
        result_ref = {'file': 'original-result.json', 'bytes': len(result_bytes),
                      'sha256': digest(result_bytes)}
        self.receipt['files'][1] = result_ref
        self.original['owned_cleanup_failure_context']['source_result'] = result_ref
        self.roots = deepcopy(evidence['root_records'])
        self.frozen = {'complete': True,
                       'processes': deepcopy(evidence['process_snapshots'][
                           'after_intervention']['processes']),
                       'tasks': [], 'owned_processes': []}
        raw.update(guest_root_present=True, trusted_task_root_present=True,
                   runner_process_inventory_complete=False,
                   unexpected_runner_processes_after_delete=None,
                   unexpected_runner_tasks_after_delete=None,
                   resource_cleanup_errors=['Original root deletion was deferred.'])
        evidence['process_snapshots']['after_delete'] = None
        evidence['task_snapshots']['after_delete'] = None
        evidence['observed_roots_before'] = None
        evidence['observed_roots_after'] = {'guest_present': True, 'trusted_present': True}
        held = evidence['protected_anchor']
        held['all_handles_closed'] = False
        held['proof'].update(handle_closed=False, parent_handle_closed=False,
                             child_path_closed=False, parent_path_closed=False,
                             accepted_snapshot_count=4)
        self.original['raw_cleanup'] = raw
        self.original['owned_cleanup_failure_context'].update(
            failed_snapshot=self.frozen, root_records=self.roots)
        self.receipt.update(schema_version=3, run_name=RUN,
                            profile_id='vm-automated-v2-owned-resources',
                            profile_sha256='a' * 64,
                            failed_snapshot=self.frozen, root_records=self.roots)
        self.signal.update(schema_version=3,
                           profile_id='vm-automated-v2-owned-resources',
                           profile_sha256='a' * 64)
        inventory = {**deepcopy(self.frozen), 'owned_tasks': []}
        final_anchor = deepcopy(held)
        final_anchor['all_handles_closed'] = True
        final_anchor['proof'].update(handle_closed=True, parent_handle_closed=True,
                                      child_path_closed=True, parent_path_closed=True,
                                      accepted_snapshot_count=6)
        self.proof.update(schema_version=3, run_name=RUN,
                          profile_id='vm-automated-v2-owned-resources',
                          profile_sha256='a' * 64,
                          pre=inventory, post=deepcopy(inventory), roots=self.roots,
                          observed_roots_before={role: {**row, 'ordinary_directory': True}
                                                 for role, row in self.roots.items()},
                          protected_anchor=final_anchor)
        self.rebind_original()

    def rebind_original(self):
        OwnedCleanupTests.rebind_original(self)

    def verify_v3(self):
        return verify_preserved_owned_cleanup(self.root,
                                              profile_id='vm-automated-v2-owned-resources',
                                              profile_sha256='a' * 64)

    def test_held_pre_name_lifetime_closes_only_after_finalizer(self):
        self.assertEqual(self.verify_v3()['owned_cleanup'], 'owned-clean')
        self.assertEqual(self.verify_v3()['acceptance'], 'rejected')

    def test_new_performance_run_cannot_omit_restoration_gate(self):
        def current_profile(value):
            if type(value) is dict:
                return {key: current_profile(item) for key, item in value.items()}
            if type(value) is list:
                return [current_profile(item) for item in value]
            return OWNED_PERFORMANCE_PROFILE_SHA256 if value == 'a' * 64 else value
        self.original = current_profile(self.original)
        self.receipt = current_profile(self.receipt)
        self.proof = current_profile(self.proof)
        self.signal = current_profile(self.signal)
        result = json.loads((self.root / 'original-result.json').read_text())
        result['acceptance_observations'] = {
            'run_id': 'performance-sample-v2-owned-r3-1366x768-96-text100-hidden-visible'}
        result_bytes = write(self.root / 'original-result.json', result)
        reference = {'file': 'original-result.json', 'bytes': len(result_bytes),
                     'sha256': digest(result_bytes)}
        self.receipt['files'][1] = reference
        self.original['owned_cleanup_failure_context']['source_result'] = reference
        self.rebind_original()
        with self.assertRaisesRegex(EvidenceError, 'frozen restoration gate'):
            verify_preserved_owned_cleanup(self.root,
                                           profile_id='vm-automated-v2-owned-resources',
                                           profile_sha256=OWNED_PERFORMANCE_PROFILE_SHA256)

    def test_finalizer_rejects_lost_handle_or_phase_recheck(self):
        seed = deepcopy(self.proof)
        for mode in ('handle', 'count', 'source'):
            self.proof = deepcopy(seed)
            anchor = self.proof['protected_anchor']
            if mode == 'handle':
                anchor['proof']['child_path_closed'] = False
            elif mode == 'count':
                anchor['proof']['accepted_snapshot_count'] = 5
            else:
                anchor['source_sha'] = 'f' * 40
            self.rebind_original()
            with self.subTest(mode=mode), self.assertRaises(EvidenceError):
                self.verify_v3()


if __name__ == '__main__':
    unittest.main()
