#!/usr/bin/env python3
"""Focused tests for VM-automated evidence transport primitives."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zlib
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile, ZipInfo


SCRIPT = Path(__file__).with_name("vm_automated_evidence.py")
SPEC = importlib.util.spec_from_file_location("vm_automated_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
evidence = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = evidence
SPEC.loader.exec_module(evidence)


def file_reference(data: bytes) -> object:
    return evidence.FileReference(hashlib.sha256(data).hexdigest(), len(data))


def archive_reference(path: Path) -> object:
    return file_reference(path.read_bytes())


def write_zip(path: Path, entries: dict[str, bytes], *, compression: int = ZIP_DEFLATED) -> None:
    with ZipFile(path, "w", compression=compression) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)


def mutate_zip_headers(path: Path, *, flags: int | None = None,
                       compression: int | None = None) -> None:
    data = bytearray(path.read_bytes())
    local = data.index(b"PK\x03\x04")
    central = data.index(b"PK\x01\x02")
    if flags is not None:
        struct.pack_into("<H", data, local + 6, flags)
        struct.pack_into("<H", data, central + 8, flags)
    if compression is not None:
        struct.pack_into("<H", data, local + 8, compression)
        struct.pack_into("<H", data, central + 10, compression)
    path.write_bytes(data)


def corrupt_stored_payload(path: Path) -> None:
    data = bytearray(path.read_bytes())
    local = data.index(b"PK\x03\x04")
    name_length, extra_length = struct.unpack_from("<HH", data, local + 26)
    payload = local + 30 + name_length + extra_length
    data[payload] ^= 0x01
    path.write_bytes(data)


def underreport_first_member(path: Path, declared: bytes) -> None:
    data = bytearray(path.read_bytes())
    local = data.index(b"PK\x03\x04")
    central = data.index(b"PK\x01\x02")
    checksum = zlib.crc32(declared) & 0xFFFFFFFF
    struct.pack_into("<I", data, local + 14, checksum)
    struct.pack_into("<I", data, central + 16, checksum)
    struct.pack_into("<I", data, local + 22, len(declared))
    struct.pack_into("<I", data, central + 24, len(declared))
    path.write_bytes(data)


def statement_fixture() -> dict[str, object]:
    return {
        "schema": "darkrenamer-vm-automated-statement-v1",
        "result": "passed",
        "candidate": {
            "repository": "PiesP/DarkReNamer",
            "source_sha": "1" * 40,
            "run_id": 101,
            "run_attempt": 2,
            "artifact_id": 303,
            "artifact_sha256": "2" * 64,
            "executable_sha256": "3" * 64,
            "handoff_sha256": "4" * 64,
        },
        "harness": {
            "repository": "PiesP/DarkReNamer",
            "source_sha": "5" * 40,
            "components": [
                {"role": "validator", "sha256": "7" * 64},
                {"role": "controller", "sha256": "6" * 64},
            ],
        },
        "profile": {
            "id": "vm-automated-v1-win11-ntfs",
            "revision": 1,
            "sha256": "8" * 64,
        },
        "environment": {
            "os_family": "Windows 11",
            "architecture": "x86_64",
            "filesystem": "NTFS",
            "desktop_mode": "managed-rdp",
            "elevated": False,
            "concurrency": 1,
        },
        "targets": [
            {"id": target_id, "verdict": "passed"}
            for target_id in reversed(sorted(evidence.REQUIRED_TARGET_IDS))
        ],
        "required_gates": [
            {"id": gate_id, "sha256": hashlib.sha256(gate_id.encode()).hexdigest()}
            for gate_id in reversed(sorted(evidence.REQUIRED_GATE_IDS))
        ],
        "ingress": {
            "release_id": 404,
            "asset_id": 505,
            "sha256": "9" * 64,
            "size": 606,
        },
        "validation": {"run_id": 707, "run_attempt": 3},
    }


# Independent literal fixture: no JSON encoder is used to form the expected bytes.
GOLDEN_STATEMENT = (
    b'{"candidate":{"artifact_id":303,"artifact_sha256":"2222222222222222222222222222222222222222222222222222222222222222",'
    b'"executable_sha256":"3333333333333333333333333333333333333333333333333333333333333333",'
    b'"handoff_sha256":"4444444444444444444444444444444444444444444444444444444444444444",'
    b'"repository":"PiesP/DarkReNamer","run_attempt":2,"run_id":101,"source_sha":"1111111111111111111111111111111111111111"},'
    b'"environment":{"architecture":"x86_64","concurrency":1,"desktop_mode":"managed-rdp","elevated":false,"filesystem":"NTFS","os_family":"Windows 11"},'
    b'"harness":{"components":[{"role":"controller","sha256":"6666666666666666666666666666666666666666666666666666666666666666"},'
    b'{"role":"validator","sha256":"7777777777777777777777777777777777777777777777777777777777777777"}],'
    b'"repository":"PiesP/DarkReNamer","source_sha":"5555555555555555555555555555555555555555"},'
    b'"ingress":{"asset_id":505,"release_id":404,"sha256":"9999999999999999999999999999999999999999999999999999999999999999","size":606},'
    b'"profile":{"id":"vm-automated-v1-win11-ntfs","revision":1,"sha256":"8888888888888888888888888888888888888888888888888888888888888888"},'
    b'"required_gates":[{"id":"candidate-package-and-provenance","sha256":"e1efd5934fb32e254ea04c9b9e98cd5561cdbfed8601d407bf86e52725de59fb"},'
    b'{"id":"immutable-promotion-binding","sha256":"5f4738b1ef67e16f4b8005ef686dff60b34c1ca874f0fe3eb279c25c0d36775c"},'
    b'{"id":"locked-host-gate","sha256":"99f81ae1be0deb14c91017f2fa973b377f9929aaab1a73c7c5e8e226a3764ee8"},'
    b'{"id":"profile-raw-evidence-verifier","sha256":"ccc73226c64e890ba6714ed7f830e09d26ece3d478e81cb90799c211da1ec749"},'
    b'{"id":"windows-backend-source-bound","sha256":"fe04169703e3d20c249e8f9de1c164c3bcf8a9ea075e38c150c6057b89698d2e"}],'
    b'"result":"passed","schema":"darkrenamer-vm-automated-statement-v1","targets":['
    b'{"id":"core-keyboard-flow","verdict":"passed"},{"id":"core-uia-flow","verdict":"passed"},'
    b'{"id":"intent-only-discard","verdict":"passed"},{"id":"layout-high-contrast-100","verdict":"passed"},'
    b'{"id":"layout-high-contrast-125","verdict":"passed"},{"id":"layout-high-contrast-150","verdict":"passed"},'
    b'{"id":"layout-high-contrast-200","verdict":"passed"},{"id":"layout-high-contrast-250","verdict":"passed"},'
    b'{"id":"layout-high-contrast-300","verdict":"passed"},{"id":"layout-normal-100","verdict":"passed"},'
    b'{"id":"layout-normal-125","verdict":"passed"},{"id":"layout-normal-150","verdict":"passed"},'
    b'{"id":"layout-normal-200","verdict":"passed"},{"id":"layout-normal-250","verdict":"passed"},'
    b'{"id":"layout-normal-300","verdict":"passed"},{"id":"layout-small-high-contrast-100","verdict":"passed"},'
    b'{"id":"layout-small-normal-100","verdict":"passed"},{"id":"layout-small-text150-100","verdict":"passed"},'
    b'{"id":"process-crash","verdict":"passed"},{"id":"recovery-export","verdict":"passed"},'
    b'{"id":"worker-cancellation","verdict":"passed"},{"id":"worker-close","verdict":"passed"}],'
    b'"validation":{"run_attempt":3,"run_id":707}}\n'
)


class StrictJsonTests(unittest.TestCase):
    def test_parse_bounded_json_rejects_duplicate_nonfinite_and_oversize(self) -> None:
        with self.assertRaisesRegex(evidence.EvidenceError, "duplicate field"):
            evidence.parse_bounded_json_bytes(b'{"x":1,"x":2}')
        for raw in (b'{"x":NaN}', b'{"x":Infinity}', b'{"x":-Infinity}'):
            with self.subTest(raw=raw), self.assertRaisesRegex(
                    evidence.EvidenceError, "non-finite"):
                evidence.parse_bounded_json_bytes(raw)
        with self.assertRaisesRegex(evidence.EvidenceError, "exceeds"):
            evidence.parse_bounded_json_bytes(b"[] ", max_bytes=2)

    def test_integer_contract_rejects_boolean_and_unbounded_integer(self) -> None:
        with self.assertRaisesRegex(evidence.EvidenceError, "not a boolean"):
            evidence.FileReference.from_json({"sha256": "0" * 64, "size": True})
        with self.assertRaisesRegex(evidence.EvidenceError, "64-bit"):
            evidence.parse_bounded_json_bytes(b'{"x":18446744073709551616}')

    def test_load_bounded_json_requires_an_ordinary_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.json"
            target.write_bytes(b'{"ok":true}')
            self.assertEqual(evidence.load_bounded_json(target), {"ok": True})
            link = root / "link.json"
            link.symlink_to(target)
            with self.assertRaisesRegex(evidence.EvidenceError, "ordinary file"):
                evidence.load_bounded_json(link)


class ReferencedFileTests(unittest.TestCase):
    def test_referenced_file_is_root_contained_ordinary_and_exact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "raw").mkdir()
            data = b'{"value":1}\n'
            (root / "raw" / "value.json").write_bytes(data)
            reference = file_reference(data)
            evidence.verify_referenced_file(root, "raw/value.json", reference)
            self.assertEqual(
                evidence.load_referenced_json(root, "raw/value.json", reference),
                {"value": 1},
            )
            with self.assertRaisesRegex(evidence.EvidenceError, "traversal"):
                evidence.verify_referenced_file(root, "../value.json", reference)
            with self.assertRaisesRegex(evidence.EvidenceError, "SHA-256"):
                evidence.verify_referenced_file(
                    root, "raw/value.json", evidence.FileReference("0" * 64, len(data)))

    def test_referenced_file_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside.json"
            outside.write_bytes(b"{}")
            (root / "inside.json").symlink_to(outside)
            with self.assertRaisesRegex(evidence.EvidenceError, "safely"):
                evidence.verify_referenced_file(root, "inside.json", file_reference(b"{}"))


class ArchiveIngressTests(unittest.TestCase):
    def test_success_is_private_nonexecutable_exact_and_always_cleaned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            archive_path = parent / "evidence.zip"
            manifest = b'{"version":1}\n'
            raw = b"raw-observation"
            with ZipFile(archive_path, "w", compression=ZIP_DEFLATED) as archive:
                archive.writestr("raw/", b"")
                archive.writestr("manifest.json", manifest)
                archive.writestr("raw/observation.bin", raw)
            allowed = {
                "manifest.json": file_reference(manifest),
                "raw/observation.bin": file_reference(raw),
            }
            extracted_root: Path | None = None
            with evidence.open_verified_evidence_archive(
                    archive_path, archive_reference(archive_path), parent, allowed) as extracted:
                extracted_root = extracted.root
                self.assertTrue(extracted.root.is_dir())
                self.assertEqual(stat.S_IMODE(extracted.root.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(
                    (extracted.root / "raw" / "observation.bin").stat().st_mode), 0o600)
                self.assertEqual(evidence.load_referenced_json(
                    extracted.root, "manifest.json", allowed["manifest.json"]), {"version": 1})
            assert extracted_root is not None
            self.assertFalse(extracted_root.exists())

    def test_unsafe_alias_and_traversal_paths_are_rejected(self) -> None:
        unsafe = [
            "/absolute.json", "../traversal.json", "raw\\backslash.json",
            "C:drive.json", "CON.json", "raw/AUX.txt", "raw/trailing.",
            "raw/long~1.json", "raw//empty.json", "caf\u00e9.json",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            for index, name in enumerate(unsafe):
                with self.subTest(name=name):
                    archive_path = parent / f"unsafe-{index}.zip"
                    write_zip(archive_path, {name: b"x"})
                    with self.assertRaises(evidence.EvidenceError):
                        with evidence.open_verified_evidence_archive(
                                archive_path, archive_reference(archive_path), parent,
                                {name: file_reference(b"x")}):
                            self.fail("unsafe archive was extracted")

    def test_duplicate_and_case_colliding_names_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            duplicate = parent / "duplicate.zip"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with ZipFile(duplicate, "w") as archive:
                    archive.writestr("raw.json", b"x")
                    archive.writestr("raw.json", b"x")
            with self.assertRaisesRegex(evidence.EvidenceError, "duplicate"):
                with evidence.open_verified_evidence_archive(
                        duplicate, archive_reference(duplicate), parent,
                        {"raw.json": file_reference(b"x")}):
                    self.fail("duplicate archive was extracted")

            collision = parent / "collision.zip"
            write_zip(collision, {"raw.json": b"x", "RAW.json": b"y"})
            with self.assertRaisesRegex(evidence.EvidenceError, "collide by case"):
                with evidence.open_verified_evidence_archive(
                        collision, archive_reference(collision), parent,
                        {"raw.json": file_reference(b"x"), "RAW.json": file_reference(b"y")}):
                    self.fail("case-colliding archive was extracted")

            component_collision = parent / "component-collision.zip"
            write_zip(component_collision, {"Raw/a.json": b"x", "raw/b.json": b"y"})
            with self.assertRaisesRegex(evidence.EvidenceError, "components collide by case"):
                with evidence.open_verified_evidence_archive(
                        component_collision, archive_reference(component_collision), parent,
                        {"Raw/a.json": file_reference(b"x"),
                         "raw/b.json": file_reference(b"y")}):
                    self.fail("component-colliding archive was extracted")

    def test_link_device_encryption_and_unsupported_compression_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            for kind, mode in (("link", stat.S_IFLNK | 0o777),
                               ("device", stat.S_IFCHR | 0o600)):
                archive_path = parent / f"{kind}.zip"
                info = ZipInfo("raw.bin")
                info.create_system = 3
                info.external_attr = mode << 16
                with ZipFile(archive_path, "w") as archive:
                    archive.writestr(info, b"x")
                with self.subTest(kind=kind), self.assertRaises(evidence.EvidenceError):
                    with evidence.open_verified_evidence_archive(
                            archive_path, archive_reference(archive_path), parent,
                            {"raw.bin": file_reference(b"x")}):
                        self.fail("unsafe file type was extracted")

            encrypted = parent / "encrypted.zip"
            write_zip(encrypted, {"raw.bin": b"x"}, compression=ZIP_STORED)
            mutate_zip_headers(encrypted, flags=1)
            with self.assertRaisesRegex(evidence.EvidenceError, "encrypted"):
                with evidence.open_verified_evidence_archive(
                        encrypted, archive_reference(encrypted), parent,
                        {"raw.bin": file_reference(b"x")}):
                    self.fail("encrypted archive was extracted")

            unsupported = parent / "unsupported.zip"
            write_zip(unsupported, {"raw.bin": b"x"}, compression=ZIP_STORED)
            mutate_zip_headers(unsupported, compression=99)
            with self.assertRaisesRegex(evidence.EvidenceError, "unsupported compression"):
                with evidence.open_verified_evidence_archive(
                        unsupported, archive_reference(unsupported), parent,
                        {"raw.bin": file_reference(b"x")}):
                    self.fail("unsupported compression was extracted")

    def test_preflight_bounds_file_count_member_total_and_ratio(self) -> None:
        cases = [
            ({"a.bin": b"a", "b.bin": b"b"},
             evidence.ArchiveLimits(max_files=1), "file count"),
            ({"a.bin": b"abcd"},
             evidence.ArchiveLimits(max_member_bytes=3), "per-file"),
            ({"a.bin": b"abc", "b.bin": b"def"},
             evidence.ArchiveLimits(max_total_bytes=5), "aggregate"),
            ({"a.bin": b"a" * 1000},
             evidence.ArchiveLimits(max_compression_ratio=2), "compression-ratio"),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            for index, (entries, limits, message) in enumerate(cases):
                with self.subTest(message=message):
                    archive_path = parent / f"bounds-{index}.zip"
                    write_zip(archive_path, entries)
                    allowed = {name: file_reference(data) for name, data in entries.items()}
                    with self.assertRaisesRegex(evidence.EvidenceError, message):
                        with evidence.open_verified_evidence_archive(
                                archive_path, archive_reference(archive_path), parent,
                                allowed, limits=limits):
                            self.fail("over-limit archive was extracted")

    def test_streamed_bytes_are_bounded_independently_of_metadata(self) -> None:
        declared = file_reference(b"abc")
        with self.assertRaisesRegex(evidence.EvidenceError, "more bytes than declared"):
            evidence._copy_stream(
                io.BytesIO(b"abcd"), io.BytesIO(), declared,
                member_limit=3, aggregate_remaining=3, label="raw.bin")

    def test_underreported_deflate_output_is_measured_and_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            archive_path = parent / "underreported.zip"
            write_zip(archive_path, {"raw.bin": b"abcd"}, compression=ZIP_DEFLATED)
            underreport_first_member(archive_path, b"abc")
            with self.assertRaisesRegex(evidence.EvidenceError, "more bytes than declared"):
                with evidence.open_verified_evidence_archive(
                        archive_path, archive_reference(archive_path), parent,
                        {"raw.bin": file_reference(b"abc")}):
                    self.fail("underreported deflate output was accepted")
            self.assertEqual(list(parent.iterdir()), [archive_path])

    def test_crc_failure_cleans_only_the_owned_extraction_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            sentinel = parent / "keep.txt"
            sentinel.write_text("keep", encoding="utf-8")
            archive_path = parent / "crc.zip"
            original = b"abcdef"
            write_zip(archive_path, {"raw.bin": original}, compression=ZIP_STORED)
            corrupt_stored_payload(archive_path)
            before = set(parent.iterdir())
            with self.assertRaisesRegex(evidence.EvidenceError, "CRC|invalid"):
                with evidence.open_verified_evidence_archive(
                        archive_path, archive_reference(archive_path), parent,
                        {"raw.bin": file_reference(original)}):
                    self.fail("corrupt archive was extracted")
            self.assertEqual(set(parent.iterdir()), before)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")


class CanonicalStatementTests(unittest.TestCase):
    def test_golden_bytes_and_array_order_are_deterministic(self) -> None:
        statement = statement_fixture()
        actual = evidence.serialize_canonical_statement(statement)
        self.assertEqual(actual, GOLDEN_STATEMENT)
        statement["targets"].reverse()
        statement["required_gates"].reverse()
        statement["harness"]["components"].reverse()
        self.assertEqual(evidence.serialize_canonical_statement(statement), GOLDEN_STATEMENT)
        self.assertEqual(evidence.parse_canonical_statement_bytes(actual)["result"], "passed")

    def test_noncanonical_statement_bytes_are_rejected(self) -> None:
        pretty = (json.dumps(statement_fixture(), indent=2) + "\n").encode()
        with self.assertRaisesRegex(evidence.EvidenceError, "not canonical"):
            evidence.parse_canonical_statement_bytes(pretty)
        with self.assertRaisesRegex(evidence.EvidenceError, "not canonical"):
            evidence.parse_canonical_statement_bytes(GOLDEN_STATEMENT.rstrip(b"\n"))

    def test_path_bearing_unknown_fields_and_boolean_ids_are_rejected(self) -> None:
        statement = statement_fixture()
        statement["ingress"]["raw_path"] = "C:\\private\\evidence.zip"
        with self.assertRaisesRegex(evidence.EvidenceError, "fields are invalid"):
            evidence.serialize_canonical_statement(statement)

        statement = statement_fixture()
        statement["candidate"]["run_id"] = True
        with self.assertRaisesRegex(evidence.EvidenceError, "not a boolean"):
            evidence.serialize_canonical_statement(statement)

        statement = statement_fixture()
        statement["targets"][0]["raw_filename"] = "journal.bin"
        with self.assertRaisesRegex(evidence.EvidenceError, "fields are invalid"):
            evidence.serialize_canonical_statement(statement)

        statement = statement_fixture()
        statement["profile"]["id"] = "other-profile"
        with self.assertRaisesRegex(evidence.EvidenceError, "fixed profile"):
            evidence.serialize_canonical_statement(statement)

    def test_full_22_target_and_gate_sets_are_mandatory(self) -> None:
        statement = statement_fixture()
        statement["targets"].pop()
        with self.assertRaisesRegex(evidence.EvidenceError, "full profile"):
            evidence.serialize_canonical_statement(statement)
        statement = statement_fixture()
        statement["required_gates"].pop()
        with self.assertRaisesRegex(evidence.EvidenceError, "gate IDs"):
            evidence.serialize_canonical_statement(statement)


class IndexedArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "evidence.zip"
        self.entries = {"campaign.json": b'{"attempts": []}', "raw/checkpoint.json": b'{}'}

    def write(self, *, index_bytes=None, extra=None) -> None:
        index = {"schema": "darkrenamer-vm-automated-index-v1", "files": {
            path: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
            for path, data in self.entries.items()}}
        entries = {"evidence-index.json": index_bytes if index_bytes is not None else json.dumps(index).encode(),
                   **self.entries, **(extra or {})}
        write_zip(self.archive, entries)

    def extract(self):
        return evidence.open_indexed_evidence_archive(self.archive, archive_reference(self.archive), self.root)

    def test_pinned_index_extracts_and_cleans(self) -> None:
        self.write()
        with self.extract() as result:
            path = result.root
            self.assertEqual((path / "campaign.json").read_bytes(), self.entries["campaign.json"])
            self.assertEqual(set(result.files), {*self.entries, "evidence-index.json"})
        self.assertFalse(path.exists())

    def test_external_pin_is_required_before_bootstrap(self) -> None:
        self.write()
        with self.assertRaises(evidence.EvidenceError):
            with evidence.open_indexed_evidence_archive(self.archive, file_reference(b"other"), self.root):
                self.fail("Wrong pin accepted")

    def test_unindexed_member_rejected(self) -> None:
        self.write(extra={"surprise.ps1": b"exit 0"})
        with self.assertRaisesRegex(evidence.EvidenceError, "unexpected file"):
            with self.extract():
                self.fail("Unindexed file accepted")

    def test_duplicate_index_and_json_keys_rejected(self) -> None:
        self.write(index_bytes=b'{"schema":"a","schema":"b","files":{}}')
        with self.assertRaises(evidence.EvidenceError):
            with self.extract():
                self.fail("Duplicate JSON key accepted")
        self.write()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with ZipFile(self.archive, "a") as archive:
                archive.writestr("evidence-index.json", b"{}")
        with self.assertRaisesRegex(evidence.EvidenceError, "one fixed"):
            with self.extract():
                self.fail("Duplicate index accepted")

    def test_index_cannot_refer_to_itself_or_escape(self) -> None:
        for name in ("evidence-index.json", "../outside", "Campaign.json"):
            index = {"schema": "darkrenamer-vm-automated-index-v1", "files": {
                "campaign.json": {"sha256": "0" * 64, "size": 0},
                name: {"sha256": "0" * 64, "size": 0}}}
            self.write(index_bytes=json.dumps(index).encode())
            with self.subTest(name=name), self.assertRaises(evidence.EvidenceError):
                with self.extract():
                    self.fail("Unsafe index accepted")

    def test_forged_index_size_cannot_hide_raw_tail(self) -> None:
        self.write(index_bytes=b'{}' + b' ' * 100)
        underreport_first_member(self.archive, b'{}')
        with self.assertRaises(evidence.EvidenceError):
            with self.extract():
                self.fail("Hidden index payload accepted")

    def test_index_member_size_bound(self) -> None:
        self.write(index_bytes=b'x' * (1024 * 1024 + 1))
        with self.assertRaisesRegex(evidence.EvidenceError, "bound"):
            with self.extract():
                self.fail("Oversized index accepted")

    def test_directory_bound_precedes_zipinfo_allocation(self) -> None:
        self.write()
        original = self.archive.read_bytes()
        for mutation in ("count", "zip64", "directory_size", "hidden_entries"):
            data = bytearray(original)
            end = data.rfind(b"PK\x05\x06")
            if mutation in ("count", "zip64", "hidden_entries"):
                count = {"count": 2049, "zip64": 0xFFFF, "hidden_entries": 1}[mutation]
                struct.pack_into("<HH", data, end + 8, count, count)
            else:
                struct.pack_into("<I", data, end + 12, 4 * 1024 * 1024 + 1)
            self.archive.write_bytes(data)
            with self.subTest(mutation=mutation), patch.object(evidence, "ZipFile") as constructor:
                with self.assertRaises(evidence.EvidenceError):
                    with self.extract():
                        self.fail("Unsafe directory accepted")
                constructor.assert_not_called()

    def test_actual_over_entry_directory_rejected_before_constructor(self) -> None:
        write_zip(self.archive, {f"f{number}": b"" for number in range(2049)})
        data = bytearray(self.archive.read_bytes())
        end = data.rfind(b"PK\x05\x06")
        struct.pack_into("<HH", data, end + 8, 1, 1)
        self.archive.write_bytes(data)
        with patch.object(evidence, "ZipFile") as constructor:
            with self.assertRaisesRegex(evidence.EvidenceError, "too many"):
                with self.extract():
                    self.fail("Forged count hid oversized directory")
            constructor.assert_not_called()


if __name__ == "__main__":
    unittest.main()
