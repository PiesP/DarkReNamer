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
import uuid

TARGET = 'x86_64-pc-windows-msvc'
POWERSHELL = Path('/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe')


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def psquote(value):
    return "'" + str(value).replace("'", "''") + "'"


def host_command(script, capture=True):
    prelude = '$ErrorActionPreference="Stop"; $env:PSModulePath="$PSHOME\\Modules;C:\\Program Files\\WindowsPowerShell\\Modules"; '
    return subprocess.run(
        [str(POWERSHELL), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-Command', prelude + script],
        cwd='/mnt/c', text=True, check=True, stdout=subprocess.PIPE if capture else None,
    ).stdout


def winpath(path):
    return subprocess.check_output(['wslpath', '-w', str(path)], text=True).strip()


def leaf(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,159}', value) or value in ('.', '..'):
        raise ValueError('Artifact names must be plain ASCII file names.')
    return value


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


def verify_result(root, manifest, result):
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
    if gui.get('status') != 'passed':
        passed = False
    else:
        screenshot = checked_artifact(root, gui['screenshot'])
        with screenshot.open('rb') as stream:
            if stream.read(8) != b'\x89PNG\r\n\x1a\n':
                raise ValueError('GUI screenshot is not a PNG.')
    if not result.get('transport', {}).get('guest_cleanup') or total == 0:
        passed = False
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm-name', required=True, help='Existing local Hyper-V VM with an unlocked test-user desktop.')
    parser.add_argument('--credential-helper', help='Windows path to a private helper returning PSCredential with -Action Load.')
    parser.add_argument('--output', type=Path, help='New external Windows-backed WSL directory for the bundle, logs, and screenshots.')
    parser.add_argument('--test-timeout-seconds', type=int, default=300)
    args = parser.parse_args()
    if not 10 <= args.test_timeout_seconds <= 1800:
        parser.error('Test timeout must be between 10 and 1800 seconds.')
    repo = Path(__file__).resolve().parent.parent
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True).strip():
        raise RuntimeError('Commit or preserve checkout changes before VM verification; results must bind a clean source SHA.')
    source_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    defaults = json.loads(host_command('[pscustomobject]@{temp=[IO.Path]::GetTempPath();helper=(Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "DarkReNamerVmTools\\auth\\credential-store.ps1")} | ConvertTo-Json -Compress'))
    if args.output:
        root = args.output
        if not root.is_absolute():
            parser.error('Output must be an absolute external path.')
    else:
        host_temp = subprocess.check_output(['wslpath', '-u', defaults['temp']], text=True).strip()
        root = Path(host_temp) / ('DarkReNamer-native-' + uuid.uuid4().hex)
    if root.exists() or root.is_symlink() or root.resolve().is_relative_to(repo):
        raise RuntimeError('Output must be a new directory outside the checkout.')
    windows_root = winpath(root)
    if windows_root.startswith('\\\\'):
        raise RuntimeError('Output must be on a Windows drive, not a WSL network path.')
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
    helper = args.credential_helper or defaults['helper']
    transport = '& ' + psquote(winpath(root / 'run-windows-vm-tests.ps1')) + ' -BundleRoot ' + psquote(windows_root) + ' -VmName ' + psquote(args.vm_name) + ' -CredentialHelper ' + psquote(helper) + ' -TestTimeoutSeconds ' + str(args.test_timeout_seconds)
    print('Executing ' + str(len(artifacts)) + ' Windows test binaries in the VM.', flush=True)
    print('Evidence: ' + str(root), flush=True)
    transport_ok = True
    try:
        host_command(transport, capture=False)
    except subprocess.CalledProcessError:
        transport_ok = False
    result_path = root / 'result.json'
    if not result_path.is_file():
        raise RuntimeError('The VM did not return a test result. Inspect the external transport result/logs.')
    result = json.loads(result_path.read_text(encoding='utf-8-sig'))
    verified = verify_result(root, manifest, result)
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
