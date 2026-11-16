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

## Rendering and presentation

The checked-in [`settings.tsv`](../settings.tsv) selects the software renderer
for reliable full-speed play. Vulkan remains available for internal-resolution
scaling and FSR 1. [`tools/run.ps1`](../tools/run.ps1) can select either path
without opening the launcher.

### Measured performance and audio

The following optimized-build measurements used an NVIDIA GeForce RTX 5070,
a 1280x960 window, and the same deterministic intro-cutscene interval. Each
row is the 300-frame report ending at presented frame 1500:

| Renderer | Internal/output scaling | FPS | Work avg / p95 | Present avg | Audio dry | Average audio speed |
|---|---|---:|---:|---:|---:|---:|
| Software | Native, SDL presentation | 59.9 | 12.93 / 15.50 ms | 0.72 ms | 0 | 100% |
| Vulkan | 1x, linear | 52.6 | 18.92 / 19.47 ms | 11.50 ms | 0 | 87% |
| Vulkan | 1x, FSR 1 | 52.1 | 19.10 / 19.72 ms | 11.66 ms | 0 | 86% |
| Vulkan | 2x, FSR 1 | 51.0 | 19.54 / 20.33 ms | 12.01 ms | 0 | 84% |
| Vulkan | 4x, linear downscale | 45.8 | 21.78 / 22.10 ms | 14.18 ms | 0 | 76% |

The software renderer is therefore the current recommendation when smooth
motion and unmodified audio pitch matter more than supersampling. Vulkan
remains below the console's 59.94 Hz rate in this scene even at 1x.

The host estimates sustained emulation speed over disjoint four-field groups
and feeds it to the existing cubic audio resampler. A single moderately slow
group is treated as scheduling jitter unless the next group is also slow;
speeds below 80% take effect immediately so the 50 ms latency budget cannot
run dry while waiting for confirmation. Slow Vulkan modes remain synchronized
by playing audio more slowly and at a lower pitch. This is not pitch-preserving
time stretch, and it does not make a slow renderer full speed.

The earlier rolling estimator reused each late field in four overlapping
windows and recovered more slowly than it reacted. In the full-speed software
path, occasional 18-26 ms frames therefore lowered the resampling step long
after the queue had recovered. The overfilled queue then discarded one or two
complete 800/801-sample batches per five-second reporting interval, producing
music stutters even though the dry-event count stayed at zero. Initial checks
of the raw pre-resampler capture found no clipping or long silence, but those
checks were not sufficient to rule out the source mixer.

Paced playback also preserves transient catch-up audio instead of discarding a
batch as soon as the queue exceeds the old two-frame slack. The queue may grow
to the supported 250 ms maximum before a hard safety drop; fast-forward keeps
its target-based dropping behavior so it cannot leave delayed sound behind.

With disjoint timing groups and continuous paced queuing, the same 1,800-frame
software route held 59.9 FPS, 100% audio speed, and zero dropped batches in
every active-music interval. A slow Vulkan 1x run still adapted to 85% at
51.1 FPS and recorded neither a dry event nor a dropped batch.

Detailed adjacent-sample analysis later found a separate source-level fault in
the main-menu music. That route uses the game's CRI driver to feed SPU2 through
`sceSdBlockTrans`; FMOD and the framework's ADX HLE ring are inactive. The
runtime mixed a future 800/801-frame host batch by rereading the live IOP
double buffer. A batch could cross into a 512-frame half before its interrupt
handler refilled it, or reread a half after a later refill had overwritten it.
The result was stale or reordered PCM at half-buffer boundaries.

The patched SPU2 path captures the initial ADMA buffer into a bounded stereo
queue, exposes each refilled half only after its interrupt handler returns, and
rejects callbacks from an older stopped transfer by generation. The queue
preserves stream order while larger source buffers are captured progressively;
loop underflows are counted and covered by the SPU regression. In the
deterministic menu capture, adjacent-sample jumps above 8,000 fell from 53 to
zero, jumps above 6,000 fell from 106 to zero, and the maximum jump fell from
15,423 to 5,678. The corrected output kept one constant 1,312-sample alignment
offset throughout every tested active segment instead of accumulating further
delay, so the stream no longer drifts slower over time.

### Vulkan GS ordering fix

GS local memory was previously accessed by the fragment shader through a
physical buffer-reference pointer. On the tested RTX 5070, fragment-shader
pixel interlock did not reliably make those storage writes visible to later
overlapping primitives. The result was nondeterministic black pixels that
moved even while the game was paused.

The fragment path now binds GS memory as a conventional coherent Vulkan
storage-buffer descriptor. Compute shaders retain buffer-device-address
access. Repeated frame-7200 captures are byte-identical at both 1x and 4x, and
visual inspection of both captures shows the aircraft without the moving
black speckles. AMD and Intel validation remains open.

The scanout buffer is also device-local. Host-visible readback is allocated
and copied only for screenshots, thumbnails, and other CPU consumers rather
than every presented frame.

### FSR 1 and temporal-upscaling limits

The Vulkan presentation path offers AMD FidelityFX Super Resolution 1.0.2:
EASU spatial upscaling followed by RCAS sharpening. It operates only on the
current color image, so it fits the PS2 GS output available here. When either
internal dimension exceeds the centered 4:3 presentation target, the renderer
uses the existing linear downscale instead.

FSR 3 temporal upscaling, DLSS Super Resolution, FSR 3 Frame Interpolation,
and DLSS Frame Generation are not exposed. The current GS renderer does not
produce the required conventional depth surface, per-pixel motion vectors,
temporal jitter/history, camera transforms, reactive masks, or UI separation.
It also lacks the presentation pacing and latency integration required for
generated frames. AMD's integration guide warns that missing motion vectors
cause ghosting and that poor temporal inputs amplify artifacts in interpolated
frames. Frame generation would also be the wrong first optimization while
real frames in heavy Vulkan scenes remain below 60 FPS.

The public projects surveyed do not establish a PS2 precedent for those
features:

- PCSX2 exposes FidelityFX Contrast Adaptive Sharpening, not FSR temporal
  reconstruction.
- RPCS3 and Xenia contain FSR 1 EASU/RCAS presentation implementations.
- RT64/Zelda64Recomp matches draw calls, interpolates transforms, and
  re-renders them; it is not FSR 3 or DLSS optical-flow frame generation.
- No public PS2 static recompilation or emulator implementation of FSR 3,
  DLSS Super Resolution, FSR 3 Frame Interpolation, or DLSS Frame Generation
  was found in the surveyed sources.

Adding DLSS through Streamline would also require a separate compatibility,
redistribution, and GPL review before any implementation decision. Source
links and revisions are recorded in [Research sources](sources.md).

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
