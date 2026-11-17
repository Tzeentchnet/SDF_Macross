# Current status

| Area | Status |
|---|---|
| Windows x86-64 native build | Working |
| Software renderer | Compatibility fallback; ~31 FPS on the animated main menu after focused fast paths |
| Vulkan renderer | Recommended; deterministic GS memory ordering and 59.9 FPS on the tested main menu and opening movie; final Mission 2 revalidation is pending |
| Output upscaling | FSR 1 EASU + RCAS or linear scaling on Vulkan |
| Audio | Adaptive slow-host pacing plus ordered SPU2 block-transfer capture; the tested menu and opening movie hold full-speed audio |
| Original Japanese image | Reaches a bounded 600-frame compatibility run |
| English-patched image | Recompiles and reaches the same 600-frame run |
| Static EE recompilation | 8,684 functions in 15 generated packages |
| Runtime VU1 programs | Private local captures can be compiled; 71 programs cover the scripted first- and second-mission routes tested so far |
| Runtime localization | Project-created multilingual CSV and runtime translation functions planned for the release; seven machine-translated language columns remain unreviewed |
| Patched-image translation | External, optional, and reproducibly pinned |
| Full-game compatibility | Not yet established |
| Release-ready port | No; this is an early bring-up and reverse-engineering project |

The successful compatibility run proves that the native executable starts,
selects the PS2 Vulkan GS renderer, and presents frames. It does not yet prove
that every mission, save path, audio path, movie, controller, or ending works.
See [Recompilation issues](recomp-issues.md) and [Remaining work](TODO.md).
