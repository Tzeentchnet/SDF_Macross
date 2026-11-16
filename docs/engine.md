# Engine findings

## Summary

The game uses a Sega AM2 PlayStation 2 engine whose rendering layer identifies
itself as:

```text
GFX2 Ver.0.958R PS2MCW Build:Aug 27 2003 22:40:59
```

Model and animation signatures include:

```text
GFX2OBJ/PS2;0200
GFX2OBJ/PS2;0100
GFX2GMOT0300
```

The executable was built with:

```text
MW MIPS C Compiler (2.4.1.01)
PlayStation2
```

No public source engine has been identified. “GFX2” is therefore used as the
name exposed by the binary itself, not as a claim about a separately released
engine.

## Main executable

| Property | Value |
|---|---|
| File | `SLPM_654.05` |
| Format | ELF32 |
| Endianness | Little-endian |
| Machine | MIPS / PS2 R5900 |
| Entry point | `0x00100008` |
| Main load file offset | `0x80` |
| Main load virtual address | `0x00100000` |
| Main load file size | `2,939,136` bytes |
| Main load memory size | `7,103,360` bytes |
| Named `.symtab` entries | `17,684` |
| Translation tool's usable symbols | `17,423` |

The full symbol table is a major advantage. It supplies boundaries and names
for gameplay, rendering, text, sound, and platform functions that would
otherwise require extensive control-flow recovery.

Representative symbol families and strings found in the ELF include:

- `GFX2*` - object, draw, material, texture, and scene operations;
- `MOT_*` and `_am2mMotionCalc` - motion expansion and evaluation;
- `STR_*` - string lookup and display attributes;
- `NAVI_*` - radio/portrait/caption presentation;
- `SND_*` - voice and sound playback;
- `SPRFNT_*` and `utl_cros_font_load` - sprite-font handling;
- `MIS_*` - mission logic;
- `g_pad_buf` and `padRead` - PS2 controller state; and
- CRI/Sofdec/ADX middleware version and entry-point strings.

## Runtime architecture

The native port does not replace every PS2 subsystem with game-specific PC
code. It combines statically translated game functions with the generic
`ps-recomp` runtime:

```text
SLPM_654.05
  -> R5900 function discovery from ELF symbols
  -> Odin source, one native procedure per guest function
  -> native Windows x86-64 executable
  -> ps-recomp PS2 runtime
       - guest memory and kernel
       - DMA and GIF
       - Vulkan GS renderer
       - VU execution
       - IOP/HLE and interpreter
       - IPU/video services
       - SDL2 host window/input/audio
```

The current generation step emits:

- 8,684 recompiled functions;
- 15 generated packages; and
- approximately 31.57 MiB of generated source in 17 files.

The final native executable is approximately 28.9 MiB before distribution
packaging.

## Rendering path

The game builds PS2-native rendering data:

1. GFX2 scene/model code selects nodes, materials, and draw packets.
2. Model packet data contains VIF command streams.
3. VIF UNPACK commands populate VU memory.
4. VU programs transform/prepare vertices.
5. GIF packets configure and feed the GS.
6. The `ps-recomp` GS implementation renders those operations through
   Vulkan 1.3.

The Vulkan renderer is therefore below the original engine's packet-building
layer. Asset conversion is not required merely to run the game, although
decoding those assets is required for a Blender importer.

The checked-in [`settings.tsv`](../settings.tsv) uses `SW=0`, and
[`tools/run.ps1`](../tools/run.ps1) sets `MACROSS_SW=0` explicitly. The
verified run logged a GPU renderer and selected an NVIDIA GeForce RTX 5070.

## Models, hierarchy, and motion

Model archives generally contain separate branches for:

- a list/manifest;
- one or more `GFX2OBJ` model leaves;
- a motion list followed by skeleton and motion records;
- TIM2 textures; and
- for some enemies, collision data.

The `GFX2OBJ` model is not a conventional desktop mesh with a flat vertex
array and face-index table. It combines:

- named metadata records;
- a secondary metadata table;
- a fixed-size node table; and
- VIF packets consumed by PS2 vector-unit code.

Historical experiments that ignored the hierarchy produced overlapping model
parts and flicker. A correct importer must resolve the 176-byte node records
and transformations before joining or displaying submeshes.

Motion archives use a manifest whose first item is normally a `.bon` skeleton,
followed by `.mot` clips. The file framing is known, but channel compression,
interpolation, and node binding remain to be decoded. See
[File formats](file-formats.md).

## Text and UI

Text is split across three mechanisms:

1. `JPN.CVM/BOOTDAT.CMP` record strings;
2. offset-table string pools in the same decompressed file; and
3. 52 in-place Shift-JIS system messages in the executable.

The sprite font already contains usable Latin glyphs. Dialogue, narration, and
radio text can therefore be translated without replacing the font.

Some visible Japanese is art, not text. Stage-title cards, logos, and portions
of the 2D menu are TIM2 textures and need a separate image-editing pipeline.

The radio-caption path already exists in the game. A character in the
six-byte record ID controls whether the engine draws the caption, while timing
comes from the associated voice playback duration.

## Audio and video

Audio uses CRI middleware:

- loose ADX streams for music/dialogue;
- an AFS archive containing 2,926 voice entries;
- stage sound-bank data inside mission archives; and
- runtime calls such as `SND_GetVoicePlayTime`.

Movies are Sofdec `.SFD` files stored in `MOV.CVM`. Their streams begin as
MPEG program streams. The PS2 runtime's IPU and IOP paths remain important for
correct movie playback even though the main EE program is statically
recompiled.

## Confidence and limits

Confirmed findings come from the exact supported image, its symbols, bounded
parsers, and successful native runs. Important limits remain:

- a 600-frame boot run is not a full compatibility test;
- significant IOP code is still interpreted;
- runtime-created VU microcode has not yet been captured for static inclusion;
- one SIF call is unimplemented;
- model packet semantics are not yet sufficiently decoded for Blender; and
- several authoring, mission, collision, and animation fields remain unknown.

Unknown fields are documented as unknown rather than assigned meanings from a
single sample.
