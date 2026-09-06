"""Contract tests for the host VM bundle and returned native evidence."""
from contextlib import redirect_stderr
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
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

    def assert_arguments_rejected(self, arguments):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            vm.parse_arguments(arguments)

    def test_complete_native_evidence(self):
        self.assertTrue(self.verify())

    def test_missing_binary_is_not_a_pass(self):
        self.result['tests'] = []
        with self.assertRaisesRegex(ValueError, 'missing'):
            self.verify()

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

    def test_ssh_rejects_credentials_and_unsafe_aliases(self):
        invalid = ('-vm', 'user@vm', 'host:22', 'two words', 'host/guest', 'a' * 129)
        for alias in invalid:
            with self.subTest(alias=alias):
                self.assert_arguments_rejected(['--ssh-host', alias])
        self.assert_arguments_rejected(['--ssh-host', 'darkrenamer-vm', '--credential-helper', 'helper.ps1'])

    def test_ssh_plan_uses_local_pwsh_without_windows_host_calls(self):
        output = self.root / 'ssh-output'
        args = vm.parse_arguments(['--ssh-host', 'darkrenamer-vm', '--output', str(output)])
        with mock.patch.object(vm, 'windows_host_defaults', side_effect=AssertionError('Windows host defaults used')), \
             mock.patch.object(vm, 'winpath', side_effect=AssertionError('wslpath used')), \
             mock.patch.object(vm, 'require_pwsh7', return_value='/usr/bin/pwsh'):
            root, defaults, pwsh = vm.prepare_transport(Path('/repo'), args)
            command = vm.controller_invocation(root, args, pwsh=pwsh)
        self.assertEqual(root, output)
        self.assertIsNone(defaults)
        self.assertEqual(pwsh, '/usr/bin/pwsh')
        self.assertEqual(command[:6], ['/usr/bin/pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(output / 'run-windows-vm-tests.ps1')])
        self.assertEqual(command[6:], ['-BundleRoot', str(output), '-SshHost', 'darkrenamer-vm', '-TestTimeoutSeconds', '300'])

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


if __name__ == '__main__':
    unittest.main()
