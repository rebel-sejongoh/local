## Motivation

- `dnc_dec.disasm` prints an init image as textual assembly, but dnckit cannot assemble that text back into the image.
- A textual representation of the assembly language forces the language to be defined precisely.
- People can read, analyze, diff and edit code in that representation.
- A planned performance regression framework will store assembly code instead of binaries wherever possible.

## Solution

- `dnc-asm` and `dnc-disasm` are new inverse commands: together they round-trip an init image through textual assembly. `dnc-disasm` runs `dnc_dec.disasm`.
- `dnc_dec.disasm` now also prints each block's SPR and LCCR words and each instruction's `fill` bits, which `dnc-asm` needs.
- A value that does not fit its field raises `AsmError` instead of being truncated.
- `dnckit.tools` gets its own suite, `PrimitiveAuthor/dnckit/tests`, which `ci-lint` runs.
- No microcode build runs `dnckit.tools`. `ci-mcc` covers only dnckit's top-level modules (#138).

## Verification

- `uv run pytest tests` in `PrimitiveAuthor/dnckit` passes. The tests take an image built with rebel_compute_lib2. They pass it through `dnc_dec.disasm` and `dnc_asm.assemble` and check that the bytes are unchanged. They also check that malformed text raises `AsmError`.
- The `ci-primitives-bytes` tests build init images. Each image comes back byte-identical after `dnc_dec.disasm` and then `dnc_asm.assemble`. A local pytest plugin around `build_init_bytes` checked this. The plugin is not committed.
- `make test`: every lane passes except `ci-host`. In that run, `ci-host` failed on `test_no_ci_lane_is_vacuous`. The test found the `ci-socsim-accept-socsimfw-*` lanes empty while they ran in parallel. This change touches none of those lanes. `make ci-host` alone passes.

## Risks

- dnckit, `cerun` and `precsim` each read and write PrecSim's init text, so their codecs can become inconsistent.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
