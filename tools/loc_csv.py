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
  font MOD --lang LANG --font TTF     build a runtime 32x32 glyph pack

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
import struct
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

INFO_COLUMNS = ["key", "offset", "speaker", "caption", "voice", "shared", "max_bytes"]
RESERVED = set(INFO_COLUMNS) | {"notes", "context"}
EXE_LOAD_DELTA = 0x100000 - 0x80  # ELF file offset -> virtual address
TABLE_COUNT = 11  # Matches STR_TABLES in the runtime.
FONT_MAGIC = b"MCFNT1\0\0"
FONT_TILE_SIZE = 32
FONT_ACTIVE_SIZE = 20
FONT_NARROW_SIZE = 12
FONT_GLYPH_SIZE = FONT_TILE_SIZE * FONT_TILE_SIZE // 2
FONT_HEADER_SIZE = 12
FONT_RECORD_SIZE = 8 + FONT_GLYPH_SIZE
FONT_NARROW_CODES = (*range(0xA2, 0xE0), 0x80, 0xA0, 0xFD, 0xFE, 0xFF)
FONT_LEADS = (0x85, 0x86, 0xEB, 0xEC, 0xEF, *range(0xF0, 0xFA))
FONT_TRAILS = (*range(0x40, 0x7F), *range(0x80, 0xFD))
FONT_WIDE_CODES = tuple((lead << 8) | trail for lead in FONT_LEADS for trail in FONT_TRAILS)
FONT_CODES = FONT_NARROW_CODES + FONT_WIDE_CODES
FONT_CODE_SET = frozenset(FONT_CODES)

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


def sjis_encode(
    text: str,
    ascii_punct: bool = True,
    custom: dict[str, int] | None = None,
) -> tuple[bytes, list[str]]:
    """Encode as the runtime does, retaining the characters replaced by '?'."""
    bad = []
    encoded = bytearray()
    for ch in rendered_text(text, ascii_punct):
        if custom and ch in custom:
            code = custom[ch]
            encoded.extend(code.to_bytes(1 if code <= 0xFF else 2, "big"))
            continue
        try:
            encoded.extend(ch.encode("cp932"))
        except UnicodeEncodeError:
            bad.append(ch)
            encoded.append(ord("?"))
    return bytes(encoded), bad


def sjis_len(
    text: str,
    ascii_punct: bool = True,
    custom: dict[str, int] | None = None,
) -> tuple[int, list[str]]:
    """Encoded byte length and characters the runtime will replace."""
    encoded, bad = sjis_encode(text, ascii_punct, custom)
    return len(encoded), bad


def conversion_signature(
    text: str,
    ascii_punct: bool = True,
    *,
    original: bool = False,
    custom: dict[str, int] | None = None,
) -> tuple[list[tuple[str, str, bool, bool]], bool]:
    """Collect runtime printf conversions and whether every percent sequence is valid."""
    if original:
        data = text.encode("cp932", "replace")
    else:
        data, _ = sjis_encode(text, ascii_punct, custom)
    result = []
    i = 0
    while i < len(data):
        byte = data[i]
        i += 1
        if byte != ord("%"):
            continue
        if i >= len(data):
            return result, False
        if data[i] == ord("%"):
            i += 1
            continue
        while i < len(data) and data[i] in b"-+ #0'":
            i += 1
        width_argument = i < len(data) and data[i] == ord("*")
        if width_argument:
            i += 1
        else:
            while i < len(data) and ord("0") <= data[i] <= ord("9"):
                i += 1
        precision_argument = False
        if i < len(data) and data[i] == ord("."):
            i += 1
            precision_argument = i < len(data) and data[i] == ord("*")
            if precision_argument:
                i += 1
            else:
                while i < len(data) and ord("0") <= data[i] <= ord("9"):
                    i += 1
        length = ""
        if i < len(data) and data[i] in b"hljztL":
            length = chr(data[i])
            i += 1
            if i < len(data) and length in ("h", "l") and data[i] == ord(length):
                length += length
                i += 1
        if i >= len(data) or data[i] not in b"diuoxXfFeEgGaAcspn":
            return result, False
        result.append((chr(data[i]), length, width_argument, precision_argument))
        i += 1
    return result, True


def conversions(
    text: str,
    ascii_punct: bool = True,
    *,
    original: bool = False,
    custom: dict[str, int] | None = None,
) -> list[str]:
    signature, _ = conversion_signature(
        text, ascii_punct, original=original, custom=custom
    )
    return [conversion[0] for conversion in signature]


# --------------------------------------------------------------- font


def font_codes() -> list[int]:
    """Reserved narrow and wide codes accepted by the runtime font hook."""
    return list(FONT_CODES)


def valid_font_code(code: int) -> bool:
    return code in FONT_CODE_SET


def narrow_font_character(ch: str) -> bool:
    """Whether a custom glyph should use the game's one-byte advance."""
    name = unicodedata.name(ch, "")
    return ord(ch) >= 0x80 and (
        "LATIN" in name
        or "CYRILLIC" in name
        or ch in "\u00a1\u00bf"
    )


def assign_font_codes(characters: list[str]) -> list[int]:
    narrow = iter(FONT_NARROW_CODES)
    wide = iter(FONT_WIDE_CODES)
    assigned = []
    for ch in characters:
        try:
            assigned.append(next(narrow if narrow_font_character(ch) else wide))
        except StopIteration as exc:
            kind = "narrow" if narrow_font_character(ch) else "wide"
            raise ValueError(f"the runtime {kind} code pool cannot encode U+{ord(ch):04X}") from exc
    return assigned


def parse_font_pack(data: bytes, source: object = "<font pack>") -> dict[int, tuple[int, bytes]]:
    """Validate a runtime font pack and return code point -> (game code, glyph)."""
    if len(data) < FONT_HEADER_SIZE or data[:8] != FONT_MAGIC:
        raise ValueError(f"{source}: not a version-1 runtime font pack")
    count = struct.unpack_from("<I", data, 8)[0]
    if count > 4096 or FONT_HEADER_SIZE + count * FONT_RECORD_SIZE != len(data):
        raise ValueError(f"{source}: invalid font record count or size")
    records: dict[int, tuple[int, bytes]] = {}
    by_code: dict[int, int] = {}
    for index in range(count):
        at = FONT_HEADER_SIZE + index * FONT_RECORD_SIZE
        codepoint, code, flags = struct.unpack_from("<IHH", data, at)
        glyph = data[at + 8:at + FONT_RECORD_SIZE]
        if (codepoint > 0x10FFFF or 0xD800 <= codepoint <= 0xDFFF
                or flags or not valid_font_code(code)):
            raise ValueError(f"{source}: font record {index} has an invalid character, code or flags")
        previous = records.get(codepoint)
        if previous is not None:
            if previous != (code, glyph):
                raise ValueError(f"{source}: U+{codepoint:04X} has conflicting records")
            continue
        if code in by_code:
            raise ValueError(
                f"{source}: code {code:04X} is reused for "
                f"U+{by_code[code]:04X} and U+{codepoint:04X}"
            )
        records[codepoint] = (code, glyph)
        by_code[code] = codepoint
    return records


def load_font_packs(paths: list[Path]) -> tuple[dict[str, int], dict[int, bytes]]:
    records: dict[int, tuple[int, bytes]] = {}
    by_code: dict[int, int] = {}
    for path in paths:
        try:
            incoming = parse_font_pack(path.read_bytes(), path)
        except (OSError, ValueError) as exc:
            raise SystemExit(exc) from exc
        for codepoint, record in incoming.items():
            if codepoint in records:
                if records[codepoint] != record:
                    raise SystemExit(f"{path}: U+{codepoint:04X} conflicts with another font pack")
                continue
            code, _ = record
            if code in by_code:
                raise SystemExit(
                    f"{path}: code {code:04X} is reused for "
                    f"U+{by_code[code]:04X} and U+{codepoint:04X}"
                )
            records[codepoint] = record
            by_code[code] = codepoint
    custom = {chr(codepoint): code for codepoint, (code, _) in records.items()}
    glyphs = {code: glyph for code, glyph in (record for record in records.values())}
    return custom, glyphs


def cjk_character(ch: str) -> bool:
    value = ord(ch)
    return (
        0x3400 <= value <= 0x4DBF
        or 0x4E00 <= value <= 0x9FFF
        or 0xF900 <= value <= 0xFAFF
        or 0x20000 <= value <= 0x323AF
    )


def font_characters(
    rows: list[dict[str, str]],
    lang: str,
    ascii_punct: bool,
    override_cjk: bool,
) -> list[str]:
    selected = set()
    for row in rows:
        for ch in rendered_text(row.get(lang, ""), ascii_punct):
            if ch in "\r\n\0":
                continue
            if override_cjk and cjk_character(ch):
                selected.add(ch)
                continue
            if narrow_font_character(ch):
                selected.add(ch)
                continue
            try:
                ch.encode("cp932")
            except UnicodeEncodeError:
                selected.add(ch)
    return sorted(selected, key=ord)


def pack_font_glyph(pixels: bytes) -> bytes:
    """Pack 32x32 coverage values as low-nibble-first 4-bit pixels."""
    if len(pixels) != FONT_TILE_SIZE * FONT_TILE_SIZE:
        raise ValueError("a runtime glyph must contain 32x32 pixels")
    packed = bytearray(FONT_GLYPH_SIZE)
    for index in range(0, len(pixels), 2):
        low = min(15, (pixels[index] + 8) // 17)
        high = min(15, (pixels[index + 1] + 8) // 17)
        packed[index // 2] = low | (high << 4)
    return bytes(packed)


def fitted_font_glyph_size(width: int, height: int, narrow: bool) -> tuple[int, int]:
    if width <= 0 or height <= 0:
        raise ValueError("a runtime glyph must have positive dimensions")
    maximum_width = FONT_NARROW_SIZE - 1 if narrow else FONT_ACTIVE_SIZE
    scale = min(1.0, FONT_ACTIVE_SIZE / height)
    fitted_width = max(1, round(width * scale))
    fitted_height = max(1, round(height * scale))
    if not narrow and fitted_width > maximum_width:
        scale = maximum_width / fitted_width
        fitted_width = maximum_width
        fitted_height = max(1, round(fitted_height * scale))
    return min(maximum_width, fitted_width), min(FONT_ACTIVE_SIZE, fitted_height)


def render_font_glyph(
    ch: str,
    font,
    image_module,
    draw_module,
    *,
    narrow: bool = False,
) -> bytes:
    image = image_module.new("L", (FONT_TILE_SIZE, FONT_TILE_SIZE), 0)
    draw = draw_module.Draw(image)
    bounds = draw.textbbox((0, 0), ch, font=font)
    width, height = bounds[2] - bounds[0], bounds[3] - bounds[1]
    if width <= 0 or height <= 0:
        raise ValueError(f"U+{ord(ch):04X} rendered as an empty glyph")
    if width > FONT_TILE_SIZE or height > FONT_TILE_SIZE:
        raise ValueError(
            f"U+{ord(ch):04X} does not fit a 32x32 tile "
            f"({width}x{height}; lower --size)"
        )
    glyph = image_module.new("L", (width, height), 0)
    glyph_draw = draw_module.Draw(glyph)
    glyph_draw.text((-bounds[0], -bounds[1]), ch, font=font, fill=255)
    target_width, target_height = fitted_font_glyph_size(width, height, narrow)
    if (target_width, target_height) != (width, height):
        resampling = getattr(image_module, "Resampling", image_module)
        glyph = glyph.resize((target_width, target_height), resampling.LANCZOS)
    active_width = FONT_NARROW_SIZE if narrow else FONT_ACTIVE_SIZE
    x = (active_width - target_width) // 2
    y = (FONT_ACTIVE_SIZE - target_height) // 2
    image.paste(glyph, (x, y))
    pixels = image.tobytes()
    if not any(pixels):
        raise ValueError(f"U+{ord(ch):04X} rendered as an empty glyph")
    return pack_font_glyph(pixels)


def select_font_variation(font, name: str | None):
    if not name:
        return font
    try:
        available = {
            value.decode("utf-8", errors="replace").casefold(): value
            for value in font.get_variation_names()
        }
    except (AttributeError, OSError) as exc:
        raise ValueError("font does not provide named variations") from exc
    selected = available.get(name.casefold())
    if selected is None:
        shown = ", ".join(value.decode("utf-8", errors="replace") for value in available.values())
        raise ValueError(f"font has no variation {name!r} (available: {shown})")
    try:
        font.set_variation_by_name(selected)
    except (AttributeError, OSError, ValueError) as exc:
        raise ValueError(f"cannot select font variation {name!r}: {exc}") from exc
    return font


def font_cmap_subtables(data: bytes, face_index: int, source: object) -> list[int]:
    try:
        if data[:4] == b"ttcf":
            count = struct.unpack_from(">I", data, 8)[0]
            if face_index >= count:
                raise ValueError(f"face index {face_index} is outside this {count}-face collection")
            face = struct.unpack_from(">I", data, 12 + face_index * 4)[0]
        else:
            if face_index:
                raise ValueError("face index must be zero for a non-collection font")
            face = 0
        table_count = struct.unpack_from(">H", data, face + 4)[0]
        cmap = None
        for index in range(table_count):
            at = face + 12 + index * 16
            tag, offset, length = struct.unpack_from(">4s4xII", data, at)
            if offset + length > len(data):
                raise ValueError("font table extends beyond the file")
            if tag == b"cmap":
                cmap = (offset, length)
        if cmap is None:
            raise ValueError("font has no cmap table")
        offset, length = cmap
        version, count = struct.unpack_from(">HH", data, offset)
        if version != 0 or 4 + count * 8 > length:
            raise ValueError("invalid cmap header")
        subtables = []
        for index in range(count):
            platform, encoding, relative = struct.unpack_from(">HHI", data, offset + 4 + index * 8)
            subtable = offset + relative
            if subtable + 2 > offset + length:
                raise ValueError("cmap subtable extends beyond the table")
            if platform == 0 or platform == 3 and encoding in (1, 10):
                if struct.unpack_from(">H", data, subtable)[0] in (0, 4, 6, 12, 13):
                    subtables.append(subtable)
        if not subtables:
            raise ValueError("font has no supported Unicode cmap")
        return subtables
    except struct.error as exc:
        raise ValueError(f"{source}: truncated or invalid font") from exc


def cmap_has_codepoint(data: bytes, offset: int, codepoint: int) -> bool:
    try:
        format_id = struct.unpack_from(">H", data, offset)[0]
        if format_id == 0:
            length = struct.unpack_from(">H", data, offset + 2)[0]
            return codepoint < 256 and length >= 262 and data[offset + 6 + codepoint] != 0
        if format_id == 6:
            length, first, count = struct.unpack_from(">HHH", data, offset + 2)
            if not first <= codepoint < first + count or 10 + count * 2 > length:
                return False
            return struct.unpack_from(">H", data, offset + 10 + (codepoint - first) * 2)[0] != 0
        if format_id == 4:
            if codepoint > 0xFFFF:
                return False
            length, segment_bytes = struct.unpack_from(">HH", data, offset + 2)
            segment_count = segment_bytes // 2
            end_codes = offset + 14
            start_codes = end_codes + segment_count * 2 + 2
            deltas = start_codes + segment_count * 2
            ranges = deltas + segment_count * 2
            if ranges + segment_count * 2 > offset + length:
                return False
            for index in range(segment_count):
                end = struct.unpack_from(">H", data, end_codes + index * 2)[0]
                if codepoint > end:
                    continue
                start = struct.unpack_from(">H", data, start_codes + index * 2)[0]
                if codepoint < start:
                    return False
                delta = struct.unpack_from(">h", data, deltas + index * 2)[0]
                range_offset_at = ranges + index * 2
                range_offset = struct.unpack_from(">H", data, range_offset_at)[0]
                if range_offset == 0:
                    return (codepoint + delta) & 0xFFFF != 0
                glyph_at = range_offset_at + range_offset + (codepoint - start) * 2
                if glyph_at + 2 > offset + length:
                    return False
                glyph = struct.unpack_from(">H", data, glyph_at)[0]
                return glyph != 0 and (glyph + delta) & 0xFFFF != 0
            return False
        if format_id in (12, 13):
            length, groups = struct.unpack_from(">II", data, offset + 4)[0], struct.unpack_from(">I", data, offset + 12)[0]
            if 16 + groups * 12 > length:
                return False
            low, high = 0, groups
            while low < high:
                middle = (low + high) // 2
                start, end, glyph = struct.unpack_from(">III", data, offset + 16 + middle * 12)
                if codepoint < start:
                    high = middle
                elif codepoint > end:
                    low = middle + 1
                else:
                    return glyph != 0 or format_id == 12 and codepoint > start
            return False
    except struct.error:
        return False
    return False


def missing_font_characters(path: Path, face_index: int, characters: list[str]) -> list[str]:
    try:
        data = path.read_bytes()
        subtables = font_cmap_subtables(data, face_index, path)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"{path}: {exc}") from exc
    return [
        ch for ch in characters
        if not any(cmap_has_codepoint(data, subtable, ord(ch)) for subtable in subtables)
    ]


def resolve_language(columns: list[str], requested: str, path: Path) -> str:
    matches = [lang for lang in languages(columns) if lang.casefold() == requested.casefold()]
    if len(matches) != 1:
        raise SystemExit(f"{path}: no language column {requested!r}")
    return matches[0]


def cmd_font(args: argparse.Namespace) -> int:
    columns, rows = read_table(args.mod)
    lang = resolve_language(columns, args.lang, args.mod)
    characters = font_characters(rows, lang, args.ascii_punct, args.override_cjk)
    if not characters:
        raise SystemExit(f"{args.mod}: {lang} needs no custom runtime glyphs")
    try:
        codes = assign_font_codes(characters)
    except ValueError as exc:
        raise SystemExit(f"{args.mod}: {lang}: {exc}") from exc
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as exc:
        raise SystemExit("font generation requires Pillow installed locally") from exc
    try:
        missing = missing_font_characters(args.font, args.face_index, characters)
        if missing:
            shown = ", ".join(f"U+{ord(ch):04X}" for ch in missing[:16])
            suffix = f" and {len(missing) - 16} more" if len(missing) > 16 else ""
            raise SystemExit(f"{args.font}: font has no glyph for {shown}{suffix}")
        font = ImageFont.truetype(str(args.font), args.size, index=args.face_index)
        select_font_variation(font, args.variation)
        output = bytearray(FONT_MAGIC)
        output.extend(struct.pack("<I", len(characters)))
        for ch, code in zip(characters, codes):
            glyph = render_font_glyph(
                ch,
                font,
                Image,
                ImageDraw,
                narrow=code <= 0xFF,
            )
            output.extend(struct.pack("<IHH", ord(ch), code, 0))
            output.extend(glyph)
        parse_font_pack(bytes(output), args.out)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_bytes(output)
    except SystemExit:
        raise
    except (OSError, ValueError) as exc:
        raise SystemExit(f"{args.out}: {exc}") from exc
    print(f"{len(characters)} glyphs for {lang} -> {args.out}")
    return 0


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
    custom, _ = load_font_packs(args.font) if args.font else ({}, {})
    base_keys: dict[str, dict] = {}
    base = []
    has_base = args.base is not None
    if has_base:
        _, base = read_table(args.base)
        base_keys = {r["key"]: r for r in base}
    langs = languages(columns)
    if args.lang:
        selected = []
        for requested in args.lang:
            lang = resolve_language(columns, requested, args.mod)
            if lang not in selected:
                selected.append(lang)
        langs = selected
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
            size, bad = sjis_len(text, args.ascii_punct, custom)
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
            original_signature, original_valid = conversion_signature(original, original=True)
            translated_signature, translated_valid = conversion_signature(
                text, args.ascii_punct, custom=custom
            )
            if (key.startswith("exe.") and original
                    and (
                        not original_valid
                        or not translated_valid
                        or original_signature != translated_signature
                    )):
                original_conversions = [conversion[0] for conversion in original_signature]
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


def positive_int(value: str) -> int:
    result = nonnegative_int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
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
    p.add_argument("--lang", action="append", help="check only this language column (repeatable)")
    p.add_argument("--font", type=Path, action="append", default=[],
                   help="runtime font.bin used by this table (repeatable)")
    p.add_argument("--width", type=nonnegative_int, default=0, help="fail on lines longer than this (0 disables)")
    p.add_argument("--ascii-punctuation", action=argparse.BooleanOptionalAction, default=True, dest="ascii_punct",
                   help="match the mod's ASCII punctuation setting (enabled by default)")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("font", help="build a runtime glyph pack from a language column")
    p.add_argument("mod", type=Path)
    p.add_argument("--lang", required=True, help="language column to scan")
    p.add_argument("--font", type=Path, required=True, help="local TTF, OTF, TTC, or OTC font")
    p.add_argument("-o", "--out", type=Path, required=True)
    p.add_argument("--face-index", type=nonnegative_int, default=0, help="face index in a font collection")
    p.add_argument("--variation", help="named variable-font instance, such as Regular")
    p.add_argument("--size", type=positive_int, default=28,
                   help="source render size before fitting to the game font area (default: 28)")
    p.add_argument("--override-cjk", action="store_true",
                   help="use this font for CJK characters even when CP932 has a glyph")
    p.add_argument("--ascii-punctuation", action=argparse.BooleanOptionalAction, default=True, dest="ascii_punct",
                   help="match the mod's ASCII punctuation setting (enabled by default)")
    p.set_defaults(func=cmd_font)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
