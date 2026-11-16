# Translation support

## Existing project

The supported external project is:

<https://github.com/chummy778/Macross-PS2-Fan-Translation-Tooling>

Pinned revision:

```text
4339a4485149a52aa2b0633e093511d452885fb5
```

No explicit license was found in that revision. For that reason this repository
does not vendor, modify, or redistribute its code or translation data. The
integration wrapper accepts a user-provided checkout.

## Coverage

| Layer | Coverage |
|---|---:|
| Hand-checked baseline UI/playability entries | 290 strings |
| Additional machine-translated entries | 2,538 strings |
| Unique exposed strings in `BOOTDAT` | 2,777 |
| Strings containing Japanese | 2,739 |
| Executable-resident system messages | 52 |
| Voice-only lines optionally captioned | 1,811 |

The machine-translated layer overlaps the baseline in two vocabulary
overrides, so its raw entry count should not be added blindly to the unique
string count.

Nine entries are intentionally left untranslated by the external project:
seven memory-card save titles whose change could orphan existing saves, and
two developer markers without translatable prose.

## Quality warning

The full story translation was machine-produced and has **not** been checked
by a Japanese-speaking human. Fluent output is not evidence of accuracy.
Treat it as:

- a playable draft;
- a terminology and layout starting point; and
- material requiring human translation and editorial review.

The 290-entry baseline is described by its project as hand-checked and is
appropriate when menu/playability support is desired without opting into the
full machine-translated story.

## Build modes

[`tools/translate.ps1`](../tools/translate.ps1) exposes three modes:

| Mode | Behavior |
|---|---|
| `Verify` | Verify that the external project accepts the source image |
| `Baseline` | Apply the 290-entry playability translation |
| `Full` | Apply baseline plus the machine-translated story layer |

`-Subtitles` additionally enables captions for voice-only radio dialogue.

Example:

```powershell
.\tools\translate.ps1 `
  -Image "F:\path\to\Macross.iso" `
  -TranslationTools ".deps\macross-translation" `
  -Mode Full `
  -Subtitles `
  -Output ".local\Macross-full-subtitles.iso"
```

The wrapper:

1. resolves source and tool paths;
2. invokes the external verifier;
3. refuses to overwrite the source image;
4. invokes the external builder with explicit options; and
5. validates the result with this project's structural verifier and
   `--allow-patched`.

Build the native port against the result:

```powershell
.\tools\setup.ps1 `
  -Image ".local\Macross-full-subtitles.iso" `
  -AllowPatchedImage
```

## Script storage

Most text is in decompressed `JPN.CVM/BOOTDAT.CMP`. There are two formats.

### Dialogue/record strings

```text
[6-byte ASCII record ID][Shift-JIS text][00][zero padding]
```

The ID is:

```text
[three decimal category characters][three decimal-or-space index characters]
```

The final three characters are not always digits. IDs such as
`ddd   `, where `d` represents a decimal digit, are valid and are used by
Global Report narration. A digit-only regular expression misses 660 records.

Byte `0x0A` inside the text is a manual line break. The game wraps by
character count, not at word boundaries.

### String pools

String pools consist of a `u32` offset table followed by NUL-terminated
Shift-JIS strings.

Confirmed invariants:

- the first offset is the table's byte length;
- offsets do not point into the table;
- each offset lands on a string start; and
- offsets are not necessarily sorted and may repeat.

Repeated offsets must be deduplicated before applying edits. Otherwise two
logical entries can write conflicting text to the same bytes.

### Slot budgets

Translations are written in place. A replacement must be **strictly shorter**
than its slot budget because one byte is required for the terminating NUL.
The usable slot is the original text plus directly following NUL padding; it
must not be measured to the next detected record because unrelated binary
tables can occur between record clusters.

The external project reports 135,666 writable bytes for 64,092 source
characters, which is sufficient for its English text without moving
individual strings.

## Executable strings

`BOOTDAT` does not contain every message. The main ELF contains 52 plain
Shift-JIS strings for memory cards, save/load results, HDD errors, and
controller calibration.

They are patched in place and are the reason a translated executable no longer
matches the original SHA-1. A broad Shift-JIS scan of an ELF produces many
false positives from numeric data, so the external project uses sentence-like
hiragana density and strict slot budgets.

## Subtitle switch

The engine already contains the radio-caption window and timing path:

```text
MIS_PlayVoice
  -> NAVI_PlayVoice
  -> SND_GetVoicePlayTime

navi_Chrw
  -> STR_GetDispAttr(record_id)
  -> NAVI_DispNarrationExec
```

Byte 2 of the six-byte record ID is a display attribute:

- ASCII `0`: voice only;
- ASCII `1`: bit 0 set, so draw the caption;
- attributes `2` and `3`: not fully characterized; `3` also has bit 0 set.

The optional subtitle patch changes one byte per affected record. It enables
1,811 lines; 864 lines already ship with captions. Voice duration remains the
timing source.

The known caption text area is 280 by 88 pixels at `(180, 287)`, inside a
300-by-100 box. At the native 32-pixel glyph size this is approximately four
lines of 28 characters. Text does not shrink to fit.

## Why the container may move

`JPN.CVM` is packed with no spare sectors, and the original `BOOTDAT.CMP`
allocation is 97 sectors. Compression ratio depends on the selected lines;
short, repetitive Japanese can compress better than distinct English text.

When the recompressed file exceeds its allocation, the external builder:

1. rebuilds the embedded ISO;
2. updates file extents and recorded lengths in both byte orders;
3. updates the inner PVD volume size;
4. updates the CVMH size field;
5. places the expanded container in the all-zero `ETC.CVM` allocation; and
6. repoints the outer ISO records.

Updating the recorded file length is required even when compressed output is
shorter. Leaving the old length can make the game's streaming reader wait for
data the decompressor has already finished consuming.

## Text that is actually art

The following are texture-driven rather than ordinary script strings:

- stage title cards in `SBTTL_*.CMP`;
- logos;
- parts of `MENU2D`; and
- other decorated 2D UI.

These assets contain TIM2 textures and require an art replacement pipeline.
Their presence does not indicate a missing text record.

## Repository hygiene

Do not commit:

- a source or patched ISO;
- extracted `BOOTDAT`;
- workbooks containing the Japanese script;
- generated translations that reproduce publisher text; or
- screenshots/assets unless their redistribution rights are clear.
