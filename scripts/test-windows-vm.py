#!/usr/bin/env python3
"""Build the current checkout's Windows tests and execute them in a Hyper-V VM."""
import argparse
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


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def psquote(value):
    return "'" + str(value).replace("'", "''") + "'"


def windows_host_command(script, capture=True):
    prelude = '$ErrorActionPreference="Stop"; $env:PSModulePath="$PSHOME\\Modules;C:\\Program Files\\WindowsPowerShell\\Modules"; '
    return subprocess.run(
        [str(POWERSHELL), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-Command', prelude + script],
        cwd='/mnt/c', text=True, check=True, stdout=subprocess.PIPE if capture else None,
    ).stdout


def require_pwsh7():
    executable = shutil.which('pwsh')
    if not executable:
        raise RuntimeError('SSH transport requires PowerShell 7 or newer as pwsh on PATH.')
    version = subprocess.check_output(
        [executable, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'],
        text=True,
    ).strip()
    if not version.isdecimal() or int(version) < 7:
        raise RuntimeError('SSH transport requires PowerShell 7 or newer as pwsh on PATH.')
    return executable


def winpath(path):
    return subprocess.check_output(['wslpath', '-w', str(path)], text=True).strip()


def leaf(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,159}', value) or value in ('.', '..'):
        raise ValueError('Artifact names must be plain ASCII file names.')
    return value


def argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    transport = parser.add_mutually_exclusive_group(required=True)
    transport.add_argument('--vm-name', help='Existing local Hyper-V VM with an unlocked test-user desktop.')
    transport.add_argument('--ssh-host', help='OpenSSH config alias for the configured VM test account.')
    parser.add_argument('--credential-helper', help='Windows path to a private helper returning PSCredential with -Action Load.')
    parser.add_argument('--output', type=Path, help='New external directory for the bundle, logs, and screenshots.')
    parser.add_argument('--test-timeout-seconds', type=int, default=300)
    return parser


def parse_arguments(argv=None):
    parser = argument_parser()
    args = parser.parse_args(argv)
    if args.ssh_host and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', args.ssh_host):
        parser.error('--ssh-host must be a 1-128 character OpenSSH config alias using letters, digits, dot, underscore, or hyphen.')
    if args.ssh_host and args.credential_helper:
        parser.error('--credential-helper can only be used with --vm-name PowerShell Direct transport.')
    if not 10 <= args.test_timeout_seconds <= 1800:
        parser.error('Test timeout must be between 10 and 1800 seconds.')
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


def prepare_transport(repo, args):
    if args.ssh_host:
        pwsh = require_pwsh7()
        defaults = None
    else:
        pwsh = None
        defaults = windows_host_defaults()
    return resolve_output_root(repo, args, defaults), defaults, pwsh


def controller_invocation(root, args, defaults=None, pwsh=None):
    script = root / 'run-windows-vm-tests.ps1'
    common = ['-TestTimeoutSeconds', str(args.test_timeout_seconds)]
    if args.ssh_host:
        executable = pwsh or require_pwsh7()
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
    transport = (
        '& ' + psquote(winpath(script)) + ' -BundleRoot ' + psquote(windows_root)
        + ' -VmName ' + psquote(args.vm_name) + ' -CredentialHelper ' + psquote(helper)
        + ' -TestTimeoutSeconds ' + str(args.test_timeout_seconds)
    )
    prelude = '$ErrorActionPreference="Stop"; $env:PSModulePath="$PSHOME\\Modules;C:\\Program Files\\WindowsPowerShell\\Modules"; '
    return [
        str(POWERSHELL), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned',
        '-Command', prelude + transport,
    ]


def run_controller(root, args, defaults=None, pwsh=None):
    command = controller_invocation(root, args, defaults, pwsh)
    cwd = root if args.ssh_host else Path('/mnt/c')
    subprocess.run(command, cwd=cwd, text=True, check=True)


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


def verify_result(root, manifest, result, expected_transport_kind=None):
    for key in ('schema_version', 'source_sha', 'source_state', 'target'):
        if result.get(key) != manifest[key]:
            raise ValueError('VM result source binding mismatch: ' + key)
    expected = {row['file']: row for row in manifest['test_binaries']}
    rows = result.get('tests', [])
    if len(rows) != len(expected) or {row['file'] for row in rows} != set(expected):
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
    checked_artifact(root, manifest['application'])
    gui = result.get('gui', {})
    if gui.get('file') != manifest['application']['file'] or gui.get('sha256') != manifest['application']['sha256']:
        raise ValueError('VM GUI result differs from the application artifact.')
    if gui.get('status') != 'passed':
        passed = False
    else:
        screenshot = checked_artifact(root, gui['screenshot'])
        with screenshot.open('rb') as stream:
            if stream.read(8) != b'\x89PNG\r\n\x1a\n':
                raise ValueError('GUI screenshot is not a PNG.')
    transport = result.get('transport', {})
    if transport.get('guest_cleanup') is not True or total == 0:
        passed = False
    if expected_transport_kind is not None:
        expected_platform = 'Unix' if expected_transport_kind == 'ssh' else 'Win32NT'
        if transport.get('kind') != expected_transport_kind or transport.get('host_platform') != expected_platform:
            raise ValueError('VM result transport binding mismatch.')
    return passed


def main():
    args = parse_arguments()
    repo = Path(__file__).resolve().parent.parent
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True).strip():
        raise RuntimeError('Commit or preserve checkout changes before VM verification; results must bind a clean source SHA.')
    source_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    root, defaults, pwsh = prepare_transport(repo, args)
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
    for name in ('windows-vm-guest.ps1', 'run-windows-vm-tests.ps1'):
        shutil.copyfile(repo / 'scripts' / name, root / name)
    manifest = {
        'schema_version': 1, 'source_sha': source_sha, 'source_state': 'clean', 'target': TARGET,
        'cargo_lock_sha256': sha256(repo / 'Cargo.lock'), 'test_binaries': artifacts,
        'application': {'file': 'DarkReNamer.exe', 'sha256': sha256(root / 'DarkReNamer.exe')},
        'runner': {'file': 'windows-vm-guest.ps1', 'sha256': sha256(root / 'windows-vm-guest.ps1')},
    }
    (root / 'bundle.json').write_text(json.dumps(manifest, indent=2))
    print('Executing ' + str(len(artifacts)) + ' Windows test binaries in the VM.', flush=True)
    print('Evidence: ' + str(root), flush=True)
    transport_ok = True
    try:
        run_controller(root, args, defaults, pwsh)
    except subprocess.CalledProcessError:
        transport_ok = False
    result_path = root / 'result.json'
    if not result_path.is_file():
        raise RuntimeError('The VM did not return a test result. Inspect the external transport result/logs.')
    result = json.loads(result_path.read_text(encoding='utf-8-sig'))
    transport_kind = 'ssh' if args.ssh_host else 'powershell_direct'
    verified = verify_result(root, manifest, result, transport_kind)
    total = sum(row.get('passed') or 0 for row in result['tests'])
    print(('PASS' if transport_ok and verified else 'FAIL') + ': ' + str(total) + ' tests passed; GUI=' + result.get('gui', {}).get('status', 'not-run'))
    print('This native VM run is not the complete Windows release acceptance matrix.')
    return 0 if transport_ok and verified else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
