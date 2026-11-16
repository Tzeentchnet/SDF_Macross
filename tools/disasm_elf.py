#!/usr/bin/env python3
"""Disassemble a named function from the game's ELF when Capstone is installed."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

from elf32 import Elf32, ElfFormatError


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("elf", type=Path)
    parser.add_argument("symbol")
    parser.add_argument("--instructions", type=int, default=200)
    args = parser.parse_args()
    try:
        from capstone import (
            CS_ARCH_MIPS,
            CS_MODE_LITTLE_ENDIAN,
            CS_MODE_MIPS64,
            Cs,
        )
    except ImportError:
        print("disasm_elf: install the optional 'capstone' package", file=sys.stderr)
        return 2

    try:
        data = args.elf.read_bytes()
        elf = Elf32(data)
        matches = [symbol for symbol in elf.symbols() if symbol.name == args.symbol]
        if not matches:
            raise ValueError(f"symbol not found: {args.symbol}")
        symbol = max(matches, key=lambda item: item.size)
        section = next(
            (
                item
                for item in elf.sections
                if item.address <= symbol.value < item.address + item.size
            ),
            None,
        )
        if not section:
            raise ValueError(f"symbol is outside a file-backed section: {args.symbol}")
        file_offset = section.offset + symbol.value - section.address
        size = symbol.size or args.instructions * 4
        code = data[file_offset : file_offset + size]
        disassembler = Cs(CS_ARCH_MIPS, CS_MODE_MIPS64 | CS_MODE_LITTLE_ENDIAN)
        decoded = {instruction.address: instruction for instruction in disassembler.disasm(code, symbol.value)}
        print(f"{symbol.name} @ {symbol.value:#010x}, {size} bytes")
        for index in range(0, min(size, args.instructions * 4), 4):
            address = symbol.value + index
            instruction = decoded.get(address)
            if instruction:
                print(
                    f"{instruction.address:08x}: "
                    f"{instruction.mnemonic:<10} {instruction.op_str}"
                )
            else:
                word = struct.unpack_from("<I", code, index)[0]
                print(f"{address:08x}: .word      0x{word:08x}")
        return 0
    except (OSError, ValueError, ElfFormatError, struct.error) as error:
        print(f"disasm_elf: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
