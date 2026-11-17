#!/usr/bin/env python3
"""Export and render language-specific Macross indexed textures.

Inputs and outputs contain publisher-derived art and must stay in ignored local
storage. The tool handles the game's pre-swizzled indexed TIM2 layouts and the
verified 512x128 SBTTL title layout. A user-supplied local CRICMP executable
performs decompression and recompression; it is never downloaded.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import struct
import subprocess
import tempfile
from pathlib import Path

import loc_csv
import mrg


LOCALES = ("en", "es-MX", "pt-BR", "zh-Hans", "fr", "de", "hu", "uk")
WIDTH = 512
HEIGHT = 128
IMAGE_SIZE = WIDTH * HEIGHT // 2
PALETTE_COLORS = 16
PSMT4 = 4
PSMT8 = 5

PSMT8_BLOCKS = (
    0, 1, 4, 5, 16, 17, 20, 21,
    2, 3, 6, 7, 18, 19, 22, 23,
    8, 9, 12, 13, 24, 25, 28, 29,
    10, 11, 14, 15, 26, 27, 30, 31,
)
PSMT8_COLUMN_WORDS = (
    (
        0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13,
        2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15,
        8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5,
        10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7,
    ),
    (
        8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5,
        10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7,
        0, 1, 4, 5, 8, 9, 12, 13, 0, 1, 4, 5, 8, 9, 12, 13,
        2, 3, 6, 7, 10, 11, 14, 15, 2, 3, 6, 7, 10, 11, 14, 15,
    ),
)
PSMT8_COLUMN_BYTES = (
    (0,) * 8 + (2,) * 8 + (0,) * 8 + (2,) * 8
    + (1,) * 8 + (3,) * 8 + (1,) * 8 + (3,) * 8
)


def bit(value: int, index: int) -> int:
    return (value >> index) & 1


def block32(x: int, y: int) -> int:
    return (
        bit(x, 0)
        | bit(y, 0) << 1
        | bit(x, 1) << 2
        | bit(y, 1) << 3
        | bit(x, 2) << 4
    )


def column32(x: int, y: int) -> int:
    return (
        bit(x, 0)
        | bit(y, 0) << 1
        | bit(x, 1) << 2
        | bit(x, 2) << 3
        | bit(y, 1) << 4
        | bit(y, 2) << 5
    )


def block16(x: int, y: int) -> int:
    return (
        bit(y, 0)
        | bit(x, 0) << 1
        | bit(y, 1) << 2
        | bit(x, 1) << 3
        | bit(y, 2) << 4
    )


def column4(x: int, y: int) -> int:
    return (
        bit(y, 1)
        | bit(x, 3) << 1
        | bit(x, 4) << 2
        | bit(x, 0) << 3
        | bit(y, 0) << 4
        | bit(x, 1) << 5
        | (bit(x, 2) ^ bit(y, 1) ^ bit(y, 2)) << 6
        | bit(y, 2) << 7
        | bit(y, 3) << 8
    )


def psmct32_word_address(x: int, y: int, buffer_width: int) -> int:
    block = ((y >> 5) * buffer_width + (x >> 6)) * 32 + block32(x >> 3, y >> 3)
    return (block << 6) + column32(x, y)


def psmt4_nibble_address(x: int, y: int, buffer_width: int) -> int:
    block = (
        (y >> 7) * (buffer_width >> 1) + (x >> 7)
    ) * 32 + block16(x >> 5, y >> 4)
    return (block << 9) + column4(x, y)


def psmt8_byte_address(x: int, y: int, buffer_width: int) -> int:
    page = ((y >> 6) * (buffer_width >> 1) + (x >> 7)) * 8192
    block_index = ((y >> 4) & 3) * 8 + ((x >> 4) & 7)
    block = PSMT8_BLOCKS[block_index] * 256
    column = (y >> 2) & 3
    within = (y & 3) * 16 + (x & 15)
    word = PSMT8_COLUMN_WORDS[column & 1][within] * 4
    return page + block + column * 64 + word + PSMT8_COLUMN_BYTES[within]


def indexed_image_size(width: int, height: int, image_type: int) -> int:
    if image_type == PSMT4:
        return width * height // 2
    if image_type == PSMT8:
        return width * height
    raise ValueError(f"unsupported indexed TIM2 image type {image_type}")


def indexed_upload_dimensions(width: int, height: int, image_type: int) -> tuple[int, int]:
    if image_type == PSMT4:
        return width // 2, height // 4
    if image_type == PSMT8:
        return width // 2, height // 2
    raise ValueError(f"unsupported indexed TIM2 image type {image_type}")


def indexed_upload_to_vram(
    payload: bytes,
    width: int,
    height: int,
    image_type: int,
) -> bytearray:
    expected = indexed_image_size(width, height, image_type)
    if len(payload) != expected:
        raise ValueError(f"indexed image payload must be {expected} bytes")
    upload_width, upload_height = indexed_upload_dimensions(width, height, image_type)
    if upload_width % 64:
        raise ValueError("indexed TIM2 upload width must be a multiple of 64 pixels")
    vram = bytearray(expected)
    buffer_width = upload_width // 64
    source = 0
    for y in range(upload_height):
        for x in range(upload_width):
            destination = psmct32_word_address(x, y, buffer_width) * 4
            vram[destination:destination + 4] = payload[source:source + 4]
            source += 4
    return vram


def indexed_vram_to_upload(
    vram: bytes,
    width: int,
    height: int,
    image_type: int,
) -> bytes:
    expected = indexed_image_size(width, height, image_type)
    if len(vram) != expected:
        raise ValueError(f"indexed VRAM image must be {expected} bytes")
    upload_width, upload_height = indexed_upload_dimensions(width, height, image_type)
    if upload_width % 64:
        raise ValueError("indexed TIM2 upload width must be a multiple of 64 pixels")
    output = bytearray(expected)
    buffer_width = upload_width // 64
    destination = 0
    for y in range(upload_height):
        for x in range(upload_width):
            source = psmct32_word_address(x, y, buffer_width) * 4
            output[destination:destination + 4] = vram[source:source + 4]
            destination += 4
    return bytes(output)


def decode_indexed_payload(
    payload: bytes,
    width: int,
    height: int,
    image_type: int,
    low_nibble_first: bool = True,
) -> bytes:
    vram = indexed_upload_to_vram(payload, width, height, image_type)
    output = bytearray(width * height)
    buffer_width = width // 64
    for y in range(height):
        for x in range(width):
            if image_type == PSMT4:
                address = psmt4_nibble_address(x, y, buffer_width)
                nibble = address & 1
                if not low_nibble_first:
                    nibble ^= 1
                output[y * width + x] = vram[address >> 1] >> (nibble * 4) & 0x0F
            else:
                output[y * width + x] = vram[psmt8_byte_address(x, y, buffer_width)]
    return bytes(output)


def encode_indexed_payload(
    indices: bytes,
    width: int,
    height: int,
    image_type: int,
    low_nibble_first: bool = True,
) -> bytes:
    colors = 16 if image_type == PSMT4 else 256 if image_type == PSMT8 else 0
    if len(indices) != width * height or not colors or any(value >= colors for value in indices):
        raise ValueError(
            f"indexed pixels must be {width}x{height} values in the range 0..{colors - 1}"
        )
    vram = bytearray(indexed_image_size(width, height, image_type))
    buffer_width = width // 64
    for y in range(height):
        for x in range(width):
            value = indices[y * width + x]
            if image_type == PSMT4:
                address = psmt4_nibble_address(x, y, buffer_width)
                nibble = address & 1
                if not low_nibble_first:
                    nibble ^= 1
                byte = address >> 1
                shift = nibble * 4
                vram[byte] = vram[byte] & ~(0x0F << shift) | value << shift
            else:
                vram[psmt8_byte_address(x, y, buffer_width)] = value
    return indexed_vram_to_upload(vram, width, height, image_type)


def parse_indexed_tim2(data: bytes, source: object = "<TIM2>") -> dict:
    if len(data) < 0x40 or data[:4] != b"TIM2":
        raise ValueError(f"{source}: not a TIM2 texture")
    if struct.unpack_from("<H", data, 6)[0] != 1:
        raise ValueError(f"{source}: expected exactly one TIM2 picture")
    alignment = data[5]
    if alignment not in (0, 1):
        raise ValueError(f"{source}: unsupported TIM2 alignment mode {alignment}")
    picture = 0x80 if alignment == 1 else 0x10
    if len(data) < picture + 0x30:
        raise ValueError(f"{source}: truncated TIM2 picture header")
    total, clut_size, image_size, header_size, colors = struct.unpack_from("<IIIHH", data, picture)
    mipmaps = data[picture + 0x11]
    image_type = data[picture + 0x13]
    width, height = struct.unpack_from("<HH", data, picture + 0x14)
    expected_colors = 16 if image_type == PSMT4 else 256 if image_type == PSMT8 else 0
    image_offset = picture + header_size
    palette_offset = image_offset + image_size
    logical_end = picture + total
    if (
        not expected_colors
        or not width
        or not height
        or width % 128
        or height % (128 if image_type == PSMT4 else 64)
        or image_size != indexed_image_size(width, height, image_type)
        or colors != expected_colors
        or mipmaps != 1
        or header_size < 0x30
        or clut_size < expected_colors * 4
        or total != header_size + image_size + clut_size
        or logical_end > len(data)
    ):
        raise ValueError(f"{source}: unsupported indexed TIM2 layout")
    return {
        "picture_offset": picture,
        "image_offset": image_offset,
        "image_size": image_size,
        "palette_offset": palette_offset,
        "palette_colors": colors,
        "image_type": image_type,
        "width": width,
        "height": height,
        "logical_end": logical_end,
    }


def indexed_palette(data: bytes, layout: dict) -> list[tuple[int, int, int, int]]:
    offset = layout["palette_offset"]
    colors = []
    for index in range(layout["palette_colors"]):
        stored = (
            (index & 0xE7) | ((index & 0x08) << 1) | ((index & 0x10) >> 1)
            if layout["palette_colors"] == 256 else index
        )
        red, green, blue, alpha = data[offset + stored * 4:offset + stored * 4 + 4]
        colors.append((red, green, blue, min(255, alpha * 2)))
    return colors


def replace_indexed_image(
    data: bytes,
    indices: bytes,
    low_nibble_first: bool = True,
) -> bytes:
    layout = parse_indexed_tim2(data)
    payload = encode_indexed_payload(
        indices,
        layout["width"],
        layout["height"],
        layout["image_type"],
        low_nibble_first,
    )
    output = bytearray(data)
    start = layout["image_offset"]
    output[start:start + layout["image_size"]] = payload
    return bytes(output)


def upload_to_vram(payload: bytes) -> bytearray:
    """Recreate the PSMCT32 upload used for this pre-swizzled PSMT4 texture."""
    return indexed_upload_to_vram(payload, WIDTH, HEIGHT, PSMT4)


def vram_to_upload(vram: bytes) -> bytes:
    return indexed_vram_to_upload(vram, WIDTH, HEIGHT, PSMT4)


def parse_title_tim2(data: bytes, source: object = "<TIM2>") -> dict:
    try:
        layout = parse_indexed_tim2(data, source)
    except ValueError as exc:
        raise ValueError(f"{source}: unsupported stage-title TIM2 layout") from exc
    if (
        layout["width"] != WIDTH
        or layout["height"] != HEIGHT
        or layout["image_size"] != IMAGE_SIZE
        or layout["palette_colors"] != PALETTE_COLORS
        or layout["image_type"] != PSMT4
    ):
        raise ValueError(f"{source}: unsupported stage-title TIM2 layout")
    return layout


def decode_indices(payload: bytes, low_nibble_first: bool = True) -> bytes:
    return decode_indexed_payload(payload, WIDTH, HEIGHT, PSMT4, low_nibble_first)


def encode_indices(indices: bytes, low_nibble_first: bool = True) -> bytes:
    return encode_indexed_payload(indices, WIDTH, HEIGHT, PSMT4, low_nibble_first)


def title_palette(data: bytes, layout: dict) -> list[tuple[int, int, int, int]]:
    return indexed_palette(data, layout)


def require_pillow():
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as exc:
        raise SystemExit("stage-title processing requires Pillow installed locally") from exc
    return Image, ImageDraw, ImageFont


def reference_image(data: bytes, low_nibble_first: bool = True):
    Image, _, _ = require_pillow()
    layout = parse_title_tim2(data)
    payload = data[layout["image_offset"]:layout["image_offset"] + layout["image_size"]]
    indices = decode_indices(payload, low_nibble_first)
    palette = title_palette(data, layout)
    rgba = bytearray()
    for index in indices:
        rgba.extend(palette[index])
    return Image.frombytes("RGBA", (WIDTH, HEIGHT), bytes(rgba))


def fit_title_font(
    text: str,
    font_path: Path,
    face_index: int,
    maximum: int,
    minimum: int,
    stroke: int,
    variation: str | None = None,
    available_width: int = WIDTH - 32,
    available_height: int = HEIGHT - 16,
):
    Image, ImageDraw, ImageFont = require_pillow()
    probe = Image.new("L", (WIDTH, HEIGHT), 0)
    draw = ImageDraw.Draw(probe)
    for size in range(maximum, minimum - 1, -1):
        font = ImageFont.truetype(str(font_path), size, index=face_index)
        loc_csv.select_font_variation(font, variation)
        spacing = max(2, size // 8)
        bounds = draw.multiline_textbbox(
            (0, 0), text, font=font, spacing=spacing, align="center", stroke_width=stroke
        )
        width, height = bounds[2] - bounds[0], bounds[3] - bounds[1]
        if width <= available_width and height <= available_height:
            return font, spacing, bounds
    raise ValueError(f"title does not fit at the minimum font size {minimum}")


def render_title_indices(
    text: str,
    font_path: Path,
    face_index: int = 0,
    maximum: int = 52,
    minimum: int = 14,
    stroke: int = 0,
    variation: str | None = None,
    subtitle: str = "",
) -> bytes:
    Image, ImageDraw, _ = require_pillow()
    text = text.replace("\\n", "\n")
    image = Image.new("L", (WIDTH, HEIGHT), 0)
    draw = ImageDraw.Draw(image)
    if subtitle:
        title_height = 78
        font, spacing, bounds = fit_title_font(
            text,
            font_path,
            face_index,
            maximum,
            minimum,
            stroke,
            variation,
            available_height=title_height - 8,
        )
    else:
        title_height = HEIGHT
        font, spacing, bounds = fit_title_font(
            text, font_path, face_index, maximum, minimum, stroke, variation
        )
    width, height = bounds[2] - bounds[0], bounds[3] - bounds[1]
    x = (WIDTH - width) / 2 - bounds[0]
    y = (title_height - height) / 2 - bounds[1]
    draw.multiline_text(
        (x, y), text, font=font, fill=255, spacing=spacing,
        align="center", stroke_width=stroke, stroke_fill=255,
    )
    if subtitle:
        subtitle_font, subtitle_spacing, subtitle_bounds = fit_title_font(
            subtitle,
            font_path,
            face_index,
            min(22, maximum),
            min(12, minimum),
            stroke,
            variation,
            available_height=30,
        )
        subtitle_width = subtitle_bounds[2] - subtitle_bounds[0]
        subtitle_x = (WIDTH - subtitle_width) / 2 - subtitle_bounds[0]
        subtitle_y = 91 - subtitle_bounds[1]
        draw.text(
            (subtitle_x, subtitle_y),
            subtitle,
            font=subtitle_font,
            fill=255,
            stroke_width=stroke,
            stroke_fill=255,
        )
    return bytes(min(15, (value + 8) // 17) for value in image.tobytes())


def stage_label(name: str) -> str:
    upper = name.upper()
    match = re.fullmatch(r"SBTTL_MV([0-9]{2})\.CMP", upper)
    if match:
        return f"STAGE:A-{match.group(1)}"
    match = re.fullmatch(r"SBTTL_TV([0-9]{2})\.CMP", upper)
    if match:
        return f"STAGE:P-{match.group(1)}"
    if upper == "SBTTL_TU00.CMP":
        return "STAGE:00"
    raise ValueError(f"{name}: cannot derive stage label")


def replace_title_image(data: bytes, indices: bytes, low_nibble_first: bool = True) -> bytes:
    parse_title_tim2(data)
    return replace_indexed_image(data, indices, low_nibble_first)


def run_cricmp(executable: Path, mode: str, source: Path, destination: Path) -> None:
    if not executable.is_file():
        raise SystemExit(f"{executable}: CRICMP executable does not exist")
    result = subprocess.run(
        [str(executable), mode, str(source), str(destination)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise SystemExit(
            f"CRICMP {mode} failed for {source} with exit {result.returncode}"
            + (f": {detail}" if detail else "")
        )
    if not destination.is_file():
        raise SystemExit(f"CRICMP {mode} did not create {destination}")
    if mode == "enc":
        with tempfile.TemporaryDirectory(prefix="macross-cricmp-verify-") as temporary_name:
            decoded = Path(temporary_name) / "decoded.bin"
            verify = subprocess.run(
                [str(executable), "dec", str(destination), str(decoded)],
                capture_output=True, text=True, check=False,
            )
            try:
                matches = (
                    verify.returncode == 0
                    and decoded.is_file()
                    and source.read_bytes() == decoded.read_bytes()
                )
            except OSError as exc:
                destination.unlink(missing_ok=True)
                raise SystemExit(f"cannot verify CRICMP output {destination}: {exc}") from exc
            if not matches:
                detail = (verify.stderr or verify.stdout).strip()
                destination.unlink(missing_ok=True)
                raise SystemExit(
                    f"CRICMP encoder did not round-trip {source}"
                    + (f": {detail}" if detail else "")
                )


def stage_files(path: Path) -> list[Path]:
    try:
        files = sorted(
            entry for entry in path.iterdir()
            if entry.is_file() and entry.name.upper().startswith("SBTTL_")
            and entry.suffix.upper() == ".CMP"
        )
    except OSError as exc:
        raise SystemExit(f"{path}: {exc}") from exc
    if not files:
        raise SystemExit(f"{path}: no SBTTL_*.CMP files")
    return files


def write_title_table(path: Path, names: list[str], force: bool) -> None:
    if path.exists() and not force:
        return
    try:
        with path.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=["file", "ja", *LOCALES], delimiter="\t")
            writer.writeheader()
            for name in names:
                writer.writerow({"file": name})
    except (OSError, UnicodeError, csv.Error) as exc:
        raise SystemExit(f"{path}: {exc}") from exc


def cmd_extract(args: argparse.Namespace) -> int:
    files = stage_files(args.input)
    tim2_dir = args.out / "tim2"
    reference_dir = args.out / "reference"
    try:
        tim2_dir.mkdir(parents=True, exist_ok=True)
        reference_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise SystemExit(f"{args.out}: {exc}") from exc
    for source in files:
        tim2 = tim2_dir / (source.name + ".tim2")
        run_cricmp(args.cricmp, "dec", source, tim2)
        try:
            data = tim2.read_bytes()
            parse_title_tim2(data, source)
            image = reference_image(data, not args.high_nibble_first)
            image.save(reference_dir / (source.name + ".png"))
        except (OSError, ValueError) as exc:
            raise SystemExit(str(exc)) from exc
    write_title_table(args.out / "titles.tsv", [path.name for path in files], args.force_titles)
    print(f"{len(files)} title textures and references -> {args.out}")
    return 0


def read_title_table(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    try:
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            columns = list(reader.fieldnames or [])
            if "file" not in columns:
                raise SystemExit(f"{path}: title table requires a 'file' column")
            rows = list(reader)
    except (OSError, UnicodeError, csv.Error) as exc:
        raise SystemExit(f"{path}: {exc}") from exc
    seen = set()
    for line, row in enumerate(rows, 2):
        name = row.get("file", "").strip()
        if not name or Path(name).name != name or not name.upper().startswith("SBTTL_") or not name.upper().endswith(".CMP"):
            raise SystemExit(f"{path}:{line}: invalid stage-title file {name!r}")
        if name.casefold() in seen:
            raise SystemExit(f"{path}:{line}: duplicate stage-title file {name!r}")
        seen.add(name.casefold())
        row["file"] = name
    return columns, rows


def assignment(values: list[str], option: str) -> dict[str, str]:
    result = {}
    for value in values:
        key, separator, item = value.partition("=")
        if not separator or key not in (*LOCALES, "all") or not item:
            raise SystemExit(f"{option}: expected LOCALE=VALUE or all=VALUE, got {value!r}")
        if key in result:
            raise SystemExit(f"{option}: duplicate assignment for {key}")
        result[key] = item
    return result


def source_tim2(root: Path, name: str) -> Path:
    candidates = (
        root / "tim2" / (name + ".tim2"),
        root / (name + ".tim2"),
        root / (name + ".bin"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise SystemExit(f"{root}: no decompressed TIM2 source for {name}")


def read_ui_table(path: Path) -> tuple[list[str], dict[str, dict[str, str]]]:
    try:
        with path.open(encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            columns = list(reader.fieldnames or [])
            if "id" not in columns:
                raise SystemExit(f"{path}: UI table requires an 'id' column")
            rows = list(reader)
    except (OSError, UnicodeError, csv.Error) as exc:
        raise SystemExit(f"{path}: {exc}") from exc
    by_id = {}
    for line, row in enumerate(rows, 2):
        identifier = row.get("id", "").strip()
        if not identifier or identifier in by_id:
            raise SystemExit(f"{path}:{line}: empty or duplicate UI id {identifier!r}")
        row["id"] = identifier
        by_id[identifier] = row
    return columns, by_id


def apply_ui_overrides(
    translations: dict[str, dict[str, str]],
    paths: list[Path],
) -> None:
    for path in paths:
        _, overrides = read_ui_table(path)
        for identifier, override in overrides.items():
            target = translations.get(identifier)
            if target is None:
                raise SystemExit(f"{path}: unknown UI id {identifier!r}")
            for locale in LOCALES:
                if override.get(locale):
                    target[locale] = override[locale]


def read_ui_manifest(path: Path) -> list[dict]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"{path}: {exc}") from exc
    if not isinstance(document, dict) or document.get("version") != 1:
        raise SystemExit(f"{path}: expected UI manifest version 1")
    assets = document.get("assets")
    if not isinstance(assets, list) or not assets:
        raise SystemExit(f"{path}: UI manifest requires a nonempty assets array")
    for asset_index, asset in enumerate(assets):
        container = asset.get("container", "JPN.CVM") if isinstance(asset, dict) else None
        if (
            not isinstance(asset, dict)
            or not isinstance(asset.get("source"), str)
            or not isinstance(asset.get("output"), str)
            or not isinstance(container, str)
            or asset.get("compression", "none") not in ("none", "cricmp")
            or not isinstance(asset.get("regions"), list)
            or not asset["regions"]
        ):
            raise SystemExit(f"{path}: invalid asset {asset_index}")
        if (
            Path(asset["source"]).name != asset["source"]
            or Path(asset["output"]).name != asset["output"]
            or container and Path(container).name != container
        ):
            raise SystemExit(
                f"{path}: asset {asset_index} source, output and container must be names"
            )
        for region_index, region in enumerate(asset["regions"]):
            valid_path = (
                isinstance(region, dict)
                and isinstance(region.get("path"), list)
                and region["path"]
                and all(isinstance(value, int) and value >= 0 for value in region["path"])
            )
            valid_box = (
                isinstance(region.get("box"), list)
                and len(region["box"]) == 4
                and all(isinstance(value, int) for value in region["box"])
                and region["box"][2] > 0
                and region["box"][3] > 0
            )
            clear = region.get("clear")
            valid_clear = (
                isinstance(clear, int)
                and 0 <= clear <= 255
                and "id" not in region
                and "background" not in region
                and "foreground" not in region
            )
            valid_text = (
                clear is None
                and isinstance(region.get("id"), str)
                and isinstance(region.get("background"), int)
                and isinstance(region.get("foreground"), int)
            )
            if (
                not valid_path
                or not valid_box
                or not (valid_clear or valid_text)
            ):
                raise SystemExit(
                    f"{path}: invalid region {region_index} in asset {asset_index}"
                )
    return assets


def text_width(draw, text: str, font) -> int:
    bounds = draw.textbbox((0, 0), text, font=font)
    return bounds[2] - bounds[0]


def split_long_token(draw, token: str, font, available_width: int) -> list[str]:
    pieces = []
    current = ""
    for ch in token:
        candidate = current + ch
        if current and text_width(draw, candidate, font) > available_width:
            pieces.append(current)
            current = ch
        else:
            current = candidate
    if current:
        pieces.append(current)
    return pieces


def wrap_region_text(draw, text: str, font, available_width: int) -> str:
    output = []
    for paragraph in text.replace("\\n", "\n").split("\n"):
        if not paragraph:
            output.append("")
            continue
        words = paragraph.split()
        if len(words) <= 1:
            tokens = list(paragraph) if text_width(draw, paragraph, font) > available_width else [paragraph]
            separator = ""
        else:
            tokens = []
            for word in words:
                if text_width(draw, word, font) > available_width:
                    tokens.extend(split_long_token(draw, word, font, available_width))
                else:
                    tokens.append(word)
            separator = " "
        current = ""
        for token in tokens:
            candidate = token if not current else current + separator + token
            if current and text_width(draw, candidate, font) > available_width:
                output.append(current)
                current = token
            else:
                current = candidate
        if current:
            output.append(current)
    return "\n".join(output)


def fit_region_text(
    text: str,
    font_path: Path,
    face_index: int,
    variation: str | None,
    width: int,
    height: int,
    maximum: int,
    minimum: int,
    padding: int,
    wrap: bool,
    max_lines: int,
):
    Image, ImageDraw, ImageFont = require_pillow()
    probe = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(probe)
    available_width = width - padding * 2
    available_height = height - padding * 2
    if available_width < 1 or available_height < 1:
        raise ValueError("text region padding leaves no drawable area")
    for size in range(maximum, minimum - 1, -1):
        font = ImageFont.truetype(str(font_path), size, index=face_index)
        loc_csv.select_font_variation(font, variation)
        rendered = (
            wrap_region_text(draw, text, font, available_width)
            if wrap else text.replace("\\n", "\n")
        )
        lines = rendered.count("\n") + 1
        if max_lines and lines > max_lines:
            continue
        spacing = max(0, size // 10)
        bounds = draw.multiline_textbbox(
            (0, 0), rendered, font=font, spacing=spacing, align="left"
        )
        rendered_width = bounds[2] - bounds[0]
        rendered_height = bounds[3] - bounds[1]
        if rendered_width <= available_width and rendered_height <= available_height:
            return font, rendered, spacing, bounds
    raise ValueError(
        f"text does not fit {width}x{height} at the minimum font size {minimum}: {text!r}"
    )


def palette_blend_lut(
    palette: list[tuple[int, int, int, int]],
    background: int,
    foreground: int,
) -> list[int]:
    if not (0 <= background < len(palette) and 0 <= foreground < len(palette)):
        raise ValueError("text region palette index is outside the TIM2 palette")
    start, end = palette[background], palette[foreground]
    output = []
    for coverage in range(256):
        target = tuple(
            (start[channel] * (255 - coverage) + end[channel] * coverage + 127) // 255
            for channel in range(4)
        )
        output.append(min(
            range(len(palette)),
            key=lambda index: sum(
                (palette[index][channel] - target[channel]) ** 2
                for channel in range(4)
            ),
        ))
    return output


def clear_ui_region(
    indices: bytearray,
    width: int,
    height: int,
    region: dict,
) -> None:
    x, y, region_width, region_height = region["box"]
    if x < 0 or y < 0 or x + region_width > width or y + region_height > height:
        raise ValueError(f"clear box is outside the {width}x{height} texture")
    value = region["clear"]
    for row in range(y, y + region_height):
        start = row * width + x
        indices[start:start + region_width] = bytes((value,)) * region_width


def render_ui_region(
    indices: bytearray,
    width: int,
    height: int,
    palette: list[tuple[int, int, int, int]],
    region: dict,
    text: str,
    font_path: Path,
    face_index: int,
    variation: str | None,
) -> None:
    x, y, region_width, region_height = region["box"]
    if x < 0 or y < 0 or x + region_width > width or y + region_height > height:
        raise ValueError(f"{region['id']}: text box is outside the {width}x{height} texture")
    background = region["background"]
    foreground = region["foreground"]
    if not (0 <= background < len(palette) and 0 <= foreground < len(palette)):
        raise ValueError(f"{region['id']}: palette index is outside the texture palette")
    for row in range(y, y + region_height):
        start = row * width + x
        indices[start:start + region_width] = bytes((background,)) * region_width

    maximum = region.get("max_size", max(8, region_height - 4))
    minimum = region.get("min_size", min(8, maximum))
    padding = region.get("padding", 1)
    max_lines = region.get("max_lines", 1)
    font, rendered, spacing, bounds = fit_region_text(
        text,
        font_path,
        face_index,
        variation,
        region_width,
        region_height,
        maximum,
        minimum,
        padding,
        bool(region.get("wrap")),
        max_lines,
    )
    Image, ImageDraw, _ = require_pillow()
    mask = Image.new("L", (region_width, region_height), 0)
    draw = ImageDraw.Draw(mask)
    rendered_width = bounds[2] - bounds[0]
    rendered_height = bounds[3] - bounds[1]
    align = region.get("align", "center")
    text_x = padding - bounds[0] if align == "left" else (region_width - rendered_width) / 2 - bounds[0]
    text_y = (
        padding - bounds[1]
        if region.get("valign") == "top"
        else (region_height - rendered_height) / 2 - bounds[1]
    )
    draw.multiline_text(
        (text_x, text_y),
        rendered,
        font=font,
        fill=255,
        spacing=spacing,
        align="left" if align == "left" else "center",
    )
    lut = palette_blend_lut(palette, background, foreground)
    mask_bytes = mask.tobytes()
    for local_y in range(region_height):
        destination = (y + local_y) * width + x
        source = local_y * region_width
        for local_x, coverage in enumerate(mask_bytes[source:source + region_width]):
            if coverage:
                indices[destination + local_x] = lut[coverage]


def indexed_reference_image(data: bytes):
    Image, _, _ = require_pillow()
    layout = parse_indexed_tim2(data)
    payload = data[layout["image_offset"]:layout["image_offset"] + layout["image_size"]]
    indices = decode_indexed_payload(
        payload,
        layout["width"],
        layout["height"],
        layout["image_type"],
    )
    palette = indexed_palette(data, layout)
    rgba = bytes(channel for index in indices for channel in palette[index])
    return Image.frombytes("RGBA", (layout["width"], layout["height"]), rgba)


def cmd_render_ui(args: argparse.Namespace) -> int:
    columns, translations = read_ui_table(args.translations)
    apply_ui_overrides(translations, args.override_table)
    assets = read_ui_manifest(args.manifest)
    locales = args.locales or [locale for locale in LOCALES if locale in columns]
    if not locales:
        raise SystemExit(f"{args.translations}: no requested locale columns")
    for locale in locales:
        if locale not in columns:
            raise SystemExit(f"{args.translations}: no locale column {locale!r}")
    fonts = assignment(args.font, "--font")
    faces = {
        key: nonnegative_int(value)
        for key, value in assignment(args.face_index, "--face-index").items()
    }
    variations = assignment(args.variation, "--variation")
    for locale in locales:
        if locale not in fonts and "all" not in fonts:
            raise SystemExit(f"--font: no font assigned for {locale}")
    for asset in assets:
        source = args.source / asset["source"]
        if not source.is_file():
            raise SystemExit(f"{source}: UI source file does not exist")
        for region in asset["regions"]:
            if "clear" not in region and region["id"] not in translations:
                raise SystemExit(f"{args.translations}: no row for UI id {region['id']!r}")

    rendered = 0
    with tempfile.TemporaryDirectory(prefix="macross-ui-") as temporary_name:
        temporary = Path(temporary_name)
        for locale in locales:
            font_path = Path(fonts.get(locale, fonts.get("all", "")))
            face = faces.get(locale, faces.get("all", 0))
            variation = variations.get(locale, variations.get("all"))
            for asset_index, asset in enumerate(assets):
                source = args.source / asset["source"]
                try:
                    container = source.read_bytes()
                except OSError as exc:
                    raise SystemExit(f"{source}: {exc}") from exc
                grouped = {}
                for region in asset["regions"]:
                    grouped.setdefault(tuple(region["path"]), []).append(region)
                for path, regions in grouped.items():
                    try:
                        leaf = mrg.member_at(container, path)
                        layout = parse_indexed_tim2(leaf, f"{source}:{path}")
                        payload = leaf[
                            layout["image_offset"]:layout["image_offset"] + layout["image_size"]
                        ]
                        indices = bytearray(decode_indexed_payload(
                            payload,
                            layout["width"],
                            layout["height"],
                            layout["image_type"],
                        ))
                        palette = indexed_palette(leaf, layout)
                        for region in regions:
                            if "clear" in region:
                                clear_ui_region(
                                    indices,
                                    layout["width"],
                                    layout["height"],
                                    region,
                                )
                                continue
                            text = translations[region["id"]].get(locale, "").strip()
                            if not text:
                                raise ValueError(
                                    f"{region['id']}: no {locale} UI translation"
                                )
                            render_ui_region(
                                indices,
                                layout["width"],
                                layout["height"],
                                palette,
                                region,
                                text,
                                font_path,
                                face,
                                variation,
                            )
                        localized_leaf = replace_indexed_image(leaf, bytes(indices))
                        container = mrg.replace_member(container, path, localized_leaf)
                        if args.preview_dir:
                            preview = (
                                args.preview_dir / locale
                                / f"{asset_index}-{'-'.join(map(str, path))}.png"
                            )
                            preview.parent.mkdir(parents=True, exist_ok=True)
                            indexed_reference_image(localized_leaf).save(preview)
                    except (OSError, ValueError, mrg.MrgFormatError) as exc:
                        raise SystemExit(f"{asset['source']} [{locale}] {path}: {exc}") from exc

                output_bytes = container
                if asset.get("compression", "none") == "cricmp":
                    unpacked = temporary / f"{locale}-{asset_index}.bin"
                    packed = temporary / f"{locale}-{asset_index}.cmp"
                    try:
                        unpacked.write_bytes(container)
                    except OSError as exc:
                        raise SystemExit(f"{unpacked}: {exc}") from exc
                    run_cricmp(args.cricmp, "enc", unpacked, packed)
                    try:
                        output_bytes = packed.read_bytes()
                    except OSError as exc:
                        raise SystemExit(f"{packed}: {exc}") from exc
                    if not output_bytes.startswith(b"CRICMP"):
                        raise SystemExit(f"{packed}: compressor output has no CRICMP header")

                destination = args.out / "languages" / locale / "files"
                if container := asset.get("container", "JPN.CVM"):
                    destination /= container
                destination /= asset["output"]
                staging = destination.with_suffix(destination.suffix + ".tmp")
                try:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    staging.write_bytes(output_bytes)
                    os.replace(staging, destination)
                except OSError as exc:
                    staging.unlink(missing_ok=True)
                    raise SystemExit(f"{destination}: {exc}") from exc
                rendered += len(asset["regions"])
    print(f"{rendered} localized UI regions -> {args.out}")
    return 0


def cmd_render(args: argparse.Namespace) -> int:
    columns, rows = read_title_table(args.titles)
    locales = args.locales or [locale for locale in LOCALES if locale in columns]
    if not locales:
        raise SystemExit(f"{args.titles}: no requested locale columns")
    for locale in locales:
        if locale not in columns:
            raise SystemExit(f"{args.titles}: no locale column {locale!r}")
    fonts = assignment(args.font, "--font")
    faces = {}
    for key, value in assignment(args.face_index, "--face-index").items():
        try:
            faces[key] = nonnegative_int(value)
        except argparse.ArgumentTypeError as exc:
            raise SystemExit(f"--face-index: {key}={value!r} {exc}") from exc
    variations = assignment(args.variation, "--variation")
    for locale in locales:
        if locale not in fonts and "all" not in fonts:
            raise SystemExit(f"--font: no font assigned for {locale}")
    rendered = 0
    with tempfile.TemporaryDirectory(prefix="macross-title-") as temporary_name:
        temporary = Path(temporary_name)
        for row in rows:
            name = row["file"]
            try:
                original_path = source_tim2(args.source, name)
                original = original_path.read_bytes()
                parse_title_tim2(original, original_path)
            except (OSError, ValueError) as exc:
                raise SystemExit(str(exc)) from exc
            for locale in locales:
                text = row.get(locale, "").strip()
                if not text:
                    continue
                font_path = Path(fonts[locale] if locale in fonts else fonts["all"])
                face = faces.get(locale, faces.get("all", 0))
                variation = variations.get(locale, variations.get("all"))
                try:
                    indices = render_title_indices(
                        text,
                        font_path,
                        face,
                        args.max_size,
                        args.min_size,
                        args.stroke,
                        variation,
                        stage_label(name),
                    )
                    localized = replace_title_image(original, indices, not args.high_nibble_first)
                except (OSError, ValueError) as exc:
                    raise SystemExit(f"{name} [{locale}]: {exc}") from exc
                unpacked = temporary / f"{locale}-{name}.tim2"
                packed = temporary / f"{locale}-{name}"
                try:
                    unpacked.write_bytes(localized)
                except OSError as exc:
                    raise SystemExit(f"{unpacked}: {exc}") from exc
                run_cricmp(args.cricmp, "enc", unpacked, packed)
                destination = args.out / "languages" / locale / "files" / "JPN.CVM" / name
                staging = destination.with_suffix(destination.suffix + ".tmp")
                try:
                    compressed = packed.read_bytes()
                    if not compressed.startswith(b"CRICMP"):
                        raise SystemExit(f"{packed}: compressor output has no CRICMP header")
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    staging.write_bytes(compressed)
                    os.replace(staging, destination)
                except OSError as exc:
                    staging.unlink(missing_ok=True)
                    raise SystemExit(f"{destination}: {exc}") from exc
                rendered += 1
    print(f"{rendered} localized stage-title overlays -> {args.out}")
    return 0


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

    extract = sub.add_parser("extract", help="decompress SBTTL CMP files and export reference PNGs")
    extract.add_argument("input", type=Path, help="directory containing extracted SBTTL_*.CMP files")
    extract.add_argument("-o", "--out", type=Path, required=True, help="ignored local work directory")
    extract.add_argument("--cricmp", type=Path, required=True, help="local CRICMP executable")
    extract.add_argument("--force-titles", action="store_true", help="replace an existing titles.tsv")
    extract.add_argument("--high-nibble-first", action="store_true", help="use alternate 4-bit pixel order")
    extract.set_defaults(func=cmd_extract)

    render = sub.add_parser("render", help="render translated title rows into language overlays")
    render.add_argument("source", type=Path, help="extract output containing decompressed TIM2 files")
    render.add_argument("titles", type=Path, help="local title TSV")
    render.add_argument("-o", "--out", type=Path, required=True, help="localization mod root")
    render.add_argument("--cricmp", type=Path, required=True, help="local CRICMP executable")
    render.add_argument("--locales", nargs="+", choices=LOCALES)
    render.add_argument("--font", action="append", default=[], metavar="LOCALE=PATH",
                        help="font for one locale, or all=PATH (repeatable)")
    render.add_argument("--face-index", action="append", default=[], metavar="LOCALE=INDEX",
                        help="font collection face index (repeatable)")
    render.add_argument("--variation", action="append", default=[], metavar="LOCALE=NAME",
                        help="named variable-font instance, such as all=Regular")
    render.add_argument("--max-size", type=positive_int, default=52)
    render.add_argument("--min-size", type=positive_int, default=14)
    render.add_argument("--stroke", type=nonnegative_int, default=0)
    render.add_argument("--high-nibble-first", action="store_true", help="use alternate 4-bit pixel order")
    render.set_defaults(func=cmd_render)

    ui = sub.add_parser("render-ui", help="render fixed UI regions into language overlays")
    ui.add_argument("source", type=Path, help="directory containing decompressed UI source files")
    ui.add_argument("translations", type=Path, help="local UI translation TSV")
    ui.add_argument("manifest", type=Path, help="UI texture and text-region JSON manifest")
    ui.add_argument("-o", "--out", type=Path, required=True, help="localization mod root")
    ui.add_argument("--cricmp", type=Path, required=True, help="local CRICMP executable")
    ui.add_argument("--override-table", type=Path, action="append", default=[],
                    help="replace nonempty locale cells from an id-keyed TSV")
    ui.add_argument("--locales", nargs="+", choices=LOCALES)
    ui.add_argument("--font", action="append", default=[], metavar="LOCALE=PATH",
                    help="font for one locale, or all=PATH (repeatable)")
    ui.add_argument("--face-index", action="append", default=[], metavar="LOCALE=INDEX",
                    help="font collection face index (repeatable)")
    ui.add_argument("--variation", action="append", default=[], metavar="LOCALE=NAME",
                    help="named variable-font instance, such as zh-Hans=Regular")
    ui.add_argument("--preview-dir", type=Path, help="optional ignored PNG preview directory")
    ui.set_defaults(func=cmd_render_ui)

    args = parser.parse_args(argv)
    if args.command == "render" and args.min_size > args.max_size:
        parser.error("--min-size cannot exceed --max-size")
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
