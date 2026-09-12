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
