# Testing

Run commands from the repository root.

## Synthetic and contract tests

Run synthetic parser, patched-image trust, disassembler, and localization tool
tests without a game image:

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

## End-to-end Windows smoke test

For the opt-in end-to-end Windows build and Vulkan smoke test, supply the
**original exact disc**, not a patched image:

```powershell
.\tests\smoke.ps1 -Image "F:\path\to\Macross.iso" -Frames 600
```

The smoke test runs full setup with `-ExactDisc`, then headless Vulkan at scale
1. It requires successful exits, a Vulkan device line, exactly one GPU
renderer line, and exactly one strictly parsed `compat` JSON record. Duplicate
object keys are rejected case-insensitively. The record must contain:

- `system: "ps2"`;
- `result: "frames"`;
- the locked framework commit;
- integer `frames` at least the requested limit;
- integer `shown` with `0 < shown <= frames`;
- boolean `fallback: false`; and
- an empty `fatal` string.

Exactly one matching `frames: ... reached` line is also required. The default
and minimum are 600 frames. Setup and run timeouts default to 1,800 and 600
seconds; adjust them with `-SetupTimeoutSeconds` and `-RunTimeoutSeconds`.
Timeouts stop the child process tree, and inherited `MACROSS_*` overrides are
cleared.

The smoke test regenerates source, rebuilds the executable, and rewrites
`local.tsv` for the supplied image. It proves bounded startup and frame
progress, not visual correctness or a full playthrough.
