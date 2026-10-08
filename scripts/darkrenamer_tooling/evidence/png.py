"""Bounded decoder for opaque, non-interlaced PNG evidence."""

from __future__ import annotations

from darkrenamer_tooling.formats.png import PngError, PngPolicy, decode_png_bytes

from darkrenamer_tooling.evidence.errors import EvidenceError


MAX_COMPRESSED_BYTES = 128 * 1024 * 1024
MAX_PNG_PIXELS = 32 * 1024 * 1024
# Covers every frozen layout target at its declared desktop bounds plus one
# individually bounded recovery screenshot, while stopping repeated large rasters.
MAX_TOTAL_DECODED_PNG_PIXELS = 144 * 1024 * 1024


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


class DecodedPixelBudget:
    """Cumulative pixel work allowed for one evidence verification."""

    def __init__(self, maximum_pixels: int = MAX_TOTAL_DECODED_PNG_PIXELS):
        require(type(maximum_pixels) is int and maximum_pixels >= 0,
                "PNG decoded-pixel budget is invalid.")
        self.remaining_pixels = maximum_pixels

    def reserve(self, pixels: int, label: str) -> None:
        require(type(pixels) is int and pixels >= 0 and pixels <= self.remaining_pixels,
                f"{label} exceeds the cumulative decoded-pixel budget.")
        self.remaining_pixels -= pixels


EVIDENCE_PNG_POLICY = PngPolicy(
    color_types=frozenset({0, 2, 4, 6}), maximum_pixels=MAX_PNG_PIXELS,
    maximum_compressed_bytes=MAX_COMPRESSED_BYTES,
    maximum_chunk_bytes=MAX_COMPRESSED_BYTES, require_opaque=True,
    maximum_chunks=4096,
)

_ERROR_MESSAGES = {
    "chunk_policy": "has an invalid chunk-count policy",
    "chunks": "exceeds its PNG chunk-count budget",
    "signature": "has an invalid PNG signature",
    "header": "has a truncated PNG chunk",
    "length": "has an invalid PNG chunk length",
    "crc": "has a PNG CRC mismatch",
    "kind": "has an invalid PNG chunk type",
    "transparency": "uses unsupported PNG transparency",
    "critical": "uses an unsupported critical PNG chunk",
    "ihdr": "has an invalid IHDR",
    "dimensions": "dimensions are invalid",
    "pixels": "dimensions are invalid",
    "encoding": "uses an unsupported PNG encoding",
    "idat": "has IDAT in an invalid position",
    "compressed_budget": "has too much compressed raster data",
    "iend": "has an invalid IEND",
    "trailing": "has trailing bytes after IEND",
    "missing": "is missing required PNG chunks",
    "compressed": "has invalid compressed raster data",
    "overflow": "decoded raster exceeds its declared dimensions",
    "stream": "decoded raster stream or length is invalid",
    "filter": "uses an invalid PNG filter",
    "opaque": "contains unsupported non-opaque pixels",
}


def decode_png(
    data: bytes,
    label: str,
    *,
    expected_dimensions: tuple[int, int] | None = None,
    budget: DecodedPixelBudget | None = None,
) -> tuple[int, int, bytes]:
    def check_dimensions(width: int, height: int) -> None:
        if expected_dimensions is not None:
            require(type(expected_dimensions) is tuple and len(expected_dimensions) == 2 and
                    all(type(value) is int and value > 0 for value in expected_dimensions),
                    f"{label} expected dimensions are invalid.")
            require((width, height) == expected_dimensions,
                    f"{label} dimensions differ from the expected raster size.")

    try:
        return decode_png_bytes(
            data, policy=EVIDENCE_PNG_POLICY, on_dimensions=check_dimensions,
            reserve_pixels=(lambda pixels: budget.reserve(pixels, label)) if budget is not None else None,
        )
    except PngError as error:
        raise EvidenceError(f"{label} {_ERROR_MESSAGES[error.code]}.") from error
