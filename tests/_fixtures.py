"""Deterministic, synthetic ISO, ELF, and MRG bytes for parser tests."""

from __future__ import annotations

import struct
from collections.abc import Mapping, Sequence

SECTOR_SIZE = 2048
PVD_OFFSET = 16 * SECTOR_SIZE
ROOT_LBA = 20
ROOT_OFFSET = ROOT_LBA * SECTOR_SIZE
FIRST_FILE_RECORD = ROOT_OFFSET + 68


def both16(value: int) -> bytes:
    return struct.pack("<H", value) + struct.pack(">H", value)


def both32(value: int) -> bytes:
    return struct.pack("<I", value) + struct.pack(">I", value)


def directory_record(
    identifier: bytes, extent: int, size: int, flags: int = 0
) -> bytes:
    length = 33 + len(identifier) + (len(identifier) % 2 == 0)
    if not identifier or length > 255:
        raise ValueError("fixture identifier does not fit a directory record")
    record = bytearray(length)
    record[0] = length
    record[2:10] = both32(extent)
    record[10:18] = both32(size)
    record[18:25] = bytes((124, 1, 1, 0, 0, 0, 0))
    record[25] = flags
    record[28:32] = both16(1)
    record[32] = len(identifier)
    record[33 : 33 + len(identifier)] = identifier
    return bytes(record)


def make_iso(
    files: Mapping[str | bytes, bytes] | None = None,
    *,
    root_sectors: int = 1,
) -> bytes:
    files = files or {}
    root_size = root_sectors * SECTOR_SIZE
    next_lba = ROOT_LBA + root_sectors
    layout: list[tuple[bytes, int, bytes]] = []
    for name, payload in files.items():
        identifier = name.encode("ascii") if isinstance(name, str) else name
        layout.append((identifier, next_lba, payload))
        next_lba += max(1, (len(payload) + SECTOR_SIZE - 1) // SECTOR_SIZE)
    volume_sectors = max(32, next_lba)
    image = bytearray(volume_sectors * SECTOR_SIZE)

    pvd = bytearray(SECTOR_SIZE)
    pvd[:7] = b"\x01CD001\x01"
    pvd[40:72] = b"SYNTHETIC".ljust(32, b" ")
    pvd[80:88] = both32(volume_sectors)
    pvd[120:124] = both16(1)
    pvd[124:128] = both16(1)
    pvd[128:132] = both16(SECTOR_SIZE)
    root_record = directory_record(b"\x00", ROOT_LBA, root_size, 2)
    pvd[156 : 156 + len(root_record)] = root_record
    image[PVD_OFFSET : PVD_OFFSET + SECTOR_SIZE] = pvd
    image[PVD_OFFSET + SECTOR_SIZE : PVD_OFFSET + SECTOR_SIZE + 7] = b"\xffCD001\x01"

    records = [
        root_record,
        directory_record(b"\x01", ROOT_LBA, root_size, 2),
        *(
            directory_record(identifier, lba, len(payload))
            for identifier, lba, payload in layout
        ),
    ]
    offset = 0
    for record in records:
        remaining = SECTOR_SIZE - offset % SECTOR_SIZE
        if len(record) > remaining:
            offset += remaining
        if offset + len(record) > root_size:
            raise ValueError("fixture root directory is full")
        image[ROOT_OFFSET + offset : ROOT_OFFSET + offset + len(record)] = record
        offset += len(record)
    for _identifier, lba, payload in layout:
        image[lba * SECTOR_SIZE : lba * SECTOR_SIZE + len(payload)] = payload
    return bytes(image)


def make_elf(payload: bytes = b"ORIGINAL") -> bytes:
    names = b"\x00.shstrtab\x00"
    section_offset = 52
    names_offset = section_offset + 2 * 40
    ident = b"\x7fELF\x01\x01\x01" + bytes(9)
    header = struct.pack(
        "<HHIIIIIHHHHHH",
        2,
        8,
        1,
        0x100000,
        0,
        section_offset,
        0,
        52,
        32,
        0,
        40,
        2,
        1,
    )
    null_section = bytes(40)
    names_section = struct.pack(
        "<IIIIIIIIII", 1, 3, 0, 0, names_offset, len(names), 0, 0, 1, 0
    )
    return ident + header + null_section + names_section + names + payload


def make_deep_iso(depth: int) -> bytes:
    if depth < 1:
        raise ValueError("fixture requires a root directory")
    image = bytearray(make_iso())
    volume_sectors = max(32, ROOT_LBA + depth)
    image.extend(bytes(volume_sectors * SECTOR_SIZE - len(image)))
    image[PVD_OFFSET + 80 : PVD_OFFSET + 88] = both32(volume_sectors)
    for level in range(depth):
        lba = ROOT_LBA + level
        parent_lba = ROOT_LBA + max(level - 1, 0)
        records = (
            directory_record(b"\x00", lba, SECTOR_SIZE, 2)
            + directory_record(b"\x01", parent_lba, SECTOR_SIZE, 2)
        )
        if level + 1 < depth:
            records += directory_record(b"D", lba + 1, SECTOR_SIZE, 2)
        start = lba * SECTOR_SIZE
        image[start : start + len(records)] = records
    return bytes(image)


def make_mrg(members: Sequence[bytes]) -> bytes:
    if not members or len(members) > 4096 or any(not item for item in members[:-1]):
        raise ValueError("fixture requires nonempty members except possibly the last")
    table_end = 8 + 4 * (len(members) - 1)
    header_size = (table_end + 15) // 16 * 16
    archive = bytearray(header_size)
    struct.pack_into("<II", archive, 0, len(members), header_size)
    archive[table_end:header_size] = b"\xa5" * (header_size - table_end)
    for index, member in enumerate(members):
        if index:
            struct.pack_into("<I", archive, 8 + (index - 1) * 4, len(archive))
        archive.extend(member)
        if index < len(members) - 1:
            archive.extend(bytes(-len(archive) % 16))
    return bytes(archive)
