# Recompilation framework selection

## Requirement

The selected framework had to:

1. support PlayStation 2 R5900/Emotion Engine code;
2. provide or integrate a PC runtime rather than only disassembling code;
3. render through Vulkan;
4. be actively maintained, with an update in the month before selection; and
5. be pin-able for reproducible builds.

The selection was performed on **2026-11-16**, so the maintenance cutoff was
2026-10-16. Upstream maintenance was rechecked on **2026-11-21** before the
current pin was adopted.

## Selected framework: `ps-recomp`

| Property | Value |
|---|---|
| Repository | <https://github.com/plaught-armor/ps-recomp> |
| Pinned commit | `20ed32d9056920652361020697f2be5481c8c3d5` |
| Commit date | 2026-11-21 22:55:32 UTC |
| Age at latest verification | Less than one day |
| License | GPL-3.0 |
| Implementation language | Odin |
| Guest architectures | PS1 R3000A and PS2 R5900 |
| PS2 graphics | Vulkan 1.3 GS renderer |
| Host integration | SDL2 window, input, and audio |
| Native targets relevant here | Windows x86-64 |

The commit date satisfies the one-month maintenance requirement with
substantial margin. The current pin incorporates 193 upstream commits after
the initial selection, including the formerly local controller, disc hook,
presentation, audio, software GS, and texture tracking changes. The exact
evidence and toolchain are recorded in
[`recomp.lock.json`](../recomp.lock.json).

## Why it fits this game

`ps-recomp` translates named MIPS functions to Odin procedures and supplies
the console-facing runtime around them:

- R5900 instruction translation and fallback interpretation;
- PS2 memory and kernel behavior;
- DMA, GIF, GS, VU, IPU, and IOP support;
- Vulkan GS rendering;
- SDL2 host input, windowing, and audio;
- memory-card support; and
- native x86-64 code generation.

This game is an unusually good static-recompilation candidate because its main
ELF retains a complete symbol table. The project generated 8,684 functions in
15 packages without first reconstructing all function boundaries manually.

The framework was also directly validated rather than selected from its README
alone: the pinned Windows build produced a native executable, selected the
Vulkan renderer, and presented 599 frames before a requested 600-frame stop.

## Alternatives considered

### `ran-j/PS2Recomp`

This project is also aimed at R5900-to-C++ static recompilation and was active
at research time. Its documented workflow emphasizes Ghidra-assisted function
export and a developing runtime. It was not selected because `ps-recomp`
already provided the integrated PS2 Vulkan GS, host, kernel, IOP, and build
path needed to reach a rendered frame in this project.

This is a fit decision, not a claim that `PS2Recomp` is abandoned or unusable.

### PCSX2 and forks

PCSX2 is a mature dynamic emulator with Vulkan support, but it is not a static
recompilation framework that emits a game-specific native program. It remains
useful as behavioral reference and for translation testing, but it does not
satisfy the requested output model.

### Recompilers for other consoles

N64, GameCube/Wii, and other platform recompilation projects do not implement
the PS2 R5900, VU, GIF/GS, IOP, or kernel environment and are therefore not
viable bases.

## Pinning and update policy

The project intentionally pins a commit rather than following a moving branch.
Setup performs a detached checkout and verifies the resulting `HEAD`.

The Odin compiler is also pinned because the framework requires a specific
development release:

- tag: `dev-2026-10`
- Windows archive:
  `odin-windows-amd64-dev-2026-10.zip`
- SHA-256:
  `b6b2e426a8b6f147b74ec7e18bef8df27cf40fe16193159df7ca09a0cc0c2011`

Before updating either pin:

1. verify the upstream commit date still meets the project's maintenance
   policy;
2. read upstream migration notes;
3. rebuild the recompiler and port from a clean ignored output tree;
4. rerun the original and translated 600-frame checks;
5. compare generated function/package counts and runtime diagnostics; and
6. update the lock file and completed-work record together.

## License consequence

The selected framework is GPL-3.0. The checked-in port bootstrap derives from
that framework, so the repository carries a GPL-3.0
[`LICENSE`](../LICENSE). Game data and generated output remain excluded; the
license does not grant permission to redistribute publisher assets.
