"""Bounded decoder for opaque, non-interlaced PNG evidence."""

from __future__ import annotations

import struct
import zlib

from darkrenamer_tooling.evidence.errors import EvidenceError


MAX_COMPRESSED_BYTES = 128 * 1024 * 1024
MAX_PNG_PIXELS = 32 * 1024 * 1024


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def paeth(left: int, up: int, upper_left: int) -> int:
    prediction = left + up - upper_left
    left_distance = abs(prediction - left)
    up_distance = abs(prediction - up)
    upper_left_distance = abs(prediction - upper_left)
    if left_distance <= up_distance and left_distance <= upper_left_distance:
        return left
    if up_distance <= upper_left_distance:
        return up
    return upper_left


def decode_png(data: bytes, label: str) -> tuple[int, int, bytes]:
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), f"{label} has an invalid PNG signature.")
    offset = 8
    ihdr = None
    compressed = bytearray()
    saw_iend = False
    while offset < len(data):
        require(offset + 12 <= len(data), f"{label} has a truncated PNG chunk.")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(length <= MAX_COMPRESSED_BYTES and end <= len(data),
                f"{label} has an invalid PNG chunk length.")
        payload = data[offset + 8:offset + 8 + length]
        checksum = struct.unpack(">I", data[offset + 8 + length:end])[0]
        require((zlib.crc32(kind + payload) & 0xFFFFFFFF) == checksum,
                f"{label} has a PNG CRC mismatch.")
        require(kind != b"tRNS", f"{label} uses unsupported PNG transparency.")
        require(kind in {b"IHDR", b"IDAT", b"IEND"} or kind[0] & 0x20,
                f"{label} uses an unsupported critical PNG chunk.")
        if kind == b"IHDR":
            require(ihdr is None and length == 13 and offset == 8,
                    f"{label} has an invalid IHDR.")
            ihdr = payload
        elif kind == b"IDAT":
            require(ihdr is not None and not saw_iend,
                    f"{label} has IDAT in an invalid position.")
            compressed.extend(payload)
            require(len(compressed) <= MAX_COMPRESSED_BYTES,
                    f"{label} has too much compressed raster data.")
        elif kind == b"IEND":
            require(length == 0 and not saw_iend, f"{label} has an invalid IEND.")
            saw_iend = True
            require(end == len(data), f"{label} has trailing bytes after IEND.")
        offset = end
    require(ihdr is not None and saw_iend and compressed,
            f"{label} is missing required PNG chunks.")
    width, height, depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", ihdr)
    require(width > 0 and height > 0 and width * height <= MAX_PNG_PIXELS,
            f"{label} dimensions are invalid.")
    require(depth == 8 and color_type in {0, 2, 4, 6} and compression == 0 and
            filtering == 0 and interlace == 0,
            f"{label} uses an unsupported PNG encoding.")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    stride = width * channels
    expected = (stride + 1) * height
    try:
        inflater = zlib.decompressobj()
        raw = inflater.decompress(bytes(compressed), expected + 1)
        require(len(raw) <= expected and not inflater.unconsumed_tail,
                f"{label} decoded raster exceeds its declared dimensions.")
        raw += inflater.flush(expected + 1 - len(raw))
    except zlib.error as error:
        raise EvidenceError(f"{label} has invalid compressed raster data.") from error
    require(len(raw) == expected and inflater.eof and not inflater.unused_data and
            not inflater.unconsumed_tail,
            f"{label} decoded raster stream or length is invalid.")
    previous = bytearray(stride)
    rgba = bytearray(width * height * 4)
    raw_offset = 0
    rgba_offset = 0
    for _ in range(height):
        filter_type = raw[raw_offset]
        require(filter_type <= 4, f"{label} uses an invalid PNG filter.")
        encoded = raw[raw_offset + 1:raw_offset + 1 + stride]
        decoded = bytearray(stride)
        for index, value in enumerate(encoded):
            left = decoded[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            predictor = (0, left, up, (left + up) // 2,
                         paeth(left, up, upper_left))[filter_type]
            decoded[index] = (value + predictor) & 0xFF
        for column in range(width):
            pixel = decoded[column * channels:(column + 1) * channels]
            if color_type == 0:
                color = (pixel[0], pixel[0], pixel[0], 255)
            elif color_type == 2:
                color = (pixel[0], pixel[1], pixel[2], 255)
            elif color_type == 4:
                color = (pixel[0], pixel[0], pixel[0], pixel[1])
            else:
                color = tuple(pixel)
            require(color[3] == 255,
                    f"{label} contains unsupported non-opaque pixels.")
            rgba[rgba_offset:rgba_offset + 4] = bytes(color)
            rgba_offset += 4
        previous = decoded
        raw_offset += stride + 1
    return width, height, bytes(rgba)
