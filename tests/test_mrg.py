from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests._fixtures import make_mrg

from mrg import MrgFormatError, parse_mrg, printable_prefix, try_parse_mrg


class MrgTests(unittest.TestCase):
    def test_slices_preserve_padding_and_nonzero_header_metadata(self) -> None:
        data = make_mrg([b"one", b"two-longer", b"end"])
        archive = parse_mrg(data)
        self.assertEqual((archive.count, archive.header_size), (3, 16))
        self.assertEqual([member.index for member in archive.members], [0, 1, 2])
        self.assertEqual([member.offset for member in archive.members], [16, 32, 48])
        self.assertEqual([member.size for member in archive.members], [16, 16, 3])
        self.assertEqual(archive.members[0].data, b"one" + bytes(13))
        self.assertEqual(archive.members[1].data, b"two-longer" + bytes(6))
        self.assertEqual(archive.members[2].data, b"end")
        self.assertEqual(try_parse_mrg(data), archive)
        metadata = make_mrg([b"first", b"second"])
        self.assertEqual(metadata[12:16], b"\xa5" * 4)
        self.assertEqual(parse_mrg(metadata).members[-1].data, b"second")

    def test_single_member_and_maximum_count(self) -> None:
        single = parse_mrg(make_mrg([b"payload"]))
        self.assertEqual((single.count, single.header_size), (1, 16))
        self.assertEqual(single.members[0].data, b"payload")
        maximum = parse_mrg(make_mrg([b"x"] * 4096))
        self.assertEqual(maximum.count, 4096)
        self.assertEqual(len(maximum.members), 4096)
        self.assertEqual(maximum.members[0].data, b"x" + bytes(15))
        self.assertEqual(maximum.members[-1].data, b"x")

    def test_final_start_exactly_at_eof_is_valid(self) -> None:
        for data in (make_mrg([b""]), make_mrg([b"a" * 16, b""])):
            with self.subTest(count=struct.unpack_from("<I", data)[0]):
                archive = parse_mrg(data)
                self.assertEqual(archive.members[-1].offset, len(data))
                self.assertEqual(archive.members[-1].size, 0)
                self.assertEqual(archive.members[-1].data, b"")

    def test_fixed_header_and_member_count(self) -> None:
        for length in range(8):
            with self.subTest(length=length):
                with self.assertRaisesRegex(MrgFormatError, "fixed header"):
                    parse_mrg(bytes(length))
                self.assertIsNone(try_parse_mrg(bytes(length)))
        for count in (0, 4097, 0xFFFFFFFF):
            with self.subTest(count=count):
                data = struct.pack("<II", count, 16) + bytes(8)
                with self.assertRaisesRegex(MrgFormatError, "member count"):
                    parse_mrg(data)

    def test_header_must_fit_table_and_archive_and_be_aligned(self) -> None:
        cases = (
            (2, 8, 32, "cannot hold"),
            (2, 12, 32, "aligned"),
            (2, 16, 11, "cannot hold"),
            (2, 48, 32, "cannot hold"),
            (3, 15, 32, "cannot hold"),
            (3, 17, 32, "aligned"),
        )
        for count, header, length, message in cases:
            with self.subTest(count=count, header=header, length=length):
                data = bytearray(length)
                struct.pack_into("<II", data, 0, count, header)
                with self.assertRaisesRegex(MrgFormatError, message):
                    parse_mrg(data)
                self.assertIsNone(try_parse_mrg(data))

    def test_member_offsets_must_be_in_bounds_aligned_and_strictly_increasing(self) -> None:
        valid = make_mrg([b"a" * 16, b"b" * 16, b"c" * 16])
        self.assertEqual(len(valid), 64)
        cases = (
            ("before header", (0, 48), "outside"),
            ("after eof", (32, 80), "outside"),
            ("unaligned", (33, 48), "aligned"),
            ("duplicate header", (16, 48), "strictly increasing"),
            ("duplicate offsets", (32, 32), "strictly increasing"),
            ("descending", (48, 32), "strictly increasing"),
        )
        for label, offsets, message in cases:
            with self.subTest(label=label):
                data = bytearray(valid)
                struct.pack_into("<II", data, 8, *offsets)
                with self.assertRaisesRegex(MrgFormatError, message):
                    parse_mrg(data)
                self.assertIsNone(try_parse_mrg(data))

    def test_printable_prefix_is_bounded_and_escapes_lines(self) -> None:
        self.assertEqual(printable_prefix(b"A\r\n\x00~\xff"), "A\\n\\n.~.")
        self.assertEqual(printable_prefix(b"ABCDEF", 3), "ABC")
        self.assertEqual(printable_prefix(b"ABC", 0), "")


if __name__ == "__main__":
    unittest.main()
