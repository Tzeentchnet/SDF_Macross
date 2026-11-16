#!/usr/bin/env python3
"""Verify and inventory a user-provided SLPM-65405 disc image."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import sys
from pathlib import Path

from disc_image import (
    DiscFormatError,
    IsoEntry,
    IsoImage,
    open_embedded_iso,
    stream_is_zero,
)
from elf32 import Elf32, ElfFormatError

KNOWN_DISC_SIZE = 1_230_897_152
KNOWN_DISC_SHA256 = "221e4137cc1b197b262c58604143d92d2fdb3dd82d6b464870c6bbf1c68a27df"
KNOWN_ELF_SHA1 = "84ff167ee9612966e5027beabb7b920e7cf18920"
KNOWN_ELF_SIZE = 4_262_380
EXPECTED_BOOT = "cdrom0:\\SLPM_654.05;1"

SYMBOL_PATTERNS = [
    r"(^|_)mrg",
    r"model",
    r"motion",
    r"vertex",
    r"texture",
    r"tim2",
    r"sprfnt",
    r"cvm",
    r"cri",
    r"str_",
    r"navi_",
    r"g_pad_buf",
]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def identify_header(data: bytes) -> str:
    if data.startswith(b"CRICMP"):
        return "CRICMP"
    if data.startswith(b"TIM2"):
        return "TIM2"
    if data.startswith(b"\x7fELF"):
        return "ELF"
    if data.startswith(b"AFS\x00"):
        return "AFS"
    if data.startswith(b"SShd"):
        return "CRI_SSHD"
    if data.startswith(b"\x00\x00\x01\xba"):
        return "MPEG_PROGRAM_STREAM"
    if data.startswith(b"\x00\x00\x01\xb3"):
        return "MPEG_SEQUENCE"
    if data[:2] == b"\x80\x00" and b"(c)CRI" in data[:64]:
        return "CRI_ADX"
    return f"UNKNOWN:{data[:8].hex()}"


def cricmp_header(data: bytes) -> dict | None:
    if not data.startswith(b"CRICMP") or len(data) < 32:
        return None
    choices = []
    for byte_order in ("little", "big"):
        header_size = int.from_bytes(data[0x10:0x14], byte_order)
        unpacked_size = int.from_bytes(data[0x14:0x18], byte_order)
        if 0x18 <= header_size <= 0x100 and unpacked_size < 0x80000000:
            choices.append((byte_order, header_size, unpacked_size))
    selected = choices[0] if len(choices) == 1 else None
    return {
        "version": data[8:16].rstrip(b"\x00").decode("ascii", "replace"),
        "byteOrder": selected[0] if selected else "ambiguous",
        "headerSize": selected[1] if selected else None,
        "uncompressedSize": selected[2] if selected else None,
        "raw10": data[0x10:0x18].hex(),
    }


def read_header(image: IsoImage, entry: IsoEntry, size: int = 64) -> bytes:
    return image.read_at(entry.extent_lba * 2048, min(size, entry.size))


def parse_system_cnf(data: bytes) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw_line in data.decode("ascii", "replace").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        result[key.strip().upper()] = value.strip()
    return result


def entry_record(image: IsoImage, entry: IsoEntry) -> dict:
    header = read_header(image, entry)
    record = {
        "path": entry.path,
        "size": entry.size,
        "extentLba": entry.extent_lba,
        "absoluteOffset": image.absolute_offset(entry),
        "format": identify_header(header),
        "headerHex": header[:32].hex(),
    }
    compressed = cricmp_header(header)
    if compressed:
        record["cricmp"] = compressed
    return record


def analyze_container(outer: IsoImage, entry: IsoEntry, exhaustive_zero_check: bool) -> dict:
    absolute = outer.absolute_offset(entry)
    header = outer.read_at(entry.extent_lba * 2048, min(64, entry.size))
    result = {
        "path": entry.path,
        "size": entry.size,
        "absoluteOffset": absolute,
        "headerHex": header[:32].hex(),
        "cvmh": header.startswith(b"CVMH"),
    }
    try:
        base, inner = open_embedded_iso(outer, entry)
    except DiscFormatError as error:
        result["embeddedIso"] = False
        result["reason"] = str(error)
        if exhaustive_zero_check:
            result["allZero"] = stream_is_zero(outer.stream, absolute, entry.size)
        return result

    files = [item for item in inner.entries() if not item.is_directory]
    records = [entry_record(inner, item) for item in files]
    extensions = collections.Counter(
        Path(item.path).suffix.upper() or "(none)" for item in files
    )
    formats = collections.Counter(record["format"].split(":", 1)[0] for record in records)
    result.update(
        {
            "embeddedIso": True,
            "isoBase": base,
            "volumeId": inner.volume_id,
            "volumeSectors": inner.volume_sectors,
            "fileCount": len(files),
            "extensionCounts": dict(sorted(extensions.items())),
            "formatCounts": dict(sorted(formats.items())),
            "files": records,
        }
    )
    return result


def inspect(
    path: Path,
    exact: bool,
    exhaustive_zero_check: bool,
    allow_patched: bool,
) -> tuple[dict, list[str]]:
    errors: list[str] = []
    stat = path.stat()
    stream, image = IsoImage.open(path)
    try:
        files = [entry for entry in image.entries() if not entry.is_directory]
        outer_records = [entry_record(image, entry) for entry in files]
        try:
            system_cnf_entry = image.find("SYSTEM.CNF")
            system = parse_system_cnf(image.read_entry(system_cnf_entry))
        except KeyError:
            system = {}
            errors.append("SYSTEM.CNF is missing")
        if system.get("BOOT2") != EXPECTED_BOOT:
            errors.append(
                f"unexpected BOOT2: {system.get('BOOT2')!r}, expected {EXPECTED_BOOT!r}"
            )

        try:
            elf_entry = image.find("SLPM_654.05")
            elf_data = image.read_entry(elf_entry)
            elf_sha1 = hashlib.sha1(elf_data).hexdigest()
            elf_sha256 = hashlib.sha256(elf_data).hexdigest()
            if elf_entry.size != KNOWN_ELF_SIZE:
                errors.append(
                    f"ELF size is {elf_entry.size}, expected {KNOWN_ELF_SIZE}"
                )
            if elf_sha1 != KNOWN_ELF_SHA1 and not allow_patched:
                errors.append(
                    f"ELF SHA-1 is {elf_sha1}, expected {KNOWN_ELF_SHA1}"
                )
            elf = Elf32(elf_data).summary(SYMBOL_PATTERNS)
        except KeyError:
            elf_sha1 = elf_sha256 = ""
            elf = {}
            errors.append("SLPM_654.05 is missing")
        except ElfFormatError as error:
            elf_sha1 = elf_sha256 = ""
            elf = {}
            errors.append(f"ELF parse failed: {error}")

        containers = [
            analyze_container(image, entry, exhaustive_zero_check)
            for entry in files
            if entry.path.upper().endswith(".CVM")
        ]
        report = {
            "schemaVersion": 1,
            "source": {
                "path": str(path.resolve()),
                "size": stat.st_size,
                "exactDiscSha256": sha256_file(path) if exact else None,
            },
            "iso9660": {
                "volumeId": image.volume_id,
                "volumeSectors": image.volume_sectors,
                "systemCnf": system,
                "fileCount": len(files),
                "files": outer_records,
            },
            "executable": {
                "sha1": elf_sha1,
                "sha256": elf_sha256,
                "matchesOriginal": elf_sha1 == KNOWN_ELF_SHA1,
                "patchedImageAllowed": allow_patched,
                "elf": elf,
            },
            "containers": containers,
        }
        if stat.st_size != KNOWN_DISC_SIZE:
            errors.append(f"disc size is {stat.st_size}, expected {KNOWN_DISC_SIZE}")
        if exact and report["source"]["exactDiscSha256"] != KNOWN_DISC_SHA256:
            errors.append(
                "disc SHA-256 is "
                f"{report['source']['exactDiscSha256']}, expected {KNOWN_DISC_SHA256}"
            )
        return report, errors
    finally:
        stream.close()


def print_summary(report: dict, errors: list[str]) -> None:
    source = report["source"]
    iso = report["iso9660"]
    executable = report["executable"]
    print(f"Image: {source['path']}")
    print(f"ISO: {iso['volumeId']!r}, {iso['fileCount']} files")
    print(f"BOOT2: {iso['systemCnf'].get('BOOT2', '(missing)')}")
    print(
        "ELF: "
        f"SHA-1 {executable['sha1']}, "
        f"{executable.get('elf', {}).get('symbolCount', 0)} named symbols"
    )
    for container in report["containers"]:
        if container.get("embeddedIso"):
            print(
                f"{container['path']}: ISO base {container['isoBase']:#x}, "
                f"{container['fileCount']} files"
            )
        else:
            suffix = " (all zero)" if container.get("allZero") else ""
            print(f"{container['path']}: no embedded ISO{suffix}")
    if errors:
        print("Verification: FAILED", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
    else:
        print("Verification: OK")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--json", type=Path, help="write the full inventory as JSON")
    parser.add_argument(
        "--exact",
        action="store_true",
        help="also hash the entire image (translated images will intentionally differ)",
    )
    parser.add_argument(
        "--exhaustive-zero-check",
        action="store_true",
        help="read non-ISO CVMs completely to determine whether they are all zero",
    )
    parser.add_argument(
        "--allow-patched",
        action="store_true",
        help="accept a structurally valid image whose executable hash was patched",
    )
    args = parser.parse_args()
    try:
        report, errors = inspect(
            args.image,
            args.exact,
            args.exhaustive_zero_check,
            args.allow_patched,
        )
    except (OSError, DiscFormatError) as error:
        print(f"inspect_game: {error}", file=sys.stderr)
        return 2
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(
            json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
        )
    print_summary(report, errors)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
