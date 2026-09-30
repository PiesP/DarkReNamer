"""Independent preserved-failure and owned-cleanup evidence contracts."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from darkrenamer_tooling.contracts.owned_cleanup import (
    _process_jobs, _reject_owned_entries, _restoration, verify_preserved_owned_cleanup,
)
from darkrenamer_tooling.evidence.archive import EvidenceError


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


class OwnedCleanupTests(unittest.TestCase):
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
             {'flags': 1, 'scheme': None}, {'flags': 1, 'scheme': ''}),
            ('text_scale', 'text-scale-snapshot.json', 1, True,
             {'registry_value': 100, 'ui_settings_raw_factor': 1.0},
             {'registry_value': 100, 'ui_settings_raw_factor': 1.0000005}),
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
            'original': {'registry_value': 100, 'ui_settings_raw_factor': 1.0},
            'restored': {'registry_value': 100, 'ui_settings_raw_factor': 1.01},
        })
        result['text_scale']['snapshot']['sha256'] = digest(data)
        with self.assertRaises(EvidenceError):
            _restoration(self.root, result, context, listed)


if __name__ == '__main__':
    unittest.main()
