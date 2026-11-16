#!/usr/bin/env python3
"""Work with the port's localization tables.

The base table comes from the game itself:

    port\\macross-recomp.exe --export-strings localization\\_base\\strings.csv

It has one row per string the game can show, keyed `tNN.IIII` (table, index)
or `exe.AAAAAAAA` (a message in the executable), with the Japanese text in
the `ja` column. A localization mod's strings.csv has the same `key` column
and one column per language; the runtime reads only `key` and the selected
language, so `ja` and the other informational columns are optional.

Subcommands:

  import-external BASE CHECKOUT OUT   convert the external fan translation's
                                      JSON (keyed by BOOTDAT offsets) to a CSV
  merge BASE MOD... -o OUT            one workbook: ja plus every language
  strip IN -o OUT                     drop ja (and other disc text) for sharing
  check MOD [--base BASE]             report problems before playing

All files are UTF-8; written files carry a BOM so spreadsheet programs
detect the encoding. Malformed or duplicate columns and keys are errors.
The checker uses ASCII punctuation by default, like the runtime; use
--no-ascii-punctuation for a mod that disables it. Byte and enabled width
limits are checked as errors, not warnings.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

INFO_COLUMNS = ["key", "offset", "speaker", "caption", "voice", "shared", "max_bytes"]
RESERVED = set(INFO_COLUMNS) | {"notes", "context"}
EXE_LOAD_DELTA = 0x100000 - 0x80  # ELF file offset -> virtual address
TABLE_COUNT = 11  # Matches STR_TABLES in the runtime.

ASCII_PUNCT = str.maketrans({
    "‘": "'", "’": "'", "“": '"', "”": '"',
    "–": "-", "—": "--", "…": "...", "\u00a0": " ",
})


def canonical_key(key: str) -> str:
    """Parse the runtime's key forms and return their unambiguous spelling."""
    key = key.strip()
    table_match = re.fullmatch(r"t([0-9]+)\.([0-9]+)", key)
    exe_match = re.fullmatch(r"exe\.([0-9a-fA-F]+)", key)
    try:
        if table_match:
            table, index = map(int, table_match.groups())
            if table < TABLE_COUNT and index <= 0xFFFF:
                return f"t{table:02d}.{index:04d}"
        elif exe_match:
            address = int(exe_match.group(1), 16)
            if address <= 0xFFFFFFFF:
                return f"exe.{address:08x}"
    except ValueError:
        pass
    raise ValueError(f"unusable key {key!r}")


def read_table(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    reader = None
    try:
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.reader(handle, strict=True)
            header = next(reader, None)
            if not header:
                raise SystemExit(f"{path}: no header row")
            columns = []
            seen_columns = set()
            for name in header:
                name = name.strip()
                folded = name.casefold()
                if not name:
                    raise SystemExit(f"{path}: empty column name")
                if folded in seen_columns:
                    raise SystemExit(f"{path}: duplicate column {name!r}")
                seen_columns.add(folded)
                columns.append(folded if folded in RESERVED or folded == "ja" else name)
            if "key" not in columns:
                raise SystemExit(f"{path}: no 'key' column")

            rows = []
            seen_keys: dict[str, int] = {}
            for fields in reader:
                line = reader.line_num
                if not fields:
                    continue
                if len(fields) != len(columns):
                    raise SystemExit(f"{path}:{line}: expected {len(columns)} fields, got {len(fields)}")
                row = dict(zip(columns, fields))
                try:
                    row["key"] = canonical_key(row["key"])
                    if "shared" in row:
                        row["shared"] = row["shared"].strip()
                        if row["shared"]:
                            row["shared"] = canonical_key(row["shared"])
                except ValueError as exc:
                    raise SystemExit(f"{path}:{line}: {exc}") from exc
                key = row["key"]
                if key in seen_keys:
                    raise SystemExit(f"{path}:{line}: duplicate key {key!r} (first at line {seen_keys[key]})")
                seen_keys[key] = line
                rows.append(row)
            return columns, rows
    except csv.Error as exc:
        raise SystemExit(f"{path}:{reader.line_num}: invalid CSV: {exc}") from exc
    except (OSError, UnicodeError) as exc:
        raise SystemExit(f"{path}: {exc}") from exc


def write_table(path: Path, columns: list[str], rows: list[dict[str, str]]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
            writer.writeheader()
            for row in rows:
                writer.writerow({c: row.get(c, "") for c in columns})
    except (OSError, UnicodeError, csv.Error) as exc:
        raise SystemExit(f"{path}: {exc}") from exc


def languages(columns: list[str]) -> list[str]:
    return [c for c in columns if c and c not in RESERVED and c != "ja"]


def table_of(key: str) -> int | None:
    return int(key[1:].partition(".")[0]) if key.startswith("t") else None


# --------------------------------------------------------------- import


def read_external_source(path: Path) -> dict[str, dict[str, str]]:
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key {key!r}")
            result[key] = value
        return result

    try:
        entries = json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=unique_object)
    except (OSError, UnicodeError, ValueError) as exc:
        raise SystemExit(f"{path}: {exc}") from exc
    if not isinstance(entries, dict):
        raise SystemExit(f"{path}: expected a JSON object")
    for uid, entry in entries.items():
        if not isinstance(entry, dict):
            raise SystemExit(f"{path}: {uid!r} must contain an object")
        for field in ("en", "note"):
            if field in entry and not isinstance(entry[field], str):
                raise SystemExit(f"{path}: {uid!r} field {field!r} must be a string")
    return entries


def cmd_import_external(args: argparse.Namespace) -> int:
    lang = args.lang.strip()
    if not lang or lang.casefold() in RESERVED | {"ja"}:
        raise SystemExit(f"invalid language column {args.lang!r}")
    base_columns, base = read_table(args.base)
    if "offset" not in base_columns:
        raise SystemExit(f"{args.base}: import requires an 'offset' column")
    checkout = args.checkout / "translation"
    sources = [checkout / "english.json"]
    if not args.baseline_only:
        sources.append(checkout / "english-mtl.json")
    entries: dict[str, tuple[dict[str, str], Path]] = {}
    for source in sources:
        entries.update((uid, (entry, source)) for uid, entry in read_external_source(source).items())

    by_record: dict[int, list[dict]] = defaultdict(list)  # record start -> rows
    tables: dict[int, list[int]] = defaultdict(list)
    for row in base:
        t = table_of(row["key"])
        if t is None:
            continue
        try:
            offset = int(row["offset"], 16)
            if not 0 <= offset <= 0xFFFFFFFF:
                raise ValueError
        except ValueError as exc:
            raise SystemExit(f"{args.base}: {row['key']}: invalid hexadecimal offset {row['offset']!r}") from exc
        tables[t].append(offset)
        by_record[offset].append(row)
    # A table's base offset: its offsets table is immediately followed by
    # the first string, so base = lowest entry offset - 4 * entry count.
    # (Record-table entries start at the record, 6 bytes before the text.)
    table_base: dict[int, int] = {}
    for t, offsets in tables.items():
        address = min(offsets) - 4 * len(offsets)
        if address < 0 or address in table_base:
            raise SystemExit(f"{args.base}: invalid or ambiguous base offset for table {t}")
        table_base[address] = t
    by_key = {row["key"]: row for row in base}
    roots: dict[str, str] = {}
    for row in base:
        key = row["key"]
        path: list[str] = []
        seen = set()
        while key not in roots:
            if key in seen:
                raise SystemExit(f"{args.base}: {key}: cyclic shared keys")
            seen.add(key)
            parent = by_key[key].get("shared", "")
            if not parent:
                roots[key] = key
                break
            if parent not in by_key:
                raise SystemExit(f"{args.base}: {key}: unknown shared key {parent!r}")
            path.append(key)
            key = parent
        root = roots[key]
        for key in path:
            roots[key] = root

    direct: dict[str, dict[str, str]] = {}
    unmatched = []
    for uid, (entry, source) in entries.items():
        text = entry.get("en", "")
        note = entry.get("note", "")
        targets: list[dict] = []
        if uid.startswith("rec-"):
            match = re.fullmatch(r"rec-([0-9a-fA-F]+)", uid)
            if not match:
                raise SystemExit(f"{source}: malformed external identifier {uid!r}")
            targets = by_record.get(int(match.group(1), 16), [])
        elif uid.startswith("str-"):
            match = re.fullmatch(r"str-([0-9a-fA-F]+)-([0-9]+)", uid)
            if not match:
                raise SystemExit(f"{source}: malformed external identifier {uid!r}")
            try:
                base_address, index = int(match.group(1), 16), int(match.group(2))
            except ValueError as exc:
                raise SystemExit(f"{source}: malformed external identifier {uid!r}") from exc
            t = table_base.get(base_address)
            if t is not None:
                row = by_key.get(f"t{t:02d}.{index:04d}")
                if row:
                    targets = [row]
                    # The pool reader sees a record's id as part of its text.
                    speaker = row.get("speaker", "")
                    if speaker and text.startswith(speaker):
                        text = text[len(speaker):]
                    elif t < 6 and len(text) >= 6 and text[:6].replace(" ", "0").isdigit():
                        text = text[6:]
        elif uid.startswith("elf-"):
            match = re.fullmatch(r"elf-([0-9a-fA-F]+)", uid)
            if not match:
                raise SystemExit(f"{source}: malformed external identifier {uid!r}")
            row = by_key.get(f"exe.{int(match.group(1), 16) + EXE_LOAD_DELTA:08x}")
            targets = [row] if row else []
        if not targets:
            unmatched.append(uid)
            continue
        if not text:
            continue  # deliberately left as on the disc
        for row in targets:
            direct[row["key"]] = {lang: text, "notes": note}

    columns = INFO_COLUMNS + (["ja"] if args.with_ja else []) + [lang, "notes"]
    # Explicit translations win; untranslated aliases prefer their shared root.
    fallback: dict[str, dict[str, str]] = {}
    for key, translation in direct.items():
        root = roots[key]
        if root not in fallback or key == root:
            fallback[root] = translation
    rows = []
    for row in base:
        translation = direct.get(row["key"], fallback.get(roots[row["key"]]))
        if translation:
            merged = dict(row)
            merged.update(translation)
            rows.append(merged)
    write_table(args.out, columns, rows)
    print(f"{len(rows)} rows written to {args.out}; {len(unmatched)} source entries unmatched")
    if unmatched:
        print("unmatched:", ", ".join(unmatched[:20]), file=sys.stderr)
    return 0 if not unmatched else 1


# ---------------------------------------------------------------- merge


def cmd_merge(args: argparse.Namespace) -> int:
    base_columns, base = read_table(args.base)
    base_keys = {row["key"] for row in base}
    lang_columns: list[str] = []
    language_names: dict[str, str] = {}
    values: dict[str, dict[str, str]] = defaultdict(dict)
    notes: dict[str, str] = {}
    for path in args.mods:
        columns, rows = read_table(path)
        mod_languages = languages(columns)
        for lang in mod_languages:
            if lang.casefold() not in language_names:
                language_names[lang.casefold()] = lang
                lang_columns.append(lang)
        for row in rows:
            if row["key"] not in base_keys:
                raise SystemExit(f"{path}: key {row['key']!r} is not in the base table")
            for lang in mod_languages:
                if row.get(lang):
                    values[row["key"]][language_names[lang.casefold()]] = row[lang]
            if row.get("notes"):
                notes[row["key"]] = row["notes"]
    columns = [c for c in INFO_COLUMNS if c in base_columns] + ["ja"] + lang_columns + ["notes"]
    rows = []
    for row in base:
        merged = dict(row)
        merged.update(values.get(row["key"], {}))
        if row["key"] in notes:
            merged["notes"] = notes[row["key"]]
        rows.append(merged)
    write_table(args.out, columns, rows)
    print(f"{len(rows)} rows, languages: ja, {', '.join(lang_columns) or '(none yet)'} -> {args.out}")
    return 0


# ---------------------------------------------------------------- strip


def cmd_strip(args: argparse.Namespace) -> int:
    columns, rows = read_table(args.input)
    langs = languages(columns)
    if not langs:
        raise SystemExit(f"{args.input}: no language columns")
    keep = ["key"] + [c for c in ("speaker", "caption", "voice", "max_bytes") if c in columns]
    keep += langs + (["notes"] if "notes" in columns else [])
    kept = [r for r in rows if any(r.get(l) for l in langs)]
    write_table(args.out, keep, kept)
    print(f"{len(kept)} translated rows, columns {', '.join(keep)} -> {args.out}")
    return 0


# ---------------------------------------------------------------- check


def rendered_text(text: str, ascii_punct: bool = True) -> str:
    """Apply the runtime's cell and optional punctuation normalization."""
    text = text.replace("\r\n", "\n").replace("\\n", "\n")
    return text.translate(ASCII_PUNCT) if ascii_punct else text


def sjis_encode(text: str, ascii_punct: bool = True) -> tuple[bytes, list[str]]:
    """Encode as the runtime does, retaining the characters replaced by '?'."""
    bad = []
    encoded = bytearray()
    for ch in rendered_text(text, ascii_punct):
        try:
            encoded.extend(ch.encode("cp932"))
        except UnicodeEncodeError:
            bad.append(ch)
            encoded.append(ord("?"))
    return bytes(encoded), bad


def sjis_len(text: str, ascii_punct: bool = True) -> tuple[int, list[str]]:
    """Encoded byte length and characters the runtime will replace."""
    encoded, bad = sjis_encode(text, ascii_punct)
    return len(encoded), bad


def conversions(text: str, ascii_punct: bool = True, *, original: bool = False) -> list[str]:
    """Collect printf conversions using the runtime's byte-level scan."""
    if original:
        data = text.encode("cp932", "replace")
    else:
        data, _ = sjis_encode(text, ascii_punct)
    result = []
    i = 0
    while i < len(data):
        byte = data[i]
        i += 1
        if byte != ord("%"):
            continue
        while i < len(data):
            byte = data[i]
            i += 1
            if byte == ord("%"):
                break
            if ord("a") <= byte <= ord("z") or ord("A") <= byte <= ord("Z"):
                result.append(chr(byte))
                break
    return result


def byte_limits(path: Path, rows: list[dict[str, str]]) -> tuple[dict[str, int], int]:
    limits = {}
    problems = 0
    for row in rows:
        value = row.get("max_bytes", "").strip()
        if not value:
            continue
        try:
            if not re.fullmatch(r"[0-9]+", value):
                raise ValueError
            limits[row["key"]] = int(value)
        except ValueError:
            print(f"{path}: {row['key']}: invalid max_bytes {value!r} (expected a nonnegative integer)")
            problems += 1
    return limits, problems


def cmd_check(args: argparse.Namespace) -> int:
    columns, rows = read_table(args.mod)
    base_keys: dict[str, dict] = {}
    base = []
    has_base = args.base is not None
    if has_base:
        _, base = read_table(args.base)
        base_keys = {r["key"]: r for r in base}
    langs = languages(columns)
    if not langs:
        print(f"{args.mod}: no language columns")
        return 1
    mod_limits, problems = byte_limits(args.mod, rows)
    base_limits, base_problems = byte_limits(args.base, base) if has_base else ({}, 0)
    problems += base_problems
    for lang in langs:
        done = 0
        for row in rows:
            text = row.get(lang, "")
            if not text:
                continue
            done += 1
            key = row["key"]
            where = f"{key} [{lang}]"
            if has_base and key not in base_keys:
                print(f"{where}: key is not in the base table")
                problems += 1
                continue
            size, bad = sjis_len(text, args.ascii_punct)
            if bad:
                codes = ", ".join(f"U+{ord(ch):04X}" for ch in sorted(set(bad)))
                print(f"{where}: no Shift-JIS form for {codes} (shown as '?')")
                problems += 1
            if "\x00" in text:
                print(f"{where}: U+0000 would terminate the string early")
                problems += 1
            budgets = [limits[key] for limits in (mod_limits, base_limits) if key in limits]
            if budgets and size > min(budgets):
                print(f"{where}: {size} bytes exceeds max_bytes {min(budgets)}")
                problems += 1
            original = base_keys.get(key, {}).get("ja", "") if has_base else row.get("ja", "")
            original_conversions = conversions(original, original=True)
            if key.startswith("exe.") and original and original_conversions != conversions(text, args.ascii_punct):
                print(f"{where}: must keep the original's printf conversions {original_conversions} in order")
                problems += 1
            longest = max(len(line) for line in rendered_text(text, args.ascii_punct).split("\n"))
            if args.width and longest > args.width:
                print(f"{where}: a line of {longest} characters (wider than --width {args.width})")
                problems += 1
        total = len(base_keys) if has_base else len(rows)
        print(f"{lang}: {done} of {total} strings translated")
    print(f"{problems} problems")
    return 1 if problems else 0


def nonnegative_int(value: str) -> int:
    try:
        result = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a nonnegative integer") from exc
    if result < 0:
        raise argparse.ArgumentTypeError("must be a nonnegative integer")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("import-external", help="convert the external fan translation's JSON")
    p.add_argument("base", type=Path)
    p.add_argument("checkout", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--lang", default="en")
    p.add_argument("--baseline-only", action="store_true", help="only the hand-checked UI strings")
    p.add_argument("--with-ja", action="store_true", help="keep the Japanese column (local use only)")
    p.set_defaults(func=cmd_import_external)

    p = sub.add_parser("merge", help="one workbook with ja and every language")
    p.add_argument("base", type=Path)
    p.add_argument("mods", type=Path, nargs="*")
    p.add_argument("-o", "--out", type=Path, required=True)
    p.set_defaults(func=cmd_merge)

    p = sub.add_parser("strip", help="drop the disc's text for sharing a mod")
    p.add_argument("input", type=Path)
    p.add_argument("-o", "--out", type=Path, required=True)
    p.set_defaults(func=cmd_strip)

    p = sub.add_parser("check", help="report problems in a mod's table")
    p.add_argument("mod", type=Path)
    p.add_argument("--base", type=Path)
    p.add_argument("--width", type=nonnegative_int, default=0, help="fail on lines longer than this (0 disables)")
    p.add_argument("--ascii-punctuation", action=argparse.BooleanOptionalAction, default=True, dest="ascii_punct",
                   help="match the mod's ASCII punctuation setting (enabled by default)")
    p.set_defaults(func=cmd_check)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
