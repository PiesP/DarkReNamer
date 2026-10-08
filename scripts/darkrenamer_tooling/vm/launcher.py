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
import time
import uuid

from darkrenamer_tooling.contracts.platform import (
    V1_PROFILE_ID, V2_PROFILE_ID, verify_controller_cleanup,
)
from darkrenamer_tooling.contracts.tooling import stage_verified_tooling
from darkrenamer_tooling.vm import host_tools

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
    'expand-bounded-candidate-archive.ps1',
    'validate-release-candidate-metadata.ps1',
    'measure-windows-binary.ps1',
)
CORE_RESULT_MAXIMUM_BYTES = 4 * 1024 * 1024
TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES = 4 * 1024 * 1024
TEST_OUTPUT_AGGREGATE_MAXIMUM_BYTES = 64 * 1024 * 1024
REFRESH_PROFILE_OUTPUT_MAXIMUM_BYTES = 32 * 1024 * 1024
REFRESH_PROFILE_TEST = 'windows::list_view::native_tests::profile_refresh_stages'
FOCUSED_ICON_FILTER = 'windows::list_view::native_tests::icon_worker_'
FOCUSED_ICON_CASES = (
    'bootstrap_and_miss_keep_ui_responsive',
    'bounds_eviction_and_stale_results',
    'close_and_forced_destroy_retire',
    'failures_and_message_loop_retire',
)
FOCUSED_REFRESH_FILTER = 'windows::list_view::native_tests::full_refresh_'
FOCUSED_REFRESH_CASES = (
    'native_rows_and_proposals',
    'native_fallback_and_apply_lock',
    'native_dates_follow_locale_and_timezone',
    'native_viewport_focus_and_close',
)
REFRESH_PROFILE_ORDERS = ('hidden-visible', 'visible-hidden')
REFRESH_PROFILE_PREFIX_SCENARIOS = (
    'ordinary-100', 'ordinary-1000', 'ordinary-10000',
    'ordinary-10000-unchanged', 'one-row-proposal-edit',
    'whole-list-proposal-edit', 'whole-list-proposal-reset',
)
REFRESH_PROFILE_COUNTERS = (
    'rows', 'scenario_envelope_ns', 'issue_count_ns',
    'row_values_inclusive_ns', 'row_values_exclusive_ns',
    'timestamps_nested_ns', 'shell_nested_ns', 'shell_max_ns',
    'native_apply_rebuild_ns', 'selection_ns', 'column_widths_ns',
    'issue_count_input_rows_visited', 'native_rows_visited', 'rows_formatted',
    'timestamp_values', 'shell_calls', 'cache_hits', 'cache_misses',
    'native_cell_updates', 'native_row_insertions', 'native_row_deletions',
    'full_rebuilds', 'extra_staged_rows_peak',
    'logical_staged_payload_bytes_peak',
)
REFRESH_PROFILE_V2_COUNTERS = tuple(name for name in REFRESH_PROFILE_COUNTERS
    if name not in {'shell_nested_ns', 'shell_max_ns', 'shell_calls', 'cache_hits', 'cache_misses'}) + (
    'ui_shell_nested_ns', 'ui_shell_max_ns', 'ui_shell_calls',
    'render_icon_cache_hits', 'render_icon_cache_misses',
    'icon_request_submissions', 'icon_results_drained',
)
REFRESH_PROFILE_V3_COUNTERS = REFRESH_PROFILE_V2_COUNTERS + (
    'normal_staged_rows_peak', 'normal_logical_staged_payload_bytes_peak',
    'fallback_staged_rows_peak', 'fallback_logical_staged_payload_bytes_peak',
    'rendered_vec_growth_events', 'rendered_vec_capacity_bytes_peak',
    'repeated_nonzero_filetime_inputs',
)
REFRESH_PROFILE_V1_KIND = 'refresh-stages-test-build'
REFRESH_PROFILE_V2_KIND = 'refresh-stages-icon-async-test-build'
REFRESH_PROFILE_V3_KIND = 'refresh-stages-icon-async-streaming-test-build'
CONTROLLER_SUITE_TIMEOUT_SECONDS = 2400
CONTROLLER_CLEANUP_ALLOWANCE_SECONDS = 600


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_json_strict(path, maximum_bytes=None):
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('JSON contains a duplicate field: ' + key)
            value[key] = item
        return value
    path = Path(path)
    with path.open('rb') as stream:
        size = os.fstat(stream.fileno()).st_size
        if maximum_bytes is not None and (size < 1 or size > maximum_bytes):
            raise ValueError('JSON input exceeds its size bound.')
        data = stream.read() if maximum_bytes is None else stream.read(maximum_bytes + 1)
    if maximum_bytes is not None and len(data) != size:
        raise ValueError('JSON input changed or exceeded its size bound while reading.')
    return json.loads(data.decode('utf-8-sig'), object_pairs_hook=unique_object)


def copy_frozen_file(source, destination, expected_sha256, label):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    if sha256(destination) != expected_sha256:
        raise RuntimeError(label + ' copy differs from its frozen digest.')


def verify_frozen_files(sources, frozen, label):
    if any(sha256(source) != frozen[name] for name, source in sources.items()):
        raise RuntimeError(label + ' changed during bundle creation.')


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


def is_supported_powershell_version(version):
    return (isinstance(version, str) and
            re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+){0,2}', version) is not None and
            tuple(int(part) for part in version.split('.')[:2]) >= (7, 4))


def require_pwsh74():
    return host_tools.require_pwsh74()


def winpath(path):
    return subprocess.check_output(
        [host_tools.resolve_tool('wslpath'), '-w', str(path)],
        env=host_tools.child_environment(), text=True).strip()


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
    parser.add_argument('--acceptance-profile-id', choices=(V1_PROFILE_ID, V2_PROFILE_ID),
                        default=V2_PROFILE_ID,
                        help='Bind the selected VM cleanup contract (default: v2 owned resources).')
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
    parser.add_argument('--profile-refresh-stages', action='store_true',
                        help='Run the fixed two-pass optimized ListView refresh diagnostic.')
    parser.add_argument('--focused-icon-tests', action='store_true',
                        help='Run only the fixed native icon-worker functional tests.')
    parser.add_argument('--focused-refresh-tests', action='store_true',
                        help='Run only the four fixed native refresh functional tests.')
    parser.add_argument('--native-test-profile', choices=('debug', 'release'),
                        help='Build the fixed focused native tests in this profile.')
    parser.add_argument('--focused-icon-case', choices=FOCUSED_ICON_CASES,
                        help='Select one fixed native icon worker case for a diagnostic run.')
    parser.add_argument('--focused-refresh-case', choices=FOCUSED_REFRESH_CASES,
                        help='Select one fixed native refresh case for a diagnostic run.')
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
    if args.native_test_profile and not (args.focused_icon_tests or args.focused_refresh_tests):
        parser.error('--native-test-profile requires one focused native test selector.')
    if args.focused_icon_case and not args.focused_icon_tests:
        parser.error('--focused-icon-case requires --focused-icon-tests.')
    if args.focused_refresh_case and not args.focused_refresh_tests:
        parser.error('--focused-refresh-case requires --focused-refresh-tests.')
    if args.focused_icon_tests and args.focused_refresh_tests:
        parser.error('Only one fixed focused native test selector may be used.')
    if args.focused_icon_tests or args.focused_refresh_tests:
        label = 'Focused icon tests' if args.focused_icon_tests else 'Focused refresh tests'
        if (args.profile_refresh_stages or not args.native_test_profile or
                args.candidate_mode or args.task_kind != 'core' or
                args.acceptance_profile_id != V2_PROFILE_ID or
                supplied('--test-timeout-seconds') or args.prepare_only):
            parser.error(label + ' require one explicit native profile and source-built v2 core mode.')
        if (args.desktop_mode != 'rdp' or
                (supplied('--desktop-scale') and args.desktop_scale != 100) or
                (supplied('--desktop-width') and args.desktop_width != 1366) or
                (supplied('--desktop-height') and args.desktop_height != 768)):
            parser.error(label + ' require the prepared 1366x768 96-DPI RDP desktop.')
        args.test_timeout_seconds = 600
        args.desktop_scale = 100
        args.desktop_width = 1366
        args.desktop_height = 768
    if args.profile_refresh_stages:
        if (args.candidate_mode or args.task_kind != 'core' or
                args.acceptance_profile_id != V2_PROFILE_ID or supplied('--test-timeout-seconds')):
            parser.error('The refresh diagnostic requires source-built core mode and its fixed timeout.')
        if (args.desktop_mode != 'rdp' or
                (supplied('--desktop-scale') and args.desktop_scale != 100) or
                (supplied('--desktop-width') and args.desktop_width != 1366) or
                (supplied('--desktop-height') and args.desktop_height != 768)):
            parser.error('The refresh diagnostic requires the prepared 1366x768 96-DPI RDP desktop.')
        args.test_timeout_seconds = 600
        args.desktop_scale = 100
        args.desktop_width = 1366
        args.desktop_height = 768
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
    if args.profile_refresh_stages and (ui_options or recovery_options or args.prepare_only):
        parser.error('The refresh diagnostic does not accept observer or prepare-only options.')
    if (args.focused_icon_tests or args.focused_refresh_tests) and (ui_options or recovery_options):
        parser.error('Focused native tests do not accept observer options.')
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
        host_temp = subprocess.check_output(
            [host_tools.resolve_tool('wslpath'), '-u', defaults['temp']],
            env=host_tools.child_environment(), text=True).strip()
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
    if getattr(args, 'profile_refresh_stages', False):
        arguments += ['-RefreshProfileOrder', args.refresh_profile_order]
    if getattr(args, 'focused_icon_tests', False):
        arguments += ['-FocusedIconTests']
        if args.focused_icon_case:
            arguments += ['-FocusedIconCase', args.focused_icon_case]
    if getattr(args, 'focused_refresh_tests', False):
        arguments += ['-FocusedRefreshTests']
        if args.focused_refresh_case:
            arguments += ['-FocusedRefreshCase', args.focused_refresh_case]
    if getattr(args, 'acceptance_profile_id', V1_PROFILE_ID) == V2_PROFILE_ID:
        digest = getattr(args, 'acceptance_profile_sha256', None)
        if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('V2 controller invocation lacks the frozen profile digest.')
        arguments += ['-AcceptanceProfileId', V2_PROFILE_ID,
                      '-AcceptanceProfileSha256', digest]
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
    expected_bundle_manifest_sha256 = getattr(
        args, 'expected_bundle_manifest_sha256', None) or sha256(root / 'bundle.json')
    common = [
        '-TestTimeoutSeconds', str(args.test_timeout_seconds),
        '-ExpectedBundleManifestSha256', expected_bundle_manifest_sha256,
        *controller_task_arguments(root, args),
    ]
    if (getattr(args, 'profile_refresh_stages', False) or
            getattr(args, 'focused_icon_tests', False) or
            getattr(args, 'focused_refresh_tests', False)):
        common += ['-SuiteTimeoutSeconds', '600']
    if desktop_sid:
        common += ['-ExpectedDesktopSid', desktop_sid]
    if args.expected_vm_id and (args.candidate_mode or args.task_kind != 'core'):
        common += ['-ExpectedGuestVmId', args.expected_vm_id]
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
        + (' -SuiteTimeoutSeconds 600' if (getattr(args, 'profile_refresh_stages', False) or
                                           getattr(args, 'focused_icon_tests', False) or
                                           getattr(args, 'focused_refresh_tests', False)) else '')
        + ''.join(' ' + (value if value.startswith('-') else psquote(value))
                  for value in task_arguments)
        + (' -ExpectedDesktopSid ' + psquote(desktop_sid) if desktop_sid else '')
        + (' -ExpectedGuestVmId ' + psquote(args.expected_vm_id)
           if args.expected_vm_id and (args.candidate_mode or args.task_kind != 'core') else '')
        + ' -ExpectedBundleManifestSha256 ' + psquote(expected_bundle_manifest_sha256)
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
    try:
        write_desktop_lease_document(evidence_root, lease_document)
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
    output = root if args.task_kind == 'core' else root / 'observer-output'
    receipt_path = output / 'owned-cleanup-strict-failure-preservation.json'
    command = None
    process = None
    preserved = None
    desktop = None
    handshake = None

    def reap(timeout):
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
            raise RuntimeError('The exact VM controller exceeded its bounded cleanup wait.') from error

    try:
        with managed_desktop(args, root) as desktop:
            command = controller_invocation(root, args, defaults, pwsh,
                                            desktop['expectedGuestSid'] if desktop else None)
            cwd = root if args.ssh_host else Path('/mnt/c')
            environment = (host_tools.child_environment() if args.ssh_host
                           else os.environ.copy())
            environment.pop('DR_VM_OWNED_CLEANUP_HANDSHAKE', None)
            if desktop:
                handshake = {
                    'nonce': uuid.uuid4().hex,
                    'lease_id': desktop['leaseId'],
                    'sid': desktop['expectedGuestSid'],
                }
                environment['DR_VM_OWNED_CLEANUP_HANDSHAKE'] = json.dumps(handshake, separators=(',', ':'))
            process = subprocess.Popen(command, cwd=cwd, text=True, env=environment)
            # The controller's default whole-suite budget is 2400 seconds; the
            # allowance covers natural OS-process exit and evidence collection.
            suite_timeout = (600 if (getattr(args, 'profile_refresh_stages', False) or
                                    getattr(args, 'focused_icon_tests', False) or
                                    getattr(args, 'focused_refresh_tests', False))
                             else CONTROLLER_SUITE_TIMEOUT_SECONDS)
            deadline = (time.monotonic() + suite_timeout +
                        CONTROLLER_CLEANUP_ALLOWANCE_SECONDS)
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError('The exact VM controller exceeded its bounded execution wait.')
                if receipt_path.is_file():
                    try:
                        preserved = read_json_strict(receipt_path, maximum_bytes=1024 * 1024)
                    except (OSError, ValueError, json.JSONDecodeError):
                        time.sleep(0.25)
                        continue
                    if (handshake is None or type(preserved) is not dict or
                            preserved.get('nonce') != handshake['nonce'] or
                            preserved.get('desktop_lease_id') != handshake['lease_id']):
                        raise ValueError('Owned cleanup receipt differs from the issued handshake.')
                    break
                time.sleep(0.25)
        if preserved is not None:
            if desktop is None or args.desktop_mode != 'rdp':
                raise ValueError('Owned cleanup requires a closed managed desktop lease.')
            original_path = output / 'original-transport.json'
            original = read_json_strict(original_path, maximum_bytes=4 * 1024 * 1024)
            lease_path = root / 'desktop-lease.json'
            lease = read_json_strict(lease_path, maximum_bytes=64 * 1024)
            v2 = getattr(args, 'acceptance_profile_id', V1_PROFILE_ID) == V2_PROFILE_ID
            if (type(preserved) is not dict or type(preserved.get('schema_version')) is not int or
                    preserved['schema_version'] != (2 if v2 else 1) or
                    (v2 and (preserved.get('profile_id') != V2_PROFILE_ID or
                             preserved.get('profile_sha256') != args.acceptance_profile_sha256 or
                             (original.get('raw_cleanup') or {}).get('profile_id') != V2_PROFILE_ID or
                             (original.get('raw_cleanup') or {}).get('profile_sha256') != args.acceptance_profile_sha256)) or
                    preserved.get('kind') != 'owned_cleanup_strict_failure_preservation' or
                    not isinstance(preserved.get('nonce'), str) or
                    re.fullmatch(r'[0-9a-f]{32}', preserved['nonce']) is None or
                    preserved.get('desktop_lease_id') != desktop['leaseId'] or
                    preserved.get('original_transport', {}).get('file') != 'original-transport.json' or
                    preserved['original_transport'].get('sha256') != sha256(original_path) or
                    original.get('guest_cleanup') is not False or
                    not isinstance(original.get('raw_cleanup'), dict) or
                    original['raw_cleanup'].get('unexpected_runner_tasks_after_delete') is not None or
                    original['raw_cleanup'].get('unexpected_runner_processes_after_delete') is not None or
                    lease.get('mode') != 'managed-rdp' or lease.get('lease_id') != desktop['leaseId'] or
                    lease.get('stop_status') != 'stopped' or
                    lease.get('cleanup_observed') is not True):
                raise ValueError('Frozen strict failure or desktop closure is incomplete.')
            signal = {
                'schema_version': 2 if v2 else 1,
                'nonce': preserved['nonce'],
                'preservation_sha256': sha256(receipt_path),
                'desktop_lease_sha256': sha256(lease_path),
            }
            if v2:
                signal.update(profile_id=V2_PROFILE_ID,
                              profile_sha256=args.acceptance_profile_sha256)
            signal_path = output / 'owned-cleanup-desktop-closed.json'
            temporary = signal_path.with_name(signal_path.name + '.new-' + uuid.uuid4().hex)
            with temporary.open('xb') as stream:
                stream.write((json.dumps(signal, sort_keys=True) + '\n').encode('utf-8'))
                stream.flush()
                os.fsync(stream.fileno())
            os.link(temporary, signal_path)
            temporary.unlink()
        code = reap(300)
        if code:
            raise subprocess.CalledProcessError(code, command)
        if (desktop and args.task_kind == 'core' and
                not getattr(args, 'profile_refresh_stages', False) and
                not getattr(args, 'focused_icon_tests', False) and
                not getattr(args, 'focused_refresh_tests', False)):
            result = read_json_strict(
                root / 'result.json', maximum_bytes=CORE_RESULT_MAXIMUM_BYTES)
            if result.get('gui', {}).get('window_dpi') != desktop['expectedDpi']:
                raise ValueError('Production window DPI differs from the requested RDP scale.')
    except BaseException:
        if process is not None and process.poll() is None:
            try:
                reap(190)
            except Exception:
                pass
        raise


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


def build_output_file(target_root, path, label):
    target_root = Path(target_root).resolve(strict=True)
    resolved = Path(path).resolve(strict=True)
    try:
        relative = resolved.relative_to(target_root)
    except ValueError as error:
        raise RuntimeError(label + ' is outside the fresh Cargo target directory.') from error
    if not relative.parts or not resolved.is_file():
        raise RuntimeError(label + ' is not a regular file in the fresh Cargo target directory.')
    return resolved


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
            'set_foreground_window', 'final', 'capture_complete', 'capture_change'}:
        raise ValueError('VM candidate flow foreground observation shape is invalid.')
    if observation['label'] != expected_label:
        raise ValueError('VM candidate flow foreground label is invalid.')
    target_hwnd = observation['target_hwnd']
    if type(target_hwnd) is not int or target_hwnd <= 0:
        raise ValueError('VM candidate flow foreground target is invalid.')
    for name in ('initial', 'final', 'capture_complete'):
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
    if observation['capture_complete'] != final:
        raise ValueError('VM candidate flow foreground changed before capture completed.')
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


def verify_result(root, manifest, result, expected_transport_kind=None, expected_vm_id=None,
                  *, profile_id=V1_PROFILE_ID, profile_sha256=None):
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
    output_bytes = 0
    for row in rows:
        if row.get('job_cleanup') is not True:
            passed = False
        if row.get('sha256') != expected[row['file']]['sha256']:
            raise ValueError('VM test executable digest differs from the bundle.')
        checked_artifact(root, expected[row['file']])
        for channel in ('stdout', 'stderr'):
            record = row.get(channel)
            if (not isinstance(record, dict) or
                    type(record.get('bytes')) is not int or record['bytes'] < 0 or
                    record['bytes'] > TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES or
                    output_bytes > TEST_OUTPUT_AGGREGATE_MAXIMUM_BYTES - record['bytes']):
                raise ValueError('VM test output exceeds its size bound.')
            artifact = root / leaf(record['file'])
            if artifact.is_symlink() or not artifact.is_file():
                raise ValueError('VM test output was not collected as an ordinary file.')
            if artifact.stat().st_size != record['bytes']:
                raise ValueError('VM test output differs from its recorded byte count.')
            checked_artifact(root, record)
            output_bytes += record['bytes']
        output = (root / row['stdout']['file']).read_bytes().decode(
            'utf-8-sig', errors='replace')
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
    if gui.get('job_cleanup') is not True:
        passed = False
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
    if transport.get('guest_cleanup') is not True:
        passed = False
    else:
        verify_controller_cleanup(transport.get('raw_cleanup'), profile_id=profile_id,
                                  profile_sha256=profile_sha256)
        if profile_id == V2_PROFILE_ID:
            _verify_v2_result_owned_binding(result, transport)
    if not candidate and total == 0:
        passed = False
    if candidate:
        engine = transport.get('runner_engine')
        if (not isinstance(engine, dict) or set(engine) != {
                'executable', 'version', 'edition', 'effective_policy'} or
                not isinstance(engine['executable'], str) or
                not engine['executable'].lower().endswith('\\pwsh.exe') or
                not is_supported_powershell_version(engine['version']) or
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
    if (not isinstance(engine, dict) or
            not is_supported_powershell_version(engine.get('version')) or engine.get('edition') != 'Core' or
            engine.get('effective_policy') != 'RemoteSigned'):
        raise RuntimeError('Candidate validation requires Windows PowerShell 7.4+ Core under its existing RemoteSigned policy.')
    return WINDOWS_PWSH


def run_candidate_validators(validator_root, source_root, handoff_root, run_metadata,
                             artifact_metadata, args):
    executable = require_windows_pwsh74()
    handoff_validator = validator_root / 'validate-release-handoff.ps1'
    metadata_validator = validator_root / 'validate-release-candidate-metadata.ps1'
    # The caller already verified a clean source and froze these helper bytes.
    # Trust only that cross-OS source path for this Git child; the engine's
    # RemoteSigned probe stays intact while frozen UNC scripts run with Bypass.
    source_winpath = winpath(source_root)
    handoff_env = os.environ.copy()
    git_config_names = ('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')
    handoff_env.update({
        'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'safe.directory',
        'GIT_CONFIG_VALUE_0': source_winpath,
    })
    inherited_wslenv = [entry for entry in handoff_env.get('WSLENV', '').split(':')
                        if entry and entry.split('/', 1)[0] not in git_config_names]
    handoff_env['WSLENV'] = ':'.join((*inherited_wslenv, *git_config_names))
    subprocess.run([
        str(executable), '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File',
        winpath(handoff_validator), '-SourceRoot', source_winpath,
        '-HandoffRoot', winpath(handoff_root),
    ], text=True, check=True, timeout=300, env=handoff_env)
    artifact_name = ('DarkReNamer-dry-run-' + args.candidate_workflow_run + '-'
                     + args.candidate_run_attempt + '-windows')
    subprocess.run([
        str(executable), '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File',
        winpath(metadata_validator), '-RunMetadataPath', winpath(run_metadata),
        '-ArtifactMetadataPath', winpath(artifact_metadata),
        '-ExpectedRunId', args.candidate_workflow_run,
        '-ExpectedRunAttempt', args.candidate_run_attempt,
        '-ExpectedArtifactId', args.candidate_artifact_id,
        '-ExpectedSourceSha', args.candidate_source_sha,
        '-ExpectedArtifactName', artifact_name,
    ], text=True, check=True, timeout=60)
    return artifact_name


def build_candidate_bundle(repo, root, args, tooling=None):
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
    if tooling is not None:
        stage_verified_tooling(tooling, root)
    return manifest


def build_bundle(repo, root, tooling=None, *, refresh_profile=False, focused_profile=None,
                 focused_case=None, focused_kind='icon'):
    repo = Path(repo)
    root = Path(root)
    if (refresh_profile and focused_profile is not None) or focused_profile not in (None, 'debug', 'release'):
        raise ValueError('A source-built bundle accepts one fixed native selector.')
    if focused_kind not in ('icon', 'refresh'):
        raise ValueError('Unknown focused native test selector.')
    focused_cases = FOCUSED_ICON_CASES if focused_kind == 'icon' else FOCUSED_REFRESH_CASES
    focused_filter = FOCUSED_ICON_FILTER if focused_kind == 'icon' else FOCUSED_REFRESH_FILTER
    if focused_case is not None and (focused_profile is None or focused_case not in focused_cases):
        raise ValueError('Focused native selection must name one fixed case.')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True).strip():
        raise RuntimeError('Commit or preserve checkout changes before VM verification; results must bind a clean source SHA.')
    source_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    root.mkdir(parents=True)
    print('Building Windows tests for source ' + source_sha, flush=True)
    env = dict(os.environ)
    env.setdefault('RC', '/usr/bin/llvm-rc-19')
    script_names = (
        'windows-vm-guest.ps1', 'run-windows-vm-tests.ps1',
        'windows-vm-acceptance.ps1', 'windows-vm-recovery-acceptance.ps1')
    # Never reuse ignored project `target/` output for exact-source evidence.
    # tempfile creates a new private directory, and the environment is set
    # unconditionally so inherited Cargo configuration cannot redirect builds.
    with tempfile.TemporaryDirectory(prefix='.cargo-target-', dir=root) as target_directory:
        target_root = Path(target_directory).resolve(strict=True)
        env['CARGO_TARGET_DIR'] = str(target_root)
        command = ['cargo', 'xwin', 'test']
        if refresh_profile or focused_profile:
            if refresh_profile or focused_profile == 'release':
                command.append('--release')
            command += ['-p', 'darknamer-app', '--lib']
        else:
            command += ['--workspace', '--all-targets']
        command += ['--all-features', '--locked', '--target', TARGET,
                    '--no-run', '--message-format=json']
        messages_path = root / 'cargo-build.jsonl'
        with messages_path.open('w') as stream:
            subprocess.run(command, cwd=repo, env=env, stdout=stream, check=True)
        with messages_path.open() as stream:
            artifacts = test_artifacts(stream)
        if (refresh_profile or focused_profile) and (len(artifacts) != 1 or artifacts[0]['name'] != 'darknamer_app'):
            raise RuntimeError('Selected icon tests must produce one app library test binary.')
        for row in artifacts:
            row['path'] = str(build_output_file(
                target_root, row['path'], 'Windows test executable ' + row['file']))

        subprocess.run(['cargo', 'xwin', 'build', '--release', '--locked', '--target', TARGET, '--package', 'darknamer-app', '--bin', 'DarkReNamer'], cwd=repo, env=env, check=True)
        metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--no-deps', '--format-version=1', '--locked'], cwd=repo, env=env, text=True))
        metadata_target = Path(metadata['target_directory']).resolve(strict=True)
        if metadata_target != target_root:
            raise RuntimeError('Cargo metadata target directory differs from the fresh private build directory.')
        application = build_output_file(
            target_root, metadata_target / TARGET / 'release' / 'DarkReNamer.exe',
            'Windows application')
        if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip() != source_sha or subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True).strip():
            raise RuntimeError('Checkout changed during the build; refusing to label the bundle with a stale source SHA.')

        sources = {
            'cargo_lock': repo / 'Cargo.lock',
            'application': application,
            **{'test:' + row['file']: row['path'] for row in artifacts},
            **{'script:' + name: repo / 'scripts' / name for name in script_names},
        }
        frozen = {name: sha256(path) for name, path in sources.items()}
        bundle_files = {}
        for row in artifacts:
            key = 'test:' + row['file']
            destination = root / row['file']
            copy_frozen_file(sources[key], destination, frozen[key], 'Windows test executable')
            bundle_files[key] = destination
            row.pop('path')
            row['sha256'] = frozen[key]
        application_path = root / 'DarkReNamer.exe'
        copy_frozen_file(application, application_path, frozen['application'], 'Windows application')
        bundle_files['application'] = application_path
        for name in script_names:
            key = 'script:' + name
            destination = root / name
            copy_frozen_file(sources[key], destination, frozen[key], 'Windows VM harness ' + name)
            bundle_files[key] = destination

        verify_frozen_files(sources, frozen, 'Source-built bundle inputs')
        verify_frozen_files(bundle_files, frozen, 'Source-built bundle copies')

    verify_frozen_files(bundle_files, frozen, 'Source-built bundle copies')
    final_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    final_status = subprocess.check_output(
        ['git', 'status', '--porcelain'], cwd=repo, text=True).strip()
    if final_sha != source_sha or final_status:
        raise RuntimeError('Checkout changed during source-built bundle creation; refusing a stale source SHA.')
    manifest = {
        'schema_version': 1, 'source_sha': source_sha, 'source_state': 'clean', 'target': TARGET,
        'cargo_lock_sha256': frozen['cargo_lock'], 'test_binaries': artifacts,
        'application': {'file': 'DarkReNamer.exe', 'sha256': frozen['application']},
        'runner': {
            'file': 'windows-vm-guest.ps1',
            'sha256': frozen['script:windows-vm-guest.ps1'],
        },
    }
    if refresh_profile:
        manifest['diagnostic'] = {
            'kind': 'profile-refresh-stages', 'test_profile': 'release',
            'test_name': REFRESH_PROFILE_TEST,
            'orders': list(REFRESH_PROFILE_ORDERS),
        }
    elif focused_profile:
        manifest['diagnostic'] = {
            'kind': 'focused-' + focused_kind + '-tests', 'test_profile': focused_profile,
            'test_filter': focused_filter,
        }
        if focused_case:
            manifest['diagnostic']['test_name'] = focused_filter + focused_case
        else:
            manifest['diagnostic']['test_names'] = [
                focused_filter + case for case in focused_cases]
    (root / 'bundle.json').write_text(json.dumps(manifest, indent=2))
    if tooling is not None:
        stage_verified_tooling(tooling, root)
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


def _verify_v2_result_owned_binding(result, transport):
    raw = transport.get('raw_cleanup') if isinstance(transport, dict) else None
    owned = raw.get('owned_resource_evidence') if isinstance(raw, dict) else None
    task = owned.get('task_execution') if isinstance(owned, dict) else None
    jobs = result.get('process_job_cleanup') if isinstance(result, dict) else None
    if (not isinstance(jobs, list) or not jobs or
            not isinstance(owned, dict) or jobs != owned.get('process_job_cleanup') or
            not isinstance(task, dict) or
            result.get('observer_lifecycle') != task.get('observer_lifecycle')):
        raise ValueError('V2 cleanup does not bind the result Job and observer lifetimes.')


def verify_refresh_profile_records(output, order):
    records = []
    test_prefix = 'test ' + REFRESH_PROFILE_TEST + ' ... '
    formats = {
        REFRESH_PROFILE_V1_KIND: (None, REFRESH_PROFILE_COUNTERS),
        REFRESH_PROFILE_V2_KIND: (2, REFRESH_PROFILE_V2_COUNTERS),
        REFRESH_PROFILE_V3_KIND: (3, REFRESH_PROFILE_V3_COUNTERS),
    }

    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('Refresh diagnostic emitted a duplicate field: ' + key)
            value[key] = item
        return value

    for line in output.splitlines():
        payload = line[len(test_prefix):] if line.startswith(test_prefix) else line
        if not payload.startswith('{'):
            continue
        try:
            record = json.loads(payload, object_pairs_hook=unique_object)
        except json.JSONDecodeError as error:
            raise ValueError('Refresh diagnostic emitted malformed JSON.') from error
        if not isinstance(record, dict) or record.get('kind') not in formats:
            continue
        version, counters = formats[record['kind']]
        async_record = version is not None
        expected_fields = set(counters) | {'kind', 'scenario'}
        if async_record:
            expected_fields.update(('schema_version', 'icon_worker_attached'))
        if (set(record) != expected_fields or
                (async_record and (type(record.get('schema_version')) is not int or
                                   record['schema_version'] != version or
                                   record.get('icon_worker_attached') is not False)) or
                not isinstance(record.get('scenario'), str) or
                any(type(record.get(key)) is not int or record[key] < 0
                    for key in counters) or
                record['timestamp_values'] != 2 * record['rows_formatted'] or
                (async_record and (record['ui_shell_nested_ns'] != 0 or
                         record['ui_shell_max_ns'] != 0 or
                         record['ui_shell_calls'] != 0 or
                         record['icon_request_submissions'] != 0 or
                         record['icon_results_drained'] != 0 or
                         record['render_icon_cache_hits'] + record['render_icon_cache_misses'] !=
                         record['rows_formatted'] or
                         record['row_values_exclusive_ns'] + record['timestamps_nested_ns'] +
                         record['ui_shell_nested_ns'] != record['row_values_inclusive_ns'])) or
                (not async_record and (record['cache_hits'] + record['cache_misses'] !=
                             record['rows_formatted'] or
                             record['shell_calls'] != record['cache_misses'] or
                             record['row_values_exclusive_ns'] + record['timestamps_nested_ns'] +
                             record['shell_nested_ns'] != record['row_values_inclusive_ns'] or
                             record['shell_max_ns'] > record['shell_nested_ns']))):
            raise ValueError('Refresh diagnostic scenario counters are invalid.')
        records.append(record)
    if len({record['kind'] for record in records}) > 1:
        raise ValueError('Refresh diagnostic mixed historical and async test-build records.')
    long_paths = ('long-hidden', 'long-hidden-unchanged',
                  'long-visible', 'long-visible-unchanged')
    if order == 'visible-hidden':
        long_paths = long_paths[2:] + long_paths[:2]
    expected = REFRESH_PROFILE_PREFIX_SCENARIOS + long_paths
    if tuple(record['scenario'] for record in records) != expected:
        raise ValueError('Refresh diagnostic scenario inventory or order is invalid.')
    for record in records:
        scenario = record['scenario']
        expected_rows = 100 if scenario == 'ordinary-100' else (
            1000 if scenario == 'ordinary-1000' or scenario.startswith('long-') else 10000)
        expected_formatted = 26500 if scenario == 'ordinary-10000' else (
            0 if 'proposal-' in scenario else expected_rows)
        if record['rows'] != expected_rows or record['rows_formatted'] != expected_formatted:
            raise ValueError('Refresh diagnostic workload cardinality is invalid.')
        if record['kind'] == REFRESH_PROFILE_V3_KIND:
            has_formatted_rows = expected_formatted > 0
            expected_repeats = (52996 if scenario == 'ordinary-10000' else
                                max(0, 2 * expected_formatted - 1))
            if (record['normal_staged_rows_peak'] != int(has_formatted_rows) or
                    (record['normal_logical_staged_payload_bytes_peak'] > 0) !=
                    has_formatted_rows or
                    record['fallback_staged_rows_peak'] != 0 or
                    record['fallback_logical_staged_payload_bytes_peak'] != 0 or
                    record['rendered_vec_growth_events'] >
                    record['native_row_insertions'] or
                    (record['rendered_vec_capacity_bytes_peak'] < expected_rows
                     if has_formatted_rows else
                     record['rendered_vec_capacity_bytes_peak'] != 0) or
                    record['repeated_nonzero_filetime_inputs'] != expected_repeats):
                raise ValueError('Streaming refresh diagnostic counters are invalid.')
    return records


def verify_refresh_profile_result(root, manifest, result, order, transport_kind,
                                  expected_vm_id, profile_sha256):
    if (manifest.get('diagnostic') != {
            'kind': 'profile-refresh-stages', 'test_profile': 'release',
            'test_name': REFRESH_PROFILE_TEST,
            'orders': list(REFRESH_PROFILE_ORDERS)} or
            len(manifest.get('test_binaries', [])) != 1 or
            manifest['test_binaries'][0].get('name') != 'darknamer_app'):
        raise ValueError('The fixed optimized test bundle is invalid.')
    if (result.get('schema_version') != 1 or
            any(result.get(key) != manifest[key] for key in
                ('source_sha', 'source_state', 'target')) or
            result.get('diagnostic') != {
                'kind': 'profile-refresh-stages', 'order': order,
                'test_name': REFRESH_PROFILE_TEST, 'test_profile': 'release'} or
            result.get('gui') is not None or result.get('status') != 'passed'):
        raise ValueError('Refresh result does not match the fixed diagnostic selection.')
    rows = result.get('tests')
    if not isinstance(rows, list) or len(rows) != 1:
        raise ValueError('Refresh result must contain exactly one native test binary.')
    row = rows[0]
    binary = manifest['test_binaries'][0]
    if (row.get('file') != binary['file'] or row.get('sha256') != binary['sha256'] or
            row.get('status') != 'passed' or row.get('job_cleanup') is not True or
            row.get('exit_code') != 0 or
            [row.get(key) for key in ('passed', 'failed', 'ignored')] != [1, 0, 0]):
        raise ValueError('Refresh native test result is incomplete.')
    checked_artifact(root, binary)
    checked_artifact(root, manifest['application'])
    checked_artifact(root, manifest['runner'])
    output_bytes = 0
    for channel in ('stdout', 'stderr'):
        record = row.get(channel)
        if (not isinstance(record, dict) or type(record.get('bytes')) is not int or
                record['bytes'] < 0 or record['bytes'] > TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES or
                output_bytes > REFRESH_PROFILE_OUTPUT_MAXIMUM_BYTES - record['bytes']):
            raise ValueError('Refresh diagnostic output exceeds its bound.')
        path = checked_artifact(root, record)
        if path.stat().st_size != record['bytes']:
            raise ValueError('Refresh diagnostic output size differs from its record.')
        output_bytes += record['bytes']
    output = (root / row['stdout']['file']).read_text(encoding='utf-8-sig', errors='replace')
    summaries = re.findall(
        r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; '
        r'\d+ measured; (\d+) filtered out;', output, re.MULTILINE)
    if (len(summaries) != 1 or summaries[0][0:4] != ('ok', '1', '0', '0') or
            int(summaries[0][4]) < 1 or
            output.count('test ' + REFRESH_PROFILE_TEST + ' ... ') != 1 or
            re.search(r'(?m)^ok\r?$', output) is None):
        raise ValueError('Refresh diagnostic did not execute the exact ignored test.')
    records = verify_refresh_profile_records(output, order)
    transport = result.get('transport')
    if (not isinstance(transport, dict) or transport.get('task_kind') != 'core' or
            transport.get('status') != 'collected' or
            transport.get('guest_cleanup') is not True):
        raise ValueError('Refresh diagnostic transport did not finish with clean collection.')
    verify_controller_cleanup(transport.get('raw_cleanup'), profile_id=V2_PROFILE_ID,
                              profile_sha256=profile_sha256)
    _verify_v2_result_owned_binding(result, transport)
    verify_transport_binding(transport, transport_kind, expected_vm_id)
    return {'order': order, 'status': 'passed', 'test_binary_sha256': binary['sha256'],
            'stdout_sha256': row['stdout']['sha256'],
            'stderr_sha256': row['stderr']['sha256'],
            'filtered_out': int(summaries[0][4]), 'output_bytes': output_bytes,
            'scenarios': len(records)}


def verify_focused_icon_result(root, manifest, result, transport_kind,
                                  expected_vm_id, profile_sha256):
    return verify_focused_native_result(root, manifest, result, transport_kind,
                                        expected_vm_id, profile_sha256, kind='icon')


def verify_focused_refresh_result(root, manifest, result, transport_kind,
                                  expected_vm_id, profile_sha256):
    return verify_focused_native_result(root, manifest, result, transport_kind,
                                        expected_vm_id, profile_sha256, kind='refresh')


def verify_focused_native_result(root, manifest, result, transport_kind,
                                 expected_vm_id, profile_sha256, *, kind):
    test_filter = FOCUSED_ICON_FILTER if kind == 'icon' else FOCUSED_REFRESH_FILTER
    cases = FOCUSED_ICON_CASES if kind == 'icon' else FOCUSED_REFRESH_CASES
    output_limit = (REFRESH_PROFILE_OUTPUT_MAXIMUM_BYTES if kind == 'refresh'
                    else TEST_OUTPUT_AGGREGATE_MAXIMUM_BYTES)
    diagnostic = manifest.get('diagnostic')
    focused_name = diagnostic.get('test_name') if isinstance(diagnostic, dict) else None
    expected_names = ([focused_name] if focused_name is not None else
                      [test_filter + case for case in cases])
    if (not isinstance(diagnostic, dict) or diagnostic.get('kind') != 'focused-' + kind + '-tests' or
            diagnostic.get('test_profile') not in ('debug', 'release') or
            diagnostic.get('test_filter') != test_filter or
            set(diagnostic) != ({'kind', 'test_profile', 'test_filter'} |
                                ({'test_name'} if focused_name is not None else {'test_names'})) or
            (focused_name is not None and focused_name not in
             {test_filter + case for case in cases}) or
            (focused_name is None and diagnostic.get('test_names') != expected_names) or
            len(manifest.get('test_binaries', [])) != 1 or
            manifest['test_binaries'][0].get('name') != 'darknamer_app'):
        raise ValueError('The fixed focused native test bundle is invalid.')
    if (type(result.get('schema_version')) is not int or result['schema_version'] != 1 or
            any(result.get(key) != manifest[key] for key in
                ('source_sha', 'source_state', 'target')) or
            result.get('diagnostic') != diagnostic or result.get('gui') is not None or
            result.get('status') not in ('passed', 'failed')):
        raise ValueError('Focused native result selection is invalid.')
    rows = result.get('tests')
    if (not isinstance(rows, list) or not 1 <= len(rows) <= len(expected_names) or
            any(not isinstance(row, dict) for row in rows)):
        raise ValueError('Focused native result must contain a fixed case prefix.')
    if (focused_name is not None and len(rows) != 1):
        raise ValueError('A selected focused native case must have one execution.')
    binary = manifest['test_binaries'][0]
    for artifact in (binary, manifest['application'], manifest['runner']):
        checked_artifact(root, artifact)
    output_bytes = 0
    passed_total = failed_total = filtered_total = 0
    failed_case = False
    for index, row in enumerate(rows, 1):
        expected_name = expected_names[index - 1]
        if (row.get('file') != binary['file'] or row.get('sha256') != binary['sha256'] or
                row.get('test_name') != expected_name or row.get('job_cleanup') is not True or
                type(row.get('exit_code')) is not int or
                any(type(row.get(key)) is not int for key in ('passed', 'failed', 'ignored'))):
            raise ValueError('Focused native test artifact, counts, or job cleanup is invalid.')
        for channel in ('stdout', 'stderr'):
            record = row.get(channel)
            if (not isinstance(record, dict) or type(record.get('bytes')) is not int or
                    record['bytes'] < 0 or record['bytes'] > TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES or
                    output_bytes > output_limit - record['bytes']):
                raise ValueError('Focused native output exceeds its bound.')
            path = checked_artifact(root, record)
            if path.stat().st_size != record['bytes']:
                raise ValueError('Focused native output size differs from its record.')
            output_bytes += record['bytes']
        output = (root / row['stdout']['file']).read_text(encoding='utf-8-sig', errors='replace')
        summaries = re.findall(
            r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; '
            r'\d+ measured; (\d+) filtered out;', output, re.MULTILINE)
        if len(summaries) != 1:
            raise ValueError('Focused native output has no unique libtest summary.')
        outcome, passed, failed, ignored, filtered = summaries[0]
        counts = (int(passed), int(failed), int(ignored))
        names = re.findall(r'(?m)^test (\S+) \.\.\. ', output)
        if (counts[0] + counts[1] != 1 or counts[2] != 0 or int(filtered) < 1 or
                (outcome == 'ok') != (counts[1] == 0) or names != [expected_name] or
                [row.get(key) for key in ('passed', 'failed', 'ignored')] != list(counts)):
            raise ValueError('Focused native selection or test counts are invalid.')
        case_passed = (outcome == 'ok' and row.get('status') == 'passed' and
                       row.get('exit_code') == 0 and row.get('failure_reason') is None)
        if not case_passed and (index != len(rows) or outcome != 'FAILED' or
                                row.get('status') != 'failed' or
                                row.get('failure_reason') != 'test_failed' or
                                row['exit_code'] == 0):
            raise ValueError('Focused native execution status differs from its libtest result.')
        if failed_case:
            raise ValueError('Focused native case executed after a failed case.')
        failed_case = not case_passed
        passed_total += counts[0]
        failed_total += counts[1]
        filtered_total += int(filtered)
    succeeded = not failed_case and len(rows) == len(expected_names) and result['status'] == 'passed'
    if not succeeded and (not failed_case or result['status'] != 'failed'):
        raise ValueError('Focused native execution did not finish its fixed case inventory.')
    transport = result.get('transport')
    if (not isinstance(transport, dict) or transport.get('task_kind') != 'core' or
            transport.get('status') != 'collected' or transport.get('guest_cleanup') is not True):
        raise ValueError('Focused native transport did not finish with clean collection.')
    verify_controller_cleanup(transport.get('raw_cleanup'), profile_id=V2_PROFILE_ID,
                              profile_sha256=profile_sha256)
    _verify_v2_result_owned_binding(result, transport)
    verify_transport_binding(transport, transport_kind, expected_vm_id)
    return {'status': 'passed' if succeeded else 'failed', 'passed': passed_total,
            'failed': failed_total, 'filtered_out': filtered_total,
            'test_profile': diagnostic['test_profile'],
            'test_binary_sha256': binary['sha256']}


def run_refresh_profile(repo, args, tooling):
    root, defaults, pwsh = prepare_transport(repo, args)
    root = resolve_prepare_output_root(repo, root)
    root.mkdir(mode=0o700)
    prepared = root / 'bundle'
    manifest = build_bundle(repo, prepared, tooling, refresh_profile=True)
    frozen = {path.relative_to(prepared): sha256(path) for path in prepared.rglob('*')
              if path.is_file() and not path.is_symlink()}
    if any(path.is_symlink() for path in prepared.rglob('*')):
        raise ValueError('The prepared diagnostic bundle contains a symbolic link.')
    profile_sha256 = args.acceptance_profile_sha256
    plan = {'schema_version': 1, 'diagnostic': 'profile-refresh-stages',
            'source_sha': manifest['source_sha'],
            'test_binary': manifest['test_binaries'][0],
            'application': manifest['application'],
            'bundle_manifest_sha256': frozen[Path('bundle.json')],
            'profile_id': V2_PROFILE_ID, 'profile_sha256': profile_sha256,
            'test_timeout_seconds': 600, 'suite_timeout_seconds': 600,
            'output_limit_bytes': REFRESH_PROFILE_OUTPUT_MAXIMUM_BYTES,
            'orders': list(REFRESH_PROFILE_ORDERS),
            'scenarios': list(REFRESH_PROFILE_PREFIX_SCENARIOS) + [
                'long-hidden', 'long-hidden-unchanged',
                'long-visible', 'long-visible-unchanged'],
            'rust_toolchain_sha256': sha256(repo / 'rust-toolchain.toml'),
            'desktop': {'mode': args.desktop_mode, 'scale': args.desktop_scale,
                        'width': args.desktop_width, 'height': args.desktop_height},
            'initial_preferences': 'fresh-isolated-localappdata'}
    (root / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    attempts = []
    for index, order in enumerate(REFRESH_PROFILE_ORDERS, 1):
        if clean_source_identity(repo, 'Refresh diagnostic checkout')[1] != manifest['source_sha']:
            raise RuntimeError('Checkout changed after the optimized diagnostic build.')
        if any(sha256(prepared / name) != digest for name, digest in frozen.items()):
            raise RuntimeError('The prepared optimized diagnostic bundle changed.')
        attempt = root / ('pass-%02d-%s' % (index, order))
        shutil.copytree(prepared, attempt)
        if any(sha256(attempt / name) != digest for name, digest in frozen.items()):
            raise RuntimeError('The copied optimized diagnostic bundle changed.')
        args.refresh_profile_order = order
        args.expected_bundle_manifest_sha256 = frozen[Path('bundle.json')]
        record = {'order': order, 'path': str(attempt), 'status': 'failed'}
        attempts.append(record)
        try:
            run_controller(attempt, args, defaults, pwsh)
            if clean_source_identity(repo, 'Refresh diagnostic checkout')[1] != manifest['source_sha']:
                raise RuntimeError('Checkout changed during the optimized diagnostic pass.')
            result = read_json_strict(attempt / 'result.json', CORE_RESULT_MAXIMUM_BYTES)
            record.update(verify_refresh_profile_result(
                attempt, manifest, result, order,
                'ssh' if args.ssh_host else 'powershell_direct', args.expected_vm_id,
                profile_sha256))
        except Exception as error:
            record['error_type'] = type(error).__name__
            print('FAIL: optimized refresh diagnostic ' + order + '; evidence=' +
                  str(attempt) + '; reason=' + str(error), file=sys.stderr, flush=True)
            return 1
        finally:
            (root / 'attempts.json').write_text(json.dumps(attempts, indent=2) + '\n')
        print('PASS: optimized refresh diagnostic ' + order + '; evidence=' + str(attempt),
              flush=True)
    return 0


def verify_observer_transport(root, role, expected_transport_kind, expected_vm_id,
                              *, profile_id=V1_PROFILE_ID, profile_sha256=None, result=None):
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
    verify_controller_cleanup(transport.get('raw_cleanup'), profile_id=profile_id,
                              profile_sha256=profile_sha256)
    if profile_id == V2_PROFILE_ID:
        _verify_v2_result_owned_binding(result, transport)
    if not is_supported_powershell_version(engine.get('version')):
        raise ValueError('Observer transport engine version is invalid.')
    verify_transport_binding(
        transport, expected_transport_kind, expected_vm_id,
        require_identity_proof=True)
    return True


def verify_recovery_inventory(root, manifest, expected_transport_kind, expected_vm_id,
                              *, profile_id=V1_PROFILE_ID, profile_sha256=None):
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
        root, 'recovery', expected_transport_kind, expected_vm_id,
        profile_id=profile_id, profile_sha256=profile_sha256, result=result)
    return result


def main(repo, argv=None, tooling=None):
    repo = Path(repo)
    args = parse_arguments(argv)
    if args.acceptance_profile_id == V2_PROFILE_ID:
        profile_path = repo / 'config' / 'vm-automated-v2.json'
        profile = read_json_strict(profile_path, maximum_bytes=1024 * 1024)
        if (not isinstance(profile, dict) or
                profile.get('schema') != 'darkrenamer-vm-automated-profile-v2' or
                profile.get('profile_id') != V2_PROFILE_ID or
                type(profile.get('revision')) is not int or profile['revision'] != 2):
            raise ValueError('V2 launcher profile definition is unavailable.')
        args.acceptance_profile_sha256 = sha256(profile_path)
    if args.prepare_only:
        root = resolve_prepare_output_root(repo, args.output)
        manifest = (build_candidate_bundle(repo, root, args, tooling) if args.candidate_mode
                    else build_bundle(repo, root, tooling))
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
    if args.profile_refresh_stages:
        return run_refresh_profile(repo, args, tooling)
    if args.focused_icon_tests or args.focused_refresh_tests:
        focused_kind = 'icon' if args.focused_icon_tests else 'refresh'
        focused_case = args.focused_icon_case if args.focused_icon_tests else args.focused_refresh_case
        root, defaults, pwsh = prepare_transport(repo, args)
        manifest = build_bundle(repo, root, tooling,
                                focused_profile=args.native_test_profile,
                                focused_case=focused_case, focused_kind=focused_kind)
        args.expected_bundle_manifest_sha256 = sha256(root / 'bundle.json')
        print('Executing fixed ' + args.native_test_profile + ' ' + focused_kind + ' ' +
              (focused_case or 'suite') +
              ' in the VM; evidence=' + str(root), flush=True)
        transport_ok = True
        try:
            run_controller(root, args, defaults, pwsh)
        except subprocess.CalledProcessError:
            transport_ok = False
        result_path = root / 'result.json'
        if not result_path.is_file():
            raise RuntimeError('The focused VM run returned no test result; inspect its private transport evidence.')
        result = read_json_strict(result_path, maximum_bytes=CORE_RESULT_MAXIMUM_BYTES)
        observed = verify_focused_native_result(
            root, manifest, result, 'ssh' if args.ssh_host else 'powershell_direct',
            args.expected_vm_id, args.acceptance_profile_sha256, kind=focused_kind)
        print(('PASS' if transport_ok and observed['status'] == 'passed' else 'FAIL') +
              ': focused ' + observed['test_profile'] + ' native tests: ' +
              str(observed['passed']) + ' passed; ' + str(observed['failed']) + ' failed',
              flush=True)
        return 0 if transport_ok and observed['status'] == 'passed' else 1
    root, defaults, pwsh = prepare_transport(repo, args)
    manifest = (build_candidate_bundle(repo, root, args, tooling) if args.candidate_mode
                else build_bundle(repo, root, tooling))
    args.expected_bundle_manifest_sha256 = sha256(root / 'bundle.json')
    observer_inputs = prepare_observer_inputs(root, manifest, args)
    if args.candidate_mode:
        print('Executing exact-candidate ' + args.task_kind + ' validation in the VM.', flush=True)
    elif args.task_kind == 'core':
        print('Executing ' + str(len(manifest['test_binaries'])) + ' Windows test binaries in the VM.', flush=True)
    else:
        print('Executing source-built ' + args.task_kind + ' observer in the VM.', flush=True)
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
        result = read_json_strict(
            result_path, maximum_bytes=CORE_RESULT_MAXIMUM_BYTES)
        verified = verify_result(root, manifest, result, transport_kind, args.expected_vm_id,
                                 profile_id=args.acceptance_profile_id,
                                 profile_sha256=getattr(args, 'acceptance_profile_sha256', None))
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
            observer_inputs['output'], 'ui', transport_kind, args.expected_vm_id,
            profile_id=args.acceptance_profile_id,
            profile_sha256=getattr(args, 'acceptance_profile_sha256', None), result=result)
        print(('PASS' if transport_ok and verified else 'FAIL') +
              ': UI observer returned review_required with frozen provenance.')
    else:
        result = verify_recovery_inventory(
            observer_inputs['output'], manifest, transport_kind, args.expected_vm_id,
            profile_id=args.acceptance_profile_id,
            profile_sha256=getattr(args, 'acceptance_profile_sha256', None))
        verified = True
        print(('PASS' if transport_ok else 'FAIL') + ': recovery observer returned ' +
              result['status'] + ' with a verified collection inventory.')
    print('This native VM run is not the complete Windows release acceptance matrix.')
    return 0 if transport_ok and verified else 1


def cli(repo, argv=None, tooling=None):
    try:
        return main(repo, argv, tooling)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
