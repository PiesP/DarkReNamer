"""Build the current checkout's Windows tests and execute them in a Hyper-V VM."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import zlib

from darkrenamer_tooling.contracts.platform import (
    V1_PROFILE_ID, V2_PROFILE_ID, verify_controller_cleanup,
    verify_current_protected_anchor_binding,
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
    'DarkReNamer-support-windows-x64.zip',
    'DarkReNamer-windows-x64.zip',
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
VIRTUAL_EXECUTION_TEST = 'benchmark_durable_production_path'
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
            'schema_version', 'source_sha', 'workflow_run', 'workflow_attempt',
            'package_layout', 'executable'} or
            type(handoff.get('schema_version')) is not int or handoff['schema_version'] != 2 or
            handoff.get('source_sha') != args.candidate_source_sha or
            handoff.get('workflow_run') != args.candidate_workflow_run or
            handoff.get('workflow_attempt') != args.candidate_run_attempt or
            handoff.get('package_layout') != 'portable-windows-x64-v1' or
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
    parser.add_argument('--expected-vm-id', help='Require this exact Hyper-V VM GUID in the controller session.')
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
    parser.add_argument('--virtual-execution-count', type=int, choices=(100, 1000, 10000),
                        help='Run one source-bound durable VM rename series at the selected file count.')
    parser.add_argument('--virtual-execution-iteration', type=int, choices=range(6),
                        help='Use 0 for warmup or 1..5 for a recorded VM execution iteration.')
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
    if (args.virtual_execution_count is None) != (args.virtual_execution_iteration is None):
        parser.error('Virtual execution requires both count and iteration.')
    if args.virtual_execution_count is not None:
        if (args.profile_refresh_stages or args.focused_icon_tests or args.focused_refresh_tests or
                args.native_test_profile or args.candidate_mode or args.task_kind != 'core' or
                args.acceptance_profile_id != V2_PROFILE_ID or args.prepare_only or
                supplied('--test-timeout-seconds') or args.expected_vm_id is None):
            parser.error('Virtual execution requires source-built v2 core mode and exact VM identity.')
        args.test_timeout_seconds = 1200
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
    if args.virtual_execution_count is not None and (ui_options or recovery_options):
        parser.error('Virtual execution does not accept UI or recovery observer options.')
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
    if getattr(args, 'virtual_execution_count', None) is not None:
        arguments += ['-VirtualExecutionCount', str(args.virtual_execution_count),
                      '-VirtualExecutionIteration', str(args.virtual_execution_iteration)]
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
            getattr(args, 'focused_refresh_tests', False) or
            getattr(args, 'virtual_execution_count', None) is not None):
        common += ['-SuiteTimeoutSeconds', str(args.test_timeout_seconds)]
    if desktop_sid:
        common += ['-ExpectedDesktopSid', desktop_sid]
    if args.expected_vm_id:
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
        + (' -SuiteTimeoutSeconds ' + str(args.test_timeout_seconds)
           if (getattr(args, 'profile_refresh_stages', False) or
               getattr(args, 'focused_icon_tests', False) or
               getattr(args, 'focused_refresh_tests', False) or
               getattr(args, 'virtual_execution_count', None) is not None) else '')
        + ''.join(' ' + (value if value.startswith('-') else psquote(value))
                  for value in task_arguments)
        + (' -ExpectedDesktopSid ' + psquote(desktop_sid) if desktop_sid else '')
        + (' -ExpectedGuestVmId ' + psquote(args.expected_vm_id)
           if args.expected_vm_id else '')
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


def write_desktop_helper_response(root, leaf, raw):
    path = Path(root) / leaf
    encoded = raw.encode('utf-8')
    if not (0 < len(encoded) <= 64 * 1024):
        raise ValueError('Desktop helper response exceeds its evidence bound.')
    with path.open('xb') as stream:
        stream.write(encoded)
        stream.flush()
        os.fsync(stream.fileno())


@contextmanager
def managed_desktop(args, evidence_root=None, *, capture_closure=False):
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
    start_raw = windows_host_command(
        '& ' + helper + ' -Action Start' + selector + ' -ScalePercent '
        + str(args.desktop_scale) + geometry)
    lease = json.loads(start_raw)
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
        if capture_closure:
            write_desktop_helper_response(evidence_root, 'desktop-start-response.json', start_raw)
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
            stop_raw = windows_host_command(
                '& ' + helper + ' -Action Stop -LeasePath ' + psquote(lease['leasePath'])
                + ' -LeaseId ' + psquote(lease['leaseId']))
            stopped = json.loads(stop_raw)
            if capture_closure:
                write_desktop_helper_response(evidence_root, 'desktop-stop-response.json', stop_raw)
        except Exception:
            write_desktop_lease_document(evidence_root, lease_document)
            raise
        cleanup_observed = (isinstance(stopped, dict) and stopped.get('status') == 'stopped' and
                            (not capture_closure or
                             (stopped.get('leaseId') == lease['leaseId'] and
                              stopped.get('lifecycleStatus') == 'closed')))
        lease_document['stop_status'] = 'stopped' if cleanup_observed else 'failed'
        lease_document['cleanup_observed'] = cleanup_observed
        write_desktop_lease_document(evidence_root, lease_document)
        if not cleanup_observed:
            raise RuntimeError('Desktop helper did not confirm session cleanup.')


def run_managed_controller(root, args, command_for_desktop, *, output, cwd,
                           suite_timeout=CONTROLLER_SUITE_TIMEOUT_SECONDS,
                           stdout=None, stderr=None, capture_desktop_closure=False):
    """Run one exact controller through managed closure and failure preservation."""
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
        desktop_scope = (managed_desktop(args, root, capture_closure=True)
                         if capture_desktop_closure else managed_desktop(args, root))
        with desktop_scope as desktop:
            command = command_for_desktop(desktop)
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
            streams = {key: value for key, value in (('stdout', stdout), ('stderr', stderr))
                       if value is not None}
            process = subprocess.Popen(command, cwd=cwd, text=True, env=environment, **streams)
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
                    preserved['schema_version'] != (3 if v2 else 1) or
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
                'schema_version': 3 if v2 else 1,
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
        return subprocess.CompletedProcess(command, code), desktop
    except BaseException:
        if process is not None and process.poll() is None:
            try:
                reap(190)
            except Exception:
                pass
        raise


def run_controller(root, args, defaults=None, pwsh=None):
    output = root if args.task_kind == 'core' else root / 'observer-output'
    suite_timeout = (args.test_timeout_seconds if (getattr(args, 'profile_refresh_stages', False) or
                            getattr(args, 'focused_icon_tests', False) or
                            getattr(args, 'focused_refresh_tests', False) or
                            getattr(args, 'virtual_execution_count', None) is not None)
                     else CONTROLLER_SUITE_TIMEOUT_SECONDS)
    completed, desktop = run_managed_controller(
        root, args,
        lambda lease: controller_invocation(
            root, args, defaults, pwsh, lease['expectedGuestSid'] if lease else None),
        output=output, cwd=root if args.ssh_host else Path('/mnt/c'),
        suite_timeout=suite_timeout,
    )
    if completed.returncode:
        raise subprocess.CalledProcessError(completed.returncode, completed.args)
    if (desktop and args.task_kind == 'core' and
            not getattr(args, 'profile_refresh_stages', False) and
            not getattr(args, 'focused_icon_tests', False) and
            not getattr(args, 'focused_refresh_tests', False) and
            getattr(args, 'virtual_execution_count', None) is None):
        result = read_json_strict(root / 'result.json', maximum_bytes=CORE_RESULT_MAXIMUM_BYTES)
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


def checked_language_capture(root, record, expected_file):
    """Check a bounded, source-bound native PNG capture and its recorded shape."""
    if not isinstance(record, dict) or record.get('file') != expected_file:
        raise ValueError('Language PNG capture inventory is incomplete.')
    path = checked_artifact(root, record)
    size = path.stat().st_size
    if (type(record.get('bytes')) is not int or record['bytes'] != size or
            not 45 <= size <= 8 * 1024 * 1024):
        raise ValueError('Language PNG capture byte count is invalid.')
    with path.open('rb') as stream:
        header = stream.read(33)
        stream.seek(-12, 2)
        trailer = stream.read(12)
    if (len(header) != 33 or header[:8] != b'\x89PNG\r\n\x1a\n' or
            header[8:16] != b'\x00\x00\x00\rIHDR' or header[24] != 8 or
            header[25] not in (2, 6) or header[26:29] != b'\x00\x00\x00' or
            int.from_bytes(header[29:33], 'big') != zlib.crc32(header[12:29]) or
            trailer != b'\x00\x00\x00\x00IEND\xaeB`\x82'):
        raise ValueError('Language capture has an invalid PNG structure.')
    width = int.from_bytes(header[16:20], 'big')
    height = int.from_bytes(header[20:24], 'big')
    if (type(record.get('width')) is not int or type(record.get('height')) is not int or
            record['width'] != width or record['height'] != height or
            not 1 <= width <= 16384 or not 1 <= height <= 16384 or
            width * height > 100_000_000):
        raise ValueError('Language capture PNG dimensions differ from the recorded window.')
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


def verify_picker_checks(checks, gui):
    if (not isinstance(checks, dict) or checks.get('schema_version') != 1 or
            checks.get('status') != 'passed' or checks.get('filesystem_unchanged') is not True or
            checks.get('model_restored_empty') is not True):
        raise ValueError('VM production picker checks are missing or incomplete.')
    expected = (
        (0x801D, '파일에서 경로목록 읽어 추가하기', 'file'),
        (0x801C, '바꿀 파일 이름 불러오기', 'file'),
        (0x8013, '모든 파일을 이동할 대상 폴더 선택', 'folder'),
    )
    actions = checks.get('actions')
    if not isinstance(actions, list) or len(actions) != 6:
        raise ValueError('VM production picker action inventory is incomplete.')
    for index, (command, title, acceptance) in enumerate(expected):
        for offset, action in enumerate(('cancel', acceptance)):
            row = actions[index * 2 + offset]
            if not isinstance(row, dict) or (row.get('command'), row.get('title'), row.get('action')) != (command, title, action):
                raise ValueError('VM production picker operation or action is invalid.')
            for key, binding in (('process_id', 'process_id'), ('session_id', 'session_id'),
                                 ('owner_handle', 'window_handle')):
                value = row.get(key)
                if type(value) is not int or value <= 0 or value != gui.get(binding):
                    raise ValueError('VM production picker process/session/owner binding is invalid.')
            if type(row.get('dialog_handle')) is not int or row['dialog_handle'] <= 0 or row['dialog_handle'] == row['owner_handle']:
                raise ValueError('VM production picker dialog handle is invalid.')
            for flag in ('native_owner_disabled', 'owner_enabled_after', 'foreground_restored', 'focus_process_bound',
                         'model_unchanged' if action == 'cancel' else 'expected_model_observed'):
                if row.get(flag) is not True:
                    raise ValueError('VM production picker modality, focus, or model observation is incomplete.')
            filters = row.get('filters')
            valid_filters = filters == [] if acceptance == 'folder' else (
                isinstance(filters, list) and len(filters) == 2 and
                filters[0] in ('텍스트 파일', '텍스트 파일 (*.txt)') and
                filters[1] in ('모든 파일', '모든 파일 (*.*)'))
            if not valid_filters:
                raise ValueError('VM production picker filters differ from the maintained policy.')
            if action == 'cancel':
                before, after = row.get('model_before'), row.get('model_after')
                if (not isinstance(before, dict) or before != after or
                        before.get('rows') != (0 if index == 0 else 1) or
                        not isinstance(before.get('cells'), list) or
                        len(before['cells']) != (0 if index == 0 else 3)):
                    raise ValueError('VM production picker Cancel snapshots are incomplete or changed.')
            else:
                expected_model, observed_model = row.get('expected_model'), row.get('observed_model')
                if row.get('default_extension_exercised') is not (index == 1):
                    raise ValueError('VM production picker default-extension observation is incomplete.')
                if (not isinstance(expected_model, dict) or expected_model != observed_model or
                        expected_model.get('rows') != 1 or
                        not isinstance(expected_model.get('cells'), list) or
                        len(expected_model['cells']) != 3 or
                        expected_model['cells'][0] != '선택-😀.txt' or
                        expected_model['cells'][1] != ('선택-😀.txt' if index == 0 else '변경-😀.txt') or
                        not isinstance(expected_model['cells'][2], str) or not expected_model['cells'][2]):
                    raise ValueError('VM production picker observed model differs from its expected result.')


def verify_native_messagebox_ok(record):
    if (not isinstance(record, dict) or
            record.get('selection_contract') != 'sole-native-messagebox-button' or
            type(record.get('native_button_count')) is not int or
            record['native_button_count'] != 1 or
            type(record.get('native_control_id')) is not int or
            record['native_control_id'] <= 0 or
            record.get('native_parent_bound') is not True or
            record.get('native_class') != 'Button' or
            record.get('enabled') is not True or
            not isinstance(record.get('automation_id'), str) or
            len(record['automation_id']) > 128):
        raise ValueError('Native MessageBox OK control binding is incomplete.')


def verify_gui_flow(root, manifest, flow, require_checkpoints=False, gui_binding=None,
                    screenshot_prefix='', language='ko', require_occupied=False):
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
    copy = {
        'ko': ('DarkReNamer - 안전한 적용 확인', '계획된 파일 변경을 적용하시겠습니까?',
               '기존 파일을 덮어쓰지 않습니다.'),
        'en': ('DarkReNamer - Confirm safe Apply', 'Apply the planned file changes?',
               'Existing files will not be overwritten.'),
        'ja': ('DarkReNamer - 安全な適用の確認', '計画されたファイル変更を適用しますか？',
               '既存のファイルは上書きしません。'),
    }
    confirmation = flow.get('localized_confirmation')
    if (not isinstance(confirmation, dict) or language not in copy or
            tuple(confirmation.get(key) for key in ('title', 'question', 'no_overwrite')) != copy[language] or
            not isinstance(confirmation.get('bounds'), dict) or
            any(type(confirmation['bounds'].get(key)) not in (int, float) or
                confirmation['bounds'][key] <= 0 for key in ('width', 'height'))):
        raise ValueError('VM production GUI flow lost localized Apply and no-overwrite copy.')
    if require_occupied:
        titles = {'ko': ('DarkReNamer - 적용 차단', '대상 이름이 이미 사용 중입니다.'),
                  'en': ('DarkReNamer - Apply blocked', 'The destination name is already in use.'),
                  'ja': ('DarkReNamer - 適用をブロック', '変更先の名前はすでに使用されています。')}
        occupied = flow.get('occupied_destination')
        if (not isinstance(occupied, dict) or
                tuple(occupied.get(key) for key in ('title', 'reason')) != titles[language] or
                occupied.get('source_unchanged') is not True or
                occupied.get('destination_unchanged') is not True or
                occupied.get('journal_residue_count') != 0 or
                not isinstance(occupied.get('ok_control'), dict) or
                not isinstance(occupied.get('bounds'), dict) or
                any(type(occupied['bounds'].get(key)) not in (int, float) or
                    occupied['bounds'][key] <= 0 for key in ('width', 'height'))):
            raise ValueError('VM production GUI flow did not prove localized no-overwrite refusal.')
        verify_native_messagebox_ok(occupied['ok_control'])
        for subject in ('source', 'destination'):
            for suffix in ('sha256', 'file_identity_sha256'):
                before = occupied.get(subject + '_before_' + suffix)
                after = occupied.get(subject + '_after_' + suffix)
                if (not isinstance(before, str) or
                        not re.fullmatch(r'[0-9a-f]{64}', before) or before != after):
                    raise ValueError('VM occupied destination raw content or identity changed.')
    screenshots = flow.get('screenshots')
    if not isinstance(screenshots, list) or len(screenshots) != 2:
        raise ValueError('VM production GUI flow screenshots are incomplete.')
    expected_screenshots = {screenshot_prefix + 'rename-preview.png',
                            screenshot_prefix + 'apply-confirmation.png'}
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
    if require_occupied:
        checked_language_capture(root, flow.get('prefix_prompt_capture'),
                                 language + '-prefix-prompt.png')
        binding = {key: flow.get(key) for key in ('process_id', 'session_id', 'window_handle')}
        if (any(type(binding[key]) is not int or binding[key] <= 0 for key in binding) or
                not isinstance(flow.get('process_start_time_utc_ticks'), str) or
                not re.fullmatch(r'[1-9][0-9]{14,19}', flow['process_start_time_utc_ticks'])):
            raise ValueError('Language flow lacks process, window, session, or start identity.')
        if gui_binding is not None and (
                any(flow.get(key) != gui_binding.get(other) for key, other in
                    (('process_id', 'process_id'), ('session_id', 'session_id'),
                     ('window_handle', 'window_handle'))) or
                (isinstance(gui_binding.get('process_lifecycle'), dict) and
                 flow['process_start_time_utc_ticks'] !=
                 gui_binding['process_lifecycle'].get('start_time_utc_ticks'))):
            raise ValueError('Language flow differs from the source-bound GUI process.')
        observations = flow.get('foreground_observations')
        if not isinstance(observations, list) or len(observations) != 3:
            raise ValueError('Language flow screenshot foreground evidence is incomplete.')
        for observation, label, window_class in zip(observations,
                ('prefix prompt', 'production rename preview', 'apply confirmation task dialog'),
                ('DarkReNamerInputWindow', 'DarkReNamerWindow', '#32770')):
            verify_flow_foreground_observation(observation, binding, label, window_class)
        if (type(flow.get('prefix_prompt_hwnd')) is not int or
                flow['prefix_prompt_hwnd'] <= 0 or
                observations[0]['target_hwnd'] != flow['prefix_prompt_hwnd'] or
                observations[1]['target_hwnd'] != flow['window_handle']):
            raise ValueError('Language flow captures differ from exact prompt or main HWND.')
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


def verify_journal_read_boundary(before, live, after, minimum_bytes):
    if (not isinstance(before, dict) or set(before) !=
            {'bytes', 'sha256', 'file_identity_sha256'} or
            type(before['bytes']) is not int or
            not minimum_bytes <= before['bytes'] <= 64 * 1024 * 1024 or
            any(not isinstance(before.get(key), str) or
                not re.fullmatch(r'[0-9a-f]{64}', before[key])
                for key in ('sha256', 'file_identity_sha256')) or
            after != before):
        raise ValueError('Retained journal full before/after-close checkpoint is invalid.')
    if (not isinstance(live, dict) or set(live) !=
            {'bytes', 'file_identity_sha256', 'content_read_status', 'native_error',
             'probe_access', 'probe_share_mode'} or
            type(live.get('bytes')) is not int or live['bytes'] != before['bytes'] or
            live.get('file_identity_sha256') != before['file_identity_sha256'] or
            live.get('content_read_status') != 'sharing-denied' or
            live.get('probe_access') != 'read' or
            live.get('probe_share_mode') != 'read-write-delete' or
            type(live.get('native_error')) is not int or live['native_error'] != 32):
        raise ValueError('Live retained journal did not prove exclusive content lock and identity.')


def verify_valid_active_recovery(root, manifest, record):
    if (not isinstance(record, dict) or record.get('schema_version') != 1 or
            record.get('status') != 'passed' or
            record.get('scope') != 'authentic-crash-child-three-language-default-cancel' or
            record.get('fixture_cleanup') != 'verified-owned-root'):
        raise ValueError('Valid-active multilingual recovery evidence is incomplete.')
    tests = [row for row in manifest['test_binaries'] if row.get('name') == 'darknamer_app']
    if len(tests) != 1 or not re.fullmatch(r'darknamer_app-[0-9a-f]{16}\.exe', tests[0]['file']):
        raise ValueError('Valid-active crash child lacks a unique source-built app test binary.')
    checked_artifact(root, tests[0])
    child = record.get('child')
    if (not isinstance(child, dict) or
            child.get('test_file') != tests[0]['file'] or
            child.get('test_sha256') != tests[0]['sha256'] or
            child.get('test_name') != 'windows::tests::crash_recovery_child' or
            child.get('arguments') != '--exact windows::tests::crash_recovery_child --nocapture --test-threads=1' or
            child.get('graph') != 'swap' or child.get('crash_point') != 'forward-completed-0' or
            child.get('exit_code') != 86 or child.get('job_clean') is not True or
            child.get('exit_semantics') != 'expected-abrupt-crash-point' or
            child.get('single_process_job') is not True or
            child.get('job_had_survivors') is not False or
            child.get('job_forced_termination') is not False or
            type(child.get('pid')) is not int or child['pid'] <= 0 or
            not isinstance(child.get('process_start_time_utc_ticks'), str) or
            not re.fullmatch(r'[1-9][0-9]{14,19}', child['process_start_time_utc_ticks'])):
        raise ValueError('Valid-active crash child is not bound to its exact source and exit.')
    partial = record.get('partial')
    if not isinstance(partial, dict) or set(partial) != {'files', 'journal'}:
        raise ValueError('Valid-active partial checkpoint is missing.')
    files = partial['files']
    if not isinstance(files, list) or len(files) != 3:
        raise ValueError('Valid-active partial data inventory is invalid.')
    expected_hashes = sorted(hashlib.sha256(value).hexdigest() for value in
                             (b'entry-a', b'entry-b', b'sentinel-work'))
    names = []
    identities = []
    for item in files:
        if (not isinstance(item, dict) or set(item) !=
                {'name', 'bytes', 'content_sha256', 'file_identity_sha256'} or
                not isinstance(item['name'], str) or not 1 <= len(item['name']) <= 160 or
                '\\' in item['name'] or '/' in item['name'] or item['name'] in ('.', '..') or
                type(item['bytes']) is not int or not 1 <= item['bytes'] <= 64 or
                any(not isinstance(item.get(key), str) or
                    not re.fullmatch(r'[0-9a-f]{64}', item[key])
                    for key in ('content_sha256', 'file_identity_sha256'))):
            raise ValueError('Valid-active partial file shape is invalid.')
        names.append(item['name'])
        identities.append(item['file_identity_sha256'])
    temporary_names = [name for name in names if re.fullmatch(
        r'\.__darknamer_[0-9a-f]{16}_[0-9a-f]{32}_[0-9a-f]{8}_[0-9a-f]{2}\.tmp', name)]
    if (len(set(names)) != 3 or len(set(identities)) != 3 or
            sorted(item['content_sha256'] for item in files) != expected_hashes or
            'sentinel.txt' not in names or len(temporary_names) != 1 or
            sum(name in ('a.txt', 'b.txt') for name in names) != 1):
        raise ValueError('Valid-active child did not leave a unique partial swap.')
    journal = partial['journal']
    if (not isinstance(journal, dict) or set(journal) !=
            {'bytes', 'sha256', 'file_identity_sha256'} or
            type(journal['bytes']) is not int or not 24 <= journal['bytes'] <= 64 * 1024 * 1024 or
            any(not isinstance(journal.get(key), str) or
                not re.fullmatch(r'[0-9a-f]{64}', journal[key])
                for key in ('sha256', 'file_identity_sha256'))):
        raise ValueError('Valid-active retained journal shape is invalid.')
    if record.get('final') != partial:
        raise ValueError('Valid-active final file or journal state changed.')
    expected_copy = (
        ('ko', 0, 2, 'DarkReNamer - 이전 변경 복구 확인',
         '이전 실행에서 중단된 이름 변경을 복구하시겠습니까?',
         '복구를 선택하면 보존된 저널과 현재 파일 신원을 다시 검증한 뒤 필요한 역방향 이름 변경을 수행합니다. 취소하면 어떤 파일도 변경하지 않고 복구 잠금을 유지합니다.'),
        ('en', 2, 3, 'DarkReNamer - Confirm recovery',
         'Recover name changes interrupted in the previous run?',
         'Recover checks the retained journal and current file identities again before reversing changes as needed. Cancel changes no files and keeps recovery locked.'),
        ('ja', 3, None, 'DarkReNamer - 復旧の確認',
         '前回の実行で中断された名前変更を復旧しますか？',
         '復旧を選ぶと、保持されたジャーナルと現在のファイル識別情報を再検証して必要な逆方向の名前変更を行います。キャンセルするとファイルは変更されず、復旧ロックが維持されます。'),
    )
    observations = record.get('observations')
    if not isinstance(observations, list) or len(observations) != 3:
        raise ValueError('Valid-active multilingual startup inventory is incomplete.')
    capture_bytes = 0
    for index, (row, (language, before, after, title, question, detail)) in enumerate(
            zip(observations, expected_copy)):
        if (not isinstance(row, dict) or row.get('language') != language or
                tuple(row.get(key) for key in ('title', 'question', 'cancel_guidance')) !=
                (title, question, detail) or
                row.get('cancel_default_focused') is not True or
                row.get('apply_locked_after_cancel') is not True or
                row.get('apply_locked_after_choice') is not True or
                row.get('normal_close') is not True or
                row.get('process_job_clean') is not True or
                any(type(row.get(key)) is not int or row[key] <= 0 for key in
                    ('pid', 'session_id', 'main_hwnd', 'notice_hwnd')) or
                row['pid'] == child['pid'] or row['main_hwnd'] == row['notice_hwnd'] or
                not isinstance(row.get('process_start_time_utc_ticks'), str) or
                not re.fullmatch(r'[1-9][0-9]{14,19}', row['process_start_time_utc_ticks']) or
                not isinstance(row.get('startup_preference'), dict) or
                row['startup_preference'].get('value') != before or
                not isinstance(row['startup_preference'].get('sha256'), str) or
                not re.fullmatch(r'[0-9a-f]{64}', row['startup_preference']['sha256'])):
            raise ValueError('Valid-active recovery process, language, or Cancel binding is invalid.')
        if row.get('before') != partial or row.get('after_close') != partial:
            raise ValueError('Valid-active full before/after-close checkpoints changed.')
        for key in ('at_startup', 'after_cancel', 'after_choice'):
            live_checkpoint = row.get(key)
            if (not isinstance(live_checkpoint, dict) or
                    set(live_checkpoint) != {'files', 'journal'} or
                    live_checkpoint['files'] != files):
                raise ValueError('Valid-active live partial file inventory changed.')
            verify_journal_read_boundary(journal, live_checkpoint['journal'], journal, 24)
        notice_bounds, cancel_bounds = row.get('notice_bounds'), row.get('cancel_bounds')
        if (not isinstance(notice_bounds, dict) or not isinstance(cancel_bounds, dict) or
                any(type(bounds.get(key)) not in (int, float) for bounds in
                    (notice_bounds, cancel_bounds) for key in ('x', 'y', 'width', 'height')) or
                any(bounds[key] <= 0 for bounds in (notice_bounds, cancel_bounds)
                    for key in ('width', 'height')) or
                notice_bounds['width'] > 16384 or notice_bounds['height'] > 16384 or
                cancel_bounds['x'] < notice_bounds['x'] or
                cancel_bounds['y'] < notice_bounds['y'] or
                cancel_bounds['x'] + cancel_bounds['width'] >
                notice_bounds['x'] + notice_bounds['width'] or
                cancel_bounds['y'] + cancel_bounds['height'] >
                notice_bounds['y'] + notice_bounds['height']):
            raise ValueError('Valid-active default Cancel bounds are clipped or invalid.')
        capture = row.get('notice_capture')
        checked_language_capture(root, capture, language + '-valid-active-recovery.png')
        capture_bytes += capture['bytes']
        verify_flow_foreground_observation(
            row.get('notice_capture_foreground'),
            {'process_id': row['pid'], 'session_id': row['session_id']},
            language + ' valid-active recovery confirmation', '#32770')
        if row['notice_capture_foreground']['target_hwnd'] != row['notice_hwnd']:
            raise ValueError('Valid-active recovery capture targeted another dialog.')
        choice = row.get('choice')
        if after is None:
            if choice is not None:
                raise ValueError('Final valid-active language unexpectedly changed preference.')
        elif (not isinstance(choice, dict) or choice.get('input') != 'native-menu-keyboard' or
              any(choice.get(key) != row[binding] for key, binding in
                  (('pid', 'pid'), ('session_id', 'session_id'), ('hwnd', 'main_hwnd'))) or
              choice.get('model_rows_before') != 0 or choice.get('model_rows_after') != 0 or
              choice.get('model_before') != {'rows': 0, 'cells': []} or
              choice.get('model_after') != {'rows': 0, 'cells': []} or
              not isinstance(choice.get('preference'), dict) or
              choice['preference'].get('value') != after or
              not isinstance(choice.get('before'), dict) or
              choice['before'].get('checked_command') != 0x9020 + before or
              not isinstance(choice.get('after'), dict) or
              choice['after'].get('checked_command') != 0x9020 + after):
            raise ValueError('Valid-active language choice did not preserve the recovery lock.')
        if after is not None:
            verify_language_menu_input_trace(choice, 0x9020 + after)
        if index > 0 and row['startup_preference'] != observations[index - 1]['choice']['preference']:
            raise ValueError('Valid-active next startup did not reload its selected language.')
    if len({row['pid'] for row in observations} | {child['pid']}) != 4:
        raise ValueError('Valid-active recovery reused a supposedly closed process.')
    return capture_bytes


def verify_language_menu_input_trace(choice, target):
    trace = choice.get('input_trace')
    target_index = target - 0x9020
    if not isinstance(trace, list) or len(trace) != target_index + 3:
        raise ValueError('Real language menu keyboard stage trace is incomplete.')
    down_count = target_index
    phases = ['alt-v', 'language-open'] + [
        'down-' + str(index) for index in range(1, down_count + 1)] + ['pre-enter']
    current_highlight = None
    view_popup = None
    language_popups = None
    language_handle = None
    for index, (stage, phase) in enumerate(zip(trace, phases)):
        if (not isinstance(stage, dict) or stage.get('phase') != phase or
                any(type(stage.get(key)) is not int or stage[key] <= 0 for key in
                    ('pid', 'session_id', 'hwnd', 'thread_id', 'language_handle')) or
                stage['pid'] != choice['pid'] or stage['session_id'] != choice['session_id'] or
                stage['hwnd'] != choice['hwnd'] or stage.get('menu_owner') != choice['hwnd'] or
                type(stage.get('gui_flags')) is not int or
                stage['gui_flags'] & 0x4 != 0x4 or
                type(stage.get('view_language_state')) is not int or
                not isinstance(stage.get('top_states'), list) or len(stage['top_states']) != 6 or
                not isinstance(stage.get('view_states'), list) or len(stage['view_states']) != 10 or
                any(type(state) is not int or state < 0 for state in
                    stage['top_states'] + stage['view_states']) or
                stage['top_states'][2] & 0x80 == 0 or
                stage['view_states'][9] != stage['view_language_state'] or
                not isinstance(stage.get('popups'), list) or
                type(stage.get('popup_count')) is not int or
                stage['popup_count'] != len(stage['popups']) or
                len(stage['popups']) != (1 if phase == 'alt-v' else 2) or
                stage.get('commands') != list(range(0x9020, 0x9024)) or
                not isinstance(stage.get('states'), list) or len(stage['states']) != 4 or
                any(type(state) is not int or state < 0 for state in stage['states'])):
            raise ValueError('Real language menu stage lost process, owner, mode, or command binding.')
        popup_handles = []
        for popup in stage['popups']:
            if not isinstance(popup, dict) or type(popup.get('hwnd')) is not int or popup['hwnd'] <= 0 or \
                    type(popup.get('owner')) is not int or \
                    type(popup.get('process_id')) is not int or popup['process_id'] != choice['pid'] or \
                    popup.get('class') != '#32768' or popup.get('visible') is not True or \
                    not isinstance(popup.get('bounds'), dict):
                raise ValueError('Real language menu popup identity is invalid.')
            bounds = popup['bounds']
            if (any(type(bounds.get(key)) is not int for key in ('left', 'top', 'right', 'bottom')) or
                    not 0 < bounds['right'] - bounds['left'] <= 4096 or
                    not 0 < bounds['bottom'] - bounds['top'] <= 4096):
                raise ValueError('Real language menu popup bounds are invalid.')
            popup_handles.append(popup['hwnd'])
        if len(set(popup_handles)) != len(popup_handles):
            raise ValueError('Real language menu popups reuse a native window handle.')
        if language_handle is None:
            language_handle = stage['language_handle']
            view_popup = popup_handles[0]
        elif stage['language_handle'] != language_handle:
            raise ValueError('Real language menu handle changed during keyboard navigation.')
        if index == 1:
            if view_popup not in popup_handles:
                raise ValueError('Language mnemonic replaced the bound View popup.')
            language_popups = set(popup_handles)
        elif index > 1 and set(popup_handles) != language_popups:
            raise ValueError('Language submenu popups changed during keyboard navigation.')
        highlighted = [position for position, state in enumerate(stage['states'])
                       if state & 0x80]
        if stage.get('highlighted_indices') != highlighted:
            raise ValueError('Real language menu highlighted indices contradict native states.')
        if phase == 'language-open':
            if (stage['view_language_state'] & 0x80 == 0 or highlighted != [0] or
                    stage['states'][0] & 0x3):
                raise ValueError('Language mnemonic did not settle on enabled System item.')
            current_highlight = 0
        elif phase.startswith('down-'):
            if current_highlight == target_index:
                raise ValueError('Language navigation continued after reaching its target.')
            expected = (current_highlight + 1) % 4
            if highlighted != [expected] or stage['states'][expected] & 0x3:
                raise ValueError('Real language menu Down did not move to its enabled next item.')
            current_highlight = expected
        elif phase == 'pre-enter' and (current_highlight != target_index or
                                       highlighted != [target_index] or
                                       stage['states'][target_index] & 0x3):
            raise ValueError('Real language menu was not visibly on the enabled target.')
    if (not isinstance(choice.get('status_before'), str) or
            len(choice['status_before']) > 512):
        raise ValueError('Language menu initial status observation is invalid.')
    samples = choice.get('post_enter')
    if not isinstance(samples, list) or not 1 <= len(samples) <= 16:
        raise ValueError('Language menu has no bounded post-Enter observations.')
    for sample in samples:
        if (not isinstance(sample, dict) or
                not isinstance(sample.get('status'), str) or len(sample['status']) > 512 or
                sample.get('checked_command') not in (None, *range(0x9020, 0x9024)) or
                sample.get('menu_read_error') is not None and
                (not isinstance(sample['menu_read_error'], str) or
                 len(sample['menu_read_error']) > 128) or
                not isinstance(sample.get('owned_modals'), list) or
                len(sample['owned_modals']) > 4):
            raise ValueError('Language menu post-Enter status or menu observation is invalid.')
        for modal in sample['owned_modals']:
            if (not isinstance(modal, dict) or type(modal.get('hwnd')) is not int or
                    modal['hwnd'] <= 0 or modal.get('class') != '#32770' or
                    not isinstance(modal.get('title'), str) or len(modal['title']) > 128):
                raise ValueError('Language menu owned modal observation is invalid.')
        preference = sample.get('preference')
        if preference is not None and (not isinstance(preference, dict) or
                type(preference.get('value')) is not int or
                preference['value'] not in range(4) or
                not isinstance(preference.get('sha256'), str) or
                not re.fullmatch(r'[0-9a-f]{64}', preference['sha256'])):
            raise ValueError('Language menu observed malformed preference metadata.')
        read_error = sample.get('preference_read_error')
        if read_error is not None and (not isinstance(read_error, dict) or
                not isinstance(read_error.get('kind'), str) or
                len(read_error['kind']) > 128 or
                type(read_error.get('native_error')) is not int or
                read_error['native_error'] < 0):
            raise ValueError('Language menu observed malformed preference read failure.')
    if samples[-1].get('preference') != choice['preference']:
        raise ValueError('Language menu saved preference lacks matching post-Enter readback.')


def verify_language_process_jobs(checks, process_jobs):
    selections = checks['selections']
    active = checks['valid_active_recovery']
    records = (selections +
               [row['blocked_recovery'] for row in selections[:3]] +
               [active['child']] + active['observations'])
    if len(records) != 12 or not isinstance(process_jobs, list) or not 12 <= len(process_jobs) <= 64:
        raise ValueError('Language process lifecycle or Job inventory is incomplete.')
    identities = set()
    for record in records:
        lifecycle = record.get('process_lifecycle') if isinstance(record, dict) else None
        if (not isinstance(lifecycle, dict) or
                set(lifecycle) != {'pid', 'start_time_utc_ticks'} or
                type(lifecycle['pid']) is not int or lifecycle['pid'] <= 0 or
                not isinstance(lifecycle['start_time_utc_ticks'], str) or
                not re.fullmatch(r'[1-9][0-9]{14,18}', lifecycle['start_time_utc_ticks']) or
                lifecycle['pid'] != record.get('pid') or
                lifecycle['start_time_utc_ticks'] != record.get('process_start_time_utc_ticks')):
            raise ValueError('Language process lifecycle differs from its recorded owner.')
        identity = (lifecycle['pid'], lifecycle['start_time_utc_ticks'])
        if identity in identities:
            raise ValueError('Language process lifecycle is duplicated across roles.')
        identities.add(identity)
    jobs = {}
    for row in process_jobs:
        if (not isinstance(row, dict) or type(row.get('pid')) is not int or row['pid'] <= 0 or
                not isinstance(row.get('process_start_time_utc_ticks'), str) or
                not re.fullmatch(r'[1-9][0-9]{14,18}', row['process_start_time_utc_ticks'])):
            raise ValueError('Language Job ledger has an invalid process identity.')
        identity = (row['pid'], row['process_start_time_utc_ticks'])
        if identity in jobs:
            raise ValueError('Language Job ledger repeats a process identity.')
        jobs[identity] = row
    for identity in identities:
        job = jobs.get(identity)
        if (not isinstance(job, dict) or job.get('status') != 'clean' or
                job.get('job_empty') is not True or job.get('job_closed') is not True or
                job.get('capture_complete') is not True or
                job.get('had_survivors') is not False or
                job.get('forced_termination') is not False or
                type(job.get('active_processes_at_close')) is not int or
                job['active_processes_at_close'] != 0):
            raise ValueError('Language process is not bound to a clean, closed Job.')


def verify_language_checks(root, manifest, checks, baseline_flow, process_jobs):
    if (not isinstance(checks, dict) or checks.get('schema_version') != 1 or
            checks.get('status') != 'passed' or
            checks.get('scope') != 'source-built-three-language-native-menu' or
            checks.get('application_sha256') != application_record(manifest)['sha256']):
        raise ValueError('Source-built language acceptance is missing or unbound.')
    system = checks.get('system_resolution')
    if not isinstance(system, dict) or not isinstance(system.get('preferred_tags'), list) or len(system['preferred_tags']) > 4096 or any(
            not isinstance(tag, str) or not 1 <= len(tag) <= 256 for tag in system['preferred_tags']):
        raise ValueError('Windows preferred UI-language inventory is invalid.')
    selected = next((tag for tag in system['preferred_tags'] if re.match(r'^(ko|en|ja)(-|$)', tag, re.I)), None)
    resolved = selected[:2].lower() if selected else 'en'
    if system.get('selected_tag') != selected or system.get('language') != resolved:
        raise ValueError('System language restart does not match the Windows preferred UI-language order.')
    labels = {
        'ko': ('언어(&L) · 다음 실행부터', '시스템 언어', '이름 앞에 문자열 붙이기...'),
        'en': ('&Language · next startup', 'System language', 'Add a name prefix...'),
        'ja': ('言語(&L) · 次回起動から', 'システム言語', '名前の先頭に文字列を追加...'),
    }
    recovery_labels = {
        'ko': ('DarkReNamer - 복구 상태', '새 적용은 잠겼습니다.'),
        'en': ('DarkReNamer - Recovery status', 'Apply is locked.'),
        'ja': ('DarkReNamer - 復旧状態', '適用をロックしました。'),
    }
    locales = (
        ('ko', 0, 2, '언어(&L) · 다음 실행부터', '시스템 언어', '이름 앞에 문자열 붙이기...'),
        ('en', 2, 3, '&Language · next startup', 'System language', 'Add a name prefix...'),
        ('ja', 3, 1, '言語(&L) · 次回起動から', 'システム言語', '名前の先頭に文字列を追加...'),
        ('ko', 1, 0, '언어(&L) · 다음 실행부터', '시스템 언어', '이름 앞에 문자열 붙이기...'),
        (resolved, 0, None, *labels[resolved]),
    )
    selections = checks.get('selections')
    if not isinstance(selections, list) or len(selections) != len(locales):
        raise ValueError('Language startup and menu selection inventory is incomplete.')
    checked_language_capture(root, baseline_flow.get('prefix_prompt_capture'),
                             'ko-prefix-prompt.png')
    capture_bytes = baseline_flow['prefix_prompt_capture']['bytes']
    for index, (row, (language, before, after, menu_label, system_label, rail_name)) in enumerate(zip(selections, locales)):
        if not isinstance(row, dict) or row.get('language') != language:
            raise ValueError('Language startup order is invalid.')
        for key in ('pid', 'hwnd', 'session_id'):
            if type(row.get(key)) is not int or row[key] <= 0:
                raise ValueError('Language process, window, or session binding is invalid.')
        if (not isinstance(row.get('process_start_time_utc_ticks'), str) or
                not re.fullmatch(r'[1-9][0-9]{14,19}', row['process_start_time_utc_ticks'])):
            raise ValueError('Language startup process start identity is invalid.')
        if index < 3:
            capture = row.get('startup_capture')
            checked_language_capture(root, capture, language + '-language-main.png')
            capture_bytes += capture['bytes']
            verify_flow_foreground_observation(
                row.get('startup_capture_foreground'),
                {'process_id': row['pid'], 'session_id': row['session_id']},
                language + ' language main workbench', 'DarkReNamerWindow')
            if row['startup_capture_foreground']['target_hwnd'] != row['hwnd']:
                raise ValueError('Language main capture differs from startup HWND.')
        elif row.get('startup_capture') is not None or row.get('startup_capture_foreground') is not None:
            raise ValueError('Language startup has an unexpected additional main capture.')
        preference, menu, rail, choice = (row.get(key) for key in
                                           ('startup_preference', 'startup_menu', 'startup_rail', 'choice'))
        if (not isinstance(preference, dict) or preference.get('value') != before or
                not isinstance(preference.get('sha256'), str) or
                not re.fullmatch(r'[0-9a-f]{64}', preference['sha256']) or
                not isinstance(menu, dict) or menu.get('parent') != menu_label or
                menu.get('options') != [system_label, '한국어', 'English', '日本語'] or
                menu.get('checked_command') != 0x9020 + before):
            raise ValueError('Language preference or translated menu did not survive startup.')
        if (not isinstance(rail, dict) or rail.get('automation_id') != '32773' or
                rail.get('name') != rail_name or not isinstance(rail.get('bounds'), dict) or
                any(type(rail['bounds'].get(key)) not in (int, float) or rail['bounds'][key] <= 0
                    for key in ('width', 'height'))):
            raise ValueError('Language accessible rail name or bounds are invalid.')
        blocked = row.get('blocked_recovery')
        if before in (0, 2, 3) and after is not None:
            if (not isinstance(blocked, dict) or blocked.get('language') != language or
                    tuple(blocked.get(key) for key in ('title', 'lock_guidance')) != recovery_labels[language] or
                    any(type(blocked.get(key)) is not int or blocked[key] <= 0
                        for key in ('pid', 'hwnd', 'session_id')) or
                    blocked['session_id'] != row['session_id'] or
                    not isinstance(blocked.get('journal_sha256'), str) or
                    not re.fullmatch(r'[0-9a-f]{64}', blocked['journal_sha256']) or
                    blocked.get('journal_unchanged') is not True or
                    blocked.get('normal_close') is not True or
                    blocked.get('process_job_clean') is not True or
                    blocked.get('apply_enabled') is not False or
                    blocked.get('model_rows') != 0 or
                    not isinstance(blocked.get('ok_control'), dict) or
                    not isinstance(blocked.get('notice_bounds'), dict) or
                    any(type(blocked['notice_bounds'].get(key)) not in (int, float) or
                        blocked['notice_bounds'][key] <= 0 for key in ('width', 'height'))):
                raise ValueError('Localized blocked recovery or retained-journal evidence is incomplete.')
            verify_native_messagebox_ok(blocked['ok_control'])
            journal_before = blocked.get('journal_before')
            verify_journal_read_boundary(journal_before, blocked.get('journal_live'),
                                         blocked.get('journal_after_close'), 1)
            marker = b'DarkReNamer bounded invalid active journal fixture'
            if (journal_before['bytes'] != len(marker) or
                    journal_before['sha256'] != hashlib.sha256(marker).hexdigest() or
                    blocked['journal_sha256'] != journal_before['sha256']):
                raise ValueError('Blocked recovery journal differs from its owned corrupt fixture.')
            capture = blocked.get('notice_capture')
            checked_language_capture(root, capture, language + '-blocked-recovery.png')
            capture_bytes += capture['bytes']
            verify_flow_foreground_observation(
                blocked.get('notice_capture_foreground'),
                {'process_id': blocked['pid'], 'session_id': blocked['session_id']},
                language + ' blocked recovery notice', '#32770')
            if (type(blocked.get('notice_hwnd')) is not int or
                    blocked['notice_hwnd'] <= 0 or blocked['notice_hwnd'] == blocked['hwnd'] or
                    blocked['notice_capture_foreground']['target_hwnd'] != blocked['notice_hwnd']):
                raise ValueError('Blocked recovery capture targeted the wrong dialog HWND.')
        elif blocked is not None:
            raise ValueError('Language startup has an unexpected blocked-recovery probe.')
        if after is None:
            if choice is not None:
                raise ValueError('System language readback unexpectedly changed the preference.')
        elif (not isinstance(choice, dict) or choice.get('input') != 'native-menu-keyboard' or
              any(choice.get(key) != row[binding] for key, binding in
                  (('pid', 'pid'), ('hwnd', 'hwnd'), ('session_id', 'session_id'))) or
              choice.get('before') != menu or
              not isinstance(choice.get('after'), dict) or
              choice['after'].get('checked_command') != 0x9020 + after or
              choice['after'].get('parent') != menu_label or
              choice['after'].get('options') != menu['options'] or
              type(choice.get('model_rows_before')) is not int or
              not 0 <= choice['model_rows_before'] <= 1 or
              choice.get('model_rows_after') != choice['model_rows_before'] or
              not isinstance(choice.get('model_before'), dict) or
              choice.get('model_after') != choice['model_before'] or
              choice['model_before'].get('rows') != choice['model_rows_before'] or
              not isinstance(choice['model_before'].get('cells'), list) or
              len(choice['model_before']['cells']) != 4 * choice['model_rows_before'] or
              any(not isinstance(cell, str) or len(cell) > 32768
                  for cell in choice['model_before']['cells']) or
              choice.get('rail_before') != rail or choice.get('rail_after') != rail or
              not isinstance(choice.get('preference'), dict) or
              choice['preference'].get('value') != after):
            raise ValueError('Language menu selection changed the current UI or model.')
        if after is not None:
            verify_language_menu_input_trace(choice, 0x9020 + after)
            pending_before = choice.get('pending_file_before')
            pending_after = choice.get('pending_file_after')
            if index == 1:
                cells = choice['model_before']['cells']
                if (choice['model_rows_before'] != 1 or
                        not all(isinstance(cell, str) and 0 < len(cell) <= 32768 for cell in cells) or
                        cells[1] == cells[0] or not cells[1].startswith('pending-') or
                        not cells[2] or not cells[3] or
                        not isinstance(pending_before, dict) or pending_after != pending_before or
                        any(not isinstance(pending_before.get(key), str) or
                            not re.fullmatch(r'[0-9a-f]{64}', pending_before[key])
                            for key in ('content_sha256', 'file_identity_sha256'))):
                    raise ValueError('Language choice did not preserve an unapplied model proposal and file.')
            elif pending_before is not None or pending_after is not None:
                raise ValueError('Language choice has an unexpected pending-file probe.')
    if capture_bytes > 48 * 1024 * 1024:
        raise ValueError('Language capture inventory exceeds its total byte bound.')
    restored = checks.get('restored_preference')
    if (not isinstance(restored, dict) or restored != selections[-2]['choice']['preference'] or
            restored != selections[-1]['startup_preference']):
        raise ValueError('Language acceptance did not restore the original System preference.')
    flows = checks.get('flows')
    if not isinstance(flows, list) or len(flows) != 2:
        raise ValueError('English and Japanese actual file-flow evidence is incomplete.')
    for row, language in zip(flows, ('en', 'ja')):
        if not isinstance(row, dict) or row.get('language') != language:
            raise ValueError('Language file-flow order is invalid.')
        flow = row.get('flow')
        selection = selections[1 if language == 'en' else 2]
        if (not isinstance(flow, dict) or
                any(flow.get(key) != selection[binding] for key, binding in
                    (('process_id', 'pid'), ('session_id', 'session_id'),
                     ('window_handle', 'hwnd'),
                     ('process_start_time_utc_ticks', 'process_start_time_utc_ticks')))):
            raise ValueError('Language file flow is not bound to its startup process and window.')
        verify_gui_flow(root, manifest, flow, screenshot_prefix=language + '-',
                        language=language, require_occupied=True)
        capture_bytes += flow['prefix_prompt_capture']['bytes']
        checkpoints = verify_flow_checkpoints(flow)
        prelaunch = flow.get('prelaunch_checkpoints')
        if (not isinstance(prelaunch, list) or len(prelaunch) != 1 or
                not isinstance(prelaunch[0], dict) or
                set(prelaunch[0]) != {'phase', 'fixture_entries', 'journal_entries'} or
                prelaunch[0]['phase'] != 'initial' or
                prelaunch[0]['fixture_entries'] != flow['checkpoints'][0]['fixture_entries']):
            raise ValueError('Language flow prelaunch fixture checkpoint is invalid.')
        runtime_lock = [{'name': 'runtime.lock', 'kind': 'file', 'bytes': 0}]
        for journal in (prelaunch[0]['journal_entries'], flow['checkpoints'][0]['journal_entries']):
            if (not isinstance(journal, list) or len(journal) != 1 or
                    not isinstance(journal[0], dict) or
                    set(journal[0]) != {'name', 'kind', 'bytes'} or
                    type(journal[0]['bytes']) is not int or journal != runtime_lock):
                raise ValueError('Language flow requires the same exact prelaunch and startup runtime lock.')
        if (flow.get('before_content_sha256') != baseline_flow.get('before_content_sha256') or
                flow.get('after_content_sha256') != checkpoints['after_apply']['content_sha256'] or
                flow.get('after_file_identity_sha256') != checkpoints['after_apply']['file_identity_sha256']):
            raise ValueError('Language file outcomes differ from the source-bound baseline.')
        if language == 'en' and (
                selections[1]['choice']['pending_file_before']['content_sha256'] !=
                flow['after_content_sha256'] or
                selections[1]['choice']['pending_file_before']['file_identity_sha256'] !=
                flow['after_file_identity_sha256']):
            raise ValueError('Pending selection file does not match the applied flow outcome.')
    if capture_bytes > 48 * 1024 * 1024:
        raise ValueError('Language capture inventory exceeds its total byte bound.')
    capture_bytes += verify_valid_active_recovery(root, manifest,
                                                  checks.get('valid_active_recovery'))
    if capture_bytes > 48 * 1024 * 1024:
        raise ValueError('Language capture inventory exceeds its total byte bound.')
    verify_language_process_jobs(checks, process_jobs)
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


def verify_current_anchor_from_bundle(root, manifest, transport):
    """Join a current owned-resource claim to the actual staged bundle bytes."""
    raw = transport.get('raw_cleanup') if isinstance(transport, dict) else None
    if not isinstance(raw, dict) or raw.get('schema_version') != 3:
        return
    source = (manifest['harness']['source_sha'] if manifest['schema_version'] == 2
              else manifest['source_sha'])
    verify_current_protected_anchor_binding(
        transport, source_sha=source, bundle_sha256=sha256(Path(root) / 'bundle.json'))


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
        if not verify_gui_flow(root, manifest, gui.get('flow', {}), candidate, gui,
                               require_occupied=not candidate):
            passed = False
        if not candidate:
            verify_picker_checks(gui.get('dialog_picker_checks'), gui)
            verify_language_checks(root, manifest, gui.get('language_checks'), gui['flow'],
                                   result.get('process_job_cleanup'))
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
        verify_current_anchor_from_bundle(root, manifest, transport)
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
                 focused_case=None, focused_kind='icon', virtual_execution=None):
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
    if virtual_execution is not None:
        if refresh_profile or focused_profile is not None or focused_case is not None or \
                not isinstance(virtual_execution, tuple) or len(virtual_execution) != 2 or \
                virtual_execution[0] not in (100, 1000, 10000) or \
                type(virtual_execution[1]) is not int or not 0 <= virtual_execution[1] <= 5:
            raise ValueError('Virtual execution requires one fixed count and iteration.')
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
        if refresh_profile or focused_profile or virtual_execution:
            if refresh_profile or focused_profile == 'release' or virtual_execution:
                command.append('--release')
            command += ['-p', 'darknamer-app']
            command += ['--test', 'rename_windows_backend'] if virtual_execution else ['--lib']
        else:
            command += ['--workspace', '--all-targets']
        command += ['--all-features', '--locked', '--target', TARGET,
                    '--no-run', '--message-format=json']
        messages_path = root / 'cargo-build.jsonl'
        with messages_path.open('w') as stream:
            subprocess.run(command, cwd=repo, env=env, stdout=stream, check=True)
        with messages_path.open() as stream:
            artifacts = test_artifacts(stream)
        if (refresh_profile or focused_profile or virtual_execution) and (len(artifacts) != 1 or artifacts[0]['name'] !=
                ('rename_windows_backend' if virtual_execution else 'darknamer_app')):
            raise RuntimeError('Selected native diagnostic must produce one expected test binary.')
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
    elif virtual_execution:
        manifest['diagnostic'] = {
            'kind': 'virtual-execution', 'test_profile': 'release',
            'test_name': VIRTUAL_EXECUTION_TEST, 'count': virtual_execution[0],
            'iteration': virtual_execution[1], 'media': 'virtual',
            'evidence_class': 'virtual-execution', 'scope': 'vm-durable',
            'variant': 'baseline', 'topology': 'same-parent',
        }
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
    verify_current_anchor_from_bundle(root, manifest, transport)
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


def verify_virtual_execution_lines(output, *, source_sha, count, iteration):
    """Reject incomplete or relabeled durable VM benchmark output.

    The caller must also bind this text to the exact test binary, libtest result,
    medium-token job and cleaned VM transport. Neither producer line is a VM
    identity or process-lifecycle attestation by itself.
    """
    prefix = 'darkrenamer_benchmark_virtual_v1,'
    test_prefix = 'test ' + VIRTUAL_EXECUTION_TEST + ' ... '
    lines = []
    for line in output.splitlines():
        line = line.removeprefix(test_prefix)
        if line.startswith(prefix):
            lines.append(line.removeprefix(prefix).strip())
    if len(lines) != 2:
        raise ValueError('Virtual execution requires started and completed v1 records.')
    parsed = []
    for line in lines:
        fields = {}
        for pair in line.split(','):
            key, sep, value = pair.partition('=')
            if not sep or not key or not value or key in fields:
                raise ValueError('Virtual execution record has a missing or duplicate field.')
            fields[key] = value
        parsed.append(fields)
    started, completed = parsed
    common = {
        'schema_version': '1', 'media': 'virtual',
        'evidence_class': 'virtual-execution', 'scope': 'vm-durable',
        'source_sha': source_sha, 'count': str(count), 'topology': 'same-parent',
        'variant': 'baseline', 'iteration': str(iteration),
        'recorded': str(iteration != 0).lower(),
    }
    if (set(started) != set(common) | {'status'} or started.get('status') != 'started' or
            any(started.get(key) != value for key, value in common.items())):
        raise ValueError('Virtual execution start record differs from the fixed selector.')
    expected_keys = set(common) | {
        'status', 'instrumentation_revision', 'setup_us', 'planning_us', 'preflight_us',
        'execution_us', 'verification_us', 'cleanup_us', 'attempted_files',
        'successful_files', 'failed_files', 'verified_files', 'backend_rename_calls',
        'backend_rename_us', 'journal_begin_calls', 'journal_begin_us',
        'journal_prepared_calls', 'journal_prepared_us', 'journal_completed_calls',
        'journal_completed_us', 'journal_not_applied_calls', 'journal_not_applied_us',
        'journal_terminal_calls', 'journal_terminal_us', 'journal_removed',
        'fixture_removed',
    }
    if (set(completed) != expected_keys or completed.get('status') != 'completed' or
            completed.get('instrumentation_revision') != 'vm-durable-v1' or
            completed.get('journal_removed') != 'true' or
            completed.get('fixture_removed') != 'true' or
            any(completed.get(key) != value for key, value in common.items())):
        raise ValueError('Virtual execution completion record is incomplete or mislabeled.')
    numeric = expected_keys - set(common) - {
        'status', 'instrumentation_revision', 'journal_removed', 'fixture_removed'
    }
    values = {}
    for key in numeric:
        value = completed[key]
        if not re.fullmatch(r'0|[1-9][0-9]*', value):
            raise ValueError('Virtual execution metric is not a bounded decimal integer.')
        values[key] = int(value)
        if values[key] > (1_200_000_000 if key.endswith('_us') else 10_000):
            raise ValueError('Virtual execution metric exceeds its supported bound.')
    counts = {
        'attempted_files': count, 'successful_files': count,
        'failed_files': 0, 'verified_files': count,
        'backend_rename_calls': count, 'journal_begin_calls': 1,
        'journal_prepared_calls': count, 'journal_completed_calls': count,
        'journal_not_applied_calls': 0, 'journal_terminal_calls': 1,
    }
    if any(values[key] != expected for key, expected in counts.items()) or values['execution_us'] == 0:
        raise ValueError('Virtual execution did not complete the declared durable workload.')
    return {'schema_version': 1, **common, **values,
            'instrumentation_revision': 'vm-durable-v1',
            'journal_removed': True, 'fixture_removed': True}


def verify_virtual_execution_job(row, jobs):
    lifecycle = row.get('process_lifecycle')
    if (not isinstance(lifecycle, dict) or
            set(lifecycle) != {'pid', 'start_time_utc_ticks'} or
            type(lifecycle['pid']) is not int or lifecycle['pid'] <= 0 or
            not isinstance(lifecycle['start_time_utc_ticks'], str) or
            not re.fullmatch(r'[1-9][0-9]{14,18}', lifecycle['start_time_utc_ticks']) or
            not isinstance(jobs, list) or len(jobs) != 1 or not isinstance(jobs[0], dict) or
            type(jobs[0].get('pid')) is not int or
            jobs[0]['pid'] != lifecycle['pid'] or
            jobs[0].get('process_start_time_utc_ticks') != lifecycle['start_time_utc_ticks'] or
            jobs[0].get('status') != 'clean' or jobs[0].get('job_empty') is not True or
            jobs[0].get('job_closed') is not True or
            jobs[0].get('capture_complete') is not True or
            jobs[0].get('had_survivors') is not False or
            jobs[0].get('forced_termination') is not False or
            type(jobs[0].get('active_processes_at_close')) is not int or
            jobs[0]['active_processes_at_close'] != 0):
        raise ValueError('Virtual execution has no clean, exact process Job receipt.')


def verify_virtual_execution_result(root, manifest, result, transport_kind,
                                    expected_vm_id, profile_sha256):
    root = Path(root)
    diagnostic = manifest.get('diagnostic')
    if (not isinstance(diagnostic, dict) or set(diagnostic) != {
            'kind', 'test_profile', 'test_name', 'count', 'iteration', 'media',
            'evidence_class', 'scope', 'variant', 'topology'} or
            diagnostic.get('kind') != 'virtual-execution' or
            diagnostic.get('test_profile') != 'release' or
            diagnostic.get('test_name') != VIRTUAL_EXECUTION_TEST or
            type(diagnostic.get('count')) is not int or
            diagnostic['count'] not in (100, 1000, 10000) or
            type(diagnostic.get('iteration')) is not int or
            not 0 <= diagnostic['iteration'] <= 5 or
            any(diagnostic.get(key) != expected for key, expected in {
                'media': 'virtual', 'evidence_class': 'virtual-execution',
                'scope': 'vm-durable', 'variant': 'baseline',
                'topology': 'same-parent'}.items()) or
            len(manifest.get('test_binaries', [])) != 1 or
            manifest['test_binaries'][0].get('name') != 'rename_windows_backend'):
        raise ValueError('The source-bound virtual execution bundle is invalid.')
    if (type(result.get('schema_version')) is not int or result['schema_version'] != 1 or
            any(result.get(key) != manifest[key] for key in
                ('source_sha', 'source_state', 'target')) or
            result.get('diagnostic') != diagnostic or result.get('gui') is not None or
            result.get('status') != 'passed'):
        raise ValueError('Virtual execution result differs from its fixed selection.')
    rows = result.get('tests')
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
        raise ValueError('Virtual execution requires one test binary result.')
    row = rows[0]
    binary = manifest['test_binaries'][0]
    if (row.get('file') != binary['file'] or row.get('sha256') != binary['sha256'] or
            row.get('test_name') != VIRTUAL_EXECUTION_TEST or row.get('status') != 'passed' or
            row.get('job_cleanup') is not True or row.get('exit_code') != 0 or
            row.get('failure_reason') is not None or
            any(type(row.get(key)) is not int for key in ('passed', 'failed', 'ignored')) or
            [row.get(key) for key in ('passed', 'failed', 'ignored')] != [1, 0, 0]):
        raise ValueError('Virtual execution test did not finish with clean job ownership.')
    verify_virtual_execution_job(row, result.get('process_job_cleanup'))
    for record in (binary, manifest['application'], manifest['runner']):
        checked_artifact(root, record)
    total_output = 0
    for channel in ('stdout', 'stderr'):
        record = row.get(channel)
        if (not isinstance(record, dict) or type(record.get('bytes')) is not int or
                record['bytes'] < 0 or record['bytes'] > TEST_OUTPUT_CHANNEL_MAXIMUM_BYTES):
            raise ValueError('Virtual execution output is missing or exceeds its channel bound.')
        if checked_artifact(root, record).stat().st_size != record['bytes']:
            raise ValueError('Virtual execution transcript size differs from its record.')
        total_output += record['bytes']
    if total_output > TEST_OUTPUT_AGGREGATE_MAXIMUM_BYTES:
        raise ValueError('Virtual execution output exceeds its aggregate bound.')
    output = (root / row['stdout']['file']).read_text(encoding='utf-8-sig', errors='replace')
    summary = re.findall(
        r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; '
        r'\d+ measured; (\d+) filtered out;', output, re.MULTILINE)
    names = re.findall(r'(?m)^test (\S+) \.\.\. ', output)
    if (len(summary) != 1 or summary[0][:4] != ('ok', '1', '0', '0') or
            int(summary[0][4]) < 1 or names != [VIRTUAL_EXECUTION_TEST]):
        raise ValueError('Virtual execution did not run the exact ignored benchmark.')
    metrics = verify_virtual_execution_lines(
        output, source_sha=manifest['source_sha'], count=diagnostic['count'],
        iteration=diagnostic['iteration'])
    transport = result.get('transport')
    if (not isinstance(transport, dict) or transport.get('task_kind') != 'core' or
            transport.get('status') != 'collected' or transport.get('guest_cleanup') is not True):
        raise ValueError('Virtual execution transport did not finish cleanly.')
    verify_controller_cleanup(transport.get('raw_cleanup'), profile_id=V2_PROFILE_ID,
                              profile_sha256=profile_sha256)
    verify_current_anchor_from_bundle(root, manifest, transport)
    _verify_v2_result_owned_binding(result, transport)
    verify_transport_binding(transport, transport_kind, expected_vm_id)
    return {'status': 'passed', 'test_binary_sha256': binary['sha256'],
            'stdout_sha256': row['stdout']['sha256'], 'metrics': metrics}


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
    verify_current_anchor_from_bundle(root, manifest, transport)
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
    if isinstance(transport.get('raw_cleanup'), dict) and transport['raw_cleanup'].get('schema_version') == 3:
        manifest = read_json_strict(Path(root).parent / 'bundle.json')
        verify_current_anchor_from_bundle(Path(root).parent, manifest, transport)
    if profile_id == V2_PROFILE_ID:
        _verify_v2_result_owned_binding(result, transport)
    if not is_supported_powershell_version(engine.get('version')):
        raise ValueError('Observer transport engine version is invalid.')
    verify_transport_binding(
        transport, expected_transport_kind, expected_vm_id,
        require_identity_proof=True)
    return transport


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
    transport = verify_observer_transport(
        root, 'recovery', expected_transport_kind, expected_vm_id,
        profile_id=profile_id, profile_sha256=profile_sha256, result=result)
    current_v2 = (profile_id == V2_PROFILE_ID and
                  transport['raw_cleanup']['schema_version'] == 3)
    closure_name = 'protected-anchor-closure.json'
    expected = set(by_name) | {'recovery-inventory.json', 'transport.json'}
    if current_v2:
        if closure_name in by_name:
            raise ValueError('Protected anchor closure is controller-owned, not observer inventory.')
        expected.add(closure_name)
    if actual != expected:
        raise ValueError('Recovery collection inventory is not complete.')
    if current_v2:
        closure_path = root / closure_name
        closure_info = closure_path.lstat()
        if (not stat.S_ISREG(closure_info.st_mode) or
                not 0 < closure_info.st_size <= 1024 * 1024):
            raise ValueError('Protected anchor closure is not an ordinary bounded file.')
        closure = read_json_strict(closure_path, maximum_bytes=1024 * 1024)
        held = transport['raw_cleanup']['owned_resource_evidence']['protected_anchor']
        final = transport.get('protected_anchor_final')
        remoting_fields = {'PSComputerName', 'RunspaceId', 'PSShowComputerName'}
        try:
            exact_anchor = (isinstance(final, dict) and
                            json.dumps({key: final[key] for key in held}, sort_keys=True,
                                       allow_nan=False) ==
                            json.dumps(held, sort_keys=True, allow_nan=False) and
                            json.dumps(closure, sort_keys=True, allow_nan=False) ==
                            json.dumps(final, sort_keys=True, allow_nan=False))
        except (KeyError, TypeError, ValueError):
            exact_anchor = False
        if (not isinstance(final, dict) or
                set(final) != set(held) | remoting_fields or
                not isinstance(final['PSComputerName'], str) or
                not 0 < len(final['PSComputerName']) <= 512 or
                not isinstance(final['RunspaceId'], str) or
                re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',
                             final['RunspaceId']) is None or
                type(final['PSShowComputerName']) is not bool or
                not exact_anchor):
            raise ValueError('Protected anchor closure differs from trusted final transport.')
    return result


def main(repo, argv=None, tooling=None):
    repo = Path(repo)
    args = parse_arguments(argv)
    if args.acceptance_profile_id == V2_PROFILE_ID:
        profile_path = repo / 'config' / 'vm-automated-v2.json'
        profile = read_json_strict(profile_path, maximum_bytes=1024 * 1024)
        if (not isinstance(profile, dict) or
                profile.get('schema') != 'darkrenamer-vm-automated-profile-v3' or
                profile.get('profile_id') != V2_PROFILE_ID or
                type(profile.get('revision')) is not int or profile['revision'] != 3):
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
    if args.virtual_execution_count is not None:
        root, defaults, pwsh = prepare_transport(repo, args)
        manifest = build_bundle(
            repo, root, tooling,
            virtual_execution=(args.virtual_execution_count, args.virtual_execution_iteration))
        args.expected_bundle_manifest_sha256 = sha256(root / 'bundle.json')
        print('Executing durable VM benchmark; evidence=' + str(root), flush=True)
        transport_ok = True
        try:
            run_controller(root, args, defaults, pwsh)
        except subprocess.CalledProcessError:
            transport_ok = False
        result_path = root / 'result.json'
        if not result_path.is_file():
            raise RuntimeError('The virtual execution returned no test result; inspect retained transport evidence.')
        result = read_json_strict(result_path, maximum_bytes=CORE_RESULT_MAXIMUM_BYTES)
        observed = verify_virtual_execution_result(
            root, manifest, result, 'ssh' if args.ssh_host else 'powershell_direct',
            args.expected_vm_id, args.acceptance_profile_sha256)
        print(('PASS' if transport_ok else 'FAIL') + ': durable virtual execution; ' +
              str(args.virtual_execution_count) + ' verified files', flush=True)
        return 0 if transport_ok and observed['status'] == 'passed' else 1
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
