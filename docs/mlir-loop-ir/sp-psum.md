# Matmul with SP partial sums: from the fused loop IR to unit programs

A full example of keeping a matmul's partial sums in SP (rcl2's order, variant A of
[`matmul-kouter-vp.md`](../matmul-kouter-vp.md)) in the fused loop IR of [`mlir-loop-ir.md`](../mlir-loop-ir.md),
then distributing it into one loop nest per unit and annotating every sync.

`y = relu(x @ w + bias)`, `x[2048, 512]`, `w[512, 256]`, DLFloat16, 16 DNCs. DNC `%d` takes rows
`128·%d .. +127`; NCore `nc` takes 64 of them, 16 tiles of 4 rows. Loops: `nb` (4 N blocks of 64), `kb` (8 K
blocks of 64), `t` (16 tiles). Every input is resident in SP (loaded once at the start), so the only syncs inside
the nest are the ones the partial sums need.

## 1. The fused loop IR

```mlir
primitive @mm_sp_psum attributes {spmd_dncs = 16} {
  %x     = alloc : memref<8x2048xvector<64xdlf16>, #shm>         // x[kb][m]
  %w     = alloc : memref<8x4x64xvector<64xdlf16>, #shm>         // w[kb][nb][q]
  %bias  = alloc : memref<4xvector<64xdlf16>, #shm>
  %y     = alloc : memref<4x2048xvector<64xdlf16>, #shm>         // y[nb][m]
  %sp_x  = alloc : memref<8x128xvector<64xdlf16>, #sp>           // this DNC's rows, 128 KB
  %sp_w  = alloc : memref<8x4x64xvector<64xdlf16>, #sp>          // 256 KB
  %sp_b  = alloc : memref<4xvector<64xdlf16>, #sp>
  %sp_y  = alloc : memref<4x128xvector<64xdlf16>, #sp>           // 64 KB
  %sp_p  = alloc : memref<2x64xvector<64xdlf16>, #sp>            // p[nc][row]: each NCore's 16 tiles of partial sums, 16 KB

  pipeline (%x, %w, %bias, %y, %sp_x, %sp_w, %sp_b, %sp_y, %sp_p) attributes {ncores = 2} {
    for kb = 0 .. 8 {                                            // inputs, hoisted: resident from here on
      load.shm2sp %sp_x[kb, 0], %x[kb, 128*%d]      : vector<128x64xdlf16>
    }
    load.shm2sp %sp_w, %w
    load.shm2sp %sp_b, %bias
    for nc = 0 .. 2 {                                            // spatial: NCore
      for nb = 0 .. 4 {                                          // N block
        for kb = 0 .. 8 iter_sp(%sp_p) {                         // K block; %sp_p carries from kb to kb + 1
          for t = 0 .. 16 {                                      //   tile t: rows 4t .. 4t+3 of this NCore
            %m  = affine.apply 64*nc + 4*t
            %xt = load.sp %sp_x[kb, %m]                 : vector<4x64xdlf16>
            %wt = load.sp %sp_w[kb, nb, 0]              : vector<64x64xdlf16>
            %p  = mxu.matmul %wt, %xt                   : vector<4x64xdlf16>
            %pp = load.sp %sp_p[nc, 4*t]                : vector<4x64xdlf16>   // the sum over K blocks 0 .. kb-1
            %a  = vu.select (kb == 0), 0.0, %pp         : vector<4x64xdlf16>
            %s  = vu.fma %p, 1.0, %a                    : vector<4x64xdlf16>
            store.sp %sp_p[nc, 4*t], %s                                         // the sum over 0 .. kb
          }
        }
        for o = 0 .. 16 {                                        // epilogue: tile o's whole sum
          %m  = affine.apply 64*nc + 4*o
          %a  = load.sp %sp_p[nc, 4*o]                  : vector<4x64xdlf16>
          %bl = load.sp %sp_b[nb]                       : vector<64xdlf16>
          %yb = vu.fma %a, 1.0, %bl                     : vector<4x64xdlf16>   // + bias, on every line
          %yr = vu.max %yb, 0.0                         : vector<4x64xdlf16>
          store.sp %sp_y[nb, %m], %yr
        }
        store.sp2shm %y[nb, 128*%d + 64*nc], %sp_y[nb, 64*nc] : vector<64x64xdlf16>
      }
    }
  }
}
```

## 2. The constraint that makes `%sp_p` legal: F1′

F1 forbids reading in one iteration what another iteration wrote. `iter_sp(%b)` on a loop `L` allows exactly
one such pattern, when all of the following hold inside `L` (here `L = kb`, `%b = %sp_p`):

| # | Constraint | Here |
|---|---|---|
| C1 | `L`'s body accesses `%b` through one `load.sp` (SPLU) and one `store.sp` (SPSU), nothing else | `%pp` and the store of `%s` |
| C2 | Both use the same index expression | `[nc, 4*t]` |
| C3 | The index does not use `L`'s index, and is injective in the loops between `L` and the accesses | no `kb`; one tile per `t` |
| C4 | The stored value depends on the loaded one through an SSA path, and the load comes first in program order | `%pp → %a → %s` |
| C5 | In `L`'s first iteration the loaded value is dead: its only use is `vu.select (L == 0)` | `%a = select(kb == 0, 0.0, %pp)` |
| C6 | Outside `L`, `%b` follows F1 as usual | the epilogue reads it after the K loop, in the same `nb` |

C2 and C3 together give: the iteration `(kb, t)` reads the lines `(kb − 1, t)` wrote, for every `kb ≥ 1`, and
the inner loops visit the tiles in the same order in every iteration of `L`. That is a dependence of
**distance 1 on `kb` and 0 on `t`**, known from the annotation alone, without comparing addresses.

## 3. The channels

Each dependence between two units that no FIFO orders becomes a sync channel. The lowering records it as
(source, sink, loop that carries it, distance):

| Channel | Source → sink | Why | Carried by, distance |
|---|---|---|---|
| `%in_ready<nc>` | NCLU → SPLU `nc` | x, w, bias are in SP | pipeline, 0 |
| `%acc<nc>` | SPSU `nc` (store `%sp_p`, `kb ≤ 6`) → SPLU `nc` (load `%pp`, `kb ≥ 1`) | RAW on `%sp_p` across K blocks | `kb`, **1** |
| `%p_ready<nc>` | SPSU `nc` (store at `kb = 7`) → SPLU `nc` (epilogue load) | RAW, the whole sum | `nb`, 0 |
| `%p_free<nc>` | SPLU `nc` (epilogue load) → SPSU `nc` (store at the next `nb`'s `kb = 0`) | WAR on `%sp_p` across N blocks | `nb`, 1 |
| `%y_ready<nc>` | SPSU `nc` (store `%sp_y`) → NCSU | the N block's outputs are in SP | `nb`, 0 |

No channel is needed for the WAR inside one K block (SPSU overwriting `(kb, t)` before the SPLU read it): the
stored value is computed from the loaded one (C4), so the FIFOs SPLU → VU → SPSU already order them. `%sp_y` is
indexed by `nb`, so it is never overwritten and needs no `free` channel.

**Placement.** For a channel with distance `d` on loop `L`:

- `put` right after the source op, in the source unit, in the iterations whose sink exists: `L ≤ last − d`;
- `get` right before the sink op, in the sink unit, in the iterations whose source exists: `L ≥ d`.

With `d = 0` there is no condition (the existing `ready` channels). The conditions are static, so the emitter
peels the first or last iteration of `L` instead of branching.

A sync is a counting semaphore: `put` adds one, `get` waits for a nonzero count and takes one. The `k`-th `get`
therefore passes only after the `k`-th `put`. Both sides visit `(kb, t)` in the same order (C3) and skip the
same number of iterations at the ends (`kb = 7` for the puts, `kb = 0` for the gets), so the `k`-th `get`
always waits for the store of the tile it is about to read.

## 4. The unit programs

One NCore, `nc` fixed; the other NCore runs the same programs with its own `%sp_p` half and channels. Each unit
keeps the loops around its ops and only its ops; FIFOs are written `-> UNIT` / `<- UNIT`. `if` conditions are
static: the emitter peels them. Every sync carries the pair it forms.

```mlir
  %f_sx  = fifo splu -> xvu  : vector<64xdlf16>        // x tiles and weight tiles
  %f_xm  = fifo xvu  -> mxu  : vector<64xdlf16>        // acts (west) and weights (north)
  %f_mv  = fifo mxu  -> vu   : vector<64xdlf16>        // products, 4 lines per tile
  %f_sv  = fifo splu -> vu   : vector<64xdlf16>        // partial sums, bias
  %f_vs  = fifo vu   -> spsu : vector<64xdlf16>        // partial sums, outputs

  %in_ready = channel nclu -> splu
  %acc      = channel spsu -> splu                      // distance 1 on kb
  %p_ready  = channel spsu -> splu
  %p_free   = channel splu -> spsu                      // distance 1 on nb
  %y_ready  = channel spsu -> ncsu

  unit @nclu {
    for kb = 0 .. 8 { load.shm2sp %sp_x[kb, 0], %x[kb, 128*%d] : vector<128x64xdlf16> }
    load.shm2sp %sp_w, %w
    load.shm2sp %sp_b, %bias
    sync put %in_ready<0> ; sync put %in_ready<1>      // pairs with each SPLU's single get
  }

  unit @splu {
    sync get %in_ready                                  // x, w, bias resident
    for nb = 0 .. 4 {
      for kb = 0 .. 8 {
        load.sp %sp_w[kb, nb, 0] -> %f_sx      : vector<64x64xdlf16>     // weight tile, latched by the MXU
        for t = 0 .. 16 {
          load.sp %sp_x[kb, 64*nc + 4*t] -> %f_sx : vector<4x64xdlf16>   // x tile first: never behind a wait
          if kb >= 1 {
            sync get %acc                               // k-th get: waits for SPSU's store of (kb-1, t)
            load.sp %sp_p[nc, 4*t] -> %f_sv    : vector<4x64xdlf16>
          }
        }
      }
      sync get %p_ready                                 // waits for SPSU's last store of this nb (kb = 7)
      load.sp %sp_b[nb] -> %f_sv               : vector<64xdlf16>        // bias, latched by the VU
      for o = 0 .. 16 {
        load.sp %sp_p[nc, 4*o] -> %f_sv        : vector<4x64xdlf16>
      }
      if nb <= 2 { sync put %p_free }                   // %sp_p may be overwritten by nb + 1
    }
  }

  unit @xvu {
    for nb = 0 .. 4 { for kb = 0 .. 8 {
      xvu.pass %f_sx -> %f_xm                  : vector<64x64xdlf16>     // weights: to TU north
      for t = 0 .. 16 { xvu.pass %f_sx -> %f_xm : vector<4x64xdlf16> }   // acts: to the ABSU
    } }
  }

  unit @mxu {
    for nb = 0 .. 4 { for kb = 0 .. 8 {
      mxu.matmul out = %f_mv, weights = %f_xm, acts = %f_xm {tiles = 16, m_rows = 4}
    } }
  }

  unit @vu {
    for nb = 0 .. 4 {
      for kb = 0 .. 8 {
        for t = 0 .. 16 {
          if kb == 0 { vu.fma %f_mv, 1.0, 0.0   -> %f_vs : vector<4x64xdlf16> }   // first K block: no partial sum
          else       { vu.fma %f_mv, 1.0, %f_sv -> %f_vs : vector<4x64xdlf16> }
        }
      }
      %bl = vu.latch %f_sv                     : vector<64xdlf16>
      for o = 0 .. 16 {
        %yb = vu.fma %f_sv, 1.0, %bl           : vector<4x64xdlf16>
        vu.max %yb, 0.0 -> %f_vs               : vector<4x64xdlf16>
      }
    }
  }

  unit @spsu {
    for nb = 0 .. 4 {
      if nb >= 1 { sync get %p_free }                   // the SPLU has read nb - 1's sums
      for kb = 0 .. 8 {
        for t = 0 .. 16 {
          store.sp %sp_p[nc, 4*t] <- %f_vs     : vector<4x64xdlf16>
          if kb <= 6 { sync put %acc }                   // k-th put: (kb, t) is in SP for kb + 1
        }
      }
      sync put %p_ready                                 // the whole sums are in SP
      for o = 0 .. 16 {
        store.sp %sp_y[nb, 64*nc + 4*o] <- %f_vs : vector<4x64xdlf16>
      }
      sync put %y_ready
    }
  }

  unit @ncsu {
    for nb = 0 .. 4 { for nc = 0 .. 2 {
      sync get %y_ready<nc>
      store.sp2shm %y[nb, 128*%d + 64*nc], %sp_y[nb, 64*nc] : vector<64x64xdlf16>
    } }
  }
```

The SPLU sends each x tile before it may wait on `%acc`, so a wait never holds back the MXU's input; with 16
tiles between a store and the read that needs it, the wait is normally already satisfied.

### Peeled

The emitter removes every `if` by peeling. The SPLU, VU and SPSU become:

```mlir
  unit @splu {
    sync get %in_ready
    sync put %p_free                                                     // nb = 0 starts free
    for nb = 0 .. 4 {
      load.sp %sp_w[0, nb, 0] -> %f_sx                                   // kb = 0: no partial sums
      for t = 0 .. 16 { load.sp %sp_x[0, 64*nc + 4*t] -> %f_sx }
      for kb = 1 .. 8 {
        load.sp %sp_w[kb, nb, 0] -> %f_sx
        for t = 0 .. 16 {
          load.sp %sp_x[kb, 64*nc + 4*t] -> %f_sx
          sync get %acc
          load.sp %sp_p[nc, 4*t] -> %f_sv
        }
      }
      sync get %p_ready
      load.sp %sp_b[nb] -> %f_sv
      for o = 0 .. 16 { load.sp %sp_p[nc, 4*o] -> %f_sv }
      sync put %p_free                                                   // nb + 1 may overwrite
    }
  }

  unit @vu {
    for nb = 0 .. 4 {
      for t = 0 .. 16 { vu.fma %f_mv, 1.0, 0.0 -> %f_vs }                // kb = 0
      for kb = 1 .. 8 { for t = 0 .. 16 { vu.fma %f_mv, 1.0, %f_sv -> %f_vs } }
      %bl = vu.latch %f_sv
      for o = 0 .. 16 { %yb = vu.fma %f_sv, 1.0, %bl ; vu.max %yb, 0.0 -> %f_vs }
    }
  }

  unit @spsu {
    for nb = 0 .. 4 {
      sync get %p_free                                                   // nb = 0: the SPLU's opening put
      for kb = 0 .. 7 {
        for t = 0 .. 16 { store.sp %sp_p[nc, 4*t] <- %f_vs ; sync put %acc }
      }
      for t = 0 .. 16 { store.sp %sp_p[nc, 4*t] <- %f_vs }              // kb = 7: read by the epilogue only
      sync put %p_ready
      for o = 0 .. 16 { store.sp %sp_y[nb, 64*nc + 4*o] <- %f_vs }
      sync put %y_ready
    }
    sync get %p_free                                                     // the SPLU's last put: closes the count
  }
```

`%p_free` is peeled differently: instead of splitting `nb`, the producer (SPLU) puts one extra token before
the loop and the consumer (SPSU) takes one extra after it, the same shape as the MXU's AB handshake. Every
iteration of `nb` then has one `put` and one `get`, and the counts close.

## 5. Checking the counts

Per NCore, the whole pipeline:

| Channel | `put`s | `get`s |
|---|---|---|
| `%in_ready` | NCLU: 1 | SPLU: 1 |
| `%acc` | SPSU: `kb = 0..6` × 16 tiles × 4 `nb` = 448 | SPLU: `kb = 1..7` × 16 × 4 = 448 |
| `%p_ready` | SPSU: 4 | SPLU: 4 |
| `%p_free` | SPLU: 1 + 4 | SPSU: 4 + 1 |
| `%y_ready` | SPSU: 4 | NCSU: 4 |

And the FIFOs, per N block:

| FIFO | Pushed | Popped |
|---|---|---|
| SPLU → XVU | 8 weight tiles + 8 × 16 x tiles | XVU: the same |
| MXU → VU | 8 × 16 tiles | VU: 8 × 16 |
| SPLU → VU | 7 × 16 partial sums + 1 bias line + 16 sums | VU: 7 × 16 + 1 latch + 16 |
| VU → SPSU | 8 × 16 partial sums + 16 outputs | SPSU: the same |

## 6. The first tokens of `%acc`

Program order of the two sides for one `nb`, numbering the tokens:

| Token | SPSU `put` after | SPLU `get` before | Order it guarantees |
|---|---|---|---|
| 1 | store `(kb 0, t 0)` | load `(kb 1, t 0)` | tile 0 is read after K block 0 wrote it |
| 2 | store `(0, 1)` | load `(1, 1)` | |
| … | | | |
| 16 | store `(0, 15)` | load `(1, 15)` | |
| 17 | store `(1, 0)` | load `(2, 0)` | |
| … | | | |
| 112 | store `(6, 15)` | load `(7, 15)` | |
| — | store `(7, t)`: no put | — | ordered by `%p_ready` instead |

What breaks it:

- **Another order.** If the SPLU read the tiles of a K block in reverse, token 1 (tile 0 written) would release
  the read of tile 15, which K block 0 may not have written yet. C3 rules this out.
- **A repeated index.** With `%sp_p[nc, 4*(t % 8)]`, tiles 0 and 8 share lines: in one K block the read for `t
  = 8` would see the value from the previous K block, not the one `t = 0` just stored. C3 (injective) rules this
  out.
- **A read in the first K block.** It would `get` a token no `put` has produced: the count would never close.
  C5 makes that read dead, so the lowering drops it.
