# Recompilation issues

## Verified compatibility baseline

Two separate 600-frame compatibility runs have completed:

| Image | Result |
|---|---|
| Exact Japanese `SLPM-65405` image | Native build reached requested frame limit |
| Full English/subtitle patch | Recompiled native build reached requested frame limit |

Observed runtime properties:

- Vulkan GS renderer selected;
- NVIDIA GeForce RTX 5070 selected;
- internal render scale 1;
- 599 frames presented before the 600-frame limit;
- `fallback: false`; and
- no fatal runtime error.

This baseline should be rerun after any framework, toolchain, recompilation
configuration, executable patch, or low-level runtime change.

## Known runtime gaps

### Unimplemented SIF operation

The current run reports:

```text
SIF server 80000100 fno 20
```

The operation needs to be identified from the loaded IOP module and call site,
then implemented or safely routed through an existing runtime service.
Suppressing the message without reproducing the operation is not a fix.

### Interpreted IOP code

The Emotion Engine executable is heavily statically recompiled, but IOP-side
behavior still relies on dynamic/interpreted execution. This affects areas such
as file streaming, sound, controller services, memory cards, and movie
playback.

Priority should be based on measured hot paths and compatibility failures, not
on converting every IOP instruction preemptively.

### Uncaptured VU microcode

No VU1 programs were captured during the initial export. The game can build or
upload microprograms at runtime, so the current runtime must interpret those
paths. Capture should cover multiple missions, model types, effects, and movie
or menu scenes before treating the set as complete.

An incomplete static VU set can be more dangerous than explicit interpretation
if it incorrectly assumes a dynamic program is known.

### Limited behavioral coverage

Boot and frame presentation do not validate:

- mission scripting;
- every Valkyrie form and enemy;
- transparent effects and unusual GS state;
- ADX music/voice streaming;
- Sofdec playback;
- all controller modes and vibration;
- memory-card create/load/save/error handling;
- route progression and endings; or
- long-session resource behavior.

Compatibility claims must name the tested scene and duration.

## Windows and Vulkan concerns

Upstream describes Windows game use as comparatively untested even though it
has Windows automation. This project supplies useful evidence for one machine,
not broad platform certification.

Potential driver-sensitive areas include:

- framebuffer feedback;
- texture formats and palette state;
- blending and PS2 alpha semantics;
- interlacing;
- depth precision;
- synchronization around GS transfers; and
- presentation timing.

Test AMD and Intel hardware before making a general Windows compatibility
claim.

## Patched executable trust

The original disc check expects the executable SHA-1:

```text
84ff167ee9612966e5027beabb7b920e7cf18920
```

The tested full translation produced:

```text
4180733603198a9aeb69bd12d18b4d5a78129d99
```

The difference is intentional: 52 executable-resident system strings are
patched. [`tools/setup.ps1`](../tools/setup.ps1) requires
`-AllowPatchedImage`, which maps to the verifier's `--allow-patched` option.

This is a trust gate, not a second identity check. It accepts a structurally
valid image with a changed executable of the expected size. Only use it for a
patch generated from a reviewed, pinned translation checkout.

## Generated-code and build concerns

- Generated source is large and must stay out of version control.
- Function/package counts are useful regression signals, but matching counts
  do not prove matching semantics.
- Odin is pinned because compiler changes may affect both framework build and
  generated-code behavior.
- The source image path is written to ignored `local.tsv`; moving the image
  requires rerunning setup.
- Recompilation is tied to executable addresses. A different region or
  revision cannot be treated as compatible because it boots to the same title.

## Translation-specific issues

- The story translation is unreviewed machine translation.
- Enabling subtitles changes a record attribute for 1,811 lines and should be
  tested for window overflow in every mission.
- English wraps by character count rather than word boundaries.
- Art-based Japanese remains in TIM2 textures.
- If the rebuilt `BOOTDAT.CMP` changes length, both ISO 9660 little- and
  big-endian length fields must be updated.
- `JPN.CVM` has no free sectors. The external translation tool relocates an
  expanded container into the all-zero `ETC.CVM` allocation and updates outer
  directory metadata.

## Triage procedure

When a new failure appears:

1. reproduce it on the exact original image;
2. record framework commit, Odin version, GPU, driver, and command line;
3. reduce to the earliest deterministic frame or input sequence;
4. determine whether the failure is EE code, IOP service, VU execution, GS
   rendering, host input/audio, or patched data;
5. compare original and translated images only after the original path is
   understood;
6. make the smallest runtime or binding change that models the missing
   behavior; and
7. rerun both 600-frame baselines plus the focused reproducer.

Do not replace errors with success-shaped defaults. Missing services should
remain visible in logs until their behavior is implemented and tested.

## Compatibility definition for a first release

A first public build should require, at minimum:

- a complete playthrough of each route;
- correct Vulkan output on NVIDIA, AMD, and Intel;
- controller and memory-card coverage;
- ADX and SFD playback coverage;
- no unknown SIF calls in ordinary play;
- documented handling of dynamic VU and IOP code;
- repeatable original and translated builds; and
- packaging that contains no publisher data.
