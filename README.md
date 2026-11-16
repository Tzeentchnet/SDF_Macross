# Chou Jikuu Yousai Macross PC Recomp

This repository is a research-stage static recompilation project for the
Japanese PlayStation 2 release of **Chou Jikuu Yousai Macross**
(`SLPM-65405`). It recompiles the Emotion Engine executable to native code and
uses a Vulkan 1.3 renderer supplied by the pinned `ps-recomp` runtime.

The project does **not** contain the game, extracted assets, generated game
code, or a translated image. You must provide your own matching disc image.

## Current status

| Area | Status |
|---|---|
| Windows x86-64 native build | Working |
| Software renderer | Recommended; sustained full speed in the tested heavy scene |
| Vulkan renderer | Working with deterministic GS memory ordering; tested on an NVIDIA GeForce RTX 5070 |
| Output upscaling | FSR 1 EASU + RCAS or linear scaling on Vulkan |
| Slow-host audio | Adaptive resampling prevents repeated queue starvation in the tested scenes |
| Original Japanese image | Reaches a bounded 600-frame compatibility run |
| English-patched image | Recompiles and reaches the same 600-frame run |
| Static EE recompilation | 8,684 functions in 15 generated packages |
| Runtime localization | 47 project-authored English system strings; optional local fan translation |
| Patched-image translation | External, optional, and reproducibly pinned |
| Full-game compatibility | Not yet established |
| Release-ready port | No; this is an early bring-up and reverse-engineering project |

The successful compatibility run proves that the native executable starts,
selects the PS2 Vulkan GS renderer, and presents frames. It does not yet prove
that every mission, save path, audio path, movie, controller, or ending works.
See [Recompilation issues](docs/recomp-issues.md) and [TODO.md](TODO.md).

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

The launcher offers text language, radio subtitles, renderer, internal
resolution, output upscaler, fullscreen, and launcher settings. Software
rendering is the measured full-speed default. Vulkan enables internal
resolution scaling; FSR 1 is a spatial EASU + RCAS option for lower internal
resolutions. It saves changed options in the local runtime data directory; F11
toggles fullscreen in-game. To start directly or force the launcher back on:

```powershell
.\port\macross-recomp.exe --play
.\port\macross-recomp.exe --launcher
```

Alternatively, [`tools\run.ps1`](tools/run.ps1) bypasses the launcher by
default and explicitly overrides saved rendering options for that run:

```powershell
# Measured full-speed path
.\tools\run.ps1 -Renderer Software

# Vulkan at native internal resolution, spatially upscaled to the window
.\tools\run.ps1 -Renderer Vulkan -Scale 1 -Upscaler FSR1

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
fallback state, and fatal errors. For automated assertions, use the smoke test
below.

Measured performance, the Vulkan speckle fix, adaptive-audio behavior, and why
FSR 3, DLSS, and frame generation are not yet viable are documented in
[Rendering and presentation](docs/engine.md#rendering-and-presentation).

## Runtime localization

The included `en-system` mod provides 47 project-authored English
executable-system messages; untranslated messages and the story remain
Japanese. The `en-fan` manifest can layer a player-supplied fan CSV over those
system strings; the fan CSV is not distributed here. Runtime localization,
radio subtitles, and string export require the original supported executable
hash and do not modify the disc image.

See [Runtime localization](docs/localization.md) for launcher options, settings
precedence, local CSV import, subtitle limits, and CVM file overlays.

## External patched-image translation

An existing fan-translation project is supported as an **external checkout**:

<https://github.com/chummy778/Macross-PS2-Fan-Translation-Tooling>

It is not vendored because no explicit license was found in the pinned
revision. The full story translation is machine-produced and has not been
reviewed by a Japanese-speaking human.

After checking out the pinned revision from [recomp.lock.json](recomp.lock.json)
and installing its CRICMP dependency, build a translated image with:

```powershell
.\tools\translate.ps1 `
  -Image "F:\path\to\Macross.iso" `
  -TranslationTools ".deps\macross-translation" `
  -Mode Full `
  -Subtitles
```

Then recompile against the new image:

```powershell
.\tools\setup.ps1 `
  -Image ".local\Macross-full.iso" `
  -AllowPatchedImage
```

`-AllowPatchedImage` is deliberately required because the translation patches
52 strings in the executable. It relaxes the original executable SHA-1 check,
not the other structural checks or an explicitly requested exact-disc hash; it
does not make arbitrary patched executables safe. Runtime localization,
subtitles, and export independently require the original executable SHA-256,
so do not enable them on that patched executable. Keep the original image
read-only and inspect the translation checkout before trusting it.

See [Translation](docs/translation.md) for coverage, quality, script layout,
subtitle behavior, and container rebuilding details.

## Analysis tools

Create a complete disc/container/ELF inventory:

```powershell
python .\tools\inspect_game.py `
  "F:\path\to\Macross.iso" `
  --exact `
  --exhaustive-zero-check `
  --json ".build\analysis\game-manifest.json"
```

Extract files from an embedded CVM into an ignored local directory:

```powershell
python .\tools\extract_assets.py `
  "F:\path\to\Macross.iso" `
  BIN.CVM `
  ".build\analysis\bin"
```

Extract and decompress `.CMP` files with a locally built CRICMP executable:

```powershell
python .\tools\extract_assets.py `
  "F:\path\to\Macross.iso" `
  BIN.CVM `
  ".build\analysis\bin" `
  --pattern "*.CMP" `
  --cricmp ".deps\cricmp\cricmp.exe" `
  --decompress-cmp
```

Inspect or extract a nested MRG tree:

```powershell
python .\tools\inspect_mrg.py ".build\analysis\bin\VF1J_AC.CMP.bin"
python .\tools\inspect_mrg.py `
  ".build\analysis\bin\VF1J_AC.CMP.bin" `
  --extract ".build\analysis\vf1j-leaves"
```

All extracted assets are copyrighted game data and must remain in ignored
local storage.

The optional [`tools/disasm_elf.py`](tools/disasm_elf.py) requires Capstone.
It validates aligned, file-backed symbol/range boundaries, decodes supported
R5900 forms, and emits `.word` for unknown instructions instead of stopping.

## Testing

Run synthetic parser, patched-image trust, disassembler, and localization
tool tests without a game image:

```powershell
python -m unittest tests.test_disc_image tests.test_inspect_game tests.test_mrg tests.test_disasm_elf tests.test_localization_tools
.\tests\test_setup_verify.ps1
.\tests\test_smoke_contract.ps1
.\tests\test_framework_patches.ps1
```

The disassembler's real-Capstone integration test is skipped if Capstone is
unavailable; localization's isolated Odin codec test is skipped if Odin is
unavailable. The patch tests use synthetic Git fixtures. The PowerShell
contract tests do not require a disc or GPU.

For the opt-in end-to-end Windows build and Vulkan smoke test, supply the
**original exact disc**, not a patched image:

```powershell
.\tests\smoke.ps1 -Image "F:\path\to\Macross.iso" -Frames 600
```

It runs full setup with `-ExactDisc`, then headless Vulkan at scale 1. It
requires successful exits, a Vulkan device line, exactly one GPU renderer line,
and exactly one strictly parsed `compat` JSON record. Duplicate object keys
are rejected case-insensitively. The record must contain `system: "ps2"`,
`result: "frames"`, the locked framework commit, integer `frames` at least the
requested limit, integer `shown` with `0 < shown <= frames`, boolean
`fallback: false`, and an empty `fatal` string.
Exactly one matching `frames: ... reached` line is also required. The default
and minimum are 600 frames. Setup and run timeouts default to 1,800 and 600
seconds; adjust them with `-SetupTimeoutSeconds` and `-RunTimeoutSeconds`.
Timeouts stop the child process tree, and inherited `MACROSS_*` overrides are
cleared.

The smoke test regenerates source, rebuilds the executable, and rewrites
`local.tsv` for the supplied image. It proves bounded startup and frame
progress, not visual correctness or a full playthrough.

## Documentation

- [Engine findings](docs/engine.md)
- [File formats and Blender-importer notes](docs/file-formats.md)
- [Framework selection](docs/framework-selection.md)
- [Runtime localization](docs/localization.md)
- [Translation support](docs/translation.md)
- [Recompilation issues](docs/recomp-issues.md)
- [Research sources](docs/sources.md)
- [Completed work](docs/completed-work.md)
- [Remaining work](TODO.md)

## Legal and repository boundaries

- Do not commit or redistribute the ISO, executable, patched image, extracted
  assets, publisher script, save data, or generated recompiled source.
- The exported publisher CSV and locally imported fan CSV are ignored; do not
  commit or redistribute them. The 47-string `en-system` table is
  project-authored.
- This project requires users to supply their own copy of the game.
- The generated port scaffold is derived from the GPL-3.0 `ps-recomp`
  framework; this repository includes the corresponding [LICENSE](LICENSE).
- The translation project is invoked from an external checkout because its
  pinned revision does not declare a license.
- Reverse-engineering notes describe formats and interoperability findings;
  they do not include game assets or substantial copyrighted script text.
