"""Contract tests for the host VM bundle and returned native evidence."""
from contextlib import redirect_stderr
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('windows_vm', Path(__file__).with_name('test-windows-vm.py'))
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


class VmRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.test = self.artifact('tests.exe', b'test executable')
        self.app = self.artifact('DarkReNamer.exe', b'app executable')
        stdout = self.artifact('tests.stdout.log', b'test result: ok. 3 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.01s\n')
        stderr = self.artifact('tests.stderr.log', b'')
        screenshot = self.artifact('main-workbench.png', b'\x89PNG\r\n\x1a\nfixture')
        preview_screenshot = dict(self.artifact('rename-preview.png', b'\x89PNG\r\n\x1a\npreview'), width=900, height=700)
        confirmation_screenshot = dict(self.artifact('apply-confirmation.png', b'\x89PNG\r\n\x1a\nconfirmation'), width=500, height=300)
        self.manifest = {'schema_version': 1, 'source_sha': 'a' * 40, 'source_state': 'clean', 'target': vm.TARGET, 'test_binaries': [self.test], 'application': self.app}
        self.result = dict(self.manifest)
        flow = {
            'status': 'passed',
            'scope': 'production-file-add-prefix-cancel-confirm',
            'application_file': self.app['file'],
            'application_sha256': self.app['sha256'],
            'source_name': 'vm-flow-source.txt',
            'preview_name': 'vm-confirmed-vm-flow-source.txt',
            'before_content_sha256': 'c' * 64,
            'after_content_sha256': 'c' * 64,
            'before_file_identity_sha256': 'e' * 64,
            'after_file_identity_sha256': 'e' * 64,
            'cancellation_source_present': True,
            'cancellation_destination_present': False,
            'confirmed_source_present': False,
            'confirmed_destination_present': True,
            'journal_residue_count': 0,
            'screenshots': [preview_screenshot, confirmation_screenshot],
            'diagnostic': None,
            'failure_reason': None,
        }
        gui = dict(
            self.app,
            status='passed',
            scope='launch-window-screenshot-normal-close',
            screenshot=screenshot,
            flow=flow,
        )
        self.result.update(status='passed', tests=[dict(self.test, status='passed', exit_code=0, passed=3, failed=0, ignored=1, stdout=stdout, stderr=stderr)], gui=gui, transport={'kind': 'ssh', 'host_platform': 'Unix', 'guest_cleanup': True})

    def artifact(self, name, data):
        (self.root / name).write_bytes(data)
        return {'file': name, 'sha256': hashlib.sha256(data).hexdigest()}

    def verify(self):
        return vm.verify_result(self.root, self.manifest, self.result)

    def candidate_evidence(self):
        metadata = {
            'release_handoff': self.artifact('release-handoff.json', b'{"validated":true}'),
            'run_metadata': self.artifact('candidate-run.json', b'{"id":1}'),
            'artifact_metadata': self.artifact('candidate-artifact.json', b'{"id":2}'),
        }
        harness = {
            'source_sha': 'b' * 40,
            'source_state': 'clean',
            'launcher': self.artifact('test-windows-vm.py', b'launcher'),
            'controller': self.artifact('run-windows-vm-tests.ps1', b'controller'),
            'runner': self.artifact('windows-vm-guest.ps1', b'runner'),
            'observers': {
                'ui': self.artifact('windows-vm-acceptance.ps1', b'ui observer'),
                'recovery': self.artifact(
                    'windows-vm-recovery-acceptance.ps1', b'recovery observer'),
            },
            'validators': {
                'release_handoff': self.artifact('validate-release-handoff.ps1', b'handoff'),
                'candidate_metadata': self.artifact(
                    'validate-release-candidate-metadata.ps1', b'metadata'),
                'binary_measurement': self.artifact('measure-windows-binary.ps1', b'measure'),
            },
        }
        product = {
            'source_sha': 'a' * 40,
            'source_state': 'clean',
            'candidate': {
                'workflow_run': '10', 'run_attempt': '1', 'artifact_id': '20',
                'artifact_name': 'DarkReNamer-dry-run-10-1-windows',
                'origin_authentication': 'pending-hosted',
            },
            'application': self.app,
            'provenance': metadata,
        }
        manifest = {
            'schema_version': 2, 'lane': 'candidate-gui-only', 'target': vm.TARGET,
            'product': product, 'harness': harness, 'test_binaries': [],
        }
        digest = self.result['gui']['flow']['before_content_sha256']
        identity = self.result['gui']['flow']['before_file_identity_sha256']
        def checkpoint(phase, source, destination):
            def file_row(name):
                return {
                    'name': name, 'kind': 'file', 'bytes': 12,
                    'content_sha256': digest,
                    'file_identity_sha256': identity,
                }
            entries = []
            if source:
                entries.append(file_row('vm-flow-source.txt'))
            if destination:
                entries.append(file_row('vm-confirmed-vm-flow-source.txt'))
            return {
                'phase': phase,
                'fixture_entries': entries,
                'journal_entries': [],
            }
        candidate_result = json.loads(json.dumps(self.result))
        for key in ('source_sha', 'source_state'):
            candidate_result.pop(key)
        candidate_result.update(
            schema_version=2, lane='candidate-gui-only',
            product=json.loads(json.dumps(product)),
            harness=json.loads(json.dumps(harness)),
            tests=[])
        candidate_result['gui']['flow']['input_mode'] = 'uia-functional'
        candidate_result['gui']['flow']['checkpoints'] = [
            checkpoint('initial', True, False),
            checkpoint('after_cancel', True, False),
            checkpoint('after_apply', False, True),
            checkpoint('post_close', False, True),
        ]
        foreground = {
            'hwnd': 100, 'process_id': 200, 'session_id': 1,
            'window_class': 'DarkReNamerWindow',
        }
        candidate_result['gui']['flow']['foreground_observations'] = []
        for label, hwnd, window_class in (
                ('production rename preview', 100, 'DarkReNamerWindow'),
                ('apply confirmation task dialog', 101, '#32770')):
            observed = dict(foreground, hwnd=hwnd, window_class=window_class)
            candidate_result['gui']['flow']['foreground_observations'].append({
                'label': label, 'target_hwnd': hwnd, 'initial': dict(observed),
                'uia_set_focus': 'not_attempted', 'set_foreground_window': None,
                'final': dict(observed), 'capture_change': None,
            })
        candidate_result['gui'].update(
            window_handle=100, process_id=200, session_id=1,
            window_class='DarkReNamerWindow',
            exit_code=0,
            foreground_activation={
                'initial': dict(foreground), 'uia_set_focus': 'not_attempted',
                'set_foreground_window': None, 'final': dict(foreground),
                'capture_change': None,
            })
        candidate_result['transport']['runner_engine'] = {
            'executable': 'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
            'version': '7.4.0', 'edition': 'Core', 'effective_policy': 'RemoteSigned',
        }
        return manifest, candidate_result

    def assert_arguments_rejected(self, arguments):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            vm.parse_arguments(arguments)

    def candidate_build_inputs(self, suffix=''):
        repo = Path(__file__).resolve().parent.parent
        product_source = self.root / ('product-source' + suffix)
        handoff = self.root / ('handoff' + suffix)
        product_source.mkdir()
        handoff.mkdir()
        for name in vm.HANDOFF_FILES:
            (handoff / name).write_bytes(('fixture ' + name).encode())
        exe = handoff / 'DarkReNamer.exe'
        exe.write_bytes(b'exact candidate bytes')
        executable_hash = hashlib.sha256(exe.read_bytes()).hexdigest()
        (handoff / 'release-handoff.json').write_text(json.dumps({
            'schema_version': 1,
            'source_sha': 'a' * 40,
            'workflow_run': '10',
            'executable': {'filename': 'DarkReNamer.exe', 'sha256': executable_hash},
        }))
        run_metadata = self.root / ('run' + suffix + '.json')
        artifact_metadata = self.root / ('artifact' + suffix + '.json')
        run_metadata.write_text(json.dumps({
            'id': 10, 'run_attempt': 1, 'event': 'workflow_dispatch',
            'status': 'completed', 'conclusion': 'success', 'head_branch': 'master',
            'head_sha': 'a' * 40, 'path': '.github/workflows/release.yaml',
        }))
        artifact_metadata.write_text(json.dumps({
            'id': 20, 'name': 'DarkReNamer-dry-run-10-1-windows', 'expired': False,
            'workflow_run': {'id': 10, 'head_branch': 'master', 'head_sha': 'a' * 40},
        }))
        args = SimpleNamespace(
            candidate_source_root=product_source,
            candidate_handoff_root=handoff,
            candidate_run_metadata=run_metadata,
            candidate_artifact_metadata=artifact_metadata,
            candidate_source_sha='a' * 40,
            candidate_workflow_run='10', candidate_run_attempt='1',
            candidate_artifact_id='20', candidate_executable_sha256=executable_hash,
        )
        return repo, product_source, handoff, run_metadata, artifact_metadata, args

    def test_complete_native_evidence(self):
        self.assertTrue(self.verify())

    def test_missing_binary_is_not_a_pass(self):
        self.result['tests'] = []
        with self.assertRaisesRegex(ValueError, 'missing'):
            self.verify()

    def test_candidate_gui_only_evidence_is_distinct_from_default_tests(self):
        manifest, result = self.candidate_evidence()
        self.assertTrue(vm.verify_result(self.root, manifest, result))
        result['tests'] = [dict(self.result['tests'][0])]
        with self.assertRaisesRegex(ValueError, 'unexpected test binaries'):
            vm.verify_result(self.root, manifest, result)

    def test_candidate_transport_requires_bound_vm_identity_proof(self):
        identity = '12345678-1234-5678-9abc-1234567890ab'
        manifest, result = self.candidate_evidence()
        result['transport']['vm_id'] = identity
        with self.assertRaisesRegex(ValueError, 'identity binding'):
            vm.verify_result(self.root, manifest, result, 'ssh', identity)
        result['transport'].update(
            vm_identity_kind='hyper-v-guest-parameters-virtual-machine-id-v1',
            vm_identity_sha256=hashlib.sha256(identity.encode()).hexdigest())
        self.assertTrue(vm.verify_result(self.root, manifest, result, 'ssh', identity))
        result['transport']['vm_identity_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'identity binding'):
            vm.verify_result(self.root, manifest, result, 'ssh', identity)

    def test_candidate_metadata_and_executable_mismatches_are_rejected(self):
        manifest, result = self.candidate_evidence()
        result['product']['candidate']['artifact_id'] = '21'
        with self.assertRaisesRegex(ValueError, 'candidate binding'):
            vm.verify_result(self.root, manifest, result)
        manifest, result = self.candidate_evidence()
        manifest['product']['application']['sha256'] = 'f' * 64
        result['product']['application']['sha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            vm.verify_result(self.root, manifest, result)

    def test_candidate_observer_digest_mismatch_is_rejected(self):
        manifest, result = self.candidate_evidence()
        manifest['harness']['observers']['ui']['sha256'] = 'f' * 64
        result['harness']['observers']['ui']['sha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            vm.verify_result(self.root, manifest, result)

    def test_candidate_observer_results_and_recovery_inventory_are_bound(self):
        manifest, _ = self.candidate_evidence()
        identity = '12345678-1234-5678-9abc-1234567890ab'
        identity_hash = hashlib.sha256(identity.encode()).hexdigest()
        ui_result = {
            'schema_version': 2, 'lane': 'candidate-gui-only',
            'product': json.loads(json.dumps(manifest['product'])),
            'harness': json.loads(json.dumps(manifest['harness'])),
            'observer_role': 'ui',
            'application': json.loads(json.dumps(manifest['product']['application'])),
            'runner_sha256': manifest['harness']['runner']['sha256'],
            'acceptance_script_sha256': manifest['harness']['observers']['ui']['sha256'],
            'status': 'review_required',
        }
        self.assertTrue(vm.verify_observer_result(
            manifest, ui_result, 'ui', manifest['harness']['observers']['ui']['sha256']))
        ui_result['observer_role'] = 'recovery'
        with self.assertRaisesRegex(ValueError, 'provenance or role'):
            vm.verify_observer_result(
                manifest, ui_result, 'ui', manifest['harness']['observers']['ui']['sha256'])

        output = self.root / 'observer-output'
        session = output / 'recovery-acceptance-fixture'
        session.mkdir(parents=True)
        recovery_result = {
            'schema_version': 2, 'lane': 'candidate-gui-only',
            'product': json.loads(json.dumps(manifest['product'])),
            'harness': json.loads(json.dumps(manifest['harness'])),
            'observer_role': 'recovery',
            'application': json.loads(json.dumps(manifest['product']['application'])),
            'runner_sha256': manifest['harness']['runner']['sha256'],
            'observer': json.loads(json.dumps(
                manifest['harness']['observers']['recovery'])),
            'status': 'passed',
        }
        summary = session / 'summary.json'
        summary.write_text(json.dumps(recovery_result))
        (self.root / 'bundle.json').write_text(json.dumps(manifest))
        relative = 'recovery-acceptance-fixture/summary.json'
        inventory = {
            'schema_version': 1, 'task_kind': 'recovery',
            'observer_role': 'recovery',
            'bundle_manifest_sha256': vm.sha256(self.root / 'bundle.json'),
            'observer': manifest['harness']['observers']['recovery'],
            'summary_file': relative,
            'files': [{
                'file': relative, 'bytes': summary.stat().st_size,
                'sha256': vm.sha256(summary),
            }],
        }
        (output / 'recovery-inventory.json').write_text(json.dumps(inventory))
        (output / 'transport.json').write_text(json.dumps({
            'kind': 'ssh', 'task_kind': 'recovery', 'host_platform': 'Unix',
            'status': 'collected', 'guest_cleanup': True,
            'vm_id': identity,
            'vm_identity_kind': 'hyper-v-guest-parameters-virtual-machine-id-v1',
            'vm_identity_sha256': identity_hash,
            'observer_process': {'state': 'exited', 'exit_code': 0},
            'recovery_engine': {
                'version': '7.4.0', 'edition': 'Core',
                'effective_policy': 'RemoteSigned',
            },
        }))
        self.assertEqual(
            vm.verify_recovery_inventory(output, manifest, 'ssh', identity)['status'],
            'passed')
        transport_path = output / 'transport.json'
        valid_transport = json.loads(transport_path.read_text())
        for field, value in (
                ('vm_id', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'),
                ('vm_id', None),
                ('vm_identity_kind', None),
                ('vm_identity_sha256', '0' * 64)):
            with self.subTest(field=field, value=value):
                invalid_transport = dict(valid_transport)
                if value is None:
                    invalid_transport.pop(field)
                else:
                    invalid_transport[field] = value
                transport_path.write_text(json.dumps(invalid_transport))
                with self.assertRaisesRegex(ValueError, 'identity binding'):
                    vm.verify_recovery_inventory(output, manifest, 'ssh', identity)
        invalid_transport = dict(valid_transport, kind='powershell_direct')
        transport_path.write_text(json.dumps(invalid_transport))
        with self.assertRaisesRegex(ValueError, 'transport binding'):
            vm.verify_recovery_inventory(output, manifest, 'ssh', identity)
        transport_path.write_text(json.dumps(valid_transport))
        inventory['files'][0]['bytes'] = True
        (output / 'recovery-inventory.json').write_text(json.dumps(inventory))
        with self.assertRaisesRegex(ValueError, 'file row'):
            vm.verify_recovery_inventory(output, manifest, 'ssh', identity)
        inventory['files'][0]['bytes'] = summary.stat().st_size
        for relative_path in ('fixture/NUL.txt', 'fixture/trailing.'):
            with self.subTest(relative_path=relative_path):
                inventory['files'][0]['file'] = relative_path
                (output / 'recovery-inventory.json').write_text(json.dumps(inventory))
                with self.assertRaisesRegex(ValueError, 'relative path'):
                    vm.verify_recovery_inventory(output, manifest, 'ssh', identity)

    def test_recovery_inventory_stops_before_hashing_over_aggregate_limit(self):
        manifest, _ = self.candidate_evidence()
        output = self.root / 'aggregate-output'
        output.mkdir()
        (self.root / 'bundle.json').write_text(json.dumps(manifest))
        bundle_hash = vm.sha256(self.root / 'bundle.json')
        rows = []
        for index in range(5):
            path = output / ('item-' + str(index) + '.bin')
            path.touch()
            os.truncate(path, 128 * 1024 * 1024)
            rows.append({
                'file': path.name, 'bytes': path.stat().st_size,
                'sha256': 'a' * 64,
            })
        (output / 'recovery-inventory.json').write_text(json.dumps({
            'schema_version': 1, 'task_kind': 'recovery',
            'observer_role': 'recovery',
            'bundle_manifest_sha256': bundle_hash,
            'observer': manifest['harness']['observers']['recovery'],
            'summary_file': 'item-0.bin', 'files': rows,
        }))
        hashed = []

        def fake_sha256(path):
            path = Path(path)
            hashed.append(path)
            return bundle_hash if path.name == 'bundle.json' else 'a' * 64

        with mock.patch.object(vm, 'sha256', side_effect=fake_sha256), \
                self.assertRaisesRegex(ValueError, 'aggregate size'):
            vm.verify_recovery_inventory(
                output, manifest, 'ssh', '12345678-1234-5678-9abc-1234567890ab')
        self.assertNotIn(output / 'item-4.bin', hashed)

    def test_ui_observer_input_is_frozen_and_duplicate_keys_are_rejected(self):
        manifest, _ = self.candidate_evidence()
        source = self.root / 'ui-input.json'
        source.write_text('{"schema_version":1,"run_id":"fixture"}')
        prepared = vm.prepare_observer_inputs(
            self.root, manifest,
            SimpleNamespace(task_kind='ui', acceptance_manifest=source))
        self.assertEqual(prepared['output'], self.root / 'observer-output')
        self.assertEqual(
            (self.root / 'acceptance-input.json').read_bytes(), source.read_bytes())
        with tempfile.TemporaryDirectory() as directory:
            duplicate_root = Path(directory)
            for name in ('windows-vm-acceptance.ps1',
                         'windows-vm-recovery-acceptance.ps1'):
                (duplicate_root / name).write_bytes((self.root / name).read_bytes())
            duplicate = duplicate_root / 'ui-input.json'
            duplicate.write_text('{"schema_version":1,"schema_version":1}')
            with self.assertRaisesRegex(ValueError, 'duplicate field'):
                vm.prepare_observer_inputs(
                    duplicate_root, manifest,
                    SimpleNamespace(task_kind='ui', acceptance_manifest=duplicate))

    def test_candidate_checkpoints_recompute_disk_identity_and_journal_state(self):
        manifest, result = self.candidate_evidence()
        result['gui']['flow']['checkpoints'][2]['fixture_entries'][0]['file_identity_sha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'preserve content and identity'):
            vm.verify_result(self.root, manifest, result)
        manifest, result = self.candidate_evidence()
        result['gui']['flow']['checkpoints'][3]['journal_entries'] = [{
            'name': 'active.drj', 'kind': 'file', 'bytes': 1,
        }]
        with self.assertRaisesRegex(ValueError, 'journal residue'):
            vm.verify_result(self.root, manifest, result)
        manifest, result = self.candidate_evidence()
        result['gui']['flow']['checkpoints'][1]['fixture_entries'].append({
            'name': 'unexpected.txt', 'kind': 'file', 'bytes': 1,
            'content_sha256': 'd' * 64, 'file_identity_sha256': 'e' * 64,
        })
        with self.assertRaisesRegex(ValueError, 'filename is invalid'):
            vm.verify_result(self.root, manifest, result)
        manifest, result = self.candidate_evidence()
        result['gui']['flow']['checkpoints'][0]['journal_entries'] = [
            {'name': 'runtime.lock', 'kind': 'file', 'bytes': 0},
            {'name': 'runtime.lock', 'kind': 'file', 'bytes': 0},
        ]
        with self.assertRaisesRegex(ValueError, 'runtime lock inventory'):
            vm.verify_result(self.root, manifest, result)
        manifest, result = self.candidate_evidence()
        result['gui']['flow']['checkpoints'][0]['journal_entries'] = [
            {'name': 'runtime.lock', 'kind': 'file', 'bytes': 1},
        ]
        with self.assertRaisesRegex(ValueError, 'runtime lock inventory'):
            vm.verify_result(self.root, manifest, result)

    def test_candidate_summary_and_exit_must_match_raw_evidence(self):
        manifest, result = self.candidate_evidence()
        result['gui']['flow']['before_content_sha256'] = 'f' * 64
        result['gui']['flow']['after_content_sha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'contradicts raw checkpoints'):
            vm.verify_result(self.root, manifest, result)
        manifest, result = self.candidate_evidence()
        result['gui']['flow']['cancellation_source_present'] = False
        with self.assertRaisesRegex(ValueError, 'disk state is invalid'):
            vm.verify_result(self.root, manifest, result)
        manifest, result = self.candidate_evidence()
        result['gui']['exit_code'] = True
        with self.assertRaisesRegex(ValueError, 'exit code'):
            vm.verify_result(self.root, manifest, result)

    def test_candidate_flow_foreground_is_bound_to_target_process_session_and_class(self):
        mutations = (
            ('target_hwnd', 999, 'target'),
            ('final.hwnd', 999, 'target'),
            ('final.process_id', 999, 'process'),
            ('final.session_id', 9, 'session'),
            ('final.window_class', 'OtherWindow', 'class'),
        )
        for field, value, message in mutations:
            with self.subTest(field=field):
                manifest, result = self.candidate_evidence()
                observation = result['gui']['flow']['foreground_observations'][0]
                if field.startswith('final.'):
                    observation['final'][field.split('.', 1)[1]] = value
                else:
                    observation[field] = value
                with self.assertRaisesRegex(ValueError, message):
                    vm.verify_result(self.root, manifest, result)

    def test_candidate_flow_foreground_activation_types_are_strict(self):
        for field, value in (
                ('uia_set_focus', True),
                ('set_foreground_window', 1),
                ('initial.hwnd', True),
                ('initial.process_id', True),
                ('initial.session_id', True),
                ('initial.window_class', 7)):
            with self.subTest(field=field):
                manifest, result = self.candidate_evidence()
                observation = result['gui']['flow']['foreground_observations'][0]
                if field.startswith('initial.'):
                    observation['initial'][field.split('.', 1)[1]] = value
                else:
                    observation[field] = value
                with self.assertRaisesRegex(ValueError, 'foreground'):
                    vm.verify_result(self.root, manifest, result)

    def test_candidate_malformed_raw_rows_fail_with_bounded_validation_errors(self):
        manifest, result = self.candidate_evidence()
        result['gui']['flow']['checkpoints'][0]['fixture_entries'] = [None]
        with self.assertRaisesRegex(ValueError, 'file shape'):
            vm.verify_result(self.root, manifest, result)
        manifest, result = self.candidate_evidence()
        result['tests'] = [None]
        with self.assertRaisesRegex(ValueError, 'unexpected test binaries'):
            vm.verify_result(self.root, manifest, result)

    def test_strict_json_rejects_duplicate_keys_and_keeps_boolean_distinct(self):
        duplicate = self.root / 'duplicate.json'
        duplicate.write_text('{"schema_version":2,"schema_version":1}')
        with self.assertRaisesRegex(ValueError, 'duplicate field'):
            vm.read_json_strict(duplicate)
        boolean = self.artifact('boolean.json', b'{"bytes":true}')
        self.assertIs(vm.read_json_strict(self.root / boolean['file'])['bytes'], True)

    def test_duplicate_binary_is_rejected(self):
        self.result['tests'] *= 2
        with self.assertRaises(ValueError):
            self.verify()

    def test_source_binding_cannot_be_reused(self):
        self.result['source_sha'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'binding'):
            self.verify()

    def test_changed_log_is_rejected(self):
        (self.root / 'tests.stdout.log').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.verify()

    def test_false_test_count_is_rejected(self):
        self.result['tests'][0]['passed'] = 100
        with self.assertRaisesRegex(ValueError, 'counts'):
            self.verify()

    def test_failed_libtest_outcome_is_not_a_pass(self):
        self.result['tests'][0]['stdout'] = self.artifact('tests.stdout.log', b'test result: FAILED. 3 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.01s\n')
        self.assertFalse(self.verify())

    def test_gui_artifact_binding_is_verified(self):
        self.result['gui']['sha256'] = 'b' * 64
        with self.assertRaisesRegex(ValueError, 'GUI result'):
            self.verify()

    def test_production_gui_flow_is_required(self):
        self.result['gui']['flow'] = {}
        with self.assertRaisesRegex(ValueError, 'missing or invalid'):
            self.verify()
        self.result['gui']['flow'] = None
        with self.assertRaisesRegex(ValueError, 'missing or invalid'):
            self.verify()

    def test_failed_production_gui_flow_is_not_a_pass(self):
        self.result['gui']['flow']['diagnostic'] = self.artifact('gui-flow-error.txt', b'fixture error')
        self.result['gui']['flow']['status'] = 'failed'
        self.assertFalse(self.verify())

    def test_production_gui_flow_is_bound_to_application_artifact(self):
        self.result['gui']['flow']['application_sha256'] = 'b' * 64
        with self.assertRaisesRegex(ValueError, 'application artifact'):
            self.verify()

    def test_production_gui_flow_requires_cancel_and_confirmed_disk_states(self):
        self.result['gui']['flow']['cancellation_destination_present'] = True
        with self.assertRaisesRegex(ValueError, 'disk state'):
            self.verify()

    def test_production_gui_flow_requires_content_identity_and_journal_cleanup(self):
        self.result['gui']['flow']['after_content_sha256'] = 'd' * 64
        with self.assertRaisesRegex(ValueError, 'content preservation'):
            self.verify()
        self.result['gui']['flow']['after_content_sha256'] = 'c' * 64
        self.result['gui']['flow']['after_file_identity_sha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'identity preservation'):
            self.verify()
        self.result['gui']['flow']['after_file_identity_sha256'] = 'e' * 64
        self.result['gui']['flow']['journal_residue_count'] = 1
        with self.assertRaisesRegex(ValueError, 'journal residue'):
            self.verify()

    def test_production_gui_flow_rejects_raw_device_identity(self):
        self.result['gui']['flow']['before_file_identity'] = '1234abcd:0123456789abcdef'
        with self.assertRaisesRegex(ValueError, 'raw device identity'):
            self.verify()

    def test_production_gui_flow_rejects_missing_or_changed_screenshot(self):
        screenshots = self.result['gui']['flow']['screenshots']
        self.result['gui']['flow']['screenshots'] = screenshots[:1]
        with self.assertRaisesRegex(ValueError, 'screenshots are incomplete'):
            self.verify()
        self.result['gui']['flow']['screenshots'] = screenshots
        (self.root / screenshots[0]['file']).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.verify()

    def test_cleanup_requires_a_boolean_success(self):
        self.result['transport']['guest_cleanup'] = {'value': False}
        self.assertFalse(self.verify())

    def test_transport_binding_is_verified(self):
        self.assertTrue(vm.verify_result(self.root, self.manifest, self.result, 'ssh'))
        self.result['transport']['host_platform'] = 'Win32NT'
        with self.assertRaisesRegex(ValueError, 'transport binding'):
            vm.verify_result(self.root, self.manifest, self.result, 'ssh')

    def test_empty_success_output_is_rejected(self):
        self.result['tests'][0]['stdout'] = self.artifact('tests.stdout.log', b'')
        with self.assertRaisesRegex(ValueError, 'summary'):
            self.verify()

    def test_timeout_and_cleanup_failure_are_not_passes(self):
        self.result['tests'][0]['status'] = 'timed-out'
        self.assertFalse(self.verify())
        self.result['tests'][0]['status'] = 'passed'
        self.result['transport']['guest_cleanup'] = False
        self.assertFalse(self.verify())

    def test_traversal_is_rejected(self):
        self.result['tests'][0]['stdout']['file'] = '../outside.log'
        with self.assertRaisesRegex(ValueError, 'plain'):
            self.verify()

    def test_build_messages_only_select_test_executables(self):
        selected = {'reason': 'compiler-artifact', 'profile': {'test': True}, 'target': {'name': 'suite'}, 'executable': '/target/suite.exe'}
        non_test = dict(selected, profile={'test': False}, executable='/target/app.exe')
        rows = vm.test_artifacts(map(json.dumps, [non_test, selected, selected]))
        self.assertEqual([row['file'] for row in rows], ['suite.exe'])
        with self.assertRaises(ValueError):
            vm.test_artifacts([json.dumps(non_test)])

    def test_transport_selection_is_mutually_exclusive(self):
        self.assertEqual(vm.parse_arguments(['--vm-name', 'vm']).vm_name, 'vm')
        self.assertEqual(vm.parse_arguments(['--ssh-host', 'darkrenamer-vm']).ssh_host, 'darkrenamer-vm')
        for arguments in ([], ['--vm-name', 'vm', '--ssh-host', 'alias']):
            self.assert_arguments_rejected(arguments)

    def test_prepare_only_is_transport_free_and_requires_new_explicit_output(self):
        args = vm.parse_arguments(['--prepare-only', '--output', '/external/new-bundle'])
        self.assertTrue(args.prepare_only)
        self.assertIsNone(args.ssh_host)
        self.assertIsNone(args.vm_name)
        for arguments in (
                ['--prepare-only'],
                ['--prepare-only', '--output', '/external/new-bundle', '--ssh-host', 'vm'],
                ['--prepare-only', '--output', '/external/new-bundle', '--desktop-scale', '100'],
                ['--prepare-only', '--output', '/external/new-bundle',
                 '--desktop-width', '800', '--desktop-height', '600']):
            self.assert_arguments_rejected(arguments)

    def test_candidate_options_are_atomic_and_require_vm_identity_for_execution(self):
        common = [
            '--candidate-handoff-root', '/handoff', '--candidate-source-root', '/source',
            '--candidate-run-metadata', '/run.json',
            '--candidate-artifact-metadata', '/artifact.json',
            '--candidate-source-sha', 'a' * 40, '--candidate-workflow-run', '10',
            '--candidate-run-attempt', '1', '--candidate-artifact-id', '20',
            '--candidate-executable-sha256', 'b' * 64,
        ]
        prepared = vm.parse_arguments(['--prepare-only', '--output', '/external/new', *common])
        self.assertTrue(prepared.candidate_mode)
        self.assert_arguments_rejected(['--prepare-only', '--output', '/external/new', *common[:-2]])
        self.assert_arguments_rejected(['--ssh-host', 'vm', *common])
        identity = '12345678-1234-5678-9abc-1234567890ab'
        running = vm.parse_arguments(['--ssh-host', 'vm', '--expected-vm-id', identity, *common])
        self.assertTrue(running.candidate_mode)
        self.assertEqual(running.expected_vm_id, identity)
        bundle = self.root / 'candidate-plan'
        bundle.mkdir()
        (bundle / 'bundle.json').write_text('{"schema_version":2}')
        command = vm.controller_invocation(bundle, running, pwsh='/usr/bin/pwsh')
        self.assertIn('-ExpectedGuestVmId', command)
        self.assertIn('-ExpectedBundleManifestSha256', command)
        self.assertIn(hashlib.sha256((bundle / 'bundle.json').read_bytes()).hexdigest(), command)
        direct = vm.parse_arguments(['--vm-name', 'vm', '--expected-vm-id', identity, *common])
        with mock.patch.object(vm, 'winpath', side_effect=lambda path: 'C:\\evidence\\' + Path(path).name):
            direct_command = vm.controller_invocation(
                bundle, direct, {'helper': 'C:\\helper.ps1'})
        self.assertIn('-ExpectedGuestVmId', direct_command[-1])
        self.assertIn('-ExpectedBundleManifestSha256', direct_command[-1])

    def test_observer_cli_flags_are_role_scoped_and_forwarded(self):
        identity = '12345678-1234-5678-9abc-1234567890ab'
        ui = vm.parse_arguments([
            '--ssh-host', 'vm', '--expected-vm-id', identity,
            '--task-kind', 'ui', '--acceptance-manifest', '/inputs/ui.json',
            '--acceptance-mode', 'current-dpi', '--acceptance-appearance', 'system',
            '--acceptance-high-contrast',
        ])
        ui_command = vm.controller_invocation(self.root, ui, pwsh='/usr/bin/pwsh')
        for value in (
                '-TaskKind', 'ui', '-AcceptanceOutputRoot', '-AcceptanceManifest',
                '-AcceptanceMode', 'current-dpi', '-AcceptanceHighContrast',
                '-ExpectedGuestVmId'):
            self.assertIn(value, ui_command)
        recovery_observer = self.root / 'windows-vm-recovery-acceptance.ps1'
        recovery_observer.write_bytes(b'recovery observer')
        recovery = vm.parse_arguments([
            '--ssh-host', 'vm', '--expected-vm-id', identity,
            '--task-kind', 'recovery', '--recovery-mode', 'ProcessCrash',
            '--recovery-export', '--recovery-intent-only-candidate-discard',
        ])
        recovery_command = vm.controller_invocation(
            self.root, recovery, pwsh='/usr/bin/pwsh')
        for value in (
                '-TaskKind', 'recovery', '-RecoveryOutputRoot', '-RecoveryMode',
                'ProcessCrash', '-RecoveryObserverSha256', '-RecoveryExport',
                '-RecoveryIntentOnlyCandidateDiscard', '-ExpectedGuestVmId'):
            self.assertIn(value, recovery_command)
        for arguments in (
                ['--ssh-host', 'vm', '--task-kind', 'ui'],
                ['--ssh-host', 'vm', '--expected-vm-id', identity,
                 '--task-kind', 'ui', '--acceptance-manifest', '/inputs/ui.json',
                 '--acceptance-mode', 'standard', '--acceptance-appearance', 'light',
                 '--acceptance-high-contrast'],
                ['--ssh-host', 'vm', '--expected-vm-id', identity,
                 '--task-kind', 'recovery', '--recovery-mode', 'WorkerClose',
                 '--recovery-export'],
                ['--ssh-host', 'vm', '--expected-vm-id', identity,
                 '--acceptance-mode', 'standard'],
                ['--ssh-host', 'vm', '--acceptance-text-scale-percent', '100'],
                ['--ssh-host', 'vm', '--recovery-fixture-count', '4096'],
                ['--ssh-host', 'vm', '--expected-vm-id', identity,
                 '--task-kind', 'recovery', '--recovery-mode', 'ProcessCrash',
                 '--test-timeout-seconds', '601'],
        ):
            self.assert_arguments_rejected(arguments)

    def test_candidate_bundle_uses_validated_handoff_without_building(self):
        repo, product_source, _, _, _, args = self.candidate_build_inputs()
        output = self.root / 'candidate-bundle'
        identities = [(repo, 'b' * 40), (product_source, 'a' * 40),
                      (repo, 'b' * 40), (product_source, 'a' * 40)]
        with mock.patch.object(vm, 'clean_source_identity', side_effect=identities), \
             mock.patch.object(vm, 'run_candidate_validators',
                               return_value='DarkReNamer-dry-run-10-1-windows') as validators, \
             mock.patch.object(vm.subprocess, 'run', side_effect=AssertionError('unexpected build')):
            manifest = vm.build_candidate_bundle(repo, output, args)
        validators.assert_called_once()
        validator_root, staged_source, staged_handoff, staged_run, staged_artifact, _ = \
            validators.call_args.args
        self.assertEqual(staged_source, product_source)
        self.assertEqual(validator_root.name, 'scripts')
        self.assertEqual(staged_handoff.name, 'handoff')
        self.assertEqual(staged_run.name, 'candidate-run.json')
        self.assertEqual(staged_artifact.name, 'candidate-artifact.json')
        self.assertNotEqual(staged_handoff, args.candidate_handoff_root)
        self.assertNotEqual(staged_run, args.candidate_run_metadata)
        self.assertNotEqual(staged_artifact, args.candidate_artifact_metadata)
        self.assertEqual(manifest['lane'], 'candidate-gui-only')
        self.assertEqual(manifest['test_binaries'], [])
        self.assertEqual(
            manifest['product']['candidate']['origin_authentication'], 'pending-hosted')
        self.assertEqual((output / 'DarkReNamer.exe').read_bytes(), b'exact candidate bytes')
        for role, leaf in (
                ('ui', 'windows-vm-acceptance.ps1'),
                ('recovery', 'windows-vm-recovery-acceptance.ps1')):
            self.assertEqual(manifest['harness']['observers'][role]['file'], leaf)
            self.assertEqual(
                manifest['harness']['observers'][role]['sha256'],
                hashlib.sha256((output / leaf).read_bytes()).hexdigest())

    def test_candidate_prepare_rejects_duplicate_run_and_artifact_metadata_keys(self):
        for metadata_kind in ('run', 'artifact'):
            with self.subTest(metadata_kind=metadata_kind):
                (repo, product_source, _, run_metadata,
                 artifact_metadata, args) = self.candidate_build_inputs('-' + metadata_kind)
                path = run_metadata if metadata_kind == 'run' else artifact_metadata
                text = path.read_text()
                path.write_text(text.replace('{', '{"id":999,', 1))
                with mock.patch.object(
                        vm, 'clean_source_identity',
                        side_effect=[(repo, 'b' * 40), (product_source, 'a' * 40)]), \
                     mock.patch.object(vm, 'run_candidate_validators') as validators:
                    with self.assertRaisesRegex(ValueError, 'duplicate field'):
                        vm.build_candidate_bundle(
                            repo, self.root / ('bundle-' + metadata_kind), args)
                validators.assert_not_called()

    def test_candidate_prepare_rejects_boolean_numeric_provenance_fields(self):
        mutations = (
            ('handoff', 'schema_version', True),
            ('run', 'id', True),
            ('artifact', 'expired', 0),
        )
        for metadata_kind, field, value in mutations:
            with self.subTest(metadata_kind=metadata_kind, field=field):
                (repo, product_source, handoff, run_metadata,
                 artifact_metadata, args) = self.candidate_build_inputs(
                     '-' + metadata_kind + '-' + field)
                path = {
                    'handoff': handoff / 'release-handoff.json',
                    'run': run_metadata,
                    'artifact': artifact_metadata,
                }[metadata_kind]
                metadata = json.loads(path.read_text())
                metadata[field] = value
                path.write_text(json.dumps(metadata))
                with mock.patch.object(
                        vm, 'clean_source_identity',
                        side_effect=[(repo, 'b' * 40), (product_source, 'a' * 40)]), \
                     mock.patch.object(vm, 'run_candidate_validators') as validators:
                    with self.assertRaisesRegex(ValueError, 'type|integer|identity'):
                        vm.build_candidate_bundle(
                            repo, self.root / ('typed-bundle-' + metadata_kind), args)
                validators.assert_not_called()

    def test_candidate_prepare_detects_source_mutation_during_staging_copy(self):
        (repo, product_source, _, run_metadata,
         _, args) = self.candidate_build_inputs()
        output = self.root / 'mutated-source-bundle'
        identities = [(repo, 'b' * 40), (product_source, 'a' * 40)]
        real_copyfile = vm.shutil.copyfile
        mutated = False

        def copy_and_mutate(source, destination):
            nonlocal mutated
            result = real_copyfile(source, destination)
            if not mutated and Path(source) == run_metadata:
                run_metadata.write_text('{"mutated":true}')
                mutated = True
            return result

        with mock.patch.object(vm, 'clean_source_identity', side_effect=identities), \
             mock.patch.object(vm, 'run_candidate_validators',
                               return_value='DarkReNamer-dry-run-10-1-windows'), \
             mock.patch.object(vm.shutil, 'copyfile', side_effect=copy_and_mutate):
            with self.assertRaisesRegex(RuntimeError, 'Candidate inputs changed'):
                vm.build_candidate_bundle(repo, output, args)

    def test_candidate_prepare_detects_destination_mutation_during_copy(self):
        repo, product_source, _, _, _, args = self.candidate_build_inputs()
        output = self.root / 'mutated-destination-bundle'
        identities = [(repo, 'b' * 40), (product_source, 'a' * 40)]
        real_copyfile = vm.shutil.copyfile

        def copy_and_corrupt(source, destination):
            result = real_copyfile(source, destination)
            if (Path(destination).parent == output and
                    Path(destination).name == 'candidate-artifact.json'):
                Path(destination).write_bytes(b'corrupt')
            return result

        with mock.patch.object(vm, 'clean_source_identity', side_effect=identities), \
             mock.patch.object(vm, 'run_candidate_validators') as validators, \
             mock.patch.object(vm.shutil, 'copyfile', side_effect=copy_and_corrupt):
            with self.assertRaisesRegex(RuntimeError, 'frozen digest'):
                vm.build_candidate_bundle(repo, output, args)
        validators.assert_called_once()

    def test_prepare_only_output_is_new_absolute_external_and_has_plain_ancestry(self):
        with tempfile.TemporaryDirectory() as external_directory:
            external = Path(external_directory)
            repo = external / 'repo'
            repo.mkdir()
            expected = external / 'new-bundle'
            self.assertEqual(vm.resolve_prepare_output_root(repo, expected), expected)
            with self.assertRaisesRegex(ValueError, 'absolute'):
                vm.resolve_prepare_output_root(repo, Path('relative'))
            with self.assertRaisesRegex(ValueError, 'outside'):
                vm.resolve_prepare_output_root(repo, repo / 'generated')
            occupied = external / 'occupied'
            occupied.mkdir()
            with self.assertRaisesRegex(ValueError, 'new directory'):
                vm.resolve_prepare_output_root(repo, occupied)
            linked_parent = external / 'linked-parent'
            (external / 'actual-parent').mkdir()
            linked_parent.symlink_to(external / 'actual-parent', target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'symlink'):
                vm.resolve_prepare_output_root(repo, linked_parent / 'generated')

    def test_desktop_geometry_requires_a_bounded_pair(self):
        args = vm.parse_arguments([
            '--ssh-host', 'vm', '--desktop-width', '800', '--desktop-height', '600'])
        self.assertEqual((args.desktop_width, args.desktop_height), (800, 600))
        for arguments in (
                ['--ssh-host', 'vm', '--desktop-width', '800'],
                ['--ssh-host', 'vm', '--desktop-height', '600'],
                ['--ssh-host', 'vm', '--desktop-width', '799', '--desktop-height', '600'],
                ['--ssh-host', 'vm', '--desktop-width', '800', '--desktop-height', '599'],
                ['--ssh-host', 'vm', '--desktop-width', '8193', '--desktop-height', '600'],
                ['--ssh-host', 'vm', '--desktop-width', '800', '--desktop-height', '4321'],
                ['--ssh-host', 'vm', '--desktop-mode', 'existing',
                 '--desktop-width', '800', '--desktop-height', '600']):
            self.assert_arguments_rejected(arguments)

    def test_direct_vm_identity_is_validated_and_passed_to_the_controller(self):
        identity = '12345678-1234-5678-9abc-1234567890ab'
        args = vm.parse_arguments(['--vm-name', 'VM', '--expected-vm-id', identity.upper()])
        self.assertEqual(args.expected_vm_id, identity)
        with mock.patch.object(vm, 'winpath', side_effect=lambda path: 'C:\\evidence\\' + Path(path).name):
            command = vm.controller_invocation(Path('/external/evidence'), args, {'helper': 'C:\\helper.ps1'})
        self.assertIn("-ExpectedVmId '" + identity + "'", command[-1])
        for value in ('not-a-guid', '00000000-0000-0000-0000-000000000000'):
            self.assert_arguments_rejected(['--vm-name', 'VM', '--expected-vm-id', value])
        self.assert_arguments_rejected(['--ssh-host', 'alias', '--expected-vm-id', identity])

    def test_direct_result_must_match_the_requested_vm_identity(self):
        identity = '12345678-1234-5678-9abc-1234567890ab'
        with self.assertRaisesRegex(ValueError, 'Hyper-V identity binding'):
            vm.verify_result(self.root, self.manifest, self.result, expected_vm_id=identity)
        self.result['transport']['vm_id'] = identity
        self.assertTrue(vm.verify_result(self.root, self.manifest, self.result, expected_vm_id=identity))
        self.result['transport']['vm_id'] = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        with self.assertRaisesRegex(ValueError, 'Hyper-V identity binding'):
            vm.verify_result(self.root, self.manifest, self.result, expected_vm_id=identity)

    def test_ssh_rejects_credentials_and_unsafe_aliases(self):
        invalid = ('-vm', 'user@vm', 'host:22', 'two words', 'host/guest', 'a' * 129)
        for alias in invalid:
            with self.subTest(alias=alias):
                self.assert_arguments_rejected(['--ssh-host', alias])
        self.assert_arguments_rejected(['--ssh-host', 'darkrenamer-vm', '--credential-helper', 'helper.ps1'])

    def test_ssh_local_pwsh_requires_version_7_4_or_newer(self):
        with mock.patch.object(vm.shutil, 'which', return_value='/usr/bin/pwsh'), \
             mock.patch.object(vm.subprocess, 'check_output') as check_output:
            for version in ('7.4', '7.4.0', '7.5.2', '8.0.0'):
                with self.subTest(version=version):
                    check_output.return_value = version + '\n'
                    self.assertEqual(vm.require_pwsh74(), '/usr/bin/pwsh')
            command = check_output.call_args.args[0]
            self.assertIn('$PSVersionTable.PSVersion.ToString()', command)
            self.assertEqual(check_output.call_args.kwargs['timeout'], 10)

    def test_ssh_local_pwsh_rejects_older_or_malformed_versions(self):
        with mock.patch.object(vm.shutil, 'which', return_value='/usr/bin/pwsh'), \
             mock.patch.object(vm.subprocess, 'check_output') as check_output:
            for version in ('7.3.9', '7', '7.4-preview.1', 'not-a-version', ''):
                with self.subTest(version=version):
                    check_output.return_value = version + '\n'
                    with self.assertRaisesRegex(RuntimeError, '7.4 or newer'):
                        vm.require_pwsh74()

    def test_ssh_plan_uses_local_pwsh_without_windows_host_calls(self):
        output = self.root / 'ssh-output'
        args = vm.parse_arguments(['--ssh-host', 'darkrenamer-vm', '--output', str(output)])
        with mock.patch.object(vm, 'windows_host_defaults', side_effect=AssertionError('Windows host defaults used')), \
             mock.patch.object(vm, 'winpath', side_effect=AssertionError('wslpath used')), \
             mock.patch.object(vm, 'require_pwsh74', return_value='/usr/bin/pwsh'):
            root, defaults, pwsh = vm.prepare_transport(Path('/repo'), args)
            command = vm.controller_invocation(root, args, pwsh=pwsh)
        self.assertEqual(root, output)
        self.assertIsNone(defaults)
        self.assertEqual(pwsh, '/usr/bin/pwsh')
        self.assertEqual(command[:6], ['/usr/bin/pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(output / 'run-windows-vm-tests.ps1')])
        self.assertEqual(command[6:], [
            '-BundleRoot', str(output), '-SshHost', 'darkrenamer-vm',
            '-TestTimeoutSeconds', '300', '-TaskKind', 'core'])

    def test_both_transports_use_the_same_controller(self):
        ssh_args = vm.parse_arguments(['--ssh-host', 'darkrenamer-vm'])
        direct_args = vm.parse_arguments(['--vm-name', 'vm'])
        root = Path('/external/evidence')
        ssh = vm.controller_invocation(root, ssh_args, pwsh='/usr/bin/pwsh')
        with mock.patch.object(vm, 'winpath', side_effect=lambda path: 'C:\\evidence\\' + Path(path).name):
            direct = vm.controller_invocation(root, direct_args, {'helper': 'C:\\helper.ps1'})
        self.assertIn('run-windows-vm-tests.ps1', ssh[5])
        self.assertIn('run-windows-vm-tests.ps1', direct[-1])
        self.assertIn('-SshHost', ssh)
        self.assertIn('-VmName', direct[-1])

    def desktop_lease(self):
        return {'status': 'ready', 'leasePath': 'C:\\Temp\\owned', 'leaseId': 'a' * 32,
                'expectedGuestSid': 'S-1-5-21-1-2-3-1001', 'expectedDpi': 192,
                'expectedDesktopWidth': 3840, 'expectedDesktopHeight': 2160}

    def test_managed_desktop_is_default_and_binds_transport_selector(self):
        for selector in (['--ssh-host', 'vm-alias'], ['--vm-name', 'VM']):
            args = vm.parse_arguments(selector)
            self.assertEqual(args.desktop_mode, 'rdp')
            with mock.patch.object(vm.Path, 'is_file', return_value=True), \
                 mock.patch.object(vm, 'windows_host_command', side_effect=[
                     json.dumps(self.desktop_lease()), '{"status":"stopped"}']) as host:
                with vm.managed_desktop(args) as lease:
                    self.assertEqual(lease['expectedDpi'], 192)
                start, stop = [call.args[0] for call in host.call_args_list]
                self.assertIn('-ExpectedSshHost' if args.ssh_host else '-ExpectedVmName', start)
                self.assertIn('-LeaseId', stop)

    def test_managed_desktop_passes_and_checks_requested_geometry(self):
        args = vm.parse_arguments([
            '--ssh-host', 'vm', '--desktop-scale', '100',
            '--desktop-width', '800', '--desktop-height', '600'])
        lease = self.desktop_lease()
        lease.update(expectedDpi=96, expectedDesktopWidth=800, expectedDesktopHeight=600)
        with mock.patch.object(vm.Path, 'is_file', return_value=True), \
             mock.patch.object(vm, 'windows_host_command', side_effect=[
                 json.dumps(lease), '{"status":"stopped"}']) as host:
            with vm.managed_desktop(args) as actual:
                self.assertEqual(actual['expectedDesktopWidth'], 800)
            self.assertIn('-DesktopWidth 800 -DesktopHeight 600', host.call_args_list[0].args[0])

        lease['expectedDesktopWidth'] = 801
        with mock.patch.object(vm.Path, 'is_file', return_value=True), \
             mock.patch.object(vm, 'windows_host_command', side_effect=[
                 json.dumps(lease), '{"status":"stopped"}']):
            with self.assertRaisesRegex(ValueError, 'geometry'):
                with vm.managed_desktop(args):
                    self.fail('Mismatched geometry reached the controller')

    def test_existing_desktop_never_calls_windows_host(self):
        args = vm.parse_arguments(['--ssh-host', 'vm', '--desktop-mode', 'existing'])
        with mock.patch.object(vm, 'windows_host_command', side_effect=AssertionError):
            with vm.managed_desktop(args) as lease:
                self.assertIsNone(lease)

    def test_desktop_stops_after_controller_failure(self):
        args = vm.parse_arguments(['--ssh-host', 'vm'])
        with mock.patch.object(vm.Path, 'is_file', return_value=True), \
             mock.patch.object(vm, 'windows_host_command', side_effect=[
                 json.dumps(self.desktop_lease()), '{"status":"stopped"}']) as host:
            with self.assertRaisesRegex(RuntimeError, 'controller failed'):
                with vm.managed_desktop(args):
                    raise RuntimeError('controller failed')
            self.assertEqual(host.call_count, 2)

    def test_invalid_desktop_identity_is_stopped_before_controller(self):
        args = vm.parse_arguments(['--ssh-host', 'vm'])
        lease = self.desktop_lease()
        lease['expectedGuestSid'] = 'wrong'
        with mock.patch.object(vm.Path, 'is_file', return_value=True), \
             mock.patch.object(vm, 'windows_host_command', side_effect=[
                 json.dumps(lease), '{"status":"stopped"}']) as host:
            with self.assertRaisesRegex(ValueError, 'identity or DPI'):
                with vm.managed_desktop(args):
                    self.fail('Invalid desktop reached controller')
            self.assertEqual(host.call_count, 2)

    def test_malformed_lease_never_requests_arbitrary_cleanup(self):
        args = vm.parse_arguments(['--ssh-host', 'vm'])
        lease = self.desktop_lease()
        lease['leaseId'] = '../other'
        with mock.patch.object(vm.Path, 'is_file', return_value=True), \
             mock.patch.object(vm, 'windows_host_command', return_value=json.dumps(lease)) as host:
            with self.assertRaisesRegex(ValueError, 'invalid lease'):
                with vm.managed_desktop(args):
                    self.fail('Invalid lease reached controller')
            self.assertEqual(host.call_count, 1)

    def test_cleanup_failure_fails_desktop_context(self):
        args = vm.parse_arguments(['--ssh-host', 'vm'])
        with mock.patch.object(vm.Path, 'is_file', return_value=True), \
             mock.patch.object(vm, 'windows_host_command', side_effect=[
                 json.dumps(self.desktop_lease()), '{"status":"failed"}']):
            with self.assertRaisesRegex(RuntimeError, 'cleanup'):
                with vm.managed_desktop(args):
                    pass


if __name__ == '__main__':
    unittest.main()
