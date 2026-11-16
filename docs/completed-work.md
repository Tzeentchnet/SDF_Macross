# Completed work

This file is the archive for finished tasks. Active work belongs in
[`TODO.md`](../TODO.md).

## 2026-11-16 - Disc identification and safety

- [x] Identified the supported game as Japanese `SLPM-65405`.
- [x] Recorded the exact image size and SHA-256 in
  [`game.lock.json`](../game.lock.json).
- [x] Recorded the main executable size, SHA-1, and SHA-256.
- [x] Confirmed the outer image is ISO 9660 with 11 root files.
- [x] Mounted the source read-only during exploratory checks.
- [x] Added ignore rules for images, extracted assets, generated code,
  binaries, runtime data, dependencies, and toolchains.
- [x] Confirmed `ETC.CVM` is an all-zero placeholder.

## 2026-11-16 - Framework and toolchain

- [x] Evaluated current PS2 recompilation options.
- [x] Selected `plaught-armor/ps-recomp` with R5900 and Vulkan 1.3 support.
- [x] Verified the selected commit was updated three days before selection,
  satisfying the one-month maintenance requirement.
- [x] Pinned framework commit
  `8ab7c5b081fa59f761783787216b067d48120374`.
- [x] Pinned Odin `dev-2026-10` and its Windows archive SHA-256.
- [x] Recorded GPL-3.0 licensing and added the repository license.
- [x] Built the pinned framework's recompiler on Windows.

## 2026-11-16 - Native port

- [x] Exported a game-specific PS2 port.
- [x] Added the generated Odin bootstrap entry point and local runtime
  configuration.
- [x] Added a native PowerShell bootstrap workflow in
  [`tools/setup.ps1`](../tools/setup.ps1).
- [x] Recompiled 8,684 game functions into 15 generated packages.
- [x] Generated approximately 31.57 MiB of native source.
- [x] Linked `port\macross-recomp.exe` successfully.
- [x] Added a Vulkan-first runner in [`tools/run.ps1`](../tools/run.ps1).
- [x] Forced the checked-in PS2 renderer setting to `SW=0`.

## 2026-11-16 - Vulkan verification

- [x] Ran the original game for a bounded 600-frame compatibility test.
- [x] Confirmed selection of an NVIDIA GeForce RTX 5070.
- [x] Confirmed the GPU renderer at scale 1.
- [x] Presented 599 frames before the requested frame-limit exit.
- [x] Confirmed `fallback: false`.
- [x] Confirmed no fatal runtime error during the bounded run.
- [x] Recorded the remaining SIF and dynamic IOP/VU issues rather than hiding
  them.

## 2026-11-16 - Translation integration

- [x] Located the existing Macross PS2 fan-translation tooling.
- [x] Verified its baseline, machine-translation, executable-string, and
  subtitle coverage.
- [x] Detected that the pinned translation revision declares no explicit
  license and kept it external.
- [x] Pinned translation revision
  `4339a4485149a52aa2b0633e093511d452885fb5`.
- [x] Added [`tools/translate.ps1`](../tools/translate.ps1).
- [x] Built a full English image with 1,811 optional radio captions.
- [x] Verified 2,818 writes and a 190,696-byte compressed script with 7,960
  bytes spare in the rebuilt allocation.
- [x] Added an explicit `--allow-patched` / `-AllowPatchedImage` gate after
  confirming the patch intentionally changes 52 ELF strings.
- [x] Recompiled the translated image.
- [x] Completed a second 600-frame Vulkan compatibility run without a fatal
  error.

## 2026-11-16 - Analysis tools

- [x] Implemented a bounds-checked ISO 9660 parser comparing the PVD volume
  size and logical block size, and directory-record extent, length, and
  volume sequence in both byte orders.
- [x] Implemented embedded CVM discovery and reading.
- [x] Implemented exact-disc, executable, container, and ELF inventory output.
- [x] Implemented safe local asset extraction with traversal protection.
- [x] Implemented ELF32 section and symbol parsing.
- [x] Implemented optional symbolic R5900/MIPS disassembly.
- [x] Implemented validated MRG offset-table parsing.
- [x] Implemented recursive MRG classification and local leaf extraction.
- [x] Built and pinned the LGPL-2.1 CRICMP utility for local analysis.
- [x] Decompressed all 310 compressed assets in `BIN.CVM`.
- [x] Inventoried all 691 files in active CVMs.

## 2026-11-16 - Engine and format findings

- [x] Identified Metrowerks MIPS compiler version `2.4.1.01`.
- [x] Identified GFX2 engine/version strings and model/motion signatures.
- [x] Counted 17,684 named ELF symbols.
- [x] Confirmed CVM's embedded ISO begins at `0x1800`.
- [x] Confirmed CRICMP 2.10 header fields and output-size metadata.
- [x] Confirmed the generic MRG offset-table layout and recursive nesting.
- [x] Mapped representative model, motion, texture, and collision archive
  hierarchies.
- [x] Confirmed GFX2OBJ's four top-level offsets.
- [x] Confirmed 32-byte model name records in the sampled `0200` file.
- [x] Confirmed a 106-entry, 176-byte node table by exact boundary arithmetic.
- [x] Confirmed PS2 VIF UNPACK commands in model packet data.
- [x] Confirmed TIM2 alignment mode 1 places the first picture at `0x80`.
- [x] Confirmed VF-1J TIM2 picture sizes, indexed image type, 256-color CLUT,
  dimensions, and archive padding.
- [x] Identified the motion/skeleton `0x3B71` framing and candidate count/frame
  fields.
- [x] Identified the collision signature, AUTH framing, ADX/AFS layout, and
  Sofdec program streams.
- [x] Documented confirmed facts separately from provisional semantics for the
  planned Blender importer.

## 2026-11-16 - Documentation

- [x] Added a user-facing build, run, translation, and analysis guide.
- [x] Documented framework selection and maintenance evidence.
- [x] Documented engine architecture and native runtime boundaries.
- [x] Documented detailed disc, archive, model, texture, motion, collision,
  text, audio, video, and ELF formats.
- [x] Documented recompilation risks and a first-release compatibility bar.
- [x] Documented translation quality, coverage, patching, and legal boundaries.
- [x] Added source attribution and research-confidence rules.
- [x] Moved completed checklist items out of active
  [`TODO.md`](../TODO.md).

## 2026-11-16 - Local runtime localization

- [x] Kept the exported publisher
  `localization\_base\strings.csv` and locally imported
  `localization\en-fan\strings.csv` ignored and out of the tracked tree.
- [x] Added the project-authored 47-string `en-system` executable-message mod
  and the `en-fan` manifest, which includes it but requires a locally
  supplied fan table.
- [x] Added launcher selection, CP932 text conversion, CSV import/checking,
  mod inclusion, and runtime string replacement without rewriting the image.
- [x] Preserved inherited settings through environment, player, repository,
  and global precedence; save only changed launcher options in the player
  settings while retaining unrelated rows.
- [x] Added transactional CVM file overlays, including validated in-place or
  zero-filled spare-sector allocation and read-time metadata updates. A failed
  installation does not leave a partial read hook.
- [x] Limited the runtime subtitle change to supported Japanese voiced
  records with attribute `0`; other values, including the still-unknown `2`
  and `3`, are preserved.
- [x] Added synthetic runtime tests for discovery, settings, shadow tables,
  subtitle attributes, and overlay success/failure paths. Full visual and
  in-game subtitle coverage remains open.

## 2026-11-16 - Build and validation hardening

- [x] Pinned the ordered framework patch series, including padman handling
  and the disc-read hook. Setup checks patch state and records generated-source
  provenance; incremental builds check that provenance. Legacy generated
  source without it remains usable only with a warning.
- [x] Hardened ELF disassembly with complete file-backed range checks,
  corrected R5900 decoding and jump targets, and per-word `.word` fallback;
  added synthetic ELF tests.
- [x] Added synthetic ISO/CVM and malformed-directory, MRG offset, ELF, and
  patched-image trust tests, including exact-disc hash behavior.
- [x] Added the opt-in [`tests\smoke.ps1`](../tests/smoke.ps1), which builds
  the pinned, patched framework for the exact original disc and strictly
  asserts Vulkan selection, compatibility JSON, frame progress, no fallback,
  and an empty fatal field. Separate synthetic PowerShell tests cover setup
  forwarding, the smoke contract, and patch application.
- [x] Documented the exact-disc smoke command and its limits in
  [`README.md`](../README.md); the earlier 600-frame observations above are
  not evidence of visual correctness or full-game compatibility.
