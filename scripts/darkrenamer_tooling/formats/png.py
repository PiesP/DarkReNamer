"""Bounded PNG byte decoding without evidence or filesystem semantics."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable
import struct
import zlib


@dataclass(frozen=True)
class PngPolicy:
    color_types: frozenset[int]
    maximum_pixels: int
    maximum_compressed_bytes: int
    maximum_dimension: int | None = None
    maximum_decoded_bytes: int | None = None
    maximum_chunk_bytes: int | None = None
    require_opaque: bool = False


class PngError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def require(condition: bool, code: str, message: str) -> None:
    if not condition:
        raise PngError(code, message)


def paeth(left: int, above: int, upper_left: int) -> int:
    predictor = left + above - upper_left
    distances = (abs(predictor - left), abs(predictor - above), abs(predictor - upper_left))
    return (left, above, upper_left)[distances.index(min(distances))]


def decode_png_bytes(
    data: bytes, *, policy: PngPolicy,
    on_dimensions: Callable[[int, int], None] | None = None,
    reserve_pixels: Callable[[int], None] | None = None,
) -> tuple[int, int, bytes]:
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), "signature", "Raster screenshot is not PNG.")
    offset = 8
    width = height = color_type = None
    compressed = bytearray()
    saw_idat = ended_idat = saw_iend = False
    while offset < len(data):
        require(offset + 12 <= len(data), "header", "PNG chunk header is truncated.")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(data) and
                (policy.maximum_chunk_bytes is None or length <= policy.maximum_chunk_bytes),
                "length", "PNG chunk is truncated.")
        payload = data[offset + 8:offset + 8 + length]
        require(zlib.crc32(kind + payload) & 0xffffffff == struct.unpack(">I", data[end - 4:end])[0],
                "crc", "PNG chunk checksum differs.")
        require(all(65 <= value <= 90 or 97 <= value <= 122 for value in kind)
                and not kind[2] & 0x20, "kind", "PNG has an invalid chunk type.")
        require(kind != b"tRNS", "transparency", "PNG transparency is outside the fixed raster contract.")
        require(kind in {b"IHDR", b"IDAT", b"IEND"} or kind[0] & 0x20,
                "critical", "PNG uses an unsupported critical chunk.")
        if kind == b"IHDR":
            require(length == 13 and width is None and offset == 8, "ihdr", "PNG has an invalid IHDR.")
            width, height, depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            require(width > 0 and height > 0 and
                    (policy.maximum_dimension is None or
                     max(width, height) <= policy.maximum_dimension),
                    "dimensions", "PNG format is outside the fixed raster contract.")
            require(width * height <= policy.maximum_pixels, "pixels", "PNG exceeds its pixel budget.")
            if on_dimensions is not None:
                on_dimensions(width, height)
            require(depth == 8 and color_type in policy.color_types and
                    color_type in {0, 2, 4, 6} and compression == filtering == interlace == 0,
                    "encoding", "PNG format is outside the fixed raster contract.")
            channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
            stride = width * channels
            expected = (stride + 1) * height
            require(policy.maximum_decoded_bytes is None or expected <= policy.maximum_decoded_bytes,
                    "decoded_budget", "PNG exceeds its decoded byte budget.")
            if reserve_pixels is not None:
                reserve_pixels(width * height)
        elif kind == b"IDAT":
            require(width is not None and not saw_iend and not ended_idat,
                    "idat", "PNG IDAT is out of order.")
            require(length <= policy.maximum_compressed_bytes - len(compressed),
                    "compressed_budget", "PNG has too much compressed raster data.")
            compressed.extend(payload)
            saw_idat = True
        elif kind == b"IEND":
            require(length == 0 and width is not None and saw_idat and not saw_iend,
                    "iend", "PNG has an invalid IEND.")
            saw_iend = True
            require(end == len(data), "trailing", "PNG has trailing bytes after IEND.")
        elif saw_idat:
            ended_idat = True
        offset = end
    require(width is not None and saw_idat and saw_iend and compressed,
            "missing", "PNG is missing required PNG chunks.")
    try:
        inflater = zlib.decompressobj()
        # One bounded call includes the stream trailer. Never flush: it could
        # allocate output after the declared scanline budget has been reached.
        raw = inflater.decompress(bytes(compressed), expected + 1)
    except zlib.error as error:
        raise PngError("compressed", "PNG has invalid compressed raster data.") from error
    require(len(raw) <= expected and not inflater.unconsumed_tail,
            "overflow", "PNG decoded raster exceeds its declared dimensions.")
    require(len(raw) == expected and inflater.eof and not inflater.unused_data
            and not inflater.unconsumed_tail,
            "stream", "PNG compressed raster stream or length is invalid.")
    previous = bytearray(stride)
    rgba = bytearray(width * height * 4)
    cursor = rgba_offset = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        scan = bytearray(raw[cursor:cursor + stride])
        cursor += stride
        require(filter_type <= 4, "filter", "PNG uses an unsupported row filter.")
        for index in range(stride):
            left = scan[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            else:
                predictor = paeth(left, above, upper_left)
            scan[index] = (scan[index] + predictor) & 0xff
        for index in range(0, stride, channels):
            pixel = scan[index:index + channels]
            if color_type in {0, 4}:
                color = (pixel[0], pixel[0], pixel[0], pixel[1] if color_type == 4 else 255)
            else:
                color = (pixel[0], pixel[1], pixel[2], pixel[3] if color_type == 6 else 255)
            require(not policy.require_opaque or color[3] == 255,
                    "opaque", "PNG contains unsupported non-opaque pixels.")
            rgba[rgba_offset:rgba_offset + 4] = bytes(color)
            rgba_offset += 4
        previous = scan
    return width, height, bytes(rgba)
