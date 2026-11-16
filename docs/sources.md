# Research sources

## Primary local evidence

The primary source for project findings is the user's exact
`SLPM-65405` image, analyzed locally and read-only:

```text
size     1,230,897,152 bytes
SHA-256  221e4137cc1b197b262c58604143d92d2fdb3dd82d6b464870c6bbf1c68a27df
```

No image, executable, extracted file, script, or generated native source is
included in the repository.

Local tools used to establish the findings:

- [`tools/disc_image.py`](../tools/disc_image.py) - bounded ISO 9660/CVM reader
- [`tools/inspect_game.py`](../tools/inspect_game.py) - disc, container, and
  ELF inventory
- [`tools/elf32.py`](../tools/elf32.py) - ELF32 sections and symbols
- [`tools/mrg.py`](../tools/mrg.py) - MRG offset-table parser
- [`tools/inspect_mrg.py`](../tools/inspect_mrg.py) - nested archive
  classification/extraction
- [`tools/disasm_elf.py`](../tools/disasm_elf.py) - optional symbolic
  disassembly

## External sources

| Source | Pinned/reference revision | Used for | License/status |
|---|---|---|---|
| [`plaught-armor/ps-recomp`](https://github.com/plaught-armor/ps-recomp) | `8ab7c5b081fa59f761783787216b067d48120374`, 2026-11-13 | R5900 static recompilation and PS2 Vulkan runtime | GPL-3.0 |
| [`chummy778/Macross-PS2-Fan-Translation-Tooling`](https://github.com/chummy778/Macross-PS2-Fan-Translation-Tooling) | `4339a4485149a52aa2b0633e093511d452885fb5` | Existing English translation, text-format and patch-path corroboration | No explicit license found; external checkout only |
| [`zeesworth/cricmp`](https://github.com/zeesworth/cricmp) | `5faf238dea4157ca6ff72c4b1342bfb90ed0b590` | CRICMP decompression/recompression | LGPL-2.1 |
| [XeNTaX Macross PS2 model discussion archive](https://github.com/XeNTaXBackup/XeNTaXBackup.github.io/blob/main/markdown/Macross%20PS2%20mdl_26090.md) | Archived 2022-2023 discussion | Corroborated GFX2OBJ offsets, 32-byte names, 176-byte nodes, VIF submeshes, and hierarchy importance | Research discussion; no code copied |
| [PS2Docs texture notes](https://github.com/ninjadynamics/PS2Docs/blob/main/ps2textures.md) | Web reference checked 2026-11-16 | TIM2/GS field semantics and PSM cross-check | Consult upstream repository |
| [Amicitia CVM overview](https://amicitia.miraheze.org/wiki/CVM) | Web reference checked 2026-11-16 | General corroboration that CVM is CRI ISO9660/ROFS with a header | Wiki reference |
| [Odin releases](https://github.com/odin-lang/Odin/releases) | `dev-2026-10` | Pinned Windows compiler required by framework | See Odin upstream |

Hashes, dates, and integration policies are machine-readable in
[`recomp.lock.json`](../recomp.lock.json) and
[`game.lock.json`](../game.lock.json).

## How sources were used

External documentation was used to:

- select a maintained framework;
- avoid reimplementing an existing CRICMP codec;
- locate an existing translation effort;
- compare independently observed model framing with earlier research; and
- cross-check standard TIM2/GS terminology.

Game-specific statements were then checked against local bytes wherever
possible. In particular:

- CVM base offsets were found by locating a valid ISO PVD;
- all ISO both-endian fields are compared;
- MRG framing was derived from exact nested boundaries;
- the GFX2OBJ node size is supported by an exact table-to-packet equation;
- TIM2 picture alignment and sizes are supported by exact payload equations;
- VIF commands are decoded from the actual packet stream; and
- translation compatibility was tested by rebuilding and running a patched
  image.

## Claims intentionally kept provisional

No external label was promoted to a confirmed game-specific field without
local evidence. The following remain explicitly provisional:

- meanings inside the 176-byte GFX2OBJ node record;
- secondary model-table fields;
- VU output/vertex semantics;
- TIM2 pixel swizzle and palette permutation for this engine;
- motion channel encoding;
- collision record meanings;
- AUTH/MRGA track formats; and
- catalogue/mission logical records.

This separation matters for a future Blender importer: a parser that accepts
unknown fields is safer than one that silently assigns an attractive but
incorrect interpretation.

## Copyright and attribution

No code was copied from the historical model-research discussion. Format
facts, byte offsets, and interoperability observations are recorded in original
wording.

The translation repository's absence of an explicit license is treated as “no
permission to vendor,” not as permission by omission.
