# Runtime localization

The port can replace text and selected CVM files at runtime without writing a
patched disc. This is separate from the external
[patched-image workflow](translation.md). It is specific to Japanese
`SLPM-65405`; enabling a mod, radio subtitles, or string export checks the boot
target, executable size, and original executable SHA-256:

```text
5e51cf5ecb8f344ccab90f7d99df04ff050fadba025579e4369c4abe0ebe75a1
```

`-AllowPatchedImage` relaxes setup's executable SHA-1 check, but does **not**
bypass this runtime check. Use the original executable for runtime
localization; disable these features when using an externally patched
executable. The runtime executable check is not a whole-disc hash check.

## Choosing options

After [setup](../README.md#build), start `.\port\macross-recomp.exe` from the
repository root. The launcher offers Japanese disc text, installed
localization mods, radio subtitles, Vulkan or software rendering, internal
resolution, Vulkan output upscaling, fullscreen, and whether to show the
launcher on later starts.
Keyboard, mouse, and controller navigation are implemented; controller
behavior still needs broader validation. F11 toggles fullscreen in-game.

- `.\port\macross-recomp.exe --play` skips the launcher.
- `.\port\macross-recomp.exe --launcher` forces it to appear.
- `.\tools\run.ps1 -Renderer Vulkan -Scale 1 -Upscaler FSR1` starts the game
  directly and overrides saved rendering options through environment
  variables. Add `-Launcher` to show the launcher instead. Its `-Headless`
  compatibility mode also skips saved settings.

### Included mods

| Mod | Contents and limits |
|---|---|
| `en-system` | 47 project-authored English executable-system messages, including memory-card, installation, calibration, and dialog text. Missing strings and the story stay as on the disc. |
| `en-fan` | A checked-in manifest that includes `en-system`. The player must supply `localization\en-fan\strings.csv` locally before it offers fan text. |

Included mods are loaded first; later nonempty rows in the selected mod win.
Thus local fan rows can override `en-system`, while missing or empty rows fall
back to an included value or the disc. Include cycles and missing included
mods are errors. The project's 47 strings are not the external image patch's
52 executable edits, and neither count implies a complete translation.

The external full story translation is machine-produced and has not been
reviewed by a Japanese-speaking human. It is not vendored: its pinned revision
declares no explicit license. Local fan-derived CSVs must not be committed or
redistributed.

## Settings and migration

Settings are resolved independently for each option, in this order:

1. `MACROSS_*` environment variables, including explicitly empty values;
2. the player's `<data>\settings.tsv`, normally
   `.local\runtime\settings.tsv` after setup;
3. the repository's `settings.tsv`;
4. the framework's global settings; and
5. built-in defaults.

Setup records the player data directory in ignored `local.tsv`. The existing
repository/global settings remain in place and continue to be inherited; the
launcher does not bulk-copy or delete them. It atomically saves only options
the player changes, preserving unrelated player-file rows such as `IRX`,
`NATIVE`, and unknown settings. An environment override still wins after a
launcher edit for that run.

The launcher controls `SW`, `SCALE`, `UPSCALER`, `LOC`, `LANG`, `SUBTITLES`,
`FULLSCREEN`, and `LAUNCHER`. `UPSCALER` is `linear` or `fsr1`; it affects the
Vulkan presentation path only. `LOC` is a mod directory name and `LANG` is its
selected CSV language column. The checked-in repository settings select
Vulkan, scale 1, and FSR 1; software remains an explicit compatibility
fallback. The settings and controller features are not a substitute for
in-game compatibility testing.

## Subtitles

For supported voiced record tables, the runtime option changes record ID
byte 2 from ASCII `0` to `1` only when the original text contains Japanese
prose. It leaves `1`, `2`, `3`, and any other values unchanged. The meanings
of `2` and `3` are not fully established, and caption layout and behavior
still need testing across missions. The external image builder's subtitle
patch is a separate operation; its historical count of 1,811 enabled lines is
not a runtime coverage guarantee.

## Exporting and importing local text

The launcher's **Export string table** action boots a headless child until
the game loads its text, then writes
`localization\_base\strings.csv`. The same operation can be requested directly:

```powershell
.\port\macross-recomp.exe --export-strings .\localization\_base\strings.csv
```

The exported UTF-8 CSV contains publisher text. Its exact path is ignored by
Git and must remain private. Exporting to another path does not automatically
make that path ignored; keep other working copies under `.local\` and do not
commit them.

To populate `en-fan`, first obtain and inspect the external translation
checkout at the revision pinned in
[`recomp.lock.json`](../recomp.lock.json). After exporting the base table:

```powershell
python .\tools\loc_csv.py import-external `
  .\localization\_base\strings.csv `
  .\.deps\macross-translation `
  .\localization\en-fan\strings.csv

python .\tools\loc_csv.py check `
  .\localization\en-fan\strings.csv `
  --base .\localization\_base\strings.csv
```

The importer reads the checkout's baseline and machine-translation JSON by
default; append `--baseline-only` to import only its baseline. It reports
unmatched source entries and exits nonzero if any remain. The `en-fan` CSV is
also explicitly ignored. `--with-ja` includes publisher text and is for
private local work only.

[`tools/loc_csv.py`](../tools/loc_csv.py) also provides `merge` and `strip`.
`merge` produces a workbook containing the original Japanese, so write it to
ignored local storage. `strip` removes the Japanese column and some metadata,
but does not grant redistribution rights for fan text or other retained
content. The checker reports malformed/duplicate keys, unencodable
characters, executable slot budgets and printf conversions when a base is
provided, and optional line-width violations.

## Mod tables and file overlays

A mod lives under `localization\<id>\`; names beginning with `_` or `.` are
not discovered as mods. It may provide a `strings.csv`, a `files` directory,
or both, with an optional `mod.tsv` manifest:

```text
localization\<id>\mod.tsv
localization\<id>\strings.csv
localization\<id>\files\JPN.CVM\<existing-root-file>
```

The UTF-8 CSV has a `key` column and one or more language columns, such as
`en`. Keys are `tNN.IIII` for a string-table entry or `exe.AAAAAAAA` for a
supported executable address. The runtime loads each table transactionally,
rejects malformed or duplicate entries, and falls back for missing text.
Text is encoded as CP932/Shift-JIS; unsupported characters become `?` and are
reported. The manifest's `ascii_punctuation` option defaults to enabled.
Executable replacements must fit their original slots and retain the original
printf argument conversions; otherwise those strings remain unchanged.

For file replacements, the directory below `files` names an existing outer
CVM and each replacement names an existing **root-level** file inside it.
Names match case-insensitively; nested replacement directories are not
supported. A 2,048-byte-sector `.iso` is required. Later included mods can
replace earlier files.

The overlay validates the image, directory metadata, file extents, and
replacement sizes before installing its read hook. Replacements can fit in
place or move to verified unallocated zero sectors inside or immediately
after a CVM. It serves replacement bytes and updated directory/volume fields
on reads, including both byte orders where applicable; it never rewrites the
source image. Missing files, unsafe overlaps, insufficient verified space,
or other preparation errors fail the whole installation rather than leaving a
partial overlay. Keep replacement files unchanged while the game is running.

Synthetic runtime tests exercise table loading, attribute preservation,
settings, discovery, and overlay failure paths. See
[testing](../README.md#testing) for the automated suites and the separate
exact-disc Vulkan smoke test. These checks do not prove full-game or visual
correctness.
