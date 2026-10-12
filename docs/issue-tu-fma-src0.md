TU FMA: the ISA document's src0 table disagrees with the VP for run_mode=2

## Problem

The src0 table on the FMA page of the REBEL EVT1 ISA document (`rebel/evt1/tu/FMA.html`) interprets src0 as a register-group index when `run_mode` > 0:

| src0 | run_mode=0 | run_mode=1 | run_mode=2 |
|---|---|---|---|
| 0x0 ~ 0x2 | LRF[0] ~ LRF[2] | {LRF[1],LRF[0]} ~ {LRF[5],LRF[4]} | {LRF[3]..LRF[0]} ~ {LRF[11]..LRF[8]} |
| 0x3 ~ 0x5 | LRF[3] ~ LRF[5] | {LRF[7],LRF[6]} ~ {LRF[11],LRF[10]} | N/A |
| 0x6 ~ 0xB | LRF[6] ~ LRF[11] | N/A | N/A |

The virtual platform (VP) interprets src0 as the group's first register instead.
With `run_mode=2`, `src0=4` selects LRF4 through LRF7 (LRF is the TU's local register file), and the table leaves `src0=4` undefined.
`run_mode=1` was not tested on the VP.

## Evidence

- rebel_compute_lib2, the kernel library whose output the VP runs, emits this FMA in its dense kernel (M=16, K=1024, N=64), in all 8 TU rows of all 16 DNCs:
  ```asm
  FMA  src0=4 src1=8 src2=2 tgte=2 tgts=3 tgtrf=0xf url=0x12 urldeg=2 s1url=1 run_mode=2 be=1
  ```
- PrecSim, the precision simulator, reads `ctx.lrf[src0]` through `ctx.lrf[src0 + 3]` for any `run_mode` > 0 (`third_party/rebel_prec_sim/prec_sim_process.py`, `TUProcess.run`).
- VP build `260521_vp_rebel_evt1_arbcal`, `src0=0` and `src0=4` tested with `run_mode=2`:
  - The kernel as emitted matches rebel_compute_lib2's golden output within rounding.
  - The table encodes the same LRF4 through LRF7 as `src0=1`. Changing only those FMAs to `src0=1` gives wrong output, with a correlation of 0.80 to the golden output.
  - The cycle count is the same in both runs, so only the registers read differ.
- dnc_binutils, the assembler, encodes src0 as the first register (#2181).

## Request

- Correct the src0 table to the first-register interpretation.
- State whether the first register must be aligned to the group size.
- Check whether the other FMA-family pages have the same table: FMABF, I8FMA, I8FMABF, F8FMA, F8FMABF, I4FMA, I4FMABF, F8F8MA, F8F8MABF.
- The FMA page says an unrolled FMA (`urldeg`, `s0url`) may advance src0 by more than 1 depending on `run_mode`. State the step for each `run_mode` under the first-register interpretation.
