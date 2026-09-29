"""Portable regression tests for diagnostic scope, ordering and failure ownership."""

import hashlib
import base64
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from contextlib import contextmanager

from darkrenamer_tooling.vm import runtimebroker_diagnostic as diagnostic


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.plan = {
            'schema_version': 1, 'vm_id': '18338a47-f647-45c4-98b8-6107331e2602',
            'runner_sid': 'S-1-5-21-2512583658-2963808555-1674717125-1001',
            'diagnostic_source_sha': 'a' * 40,
            'candidate_source_sha': diagnostic.PRODUCT_SHA,
            'candidate_executable_sha256': diagnostic.PRODUCT_EXE_SHA256,
            'attempts': [{'id': 'preparation-only', 'preparation_only': True,
                          'followup_seconds': 0, 'launcher_arguments': []}],
        }
        self.args = SimpleNamespace(
            ssh_host='configured-vm', candidate_mode=True, desktop_mode='rdp',
            task_kind='ui', expected_vm_id=self.plan['vm_id'],
            candidate_source_sha=diagnostic.PRODUCT_SHA,
            candidate_executable_sha256=diagnostic.PRODUCT_EXE_SHA256,
            test_timeout_seconds=300)

    def save_plan(self):
        path = self.root / 'plan.json'
        data = diagnostic.document_bytes(self.plan)
        path.write_bytes(data)
        return path, hashlib.sha256(data).hexdigest()

    def test_frozen_plan_rejects_digest_change_and_duplicate_properties(self):
        path, digest = self.save_plan()
        path.write_bytes(path.read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'digest'):
            diagnostic.load_plan(path, digest)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            diagnostic.parse_json('{"schema_version":1,"schema_version":2}')

    def test_plan_rejects_fifth_attempt_and_rewritten_candidate(self):
        self.plan['attempts'] *= 5
        path, digest = self.save_plan()
        with self.assertRaisesRegex(ValueError, 'schema'):
            diagnostic.load_plan(path, digest)
        self.plan['attempts'] = self.plan['attempts'][:1]
        self.plan['candidate_executable_sha256'] = 'f' * 64
        path, digest = self.save_plan()
        with self.assertRaisesRegex(ValueError, 'candidate'):
            diagnostic.load_plan(path, digest)

    def test_plan_rejects_duplicate_attempt_and_unbounded_followup(self):
        with mock.patch.object(diagnostic.launcher, 'parse_arguments', return_value=self.args):
            self.plan['attempts'] *= 2
            path, digest = self.save_plan()
            with self.assertRaisesRegex(ValueError, 'duplicated'):
                diagnostic.load_plan(path, digest)
            self.plan['attempts'] = self.plan['attempts'][:1]
            self.plan['attempts'][0]['followup_seconds'] = 361
            path, digest = self.save_plan()
            with self.assertRaisesRegex(ValueError, 'invalid'):
                diagnostic.load_plan(path, digest)

    def test_new_attempt_cannot_replace_failed_attempt_or_frozen_plan(self):
        output = self.root / 'runs'
        data = diagnostic.document_bytes(self.plan)
        digest = hashlib.sha256(data).hexdigest()
        directory, run_id = diagnostic.reserve_attempt(output, self.plan, data, digest, 'preparation-only')
        self.assertRegex(run_id, r'^[a-f0-9]{32}$')
        with self.assertRaisesRegex(RuntimeError, 'incomplete'):
            diagnostic.reserve_attempt(output, self.plan, data, digest, 'preparation-only')
        (directory / 'diagnostic-receipt.json').write_bytes(diagnostic.document_bytes({'safe_to_continue': True}))
        with self.assertRaises(FileExistsError):
            diagnostic.reserve_attempt(output, self.plan, data, digest, 'preparation-only')
        with self.assertRaisesRegex(ValueError, 'different frozen'):
            diagnostic.reserve_attempt(output, self.plan, data + b' ', digest, 'other')

    def test_plan_cannot_use_bundle_prepare_only_or_replace_output_or_existing_desktop(self):
        for option in ('--prepare-only', '--output=/tmp/alternate', '--desktop-mode=existing'):
            self.plan['attempts'][0]['launcher_arguments'] = [option]
            with self.assertRaisesRegex(ValueError, 'managed RDP'):
                diagnostic.workload_arguments(self.plan['attempts'][0], self.plan)

    def test_symlink_evidence_ancestry_is_rejected(self):
        link = self.root / 'linked'
        try:
            link.symlink_to(self.root, target_is_directory=True)
        except OSError:
            self.skipTest('Host cannot create symlinks')
        with self.assertRaisesRegex(ValueError, 'ordinary ancestry'):
            diagnostic.reserve_attempt(link / 'runs', self.plan, b'{}', 'a' * 64, 'one')

    def test_deadline_uses_monotonic_budget_not_phase_reset(self):
        now = [10]
        deadline = diagnostic.Deadline(clock=lambda: now[0])
        now[0] += 800
        self.assertEqual(deadline.require(35), 65)
        now[0] += 100
        with self.assertRaises(TimeoutError):
            deadline.require()

    def test_bridge_rejects_response_sequence_mismatch_and_disconnect(self):
        bridge = object.__new__(diagnostic.Bridge)
        bridge.closed = False
        bridge.sequence = 0
        bridge.run_id = 'b' * 32
        bridge.process = SimpleNamespace(stdin=io.BytesIO())
        bridge.messages = diagnostic.queue.Queue()
        bridge.deadline = diagnostic.Deadline()
        bridge.messages.put({'sequence': 2, 'ok': True, 'result': {}, 'error': None})
        with self.assertRaisesRegex(ValueError, 'identity'):
            bridge.request('ready')
        bridge.messages.put(RuntimeError('disconnected'))
        with self.assertRaisesRegex(RuntimeError, 'disconnected'):
            bridge.request('stop')

    def test_collection_checks_hash_before_deleting_guest_evidence(self):
        bridge = object.__new__(diagnostic.Bridge)
        bridge.directory = self.root
        operations = []
        payload = b'{}\n'
        inventory = [{'name': name, 'size': len(payload),
                      'sha256': hashlib.sha256(payload).hexdigest()}
                     for name in ('ready.json', 'events.jsonl', 'result.json')]

        def request(operation, value=None, timeout=None):
            operations.append(operation)
            if operation == 'stop':
                return {'clean': True}
            if operation == 'inventory':
                return inventory
            if operation == 'read':
                return base64.b64encode(b'BAD').decode()
            self.fail('Guest evidence must remain when its download digest differs.')

        bridge.request = request
        with self.assertRaisesRegex(ValueError, 'bytes differ'):
            bridge.stop_and_collect()
        self.assertNotIn('cleanup', operations)

    def test_collection_rejects_total_budget_before_downloading(self):
        bridge = object.__new__(diagnostic.Bridge)
        bridge.directory = self.root
        bridge.request = mock.Mock(side_effect=[{'clean': True}, [
            {'name': 'events.jsonl', 'size': diagnostic.COLLECTOR_BYTES + 1, 'sha256': 'f' * 64}]])
        with self.assertRaisesRegex(ValueError, 'budgets'):
            bridge.stop_and_collect()
        self.assertEqual(bridge.request.call_count, 2)

    def test_cleanup_proof_binds_receipt_and_raw_evidence_without_changing_acceptance(self):
        prior = self.root / 'prior'
        prior.mkdir()
        receipt = {'ready_before_desktop': True, 'deadline_exceeded': False,
                   'desktop_resources_closed': True, 'error': None,
                   'bridge_lifecycle': {'clean': True},
                   'observation': {'observer_job': {'clean': True},
                                   'root_cleanup': {'removed': True}, 'collector_owned_cleanup': True}}
        receipt_bytes = diagnostic.document_bytes(receipt)
        (prior / 'diagnostic-receipt.json').write_bytes(receipt_bytes)
        evidence = self.root / 'raw-cleanup.json'
        evidence.write_bytes(b'{"exact_owned_resources_absent":true}')
        proof = {'schema_version': 1, 'previous_attempt_id': 'prior',
                 'previous_receipt_sha256': hashlib.sha256(receipt_bytes).hexdigest(),
                 'vm_id': self.plan['vm_id'], 'runner_sid': self.plan['runner_sid'],
                 'verified_at_utc': '2026-09-30T00:00:00Z',
                 'workload_owned_roots_absent': True, 'workload_owned_tasks_absent': True,
                 'workload_owned_processes_absent': True, 'restoration_verified': True,
                 'observer_resources_closed': True, 'desktop_resources_closed': True,
                 'os_processes_terminated': False, 'acceptance_reclassified': False,
                 'raw_evidence': [{'file': str(evidence), 'bytes': evidence.stat().st_size,
                                   'sha256': hashlib.sha256(evidence.read_bytes()).hexdigest()}]}
        path = self.root / 'proof.json'

        def save():
            data = diagnostic.document_bytes(proof)
            path.write_bytes(data)
            return hashlib.sha256(data).hexdigest()

        self.assertEqual(diagnostic.verify_cleanup_proof(path, save(), prior, self.plan), path.read_bytes())
        self.assertEqual((prior / 'diagnostic-receipt.json').read_bytes(), receipt_bytes)
        proof['acceptance_reclassified'] = True
        with self.assertRaisesRegex(ValueError, 'cannot override'):
            diagnostic.verify_cleanup_proof(path, save(), prior, self.plan)
        proof['acceptance_reclassified'] = False
        evidence.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'differs'):
            diagnostic.verify_cleanup_proof(path, save(), prior, self.plan)

    def test_cleanup_proof_cannot_override_observer_failure_or_deadline_overrun(self):
        prior = self.root / 'prior'
        prior.mkdir()
        proof = {'schema_version': 1, 'previous_attempt_id': 'prior',
                 'vm_id': self.plan['vm_id'], 'runner_sid': self.plan['runner_sid'],
                 'verified_at_utc': '2026-09-30T00:00:00Z',
                 'workload_owned_roots_absent': True, 'workload_owned_tasks_absent': True,
                 'workload_owned_processes_absent': True, 'restoration_verified': True,
                 'observer_resources_closed': True, 'desktop_resources_closed': True,
                 'os_processes_terminated': False, 'acceptance_reclassified': False,
                 'raw_evidence': [{'file': str(self.root / 'unused'), 'sha256': 'a' * 64, 'bytes': 0}]}
        for failure in ('deadline', 'observer', 'unready', 'error'):
            receipt = {'ready_before_desktop': True, 'deadline_exceeded': False,
                       'desktop_resources_closed': True, 'error': None,
                       'bridge_lifecycle': {'clean': True},
                       'observation': {'observer_job': {'clean': True}, 'root_cleanup': {'removed': True},
                                       'collector_owned_cleanup': True}}
            if failure == 'deadline':
                receipt['deadline_exceeded'] = True
            elif failure == 'observer':
                receipt['observation']['observer_job']['clean'] = False
            elif failure == 'unready':
                receipt['ready_before_desktop'] = False
            else:
                receipt['error'] = 'disconnect'
            data = diagnostic.document_bytes(receipt)
            (prior / 'diagnostic-receipt.json').write_bytes(data)
            proof['previous_receipt_sha256'] = hashlib.sha256(data).hexdigest()
            raw = diagnostic.document_bytes(proof)
            path = self.root / 'proof.json'
            path.write_bytes(raw)
            with self.assertRaisesRegex(ValueError, 'cannot override'):
                diagnostic.verify_cleanup_proof(path, hashlib.sha256(raw).hexdigest(), prior, self.plan)

    def run_fake_attempt(self, ready_error=False, controller_error=False):
        order = []
        root = self.root / 'attempt'
        root.mkdir()
        owner = self

        class FakeBridge:
            def __init__(self, *args):
                order.append('observer-start')

            def wait_ready(self):
                order.append('observer-ready')
                if ready_error:
                    raise RuntimeError('not-ready')
                return {'root': 'C:\\ProgramData\\DarkReNamerRuntimeBrokerDiag-' + 'b' * 32,
                        'ready': True, 'run_id': 'b' * 32}

            def mark(self, phase, state, details=None):
                order.append(phase + ':' + state)

            def stop_and_collect(self):
                order.append('observer-collect')
                return {'observer_job': {'clean': True}, 'root_cleanup': {'removed': True},
                        'observer_result': {'retained': True}, 'inventory': [], 'collector_owned_cleanup': True}

            def close(self):
                order.append('observer-close')
                return {'clean': True, 'exit_code': 0, 'forced_local_bridge_stop': False}

        @contextmanager
        def desktop(args, bundle):
            order.append('desktop-start')
            try:
                yield {'expectedGuestSid': owner.plan['runner_sid']}
            finally:
                order.append('desktop-stop')
                (bundle / 'desktop-lease.json').write_text('{"cleanup_observed":true}')

        def run(command, **kwargs):
            order.append('controller')
            self.assertNotIn('timeout', kwargs)  # Restoration must not be killed.
            self.assertIn('-RuntimeBrokerDiagnosticBudgetSeconds', command)
            self.assertIn('-RuntimeBrokerPreparationOnly', command)
            (root / 'workload/transport.json').write_text('{"guest_cleanup":true}')
            if controller_error:
                raise OSError('controller-disconnect')
            return SimpleNamespace(returncode=1)  # Strict failure remains a strict failure.

        with mock.patch.object(diagnostic, 'workload_arguments', return_value=self.args), \
                mock.patch.object(diagnostic.launcher, 'clean_source_identity', return_value=(self.root, 'a' * 40)), \
                mock.patch.object(diagnostic.launcher, 'build_candidate_bundle'), \
                mock.patch.object(diagnostic.launcher, 'managed_desktop', side_effect=desktop), \
                mock.patch.object(diagnostic.launcher, 'controller_invocation', return_value=['controller']), \
                mock.patch.object(diagnostic.subprocess, 'run', side_effect=run):
            receipt = diagnostic.run_attempt(self.root, root, self.plan, self.plan['attempts'][0],
                                              'b' * 32, None, FakeBridge)
        return order, receipt

    def test_ready_precedes_desktop_and_observer_collect_follows_desktop_stop(self):
        order, receipt = self.run_fake_attempt()
        self.assertLess(order.index('observer-ready'), order.index('desktop-start'))
        self.assertLess(order.index('desktop-stop'), order.index('observer-collect'))
        self.assertEqual(receipt['controller_exit_code'], 1)
        self.assertFalse(receipt['acceptance_reclassification'])
        self.assertNotIn('observer_result', receipt['observation'])

    def test_unready_observer_prevents_desktop_and_closes_owned_resources(self):
        order, receipt = self.run_fake_attempt(ready_error=True)
        self.assertNotIn('desktop-start', order)
        self.assertEqual(order[-2:], ['observer-collect', 'observer-close'])
        self.assertFalse(receipt['safe_to_continue'])

    def test_controller_disconnect_restores_desktop_and_closes_observer(self):
        order, receipt = self.run_fake_attempt(controller_error=True)
        self.assertLess(order.index('desktop-stop'), order.index('observer-close'))
        self.assertEqual(receipt['error'], 'controller-disconnect')
        self.assertFalse(receipt['safe_to_continue'])


if __name__ == '__main__':
    unittest.main()
