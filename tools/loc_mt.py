#!/usr/bin/env python3
"""Create unreviewed multilingual drafts with an offline NLLB model.

The model must already exist in a local directory. Hugging Face network access
is disabled before transformers is imported, and every load uses
``local_files_only=True``. Source tables, caches, and output that retains the
Japanese source belong only in ignored local storage. A release table must omit
the Japanese source and contain only project-created locale columns.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import tempfile
from pathlib import Path

import loc_csv


SOURCE_LANGUAGE = "jpn_Jpan"
LOCALES = {
    "en": "eng_Latn",
    "es-MX": "spa_Latn",
    "pt-BR": "por_Latn",
    "zh-Hans": "zho_Hans",
    "fr": "fra_Latn",
    "de": "deu_Latn",
    "hu": "hun_Latn",
    "uk": "ukr_Cyrl",
}
DEFAULT_LOCALES = tuple(locale for locale in LOCALES if locale != "en")
MACHINE_NOTE = "UNREVIEWED MACHINE TRANSLATION"
PRESERVED_DISC_KEYS = frozenset({
    "t06.0017",
    "t06.0018",
    "t06.0019",
    "t06.0020",
    "t06.0021",
    "t06.0022",
    "t06.0023",
})
LINE_BREAK = re.compile(r"\r\n|\r|\n|\\n")
FORMAT_TOKEN = re.compile(r"%%|%[^%\r\nA-Za-z]*[A-Za-z]")
FORMAT_SENTINEL = re.compile(r"ZXQFMT[0-9]+QXZ")
PROTECTED = re.compile(r"\r\n|\r|\n|\\n|%%|%[^%\r\nA-Za-z]*[A-Za-z]")


def protected_plan(text: str) -> list[tuple[bool, str]]:
    """Split text into translatable lines and exact newline tokens."""
    plan = []
    start = 0
    for match in LINE_BREAK.finditer(text):
        if match.start() > start:
            plan.append((True, text[start:match.start()]))
        plan.append((False, match.group()))
        start = match.end()
    if start < len(text):
        plan.append((True, text[start:]))
    return plan


def mask_formats(text: str) -> tuple[str, list[str]]:
    if "ZXQFMT" in text:
        raise SystemExit("source text contains the reserved ZXQFMT translation sentinel")
    tokens = []

    def replace(match):
        tokens.append(match.group())
        return f"ZXQFMT{len(tokens) - 1}QXZ"

    return FORMAT_TOKEN.sub(replace, text), tokens


def restore_formats(text: str, tokens: list[str], target: str) -> str:
    expected = [f"ZXQFMT{index}QXZ" for index in range(len(tokens))]
    if FORMAT_SENTINEL.findall(text) != expected:
        raise ValueError(f"{target} translation changed a format sentinel")
    for sentinel, token in zip(expected, tokens):
        text = text.replace(sentinel, token, 1)
    return text


def translatable_core(text: str) -> tuple[str, str, str]:
    """Keep surrounding whitespace out of model generation."""
    match = re.fullmatch(r"(\s*)(.*?)(\s*)", text, re.DOTALL)
    assert match is not None
    return match.group(1), match.group(2), match.group(3)


class TranslationCache:
    def __init__(self, path: Path | None, model: str):
        self.path = path
        self.model = model
        self.values: dict[str, dict[str, str]] = {}
        if path is None or not path.exists():
            return
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError) as exc:
            raise SystemExit(f"{path}: {exc}") from exc
        if payload.get("version") != 1 or payload.get("source_language") != SOURCE_LANGUAGE:
            raise SystemExit(f"{path}: unsupported translation cache format")
        if payload.get("model") != model:
            raise SystemExit(f"{path}: cache belongs to a different local model")
        raw = payload.get("translations")
        if not isinstance(raw, dict):
            raise SystemExit(f"{path}: invalid translations object")
        for target, entries in raw.items():
            if not isinstance(target, str) or not isinstance(entries, dict):
                raise SystemExit(f"{path}: invalid translation cache entries")
            if not all(isinstance(k, str) and isinstance(v, str) for k, v in entries.items()):
                raise SystemExit(f"{path}: invalid cached translation")
            self.values[target] = dict(entries)

    def target(self, language: str) -> dict[str, str]:
        return self.values.setdefault(language, {})

    def save(self) -> None:
        if self.path is None:
            return
        payload = {
            "version": 1,
            "model": self.model,
            "source_language": SOURCE_LANGUAGE,
            "translations": self.values,
        }
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                "w", encoding="utf-8", newline="\n", dir=self.path.parent,
                prefix=self.path.name + ".", suffix=".tmp", delete=False,
            ) as handle:
                temporary = Path(handle.name)
                json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
                handle.write("\n")
            os.replace(temporary, self.path)
        except (OSError, UnicodeError) as exc:
            try:
                temporary.unlink(missing_ok=True)
            except UnboundLocalError:
                pass
            raise SystemExit(f"{self.path}: {exc}") from exc


class NllbBackend:
    def __init__(
        self,
        model_path: Path,
        device: str,
        max_new_tokens: int,
        num_beams: int,
        no_repeat_ngram_size: int,
        repetition_penalty: float,
    ):
        if not model_path.is_dir():
            raise SystemExit(f"{model_path}: local model directory does not exist")
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        try:
            import torch
            from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
        except ImportError as exc:
            raise SystemExit(
                "offline translation requires locally installed torch, sentencepiece, and transformers"
            ) from exc
        if device == "auto":
            device = "cuda" if torch.cuda.is_available() else "cpu"
        if device == "cuda" and not torch.cuda.is_available():
            raise SystemExit("CUDA was requested but torch reports no available CUDA device")
        try:
            self.tokenizer = AutoTokenizer.from_pretrained(
                model_path, local_files_only=True, trust_remote_code=False
            )
            self.model = AutoModelForSeq2SeqLM.from_pretrained(
                model_path,
                local_files_only=True,
                trust_remote_code=False,
                dtype=torch.float16 if device == "cuda" else None,
            )
        except (ImportError, OSError, ValueError) as exc:
            raise SystemExit(f"{model_path}: cannot load local translation model: {exc}") from exc
        self.device = device
        self.max_new_tokens = max_new_tokens
        self.num_beams = num_beams
        self.no_repeat_ngram_size = no_repeat_ngram_size
        self.repetition_penalty = repetition_penalty
        self.tokenizer.src_lang = SOURCE_LANGUAGE
        self.model.to(device)
        self.model.eval()
        self.torch = torch

    def translate(self, texts: list[str], target: str) -> list[str]:
        if not texts:
            return []
        token_id = self.tokenizer.convert_tokens_to_ids(target)
        if token_id is None or token_id == self.tokenizer.unk_token_id:
            raise SystemExit(f"the local tokenizer does not support target language {target}")
        encoded = self.tokenizer(texts, return_tensors="pt", padding=True, truncation=False)
        encoded = {name: value.to(self.device) for name, value in encoded.items()}
        with self.torch.inference_mode():
            generated = self.model.generate(
                **encoded,
                forced_bos_token_id=token_id,
                max_length=self.max_new_tokens,
                num_beams=self.num_beams,
                no_repeat_ngram_size=self.no_repeat_ngram_size,
                repetition_penalty=self.repetition_penalty,
            )
        return self.tokenizer.batch_decode(generated, skip_special_tokens=True)


def batched(values: list[str], size: int):
    for start in range(0, len(values), size):
        yield values[start:start + size]


def translate_texts(
    texts: list[str],
    target: str,
    backend,
    cache: dict[str, str],
    batch_size: int,
) -> list[str]:
    """Translate unique spans once while preserving protected tokens exactly."""
    missing_texts = list(dict.fromkeys(text for text in texts if text and text not in cache))
    plans: dict[str, list[tuple[bool, str]]] = {}
    cores = []
    for text in missing_texts:
        plan = protected_plan(text)
        plans[text] = plan
        for translated, value in plan:
            if not translated:
                continue
            _, core, _ = translatable_core(value)
            masked, _ = mask_formats(core)
            if masked and masked not in cache:
                cores.append(masked)
    unique_cores = list(dict.fromkeys(cores))
    groups = list(batched(unique_cores, batch_size))
    for index, group in enumerate(groups, 1):
        if index == 1 or index == len(groups) or index % 10 == 0:
            print(f"{target}: translation batch {index} of {len(groups)}", file=sys.stderr, flush=True)
        translated = backend.translate(group, target)
        if len(translated) != len(group) or any(not isinstance(value, str) for value in translated):
            raise SystemExit("translation model returned an unexpected batch shape")
        if any(source.strip() and not value.strip() for source, value in zip(group, translated)):
            raise SystemExit(f"translation model returned an empty {target} draft")
        for source, value in zip(group, translated):
            expected = FORMAT_SENTINEL.findall(source)
            if FORMAT_SENTINEL.findall(value) != expected:
                pieces = FORMAT_SENTINEL.split(source)
                piece_parts = [translatable_core(piece) for piece in pieces]
                piece_cores = [core for _, core, _ in piece_parts if core]
                translated_cores = backend.translate(piece_cores, target)
                if len(translated_cores) != len(piece_cores):
                    raise SystemExit("translation model returned an unexpected fallback batch shape")
                rebuilt = []
                sentinels = FORMAT_SENTINEL.findall(source)
                translated_index = 0
                for piece_index, (before, core, after) in enumerate(piece_parts):
                    translated_piece = ""
                    if core:
                        translated_piece = translated_cores[translated_index]
                        translated_index += 1
                    if core.strip() and not translated_piece.strip():
                        raise SystemExit(f"translation model returned an empty {target} fallback draft")
                    rebuilt.append(before + translated_piece + after)
                    if piece_index < len(sentinels):
                        rebuilt.append(sentinels[piece_index])
                value = "".join(rebuilt)
                if FORMAT_SENTINEL.findall(value) != expected:
                    raise SystemExit(f"split fallback could not preserve {target} format sentinels")
                print(f"warning: {target} required split fallback for a format sentinel", file=sys.stderr)
            cache[source] = value
    for text, plan in plans.items():
        output = []
        for should_translate, value in plan:
            if not should_translate:
                output.append(value)
                continue
            before, core, after = translatable_core(value)
            masked, tokens = mask_formats(core)
            try:
                translated_core = restore_formats(cache[masked], tokens, target) if core else ""
            except ValueError as exc:
                raise SystemExit(exc) from exc
            output.append(before + translated_core + after)
        cache[text] = "".join(output)
    output = [cache.get(text, "") if text else "" for text in texts]
    for source, translated in zip(texts, output):
        if LINE_BREAK.findall(source) != LINE_BREAK.findall(translated):
            raise SystemExit(f"cached or generated {target} text changed a line break")
    return output


def machine_note(existing: str) -> str:
    existing = existing.strip()
    if MACHINE_NOTE in existing:
        return existing
    return f"{existing}; {MACHINE_NOTE}" if existing else MACHINE_NOTE


def apply_override_tables(
    rows: list[dict[str, str]],
    output_columns: list[str],
    paths: list[Path],
) -> None:
    by_key = {row["key"]: row for row in rows}
    output_names = {column.casefold(): column for column in output_columns}
    for path in paths:
        columns, overrides = loc_csv.read_table(path)
        override_languages = loc_csv.languages(columns)
        resolved = {}
        for language in override_languages:
            output_name = output_names.get(language.casefold())
            if output_name is None:
                raise SystemExit(f"{path}: override language {language!r} is not in the output table")
            resolved[language] = output_name
        for override in overrides:
            target = by_key.get(override["key"])
            if target is None:
                raise SystemExit(f"{path}: key {override['key']!r} is not in the Japanese base table")
            for language, output_name in resolved.items():
                if override.get(language):
                    if override["key"] in PRESERVED_DISC_KEYS:
                        raise SystemExit(
                            f"{path}: {override['key']} is persistent save metadata "
                            "and must fall back to the original disc bytes"
                        )
                    target[output_name] = override[language]
            if override.get("notes"):
                target["notes"] = override["notes"]


def translate_columns(
    rows: list[dict[str, str]],
    locales: list[str],
    backend,
    cache: TranslationCache,
    batch_size: int,
) -> None:
    sources = [
        "" if row.get("key") in PRESERVED_DISC_KEYS else row.get("ja", "")
        for row in rows
    ]
    for locale in locales:
        target = LOCALES[locale]
        translated = translate_texts(sources, target, backend, cache.target(target), batch_size)
        for row, value, source in zip(rows, translated, sources):
            row[locale] = value
            if source:
                row["notes"] = machine_note(row.get("notes", ""))
        cache.save()


def write_delimited(path: Path, columns: list[str], rows: list[dict[str, str]], delimiter: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns, delimiter=delimiter, extrasaction="ignore")
            writer.writeheader()
            writer.writerows({column: row.get(column, "") for column in columns} for row in rows)
    except (OSError, UnicodeError, csv.Error) as exc:
        raise SystemExit(f"{path}: {exc}") from exc


def cmd_strings(args: argparse.Namespace) -> int:
    columns, rows = loc_csv.read_table(args.input)
    if "ja" not in columns:
        raise SystemExit(f"{args.input}: offline translation requires a 'ja' column")
    by_key = {row["key"]: row for row in rows}
    included_languages = []
    included_names = {}
    translated_names = {locale.casefold() for locale in args.locales}
    for path in args.include_table:
        include_columns, include_rows = loc_csv.read_table(path)
        for language in loc_csv.languages(include_columns):
            folded = language.casefold()
            if folded in translated_names:
                raise SystemExit(f"{path}: included language {language!r} is also being machine translated")
            if folded not in included_names:
                included_names[folded] = language
                included_languages.append(language)
        for include_row in include_rows:
            target = by_key.get(include_row["key"])
            if target is None:
                raise SystemExit(f"{path}: key {include_row['key']!r} is not in the Japanese base table")
            for language in loc_csv.languages(include_columns):
                if include_row.get(language):
                    target[included_names[language.casefold()]] = include_row[language]
            if include_row.get("notes"):
                target["notes"] = include_row["notes"]
    keep = [column for column in loc_csv.INFO_COLUMNS if column in columns]
    output_columns = (
        keep + (["ja"] if args.with_ja else [])
        + included_languages + args.locales + ["notes"]
    )
    translate_columns(rows, args.locales, args.backend, args.cache_object, args.batch_size)
    apply_override_tables(rows, output_columns, args.override_table)
    for row in rows:
        if row["key"] in PRESERVED_DISC_KEYS:
            for locale in args.locales:
                row[locale] = ""
    loc_csv.write_table(args.out, output_columns, rows)
    print(f"{len(rows)} rows, unreviewed locales {', '.join(args.locales)} -> {args.out}")
    return 0


def read_titles(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    try:
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            if not reader.fieldnames or "file" not in reader.fieldnames or "ja" not in reader.fieldnames:
                raise SystemExit(f"{path}: title table requires 'file' and 'ja' columns")
            rows = list(reader)
    except (OSError, UnicodeError, csv.Error) as exc:
        raise SystemExit(f"{path}: {exc}") from exc
    seen = set()
    for line, row in enumerate(rows, 2):
        name = row.get("file", "").strip()
        if not name or name in seen:
            raise SystemExit(f"{path}:{line}: empty or duplicate title file {name!r}")
        seen.add(name)
        row["file"] = name
    return list(reader.fieldnames), rows


def cmd_titles(args: argparse.Namespace) -> int:
    columns, rows = read_titles(args.input)
    output_columns = [column for column in columns if column not in LOCALES and column != "notes"]
    output_columns += args.locales + ["notes"]
    translate_columns(rows, args.locales, args.backend, args.cache_object, args.batch_size)
    write_delimited(args.out, output_columns, rows, "\t")
    print(f"{len(rows)} titles, unreviewed locales {', '.join(args.locales)} -> {args.out}")
    return 0


def positive_int(value: str) -> int:
    try:
        result = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive integer") from exc
    if result < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return result


def positive_float(value: str) -> float:
    try:
        result = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive number") from exc
    if result <= 0:
        raise argparse.ArgumentTypeError("must be a positive number")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--model", type=Path, required=True, help="existing local NLLB-compatible model directory")
    common.add_argument("--locales", nargs="+", choices=LOCALES, default=list(DEFAULT_LOCALES),
                        help="output locales (default: seven non-English release locales)")
    common.add_argument("--cache", type=Path, help="local JSON cache (default: OUT.mt-cache.json)")
    common.add_argument("--batch-size", type=positive_int, default=8)
    common.add_argument("--max-new-tokens", type=positive_int, default=256)
    common.add_argument("--num-beams", type=positive_int, default=4)
    common.add_argument("--no-repeat-ngram-size", type=positive_int, default=3)
    common.add_argument("--repetition-penalty", type=positive_float, default=1.1)
    common.add_argument("--device", choices=("auto", "cpu", "cuda"), default="auto")
    sub = parser.add_subparsers(dest="command", required=True)

    strings_parser = sub.add_parser("strings", parents=[common], help="translate an exported localization CSV")
    strings_parser.add_argument("input", type=Path)
    strings_parser.add_argument("-o", "--out", type=Path, required=True)
    strings_parser.add_argument("--include-table", type=Path, action="append", default=[],
                                help="carry language columns and notes from another keyed CSV")
    strings_parser.add_argument("--override-table", type=Path, action="append", default=[],
                                help="replace nonempty output cells after machine translation")
    strings_parser.add_argument("--with-ja", action="store_true", help="retain publisher Japanese in local output")
    strings_parser.set_defaults(func=cmd_strings)

    titles_parser = sub.add_parser("titles", parents=[common], help="translate a local mission-title TSV")
    titles_parser.add_argument("input", type=Path)
    titles_parser.add_argument("-o", "--out", type=Path, required=True)
    titles_parser.set_defaults(func=cmd_titles)

    args = parser.parse_args(argv)
    model_path = args.model.resolve()
    cache_path = args.cache or args.out.with_suffix(args.out.suffix + ".mt-cache.json")
    args.cache_object = TranslationCache(cache_path, str(model_path))
    args.backend = NllbBackend(
        model_path,
        args.device,
        args.max_new_tokens,
        args.num_beams,
        args.no_repeat_ngram_size,
        args.repetition_penalty,
    )
    if any(locale in args.locales for locale in ("es-MX", "pt-BR")):
        print(
            "warning: NLLB provides generic Spanish and Portuguese drafts; "
            "Mexican and Brazilian review is still required",
            file=sys.stderr,
        )
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
