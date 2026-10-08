#!/usr/bin/env python3
"""Synthetic candidate provenance and public release readback regressions."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "validate-release-publication.py"
SPEC = importlib.util.spec_from_file_location("release_publication", SCRIPT)
publication = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publication)
REPO = "PiesP/DarkReNamer"
SOURCE = "a" * 40


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.candidate = self.root / "candidate"
        self.verified = self.root / "verified"
        self.downloaded = self.root / "downloaded"
        for directory in (self.candidate, self.verified, self.downloaded):
            directory.mkdir()
        self.statement = self.root / publication.VALIDATION_ASSET
        self.statement.write_bytes(b"hosted statement")
        self.release_metadata = self.root / "release.json"
        for name in publication.CANDIDATE_ASSETS:
            (self.candidate / name).write_bytes(name.encode())
        (self.candidate / "DarkReNamer.pdb").write_bytes(b"private raw symbols")
        self.write_verified()
        self.write_public()

    def row(self, name):
        uri = f"https://github.com/{REPO}"
        signer = f"{uri}/.github/workflows/release.yaml@refs/heads/master"
        return {"verificationResult": {
            "signature": {"certificate": {
                "issuer": "https://token.actions.githubusercontent.com",
                "subjectAlternativeName": signer, "buildSignerURI": signer,
                "buildSignerDigest": SOURCE, "runnerEnvironment": "github-hosted",
                "sourceRepositoryURI": uri, "sourceRepositoryDigest": SOURCE,
                "sourceRepositoryRef": "refs/heads/master", "buildTrigger": "workflow_dispatch",
                "runInvocationURI": f"{uri}/actions/runs/10/attempts/2",
            }},
            "statement": {"_type": publication.STATEMENT_TYPE,
                          "predicateType": publication.PREDICATE_TYPE,
                          "subject": [{"name": name, "digest": {
                              "sha256": publication.digest(self.candidate / name)}}]},
        }}

    def write_verified(self):
        for index, name in enumerate(publication.CANDIDATE_ASSETS):
            (self.verified / f"{index}.json").write_text(json.dumps([self.row(name)]))

    def write_public(self):
        expected = publication.expected_paths(self.candidate, self.statement)
        assets = []
        for index, (name, source) in enumerate(expected.items(), 1):
            (self.downloaded / name).write_bytes(source.read_bytes())
            assets.append({"id": index, "name": name, "state": "uploaded",
                           "size": source.stat().st_size})
        self.release_metadata.write_text(json.dumps({"tag_name": "v0.2.0",
                                                     "draft": False, "assets": assets}))

    def candidate_ok(self):
        publication.verify_candidate(self.candidate, self.verified, REPO, SOURCE, "10", "2")

    def public_ok(self):
        publication.verify_public_readback(self.candidate, self.statement,
                                           self.release_metadata, self.downloaded, "v0.2.0")

    def test_complete_candidate_and_public_readback(self):
        self.candidate_ok()
        self.public_ok()
        self.assertIn("SHA256SUMS.txt", publication.CANDIDATE_ASSETS)
        self.assertIn("release-metrics.json", publication.CANDIDATE_ASSETS)
        self.assertNotIn(publication.VALIDATION_ASSET, publication.CANDIDATE_ASSETS)

    def test_verified_multi_subject_handoff_includes_raw_pdb(self):
        for index, name in enumerate(publication.CANDIDATE_ASSETS):
            row = self.row(name)
            row["verificationResult"]["statement"]["subject"] = [
                {"name": subject, "digest": {
                    "sha256": publication.digest(self.candidate / subject)}}
                for subject in sorted(publication.HANDOFF_ASSETS)
            ]
            (self.verified / f"{index}.json").write_text(json.dumps([row]))
        self.candidate_ok()

    def test_other_run_attestation_is_ignored_when_exact_attempt_exists(self):
        name = publication.CANDIDATE_ASSETS[0]
        other = self.row(name)
        other["verificationResult"]["signature"]["certificate"]["runInvocationURI"] = (
            f"https://github.com/{REPO}/actions/runs/11/attempts/2")
        (self.verified / "0.json").write_text(json.dumps([other, self.row(name)]))
        self.candidate_ok()

    def test_recomputed_local_checksums_do_not_replace_auxiliary_provenance(self):
        (self.candidate / "THIRD_PARTY_LICENSES.html").write_bytes(b"modified")
        (self.candidate / "SHA256SUMS.txt").write_bytes(b"recomputed")
        with self.assertRaisesRegex(ValueError, "subject or predicate"):
            self.candidate_ok()

    def test_missing_wrong_authority_predicate_and_subject_fail(self):
        name = publication.CANDIDATE_ASSETS[0]
        index = 0
        path = self.verified / f"{index}.json"
        path.unlink()
        with self.assertRaisesRegex(ValueError, "output set"):
            self.candidate_ok()
        for change, fragment in (
            (lambda row: row["verificationResult"]["signature"]["certificate"].update(
                runInvocationURI=f"https://github.com/{REPO}/actions/runs/11/attempts/2"),
             "provenance is missing"),
            (lambda row: row["verificationResult"]["signature"]["certificate"].update(
                buildSignerURI="wrong signer"), "authority"),
            (lambda row: row["verificationResult"]["signature"]["certificate"].update(
                sourceRepositoryDigest="b" * 40), "authority"),
            (lambda row: row["verificationResult"]["statement"].update(
                predicateType="https://spdx.dev/Document"), "predicate"),
            (lambda row: row["verificationResult"]["statement"].update(
                subject=[]), "subject"),
            (lambda row: row["verificationResult"]["statement"]["subject"].append(
                {"name": "extra", "digest": {"sha256": "f" * 64}}), "subject"),
        ):
            with self.subTest(fragment=fragment):
                row = self.row(name)
                change(row)
                path.write_text(json.dumps([row]))
                with self.assertRaisesRegex(ValueError, fragment):
                    self.candidate_ok()

    def test_public_missing_extra_and_wrong_digest_fail(self):
        name = publication.CANDIDATE_ASSETS[0]
        (self.downloaded / name).unlink()
        with self.assertRaisesRegex(ValueError, "Downloaded public release asset set"):
            self.public_ok()
        self.write_public()
        (self.downloaded / "extra.txt").write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "Downloaded public release asset set"):
            self.public_ok()
        (self.downloaded / "extra.txt").unlink()
        (self.downloaded / name).write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            self.public_ok()
        self.write_public()
        metadata = json.loads(self.release_metadata.read_text())
        metadata["assets"].append({"id": 99, "name": "extra.txt", "state": "uploaded", "size": 5})
        self.release_metadata.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, "names differ"):
            self.public_ok()


if __name__ == "__main__":
    unittest.main()
