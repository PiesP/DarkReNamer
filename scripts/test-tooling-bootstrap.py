#!/usr/bin/env python3
"""Behavioral tests for the authenticated tooling bootstrap."""

from __future__ import annotations

import builtins
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
import py_compile
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "tooling_bootstrap", SCRIPT_DIR / "tooling_bootstrap.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load tooling bootstrap")
bootstrap = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bootstrap
SPEC.loader.exec_module(bootstrap)


PACKAGE_SOURCE = b"PACKAGE_VALUE = 'verified'\n"
CAMPAIGN_PACKAGE_SOURCE = b"CAMPAIGN_PACKAGE_VALUE = 'verified'\n"
WORKER_SOURCE = b"VALUE = 'verified'\n"
VERIFIER_SOURCE = b"VALUE = 'later'\n"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Fixture:
    def __init__(self, root: Path, mode: str = "checkout") -> None:
        self.root = root
        self.mode = mode
        self.manifest_location = (
            "config/tooling-bundle.json" if mode == "checkout" else "tooling-bundle.json"
        )
        self.sources = {
            "package-root": PACKAGE_SOURCE,
            "package-campaign": CAMPAIGN_PACKAGE_SOURCE,
            "campaign-planning": WORKER_SOURCE,
            "campaign-verifier": VERIFIER_SOURCE,
        }
        self.entries = [
            self.entry(
                "package-root",
                "scripts/darkrenamer_tooling/__init__.py",
                "tooling-package-root.py",
                "python-package",
                "darkrenamer_tooling",
                [],
            ),
            self.entry(
                "package-campaign",
                "scripts/darkrenamer_tooling/campaign/__init__.py",
                "tooling-package-campaign.py",
                "python-package",
                "darkrenamer_tooling.campaign",
                ["package-root"],
            ),
            self.entry(
                "campaign-planning",
                "scripts/darkrenamer_tooling/campaign/planning.py",
                "tooling-campaign-planning.py",
                "python",
                "darkrenamer_tooling.campaign.planning",
                ["package-root", "package-campaign"],
            ),
            self.entry(
                "campaign-verifier",
                "scripts/darkrenamer_tooling/campaign/verifier.py",
                "tooling-campaign-verifier.py",
                "python",
                "darkrenamer_tooling.campaign.verifier",
                ["package-root", "package-campaign"],
            ),
        ]

    def entry(
        self,
        role: str,
        source: str,
        bundle: str,
        kind: str,
        module: str | None,
        dependencies: list[str],
    ) -> dict[str, object]:
        return {
            "role": role,
            "source": source,
            "bundle": bundle,
            "kind": kind,
            "module": module,
            "sha256": digest(self.sources[role]),
            "dependencies": dependencies,
        }

    def module_path(self, entry: dict[str, object]) -> Path:
        key = "source" if self.mode == "checkout" else "bundle"
        return self.root / str(entry[key])

    def write_modules(self) -> None:
        for entry in self.entries:
            path = self.module_path(entry)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(self.sources[str(entry["role"])])

    def write_manifest(self, raw: bytes | None = None) -> str:
        path = self.root / self.manifest_location
        path.parent.mkdir(parents=True, exist_ok=True)
        data = raw
        if data is None:
            data = (json.dumps({"schema_version": 1, "modules": self.entries}) + "\n").encode()
        path.write_bytes(data)
        return digest(data)

    def verify(self, roles: tuple[str, ...] = ("campaign-planning",)):
        return bootstrap.verify_tooling(
            root=self.root,
            manifest_location=self.manifest_location,
            expected_manifest_sha256=self.write_manifest(),
            mode=self.mode,
            required_roles=roles,
        )


class ToolingBootstrapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = Fixture(self.root)
        self.fixture.write_modules()

    def tearDown(self) -> None:
        for name in list(sys.modules):
            if name == "darkrenamer_tooling" or name.startswith("darkrenamer_tooling."):
                del sys.modules[name]
        for name in ("TOOLING_PACKAGE_EXECUTED", "TOOLING_WORKER_EXECUTED"):
            if hasattr(builtins, name):
                delattr(builtins, name)
        self.temp.cleanup()

    def assert_rejected(self, expected_digest: str, roles=("campaign-planning",)) -> None:
        with self.assertRaises(bootstrap.ToolingBootstrapError):
            bootstrap.verify_tooling(
                root=self.root,
                manifest_location=self.fixture.manifest_location,
                expected_manifest_sha256=expected_digest,
                mode=self.fixture.mode,
                required_roles=roles,
            )

    def test_checkout_and_bundle_modes_load_only_verified_bytes(self) -> None:
        for mode in ("checkout", "bundle"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(Path(directory), mode)
                fixture.write_modules()
                verified = fixture.verify()
                self.assertEqual(
                    [entry.role for entry in verified.entries],
                    ["package-root", "package-campaign", "campaign-planning"],
                )
                with verified.importer() as imports:
                    module = imports.import_role("campaign-planning")
                    self.assertEqual(module.VALUE, "verified")
                    self.assertFalse(hasattr(module, "__file__"))
                    self.assertEqual(
                        module.__tooling_source__,
                        "scripts/darkrenamer_tooling/campaign/planning.py",
                    )
                    self.assertEqual(module.__tooling_sha256__, digest(WORKER_SOURCE))
                    self.assertEqual(
                        importlib.import_module("darkrenamer_tooling").PACKAGE_VALUE,
                        "verified",
                    )
                    self.assertEqual(
                        importlib.import_module(
                            "darkrenamer_tooling.campaign"
                        ).CAMPAIGN_PACKAGE_VALUE,
                        "verified",
                    )
                    with self.assertRaises(ModuleNotFoundError):
                        importlib.import_module("darkrenamer_tooling.campaign.verifier")
                self.assertNotIn("darkrenamer_tooling", sys.modules)

    def test_powershell_module_suffix_and_null_module_are_supported(self) -> None:
        source = b"function Invoke-Test { 'verified' }\n"
        self.fixture.sources["powershell-common"] = source
        self.fixture.entries.append(
            self.fixture.entry(
                "powershell-common",
                "scripts/modules/common.psm1",
                "tooling-common.psm1",
                "powershell",
                None,
                [],
            )
        )
        self.fixture.write_modules()
        verified = self.fixture.verify(("powershell-common",))
        self.assertEqual([entry.role for entry in verified.entries], ["powershell-common"])
        with verified.importer() as imports:
            with self.assertRaises(bootstrap.ToolingBootstrapError):
                imports.import_role("powershell-common")

    def test_selected_closure_has_an_aggregate_byte_limit(self) -> None:
        with mock.patch.object(bootstrap, "MAX_TOTAL_MODULE_BYTES", len(PACKAGE_SOURCE)):
            self.assert_rejected(self.fixture.write_manifest())

    def test_missing_or_tampered_later_member_prevents_all_execution(self) -> None:
        self.fixture.sources["package-root"] = (
            b"import builtins\nbuiltins.TOOLING_PACKAGE_EXECUTED = True\n"
        )
        self.fixture.sources["campaign-planning"] = (
            b"import builtins\nbuiltins.TOOLING_WORKER_EXECUTED = True\n"
        )
        for entry in self.fixture.entries:
            entry["sha256"] = digest(self.fixture.sources[str(entry["role"])])
        self.fixture.write_modules()
        manifest_digest = self.fixture.write_manifest()
        self.fixture.module_path(self.fixture.entries[3]).unlink()
        self.assert_rejected(manifest_digest, ("campaign-planning", "campaign-verifier"))
        self.assertFalse(hasattr(builtins, "TOOLING_PACKAGE_EXECUTED"))
        self.assertFalse(hasattr(builtins, "TOOLING_WORKER_EXECUTED"))

        self.fixture.module_path(self.fixture.entries[3]).write_bytes(b"tampered\n")
        self.assert_rejected(manifest_digest, ("campaign-planning", "campaign-verifier"))
        self.assertFalse(hasattr(builtins, "TOOLING_PACKAGE_EXECUTED"))
        self.assertFalse(hasattr(builtins, "TOOLING_WORKER_EXECUTED"))

    def test_later_syntax_error_prevents_all_package_execution(self) -> None:
        self.fixture.sources["package-root"] = (
            b"import builtins\nbuiltins.TOOLING_PACKAGE_EXECUTED = True\n"
        )
        self.fixture.sources["campaign-planning"] = (
            b"import builtins\nbuiltins.TOOLING_WORKER_EXECUTED = True\n"
        )
        self.fixture.sources["campaign-verifier"] = b"def incomplete(\n"
        for entry in self.fixture.entries:
            entry["sha256"] = digest(self.fixture.sources[str(entry["role"])])
        self.fixture.write_modules()
        manifest_digest = self.fixture.write_manifest()
        self.assert_rejected(manifest_digest, ("campaign-planning", "campaign-verifier"))
        self.assertFalse(hasattr(builtins, "TOOLING_PACKAGE_EXECUTED"))
        self.assertFalse(hasattr(builtins, "TOOLING_WORKER_EXECUTED"))

    def test_initializer_tamper_is_rejected_before_worker_execution(self) -> None:
        self.fixture.sources["campaign-planning"] = (
            b"import builtins\nbuiltins.TOOLING_WORKER_EXECUTED = True\n"
        )
        self.fixture.entries[2]["sha256"] = digest(self.fixture.sources["campaign-planning"])
        self.fixture.write_modules()
        manifest_digest = self.fixture.write_manifest()
        self.fixture.module_path(self.fixture.entries[0]).write_bytes(b"tampered\n")
        self.assert_rejected(manifest_digest)
        self.assertFalse(hasattr(builtins, "TOOLING_WORKER_EXECUTED"))

        self.fixture.write_modules()
        self.fixture.module_path(self.fixture.entries[1]).write_bytes(b"tampered nested init\n")
        self.assert_rejected(manifest_digest)
        self.assertFalse(hasattr(builtins, "TOOLING_WORKER_EXECUTED"))

    def test_manifest_digest_duplicate_keys_and_exact_shape_are_required(self) -> None:
        valid_digest = self.fixture.write_manifest()
        self.assert_rejected("0" * 64)

        duplicate = b'{"schema_version":1,"schema_version":1,"modules":[]}\n'
        self.assert_rejected(self.fixture.write_manifest(duplicate), ())

        extra = json.dumps(
            {"schema_version": 1, "modules": self.fixture.entries, "extra": False}
        ).encode()
        self.assert_rejected(self.fixture.write_manifest(extra))
        self.assertEqual(len(valid_digest), 64)

    def test_wrong_module_digest_dependency_role_and_kind_are_rejected(self) -> None:
        mutations = (
            lambda entry: entry.__setitem__("sha256", "0" * 64),
            lambda entry: entry.__setitem__("dependencies", ["missing-role"]),
            lambda entry: entry.__setitem__("role", "unknown-role"),
            lambda entry: entry.__setitem__("kind", "powershell"),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(Path(directory))
                fixture.write_modules()
                mutate(fixture.entries[2])
                with self.assertRaises(bootstrap.ToolingBootstrapError):
                    bootstrap.verify_tooling(
                        root=fixture.root,
                        manifest_location=fixture.manifest_location,
                        expected_manifest_sha256=fixture.write_manifest(),
                        mode="checkout",
                        required_roles=("campaign-planning",),
                    )

    def test_path_case_and_reserved_names_are_rejected(self) -> None:
        changes = (
            ("source", "../worker.py"),
            ("source", "scripts/CON.py"),
            ("bundle", "nested/worker.py"),
            ("bundle", "NUL.py"),
        )
        for field, value in changes:
            with self.subTest(field=field, value=value):
                original = self.fixture.entries[2][field]
                self.fixture.entries[2][field] = value
                self.assert_rejected(self.fixture.write_manifest())
                self.fixture.entries[2][field] = original

        duplicate = dict(self.fixture.entries[3])
        duplicate["role"] = "evidence-archive"
        duplicate["source"] = str(self.fixture.entries[2]["source"]).upper()
        duplicate["module"] = "darkrenamer_tooling.campaign.case_collision"
        self.fixture.entries.append(duplicate)
        self.assert_rejected(self.fixture.write_manifest())

        duplicate["source"] = "scripts/darkrenamer_tooling/evidence/archive.py"
        duplicate["bundle"] = str(self.fixture.entries[2]["bundle"]).upper()
        self.assert_rejected(self.fixture.write_manifest())

    def test_symlinks_and_special_files_are_rejected(self) -> None:
        worker = self.fixture.module_path(self.fixture.entries[2])
        target = self.root / "outside.py"
        target.write_bytes(WORKER_SOURCE)
        worker.unlink()
        worker.symlink_to(target)
        self.assert_rejected(self.fixture.write_manifest())

        worker.unlink()
        if hasattr(os, "mkfifo"):
            os.mkfifo(worker)
            self.assert_rejected(self.fixture.write_manifest())

        worker.unlink(missing_ok=True)
        linked_target = self.root / "linked-target"
        linked_target.mkdir()
        (linked_target / "planning.py").write_bytes(WORKER_SOURCE)
        linked_parent = self.root / "scripts" / "linked"
        linked_parent.symlink_to(linked_target, target_is_directory=True)
        self.fixture.entries[2]["source"] = "scripts/linked/planning.py"
        self.assert_rejected(self.fixture.write_manifest())

        manifest = self.root / self.fixture.manifest_location
        manifest.unlink(missing_ok=True)
        manifest.symlink_to(self.root / "outside-manifest.json")
        (self.root / "outside-manifest.json").write_bytes(b"{}")
        self.assert_rejected(digest(b"{}"))

    def test_search_path_and_bytecode_cannot_shadow_verified_modules(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            shadow_root = Path(directory)
            package = shadow_root / "darkrenamer_tooling"
            package.mkdir()
            (package / "__init__.py").write_text("raise RuntimeError('shadow package')\n")
            shadow = package / "worker.py"
            shadow.write_text("VALUE = 'shadow'\n")
            py_compile.compile(str(shadow), doraise=True)
            sys.path.insert(0, str(shadow_root))
            try:
                verified = self.fixture.verify()
                with verified.importer() as imports:
                    self.assertEqual(imports.import_role("campaign-planning").VALUE, "verified")
            finally:
                sys.path.remove(str(shadow_root))

    def test_file_mutation_after_verification_cannot_change_executed_bytes(self) -> None:
        verified = self.fixture.verify()
        self.fixture.module_path(self.fixture.entries[0]).write_bytes(
            b"PACKAGE_VALUE = 'mutated'\n"
        )
        self.fixture.module_path(self.fixture.entries[2]).write_bytes(b"VALUE = 'mutated'\n")
        with verified.importer() as imports:
            module = imports.import_role("campaign-planning")
            self.assertEqual(module.VALUE, "verified")
            self.assertEqual(
                importlib.import_module("darkrenamer_tooling").PACKAGE_VALUE,
                "verified",
            )

    def test_preloaded_namespace_shadowing_is_rejected(self) -> None:
        verified = self.fixture.verify()
        sys.modules["darkrenamer_tooling"] = types.ModuleType("darkrenamer_tooling")
        with self.assertRaises(bootstrap.ToolingBootstrapError):
            with verified.importer():
                self.fail("shadowed namespace was accepted")

    def test_concurrent_verified_importers_are_rejected(self) -> None:
        verified = self.fixture.verify()
        with verified.importer():
            with self.assertRaises(bootstrap.ToolingBootstrapError):
                with verified.importer():
                    self.fail("concurrent verified importer was accepted")

    def test_importing_library_has_no_io_process_or_external_mutation(self) -> None:
        source = (SCRIPT_DIR / "tooling_bootstrap.py").read_bytes()
        before_cwd = os.getcwd()
        before_environment = dict(os.environ)
        before_meta_path = tuple(sys.meta_path)
        before_names = set(sys.modules)
        namespace = {
            "__name__": "tooling_bootstrap_side_effect_probe",
            "__file__": str(SCRIPT_DIR / "tooling_bootstrap.py"),
        }
        probe = types.ModuleType(namespace["__name__"])
        probe.__dict__.update(namespace)
        sys.modules[probe.__name__] = probe
        try:
            with mock.patch("builtins.open", side_effect=AssertionError("unexpected open")), \
                    mock.patch("os.open", side_effect=AssertionError("unexpected os.open")), \
                    mock.patch("os.stat", side_effect=AssertionError("unexpected stat")), \
                    mock.patch("os.lstat", side_effect=AssertionError("unexpected lstat")), \
                    mock.patch.object(
                        subprocess, "Popen", side_effect=AssertionError("unexpected process")
                    ):
                exec(compile(source, namespace["__file__"], "exec"), probe.__dict__)
        finally:
            del sys.modules[probe.__name__]
        self.assertEqual(os.getcwd(), before_cwd)
        self.assertEqual(dict(os.environ), before_environment)
        self.assertEqual(tuple(sys.meta_path), before_meta_path)
        self.assertEqual(set(sys.modules) - before_names, set())


if __name__ == "__main__":
    unittest.main()
