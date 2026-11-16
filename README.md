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
| Vulkan renderer | Working; tested on an NVIDIA GeForce RTX 5070 |
| Original Japanese image | Reaches a bounded 600-frame compatibility run |
| English-patched image | Recompiles and reaches the same 600-frame run |
| Static EE recompilation | 8,684 functions in 15 generated packages |
| Translation integration | External, optional, and reproducibly pinned |
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

The same region/revision is required because static recompilation depends on
exact code addresses and function boundaries. Patched translation images are
accepted only through an explicit trust flag.

## Requirements

- Windows 10 or Windows 11, x86-64
- PowerShell
- Python 3
- Git
- A Vulkan 1.3-capable GPU and current graphics driver
- A legally obtained matching disc image
- Internet access during the first setup, to fetch the pinned framework and
  Odin toolchain

The setup script downloads Odin `dev-2026-10`, verifies its SHA-256, checks out
the exact framework commit in [recomp.lock.json](recomp.lock.json), builds the
recompiler, generates native source, and builds the port.

## Build

From PowerShell in the repository root:

```powershell
.\tools\setup.ps1 `
  -Image "F:\Recomp_GameSource\Chou Jikuu Yousai Macross (Japan).iso" `
  -ExactDisc
```

`-ExactDisc` hashes the complete image. Without it, setup still validates the
disc structure, boot target, executable size, and executable hash.

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

## Run

```powershell
.\tools\run.ps1 -Scale 1
```

The runner explicitly sets `MACROSS_SW=0`, selecting the Vulkan GS path rather
than the software renderer. Scale may be set from 1 through 8.

A bounded compatibility run is useful for automation:

```powershell
.\tools\run.ps1 -Headless -Frames 600
```

The headless option still exercises the compatibility path and terminates at
the requested frame limit. Inspect runtime output for the selected renderer,
presented-frame count, fallback state, and fatal errors.

## English translation

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
52 strings in the executable. It relaxes the original executable hash check;
it does not make arbitrary patched executables safe. Keep the original image
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

## Documentation

- [Engine findings](docs/engine.md)
- [File formats and Blender-importer notes](docs/file-formats.md)
- [Framework selection](docs/framework-selection.md)
- [Translation support](docs/translation.md)
- [Recompilation issues](docs/recomp-issues.md)
- [Research sources](docs/sources.md)
- [Completed work](docs/completed-work.md)
- [Remaining work](TODO.md)

## Legal and repository boundaries

- Do not commit or redistribute the ISO, executable, patched image, extracted
  assets, publisher script, save data, or generated recompiled source.
- This project requires users to supply their own copy of the game.
- The generated port scaffold is derived from the GPL-3.0 `ps-recomp`
  framework; this repository includes the corresponding [LICENSE](LICENSE).
- The translation project is invoked from an external checkout because its
  pinned revision does not declare a license.
- Reverse-engineering notes describe formats and interoperability findings;
  they do not include game assets or substantial copyrighted script text.
