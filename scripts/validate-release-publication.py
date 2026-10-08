#!/usr/bin/env python3
"""Validate candidate provenance and the exact public release file set."""

import argparse
import hashlib
import json
from pathlib import Path


# This is the sole promotion file list. The candidate handoff additionally retains
# the raw PDB, which is published only inside the debug-symbols ZIP.
CANDIDATE_ASSETS = (
    "DarkReNamer.exe",
    "DarkReNamer.cdx.json",
    "DarkReNamer-debug-symbols.zip",
    "SHA256SUMS.txt",
    "LICENSE",
    "THIRD_PARTY_LICENSES.html",
    "THIRD_PARTY_NOTICES.md",
    "DISTRIBUTION.md",
    "release-handoff.json",
    "release-metrics.json",
)
VALIDATION_ASSET = "validation-statement.json"
HANDOFF_ASSETS = frozenset((*CANDIDATE_ASSETS, "DarkReNamer.pdb"))
PREDICATE_TYPE = "https://slsa.dev/provenance/v1"
STATEMENT_TYPE = "https://in-toto.io/Statement/v1"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def expected_paths(candidate_root, statement):
    return {name: candidate_root / name for name in CANDIDATE_ASSETS} | {
        VALIDATION_ASSET: statement
    }


def verify_candidate(candidate_root, verified_root, repository, source_sha,
                     run_id, run_attempt):
    require(repository.count("/") == 1, "Invalid repository identity.")
    require(len(source_sha) == 40 and all(c in "0123456789abcdef" for c in source_sha),
            "Invalid candidate source SHA.")
    require(run_id.isdecimal() and int(run_id) > 0 and
            run_attempt.isdecimal() and int(run_attempt) > 0,
            "Invalid candidate run identity.")
    require({p.name for p in verified_root.iterdir()} ==
            {f"{index}.json" for index in range(len(CANDIDATE_ASSETS))},
            "Candidate verification output set differs from publication list.")
    uri = f"https://github.com/{repository}"
    signer = f"{uri}/.github/workflows/release.yaml@refs/heads/master"
    invocation = f"{uri}/actions/runs/{run_id}/attempts/{run_attempt}"
    for index, name in enumerate(CANDIDATE_ASSETS):
        path = candidate_root / name
        require(path.is_file() and not path.is_symlink(),
                f"Candidate publication file missing or unsupported: {name}")
        rows = read_json(verified_root / f"{index}.json")
        require(isinstance(rows, list) and 0 < len(rows) <= 128,
                f"No bounded verified attestation output for {name}.")
        expected_subject = {"name": name, "digest": {"sha256": digest(path)}}
        matched = False
        for row in rows:
            require(isinstance(row, dict), f"Invalid verified row for {name}.")
            result = row.get("verificationResult")
            require(isinstance(result, dict), f"Missing verified result for {name}.")
            signature = result.get("signature")
            require(isinstance(signature, dict), f"Missing verified signature for {name}.")
            certificate = signature.get("certificate")
            statement = result.get("statement")
            require(isinstance(certificate, dict) and isinstance(statement, dict),
                    f"Missing verified certificate or statement for {name}.")
            if certificate.get("runInvocationURI") != invocation:
                continue
            require(certificate.get("issuer") == "https://token.actions.githubusercontent.com" and
                    certificate.get("subjectAlternativeName") == signer and
                    certificate.get("buildSignerURI") == signer and
                    certificate.get("buildSignerDigest") == source_sha and
                    certificate.get("runnerEnvironment") == "github-hosted" and
                    certificate.get("sourceRepositoryURI") == uri and
                    certificate.get("sourceRepositoryDigest") == source_sha and
                    certificate.get("sourceRepositoryRef") == "refs/heads/master" and
                    certificate.get("buildTrigger") == "workflow_dispatch",
                    f"Wrong original candidate attestation authority for {name}.")
            subjects = statement.get("subject")
            require(statement.get("_type") == STATEMENT_TYPE and
                    statement.get("predicateType") == PREDICATE_TYPE and
                    isinstance(subjects, list) and 0 < len(subjects) <= len(HANDOFF_ASSETS),
                    f"Wrong original candidate attestation subject or predicate for {name}.")
            observed = set()
            for subject in subjects:
                require(isinstance(subject, dict) and
                        subject.get("name") in HANDOFF_ASSETS and
                        subject["name"] not in observed and
                        subject == {"name": subject["name"], "digest": {
                            "sha256": digest(candidate_root / subject["name"]) }},
                        f"Wrong original candidate attestation subject or predicate for {name}.")
                observed.add(subject["name"])
            require(expected_subject in subjects,
                    f"Wrong original candidate attestation subject or predicate for {name}.")
            matched = True
        require(matched, f"Original candidate provenance is missing for {name}.")


def verify_public_readback(candidate_root, statement, release_metadata,
                           downloaded_root, release_tag):
    release = read_json(release_metadata)
    require(isinstance(release, dict) and release.get("tag_name") == release_tag and
            release.get("draft") is False,
            "Public release tag or state differs from the selected release.")
    assets = release.get("assets")
    expected = expected_paths(candidate_root, statement)
    names = [a.get("name") for a in assets if isinstance(a, dict)] if isinstance(assets, list) else []
    require(isinstance(assets, list) and len(assets) == len(expected) and
            len(names) == len(expected) and set(names) == set(expected),
            "Public release asset names differ from the exact publication list.")
    require({p.name for p in downloaded_root.iterdir()} == set(expected),
            "Downloaded public release asset set differs from publication list.")
    for asset in assets:
        name = asset["name"]
        path = downloaded_root / name
        require(asset.get("state") == "uploaded" and
                type(asset.get("size")) is int and asset["size"] > 0 and
                path.is_file() and not path.is_symlink(),
                f"Public release asset is unavailable: {name}")
        require(path.stat().st_size == asset["size"] and
                digest(path) == digest(expected[name]),
                f"Public release asset bytes differ from the verified input: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    listed = commands.add_parser("list")
    listed.add_argument("--candidate-root", type=Path, required=True)
    candidate = commands.add_parser("verify-candidate")
    candidate.add_argument("--candidate-root", type=Path, required=True)
    candidate.add_argument("--verified-root", type=Path, required=True)
    candidate.add_argument("--repository", required=True)
    candidate.add_argument("--source-sha", required=True)
    candidate.add_argument("--run-id", required=True)
    candidate.add_argument("--run-attempt", required=True)
    public = commands.add_parser("verify-public-readback")
    public.add_argument("--candidate-root", type=Path, required=True)
    public.add_argument("--statement", type=Path, required=True)
    public.add_argument("--release-metadata", type=Path, required=True)
    public.add_argument("--downloaded-root", type=Path, required=True)
    public.add_argument("--release-tag", required=True)
    args = parser.parse_args()
    if args.command == "list":
        for name in CANDIDATE_ASSETS:
            print(args.candidate_root / name)
    elif args.command == "verify-candidate":
        verify_candidate(args.candidate_root, args.verified_root, args.repository,
                         args.source_sha, args.run_id, args.run_attempt)
    else:
        verify_public_readback(args.candidate_root, args.statement,
                               args.release_metadata, args.downloaded_root,
                               args.release_tag)


if __name__ == "__main__":
    main()
