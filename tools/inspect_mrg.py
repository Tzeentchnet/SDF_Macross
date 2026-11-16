#!/usr/bin/env python3
"""Print or extract the nested MRG tree of a decompressed game asset."""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

from mrg import MrgArchive, MrgMember, printable_prefix, try_parse_mrg


def leaf_kind(data: bytes) -> str:
    if data.startswith(b"GFX2OBJ/PS2;"):
        return "GFX2OBJ model"
    if data.startswith(b"TIM2"):
        return "TIM2 texture"
    if data.startswith(b"MRGA"):
        return "MRGA authoring record"
    if data.startswith(b"AUTH"):
        return "AUTH camera/authoring data"
    if data.startswith(b"CLS "):
        return "collision data"
    return "binary/text leaf"


def walk(
    data: bytes,
    logical_path: str,
    *,
    depth: int,
    max_depth: int,
    output: Path | None,
) -> None:
    indent = "  " * depth
    archive: MrgArchive | None = try_parse_mrg(data) if depth < max_depth else None
    if archive:
        print(
            f"{indent}{logical_path}: MRG count={archive.count} "
            f"header={archive.header_size:#x} size={len(data):#x}"
        )
        for member in archive.members:
            walk(
                member.data,
                f"{logical_path}/{member.index:03d}",
                depth=depth + 1,
                max_depth=max_depth,
                output=output,
            )
        return

    digest = hashlib.sha1(data).hexdigest()[:12]
    print(
        f"{indent}{logical_path}: {leaf_kind(data)}, size={len(data):#x}, "
        f"sha1={digest}, head={data[:16].hex()}, text={printable_prefix(data)}"
    )
    if output:
        destination = output.joinpath(*logical_path.split("/")).with_suffix(".bin")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("asset", type=Path)
    parser.add_argument("--max-depth", type=int, default=8)
    parser.add_argument("--extract", type=Path)
    args = parser.parse_args()
    try:
        data = args.asset.read_bytes()
        walk(
            data,
            args.asset.name,
            depth=0,
            max_depth=args.max_depth,
            output=args.extract,
        )
        return 0
    except OSError as error:
        print(f"inspect_mrg: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
