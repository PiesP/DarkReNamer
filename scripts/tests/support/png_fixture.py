"""PNG byte construction for independent tooling test fixtures."""

import struct
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_chunk(kind: bytes, payload: bytes, *, checksum: int | None = None) -> bytes:
    if checksum is None:
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def png_bytes(width: int, height: int, color_type: int, filtered: bytes, *,
              compressed: bytes | None = None, before_idat=(), after_idat=(),
              include_iend: bool = True, iend_payload: bytes = b"",
              trailing: bytes = b"") -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    payload = zlib.compress(filtered) if compressed is None else compressed
    result = PNG_SIGNATURE + png_chunk(b"IHDR", ihdr)
    result += b"".join(before_idat) + png_chunk(b"IDAT", payload) + b"".join(after_idat)
    if include_iend:
        result += png_chunk(b"IEND", iend_payload)
    return result + trailing
