#!/usr/bin/env python3
"""Update or check the explicit dependency-closed tooling module manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


INVENTORY = (
    ("tooling-loader", "scripts/tooling_bootstrap.py", "tooling-loader.py", "python", "darkrenamer_tooling.loader", ("package-root",)),
    ("package-root", "scripts/darkrenamer_tooling/__init__.py", "tooling-package-root.py", "python-package", "darkrenamer_tooling", ()),
    ("package-campaign", "scripts/darkrenamer_tooling/campaign/__init__.py", "tooling-package-campaign.py", "python-package", "darkrenamer_tooling.campaign", ("package-root",)),
    ("campaign-planning", "scripts/darkrenamer_tooling/campaign/planning.py", "tooling-campaign-planning.py", "python", "darkrenamer_tooling.campaign.planning", ("package-root", "package-campaign", "package-contracts", "contracts-binding", "contracts-platform", "package-evidence", "evidence-archive")),
    ("campaign-recovery", "scripts/darkrenamer_tooling/campaign/recovery.py", "tooling-campaign-recovery.py", "python", "darkrenamer_tooling.campaign.recovery", ("package-root", "package-campaign", "campaign-planning", "package-contracts", "contracts-binding", "contracts-platform", "contracts-state", "package-evidence", "evidence-archive", "evidence-png", "evidence-recovery")),
    ("campaign-verifier", "scripts/darkrenamer_tooling/campaign/verifier.py", "tooling-campaign-verifier.py", "python", "darkrenamer_tooling.campaign.verifier", ("package-root", "package-campaign", "campaign-planning", "campaign-recovery", "package-contracts", "contracts-binding", "contracts-menu-layout", "contracts-platform", "contracts-state", "contracts-tooling", "package-evidence", "evidence-archive", "evidence-png")),
    ("campaign-runner", "scripts/darkrenamer_tooling/campaign/runner.py", "tooling-campaign-runner.py", "python", "darkrenamer_tooling.campaign.runner", ("tooling-loader", "package-root", "package-campaign", "campaign-planning", "campaign-verifier", "package-contracts", "contracts-binding", "contracts-tooling", "package-evidence", "evidence-archive", "package-vm", "vm-launcher", "vm-gui")),
    ("package-vm", "scripts/darkrenamer_tooling/vm/__init__.py", "tooling-package-vm.py", "python-package", "darkrenamer_tooling.vm", ("package-root",)),
    ("vm-launcher", "scripts/darkrenamer_tooling/vm/launcher.py", "tooling-vm-launcher.py", "python", "darkrenamer_tooling.vm.launcher", ("tooling-loader", "package-root", "package-vm", "package-contracts", "contracts-tooling", "package-evidence", "evidence-errors")),
    ("vm-gui", "scripts/darkrenamer_tooling/vm/gui.py", "tooling-vm-gui.py", "python", "darkrenamer_tooling.vm.gui", ("tooling-loader", "package-root", "package-vm", "vm-launcher", "package-contracts", "contracts-tooling", "package-evidence", "evidence-errors")),
    ("package-contracts", "scripts/darkrenamer_tooling/contracts/__init__.py", "tooling-package-contracts.py", "python-package", "darkrenamer_tooling.contracts", ("package-root",)),
    ("contracts-binding", "scripts/darkrenamer_tooling/contracts/binding.py", "tooling-contracts-binding.py", "python", "darkrenamer_tooling.contracts.binding", ("package-root", "package-contracts", "package-evidence", "evidence-archive")),
    ("contracts-menu-layout", "scripts/darkrenamer_tooling/contracts/menu_layout.py", "tooling-contracts-menu-layout.py", "python", "darkrenamer_tooling.contracts.menu_layout", ("package-root", "package-contracts", "contracts-platform", "contracts-state", "package-evidence", "evidence-archive")),
    ("contracts-platform", "scripts/darkrenamer_tooling/contracts/platform.py", "tooling-contracts-platform.py", "python", "darkrenamer_tooling.contracts.platform", ("package-root", "package-contracts", "contracts-state", "package-evidence", "evidence-archive")),
    ("contracts-state", "scripts/darkrenamer_tooling/contracts/state.py", "tooling-contracts-state.py", "python", "darkrenamer_tooling.contracts.state", ("package-root", "package-contracts", "package-evidence", "evidence-archive")),
    ("contracts-authority", "scripts/darkrenamer_tooling/contracts/authority.py", "tooling-contracts-authority.py", "python", "darkrenamer_tooling.contracts.authority", ("tooling-loader", "package-root", "package-contracts")),
    ("contracts-tooling", "scripts/darkrenamer_tooling/contracts/tooling.py", "tooling-contracts-tooling.py", "python", "darkrenamer_tooling.contracts.tooling", ("package-root", "package-contracts", "package-evidence", "evidence-errors")),
    ("package-evidence", "scripts/darkrenamer_tooling/evidence/__init__.py", "tooling-package-evidence.py", "python-package", "darkrenamer_tooling.evidence", ("package-root",)),
    ("evidence-archive", "scripts/darkrenamer_tooling/evidence/archive.py", "tooling-evidence-archive.py", "python", "darkrenamer_tooling.evidence.archive", ("package-root", "package-evidence", "evidence-errors")),
    ("evidence-journal", "scripts/darkrenamer_tooling/evidence/journal.py", "tooling-evidence-journal.py", "python", "darkrenamer_tooling.evidence.journal", ("package-root", "package-evidence")),
    ("evidence-png", "scripts/darkrenamer_tooling/evidence/png.py", "tooling-evidence-png.py", "python", "darkrenamer_tooling.evidence.png", ("package-root", "package-evidence", "evidence-errors")),
    ("evidence-recovery", "scripts/darkrenamer_tooling/evidence/recovery.py", "tooling-evidence-recovery.py", "python", "darkrenamer_tooling.evidence.recovery", ("package-root", "package-evidence", "evidence-archive", "evidence-journal", "package-contracts", "contracts-state")),
    ("evidence-errors", "scripts/darkrenamer_tooling/evidence/errors.py", "tooling-evidence-errors.py", "python", "darkrenamer_tooling.evidence.errors", ("package-root", "package-evidence")),
    ("evidence-gui", "scripts/darkrenamer_tooling/evidence/gui.py", "tooling-evidence-gui.py", "python", "darkrenamer_tooling.evidence.gui", ("tooling-loader", "package-root", "package-evidence", "evidence-errors", "evidence-png")),
    ("evidence-cli", "scripts/darkrenamer_tooling/evidence/cli.py", "tooling-evidence-cli.py", "python", "darkrenamer_tooling.evidence.cli", ("tooling-loader", "package-root", "package-evidence", "evidence-archive", "package-campaign", "campaign-verifier", "package-contracts", "contracts-binding", "contracts-tooling")),
)

PUBLIC_BOOTSTRAPS = (
    "scripts/test-windows-vm.py",
    "scripts/run-gui-regression.py",
    "scripts/run-vm-automated-campaign.py",
    "scripts/validate-gui-regression-evidence.py",
    "scripts/validate-vm-automated-evidence.py",
    "scripts/validate-vm-automated-authority.py",
)
PIN_PATTERN = re.compile(
    r'^(TOOLING_(?:MANIFEST|LOADER)_SHA256 = )(?:(?:"[0-9a-f]{64}")|(?:"0" \* 64))$',
    re.MULTILINE,
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def manifest_bytes(root: Path) -> bytes:
    modules = []
    for role, source, bundle, kind, module, dependencies in INVENTORY:
        data = (root / source).read_bytes()
        modules.append({
            "role": role,
            "source": source,
            "bundle": bundle,
            "kind": kind,
            "module": module,
            "sha256": digest(data),
            "dependencies": list(dependencies),
        })
    return (json.dumps({"schema_version": 1, "modules": modules}, indent=2) + "\n").encode()


def updated_bootstrap(data: bytes, *, manifest_sha256: str, loader_sha256: str) -> bytes:
    text = data.decode("utf-8")
    replacements = {
        "TOOLING_MANIFEST_SHA256": manifest_sha256,
        "TOOLING_LOADER_SHA256": loader_sha256,
    }

    def replace(match: re.Match[str]) -> str:
        name = match.group(1).split(" =", 1)[0]
        return match.group(1) + '"' + replacements[name] + '"'

    changed, count = PIN_PATTERN.subn(replace, text)
    if count != 2:
        raise ValueError("Public bootstrap does not contain exactly two generated tooling pins.")
    return changed.encode()


def unregistered_modules(root: Path) -> list[str]:
    registered = {source for _role, source, _bundle, _kind, _module, _deps in INVENTORY}
    actual = {
        path.relative_to(root).as_posix()
        for path in (root / "scripts" / "darkrenamer_tooling").rglob("*.py")
    }
    return sorted(actual - registered)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    missing = [source for _role, source, _bundle, _kind, _module, _deps in INVENTORY
               if not (root / source).is_file()]
    extras = unregistered_modules(root)
    if missing or extras:
        for path in missing:
            print("Missing registered tooling module: " + path, file=sys.stderr)
        for path in extras:
            print("Unregistered tooling package module: " + path, file=sys.stderr)
        return 1
    manifest = manifest_bytes(root)
    manifest_sha256 = digest(manifest)
    loader_sha256 = digest((root / "scripts" / "tooling_bootstrap.py").read_bytes())
    expected = {root / "config" / "tooling-bundle.json": manifest}
    for relative in PUBLIC_BOOTSTRAPS:
        path = root / relative
        expected[path] = updated_bootstrap(
            path.read_bytes(), manifest_sha256=manifest_sha256, loader_sha256=loader_sha256
        )
    stale = [path for path, data in expected.items() if not path.is_file() or path.read_bytes() != data]
    if args.check:
        for path in stale:
            print("Stale tooling bundle generated file: " + path.relative_to(root).as_posix(),
                  file=sys.stderr)
        return 1 if stale else 0
    for path in stale:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(expected[path])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
