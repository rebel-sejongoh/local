# Matmul with SP partial sums as a queue: before and after distribution

The example of [`sp-psum.md`](sp-psum.md), `y = relu(x @ w + bias)` with `x[2048, 512]`, `w[512, 256]`, 16 DNCs,
2 NCores per DNC, 16 tiles of 4 rows per NCore. There the partial sums are an SP buffer read and rewritten
across K blocks, and the syncs have to be derived from that dependence. Here they are a **queue in SP**: the
SPSU pushes each tile's partial sum, the SPLU pops it one K block later, in the same order. The syncs belong to
the queue ops, so distributing the loops is a projection: each unit keeps its own ops and nothing is derived.

## The queue

```mlir
%q = queue.alloc {chunk = 4} : !queue<16 x vector<4x64xdlf16>, #sp>
```

- 16 slots of one tile each, a ring in SP (64 lines). One unit pushes (SPSU), one pops (SPLU).
- `chunk = 4`: one sync token stands for 4 consecutive slots. The SPLU–SPSU sync FIFOs of one NCore hold 16
  tokens (SPSU `SYNC`, ISA), so `slots / chunk` must not exceed 16; here it is 4.
- The `j`-th push and the `j`-th pop use slot `j mod 16`.

Lowering of each op (fixed, wherever it sits):

| Op | Unit | Becomes |
|---|---|---|
| first push of a chunk | SPSU | `sync get %q.space` before the store |
| `queue.push %q, v` | SPSU | `store.sp` to the next slot (the value from VU, or `zero`: `ST`'s ZERO producer) |
| last push of a chunk | SPSU | `sync put %q.data` after the store |
| first pop of a chunk | SPLU | `sync get %q.data` before the load |
| `%v = queue.pop %q` | SPLU | `load.sp` from the next slot |
| last pop of a chunk | SPLU | `sync put %q.space` after the load |
| `queue.alloc` | SPLU / SPSU | the SPLU puts `slots / chunk` space tokens at the start; the SPSU takes them back at the end |

"First / last of a chunk" must be a loop boundary: the pushes (and pops) of one chunk are exactly one iteration
of a loop. Here that is one iteration of `tc` (4 tiles of `ti`).

## Before distribution: the fused loop IR

```mlir
primitive @mm_sp_queue attributes {spmd_dncs = 16} {
  %x     = alloc : memref<8x2048xvector<64xdlf16>, #shm>         // x[kb][m]
  %w     = alloc : memref<8x4x64xvector<64xdlf16>, #shm>         // w[kb][nb][q]
  %bias  = alloc : memref<4xvector<64xdlf16>, #shm>
  %y     = alloc : memref<4x2048xvector<64xdlf16>, #shm>         // y[nb][m]
  %sp_x  = alloc : memref<8x128xvector<64xdlf16>, #sp>
  %sp_w  = alloc : memref<8x4x64xvector<64xdlf16>, #sp>
  %sp_b  = alloc : memref<4xvector<64xdlf16>, #sp>
  %sp_y  = alloc : memref<4x128xvector<64xdlf16>, #sp>

  pipeline (%x, %w, %bias, %y, %sp_x, %sp_w, %sp_b, %sp_y) attributes {ncores = 2} {
    for kb = 0 .. 8 {
      load.shm2sp %sp_x[kb, 0], %x[kb, 128*%d]      : vector<128x64xdlf16>
    }
    load.shm2sp %sp_w, %w
    load.shm2sp %sp_b, %bias
    for nc = 0 .. 2 {                                            // spatial: NCore
      %q = queue.alloc {chunk = 4} : !queue<16 x vector<4x64xdlf16>, #sp>
      for nb = 0 .. 4 {                                          // N block
        for tc = 0 .. 4 { for ti = 0 .. 4 {                      // 16 zero tiles: the sums start at 0
          queue.push %q, zero                     : vector<4x64xdlf16>
        } }
        for kb = 0 .. 8 {                                        // K block
          for tc = 0 .. 4 { for ti = 0 .. 4 {                    //   tile 4tc + ti
            %m  = affine.apply 64*nc + 16*tc + 4*ti
            %xt = load.sp %sp_x[kb, %m]           : vector<4x64xdlf16>
            %wt = load.sp %sp_w[kb, nb, 0]        : vector<64x64xdlf16>
            %p  = mxu.matmul %wt, %xt             : vector<4x64xdlf16>
            %pp = queue.pop %q                    : vector<4x64xdlf16>    // the sum over K blocks 0 .. kb-1
            %s  = vu.fma %p, 1.0, %pp             : vector<4x64xdlf16>
            queue.push %q, %s                     : vector<4x64xdlf16>    // the sum over 0 .. kb
          } }
        }
        for oc = 0 .. 4 { for oi = 0 .. 4 {                      // epilogue: tile 4oc + oi
          %m  = affine.apply 64*nc + 16*oc + 4*oi
          %a  = queue.pop %q                      : vector<4x64xdlf16>    // the whole sum
          %bl = load.sp %sp_b[nb]                 : vector<64xdlf16>
          %yb = vu.fma %a, 1.0, %bl               : vector<4x64xdlf16>
          %yr = vu.max %yb, 0.0                   : vector<4x64xdlf16>
          store.sp %sp_y[nb, %m], %yr
        } }
        store.sp2shm %y[nb, 128*%d + 64*nc], %sp_y[nb, 64*nc] : vector<64x64xdlf16>
      }
    }
  }
}
```

Compared with the register-psum example: no `vu.select (kb == 0)`, no `#vu` buffer, and the MXU latches each
weight tile once for all 16 tiles (`tiles = 16`).

### What the verifier checks

| # | Check | Here |
|---|---|---|
| Q1 | one unit pushes, one unit pops | SPSU, SPLU |
| Q2 | in each iteration of the innermost loop around all of the queue's ops, pushes = pops | per `nb`: 16 + 8·16 = 144 pushes, 8·16 + 16 = 144 pops |
| Q3 | in program order (the fused IR run sequentially), 0 ≤ occupancy ≤ slots | 16 after the zero fill, 16 throughout `kb` (each iteration pops one and pushes one), 0 after the epilogue |
| Q4 | the pushes, and the pops, of one chunk are one iteration of a loop | one iteration of `tc` and of `oc`: 4 tiles |
| Q5 | `slots / chunk` ≤ the sync FIFO depth between the two units | 16 / 4 = 4 ≤ 16 |
| Q6 | every loop nest of pushes (or pops) covers the slots exactly once, so slot `j mod slots` is an affine index of that nest and needs no modulo | `4·tc + ti` and `4·oc + oi`: each nest is 16 tiles |

The other channels (`%in_ready`, `%y_ready`) and the FIFOs are checked as before.

## After distribution

Each unit copies the loops around its ops and keeps only its ops; each queue op expands as in the table. Nothing
else is inserted, and no loop is peeled.

```mlir
  // FIFOs, one NCore
  %f_sx = fifo splu -> xvu  : vector<64xdlf16>          // weight tiles, x tiles
  %f_xm = fifo xvu  -> mxu  : vector<64xdlf16>          // to TU north (weights), to the ABSU (acts)
  %f_mv = fifo mxu  -> vu   : vector<64xdlf16>          // products
  %f_sv = fifo splu -> vu   : vector<64xdlf16>          // partial sums, bias
  %f_vs = fifo vu   -> spsu : vector<64xdlf16>          // partial sums, outputs
  // channels
  %in_ready = channel nclu -> splu                      // inputs resident (depth 4 + 2)
  %q.data   = channel spsu -> splu                      // a chunk of the queue is filled (depth 16)
  %q.space  = channel splu -> spsu                      // a chunk of the queue is free (depth 16)
  %y_ready  = channel spsu -> ncsu                      // an N block's outputs are in SP (depth 4 + 2)

  unit @nclu {
    for kb = 0 .. 8 { load.shm2sp %sp_x[kb, 0], %x[kb, 128*%d] : vector<128x64xdlf16> }
    load.shm2sp %sp_w, %w
    load.shm2sp %sp_b, %bias
    sync put %in_ready<0> ; sync put %in_ready<1>
  }

  unit @splu {
    sync get %in_ready
    for c = 0 .. 4 { sync put %q.space }                          // queue.alloc: 4 free chunks
    for nb = 0 .. 4 {
      for kb = 0 .. 8 {
        load.sp %sp_w[kb, nb, 0] -> %f_sx         : vector<64x64xdlf16>
        for tc = 0 .. 4 {
          sync get %q.data                                         // pop, first of the chunk
          for ti = 0 .. 4 {
            load.sp %sp_x[kb, 64*nc + 16*tc + 4*ti] -> %f_sx : vector<4x64xdlf16>
            load.sp %q[4*tc + ti] -> %f_sv        : vector<4x64xdlf16>   // pop
          }
          sync put %q.space                                        // pop, last of the chunk
        }
      }
      load.sp %sp_b[nb] -> %f_sv                  : vector<64xdlf16>
      for oc = 0 .. 4 {
        sync get %q.data
        for oi = 0 .. 4 {
          load.sp %q[4*oc + oi] -> %f_sv          : vector<4x64xdlf16>   // pop
        }
        sync put %q.space
      }
    }
  }

  unit @xvu {
    for nb = 0 .. 4 { for kb = 0 .. 8 {
      xvu.pass %f_sx -> %f_xm                     : vector<64x64xdlf16>
      for tc = 0 .. 4 { for ti = 0 .. 4 { xvu.pass %f_sx -> %f_xm : vector<4x64xdlf16> } }
    } }
  }

  unit @mxu {
    for nb = 0 .. 4 { for kb = 0 .. 8 {
      mxu.matmul out = %f_mv, weights = %f_xm, acts = %f_xm {tiles = 16, m_rows = 4}
    } }
  }

  unit @vu {
    for nb = 0 .. 4 {
      for kb = 0 .. 8 { for tc = 0 .. 4 { for ti = 0 .. 4 {
        vu.fma %f_mv, 1.0, %f_sv -> %f_vs         : vector<4x64xdlf16>   // the same for every kb
      } } }
      %bl = vu.latch %f_sv                        : vector<64xdlf16>
      for oc = 0 .. 4 { for oi = 0 .. 4 {
        %yb = vu.fma %f_sv, 1.0, %bl              : vector<4x64xdlf16>
        vu.max %yb, 0.0 -> %f_vs                  : vector<4x64xdlf16>
      } }
    }
  }

  unit @spsu {
    for nb = 0 .. 4 {
      for tc = 0 .. 4 {
        sync get %q.space                                          // push, first of the chunk
        for ti = 0 .. 4 { store.sp %q[4*tc + ti] <- zero : vector<4x64xdlf16> }
        sync put %q.data                                           // push, last of the chunk
      }
      for kb = 0 .. 8 { for tc = 0 .. 4 {
        sync get %q.space
        for ti = 0 .. 4 { store.sp %q[4*tc + ti] <- %f_vs : vector<4x64xdlf16> }
        sync put %q.data
      } }
      for oc = 0 .. 4 { for oi = 0 .. 4 {
        store.sp %sp_y[nb, 64*nc + 16*oc + 4*oi] <- %f_vs : vector<4x64xdlf16>
      } }
      sync put %y_ready
    }
    for c = 0 .. 4 { sync get %q.space }                          // queue.alloc: close the count
  }

  unit @ncsu {
    for nb = 0 .. 4 { for nc = 0 .. 2 {
      sync get %y_ready<nc>
      store.sp2shm %y[nb, 128*%d + 64*nc], %sp_y[nb, 64*nc] : vector<64x64xdlf16>
    } }
  }
```

### Counts

| Channel | `put` | `get` | Most tokens waiting |
|---|---|---|---|
| `%q.data` | SPSU: (4 + 8·4) · 4 `nb` = 144 | SPLU: (8·4 + 4) · 4 = 144 | 4 (= slots / chunk) |
| `%q.space` | SPLU: 4 + 144 | SPSU: 144 + 4 | 4 |
| `%in_ready` | NCLU: 1 per NCore | SPLU: 1 | 1 |
| `%y_ready` | SPSU: 4 | NCSU: 4 per NCore | 1 |

| FIFO, per `nb` | Pushed | Popped |
|---|---|---|
| SPLU → VU | 8·16 partial sums + 1 bias + 16 sums | VU: 8·16 + 1 latch + 16 |
| VU → SPSU | 8·16 partial sums + 16 outputs | SPSU: the same |
| MXU → VU | 8·16 | VU: 8·16 |

### How the tokens flow in one `nb`

| `%q.data` token | SPSU filled | SPLU then pops |
|---|---|---|
| 1–4 | zero chunks `tc = 0..3` | `kb = 0`, chunks `tc = 0..3`: the sums start at 0 |
| 5–8 | `kb = 0`'s chunks | `kb = 1`'s pops |
| … | | |
| 33–36 | `kb = 7`'s chunks: the whole sums | the epilogue, `oc = 0..3` |

Each `%q.space` token goes the other way: the SPLU returns a chunk once it has popped it, and the SPSU takes one
before it refills that chunk. At the start the SPLU hands over all 4.

## Scaling the queue

The queue's size is limited by SP, not by the sync FIFOs: a token stands for a chunk, and only the number of
chunks is bounded.

| Case | Slots (tiles) | Chunk | Tokens | SP |
|---|---|---|---|---|
| this example | 16 | 4 | 4 | 8 KB |
| one token per tile | 16 | 1 | 16 (the limit) | 8 KB |
| prefill tile, Mt = 512 rows × 64 columns | 128 | 16 | 8 | 64 KB |
| Mt = 512, Nt = 256 (4 column blocks in flight) | 512 | 64 | 8 | 256 KB |
| between NCores (depth 4 + 2) | any | slots / 6 or more | ≤ 6 | |

A larger chunk delays the reader until the whole chunk is written; with at least two chunks in the queue the
SPSU fills one while the SPLU reads another.
