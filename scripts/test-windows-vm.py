#!/usr/bin/env python3
"""Build the current checkout's Windows tests and execute them in a Hyper-V VM."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

TARGET = 'x86_64-pc-windows-msvc'
POWERSHELL = Path('/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe')
WINDOWS_PWSH = Path('/mnt/c/Program Files/PowerShell/7/pwsh.exe')
HANDOFF_FILES = (
    'DarkReNamer-debug-symbols.zip',
    'DarkReNamer.cdx.json',
    'DarkReNamer.exe',
    'DarkReNamer.pdb',
    'DISTRIBUTION.md',
    'LICENSE',
    'release-handoff.json',
    'release-metrics.json',
    'SHA256SUMS.txt',
    'THIRD_PARTY_LICENSES.html',
    'THIRD_PARTY_NOTICES.md',
)
CANDIDATE_HARNESS_FILES = (
    'test-windows-vm.py',
    'run-windows-vm-tests.ps1',
    'windows-vm-guest.ps1',
    'windows-vm-acceptance.ps1',
    'windows-vm-recovery-acceptance.ps1',
    'validate-release-handoff.ps1',
    'validate-release-candidate-metadata.ps1',
    'measure-windows-binary.ps1',
)


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_json_strict(path):
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('JSON contains a duplicate field: ' + key)
            value[key] = item
        return value
    return json.loads(Path(path).read_text(encoding='utf-8-sig'), object_pairs_hook=unique_object)


def copy_frozen_file(source, destination, expected_sha256, label):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    if sha256(destination) != expected_sha256:
        raise RuntimeError(label + ' copy differs from its frozen digest.')


def verify_frozen_files(sources, frozen, label):
    if any(sha256(source) != frozen[name] for name, source in sources.items()):
        raise RuntimeError(label + ' changed during candidate bundle creation.')


def require_positive_json_integer(value, label):
    if type(value) is not int or value <= 0:
        raise ValueError(label + ' must be a positive JSON integer.')
    return str(value)


def validate_candidate_provenance_json(handoff_path, run_path, artifact_path, args):
    handoff = read_json_strict(handoff_path)
    run = read_json_strict(run_path)
    artifact = read_json_strict(artifact_path)
    if (not isinstance(handoff, dict) or set(handoff) != {
            'schema_version', 'source_sha', 'workflow_run', 'executable'} or
            type(handoff.get('schema_version')) is not int or handoff['schema_version'] != 1 or
            handoff.get('source_sha') != args.candidate_source_sha or
            handoff.get('workflow_run') != args.candidate_workflow_run or
            not isinstance(handoff.get('executable'), dict) or
            set(handoff['executable']) != {'filename', 'sha256'} or
            handoff['executable'].get('filename') != 'DarkReNamer.exe' or
            handoff['executable'].get('sha256') != args.candidate_executable_sha256):
        raise ValueError('Release handoff JSON identity or type is invalid.')
    if not isinstance(run, dict):
        raise ValueError('Run metadata must be a JSON object.')
    required_run = {
        'id': args.candidate_workflow_run,
        'run_attempt': args.candidate_run_attempt,
    }
    for name, expected in required_run.items():
        if require_positive_json_integer(run.get(name), 'Run metadata.' + name) != expected:
            raise ValueError('Run metadata identity differs from the explicit candidate.')
    expected_run_strings = {
        'event': 'workflow_dispatch',
        'status': 'completed',
        'conclusion': 'success',
        'head_branch': 'master',
        'head_sha': args.candidate_source_sha,
        'path': '.github/workflows/release.yaml',
    }
    if any(not isinstance(run.get(name), str) or run[name] != expected
           for name, expected in expected_run_strings.items()):
        raise ValueError('Run metadata identity or type is invalid.')
    if not isinstance(artifact, dict):
        raise ValueError('Artifact metadata must be a JSON object.')
    if (require_positive_json_integer(
            artifact.get('id'), 'Artifact metadata.id') != args.candidate_artifact_id or
            not isinstance(artifact.get('name'), str) or
            artifact['name'] != ('DarkReNamer-dry-run-' + args.candidate_workflow_run + '-'
                                 + args.candidate_run_attempt + '-windows') or
            type(artifact.get('expired')) is not bool or artifact['expired']):
        raise ValueError('Artifact metadata identity or type is invalid.')
    artifact_run = artifact.get('workflow_run')
    if (not isinstance(artifact_run, dict) or
            require_positive_json_integer(
                artifact_run.get('id'), 'Artifact metadata.workflow_run.id') !=
            args.candidate_workflow_run or
            not isinstance(artifact_run.get('head_branch'), str) or
            artifact_run['head_branch'] != 'master' or
            not isinstance(artifact_run.get('head_sha'), str) or
            artifact_run['head_sha'] != args.candidate_source_sha):
        raise ValueError('Artifact workflow run identity or type is invalid.')
    return handoff


def psquote(value):
    return "'" + str(value).replace("'", "''") + "'"


def windows_host_command(script, capture=True, timeout=120):
    prelude = '$ErrorActionPreference="Stop"; $env:PSModulePath="$PSHOME\\Modules;C:\\Program Files\\WindowsPowerShell\\Modules"; '
    return subprocess.run(
        [str(POWERSHELL), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-Command', prelude + script],
        cwd='/mnt/c', text=True, check=True, stdout=subprocess.PIPE if capture else None, timeout=timeout,
    ).stdout


def require_pwsh74():
    executable = shutil.which('pwsh')
    if not executable:
        raise RuntimeError('SSH transport requires PowerShell 7.4 or newer as pwsh on PATH.')
    try:
        version = subprocess.check_output(
            [executable, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
             '$PSVersionTable.PSVersion.ToString()'],
            text=True,
            timeout=10,
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise RuntimeError('Unable to verify that pwsh is PowerShell 7.4 or newer.') from error
    if not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+){0,2}', version):
        raise RuntimeError('SSH transport requires PowerShell 7.4 or newer as pwsh on PATH.')
    major, minor = (int(part) for part in version.split('.')[:2])
    if (major, minor) < (7, 4):
        raise RuntimeError('SSH transport requires PowerShell 7.4 or newer as pwsh on PATH.')
    return executable


def winpath(path):
    return subprocess.check_output(['wslpath', '-w', str(path)], text=True).strip()


def safe_ordinary_segment(value):
    if (not isinstance(value, str) or
            not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,159}', value) or
            value in ('.', '..') or value.endswith(('.', ' '))):
        return False
    basename = value.split('.', 1)[0]
    return re.fullmatch(r'(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])', basename,
                        re.IGNORECASE) is None


def leaf(value):
    if not safe_ordinary_segment(value):
        raise ValueError('Artifact names must be plain ASCII file names.')
    return value


def argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    transport = parser.add_mutually_exclusive_group()
    transport.add_argument('--vm-name', help='Existing local Hyper-V VM with an unlocked test-user desktop.')
    transport.add_argument('--ssh-host', help='OpenSSH config alias for the configured VM test account.')
    parser.add_argument('--expected-vm-id', help='Require this exact Hyper-V VM GUID when using --vm-name.')
    parser.add_argument('--credential-helper', help='Windows path to a private helper returning PSCredential with -Action Load.')
    parser.add_argument('--desktop-mode', choices=('rdp', 'existing'), default='rdp',
                        help='Prepare a managed RDP desktop (default), or use an existing unlocked desktop.')
    parser.add_argument('--desktop-helper', help='Trusted Windows desktop-session.ps1 path; uses the local RDP profile.')
    parser.add_argument('--desktop-scale', type=int, choices=(100, 125, 150, 175, 200, 250, 300), default=200)
    parser.add_argument('--desktop-width', type=int,
                        help='Request a managed RDP desktop width; requires --desktop-height.')
    parser.add_argument('--desktop-height', type=int,
                        help='Request a managed RDP desktop height; requires --desktop-width.')
    parser.add_argument('--output', type=Path, help='New external directory for the bundle, logs, and screenshots.')
    parser.add_argument('--prepare-only', action='store_true',
                        help='Build a clean source-bound bundle without contacting the VM.')
    parser.add_argument('--candidate-handoff-root', type=Path,
                        help='Validated release handoff directory for an exact-candidate GUI-only bundle.')
    parser.add_argument('--candidate-source-root', type=Path,
                        help='Clean source checkout at the candidate source commit.')
    parser.add_argument('--candidate-run-metadata', type=Path,
                        help='Downloaded GitHub Actions run metadata JSON for the candidate.')
    parser.add_argument('--candidate-artifact-metadata', type=Path,
                        help='Downloaded GitHub Actions artifact metadata JSON for the candidate.')
    parser.add_argument('--candidate-source-sha')
    parser.add_argument('--candidate-workflow-run')
    parser.add_argument('--candidate-run-attempt')
    parser.add_argument('--candidate-artifact-id')
    parser.add_argument('--candidate-executable-sha256')
    parser.add_argument('--task-kind', choices=('core', 'ui', 'recovery'), default='core')
    parser.add_argument('--acceptance-manifest', type=Path)
    parser.add_argument('--acceptance-mode', choices=(
        'current-dpi', 'full-context', 'standard', 'text-scale', 'tooltip'))
    parser.add_argument('--acceptance-appearance', choices=('system', 'light', 'dark'))
    parser.add_argument('--acceptance-text-scale-percent', type=int, choices=(100, 150), default=100)
    parser.add_argument('--acceptance-high-contrast', action='store_true')
    parser.add_argument('--acceptance-clipboard', action='store_true')
    parser.add_argument('--acceptance-capture-native-menu', action='store_true')
    parser.add_argument('--acceptance-capture-advanced-appearance', action='store_true')
    parser.add_argument('--recovery-mode', choices=(
        'ProcessCrash', 'WorkerCancellation', 'WorkerClose'))
    parser.add_argument('--recovery-fixture-count', type=int, default=4096)
    parser.add_argument('--recovery-export', action='store_true')
    parser.add_argument('--recovery-intent-only-candidate-discard', action='store_true')
    parser.add_argument('--test-timeout-seconds', type=int, default=300)
    return parser


def parse_arguments(argv=None):
    parser = argument_parser()
    raw_arguments = list(sys.argv[1:] if argv is None else argv)
    args = parser.parse_args(raw_arguments)
    def supplied(name):
        return any(value == name or value.startswith(name + '=') for value in raw_arguments)
    if not args.vm_name and not args.ssh_host and not args.prepare_only:
        parser.error('one of --vm-name or --ssh-host is required unless --prepare-only is used.')
    candidate_names = (
        'candidate_handoff_root', 'candidate_source_root', 'candidate_run_metadata',
        'candidate_artifact_metadata', 'candidate_source_sha', 'candidate_workflow_run',
        'candidate_run_attempt', 'candidate_artifact_id', 'candidate_executable_sha256',
    )
    candidate_values = [getattr(args, name) for name in candidate_names]
    if any(value is not None for value in candidate_values) and not all(
            value is not None for value in candidate_values):
        parser.error('all exact-candidate handoff, metadata, identity, and digest options must be supplied together.')
    args.candidate_mode = all(value is not None for value in candidate_values)
    ui_options = any((
        args.acceptance_manifest is not None,
        args.acceptance_mode is not None,
        args.acceptance_appearance is not None,
        supplied('--acceptance-text-scale-percent'),
        args.acceptance_high_contrast,
        args.acceptance_clipboard,
        args.acceptance_capture_native_menu,
        args.acceptance_capture_advanced_appearance,
    ))
    recovery_options = any((
        args.recovery_mode is not None,
        supplied('--recovery-fixture-count'),
        args.recovery_export,
        args.recovery_intent_only_candidate_discard,
    ))
    if args.task_kind == 'core' and (ui_options or recovery_options):
        parser.error('core tasks do not accept UI or recovery observer options.')
    if args.task_kind == 'ui':
        if recovery_options:
            parser.error('UI tasks do not accept recovery observer options.')
        if (args.acceptance_manifest is None or args.acceptance_mode is None or
                args.acceptance_appearance is None):
            parser.error('UI tasks require --acceptance-manifest, --acceptance-mode, and --acceptance-appearance.')
        if ((args.acceptance_mode == 'text-scale') !=
                (args.acceptance_text_scale_percent == 150)):
            parser.error('only text-scale UI tasks may request 150 percent text.')
        current_dpi_option = any((
            args.acceptance_high_contrast,
            args.acceptance_clipboard,
            args.acceptance_capture_native_menu,
            args.acceptance_capture_advanced_appearance,
        ))
        if current_dpi_option and args.acceptance_mode != 'current-dpi':
            parser.error('current-DPI UI options require --acceptance-mode current-dpi.')
        if args.acceptance_high_contrast and args.acceptance_appearance != 'system':
            parser.error('High Contrast UI tasks require --acceptance-appearance system.')
        if args.acceptance_high_contrast and args.acceptance_capture_advanced_appearance:
            parser.error('advanced appearance capture is unavailable during High Contrast.')
    if args.task_kind == 'recovery':
        if ui_options:
            parser.error('recovery tasks do not accept UI observer options.')
        if args.recovery_mode is None:
            parser.error('recovery tasks require --recovery-mode.')
        if not 128 <= args.recovery_fixture_count <= 10000:
            parser.error('--recovery-fixture-count must be between 128 and 10000.')
        if ((args.recovery_export or args.recovery_intent_only_candidate_discard) and
                args.recovery_mode != 'ProcessCrash'):
            parser.error('recovery export and intent-only discard require ProcessCrash mode.')
    if args.task_kind != 'recovery' and recovery_options:
        parser.error('recovery observer options require --task-kind recovery.')
    if args.task_kind != 'ui' and ui_options:
        parser.error('UI observer options require --task-kind ui.')
    if args.candidate_mode:
        if not re.fullmatch(r'[0-9a-f]{40}', args.candidate_source_sha):
            parser.error('--candidate-source-sha must be a lowercase full Git SHA.')
        if not re.fullmatch(r'[0-9a-f]{64}', args.candidate_executable_sha256):
            parser.error('--candidate-executable-sha256 must be a lowercase SHA-256 digest.')
        for name in ('candidate_workflow_run', 'candidate_run_attempt', 'candidate_artifact_id'):
            if not re.fullmatch(r'[1-9][0-9]*', getattr(args, name)):
                parser.error('--' + name.replace('_', '-') + ' must be a positive decimal integer.')
        if not args.prepare_only and args.expected_vm_id is None:
            parser.error('exact-candidate execution requires --expected-vm-id for either transport.')
    if args.task_kind != 'core' and not args.prepare_only and args.expected_vm_id is None:
        parser.error('observer execution requires --expected-vm-id for either transport.')
    if args.prepare_only and (args.vm_name or args.ssh_host or args.desktop_helper or
                              args.credential_helper or args.expected_vm_id or
                              args.desktop_mode != 'rdp' or args.desktop_scale != 200 or
                              args.desktop_width is not None or args.desktop_height is not None or
                              args.task_kind != 'core' or ui_options or recovery_options):
        parser.error('--prepare-only accepts only build and output options, not transport or desktop options.')
    if args.prepare_only and args.output is None:
        parser.error('--prepare-only requires an explicit --output directory.')
    if args.ssh_host and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', args.ssh_host):
        parser.error('--ssh-host must be a 1-128 character OpenSSH config alias using letters, digits, dot, underscore, or hyphen.')
    if args.ssh_host and args.credential_helper:
        parser.error('--credential-helper can only be used with --vm-name PowerShell Direct transport.')
    if args.expected_vm_id is not None:
        if args.ssh_host and not args.candidate_mode and args.task_kind == 'core':
            parser.error('--expected-vm-id can only be used with --vm-name PowerShell Direct transport.')
        try:
            identity = uuid.UUID(args.expected_vm_id)
            if identity.int == 0:
                raise ValueError('Zero UUID')
            args.expected_vm_id = str(identity)
        except ValueError:
            parser.error('--expected-vm-id must be a non-zero UUID.')
    if args.desktop_mode == 'existing' and args.desktop_helper:
        parser.error('--desktop-helper requires --desktop-mode rdp.')
    if (args.desktop_width is None) != (args.desktop_height is None):
        parser.error('--desktop-width and --desktop-height must be specified together.')
    if args.desktop_mode == 'existing' and args.desktop_width is not None:
        parser.error('Desktop geometry can only be requested with --desktop-mode rdp.')
    if args.desktop_width is not None and not (800 <= args.desktop_width <= 8192 and
                                               600 <= args.desktop_height <= 4320):
        parser.error('Desktop geometry must be within 800..8192 by 600..4320 pixels.')
    if not 10 <= args.test_timeout_seconds <= 1800:
        parser.error('Test timeout must be between 10 and 1800 seconds.')
    if args.task_kind != 'core' and args.test_timeout_seconds > 600:
        parser.error('observer timeout must be between 10 and 600 seconds.')
    return args


def windows_host_defaults():
    return json.loads(windows_host_command(
        '[pscustomobject]@{temp=[IO.Path]::GetTempPath();helper=(Join-Path '
        '([Environment]::GetFolderPath("LocalApplicationData")) '
        '"DarkReNamerVmTools\\auth\\credential-store.ps1")} | ConvertTo-Json -Compress'
    ))


def resolve_output_root(repo, args, defaults=None):
    if args.output:
        root = args.output
        if not root.is_absolute():
            raise ValueError('Output must be an absolute external path.')
    elif args.ssh_host:
        root = Path(tempfile.gettempdir()) / ('DarkReNamer-native-' + uuid.uuid4().hex)
    else:
        if defaults is None:
            raise ValueError('PowerShell Direct output resolution requires Windows host defaults.')
        host_temp = subprocess.check_output(['wslpath', '-u', defaults['temp']], text=True).strip()
        root = Path(host_temp) / ('DarkReNamer-native-' + uuid.uuid4().hex)
    if root.exists() or root.is_symlink() or root.resolve().is_relative_to(repo):
        raise RuntimeError('Output must be a new directory outside the checkout.')
    if not args.ssh_host and winpath(root).startswith('\\\\'):
        raise RuntimeError('PowerShell Direct output must be on a Windows drive, not a WSL network path.')
    return root


def resolve_prepare_output_root(repo, requested):
    repo = Path(repo).resolve(strict=True)
    requested = Path(requested)
    if not requested.is_absolute():
        raise ValueError('Prepare-only output must be an absolute external path.')
    if requested.exists():
        raise ValueError('Prepare-only output must be a new directory.')
    parent = requested.parent
    if parent.is_symlink():
        raise ValueError('Prepare-only output ancestry must not contain symlinks.')
    if not parent.is_dir():
        raise ValueError('Prepare-only output parent must be an existing ordinary directory.')
    resolved_parent = parent.resolve(strict=True)
    cursor = parent
    while cursor != cursor.parent:
        if cursor.is_symlink():
            raise ValueError('Prepare-only output ancestry must not contain symlinks.')
        cursor = cursor.parent
    target = resolved_parent / leaf(requested.name)
    if target.is_relative_to(repo) or repo.is_relative_to(target):
        raise ValueError('Prepare-only output must be outside the checkout.')
    return target


def prepare_transport(repo, args):
    if args.ssh_host:
        pwsh = require_pwsh74()
        defaults = None
    else:
        pwsh = None
        defaults = windows_host_defaults()
    return resolve_output_root(repo, args, defaults), defaults, pwsh


def prepare_observer_inputs(root, manifest, args):
    if args.task_kind == 'core':
        return None
    output = root / 'observer-output'
    output.mkdir()
    role = args.task_kind
    observer_name = ('windows-vm-acceptance.ps1' if role == 'ui'
                     else 'windows-vm-recovery-acceptance.ps1')
    observer = (manifest['harness']['observers'][role]
                if manifest['schema_version'] == 2 else {
                    'file': observer_name,
                    'sha256': sha256(root / observer_name),
                })
    if observer.get('file') != observer_name or sha256(root / observer_name) != observer.get('sha256'):
        raise ValueError('Observer artifact differs from its selected frozen role.')
    prepared = {'output': output, 'observer': observer}
    if role == 'ui':
        source = args.acceptance_manifest
        if (not source.is_absolute() or not source.is_file() or source.is_symlink() or
                source.stat().st_size > 1024 * 1024):
            raise ValueError('Acceptance manifest must be an absolute ordinary bounded file.')
        frozen = sha256(source)
        destination = root / 'acceptance-input.json'
        copy_frozen_file(source, destination, frozen, 'Acceptance manifest')
        if sha256(source) != frozen:
            raise RuntimeError('Acceptance manifest changed while preparing the observer task.')
        read_json_strict(destination)
        prepared['manifest'] = destination
    return prepared


def controller_task_arguments(root, args, path_converter=str):
    arguments = ['-TaskKind', args.task_kind]
    if args.task_kind == 'ui':
        arguments += [
            '-AcceptanceOutputRoot', path_converter(root / 'observer-output'),
            '-AcceptanceManifest', path_converter(root / 'acceptance-input.json'),
            '-AcceptanceMode', args.acceptance_mode,
            '-AcceptanceAppearance', args.acceptance_appearance,
            '-AcceptanceTextScalePercent', str(args.acceptance_text_scale_percent),
        ]
        for enabled, switch in (
                (args.acceptance_high_contrast, '-AcceptanceHighContrast'),
                (args.acceptance_clipboard, '-AcceptanceClipboard'),
                (args.acceptance_capture_native_menu, '-AcceptanceCaptureNativeMenu'),
                (args.acceptance_capture_advanced_appearance,
                 '-AcceptanceCaptureAdvancedAppearance')):
            if enabled:
                arguments.append(switch)
    elif args.task_kind == 'recovery':
        arguments += [
            '-RecoveryOutputRoot', path_converter(root / 'observer-output'),
            '-RecoveryMode', args.recovery_mode,
            '-RecoveryFixtureCount', str(args.recovery_fixture_count),
            '-RecoveryObserverSha256', sha256(
                root / 'windows-vm-recovery-acceptance.ps1'),
        ]
        if args.recovery_export:
            arguments.append('-RecoveryExport')
        if args.recovery_intent_only_candidate_discard:
            arguments.append('-RecoveryIntentOnlyCandidateDiscard')
    return arguments


def controller_invocation(root, args, defaults=None, pwsh=None, desktop_sid=None):
    script = root / 'run-windows-vm-tests.ps1'
    common = [
        '-TestTimeoutSeconds', str(args.test_timeout_seconds),
        *controller_task_arguments(root, args),
    ]
    if desktop_sid:
        common += ['-ExpectedDesktopSid', desktop_sid]
    if args.expected_vm_id and (args.candidate_mode or args.task_kind != 'core'):
        common += ['-ExpectedGuestVmId', args.expected_vm_id]
    if args.candidate_mode and args.expected_vm_id:
        common += ['-ExpectedBundleManifestSha256', sha256(root / 'bundle.json')]
    if args.ssh_host:
        executable = pwsh or require_pwsh74()
        return [
            executable, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(script),
            '-BundleRoot', str(root), '-SshHost', args.ssh_host, *common,
        ]
    if defaults is None:
        raise ValueError('PowerShell Direct invocation requires Windows host defaults.')
    windows_root = winpath(root)
    if windows_root.startswith('\\\\'):
        raise RuntimeError('PowerShell Direct output must be on a Windows drive, not a WSL network path.')
    helper = args.credential_helper or defaults['helper']
    task_arguments = controller_task_arguments(root, args, winpath)
    transport = (
        '& ' + psquote(winpath(script)) + ' -BundleRoot ' + psquote(windows_root)
        + ' -VmName ' + psquote(args.vm_name) + ' -CredentialHelper ' + psquote(helper)
        + (' -ExpectedVmId ' + psquote(args.expected_vm_id) if args.expected_vm_id else '')
        + ' -TestTimeoutSeconds ' + str(args.test_timeout_seconds)
        + ''.join(' ' + (value if value.startswith('-') else psquote(value))
                  for value in task_arguments)
        + (' -ExpectedDesktopSid ' + psquote(desktop_sid) if desktop_sid else '')
        + (' -ExpectedGuestVmId ' + psquote(args.expected_vm_id)
           if args.expected_vm_id and (args.candidate_mode or args.task_kind != 'core') else '')
        + (' -ExpectedBundleManifestSha256 ' + psquote(sha256(root / 'bundle.json'))
           if args.candidate_mode and args.expected_vm_id else '')
    )
    prelude = '$ErrorActionPreference="Stop"; $env:PSModulePath="$PSHOME\\Modules;C:\\Program Files\\WindowsPowerShell\\Modules"; '
    return [
        str(POWERSHELL), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned',
        '-Command', prelude + transport,
    ]


def write_desktop_lease_document(root, document):
    if root is None:
        return
    path = Path(root) / 'desktop-lease.json'
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


@contextmanager
def managed_desktop(args, evidence_root=None):
    if args.desktop_mode == 'existing':
        yield None
        return
    if not POWERSHELL.is_file():
        raise RuntimeError('Managed RDP requires WSL Windows interop and a configured desktop helper; use --desktop-mode existing for a separately prepared desktop.')
    helper = psquote(args.desktop_helper) if args.desktop_helper else (
        '(Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) '
        '"DarkReNamerVmTools\\rdp\\desktop-session.ps1")')
    selector = (' -ExpectedSshHost ' + psquote(args.ssh_host) if args.ssh_host else
                ' -ExpectedVmName ' + psquote(args.vm_name))
    # Start owns cleanup until it returns a valid lease; the helper bounds an
    # abandoned child independently of this Python process.
    geometry = ('' if args.desktop_width is None else
                ' -DesktopWidth ' + str(args.desktop_width)
                + ' -DesktopHeight ' + str(args.desktop_height))
    lease_document_path = None if evidence_root is None else Path(evidence_root) / 'desktop-lease.json'
    if lease_document_path is not None and lease_document_path.exists():
        raise ValueError('Managed desktop lease evidence path already exists.')
    lease = json.loads(windows_host_command(
        '& ' + helper + ' -Action Start' + selector + ' -ScalePercent '
        + str(args.desktop_scale) + geometry))
    if (not isinstance(lease, dict) or lease.get('status') != 'ready' or
            not isinstance(lease.get('leasePath'), str) or
            not re.fullmatch(r'[A-Za-z]:\\[^\r\n]+', lease['leasePath']) or
            not isinstance(lease.get('leaseId'), str) or
            not re.fullmatch(r'[a-f0-9]{32}', lease['leaseId'])):
        raise ValueError('Desktop helper returned an invalid lease; inspect its bounded session diagnostics.')
    lease_document = {
        'schema_version': 1,
        'mode': 'managed-rdp',
        'lease_id': lease['leaseId'],
        'requested_scale': args.desktop_scale,
        'requested_width': args.desktop_width,
        'requested_height': args.desktop_height,
        'expected_dpi': lease.get('expectedDpi'),
        'start_status': 'ready',
        'stop_status': 'failed',
        'cleanup_observed': False,
    }
    write_desktop_lease_document(evidence_root, lease_document)
    try:
        if (not isinstance(lease.get('expectedGuestSid'), str) or
                not re.fullmatch(r'S-1-5-21-(?:\d+-){2}\d+-\d+', lease['expectedGuestSid']) or
                type(lease.get('expectedDpi')) is not int or
                lease['expectedDpi'] != args.desktop_scale * 96 // 100):
            raise ValueError('Desktop helper returned an unexpected identity or DPI.')
        if args.desktop_width is not None and (
                type(lease.get('expectedDesktopWidth')) is not int or
                type(lease.get('expectedDesktopHeight')) is not int or
                lease['expectedDesktopWidth'] != args.desktop_width or
                lease['expectedDesktopHeight'] != args.desktop_height):
            raise ValueError('Desktop helper returned unexpected desktop geometry.')
        yield lease
    finally:
        try:
            stopped = json.loads(windows_host_command(
                '& ' + helper + ' -Action Stop -LeasePath ' + psquote(lease['leasePath'])
                + ' -LeaseId ' + psquote(lease['leaseId'])))
        except Exception:
            write_desktop_lease_document(evidence_root, lease_document)
            raise
        cleanup_observed = isinstance(stopped, dict) and stopped.get('status') == 'stopped'
        lease_document['stop_status'] = 'stopped' if cleanup_observed else 'failed'
        lease_document['cleanup_observed'] = cleanup_observed
        write_desktop_lease_document(evidence_root, lease_document)
        if not cleanup_observed:
            raise RuntimeError('Desktop helper did not confirm session cleanup.')


def run_controller(root, args, defaults=None, pwsh=None):
    with managed_desktop(args, root) as desktop:
        command = controller_invocation(root, args, defaults, pwsh,
                                        desktop['expectedGuestSid'] if desktop else None)
        cwd = root if args.ssh_host else Path('/mnt/c')
        subprocess.run(command, cwd=cwd, text=True, check=True)
        if desktop and args.task_kind == 'core':
            result = read_json_strict(root / 'result.json')
            if result.get('gui', {}).get('window_dpi') != desktop['expectedDpi']:
                raise ValueError('Production window DPI differs from the requested RDP scale.')


def test_artifacts(messages):
    artifacts = {}
    for line in messages:
        item = json.loads(line)
        if item.get('reason') != 'compiler-artifact' or not item.get('profile', {}).get('test') or not item.get('executable'):
            continue
        executable = Path(item['executable'])
        if executable.suffix.lower() != '.exe':
            raise ValueError('Cargo returned a non-Windows test executable.')
        name = leaf(executable.name)
        if name in artifacts and artifacts[name]['path'] != executable:
            raise ValueError('Cargo returned colliding test executable names.')
        artifacts[name] = {'name': item['target']['name'], 'file': name, 'path': executable}
    if not artifacts:
        raise ValueError('Cargo did not report any Windows test executables.')
    return [artifacts[key] for key in sorted(artifacts)]


def checked_artifact(root, record):
    path = root / leaf(record['file'])
    if path.is_symlink() or not path.is_file() or sha256(path) != record['sha256']:
        raise ValueError('Artifact digest mismatch: ' + record['file'])
    return path


def application_record(manifest):
    if manifest.get('schema_version') == 2:
        return manifest['product']['application']
    return manifest['application']


def verify_flow_checkpoints(flow):
    checkpoints = flow.get('checkpoints')
    if not isinstance(checkpoints, list) or [row.get('phase') for row in checkpoints
                                             if isinstance(row, dict)] != [
            'initial', 'after_cancel', 'after_apply', 'post_close']:
        raise ValueError('VM production GUI flow checkpoints are incomplete.')
    parsed = {}
    digest_pattern = re.compile(r'^[0-9a-f]{64}$')
    for checkpoint in checkpoints:
        if (not isinstance(checkpoint, dict) or
                set(checkpoint) != {'phase', 'fixture_entries', 'journal_entries'}):
            raise ValueError('VM production GUI flow checkpoint shape is invalid.')
        entries = checkpoint['fixture_entries']
        if not isinstance(entries, list) or len(entries) > 8:
            raise ValueError('VM production GUI flow checkpoint fixture inventory is invalid.')
        by_name = {}
        for row in entries:
            if (not isinstance(row, dict) or
                    set(row) != {'name', 'kind', 'bytes', 'content_sha256', 'file_identity_sha256'}):
                raise ValueError('VM production GUI flow checkpoint file shape is invalid.')
            if row['name'] not in ('vm-flow-source.txt', 'vm-confirmed-vm-flow-source.txt'):
                raise ValueError('VM production GUI flow checkpoint filename is invalid.')
            if (row['kind'] != 'file' or type(row['bytes']) is not int or row['bytes'] < 0 or
                    not isinstance(row['content_sha256'], str) or
                    not digest_pattern.fullmatch(row['content_sha256']) or
                    not isinstance(row['file_identity_sha256'], str) or
                    not digest_pattern.fullmatch(row['file_identity_sha256']) or
                    row['name'] in by_name):
                raise ValueError('VM production GUI flow checkpoint file evidence is invalid.')
            by_name[row['name']] = row
        journal_entries = checkpoint['journal_entries']
        if not isinstance(journal_entries, list) or len(journal_entries) > 16:
            raise ValueError('VM production GUI flow journal inventory is invalid.')
        journal_names = set()
        for entry in journal_entries:
            if (not isinstance(entry, dict) or set(entry) != {'name', 'kind', 'bytes'} or
                    not isinstance(entry['name'], str) or
                    entry['kind'] not in ('file', 'directory', 'reparse') or
                    type(entry['bytes']) is not int or entry['bytes'] < 0):
                raise ValueError('VM production GUI flow journal entry is invalid.')
            if entry['name'] != 'runtime.lock' or entry['kind'] != 'file':
                raise ValueError('VM production GUI flow checkpoints contain journal residue.')
            if entry['name'] in journal_names or entry['bytes'] != 0:
                raise ValueError('VM production GUI flow runtime lock inventory is invalid.')
            journal_names.add(entry['name'])
        parsed[checkpoint['phase']] = (by_name, journal_entries)
    initial, initial_journal = parsed['initial']
    cancelled, cancelled_journal = parsed['after_cancel']
    applied, applied_journal = parsed['after_apply']
    closed, closed_journal = parsed['post_close']
    source_name = 'vm-flow-source.txt'
    destination_name = 'vm-confirmed-vm-flow-source.txt'
    if (set(initial) != {source_name} or set(cancelled) != {source_name} or
            set(applied) != {destination_name} or set(closed) != {destination_name}):
        raise ValueError('VM production GUI flow checkpoint disk state is invalid.')
    baseline = initial[source_name]
    for observed in (cancelled[source_name], applied[destination_name], closed[destination_name]):
        if (observed['bytes'] != baseline['bytes'] or
                observed['content_sha256'] != baseline['content_sha256'] or
                observed['file_identity_sha256'] != baseline['file_identity_sha256']):
            raise ValueError('VM production GUI flow checkpoints do not preserve content and identity.')
    # runtime.lock is the live process lock, not a journal transaction. Every
    # other entry is rejected above, so the serialized inventories prove zero
    # journal residue without hiding the lock file.
    return {
        'initial': initial[source_name],
        'after_cancel': cancelled[source_name],
        'after_apply': applied[destination_name],
        'post_close': closed[destination_name],
    }


def verify_foreground_evidence(gui):
    expected = {
        'hwnd': gui.get('window_handle'),
        'process_id': gui.get('process_id'),
        'session_id': gui.get('session_id'),
        'window_class': gui.get('window_class'),
    }
    if (any(type(expected[key]) is not int or expected[key] <= 0
            for key in ('hwnd', 'process_id', 'session_id')) or
            expected['window_class'] != 'DarkReNamerWindow'):
        raise ValueError('VM candidate GUI target window binding is invalid.')
    activation = gui.get('foreground_activation')
    if not isinstance(activation, dict) or set(activation) != {
            'initial', 'uia_set_focus', 'set_foreground_window', 'final', 'capture_change'}:
        raise ValueError('VM candidate foreground activation evidence is invalid.')
    for name in ('initial', 'final'):
        observed = activation[name]
        if (not isinstance(observed, dict) or set(observed) != set(expected) or
                type(observed['hwnd']) is not int or type(observed['process_id']) is not int or
                (observed['session_id'] is not None and type(observed['session_id']) is not int) or
                not isinstance(observed['window_class'], str) or
                len(observed['window_class']) > 255):
            raise ValueError('VM candidate foreground window observation is invalid.')
    if activation['final'] != expected or activation['capture_change'] is not None:
        raise ValueError('VM candidate GUI did not retain the bound foreground window.')
    if activation['uia_set_focus'] not in {
            'not_attempted', 'succeeded', 'failed', 'element_unavailable'}:
        raise ValueError('VM candidate foreground activation outcome is invalid.')
    attempted = activation['uia_set_focus'] != 'not_attempted'
    if ((not attempted and activation['set_foreground_window'] is not None) or
            (attempted and type(activation['set_foreground_window']) is not bool)):
        raise ValueError('VM candidate SetForegroundWindow outcome is invalid.')


def verify_flow_foreground_observation(observation, gui, expected_label, expected_class):
    if not isinstance(observation, dict) or set(observation) != {
            'label', 'target_hwnd', 'initial', 'uia_set_focus',
            'set_foreground_window', 'final', 'capture_change'}:
        raise ValueError('VM candidate flow foreground observation shape is invalid.')
    if observation['label'] != expected_label:
        raise ValueError('VM candidate flow foreground label is invalid.')
    target_hwnd = observation['target_hwnd']
    if type(target_hwnd) is not int or target_hwnd <= 0:
        raise ValueError('VM candidate flow foreground target is invalid.')
    for name in ('initial', 'final'):
        actual = observation[name]
        if (not isinstance(actual, dict) or set(actual) != {
                'hwnd', 'process_id', 'session_id', 'window_class'} or
                type(actual['hwnd']) is not int or actual['hwnd'] < 0 or
                type(actual['process_id']) is not int or actual['process_id'] < 0 or
                (actual['session_id'] is not None and
                 (type(actual['session_id']) is not int or actual['session_id'] < 0)) or
                not isinstance(actual['window_class'], str) or
                len(actual['window_class']) > 255):
            raise ValueError('VM candidate flow foreground window evidence is invalid.')
    final = observation['final']
    if final['hwnd'] != target_hwnd:
        raise ValueError('VM candidate flow foreground final HWND differs from its target.')
    if final['process_id'] != gui['process_id']:
        raise ValueError('VM candidate flow foreground process binding is invalid.')
    if final['session_id'] != gui['session_id']:
        raise ValueError('VM candidate flow foreground session binding is invalid.')
    if final['window_class'] != expected_class:
        raise ValueError('VM candidate flow foreground window class is invalid.')
    if observation['uia_set_focus'] not in {
            'not_attempted', 'succeeded', 'failed', 'element_unavailable'}:
        raise ValueError('VM candidate flow foreground activation outcome is invalid.')
    attempted = observation['uia_set_focus'] != 'not_attempted'
    if ((not attempted and observation['set_foreground_window'] is not None) or
            (attempted and type(observation['set_foreground_window']) is not bool)):
        raise ValueError('VM candidate flow foreground SetForegroundWindow outcome is invalid.')
    if observation['capture_change'] is not None:
        raise ValueError('VM candidate flow foreground changed during capture.')


def verify_gui_flow(root, manifest, flow, require_checkpoints=False, gui_binding=None):
    if not isinstance(flow, dict):
        raise ValueError('VM production GUI flow is missing or invalid.')
    if 'status' not in flow:
        raise ValueError('VM production GUI flow is missing or invalid.')
    if 'before_file_identity' in flow or 'after_file_identity' in flow:
        raise ValueError('VM production GUI flow must not expose raw device identity.')
    if flow.get('status') != 'passed':
        diagnostic = flow.get('diagnostic')
        if not isinstance(diagnostic, dict):
            raise ValueError('Failed VM production GUI flow has no diagnostic artifact.')
        checked_artifact(root, diagnostic)
        return False
    if flow.get('scope') != 'production-file-add-prefix-cancel-confirm':
        raise ValueError('VM production GUI flow scope is invalid.')
    application = application_record(manifest)
    if (flow.get('application_file') != application['file'] or
            flow.get('application_sha256') != application['sha256']):
        raise ValueError('VM production GUI flow differs from the application artifact.')
    if require_checkpoints and flow.get('input_mode') != 'uia-functional':
        raise ValueError('VM candidate GUI flow input mode is invalid.')
    if (flow.get('source_name') != 'vm-flow-source.txt' or
            flow.get('preview_name') != 'vm-confirmed-vm-flow-source.txt'):
        raise ValueError('VM production GUI flow fixture names are invalid.')
    digest_pattern = re.compile(r'^[0-9a-f]{64}$')
    before_digest = flow.get('before_content_sha256')
    after_digest = flow.get('after_content_sha256')
    if (not isinstance(before_digest, str) or not digest_pattern.fullmatch(before_digest) or
            after_digest != before_digest):
        raise ValueError('VM production GUI flow did not prove content preservation.')
    before_identity = flow.get('before_file_identity_sha256')
    after_identity = flow.get('after_file_identity_sha256')
    if (not isinstance(before_identity, str) or not digest_pattern.fullmatch(before_identity) or
            after_identity != before_identity):
        raise ValueError('VM production GUI flow did not prove file identity preservation.')
    expected_disk_state = {
        'cancellation_source_present': True,
        'cancellation_destination_present': False,
        'confirmed_source_present': False,
        'confirmed_destination_present': True,
    }
    if any(flow.get(key) is not value for key, value in expected_disk_state.items()):
        raise ValueError('VM production GUI flow disk state is invalid.')
    if type(flow.get('journal_residue_count')) is not int or flow['journal_residue_count'] != 0:
        raise ValueError('VM production GUI flow left journal residue.')
    if flow.get('diagnostic') is not None:
        raise ValueError('Passing VM production GUI flow unexpectedly has a diagnostic artifact.')
    screenshots = flow.get('screenshots')
    if not isinstance(screenshots, list) or len(screenshots) != 2:
        raise ValueError('VM production GUI flow screenshots are incomplete.')
    expected_screenshots = {'rename-preview.png', 'apply-confirmation.png'}
    if {row.get('file') for row in screenshots if isinstance(row, dict)} != expected_screenshots:
        raise ValueError('VM production GUI flow screenshots are missing or unexpected.')
    for row in screenshots:
        screenshot = checked_artifact(root, row)
        if (type(row.get('width')) is not int or row['width'] <= 0 or
                type(row.get('height')) is not int or row['height'] <= 0):
            raise ValueError('VM production GUI flow screenshot dimensions are invalid.')
        with screenshot.open('rb') as stream:
            if stream.read(8) != b'\x89PNG\r\n\x1a\n':
                raise ValueError('VM production GUI flow screenshot is not a PNG.')
    if require_checkpoints:
        observations = flow.get('foreground_observations')
        expected_observations = (
            ('production rename preview', 'DarkReNamerWindow'),
            ('apply confirmation task dialog', '#32770'),
        )
        if not isinstance(observations, list) or len(observations) != len(expected_observations):
            raise ValueError('VM candidate flow foreground observations are incomplete.')
        for observation, (label, window_class) in zip(observations, expected_observations):
            verify_flow_foreground_observation(
                observation, gui_binding, label, window_class)
        raw = verify_flow_checkpoints(flow)
        if (flow.get('before_content_sha256') != raw['initial']['content_sha256'] or
                flow.get('after_content_sha256') != raw['after_apply']['content_sha256'] or
                flow.get('before_file_identity_sha256') != raw['initial']['file_identity_sha256'] or
                flow.get('after_file_identity_sha256') != raw['after_apply']['file_identity_sha256'] or
                flow.get('cancellation_source_present') is not True or
                flow.get('cancellation_destination_present') is not False or
                flow.get('confirmed_source_present') is not False or
                flow.get('confirmed_destination_present') is not True or
                type(flow.get('journal_residue_count')) is not int or
                flow['journal_residue_count'] != 0):
            raise ValueError('VM candidate GUI summary contradicts raw checkpoints.')
    return True


def verify_transport_binding(transport, expected_transport_kind=None, expected_vm_id=None,
                             require_identity_proof=False):
    if not isinstance(transport, dict):
        raise ValueError('VM result transport binding mismatch.')
    if expected_transport_kind is not None:
        expected_platform = 'Unix' if expected_transport_kind == 'ssh' else 'Win32NT'
        if (transport.get('kind') != expected_transport_kind or
                transport.get('host_platform') != expected_platform):
            raise ValueError('VM result transport binding mismatch.')
    if expected_vm_id is not None:
        if transport.get('vm_id') != expected_vm_id:
            raise ValueError('VM result Hyper-V identity binding mismatch.')
        expected_identity_sha256 = hashlib.sha256(expected_vm_id.encode()).hexdigest()
        if require_identity_proof and (
                transport.get('vm_identity_kind') !=
                'hyper-v-guest-parameters-virtual-machine-id-v1' or
                transport.get('vm_identity_sha256') != expected_identity_sha256):
            raise ValueError('VM result Hyper-V identity binding mismatch.')
    return True


def verify_result(root, manifest, result, expected_transport_kind=None, expected_vm_id=None):
    if type(manifest.get('schema_version')) is not int or manifest['schema_version'] not in (1, 2):
        raise ValueError('VM bundle schema version is invalid.')
    candidate = manifest['schema_version'] == 2
    if candidate:
        for key in ('schema_version', 'lane', 'target', 'product', 'harness'):
            if result.get(key) != manifest[key]:
                raise ValueError('VM result candidate binding mismatch: ' + key)
        if manifest.get('lane') != 'candidate-gui-only':
            raise ValueError('VM candidate lane is invalid.')
        for record in (
                *manifest['product']['provenance'].values(),
                manifest['harness']['launcher'], manifest['harness']['controller'],
                manifest['harness']['runner'], *manifest['harness']['observers'].values(),
                *manifest['harness']['validators'].values()):
            checked_artifact(root, record)
    else:
        for key in ('schema_version', 'source_sha', 'source_state', 'target'):
            if result.get(key) != manifest[key]:
                raise ValueError('VM result source binding mismatch: ' + key)
    expected = {row['file']: row for row in manifest['test_binaries']}
    rows = result.get('tests', [])
    if (not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows) or
            len(rows) != len(expected) or
            {row.get('file') for row in rows} != set(expected)):
        raise ValueError('VM result has missing, duplicate, or unexpected test binaries.')
    passed = result.get('status') == 'passed'
    total = 0
    for row in rows:
        if row.get('sha256') != expected[row['file']]['sha256']:
            raise ValueError('VM test executable digest differs from the bundle.')
        checked_artifact(root, expected[row['file']])
        for channel in ('stdout', 'stderr'):
            checked_artifact(root, row[channel])
        output = (root / row['stdout']['file']).read_text(encoding='utf-8-sig', errors='replace')
        summaries = re.findall(r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; \d+ measured; (\d+) filtered out;', output, re.MULTILINE)
        counts = [row.get(key) for key in ('passed', 'failed', 'ignored')]
        if summaries:
            summary = summaries[-1]
            if summary[0] != 'ok':
                passed = False
            if counts != [int(n) for n in summary[1:4]] or int(summary[4]) != 0:
                raise ValueError('VM test counts differ from the actual libtest output, or tests were filtered.')
        elif row.get('status') == 'passed':
            raise ValueError('A passing VM test binary has no libtest summary.')
        if row.get('status') != 'passed' or row.get('exit_code') != 0 or any(type(n) is not int or n < 0 for n in counts) or row.get('failed') != 0:
            passed = False
        if type(row.get('passed')) is int:
            total += row['passed']
    application = application_record(manifest)
    checked_artifact(root, application)
    gui = result.get('gui', {})
    if gui.get('file') != application['file'] or gui.get('sha256') != application['sha256']:
        raise ValueError('VM GUI result differs from the application artifact.')
    if gui.get('status') != 'passed':
        passed = False
    else:
        if gui.get('scope') != 'launch-window-screenshot-normal-close':
            raise ValueError('VM GUI smoke scope is invalid.')
        screenshot = checked_artifact(root, gui['screenshot'])
        with screenshot.open('rb') as stream:
            if stream.read(8) != b'\x89PNG\r\n\x1a\n':
                raise ValueError('GUI screenshot is not a PNG.')
        if not verify_gui_flow(root, manifest, gui.get('flow', {}), candidate, gui):
            passed = False
        if candidate:
            if type(gui.get('exit_code')) is not int or gui['exit_code'] != 0:
                raise ValueError('VM candidate GUI process exit code is invalid.')
            verify_foreground_evidence(gui)
    transport = result.get('transport', {})
    if transport.get('guest_cleanup') is not True or (not candidate and total == 0):
        passed = False
    if candidate:
        engine = transport.get('runner_engine')
        if (not isinstance(engine, dict) or set(engine) != {
                'executable', 'version', 'edition', 'effective_policy'} or
                not isinstance(engine['executable'], str) or
                not engine['executable'].lower().endswith('\\pwsh.exe') or
                not isinstance(engine['version'], str) or
                not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+){0,2}', engine['version']) or
                tuple(int(part) for part in engine['version'].split('.')[:2]) < (7, 4) or
                engine['edition'] != 'Core' or engine['effective_policy'] != 'RemoteSigned'):
            raise ValueError('VM candidate runner engine binding is invalid.')
    verify_transport_binding(
        transport, expected_transport_kind, expected_vm_id,
        require_identity_proof=candidate)
    return passed


def clean_source_identity(root, label):
    root = Path(root).resolve(strict=True)
    top = Path(subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', '--show-toplevel'], text=True).strip()).resolve(strict=True)
    if top != root:
        raise ValueError(label + ' must be an exact Git worktree root.')
    if subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'], text=True).strip():
        raise ValueError(label + ' must be clean.')
    source_sha = subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError(label + ' HEAD is invalid.')
    return root, source_sha


def ordinary_input_file(path, label):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ValueError(label + ' must be an absolute ordinary file.')
    return path.resolve(strict=True)


def ordinary_input_directory(path, label):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        raise ValueError(label + ' must be an absolute ordinary directory.')
    return path.resolve(strict=True)


def require_windows_pwsh74():
    if not WINDOWS_PWSH.is_file():
        raise RuntimeError('Candidate handoff validation requires installed Windows PowerShell 7.4+ Core.')
    engine = json.loads(subprocess.check_output([
        str(WINDOWS_PWSH), '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
        '[ordered]@{version=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;'
        'effective_policy=(Get-ExecutionPolicy).ToString()} | ConvertTo-Json -Compress',
    ], text=True, timeout=30))
    try:
        version = tuple(int(part) for part in engine['version'].split('.')[:2])
    except (KeyError, AttributeError, ValueError):
        version = (0, 0)
    if (version < (7, 4) or engine.get('edition') != 'Core' or
            engine.get('effective_policy') != 'RemoteSigned'):
        raise RuntimeError('Candidate validation requires Windows PowerShell 7.4+ Core under its existing RemoteSigned policy.')
    return WINDOWS_PWSH


def run_candidate_validators(validator_root, source_root, handoff_root, run_metadata,
                             artifact_metadata, args):
    executable = require_windows_pwsh74()
    handoff_validator = validator_root / 'validate-release-handoff.ps1'
    metadata_validator = validator_root / 'validate-release-candidate-metadata.ps1'
    subprocess.run([
        str(executable), '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
        winpath(handoff_validator), '-SourceRoot', winpath(source_root),
        '-HandoffRoot', winpath(handoff_root),
    ], text=True, check=True, timeout=300)
    artifact_name = ('DarkReNamer-dry-run-' + args.candidate_workflow_run + '-'
                     + args.candidate_run_attempt + '-windows')
    subprocess.run([
        str(executable), '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
        winpath(metadata_validator), '-RunMetadataPath', winpath(run_metadata),
        '-ArtifactMetadataPath', winpath(artifact_metadata),
        '-ExpectedRunId', args.candidate_workflow_run,
        '-ExpectedRunAttempt', args.candidate_run_attempt,
        '-ExpectedArtifactId', args.candidate_artifact_id,
        '-ExpectedSourceSha', args.candidate_source_sha,
        '-ExpectedArtifactName', artifact_name,
    ], text=True, check=True, timeout=60)
    return artifact_name


def build_candidate_bundle(repo, root, args):
    repo, harness_sha = clean_source_identity(repo, 'Harness source')
    source_root, product_sha = clean_source_identity(args.candidate_source_root, 'Candidate source')
    if product_sha != args.candidate_source_sha:
        raise ValueError('Candidate source HEAD does not match --candidate-source-sha.')
    handoff_root = ordinary_input_directory(args.candidate_handoff_root, 'Candidate handoff root')
    run_metadata = ordinary_input_file(args.candidate_run_metadata, 'Candidate run metadata')
    artifact_metadata = ordinary_input_file(
        args.candidate_artifact_metadata, 'Candidate artifact metadata')
    handoff_metadata = ordinary_input_file(
        handoff_root / 'release-handoff.json', 'Release handoff metadata')
    handoff_executable = ordinary_input_file(
        handoff_root / 'DarkReNamer.exe', 'Release handoff executable')
    actual_handoff_names = {entry.name for entry in handoff_root.iterdir()}
    if actual_handoff_names != set(HANDOFF_FILES):
        raise ValueError('Candidate handoff root must contain the exact release handoff layout.')
    handoff_sources = {
        'handoff/' + name: ordinary_input_file(
            handoff_root / name, 'Release handoff file ' + name)
        for name in HANDOFF_FILES
    }
    metadata_sources = {
        'metadata/candidate-run.json': run_metadata,
        'metadata/candidate-artifact.json': artifact_metadata,
    }
    harness_sources = {
        'scripts/' + name: ordinary_input_file(
            repo / 'scripts' / name, 'Candidate harness file ' + name)
        for name in CANDIDATE_HARNESS_FILES
    }
    frozen_sources = {**handoff_sources, **metadata_sources, **harness_sources}
    # Freeze every externally supplied and harness input before the first copy.
    frozen = {name: sha256(path) for name, path in frozen_sources.items()}
    if frozen['handoff/DarkReNamer.exe'] != args.candidate_executable_sha256:
        raise ValueError('Release handoff executable differs from the explicit candidate digest.')

    root = Path(root)
    with tempfile.TemporaryDirectory(
            prefix='.darkrenamer-vm-stage-', dir=handoff_root.parent) as stage_directory:
        stage = Path(stage_directory)
        for name, source in frozen_sources.items():
            copy_frozen_file(source, stage / name, frozen[name], 'Candidate staged ' + name)
        staged_handoff = stage / 'handoff'
        staged_run = stage / 'metadata' / 'candidate-run.json'
        staged_artifact = stage / 'metadata' / 'candidate-artifact.json'
        validate_candidate_provenance_json(
            staged_handoff / 'release-handoff.json', staged_run, staged_artifact, args)
        artifact_name = run_candidate_validators(
            stage / 'scripts', source_root, staged_handoff,
            staged_run, staged_artifact, args)
        verify_frozen_files(
            {name: stage / name for name in frozen_sources}, frozen,
            'Staged candidate inputs')

        root.mkdir(parents=True)
        bundle_sources = {
            'DarkReNamer.exe': 'handoff/DarkReNamer.exe',
            'release-handoff.json': 'handoff/release-handoff.json',
            'candidate-run.json': 'metadata/candidate-run.json',
            'candidate-artifact.json': 'metadata/candidate-artifact.json',
            **{name: 'scripts/' + name for name in CANDIDATE_HARNESS_FILES},
        }
        for destination_name, staged_name in bundle_sources.items():
            copy_frozen_file(
                stage / staged_name, root / destination_name, frozen[staged_name],
                'Candidate bundle ' + destination_name)
        bundle_frozen_sources = {
            staged_name: root / destination_name
            for destination_name, staged_name in bundle_sources.items()
        }
        verify_frozen_files(bundle_frozen_sources, frozen, 'Candidate bundle files')

    verify_frozen_files(frozen_sources, frozen, 'Candidate inputs')
    _, final_harness_sha = clean_source_identity(repo, 'Harness source')
    _, final_product_sha = clean_source_identity(source_root, 'Candidate source')
    if final_harness_sha != harness_sha or final_product_sha != product_sha:
        raise RuntimeError('Source checkout changed during candidate bundle creation.')
    verify_frozen_files(bundle_frozen_sources, frozen, 'Candidate bundle files')
    manifest = {
        'schema_version': 2,
        'lane': 'candidate-gui-only',
        'target': TARGET,
        'product': {
            'source_sha': product_sha,
            'source_state': 'clean',
            'candidate': {
                'workflow_run': args.candidate_workflow_run,
                'run_attempt': args.candidate_run_attempt,
                'artifact_id': args.candidate_artifact_id,
                'artifact_name': artifact_name,
                'origin_authentication': 'pending-hosted',
            },
            'application': {
                'file': 'DarkReNamer.exe',
                'sha256': frozen['handoff/DarkReNamer.exe'],
            },
            'provenance': {
                'release_handoff': {
                    'file': 'release-handoff.json',
                    'sha256': frozen['handoff/release-handoff.json'],
                },
                'run_metadata': {
                    'file': 'candidate-run.json',
                    'sha256': frozen['metadata/candidate-run.json'],
                },
                'artifact_metadata': {
                    'file': 'candidate-artifact.json',
                    'sha256': frozen['metadata/candidate-artifact.json'],
                },
            },
        },
        'harness': {
            'source_sha': harness_sha,
            'source_state': 'clean',
            'launcher': {
                'file': 'test-windows-vm.py',
                'sha256': frozen['scripts/test-windows-vm.py'],
            },
            'controller': {
                'file': 'run-windows-vm-tests.ps1',
                'sha256': frozen['scripts/run-windows-vm-tests.ps1'],
            },
            'runner': {
                'file': 'windows-vm-guest.ps1',
                'sha256': frozen['scripts/windows-vm-guest.ps1'],
            },
            'observers': {
                'ui': {
                    'file': 'windows-vm-acceptance.ps1',
                    'sha256': frozen['scripts/windows-vm-acceptance.ps1'],
                },
                'recovery': {
                    'file': 'windows-vm-recovery-acceptance.ps1',
                    'sha256': frozen['scripts/windows-vm-recovery-acceptance.ps1'],
                },
            },
            'validators': {
                'release_handoff': {
                    'file': 'validate-release-handoff.ps1',
                    'sha256': frozen['scripts/validate-release-handoff.ps1'],
                },
                'candidate_metadata': {
                    'file': 'validate-release-candidate-metadata.ps1',
                    'sha256': frozen['scripts/validate-release-candidate-metadata.ps1'],
                },
                'binary_measurement': {
                    'file': 'measure-windows-binary.ps1',
                    'sha256': frozen['scripts/measure-windows-binary.ps1'],
                },
            },
        },
        'test_binaries': [],
    }
    (root / 'bundle.json').write_text(json.dumps(manifest, indent=2))
    return manifest


def build_bundle(repo, root):
    repo = Path(repo)
    root = Path(root)
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True).strip():
        raise RuntimeError('Commit or preserve checkout changes before VM verification; results must bind a clean source SHA.')
    source_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    root.mkdir(parents=True)
    print('Building Windows tests for source ' + source_sha, flush=True)
    env = dict(os.environ)
    env.setdefault('RC', '/usr/bin/llvm-rc-19')
    command = ['cargo', 'xwin', 'test', '--workspace', '--all-targets', '--all-features', '--locked', '--target', TARGET, '--no-run', '--message-format=json']
    messages_path = root / 'cargo-build.jsonl'
    with messages_path.open('w') as stream:
        subprocess.run(command, cwd=repo, env=env, stdout=stream, check=True)
    with messages_path.open() as stream:
        artifacts = test_artifacts(stream)
    subprocess.run(['cargo', 'xwin', 'build', '--release', '--locked', '--target', TARGET, '--package', 'darknamer-app', '--bin', 'DarkReNamer'], cwd=repo, env=env, check=True)
    metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--no-deps', '--format-version=1', '--locked'], cwd=repo, env=env, text=True))
    application = Path(metadata['target_directory']) / TARGET / 'release' / 'DarkReNamer.exe'
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip() != source_sha or subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True).strip():
        raise RuntimeError('Checkout changed during the build; refusing to label the bundle with a stale source SHA.')
    for row in artifacts:
        shutil.copyfile(row.pop('path'), root / row['file'])
        row['sha256'] = sha256(root / row['file'])
    shutil.copyfile(application, root / 'DarkReNamer.exe')
    for name in (
            'windows-vm-guest.ps1', 'run-windows-vm-tests.ps1',
            'windows-vm-acceptance.ps1', 'windows-vm-recovery-acceptance.ps1'):
        shutil.copyfile(repo / 'scripts' / name, root / name)
    manifest = {
        'schema_version': 1, 'source_sha': source_sha, 'source_state': 'clean', 'target': TARGET,
        'cargo_lock_sha256': sha256(repo / 'Cargo.lock'), 'test_binaries': artifacts,
        'application': {'file': 'DarkReNamer.exe', 'sha256': sha256(root / 'DarkReNamer.exe')},
        'runner': {'file': 'windows-vm-guest.ps1', 'sha256': sha256(root / 'windows-vm-guest.ps1')},
    }
    (root / 'bundle.json').write_text(json.dumps(manifest, indent=2))
    return manifest


def verify_observer_result(manifest, result, role, observer_sha256):
    if not isinstance(result, dict) or type(result.get('schema_version')) is not int:
        raise ValueError('Observer result schema is invalid.')
    if result['schema_version'] != manifest['schema_version']:
        raise ValueError('Observer result schema differs from the bundle.')
    candidate = manifest['schema_version'] == 2
    if candidate:
        if (result.get('lane') != 'candidate-gui-only' or
                result.get('observer_role') != role or
                result.get('product') != manifest['product'] or
                result.get('harness') != manifest['harness']):
            raise ValueError('Candidate observer result provenance or role differs from the bundle.')
        application = manifest['product']['application']
        runner = manifest['harness']['runner']
        observer = manifest['harness']['observers'][role]
    else:
        if any(name in result for name in ('lane', 'product', 'harness', 'observer_role')):
            raise ValueError('Legacy observer result contains candidate-only provenance.')
        if result.get('source_sha') != manifest['source_sha']:
            raise ValueError('Legacy observer result source differs from the bundle.')
        if role == 'recovery' and result.get('source_state') != manifest['source_state']:
            raise ValueError('Legacy recovery result state differs from the bundle.')
        application = manifest['application']
        runner = manifest['runner']
        observer = {
            'file': ('windows-vm-acceptance.ps1' if role == 'ui'
                     else 'windows-vm-recovery-acceptance.ps1'),
            'sha256': observer_sha256,
        }
    if (observer != {
            'file': ('windows-vm-acceptance.ps1' if role == 'ui'
                     else 'windows-vm-recovery-acceptance.ps1'),
            'sha256': observer_sha256,
            } or result.get('application') != application or
            result.get('runner_sha256') != runner['sha256']):
        raise ValueError('Observer result executable or script binding is invalid.')
    if role == 'ui':
        if (result.get('acceptance_script_sha256') != observer_sha256 or
                result.get('status') != 'review_required'):
            raise ValueError('UI observer did not return a bound review-required result.')
    elif (result.get('observer') != observer or result.get('status') != 'passed'):
        raise ValueError('Recovery observer did not return a bound passing result.')
    return True


def verify_observer_transport(root, role, expected_transport_kind, expected_vm_id):
    transport = read_json_strict(Path(root) / 'transport.json')
    engine_name = 'acceptance_engine' if role == 'ui' else 'recovery_engine'
    engine = transport.get(engine_name) if isinstance(transport, dict) else None
    process = transport.get('observer_process') if isinstance(transport, dict) else None
    if (not isinstance(transport, dict) or transport.get('task_kind') != role or
            transport.get('status') != 'collected' or
            transport.get('guest_cleanup') is not True or
            not isinstance(process, dict) or process.get('state') != 'exited' or
            type(process.get('exit_code')) is not int or process['exit_code'] != 0 or
            not isinstance(engine, dict) or engine.get('edition') != 'Core' or
            engine.get('effective_policy') != 'RemoteSigned'):
        raise ValueError('Observer transport result is incomplete or invalid.')
    try:
        if tuple(int(part) for part in engine['version'].split('.')[:2]) < (7, 4):
            raise ValueError
    except (AttributeError, KeyError, ValueError):
        raise ValueError('Observer transport engine version is invalid.') from None
    verify_transport_binding(
        transport, expected_transport_kind, expected_vm_id,
        require_identity_proof=True)
    return True


def verify_recovery_inventory(root, manifest, expected_transport_kind, expected_vm_id):
    root = Path(root)
    inventory = read_json_strict(root / 'recovery-inventory.json')
    if (not isinstance(inventory, dict) or set(inventory) != {
            'schema_version', 'task_kind', 'observer_role', 'bundle_manifest_sha256',
            'observer', 'summary_file', 'files'} or
            type(inventory.get('schema_version')) is not int or
            inventory['schema_version'] != 1 or
            inventory.get('task_kind') != 'recovery' or
            inventory.get('observer_role') != 'recovery' or
            inventory.get('bundle_manifest_sha256') != sha256(root.parent / 'bundle.json')):
        raise ValueError('Recovery collection inventory binding is invalid.')
    expected_observer = (manifest['harness']['observers']['recovery']
                         if manifest['schema_version'] == 2 else {
                             'file': 'windows-vm-recovery-acceptance.ps1',
                             'sha256': sha256(root.parent / 'windows-vm-recovery-acceptance.ps1'),
                         })
    if inventory.get('observer') != expected_observer:
        raise ValueError('Recovery collection observer binding is invalid.')
    rows = inventory.get('files')
    if not isinstance(rows, list) or not rows:
        raise ValueError('Recovery collection inventory is empty or invalid.')
    if len(rows) > 256:
        raise ValueError('Recovery collection file count exceeds its bound.')
    seen = set()
    by_name = {}
    total = 0
    for row in rows:
        if (not isinstance(row, dict) or set(row) != {'file', 'bytes', 'sha256'} or
                not isinstance(row.get('file'), str) or len(row['file']) > 512 or
                type(row.get('bytes')) is not int or row['bytes'] < 0 or
                row['bytes'] > 128 * 1024 * 1024 or
                not isinstance(row.get('sha256'), str) or
                not re.fullmatch(r'[0-9a-f]{64}', row['sha256'])):
            raise ValueError('Recovery collection file row is invalid.')
        parts = row['file'].split('/')
        if (not 1 <= len(parts) <= 8 or
                any(not safe_ordinary_segment(part) for part in parts)):
            raise ValueError('Recovery collection relative path is invalid.')
        folded = row['file'].casefold()
        if folded in seen:
            raise ValueError('Recovery collection contains duplicate paths.')
        seen.add(folded)
        total += row['bytes']
        if total > 512 * 1024 * 1024:
            raise ValueError('Recovery collection aggregate size exceeds its bound.')
        path = root.joinpath(*parts)
        if (not path.is_file() or path.is_symlink() or path.stat().st_size != row['bytes'] or
                sha256(path) != row['sha256']):
            raise ValueError('Recovery collection file differs from its inventory.')
        by_name[row['file']] = row
    summary_file = inventory.get('summary_file')
    if (not isinstance(summary_file, str) or summary_file not in by_name or
            not re.fullmatch(r'[^/]+/summary\.json', summary_file)):
        raise ValueError('Recovery collection summary binding is invalid.')
    result = read_json_strict(root.joinpath(*summary_file.split('/')))
    verify_observer_result(
        manifest, result, 'recovery', expected_observer['sha256'])
    actual = set()
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in directory_names:
            if (directory_path / name).is_symlink():
                raise ValueError('Recovery collection contains a linked directory.')
        for name in file_names:
            path = directory_path / name
            if path.is_symlink():
                raise ValueError('Recovery collection contains a linked file.')
            actual.add(path.relative_to(root).as_posix())
    expected = set(by_name) | {'recovery-inventory.json', 'transport.json'}
    if actual != expected:
        raise ValueError('Recovery collection inventory is not complete.')
    verify_observer_transport(
        root, 'recovery', expected_transport_kind, expected_vm_id)
    return result


def main():
    args = parse_arguments()
    repo = Path(__file__).resolve().parent.parent
    if args.prepare_only:
        root = resolve_prepare_output_root(repo, args.output)
        manifest = (build_candidate_bundle(repo, root, args) if args.candidate_mode
                    else build_bundle(repo, root))
        application = application_record(manifest)
        print(json.dumps({
            'status': 'prepared',
            'lane': manifest.get('lane', 'source-built-native'),
            'source_sha': (manifest['product']['source_sha'] if args.candidate_mode
                           else manifest['source_sha']),
            'application_sha256': application['sha256'],
            'bundle': str(root),
        }))
        return 0
    root, defaults, pwsh = prepare_transport(repo, args)
    manifest = (build_candidate_bundle(repo, root, args) if args.candidate_mode
                else build_bundle(repo, root))
    observer_inputs = prepare_observer_inputs(root, manifest, args)
    if args.candidate_mode:
        print('Executing exact-candidate ' + args.task_kind + ' validation in the VM.', flush=True)
    else:
        print('Executing ' + str(len(manifest['test_binaries'])) + ' Windows test binaries in the VM.', flush=True)
    print('Evidence: ' + str(root), flush=True)
    transport_ok = True
    try:
        run_controller(root, args, defaults, pwsh)
    except subprocess.CalledProcessError:
        transport_ok = False
    transport_kind = 'ssh' if args.ssh_host else 'powershell_direct'
    if args.task_kind == 'core':
        result_path = root / 'result.json'
        if not result_path.is_file():
            raise RuntimeError('The VM did not return a test result. Inspect the external transport result/logs.')
        result = read_json_strict(result_path)
        verified = verify_result(root, manifest, result, transport_kind, args.expected_vm_id)
        total = sum(row.get('passed') or 0 for row in result['tests'])
        print(('PASS' if transport_ok and verified else 'FAIL') + ': ' + str(total) +
              ' tests passed; GUI=' + result.get('gui', {}).get('status', 'not-run'))
    elif args.task_kind == 'ui':
        result_path = observer_inputs['output'] / 'acceptance-result.json'
        if not result_path.is_file():
            raise RuntimeError('The VM did not return a UI observer result.')
        result = read_json_strict(result_path)
        verified = verify_observer_result(
            manifest, result, 'ui', observer_inputs['observer']['sha256'])
        verify_observer_transport(
            observer_inputs['output'], 'ui', transport_kind, args.expected_vm_id)
        print(('PASS' if transport_ok and verified else 'FAIL') +
              ': UI observer returned review_required with frozen provenance.')
    else:
        result = verify_recovery_inventory(
            observer_inputs['output'], manifest, transport_kind, args.expected_vm_id)
        verified = True
        print(('PASS' if transport_ok else 'FAIL') + ': recovery observer returned ' +
              result['status'] + ' with a verified collection inventory.')
    print('This native VM run is not the complete Windows release acceptance matrix.')
    return 0 if transport_ok and verified else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
