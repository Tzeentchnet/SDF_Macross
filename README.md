# Chou Jikuu Yousai Macross PC Recomp

This repository is a research-stage static recompilation project for the
Japanese PlayStation 2 release of **Chou Jikuu Yousai Macross**
(`SLPM-65405`). It recompiles the Emotion Engine executable to native code and
uses a Vulkan 1.3 renderer supplied by the pinned `ps-recomp` runtime.

The project does **not** contain the game, extracted assets, generated game
code, or a translated image. You must provide your own matching disc image.

See [Current status](docs/status.md) for implemented features, measured
renderer coverage, and the remaining compatibility limitations.

## Supported disc

Only this image is currently supported:

| Property | Value |
|---|---|
| Title | Chou Jikuu Yousai Macross (Japan) |
| Serial | `SLPM-65405` |
| Image size | `1,230,897,152` bytes |
| Image SHA-256 | `221e4137cc1b197b262c58604143d92d2fdb3dd82d6b464870c6bbf1c68a27df` |
| Main executable | `SLPM_654.05` |
| Executable SHA-1 | `84ff167ee9612966e5027beabb7b920e7cf18920` |
| Executable SHA-256 | `5e51cf5ecb8f344ccab90f7d99df04ff050fadba025579e4369c4abe0ebe75a1` |

The same region/revision is required because static recompilation depends on
exact code addresses and function boundaries. An image with a changed
executable requires an explicit trust flag. Without `-ExactDisc`, changes
elsewhere in a structurally valid image are not authenticated.

## Requirements

- Windows 10 or Windows 11, x86-64
- PowerShell
- Python 3
- Git
- A Vulkan 1.3-capable GPU and current graphics driver
- A legally obtained matching disc image
- Internet access during the first setup, to fetch the pinned framework and
  Odin toolchain

On first installation, setup downloads Odin `dev-2026-10` and verifies the
archive SHA-256. It uses the framework commit in
[recomp.lock.json](recomp.lock.json), applies the ordered
[framework patch series](patches/ps-recomp/series), builds the recompiler,
generates native source, and builds the port. Existing tool installations are
reused.

## Build

From PowerShell in the repository root:

```powershell
.\tools\setup.ps1 `
  -Image "F:\Recomp_GameSource\Chou Jikuu Yousai Macross (Japan).iso" `
  -ExactDisc
```

`-ExactDisc` checks the complete image SHA-256. Without it, setup still
validates disc size and structure, the boot target, and the executable's size,
format, and SHA-1.

Generated and downloaded files are kept under ignored paths:

- `.deps\` - pinned dependency checkouts
- `.tools\` - Odin and other local tools
- `.build\` - generated configuration and analysis output
- `.local\` - local runtime data and patched images
- `port\src\rec\` - generated native source
- `port\macross-recomp.exe` - native executable
- `local.tsv` - local disc and runtime paths

To regenerate source without linking the final executable:

```powershell
.\tools\setup.ps1 -Image "F:\path\to\Macross.iso" -RecompileOnly
```

The game uploads VU1 graphics microprograms at runtime which are not present in
the ELF. An uncaptured program remains correct but runs in the interpreter.
To capture programs from the missions you play, then compile them into a local
release:

```powershell
$env:MACROSS_VU_CAPTURE = "1"
$env:MACROSS_VU1_CAPTURE = Join-Path $PWD ".local\vu1-capture.bin"
.\port\macross-recomp.exe --play
Remove-Item Env:\MACROSS_VU_CAPTURE, Env:\MACROSS_VU1_CAPTURE

.\tools\setup.ps1 `
  -Image "F:\path\to\Macross.iso" `
  -Vu1Capture ".local\vu1-capture.bin"
```

Close the game after visiting the scenes to capture. `VU_CAPTURE=1`
intentionally interprets every visited program while recording it. After
rebuilding, use `VU_CAPTURE=miss` with the same capture path to run known
programs as compiled code and append only newly encountered programs. Do not
run concurrent capture sessions against one file.

The capture contains code derived from the player's disc, remains ignored
under `.local\`, and must not be committed or redistributed. Re-run setup
after extending it so the newly seen programs are included. Unknown programs
still fall back to the interpreter, so one route's converged capture is not
evidence of full-game coverage.

For port-source edits after setup, rebuild using the existing generated code:

```powershell
.\tools\build.ps1
# Or use -Fast for a minimally optimized debug build.
```

The incremental build checks generated-source provenance against the locked
framework, patch series, recompiler configuration, and generated files.
Recorded mismatches fail the build. Legacy output without provenance is
accepted with a warning, not proven current; a missing generated
configuration also produces a warning. Rerun full setup after changing the
image, framework, patch series, or recompilation configuration, and to
replace legacy output with verified provenance.

## Run

```powershell
.\port\macross-recomp.exe
```

The launcher offers text language, an independent English system-message
overlay, radio subtitles, renderer, coordinated render presets, internal
resolution, output upscaler, fullscreen, and launcher settings. `Performance`
uses 1x with FSR 1, `Balanced` uses 2x with FSR 1, and `Quality` uses 3x with
linear output; other manually selected combinations appear as `Custom`.
Vulkan is the measured full-speed default and enables internal resolution
scaling; FSR 1 is a spatial EASU + RCAS option for lower internal resolutions.
Software remains a compatibility fallback. Changed options are saved in the
local runtime data directory; F11 toggles fullscreen in-game. To start
directly or force the launcher back on:

```powershell
.\port\macross-recomp.exe --play
.\port\macross-recomp.exe --launcher
```

String-table export is command-line only and exits after writing the CSV:

```powershell
.\port\macross-recomp.exe --export-strings .\localization\_base\strings.csv
```

Localization mods can expose multiple friendly language choices from one
table. Runtime glyph packs add Latin diacritics, Simplified Chinese, and
Ukrainian characters without recompiling, while language-scoped file overlays
can replace stage-title art. The release project will ship the project-created
multilingual translation CSV and runtime translation functions. The offline
generation, review, font, UI, and title-card workflow is documented in the
[localization contributor tutorial](docs/localization.md#tutorial-add-a-language).

Alternatively, [`tools\run.ps1`](tools/run.ps1) bypasses the launcher by
default and explicitly overrides saved rendering options for that run:

```powershell
# Measured full-speed path at native internal resolution
.\tools\run.ps1 -Renderer Vulkan -Scale 1 -Upscaler FSR1

# Software compatibility fallback
.\tools\run.ps1 -Renderer Software

# Show the launcher instead of starting immediately
.\tools\run.ps1 -Launcher
```

Scale may be set from 1 through 8. `-Upscaler` accepts `Linear` or `FSR1`.
FSR 1 runs only when the presentation target is larger than the internal
Vulkan image; downscaling remains linear.

A bounded compatibility run is useful for automation:

```powershell
.\tools\run.ps1 -Headless -Frames 600
```

Headless compatibility runs bypass the launcher and saved player settings.
Inspect runtime output for the selected renderer, presented-frame count,
fallback state, and fatal errors. For automated assertions, use the
[end-to-end smoke test](docs/testing.md#end-to-end-windows-smoke-test).

Measured performance, the Vulkan speckle fix, adaptive-audio behavior, and why
FSR 3, DLSS, and frame generation are not yet viable are documented in
[Rendering and presentation](docs/engine.md#rendering-and-presentation).

## Runtime localization

The release project includes the project-created multilingual translation CSV
and runtime translation functions for English, Mexican Spanish, Brazilian
Portuguese, Simplified Chinese, French, German, Hungarian, and Ukrainian. The
generated language columns remain unreviewed machine translations. The
independent `en-system` launcher option overlays 47 project-authored English
executable-system messages on any selected text language, and `en-fan` remains
an optional private-import workflow for player-supplied third-party text.
Runtime localization, radio subtitles, and string export require the original
supported executable hash and do not modify the disc image.

See the [localization contributor guide](docs/localization.md) to add or review
a language and for launcher options, local CSV import, font packs, UI art,
subtitle limits, and CVM file overlays.

The separate [external patched-image workflow](docs/patched-image.md) is an
advanced compatibility reference for a third-party ISO patcher; translators
do not need it to add a runtime language. Disc and asset inspection commands
are in [Analysis tools](docs/analysis-tools.md), and validation workflows are
in [Testing](docs/testing.md).

## Documentation

- [Analysis tools](docs/analysis-tools.md)
- [Current status](docs/status.md)
- [Engine findings](docs/engine.md)
- [File formats and Blender-importer notes](docs/file-formats.md)
- [Framework selection](docs/framework-selection.md)
- [Localization contributor guide](docs/localization.md)
- [Testing](docs/testing.md)
- [External patched-image workflow](docs/patched-image.md)
- [Recompilation issues](docs/recomp-issues.md)
- [Research sources](docs/sources.md)
- [Completed work](docs/completed-work.md)
- [Remaining work](docs/TODO.md)

## Legal and repository boundaries

- Do not commit or redistribute the ISO, executable, patched image, extracted
  assets, publisher script, save data, or generated recompiled source.
- The project-created multilingual translation CSV, runtime translation
  functions, and 47-string `en-system` table are release content. The raw
  publisher export, original Japanese source column, and optional locally
  imported third-party fan CSV remain ignored and are not release content.
- This project requires users to supply their own copy of the game.
- The generated port scaffold is derived from the GPL-3.0 `ps-recomp`
  framework; this repository includes the corresponding [LICENSE](LICENSE).
- The translation project is invoked from an external checkout because its
  pinned revision does not declare a license.
- Reverse-engineering notes describe formats and interoperability findings;
  they do not include game assets or substantial copyrighted script text.
