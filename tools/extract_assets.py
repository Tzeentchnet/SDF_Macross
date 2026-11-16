#!/usr/bin/env python3
"""Extract files from one game CVM for local reverse engineering."""

from __future__ import annotations

import argparse
import fnmatch
import os
import subprocess
import sys
from pathlib import Path

from disc_image import DiscFormatError, IsoImage, open_embedded_iso


def safe_destination(root: Path, member: str) -> Path:
    parts = [part for part in member.replace("\\", "/").split("/") if part]
    if not parts or any(part in (".", "..") for part in parts):
        raise ValueError(f"unsafe member path: {member!r}")
    destination = root.joinpath(*parts).resolve()
    if os.path.commonpath((root.resolve(), destination)) != str(root.resolve()):
        raise ValueError(f"member escapes destination: {member!r}")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extracts copyrighted assets only to an ignored local directory."
    )
    parser.add_argument("image", type=Path)
    parser.add_argument("container", help="outer ISO path, for example BIN.CVM")
    parser.add_argument("output", type=Path)
    parser.add_argument("--pattern", default="*", help="case-insensitive glob")
    parser.add_argument("--cricmp", type=Path, help="optional CRICMP executable")
    parser.add_argument("--decompress-cmp", action="store_true")
    args = parser.parse_args()

    if args.decompress_cmp and not args.cricmp:
        parser.error("--decompress-cmp requires --cricmp")
    stream = None
    try:
        stream, outer = IsoImage.open(args.image)
        container = outer.find(args.container)
        _, inner = open_embedded_iso(outer, container)
        selected = [
            entry
            for entry in inner.entries()
            if not entry.is_directory
            and fnmatch.fnmatch(entry.path.upper(), args.pattern.upper())
        ]
        if not selected:
            print("extract_assets: no files matched", file=sys.stderr)
            return 1
        for entry in selected:
            destination = safe_destination(args.output, entry.path)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(inner.read_entry(entry))
            if args.decompress_cmp and destination.suffix.upper() == ".CMP":
                unpacked = destination.with_suffix(destination.suffix + ".bin")
                completed = subprocess.run(
                    [str(args.cricmp), "dec", str(destination), str(unpacked)],
                    check=False,
                )
                if completed.returncode != 0:
                    raise RuntimeError(
                        f"CRICMP failed for {entry.path} with "
                        f"exit code {completed.returncode}"
                    )
        print(f"Extracted {len(selected)} files to {args.output.resolve()}")
        return 0
    except (OSError, KeyError, ValueError, DiscFormatError, RuntimeError) as error:
        print(f"extract_assets: {error}", file=sys.stderr)
        return 2
    finally:
        if stream:
            stream.close()


if __name__ == "__main__":
    raise SystemExit(main())
