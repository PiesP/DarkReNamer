"""Fresh synthetic journal and filesystem state for recovery tests."""

import hashlib
import struct
from types import SimpleNamespace
import zlib


VOLUME = 0xAABBCCDD11223344
PARENT = 1 << 120
ROOT = r"C:\fixture"


def identity(index):
    return struct.pack("<Q", VOLUME) + index.to_bytes(16, "little")


def text(value):
    encoded = value.encode("utf-16-le")
    return struct.pack("<I", len(encoded) // 2) + encoded


def frame(kind, sequence, payload):
    header = struct.pack("<HBBQI", 2, kind, 0, sequence, len(payload))
    return b"DRJ1" + header + struct.pack("<I", zlib.crc32(header + payload)) + payload


def build_recovery_fixture():
    initial = []
    steps = []
    for index in range(4096):
        name = f"item-{index:05}.txt"
        file_id = (1 << 96) + index
        steps.append(struct.pack("<I", index) + text(ROOT + "\\" + name) +
                     text(ROOT + "\\vm-recovered-" + name) + identity(file_id) +
                     identity(PARENT) * 2 + bytes((0, 0, 0)))
        initial.append({"name": name, "kind": "file", "bytes": 65,
                            "content_sha256": hashlib.sha256(name.encode()).hexdigest(),
                            "file_identity": {"volume_serial": f"{VOLUME:016x}", "file_id": f"{file_id:032x}"}})
    initial.append({"name": "sentinel.bin", "kind": "file", "bytes": 9,
                        "content_sha256": hashlib.sha256(b"sentinel\n").hexdigest(),
                        "file_identity": {"volume_serial": f"{VOLUME:016x}", "file_id": f"{PARENT + 1:032x}"}})
    intent = frame(1, 0, struct.pack("<QI", 42, 4096) + b"".join(steps))
    completed = intent + frame(2, 1, struct.pack("<IB", 0, 0)) + frame(3, 2, struct.pack("<IB", 0, 0))
    prepared = completed + frame(2, 3, struct.pack("<IB", 1, 0))
    parent = {"volume_serial": f"{VOLUME:016x}", "file_id": f"{PARENT:032x}"}
    return SimpleNamespace(initial=initial, intent=intent, completed=completed,
                           prepared=prepared, parent=parent)
