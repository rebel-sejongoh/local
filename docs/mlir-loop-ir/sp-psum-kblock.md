# Matmul with SP partial sums: footprint blocks and tile-group syncs

The running example of [`mlir-loop-ir.md`](../mlir-loop-ir.md), `y = relu(x @ w + bias)`, with the partial sums
in SP instead of VU registers. This is the order rcl2's dense matmul runs ("variant A" of
[`matmul-kouter-vp.md`](../matmul-kouter-vp.md)): one weight latch serves every tile of an NCore, KB latches per
N block instead of KB · T / 4. The fused loop IR is in the canonical form of the main document, with the ops
named by their units (`nclu.load`, `splu.load`, `spsu.store`, `ncsu.store`).

Three changes make the conversion as mechanical as for register partial sums, with no peeled iteration, no guard
and no value carried in registers:

- **Zero fill as one op.** `spsu.store %sp_psum[nc, 0], zero : vector<Mcx64xdlf16>` before the K loop: one SPSU
  `ST` with the ZERO producer (up to 64 lines per burst; Mc = 64 here). Every K block then reads and adds the
  same way.
- **`psum.accumulate`**, one op for `p[...] += v`: the read, the add and the write of a tile. The conversion splits
  it into a `splu.load`, a `vu.fma` and a `spsu.store`.
- **`psum.block`**, a region that names the lines one sync token covers (its footprint). Where the syncs go, and how
  coarse they are, is decided in the fused IR by where the blocks are, before any sync is inserted.
  `psum.block %sp_psum[nc, 4*G*g] sizes = [1, 4*G]` gives the footprint's first index and its size in each
  dimension, as the offsets and sizes of `memref.subview`: 4·G lines from line 4·G·g of NCore `nc`'s partial
  sums, the G tiles of group `g`.

The `psum` prefix names the case, not a unit: these ops are the one exception to the read-after-write rule
(C6 of the main document), and the conversion assigns the units (`psum.accumulate` to the SPLU, VU and SPSU).

## Terms

A tile is 4 rows of 64 values (one MXU pass); a line is 64 values.

| Symbol | Meaning | Here |
|---|---|---|
| M, N, K | `x[M, K]`, `w[K, N]` | 2048, 256, 512 |
| D, C | DNCs, NCores per DNC | 16, 2 |
| NB, KB | N blocks and K blocks of 64: N / 64, K / 64 | 4, 8 |
| Mc | rows per NCore: M / (D · C) | 64 |
| T | tiles per NCore, Mc / 4: the x tiles streamed through one latched weight tile, and the tiles of `%sp_psum` | 16 |
| G | tiles per group: one `psum.block`, one sync token | 4 below; 1 and T are the extremes |
| footprint | the lines a block (or a lone op) covers | `%sp_psum[nc, 4*G*g] sizes = [1, 4*G]` |
| phase | one sweep over all T tiles of `%sp_psum`, in one iteration of `nb` | below |

The phases of one `nb`, by loop:

| Phase | Loops | Each tile |
|---|---|---|
| W | the zero fill, one op | written (SPSU) |
| RW₀ … RW_{KB−1} | one iteration of `kb`: the `g` × `i` nest inside it | read (SPLU), added (VU), written (SPSU) |
| R | the epilogue's `g` × `i` nest | read (SPLU) |

Inside a phase the tiles are independent. Across phases, tile `t` of one phase must follow tile `t` of the phase
before: that, and nothing else, is what the syncs on `%sp_psum` order.

## The fused loop IR

`g` is a group of G tiles and `i` a tile in it, as in the main document; tile `G·g + i` holds rows
`Mc·nc + 4·(G·g + i)` of the DNC.

```mlir
primitive @mm_sp_psum attributes {spmd_dncs = D} {
  // SHM, in lines (64 values, 128 B each)
  %x       = alloc : memref<KBxMxvector<64xdlf16>, #shm>            // x[kb][m]
  %w       = alloc : memref<KBxNBx64xvector<64xdlf16>, #shm>        // w[kb][nb][q]
  %bias    = alloc : memref<NBxvector<64xdlf16>, #shm>
  %y       = alloc : memref<NBxMxvector<64xdlf16>, #shm>            // y[nb][m]
  // SP
  %sp_x    = alloc : memref<KBx(C·Mc)xvector<64xdlf16>, #sp>
  %sp_w    = alloc : memref<CxKBxNBx64xvector<64xdlf16>, #sp>       // per NCore
  %sp_b    = alloc : memref<CxNBxvector<64xdlf16>, #sp>             // per NCore
  %sp_y    = alloc : memref<NBx(C·Mc)xvector<64xdlf16>, #sp>
  %sp_psum = alloc : memref<CxMcxvector<64xdlf16>, #sp>             // psum[nc][row]: an NCore's T tiles

  pipeline (%x, %w, %bias, %y, %sp_x, %sp_w, %sp_b, %sp_y, %sp_psum) attributes {ncores = C} {
    for nc = 0 .. C {                                              // spatial: NCore
      for nb = 0 .. NB {                                           // N block
        spsu.store %sp_psum[nc, 0], zero                                 : vector<Mcx64xdlf16>  // W
        for kb = 0 .. KB {                                         // RW_kb
          for g = 0 .. T/G {                                       // a group of G tiles: one token
            psum.block %sp_psum[nc, 4*G*g] sizes = [1, 4*G] {
              for i = 0 .. G {                                     // tile G·g + i
                %m  = affine.apply Mc*nc + 4*(G*g + i)
                nclu.load %sp_w[nc, kb, nb, 0], %w[kb, nb, 0]            : vector<64x64xdlf16>
                nclu.load %sp_x[kb, %m], %x[kb, C*Mc*%d + %m]            : vector<4x64xdlf16>
                %wt = splu.load %sp_w[nc, kb, nb, 0]                     : vector<64x64xdlf16>
                %xt = splu.load %sp_x[kb, %m]                            : vector<4x64xdlf16>
                %p  = mxu.matmul %wt, %xt                                : vector<4x64xdlf16>
                psum.accumulate %sp_psum[nc, 4*(G*g + i)], %p              : vector<4x64xdlf16>   // psum += this K block's product
              }
            }
          }
        }
        for g = 0 .. T/G {                                         // R
          psum.block %sp_psum[nc, 4*G*g] sizes = [1, 4*G] {
            for i = 0 .. G {
              %m  = affine.apply Mc*nc + 4*(G*g + i)
              nclu.load %sp_b[nc, nb], %bias[nb]                         : vector<64xdlf16>
              %a  = splu.load %sp_psum[nc, 4*(G*g + i)]                  : vector<4x64xdlf16>   // the whole sum
              %bl = splu.load %sp_b[nc, nb]                              : vector<64xdlf16>
              %yb = vu.fma %a, 1.0, %bl                                  : vector<4x64xdlf16>
              %yr = vu.max %yb, 0.0                                      : vector<4x64xdlf16>
              spsu.store %sp_y[nb, %m], %yr
              ncsu.store %y[nb, C*Mc*%d + %m], %sp_y[nb, %m]             : vector<4x64xdlf16>
            }
          }
        }
      }
    }
  }
}
```

The weight tile is loaded per tile, as the canonical form says. Hoisting it out of `i` and `g` (it touches no
line of `%sp_psum`, so it may leave a block) gives one latch per K block for all T tiles:
`mxu.matmul {tiles = T, m_rows = 4}`.

## Rules for an accumulator buffer

A buffer written by `psum.accumulate` is an accumulator buffer. The verifier checks, inside one iteration of the
loop around its phases (`nb`):

| # | Rule | Here |
|---|---|---|
| B1 | **Accesses.** Only three kinds: a zero store (W), `psum.accumulate` (RW), `splu.load` (R). The SPLU reads it and the SPSU writes it | yes |
| B2 | **Phase order.** W, then RW any number of times, then R. An RW phase is one iteration of the loop around the `psum.accumulate` blocks whose index no footprint uses (`kb`, the reduction loop) | W, RW × KB, R |
| B3 | **Footprints.** Every access lies inside its block's footprint (a lone op is its own block). Within a phase the footprints are disjoint and together cover the buffer | T/G blocks of 4G lines, or one op of Mc |
| B4 | **Same partition.** Every RW and R phase uses the same footprints in the same order. W may be one op over the whole buffer | `[nc, 4*G*g]`, `g = 0 .. T/G`, in every RW and in R |
| B5 | **Tokens.** Blocks per phase ≤ the depth of the SYNC FIFO between the SPSU and the SPLU (16 on one NCore) | T/G = 4 ≤ 16 |

`psum.accumulate` is the only op that reads and writes the same lines, and it is one op: the read-modify-write of
a tile is not split across statements of the fused IR, so no ordering inside a phase is left to check.

**Partial sums are the only exception.** Elsewhere, an SP buffer is never read and then rewritten from its own
value (C6 of the main document). The rules above cover only `psum.accumulate` buffers. They do not cover a
general read-modify-write in SP, such as a running max, a scatter-add or an in-place update. That stays out
until it can be generalized formally.

## Sync insertion

Two channels, named like the main document's `ready` and `free`. A block's `get` waits for the `put` of the last
block of the phase before that touched its lines.

| Channel | `put` | `get` |
|---|---|---|
| `%psum_ready` (SPSU → SPLU): a footprint has been written | after each block of RW; after W, T/G at once, one per block of RW₀ | before each block of RW and R |
| `%psum_free` (SPLU → SPSU): the buffer has been read for the last time | once after R | once at the end of the same `nb` on the SPSU, so the next W waits for it |

W is one op over the whole buffer, so it needs only the last block of R: one `%psum_free` token per `nb`. The
SPSU takes it at the end of the `nb` that produced it, right before the next W, so no credits are needed.

The fused IR of one `nb` with its syncs (each annotated with its unit):

```mlir
      for nb = 0 .. NB {
        spsu.store %sp_psum[nc, 0], zero
        for g = 0 .. T/G { sync put %psum_ready }   @spsu   // one per block of RW_0
        for kb = 0 .. KB {
          for g = 0 .. T/G {
            sync get %psum_ready                    @splu
            psum.block … { for i { … psum.accumulate … } }
            sync put %psum_ready                    @spsu
          }
        }
        for g = 0 .. T/G {
          sync get %psum_ready                      @splu
          psum.block … { for i { … %a = splu.load %sp_psum[…] … } }
        }
        sync put %psum_free                         @splu
        sync get %psum_free                         @spsu   // the next W waits for R
      }
```

The input and output transfers get their `ready` and `free` channels per tile as in the main document
(`%in_ready`, `%in_free`, `%b_ready`, `%b_free`, `%y_ready`).

## Checks

| Check | Here |
|---|---|
| P2: counts per iteration | `g` in RW: `%psum_ready` 1 `get`, 1 `put`. `nb`: `%psum_ready` (KB + 1) · T/G `put`s and `get`s; `%psum_free` 1 and 1 |
| P3: never a `get` before its `put` | `%psum_ready` over `nb`'s body: T/G after W, then per block −1 (`get`) and +1 (`put`), then −T/G over R: back to 0. `%psum_free`: +1 after R, −1 after it |
| P6: capacity | `%psum_ready` holds at most T/G tokens (B5), `%psum_free` 1 |

**Why at most one phase of tokens wait.** A `get` of phase k+1 takes the `put` of the same block in phase k. The
SPSU can finish a block of phase k+1 only after the SPLU has read it, after that `get`. So the SPSU is at most one
phase ahead of the SPLU, and at most T/G tokens wait, independent of KB.

## After projection

The per-NCore blocks of NCore `nc`; the input and output transfers and their syncs are elided (`…`).

```mlir
  %f_sx = fifo splu -> xvu  : vector<64xdlf16>          // weight tiles, x tiles
  %f_xm = fifo xvu  -> mxu  : vector<64xdlf16>
  %f_mv = fifo mxu  -> vu   : vector<64xdlf16>          // products
  %f_sv = fifo splu -> vu   : vector<64xdlf16>          // partial sums, bias lines
  %f_vs = fifo vu   -> spsu : vector<64xdlf16>          // partial sums, outputs

  %psum_ready = channel spsu -> splu                    // a footprint of %sp_psum has been written
  %psum_free  = channel splu -> spsu                    // %sp_psum has been read for the last time

  @splu {
    for nb = 0 .. NB {
      for kb = 0 .. KB {
        for g = 0 .. T/G {
          sync get %psum_ready
          for i = 0 .. G {
            …                                                          // get %in_ready
            splu.load %sp_w[nc, kb, nb, 0] -> %f_sx                    : vector<64x64xdlf16>
            splu.load %sp_x[kb, Mc*nc + 4*(G*g + i)] -> %f_sx          : vector<4x64xdlf16>
            …                                                          // put %in_free
            splu.load %sp_psum[nc, 4*(G*g + i)] -> %f_sv               : vector<4x64xdlf16>   // psum.accumulate's read
          }
        }
      }
      for g = 0 .. T/G {
        sync get %psum_ready
        for i = 0 .. G {
          splu.load %sp_psum[nc, 4*(G*g + i)] -> %f_sv                 : vector<4x64xdlf16>
          …                                                            // get %b_ready
          splu.load %sp_b[nc, nb] -> %f_sv                             : vector<64xdlf16>
          …                                                            // put %b_free
        }
      }
      sync put %psum_free
    }
  }
  @xvu {
    for nb = 0 .. NB { for kb = 0 .. KB { for g = 0 .. T/G { for i = 0 .. G {
      xvu.pass %f_sx -> %f_xm                                          : vector<64x64xdlf16>
      xvu.pass %f_sx -> %f_xm                                          : vector<4x64xdlf16>
    } } } }
  }
  @mxu {
    for nb = 0 .. NB { for kb = 0 .. KB { for g = 0 .. T/G { for i = 0 .. G {
      %wl = mxu.latch %f_xm                                            : vector<64x64xdlf16>
      mxu.matmul %wl, %f_xm -> %f_mv                                   : vector<4x64xdlf16>
    } } } }
  }
  @vu {
    for nb = 0 .. NB {
      for kb = 0 .. KB { for g = 0 .. T/G { for i = 0 .. G {
        vu.fma %f_mv, 1.0, %f_sv -> %f_vs                              : vector<4x64xdlf16>   // psum.accumulate's add
      } } }
      for g = 0 .. T/G { for i = 0 .. G {
        %yb = vu.fma %f_sv, 1.0, %f_sv                                 : vector<4x64xdlf16>   // the sum, then the bias line
        vu.max %yb, 0.0 -> %f_vs                                       : vector<4x64xdlf16>
      } }
    }
  }
  @spsu {
    for nb = 0 .. NB {
      spsu.store %sp_psum[nc, 0] <- zero                               : vector<Mcx64xdlf16>
      for g = 0 .. T/G { sync put %psum_ready }
      for kb = 0 .. KB {
        for g = 0 .. T/G {
          for i = 0 .. G {
            spsu.store %sp_psum[nc, 4*(G*g + i)] <- %f_vs              : vector<4x64xdlf16>   // psum.accumulate's write
          }
          sync put %psum_ready
        }
      }
      for g = 0 .. T/G { for i = 0 .. G {
        spsu.store %sp_y[nb, Mc*nc + 4*(G*g + i)] <- %f_vs             : vector<4x64xdlf16>
        …                                                              // put %y_ready
      } }
      sync get %psum_free
    }
  }
```

No unit has a branch, a peeled iteration or an indexed register: the VU needs no unrolling.

## FIFO depths

SYNC FIFOs (EVT1 `SYNC` pages of the ISA documents; the same table is in rcl2's
`.github/instructions/module/hw_architecture/sync-discipline.instructions.md`):

| Channel | Depth |
|---|---|
| SPSU → SPLU, SPLU → SPSU, same NCore | 16 (4 on ATOM) |
| SPSU ↔ SPLU, neighbor NCore | 4 + 2 |
| NCLU → SPLU, SPLU → NCLU, SPSU → NCSU, NCSU → SPSU | 4 + 2 |
| NCLU ↔ NCSU | 16 |

Data FIFOs, in lines. The ISA documents do not list them; these are the constants of rcl2's hardware test
`submodules/rebel_hw_util/tools/verif_prim/ncore_data_passing/data_passing_on_full_fifo.py`, to be confirmed:

| SPLU→XVU | SPLU→VU | SPLU→SPSU | XVU→VU | XVU→SPSU | XVU→TU | VU→XVU | VU→SPSU |
|---|---|---|---|---|---|---|---|
| 16 | 16 | 4 | 2 | 6 | 6 | 6 | 2 |

**Why B5 is needed.** If a phase had more blocks than the SYNC FIFO holds, the SPSU would block on a `put`; the
VU then blocks on the full VU → SPSU FIFO (half a tile), and the SPLU on the full SPLU → VU FIFO (4 tiles) before
it reaches the `get` that would free the SPSU: a cycle of waits. The data FIFOs cannot absorb the difference, so
the token count per phase, not the FIFO data, is what must fit. An NCore with more than 16 tiles (rcl2's
m512_k1024 has about 43) needs G > 1.

## Choosing G

| G | Tokens per phase | Wait |
|---|---|---|
| 1 (a block per tile, or no block: each `psum.accumulate` is its own) | T, only if T ≤ 16 | tile `t` waits only for tile `t` of the previous phase |
| ⌈T / 16⌉ | ≤ 16 | the finest grouping the depth allows |
| T (one block around the whole `g` × `i` nest) | 1 | one sync per K block, as rcl2 does: the first read of a K block waits for the last store of the previous one |

With G = T, moving the hoisted weight load above `get %psum_ready` (it touches no line of `%sp_psum`) lets the
MXU latch during that wait, as rcl2 does.

## Counts per NCore

| Channel | `put`s = `get`s | Here (G = 4) | Most waiting |
|---|---|---|---|
| `%psum_ready` | NB · (KB + 1) · T/G | 4 · 9 · 4 = 144 | T/G = 4 |
| `%psum_free` | NB | 4 | 1 |

## Earlier versions

- The first version of this file synced once per K block with an `accumulate` attribute on the `kb` loop and
  phase rules A1–A5; it is the G = T case here.
- [`sp-psum.md`](sp-psum.md): one sync per tile without a zero fill: a channel with distance 1 on `kb` and guards
  or peeling at the first and last K block.
- [`sp-psum-queue.md`](sp-psum-queue.md): the partial sums as a queue in SP, with data and space semaphores. The
  same order of tokens comes here from B4 instead of a queue type.
