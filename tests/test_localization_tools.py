"""Synthetic, self-contained tests for the localization tools."""

from __future__ import annotations

import contextlib
import csv
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import unittest
import uuid
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("loc_csv", ROOT / "tools" / "loc_csv.py")
loc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loc)


def csv_text(columns, rows):
    stream = io.StringIO(newline="")
    writer = csv.DictWriter(stream, fieldnames=columns)
    writer.writeheader()
    writer.writerows(rows)
    return "\ufeff" + stream.getvalue()


class MemoryFiles:
    """Keep all CSV and external JSON fixtures synthetic and in memory."""

    def __init__(self, files=None):
        self.files = dict(files or {})

    def __enter__(self):
        self.stack = contextlib.ExitStack()
        files = self.files

        def open_file(path, mode="r", encoding=None, errors=None, newline=None):
            name = str(path)
            if "w" in mode:
                class Writer(io.StringIO):
                    def close(self):
                        if not self.closed:
                            prefix = "\ufeff" if encoding == "utf-8-sig" else ""
                            files[name] = prefix + self.getvalue()
                        super().close()

                return Writer(newline=newline)
            if name not in files:
                raise FileNotFoundError(2, "No such file", name)
            text = files[name]
            if encoding == "utf-8-sig" and text.startswith("\ufeff"):
                text = text[1:]
            return io.StringIO(text, newline=newline)

        self.stack.enter_context(mock.patch.object(Path, "open", new=open_file))
        self.stack.enter_context(mock.patch.object(Path, "mkdir", new=lambda *args, **kwargs: None))
        return self

    def __exit__(self, *exc):
        return self.stack.__exit__(*exc)

    def invoke(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with self, contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                status = loc.main(list(args))
            except SystemExit as exc:
                status = exc.code if isinstance(exc.code, int) else 1
                if isinstance(exc.code, str):
                    print(exc.code, file=sys.stderr)
        return status, stdout.getvalue(), stderr.getvalue()

    def rows(self, name):
        text = self.files[name]
        if text.startswith("\ufeff"):
            text = text[1:]
        return list(csv.DictReader(io.StringIO(text, newline="")))

    def columns(self, name):
        text = self.files[name].removeprefix("\ufeff")
        return next(csv.reader(io.StringIO(text, newline="")))


class GeneratorTests(unittest.TestCase):
    def test_deterministic_stdout_output_option_and_checked_in_table(self):
        script = ROOT / "tools" / "gen_sjis_table.py"
        results = []
        for seed, encoding in (("1", "cp1252"), ("2", "utf-8")):
            env = dict(os.environ, PYTHONHASHSEED=seed, PYTHONIOENCODING=encoding)
            results.append(subprocess.check_output([sys.executable, "-B", str(script)], env=env))
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0], (ROOT / "port" / "src" / "sjis_table.odin").read_bytes())
        self.assertNotIn(b"\r", results[0])

        output = Path(f".synthetic-sjis-{uuid.uuid4().hex}.odin")
        try:
            subprocess.run([sys.executable, "-B", str(script), "--output", str(output)], check=True)
            self.assertEqual(output.read_bytes(), results[0])
        finally:
            output.unlink(missing_ok=True)

    def test_tables_match_all_cp932_double_byte_mappings(self):
        text = (ROOT / "port" / "src" / "sjis_table.odin").read_text(encoding="ascii")

        def array(name):
            match = re.search(rf"{name} := \[(\d+)\]u32\{{(.*?)\}}", text, re.S)
            self.assertIsNotNone(match, name)
            values = [int(value, 16) for value in re.findall(r"0x[0-9a-f]{8}", match.group(2))]
            self.assertEqual(len(values), int(match.group(1)))
            self.assertEqual(values, sorted(values))
            return values

        decode = array("SJIS_DECODE")
        encode = array("SJIS_ENCODE")
        expected_decode = []
        for lead in (*range(0x81, 0xA0), *range(0xE0, 0xFD)):
            for trail in range(256):
                try:
                    value = bytes((lead, trail)).decode("cp932")
                except UnicodeDecodeError:
                    continue
                self.assertEqual(len(value), 1)
                expected_decode.append(((lead << 8 | trail) << 16) | ord(value))
        expected_encode = []
        for codepoint in range(0x10000):
            try:
                raw = chr(codepoint).encode("cp932")
            except UnicodeEncodeError:
                continue
            if len(raw) == 2:
                expected_encode.append((codepoint << 16) | int.from_bytes(raw, "big"))
        self.assertEqual(decode, expected_decode)
        self.assertEqual(encode, expected_encode)
        for codepoint in (0x00A2, 0x00A3, 0x00AC, 0x2016, 0x2212, 0x301C):
            self.assertIn((codepoint << 16) | int.from_bytes(chr(codepoint).encode("cp932"), "big"), encode)

    def test_invalid_generator_output_is_a_reported_failure(self):
        target = Path(f".synthetic-missing-{uuid.uuid4().hex}") / "table.odin"
        result = subprocess.run(
            [sys.executable, "-B", str(ROOT / "tools" / "gen_sjis_table.py"), "--output", str(target)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("table.odin", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


class EncodingTests(unittest.TestCase):
    def test_cp932_aliases_single_bytes_and_unmappable_fallback(self):
        text = "\x80\uf8f0\uf8f1\uf8f2\uf8f3\u301c\uff5e\u00a2\u2212"
        encoded, bad = loc.sjis_encode(text, False)
        self.assertEqual(encoded, text.encode("cp932"))
        self.assertEqual(bad, [])
        self.assertEqual(loc.sjis_encode("a😀🛸", False), (b"a??", ["😀", "🛸"]))

        characters = []
        for codepoint in range(0x10000):
            try:
                chr(codepoint).encode("cp932")
            except UnicodeEncodeError:
                continue
            characters.append(chr(codepoint))
        all_cp932 = "".join(characters)
        self.assertEqual(loc.sjis_encode(all_cp932, False), (all_cp932.encode("cp932"), []))

    def test_punctuation_and_cell_normalization_precede_encoding(self):
        text = "‘’“”–—…\u00a0"
        self.assertEqual(loc.sjis_encode(text), (b"''\"\"---... ", []))
        self.assertEqual(loc.sjis_len("…"), (3, []))
        self.assertEqual(loc.sjis_len("…", False), (2, []))
        self.assertEqual(loc.sjis_encode(text, False), (text.encode("cp932", "replace"), ["–", "—", "\u00a0"]))
        self.assertEqual(loc.sjis_encode("A\r\nB\\nC"), (b"A\nB\nC", []))

    def test_printf_scanning_matches_runtime_bytes(self):
        self.assertEqual(loc.conversions("%*d %02s %% %x"), ["d", "s", "x"])
        character_with_ascii_trail = bytes.fromhex("8161").decode("cp932")
        self.assertEqual(loc.conversions("%" + character_with_ascii_trail + "d", False), ["a"])
        self.assertEqual(loc.conversions("%\\n", original=True), ["n"])
        self.assertEqual(loc.conversions("%\\n"), [])

    def test_cp932_invalid_leads_do_not_consume_the_next_byte(self):
        for lead in (*range(0x81, 0xA0), *range(0xE0, 0xFD)):
            for trail in range(256):
                pair = bytes((lead, trail))
                try:
                    expected = pair.decode("cp932")
                except UnicodeDecodeError:
                    expected = "\ufffd" + bytes((trail,)).decode("cp932", "replace")
                self.assertEqual(pair.decode("cp932", "replace"), expected)


class CsvToolTests(unittest.TestCase):
    def setUp(self):
        self.base_columns = loc.INFO_COLUMNS + ["ja", "notes"]
        self.base = [
            {"key": "t00.0000", "offset": "00010c", "speaker": "123456", "ja": "original-0"},
            {"key": "t00.0001", "offset": "00010c", "speaker": "123456", "shared": "t00.0000", "ja": "original-1"},
            {"key": "t00.0002", "offset": "000120", "speaker": "654321", "ja": "original-2"},
            {"key": "t06.0000", "offset": "000204", "ja": "original-pool"},
            {"key": "exe.00100080", "max_bytes": "16", "ja": "status %d"},
        ]
        self.baseline = {
            "str-000100-0": {"en": "123456alpha", "note": "synthetic note"},
            "rec-000120": {"en": "record"},
            "str-000200-0": {"en": "pool"},
            "elf-000100": {"en": "result %d"},
        }
        self.machine = {
            "rec-000120": {"en": "draft"},
            "str-000200-0": {"en": ""},
        }
        self.source = str(Path("checkout") / "translation" / "english.json")
        self.machine_source = str(Path("checkout") / "translation" / "english-mtl.json")
        self.fs = MemoryFiles({
            "base.csv": csv_text(self.base_columns, self.base),
            self.source: json.dumps(self.baseline),
            self.machine_source: json.dumps(self.machine),
        })

    def test_import_baseline_full_shared_blank_fallback_and_metadata(self):
        machine_source = self.fs.files.pop(self.machine_source)
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "baseline.csv", "--baseline-only")
        self.assertEqual((status, error), (0, ""))
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "missing.csv")
        self.assertEqual(status, 1)
        self.assertIn("No such file", error)
        self.assertNotIn("missing.csv", self.fs.files)
        self.fs.files[self.machine_source] = machine_source
        rows = {r["key"]: r for r in self.fs.rows("baseline.csv")}
        self.assertEqual(rows["t00.0000"]["en"], "alpha")
        self.assertEqual(rows["t00.0001"]["en"], "alpha")
        self.assertEqual(rows["t00.0001"]["notes"], "synthetic note")
        self.assertEqual(rows["t00.0002"]["en"], "record")
        self.assertEqual(rows["t06.0000"]["en"], "pool")
        self.assertEqual(rows["exe.00100080"]["en"], "result %d")
        self.assertNotIn("ja", self.fs.columns("baseline.csv"))
        self.assertTrue(self.fs.files["baseline.csv"].startswith("\ufeff"))

        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "full.csv", "--with-ja")
        self.assertEqual((status, error), (0, ""))
        rows = {r["key"]: r for r in self.fs.rows("full.csv")}
        self.assertEqual(rows["t00.0002"]["en"], "draft")
        self.assertNotIn("t06.0000", rows)
        self.assertEqual(rows["t00.0000"]["ja"], "original-0")

    def test_explicit_shared_translation_and_unmatched_source(self):
        baseline = dict(self.baseline)
        baseline["str-000100-1"] = {"en": "123456explicit"}
        baseline["rec-00ffff"] = {"en": "unmatched"}
        self.fs.files[self.source] = json.dumps(baseline)
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "out.csv", "--baseline-only")
        self.assertEqual(status, 1)
        self.assertIn("rec-00ffff", error)
        rows = {r["key"]: r for r in self.fs.rows("out.csv")}
        self.assertEqual(rows["t00.0000"]["en"], "alpha")
        self.assertEqual(rows["t00.0001"]["en"], "explicit")

    def test_import_alias_first_propagates_without_overwriting_explicit_text(self):
        self.base.append({"key": "t06.0001", "offset": "00010c", "shared": "t00.0000", "ja": "original-alias"})
        self.fs.files["base.csv"] = csv_text(self.base_columns, self.base)
        source = {
            "str-000100-1": {"en": "123456alias"},
            "str-000100-0": {"en": "123456root"},
        }
        self.fs.files[self.source] = json.dumps(source)
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "aliases.csv", "--baseline-only")
        self.assertEqual((status, error), (0, ""))
        rows = {r["key"]: r for r in self.fs.rows("aliases.csv")}
        self.assertEqual(rows["t00.0000"]["en"], "root")
        self.assertEqual(rows["t00.0001"]["en"], "alias")
        self.assertEqual(rows["t06.0001"]["en"], "root")

        self.fs.files[self.source] = json.dumps({"str-000100-1": source["str-000100-1"]})
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "aliases.csv", "--baseline-only")
        self.assertEqual((status, error), (0, ""))
        rows = {r["key"]: r for r in self.fs.rows("aliases.csv")}
        self.assertEqual(rows["t00.0000"]["en"], "alias")
        self.assertEqual(rows["t00.0001"]["en"], "alias")
        self.assertEqual(rows["t06.0001"]["en"], "alias")

    def test_import_rejects_malformed_sources_offsets_and_language(self):
        cases = [
            ('{"rec-120":{"en":"x"},"rec-120":{"en":"y"}}', "duplicate JSON key"),
            ('{"rec-120":{"en":3}}', "must be a string"),
            ('{"str-nope":{"en":"x"}}', "malformed external identifier"),
            ('{"rec-nope":{"en":"x"}}', "malformed external identifier"),
            ('{"elf-nope":{"en":"x"}}', "malformed external identifier"),
            ('[1, 2]', "expected a JSON object"),
        ]
        for source, expected in cases:
            with self.subTest(source=source):
                self.fs.files[self.source] = source
                status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "invalid.csv", "--baseline-only")
                self.assertEqual(status, 1)
                self.assertIn(expected, error)
                self.assertNotIn("invalid.csv", self.fs.files)
        self.fs.files[self.source] = json.dumps(self.baseline)
        self.base[0]["offset"] = "not-hex"
        self.fs.files["base.csv"] = csv_text(self.base_columns, self.base)
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "invalid.csv", "--baseline-only")
        self.assertEqual(status, 1)
        self.assertIn("invalid hexadecimal offset", error)
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "invalid.csv", "--lang", "notes")
        self.assertEqual(status, 1)
        self.assertIn("invalid language column", error)

    def test_import_rejects_unknown_and_cyclic_shared_keys(self):
        self.base[1]["shared"] = "t00.0009"
        self.fs.files["base.csv"] = csv_text(self.base_columns, self.base)
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "invalid.csv", "--baseline-only")
        self.assertEqual(status, 1)
        self.assertIn("unknown shared key", error)
        self.base[0]["shared"] = "t00.0001"
        self.base[1]["shared"] = "t00.0000"
        self.fs.files["base.csv"] = csv_text(self.base_columns, self.base)
        status, _, error = self.fs.invoke("import-external", "base.csv", "checkout", "invalid.csv", "--baseline-only")
        self.assertEqual(status, 1)
        self.assertIn("cyclic shared keys", error)

    def test_merge_precedence_case_insensitive_languages_and_strip(self):
        self.fs.files["one.csv"] = csv_text(
            ["key", "en", "fr", "notes"],
            [{"key": "t00.0000", "en": "first", "notes": "kept"},
             {"key": "t00.0001", "fr": "deux"}],
        )
        self.fs.files["two.csv"] = csv_text(
            ["key", "EN"],
            [{"key": "t00.0000", "EN": ""}, {"key": "t00.0001", "EN": "second"}],
        )
        status, _, error = self.fs.invoke("merge", "base.csv", "one.csv", "two.csv", "-o", "merged.csv")
        self.assertEqual((status, error), (0, ""))
        self.assertEqual(self.fs.columns("merged.csv").count("en"), 1)
        self.assertNotIn("EN", self.fs.columns("merged.csv"))
        rows = {r["key"]: r for r in self.fs.rows("merged.csv")}
        self.assertEqual(rows["t00.0000"]["en"], "first")
        self.assertEqual(rows["t00.0000"]["notes"], "kept")
        self.assertEqual(rows["t00.0001"]["en"], "second")
        self.assertEqual(rows["t00.0001"]["fr"], "deux")
        self.assertEqual(rows["t00.0002"]["ja"], "original-2")

        status, _, error = self.fs.invoke("strip", "merged.csv", "-o", "stripped.csv")
        self.assertEqual((status, error), (0, ""))
        self.assertEqual([r["key"] for r in self.fs.rows("stripped.csv")], ["t00.0000", "t00.0001"])
        for removed in ("ja", "offset", "shared", "context"):
            self.assertNotIn(removed, self.fs.columns("stripped.csv"))
        self.assertTrue(self.fs.files["stripped.csv"].startswith("\ufeff"))
        self.assertNotIn("original-", self.fs.files["stripped.csv"])

    def test_merge_unknown_key_and_strip_without_language_fail(self):
        self.fs.files["extra.csv"] = csv_text(["key", "en"], [{"key": "t09.0000", "en": "extra"}])
        status, _, error = self.fs.invoke("merge", "base.csv", "extra.csv", "-o", "out.csv")
        self.assertEqual(status, 1)
        self.assertIn("not in the base table", error)
        self.assertNotIn("out.csv", self.fs.files)
        self.fs.files["empty.csv"] = csv_text(["key", "ja"], [{"key": "t00.0000", "ja": "original"}])
        status, _, error = self.fs.invoke("strip", "empty.csv", "-o", "out.csv")
        self.assertEqual(status, 1)
        self.assertIn("no language columns", error)

    def test_csv_malformed_rows_and_semantic_duplicates_fail(self):
        cases = [
            ("en\nx\n", "no 'key' column"),
            ("key,en,EN\nt00.0000,a,b\n", "duplicate column"),
            ("key,\nt00.0000,a\n", "empty column name"),
            ("key,en\nt00.0000,a,extra\n", "expected 2 fields"),
            ("key,en\nt00.0000\n", "expected 2 fields"),
            ('key,en\nt00.0000,"unfinished\n', "invalid CSV"),
            ("key,en\n,b\n", "unusable key"),
            ("key,en\nt11.0000,b\n", "unusable key"),
            ("key,en\nexe.100000000,b\n", "unusable key"),
            ("key,en\nt1.2,a\nt01.0002,b\n", "duplicate key"),
            ("key,en\nexe.a,a\nexe.0000000A,b\n", "duplicate key"),
        ]
        for text, expected in cases:
            with self.subTest(expected=expected, text=text):
                self.fs.files["bad.csv"] = text
                status, _, error = self.fs.invoke("check", "bad.csv")
                self.assertEqual(status, 1)
                self.assertIn(expected, error)
                self.assertNotIn("Traceback", error)

    def test_check_punctuation_budget_and_authoritative_base_limit(self):
        base = [{"key": "exe.00000001", "max_bytes": "2", "ja": "placeholder"}]
        self.fs.files["limits.csv"] = csv_text(["key", "max_bytes", "ja"], base)
        self.fs.files["mod.csv"] = csv_text(
            ["key", "max_bytes", "en"], [{"key": "exe.00000001", "max_bytes": "100", "en": "…"}]
        )
        status, out, _ = self.fs.invoke("check", "mod.csv", "--base", "limits.csv")
        self.assertEqual(status, 1)
        self.assertIn("3 bytes exceeds max_bytes 2", out)
        status, _, error = self.fs.invoke("check", "mod.csv", "--base", "limits.csv", "--no-ascii-punctuation")
        self.assertEqual((status, error), (0, ""))

        base[0]["max_bytes"] = "3"
        self.fs.files["limits.csv"] = csv_text(["key", "max_bytes", "ja"], base)
        status, _, _ = self.fs.invoke("check", "mod.csv", "--base", "limits.csv")
        self.assertEqual(status, 0)
        self.fs.files["mod.csv"] = csv_text(
            ["key", "max_bytes", "en"], [{"key": "exe.00000001", "max_bytes": "2", "en": "…"}]
        )
        status, out, _ = self.fs.invoke("check", "mod.csv", "--base", "limits.csv")
        self.assertEqual(status, 1)
        self.assertIn("max_bytes 2", out)

    def test_check_width_newlines_and_nonnegative_argument(self):
        self.fs.files["width.csv"] = csv_text(["key", "en"], [{"key": "t00.0000", "en": "x\\n…"}])
        status, out, _ = self.fs.invoke("check", "width.csv", "--width", "2")
        self.assertEqual(status, 1)
        self.assertIn("line of 3 characters", out)
        status, _, error = self.fs.invoke("check", "width.csv", "--width", "2", "--no-ascii-punctuation")
        self.assertEqual((status, error), (0, ""))
        self.fs.files["width.csv"] = csv_text(["key", "en"], [{"key": "t00.0000", "en": "ab\r\nc"}])
        self.assertEqual(self.fs.invoke("check", "width.csv", "--width", "2")[0], 0)
        self.fs.files["width.csv"] = csv_text(["key", "en"], [{"key": "t00.0000", "en": "\u3042"}])
        self.assertEqual(self.fs.invoke("check", "width.csv", "--width", "1")[0], 0)
        status, _, error = self.fs.invoke("check", "width.csv", "--width", "-1")
        self.assertEqual(status, 2)
        self.assertIn("nonnegative integer", error)

    def test_check_bad_limits_nul_unmappable_unknown_and_printf(self):
        rows = [
            {"key": "t00.0000", "max_bytes": "-1", "en": "x"},
            {"key": "t00.0001", "max_bytes": "0", "en": "x"},
            {"key": "t00.0002", "en": "😀\x00"},
            {"key": "t00.0003", "max_bytes": "1", "en": "\u3042"},
        ]
        self.fs.files["unsafe.csv"] = csv_text(["key", "max_bytes", "en"], rows)
        status, out, _ = self.fs.invoke("check", "unsafe.csv")
        self.assertEqual(status, 1)
        for message in ("invalid max_bytes", "exceeds max_bytes 0", "2 bytes exceeds max_bytes 1", "U+1F600", "U+0000"):
            self.assertIn(message, out)

        self.fs.files["empty-base.csv"] = csv_text(["key", "ja"], [])
        status, out, _ = self.fs.invoke("check", "unsafe.csv", "--base", "empty-base.csv")
        self.assertEqual(status, 1)
        self.assertIn("key is not in the base table", out)

        self.fs.files["exe-base.csv"] = csv_text(
            ["key", "ja", "max_bytes"], [{"key": "exe.00000001", "ja": "value %d", "max_bytes": "20"}]
        )
        self.fs.files["exe-mod.csv"] = csv_text(
            ["key", "en"], [{"key": "exe.00000001", "en": "value %s"}]
        )
        status, out, _ = self.fs.invoke("check", "exe-mod.csv", "--base", "exe-base.csv")
        self.assertEqual(status, 1)
        self.assertIn("printf conversions", out)

        self.fs.files["exe-base.csv"] = csv_text(
            ["key", "ja"], [{"key": "exe.00000001", "ja": "%\\n"}]
        )
        self.fs.files["exe-mod.csv"] = csv_text(["key", "en"], [{"key": "exe.00000001", "en": "%"}])
        status, out, _ = self.fs.invoke("check", "exe-mod.csv", "--base", "exe-base.csv")
        self.assertEqual(status, 1)
        self.assertIn("printf conversions", out)


class CliTests(unittest.TestCase):
    def test_real_bom_merge_strip_and_check(self):
        prefix = f".synthetic-localization-{uuid.uuid4().hex}"
        base, mod, merged, stripped = (Path(f"{prefix}-{suffix}.csv") for suffix in ("base", "mod", "merged", "stripped"))
        script = ROOT / "tools" / "loc_csv.py"
        env = dict(os.environ, PYTHONIOENCODING="utf-8")

        def run(*args):
            return subprocess.run([sys.executable, "-B", str(script), *map(str, args)],
                                  capture_output=True, text=True, env=env, timeout=30)

        try:
            base.write_text(csv_text(["key", "max_bytes", "ja"], [
                {"key": "t00.0000", "ja": "synthetic original"},
                {"key": "exe.00000001", "max_bytes": "2", "ja": "original"},
            ]), encoding="utf-8", newline="")
            mod.write_text(csv_text(["key", "en"], [
                {"key": "t00.0000", "en": "x"},
                {"key": "exe.00000001", "en": "…"},
            ]), encoding="utf-8", newline="")
            result = run("merge", base, mod, "-o", merged)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = run("strip", merged, "-o", stripped)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(stripped.read_bytes().startswith(b"\xef\xbb\xbf"))
            self.assertNotIn("synthetic original", stripped.read_text(encoding="utf-8-sig"))

            result = run("check", stripped, "--base", base, "--width", "2")
            self.assertEqual(result.returncode, 1)
            self.assertIn("3 bytes exceeds max_bytes 2", result.stdout)
            self.assertIn("line of 3 characters", result.stdout)
            result = run("check", stripped, "--base", base, "--width", "2", "--no-ascii-punctuation")
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        finally:
            for path in (base, mod, merged, stripped):
                path.unlink(missing_ok=True)


ODIN_HARNESS = r"""
equal_bytes :: proc(a, b: []u8) -> bool {
    if len(a) != len(b) {return false}
    for value, i in a {
        if value != b[i] {return false}
    }
    return true
}

expect_encode :: proc(text: string, ascii: bool, expected: []u8, expected_missing: int) {
    actual, missing := sjis_encode(text, ascii)
    assert(missing == expected_missing && equal_bytes(actual, expected), "encoding mismatch")
}

main :: proc() {
    input := strings.builder_make(context.allocator)
    expected := make([dynamic]u8)
    for n in 0 ..= 0x80 {
        strings.write_rune(&input, rune(n))
        append(&expected, u8(n))
    }
    strings.write_rune(&input, rune(0xf8f0))
    append(&expected, 0xa0)
    for n in 0xa1 ..= 0xdf {
        strings.write_rune(&input, rune(0xff61 + n - 0xa1))
        append(&expected, u8(n))
    }
    for n in 0xfd ..= 0xff {
        strings.write_rune(&input, rune(0xf8f1 + n - 0xfd))
        append(&expected, u8(n))
    }
    for entry in SJIS_ENCODE {
        strings.write_rune(&input, rune(entry >> 16))
        append(&expected, u8(entry >> 8), u8(entry))
    }
    encoded, missing := sjis_encode(strings.to_string(input), false)
    assert(missing == 0 && equal_bytes(encoded, expected[:]), "complete CP932 encoding")

    raw := make([dynamic]u8)
    decoded := strings.builder_make(context.allocator)
    for entry in SJIS_DECODE {
        append(&raw, u8(entry >> 24), u8(entry >> 16))
        strings.write_rune(&decoded, rune(entry & 0xffff))
    }
    assert(sjis_decode(raw[:]) == strings.to_string(decoded), "complete CP932 decoding")

    for lead in 0x81 ..= 0xfc {
        if !sjis_lead(u8(lead)) {continue}
        for trail in 0 ..= 0xff {
            pair := [2]u8{u8(lead), u8(trail)}
            want := strings.builder_make(context.allocator)
            code := u32(lead) << 8 | u32(trail)
            k, found := slice.binary_search_by(SJIS_DECODE[:], code, proc(e, key: u32) -> slice.Ordering {
                return slice.cmp(e >> 16, key)
            })
            if found {
                strings.write_rune(&want, rune(SJIS_DECODE[k] & 0xffff))
            } else {
                strings.write_rune(&want, utf8.RUNE_ERROR)
                switch {
                case trail <= 0x80:
                    strings.write_rune(&want, rune(trail))
                case trail == 0xa0:
                    strings.write_rune(&want, rune(0xf8f0))
                case trail >= 0xa1 && trail <= 0xdf:
                    strings.write_rune(&want, rune(0xff61 + trail - 0xa1))
                case trail >= 0xfd:
                    strings.write_rune(&want, rune(0xf8f1 + trail - 0xfd))
                case:
                    strings.write_rune(&want, utf8.RUNE_ERROR)
                }
            }
            assert(sjis_decode(pair[:]) == strings.to_string(want), "invalid CP932 lead handling")
        }
    }

    punctuation := strings.builder_make(context.allocator)
    points := [?]rune{0x2018, 0x2019, 0x201c, 0x201d, 0x2013, 0x2014, 0x2026, 0x00a0}
    for r in points {
        strings.write_rune(&punctuation, r)
    }
    text := strings.to_string(punctuation)
    expect_encode(text, true, []u8{39, 39, 34, 34, 45, 45, 45, 46, 46, 46, 32}, 0)
    expect_encode(text, false, []u8{0x81, 0x65, 0x81, 0x66, 0x81, 0x67, 0x81, 0x68,
                                   '?', '?', 0x81, 0x63, '?'}, 3)
    emoji := strings.builder_make(context.allocator)
    strings.write_rune(&emoji, rune(0x1f600))
    expect_encode(strings.to_string(emoji), true, []u8{'?'}, 1)
    assert(!sjis_has_japanese([]u8{0x41, 0x42}), "ASCII is not Japanese")
    assert(sjis_has_japanese([]u8{0x82, 0xa0}), "hiragana is Japanese")
}
"""


class OdinRuntimeTests(unittest.TestCase):
    def test_isolated_odin_codec(self):
        compiler = os.environ.get("ODIN_EXE") or shutil.which("odin")
        if not compiler:
            tool_dir = ROOT / ".tools"
            executable = "odin.exe" if os.name == "nt" else "odin"
            candidates = sorted(child / "dist" / executable for child in tool_dir.iterdir()
                                if (child / "dist" / executable).is_file()) if tool_dir.is_dir() else []
            compiler = str(candidates[0]) if candidates else None
        if not compiler:
            self.skipTest("Odin compiler not installed")

        source = (ROOT / "port" / "src" / "sjis.odin").read_text(encoding="utf-8")
        table = (ROOT / "port" / "src" / "sjis_table.odin").read_text(encoding="utf-8")
        _, separator, table = table.partition("package main\n")
        self.assertTrue(separator)
        name = f".synthetic-sjis-{uuid.uuid4().hex}"
        scratch = Path(name + ".odin")
        binary = Path(name + (".exe" if os.name == "nt" else ""))
        env = dict(os.environ, TMP=str(Path.cwd()), TEMP=str(Path.cwd()))
        try:
            scratch.write_text(source + "\n" + table + "\n" + ODIN_HARNESS, encoding="utf-8", newline="\n")
            for command in (
                [compiler, "check", str(scratch), "-file"],
                [compiler, "run", str(scratch), "-file", f"-out:{binary}"],
            ):
                result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=180)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        finally:
            for path in (scratch, binary, Path(name + ".pdb"), Path(name + ".obj"), Path(name + ".ilk")):
                path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
