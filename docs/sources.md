# Research sources

## Primary local evidence

The primary source for project findings is the user's exact
`SLPM-65405` image, analyzed locally and read-only:

```text
size     1,230,897,152 bytes
SHA-256  221e4137cc1b197b262c58604143d92d2fdb3dd82d6b464870c6bbf1c68a27df
```

No image, executable, extracted file, publisher script, private fan CSV, or
generated native source is included in the repository. The 47-string
[`en-system` table](../localization/en-system/strings.csv), multilingual
release CSV, and runtime translation functions are project-created release
content. The [`en-fan` manifest](../localization/en-fan/mod.tsv) contains no
fan text; the publisher export and any locally imported third-party fan CSV
remain ignored and outside the release.

Local tools used to establish the findings:

- [`tools/disc_image.py`](../tools/disc_image.py) - bounded ISO 9660/CVM reader
- [`tools/inspect_game.py`](../tools/inspect_game.py) - disc, container, and
  ELF inventory
- [`tools/elf32.py`](../tools/elf32.py) - ELF32 sections and symbols
- [`tools/mrg.py`](../tools/mrg.py) - MRG offset-table parser
- [`tools/inspect_mrg.py`](../tools/inspect_mrg.py) - nested archive
  classification/extraction
- [`tools/disasm_elf.py`](../tools/disasm_elf.py) - optional symbolic
  disassembly with validated file-backed ranges and per-word fallback
- [`tools/loc_csv.py`](../tools/loc_csv.py) - local CSV import, merge, strip,
  and validation
- [`tests`](../tests) - synthetic parser/trust, disassembler, localization,
  patch-state, and smoke-contract fixtures; the separate smoke test requires
  the user's exact original image and a Vulkan device

## External sources

| Source | Pinned/reference revision | Used for | License/status |
|---|---|---|---|
| [`plaught-armor/ps-recomp`](https://github.com/plaught-armor/ps-recomp) | `8ab7c5b081fa59f761783787216b067d48120374`, 2026-11-13 | R5900 static recompilation and PS2 Vulkan runtime | GPL-3.0 |
| [AMD FidelityFX FSR 1](https://github.com/GPUOpen-Effects/FidelityFX-FSR/tree/a21ffb8f6c13233ba336352bdff293894c706575) | `a21ffb8f6c13233ba336352bdff293894c706575`, v1.0.2 | EASU/RCAS shader headers used by Vulkan presentation | MIT; license vendored with the framework patch |
| [`chummy778/Macross-PS2-Fan-Translation-Tooling`](https://github.com/chummy778/Macross-PS2-Fan-Translation-Tooling) | `4339a4485149a52aa2b0633e093511d452885fb5` | Existing English translation, text-format and patch-path corroboration | No explicit license found; external checkout only |
| [`zeesworth/cricmp`](https://github.com/zeesworth/cricmp) | `5faf238dea4157ca6ff72c4b1342bfb90ed0b590` | CRICMP decompression/recompression | LGPL-2.1 |
| [XeNTaX Macross PS2 model discussion archive](https://github.com/XeNTaXBackup/XeNTaXBackup.github.io/blob/main/markdown/Macross%20PS2%20mdl_26090.md) | Archived 2022-2023 discussion | Corroborated GFX2OBJ offsets, 32-byte names, 176-byte nodes, VIF submeshes, and hierarchy importance | Research discussion; no code copied |
| [PS2Docs texture notes](https://github.com/ninjadynamics/PS2Docs/blob/main/ps2textures.md) | Web reference checked 2026-11-16 | TIM2/GS field semantics and PSM cross-check | Consult upstream repository |
| [Amicitia CVM overview](https://amicitia.miraheze.org/wiki/CVM) | Web reference checked 2026-11-16 | General corroboration that CVM is CRI ISO9660/ROFS with a header | Wiki reference |
| [Odin releases](https://github.com/odin-lang/Odin/releases) | `dev-2026-10` | Pinned Windows compiler required by framework | See Odin upstream |

## Upscaling and frame-interpolation survey

These upstream sources were checked on 2026-11-16 to distinguish spatial
upscaling from temporal reconstruction and frame interpolation:

- [PCSX2's graphics settings](https://github.com/PCSX2/pcsx2/blob/79929f01750fdc8185810968c934bd3923d099a7/pcsx2-qt/Settings/GraphicsSettingsWidget.cpp)
  describe FidelityFX Contrast Adaptive Sharpening.
- [RPCS3's FSR 1 shader](https://github.com/RPCS3/rpcs3/blob/fb6737b1c8306ceeccb53b7fa051acfc9e641cd7/rpcs3/Emu/RSX/Program/Upscalers/FSR1/fsr_ubershader.glsl)
  and [Xenia's FSR EASU shader](https://github.com/xenia-project/xenia/blob/95a5c3ee250f80c3b9d139658649d9ffb6db3eec/src/xenia/ui/shaders/guest_output_ffx_fsr_easu.ps.xesl)
  provide spatial FSR 1 precedents.
- [RT64's frame-interpolation description](https://github.com/rt64/rt64/blob/d9817c68ffd7328cd0af383af124971489366e18/README.md#frame-interpolation)
  says matched calls receive interpolated transforms and are processed again.
- [AMD's FSR 3 integration documentation](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/main/Kits/FidelityFX/docs/techniques/super-resolution-upscaler.md)
  documents motion vectors, depth-related inputs, temporal data, and reactive
  masks.
- [NVIDIA's Streamline DLSS guide](https://github.com/NVIDIA-RTX/Streamline/blob/main/docs/ProgrammingGuideDLSS.md)
  and [DLSS Frame Generation guide](https://github.com/NVIDIA-RTX/Streamline/blob/main/docs/ProgrammingGuideDLSS_G.md)
  document NVIDIA's integration path.

Repository and code searches found no public PS2 static recompilation or
emulator implementation of FSR 3 temporal upscaling, DLSS Super Resolution,
FSR 3 Frame Interpolation, or DLSS Frame Generation. That is a bounded survey,
not proof that no private or unindexed implementation exists.

Hashes, dates, and integration policies are machine-readable in
[`recomp.lock.json`](../recomp.lock.json) and
[`game.lock.json`](../game.lock.json). The ordered local modifications to the
locked framework are listed in
[`patches/ps-recomp/series`](../patches/ps-recomp/series).

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
- the ISO parser compares the PVD volume size and logical block size, plus
  each parsed directory record's extent, data length, and volume sequence,
  in both byte orders; it does not claim to validate every ISO both-endian
  field;
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
permission to vendor,” not as permission by omission. Exported publisher text
and fan-derived tables remain local even when a CSV conversion removes the
Japanese column.
