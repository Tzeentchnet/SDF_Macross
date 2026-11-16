# File formats and Blender-importer notes

This document records formats found in the exact Japanese `SLPM-65405` image.
It is intended to support future interoperable tooling, especially a Blender
importer. It does not contain publisher assets.

## Confidence labels

- **Confirmed** - independently parsed from multiple structures or validated by
  exact size/boundary relationships.
- **Corroborated** - confirmed locally and consistent with a named external
  source.
- **Provisional** - repeatable observation whose semantic meaning is not yet
  proven.
- **Unknown** - deliberately not assigned a meaning.

Unless noted otherwise, game-specific integers are little-endian. ISO 9660
stores several fields twice, once little-endian and once big-endian.

## Disc layout

The outer image is ISO 9660 with 2,048-byte sectors and 11 root files.

| File | Size | Purpose |
|---|---:|---|
| `0FLIST.DIR` | 37 | Lists `adxj.cvm`, `bin.cvm`, `jpn.cvm`, and `mov.cvm` |
| `ADXJ.CVM` | 478,025,728 | Loose ADX audio and an AFS voice archive |
| `BIN.CVM` | 252,286,976 | Models, motions, stages, missions, and sound banks |
| `CRSDAT.MRG` | 1,329,532 | Root crosshair/common UI archive |
| `ETC.CVM` | 208,666,624 | All-zero placeholder; absent from `0FLIST.DIR` |
| `IOPRP300.IMG` | 266,707 | IOP module image |
| `JPN.CVM` | 23,820,288 | Japanese script and region UI assets |
| `MODULES.MRG` | 562,876 | Manifest plus 11 IOP ELF modules |
| `MOV.CVM` | 320,571,392 | Four Sofdec movies |
| `SLPM_654.05` | 4,262,380 | Main EE ELF |
| `SYSTEM.CNF` | 58 | PS2 boot configuration |

`SYSTEM.CNF` selects:

```text
cdrom0:\SLPM_654.05;1
```

The bounded parser in [`tools/disc_image.py`](../tools/disc_image.py) validates
both byte orders of the PVD volume size and logical block size, and each
parsed directory record's extent, data length, and volume sequence. It does
not validate every both-endian field in ISO 9660.

## CVM / CVMH containers

**Confidence: confirmed and externally corroborated.**

The four active `.CVM` files are CRI CVM/ROFS containers:

```text
+0x0000  CVMH header and reserved area
+0x1800  embedded ISO 9660 image
```

The normal ISO primary volume descriptor is at sector 16 relative to the
embedded image:

```text
embedded PVD start   = 0x1800 + 16 * 0x800 = 0x9800
CD001 text position  = 0x9801
```

No encryption was found. The inner files can be read by applying the base
offset and using ordinary ISO 9660 directory records.

The external translation project additionally identifies the CVMH byte-size
field at `+0x20` as big-endian and updates it when rebuilding a container.
That field should be revalidated against more CVM-producing tools before a
general-purpose writer is published.

Inventory:

| Container | Files | Notes |
|---|---:|---|
| `ADXJ.CVM` | 115 | 114 loose ADX files plus `MCRSVOICE.AFS` |
| `BIN.CVM` | 502 | 310 CRICMP files plus uncompressed archives/data |
| `JPN.CVM` | 70 | 64 CRICMP files, MRG/TIM2 data, icons |
| `MOV.CVM` | 4 | SFD/MPEG program streams |
| `ETC.CVM` | 0 | No embedded ISO; exhaustive scan is all zero |

The [runtime overlay](localization.md) can replace existing root-level files
inside a CVM without editing the image. It validates container and extent
boundaries, prepares all replacements before installing the read hook, and
serves updated directory/volume metadata in both byte orders. A larger file
can move only to verified, unallocated zero sectors in or immediately after
the CVM; insufficient safe space causes the overlay to fail rather than
overwrite another extent.

## CRICMP

**Confidence: confirmed; codec externally supplied.**

Observed header:

```text
Offset  Size  Type     Meaning
0x00    8     char[8]  "CRICMP\0\0"
0x08    8     char[8]  version, observed "2.10\0\0\0\0"
0x10    4     u32 LE   header size, observed 0x20
0x14    4     u32 LE   uncompressed size
0x18    8     bytes    reserved/unknown in observed files
0x20    ...   bytes    compressed stream
```

All 374 compressed assets found across `BIN.CVM` and `JPN.CVM` decompress to
the exact `uncompressed size` recorded in their headers.

CRICMP is a custom LZ-family stream. Literal bytes can make fragments of text
visible inside compressed data; those fragments are not stable file offsets.
Use the pinned LGPL-2.1
[`zeesworth/cricmp`](https://github.com/zeesworth/cricmp) codec rather than
editing compressed bytes directly.

## MRG offset-table archives

**Confidence: confirmed across root, model, texture, motion, mission, and
catalogue archives.**

MRG has no magic. It is identified structurally:

```text
Offset  Size              Type      Meaning
0x00    4                 u32 LE    member_count = N
0x04    4                 u32 LE    first member offset / header size
0x08    4 * (N - 1)       u32 LE[]  offsets of members 1 through N-1
...     to header size    bytes     header padding/metadata
header  variable          bytes     member 0
```

Member starts are therefore:

```text
starts[0] = header_size
starts[1..N-1] = offset_table[0..N-2]
```

Member end is the next start, or archive EOF for the final member.

Validated invariants used by [`tools/mrg.py`](../tools/mrg.py):

- `1 <= member_count <= 4096`;
- header holds the complete offset table;
- header and member offsets are 16-byte aligned;
- offsets are in bounds, unique, and strictly increasing; and
- padding before member 0 is not assumed to be zero.

MRG member slices include alignment padding. A child format with an internal
`total_size` must use that logical size rather than treating every trailing
byte as payload.

Many first members are ASCII manifests such as `mrg.lst`, `mot.lst`, or
`tex.lst`. Blank lines and `_` placeholders are meaningful to member
association and must not be discarded casually.

MRG is used beyond `.MRG` extensions. Confirmed structurally valid examples
include:

- decompressed `.CMP` model bundles;
- `.MSD` mission/stage data;
- `.CHRW` and `.CAT` catalogues;
- root `CRSDAT.MRG`; and
- `MODULES.MRG`.

### Example: VF-1J asset bundle

A decompressed `VF1J_AC.CMP` contains three top-level branches:

```text
root
|- model archive
|  |- list
|  |- five GFX2OBJ/PS2;0200 leaves
|  `- one GFX2OBJ/PS2;0100 leaf
|- motion archive
|  |- list
|  `- two motion-related records
`- texture archive
   |- list
   `- three TIM2 pictures
```

Enemy bundles add a collision archive.

## GFX2OBJ models

**Container framing: confirmed. Field semantics: partial/provisional.**

### File header

The first 16 bytes are an ASCII version signature:

```text
GFX2OBJ/PS2;0200
GFX2OBJ/PS2;0100
```

Four little-endian offsets follow:

```text
Offset  Size  Meaning
0x00    16    version signature
0x10    4     name table offset
0x14    4     secondary table offset
0x18    4     node table offset
0x1C    4     VIF/packet-data offset
```

For the inspected `VF1J_OPA_000` sample:

```text
name table       0x0020
secondary table  0x0064
node table       0x00B0
packet data      0x49B0
```

Offsets are file-relative.

### Name table

Observed layout:

```text
+0x00  u32 LE  record count
+0x04  record[record_count]
```

Each observed record is 32 bytes. It contains a NUL-terminated ASCII name and
trailing metadata. In the sample the names are `VF1J_OPA_000` and `cano_00`.
The trailing fields vary and are not yet assigned semantics.

The table ends exactly at the secondary-table offset:

```text
0x20 + 4 + 2 * 32 = 0x64
```

### Secondary table

The sample begins with `u32 count = 2` and occupies `0x4C` bytes before the
node table. Two 36-byte records fit that boundary exactly:

```text
4 + 2 * 36 = 0x4C
```

The record size is therefore strongly supported for this version, but the
fields and relationship to names/materials are still provisional.

### Node table

For the inspected sample:

- node-table header begins at `0xB0`;
- node count is a `u32` at node-table-relative `+0x1C`;
- count is 106 (`0x6A`);
- records begin at file offset `0xD0`; and
- each record is 176 bytes (`0xB0`).

The boundary is exact:

```text
0xD0 + 106 * 0xB0 = 0x49B0
```

This is one of the strongest framing results. It does **not** yet establish
the meaning of the 44 32-bit words in each node. Candidate matrices,
indices, flags, and packet references must be validated across multiple
models and against runtime transforms before naming them.

### Packet/VIF stream

The packet region contains valid PS2 VIF codes. VIF codes are little-endian
32-bit words:

```text
bits  0..15  immediate
bits 16..23  NUM (zero represents 256 for commands that use NUM)
bits 24..30  command
bit      31  interrupt
```

For UNPACK commands (`command` in `0x60..0x7F`):

```text
VN = (command >> 2) & 3   # component count is VN + 1
VL = command & 3          # 32, 16, 8, or packed 5-bit element width
```

Observed examples:

```text
Bytes          u32 LE      Interpretation
FE 03 00 60    0x600003FE  UNPACK V1-32
00 00 03 68    0x68030000  UNPACK V3-32, NUM=3
00 C0 03 6E    0x6E03C000  UNPACK V4-8, NUM=3
03 80 19 6C    0x6C198003  UNPACK V4-32, NUM=25
```

The immediate also carries VU address and UNPACK flags. A complete decoder
must honor:

- destination address;
- signed/unsigned mode;
- flag/top behavior;
- `STCYCL`;
- mask mode and `STMASK`;
- row/column register fills;
- packed element widths;
- four-byte command/data alignment; and
- commands interleaved with UNPACK payloads.

Do not interpret every group of floats as a desktop vertex record. VIF
transfers populate VU memory, and the active VU microprogram determines the
semantic use of each lane. There is no confirmed conventional face-index
table. Historical research and local packet evidence both point to many small
submeshes and strip-style topology.

### Blender implications

A safe importer order is:

1. parse MRG boundaries;
2. parse GFX2OBJ offsets and validate non-overlap;
3. expose names, raw secondary records, and raw node records;
4. decode VIF to an emulated VU-memory image;
5. identify the matching VU microprogram and output layout;
6. reconstruct submesh topology and material assignment;
7. apply the node hierarchy and bind transforms; and only then
8. convert coordinates and emit Blender meshes/armatures.

Importing packet fragments without hierarchy is known to place parts on top of
one another and can create flickering coincident geometry.

Still unknown:

- parent and child fields;
- bind/local/world matrix convention;
- packet ownership per node;
- material/name indices;
- visibility/LOD flags;
- exact position, normal, UV, color, and weight lanes;
- strip restart markers and winding;
- handedness, unit scale, and Blender axis conversion.

## TIM2 textures

**Header framing: confirmed. Pixel conversion: pending validation.**

### File header

```text
Offset  Size  Type      Meaning
0x00    4     char[4]   "TIM2"
0x04    1     u8        version, observed 4
0x05    1     u8        alignment mode
0x06    2     u16 LE    picture count
0x08    8     bytes     reserved/game metadata
```

Picture-header location depends on alignment mode:

```text
alignment 0 -> first picture at 0x10
alignment 1 -> first picture at 0x80
```

This distinction explains apparently empty files whose bytes from `0x10`
through `0x7F` are zero. The inspected VF-1J textures use mode 1 and have a
valid picture header at `0x80`.

Reserved file-header bytes are nonzero in some CMP-contained textures and zero
in some color-variant MRG textures. They must not be treated as a standard
picture offset.

### Picture header

Base picture header:

```text
Offset  Size  Type      Meaning
0x00    4     u32 LE    total picture size
0x04    4     u32 LE    CLUT/palette byte size
0x08    4     u32 LE    image byte size, including mip levels
0x0C    2     u16 LE    full picture-header size
0x0E    2     u16 LE    CLUT color count
0x10    1     u8        picture format
0x11    1     u8        mipmap count
0x12    1     u8        CLUT type/flags
0x13    1     u8        image type
0x14    2     u16 LE    width
0x16    2     u16 LE    height
0x18    8     u64 LE    GS TEX0 value
0x20    8     u64 LE    GS TEX1 value
0x28    4     u32 LE    GS register data
0x2C    4     u32 LE    GS TEXCLUT value
0x30    ...   bytes     optional mipmap/user/extended header
```

Payload positions:

```text
image = picture_offset + header_size
clut  = image + image_size
next  = picture_offset + total_size
```

The logical TIM2 end may precede the MRG member end because MRG adds alignment
padding.

### Confirmed sample values

All three inspected VF-1J pictures are 8-bit indexed textures:

| Width | Height | Image bytes | CLUT bytes | Colors | Image type | CLUT type |
|---:|---:|---:|---:|---:|---:|---:|
| 64 | 64 | `0x1000` | `0x400` | 256 | `0x05` | `0x03` |
| 512 | 512 | `0x40000` | `0x400` | 256 | `0x05` | `0x03` |
| 128 | 64 | `0x2000` | `0x400` | 256 | `0x05` | `0x03` |

For these files:

- picture offset is `0x80`;
- picture-header size is `0x80`;
- image type `0x05` is indexed 8-bit;
- CLUT type base `0x03` is 32-bit RGBA;
- mipmap count is 1; and
- an `eXt\0` extended-header marker appears at picture-relative `+0x30`.

The size equation holds exactly for the first sample:

```text
picture total = 0x80 header + 0x1000 image + 0x400 CLUT = 0x1480
file logical end = 0x80 file/header alignment + 0x1480 = 0x1500
```

The enclosing MRG member is `0x1520`, leaving `0x20` bytes of archive padding.

### Decoder requirements

A Blender decoder must derive layout from image type and GS registers rather
than assume linear RGBA:

- decode direct-color or indexed image types;
- decode TEX0 PSM and CLUT CPSM/CSM/CSA fields;
- establish whether each payload uses GS swizzle or a linear TIM2 ordering;
- apply the 8-bit CLUT permutation when required;
- expand PS2 alpha (`0x80` is normal full opacity, not `0xFF`);
- process mipmaps and extended headers;
- determine UV origin/vertical orientation from rendered comparisons; and
- retain raw register values in imported metadata for debugging.

Palette permutation and pixel swizzle are not yet declared “solved” in this
project because header correctness alone does not prove a visually correct
decode.

## Skeleton and motion records

**Framing: provisional but repeated. Channel semantics: unknown.**

Motion archives commonly begin with `mot.lst`, followed by one `.bon` and many
`.mot` entries.

Both observed record types begin with little-endian magic `0x3B71`:

```text
Offset  Size  Candidate meaning
0x00    2     magic 0x3B71
0x02    2     kind: observed 1 for .bon, 0 for .mot
```

Observed `.mot` header fields:

```text
+0x04  f32 LE   1.0 in sampled clips
+0x08  u32 LE   node/bone count; 49 for VF-1 Battroid,
                 56 for a transformation set
+0x0C  u16 LE   flags/variant; often 0, observed 2
+0x0E  u16 LE   frame count; examples 10, 15, 30, 36, 45, 60, 80, 130, 150
```

These assignments are supported by repetition and plausible clip names, but
must be confirmed from runtime code before becoming a writer contract.

The `.bon` sample starts with kind 1 and a count of 49, but its following
offsets/records have not been decoded. Required work includes:

- hierarchy and node-name association;
- rest transforms;
- per-channel presence masks;
- key time/value encoding;
- quantization/compression;
- interpolation;
- frame rate;
- looping flags; and
- mapping to GFX2OBJ node indices.

## Collision data

**Signature confirmed; layout provisional.**

Enemy archives contain leaves beginning with the exact 32-byte text:

```text
CLS COLLISION LIBLARY VER 1.00\0\0
```

The misspelling `LIBLARY` is part of the format signature.

An inspected sample has:

- scalar and bounds-like floats after the signature;
- offset-like values `0x50`, `0x60`, `0x70`, `0x1F0`, and `0x330` in the
  `0x40..0x5F` region;
- count-like values 8 and 10 at `0x64` and `0x74`; and
- repeated records beginning at `0x80` with an apparent `0x30` stride.

These are observations, not final field names. A decoder must validate every
offset against file bounds and correlate candidate shapes with runtime
collision calls before deciding whether records are points, planes, boxes,
triangles, or hierarchy nodes.

## AUTH and MRGA authoring data

`AUTH` files are used by event/camera/scene assets. Confirmed framing:

```text
+0x00  char[4]  "AUTH"
+0x04  u32 LE   total file size
+0x08  u32 LE   observed class/version value 1 or 2
+0x0C  u32 LE   unknown
+0x10  f32 LE   observed 60.0 in sampled files
+0x14  u32 LE   unknown
+0x18  u32 LE   observed header/data offset such as 0x2C
```

Later strings such as `ANIM` occur, but track layouts are not decoded.

`MRGA` leaves occur inside menu/authoring archives. Only the magic and
repeatable containment are confirmed. Do not confuse `MRGA` leaves with the
magic-less MRG offset-table container.

## Script formats

See [Translation](translation.md) for external image patching and
[Runtime localization](localization.md) for read-time replacements.

### Record strings

```text
[3 ASCII category digits][3 ASCII digits or spaces]
[Shift-JIS bytes, with 0x0A line breaks]
[0x00 terminator]
[directly following zero padding]
```

The runtime subtitle option changes attribute byte 2 from `0` to `1` only for
supported Japanese voiced records. It preserves all other values, including
`2` and `3`, whose complete semantics remain unverified.

### Offset-table pools

```text
[u32 LE offsets...][NUL-terminated Shift-JIS strings...]
```

The first offset is the table size. Offsets may repeat or move backward but
must land on string starts and outside the table.

Individual strings are edited in place. The replacement must leave a NUL
terminator inside its measured slot.

## ADX audio

**Standard CRI format; header fields confirmed in local files.**

Loose `.ADX` files begin with a big-endian header:

```text
Offset  Size  Type    Meaning
0x00    2     u16 BE  signature, 0x8000
0x02    2     u16 BE  data start minus 4
0x04    1     u8      encoding type, observed 3
0x05    1     u8      block size, observed 0x12
0x06    1     u8      sample bit depth, observed 4
0x07    1     u8      channel count, often 2
0x08    4     u32 BE  sample rate, observed 48,000
0x0C    4     u32 BE  sample count
0x10    2     u16 BE  high-pass/cutoff field
0x12    1     u8      version
0x13    1     u8      flags
```

The `(c)CRI` marker is near the end of the variable-size header. Some files
use a short data offset such as `0x24`; others pad data to larger boundaries
such as `0x800`.

For conversion, preserve sample rate, channels, loop metadata, and sample
count. Established ADX decoders such as vgmstream or FFmpeg are preferable to
writing a new audio decoder for the Blender pipeline.

## AFS archive

`ADXJ.CVM/MCRSVOICE.AFS` begins:

```text
Offset  Size           Type       Meaning
0x00    4              char[4]    "AFS\0"
0x04    4              u32 LE     entry count
0x08    count * 8      pair[]     (offset, size) for each entry
...     aligned        bytes      entry payloads
```

The observed entry count is `0x0B6E` = 2,926. The first payload begins at
`0x80000`, leaving room for the large offset/size table and alignment.

AFS variants can carry a filename/timestamp table near the end. Import code
should not require names; index order is sufficient to preserve the game's
voice references.

## Sofdec SFD movies

`MOV.CVM` contains:

| File | Size |
|---|---:|
| `ADV01.SFD` | 85,977,088 |
| `END_MV.SFD` | 104,439,808 |
| `END_TV.SFD` | 92,725,248 |
| `TTL01.SFD` | 22,898,688 |

Each begins with MPEG program-stream pack start code `00 00 01 BA`. Sofdec
commonly combines MPEG video with CRI audio/private streams. Use a mature
demuxer/decoder for analysis; the recomp runtime still needs correct PS2 IPU,
streaming, timing, and audio behavior.

## Mission, catalogue, and sound-bank containers

### `.MSD`

Mission/stage `.MSD` files are structurally valid MRG archives, usually with
three members and an aligned `0x80` header.

The first member is another MRG archive containing stage sound-bank data. Tags
such as these appear byte-reversed in 32-bit little-endian chunks:

```text
IECSsreV  -> SCEI / Vers
IECSdaeH  -> SCEI / Head
IECSuqeS  -> SCEI / Sequ
```

Another member begins `SECTver0.502`. Its section/mission semantics remain
undecoded.

### `.CHRW` and `.CAT`

`CHRW.CHRW` and stage `CHRW_*.CAT` files are also four-member MRG archives.
They combine small metadata members, a TIM2 texture, and a large record/data
member. Their logical catalogue record format is not yet known.

### `MODULES.MRG`

This root archive contains:

- member 0: `mrg.lst`; and
- members 1 through 11: little-endian ELF IOP modules.

The manifest names modules including CRI ADX, `libsd`, memory-card services,
MIDI/synthesis, and related runtime components.

## ELF32

The main executable and IOP modules use ELF framing. The main EE file is
ELF32 little-endian MIPS with sections and symbols intact. The local
[`tools/elf32.py`](../tools/elf32.py) parser bounds-checks headers, sections,
string tables, and symbols.

Capstone can assist with ordinary MIPS/R5900 instructions through
[`tools/disasm_elf.py`](../tools/disasm_elf.py), but some R5900 MMI
instructions are not decoded and must remain raw words rather than being
misidentified.

## Blender importer architecture

Keep format parsing independent from Blender APIs:

```text
disc/CVM reader
  -> CRICMP decoder invocation
  -> recursive MRG parser
  -> typed GFX2OBJ/TIM2/MOT/CLS parsers
  -> neutral scene model
       nodes
       transforms
       meshes/submeshes
       materials/textures
       skeletons/animations
  -> Blender adapter
```

Recommended invariants:

- every offset/size is checked before slicing;
- unknown bytes are retained for diagnostics;
- no guessed field is required for parsing unrelated sections;
- logical child sizes are separated from archive padding;
- source file/member/node indices are stored as custom properties;
- coordinate conversion occurs once at the adapter boundary; and
- synthetic fixtures test framing without committing game assets.

Do not build the Blender add-on around one VF-1 sample. At minimum compare
opaque/transparent aircraft pieces, transformation models, enemies with
collision, stage geometry, color variants, and models using both `0100` and
`0200` signatures.
