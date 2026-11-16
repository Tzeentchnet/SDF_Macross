#!/usr/bin/env python3
"""Parser for the offset-table MRG archives used by the game."""

from __future__ import annotations

import struct
from dataclasses import dataclass


class MrgFormatError(ValueError):
    pass


@dataclass(frozen=True)
class MrgMember:
    index: int
    offset: int
    size: int
    data: bytes


@dataclass(frozen=True)
class MrgArchive:
    count: int
    header_size: int
    members: tuple[MrgMember, ...]


def parse_mrg(data: bytes) -> MrgArchive:
    if len(data) < 8:
        raise MrgFormatError("MRG is shorter than its fixed header")
    count, header_size = struct.unpack_from("<II", data)
    if count < 1 or count > 4096:
        raise MrgFormatError(f"implausible member count {count}")
    table_end = 8 + (count - 1) * 4
    if header_size < table_end or header_size > len(data):
        raise MrgFormatError(
            f"header size {header_size:#x} cannot hold {count - 1} offsets"
        )
    if header_size % 0x10:
        raise MrgFormatError(f"header size {header_size:#x} is not 16-byte aligned")

    starts = [header_size]
    if count > 1:
        starts.extend(struct.unpack_from(f"<{count - 1}I", data, 8))
    if any(offset < header_size or offset > len(data) for offset in starts):
        raise MrgFormatError("member offset is outside the archive")
    if any(offset % 0x10 for offset in starts):
        raise MrgFormatError("member offset is not 16-byte aligned")
    if starts != sorted(starts) or len(set(starts)) != len(starts):
        raise MrgFormatError("member offsets are not strictly increasing")

    ends = starts[1:] + [len(data)]
    members = tuple(
        MrgMember(index, start, end - start, data[start:end])
        for index, (start, end) in enumerate(zip(starts, ends))
    )
    return MrgArchive(count=count, header_size=header_size, members=members)


def try_parse_mrg(data: bytes) -> MrgArchive | None:
    try:
        return parse_mrg(data)
    except MrgFormatError:
        return None


def printable_prefix(data: bytes, limit: int = 80) -> str:
    result = []
    for value in data[:limit]:
        if 0x20 <= value <= 0x7E:
            result.append(chr(value))
        elif value in (0x0A, 0x0D):
            result.append("\\n")
        else:
            result.append(".")
    return "".join(result)
