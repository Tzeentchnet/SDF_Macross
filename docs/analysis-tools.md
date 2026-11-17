# Analysis tools

Run these commands from the repository root. Store extracted data only in
ignored local directories.

## Disc, container, and ELF inventory

Create a complete disc/container/ELF inventory:

```powershell
python .\tools\inspect_game.py `
  "F:\path\to\Macross.iso" `
  --exact `
  --exhaustive-zero-check `
  --json ".build\analysis\game-manifest.json"
```

## Asset extraction

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

## Nested MRG archives

Inspect or extract a nested MRG tree:

```powershell
python .\tools\inspect_mrg.py ".build\analysis\bin\VF1J_AC.CMP.bin"
python .\tools\inspect_mrg.py `
  ".build\analysis\bin\VF1J_AC.CMP.bin" `
  --extract ".build\analysis\vf1j-leaves"
```

## ELF disassembly

The optional [`tools/disasm_elf.py`](../tools/disasm_elf.py) requires
Capstone. It validates aligned, file-backed symbol/range boundaries, decodes
supported R5900 forms, and emits `.word` for unknown instructions instead of
stopping.

## Data handling

All extracted assets are copyrighted game data and must remain in ignored
local storage. Do not commit or redistribute disc contents, extracted assets,
publisher script, or generated disassembly containing substantial publisher
data.

See [File formats](file-formats.md) for the documented structures and
[Research sources](sources.md) for the tools and external references used to
establish those findings.
