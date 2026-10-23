# K-outer matmul on one DNC: a sequential program and its loop distribution

mcc's systolic matmul always runs K inside M: `loop mtile.M { loop K.bin { latch w; one 4-row tile } }`, so the TU
latches every weight tile once per M tile. This note writes the opposite order, K blocks outside and M tiles inside,
as one sequential program with a loop nest (in the spirit of mcc's `Mseq`), then distributes it onto the units and
checks whether the distribution is mechanical and free of structural hazards. Nothing here has been run; the
register and buffer sizes are from the ISA doc and `foundation/r100.py`.

Terms for a TU row's FMAs: **weight load** latches the row's 8 weight lines into LRF0..7 (mcc `tu_prime`);
**pass** forwards weight lines to the rows below (mcc forward); **mac** and **drain** compute the partial sum and
send it south.

## Problem and indices

`y[M, N] = x[M, K] @ w[K, N]`. M is split over DNCs and the two NCores; K stays inside the DNC (`K ≤ 1024`, no
cross-DNC reduction); N is walked in 64-lane blocks. Per NCore, `M_d` rows with `T = M_d / 4` tiles and `T ≫ 4`.

| Index | Range | Meaning |
|---|---|---|
| `nb` | `N / 64` | 64-lane output block: columns `64·nb .. +63` |
| `kb` | `K / 64` | K block: rows `64·kb .. +63` of w, columns of x (mcc's K bin) |
| `kq` | 64 | K row within a block: one weight line `w[64·kb + kq, 64·nb .. +63]` |
| `r` | 8 | TU row: holds K rows `64·kb + 8r .. +7` |
| `R` | ≤ 4 | variant C: tiles accumulated in VU registers at once (4 LRFs each, 16 in all) |
| `mg` | `T / R` | M group: R tiles whose accumulators sit in VU registers (variant C) |
| `mi` | `R` (C) or `T` (A) | M tile within the group |
| `mr` | 4 | row within the tile: M row `m = 4·(R·mg + mi) + mr` (C) or `4·mi + mr` (A) of this NCore |

## Registers available for blocking

| Storage | Size | Use in this schedule |
|---|---|---|
| TU LRF, per row | 12 (`lrf_tgt` 0..11) | LRF0..7: the row's 8 latched weight lines. LRF8..11: the 4 partial sums of the tile in flight, reused tile after tile |
| VU LRF | 16 (`src` 0x10..0x1F = LRF0..15) | 4 per M tile accumulator (one register per row `mr`, 64 lanes). Constants come from `.lccr` (CONST0..5), so no LRF is spent on them |
| AB, per TU row | 1 KB ring | one 4-line activation block at a time (16 B per line per row) |
| SP | 32768 lines (4 MiB), shared by the 2 NCores | w for the K blocks of one `nb`, x, psum or output lines |

So **register blocking can hold R ≤ 4 M tiles (16 rows) in the VU**, with no other VU register in use. With
`T ≫ 4`, variant C still reloads each weight block `T / R` times; only variant A (psum in SP) reloads it once.

## The sequential program

Two variants: **C** keeps a group of R tiles in VU registers; **A** keeps every tile's partial sum in SP.

Each statement is `value : type = UNIT.op operands`, so the shape it moves is on the left. Types:

| Type | Meaning |
|---|---|
| `shm<[R, C]>`, `sp<[R, C]>` | R lines of C lanes in SHM or SP (a line is 64 dlf16 lanes, 128 B) |
| `fifo<[L, 64]>` | L entries of one 64-lane line through a unit-to-unit FIFO: L beats, one instruction (or unroll step) each |
| `fifo<[L, 2, 4]>` | L entries of 8 lanes on a TU row's west link: two halves of 4 x values, each duplicated across 8 lanes |
| `tu.lrf<[8, 64]>`, `tu.lrf<[4, 64]>` | per TU row: the 8 latched weight lines (LRF0..7); the 4 partial sums of a tile (LRF8..11) |
| `vu.lrf<[4, 64]>`, `vu.lrf<[R, 4, 64]>` | 4 VU registers, one per tile row; R such groups (`%acc[mi]` is LRF `4·mi .. +4`) |
| `ab<[4, 8]>` per row | one 4-line block in a TU row's AB region, 8 lanes per line |

`[i .. +n]` is the half-open range `[i, i + n)`; `tile(mg, mi)` (variant C) is the 4 M rows `4·(R·mg + mi) .. +4` of this NCore;
`tile(mi)` (variant A, no M groups) is the 4 M rows `4·mi .. +4`. Either way the tiles together cover all
`M_d = 4T` rows; the last one is rows `M_d − 4 .. M_d − 1`.

```
Seq (variant C: register blocking)
  %xs : sp<[M_d, K]>          = NCLU.load   shm.x[rows of this NCore, 0 .. K]
  Loop nb in N/64:
    %ws : sp<[K, 64]>          = NCLU.load   shm.w[0 .. K, 64·nb .. +64]
                                 NCLU.put    stage -> SPLU
    Loop mg in T/R:
      %acc : vu.lrf<[R, 4, 64]>                                             // R tiles × 4 rows: VU LRF0 .. 4R − 1
      Loop kb in K/64:
        %wf : fifo<[64, 64]>   = SPLU.stage  %ws[64·kb .. +64, :]           // 64 LDUs, one line each
        %wn : fifo<[64, 64]>   = XVU.pass    %wf  -> TU.north                // 64 LOGICALs (tu_tgt)
        %W  : tu.lrf<[8, 64]>  = TU[r].load  %wn                             // row r latches w[64·kb + 8r .. +8, :],
                                                                            //   passes the 56 − 8r lines below it
        Loop mi in R:
          %xf : fifo<[4, 64]> = SPLU.stage  %xs[tile(mg, mi), 64·kb .. +64]  // 1 LDU, burst 4
          %xa : fifo<[4, 64]> = XVU.pass    %xf  -> ABSU                     // 4 LOGICALs (ab_tgt)
          %ab : ab<[4, 8]>    = ABSU.store  %xa                              // row r gets lanes 8r .. +8: x[·, 64·kb + 8r .. +8]
                                 ABSU.put abw ; ABSU.get abf
                                 ABLU.put abf ; ABLU.get abw
          %z  : fifo<[4, 2, 4]> = ABLU[r].load %ab                           // 2 LDUs, burst 4: halves h = 0, 1
          %ps : tu.lrf<[4, 64]> = TU[r].mac  %W[0 .. 4], %z[:, 0], north     // row 0: + 0 instead of north
          %s  : fifo<[4, 64]>   = TU[r].drain %W[4 .. 8], %z[:, 1], %ps -> south   // row 7's south is the VU
          %acc[mi] : vu.lrf<[4, 64]> = VU.add %s, %acc[mi]                  // kb == 0: %acc[mi] = %s
      Loop mi in R:
        %yv : fifo<[4, 64]>     = VU.push    %acc[mi] -> SPSU
        %ys : sp<[4, 64]>       = SPSU.store %yv
                                  SPSU.put done ; NCSU.get done
        shm.y[tile(mg, mi), 64·nb .. +64] : shm<[4, 64]> = NCSU.store %ys
```

Variant A drops `Loop mg` (`Loop mi` runs over all T tiles) and keeps the
partial sums in an SP band `%pb`. This is the order rcl2's dense GEMM uses (`rebel_sp_matmul_fp16_seq1.h`, VU loop:
first K block adds `0.0`, middle blocks add the SPLU psum and write back through SPSU, the last block writes the
output).

```
Seq (variant A: partial sums in SP)
  %xs : sp<[M_d, K]>          = NCLU.load   shm.x[rows of this NCore, 0 .. K]
  Loop nb in N/64:
    %ws : sp<[K, 64]>          = NCLU.load   shm.w[0 .. K, 64·nb .. +64]
                                 NCLU.put    stage -> SPLU
    %pb : sp<[M_d, 64]>                                                     // psum band, rewritten every kb
    Loop kb in K/64:
      %wf : fifo<[64, 64]>     = SPLU.stage  %ws[64·kb .. +64, :]
      %wn : fifo<[64, 64]>     = XVU.pass    %wf  -> TU.north
      %W  : tu.lrf<[8, 64]>    = TU[r].load  %wn                             // once per (nb, kb)
      Loop mi in T:
        %xf : fifo<[4, 64]>   = SPLU.stage  %xs[tile(mi), 64·kb .. +64]
        %xa : fifo<[4, 64]>   = XVU.pass    %xf  -> ABSU
        %ab : ab<[4, 8]>      = ABSU.store  %xa
                                ABSU.put abw ; ABSU.get abf
                                ABLU.put abf ; ABLU.get abw
        %z  : fifo<[4, 2, 4]> = ABLU[r].load %ab
        %ps : tu.lrf<[4, 64]> = TU[r].mac   %W[0 .. 4], %z[:, 0], north
        %s  : fifo<[4, 64]>   = TU[r].drain %W[4 .. 8], %z[:, 1], %ps -> south
        [kb > 0]  SPLU.get pwrote                                           // psum of tile mi from block kb − 1
        [kb > 0]  %pf : fifo<[4, 64]> = SPLU.stage %pb[tile(mi), :]         // after the x stage of tile mi
        %a  : fifo<[4, 64]>   = VU.add     %s, (kb > 0 ? %pf : 0) -> SPSU
        %pb[tile(mi), :] : sp<[4, 64]> = SPSU.store %a
        [kb < K/64 − 1] SPSU.put pwrote
        [kb = K/64 − 1] SPSU.put done ; NCSU.get done
        [kb = K/64 − 1] shm.y[tile(mi), 64·nb .. +64] : shm<[4, 64]> = NCSU.store %pb[tile(mi), :]
```

The `[kb …]` guards go away if the first and last iterations of `Loop kb` are peeled, as rcl2's VU does (first
block with `Z = 0.0`, a `Bin − 2` loop with `Z = SPLU`, then a separate last block). To keep the three bodies short,
two names stand for statement groups copied from the code above (they are not operations; each use is replaced by
its statements):

```
%W = weights(%ws, kb) :=                                                   // w for K block kb, latched in the TU
  %wf : fifo<[64, 64]>   = SPLU.stage  %ws[64·kb .. +64, :]
  %wn : fifo<[64, 64]>   = XVU.pass    %wf  -> TU.north
  %W  : tu.lrf<[8, 64]>  = TU[r].load  %wn

%s = tile_mac(%xs, %W, kb, mi) :=                                           // tile mi times the latched w
  %xf : fifo<[4, 64]>   = SPLU.stage  %xs[tile(mi), 64·kb .. +64]
  %xa : fifo<[4, 64]>   = XVU.pass    %xf  -> ABSU
  %ab : ab<[4, 8]>      = ABSU.store  %xa
                          ABSU.put abw ; ABSU.get abf
                          ABLU.put abf ; ABLU.get abw
  %z  : fifo<[4, 2, 4]> = ABLU[r].load %ab
  %ps : tu.lrf<[4, 64]> = TU[r].mac   %W[0 .. 4], %z[:, 0], north
  %s  : fifo<[4, 64]>   = TU[r].drain %W[4 .. 8], %z[:, 1], %ps -> south
```

This assumes `K/64 ≥ 2`; with one K block the first and last bodies merge.

```
Seq (variant A, peeled)
  %xs : sp<[M_d, K]>          = NCLU.load   shm.x[rows of this NCore, 0 .. K]
  Loop nb in N/64:
    %ws : sp<[K, 64]>          = NCLU.load   shm.w[0 .. K, 64·nb .. +64]
                                 NCLU.put    stage -> SPLU
    %pb : sp<[M_d, 64]>
    // first K block: no psum to read
    %W  : tu.lrf<[8, 64]>       = weights(%ws, 0)
    Loop mi in T:
      %s  : fifo<[4, 64]>     = tile_mac(%xs, %W, 0, mi)
      %a  : fifo<[4, 64]>     = VU.add     %s, 0 -> SPSU
      %pb[tile(mi), :] : sp<[4, 64]> = SPSU.store %a
                                SPSU.put pwrote
    // middle K blocks
    Loop kb in [1, K/64 − 1):                                              // K/64 − 2 iterations
      %W  : tu.lrf<[8, 64]>     = weights(%ws, kb)
      Loop mi in T:
        %s  : fifo<[4, 64]>   = tile_mac(%xs, %W, kb, mi)
                                SPLU.get pwrote
        %pf : fifo<[4, 64]>   = SPLU.stage %pb[tile(mi), :]
        %a  : fifo<[4, 64]>   = VU.add     %s, %pf -> SPSU
        %pb[tile(mi), :] : sp<[4, 64]> = SPSU.store %a
                                SPSU.put pwrote
    // last K block: the sum goes out
    %W  : tu.lrf<[8, 64]>       = weights(%ws, K/64 − 1)
    Loop mi in T:
      %s  : fifo<[4, 64]>     = tile_mac(%xs, %W, K/64 − 1, mi)
                                SPLU.get pwrote
      %pf : fifo<[4, 64]>     = SPLU.stage %pb[tile(mi), :]
      %a  : fifo<[4, 64]>     = VU.add     %s, %pf -> SPSU
      %pb[tile(mi), :] : sp<[4, 64]> = SPSU.store %a
                                SPSU.put done ; NCSU.get done
      shm.y[tile(mi), 64·nb .. +64] : shm<[4, 64]> = NCSU.store %pb[tile(mi), :]
```

The three bodies differ only in their VU addend and their last sync, so each unit gets three copies of its loop
body, without branches. `pwrote` is balanced: T puts in the first block, T gets in the last, and one of each per
tile in between.

The psum lines are shown as `[4, 64]` like the output. With high-precision accumulation they are wider than dlf16;
rcl2 packs them on EVT0 (7 lines per tile instead of more) at the cost of a 9-cycle VU step per tile.

The shape on the left fixes each unit's instruction count: a `fifo<[64, 64]>` stage is 64 single-line LDUs (or
fewer with bursts), its pass is 64 LOGICALs, a `fifo<[4, 64]>` is one 4-beat burst or one `degree = 2` FMA.

Weight latches per NCore, for each `nb`: current mcc order `T · K/64`; variant C `(T / R) · K/64`; variant A `K/64`.

## Loop distribution

Each unit's program is the sequential program restricted to that unit's statements, with every enclosing loop
kept (same trip counts). Two properties make this projection valid:

- A statement stays in the same loops as in the sequential program. For example, the TU's weight load is inside
  `Loop kb` and outside `Loop mi` in both, so it runs once per K block on the TU, as the sequential program says.
- A unit reads only its own registers and what arrives on its input FIFOs or sync channels. For example, the TU
  never reads SP: it gets w from the north link and x from ABLU; the VU gets partial sums from TU row 7.

| Unit | Distributed program (variant C) |
|---|---|
| NCLU | `load x ; Loop nb { load w ; put stage }` |
| SPLU | `Loop nb { get stage ; Loop mg { Loop kb { stage w (64) ; Loop mi { stage x (4) } } } }` |
| XVU | `Loop nb { Loop mg { Loop kb { pass ×64 -> TU.north ; Loop mi { pass ×4 -> ABSU } } } }` |
| ABSU | `Loop nb { Loop mg { Loop kb { Loop mi { store 4 ; put abw ; get abf } } } }` |
| ABLU:r | `Loop nb { Loop mg { Loop kb { Loop mi { put abf ; get abw ; load ×2 (4) } } } }` |
| TU:r | `Loop nb { Loop mg { Loop kb { weight load ; Loop (56 − 8r) { pass } ; Loop mi { mac ; drain } } } }` |
| VU | `Loop nb { Loop mg { Loop kb { Loop mi { acc[mi] += pop(TU) ×4 } } ; Loop mi { push acc[mi] } } }` |
| SPSU | `Loop nb { Loop mg { Loop mi { store 4 ; put done } } }` |
| NCSU | `Loop nb { Loop mg { Loop mi { get done ; store } } }` |

Variant A adds to SPLU `[kb > 0] get pwrote ; stage psum (4)` after each `stage x`, to VU a second pop per tile,
and to SPSU a store per `(kb, mi)` with `put pwrote`; SPSU's and NCSU's loops move inside `Loop kb`.

Two points need more than a projection:

- **A register index that depends on a loop variable.** The VU's `acc[mi]` is LRF `4·mi .. 4·mi + 3`. The hardware
  has no register-indirect operand, so the VU's `Loop mi` is unrolled at emit (R ≤ 4 copies, one FMA each with
  `lrf_tgt = 4·mi`, `degree = 2`). This is the same kind of rewrite as the TU's row index in `mlir-machine-ir.md`.
- **The first K block.** `kb == 0` writes instead of adding (or zeroes `acc` before `Loop kb`). In variant A it also
  skips the psum load, so SPLU's and VU's bodies differ for `kb = 0`: peel the first iteration of `Loop kb`.

## Checks

### Channel order

Every FIFO and sync channel has one producer and one consumer. The projection keeps each unit's statements in the
sequential program's order, so a channel's pushes and pops come in the same order on both sides. Counts per K block
`kb` and tile `mi`:

| Channel | Producer pushes | Consumer pops | Order on both sides |
|---|---|---|---|
| SPLU → XVU | 64 w, then 4 x per tile | XVU: 64, then 4 per tile | w before the tiles of the block |
| XVU → TU row 0 north | 64 per `kb` | row 0: 8 latched + 56 passed | per `kb` |
| TU row r−1 → row r (r ≥ 1) | `56 − 8(r−1)` w, then 4 per tile | row r: `8 + (56 − 8r)` w, then 4 per tile | `64 − 8r` both; w before psums |
| XVU → ABSU | 4 per tile | ABSU: 4 per tile (one block) | per tile |
| ABLU:r → TU row r west | 8 per tile | 4 + 4 per tile | per tile |
| TU row 7 → VU | 4 per tile | VU: 4 per tile | per tile |
| SPLU → VU (A only) | 4 per tile, `kb > 0` | VU: 4 per tile, `kb > 0` | after the TU pop of the same tile |
| SPSU → SPLU sync `pwrote` (A only) | 1 per tile, `kb < K/64 − 1` | 1 per tile, `kb > 0` | tile `mi` of block `kb` before tile `mi` of block `kb + 1` |

### Structural resources

| Resource | Who uses it, and when | Conflict? |
|---|---|---|
| TU LRF0..7 | written by the weight load at the start of a K block, read by every tile of the block | No: the next weight load follows the block's last tile in the row's program |
| TU LRF8..11 | written by `mac`, read by `drain`, per tile | No: sequential in the row's program |
| North link | per `kb`: w lines, then the block's psums | No: a row passes the next block's w only after its own tiles, so every link carries w(kb), psum(kb), w(kb+1), … in order |
| AB block | one 4-line block per tile, guarded by `abw` / `abf` | No: one block in flight; a second slot would allow overlap, not prevent a hazard |
| VU LRF | variant C: `4R ≤ 16`; variant A: 4 | C requires R ≤ 4 |
| SP | x `M_d · K/64` + w `K` (one `nb`) + psum or y `M_d` lines, per NCore | e.g. `M_d = 512`, `K = 1024`: 8192 + 1024 + 512 lines per NCore, about 19K for both, within 32768 |

### Streaming with the psum in SP (variant A)

The SP round trip does not stop the stream by itself:

- **Dependence distance.** `%pb[tile(mi)]` is written in block `kb` and read in block `kb + 1`, T tiles later. In
  steady state `pwrote` is already posted when SPLU asks for it, so SPLU never waits. Only when T is small (a few
  tiles) does SPLU at `kb + 1` wait for the write latency of TU → VU → SPSU → SP; then the pipeline drains once per
  K block. Small T is also where variant A saves little, since there are few weight reloads to save.
- **Bandwidth.** Per tile and K block, SPLU reads 8 lines (4 x + 4 psum) instead of 4, and SPSU writes 4 lines
  instead of 4 per `K/64` blocks. The TU needs about 8 cycles per tile, so if SPLU or the VU cannot keep up, the
  stream slows rather than stops. rcl2's note gives one data point: with packed high-precision psums the VU takes 9
  cycles per tile against the TU's 8.

So variant A trades weight reloads for SP traffic per tile; which one costs more needs the VP.

### Progress (deadlock)

No unit waits on a value that requires its own later output. The one place where order matters is SPLU in
variant A: it must push tile `mi`'s x before tile `mi`'s psum, because the VU pops the TU's result (which needs that
x) before the psum. Pushing psums ahead of the x they pair with can fill the VU-bound FIFO, block SPLU, and starve
the TU of the x that the VU is waiting on. The sequential order already has x before psum, and the projection keeps
it. How far SPLU may run ahead (prefetch the next tile's psum) depends on FIFO depths, which are not documented.

## What the exercise shows

- The loop distribution is mechanical: project the sequential program per unit, keep the loops, unroll the loops
  whose variable selects a register (VU `acc[mi]`, TU row `r`), and peel the first K block when its body differs.
- Correct ordering follows from one rule: within each loop body, a unit's pushes appear in the same order as the
  consumer's pops. Writing the schedule as one sequential program guarantees it.
- The structural limits are capacities, not ordering: VU registers (R ≤ 4), one AB block, SP lines, and FIFO
  depths for how far a producer may run ahead.
- With `T ≫ 4`, register blocking alone cuts weight reloads only by R ≤ 4; reloading each weight block once per
  `nb` needs the SP psum of variant A.

Open points:

- mcc's `tiling.py` rejects `bin > 16` because PrecSim keeps only the last 16 K tiles in the "accumulation seam
  between the TU and the VU". Variant C accumulates in VU registers like today's `bin`, so it may hit the same limit;
  variant A accumulates through SP and may not. Neither has been checked.
- Whether the weight latch (64 north beats per K block) or SPLU throughput dominates after the reorder; this needs
  the VP.
- mcc has no knob for this order: `m_tiles` (M) is always outside `bin` (K). Adding it means a loop-order field in
  `TilingDecision` and an `mseq_matmul` that emits the K-outer nest.
