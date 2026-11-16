# Remaining work

Completed milestones are recorded in
[docs/completed-work.md](docs/completed-work.md). This file intentionally
contains only unfinished work.

## Runtime compatibility

- [ ] Play through every route and mission while recording deterministic
  checkpoints, crashes, rendering errors, and timing-sensitive behavior.
- [ ] Identify and implement or correctly route SIF server `0x80000100`,
  function `20`.
- [ ] Capture runtime-generated VU1 microprograms, add them to the recompilation
  input, and verify that VU execution no longer depends on uncaptured dynamic
  code for known scenes.
- [ ] Reduce interpreted IOP execution by identifying hot modules and selecting
  a safe recompilation or HLE strategy for each.
- [ ] Validate controller mapping, analog input, vibration, memory-card
  creation/load/save, audio mixing, ADX streaming, and SFD playback.
- [ ] Test Vulkan behavior on AMD and Intel hardware and on more than one
  driver version.
- [ ] Add long-running soak tests beyond the current 600-frame boot check.

## Recompiler and build

- [ ] Decide how to package a release without redistributing the ISO, extracted
  files, generated code derived from the executable, or translation content.
- [ ] Recheck upstream maintenance before each dependency update and record the
  new commit/date/license evidence before changing the lock file.

## Blender importer and asset formats

- [ ] Decode every field in the 176-byte `GFX2OBJ` node record and establish
  parent/child, mesh, material, visibility, and transform semantics.
- [ ] Implement a VIF command-stream decoder, including `STCYCL`, masks,
  signed/unsigned UNPACK modes, row/column registers, alignment, and VU-memory
  addressing.
- [ ] Determine the VU-side vertex program semantics and map unpacked streams
  to positions, normals, UVs, colors, weights, bones, and triangle strips.
- [ ] Confirm strip restart/degenerate conventions and winding order across
  multiple models.
- [ ] Decode TIM2 pixel and CLUT storage for every observed image type,
  including palette permutation, GS swizzle, mipmaps, and PS2 alpha expansion.
- [ ] Confirm the game-to-Blender coordinate-system, handedness, unit scale,
  matrix order, and UV origin.
- [ ] Decode `.bon` skeleton records and `.mot` animation channels, compression,
  interpolation, frame rate, and transform conventions.
- [ ] Decode the `CLS COLLISION LIBLARY VER 1.00` header, shape records, and
  hierarchy.
- [ ] Implement a Blender add-on only after the parser can round-trip metadata
  and export a known model with correct hierarchy and textures.
- [ ] Add golden metadata tests using synthetic fixtures; never commit extracted
  game assets as test fixtures.

## Translation

- [ ] Have a fluent Japanese-speaking translator review the machine-produced
  story translation.
- [ ] Audit the nine intentionally untranslated entries and preserve save-name
  compatibility where required.
- [ ] Translate texture-based title cards, logos, and menu art through a
  separate, legally clean art pipeline.
- [ ] Test all subtitle attributes and determine the behavior of record
  attributes `2` and `3`.
