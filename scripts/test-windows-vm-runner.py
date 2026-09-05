"""Contract tests for the WSL VM bundle and returned native evidence."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

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
        self.manifest = {'schema_version': 1, 'source_sha': 'a' * 40, 'source_state': 'clean', 'target': vm.TARGET, 'test_binaries': [self.test], 'application': self.app}
        self.result = dict(self.manifest)
        self.result.update(status='passed', tests=[dict(self.test, status='passed', exit_code=0, passed=3, failed=0, ignored=1, stdout=stdout, stderr=stderr)], gui=dict(self.app, status='passed', screenshot=screenshot), transport={'guest_cleanup': True})

    def artifact(self, name, data):
        (self.root / name).write_bytes(data)
        return {'file': name, 'sha256': hashlib.sha256(data).hexdigest()}

    def verify(self):
        return vm.verify_result(self.root, self.manifest, self.result)

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

    def test_cleanup_requires_a_boolean_success(self):
        self.result['transport']['guest_cleanup'] = {'value': False}
        self.assertFalse(self.verify())

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


if __name__ == '__main__':
    unittest.main()
