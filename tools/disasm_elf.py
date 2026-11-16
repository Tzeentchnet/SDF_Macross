#!/usr/bin/env python3
"""Disassemble a named function (or an address range) from the game's ELF.

Requires the optional Capstone package. Capstone does not know the R5900's
128-bit loads/stores or its MMI opcode space, so every word is decoded on its
own: an unknown word no longer stops decoding of the rest of the function.
`lq`, `sq` and the common MMI forms are decoded here; call targets are
annotated with their ELF symbol names. Ranges use 0xLO-0xHI with an exclusive,
word-aligned end, and must fit in one file-backed section.
"""

from __future__ import annotations

import argparse
import bisect
import re
import struct
import sys
from pathlib import Path

from elf32 import Elf32, ElfFormatError

GPR = [
    "zero", "at", "v0", "v1", "a0", "a1", "a2", "a3",
    "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
    "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
    "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra",
]

# R5900 MMI function field (opcode 0x1c) for the forms that are not sub-grouped.
MMI_FUNCT = {
    0x00: "madd", 0x01: "maddu", 0x04: "plzcw", 0x10: "mfhi1", 0x11: "mthi1",
    0x12: "mflo1", 0x13: "mtlo1", 0x18: "mult1", 0x19: "multu1", 0x1a: "div1",
    0x1b: "divu1", 0x20: "madd1", 0x21: "maddu1", 0x30: "pmfhl", 0x31: "pmthl",
    0x34: "psllh", 0x36: "psrlh", 0x37: "psrah", 0x3c: "psllw", 0x3e: "psrlw",
    0x3f: "psraw",
}
MMI_SUB = {
    0x08: {0x00: "paddw", 0x01: "psubw", 0x02: "pcgtw", 0x03: "pmaxw", 0x04: "paddh",
           0x05: "psubh", 0x06: "pcgth", 0x07: "pmaxh", 0x08: "paddb", 0x09: "psubb",
           0x0a: "pcgtb", 0x10: "paddsw", 0x11: "psubsw", 0x12: "pextlw", 0x13: "ppacw",
           0x14: "paddsh", 0x15: "psubsh", 0x16: "pextlh", 0x17: "ppach", 0x18: "paddsb",
           0x19: "psubsb", 0x1a: "pextlb", 0x1b: "ppacb", 0x1e: "pext5", 0x1f: "ppac5"},
    0x09: {0x00: "pmaddw", 0x02: "psllvw", 0x03: "psrlvw", 0x04: "pmsubw", 0x08: "pmfhi",
           0x09: "pmflo", 0x0a: "pinth", 0x0c: "pmultw", 0x0d: "pdivw", 0x0e: "pcpyld",
           0x10: "pmaddh", 0x11: "phmadh", 0x12: "pand", 0x13: "pxor", 0x14: "pmsubh",
           0x15: "phmsbh", 0x1a: "pexeh", 0x1b: "prevh", 0x1c: "pmulth", 0x1d: "pdivbw",
           0x1e: "pexew", 0x1f: "prot3w"},
    0x28: {0x01: "pabsw", 0x02: "pceqw", 0x03: "pminw", 0x04: "padsbh", 0x05: "pabsh",
           0x06: "pceqh", 0x07: "pminh", 0x0a: "pceqb", 0x10: "padduw", 0x11: "psubuw",
           0x12: "pextuw", 0x14: "padduh", 0x15: "psubuh", 0x16: "pextuh", 0x18: "paddub",
           0x19: "psubub", 0x1a: "pextub", 0x1b: "qfsrv"},
    0x29: {0x00: "pmadduw", 0x03: "psravw", 0x08: "pmthi", 0x09: "pmtlo", 0x0a: "pinteh",
           0x0c: "pmultuw", 0x0d: "pdivuw", 0x0e: "pcpyud", 0x12: "por", 0x13: "pnor",
           0x1a: "pexch", 0x1b: "pcpyh", 0x1e: "pexcw"},
}

MMI_RD_ONLY = {"mfhi1", "mflo1", "pmfhi", "pmflo"}
MMI_RS_ONLY = {"mthi1", "mtlo1", "pmthi", "pmtlo"}
MMI_RD_RT = {
    "pext5", "ppac5", "pabsw", "pabsh", "pexeh", "prevh", "pexew",
    "prot3w", "pexch", "pcpyh", "pexcw",
}
MMI_DIV = {"div1", "divu1", "pdivw", "pdivuw", "pdivbw"}
MMI_VARIABLE_SHIFT = {"psllvw", "psrlvw", "psravw"}
MMI_IMMEDIATE_SHIFT = {"psllh", "psrlh", "psrah", "psllw", "psrlw", "psraw"}
PMFHL_FORMATS = ("lw", "uw", "slw", "lh", "sh")

ADDRESS_LIMIT = 1 << 32
SHT_NULL = 0
SHT_NOBITS = 8
SHN_LORESERVE = 0xFF00
SHF_ALLOC = 0x2
SHF_EXECINSTR = 0x4
ADDRESS_RANGE = re.compile(r"0x([0-9a-fA-F]+)-0x([0-9a-fA-F]+)")


def word_directive(word: int) -> str:
    return f".word      {word:#010x}"


def r5900(word: int) -> str | None:
    """Decode R5900 forms, keeping unknown MMI encodings away from Capstone."""
    op = word >> 26
    rs, rt, rd = (word >> 21) & 31, (word >> 16) & 31, (word >> 11) & 31
    imm = struct.unpack("<h", struct.pack("<H", word & 0xFFFF))[0]
    if op in (0x1E, 0x1F):
        name = "lq" if op == 0x1E else "sq"
        return f"{name:<10} ${GPR[rt]}, {imm:#x}(${GPR[rs]})"
    if op == 0x1C:
        funct = word & 0x3F
        sa = (word >> 6) & 31
        if funct in MMI_SUB:
            name = MMI_SUB[funct].get(sa)
        else:
            name = MMI_FUNCT.get(funct)
        if name is None:
            return word_directive(word)

        if name == "pmfhl":
            if rs or rt or sa >= len(PMFHL_FORMATS):
                return word_directive(word)
            name = f"pmfhl.{PMFHL_FORMATS[sa]}"
            operands = (f"${GPR[rd]}",)
        elif name == "pmthl":
            if rt or rd or sa:
                return word_directive(word)
            name = "pmthl.lw"
            operands = (f"${GPR[rs]}",)
        elif name in MMI_IMMEDIATE_SHIFT:
            if rs:
                return word_directive(word)
            operands = (f"${GPR[rd]}", f"${GPR[rt]}", str(sa))
        else:
            if funct not in MMI_SUB and sa:
                return word_directive(word)
            if name in MMI_RD_ONLY:
                if rs or rt:
                    return word_directive(word)
                operands = (f"${GPR[rd]}",)
            elif name in MMI_RS_ONLY:
                if rt or rd:
                    return word_directive(word)
                operands = (f"${GPR[rs]}",)
            elif name == "plzcw":
                if rt:
                    return word_directive(word)
                operands = (f"${GPR[rd]}", f"${GPR[rs]}")
            elif name in MMI_RD_RT:
                if rs:
                    return word_directive(word)
                operands = (f"${GPR[rd]}", f"${GPR[rt]}")
            elif name in MMI_DIV:
                if rd:
                    return word_directive(word)
                operands = (f"${GPR[rs]}", f"${GPR[rt]}")
                if name in {"div1", "divu1"}:
                    # The scalar divide syntax has an explicit fixed-zero destination.
                    operands = ("$zero", *operands)
            elif name in MMI_VARIABLE_SHIFT:
                operands = (f"${GPR[rd]}", f"${GPR[rt]}", f"${GPR[rs]}")
            else:
                operands = (f"${GPR[rd]}", f"${GPR[rs]}", f"${GPR[rt]}")
        return f"{name:<10} {', '.join(operands)}"
    return None


def checked_range(start: int, end: int) -> None:
    if start < 0 or end > ADDRESS_LIMIT:
        raise ValueError("address range exceeds the 32-bit address space")
    if end <= start:
        raise ValueError("address range must be nonempty and increasing")
    if start % 4 or end % 4:
        raise ValueError("address range must contain aligned, complete 4-byte words")


def section_offset(section, start: int, end: int, file_size: int) -> int:
    """Validate an entire file-backed section and the requested interval."""
    if section.type in (SHT_NULL, SHT_NOBITS):
        raise ValueError(f"section {section.name!r} is not file-backed")
    section_end = section.address + section.size
    if section_end > ADDRESS_LIMIT:
        raise ValueError(f"section {section.name!r} exceeds the 32-bit address space")
    if start < section.address or end > section_end:
        raise ValueError(f"address range extends outside section {section.name!r}")
    if section.offset + section.size > file_size:
        raise ValueError(f"section {section.name!r} extends past the ELF")
    return section.offset + start - section.address


def symbol_section(symbol, sections):
    index = symbol.section_index
    if 0 < index < min(len(sections), SHN_LORESERVE):
        return sections[index]
    return None


def symbol_rank(symbol, section) -> tuple:
    return (
        bool(section.flags & SHF_EXECINSTR),
        (symbol.info & 0xF) == 2,
        bool(symbol.size),
        symbol.size,
        bool(symbol.info >> 4),
    )


def resolve_symbol(name: str, symbols, sections, file_size: int, instructions: int):
    matches = [symbol for symbol in symbols if symbol.name == name]
    if not matches:
        raise ValueError(f"symbol not found: {name}")
    candidates = []
    errors = []
    for symbol in matches:
        section = symbol_section(symbol, sections)
        if section is None:
            continue
        end = symbol.value + (symbol.size or instructions * 4)
        try:
            checked_range(symbol.value, end)
            offset = section_offset(section, symbol.value, end, file_size)
        except ValueError as error:
            errors.append(str(error))
            continue
        candidates.append((symbol_rank(symbol, section), symbol, end, offset))
    if not candidates:
        detail = f": {errors[0]}" if errors else " (no defined file-backed symbol)"
        raise ValueError(f"no suitable definition for symbol {name!r}{detail}")
    _, symbol, end, offset = max(candidates, key=lambda item: item[0])
    return symbol.value, end, offset


def resolve_range(start: int, end: int, sections, file_size: int) -> int:
    checked_range(start, end)
    candidates = [
        section for section in sections
        if section.size and section.address <= start < section.address + section.size
    ]
    # Non-allocated metadata commonly has address zero and must not mask a mapping.
    allocated = [section for section in candidates if section.flags & SHF_ALLOC]
    if allocated:
        candidates = allocated
    candidates.sort(key=lambda section: bool(section.flags & SHF_EXECINSTR), reverse=True)
    errors = []
    for section in candidates:
        try:
            return section_offset(section, start, end, file_size)
        except ValueError as error:
            errors.append(str(error))
    if errors:
        raise ValueError(errors[0])
    raise ValueError(f"address is outside a file-backed section: {start:#x}")


def symbols_by_address(symbols, sections, file_size: int) -> dict[int, str]:
    result = {}
    ranks = {}
    for symbol in symbols:
        section = symbol_section(symbol, sections)
        if section is None:
            continue
        end = symbol.value + (symbol.size or 4)
        try:
            checked_range(symbol.value, end)
            section_offset(section, symbol.value, end, file_size)
        except ValueError:
            continue
        rank = symbol_rank(symbol, section)
        if symbol.value not in ranks or rank > ranks[symbol.value]:
            ranks[symbol.value] = rank
            result[symbol.value] = symbol.name
    return result


def positive_int(value: str) -> int:
    try:
        result = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if result <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("elf", type=Path)
    parser.add_argument("symbol", help="symbol name, or an exclusive range 0xLO-0xHI")
    parser.add_argument(
        "--instructions", type=positive_int, default=200,
        help="maximum number of instructions (default: %(default)s)",
    )
    args = parser.parse_args()
    try:
        from capstone import CS_ARCH_MIPS, CS_MODE_LITTLE_ENDIAN, CS_MODE_MIPS64, Cs, CsError
    except ImportError:
        print("disasm_elf: install the optional 'capstone' package", file=sys.stderr)
        return 2

    try:
        data = args.elf.read_bytes()
        elf = Elf32(data)
        symbols = [symbol for symbol in elf.symbols() if symbol.name]
        by_address = symbols_by_address(symbols, elf.sections, len(data))
        range_match = ADDRESS_RANGE.fullmatch(args.symbol)
        if range_match:
            start, end = (int(part, 16) for part in range_match.groups())
            file_offset = resolve_range(start, end, elf.sections, len(data))
        else:
            start, end, file_offset = resolve_symbol(
                args.symbol, symbols, elf.sections, len(data), args.instructions
            )
        size = end - start
        code = data[file_offset : file_offset + size]
        cs = Cs(CS_ARCH_MIPS, CS_MODE_MIPS64 | CS_MODE_LITTLE_ENDIAN)
        print(f"{args.symbol} @ {start:#010x}, {size} bytes")
        for index in range(0, min(len(code), args.instructions * 4), 4):
            address = start + index
            word = struct.unpack_from("<I", code, index)[0]
            text = r5900(word)
            if word >> 26 in (2, 3):  # j / jal: name the target
                target = ((address + 4) & 0xF0000000) | ((word & 0x03FFFFFF) << 2)
                name = "j" if word >> 26 == 2 else "jal"
                text = f"{name:<10} {target:#x}"
                if target in by_address:
                    text += f"  <{by_address[target]}>"
            elif text is None:
                try:
                    decoded = next(cs.disasm(code[index : index + 4], address), None)
                except CsError:
                    decoded = None
                text = (
                    f"{decoded.mnemonic:<10} {decoded.op_str}".rstrip()
                    if decoded else word_directive(word)
                )
            print(f"{address:08x}: {text}")
        return 0
    except (OSError, ValueError, ElfFormatError, struct.error, CsError) as error:
        print(f"disasm_elf: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
