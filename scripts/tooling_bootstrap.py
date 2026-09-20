#!/usr/bin/env python3
"""Authenticate and load dependency-closed DarkReNamer tooling modules.

Importing this module only defines the verification API. Call :func:`verify_tooling`
before entering the returned object's importer context.
"""

from __future__ import annotations

from dataclasses import dataclass
import _imp
import hashlib
import importlib
import importlib.abc
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import threading
from types import CodeType, MappingProxyType, ModuleType
from typing import Any, Sequence


MAX_MANIFEST_BYTES = 512 * 1024
MAX_MODULE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_MODULE_BYTES = 32 * 1024 * 1024
MAX_MODULES = 128
TOOLING_NAMESPACE = "darkrenamer_tooling"

# Roles are authorization identifiers, not user-extensible labels. A manifest may
# use only the roles and implementation kinds declared here.
SUPPORTED_ROLES = MappingProxyType({
    "tooling-loader": ("python", "darkrenamer_tooling.loader"),
    "package-root": ("python-package", "darkrenamer_tooling"),
    "package-campaign": ("python-package", "darkrenamer_tooling.campaign"),
    "campaign-planning": ("python", "darkrenamer_tooling.campaign.planning"),
    "campaign-recovery": ("python", "darkrenamer_tooling.campaign.recovery"),
    "campaign-verifier": ("python", "darkrenamer_tooling.campaign.verifier"),
    "campaign-runner": ("python", "darkrenamer_tooling.campaign.runner"),
    "package-vm": ("python-package", "darkrenamer_tooling.vm"),
    "vm-launcher": ("python", "darkrenamer_tooling.vm.launcher"),
    "vm-gui": ("python", "darkrenamer_tooling.vm.gui"),
    "package-contracts": ("python-package", "darkrenamer_tooling.contracts"),
    "contracts-binding": ("python", "darkrenamer_tooling.contracts.binding"),
    "contracts-menu-layout": ("python", "darkrenamer_tooling.contracts.menu_layout"),
    "contracts-platform": ("python", "darkrenamer_tooling.contracts.platform"),
    "contracts-state": ("python", "darkrenamer_tooling.contracts.state"),
    "contracts-authority": ("python", "darkrenamer_tooling.contracts.authority"),
    "contracts-tooling": ("python", "darkrenamer_tooling.contracts.tooling"),
    "package-evidence": ("python-package", "darkrenamer_tooling.evidence"),
    "evidence-archive": ("python", "darkrenamer_tooling.evidence.archive"),
    "evidence-journal": ("python", "darkrenamer_tooling.evidence.journal"),
    "evidence-png": ("python", "darkrenamer_tooling.evidence.png"),
    "evidence-recovery": ("python", "darkrenamer_tooling.evidence.recovery"),
    "evidence-errors": ("python", "darkrenamer_tooling.evidence.errors"),
    "evidence-gui": ("python", "darkrenamer_tooling.evidence.gui"),
    "evidence-cli": ("python", "darkrenamer_tooling.evidence.cli"),
    "powershell-common": ("powershell", None),
    "powershell-loader": ("powershell", None),
    "powershell-guest-contracts": ("powershell", None),
    "powershell-guest-process": ("powershell", None),
    "powershell-guest-native": ("powershell", None),
    "powershell-guest-platform": ("powershell", None),
    "powershell-guest-uia": ("powershell", None),
    "powershell-guest-state": ("powershell", None),
    "powershell-guest-scenario": ("powershell", None),
    "powershell-guest-runtime": ("powershell", None),
    "powershell-guest-entry": ("powershell", None),
    "powershell-ui-bootstrap": ("powershell", None),
    "powershell-ui-appearance": ("powershell", None),
    "powershell-ui-native": ("powershell", None),
    "powershell-ui-menu": ("powershell", None),
    "powershell-ui-input": ("powershell", None),
    "powershell-ui-application": ("powershell", None),
    "powershell-ui-fixtures": ("powershell", None),
    "powershell-ui-context-scenarios": ("powershell", None),
    "powershell-ui-regression": ("powershell", None),
    "powershell-ui-current-dpi": ("powershell", None),
    "powershell-ui-entry": ("powershell", None),
    "powershell-recovery-bootstrap": ("powershell", None),
    "powershell-recovery-journal": ("powershell", None),
    "powershell-recovery-evidence": ("powershell", None),
    "powershell-recovery-process": ("powershell", None),
    "powershell-recovery-native": ("powershell", None),
    "powershell-recovery-worker": ("powershell", None),
    "powershell-recovery-scenarios": ("powershell", None),
    "powershell-recovery-entry": ("powershell", None),
    "powershell-controller-contracts": ("powershell", None),
    "powershell-controller-transport": ("powershell", None),
    "powershell-controller-poll": ("powershell", None),
    "powershell-controller-rescue": ("powershell", None),
    "powershell-controller-entry": ("powershell", None),
    "powershell-guest": ("powershell", None),
    "powershell-ui-observer": ("powershell", None),
    "powershell-recovery-observer": ("powershell", None),
    "release-tooling": ("powershell", None),
})

_ENTRY_KEYS = frozenset(
    {"role", "source", "bundle", "kind", "module", "sha256", "dependencies"}
)
_MANIFEST_KEYS = frozenset({"schema_version", "modules"})
_DIGEST_RE = re.compile(r"[0-9a-f]{64}\Z")
_COMPONENT_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*\Z")
_MODULE_RE = re.compile(r"darkrenamer_tooling(?:\.[a-z][a-z0-9_]*)*\Z")
_WINDOWS_RESERVED = frozenset(
    {"CON", "PRN", "AUX", "NUL", "CLOCK$"}
    | {f"COM{index}" for index in range(1, 10)}
    | {f"LPT{index}" for index in range(1, 10)}
)
_REPARSE_POINT = 0x400


class ToolingBootstrapError(RuntimeError):
    """The tooling inventory or one of its authenticated files is invalid."""


@dataclass(frozen=True)
class ManifestEntry:
    role: str
    source: str
    bundle: str
    kind: str
    module: str | None
    sha256: str
    dependencies: tuple[str, ...]


@dataclass(frozen=True)
class _FrozenModule:
    entry: ManifestEntry
    source_bytes: bytes
    code: CodeType


@dataclass(frozen=True)
class VerifiedTooling:
    """A verified dependency closure whose executable bytes are immutable.

    Imported modules use a synthetic origin and intentionally have no real
    ``__file__``. Tooling entry points must receive their checkout or bundle root
    explicitly instead of inferring it from loader metadata.
    """

    manifest_bytes: bytes
    manifest_sha256: str
    mode: str
    required_roles: tuple[str, ...]
    entries: tuple[ManifestEntry, ...]
    _modules: tuple[_FrozenModule, ...]
    _files: tuple[tuple[str, bytes], ...]

    def bytes_for_role(self, role: str) -> bytes:
        """Return the frozen bytes for staging without reopening a source file."""
        for selected_role, data in self._files:
            if selected_role == role:
                return data
        raise ToolingBootstrapError(f"role is outside the verified closure: {role}")

    def importer(self) -> _ImportScope:
        """Return a context that imports only the verified Python closure."""
        return _ImportScope(self)


class _FrozenLoader(importlib.abc.Loader):
    def __init__(self, frozen: _FrozenModule, owner: object) -> None:
        self._frozen = frozen
        self._tooling_owner = owner

    def create_module(self, spec: Any) -> ModuleType | None:
        return None

    def exec_module(self, module: ModuleType) -> None:
        exec(self._frozen.code, module.__dict__)
        module.__tooling_source__ = self._frozen.entry.source
        module.__tooling_sha256__ = self._frozen.entry.sha256


class _FrozenFinder(importlib.abc.MetaPathFinder):
    def __init__(self, modules: tuple[_FrozenModule, ...]) -> None:
        self._by_name = {
            frozen.entry.module: frozen
            for frozen in modules
            if frozen.entry.module is not None
        }

    def find_spec(
        self,
        fullname: str,
        path: Sequence[str] | None = None,
        target: ModuleType | None = None,
    ) -> importlib.machinery.ModuleSpec | None:
        del path, target
        frozen = self._by_name.get(fullname)
        if frozen is None:
            if fullname == TOOLING_NAMESPACE or fullname.startswith(TOOLING_NAMESPACE + "."):
                raise ModuleNotFoundError(f"undeclared tooling module: {fullname}")
            return None
        is_package = frozen.entry.kind == "python-package"
        origin = f"verified-{frozen.entry.source}"
        return importlib.util.spec_from_loader(
            fullname,
            _FrozenLoader(frozen, self),
            origin=origin,
            is_package=is_package,
        )


def _shared_import_state() -> dict[str, Any]:
    # The import lock protects lazy initialization across separately loaded
    # copies of this library. No process state changes when merely importing it.
    _imp.acquire_lock()
    try:
        state = getattr(sys, "_darkrenamer_verified_tooling_state", None)
        if state is None:
            state = {"lock": threading.RLock(), "owner": None}
            sys._darkrenamer_verified_tooling_state = state
        return state
    finally:
        _imp.release_lock()


class _ImportScope:
    def __init__(self, verified: VerifiedTooling) -> None:
        self._verified = verified
        self._finder = _FrozenFinder(verified._modules)
        self._active = False
        self._state: dict[str, Any] | None = None

    def __enter__(self) -> _ImportScope:
        state = _shared_import_state()
        with state["lock"]:
            if self._active:
                raise ToolingBootstrapError("verified importer is already active")
            if state["owner"] is not None:
                raise ToolingBootstrapError("another verified tooling importer is active")
            shadowed = sorted(
                name
                for name in sys.modules
                if name == TOOLING_NAMESPACE or name.startswith(TOOLING_NAMESPACE + ".")
            )
            if shadowed:
                raise ToolingBootstrapError(
                    f"tooling namespace is already loaded: {', '.join(shadowed)}"
                )
            sys.meta_path.insert(0, self._finder)
            state["owner"] = self._finder
            self._state = state
            self._active = True
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        del exc_type, exc, traceback
        if self._state is not None:
            with self._state["lock"]:
                if not self._active:
                    return
                if self._state["owner"] is not self._finder:
                    raise ToolingBootstrapError("verified importer lost process ownership")
                sys.meta_path[:] = [finder for finder in sys.meta_path if finder is not self._finder]
                for name, module in list(sys.modules.items()):
                    loader = getattr(module, "__loader__", None)
                    if getattr(loader, "_tooling_owner", None) is self._finder:
                        del sys.modules[name]
                self._state["owner"] = None
                self._active = False

    def import_role(self, role: str) -> ModuleType:
        if self._state is None:
            raise ToolingBootstrapError("verified importer context is not active")
        with self._state["lock"]:
            if not self._active or self._state["owner"] is not self._finder:
                raise ToolingBootstrapError("verified importer context is not active")
            matches = [entry for entry in self._verified.entries if entry.role == role]
            if not matches:
                raise ToolingBootstrapError(f"role is outside the verified closure: {role}")
            entry = matches[0]
            if entry.module is None:
                raise ToolingBootstrapError(f"role is not a Python module: {role}")
            module = importlib.import_module(entry.module)
            if (getattr(getattr(module, "__loader__", None), "_tooling_owner", None)
                    is not self._finder or
                    getattr(module, "__tooling_sha256__", None) != entry.sha256):
                raise ToolingBootstrapError("imported module differs from its verified owner or digest")
            return module


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _is_reparse_point(metadata: os.stat_result) -> bool:
    return bool(getattr(metadata, "st_file_attributes", 0) & _REPARSE_POINT)


def _validate_root(root: str | os.PathLike[str]) -> Path:
    path = Path(root)
    if not path.is_absolute():
        raise ToolingBootstrapError("tooling root must be absolute")
    current = Path(path.anchor)
    try:
        for component in path.parts[1:]:
            current /= component
            metadata = os.lstat(current)
            if stat.S_ISLNK(metadata.st_mode) or _is_reparse_point(metadata):
                raise ToolingBootstrapError(f"tooling root contains a link: {current}")
        metadata = os.lstat(path)
    except OSError as error:
        raise ToolingBootstrapError(f"could not inspect tooling root: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise ToolingBootstrapError("tooling root is not a directory")
    return path


def _validate_component(component: str) -> None:
    if not _COMPONENT_RE.fullmatch(component) or component in {".", ".."}:
        raise ToolingBootstrapError(f"non-canonical path component: {component!r}")
    if component.endswith((".", " ")) or "~" in component:
        raise ToolingBootstrapError(f"unsafe path component: {component!r}")
    stem = component.split(".", 1)[0].upper()
    if stem in _WINDOWS_RESERVED:
        raise ToolingBootstrapError(f"reserved path component: {component!r}")


def _validate_relative_path(value: Any, *, source: bool = False, flat: bool = False) -> str:
    if type(value) is not str or not value or "\\" in value or "\x00" in value:
        raise ToolingBootstrapError("path must be a non-empty canonical string")
    components = value.split("/")
    if flat and len(components) != 1:
        raise ToolingBootstrapError(f"bundle path must be a flat filename: {value!r}")
    if any(not component for component in components):
        raise ToolingBootstrapError(f"path contains an empty component: {value!r}")
    for component in components:
        _validate_component(component)
    if source and (len(components) < 2 or components[0] != "scripts"):
        raise ToolingBootstrapError(f"source path must be below scripts/: {value!r}")
    return value


def _read_fd_bounded(file_descriptor: int, limit: int, label: str) -> bytes:
    before = os.fstat(file_descriptor)
    if not stat.S_ISREG(before.st_mode) or _is_reparse_point(before):
        raise ToolingBootstrapError(f"{label} is not an ordinary file")
    if before.st_size > limit:
        raise ToolingBootstrapError(f"{label} exceeds the size limit")
    chunks: list[bytes] = []
    total = 0
    while total <= limit:
        chunk = os.read(file_descriptor, min(64 * 1024, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    if total > limit:
        raise ToolingBootstrapError(f"{label} exceeds the size limit")
    after = os.fstat(file_descriptor)
    identity_before = (before.st_dev, before.st_ino, before.st_size)
    identity_after = (after.st_dev, after.st_ino, after.st_size)
    if identity_before != identity_after or total != after.st_size:
        raise ToolingBootstrapError(f"{label} changed while it was read")
    return b"".join(chunks)


def _read_relative_posix(root: Path, relative: str, limit: int, label: str) -> bytes:
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    file_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NONBLOCK", 0)
    descriptors: list[int] = []
    try:
        current = os.open(root, directory_flags)
        descriptors.append(current)
        components = relative.split("/")
        for component in components[:-1]:
            current = os.open(component, directory_flags, dir_fd=current)
            descriptors.append(current)
        file_descriptor = os.open(components[-1], file_flags, dir_fd=current)
        descriptors.append(file_descriptor)
        return _read_fd_bounded(file_descriptor, limit, label)
    except ToolingBootstrapError:
        raise
    except OSError as error:
        raise ToolingBootstrapError(f"could not read {label}: {error}") from error
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def _read_relative_portable(root: Path, relative: str, limit: int, label: str) -> bytes:
    path = root
    snapshots: list[tuple[Path, tuple[int, int]]] = []
    try:
        for component in relative.split("/"):
            path /= component
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode) or _is_reparse_point(metadata):
                raise ToolingBootstrapError(f"{label} contains a link")
            snapshots.append((path, (metadata.st_dev, metadata.st_ino)))
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_BINARY", 0)
        flags |= getattr(os, "O_NOINHERIT", 0)
        flags |= getattr(os, "O_NONBLOCK", 0)
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != snapshots[-1][1]:
                raise ToolingBootstrapError(f"{label} resolved to a different file")
            data = _read_fd_bounded(descriptor, limit, label)
        finally:
            os.close(descriptor)
        for observed_path, identity in snapshots:
            metadata = os.lstat(observed_path)
            if (metadata.st_dev, metadata.st_ino) != identity:
                raise ToolingBootstrapError(f"{label} path changed while it was read")
        return data
    except ToolingBootstrapError:
        raise
    except OSError as error:
        raise ToolingBootstrapError(f"could not read {label}: {error}") from error


def _read_relative(root: Path, relative: str, limit: int, label: str) -> bytes:
    relative = _validate_relative_path(relative)
    if os.name == "posix" and hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"):
        return _read_relative_posix(root, relative, limit, label)
    return _read_relative_portable(root, relative, limit, label)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ToolingBootstrapError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _parse_manifest(manifest_bytes: bytes) -> tuple[ManifestEntry, ...]:
    try:
        value = json.loads(manifest_bytes.decode("utf-8"), object_pairs_hook=_unique_object)
    except ToolingBootstrapError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ToolingBootstrapError(f"invalid tooling manifest JSON: {error}") from error
    if type(value) is not dict or frozenset(value) != _MANIFEST_KEYS:
        raise ToolingBootstrapError(
            "tooling manifest must contain exactly schema_version and modules"
        )
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ToolingBootstrapError("unsupported tooling manifest schema_version")
    modules = value["modules"]
    if type(modules) is not list or not 1 <= len(modules) <= MAX_MODULES:
        raise ToolingBootstrapError("tooling manifest modules must be a bounded non-empty array")

    entries: list[ManifestEntry] = []
    roles: set[str] = set()
    source_names: set[str] = set()
    bundle_names: set[str] = set()
    module_names: set[str] = set()
    for raw in modules:
        if type(raw) is not dict or frozenset(raw) != _ENTRY_KEYS:
            raise ToolingBootstrapError("module entries must contain exactly the supported fields")
        role = raw["role"]
        if type(role) is not str or role not in SUPPORTED_ROLES:
            raise ToolingBootstrapError(f"unsupported tooling role: {role!r}")
        if role in roles:
            raise ToolingBootstrapError(f"duplicate tooling role: {role}")
        roles.add(role)
        kind = raw["kind"]
        expected_kind, expected_module = SUPPORTED_ROLES[role]
        if type(kind) is not str or expected_kind != kind:
            raise ToolingBootstrapError(f"role {role} has the wrong implementation kind")
        source = _validate_relative_path(raw["source"], source=True)
        bundle = _validate_relative_path(raw["bundle"], flat=True)
        for name, seen, label in (
            (source, source_names, "source path"),
            (bundle, bundle_names, "bundle filename"),
        ):
            folded = name.casefold()
            if folded in seen:
                raise ToolingBootstrapError(f"case-colliding {label}: {name}")
            seen.add(folded)
        expected_suffixes = (".ps1", ".psm1") if kind == "powershell" else (".py",)
        if not source.endswith(expected_suffixes) or not bundle.endswith(expected_suffixes):
            raise ToolingBootstrapError(f"role {role} has a filename inconsistent with its kind")
        module = raw["module"]
        if module != expected_module:
            raise ToolingBootstrapError(f"role {role} has the wrong Python module name")
        if kind == "powershell":
            if module is not None:
                raise ToolingBootstrapError(f"PowerShell role {role} must have a null module")
        else:
            if type(module) is not str or not _MODULE_RE.fullmatch(module):
                raise ToolingBootstrapError(f"invalid Python module name for role {role}")
            if kind == "python" and module == TOOLING_NAMESPACE:
                raise ToolingBootstrapError(
                    "a Python module cannot replace the package initializer"
                )
            folded_module = module.casefold()
            if folded_module in module_names:
                raise ToolingBootstrapError(f"case-colliding Python module: {module}")
            module_names.add(folded_module)
        sha256 = raw["sha256"]
        if type(sha256) is not str or not _DIGEST_RE.fullmatch(sha256):
            raise ToolingBootstrapError(f"invalid SHA-256 for role {role}")
        dependencies = raw["dependencies"]
        if type(dependencies) is not list or any(type(item) is not str for item in dependencies):
            raise ToolingBootstrapError(f"dependencies for role {role} must be an array of roles")
        if len(dependencies) != len(set(dependencies)) or role in dependencies:
            raise ToolingBootstrapError(f"dependencies for role {role} are not unique and acyclic")
        entries.append(
            ManifestEntry(
                role, source, bundle, kind, module, sha256, tuple(dependencies)
            )
        )

    by_role = {entry.role: entry for entry in entries}
    package_entries = [entry for entry in entries if entry.kind == "python-package"]
    packages_by_module = {entry.module: entry for entry in package_entries}
    if any(
        entry.kind in {"python", "python-package"}
        for entry in entries
    ):
        root_package = packages_by_module.get(TOOLING_NAMESPACE)
        if root_package is None:
            raise ToolingBootstrapError("Python modules require the root package initializer")
    for entry in entries:
        unknown = [dependency for dependency in entry.dependencies if dependency not in by_role]
        if unknown:
            raise ToolingBootstrapError(
                f"role {entry.role} has unknown dependencies: {', '.join(unknown)}"
            )
        if entry.kind in {"python", "python-package"}:
            if entry.module is None:
                raise ToolingBootstrapError(f"Python role {entry.role} has no module name")
            parts = entry.module.split(".")
            ancestor_modules = [".".join(parts[:index]) for index in range(1, len(parts))]
            for ancestor_module in ancestor_modules:
                ancestor = packages_by_module.get(ancestor_module)
                if ancestor is None:
                    raise ToolingBootstrapError(
                        f"Python role {entry.role} is missing package {ancestor_module}"
                    )
                if ancestor.role not in entry.dependencies:
                    raise ToolingBootstrapError(
                        f"Python role {entry.role} must explicitly depend on {ancestor.role}"
                    )

    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(role: str) -> None:
        if role in visiting:
            raise ToolingBootstrapError(f"dependency cycle includes role {role}")
        if role in visited:
            return
        visiting.add(role)
        for dependency in by_role[role].dependencies:
            visit(dependency)
        visiting.remove(role)
        visited.add(role)

    for entry in entries:
        visit(entry.role)
    return tuple(entries)


def verify_tooling(
    *,
    root: str | os.PathLike[str],
    manifest_location: str,
    expected_manifest_sha256: str,
    mode: str,
    required_roles: Sequence[str],
) -> VerifiedTooling:
    """Verify and freeze the selected tooling dependency closure.

    ``mode`` selects repository ``source`` paths or flat packaged ``bundle``
    filenames. No module code runs until the caller enters ``importer()``.
    """
    root_path = _validate_root(root)
    if mode not in {"checkout", "bundle"}:
        raise ToolingBootstrapError(f"unsupported tooling mode: {mode!r}")
    if type(expected_manifest_sha256) is not str or not _DIGEST_RE.fullmatch(
        expected_manifest_sha256
    ):
        raise ToolingBootstrapError("trusted manifest SHA-256 must be lowercase hexadecimal")
    manifest_location = _validate_relative_path(
        manifest_location, flat=mode == "bundle"
    )
    manifest_bytes = _read_relative(
        root_path, manifest_location, MAX_MANIFEST_BYTES, "tooling manifest"
    )
    observed_manifest_sha256 = _sha256(manifest_bytes)
    if observed_manifest_sha256 != expected_manifest_sha256:
        raise ToolingBootstrapError("tooling manifest SHA-256 does not match the trusted pin")
    entries = _parse_manifest(manifest_bytes)
    by_role = {entry.role: entry for entry in entries}
    if type(required_roles) not in {tuple, list} or not required_roles:
        raise ToolingBootstrapError("at least one required tooling role must be selected")
    selected = tuple(required_roles)
    if any(type(role) is not str for role in selected) or len(selected) != len(set(selected)):
        raise ToolingBootstrapError("required tooling roles must be unique strings")
    unknown = [role for role in selected if role not in by_role]
    if unknown:
        raise ToolingBootstrapError(f"required tooling roles are absent: {', '.join(unknown)}")

    closure: set[str] = set()

    def select(role: str) -> None:
        if role in closure:
            return
        for dependency in by_role[role].dependencies:
            select(dependency)
        closure.add(role)

    for role in selected:
        select(role)

    selected_entries = tuple(entry for entry in entries if entry.role in closure)
    frozen_modules: list[_FrozenModule] = []
    frozen_files: list[tuple[str, bytes]] = []
    total_module_bytes = 0
    for entry in selected_entries:
        relative = entry.source if mode == "checkout" else entry.bundle
        source_bytes = _read_relative(
            root_path, relative, MAX_MODULE_BYTES, f"tooling role {entry.role}"
        )
        if _sha256(source_bytes) != entry.sha256:
            raise ToolingBootstrapError(f"SHA-256 mismatch for tooling role {entry.role}")
        total_module_bytes += len(source_bytes)
        if total_module_bytes > MAX_TOTAL_MODULE_BYTES:
            raise ToolingBootstrapError("selected tooling closure exceeds the aggregate size limit")
        frozen_files.append((entry.role, source_bytes))
        if entry.kind != "powershell":
            origin = f"verified-{entry.source}"
            try:
                code = compile(source_bytes, origin, "exec", dont_inherit=True)
            except (SyntaxError, ValueError, OverflowError, RecursionError) as error:
                raise ToolingBootstrapError(
                    f"invalid Python source for tooling role {entry.role}: {error}"
                ) from error
            frozen_modules.append(_FrozenModule(entry, source_bytes, code))

    return VerifiedTooling(
        manifest_bytes=manifest_bytes,
        manifest_sha256=observed_manifest_sha256,
        mode=mode,
        required_roles=selected,
        entries=selected_entries,
        _modules=tuple(frozen_modules),
        _files=tuple(frozen_files),
    )
