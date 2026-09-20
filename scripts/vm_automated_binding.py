"""Bind untrusted VM records to independently obtained candidate/source facts."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import re
import subprocess

from vm_automated_evidence import EvidenceError, require_exact_keys, require_int


COMPONENTS = {
    "launcher": "test-windows-vm.py",
    "controller": "run-windows-vm-tests.ps1",
    "runner": "windows-vm-guest.ps1",
    "validators.release_handoff": "validate-release-handoff.ps1",
    "validators.candidate_metadata": "validate-release-candidate-metadata.ps1",
    "validators.binary_measurement": "measure-windows-binary.ps1",
    "observers.ui": "windows-vm-acceptance.ps1",
    "observers.recovery": "windows-vm-recovery-acceptance.ps1",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def sha(value: object, length: int) -> str:
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{" + str(length) + "}", value) is not None,
            "Source or artifact digest is invalid.")
    return value


def decimal(value: object) -> str:
    require(type(value) is str and re.fullmatch(r"[1-9][0-9]{0,18}", value) is not None,
            "Candidate numeric identifier must be a canonical decimal string.")
    require(int(value) < 1 << 63, "Candidate identifier exceeds the supported range.")
    return value


@dataclass(frozen=True)
class Candidate:
    """Expected facts from a separately authenticated immutable handoff."""

    source_sha: str
    workflow_run: str
    run_attempt: str
    artifact_id: str
    executable_sha256: str
    handoff_sha256: str

    def __post_init__(self) -> None:
        sha(self.source_sha, 40)
        for value in (self.workflow_run, self.run_attempt, self.artifact_id):
            decimal(value)
        sha(self.executable_sha256, 64)
        sha(self.handoff_sha256, 64)


def trusted_component_hashes(checkout: Path, source_sha: str) -> dict[str, str]:
    """Read only fixed tracked blobs from the trusted verifier checkout.

    The caller must establish the checkout/workflow authority. Never choose this
    checkout or source SHA from an archive-supplied manifest.
    """
    sha(source_sha, 40)
    checkout = checkout.resolve(strict=True)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    require(head == source_sha, "Trusted checkout does not match the selected source.")
    result = {}
    for role, name in COMPONENTS.items():
        path = "scripts/" + name
        tree = subprocess.check_output(["git", "ls-tree", source_sha, "--", path],
                                       cwd=checkout, text=True).strip()
        require(tree.startswith(("100644 blob ", "100755 blob ")) and tree.endswith("\t" + path),
                "Trusted component must be one tracked ordinary file.")
        data = subprocess.check_output(["git", "show", source_sha + ":" + path], cwd=checkout)
        require(len(data) <= 4 * 1024 * 1024, "Trusted component exceeds its bound.")
        result[role] = hashlib.sha256(data).hexdigest()
    return result


def verify_candidate_bundle(bundle: object, *, expected: Candidate, harness_sha: str,
                            component_hashes: dict[str, str], release: bool) -> None:
    require(type(expected) is Candidate, "Expected candidate must be independently established.")
    sha(harness_sha, 40)
    require(type(release) is bool, "Release binding mode must be explicit.")
    require(not release or expected.source_sha == harness_sha,
            "Final acceptance requires identical product and trusted harness source.")
    require(type(component_hashes) is dict and set(component_hashes) == set(COMPONENTS),
            "Trusted component inventory is incomplete or unexpected.")
    top = require_exact_keys(bundle, {"schema_version", "lane", "target", "product", "harness",
                                      "test_binaries"}, "Candidate bundle")
    require_int(top["schema_version"], 2, 2, "Bundle schema")
    require(top["lane"] == "candidate-gui-only" and top["target"] == "x86_64-pc-windows-msvc"
            and type(top["test_binaries"]) is list and not top["test_binaries"],
            "Candidate lane cannot replace source-bound backend test evidence.")
    product = require_exact_keys(top["product"], {"source_sha", "source_state", "candidate",
                                                "application", "provenance"}, "Product binding")
    require(product["source_sha"] == expected.source_sha and product["source_state"] == "clean",
            "Product source binding differs from the independent candidate.")
    candidate = require_exact_keys(product["candidate"], {"workflow_run", "run_attempt", "artifact_id",
                                                         "artifact_name", "origin_authentication"},
                                   "Candidate identity")
    for key in ("workflow_run", "run_attempt", "artifact_id"):
        require(decimal(candidate[key]) == getattr(expected, key), "Candidate identity mismatch.")
    require(candidate["artifact_name"] ==
            f"DarkReNamer-dry-run-{expected.workflow_run}-{expected.run_attempt}-windows",
            "Candidate artifact name differs from its exact run and attempt.")
    require(candidate["origin_authentication"] == "pending-hosted",
            "Local producer cannot assert hosted origin authentication.")
    require(product["application"] == {"file": "DarkReNamer.exe", "sha256": expected.executable_sha256},
            "Product EXE differs from the independently authenticated bytes.")
    provenance = require_exact_keys(product["provenance"], {"release_handoff", "run_metadata",
                                                          "artifact_metadata"}, "Product provenance")
    for key, filename in (("release_handoff", "release-handoff.json"),
                          ("run_metadata", "candidate-run.json"),
                          ("artifact_metadata", "candidate-artifact.json")):
        row = require_exact_keys(provenance[key], {"file", "sha256"}, "Provenance reference")
        require(row["file"] == filename, "Provenance reference has an unexpected filename.")
        sha(row["sha256"], 64)
    require(provenance["release_handoff"]["sha256"] == expected.handoff_sha256,
            "Observed handoff differs from the independently fetched handoff.")
    harness = require_exact_keys(top["harness"], {"source_sha", "source_state", "launcher", "controller",
                                                "runner", "validators", "observers"}, "Harness binding")
    require(harness["source_sha"] == harness_sha and harness["source_state"] == "clean",
            "Observed harness source differs from the trusted verifier source.")
    require_exact_keys(harness["validators"], {"release_handoff", "candidate_metadata", "binary_measurement"},
                       "Harness validators")
    require_exact_keys(harness["observers"], {"ui", "recovery"}, "Harness observers")
    for role, filename in COMPONENTS.items():
        parts = role.split(".")
        actual = harness[parts[0]] if len(parts) == 1 else harness[parts[0]][parts[1]]
        require(actual == {"file": filename, "sha256": sha(component_hashes[role], 64)},
                "Observed harness component differs from its trusted source blob: " + role)


def verify_result_binding(result: object, bundle: dict, *, observer: str) -> None:
    require(type(result) is dict, "Observer result must be an object.")
    require(observer in {"core", "ui", "recovery"}, "Unexpected observer role.")
    require_int(result.get("schema_version"), 2, 2, "Observer result schema")
    for field in ("lane", "product", "harness"):
        require(result.get(field) == bundle[field], "Observer result is bound to another " + field + ".")
    if observer != "recovery":
        require(result.get("target") == bundle["target"], "Observer target mismatch.")
    if observer != "core":
        require(result.get("observer_role") == observer and
                result.get("runner_sha256") == bundle["harness"]["runner"]["sha256"] and
                result.get("application") == bundle["product"]["application"],
                "Observer result role or frozen script hash differs.")
        expected = bundle["harness"]["observers"][observer]
        if observer == "ui":
            require(result.get("acceptance_script_sha256") == expected["sha256"], "UI observer hash mismatch.")
        else:
            require(result.get("observer") == expected, "Recovery observer hash mismatch.")
