"""One predeclared VM diagnostic; its observations never change acceptance."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import stat
import subprocess
import threading
import time
import uuid

from darkrenamer_tooling.vm import launcher


TOTAL_SECONDS = 900
FOLLOWUP_SECONDS = 360
FOLLOWUP_CLOSE_RESERVE_SECONDS = 60
COLLECTOR_BYTES = 14 * 1024 * 1024
PHASE_BYTES = 1024 * 1024
OUTER_BYTES = 1024 * 1024
PRODUCT_SHA = 'd25f67a357d360c45d2a6899f4a83c1edc70e0d5'
PRODUCT_EXE_SHA256 = '11ec750a997d6143ec91d0e5172b2528c2f2a27a0d9a92aaec66ea787fe63e89'
SHA256 = re.compile(r'[0-9a-f]{64}\Z')
ATTEMPT_ID = re.compile(r'[a-z][a-z0-9-]{0,63}\Z')
RUN_ID = re.compile(r'[a-f0-9]{32}\Z')
SID = re.compile(r'S-1-5-21-(?:\d+-){2}\d+-\d+\Z')
GUEST_ROLES = ('powershell-runtimebroker-observer', 'powershell-guest-contracts',
               'powershell-guest-process', 'powershell-guest-native')


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError('Duplicate JSON property: ' + name)
        result[name] = value
    return result


def parse_json(data):
    return json.loads(data, object_pairs_hook=unique_object)


def ordinary_ancestry(path: Path):
    for candidate in (path, *path.parents):
        metadata = candidate.lstat()
        if (stat.S_ISLNK(metadata.st_mode)
                or getattr(metadata, 'st_file_attributes', 0) & 0x400):
            raise ValueError('Diagnostic paths must have ordinary ancestry.')


def read_bounded(path, maximum):
    path = Path(path).absolute()
    ordinary_ancestry(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            raise ValueError('Diagnostic input is not a bounded ordinary file.')
        chunks = []
        count = 0
        while count <= maximum:
            chunk = os.read(descriptor, min(64 * 1024, maximum + 1 - count))
            if not chunk:
                break
            chunks.append(chunk)
            count += len(chunk)
        data = b''.join(chunks)
        after = os.fstat(descriptor)
        if ((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                or len(data) != before.st_size):
            raise ValueError('Diagnostic input changed while read.')
        return data
    finally:
        os.close(descriptor)


def write_new(path, data):
    with Path(path).open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def document_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def load_plan(path, expected_sha256):
    if not SHA256.fullmatch(expected_sha256):
        raise ValueError('Plan SHA-256 is required.')
    data = read_bounded(path, 64 * 1024)
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError('Frozen diagnostic plan digest differs.')
    plan = parse_json(data)
    fields = {'schema_version', 'vm_id', 'runner_sid', 'diagnostic_source_sha',
              'candidate_source_sha', 'candidate_executable_sha256', 'attempts'}
    if (type(plan) is not dict or set(plan) != fields or plan['schema_version'] != 1
            or not SID.fullmatch(str(plan['runner_sid']))
            or not re.fullmatch(r'[a-f0-9]{40}', str(plan['diagnostic_source_sha']))
            or plan['candidate_source_sha'] != PRODUCT_SHA
            or plan['candidate_executable_sha256'] != PRODUCT_EXE_SHA256
            or type(plan['attempts']) is not list or not 1 <= len(plan['attempts']) <= 4):
        raise ValueError('Frozen diagnostic plan schema or candidate identity differs.')
    if str(uuid.UUID(plan['vm_id'])) != plan['vm_id']:
        raise ValueError('Plan VM GUID must be canonical lowercase.')
    seen = set()
    for item in plan['attempts']:
        if (type(item) is not dict or set(item) != {
                'id', 'preparation_only', 'followup_seconds', 'launcher_arguments'}
                or not ATTEMPT_ID.fullmatch(str(item['id'])) or item['id'] in seen
                or type(item['preparation_only']) is not bool
                or type(item['followup_seconds']) is not int
                or not 0 <= item['followup_seconds'] <= FOLLOWUP_SECONDS
                or type(item['launcher_arguments']) is not list
                or not all(type(v) is str and len(v) <= 4096
                           for v in item['launcher_arguments'])):
            raise ValueError('Diagnostic attempt is invalid or duplicated.')
        seen.add(item['id'])
        args = workload_arguments(item, plan)
        if args.test_timeout_seconds > 600:
            raise ValueError('Diagnostic workload exceeds its bounded observer timeout.')
    return plan, data


def workload_arguments(attempt, plan):
    arguments = list(attempt['launcher_arguments'])
    if any(v.split('=', 1)[0] in {'--output', '--prepare-only', '--vm-name',
                                  '--credential-helper', '--desktop-mode'}
           for v in arguments):
        raise ValueError('Plan must use unchanged managed RDP with SSH and exclusive output.')
    # Frozen diagnostic plans predate the new-campaign v2 default. Keep their
    # strict contract explicit without rewriting the hash-bound plan bytes.
    if not any(value.split('=', 1)[0] == '--acceptance-profile-id' for value in arguments):
        arguments += ['--acceptance-profile-id', launcher.V1_PROFILE_ID]
    args = launcher.parse_arguments(arguments)
    if args.acceptance_profile_id != launcher.V1_PROFILE_ID:
        raise ValueError('Historical RuntimeBroker diagnostics require the strict v1 profile.')
    if (not args.ssh_host or not args.candidate_mode or args.desktop_mode != 'rdp'
            or args.task_kind != 'ui'
            or args.acceptance_mode != 'current-dpi'
            or args.expected_vm_id != plan['vm_id']
            or args.candidate_source_sha != plan['candidate_source_sha']
            or args.candidate_executable_sha256 != plan['candidate_executable_sha256']):
        raise ValueError('Diagnostic workload differs from pinned candidate/VM contract.')
    return args


class Deadline:
    def __init__(self, seconds=TOTAL_SECONDS, clock=time.monotonic):
        self.clock = clock
        self.end = clock() + seconds

    def remaining(self):
        return max(0.0, self.end - self.clock())

    def require(self, reserve=0):
        remaining = self.remaining() - reserve
        if remaining <= 0:
            raise TimeoutError('Diagnostic overall deadline exhausted.')
        return remaining


class Bridge:
    """Keep the sole handle-owning SSH session alive across the workload."""

    def __init__(self, directory, args, plan, run_id, tooling, deadline):
        self.directory = directory
        self.deadline = deadline
        self.sequence = 0
        self.messages = queue.Queue(maxsize=2)
        self.closed = False
        self.process = None
        self.run_id = run_id
        self.runner_sid = plan['runner_sid']
        self.vm_id = plan['vm_id']
        bridge_source = tooling.bytes_for_role('powershell-runtimebroker-bridge')
        bridge_path = directory / 'runtimebroker-bridge.ps1'
        write_new(bridge_path, bridge_source)
        files = []
        for role in GUEST_ROLES:
            entry = next(row for row in tooling.entries if row.role == role)
            source = tooling.bytes_for_role(role)
            if hashlib.sha256(source).hexdigest() != entry.sha256:
                raise ValueError('Frozen collector dependency hash differs.')
            files.append({'role': role, 'name': entry.bundle, 'sha256': entry.sha256,
                          'data': base64.b64encode(source).decode('ascii')})
        config = {'schema_version': 1, 'ssh_host': args.ssh_host,
                  'vm_id': plan['vm_id'], 'runner_sid': plan['runner_sid'],
                  'run_id': run_id, 'duration_seconds': max(1, math.floor(deadline.require(35))),
                  'files': files}
        config_path = directory / 'bridge-configuration.json'
        write_new(config_path, document_bytes(config))
        self.stderr = (directory / 'bridge.stderr.log').open('xb')
        try:
            self.process = subprocess.Popen(
                [launcher.require_pwsh74(), '-NoLogo', '-NoProfile', '-NonInteractive',
                 '-File', str(bridge_path), '-Configuration', str(config_path)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except Exception:
            self.stderr.close()
            raise
        self.reader = threading.Thread(target=self._read_messages, daemon=True)
        self.errors = threading.Thread(target=self._read_errors, daemon=True)
        self.reader.start()
        self.errors.start()

    def _read_messages(self):
        try:
            while True:
                line = self.process.stdout.readline(128 * 1024 + 1)
                if not line:
                    raise RuntimeError('Observer bridge disconnected.')
                if len(line) > 128 * 1024 or not line.endswith(b'\n'):
                    raise ValueError('Observer bridge response exceeds its bound.')
                self.messages.put(parse_json(line), timeout=5)
        except Exception as error:
            try:
                self.messages.put(error, timeout=5)
            except queue.Full:
                pass

    def _read_errors(self):
        count = 0
        while True:
            data = self.process.stderr.read(4096)
            if not data:
                break
            allowed = min(len(data), max(0, 64 * 1024 - count))
            if allowed:
                self.stderr.write(data[:allowed])
            count += len(data)
        self.stderr.flush()

    def request(self, operation, payload=None, timeout=None):
        if self.closed:
            raise RuntimeError('Observer bridge already closed.')
        self.sequence += 1
        command = {'sequence': self.sequence, 'operation': operation,
                   'run_id': self.run_id, 'payload': payload}
        raw = document_bytes(command)
        if len(raw) > 8192:
            raise ValueError('Observer bridge command exceeds its bound.')
        self.process.stdin.write(raw)
        self.process.stdin.flush()
        try:
            response = self.messages.get(timeout=timeout or self.deadline.require())
        except queue.Empty as error:
            raise TimeoutError('Observer bridge response timed out.') from error
        if isinstance(response, Exception):
            raise response
        if (type(response) is not dict or set(response) != {'sequence', 'ok', 'result', 'error'}
                or response['sequence'] != self.sequence or type(response['ok']) is not bool):
            raise ValueError('Observer bridge RPC identity differs.')
        if not response['ok']:
            raise RuntimeError('Observer bridge failed: ' + str(response['error'])[:4096])
        return response['result']

    def wait_ready(self):
        end = time.monotonic() + min(90, self.deadline.require(35))
        while True:
            result = self.request('ready')
            if result['ready']:
                if (not result['alive'] or result['run_id'] != self.run_id
                        or result['runner_sid'] is None):
                    raise ValueError('Observer READY identity differs.')
                return result
            if not result['alive']:
                raise RuntimeError('Observer exited before READY.')
            if time.monotonic() >= end:
                raise TimeoutError('Observer never became READY.')
            time.sleep(min(0.5, self.deadline.require(35)))

    def mark(self, phase, state, details=None):
        return self.request('phase', {'phase': phase, 'state': state,
                                    'details': details or {},
                                    'recorded_at_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})

    def stop_and_collect(self):
        # Cleanup retains a separate bounded grace after the observation deadline.
        stopped = self.request('stop', timeout=40)
        inventory = self.request('inventory', timeout=20)
        collector_total = phase_total = outer_total = 0
        for row in inventory:
            name = row.get('name')
            if name in {'ready.json', 'events.jsonl', 'result.json'}:
                collector_total += row['size']
            elif type(name) is str and re.fullmatch(r'phases/[a-f0-9]{32}\.json', name):
                if row['size'] > 4096:
                    raise ValueError('Phase marker exceeds its bound.')
                phase_total += row['size']
            elif name in {'observer.stdout.log', 'observer.stderr.log'}:
                outer_total += row['size']
            else:
                raise ValueError('Bridge returned an unexpected diagnostic member.')
            if (type(row.get('size')) is not int or row['size'] < 0
                    or not SHA256.fullmatch(str(row.get('sha256')))):
                raise ValueError('Bridge inventory record is invalid.')
        if (collector_total > COLLECTOR_BYTES or phase_total > PHASE_BYTES
                or outer_total > 128 * 1024 or len(inventory) > 261):
            raise ValueError('Diagnostic aggregate inventory exceeds its reserved budgets.')
        if len({row['name'] for row in inventory}) != len(inventory):
            raise ValueError('Duplicate diagnostic inventory member.')
        for row in inventory:
            target = self.directory / 'observation' / row['name']
            target.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            offset = 0
            with target.open('xb') as stream:
                while offset < row['size']:
                    chunk = self.request('read', {'name': row['name'], 'offset': offset,
                                                  'count': min(49152, row['size'] - offset)}, timeout=20)
                    data = base64.b64decode(chunk, validate=True)
                    if len(data) != min(49152, row['size'] - offset):
                        raise ValueError('Diagnostic chunk differs from frozen inventory.')
                    stream.write(data)
                    digest.update(data)
                    offset += len(data)
            if digest.hexdigest() != row['sha256']:
                raise ValueError('Collected diagnostic bytes differ from guest inventory.')
        names = {row['name'] for row in inventory}
        if not {'ready.json', 'events.jsonl', 'result.json'} <= names:
            raise ValueError('Observer did not produce its actual diagnostic result.')
        observer_result = parse_json(read_bounded(self.directory / 'observation/result.json', COLLECTOR_BYTES))
        if (type(observer_result) is not dict or observer_result.get('schema_version') != 1
                or observer_result.get('run_id') != self.run_id
                or observer_result.get('runner_sid') != self.runner_sid
                or str(uuid.UUID(observer_result.get('expected_vm_id'))) != self.vm_id
                or observer_result.get('status') not in {'diagnostic-completed', 'diagnostic-incomplete'}):
            raise ValueError('Actual collector result identity differs from this diagnostic.')
        cleanup_record = observer_result.get('cleanup') or {}
        compiler_record = observer_result.get('compiler_cleanup') or {}
        collector_owned_cleanup = bool(
            cleanup_record.get('subscriptions_closed') is True
            and type(cleanup_record.get('owned_handles_remaining')) is int
            and cleanup_record['owned_handles_remaining'] == 0
            and cleanup_record.get('errors') == []
            and type(cleanup_record.get('native_close_failures')) is int
            and cleanup_record['native_close_failures'] == 0
            and compiler_record.get('completed') is True
            and type(compiler_record.get('owned_temp_artifacts_remaining')) is int
            and compiler_record['owned_temp_artifacts_remaining'] == 0
            and compiler_record.get('errors') == [])
        # Producer status is retained for independent review, never acceptance proof.
        cleanup = self.request('cleanup', timeout=20)
        return {'observer_job': stopped, 'root_cleanup': cleanup,
                'observer_result': observer_result, 'inventory': inventory,
                'collector_status': observer_result['status'],
                'collector_owned_cleanup': collector_owned_cleanup}

    def close(self):
        if self.closed:
            return self.close_result
        self.closed = True
        forced = False
        if self.process is not None:
            try:
                self.process.stdin.close()  # EOF runs the bridge's exact owned-resource finally.
                self.process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                forced = True
                self.process.kill()  # Only the owned local bridge; remote uncertainty is reported.
                self.process.wait(timeout=10)
            self.reader.join(timeout=1)
            self.errors.join(timeout=2)
            self.stderr.close()
        self.close_result = {'exit_code': self.process.returncode if self.process else None,
                             'forced_local_bridge_stop': forced,
                             'clean': self.process is not None and self.process.returncode == 0 and not forced}
        return self.close_result


def verify_cleanup_proof(path, digest, prior, plan):
    if not SHA256.fullmatch(str(digest)):
        raise ValueError('Previous owned cleanup proof digest is required.')
    data = read_bounded(path, 64 * 1024)
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('Previous owned cleanup proof digest differs.')
    proof = parse_json(data)
    true_fields = {'workload_owned_roots_absent', 'workload_owned_tasks_absent',
                   'workload_owned_processes_absent', 'restoration_verified',
                   'observer_resources_closed', 'desktop_resources_closed'}
    false_fields = {'os_processes_terminated', 'acceptance_reclassified'}
    fields = true_fields | false_fields | {
        'schema_version', 'previous_attempt_id', 'previous_receipt_sha256',
        'vm_id', 'runner_sid', 'verified_at_utc', 'raw_evidence'}
    receipt_data = read_bounded(prior / 'diagnostic-receipt.json', 64 * 1024)
    receipt = parse_json(receipt_data)
    observation = receipt.get('observation') or {}
    if (type(proof) is not dict or set(proof) != fields or proof['schema_version'] != 1
            or proof['previous_attempt_id'] != prior.name
            or proof['previous_receipt_sha256'] != hashlib.sha256(receipt_data).hexdigest()
            or proof['vm_id'] != plan['vm_id'] or proof['runner_sid'] != plan['runner_sid']
            or not all(proof[key] is True for key in true_fields)
            or not all(proof[key] is False for key in false_fields)
            or type(proof['verified_at_utc']) is not str
            or type(proof['raw_evidence']) is not list or not proof['raw_evidence']
            or receipt.get('error') is not None or not receipt.get('ready_before_desktop')
            or receipt.get('deadline_exceeded') is not False
            or receipt.get('desktop_resources_closed') is not True
            or receipt.get('bridge_lifecycle', {}).get('clean') is not True
            or receipt.get('restoration_uncertain') is True
            or observation.get('observer_job', {}).get('clean') is not True
            or observation.get('collector_owned_cleanup') is not True
            or observation.get('root_cleanup', {}).get('removed') is not True):
        raise ValueError('Owned cleanup proof cannot override this failed diagnostic boundary.')
    for row in proof['raw_evidence']:
        if (type(row) is not dict or set(row) != {'file', 'sha256', 'bytes'}
                or type(row['file']) is not str or not Path(row['file']).is_absolute()
                or not SHA256.fullmatch(str(row['sha256']))
                or type(row['bytes']) is not int or not 0 <= row['bytes'] <= 16 * 1024 * 1024):
            raise ValueError('Owned cleanup raw evidence record is invalid.')
        raw = read_bounded(row['file'], row['bytes'])
        if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
            raise ValueError('Owned cleanup raw evidence differs from its pin.')
    return data


def reserve_attempt(output, plan, plan_data, plan_digest, attempt_id,
                    cleanup_proof=None, cleanup_proof_digest=None):
    output = Path(output).absolute()
    if output.exists():
        ordinary_ancestry(output)
    else:
        ordinary_ancestry(output.parent)
        output.mkdir(mode=0o700)
    for item in plan['attempts']:
        prior = output / item['id']
        if not prior.exists():
            continue
        ordinary_ancestry(prior)
        receipt = prior / 'diagnostic-receipt.json'
        if not receipt.is_file():
            raise RuntimeError('Prior attempt is incomplete or owned cleanup/restoration is uncertain.')
        if not parse_json(read_bounded(receipt, 64 * 1024)).get('safe_to_continue'):
            saved = list(prior.glob('owned-cleanup-proof-*.json'))
            if len(saved) > 1:
                raise ValueError('Prior attempt has ambiguous owned cleanup proofs.')
            if saved:
                digest = saved[0].stem.removeprefix('owned-cleanup-proof-')
                verify_cleanup_proof(saved[0], digest, prior, plan)
            elif cleanup_proof is not None:
                proof_data = verify_cleanup_proof(cleanup_proof, cleanup_proof_digest, prior, plan)
                write_new(prior / ('owned-cleanup-proof-' + cleanup_proof_digest + '.json'), proof_data)
                cleanup_proof = None
            else:
                raise RuntimeError('Prior attempt is incomplete or owned cleanup/restoration is uncertain.')
    frozen = output / 'frozen-plan.json'
    if frozen.exists():
        if read_bounded(frozen, 64 * 1024) != plan_data:
            raise ValueError('Diagnostic output belongs to a different frozen plan.')
    else:
        write_new(frozen, plan_data)
    directory = output / attempt_id
    directory.mkdir(mode=0o700)  # Never retry or overwrite an attempted condition.
    write_new(directory / 'attempt.json', document_bytes({
        'schema_version': 1, 'plan_sha256': plan_digest, 'attempt_id': attempt_id,
        'run_id': uuid.uuid4().hex, 'acceptance_reclassification': False}))
    return directory, parse_json(read_bounded(directory / 'attempt.json', 4096))['run_id']


def preparation_result(output, run_id):
    record = parse_json(read_bounded(output / 'runtimebroker-controller.json', 64 * 1024))
    fields = {'schema_version', 'run_id', 'preparation_only', 'preparation_completed',
              'acceptance_claim', 'controller_status', 'guest_cleanup', 'phase_errors',
              'controller_elapsed_ms', 'controller_budget_seconds', 'controller_deadline_exceeded'}
    if (type(record) is not dict or set(record) != fields or record['schema_version'] != 1
            or record['run_id'] != run_id or record['preparation_only'] is not True
            or record['preparation_completed'] is not True or record['acceptance_claim'] is not False
            or record['controller_status'] != 'diagnostic-prepared'
            or type(record['guest_cleanup']) is not bool
            or record['controller_deadline_exceeded'] is not False
            or type(record['phase_errors']) is not list
            or (output / 'acceptance-result.json').exists()):
        raise ValueError('Preparation-only controller result is incomplete or claims acceptance.')
    return record


def ui_restoration(output, manifest, args, observer):
    if not args.acceptance_high_contrast:
        return {'status': 'not_required', 'uncertain': False}
    result_path = output / 'acceptance-result.json'
    if not result_path.is_file():
        return {'status': 'missing', 'uncertain': True}
    raw = read_bounded(result_path, 16 * 1024 * 1024)
    result = parse_json(raw)
    # Bind the actual collected record without relabeling a failed UI outcome
    # as the passing status required by the acceptance verifier.
    if (type(result) is not dict or result.get('schema_version') != 2
            or result.get('lane') != 'candidate-gui-only' or result.get('observer_role') != 'ui'
            or result.get('product') != manifest['product']
            or result.get('harness') != manifest['harness']
            or result.get('application') != manifest['product']['application']
            or result.get('runner_sha256') != manifest['harness']['runner']['sha256']
            or result.get('acceptance_script_sha256') != observer['sha256']
            or result.get('status') not in {'failed', 'review_required'}
            or type(result.get('high_contrast')) is not dict
            or result['high_contrast'].get('requested') is not True):
        raise ValueError('HC restoration record differs from the frozen UI workload.')
    status = (result.get('high_contrast') or {}).get('restoration')
    return {'status': status, 'uncertain': status != 'verified',
            'file': 'acceptance-result.json', 'sha256': hashlib.sha256(raw).hexdigest()}


def run_attempt(repo, directory, plan, attempt, run_id, tooling, bridge_factory=Bridge):
    deadline = Deadline()
    args = workload_arguments(attempt, plan)
    bundle = directory / 'workload'
    receipt = {'schema_version': 1, 'run_id': run_id, 'attempt_id': attempt['id'],
               'diagnostic_source_sha': plan['diagnostic_source_sha'],
               'candidate_source_sha': plan['candidate_source_sha'],
               'candidate_executable_sha256': plan['candidate_executable_sha256'],
               'acceptance_reclassification': False, 'safe_to_continue': False,
               'restoration_uncertain': bool(args.acceptance_high_contrast and not attempt['preparation_only']),
               'ready_before_desktop': False, 'controller_exit_code': None,
               'error': None, 'observation': None}
    bridge = None
    try:
        _, harness_sha = launcher.clean_source_identity(repo, 'Diagnostic source')
        if harness_sha != plan['diagnostic_source_sha']:
            raise ValueError('Diagnostic source differs from frozen plan.')
        manifest = launcher.build_candidate_bundle(repo, bundle, args, tooling)
        args.expected_bundle_manifest_sha256 = launcher.sha256(bundle / 'bundle.json')
        observer_inputs = launcher.prepare_observer_inputs(bundle, manifest, args)
        bridge = bridge_factory(directory, args, plan, run_id, tooling, deadline)
        ready = bridge.wait_ready()
        receipt['ready_before_desktop'] = True
        receipt['observer_ready'] = ready
        bridge.mark('desktop-preparation', 'begin')
        try:
            with launcher.managed_desktop(args, bundle) as desktop:
                if desktop['expectedGuestSid'] != plan['runner_sid']:
                    raise ValueError('Managed desktop SID differs from diagnostic observer.')
                bridge.mark('desktop-preparation', 'end', {'runner_sid': desktop['expectedGuestSid']})
                command = launcher.controller_invocation(bundle, args, desktop_sid=desktop['expectedGuestSid'])
                command += ['-RuntimeBrokerDiagnosticRoot', ready['root'],
                            '-RuntimeBrokerDiagnosticRunId', run_id,
                            '-RuntimeBrokerDiagnosticBudgetSeconds',
                            str(math.floor(deadline.require(155)))]
                if attempt['preparation_only']:
                    command.append('-RuntimeBrokerPreparationOnly')
                bridge.mark('controller', 'begin')
                # The controller cooperatively enters its normal finally using
                # this remaining budget. Never kill it during HC restoration.
                completed = subprocess.run(command, cwd=bundle, check=False)
                receipt['controller_exit_code'] = completed.returncode
                bridge.mark('controller', 'end', {'exit_code': completed.returncode})
                bridge.mark('desktop-stop', 'begin')
        finally:
            bridge.mark('desktop-stop', 'end')
        lease = parse_json(read_bounded(bundle / 'desktop-lease.json', 64 * 1024))
        desktop_clean = lease.get('cleanup_observed') is True
        receipt['desktop_resources_closed'] = desktop_clean
        bridge.mark('followup', 'begin')
        # Stop before the observer's independently rounded deadline (35-second
        # reserve), leaving time to collect and close its owned resources.
        end = time.monotonic() + min(attempt['followup_seconds'],
                                    max(0, deadline.remaining() - FOLLOWUP_CLOSE_RESERVE_SECONDS))
        while time.monotonic() < end:
            state = bridge.request('ready')
            if not state['alive']:
                raise RuntimeError('Observer exited during bounded follow-up.')
            time.sleep(min(1, max(0, end - time.monotonic())))
        bridge.mark('followup', 'end')
        receipt['observation'] = bridge.stop_and_collect()
        observer_clean = receipt['observation']['observer_job'].get('clean') is True
        collector_clean = receipt['observation'].get('collector_owned_cleanup') is True
        root_clean = receipt['observation']['root_cleanup'].get('removed') is True
        observer_output = observer_inputs['output']
        transport = parse_json(read_bounded(observer_output / 'transport.json', 4 * 1024 * 1024))
        if attempt['preparation_only']:
            receipt['preparation_result'] = preparation_result(observer_output, run_id)
            receipt['restoration_uncertain'] = False
        else:
            receipt['restoration'] = ui_restoration(observer_output, manifest, args, observer_inputs['observer'])
            receipt['restoration_uncertain'] = receipt['restoration']['uncertain']
        # A strict OS delta failure may retain its workload root. Further trials
        # require the coordinator to establish restoration/owned cleanup, not a
        # later broker disappearance or this diagnostic's producer summary.
        receipt['deadline_exceeded'] = deadline.remaining() <= 0
        receipt['safe_to_continue'] = bool(not receipt['deadline_exceeded']
                                           and desktop_clean and observer_clean and collector_clean and root_clean
                                           and not receipt['restoration_uncertain']
                                           and transport.get('guest_cleanup') is True)
    except Exception as error:
        receipt['error'] = str(error)[:4096]
        if bridge is not None and receipt['observation'] is None:
            try:
                receipt['observation'] = bridge.stop_and_collect()
            except Exception as cleanup_error:
                receipt['cleanup_error'] = str(cleanup_error)[:4096]
    finally:
        if bridge is not None:
            try:
                receipt['bridge_lifecycle'] = bridge.close()
                if receipt['bridge_lifecycle'].get('clean') is not True:
                    receipt['safe_to_continue'] = False
            except Exception as close_error:
                receipt['bridge_close_error'] = str(close_error)[:4096]
                receipt['safe_to_continue'] = False
        receipt['deadline_exceeded'] = deadline.remaining() <= 0
        if receipt['deadline_exceeded']:
            receipt['safe_to_continue'] = False
        raw = document_bytes(receipt)
        # Do not duplicate the full collector result in the outer receipt.
        if receipt['observation'] is not None:
            receipt['observation'].pop('observer_result', None)
            raw = document_bytes(receipt)
        if len(raw) > 64 * 1024:
            raise ValueError('Diagnostic receipt exceeds its outer metadata reservation.')
        write_new(directory / 'diagnostic-receipt.json', raw)
    return receipt


def cli(repo, argv=None, tooling=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--plan-sha256', required=True)
    parser.add_argument('--attempt', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--previous-owned-cleanup-proof', type=Path)
    parser.add_argument('--previous-owned-cleanup-proof-sha256')
    options = parser.parse_args(argv)
    if (options.previous_owned_cleanup_proof is None) != (options.previous_owned_cleanup_proof_sha256 is None):
        raise ValueError('Previous owned cleanup proof and digest must be supplied together.')
    plan, data = load_plan(options.plan, options.plan_sha256)
    attempt = next((item for item in plan['attempts'] if item['id'] == options.attempt), None)
    if attempt is None:
        raise ValueError('Attempt was not declared in the frozen plan.')
    if options.output.absolute().is_relative_to(Path(repo).resolve()):
        raise ValueError('Diagnostic evidence must remain outside the checkout.')
    directory, run_id = reserve_attempt(options.output, plan, data, options.plan_sha256, attempt['id'],
                                       options.previous_owned_cleanup_proof,
                                       options.previous_owned_cleanup_proof_sha256)
    receipt = run_attempt(repo, directory, plan, attempt, run_id, tooling)
    print(json.dumps({'attempt': attempt['id'], 'diagnostic_receipt': str(directory / 'diagnostic-receipt.json'),
                      'safe_to_continue': receipt['safe_to_continue'], 'error': receipt['error']}))
    return 0 if receipt['safe_to_continue'] and receipt['error'] is None else 1
