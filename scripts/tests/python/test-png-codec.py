"""Default offline coverage for shared PNG decoding and consumer policies."""

import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
from unittest.mock import patch
import zlib

from tooling_test_paths import SCRIPT_ROOT
from darkrenamer_tooling.formats import png as codec
from darkrenamer_tooling.evidence import png as evidence


RGB_POLICY = codec.PngPolicy(
    color_types=frozenset({2, 6}), maximum_pixels=32 * 1024 * 1024,
    maximum_compressed_bytes=128 * 1024 * 1024, maximum_dimension=8192,
    maximum_decoded_bytes=128 * 1024 * 1024,
)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_chunk(kind, payload, *, checksum=None):
    if checksum is None:
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def paeth(left, above, upper_left):
    predictor = left + above - upper_left
    distances = (
        abs(predictor - left), abs(predictor - above), abs(predictor - upper_left),
    )
    return (left, above, upper_left)[distances.index(min(distances))]


def encode_filtered_rows(rows, channels, filters):
    previous = bytes(len(rows[0]))
    encoded = bytearray()
    for row, filter_type in zip(rows, filters, strict=True):
        encoded.append(filter_type)
        for index, value in enumerate(row):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            predictor = (
                0, left, above, (left + above) // 2, paeth(left, above, upper_left),
            )[filter_type]
            encoded.append((value - predictor) & 0xFF)
        previous = row
    return bytes(encoded)


def png_bytes(width, height, color_type, filtered, *, compressed=None,
              before_idat=(), after_idat=(), include_iend=True,
              iend_payload=b"", trailing=b""):
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    payload = zlib.compress(filtered) if compressed is None else compressed
    result = PNG_SIGNATURE + png_chunk(b"IHDR", ihdr)
    result += b"".join(before_idat) + png_chunk(b"IDAT", payload) + b"".join(after_idat)
    if include_iend:
        result += png_chunk(b"IEND", iend_payload)
    return result + trailing


def png(width=8, height=8, *_unused, transparent=False):
    pixels = bytes((18, 52, 86, 0 if transparent else 255)) * width
    return png_bytes(width, height, 6, (b"\0" + pixels) * height)


class PngCodecTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)


    def write_png(self, name, value):
        path = self.root / name
        path.write_bytes(value)
        return path

    def test_decode_png_preserves_rgb_rgba_and_all_supported_filters(self):
        filters = (0, 1, 2, 3, 4)
        for color_type, channels in ((2, 3), (6, 4)):
            rows = [
                bytes((17 + row * 31 + column * 19) & 0xFF
                      for column in range(channels * 2))
                for row in range(len(filters))
            ]
            filtered = encode_filtered_rows(rows, channels, filters)
            path = self.write_png(
                f"filtered-{color_type}.png",
                png_bytes(
                    2, len(rows), color_type, filtered,
                    before_idat=(png_chunk(b"pHYs", struct.pack(">IIB", 3780, 3780, 1)),),
                    after_idat=(png_chunk(b"tEXt", b"source\x00native-observer"),),
                ),
            )
            width, height, rgba = codec.decode_png_bytes((path).read_bytes(), policy=RGB_POLICY)
            expected = bytearray()
            for row in rows:
                for offset in range(0, len(row), channels):
                    expected.extend(row[offset:offset + 3])
                    expected.append(row[offset + 3] if channels == 4 else 255)
            self.assertEqual((width, height, rgba), (2, len(rows), bytes(expected)))

    def test_decode_png_requires_strict_chunk_structure_and_complete_zlib_stream(self):
        filtered = b"\x00\x11\x22\x33"
        compressed = zlib.compress(filtered)
        ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
        valid = png_bytes(1, 1, 2, filtered)
        idat_offset = valid.index(b"IDAT")
        idat_length = struct.unpack(">I", valid[idat_offset - 4:idat_offset])[0]
        crc_offset = idat_offset + 4 + idat_length
        bad_crc = bytearray(valid)
        bad_crc[crc_offset] ^= 0x01
        split = len(compressed) // 2
        contiguous_idat = (
            PNG_SIGNATURE + png_chunk(b"IHDR", ihdr)
            + png_chunk(b"IDAT", compressed[:split])
            + png_chunk(b"IDAT", compressed[split:])
            + png_chunk(b"IEND", b"")
        )
        self.assertEqual(
            codec.decode_png_bytes((self.write_png("contiguous-idat.png", contiguous_idat)).read_bytes(), policy=RGB_POLICY),
            (1, 1, b"\x11\x22\x33\xff"),
        )
        fixtures = (
            ("missing-iend.png", png_bytes(1, 1, 2, filtered, include_iend=False), "missing required PNG chunks"),
            ("after-iend.png", valid + b"trailing", "trailing bytes after IEND"),
            ("bad-crc.png", bytes(bad_crc), "chunk checksum differs"),
            (
                "idat-before-ihdr.png",
                PNG_SIGNATURE + png_chunk(b"IDAT", compressed) + png_chunk(b"IHDR", ihdr)
                + png_chunk(b"IEND", b""),
                "IDAT is out of order",
            ),
            (
                "noncontiguous-idat.png",
                PNG_SIGNATURE + png_chunk(b"IHDR", ihdr)
                + png_chunk(b"IDAT", compressed[:split])
                + png_chunk(b"tEXt", b"key\x00value")
                + png_chunk(b"IDAT", compressed[split:])
                + png_chunk(b"IEND", b""),
                "IDAT is out of order",
            ),
            ("nonempty-iend.png", png_bytes(1, 1, 2, filtered, iend_payload=b"x"), "invalid IEND"),
            (
                "zlib-unused-data.png",
                png_bytes(1, 1, 2, filtered, compressed=compressed + b"unused"),
                "compressed raster stream or length is invalid",
            ),
            (
                "truncated-zlib.png",
                png_bytes(1, 1, 2, filtered, compressed=compressed[:-2]),
                "compressed raster stream or length is invalid",
            ),
        )
        for name, value, message in fixtures:
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, message):
                    codec.decode_png_bytes((self.write_png(name, value)).read_bytes(), policy=RGB_POLICY)

    def test_decode_png_caps_inflate_to_declared_scanlines_without_flush(self):
        compressed = zlib.compress(b"\x00" * (1024 * 1024))
        path = self.write_png(
            "oversized-inflate.png",
            png_bytes(1, 1, 2, b"", compressed=compressed),
        )
        original_decompressobj = zlib.decompressobj
        calls = []
        flush_calls = []

        class ObservedInflater:
            def __init__(self):
                self.inner = original_decompressobj()

            def decompress(self, data, max_length=0):
                result = self.inner.decompress(data, max_length)
                calls.append({
                    "input_bytes": len(data),
                    "max_length": max_length,
                    "returned_bytes": len(result),
                })
                return result

            def flush(self, *arguments):
                result = self.inner.flush(*arguments)
                flush_calls.append({"arguments": arguments, "returned_bytes": len(result)})
                return result

            def __getattr__(self, name):
                return getattr(self.inner, name)

        with mock.patch.object(codec.zlib, "decompressobj", side_effect=ObservedInflater):
            with self.assertRaisesRegex(ValueError, "decoded raster exceeds its declared dimensions"):
                codec.decode_png_bytes((path).read_bytes(), policy=RGB_POLICY)
        self.assertEqual(calls, [{
            "input_bytes": len(compressed), "max_length": 5, "returned_bytes": 5,
        }])
        self.assertEqual(flush_calls, [])

        exact = zlib.compress(b"\x00\x11\x22\x33")
        calls.clear()
        with mock.patch.object(codec.zlib, "decompressobj", side_effect=ObservedInflater):
            decoded = codec.decode_png_bytes((self.write_png(
                "observed-valid.png", png_bytes(1, 1, 2, b"", compressed=exact),
            )).read_bytes(), policy=RGB_POLICY)
        self.assertEqual(decoded, (1, 1, b"\x11\x22\x33\xff"))
        self.assertEqual(calls, [{
            "input_bytes": len(exact), "max_length": 5, "returned_bytes": 4,
        }])
        self.assertEqual(flush_calls, [])

        truncated = exact[:-2]
        calls.clear()
        with mock.patch.object(codec.zlib, "decompressobj", side_effect=ObservedInflater):
            with self.assertRaisesRegex(ValueError, "compressed raster stream or length is invalid"):
                codec.decode_png_bytes((self.write_png(
                    "observed-truncated.png",
                    png_bytes(1, 1, 2, b"", compressed=truncated),
                )).read_bytes(), policy=RGB_POLICY)
        self.assertEqual(calls, [{
            "input_bytes": len(truncated), "max_length": 5, "returned_bytes": 4,
        }])
        self.assertEqual(flush_calls, [])

    def test_decode_png_rejects_pixel_and_decoded_byte_budgets_before_inflate(self):
        inflater = mock.Mock()
        fixtures = (
            (
                "pixel-budget.png",
                png_bytes(8192, 4097, 2, b"\x00"),
                "pixel budget",
            ),
            (
                "decoded-budget.png",
                png_bytes(8192, 4096, 6, b"\x00"),
                "decoded byte budget",
            ),
        )
        with mock.patch.object(codec.zlib, "decompressobj", inflater):
            for name, value, message in fixtures:
                with self.subTest(name=name):
                    with self.assertRaisesRegex(ValueError, message):
                        codec.decode_png_bytes((self.write_png(name, value)).read_bytes(), policy=RGB_POLICY)
        inflater.assert_not_called()

    def test_png_decoder_rejects_bomb_transparency_and_unsupported_transparency_chunk(self):
        header = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
        bomb = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) +
                png_chunk(b"IDAT", zlib.compress(b"\0" + b"\0" * 1_000_000)) +
                png_chunk(b"IEND", b""))
        with self.assertRaisesRegex(evidence.EvidenceError, "exceeds its declared dimensions"):
            evidence.decode_png(bomb, "bomb")
        with self.assertRaisesRegex(evidence.EvidenceError, "non-opaque"):
            evidence.decode_png(png(transparent=True), "alpha")
        opaque = png()
        idat = opaque.index(b"IDAT") - 4
        with_trns = opaque[:idat] + png_chunk(b"tRNS", b"\x00\x00\x00\x00\x00\x00") + opaque[idat:]
        with self.assertRaisesRegex(evidence.EvidenceError, "unsupported PNG transparency"):
            evidence.decode_png(with_trns, "trns")

    def test_png_decoder_checks_expected_dimensions_before_inflating(self):
        header = struct.pack(">IIBBBBB", 8192, 4096, 8, 6, 0, 0, 0)
        image = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) +
                 png_chunk(b"IDAT", zlib.compress(b"unused")) +
                 png_chunk(b"IEND", b""))
        with patch("darkrenamer_tooling.formats.png.zlib.decompressobj") as inflate:
            with self.assertRaisesRegex(evidence.EvidenceError, "expected raster size"):
                evidence.decode_png(image, "mismatched", expected_dimensions=(80, 30))
            inflate.assert_not_called()

    def test_png_decoder_requires_valid_chunk_types_and_consecutive_idat(self):
        prefix = b"\x89PNG\r\n\x1a\n" + png_chunk(
            b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        compressed = zlib.compress(b"\0\x12\x34\x56\xff")
        first = png_chunk(b"IDAT", compressed[:3])
        second = png_chunk(b"IDAT", compressed[3:])
        end = png_chunk(b"IEND", b"")
        ancillary = png_chunk(b"tEXt", b"key\0value")
        expected = (1, 1, b"\x12\x34\x56\xff")
        self.assertEqual(evidence.decode_png(prefix + ancillary + first + second + end, "valid"), expected)
        self.assertEqual(evidence.decode_png(prefix + first + second + ancillary + end, "valid"), expected)
        with self.assertRaisesRegex(evidence.EvidenceError, "IDAT in an invalid position"):
            evidence.decode_png(prefix + first + ancillary + second + end, "split")
        for kind in (b"abcd", b"tE1t", b"\xffEXt"):
            with self.subTest(kind=kind), self.assertRaisesRegex(evidence.EvidenceError, "invalid PNG chunk type"):
                evidence.decode_png(prefix + png_chunk(kind, b"") + first + second + end, "invalid")

    def test_png_decoder_preserves_supported_opaque_color_formats(self):
        for color_type, pixel, rgba in (
            (0, b"\x12", b"\x12\x12\x12\xff"),
            (2, b"\x12\x34\x56", b"\x12\x34\x56\xff"),
            (4, b"\x12\xff", b"\x12\x12\x12\xff"),
            (6, b"\x12\x34\x56\xff", b"\x12\x34\x56\xff"),
        ):
            image = (b"\x89PNG\r\n\x1a\n" + png_chunk(
                b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, color_type, 0, 0, 0)) +
                png_chunk(b"IDAT", zlib.compress(b"\0" + pixel)) + png_chunk(b"IEND", b""))
            with self.subTest(color_type=color_type):
                self.assertEqual(evidence.decode_png(image, "opaque"), (1, 1, rgba))

    def test_png_decoder_enforces_one_campaign_pixel_budget(self):
        budget = evidence.DecodedPixelBudget(maximum_pixels=64)
        small = png(8, 8, 1, 1)
        evidence.decode_png(small, "first", expected_dimensions=(8, 8), budget=budget)
        self.assertEqual(budget.remaining_pixels, 0)
        with patch("darkrenamer_tooling.formats.png.zlib.decompressobj") as inflate:
            with self.assertRaisesRegex(evidence.EvidenceError, "cumulative decoded-pixel budget"):
                evidence.decode_png(small, "second", expected_dimensions=(8, 8), budget=budget)
            inflate.assert_not_called()

    def test_campaign_pixel_budget_covers_frozen_layout_targets_and_recovery_png(self):
        profile = json.loads((SCRIPT_ROOT.parent / "config" / "vm-automated-v1.json").read_text())
        layout_targets = [row for row in profile["required_targets"]
                          if row["id"].startswith("layout-")]
        maximum_profile_pixels = sum(row["desktop_width"] * row["desktop_height"]
                                     for row in layout_targets) + evidence.MAX_PNG_PIXELS
        self.assertLessEqual(maximum_profile_pixels,
                             evidence.MAX_TOTAL_DECODED_PNG_PIXELS)
        self.assertLessEqual(evidence.MAX_TOTAL_DECODED_PNG_PIXELS,
                             maximum_profile_pixels + 16 * 1024 * 1024)

    def test_codec_canonicalizes_all_color_formats_and_filters(self):
        filters = (0, 1, 2, 3, 4)
        for color_type, channels in ((0, 1), (2, 3), (4, 2), (6, 4)):
            rows = []
            expected = bytearray()
            for row_index in range(5):
                row = bytearray()
                for column in range(2):
                    value = 17 + row_index * 31 + column * 19
                    pixel = {0: (value,), 2: (value, 18, 90),
                             4: (value, 255), 6: (value, 18, 90, 255)}[color_type]
                    row.extend(pixel)
                    expected.extend((value, value, value, 255) if color_type in {0, 4}
                                    else (value, 18, 90, 255))
                rows.append(bytes(row))
            image = png_bytes(2, 5, color_type, encode_filtered_rows(rows, channels, filters))
            with self.subTest(color_type=color_type):
                self.assertEqual(codec.decode_png_bytes(image, policy=evidence.EVIDENCE_PNG_POLICY),
                                 (2, 5, bytes(expected)))

    def test_compressed_budget_rejects_multiple_idat_chunks_before_inflate(self):
        policy = codec.PngPolicy(color_types=frozenset({2}), maximum_pixels=1,
                                 maximum_compressed_bytes=5)
        image = (PNG_SIGNATURE + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) +
                 png_chunk(b"IDAT", b"123") + png_chunk(b"IDAT", b"456") + png_chunk(b"IEND", b""))
        with mock.patch.object(codec.zlib, "decompressobj") as inflate:
            with self.assertRaisesRegex(codec.PngError, "too much compressed"):
                codec.decode_png_bytes(image, policy=policy)
            inflate.assert_not_called()

    def test_shared_decoder_never_flushes_for_evidence_consumer(self):
        original = zlib.decompressobj
        for raw in (b"\0\x12\x34\x56\xff", b"\0" * 100_000):
            inner = original()
            observed = mock.Mock(wraps=inner)
            # zlib properties need explicit forwarding on Mock wrappers.
            class Inflater:
                def decompress(self, data, maximum):
                    return observed.decompress(data, maximum)
                def flush(self, *args):
                    return observed.flush(*args)
                def __getattr__(self, name):
                    return getattr(inner, name)
            image = png_bytes(1, 1, 6, raw)
            with self.subTest(size=len(raw)), mock.patch.object(codec.zlib, "decompressobj", return_value=Inflater()):
                if len(raw) == 5:
                    self.assertEqual(evidence.decode_png(image, "valid"), (1, 1, raw[1:]))
                else:
                    with self.assertRaisesRegex(evidence.EvidenceError, "exceeds its declared dimensions"):
                        evidence.decode_png(image, "bomb")
            observed.decompress.assert_called_once_with(zlib.compress(raw), 6)
            observed.flush.assert_not_called()


if __name__ == "__main__":
    unittest.main()
