# K-outer matmul on the VP: VU-register accumulators (C) vs SP partial sums (A) vs rcl2

The two K-outer schedules of [`matmul-k-outer-schedule.md`](matmul-k-outer-schedule.md), written as assembly and
run on the VP over a small shape sweep, with rcl2's dense as the reference:

- **C, "register psum"**: R tiles' accumulators in VU registers (4R LRFs, R ≤ 4). R = 1 is mcc's order
  (M outside K).
- **A, "SP psum"**: every tile's partial sum in SP, read back by the SPLU and rewritten by the SPSU each K
  block. This is the order rcl2's dense uses.

Accumulation over K stays inside one DNC: the 16 DNCs split M only. The code, cases and scripts are in
[`matmul-kouter-vp/`](matmul-kouter-vp/).

## Setup

`y[M, 64] = x[M, K] @ w[K, 64]`, DLFloat16, R100 EVT1, VP `260521_vp_rebel_evt1_arbcal`.

| | |
|---|---|
| Split | DNC `d` takes `M/16` rows, each NCore half of them: `T = M/128` tiles of 4 rows per NCore; `KB = K/64` K blocks |
| Data | rcl2's dense test captured with `capture_rcl2.py` (manifest, SHM layout, rcl2's code); inputs from the manifest's seed |
| Code | written by [`scripts/gen_mm.py`](matmul-kouter-vp/scripts/gen_mm.py), every unit's program; assembled, closed with mcc's cluster fence (`xdnc_fence`), run with `run_vp.py` |
| Check | every run's output against `x @ w` in float64 from the same SHM inputs ([`scripts/check.py`](matmul-kouter-vp/scripts/check.py)) |
| NC floors | **N**: the NCLU loads and NCSU stores of A, with no compute. **Nrcl2**: the same for rcl2's split, read from rcl2's NCLU descriptors ([`scripts/gen_nc_rcl2.py`](matmul-kouter-vp/scripts/gen_nc_rcl2.py)) |

The NCLU loads in the order each schedule consumes (A: per K block; C: per group and K block) and signals both
SPLUs per chunk. A's SPSU signals the SPLU once per K block that the partial sums are written. mcc cannot build
these shapes (its SPSU block outgrows the 255-entry instruction buffer), so C with R = 1 stands in for mcc's
order. N = 256 is missing: rcl2's capture fails for it (`wrong scale dim`).

## Results

Cycles at which the VP stops, all DNCs returned. Every output matches `x @ w` (largest error over the largest
output, last two columns).

| Shape | T | KB | rcl2 | A | C, R=4 | R=3 | R=2 | R=1 | N | Nrcl2 | err rcl2 | err A, C |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| m512_k256 | 4 | 4 | 1993 | 2080 | 2104 | 2384 | 2442 | 2936 | 1590 | 1177 | 1.6e-3 | 1.7e-3 |
| m512_k1024 | 4 | 16 | 4152 | 5338 | 5356 | 6584 | 6608 | 8726 | 4923 | 3150 | 1.7e-3 | 3.3e-3 |
| m2048_k256 | 16 | 4 | 3245 | 3450 | 3670 | 4230 | 4790 | 6754 | 2735 | 2567 | 1.8e-3 | 1.5e-3 |
| m2048_k1024 | 16 | 16 | 7818 | **7696** | 10042 | 12408 | 14686 | 23224 | 6977 | 6462 | 1.3e-3 | 3.3e-3 |

Also in [`matmul-kouter-vp/results.tsv`](matmul-kouter-vp/results.tsv). Relative to rcl2:

![VP cycles of SP psum and register psum over rcl2's, per shape, with the NC floors](matmul-kouter-vp/cycles.svg)

The bars are cycles over rcl2's for each shape (labels: cycles). The dashed red line is the NC floor of this
experiment's split (N), the dotted line that of rcl2's split (Nrcl2). Drawn by
[`scripts/plot.py`](matmul-kouter-vp/scripts/plot.py).

- **SP psum** (variant A, the hand-tuned order rcl2 uses): the weights are latched once per K block, and every
  tile's partial sum round-trips through SP each K block. The SPSU must signal the SPLU before a partial sum
  is read back, the first K block is peeled (nothing to read yet) and the last one stores to the output instead
  of SP, and the SPLU sends x ahead of the partial sums so the pipeline does not stall.
- **Register psum, R** (variant C): the R tiles' partial sums stay in VU registers, so the only value carried
  across K blocks lives inside the VU. No unit waits on another across iterations and no K block is special,
  so the program is easier to write and check. The price is that the weights are latched once per group of R
  tiles, and the VU's 16 registers cap R at 4 (4 per tile).

## C against A: weight latches

![Speed relative to SP psum, per shape, for SP psum and register psum with R = 1..4](matmul-kouter-vp/speed.svg)

Speed relative to SP psum (SP psum's cycles over each one's; higher is better), without rcl2; the labels in
the bars are cycles. With 4 tiles per NCore (T = 4) register psum reaches SP psum at R = 4; with T = 16 it
stays below, since R cannot exceed 4.

Each NCore latches `KB` weight tiles in A and `⌈T/R⌉ · KB` in C. A latch streams 64 w lines through
SPLU → XVU → TU north.

| T | A | C, R=4 | R=3 | R=2 | R=1 |
|---|---|---|---|---|---|
| 4 | KB | KB | 2 KB | 2 KB | 4 KB |
| 16 | KB | 4 KB | 6 KB | 8 KB | 16 KB |

- With `T = 4`, C with R = 4 latches as often as A and runs within 1.2% of it. R = 3 needs two groups (3 + 1),
  so it costs the same as R = 2.
- With `T = 16`, R = 4 still latches 4 times as often as A, and C falls behind: 30% at K = 1024.
- Each extra latch costs about 50–70 cycles where the compute is the bottleneck (m2048_k1024, m512_k1024),
  close to the 64 w lines at one line per cycle; less where the NC traffic hides it (m2048_k256).
- The VU's 16 LRFs cap R at 4, so C matches A only while `T ≤ 4` tiles per NCore (16 rows).

## Why rcl2 is faster than A

rcl2 splits the work differently. Read from its NCLU descriptors:

| Shape | DNCs used | K split across DNCs | Rows per DNC |
|---|---|---|---|
| m512_k256 | 12 | 2 | ~86 |
| m512_k1024 | 16 | 4 | 128 |
| m2048_k256 | 10 | none | ~205 |
| m2048_k1024 | 12 | 2 | ~342 |

So in three shapes rcl2 reduces partial sums across DNCs, which this experiment excludes, and it uses fewer
DNCs when K is short. Both cut the w lines read from SHM, since every DNC loads the w of its K range.

### rcl2's structure inside a DNC

rcl2 is weight-stationary and runs the order of variant A inside each DNC. Its units for m512_k1024, DNC 0
(64 rows per NCore, K blocks 0..3):

| Unit | Program |
|---|---|
| TU | `loop 4 (K block) { latch 64 w lines into LRF0..7; pass; loop 16 (tile) { mac; drain } }` |
| XVU | per K block: 64 w lines to the TU, then 64 x lines (all 16 tiles of the block) to the AB |
| ABSU, ABLU | the 16-block AB ring handed over in halves of 8 blocks |
| SPLU | per K block: the w lines, x as two 32-line bursts, then each tile's partial sum (2 + 4 lines) to the VU; one SPSU sync per K block |
| VU | first K block `FMAHP` (partial sums written as high and low parts, 6 SP lines per tile); later blocks `FADDHP` of the SP partial and the TU result; at the end the cross-DNC add (`FMA src0=FIFO_SPLU, src2=FIFO_XVU`) and scale and offset |

Weight latches and tiles per latch, per NCore:

| Shape | A (this experiment) | rcl2 |
|---|---|---|
| m512_k256 | 4 latches × 4 tiles | 2 × ~11 |
| m512_k1024 | 16 × 4 | 4 × 16 |
| m2048_k256 | 4 × 16 | 4 × ~26 |
| m2048_k1024 | 16 × 16 | 8 × ~43 |

### How rcl2 splits K and reduces

A group of `s` neighboring DNCs shares the same rows; DNC `j` of the group takes the contiguous K range
`j · K/s .. +K/s` (w and x of those K blocks only). In m512_k1024 (`s = 4`), DNCs 0..3 take K blocks 0..3,
4..7, 8..11, 12..15 of rows 0..127.

1. **Local K accumulation.** Each DNC runs the order of variant A over its K/s blocks: partial sums in SP, in
   high precision.
2. **Reduction tree.** After the matmul, a binary tree over the group, `log2 s` levels:

   ```
   s = 4:   level 1   DNC 1 → DNC 0     DNC 3 → DNC 2     (in parallel)
            level 2   DNC 2 → DNC 0
   s = 2:   level 1   DNC 1 → DNC 0
   ```

   The sender keeps its partial in its own SP. Its NCSU issues one `MESYNC` put+get to the receiver's NCLU:
   the put says the partial is ready, the get waits until the receiver has taken it. The receiver's NCLU waits
   for that put, loads the sender's partial straight from the sender's SP, and answers with a put. The load is
   an NC load whose address has no SHM tag: `CBR` = the sender's SP line and `CAR` = `0x8000 ×` (sender −
   receiver), 0x8000 lines being one DNC's SP. No partial goes through SHM. The receiver's SPLU streams the
   received partial and its own to the VU (one through the XVU), the VU adds them
   (`FMA src0=FIFO_SPLU, src2=FIFO_XVU`), and on the root applies scale and offset before the store.
3. **Store.** Only the group's root (`j = 0`) stores the rows to SHM.

### Why the K split pays despite the reduction

It is the weights. A K split of `s` cuts them twice:

1. **From SHM.** Each DNC loads only the w of its K range, so the 16 DNCs read w `16 / s` times instead of 16
   times. Most of the measured gap is this (next table and [The gap, split](#the-gap-split)).
2. **Into the TU.** Each DNC gets `s` times the rows, so one latched weight tile serves `s` times the tiles,
   and each NCore latches `1 / s` as often (previous table). A latch costs about 64 cycles.

The reduction costs much less than it saves: it moves only the partial rows, it never touches SHM, and it has
`log2 s` (one or two) levels.

Per 64 output columns, with `P` DNCs and the K split `s`, the lines the NC units move are

- w: `(P / s) · K`, since each of the `P / s` row groups reads all of w once;
- x: `M · K/64` and y: `M`, the same for any split;
- the reduction: `(s − 1) · M` partial lines, read DNC to DNC.

Splitting K trades the first term against the last. It pays while `P · K / s` falls faster than `(s − 1) · M`
grows; the total is smallest near `s = √(P · K / M)`. With `P = 16` that is 2.8, 5.7, 1.4 and 2.8 for the four
shapes, and rcl2 picks `s = 2, 4, 1, 2`: the split follows the w re-reads. For m2048_k256, where a split
does not pay, rcl2 instead leaves 6 DNCs idle, which also cuts the w copies (10 instead of 16).

| Shape | w + x + y lines, M-only split | rcl2's split: w + x + y | + partials | N / Nrcl2 |
|---|---|---|---|---|
| m512_k256 | 4096 + 2048 + 512 = 6656 | 1536 + 2048 + 512 = 4096 | 512 | 1.35 |
| m512_k1024 | 16384 + 8192 + 512 = 25088 | 4096 + 8192 + 512 = 12800 | 1536 | 1.56 |
| m2048_k256 | 4096 + 8192 + 2048 = 14336 | 2560 + 8192 + 2048 = 12800 | 0 | 1.07 |
| m2048_k1024 | 16384 + 32768 + 2048 = 51200 | 6144 + 32768 + 2048 = 40960 | 2048 | 1.08 |

The NC floors move with the traffic but less than in proportion (the floor is not pure bandwidth: each NCLU
issues its own loads, and the DNCs share the SHM bus). The reduction runs after the matmul, `log2 s` levels of
one load of the group's rows and one VU pass each; its cost is inside the rcl2 cycles above and was not
measured on its own.

### The gap, split

Splitting the gap into the NC floors and what each code adds above its floor:

| Shape | A − rcl2 | N − Nrcl2 (split) | A − N | rcl2 − Nrcl2 |
|---|---|---|---|---|
| m512_k256 | 87 | 413 | 490 | 816 |
| m512_k1024 | 1186 | 1773 | 415 | 1002 |
| m2048_k256 | 205 | 168 | 715 | 678 |
| m2048_k1024 | −122 | 515 | 719 | 1356 |

- The whole gap comes from the split. Both codes spend most of their time on NC traffic, and rcl2's split moves
  less of it (N − Nrcl2 ≥ A − rcl2 in every shape but one).
- Above its own floor, A adds less than rcl2 in three shapes, and 37 cycles more in m2048_k256, the one shape
  where both split only M. A's on-chip schedule is not what makes it slower.
- In m2048_k1024, where rcl2's K split saves least, A is 122 cycles faster than rcl2.

## Other findings

- **Precision.** A and C accumulate in DLFloat16 (VU registers or SP lines); rcl2 accumulates in high precision
  (`FMAHP`, 6 SP lines per tile on EVT1 instead of 4). At K = 1024 A's error is twice rcl2's. A with rcl2's
  high-precision partial sums would move 50% more SP lines per tile.
- **AB handshake.** A first version released the AB one block at a time, with `L` blocks of credit
  (`L = min(8, T)`). Register psum hung on the VP for every R at T = 16 (125000-cycle limit), though its
  counts balance; SP psum did not. With a 6000-cycle limit on m2048_k256, R = 4 hung with L = 1, 7 and 8 and
  finished with L = 2..5 ([Artifacts](#artifacts)). The version measured here uses mcc's and rcl2's handshake:
  the ABSU writes 8 blocks, then waits until the ABLUs have released the half of the 16-block ring it is about
  to overwrite. The hang is not explained.

## Limits

- One output block (N = 64); a larger N repeats the same nest per 64 columns.
- Nrcl2 approximates rcl2's cross-DNC reduction traffic (one partial per partner, loaded by the root).
- A signals once per K block; finer signals would let the SPLU read a tile's partial sums earlier.
- VP cycles only; the VP has no per-unit statistics, so the overheads above the NC floor are not split further.

## Artifacts

Everything a run used or produced is kept in [`matmul-kouter-vp/`](matmul-kouter-vp/) (26 MB), so each number
above can be traced to the code that ran.

| Item | Value |
|---|---|
| Date | 2026-10-22 and 23 |
| codesigner | `082b42cfa` (branch `dnc-binutils-legacy-dir`): `run_vp.py`, `capture_rcl2.py`, `dnc_binutils`, mcc's `xdnc_fence` |
| rcl2 | `5e1413153067` (the capture's `manifest.json`), dense test `test_rbln_initgen_dense_fp16.py` |
| VP | `260521_vp_rebel_evt1_arbcal`, 2 clusters × 8 DNCs, 125000-cycle limit |
| Inputs | random DLFloat16 from the manifest's seed (0), regenerated by `run_vp.py` on every run |

The assembly, one directory per run, each with `raw_<d>.s` as generated and `init_<d>.s` as run (closed with
the cluster fence) for all 16 DNCs:

| Directory | Generator | Runs |
|---|---|---|
| `asm/<shape>.A`, `asm/<shape>.C1` .. `C4` | `scripts/gen_mm.py` (half-ring AB handshake) | the results above |
| `asm/<shape>.N` | `scripts/gen_nc.py --variant N` | NC floor, this experiment's split |
| `asm/<shape>.Nrcl2` | `scripts/gen_nc_rcl2.py` | NC floor, rcl2's split |
| `cases/dense/<shape>/base/code/` | rcl2 (captured) | rcl2 |
| `asm/per-block-handshake/<shape>.<A, C1..C4>` | `scripts/gen_mm_per_block.py` (per-block AB credit, `L = min(8, T)`) | the first sweep, below |
| `asm/per-block-handshake/lead/m2048_k256_n64.C<R>L<L>` | `scripts/gen_mm_per_block.py --R R --lead L` | the credit experiment, below |

The first sweep, with the per-block handshake (cycles; "hang": the VP stopped at its 125000-cycle limit):

| Shape | A | C1 | C2 | C3 | C4 |
|---|---|---|---|---|---|
| m512_k256 | 2080 | 2936 | 2450 | 2386 | 2110 |
| m512_k1024 | 5372 | 8726 | 6666 | 6610 | 5374 |
| m2048_k256 | 3496 | hang | hang | hang | hang |
| m2048_k1024 | 7818 | hang | hang | hang | hang |

The credit experiment on m2048_k256, with the VP limit lowered to 6000 cycles (`timeout_cycles` in a copy of
the case's manifest): C4 with L = 1, 7, 8 hung; L = 2, 3, 4, 5 took 4410, 4274, 3702, 3702; C2 with L = 2
and 4 took 4834. C1 with L = 4 did not finish in 6000 cycles, which says nothing about a hang: C1 needs
6754 cycles even with the half-ring handshake.

The scratch runs named the half-ring runs `h1` .. `h4` and `hA`; they are `C1` .. `C4` and `A` here.

## Files

[`matmul-kouter-vp/`](matmul-kouter-vp/):

| Path | Contents |
|---|---|
| `asm/<shape>.<A, C1..C4, N, Nrcl2>/` | `raw_<d>.s` as generated, `init_<d>.s` as run (fence added), per DNC |
| `cases/dense/<shape>/` | rcl2's capture: `base/manifest.json`, `base/data/`, `base/code/` (rcl2's code), and `kernel.py` |
| `scripts/gen_mm.py` | A and C |
| `scripts/gen_mm_per_block.py` | A and C with the per-block AB handshake (first sweep; hangs at T = 16) |
| `scripts/gen_nc.py`, `scripts/gen_nc_rcl2.py` | the NC floors N and Nrcl2 |
| `scripts/finish.py`, `scripts/run.sh`, `scripts/check.py` | assemble and fence, run one case, check the output |
| `scripts/capture_more.py` | `capture_rcl2.py` with extra dense shapes |
| `scripts/plot.py`, `cycles.svg`, `speed.svg` | the two charts, drawn from `results.tsv` |

`scripts/run.sh m2048_k256_n64 C 4` regenerates and reruns one point; an M = 2048 run takes 10–60 minutes of
wall time on the VP.
