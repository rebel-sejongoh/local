# Lowering mcc's tiled trace to uloop: design

Status: prototype on `mcc-uloop-interp` (`mlir/python/mlir_mcc/lowering/trace.py`, uncommitted);
add, dense and batch matmul lower and run.

## Decisions (2026-10-27)

- The mseq-based mcc code stays. The MLIR flow is a new, separate flow that will eventually
  replace the mseq and everything below it.
- Lowering is plain codegen into a canonical form, close to a perfect loop nest: one tile per
  statement in the innermost loop, NC transfers of one tile (no chunking), nothing hoisted (a
  matmul reloads its weight tile per row tile). Optimizations come later as separate uloop passes.
  Only a reduction's initialization and final store sit outside its loop.
- A K split across DNCs (`reduce_size > 1`) needs a reduce collective in a pipeline; it is
  designed later. The lowering refuses it for now; the per-DNC partials lower without trouble.
- The DNC grid: `uloop.dnc_grid = [D0, D1, ...]` on the kernel replaces `uloop.spmd_dncs`, and
  `uloop.dnc_id` returns one index per dimension (`%m, %k = uloop.dnc_id : index, index`); DNC
  number = the grid point in row-major order, as mcc's `Mdmap` numbers them. Done.
- The lowering and the kernel builder live in `mlir_mcc.lowering` (`mlir/python/mlir_mcc/lowering`):
  `lower(trace)` reads the trace's fields and does not import mcc, so mcc can call it.

## Goal

Lower the IR mcc has **before the mseq** into `uloop`: the tiled `TracedOp` with its
`TilingDecision`, its address spec and its SP placement. Today `block_chain.mapped` turns that into
one mseq per DNC (`grounding/mseq_elementwise`, `mseq_matmul`), and the mseq goes on to the mpn and
JIR. The uloop path replaces the mseq builders for the ops it covers: one kernel for all DNCs, its
loops and addresses affine in the DNC and NCore indices, each statement on the unit that runs it.

## The input

`KPLCompiler().build(MAIN, addresses, red_addr=)` returns it; `trace_print.format_tiled(trace)`
prints it. What it states, and where it goes in uloop:

| Input | States | uloop |
|---|---|---|
| `trace.kind` | `streaming` (VU elementwise) or `systolic` (TU matmul) | which rule set below |
| `trace.nodes` | the op DAG: `add(input1, input2)`; `y = reduce.add(mul(x, w))` with a card | the unit ops |
| `trace.axes` | each axis's role: `lane`, `shard`, `contract`, `reduce` | buffer shapes, which index is a lane |
| `trace.vu_dtype` | dlf16 or bf16 | the line's lane type |
| `TilingDecision` | `n_shards`, `reduce_size`, `m_tiles`, `bin`, `ncore_fan`/`numncores`, `batch`, `lane_blocks`, `per_dnc_rows`, `tile_rows`, `mdmap` | `spmd_dncs`, `dnc_id`, `ncore_id`, the loops and their trip counts |
| `trace.spec` | `StreamAddrs` (`in_addrs`, `out_addr`, `extents`) or `_SystolicSpec` (`m`, `k`, `n`, `act_addr`, `ker_addr`, `out_addr`, `red_addr`, `g`, batch and K-block strides) | SHM buffers: `shm_line` and shape |
| `trace.placement` | the SP buffers: `(NCLU, w) → kernel`, `(NCLU, x) → ab_bank`, `(TU, y) → tu_psum`, `(VU, acc) → vu_acc` | SP `uloop.alloc`s |

It states the splits and the loop nest as numbers, the SHM placement, and the op; it does not
state SP line addresses, chunking, or any unit's instruction stream. Those are uloop's or later.

## Rules

### Kernel and pipeline

- `uloop.spmd_dncs = tiling.active_dncs`; the pipeline's `ncores = tiling.numncores`.
- `%d = uloop.dnc_id`. A DNC's share of each axis is `tiling.mdmap.index(d, axis)`. With one
  split level (M only) that share is `d` itself; with an M and a K level it is a mixed-radix digit
  of `d`, which uloop cannot express yet (see "uloop changes").
- `%nc = uloop.ncore_id` where `numncores > 1`.

### SHM buffers

One `uloop.alloc {name, shm_line}` per tensor, `shm_line` from the spec, shaped so the layout is a
row-major memref of lines:

| Op | Tensor | Shape (lines) | From |
|---|---|---|---|
| streaming | each input and the output | `[R / 64][K]`: lane = R, K down the lines | `extents`, `lane` role |
| systolic | x (act) | `[K / 64][M]` | `m`, `k`, `act_addr` |
| systolic | w (kernel) | `[B][K / 64][64]` | `k`, `g`, `ker_addr`, `ker_batch_stride` |
| systolic | y (out) | `[M]` (N = 64) | `m`, `out_addr` |

A stacked batch (`batch > 1`) puts problem `b`'s rows at `b * rows_per_batch` in x and y, so x and
y keep their plain shapes; only w gains the `[B]` dimension, indexed by the DNC's problem
(`d / shards_per_batch`).

### Loops

Outermost first, inside the pipeline:

| Loop | Trips | Index's coefficient in addresses |
|---|---|---|
| M tile (`m_tiles`) | `m_tiles` | `tile_rows` rows of x, y |
| K bin (`bin`, systolic) | `bin` | one K-block of x, w |
| N block (`lane_blocks`) | `lane_blocks` | not in the examples |
| leaf | lines / tile | one tile: 4, 2 or 1 lines (streaming: the largest dividing K; systolic: the TU leaf, `min(leaf_atom, ncore_rows)`) |

A DNC's rows start at `per_dnc_rows * d` (its M share); an NCore's at `ncore_rows * nc` inside the
M tile.

### Ops

- **Streaming map:** each DAG node becomes a VU op on 4-line tiles: `add(a, b)` → `vu.fma a, 1.0,
  b`; `mul` → `vu.fma a, b, 0.0`; `max`, `exp` as named. Operands come in by `nclu.load` and
  `splu.load`; the result goes out by `spsu.store` and `ncsu.store`.
- **Systolic matmul (`reduce.add(mul(x, w))`):** per K bin, `nclu.load` the weight tile once per
  NCore and the 4-row x tile, `splu.load` both, `mxu.matmul`. Across bins the VU sums the tiles in
  a VU register (`vu.reg_read` / `vu.fma p, 1.0, acc` / `vu.reg_write`); the last bin's sum is
  stored. That is `trace`'s accumulate edge `(VU, VU, acc)` with cadence `accum = bin`.
- **Cross-DNC K split (`reduce_size > 1`):** the root of each group gathers its leaves' partials
  through SHM at `red_addr`. In uloop: a first pipeline in which every DNC computes its partial and
  the leaves store theirs to a partial buffer at `red_addr`, then a second pipeline in which each
  root sums them and stores the output. Needs the uloop changes below.

### SP buffers

One SP `uloop.alloc` per placement entry, per NCore where the NCore stages its own (`kernel` holds
each NCore's `[bin][64]` weight lines; `ab_bank` the x tiles `[bin][rows]`). SP line addresses are
left to the later lowering: uloop's SP buffers have no `shm_line` counterpart.

## Examples

Hand-lowered by the rules above, run with `mcc-uloop-interp` on the VP's input image, and compared
line for line with the VP's output image (`run_vp.py <case> --workdir`):

| Case | Tiling | uloop | Result |
|---|---|---|---|
| add_elementwise/1x16x2x64 | 16 DNCs, K = 2 | `tests/Interp/add-vp.mlir` | bit-exact |
| add_elementwise/64x512x64 | 16 DNCs, `m_tiles` 2, K = 1024 in 16-line chunks | below | bit-exact |
| dense/m128_k64_n64 | 16 DNCs × 2 NCores, 4-row tiles | `tests/Interp/dense-vp.mlir` | bit-exact |
| dense/m1024_k64_n64 | + `m_tiles` 8 | matmul listing, `KB = 1`, `MT = 8` | bit-exact |
| batch_matmul/b16_m64_k64_n64 | + `batch` 16: a problem per DNC | matmul listing, w indexed by `d` | bit-exact |
| dense/m128_k256_n64 | + `bin` 4: K-blocks summed in time | matmul listing, `KB = 4` | 2477 of 8192 differ, by design; within the perf test's tolerance (mean 0.00028 ≤ 0.001, max 0.0041 ≤ 0.006) |
| dense/m4_k256_n64 | `reduce_size` 4 | not expressible yet | — |

m128_k256 differs because the two tilings differ, not the interpreter. The base code splits K
over 4 DNCs and sums their dlf16 results pairwise, `(p0 + p1) + (p2 + p3)`, each sum rounded half
away from zero; with that order a numpy model matches the VP bit for bit. mcc's tiling instead sums
the 4 K-blocks in time on one DNC, `((p0 + p1) + p2) + p3`, which is what the uloop computes. The
perf test already compares mcc's output with the base code's within a tolerance for this case
(`compare` in its manifest). So a lowered kernel is checked bit for bit against the VP only where
its tiling sums in the base code's order; otherwise against the base code within the case's
`compare` tolerance, or against numpy.

The matmul listing (dlf16; `KB` K-blocks, `MT` M tiles, `RPD` rows per DNC, `WS` the weight's
batch stride, 0 for a plain dense):

```mlir
uloop.pipeline buffers(...) attributes {ncores = 2} {
  %d = uloop.dnc_id
  %nc = uloop.ncore_id
  uloop.for %kb = 0 to KB {
    uloop.nclu.load %sw[%nc, %kb, 0], %w[WS * %d + 64 * %kb] : !wtile, !sp_w, !w
  }
  uloop.for %mt = 0 to MT {
    uloop.vu.reg_write %acc[0], zero : !acc
    uloop.for %kb = 0 to KB {
      uloop.nclu.load %sx[%kb, 4 * %nc], %x[%kb, RPD * %d + 8 * %mt + 4 * %nc] : !tile, !sp_x, !x
      %wt = uloop.splu.load %sw[%nc, %kb, 0] : !wtile, !sp_w
      %xt = uloop.splu.load %sx[%kb, 4 * %nc] : !tile, !sp_x
      %p = uloop.mxu.matmul %wt, %xt : !tile
      %a = uloop.vu.reg_read %acc[0] : !acc
      %s = uloop.vu.fma %p, 1.0, %a : !tile
      uloop.vu.reg_write %acc[0], %s : !acc
    }
    %r = uloop.vu.reg_read %acc[0] : !acc
    uloop.spsu.store %sy[4 * %nc], %r : !tile, !sp_y
    uloop.ncsu.store %y[RPD * %d + 8 * %mt + 4 * %nc], %sy[4 * %nc] : !tile, !y, !sp_y
  }
}
```

The add listing, 64x512x64 (`!rows = memref<32x1024x!line, #ucommon.shm>`):

```mlir
uloop.pipeline buffers(...) {
  %d = uloop.dnc_id
  uloop.for %mt = 0 to 2 {
    uloop.for %c = 0 to 64 {
      uloop.for %j = 0 to 4 {
        uloop.nclu.load %sa[4 * %j], %a[2 * %d + %mt, 16 * %c + 4 * %j] : !tile, !sp, !rows
        uloop.nclu.load %sb[4 * %j], %b[2 * %d + %mt, 16 * %c + 4 * %j] : !tile, !sp, !rows
        %x = uloop.splu.load %sa[4 * %j] : !tile, !sp
        %z = uloop.splu.load %sb[4 * %j] : !tile, !sp
        %s = uloop.vu.fma %x, 1.0, %z : !tile
        uloop.spsu.store %sy[4 * %j], %s : !tile, !sp
        uloop.ncsu.store %y[2 * %d + %mt, 16 * %c + 4 * %j], %sy[4 * %j] : !tile, !rows, !sp
      }
    }
  }
}
```

## uloop changes the lowering needs

1. **NC transfers of any line count.** mcc's mseq moves 16-line chunks and 64-line weights in one
   transfer; `nclu.load`/`ncsu.store` take 1, 2, 4, 8 or 64 lines. Let them take a contiguous
   run of n lines (n ≤ the hardware's burst), so a chunk is one statement. The examples work around
   it with 4-line transfers.
2. **A DNC grid.** With an M and a K split, a DNC's shares are mixed-radix digits of its index,
   which no affine expression of `%d` gives. Proposal: `%m, %k = uloop.dnc_id {shape = [4, 4]}`,
   the digits outermost first, `spmd_dncs` their product. The NCore index stays one-dimensional.
3. **A pipeline on part of the grid.** The gather runs on the roots only. Proposal: a pipeline
   attribute giving the grid box it runs on, e.g. `{dncs = [4, 1]}` for K share 0; the other DNCs
   skip it. SP keeps its contents across pipelines, so a root's own partial can stay in SP.

The K-block sum needs no change: a VU `fma p, 1.0, acc` per block, rounded to dlf16, is what the
hardware does, in whatever order the tiling sums.

## Implementation plan

- `src/mcc/uloop/lower.py`: `lower(trace) -> Kernel`, built with the existing `mcc.uloop.Kernel`
  builder. It refuses, with the reason, what it does not cover: ragged splits (`m_valid`,
  `lane_valid`), `transpose`, `cout_spatial`, `lane_blocks > 1`, spatial batches, conv, softmax and
  RMSNorm (cross-lane ops), and `reduce_size > 1` until changes 2 and 3 land.
- `mcc.uloop` then imports `mcc.grounding`; `check_layering.py` needs a `uloop` entry above it.
- Tests: lower each perf case in `tests/perf/` the lowering covers and run it on the interpreter:
  bit for bit against a saved VP image where one is kept (`mlir/tests/Interp/`), otherwise against
  numpy within the case's tolerance. The inputs come from `run_vp.write_shm`, so no VP is needed
  in CI.

## Out of scope for the first cut

Ragged shapes, transposed kernels, N > 64, conv, softmax and RMSNorm, spatial batches, double
buffering, SP addresses, and anything the mseq builders decide about timing (chunk pipelining,
syncs).

## Prototype results

`mlir/tests/lowering/test_lower.py` builds each case with mcc at its manifest's addresses, lowers
it, and runs it on the interpreter:

| Case | Check | Result |
|---|---|---|
| add_elementwise/1x16x2x64 | VP image, bit for bit; numpy | pass |
| add_elementwise/3x231x64 | numpy | pass |
| dense/m128_k64_n64 | VP image, bit for bit; numpy | pass |
| dense/m128_k256_n64 | numpy | pass |
| dense/m1024_k64_n64 | numpy | pass |
| batch_matmul/b16_m64_k64_n64 | numpy | pass |
| dense/m4_k256_n64 | refused: a K split across DNCs needs a collective | pass |

Run by hand against saved VP runs, add_elementwise/64x512x64, dense/m1024_k64_n64 and
batch_matmul/b16_m64_k64_n64 also match bit for bit; dense/m128_k256_n64 differs, as above.

## Open questions

1. The reduce collective for a K split across DNCs, and the pipeline-on-part-of-the-grid it needs.
2. Whether NC transfers should take any line count (change 1), now that the canonical form moves a
   tile at a time and chunking is an optimization pass's job.
