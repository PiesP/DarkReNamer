"""Independent filesystem-state predicates for VM-Automated evidence.

These functions compare raw observations. They neither authenticate a producer
nor grant a profile verdict; the enclosing verifier must bind the candidate,
observer, environment, execution history, and cleanup separately.
"""

from __future__ import annotations

from dataclasses import dataclass
import re

from vm_automated_evidence import EvidenceError, require_exact_keys, require_int


HEX64 = re.compile(r"[0-9a-f]{64}\Z")
HEX16 = re.compile(r"[0-9a-f]{16}\Z")
HEX32 = re.compile(r"[0-9a-f]{32}\Z")
MAX_FIXTURES = 10_001
MAX_FILE_BYTES = 64 * 1024 * 1024
RESERVED = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)),
            *(f"LPT{i}" for i in range(1, 10))}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def leaf_name(value: object) -> str:
    require(type(value) is str and 0 < len(value) <= 255,
            "Fixture name must be a bounded leaf.")
    require(not any(ord(char) < 32 or char in '<>:"/\\|?*' for char in value)
            and value not in {".", ".."} and not value.endswith((" ", "."))
            and value.split(".", 1)[0].upper() not in RESERVED,
            "Fixture name is not an ordinary Windows leaf.")
    try:
        require(len(value.encode("utf-16-le")) // 2 <= 255,
                "Fixture name exceeds the UTF-16 bound.")
    except UnicodeEncodeError as error:
        raise EvidenceError("Fixture name contains an unpaired surrogate.") from error
    return value


def digest(value: object) -> str:
    require(type(value) is str and HEX64.fullmatch(value) is not None,
            "Content or identity digest must be lowercase SHA-256.")
    return value


@dataclass(frozen=True)
class Identity:
    """FILE_ID_INFO numeric tuple, matching the product's u64/u128 fields."""

    volume: int
    file_id: int

    @classmethod
    def parse(cls, value: object) -> Identity:
        row = require_exact_keys(value, {"volume_serial", "file_id"}, "FILE_ID_INFO")
        require(type(row["volume_serial"]) is str and
                HEX16.fullmatch(row["volume_serial"]) is not None,
                "Volume serial must preserve all 64 bits.")
        require(type(row["file_id"]) is str and HEX32.fullmatch(row["file_id"]) is not None,
                "File ID must preserve all 128 bits.")
        return cls(int(row["volume_serial"], 16), int(row["file_id"], 16))


@dataclass(frozen=True)
class FileState:
    size: int
    content_sha256: str
    identity: Identity | str


def fixture_inventory(value: object, *, full_identity: bool) -> dict[str, FileState]:
    require(type(value) is list and 0 < len(value) <= MAX_FIXTURES,
            "Fixture inventory must enumerate every bounded regular file.")
    files: dict[str, FileState] = {}
    folded: set[str] = set()
    identities: set[Identity | str] = set()
    identity_field = "file_identity" if full_identity else "file_identity_sha256"
    for raw in value:
        row = require_exact_keys(raw, {"name", "kind", "bytes", "content_sha256",
                                       identity_field}, "Fixture row")
        name = leaf_name(row["name"])
        require(name.casefold() not in folded, "Fixture inventory repeats or aliases a name.")
        require(row["kind"] == "file", "Fixture inventory contains a non-file entry.")
        size = require_int(row["bytes"], 0, MAX_FILE_BYTES, "Fixture bytes")
        content = digest(row["content_sha256"])
        identity = Identity.parse(row[identity_field]) if full_identity else digest(row[identity_field])
        require(identity not in identities, "Independent fixture files share an identity.")
        identities.add(identity)
        folded.add(name.casefold())
        files[name] = FileState(size, content, identity)
    return files


def clean_journal_inventory(value: object) -> tuple[tuple[str, int], ...]:
    """Permit only the observed zero-byte runtime lock, never residue counts."""
    require(type(value) is list and len(value) <= 1,
            "Clean journal inventory contains unexpected or repeated entries.")
    entries = []
    for raw in value:
        row = require_exact_keys(raw, {"name", "kind", "bytes"}, "Clean journal row")
        require(row["name"] == "runtime.lock" and row["kind"] == "file",
                "Active, candidate, directory, or unknown journal residue remains.")
        require_int(row["bytes"], 0, 0, "Runtime lock bytes")
        entries.append((row["name"], row["bytes"]))
    return tuple(entries)


def core_rename_checkpoints(value: object, *, source_name: str, destination_name: str,
                            full_identity: bool = False) -> dict[str, FileState]:
    """Derive Cancel invariance and Apply preservation from four whole inventories."""
    source_name, destination_name = leaf_name(source_name), leaf_name(destination_name)
    require(source_name.casefold() != destination_name.casefold(),
            "The core prefix trial must change the fixture name.")
    phases = ("initial", "after_cancel", "after_apply", "post_close")
    require(type(value) is list and len(value) == len(phases),
            "Core trial needs exactly four ordered checkpoint inventories.")
    snapshots = []
    journals = []
    for raw, phase in zip(value, phases, strict=True):
        row = require_exact_keys(raw, {"phase", "fixture_entries", "journal_entries"},
                                 "Core checkpoint")
        require(row["phase"] == phase, "Core checkpoint order or phase differs.")
        snapshots.append(fixture_inventory(row["fixture_entries"], full_identity=full_identity))
        journals.append(clean_journal_inventory(row["journal_entries"]))
    initial, cancelled, applied, closed = snapshots
    require(set(initial) == {source_name} and cancelled == initial,
            "Cancel changed the complete initial fixture inventory.")
    require(journals[1] == journals[0], "Cancel changed the journal inventory.")
    expected = {destination_name: initial[source_name]}
    require(applied == expected and closed == expected,
            "Apply or normal close changed fixture contents, size, identity, or inventory.")
    return closed


def restored_inventory(initial: object, restored: object, *, expected_count: int) -> dict[str, FileState]:
    require_int(expected_count, 1, MAX_FIXTURES, "Expected fixture count")
    before = fixture_inventory(initial, full_identity=True)
    after = fixture_inventory(restored, full_identity=True)
    require(len(before) == expected_count and after == before,
            "Rollback did not restore the complete original fixture inventory.")
    return before


def interrupted_inventory(initial: object, partial: object, *, renames: list[tuple[str, str]],
                          completed: int, prepared: int | None,
                          protected_names: tuple[str, ...]) -> int:
    """Join a validated forward journal prefix to quiescent on-disk observations.

    `renames`, `completed`, and `prepared` must come from strict journal replay,
    with every journal identity cross-bound to the initial FILE_ID_INFO rows.
    A pending Prepared rename may have reached disk before its completion frame.
    Both possibilities are explicit; all unrelated fixture rows remain identical.
    """
    before = fixture_inventory(initial, full_identity=True)
    after = fixture_inventory(partial, full_identity=True)
    require(type(protected_names) is tuple and 0 < len(protected_names) <= MAX_FIXTURES,
            "Recovery trial requires explicit protected sentinel names.")
    protected = {leaf_name(name).casefold() for name in protected_names}
    require(len(protected) == len(protected_names) and
            all(name in before for name in protected_names),
            "Protected sentinels must be unique and present in the initial inventory.")
    require(type(renames) is list and 1 < len(renames) < MAX_FIXTURES,
            "Recovery trial needs a bounded schedule with multiple files.")
    require_int(completed, 0, len(renames), "Completed forward prefix")
    require(prepared is None or type(prepared) is int and prepared == completed < len(renames),
            "Prepared step is not the next forward operation.")
    sources: set[str] = set()
    destinations: set[str] = set()
    initial_names = {name.casefold() for name in before}
    for pair in renames:
        require(type(pair) is tuple and len(pair) == 2, "Rename schedule has an invalid pair.")
        source, destination = leaf_name(pair[0]), leaf_name(pair[1])
        require(source.casefold() not in protected and destination.casefold() not in protected,
                "Recovery schedule must never rename or replace a protected sentinel.")
        require(source in before and source.casefold() not in sources and
                destination.casefold() not in destinations and
                destination.casefold() not in initial_names,
                "Recovery schedule aliases a source, destination, or existing fixture.")
        sources.add(source.casefold())
        destinations.add(destination.casefold())
    require(sources == initial_names - protected,
            "Recovery schedule must cover exactly the non-sentinel fixture files.")
    possibilities = [completed] if prepared is None else [completed, completed + 1]
    for count in possibilities:
        if not 0 < count < len(renames):
            continue
        expected = dict(before)
        for source, destination in renames[:count]:
            expected[destination] = expected.pop(source)
        if after == expected:
            return count
    raise EvidenceError("Quiescent files do not match a genuine partial journal prefix.")
