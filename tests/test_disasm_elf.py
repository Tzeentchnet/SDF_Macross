import contextlib
import importlib.util
import io
import struct
import sys
import types
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import disasm_elf


def mmi(funct, *, rs=0, rt=0, rd=0, sa=0):
    return (0x1C << 26) | (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | funct


def words(*values):
    return struct.pack(f"<{len(values)}I", *values)


def make_elf(code, *, address=0x1000, symbols=(), extra_sections=()):
    """Create an ELF32 containing only synthetic sections and symbols."""
    data = bytearray(52)

    def append(blob, alignment=1):
        data.extend(b"\0" * (-len(data) % alignment))
        offset = len(data)
        data.extend(blob)
        return offset

    text_offset = append(code, 4)
    extras = []
    for spec in extra_sections:
        section_type = spec.get("type", 1)
        payload = spec.get("data", b"")
        offset = text_offset if section_type == 8 else append(payload, 4)
        extras.append((
            spec["name"], section_type, spec.get("flags", 6), spec["address"],
            offset, spec.get("size", len(payload)), 0, 0, 4, 0,
        ))

    strings = bytearray(b"\0")
    symbol_data = bytearray(16)
    for name, value, size, section_index, info in symbols:
        name_offset = len(strings)
        strings.extend(name.encode("ascii") + b"\0")
        symbol_data.extend(struct.pack("<IIIBBH", name_offset, value, size, info, 0, section_index))
    strings_offset = append(strings)

    section_names = ["", ".text", ".strtab", ".shstrtab", ".symtab"]
    section_names.extend(section[0] for section in extras)
    names = bytearray(b"\0")
    name_offsets = {"": 0}
    for name in section_names[1:]:
        name_offsets[name] = len(names)
        names.extend(name.encode("ascii") + b"\0")
    names_offset = append(names)
    symbols_offset = append(symbol_data, 4)

    sections = [
        ("", 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (".text", 1, 6, address, text_offset, len(code), 0, 0, 4, 0),
        (".strtab", 3, 0, 0, strings_offset, len(strings), 0, 0, 1, 0),
        (".shstrtab", 3, 0, 0, names_offset, len(names), 0, 0, 1, 0),
        (".symtab", 2, 0, 0, symbols_offset, len(symbol_data), 2, 1, 4, 16),
        *extras,
    ]
    section_offset = append(b"", 4)
    for name, *fields in sections:
        data.extend(struct.pack("<10I", name_offsets[name], *fields))

    ident = b"\x7fELF\x01\x01\x01" + b"\0" * 9
    header = struct.pack(
        "<16sHHIIIIIHHHHHH", ident, 2, 8, 1, address, 0, section_offset, 0,
        52, 0, 0, 40, len(sections), 3,
    )
    data[:52] = header
    return bytes(data)


def change_section(data, index, **changes):
    positions = {
        "type": 1, "flags": 2, "address": 3, "offset": 4, "size": 5,
        "link": 6, "info": 7, "alignment": 8, "entry_size": 9,
    }
    data = bytearray(data)
    table_offset = struct.unpack_from("<I", data, 32)[0]
    for name, value in changes.items():
        struct.pack_into("<I", data, table_offset + index * 40 + positions[name] * 4, value)
    return bytes(data)


class FakeCsError(Exception):
    pass


class FakeCs:
    calls = []

    def __init__(self, _architecture, _mode):
        pass

    def disasm(self, code, address):
        word = struct.unpack("<I", code)[0]
        self.calls.append((address, word))
        if word == 0x0000003E:
            raise FakeCsError("synthetic decoder error")
        if word == 0x0000003F:
            return iter(())
        if word == mmi(0x02):
            return iter((types.SimpleNamespace(mnemonic="wrong-mips-mul", op_str=""),))
        if word == 0x24020001:
            return iter((types.SimpleNamespace(mnemonic="addiu", op_str="$v0, $zero, 1"),))
        if word == 0:
            return iter((types.SimpleNamespace(mnemonic="nop", op_str=""),))
        return iter(())


fake_capstone = types.ModuleType("capstone")
fake_capstone.CS_ARCH_MIPS = 1
fake_capstone.CS_MODE_LITTLE_ENDIAN = 2
fake_capstone.CS_MODE_MIPS64 = 4
fake_capstone.Cs = FakeCs
fake_capstone.CsError = FakeCsError
HAS_CAPSTONE = importlib.util.find_spec("capstone") is not None


def run_main(data, symbol, *options, capstone=fake_capstone):
    stdout, stderr = io.StringIO(), io.StringIO()
    FakeCs.calls = []
    arguments = ["disasm_elf.py", "synthetic.elf", symbol, *options]
    with (
        mock.patch.object(sys, "argv", arguments),
        mock.patch.dict(sys.modules, {"capstone": capstone}),
        mock.patch.object(Path, "read_bytes", return_value=data),
        contextlib.redirect_stdout(stdout),
        contextlib.redirect_stderr(stderr),
    ):
        result = disasm_elf.main()
    return result, stdout.getvalue(), stderr.getvalue()


class R5900Tests(unittest.TestCase):
    def assert_decoded(self, word, mnemonic, operands):
        self.assertEqual(disasm_elf.r5900(word), f"{mnemonic:<10} {operands}")

    def test_signed_lq_and_sq_offsets(self):
        for opcode, name in ((0x1E, "lq"), (0x1F, "sq")):
            for encoded, expected in (
                (0, "0x0"), (0x7FFF, "0x7fff"), (0x8000, "-0x8000"), (0xFFFF, "-0x1")
            ):
                with self.subTest(name=name, immediate=encoded):
                    word = (opcode << 26) | (29 << 21) | (2 << 16) | encoded
                    self.assert_decoded(word, name, f"$v0, {expected}($sp)")
        self.assertIsNone(disasm_elf.r5900(0))

    def test_three_register_mmi_forms(self):
        ordinary = {
            0x00: "madd", 0x01: "maddu", 0x18: "mult1", 0x19: "multu1",
            0x20: "madd1", 0x21: "maddu1",
        }
        for funct, name in ordinary.items():
            with self.subTest(name=name):
                self.assert_decoded(mmi(funct, rs=1, rt=2, rd=3), name, "$v1, $at, $v0")

        grouped = {
            0x08: {
                0x00: "paddw", 0x01: "psubw", 0x02: "pcgtw", 0x03: "pmaxw",
                0x04: "paddh", 0x05: "psubh", 0x06: "pcgth", 0x07: "pmaxh",
                0x08: "paddb", 0x09: "psubb", 0x0A: "pcgtb", 0x10: "paddsw",
                0x11: "psubsw", 0x12: "pextlw", 0x13: "ppacw", 0x14: "paddsh",
                0x15: "psubsh", 0x16: "pextlh", 0x17: "ppach", 0x18: "paddsb",
                0x19: "psubsb", 0x1A: "pextlb", 0x1B: "ppacb",
            },
            0x09: {
                0x00: "pmaddw", 0x04: "pmsubw", 0x0A: "pinth", 0x0C: "pmultw",
                0x0E: "pcpyld", 0x10: "pmaddh", 0x11: "phmadh", 0x12: "pand",
                0x13: "pxor", 0x14: "pmsubh", 0x15: "phmsbh", 0x1C: "pmulth",
            },
            0x28: {
                0x02: "pceqw", 0x03: "pminw", 0x04: "padsbh", 0x06: "pceqh",
                0x07: "pminh", 0x0A: "pceqb", 0x10: "padduw", 0x11: "psubuw",
                0x12: "pextuw", 0x14: "padduh", 0x15: "psubuh", 0x16: "pextuh",
                0x18: "paddub", 0x19: "psubub", 0x1A: "pextub", 0x1B: "qfsrv",
            },
            0x29: {
                0x00: "pmadduw", 0x0A: "pinteh", 0x0C: "pmultuw", 0x0E: "pcpyud",
                0x12: "por", 0x13: "pnor",
            },
        }
        for funct, table in grouped.items():
            for sub, name in table.items():
                with self.subTest(name=name):
                    self.assert_decoded(
                        mmi(funct, rs=1, rt=2, rd=3, sa=sub), name, "$v1, $at, $v0"
                    )
        self.assert_decoded(mmi(0x08), "paddw", "$zero, $zero, $zero")

    def test_unary_and_two_register_mmi_forms(self):
        for funct, name in ((0x10, "mfhi1"), (0x12, "mflo1")):
            with self.subTest(name=name):
                self.assert_decoded(mmi(funct, rd=3), name, "$v1")
                self.assert_decoded(mmi(funct), name, "$zero")
        for funct, name in ((0x11, "mthi1"), (0x13, "mtlo1")):
            with self.subTest(name=name):
                self.assert_decoded(mmi(funct, rs=1), name, "$at")
                self.assert_decoded(mmi(funct), name, "$zero")
        self.assert_decoded(mmi(0x04, rs=1, rd=3), "plzcw", "$v1, $at")

        for sub, name in ((0x08, "pmfhi"), (0x09, "pmflo")):
            self.assert_decoded(mmi(0x09, rd=3, sa=sub), name, "$v1")
        for sub, name in ((0x08, "pmthi"), (0x09, "pmtlo")):
            self.assert_decoded(mmi(0x29, rs=1, sa=sub), name, "$at")

        unary = {
            0x08: {0x1E: "pext5", 0x1F: "ppac5"},
            0x09: {0x1A: "pexeh", 0x1B: "prevh", 0x1E: "pexew", 0x1F: "prot3w"},
            0x28: {0x01: "pabsw", 0x05: "pabsh"},
            0x29: {0x1A: "pexch", 0x1B: "pcpyh", 0x1E: "pexcw"},
        }
        for funct, table in unary.items():
            for sub, name in table.items():
                with self.subTest(name=name):
                    self.assert_decoded(mmi(funct, rt=2, rd=3, sa=sub), name, "$v1, $v0")
                    self.assert_decoded(mmi(funct, sa=sub), name, "$zero, $zero")

        for funct, name in ((0x1A, "div1"), (0x1B, "divu1")):
            self.assert_decoded(mmi(funct, rs=1, rt=2), name, "$zero, $at, $v0")
        for funct, sub, name in (
            (0x09, 0x0D, "pdivw"), (0x09, 0x1D, "pdivbw"), (0x29, 0x0D, "pdivuw")
        ):
            self.assert_decoded(mmi(funct, rs=1, rt=2, sa=sub), name, "$at, $v0")

    def test_shift_and_hi_lo_formats(self):
        for funct, name in (
            (0x34, "psllh"), (0x36, "psrlh"), (0x37, "psrah"),
            (0x3C, "psllw"), (0x3E, "psrlw"), (0x3F, "psraw")
        ):
            for amount in (0, 15, 31):
                with self.subTest(name=name, amount=amount):
                    self.assert_decoded(
                        mmi(funct, rt=2, rd=3, sa=amount), name, f"$v1, $v0, {amount}"
                    )
        for funct, sub, name in (
            (0x09, 0x02, "psllvw"), (0x09, 0x03, "psrlvw"), (0x29, 0x03, "psravw")
        ):
            with self.subTest(name=name):
                self.assert_decoded(
                    mmi(funct, rs=1, rt=2, rd=3, sa=sub), name, "$v1, $v0, $at"
                )
                self.assert_decoded(mmi(funct, sa=sub), name, "$zero, $zero, $zero")
        for sub, suffix in enumerate(("lw", "uw", "slw", "lh", "sh")):
            self.assert_decoded(mmi(0x30, rd=3, sa=sub), f"pmfhl.{suffix}", "$v1")
        self.assert_decoded(mmi(0x30), "pmfhl.lw", "$zero")
        self.assert_decoded(mmi(0x31, rs=1), "pmthl.lw", "$at")
        self.assert_decoded(mmi(0x31), "pmthl.lw", "$zero")

    def test_unknown_and_reserved_mmi_encodings_are_words(self):
        invalid = (
            mmi(0x02), mmi(0x3B), mmi(0x08, sa=0x0B), mmi(0x09, sa=0x01),
            mmi(0x28, sa=0x00), mmi(0x29, sa=0x1F), mmi(0x30, sa=5),
            mmi(0x30, sa=31), mmi(0x31, sa=1), mmi(0x30, rs=1),
            mmi(0x31, rd=1), mmi(0x00, sa=1), mmi(0x10, rs=1),
            mmi(0x11, rt=1), mmi(0x04, rt=1), mmi(0x1A, rd=1),
            mmi(0x34, rs=1), mmi(0x28, rs=1, sa=1), mmi(0x09, rd=1, sa=0x0D),
        )
        for word in invalid:
            with self.subTest(word=f"{word:#010x}"):
                self.assertEqual(disasm_elf.r5900(word), f".word      {word:#010x}")


class DisassemblyTests(unittest.TestCase):
    def assert_error(self, data, symbol, *options, contains=None):
        result, stdout, stderr = run_main(data, symbol, *options)
        self.assertEqual(result, 2, stderr)
        self.assertEqual(stdout, "")
        self.assertIn("disasm_elf:", stderr)
        if contains:
            self.assertIn(contains, stderr)

    def test_recovery_after_unknown_words_and_capstone_errors(self):
        unknown_mmi = mmi(0x02)
        data = make_elf(words(0, 0x0000003F, unknown_mmi, 0x0000003E, 0x24020001))
        result, out, err = run_main(data, "0x1000-0x1014")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("00001000: nop", out)
        self.assertIn("00001004: .word      0x0000003f", out)
        self.assertIn("00001008: .word      0x70000002", out)
        self.assertIn("0000100c: .word      0x0000003e", out)
        self.assertIn("00001010: addiu", out)
        self.assertNotIn((0x1008, unknown_mmi), FakeCs.calls)

    @unittest.skipUnless(HAS_CAPSTONE, "Capstone is optional")
    def test_real_capstone_integration(self):
        import capstone

        data = make_elf(words(0, mmi(0x02), mmi(0x08, rs=1, rt=2, rd=3), 0x24020001))
        result, out, err = run_main(data, "0x1000-0x1010", capstone=capstone)
        self.assertEqual((result, err), (0, ""))
        self.assertIn("00001000: nop", out)
        self.assertIn("00001004: .word      0x70000002", out)
        self.assertIn("00001008: paddw      $v1, $at, $v0", out)
        self.assertIn("0000100c: addiu", out)

    def test_range_grammar_and_hyphenated_symbols(self):
        symbols = (
            ("valid-symbol", 0x1000, 4, 1, 0x12),
            ("0xname-with-hyphen", 0x1004, 4, 1, 0x12),
            ("0X1000-0X1004", 0x1000, 4, 1, 0x12),
        )
        data = make_elf(words(0, 0, 0), symbols=symbols)
        for target in ("0x1000-0x1008", "0x1000-0x100C"):
            result, out, err = run_main(data, target)
            self.assertEqual((result, err), (0, ""))
            self.assertIn("00001004: nop", out)
        self.assert_error(data, "0x1000-0x100A", contains="aligned")
        for name in ("valid-symbol", "0xname-with-hyphen", "0X1000-0X1004"):
            result, out, err = run_main(data, name)
            self.assertEqual((result, err), (0, ""))
            self.assertTrue(out.startswith(name + " @"))
        for target in (
            "0x1000-0x1008-0x100c", "0x1000-0X1008", "0x1000-0x1008junk",
            "0x1000-0x", "0x+1000-0x1008", "0x1_000-0x1008",
            "0x1000-0x1008 ", "0X1000-0x1008",
        ):
            with self.subTest(target=target):
                self.assert_error(data, target, contains="symbol not found")

    def test_range_order_alignment_and_complete_section_bounds(self):
        data = make_elf(words(0, 0))
        for target in (
            "0x1000-0x1000", "0x1004-0x1000", "0x1001-0x1004",
            "0x1000-0x1003", "0x1000-0x100c", "0x0ffc-0x1004",
            "0x1008-0x100c", "0xfffffffc-0x100000004",
        ):
            with self.subTest(target=target):
                self.assert_error(data, target)
        self.assert_error(data, "0x1000-0x100c", "--instructions", "1",
                          contains="outside section")
        result, out, err = run_main(data, "0x1004-0x1008")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("00001004: nop", out)

    def test_cannot_cross_adjacent_sections(self):
        data = make_elf(words(0), extra_sections=(
            {"name": ".next", "address": 0x1004, "data": words(0)},
        ))
        self.assert_error(data, "0x1000-0x1008", contains="outside section")
        result, out, err = run_main(data, "0x1004-0x1008")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("00001004: nop", out)

    def test_nobits_is_rejected_for_both_ranges_and_symbols(self):
        data = make_elf(
            words(0), symbols=(("in_bss", 0x2000, 4, 5, 0x12),),
            extra_sections=({"name": ".bss", "address": 0x2000, "type": 8, "size": 8},),
        )
        self.assert_error(data, "0x2000-0x2004", contains="not file-backed")
        self.assert_error(data, "in_bss", contains="not file-backed")

    def test_allocated_nobits_cannot_fall_back_to_metadata_at_zero(self):
        data = make_elf(
            words(0), symbols=(("in_bss", 0, 4, 5, 0x12),),
            extra_sections=(
                {"name": ".bss", "address": 0, "flags": 2, "type": 8, "size": 8},
            ),
        )
        self.assert_error(data, "0x0-0x4", contains="not file-backed")
        self.assert_error(data, "in_bss", contains="not file-backed")

    def test_truncated_and_malformed_elf_sections(self):
        good = make_elf(words(0, 0), symbols=(("fn", 0x1000, 8, 1, 0x12),))
        self.assert_error(good[:20], "fn", contains="not an ELF")
        self.assert_error(good[:-1], "fn", contains="section header")
        self.assert_error(change_section(good, 1, offset=len(good) - 2), "0x1000-0x1004",
                          contains="extends past")
        self.assert_error(change_section(good, 1, offset=0xFFFFFFFC), "0x1000-0x1004",
                          contains="extends past")
        self.assert_error(change_section(good, 1, size=len(good) + 4), "fn",
                          contains="extends past")
        self.assert_error(change_section(good, 4, link=99), "fn", contains="string table link")
        overflow = make_elf(words(0, 0), address=0xFFFFFFFC)
        self.assert_error(overflow, "0xfffffffc-0x100000000", contains="32-bit")

    def test_symbol_sizes_alignment_zero_size_and_section_membership(self):
        data = make_elf(
            words(0, 0),
            symbols=(
                ("six_bytes", 0x1000, 6, 1, 0x12),
                ("unaligned", 0x1001, 4, 1, 0x12),
                ("too_large", 0x1000, 12, 1, 0x12),
                ("zero_size", 0x1000, 0, 1, 0x12),
                ("at_end", 0x1008, 0, 1, 0x12),
                ("wrong_section", 0x1000, 4, 5, 0x12),
            ),
            extra_sections=({"name": ".other", "address": 0x2000, "data": words(0)},),
        )
        for name in ("six_bytes", "unaligned", "too_large", "at_end", "wrong_section"):
            with self.subTest(name=name):
                self.assert_error(data, name, "--instructions", "1")
        self.assert_error(data, "zero_size", "--instructions", "3", contains="outside section")
        result, out, err = run_main(data, "zero_size", "--instructions", "2")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("zero_size @ 0x00001000, 8 bytes", out)
        self.assertIn("00001004: nop", out)

    def test_symbol_aliases_select_a_suitable_defined_definition(self):
        symbols = (
            ("alias", 0, 0xFFFF, 0, 0x12),
            ("alias", 0x1000, 0xFFFF, 0xFFF1, 0x12),
            ("alias", 0x2000, 8, 5, 0x12),
            ("alias", 0x1004, 8, 1, 0x12),
            ("alias", 0x1000, 8, 1, 0x10),
            ("alias", 0x1004, 4, 1, 0x12),
            ("undefined_only", 0, 4, 0, 0x12),
        )
        data = make_elf(
            words(0, 0), symbols=symbols,
            extra_sections=({"name": ".bss", "address": 0x2000, "type": 8, "size": 8},),
        )
        result, out, err = run_main(data, "alias")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("alias @ 0x00001004, 4 bytes", out)
        self.assert_error(data, "undefined_only", contains="no defined")

    def test_executable_alias_wins_over_a_data_definition(self):
        data = make_elf(
            words(0), symbols=(
                ("alias", 0x2000, 8, 5, 0x12),
                ("alias", 0x1000, 4, 1, 0x10),
            ),
            extra_sections=(
                {"name": ".data", "address": 0x2000, "flags": 2, "data": words(0, 0)},
            ),
        )
        result, out, err = run_main(data, "alias")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("alias @ 0x00001000, 4 bytes", out)

    def test_ranges_work_without_a_symbol_table(self):
        data = change_section(make_elf(words(0)), 4, type=0)
        result, out, err = run_main(data, "0x1000-0x1004")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("00001000: nop", out)
        self.assert_error(data, "missing", contains="symbol not found")

    def test_jump_and_jal_use_pc_plus_four_at_region_boundary(self):
        target = 0x10000008
        symbols = (
            ("undefined", target, 4, 0, 0x12),
            ("label", target, 4, 5, 0x10),
            ("function", target, 4, 5, 0x12),
        )
        for opcode, name in ((2, "j"), (3, "jal")):
            with self.subTest(name=name):
                data = make_elf(
                    words((opcode << 26) | 2), address=0x0FFFFFFC, symbols=symbols,
                    extra_sections=({"name": ".target", "address": target, "data": words(0)},),
                )
                result, out, err = run_main(data, "0x0ffffffc-0x10000000")
                self.assertEqual((result, err), (0, ""))
                self.assertIn(f"{name:<10} 0x10000008  <function>", out)
                self.assertNotIn("<undefined>", out)
                self.assertNotIn("<label>", out)

    def test_undefined_target_is_not_annotated(self):
        data = make_elf(
            words(2 << 26), address=0x1000,
            symbols=(("undefined", 0, 4, 0, 0x12),),
        )
        result, out, err = run_main(data, "0x1000-0x1004")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("j          0x0", out)
        self.assertNotIn("<undefined>", out)

    def test_jump_wraps_at_end_of_32_bit_address_space(self):
        for opcode, name in ((2, "j"), (3, "jal")):
            with self.subTest(name=name):
                data = make_elf(
                    words(opcode << 26), address=0xFFFFFFFC,
                    symbols=(("wrapped", 0, 4, 5, 0x12),),
                    extra_sections=({"name": ".target", "address": 0, "data": words(0)},),
                )
                result, out, err = run_main(data, "0xfffffffc-0x100000000")
                self.assertEqual((result, err), (0, ""))
                self.assertIn(f"{name:<10} 0x0  <wrapped>", out)
                self.assertNotIn("0x100000000  <", out)

    def test_positive_instruction_limit_and_full_range_validation(self):
        data = make_elf(words(0, 0))
        result, out, err = run_main(data, "0x1000-0x1008", "--instructions", "1")
        self.assertEqual((result, err), (0, ""))
        self.assertIn("00001000: nop", out)
        self.assertNotIn("00001004:", out)
        for amount in ("0", "-1", "abc"):
            with self.subTest(amount=amount):
                with (
                    mock.patch.object(sys, "argv", ["disasm_elf.py", "x", "x", "--instructions", amount]),
                    contextlib.redirect_stderr(io.StringIO()),
                    self.assertRaises(SystemExit) as error,
                ):
                    disasm_elf.main()
                self.assertEqual(error.exception.code, 2)

    def test_missing_capstone_has_clear_error_and_help_still_works(self):
        result, out, err = run_main(b"", "anything", capstone=None)
        self.assertEqual(result, 2)
        self.assertEqual(out, "")
        self.assertIn("optional 'capstone' package", err)
        stdout = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["disasm_elf.py", "--help"]),
            mock.patch.dict(sys.modules, {"capstone": None}),
            contextlib.redirect_stdout(stdout),
            self.assertRaises(SystemExit) as error,
        ):
            disasm_elf.main()
        self.assertEqual(error.exception.code, 0)
        self.assertIn("0xLO-0xHI", stdout.getvalue())

    def test_capstone_setup_failure_is_reported(self):
        broken = types.ModuleType("capstone")
        for name in ("CS_ARCH_MIPS", "CS_MODE_LITTLE_ENDIAN", "CS_MODE_MIPS64", "CsError"):
            setattr(broken, name, getattr(fake_capstone, name))

        def fail_setup(*_args):
            raise FakeCsError("synthetic setup error")

        broken.Cs = fail_setup
        result, out, err = run_main(make_elf(words(0)), "0x1000-0x1004", capstone=broken)
        self.assertEqual((result, out), (2, ""))
        self.assertIn("synthetic setup error", err)


if __name__ == "__main__":
    unittest.main()
