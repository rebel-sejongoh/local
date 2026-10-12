feat(dnc_binutils)!: state TU dot-product length as dot_len

## Motivation

- `run_mode` sets the TU dot-product length, but its name does not say so. `FMA ... src0=4 ... {run_mode=2}` is hard to read as a 4-element dot product over LRF4 through LRF7.
- A register-group `src0` was encoded as a group index (`LRF[4:7]` → 1), but the VP reads it as the group's first register.
- The disassembler printed an undefined encoding as a raw number, which looked valid and assembled back.
- `.bypass` forwards south only, but its name does not say which direction.

## Solution

- A computing TU instruction states `dot_len`; `run_mode = log2(dot_len)`. The assembler checks it against the `LRF[a:b]` register count.
  `FMA south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {dot_len=4, uc.degree=4, uc.src1_inc=1, be=1}`
- `LRF[a:b]` encodes its first register `a`.
- `.bypass` is removed. A forward names its destination, as in `FMA south_tgt=src0, src0=FIFO_NORTH`, and takes no `dot_len`.
- The disassembler raises an error on an undefined encoding. A raw number is written with the `.raw` mnemonic suffix, as in `FMA.raw src0=4`.
- Migration: `run_mode=N` → `dot_len=2^N`, numeric `src0` → `LRF[a:b]`, `<op>.bypass dst=SOUTH, srcN=X` → `<op> south_tgt=srcN, srcN=X`. The `.s` program fixtures are migrated, and the binaries they assemble to are unchanged.

## Verification

- `uv run pytest` in `PrimitiveAuthor/dnc_binutils`, `moon run ':static-check-*' --affected` and `moon run repolint:lint-all` pass.
- On the VP, rebel_compute_lib2's dense kernel matches its golden output with `src0=4` for LRF4 through LRF7, and is wrong with `src0=1`.

## Risks

- The ISA document's FMA src0 table still describes a group index.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
