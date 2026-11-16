#!/usr/bin/env python3
"""Small, read-only ISO 9660 and CRI CVM reader used by the project tools."""

from __future__ import annotations

import hashlib
import io
import os
import re
import struct
from dataclasses import dataclass
from typing import BinaryIO, Iterable

SECTOR_SIZE = 2048
PVD_SECTOR = 16
PVD_MAGIC = b"\x01CD001\x01"


class DiscFormatError(ValueError):
    pass


@dataclass(frozen=True)
class IsoEntry:
    path: str
    extent_lba: int
    size: int
    flags: int

    @property
    def is_directory(self) -> bool:
        return bool(self.flags & 0x02)


def _both_u16(data: bytes, offset: int, field: str) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise DiscFormatError(f"{field}: truncated ISO both-endian value")
    little = struct.unpack_from("<H", data, offset)[0]
    big = struct.unpack_from(">H", data, offset + 2)[0]
    if little != big:
        raise DiscFormatError(
            f"{field}: ISO both-endian values disagree ({little} != {big})"
        )
    return little


def _both_u32(data: bytes, offset: int, field: str) -> int:
    if offset < 0 or offset + 8 > len(data):
        raise DiscFormatError(f"{field}: truncated ISO both-endian value")
    little = struct.unpack_from("<I", data, offset)[0]
    big = struct.unpack_from(">I", data, offset + 4)[0]
    if little != big:
        raise DiscFormatError(
            f"{field}: ISO both-endian values disagree ({little} != {big})"
        )
    return little


def _clean_identifier(raw: bytes) -> str:
    try:
        name = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise DiscFormatError(f"non-ASCII ISO identifier: {raw!r}") from exc
    if any(ord(char) < 0x20 or ord(char) == 0x7F or char in "/\\:" for char in name):
        raise DiscFormatError(f"unsafe ISO identifier: {raw!r}")
    name = re.sub(r";[0-9]+$", "", name)
    if not name.strip(" ."):
        raise DiscFormatError(f"unsafe ISO identifier: {raw!r}")
    return name


class IsoImage:
    """ISO 9660 view over a file, optionally beginning at an embedded offset."""

    def __init__(
        self,
        stream: BinaryIO,
        *,
        base_offset: int = 0,
        byte_length: int | None = None,
        label: str = "image",
    ) -> None:
        self.stream = stream
        self.base_offset = base_offset
        self.label = label
        self._entries: list[IsoEntry] | None = None
        if base_offset < 0 or (byte_length is not None and byte_length < 0):
            raise DiscFormatError(f"{label}: negative image boundary")
        stream.seek(0, io.SEEK_END)
        available = stream.tell() - base_offset
        if available < 0 or (byte_length is not None and byte_length > available):
            raise DiscFormatError(f"{label}: image boundary extends past stream")
        self.byte_length = available if byte_length is None else byte_length
        self._volume_bytes: int | None = None

        pvd = self.read_at(PVD_SECTOR * SECTOR_SIZE, SECTOR_SIZE)
        if pvd[:7] != PVD_MAGIC:
            raise DiscFormatError(
                f"{label}: missing ISO 9660 primary volume descriptor"
            )
        self.volume_id = pvd[40:72].decode("ascii", "replace").rstrip(" ")
        self.volume_sectors = _both_u32(pvd, 80, f"{label} volume size")
        block_size = _both_u16(pvd, 128, f"{label} logical block size")
        if block_size != SECTOR_SIZE:
            raise DiscFormatError(f"{label}: unsupported logical block size {block_size}")
        self._volume_bytes = self.volume_sectors * SECTOR_SIZE
        if self._volume_bytes < (PVD_SECTOR + 1) * SECTOR_SIZE:
            raise DiscFormatError(f"{label}: ISO volume is too short for its descriptor")
        if self._volume_bytes > self.byte_length:
            raise DiscFormatError(f"{label}: ISO volume exceeds image boundary")
        self._root = self._parse_record(pvd[156:], "")
        if not self._root.is_directory or self._root.path != "." or not self._root.size:
            raise DiscFormatError(f"{label}: invalid root directory record")

    @classmethod
    def open(cls, path: str | os.PathLike[str]) -> tuple[BinaryIO, "IsoImage"]:
        stream = open(path, "rb")
        try:
            size = os.fstat(stream.fileno()).st_size
            image = cls(stream, byte_length=size, label=os.fspath(path))
        except Exception:
            stream.close()
            raise
        return stream, image

    def read_at(self, relative_offset: int, size: int) -> bytes:
        if relative_offset < 0 or size < 0:
            raise DiscFormatError(f"{self.label}: negative read")
        if relative_offset + size > self.byte_length:
            raise DiscFormatError(
                f"{self.label}: read past image boundary at {relative_offset:#x}"
            )
        if self._volume_bytes is not None and relative_offset + size > self._volume_bytes:
            raise DiscFormatError(
                f"{self.label}: read past ISO volume at {relative_offset:#x}"
            )
        self.stream.seek(self.base_offset + relative_offset)
        data = self.stream.read(size)
        if len(data) != size:
            raise DiscFormatError(
                f"{self.label}: short read at {relative_offset:#x}: "
                f"wanted {size}, got {len(data)}"
            )
        return data

    def read_entry(self, entry: IsoEntry) -> bytes:
        return self.read_at(entry.extent_lba * SECTOR_SIZE, entry.size)

    def absolute_offset(self, entry: IsoEntry) -> int:
        return self.base_offset + entry.extent_lba * SECTOR_SIZE

    def hash_entry(self, entry: IsoEntry, algorithm: str = "sha256") -> str:
        digest = hashlib.new(algorithm)
        remaining = entry.size
        offset = entry.extent_lba * SECTOR_SIZE
        while remaining:
            amount = min(1024 * 1024, remaining)
            digest.update(self.read_at(offset, amount))
            offset += amount
            remaining -= amount
        return digest.hexdigest()

    def _parse_record(self, data: bytes, parent: str) -> IsoEntry:
        if len(data) < 34:
            raise DiscFormatError(f"{self.label}: truncated directory record")
        record_length = data[0]
        if record_length < 34 or record_length > len(data):
            raise DiscFormatError(
                f"{self.label}: invalid directory record length {record_length}"
            )
        if record_length % 2:
            raise DiscFormatError(f"{self.label}: odd directory record length")
        record = data[:record_length]
        extent = _both_u32(record, 2, f"{self.label} directory extent")
        size = _both_u32(record, 10, f"{self.label} directory length")
        _both_u16(record, 28, f"{self.label} volume sequence")
        identifier_length = record[32]
        identifier_end = 33 + identifier_length
        if not identifier_length or identifier_end > record_length:
            raise DiscFormatError(f"{self.label}: truncated directory identifier")
        if identifier_length % 2 == 0:
            if identifier_end >= record_length or record[identifier_end] != 0:
                raise DiscFormatError(f"{self.label}: invalid directory identifier padding")
        if extent * SECTOR_SIZE + size > self._volume_bytes:
            raise DiscFormatError(f"{self.label}: directory entry exceeds ISO volume")
        raw_name = record[33:identifier_end]
        if raw_name == b"\x00":
            name = "."
        elif raw_name == b"\x01":
            name = ".."
        else:
            name = _clean_identifier(raw_name)
        path = name if not parent else f"{parent}/{name}"
        return IsoEntry(path=path, extent_lba=extent, size=size, flags=record[25])

    def _walk_directory(
        self,
        directory: IsoEntry,
        parent: str,
        visited: set[tuple[int, int]],
        parent_directory: IsoEntry | None = None,
    ) -> Iterable[IsoEntry]:
        key = (directory.extent_lba, directory.size)
        if key in visited:
            return
        visited.add(key)
        record_count = 0
        for sector_offset in range(0, directory.size, SECTOR_SIZE):
            data = self.read_at(
                directory.extent_lba * SECTOR_SIZE + sector_offset,
                min(SECTOR_SIZE, directory.size - sector_offset),
            )
            offset = 0
            while offset < len(data):
                record_length = data[offset]
                if record_length == 0:
                    if any(data[offset:]):
                        raise DiscFormatError(f"{self.label}: nonzero directory padding")
                    break
                if offset + record_length > len(data):
                    raise DiscFormatError(
                        f"{self.label}: directory record crosses a sector or its extent"
                    )
                entry = self._parse_record(data[offset : offset + record_length], parent)
                offset += record_length
                leaf = entry.path.rsplit("/", 1)[-1]
                if record_count < 2:
                    expected_name = "." if record_count == 0 else ".."
                    expected_directory = (
                        directory if record_count == 0 else parent_directory or directory
                    )
                    if (
                        leaf != expected_name
                        or not entry.is_directory
                        or (entry.extent_lba, entry.size)
                        != (expected_directory.extent_lba, expected_directory.size)
                    ):
                        raise DiscFormatError(
                            f"{self.label}: invalid {expected_name} directory record"
                        )
                    record_count += 1
                    continue
                if leaf in (".", ".."):
                    raise DiscFormatError(f"{self.label}: misplaced special directory record")
                record_count += 1
                yield entry
                if entry.is_directory:
                    yield from self._walk_directory(entry, entry.path, visited, directory)
        if record_count < 2:
            raise DiscFormatError(f"{self.label}: directory is missing . or .. records")

    def entries(self) -> list[IsoEntry]:
        if self._entries is None:
            try:
                self._entries = list(self._walk_directory(self._root, "", set()))
            except RecursionError as exc:
                raise DiscFormatError(f"{self.label}: directory nesting is too deep") from exc
        return list(self._entries)

    def find(self, path: str) -> IsoEntry:
        normalized = path.replace("\\", "/").lstrip("/").upper()
        for entry in self.entries():
            if entry.path.upper() == normalized:
                return entry
        raise KeyError(path)


def find_embedded_iso_base(
    stream: BinaryIO, absolute_offset: int, byte_length: int
) -> int | None:
    """Return the relative base of a structurally valid ISO inside a CVM."""
    result = _find_embedded_iso(stream, absolute_offset, byte_length, "embedded image")
    return result[0] if result is not None else None


def _find_embedded_iso(
    stream: BinaryIO, absolute_offset: int, byte_length: int, label: str
) -> tuple[int, IsoImage] | None:
    if absolute_offset < 0 or byte_length < 0:
        raise DiscFormatError(f"{label}: negative container boundary")
    stream.seek(0, io.SEEK_END)
    if absolute_offset + byte_length > stream.tell():
        raise DiscFormatError(f"{label}: container boundary extends past stream")

    probe_size = min(byte_length, 0x40000)
    stream.seek(absolute_offset)
    probe = stream.read(probe_size)
    start = 0
    while True:
        descriptor = probe.find(PVD_MAGIC, start)
        if descriptor < 0:
            return None
        base = descriptor - PVD_SECTOR * SECTOR_SIZE
        if base >= 0 and base % SECTOR_SIZE == 0:
            try:
                image = IsoImage(
                    stream,
                    base_offset=absolute_offset + base,
                    byte_length=byte_length - base,
                    label=label,
                )
                image.entries()
            except DiscFormatError:
                pass
            else:
                return base, image
        start = descriptor + 1


def open_embedded_iso(outer: IsoImage, entry: IsoEntry) -> tuple[int, IsoImage]:
    if entry.size < 0:
        raise DiscFormatError(f"{entry.path}: negative container size")
    outer.read_at(entry.extent_lba * SECTOR_SIZE, 0)
    if entry.size:
        outer.read_at(entry.extent_lba * SECTOR_SIZE + entry.size - 1, 1)
    absolute = outer.absolute_offset(entry)
    result = _find_embedded_iso(outer.stream, absolute, entry.size, entry.path)
    if result is None:
        raise DiscFormatError(f"{entry.path}: no embedded ISO 9660 image found")
    return result


def stream_is_zero(
    stream: BinaryIO, absolute_offset: int, byte_length: int, chunk_size: int = 1024 * 1024
) -> bool:
    stream.seek(absolute_offset)
    remaining = byte_length
    zero = bytes(chunk_size)
    while remaining:
        amount = min(chunk_size, remaining)
        if stream.read(amount) != zero[:amount]:
            return False
        remaining -= amount
    return True
