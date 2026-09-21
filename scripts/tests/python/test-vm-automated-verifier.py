#!/usr/bin/env python3
"""Hosted origin and indexed raw joins reject substituted evidence."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from darkrenamer_tooling.campaign.verifier import (
    EvidenceReader,
    verify_authenticated_gate_metadata,
    verify_backend_execution,
    verify_core_execution,
    verify_execution_freshness,
    verify_appearance,
    verify_focus_reachability,
    FOCUS_ORDER, FOCUS_GROUPS,
    verify_desktop_lease,
    verify_layout_controls,
    verify_setting_restoration,
)
from darkrenamer_tooling.contracts.binding import Candidate
from darkrenamer_tooling.evidence.archive import EvidenceError, ExtractedEvidence, FileReference


EXPECTED_RAIL_IDS = {
    '32771', '32772', '32773', '32774', '32775', '32776', '32777', '32778',
    '32779', '32780', '32781', '32783', '65535', '32784', '32788', '32789',
    '32790', '32785', '32786',
}


def add_indexed_bytes(root, files, path, data):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    files[path] = FileReference(hashlib.sha256(data).hexdigest(), len(data))
    return files[path]


def add_indexed_json(root, files, path, value):
    return add_indexed_bytes(root, files, path, json.dumps(value, separators=(',', ':')).encode())


class GateTests(unittest.TestCase):
    def setUp(self):
        self.candidate = Candidate('a' * 40, '12', '1', '34', 'b' * 64, 'c' * 64)
        def run(number, path, event):
            return {'id': number, 'run_attempt': 1, 'path': '.github/workflows/' + path,
                    'event': event, 'head_branch': 'master', 'head_sha': 'a' * 40,
                    'status': 'completed', 'conclusion': 'success', 'repository_id': 45}
        def jobs(names):
            return [{'name': name, 'status': 'completed', 'conclusion': 'success'} for name in names]
        self.facts = {
            'schema_version': 1,
            'repository': {'full_name': 'PiesP/DarkReNamer', 'id': 45,
                           'owner': {'login': 'PiesP', 'id': 56, 'type': 'User'}},
            'candidate': {'run': run(12, 'release.yaml', 'workflow_dispatch'),
                          'jobs': jobs(['candidate/build-windows']), 'artifact_sha256': 'd' * 64,
                          'artifact': {'id': 34, 'name': 'DarkReNamer-dry-run-12-1-windows',
                                       'digest': 'sha256:' + 'd' * 64, 'size': 1234, 'expired': False,
                                       'workflow_run': {'id': 12, 'head_sha': 'a' * 40}}},
            'ci': {'run': run(78, 'ci.yaml', 'push'),
                   'jobs': jobs(['pr-gate/quality', 'pr-gate/unit', 'pr-gate/security', 'pr-gate/windows'])}}

    def test_authenticated_gate_reduction_is_order_independent(self):
        expected = verify_authenticated_gate_metadata(self.facts, self.candidate)
        self.facts['ci']['jobs'].reverse()
        self.assertEqual(verify_authenticated_gate_metadata(self.facts, self.candidate), expected)
        self.assertEqual(expected['artifact_sha256'], 'd' * 64)

    def test_wrong_source_attempt_event_or_repository_fails(self):
        for field, value in (('head_sha', 'e' * 40), ('run_attempt', 2),
                             ('event', 'pull_request'), ('repository_id', 99),
                             ('conclusion', 'failure'), ('id', True)):
            changed = deepcopy(self.facts)
            changed['candidate']['run'][field] = value
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_authenticated_gate_metadata(changed, self.candidate)

    def test_missing_duplicate_skipped_or_failed_job_rejected(self):
        for mode in ('missing', 'duplicate', 'skipped', 'failed'):
            changed = deepcopy(self.facts)
            jobs = changed['ci']['jobs']
            if mode == 'missing': jobs.pop()
            elif mode == 'duplicate': jobs[-1] = deepcopy(jobs[0])
            else: jobs[0]['conclusion'] = mode
            with self.subTest(mode=mode), self.assertRaises(EvidenceError):
                verify_authenticated_gate_metadata(changed, self.candidate)

    def test_artifact_expiry_wrong_digest_or_run_rejected(self):
        for field, value in (('expired', True), ('digest', 'sha256:' + 'e' * 64),
                             ('workflow_run', {'id': 99, 'head_sha': 'a' * 40}), ('size', False)):
            changed = deepcopy(self.facts)
            changed['candidate']['artifact'][field] = value
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_authenticated_gate_metadata(changed, self.candidate)


class ReaderTests(unittest.TestCase):
    def test_bom_raw_is_hashed_before_parse_and_never_resolved_across_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = 'runs/one/raw.json'
            data = b'\xef\xbb\xbf{"boundary":"initial"}'
            (root / path).parent.mkdir(parents=True)
            (root / path).write_bytes(data)
            pin = FileReference(hashlib.sha256(data).hexdigest(), len(data))
            reader = EvidenceReader(ExtractedEvidence(root, {path: pin}))
            self.assertEqual(reader.json(path), {'boundary': 'initial'})
            reference = {'bytes': len(data), 'sha256': pin.sha256, 'boundary': 'initial'}
            self.assertEqual(reader.digest_reference(reference, prefix='runs/one/'), path)
            with self.assertRaises(EvidenceError): reader.digest_reference(reference, prefix='runs/two/')
            (root / path).write_bytes(data[3:])
            with self.assertRaises(EvidenceError): reader.json(path)

    def test_unindexed_and_parent_relative_sibling_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            reader = EvidenceReader(ExtractedEvidence(Path(directory), {}))
            with self.assertRaises(EvidenceError): reader.json('../outside.json')
            with self.assertRaises(EvidenceError):
                reader.sibling('runs/one/result.json', {'file': '../outside.json', 'sha256': 'a' * 64})


class PredicateTests(unittest.TestCase):
    def setUp(self):
        self.source_sha = 'a' * 40
        self.exe_sha = 'b' * 64
        self.runner_sha = 'c' * 64
        self.observer_sha = 'd' * 64
        self.bundle = {
            'lane': 'candidate-gui-only',
            'target': 'x86_64-pc-windows-msvc',
            'product': {'source_sha': self.source_sha,
                        'application': {'file': 'DarkReNamer.exe', 'sha256': self.exe_sha}},
            'harness': {'runner': {'file': 'windows-vm-guest.ps1', 'sha256': self.runner_sha},
                        'observers': {'ui': {'file': 'windows-vm-acceptance.ps1',
                                             'sha256': self.observer_sha}}},
        }
        self.target = {'hwnd_dpi': 96, 'text_scale_percent': 100, 'contrast': 'normal',
                       'desktop_width': 800, 'desktop_height': 600, 'scale_percent': 100}
        self.environment = {
            'schema_version': 1,
            'platform': {'os_product_name': 'Windows 11 Pro', 'display_version': '25H2',
                         'build_number': 26200, 'architecture': 'x86_64', 'product_type': 1},
            'process': {'pid': 1234, 'session_id': 2, 'is_elevated': False},
            'desktop': {'input_desktop_active': True, 'locked': False},
            'fixture_volume': {'filesystem': 'NTFS', 'root_path': r'C:\fixture',
                               'root_identity': {'volume_serial': '1' * 16, 'file_id': '2' * 32}},
            'target_display': {
                'hwnd': 12, 'process_id': 1234, 'session_id': 2, 'dpi_x': 96, 'dpi_y': 96,
                'text_scale_percent': 100, 'high_contrast_flags': 0,
                'monitor_rect': {'left': 0, 'top': 0, 'right': 800, 'bottom': 600},
                'work_rect': {'left': 0, 'top': 0, 'right': 800, 'bottom': 560},
                'window_rect': {'left': 0, 'top': 0, 'right': 790, 'bottom': 550},
            },
        }

    @staticmethod
    def cleanups():
        return (
            {'owned_processes_after': [],
             'runtime_root_after': {'exists': False, 'entries': []},
             'journal_after': {'entries': []}},
            {'scheduled_task_present': False, 'guest_root_present': False,
             'owned_processes_after': []},
        )

    def lifecycle(self):
        return {'pid': 1234, 'session_id': 2, 'start_time_utc_ticks': '639000000000000000',
                'executable_path': r'C:\bundle\DarkReNamer.exe',
                'executable_sha256': self.exe_sha, 'start_observed': True,
                'exit_observed': True, 'exit_code': 0, 'exit_method': 'normal-close'}

    @staticmethod
    def fixture(name):
        return {'name': name, 'kind': 'file', 'bytes': 5, 'content_sha256': '3' * 64,
                'file_identity': {'volume_serial': '1' * 16, 'file_id': '4' * 32}}

    def checkpoints(self):
        initial = self.fixture('vm-flow-source.txt')
        renamed = self.fixture('vm-confirmed-vm-flow-source.txt')
        return [{'phase': phase, 'fixture_entries': [deepcopy(state)], 'journal_entries': []}
                for phase, state in (('initial', initial), ('after_cancel', initial),
                                     ('after_apply', renamed), ('post_close', renamed))]

    def core_records(self):
        guest, host = self.cleanups()
        raw = {'raw_environment': deepcopy(self.environment),
               'raw_checkpoints': self.checkpoints()}
        result = {'schema_version': 2, 'lane': self.bundle['lane'],
                  'product': deepcopy(self.bundle['product']),
                  'harness': deepcopy(self.bundle['harness']), 'target': self.bundle['target'],
                  'gui': {'flow': raw, 'process_lifecycle': self.lifecycle()},
                  'raw_cleanup': guest}
        return result, {'raw_cleanup': host}

    def test_core_execution_uses_raw_inventory_identity_and_cleanup(self):
        result, transport = self.core_records()
        verify_core_execution(result, self.bundle, transport, self.target, keyboard=False)
        mutations = ('boolean-pid', 'foreign-pid', 'missing-checkpoint', 'journal-residue',
                     'host-residue')
        for mutation in mutations:
            changed_result, changed_transport = deepcopy(result), deepcopy(transport)
            changed_result['passed'] = True
            if mutation == 'boolean-pid':
                changed_result['gui']['process_lifecycle']['pid'] = True
            elif mutation == 'foreign-pid':
                changed_result['gui']['flow']['raw_environment']['process']['pid'] = 99
            elif mutation == 'missing-checkpoint':
                changed_result['gui']['flow']['raw_checkpoints'].pop()
            elif mutation == 'journal-residue':
                changed_result['raw_cleanup']['journal_after']['entries'] = [
                    {'name': 'active.drj', 'kind': 'file', 'bytes': 1}]
            else:
                changed_transport['raw_cleanup']['scheduled_task_present'] = True
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_core_execution(changed_result, self.bundle, changed_transport,
                                      self.target, keyboard=False)

    def control(self, automation_id, control_type='ControlType.Button', *, enabled=True):
        return {'automation_id': automation_id, 'control_type': control_type,
                'visible': True, 'enabled': enabled, 'keyboard_focusable': True,
                'bounds': {'left': 10, 'top': 10, 'right': 30, 'bottom': 30},
                'pid': 1234, 'session_id': 2, 'root_hwnd': 12}

    def layout(self):
        controls = [self.control('', 'ControlType.Window'),
                    self.control('1000', 'ControlType.DataGrid')]
        controls.extend(self.control(identifier) for identifier in sorted(EXPECTED_RAIL_IDS))
        return {'controls': controls, 'focus': [deepcopy(controls[2])], 'screenshots': [], 'focus_reachability': None}

    def test_layout_controls_require_complete_owned_visible_inventory(self):
        layout = self.layout()
        verify_layout_controls(layout, self.environment, keyboard_focus=False)
        mutations = ('missing-control', 'foreign-pid', 'foreign-session', 'boolean-enabled',
                     'clipped-control', 'disabled-focus')
        for mutation in mutations:
            changed = deepcopy(layout)
            if mutation == 'missing-control':
                changed['controls'].pop()
            elif mutation == 'foreign-pid':
                changed['controls'][2]['pid'] = 99
            elif mutation == 'foreign-session':
                changed['controls'][2]['session_id'] = 3
            elif mutation == 'boolean-enabled':
                changed['controls'][2]['enabled'] = 1
            elif mutation == 'clipped-control':
                changed['controls'][2]['bounds']['right'] = 900
            else:
                changed['focus'][0]['enabled'] = False
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_layout_controls(changed, self.environment, keyboard_focus=False)

    def restoration_records(self, root, files):
        colors = {key: index for index, key in enumerate(
            ('window', 'window_text', 'button_face', 'button_text', 'highlight',
             'highlight_text', 'gray_text', 'hot_light'), start=1)}
        high_contrast = {'flags': 0, 'scheme': '', 'colors': colors,
                         'visual_style': {'path': '', 'color': '', 'size': ''}}
        text_scale = {'registry_key_existed': True, 'registry_value_existed': True,
                      'registry_value_kind': 'DWord', 'registry_value': 100,
                      'ui_settings_raw_factor': 1.0, 'ui_settings_percent': 100}
        snapshot = {'schema_version': 2, 'source_sha': self.source_sha,
                    'acceptance_script_sha256': self.observer_sha,
                    'restoration_required': False, 'restoration_verified': True,
                    'original': deepcopy(high_contrast), 'restored': deepcopy(high_contrast)}
        snapshot_pin = add_indexed_json(root, files, 'runs/cell/high-contrast.json', snapshot)
        result = {'high_contrast': {'snapshot': {'file': 'high-contrast.json',
                                                  'sha256': snapshot_pin.sha256}}}
        text_snapshot = {'schema_version': 1, 'source_sha': self.source_sha,
                         'acceptance_script_sha256': self.observer_sha,
                         'restoration_required': True, 'restoration_verified': True,
                         'original': deepcopy(text_scale), 'restored': deepcopy(text_scale)}
        text_pin = add_indexed_json(root, files, 'runs/cell/text-scale.json', text_snapshot)
        activation = add_indexed_json(root, files, 'runs/cell/text-scale-activation.json',
                                      {'observed': True})
        restoration = add_indexed_json(root, files, 'runs/cell/text-scale-restoration.json',
                                       {'observed': True})
        active = {**text_scale, 'registry_value': 150, 'ui_settings_raw_factor': 1.5,
                  'ui_settings_percent': 150}
        result['raw_text_scale'] = {
            'original': deepcopy(text_scale), 'active': active, 'active_winrt_percent': 150,
            'restored': deepcopy(text_scale),
            'snapshot': {'file': 'text-scale.json', 'sha256': text_pin.sha256},
            'activation': {'file': 'text-scale-activation.json', 'sha256': activation.sha256},
            'restoration': {'file': 'text-scale-restoration.json', 'sha256': restoration.sha256},
        }
        return result, snapshot

    def test_setting_restoration_joins_indexed_snapshot_and_rejects_changed_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root, files = Path(directory), {}
            result, snapshot = self.restoration_records(root, files)
            reader = EvidenceReader(ExtractedEvidence(root, files))
            target = {**self.target, 'contrast': 'high-contrast', 'text_scale_percent': 150}
            verify_setting_restoration(reader, 'runs/cell/result.json', result,
                                       self.bundle, target)

            changed_result = deepcopy(result)
            changed_result['raw_text_scale']['restored']['registry_value'] = 101
            with self.assertRaises(EvidenceError):
                verify_setting_restoration(reader, 'runs/cell/result.json', changed_result,
                                           self.bundle, target)

            snapshot['restored']['colors']['window'] = 999
            pin = add_indexed_json(root, files, 'runs/cell/high-contrast.json', snapshot)
            result['high_contrast']['snapshot']['sha256'] = pin.sha256
            reader = EvidenceReader(ExtractedEvidence(root, files))
            with self.assertRaises(EvidenceError):
                verify_setting_restoration(reader, 'runs/cell/result.json', result,
                                           self.bundle, target)

    def test_setting_restoration_rejects_wrong_schema_state_and_unknown_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root, files = Path(directory), {}
            result, snapshot = self.restoration_records(root, files)
            target = {**self.target, 'contrast': 'high-contrast', 'text_scale_percent': 100}

            for name, mutate in (
                ('old-schema', lambda row: row.update(schema_version=1)),
                ('pending-state', lambda row: row.update(restoration_required=True)),
                ('non-boolean-state', lambda row: row.update(restoration_verified=1)),
                ('unknown-field', lambda row: row.update(unexpected=True)),
            ):
                changed = deepcopy(snapshot)
                mutate(changed)
                pin = add_indexed_json(root, files, 'runs/cell/high-contrast.json', changed)
                result['high_contrast']['snapshot']['sha256'] = pin.sha256
                reader = EvidenceReader(ExtractedEvidence(root, files))
                with self.subTest(name=name), self.assertRaises(EvidenceError):
                    verify_setting_restoration(reader, 'runs/cell/result.json', result,
                                               self.bundle, target)

    def backend_records(self, root, *, transcript=None, passed=1, guest_cleanup=True):
        files = {}
        binary_sha = add_indexed_bytes(root, files, 'backend/required-tests.exe', b'MZ native test fixture').sha256
        if transcript is None:
            transcript = ('running 1 test\n'
                          'test engine::required_regression ... ok\n\n'
                          'test result: ok. 1 passed; 0 failed; 0 ignored; '
                          '0 measured; 0 filtered out; finished in 0.01s\n')
        stdout = add_indexed_bytes(root, files, 'backend/stdout.txt', transcript.encode())
        stderr = add_indexed_bytes(root, files, 'backend/stderr.txt', b'')
        bundle = {'schema_version': 1, 'source_sha': self.source_sha, 'source_state': 'clean',
                  'target': 'x86_64-pc-windows-msvc',
                  'test_binaries': [{'file': 'required-tests.exe', 'sha256': binary_sha}]}
        result = {'schema_version': 1, 'source_sha': self.source_sha, 'source_state': 'clean',
                  'target': 'x86_64-pc-windows-msvc', 'failure_reason': None,
                  'transport': {'guest_cleanup': guest_cleanup},
                  'tests': [{'file': 'required-tests.exe', 'sha256': binary_sha,
                             'exit_code': 0, 'passed': passed, 'failed': 0, 'ignored': 0,
                             'stdout': {'file': 'stdout.txt', 'sha256': stdout.sha256},
                             'stderr': {'file': 'stderr.txt', 'sha256': stderr.sha256}}]}
        add_indexed_json(root, files, 'backend/bundle.json', bundle)
        add_indexed_json(root, files, 'backend/result.json', result)
        return EvidenceReader(ExtractedEvidence(root, files)), result

    def test_backend_execution_requires_complete_parent_transcript_and_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            reader, _ = self.backend_records(Path(directory))
            digest = verify_backend_execution(
                reader, 'backend/bundle.json', 'backend/result.json',
                source_sha=self.source_sha, required_tests=['required_regression'])
            self.assertRegex(digest, r'^[0-9a-f]{64}$')

        child_only = ('running 1 test\n'
                      'test engine::required_regression ... ok\n'
                      'test result: ok. 1 passed; 0 failed; 0 ignored; '
                      '0 measured; 1 filtered out; finished in 0.01s\n')
        for mutation in ('child-only', 'boolean-count', 'count-mismatch', 'cleanup'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                options = {}
                if mutation == 'child-only': options['transcript'] = child_only
                elif mutation == 'boolean-count': options['passed'] = True
                elif mutation == 'count-mismatch': options['passed'] = 2
                else: options['guest_cleanup'] = False
                reader, _ = self.backend_records(Path(directory), **options)
                with self.assertRaises(EvidenceError):
                    verify_backend_execution(
                        reader, 'backend/bundle.json', 'backend/result.json',
                        source_sha=self.source_sha, required_tests=['required_regression'])

    def test_backend_binary_bytes_cannot_be_missing_or_substituted(self):
        for missing in (True, False):
            with tempfile.TemporaryDirectory() as directory:
                reader, _ = self.backend_records(Path(directory))
                if missing:
                    del reader.evidence.files['backend/required-tests.exe']
                else:
                    (Path(directory) / 'backend/required-tests.exe').write_bytes(b'MZ substituted')
                with self.assertRaises(EvidenceError):
                    verify_backend_execution(reader, 'backend/bundle.json', 'backend/result.json',
                                             source_sha=self.source_sha, required_tests=['required_regression'])

    def test_freshness_rejects_copied_process_lifetime_or_changed_vm(self):
        result, transport = self.core_records()
        vm = '12345678-1234-1234-1234-123456789abc'
        transport.update(vm_id=vm, vm_identity_kind='hyper-v-guest-parameters-virtual-machine-id-v1',
                         vm_identity_sha256=hashlib.sha256(vm.encode()).hexdigest())
        seen, vms = set(), set()
        verify_execution_freshness(None, result, transport, run_prefix='runs/one/', seen=seen, vm_ids=vms)
        with self.assertRaises(EvidenceError):
            verify_execution_freshness(None, result, transport, run_prefix='runs/two/', seen=seen, vm_ids=vms)
        result['gui']['process_lifecycle']['start_time_utc_ticks'] = '639000000000000001'
        verify_execution_freshness(None, result, transport, run_prefix='runs/two/', seen=seen, vm_ids=vms)
        transport['vm_id'] = '22345678-1234-1234-1234-123456789abc'
        transport['vm_identity_sha256'] = hashlib.sha256(transport['vm_id'].encode()).hexdigest()
        with self.assertRaises(EvidenceError):
            verify_execution_freshness(None, result, transport, run_prefix='runs/three/', seen=seen, vm_ids=vms)

    def test_appearance_requires_exact_owned_checked_menu(self):
        raw = {'hwnd': 12, 'pid': 1234, 'session_id': 2,
               'menu_checked': [{'command_id': command, 'checked': command == 0x9011}
                                for command in (0x9010, 0x9011, 0x9012)]}
        target = {**self.target, 'appearance': 'light'}
        verify_appearance(raw, self.environment, target)
        for key, value in (('pid', 1235), ('session_id', True), ('hwnd', 13)):
            with self.assertRaises(EvidenceError):
                verify_appearance({**raw, key: value}, self.environment, target)
        raw['menu_checked'][1]['checked'] = False
        with self.assertRaises(EvidenceError): verify_appearance(raw, self.environment, target)

    def test_full_keyboard_reachability_rejects_gaps_and_state_mutation(self):
        controls = []
        for index, (identifier, group) in enumerate(zip(FOCUS_ORDER, FOCUS_GROUPS)):
            control = self.control(identifier, 'ControlType.DataGrid' if index == 0 else 'ControlType.Button')
            controls.append({**control, 'rail': 'list' if index == 0 else ('left' if index <= 10 else 'right'),
                             'rail_group': group, 'expected_reachable': True, 'exclusion_reason': None})
        bindings = [{key: value for key, value in control.items()
                     if key not in {'rail', 'rail_group', 'expected_reachable', 'exclusion_reason'}} for control in controls]
        state = {'fixture_root': self.environment['fixture_volume']['root_path'],
                 'root_identity': self.environment['fixture_volume']['root_identity'],
                 'fixture_entries': [self.fixture('navigation.txt')], 'journal_entries': []}
        raw = {'schema_version': 1, 'input_method': 'keyboard', 'initial': bindings[0], 'final': bindings[0],
               'controls': controls, 'state_before': deepcopy(state), 'state_after': deepcopy(state),
               'transitions': [{'sequence': index, 'input': 'tab' if index in {1, 11} else 'down',
                                'from': bindings[index - 1], 'to': bindings[index]} for index in range(1, len(bindings))]}
        raw['transitions'].append({'sequence': len(bindings), 'input': 'tab', 'from': bindings[-1], 'to': bindings[0]})
        verify_focus_reachability(raw, self.environment)
        for mutation in ('missing-target', 'fake-input', 'broken-chain', 'file-change', 'foreign-session', 'unfocused', 'all-tab', 'catalog-disabled', 'foreign-volume'):
            changed = deepcopy(raw)
            if mutation == 'missing-target':
                changed['transitions'].pop()
                changed['final'] = changed['transitions'][-1]['to']
            elif mutation == 'fake-input': changed['transitions'][0]['input'] = 'uia-invoke'
            elif mutation == 'broken-chain': changed['transitions'][1]['from'] = changed['initial']
            elif mutation == 'file-change': changed['state_after']['fixture_entries'][0]['content_sha256'] = 'f' * 64
            elif mutation == 'foreign-session': changed['transitions'][0]['to']['session_id'] = 3
            elif mutation == 'unfocused': changed['transitions'][0]['to']['keyboard_focusable'] = False
            elif mutation == 'all-tab':
                for transition in changed['transitions']: transition['input'] = 'tab'
            elif mutation == 'catalog-disabled':
                changed['controls'][1].update(enabled=False, expected_reachable=False, exclusion_reason='disabled')
            else:
                for phase in ('state_before', 'state_after'):
                    changed[phase]['fixture_entries'][0]['file_identity']['volume_serial'] = 'f' * 16
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError):
                verify_focus_reachability(changed, self.environment)

    def test_desktop_lease_is_exact_clean_and_unique(self):
        lease = {'schema_version': 1, 'mode': 'managed-rdp', 'lease_id': 'f' * 32,
                 'requested_scale': 100, 'requested_width': 800, 'requested_height': 600,
                 'expected_dpi': 96, 'start_status': 'ready', 'stop_status': 'stopped',
                 'cleanup_observed': True}
        seen = set()
        verify_desktop_lease(lease, self.target, seen)
        self.assertEqual(seen, {'f' * 32})
        with self.assertRaises(EvidenceError):
            verify_desktop_lease(lease, self.target, seen)
        for field, value in (('cleanup_observed', False), ('requested_width', 801),
                             ('expected_dpi', True), ('lease_id', 'not-a-lease')):
            changed = {**lease, field: value}
            with self.subTest(field=field), self.assertRaises(EvidenceError):
                verify_desktop_lease(changed, self.target, set())


if __name__ == '__main__':
    unittest.main()
