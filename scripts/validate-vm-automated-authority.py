#!/usr/bin/env python3
"""Check GitHub metadata bindings after authenticated downloads and gh verification.

This helper does not authenticate caller-supplied JSON. Workflows must fetch the
exact REST endpoints and successfully run restricted `gh attestation verify`
before using these consistency checks. SLSA predicate values are not authority.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

WORKFLOW = '.github/workflows/vm-acceptance.yaml'
REF = 'refs/heads/master'
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def positive(value, label):
    require(type(value) is int and 0 < value < 2**63, label + ' must be a positive integer.')
    return str(value)


def pin(value, label):
    require(isinstance(value, str) and re.fullmatch(r'[1-9][0-9]{0,18}', value) is not None,
            label + ' must be a positive decimal string.')
    require(int(value) < 2**63, label + ' exceeds its bound.')
    return value


def digest(value, length, label):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{' + str(length) + '}', value) is not None,
            label + ' must be a lowercase digest.')
    return value


def object_value(value, label):
    require(isinstance(value, dict), label + ' must be an object.')
    return value


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON field.')
            result[key] = value
        return result

    def constant(_value):
        raise ValueError('Non-finite JSON constant.')

    with Path(path).open('rb') as stream:
        data = stream.read(MAX_JSON_BYTES + 1)
    require(len(data) <= MAX_JSON_BYTES, 'JSON exceeds its size bound.')
    try:
        return json.loads(data.decode('utf-8-sig'), object_pairs_hook=unique, parse_constant=constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError('Malformed bounded JSON.') from error


def repository_identity(repository, expected_repository):
    require(isinstance(expected_repository, str) and
            re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', expected_repository) is not None,
            'Repository name is invalid.')
    repository = object_value(repository, 'Repository metadata')
    require(repository.get('full_name') == expected_repository, 'Repository identity mismatch.')
    repository_id = positive(repository.get('id'), 'Repository ID')
    owner = object_value(repository.get('owner'), 'Repository owner')
    owner_id = positive(owner.get('id'), 'Repository owner ID')
    require(owner.get('login') == expected_repository.split('/')[0] and owner.get('type') == 'User',
            'The v1 private ingress requires the repository user owner.')
    return repository_id, owner_id


def owner_matches(actor, expected_login, owner_id):
    actor = object_value(actor, 'Ingress actor')
    require(actor.get('login') == expected_login and actor.get('type') == 'User' and
            positive(actor.get('id'), 'Ingress actor ID') == owner_id,
            'Private ingress must be authored and uploaded by the repository owner.')


def validate_ingress(repository, release, asset, *, expected_repository, source_sha,
                     release_id, asset_id, asset_sha256, asset_size):
    """Validate a dedicated never-published draft asset's authenticated metadata."""
    digest(source_sha, 40, 'Source SHA')
    digest(asset_sha256, 64, 'Asset SHA256')
    for value, label in ((release_id, 'Release ID'), (asset_id, 'Asset ID'), (asset_size, 'Asset size')):
        pin(value, label)
    require(int(asset_size) <= MAX_ARCHIVE_BYTES, 'Ingress archive exceeds its bound.')
    _, owner_id = repository_identity(repository, expected_repository)
    release = object_value(release, 'Release metadata')
    asset = object_value(asset, 'Asset metadata')
    require(positive(release.get('id'), 'Release ID') == release_id, 'Release ID mismatch.')
    require(release.get('draft') is True and release.get('prerelease') is True and
            release.get('published_at') is None, 'Ingress release must remain an unpublished draft prerelease.')
    require(release.get('target_commitish') == source_sha, 'Ingress release source mismatch.')
    require(isinstance(release.get('tag_name'), str) and re.fullmatch(
        'vm-validation-' + source_sha + r'-[0-9a-f]{32}', release['tag_name']) is not None,
        'Ingress release must use its dedicated validation tag namespace.')
    api_root = 'https://api.github.com/repos/' + expected_repository
    require(release.get('url') == api_root + '/releases/' + release_id, 'Release API identity mismatch.')
    owner_login = expected_repository.split('/')[0]
    owner_matches(release.get('author'), owner_login, owner_id)
    owner_matches(asset.get('uploader'), owner_login, owner_id)
    require(positive(asset.get('id'), 'Asset ID') == asset_id, 'Asset ID mismatch.')
    require(positive(asset.get('size'), 'Asset size') == asset_size, 'Asset size mismatch.')
    expected_name = 'vm-automated-' + asset_sha256 + '.zip'
    expected_asset_fields = {
        'name': expected_name, 'state': 'uploaded', 'content_type': 'application/zip',
        'digest': 'sha256:' + asset_sha256,
        'url': api_root + '/releases/assets/' + asset_id,
    }
    require(all(asset.get(key) == value for key, value in expected_asset_fields.items()),
            'Asset metadata differs from the pinned private archive.')
    listed = release.get('assets')
    require(isinstance(listed, list) and len(listed) == 1 and isinstance(listed[0], dict),
            'Dedicated ingress release must contain exactly one asset.')
    for key in ('id', 'size', 'name', 'state', 'content_type', 'digest', 'url', 'uploader'):
        require(type(listed[0].get(key)) is type(asset.get(key)) and listed[0].get(key) == asset.get(key),
                'Asset does not belong to the pinned release.')


def verify_archive_bytes(path, expected_sha256, expected_size):
    digest(expected_sha256, 64, 'Archive SHA256')
    pin(expected_size, 'Archive size')
    require(int(expected_size) <= MAX_ARCHIVE_BYTES, 'Ingress archive exceeds its bound.')
    path = Path(path)
    require(not path.is_symlink() and path.is_file(), 'Ingress archive must be an ordinary file.')
    algorithm = hashlib.sha256()
    count = 0
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            count += len(chunk)
            require(count <= int(expected_size), 'Downloaded archive exceeds pinned size.')
            algorithm.update(chunk)
    require(count == int(expected_size) and algorithm.hexdigest() == expected_sha256,
            'Downloaded archive digest or size mismatch.')


def validate_run_authority(repository, run, verified_attestations, *, expected_repository,
                           source_sha, run_id, run_attempt, statement_sha256):
    """Bind a verified subject to its exact successful hosted workflow attempt.

    The input must be stdout from a successful restricted gh attestation verify;
    parsing this structure alone is not signature verification.
    """
    digest(source_sha, 40, 'Source SHA')
    digest(statement_sha256, 64, 'Statement SHA256')
    pin(run_id, 'Validation run ID')
    pin(run_attempt, 'Validation run attempt')
    repository_id, owner_id = repository_identity(repository, expected_repository)
    run = object_value(run, 'Exact run attempt metadata')
    require(positive(run.get('id'), 'Run ID') == run_id and
            positive(run.get('run_attempt'), 'Run attempt') == run_attempt,
            'Validation run attempt mismatch.')
    expected_run = {'path': WORKFLOW, 'head_branch': 'master', 'head_sha': source_sha,
                    'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success'}
    require(all(run.get(key) == value for key, value in expected_run.items()),
            'Validation attempt must be successful at the pinned master source and workflow.')
    for key in ('repository', 'head_repository'):
        actual = object_value(run.get(key), 'Run ' + key)
        require(actual.get('full_name') == expected_repository and
                positive(actual.get('id'), 'Run repository ID') == repository_id,
                'Validation run repository mismatch.')
    repo_uri = 'https://github.com/' + expected_repository
    invocation = repo_uri + '/actions/runs/' + run_id + '/attempts/' + run_attempt
    signer = repo_uri + '/' + WORKFLOW + '@' + REF
    expected_certificate = {
        'issuer': 'https://token.actions.githubusercontent.com',
        'subjectAlternativeName': signer, 'buildSignerURI': signer,
        'buildSignerDigest': source_sha, 'runnerEnvironment': 'github-hosted',
        'sourceRepositoryURI': repo_uri, 'sourceRepositoryDigest': source_sha,
        'sourceRepositoryRef': REF, 'sourceRepositoryIdentifier': repository_id,
        'sourceRepositoryOwnerIdentifier': owner_id, 'buildTrigger': 'workflow_dispatch',
        'runInvocationURI': invocation,
    }
    require(isinstance(verified_attestations, list) and 0 < len(verified_attestations) <= 128,
            'Verified attestation output must be a bounded nonempty list.')
    matches = 0
    for row in verified_attestations:
        row = object_value(row, 'Verified attestation row')
        verified = object_value(row.get('verificationResult'), 'Verification result')
        signature = object_value(verified.get('signature'), 'Verified signature')
        certificate = object_value(signature.get('certificate'), 'Verified certificate')
        if certificate.get('runInvocationURI') != invocation:
            continue
        require(all(certificate.get(key) == value for key, value in expected_certificate.items()),
                'Verified certificate authority mismatch.')
        statement = object_value(verified.get('statement'), 'Verified statement')
        require(statement.get('_type') == 'https://in-toto.io/Statement/v1' and
                statement.get('predicateType') == 'https://slsa.dev/provenance/v1',
                'Verified statement type mismatch.')
        require(statement.get('subject') == [
            {'name': 'validation-statement.json', 'digest': {'sha256': statement_sha256}}
        ], 'Verified subject differs from the recomputed canonical statement.')
        matches += 1
    require(matches > 0, 'No verified attestation matches the exact validation run attempt.')
    return invocation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    ingress = commands.add_parser('ingress')
    authority = commands.add_parser('validation-run')
    for command in (ingress, authority):
        command.add_argument('--repository-metadata', type=Path, required=True)
        command.add_argument('--repository', required=True)
        command.add_argument('--source-sha', required=True)
    ingress.add_argument('--release-metadata', type=Path, required=True)
    ingress.add_argument('--asset-metadata', type=Path, required=True)
    ingress.add_argument('--release-id', required=True)
    ingress.add_argument('--asset-id', required=True)
    ingress.add_argument('--asset-sha256', required=True)
    ingress.add_argument('--asset-size', required=True)
    ingress.add_argument('--archive', type=Path, required=True)
    authority.add_argument('--run-metadata', type=Path, required=True)
    authority.add_argument('--verified-attestations', type=Path, required=True)
    authority.add_argument('--run-id', required=True)
    authority.add_argument('--run-attempt', required=True)
    authority.add_argument('--statement', type=Path, required=True)
    args = parser.parse_args()
    repository = read_json(args.repository_metadata)
    if args.command == 'ingress':
        validate_ingress(repository, read_json(args.release_metadata), read_json(args.asset_metadata),
                         expected_repository=args.repository, source_sha=args.source_sha,
                         release_id=args.release_id, asset_id=args.asset_id,
                         asset_sha256=args.asset_sha256, asset_size=args.asset_size)
        verify_archive_bytes(args.archive, args.asset_sha256, args.asset_size)
    else:
        require(args.statement.is_file() and not args.statement.is_symlink(), 'Statement must be an ordinary file.')
        with args.statement.open('rb') as stream:
            data = stream.read(MAX_JSON_BYTES + 1)
        require(len(data) <= MAX_JSON_BYTES, 'Statement exceeds its size bound.')
        validate_run_authority(repository, read_json(args.run_metadata), read_json(args.verified_attestations),
                               expected_repository=args.repository, source_sha=args.source_sha,
                               run_id=args.run_id, run_attempt=args.run_attempt,
                               statement_sha256=hashlib.sha256(data).hexdigest())
    print('GitHub authority bindings verified; raw evidence derivation remains a separate required gate.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
