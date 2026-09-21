#!/usr/bin/env python3
"""Negative authority-binding tests; no network or actual signature generation."""

import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

from darkrenamer_tooling.contracts import authority
REPO = 'PiesP/DarkReNamer'
SOURCE = 'a' * 40
DIGEST = 'b' * 64
OWNER = {'id': 17, 'login': 'PiesP', 'type': 'User'}
REPOSITORY = {'id': 29, 'full_name': REPO, 'owner': OWNER}


class AuthorityTests(unittest.TestCase):
    def ingress_fixture(self):
        asset = {'id': 41, 'size': 100, 'name': 'vm-automated-' + DIGEST + '.zip',
                 'state': 'uploaded', 'content_type': 'application/zip', 'digest': 'sha256:' + DIGEST,
                 'url': 'https://api.github.com/repos/' + REPO + '/releases/assets/41',
                 'uploader': copy.deepcopy(OWNER)}
        release = {'id': 37, 'draft': True, 'prerelease': True, 'published_at': None,
                   'target_commitish': SOURCE, 'tag_name': 'vm-validation-' + SOURCE + '-' + 'c' * 32,
                   'url': 'https://api.github.com/repos/' + REPO + '/releases/37',
                   'author': copy.deepcopy(OWNER), 'assets': [copy.deepcopy(asset)]}
        return release, asset

    def check_ingress(self, release, asset, **overrides):
        arguments = dict(expected_repository=REPO, source_sha=SOURCE, release_id='37',
                         asset_id='41', asset_sha256=DIGEST, asset_size='100')
        arguments.update(overrides)
        authority.validate_ingress(REPOSITORY, release, asset, **arguments)

    def run_fixture(self):
        repo = {'id': 29, 'full_name': REPO}
        run = {'id': 43, 'run_attempt': 2, 'path': authority.WORKFLOW,
               'head_branch': 'master', 'head_sha': SOURCE, 'event': 'workflow_dispatch',
               'status': 'completed', 'conclusion': 'success', 'repository': repo,
               'head_repository': copy.deepcopy(repo)}
        uri = 'https://github.com/' + REPO
        signer = uri + '/' + authority.WORKFLOW + '@refs/heads/master'
        certificate = {
            'issuer': 'https://token.actions.githubusercontent.com', 'subjectAlternativeName': signer,
            'buildSignerURI': signer, 'buildSignerDigest': SOURCE, 'runnerEnvironment': 'github-hosted',
            'sourceRepositoryURI': uri, 'sourceRepositoryDigest': SOURCE,
            'sourceRepositoryRef': 'refs/heads/master', 'sourceRepositoryIdentifier': '29',
            'sourceRepositoryOwnerIdentifier': '17', 'buildTrigger': 'workflow_dispatch',
            'runInvocationURI': uri + '/actions/runs/43/attempts/2',
        }
        rows = [{'verificationResult': {'signature': {'certificate': certificate}, 'statement': {
            '_type': 'https://in-toto.io/Statement/v1', 'predicateType': 'https://slsa.dev/provenance/v1',
            'subject': [{'name': 'validation-statement.json', 'digest': {'sha256': DIGEST}}],
            'predicate': {'runInvocationURI': 'intentionally-untrusted'},
        }}}]
        return run, rows

    def check_run(self, run, rows, **overrides):
        arguments = dict(expected_repository=REPO, source_sha=SOURCE, run_id='43',
                         run_attempt='2', statement_sha256=DIGEST)
        arguments.update(overrides)
        return authority.validate_run_authority(REPOSITORY, run, rows, **arguments)

    def test_dedicated_private_draft_asset(self):
        self.check_ingress(*self.ingress_fixture())

    def test_published_or_wrong_source_draft_is_rejected(self):
        for field, bad in [('draft', False), ('draft', 1), ('prerelease', False),
                           ('published_at', '2026-09-20T00:00:00Z'), ('target_commitish', 'master'),
                           ('tag_name', 'v0.1.1'), ('id', True), ('id', 37.0)]:
            with self.subTest(field=field, bad=bad):
                release, asset = self.ingress_fixture()
                release[field] = bad
                with self.assertRaises(ValueError):
                    self.check_ingress(release, asset)

    def test_owner_identity_and_release_membership_are_required(self):
        for kind in ('author', 'uploader', 'membership', 'duplicate'):
            release, asset = self.ingress_fixture()
            if kind == 'author':
                release['author']['id'] = 99
            elif kind == 'uploader':
                asset['uploader']['login'] = 'someone-else'
            elif kind == 'membership':
                release['assets'][0]['id'] = 99
            else:
                release['assets'].append(copy.deepcopy(asset))
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.check_ingress(release, asset)

    def test_each_asset_pin_is_required(self):
        mutations = [('id', 42), ('id', True), ('size', 99), ('size', 100.0),
                     ('name', 'arbitrary.zip'), ('state', 'new'), ('content_type', 'text/plain'),
                     ('digest', 'sha256:' + 'd' * 64), ('url', 'https://example.com/41')]
        for field, bad in mutations:
            release, asset = self.ingress_fixture()
            asset[field] = bad
            release['assets'] = [copy.deepcopy(asset)]
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check_ingress(release, asset)

    def test_invalid_cli_pin_types_and_bounds_are_rejected(self):
        for name, value in [('asset_id', True), ('release_id', '01'), ('asset_size', '1e2'),
                            ('asset_size', str(authority.MAX_ARCHIVE_BYTES + 1)),
                            ('asset_id', str(2**63)), ('source_sha', 'A' * 40),
                            ('asset_sha256', '../escape')]:
            with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                self.check_ingress(*self.ingress_fixture(), **{name: value})

    def test_archive_bytes_are_checked_independently_of_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'archive.zip'
            path.write_bytes(b'archive sentinel')
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            size = str(path.stat().st_size)
            authority.verify_archive_bytes(path, sha, size)
            for wrong_sha, wrong_size in [(DIGEST, size), (sha, '1'), (sha, str(int(size) + 1))]:
                with self.assertRaises(ValueError):
                    authority.verify_archive_bytes(path, wrong_sha, wrong_size)
            link = Path(root) / 'link.zip'
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                authority.verify_archive_bytes(link, sha, size)

    def test_exact_successful_run_and_certificate(self):
        self.assertTrue(self.check_run(*self.run_fixture()).endswith('/43/attempts/2'))

    def test_predicate_cannot_supply_certificate_authority(self):
        run, rows = self.run_fixture()
        uri = rows[0]['verificationResult']['signature']['certificate'].pop('runInvocationURI')
        rows[0]['verificationResult']['statement']['predicate']['runInvocationURI'] = uri
        with self.assertRaisesRegex(ValueError, 'No verified attestation'):
            self.check_run(run, rows)

    def test_prior_attempt_or_other_workflow_does_not_authorize(self):
        for key, value in [('runInvocationURI', 'https://github.com/' + REPO + '/actions/runs/43/attempts/1'),
                           ('buildSignerDigest', 'd' * 40), ('runnerEnvironment', 'self-hosted'),
                           ('sourceRepositoryRef', 'refs/heads/feature'), ('buildSignerURI', 'another-workflow'),
                           ('sourceRepositoryIdentifier', '99'), ('sourceRepositoryOwnerIdentifier', '99')]:
            run, rows = self.run_fixture()
            rows[0]['verificationResult']['signature']['certificate'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check_run(run, rows)

    def test_failed_or_incomplete_exact_attempt_never_passes(self):
        for key, value in [('conclusion', 'failure'), ('conclusion', None), ('status', 'in_progress'),
                           ('run_attempt', 1), ('run_attempt', True), ('run_attempt', 2.0),
                           ('head_sha', 'd' * 40), ('head_branch', 'feature'), ('event', 'pull_request'),
                           ('path', '.github/workflows/release.yaml')]:
            run, rows = self.run_fixture()
            run[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check_run(run, rows)

    def test_fork_identity_is_rejected(self):
        run, rows = self.run_fixture()
        run['head_repository']['id'] = 99
        with self.assertRaises(ValueError):
            self.check_run(run, rows)

    def test_subject_must_match_actual_statement(self):
        for subject in [[], [{'name': 'raw.zip', 'digest': {'sha256': DIGEST}}],
                        [{'name': 'validation-statement.json', 'digest': {'sha256': 'd' * 64}}]]:
            run, rows = self.run_fixture()
            rows[0]['verificationResult']['statement']['subject'] = subject
            with self.assertRaises(ValueError):
                self.check_run(run, rows)

    def test_equivalent_verified_rows_and_unrelated_retries(self):
        run, rows = self.run_fixture()
        other = copy.deepcopy(rows[0])
        other['verificationResult']['signature']['certificate']['runInvocationURI'] = (
            'https://github.com/' + REPO + '/actions/runs/43/attempts/1')
        self.check_run(run, [other, rows[0], copy.deepcopy(rows[0])])

    def test_ambiguous_matching_certificate_is_rejected(self):
        run, rows = self.run_fixture()
        other = copy.deepcopy(rows[0])
        other['verificationResult']['signature']['certificate']['buildSignerDigest'] = 'd' * 40
        with self.assertRaises(ValueError):
            self.check_run(run, rows + [other])

    def test_raw_bundle_without_verified_output_is_rejected(self):
        run, _ = self.run_fixture()
        for rows in [[], {}, [{'bundle': {'certificate': 'unverified'}}]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.check_run(run, rows)

    def test_duplicate_nonfinite_and_malformed_json(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'metadata.json'
            for data in [b'{"draft":false,"draft":true}', b'{"n":NaN}', b'{"n":Infinity}', b'\xff', b'{']:
                path.write_bytes(data)
                with self.subTest(data=data), self.assertRaises(ValueError):
                    authority.read_json(path)


if __name__ == '__main__':
    unittest.main()
