#!/usr/bin/env python3
"""Read the subset of little-endian ELF32 metadata needed for game analysis."""

from __future__ import annotations

import re
import struct
from dataclasses import dataclass


class ElfFormatError(ValueError):
    pass


@dataclass(frozen=True)
class Section:
    index: int
    name: str
    type: int
    flags: int
    address: int
    offset: int
    size: int
    link: int
    info: int
    alignment: int
    entry_size: int


@dataclass(frozen=True)
class Symbol:
    name: str
    value: int
    size: int
    info: int
    section_index: int


def _cstring(data: bytes, offset: int) -> str:
    if offset < 0 or offset >= len(data):
        return ""
    end = data.find(b"\x00", offset)
    if end < 0:
        end = len(data)
    return data[offset:end].decode("utf-8", "replace")


class Elf32:
    SHT_SYMTAB = 2

    def __init__(self, data: bytes) -> None:
        self.data = data
        if len(data) < 52 or data[:4] != b"\x7fELF":
            raise ElfFormatError("not an ELF file")
        if data[4] != 1 or data[5] != 1:
            raise ElfFormatError("expected 32-bit little-endian ELF")
        (
            self.type,
            self.machine,
            self.version,
            self.entry,
            self.program_offset,
            self.section_offset,
            self.flags,
            self.header_size,
            self.program_entry_size,
            self.program_count,
            self.section_entry_size,
            self.section_count,
            self.section_name_index,
        ) = struct.unpack_from("<HHIIIIIHHHHHH", data, 16)
        if self.section_entry_size < 40:
            raise ElfFormatError("invalid ELF section entry size")
        self.sections = self._read_sections()

    def _slice(self, offset: int, size: int, label: str) -> bytes:
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ElfFormatError(f"{label} extends past the ELF")
        return self.data[offset : offset + size]

    def _read_sections(self) -> list[Section]:
        raw_headers: list[tuple[int, ...]] = []
        for index in range(self.section_count):
            offset = self.section_offset + index * self.section_entry_size
            raw = self._slice(offset, 40, f"section header {index}")
            raw_headers.append(struct.unpack_from("<IIIIIIIIII", raw))
        if self.section_name_index >= len(raw_headers):
            raise ElfFormatError("invalid section-name table index")
        names_header = raw_headers[self.section_name_index]
        names = self._slice(names_header[4], names_header[5], "section-name table")
        sections = []
        for index, header in enumerate(raw_headers):
            sections.append(
                Section(
                    index=index,
                    name=_cstring(names, header[0]),
                    type=header[1],
                    flags=header[2],
                    address=header[3],
                    offset=header[4],
                    size=header[5],
                    link=header[6],
                    info=header[7],
                    alignment=header[8],
                    entry_size=header[9],
                )
            )
        return sections

    def symbols(self) -> list[Symbol]:
        symbols: list[Symbol] = []
        for section in self.sections:
            if section.type != self.SHT_SYMTAB or section.entry_size < 16:
                continue
            if section.link >= len(self.sections):
                raise ElfFormatError(f"{section.name}: invalid string table link")
            string_section = self.sections[section.link]
            strings = self._slice(
                string_section.offset, string_section.size, string_section.name
            )
            table = self._slice(section.offset, section.size, section.name)
            for offset in range(0, len(table) - 15, section.entry_size):
                name, value, size, info, _other, section_index = struct.unpack_from(
                    "<IIIBBH", table, offset
                )
                symbols.append(
                    Symbol(
                        name=_cstring(strings, name),
                        value=value,
                        size=size,
                        info=info,
                        section_index=section_index,
                    )
                )
        return symbols

    def summary(self, symbol_patterns: list[str] | None = None) -> dict:
        symbols = self.symbols()
        compiled = [re.compile(pattern, re.IGNORECASE) for pattern in symbol_patterns or []]
        selected = [
            {
                "name": symbol.name,
                "address": f"0x{symbol.value:08x}",
                "size": symbol.size,
                "sectionIndex": symbol.section_index,
            }
            for symbol in symbols
            if symbol.name and any(pattern.search(symbol.name) for pattern in compiled)
        ]
        return {
            "class": "ELF32",
            "endianness": "little",
            "machine": self.machine,
            "entryPoint": f"0x{self.entry:08x}",
            "programHeaderCount": self.program_count,
            "sectionCount": len(self.sections),
            "symbolCount": sum(1 for symbol in symbols if symbol.name),
            "sections": [
                {
                    "name": section.name,
                    "type": section.type,
                    "flags": f"0x{section.flags:x}",
                    "address": f"0x{section.address:08x}",
                    "offset": section.offset,
                    "size": section.size,
                    "alignment": section.alignment,
                }
                for section in self.sections
            ],
            "selectedSymbols": selected,
        }
