from __future__ import annotations

import hashlib
import io
import sys
import unittest
from pathlib import Path

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests._fixtures import (
    FIRST_FILE_RECORD,
    PVD_OFFSET,
    ROOT_LBA,
    ROOT_OFFSET,
    SECTOR_SIZE,
    both16,
    both32,
    directory_record,
    make_deep_iso,
    make_iso,
)

from disc_image import (
    DiscFormatError,
    IsoEntry,
    IsoImage,
    _both_u16,
    _both_u32,
    find_embedded_iso_base,
    open_embedded_iso,
    stream_is_zero,
)


def image_from(data: bytes, **kwargs: object) -> IsoImage:
    return IsoImage(io.BytesIO(data), **kwargs)


def outer_with_container(data: bytes) -> tuple[IsoImage, IsoEntry]:
    outer = image_from(make_iso({"INNER.CVM;1": data}))
    return outer, outer.find("INNER.CVM")


class BothEndianTests(unittest.TestCase):
    def test_matches_at_nonzero_offsets(self) -> None:
        for value in (0, 1, 0x1234, 0xFFFF):
            with self.subTest(bits=16, value=value):
                self.assertEqual(_both_u16(b"x" + both16(value), 1, "field"), value)
        for value in (0, 1, 0x12345678, 0xFFFFFFFF):
            with self.subTest(bits=32, value=value):
                self.assertEqual(_both_u32(b"x" + both32(value), 1, "field"), value)

    def test_mismatch_and_truncation_are_format_errors(self) -> None:
        for read, little, big, width in (
            (_both_u16, both16(7)[:2], both16(8)[2:], 4),
            (_both_u32, both32(7)[:4], both32(8)[4:], 8),
        ):
            with self.subTest(width=width, error="mismatch"):
                with self.assertRaisesRegex(DiscFormatError, "test field.*disagree"):
                    read(little + big, 0, "test field")
            for offset, data in ((0, bytes(width - 1)), (-1, bytes(width))):
                with self.subTest(width=width, offset=offset):
                    with self.assertRaisesRegex(DiscFormatError, "test field.*truncated"):
                        read(data, offset, "test field")


class IsoImageTests(unittest.TestCase):
    def test_reads_files_versions_and_embedded_base(self) -> None:
        data = make_iso({"HELLO.TXT;1": b"hello", "EMPTY;2": b""})
        prefix = bytes(SECTOR_SIZE * 3)
        image = IsoImage(
            io.BytesIO(prefix + data + b"trailer"),
            base_offset=len(prefix),
            byte_length=len(data),
        )
        self.assertEqual(image.volume_id, "SYNTHETIC")
        self.assertEqual(image.volume_sectors, len(data) // SECTOR_SIZE)
        entries = image.entries()
        self.assertEqual([entry.path for entry in entries], ["HELLO.TXT", "EMPTY"])
        entries.clear()
        entry = image.find(r"\hello.txt")
        self.assertEqual(image.read_entry(entry), b"hello")
        self.assertEqual(image.hash_entry(entry), hashlib.sha256(b"hello").hexdigest())
        self.assertEqual(image.hash_entry(entry, "sha1"), hashlib.sha1(b"hello").hexdigest())
        self.assertEqual(image.absolute_offset(entry), len(prefix) + 21 * SECTOR_SIZE)
        self.assertEqual(image.read_entry(image.find("empty")), b"")
        with self.assertRaises(KeyError):
            image.find("missing")

    def test_volume_and_block_fields_are_checked(self) -> None:
        original = make_iso()
        for label, offset, replacement, message in (
            ("volume endian", PVD_OFFSET + 84, both32(31)[4:], "disagree"),
            ("block endian", PVD_OFFSET + 130, both16(512)[2:], "disagree"),
            ("block size", PVD_OFFSET + 128, both16(1024), "block size"),
            ("volume short", PVD_OFFSET + 80, both32(16), "too short"),
            ("volume outside image", PVD_OFFSET + 80, both32(33), "exceeds"),
            ("missing pvd", PVD_OFFSET, b"\x00", "descriptor"),
        ):
            with self.subTest(label=label):
                malformed = bytearray(original)
                malformed[offset : offset + len(replacement)] = replacement
                with self.assertRaisesRegex(DiscFormatError, message):
                    image_from(malformed)

    def test_image_and_read_boundaries(self) -> None:
        data = make_iso()
        for kwargs in (
            {"base_offset": -1},
            {"byte_length": -1},
            {"base_offset": len(data) + 1},
            {"byte_length": len(data) + 1},
        ):
            with self.subTest(kwargs=kwargs), self.assertRaises(DiscFormatError):
                image_from(data, **kwargs)
        with self.assertRaisesRegex(DiscFormatError, "boundary"):
            image_from(data[:-1])
        image = image_from(data + b"extra")
        for offset, length in ((-1, 1), (0, -1), (len(data), 1)):
            with self.subTest(offset=offset, length=length):
                with self.assertRaises(DiscFormatError):
                    image.read_at(offset, length)
        self.assertEqual(image.read_at(len(data), 0), b"")

    def test_short_physical_read_is_a_format_error(self) -> None:
        class ShortReader(io.BytesIO):
            def read(self, size: int = -1) -> bytes:
                return super().read(size - 1 if size > 0 else size)

        with self.assertRaisesRegex(DiscFormatError, "short read"):
            IsoImage(ShortReader(make_iso()))

    def test_root_record_must_be_a_nonempty_directory(self) -> None:
        original = make_iso()
        for label, offset, replacement in (
            ("file", PVD_OFFSET + 156 + 25, b"\x00"),
            ("wrong identifier", PVD_OFFSET + 156 + 33, b"A"),
            ("empty extent", PVD_OFFSET + 156 + 10, both32(0)),
            ("outside volume", PVD_OFFSET + 156 + 2, both32(32)),
        ):
            with self.subTest(label=label):
                malformed = bytearray(original)
                malformed[offset : offset + len(replacement)] = replacement
                with self.assertRaises(DiscFormatError):
                    image_from(malformed)

    def test_malformed_directory_records(self) -> None:
        original = make_iso({"AB;1": b"x"})
        cases = (
            ("short record", 0, b"\x20", "record"),
            ("odd record", 0, b"\x25", "odd"),
            ("extent endian", 6, b"\xff", "disagree"),
            ("length endian", 14, b"\xff", "disagree"),
            ("sequence endian", 30, b"\xff", "disagree"),
            ("empty identifier", 32, b"\x00", "identifier"),
            ("long identifier", 32, b"\xff", "identifier"),
            ("nonzero identifier pad", 37, b"\x01", "padding"),
        )
        for label, relative, replacement, message in cases:
            with self.subTest(label=label):
                malformed = bytearray(original)
                start = FIRST_FILE_RECORD + relative
                malformed[start : start + len(replacement)] = replacement
                image = image_from(malformed)
                with self.assertRaisesRegex(DiscFormatError, message):
                    image.entries()
        image = image_from(original)
        with self.assertRaisesRegex(DiscFormatError, "truncated directory record"):
            image._parse_record(b"\x22" + bytes(10), "")

    def test_nonzero_system_use_bytes_after_identifier_padding_are_allowed(self) -> None:
        data = bytearray(make_iso({"AB;1": b"x"}))
        length = data[FIRST_FILE_RECORD]
        record = bytearray(data[FIRST_FILE_RECORD : FIRST_FILE_RECORD + length])
        record[0] += 2
        record.extend(b"\xa5\x5a")
        data[FIRST_FILE_RECORD : FIRST_FILE_RECORD + len(record)] = record
        image = image_from(data)
        self.assertEqual(image.read_entry(image.find("AB")), b"x")

    def test_invalid_identifiers_cannot_hide_or_escape_paths(self) -> None:
        invalid = (
            b"\xff",
            b"../FILE",
            b"FILE\\NAME",
            b"C:FILE",
            b"\x00A",
            b"\x01A",
            b"A\x7f",
            b".",
            b"..",
            b";1",
            b".;1",
            b"..;1",
            b"...;1",
            b" .. ;1",
            b" ;1",
        )
        for identifier in invalid:
            with self.subTest(identifier=identifier):
                image = image_from(make_iso({identifier: b"x"}))
                with self.assertRaises(DiscFormatError):
                    image.entries()

    def test_directory_entry_extent_is_checked_against_volume(self) -> None:
        original = make_iso({"FILE;1": b"x"})
        for extent, size in ((32, 1), (31, SECTOR_SIZE + 1), (33, 0)):
            with self.subTest(extent=extent, size=size):
                malformed = bytearray(original + bytes(SECTOR_SIZE * 2))
                malformed[FIRST_FILE_RECORD + 2 : FIRST_FILE_RECORD + 10] = both32(extent)
                malformed[FIRST_FILE_RECORD + 10 : FIRST_FILE_RECORD + 18] = both32(size)
                with self.assertRaisesRegex(DiscFormatError, "exceeds ISO volume"):
                    image_from(malformed).entries()
        empty = bytearray(make_iso({"FILE;1": b""}))
        empty[FIRST_FILE_RECORD + 2 : FIRST_FILE_RECORD + 10] = both32(32)
        image = image_from(empty)
        self.assertEqual(image.read_entry(image.find("FILE")), b"")

    def test_record_cannot_cross_directory_extent(self) -> None:
        malformed = bytearray(make_iso({"FILE;1": b"x"}))
        malformed[PVD_OFFSET + 156 + 10 : PVD_OFFSET + 156 + 18] = both32(70)
        for offset in (ROOT_OFFSET + 10, ROOT_OFFSET + 34 + 10):
            malformed[offset : offset + 8] = both32(70)
        with self.assertRaisesRegex(DiscFormatError, "crosses"):
            image_from(malformed).entries()

    def test_record_cannot_cross_sector_even_within_extent(self) -> None:
        malformed = bytearray(make_iso(root_sectors=2))
        record = directory_record(b"A", ROOT_LBA + 2, 0)
        start = ROOT_OFFSET + 68
        malformed[start : start + 58 * len(record)] = record * 58
        self.assertEqual(start + 58 * len(record), ROOT_OFFSET + SECTOR_SIZE - 8)
        malformed[start + 58 * len(record) : start + 59 * len(record)] = record
        with self.assertRaisesRegex(DiscFormatError, "crosses"):
            image_from(malformed).entries()

    def test_zero_padding_advances_sectors_and_nonzero_padding_fails(self) -> None:
        data = bytearray(make_iso({"ONE;1": b"x"}, root_sectors=2))
        second = directory_record(b"TWO;1", ROOT_LBA + 2, 1)
        data[ROOT_OFFSET + SECTOR_SIZE : ROOT_OFFSET + SECTOR_SIZE + len(second)] = second
        image = image_from(data)
        self.assertEqual([entry.path for entry in image.entries()], ["ONE", "TWO"])
        self.assertEqual(image.read_entry(image.find("TWO")), b"x")

        malformed = bytearray(make_iso())
        malformed[ROOT_OFFSET + 70] = 1
        with self.assertRaisesRegex(DiscFormatError, "nonzero directory padding"):
            image_from(malformed).entries()

    def test_nested_directory_special_records_and_cycles(self) -> None:
        data = bytearray(make_iso({"SUBDIR": bytes(SECTOR_SIZE)}))
        data[FIRST_FILE_RECORD + 25] = 2
        child_offset = (ROOT_LBA + 1) * SECTOR_SIZE
        child_records = b"".join(
            (
                directory_record(b"\x00", ROOT_LBA + 1, SECTOR_SIZE, 2),
                directory_record(b"\x01", ROOT_LBA, SECTOR_SIZE, 2),
                directory_record(b"INNER.TXT;1", ROOT_LBA + 2, 4),
                directory_record(b"LOOP", ROOT_LBA, SECTOR_SIZE, 2),
            )
        )
        data[child_offset : child_offset + len(child_records)] = child_records
        data[(ROOT_LBA + 2) * SECTOR_SIZE : (ROOT_LBA + 2) * SECTOR_SIZE + 4] = b"data"
        image = image_from(data)
        self.assertEqual(
            [entry.path for entry in image.entries()],
            ["SUBDIR", "SUBDIR/INNER.TXT", "SUBDIR/LOOP"],
        )
        self.assertEqual(image.read_entry(image.find(r"subdir\inner.txt")), b"data")

        for label, relative, replacement in (
            ("wrong self extent", 2, both32(ROOT_LBA)),
            ("self is not directory", 25, b"\x00"),
            ("wrong parent extent", 34 + 2, both32(ROOT_LBA + 1)),
            ("wrong parent identifier", 34 + 33, b"A"),
        ):
            with self.subTest(label=label):
                malformed = bytearray(data)
                start = child_offset + relative
                malformed[start : start + len(replacement)] = replacement
                with self.assertRaisesRegex(DiscFormatError, "directory record"):
                    image_from(malformed).entries()

    def test_directory_must_have_special_entries_only_at_start(self) -> None:
        empty = bytearray(make_iso())
        empty[ROOT_OFFSET : ROOT_OFFSET + SECTOR_SIZE] = bytes(SECTOR_SIZE)
        with self.assertRaisesRegex(DiscFormatError, "missing"):
            image_from(empty).entries()
        missing_parent = bytearray(make_iso())
        missing_parent[ROOT_OFFSET + 34 : ROOT_OFFSET + SECTOR_SIZE] = bytes(
            SECTOR_SIZE - 34
        )
        with self.assertRaisesRegex(DiscFormatError, "missing"):
            image_from(missing_parent).entries()
        misplaced = bytearray(make_iso())
        extra_self = directory_record(b"\x00", ROOT_LBA, SECTOR_SIZE, 2)
        misplaced[ROOT_OFFSET + 68 : ROOT_OFFSET + 68 + len(extra_self)] = extra_self
        with self.assertRaisesRegex(DiscFormatError, "misplaced"):
            image_from(misplaced).entries()

    def test_deep_directory_nesting_is_a_format_error_not_a_crash(self) -> None:
        image = image_from(make_deep_iso(300))
        limit = sys.getrecursionlimit()
        try:
            sys.setrecursionlimit(200)
            with self.assertRaisesRegex(DiscFormatError, "nesting is too deep"):
                image.entries()
        finally:
            sys.setrecursionlimit(limit)


class EmbeddedIsoTests(unittest.TestCase):
    def test_zero_and_nonzero_bases_and_absolute_offset(self) -> None:
        inner = make_iso({"VALUE.DAT;1": b"inner content"})
        for base in (0, 3 * SECTOR_SIZE):
            with self.subTest(base=base):
                container = bytes(base) + inner
                wrapped = b"prefix" + container + b"suffix"
                self.assertEqual(
                    find_embedded_iso_base(io.BytesIO(wrapped), 6, len(container)),
                    base,
                )
                outer, entry = outer_with_container(container)
                found_base, image = open_embedded_iso(outer, entry)
                self.assertEqual(found_base, base)
                member = image.find("VALUE.DAT")
                self.assertEqual(image.read_entry(member), b"inner content")
                self.assertEqual(
                    image.absolute_offset(member),
                    outer.absolute_offset(entry) + base + 21 * SECTOR_SIZE,
                )

    def test_skips_aligned_invalid_candidates(self) -> None:
        inner = make_iso({"GOOD;1": b"ok"})
        for kind in ("endian", "root", "volume", "directory"):
            with self.subTest(kind=kind):
                base = 3 * SECTOR_SIZE
                container = bytearray(bytes(base) + inner)
                decoy = bytearray(inner[PVD_OFFSET : PVD_OFFSET + SECTOR_SIZE])
                if kind == "endian":
                    decoy[84] ^= 1
                elif kind == "root":
                    decoy[156 + 25] = 0
                elif kind == "volume":
                    decoy[80:88] = both32(len(container) // SECTOR_SIZE + 1)
                container[PVD_OFFSET : PVD_OFFSET + SECTOR_SIZE] = decoy
                self.assertEqual(
                    find_embedded_iso_base(io.BytesIO(container), 0, len(container)),
                    base,
                )
                outer, entry = outer_with_container(container)
                found_base, image = open_embedded_iso(outer, entry)
                self.assertEqual(found_base, base)
                self.assertEqual(image.read_entry(image.find("GOOD")), b"ok")

    def test_skips_decoy_with_invalid_file_extent(self) -> None:
        inner = make_iso({"GOOD;1": b"ok"})
        decoy = bytearray(make_iso({"BAD;1": b"x"}))
        decoy[FIRST_FILE_RECORD + 2 : FIRST_FILE_RECORD + 10] = both32(33)
        base = 16 * SECTOR_SIZE
        container = bytearray(bytes(base) + inner)
        container[PVD_OFFSET : PVD_OFFSET + SECTOR_SIZE] = decoy[
            PVD_OFFSET : PVD_OFFSET + SECTOR_SIZE
        ]
        container[ROOT_OFFSET : ROOT_OFFSET + SECTOR_SIZE] = decoy[
            ROOT_OFFSET : ROOT_OFFSET + SECTOR_SIZE
        ]
        outer, entry = outer_with_container(container)
        found_base, image = open_embedded_iso(outer, entry)
        self.assertEqual(found_base, base)
        self.assertEqual(image.read_entry(image.find("GOOD")), b"ok")

    def test_skips_decoy_with_empty_root_directory(self) -> None:
        inner = make_iso({"GOOD;1": b"ok"})
        base = 16 * SECTOR_SIZE
        container = bytearray(bytes(base) + inner)
        container[PVD_OFFSET : PVD_OFFSET + SECTOR_SIZE] = inner[
            PVD_OFFSET : PVD_OFFSET + SECTOR_SIZE
        ]
        container[ROOT_OFFSET : ROOT_OFFSET + SECTOR_SIZE] = bytes(SECTOR_SIZE)
        outer, entry = outer_with_container(container)
        found_base, image = open_embedded_iso(outer, entry)
        self.assertEqual(found_base, base)
        self.assertEqual(image.read_entry(image.find("GOOD")), b"ok")

    def test_unaligned_and_truncated_candidates_are_not_accepted(self) -> None:
        inner = make_iso()
        self.assertIsNone(
            find_embedded_iso_base(io.BytesIO(b"x" + inner), 0, len(inner) + 1)
        )
        outer, full_entry = outer_with_container(inner)
        for length in (PVD_OFFSET + 7, len(inner) - 1):
            with self.subTest(length=length):
                truncated = IsoEntry(full_entry.path, full_entry.extent_lba, length, 0)
                with self.assertRaisesRegex(DiscFormatError, "no embedded ISO"):
                    open_embedded_iso(outer, truncated)

    def test_parent_bounds_override_bytes_present_after_parent(self) -> None:
        outer_bytes = make_iso()
        inner = make_iso({"LEAK;1": b"no"})
        stream = io.BytesIO(outer_bytes + inner)
        outer = IsoImage(stream, byte_length=len(outer_bytes))
        outside = IsoEntry("OUTSIDE.CVM", len(outer_bytes) // SECTOR_SIZE, len(inner), 0)
        with self.assertRaisesRegex(DiscFormatError, "boundary"):
            open_embedded_iso(outer, outside)
        outer_with_trailing = IsoImage(stream, byte_length=len(outer_bytes) + len(inner))
        with self.assertRaisesRegex(DiscFormatError, "volume"):
            open_embedded_iso(outer_with_trailing, outside)
        with self.assertRaisesRegex(DiscFormatError, "negative"):
            open_embedded_iso(outer, IsoEntry("BAD.CVM", -1, len(inner), 0))
        with self.assertRaisesRegex(DiscFormatError, "negative"):
            open_embedded_iso(outer, IsoEntry("BAD.CVM", 1, -1, 0))

    def test_embedded_parent_base_and_boundary(self) -> None:
        inner = make_iso({"VALUE;1": b"inside"})
        parent_bytes = make_iso({"INNER.CVM;1": bytes(SECTOR_SIZE) + inner})
        prefix = bytes(2 * SECTOR_SIZE)
        stream = io.BytesIO(prefix + parent_bytes + inner)
        parent = IsoImage(stream, base_offset=len(prefix), byte_length=len(parent_bytes))
        entry = parent.find("INNER.CVM")
        base, embedded = open_embedded_iso(parent, entry)
        self.assertEqual(base, SECTOR_SIZE)
        self.assertEqual(embedded.read_entry(embedded.find("VALUE")), b"inside")
        self.assertEqual(
            embedded.base_offset, len(prefix) + entry.extent_lba * SECTOR_SIZE + base
        )
        outside = IsoEntry("OUTSIDE.CVM", len(parent_bytes) // SECTOR_SIZE, len(inner), 0)
        with self.assertRaisesRegex(DiscFormatError, "boundary"):
            open_embedded_iso(parent, outside)

    def test_probe_is_bounded_and_declared_container_must_exist(self) -> None:
        inner = make_iso({"FILE;1": b"x"})
        last_scanned_base = 0x40000 - PVD_OFFSET - SECTOR_SIZE
        outside_base = 0x40000 - PVD_OFFSET
        for base, expected in ((last_scanned_base, last_scanned_base), (outside_base, None)):
            with self.subTest(base=base):
                container = bytes(base) + inner
                self.assertEqual(
                    find_embedded_iso_base(io.BytesIO(container), 0, len(container)),
                    expected,
                )
                outer, entry = outer_with_container(container)
                if expected is None:
                    with self.assertRaisesRegex(DiscFormatError, "no embedded ISO"):
                        open_embedded_iso(outer, entry)
                else:
                    self.assertEqual(open_embedded_iso(outer, entry)[0], expected)
        with self.assertRaisesRegex(DiscFormatError, "past stream"):
            find_embedded_iso_base(io.BytesIO(inner), 0, len(inner) + 1)
        with self.assertRaisesRegex(DiscFormatError, "negative"):
            find_embedded_iso_base(io.BytesIO(inner), -1, len(inner))
        self.assertIsNone(find_embedded_iso_base(io.BytesIO(bytes(128)), 0, 128))

    def test_zero_stream_scan_handles_chunks_and_truncation(self) -> None:
        stream = io.BytesIO(b"XX" + bytes(9) + b"Y")
        self.assertTrue(stream_is_zero(stream, 2, 9, chunk_size=4))
        self.assertFalse(stream_is_zero(stream, 2, 10, chunk_size=4))
        self.assertFalse(stream_is_zero(stream, 2, 20, chunk_size=4))
        self.assertTrue(stream_is_zero(stream, 2, 0, chunk_size=4))


if __name__ == "__main__":
    unittest.main()
