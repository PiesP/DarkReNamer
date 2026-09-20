#!/usr/bin/env python3
"""Verify private campaign bytes with trusted source and authenticated gate facts.

The hosted wrapper authenticates the independently supplied candidate, ingress,
and gate metadata before invoking this CLI. No archive member is executable.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

from vm_automated_binding import Candidate, decimal, sha, trusted_component_hashes
from vm_automated_evidence import (
    EvidenceError, FileReference, MAX_ARCHIVE_BYTES, MAX_MEMBER_BYTES, MAX_JSON_BYTES,
    _open_absolute_regular,
    load_bounded_json, open_indexed_evidence_archive, parse_bounded_json_bytes,
    read_referenced_file, require_exact_keys, require_int, serialize_canonical_statement,
)
from vm_automated_verifier import (
    EvidenceReader, canonical_digest, require, verify_authenticated_gate_metadata,
    verify_complete_campaign,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    for name in ('archive', 'candidate-handoff-root', 'trusted-source-root', 'gate-metadata', 'output'):
        result.add_argument('--' + name, type=Path, required=True)
    for name in ('archive-sha256', 'archive-size', 'candidate-run-id', 'candidate-run-attempt',
                 'candidate-artifact-id', 'candidate-source-sha', 'expected-exe-sha256',
                 'release-id', 'asset-id', 'validation-run-id', 'validation-run-attempt'):
        result.add_argument('--' + name, required=True)
    return result


def validate(args: argparse.Namespace) -> bytes:
    source_sha = sha(args.candidate_source_sha, 40)
    archive_digest = sha(args.archive_sha256, 64)
    archive_size = int(decimal(args.archive_size))
    require_int(archive_size, 1, MAX_ARCHIVE_BYTES, 'Archive size')
    source = args.trusted_source_root.resolve(strict=True)
    components = trusted_component_hashes(source, source_sha)
    profile_path = 'config/vm-automated-v1.json'
    entry = subprocess.check_output(['git', 'ls-tree', source_sha, '--', profile_path], cwd=source, text=True).strip()
    require(entry.startswith('100644 blob ') and entry.endswith('\t' + profile_path),
            'Required profile is not an ordinary trusted source blob.')
    profile_bytes = subprocess.check_output(['git', 'show', source_sha + ':' + profile_path], cwd=source)
    profile = parse_bounded_json_bytes(profile_bytes, label='trusted profile')
    profile_digest = hashlib.sha256(profile_bytes).hexdigest()

    handoff_root = args.candidate_handoff_root.resolve(strict=True)
    handoff_path = handoff_root / 'release-handoff.json'
    with _open_absolute_regular(handoff_path) as stream:
        handoff_bytes = stream.read(MAX_JSON_BYTES + 1)
    handoff = parse_bounded_json_bytes(handoff_bytes, label="independent handoff")
    require_exact_keys(handoff, {'schema_version', 'source_sha', 'workflow_run', 'executable'}, 'Independent handoff')
    require_int(handoff['schema_version'], 1, 1, 'Handoff schema')
    require(handoff['source_sha'] == source_sha and str(handoff['workflow_run']) == args.candidate_run_id,
            'Independent handoff source/run differs from the selected candidate.')
    executable = require_exact_keys(handoff['executable'], {'filename', 'sha256'}, 'Independent executable')
    require(executable == {'filename': 'DarkReNamer.exe', 'sha256': sha(args.expected_exe_sha256, 64)},
            'Independent executable binding differs from the selected candidate.')
    executable_path = handoff_root / 'DarkReNamer.exe'
    read_referenced_file(handoff_root, 'DarkReNamer.exe',
                         FileReference(args.expected_exe_sha256, executable_path.stat().st_size),
                         max_bytes=MAX_MEMBER_BYTES)
    candidate = Candidate(source_sha, args.candidate_run_id, args.candidate_run_attempt,
                          args.candidate_artifact_id, args.expected_exe_sha256,
                          hashlib.sha256(handoff_bytes).hexdigest())
    gates = verify_authenticated_gate_metadata(load_bounded_json(args.gate_metadata), candidate)
    ingress = {'release_id': int(decimal(args.release_id)), 'asset_id': int(decimal(args.asset_id)),
               'sha256': archive_digest, 'size': archive_size}
    validation = {'run_id': int(decimal(args.validation_run_id)),
                  'run_attempt': int(decimal(args.validation_run_attempt))}
    # The wrapper owns this private parent and removes it before attestation.
    with open_indexed_evidence_archive(args.archive, FileReference(archive_digest, archive_size),
                                       args.archive.resolve(strict=True).parent) as extracted:
        verified = verify_complete_campaign(EvidenceReader(extracted), profile=profile,
                    profile_sha256=profile_digest, candidate=candidate, component_hashes=components)
    binding_digest = canonical_digest({'candidate': candidate.__dict__, 'ingress': ingress,
                                       'validation': validation, 'source_sha': source_sha})
    gate_digests = {
        'locked-host-gate': gates['locked_host_gate_sha256'],
        'windows-backend-source-bound': verified['backend_sha256'],
        'candidate-package-and-provenance': gates['candidate_gate_sha256'],
        'profile-raw-evidence-verifier': verified['profile_evidence_sha256'],
        'immutable-promotion-binding': binding_digest,
    }
    statement = {
        'schema': 'darkrenamer-vm-automated-statement-v1', 'result': 'passed',
        'candidate': {'repository': 'PiesP/DarkReNamer', 'source_sha': source_sha,
                      'run_id': int(candidate.workflow_run), 'run_attempt': int(candidate.run_attempt),
                      'artifact_id': int(candidate.artifact_id), 'artifact_sha256': gates['artifact_sha256'],
                      'executable_sha256': candidate.executable_sha256, 'handoff_sha256': candidate.handoff_sha256},
        'harness': {'repository': 'PiesP/DarkReNamer', 'source_sha': source_sha,
                    'components': [{'role': role, 'sha256': digest} for role, digest in components.items()]},
        'profile': {'id': profile['profile_id'], 'revision': profile['revision'], 'sha256': profile_digest},
        'environment': profile['environment'],
        'targets': [{'id': row['id'], 'verdict': 'passed'} for row in profile['required_targets']],
        'required_gates': [{'id': name, 'sha256': digest} for name, digest in gate_digests.items()],
        'ingress': ingress, 'validation': validation,
    }
    return serialize_canonical_statement(statement)


def main() -> int:
    args = parser().parse_args()
    try:
        # Output is newly created only after all checks and private extraction
        # cleanup succeed; no attacker-supplied statement is copied from input.
        output = args.output.absolute()
        require(not output.exists() and not output.is_symlink(), 'Statement output already exists.')
        require(not output.parent.resolve(strict=True).is_relative_to(args.archive.resolve(strict=True).parent),
                'Public statement output must be outside private archive scratch.')
        statement = validate(args)
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(statement)
            stream.flush()
            os.fsync(stream.fileno())
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('VM-automated evidence verification failed closed.', file=sys.stderr)
        return 1
    print('VM-automated full profile verified; canonical statement created.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
