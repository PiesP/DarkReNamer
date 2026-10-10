"""Private VM evidence CLI inputs built in an isolated synthetic checkout."""

from argparse import Namespace
import hashlib
import json
from pathlib import Path
import subprocess
from zipfile import ZIP_STORED, ZipFile

from campaign_fixture import CampaignFixture
from darkrenamer_tooling.contracts.binding import COMPONENTS, Candidate
from tooling_test_paths import REPOSITORY_ROOT


def compact(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":")).encode()


class CliFixture:
    def __init__(self, root: Path, *, revision: int = 1):
        self.root = root
        self.revision = revision
        self.scratch = root / "private-scratch"
        self.handoff_root = root / "candidate-handoff"
        self.trusted_root = root / "trusted-source"
        self.raw_root = root / "raw-campaign"
        self.output_root = root / "public"
        for path in (self.scratch, self.handoff_root, self.trusted_root,
                     self.raw_root, self.output_root):
            path.mkdir()

        source_profile = REPOSITORY_ROOT / f"config/vm-automated-v{revision}.json"
        self.profile_bytes = source_profile.read_bytes()
        self.profile = json.loads(self.profile_bytes)
        component_bytes = self._create_trusted_checkout()
        self.source_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=self.trusted_root, text=True).strip()
        self.components = {
            role: hashlib.sha256(component_bytes[role]).hexdigest() for role in COMPONENTS
        }

        self.executable_bytes = b"MZ\x00trusted immutable candidate executable"
        self.executable_sha = hashlib.sha256(self.executable_bytes).hexdigest()
        (self.handoff_root / "DarkReNamer.exe").write_bytes(self.executable_bytes)
        self.handoff = {
            "schema_version": 1, "source_sha": self.source_sha, "workflow_run": 12,
            "executable": {"filename": "DarkReNamer.exe", "sha256": self.executable_sha},
        }
        self.handoff_bytes = compact(self.handoff)
        (self.handoff_root / "release-handoff.json").write_bytes(self.handoff_bytes)
        self.candidate = Candidate(
            self.source_sha, "12", "1", "34", self.executable_sha,
            hashlib.sha256(self.handoff_bytes).hexdigest(),
        )
        self.campaign = CampaignFixture(
            self.raw_root, profile=self.profile,
            profile_sha256=hashlib.sha256(self.profile_bytes).hexdigest(),
            candidate=self.candidate, components=self.components,
        )
        self._add_tooling_evidence()
        self.archive = self.scratch / "evidence.zip"
        self.write_archive(self.archive)
        self.gate_metadata = root / "gate-metadata.json"
        self.gate_metadata.write_bytes(compact(self._gate_facts()))

    def _create_trusted_checkout(self) -> dict[str, bytes]:
        repository = REPOSITORY_ROOT
        (self.trusted_root / "config").mkdir()
        (self.trusted_root / "scripts").mkdir()
        (self.trusted_root / f"config/vm-automated-v{self.revision}.json").write_bytes(self.profile_bytes)
        tooling_manifest = (repository / "config/tooling-bundle.json").read_bytes()
        (self.trusted_root / "config/tooling-bundle.json").write_bytes(tooling_manifest)
        for entry in json.loads(tooling_manifest)["modules"]:
            destination = self.trusted_root / entry["source"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((repository / entry["source"]).read_bytes())
        component_bytes = {}
        for role, filename in COMPONENTS.items():
            data = ("trusted component " + role + "\n").encode()
            (self.trusted_root / "scripts" / filename).write_bytes(data)
            component_bytes[role] = data
        subprocess.run(["git", "init", "-q"], cwd=self.trusted_root, check=True)
        subprocess.run(["git", "config", "user.name", "VM Evidence Test"],
                       cwd=self.trusted_root, check=True)
        subprocess.run(["git", "config", "user.email", "vm-evidence@example.invalid"],
                       cwd=self.trusted_root, check=True)
        subprocess.run(["git", "config", "commit.gpgsign", "false"],
                       cwd=self.trusted_root, check=True)
        subprocess.run(["git", "add", "config", "scripts"], cwd=self.trusted_root, check=True)
        subprocess.run(["git", "commit", "-q", "--no-gpg-sign", "-m", "test fixture"],
                       cwd=self.trusted_root, check=True)
        return component_bytes

    def _add_tooling_evidence(self) -> None:
        manifest = (self.trusted_root / "config/tooling-bundle.json").read_bytes()
        parsed = json.loads(manifest)
        by_role = {entry["role"]: entry for entry in parsed["modules"]}
        selected = set()

        def select(role: str) -> None:
            if role in selected:
                return
            for dependency in by_role[role]["dependencies"]:
                select(dependency)
            selected.add(role)

        select("vm-launcher")
        retained = {"tooling-bundle.json": manifest}
        for entry in parsed["modules"]:
            if entry["role"] in selected:
                retained[entry["bundle"]] = (self.trusted_root / entry["source"]).read_bytes()
        prefixes = {
            str(Path(attempt["bundle"]).parent).replace("\\", "/") + "/"
            for attempt in self.campaign.campaign["attempts"]
        } | {"backend/"}
        for prefix in prefixes:
            for name, data in retained.items():
                reference = self.campaign.add_bytes(prefix + name, data)
                if prefix == "backend/":
                    self.campaign.campaign["backend"]["files"].append({
                        "file": prefix + name,
                        "sha256": reference.sha256,
                        "size": reference.size,
                    })
        self.campaign.add_json("campaign.json", self.campaign.campaign)

    def _gate_facts(self) -> dict:
        def run(identifier: int, path: str, event: str) -> dict:
            return {
                "id": identifier, "run_attempt": 1, "path": path, "event": event,
                "head_branch": "master", "head_sha": self.source_sha,
                "status": "completed", "conclusion": "success", "repository_id": 45,
            }

        def jobs(names: list[str]) -> list[dict]:
            return [{"name": name, "status": "completed", "conclusion": "success"}
                    for name in names]

        return {
            "schema_version": 1,
            "repository": {"full_name": "PiesP/DarkReNamer", "id": 45,
                           "owner": {"login": "PiesP", "id": 56, "type": "User"}},
            "candidate": {
                "run": run(12, ".github/workflows/release.yaml", "workflow_dispatch"),
                "jobs": jobs(["candidate/build-windows", "candidate/attest"]),
                "artifact_sha256": "d" * 64,
                "artifact": {
                    "id": 34, "name": "DarkReNamer-dry-run-12-1-windows",
                    "digest": "sha256:" + "d" * 64, "size": 1234, "expired": False,
                    "workflow_run": {"id": 12, "head_sha": self.source_sha},
                },
            },
            "ci": {
                "run": run(78, ".github/workflows/ci.yaml", "push"),
                "jobs": jobs(["pr-gate/quality", "pr-gate/unit", "pr-gate/security",
                              "pr-gate/windows"]),
            },
        }

    def write_archive(self, destination: Path, *, campaign: dict | None = None,
                      replacements: dict[str, bytes] | None = None,
                      omitted: set[str] | None = None) -> None:
        overrides = dict(replacements or {})
        omitted = set(omitted or ())
        if campaign is not None:
            overrides["campaign.json"] = compact(campaign)
        pins = {}
        for path, reference in self.campaign.files.items():
            if path in omitted:
                continue
            data = overrides.get(path)
            pins[path] = {
                "sha256": (hashlib.sha256(data).hexdigest() if data is not None else reference.sha256),
                "size": len(data) if data is not None else reference.size,
            }
        index = compact({"schema": f"darkrenamer-vm-automated-index-v{self.revision}", "files": pins})
        with ZipFile(destination, "w", compression=ZIP_STORED, allowZip64=False) as archive:
            archive.writestr("evidence-index.json", index)
            for path in self.campaign.files:
                if path in omitted:
                    continue
                archive.writestr(path, overrides.get(path, (self.raw_root / path).read_bytes()))

    def args(self, archive: Path | None = None, output: Path | None = None) -> Namespace:
        selected = archive or self.archive
        data = selected.read_bytes()
        return Namespace(
            profile_id=self.profile["profile_id"], archive=selected,
            archive_sha256=hashlib.sha256(data).hexdigest(), archive_size=str(len(data)),
            candidate_handoff_root=self.handoff_root, trusted_source_root=self.trusted_root,
            gate_metadata=self.gate_metadata, output=output or self.output_root / "statement.json",
            candidate_run_id="12", candidate_run_attempt="1", candidate_artifact_id="34",
            candidate_source_sha=self.source_sha, expected_exe_sha256=self.executable_sha,
            release_id="37", asset_id="41", validation_run_id="90",
            validation_run_attempt="1",
        )

