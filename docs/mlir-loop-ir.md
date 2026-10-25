# MLIR loop IR for REBEL pipelines: fused and dataflow

A design for two MLIR-based loop IRs between mcc's tiled op and the machine IR of
[`mlir-machine-ir.md`](mlir-machine-ir.md), for the computation of one DNC. It follows the **Fused IR** of the
"Low-level mcc MLIR dialects" document
([Google doc](https://docs.google.com/document/d/1p8DtdZuhfBHAxJXkOacq0ODQ4XXJT266dsRh2-jL6sc/edit)). It is a
design; no compiler implements it.

- The **fused loop IR** is a sequential program: loop nests over SHM and SP buffers and SSA values, with no
  units, FIFOs or syncs. A `pipeline` op marks a region the hardware can run as dataflow: the units run its
  ops concurrently, passing values through FIFOs and syncing on SP buffers.
- The **dataflow loop IR** is the same region after loop distribution and unit projection: one block of loops
  per unit, with FIFOs between units and sync channels on SP buffers.

The conversion between them is mechanical when the fused loop IR follows a few programming constraints. One
example runs through the document: a weight-stationary matmul in outer-product order, tiled in M, N and K, with
the partial sums in VU registers.

| Section | Contents |
|---|---|
| [Overview](#overview) | the two IRs, where they sit, the running example |
| [Fused loop IR](#fused-loop-ir) | ops, memory, values, the canonical form; the example |
| [Programming constraints](#programming-constraints) | C1–C8: what makes sync insertion mechanical |
| [Dataflow loop IR](#dataflow-loop-ir) | unit blocks, FIFOs, channels; the example |
| [From fused to dataflow](#from-fused-to-dataflow) | units, routing, sync insertion, checks, projection, unit-local passes |
| [Appendix A: from mcc's traced op](#appendix-a-from-mccs-traced-op-to-the-fused-loop-ir) | lowering mcc's IR before mseq to the fused loop IR |
| [Appendix B: other patterns](#appendix-b-other-patterns) | elementwise, RMSNorm, softmax |
| [Appendix C: hoisting (later)](#appendix-c-hoisting-later) | moving loads to outer loops: latches, resident inputs, fewer syncs |
| [Appendix D: where a pipeline must be cut](#appendix-d-where-a-pipeline-must-be-cut) | constraint violations and their cuts |
| [Appendix E: prototype](#appendix-e-prototype) | `lower.py` and its results |
| [Appendix F: next, partial sums in SP](#appendix-f-next-partial-sums-in-sp) | rcl2's order; the `accumulate` loop and its phase syncs |
| [Appendix G: resources and performance](#appendix-g-resources-and-performance) | what can be counted early, what cannot |
| [Appendix H: open points](#appendix-h-open-points) | |

## Overview

```
kpl declaration → kpl_ir graph → traced op (Expr DAG + TilingDecision + Mdmap; StreamPlan)     ← mcc today
   │  (today: mseq builders → Mseq → Mpn → JIR)                                  Appendix A
   ▼
fused loop IR       sequential loop nests; `pipeline` regions; SHM/SP buffers, SSA values; canonical form
   │  hoisting (later: Appendix C)
   ▼
fused loop IR, hoisted
   │  units, routing, sync insertion, checks (C1–C8, P1–P7)
   ▼
dataflow loop IR    per pipeline: one block of loops per unit; FIFOs, sync channels
   │  unit-local passes (MXU tile folding, VU unrolling, address registers), register allocation
   ▼
machine IR → assembly per DNC                                                    mlir-machine-ir.md
```

A `pipeline` is one SDF. Its buffers are allocated before it starts and live until it ends; the next pipeline
starts after it. Inside, the fused loop IR reads as if one processor ran it: the program order is the order of
the data. The conversion spreads the ops over the units without changing that order. That is why it can insert
the FIFOs and syncs by rule instead of by search.

**The running example.** `y = relu(x @ w + bias)`, `x[2048, 512]`, `w[512, 256]`, DLFloat16.

| Axis | Tiling |
|---|---|
| M | 16 DNCs × 128 rows (spatial, `%d`); 2 NCores × 64 rows (spatial, `nc`); 4 groups (`g`) of 4 tiles (`i`) of 4 rows |
| N | 4 blocks of 64 columns (`nb`): one line of the output |
| K | 8 blocks of 64 (`kb`): one MXU pass |

K is not split across DNCs: each DNC reduces all of K for its rows, so there is no reduction across DNCs.

The loop order inside an NCore is `nb`, `g`, `kb`, `i`. For each K block, the weight tile `w[kb, nb]` is latched
in the MXU (**weight-stationary**) and the group's 4 x tiles stream through it, once hoisting has moved the
weight load out of `i`. Each K block adds one rank-64
outer product to every tile's partial sum (**outer-product order**), so the partial sums of the group's 4 tiles
are live at once. They stay in VU registers: a tile is 4 lines, and the VU has 16. The group size is what the
registers allow; the weight tile is then latched 4 · 8 = 32 times per N block. Taking all 16 tiles of an NCore per
latch (8 latches) needs their partial sums in SP, which is rcl2's order and the next topic
([Appendix F](#appendix-f-next-partial-sums-in-sp)).

## Fused loop IR

### Ops and types

Every op that runs on a unit carries the unit's name.

| Op | Meaning | Unit after conversion |
|---|---|---|
| `alloc : memref<D0 x … x vector<64xdlf16>, #shm \| #sp>` | a buffer of 128-byte lines (64 DLFloat16 values), indexed by its layout's dimensions | allocator (outside the pipeline) |
| `%r = vu.alloc_regs : !vu.regs<N x T>` | `N` values of type `T` in VU registers (a tile of `n` lines takes `n` registers) | VU registers |
| `pipeline (%bufs…) { … }` | one SDF: the region that becomes dataflow | |
| `for i = 0 .. n { … }` | a loop with a static trip count (a runtime count is read once at the pipeline's start) | every unit with ops inside |
| `for i = 0 .. n iter(%a = %init) { … yield }` | a loop with loop-carried values | the unit that updates them |
| `nclu.load %sp[a], %shm[b] : T` | copy SHM → SP the lines a value of type `T` holds | NCLU |
| `ncsu.store %shm[b], %sp[a] : T` | copy SP → SHM, likewise | NCSU |
| `%v = splu.load %sp[a] : T` | read a line, a tile or a 64×64 weight tile into a value | SPLU |
| `spsu.store %sp[a], %v` | write a value's lines to SP | SPSU |
| `%v = vu.reg_read %r[i] : T`, `vu.reg_write %r[i], %v`, `vu.reg_write %r[i], zero : T` | pseudo ops: read, write or zero element `i` of a register array; the index is a loop index or a constant. They disappear when the VU's loops unroll: the registers become the operands of the ops around them | VU |
| `%r = vu.<op> …`, `%r = xvu.<op> …` | elementwise arithmetic on lines or tiles (`fma`, `max`, the sqrt sequence, …) | VU, XVU |
| `%p = mxu.matmul %w, %xt : vector<4x64xdlf16>` | a tile of 4 rows of acts (64 K values per line) times the 64×64 weight tile `%w` (64 lines of 64 N values) | MXU |

### Memory

A buffer is a `memref` whose element is one line, `vector<64xdlf16>` (128 bytes), with the layout's dimensions
as its shape: `memref<8x2048xvector<64xdlf16>, #shm>` is `x[kb][m]`, 8 K blocks of 2048 rows. `%buf[i, …, j]`
addresses the line at that index. The access's type says how many lines it covers, consecutive along the last
dimension: `vector<64xdlf16>` one line, `vector<n x 64 x dlf16>` `n` lines (a transfer, which has no result,
carries the type after `:`). The buffer's name alone is all of it. Every unit of the fused IR counts in lines;
the conversion turns them into addresses:

| Unit | Address of line `e` (the index linearized in the buffer's layout) |
|---|---|
| NCLU, NCSU, SP side | line `SBR + SAR`: the buffer's first SP line plus `e` |
| NCLU, NCSU, SHM side | line `CBR + CAR` (`CBR` carries the SHM tag `0x80000`) |
| SPLU, SPSU | byte `128 · (first line + e)`, held one stride early (the unit adds the stride before it reads) |
| ABSU, ABLU | inside the MXU, not addressed in the fused IR |

Indices are affine in the loop indices and in `%d`, the DNC index. No unit multiplies. An affine address is kept
in a register that each loop advances by a constant at the end of an iteration and rewinds by its trip times
that constant on exit (`ADDSXRIMM`, `ADDCXRIMM` on the NCLU and NCSU, whose transfers also advance by their own
length; `MODLRFIMM` on the SPLU and SPSU). Each access stream takes one register (an NC descriptor, of 16; an SP
unit's LRF). Each step must fit its immediate (15 bits for SAR, 20 for CAR, 21 for `MODLRFIMM`). The conversion
refuses a pipeline that runs out of either.

A register array (`vu.alloc_regs`) is not memory. The VU has no register indirection, so its index must be a
loop index or a constant; the conversion unrolls that loop on the VU ([unit-local passes](#6-unit-local-passes)).

The SPLU and SPSU can also reach parts of a line (16-byte slices; a 2-byte scalar for the SPLU's own
registers). The examples need none; an access that does will get its own buffer type.

### Values

Values are MLIR builtin types: a line is `vector<64xdlf16>` (64 lanes), a tile `vector<n x 64 x dlf16>` of `n`
lines, a weight tile `vector<64x64xdlf16>`. An op on a tile is one instruction over its `n` lines, which every
unit on the path can do: the SPLU and SPSU as a burst, the XVU and VU with `unroll_degree` (1, 2, 4 or 8 lines
on consecutive registers; at least 3 avoids the LRF read-after-write stall), the MXU as an AB block of `m_rows`
lines. So `n` is 1, 2, 4 or 8, and a tile is never split below. The matmul's `n = 4` is mcc's leaf,
`M=4:line`. A line operand of a tile op (a bias line) applies to every line. Values never live in memory unless
an op writes them.

**Lanes.** Which tensor axis sits in a line's 64 lanes comes from the upstream IR's `roles` (`lane=N` for a
matmul's output, `lane=K` for RMSNorm and softmax, `lane=C` for the elementwise example) and its `LEAF`
(`K.blk[8] × K.in[64]`: 8 lines of 64 lanes). The types do not carry it. The conversion reads it from upstream
and checks that an elementwise op's operands put the same axis in their lanes, or that one of them is the same
in every lane (a per-row value after a lane reduction). The MXU changes the lane axis: its acts carry K, its
output N.

### Canonical form

Every example is written in a canonical form, which says what each iteration computes and nothing about where
data is kept longer:

- **Perfect nests.** Ops sit only in innermost loop bodies. Where an op must run after an inner loop has
  finished (an epilogue after the K loop, a second pass after the first), it gets its own nest, a sibling under
  the shared outer loops.
- **Transfers at the point of use.** Every `nclu.load` sits in the innermost iteration that reads its lines, and
  moves exactly those lines; every `ncsu.store` sits in the iteration that writes them. Every `splu.load` sits
  in the iteration that uses its value.
- **Registers as an array.** A value that crosses loops (an accumulator) is a register array read and written in
  the innermost body, and zeroed by a nest of its own before the loop that accumulates.

A load whose lines do not change with an inner loop's index is still repeated in every iteration of it. Moving it
to an outer loop, so that it runs once and its value is reused (a weight tile latched in the MXU, a bias line
latched in the VU, an input kept resident in SP), is **hoisting**, a later step
([Appendix C](#appendix-c-hoisting-later)). It changes how often a transfer runs and where its syncs go, not
what the pipeline computes.

### The example

Each group's partial sums are the register array `%acc`. SP buffers have their full size; an SP buffer written
inside the spatial loop `nc` has a line for each NCore (`%sp_w`, `%sp_b`), so the two NCores never share one.

```mlir
primitive @mm attributes {spmd_dncs = 16} {
  // SHM, in lines (64 values, 128 B each)
  %x     = alloc : memref<8x2048xvector<64xdlf16>, #shm>         // x[kb][m]: K block kb of row m; 2 MB
  %w     = alloc : memref<8x4x64xvector<64xdlf16>, #shm>         // w[kb][nb][q]: K row 64·kb + q, N block nb; 256 KB
  %bias  = alloc : memref<4xvector<64xdlf16>, #shm>              // bias[nb]: N values 64·nb .. +63
  %y     = alloc : memref<4x2048xvector<64xdlf16>, #shm>         // y[nb][m]
  // SP: this DNC's share
  %sp_x  = alloc : memref<8x128xvector<64xdlf16>, #sp>           // its 128 rows of every K block; 128 KB
  %sp_w  = alloc : memref<2x8x4x64xvector<64xdlf16>, #sp>        // w, per NCore; 512 KB
  %sp_b  = alloc : memref<2x4xvector<64xdlf16>, #sp>             // bias, per NCore
  %sp_y  = alloc : memref<4x128xvector<64xdlf16>, #sp>           // 64 KB
  // VU registers
  %acc   = vu.alloc_regs : !vu.regs<4 x vector<4x64xdlf16>>     // the group's 4 partial-sum tiles: LRF0..15

  pipeline (%x, %w, %bias, %y, %sp_x, %sp_w, %sp_b, %sp_y) attributes {ncores = 2} {
    for nc = 0 .. 2 {                                            // spatial: NCore, rows 64·nc .. +63
      for nb = 0 .. 4 {                                          // N block
        for g = 0 .. 4 {                                         // group of 4 tiles: rows 64·nc + 16g .. +15
          for i = 0 .. 4 {                                       // the sums start at 0
            vu.reg_write %acc[i], zero                                 : vector<4x64xdlf16>
          }
          for kb = 0 .. 8 {                                      // K block
            for i = 0 .. 4 {                                     // tile 4g + i
              %m  = affine.apply 64*nc + 16*g + 4*i
              nclu.load %sp_w[nc, kb, nb, 0], %w[kb, nb, 0]            : vector<64x64xdlf16>
              nclu.load %sp_x[kb, %m], %x[kb, 128*%d + %m]             : vector<4x64xdlf16>
              %wt = splu.load %sp_w[nc, kb, nb, 0]                     : vector<64x64xdlf16>
              %xt = splu.load %sp_x[kb, %m]                            : vector<4x64xdlf16>
              %p  = mxu.matmul %wt, %xt                                : vector<4x64xdlf16>   // this K block's product
              %a  = vu.reg_read %acc[i]                                : vector<4x64xdlf16>   // the sum over K blocks 0 .. kb-1
              %s  = vu.fma %p, 1.0, %a                                 : vector<4x64xdlf16>
              vu.reg_write %acc[i], %s                                                        // the sum over 0 .. kb
            }
          }
          for o = 0 .. 4 {                                       // epilogue: tile 4g + o, its whole sum
            %m  = affine.apply 64*nc + 16*g + 4*o
            nclu.load %sp_b[nc, nb], %bias[nb]                         : vector<64xdlf16>
            %bl = splu.load %sp_b[nc, nb]                              : vector<64xdlf16>
            %a  = vu.reg_read %acc[o]                                  : vector<4x64xdlf16>
            %yb = vu.fma %a, 1.0, %bl                                  : vector<4x64xdlf16>   // + bias (a line, to every row)
            %yr = vu.max %yb, 0.0                                      : vector<4x64xdlf16>   // relu
            spsu.store %sp_y[nb, %m], %yr
            ncsu.store %y[nb, 128*%d + %m], %sp_y[nb, %m]              : vector<4x64xdlf16>
          }
        }
      }
    }
  }
}
```

`for nc` is spatial: each NCore runs one iteration, at the same time, on its own SPLU, XVU, MXU, VU and SPSU; the
NCLU and NCSU serve both.

**Why `g`, `i` and `o`.** Inside a group, the K loop runs to the end, and each K block's weight tile serves the
group's 4 tiles (`i`): once hoisted out of `i`, it is latched once for all 4. The epilogue needs a tile's whole
sum, so it cannot sit in `i`, which is inside `kb`; it runs in its own loop over the group's 4 tiles (`o`, the
same index as `i`) after the K loop. The zero fill is a nest of its own before the K loop, so every K block reads
and adds the same way.

| Loop | Covers | When it has run through |
|---|---|---|
| `i` (or `o`) | a group's 16 rows, 4 tiles | the group, for one K block (or for the output) |
| `kb` | K = 512, eight 64-row blocks | the group's whole sums, for one N block |
| `g` | the NCore's 64 rows, 4 groups | all its rows, for one N block |
| `nb` | N = 256, four 64-column blocks | all the NCore's outputs |
| `nc` (spatial) | the DNC's 128 rows, two NCores | DNC `%d`'s rows |
| DNCs (spatial, `%d`) | 2048 rows, 16 DNCs | the whole tensor |

## Programming constraints

A pipeline converts to dataflow when it meets these constraints. Each is checked on the loop nest alone, and
each fixes where the conversion puts a FIFO or a sync, so that no placement has to be searched for.

| # | Constraint | What the conversion gets from it |
|---|---|---|
| C1 | **Units.** Every op's unit is fixed by its name ([table](#ops-and-types)) | projection without a choice |
| C2 | **Static loops.** Trip counts are static (or read once at the pipeline's start); indices are affine in loop indices and `%d` | every count is a product of trip counts; addresses are strides |
| C3 | **Values between units.** A value defined on one unit and used on another is used inside the iteration that defines it: in the same loop, or in loops nested inside it (a broadcast). It follows a hardware link: SPLU → XVU, SPLU → VU, XVU → MXU, XVU → VU, XVU → SPSU, MXU → VU, VU → SPSU, VU → XVU | a FIFO pushed and popped the same number of times per iteration; a broadcast is a latch |
| C4 | **Carried values.** A value carried across iterations (an `iter`, or a register array) belongs to one unit and fits its registers (VU: 16 lines) | no FIFO and no memory across iterations |
| C5 | **Buffers.** An SHM buffer is only read or only written in the pipeline. An SP buffer has one writer unit and one reader unit. An SP line written inside a spatial loop belongs to one of its iterations (the address uses its index) | one channel pair per buffer, with fixed ends |
| C6 | **Read after write.** A read of an SP buffer reads lines written in the same iteration of every loop around both the write and the read (both addresses use those loops' indices the same way), after the write in program order | a `ready` channel: put after the write, get before the read |
| C7 | **Rewrite.** An SP buffer may be rewritten in later iterations of a loop around the write and the read (its write address does not use the loop's index) | a `free` channel back, with one credit |
| C8 | **No cycles.** The graph of units, with an edge for each FIFO and each `ready` channel (writer → reader), is acyclic. `free` channels are not edges | no unit waits for its own output inside one iteration |

C3 and C6 are the fused-IR form of the machine IR's "same iteration" rule (P2): no value between units and no
memory location is matched across loop iterations, so every FIFO and `ready` channel counts the same on both
sides. C7 is the one controlled exception, and it comes with a channel of a fixed shape. C4 is why the example's
partial sums are in registers: in SP, each K block would read what the previous one wrote, which C6 forbids
([Appendix F](#appendix-f-next-partial-sums-in-sp) relaxes it).

Partial sums are the only planned exception to C6: an SP buffer that is read and then rewritten from its own
value. They get a dedicated op (`psum.accumulate`) and their own rules. Any other read-modify-write in SP stays
out of the fused loop IR unless it is generalized formally.

A buffer in SP that a pipeline only reads, or only writes, is an input from, or an output to, a neighboring
pipeline. A pipeline that breaks a constraint is cut into pipelines ([Appendix D](#appendix-d-where-a-pipeline-must-be-cut)).

In the example:

| # | Holds because |
|---|---|
| C3 | every value is used in the iteration of `i` or `o` that defines it |
| C4 | `%acc` is on the VU, 16 lines |
| C5 | `%sp_x`, `%sp_w`, `%sp_b`: NCLU writes, SPLU reads. `%sp_y`: SPSU writes, NCSU reads. `%sp_w` and `%sp_b` are indexed by `nc`; `%sp_x` and `%sp_y` by rows that `nc` splits |
| C6 | each SP line is written and read in the same iteration of `i` or `o` |
| C7 | `%sp_w[nc, kb, nb, 0]` is rewritten across `g` and `i`, `%sp_x[kb, %m]` across `nb`, `%sp_b[nc, nb]` across `g` and `o` |
| C8 | NCLU → SPLU → XVU → MXU → VU → SPSU → NCSU, and SPLU → VU |

## Dataflow loop IR

A pipeline in the dataflow loop IR is a list of **unit blocks**. A block holds one unit's ops in its own loops;
no loop is shared between blocks. Units pass values through FIFOs and order their SP accesses with channels.

| Op | Meaning |
|---|---|
| `%f = fifo a -> b : T` | a hardware FIFO from unit `a` to unit `b`, carrying lines |
| `%c = channel a -> b` | a sync counter from unit `a` to unit `b` (a SYNC FIFO); `%c<i>` is NCore `i`'s copy |
| `@unit { … }` | a block of one unit's ops |
| `sync put %c`, `sync get %c` | signal; wait for a signal (`put` blocks only when the counter is full) |
| `op … -> %f` | push the result into FIFO `%f` |
| `%f` as an operand | pop it |
| `splu.load %b[a] -> %f`, `spsu.store %b[a] <- %f` | the SPLU and SPSU with a FIFO end instead of a value |
| `xvu.pass %f -> %g` | forward through the XVU (SPLU → MXU, SPLU → SPSU have no direct link) |
| `%r = mxu.latch %f`, `%r = vu.latch %f` | pop a weight tile, or a broadcast value, into registers for the ops below |

**Semantics.** All blocks run concurrently. The blocks of one unit run in the order they are listed: the unit's
program is their concatenation, which the emitter produces at the end. Apart from that, the listing order means
nothing. A unit stops at a pop of an empty FIFO, a push into a full one, and a `get` with no `put` to match.

### The example

The fused pipeline has one top-level nest, so each unit has one block. The per-NCore units' blocks are NCore
`nc`'s.

```mlir
  %f_sx = fifo splu -> xvu  : vector<64xdlf16>          // weight tiles, x tiles
  %f_xm = fifo xvu  -> mxu  : vector<64xdlf16>          // to TU north (weights), to the ABSU (acts)
  %f_mv = fifo mxu  -> vu   : vector<64xdlf16>          // products
  %f_sv = fifo splu -> vu   : vector<64xdlf16>          // bias lines
  %f_vs = fifo vu   -> spsu : vector<64xdlf16>          // outputs

  %in_ready = channel nclu -> splu                      // a tile's weights and acts are in SP
  %in_free  = channel splu -> nclu                      //   and have been read
  %b_ready  = channel nclu -> splu                      // a bias line is in SP
  %b_free   = channel splu -> nclu                      //   and has been read
  %y_ready  = channel spsu -> ncsu                      // an output tile is in SP

  @nclu {
    for nb = 0 .. 4 {
      for g = 0 .. 4 {
        for kb = 0 .. 8 {
          for i = 0 .. 4 {
            for nc = 0 .. 2 {
              sync get %in_free<nc>
              nclu.load %sp_w[nc, kb, nb, 0], %w[kb, nb, 0]                              : vector<64x64xdlf16>
              nclu.load %sp_x[kb, 64*nc + 16*g + 4*i], %x[kb, 128*%d + 64*nc + 16*g + 4*i] : vector<4x64xdlf16>
              sync put %in_ready<nc>
            }
          }
        }
        for o = 0 .. 4 {
          for nc = 0 .. 2 {
            sync get %b_free<nc>
            nclu.load %sp_b[nc, nb], %bias[nb]                                           : vector<64xdlf16>
            sync put %b_ready<nc>
          }
        }
      }
    }
    for nc = 0 .. 2 {
      sync get %in_free<nc> ; sync get %b_free<nc>      // the credits back
    }
  }
  @splu {
    sync put %in_free ; sync put %b_free                // credits
    for nb = 0 .. 4 {
      for g = 0 .. 4 {
        for kb = 0 .. 8 {
          for i = 0 .. 4 {
            sync get %in_ready
            splu.load %sp_w[nc, kb, nb, 0] -> %f_sx                : vector<64x64xdlf16>
            splu.load %sp_x[kb, 64*nc + 16*g + 4*i] -> %f_sx       : vector<4x64xdlf16>
            sync put %in_free
          }
        }
        for o = 0 .. 4 {
          sync get %b_ready
          splu.load %sp_b[nc, nb] -> %f_sv                         : vector<64xdlf16>
          sync put %b_free
        }
      }
    }
  }
  @xvu {
    for nb = 0 .. 4 {
      for g = 0 .. 4 {
        for kb = 0 .. 8 {
          for i = 0 .. 4 {
            xvu.pass %f_sx -> %f_xm                                : vector<64x64xdlf16>
            xvu.pass %f_sx -> %f_xm                                : vector<4x64xdlf16>
          }
        }
      }
    }
  }
  @mxu {
    for nb = 0 .. 4 {
      for g = 0 .. 4 {
        for kb = 0 .. 8 {
          for i = 0 .. 4 {
            %wl = mxu.latch %f_xm                                  : vector<64x64xdlf16>
            mxu.matmul %wl, %f_xm -> %f_mv                         : vector<4x64xdlf16>
          }
        }
      }
    }
  }
  @vu {
    for nb = 0 .. 4 {
      for g = 0 .. 4 {
        for i = 0 .. 4 {
          vu.reg_write %acc[i], zero                               : vector<4x64xdlf16>
        }
        for kb = 0 .. 8 {
          for i = 0 .. 4 {
            %a = vu.reg_read %acc[i]                               : vector<4x64xdlf16>
            %s = vu.fma %f_mv, 1.0, %a                             : vector<4x64xdlf16>
            vu.reg_write %acc[i], %s
          }
        }
        for o = 0 .. 4 {
          %a  = vu.reg_read %acc[o]                                : vector<4x64xdlf16>
          %yb = vu.fma %a, 1.0, %f_sv                              : vector<4x64xdlf16>
          vu.max %yb, 0.0 -> %f_vs                                 : vector<4x64xdlf16>
        }
      }
    }
  }
  @spsu {
    for nb = 0 .. 4 {
      for g = 0 .. 4 {
        for o = 0 .. 4 {
          spsu.store %sp_y[nb, 64*nc + 16*g + 4*o] <- %f_vs        : vector<4x64xdlf16>
          sync put %y_ready
        }
      }
    }
  }
  @ncsu {
    for nb = 0 .. 4 {
      for g = 0 .. 4 {
        for o = 0 .. 4 {
          for nc = 0 .. 2 {
            sync get %y_ready<nc>
            ncsu.store %y[nb, 128*%d + 64*nc + 16*g + 4*o], %sp_y[nb, 64*nc + 16*g + 4*o] : vector<4x64xdlf16>
          }
        }
      }
    }
  }
```

The graph of units (`free` channels dashed):

```
         in_ready, b_ready     f_sx         f_xm         f_mv          f_vs           y_ready
  NCLU ───────────────▶ SPLU ───────▶ XVU ───────▶ MXU ───────▶ VU ───────▶ SPSU ──────────▶ NCSU
    ▲                    │ │                                     ▲
    └ ─ in_free, b_free ─┘ └──────────────── f_sv ───────────────┘
```

Data flows one way: no unit waits for a later unit's output. The `free` channels go back, but only to let the
NCLU rewrite a line the SPLU has finished with.

This is what the canonical form costs before hoisting: the NCLU and SPLU sync on every tile, every tile reloads
its weight tile into SP and into the MXU (`tiles = 1` per latch), and every bias line is loaded from SHM 16
times. Hoisting ([Appendix C](#appendix-c-hoisting-later)) removes each of these without changing the rules
used here.

## From fused to dataflow

| Step | On | Produces |
|---|---|---|
| 1. Units | fused IR | each op's unit (C1) |
| 2. Routing | fused IR | FIFOs, XVU passes, latches |
| 3. Sync insertion | fused IR | channels, with each `put` and `get` at a statement of the fused IR |
| 4. Checks | the fused IR with syncs | C1–C8; the machine IR's P1–P7, counted in program order |
| 5. Projection | the fused IR with syncs | the dataflow loop IR |
| 6. Unit-local passes | each block | MXU tile folding, VU unrolling, scheduling, addresses |

The syncs go in before the program is split. On the sequential program, the program order is one order every
unit agrees with, so the checks are a walk over one loop nest; after projection, the same check would have to
pair counts across blocks.

### 1. Units

Each op goes to the unit its name says. The inputs are written by the NCLU and read by the SPLU; `%sp_y` is
written by the SPSU and read by the NCSU; `%acc` is the VU's.

### 2. Routing

- **FIFOs.** Each value defined on one unit and used on another becomes a FIFO along the link. SPLU → MXU and
  SPLU → SPSU have no link and go through the XVU, which gets an `xvu.pass`.
- **Broadcasts.** A value used in loops nested inside its definition's iteration is sent once per defining
  iteration; the consumer pops it into a register and reuses it. For the MXU this is the weight latch: the trip
  product of the loops between the weight tile's definition and its use is the op's `tiles`. The canonical form
  has no broadcasts; hoisting makes them.

| Value | FIFO | Per |
|---|---|---|
| `%wt` | SPLU → XVU → MXU | `i`: the MXU latches it for one tile (`tiles = 1`) |
| `%xt` | SPLU → XVU → MXU | `i` |
| `%p` | MXU → VU | `i` |
| `%bl` | SPLU → VU | `o` |
| `%yr` | VU → SPSU | `o` |

### 3. Sync insertion

For each SP buffer, the channels go at fixed statements of the fused IR. Let `L` be the innermost loop around
both the write and the read (or the pipeline body).

| Channel | Kind | `put` | `get` |
|---|---|---|---|
| `ready` (writer → reader) | C6 | in `L`'s body, after the statement holding the write | in `L`'s body, before the statement holding the read |
| `free` (reader → writer) | C7 | in `L`'s body, after the statement holding the read; plus a credit, put by the reader at the pipeline's start | in `L`'s body, before the statement holding the write; plus one at the pipeline's end, by the writer |

The credit lets the first write go ahead; the last `get` takes it back, so every counter ends at zero. Channels
with the same two units whose `put`s and `get`s fall at adjacent statements of the same body merge: `%sp_w`'s
and `%sp_x`'s channels become `%in_ready` and `%in_free`.

The example with its syncs (each annotated with the unit that runs it):

```mlir
    for nc = 0 .. 2 {
      sync put %in_free                                 @splu   // credits
      sync put %b_free                                  @splu
      for nb = 0 .. 4 {
        for g = 0 .. 4 {
          for i = 0 .. 4 { vu.reg_write %acc[i], zero }
          for kb = 0 .. 8 {
            for i = 0 .. 4 {
              sync get %in_free                         @nclu   // free: before the writes
              nclu.load %sp_w[nc, kb, nb, 0], …
              nclu.load %sp_x[kb, %m], …
              sync put %in_ready                        @nclu   // ready: after the writes
              sync get %in_ready                        @splu   // ready: before the reads
              %wt = splu.load %sp_w[nc, kb, nb, 0]
              %xt = splu.load %sp_x[kb, %m]
              sync put %in_free                         @splu   // free: after the reads
              …
            }
          }
          for o = 0 .. 4 {
            sync get %b_free                            @nclu
            nclu.load %sp_b[nc, nb], %bias[nb]
            sync put %b_ready                           @nclu
            sync get %b_ready                           @splu
            %bl = splu.load %sp_b[nc, nb]
            sync put %b_free                            @splu
            …
            spsu.store %sp_y[nb, %m], %yr
            sync put %y_ready                           @spsu
            sync get %y_ready                           @ncsu
            ncsu.store %y[nb, 128*%d + %m], %sp_y[nb, %m]
          }
        }
      }
      sync get %in_free                                 @nclu   // credits back
      sync get %b_free                                  @nclu
    }
```

`%sp_y`'s write address uses every loop around it, so it needs no `free` channel.

### 4. Checks

The constraints C1–C8 are checked first. Then the machine IR's checks P1–P7
([`mlir-machine-ir.md`](mlir-machine-ir.md#constraints)) run on the fused IR with its syncs, by walking it in
program order:

| Check | In the example |
|---|---|
| P1: units | `%acc` and the epilogue temporaries on the VU |
| P2: counts per iteration | `i`: `%in_ready`, `%in_free` 1 `put` and 1 `get`; `%f_sx`, `%f_xm` 1 weight tile + 1 x tile pushed and popped; `%f_mv` 1 tile. `o`: `%b_ready`, `%b_free`, `%y_ready` 1 and 1; `%f_sv` 1 line, `%f_vs` 1 tile. `nc`'s body: the credits, 1 `put` and 1 `get` |
| P3: never a pop or `get` before its push or `put` | `%in_free`: credit, then `get`, `put` per `i`, then the last `get`: the count goes 1, 0, 1, 0, …, 0. The others: `put` before `get` in every body |
| P4: buffers | `%sp_x`, `%sp_w` covered by `%in_ready` and `%in_free`; `%sp_b` by `%b_ready` and `%b_free`; `%sp_y` by `%y_ready` |
| P5: no cycles | C8 |
| P6: capacity | every channel holds at most 1 token in program order |
| P7: resources | VU: 16 registers for `%acc`; the epilogue's `%yb` reuses `%acc[o]`'s 4 after their last read. SP: 5640 lines at full size |

Counts per NCore:

| Channel or FIFO | Pushed or `put` | Popped or `get` |
|---|---|---|
| `%in_ready` | NCLU: 4 `nb` · 4 `g` · 8 `kb` · 4 `i` = 512 | SPLU: 512 |
| `%in_free` | SPLU: 1 + 512 | NCLU: 512 + 1 |
| `%b_ready`, `%y_ready` | 4 · 4 · 4 `o` = 64 | 64 |
| `%b_free` | SPLU: 1 + 64 | NCLU: 64 + 1 |
| `%f_sx`, `%f_xm` | 512 weight tiles, 512 x tiles | the same |
| `%f_mv` | MXU: 512 tiles | VU: 512 |
| `%f_sv` | SPLU: 64 lines | VU: 64 |
| `%f_vs` | VU: 64 tiles | SPSU: 64 |

### 5. Projection

1. **Blocks.** For each top-level nest and each unit, the block is the nest with only that unit's ops and syncs,
   in the same order. A loop left with no ops is dropped. A value used on another unit becomes a push here and a
   pop there; a broadcast becomes a latch on the consumer.
2. **Spatial loops.** `for nc` disappears from the per-NCore units: each NCore's block has `nc` fixed, and its
   channels are that NCore's copies. On a unit both NCores share (the NCLU, the NCSU), it stays a loop, moved
   innermost so both NCores are served in step; statements outside the other loops (the credits) get a `for nc`
   of their own.
3. **Syncs between nests.** A sync between two top-level nests goes to the block of the nest on the same side.

Nothing is reordered, and no block is split further. Splitting a block into several blocks of the same unit is
loop fission inside that unit, and changes the order the unit runs its ops in. It is legal only if no dependence
crosses the split. Here it is not: splitting the VU's `g` loop into "all zero fills", "all accumulations", "all
epilogues" would zero `%acc` for the next group before this one's epilogue has read it. Blocks come apart where
the fused IR already has separate nests.

The counts above hold after projection unchanged: each block keeps its unit's statements and their loops.

### 6. Unit-local passes

Passes that change one unit's loops stay inside its block, and leave every count and pairing as it is.

- **MXU tiles.** The MXU folds the tiles that use one latched weight tile into one
  `mxu.matmul {tiles = n, m_rows = 4}`, as in the machine IR: `n = 1` in the canonical form, `n = 4` once the
  weight load is hoisted out of `i`.
- **VU registers.** The VU has no register indirection, so its `i` and `o` loops unroll, and `%acc[i]` becomes
  the fixed registers `LRF[4i .. 4i+3]`. The zero fill can fold into a peeled first K block that adds to the
  constant zero instead (`Z = CONST0`), which saves the 4 zeroing instructions per group:

  ```mlir
    @vu {
      for nb = 0 .. 4 {
        for g = 0 .. 4 {
          for kb = 0 .. 8 {                                    // i unrolled
            vu.fma %f_mv, 1.0, LRF[0..3]   -> LRF[0..3]        : vector<4x64xdlf16>
            vu.fma %f_mv, 1.0, LRF[4..7]   -> LRF[4..7]        : vector<4x64xdlf16>
            vu.fma %f_mv, 1.0, LRF[8..11]  -> LRF[8..11]       : vector<4x64xdlf16>
            vu.fma %f_mv, 1.0, LRF[12..15] -> LRF[12..15]      : vector<4x64xdlf16>
          }
          …                                                    // o unrolled likewise
        }
      }
    }
  ```
- **Scheduling.** An op may move above a `get` when it touches no buffer of that channel.
- **Addresses.** Each access stream gets its register and its strides ([Memory](#memory)).

Then register allocation and emission, as in [`mlir-machine-ir.md`](mlir-machine-ir.md).

## Appendix A: from mcc's traced op to the fused loop IR

Above the fused loop IR is mcc's IR just before mseq: the **traced op** (`TracedOp`, level 5 in
[`mcc-ir-to-jir.md`](mcc-ir-to-jir.md)), its expression DAG with a `TilingDecision` and an `Mdmap`, which
`trace_print.format_tiled` prints, and on the streaming arm the `StreamPlan` (level 6). It fixes the op's roles
(lane, shard and contract axes), the DNC split, the loop nest of tiles (`temporal`) and the buffers, but not the
units' statements: today the mseq builders (`mseq_elementwise`, `mseq_softmax`, `mseq_matmul`, …) turn it into
statements directly. The fused loop IR would take that place.
[`mlir-loop-ir/tiled.py`](mlir-loop-ir/tiled.py) prints the traced ops; the outputs are in
[`mlir-loop-ir/mcc/`](mlir-loop-ir/mcc/).

### The mapping

| Traced op | Fused loop IR |
|---|---|
| `spatial dnc[n] = shard.X[n]` | the pipeline is DNC `%d`'s share of X: an offset `%d · X/n` in every SHM index |
| `ncore[2]` | `for nc = 0 .. 2`, a spatial loop |
| `temporal` loops | `for` loops, outermost first, possibly reordered (below) |
| `LEAF X=n:line` | a tile of `n` lines, `vector<n x 64 x dlf16>` |
| `roles lane=…`, `K.blk[b] × K.in[64]` | which axis is in the lanes; `b` lines per row |
| the DAG's ops | `vu.*`, `xvu.*` and `mxu.matmul` ops in the loop body |
| `card` (`combine`, `reduce`, `stationary`, `streamed`) | `mxu.matmul`: the stationary operand is the weight tile, the streamed one the acts |
| `buffers SP:…` | `alloc … #sp` |
| `accumulate acc_edge …`, `cadence` | the partial sums: a register array, zeroed before the accumulating loop |
| `StreamPlan` passes | sibling nests in the group's body, one per pass |
| `StreamPlan` chunks | the loop that NC transfers and their syncs are hoisted to |

### The matmul

mcc refuses a contraction with an epilogue operand before tiling (with a prologue too:
[`mcc/mm1.out`](mlir-loop-ir/mcc/mm1.out), "this seam derives a systolic placement for exactly one held and one
streamed operand"). With only `x` and `w` (`(x @ w) * 0.125`, [`mcc/mm2048.out`](mlir-loop-ir/mcc/mm2048.out))
it tiles the contraction; the running example starts from that tiling and adds the bias and relu after it:

```
Expr: x:in[M,K]  w:in[K,N]  mul1=mul(x,w)  red2=reduce.add[K](mul1)  mul3=mul(red2,0.125)
tiled.trace  _systolic  N=256 M=2048 K=512        kind=systolic  units=ABLU,ABSU,NCLU,NCSU,TU,VU
  card      ComputeOperands(combine='mul', reduce='add', stationary='north', streamed='west')
  roles     lane=N  shard=M  contract=K
  spatial   dnc[16] = shard.M[16] × split.K.beat[1]
            ncore[2]  (within each dnc)
  temporal  loop laneblk.N[4]
              loop mtile.M[16]
                loop bin.K.beat[8]
                  loop K.bin[8]
                    LEAF  N=256:lane · M=4:line   reduce K.col[8] × K.beat[8]
  buffers   SP:kernel w @NCLU / SP:ab_bank x @NCLU / SP:tu_psum y @TU / SP:vu_acc acc @VU
  accumulate acc_edge ('VU', 'VU', 'acc')  monoid=add  cadence={'accum': 8, 'npass': 1}
```

| mcc | Fused loop IR |
|---|---|
| `dnc[16] = shard.M[16]`, `split.K.beat[1]` | DNC `%d`'s rows `128·%d .. +127`; K not split across DNCs |
| `ncore[2]` | `for nc = 0 .. 2`, 64 rows per NCore |
| `loop laneblk.N[4]` | `for nb = 0 .. 4`: N blocks of 64 |
| `loop mtile.M[16]`, `M=4:line` | `for g = 0 .. 4` × `for i = 0 .. 4`: 16 tiles of 4 rows, `vector<4x64xdlf16>` |
| `loop bin.K.beat[8]`, `K.col[8] × K.beat[8]` | `for kb = 0 .. 8`: K blocks of 64; within a block, the MXU |
| `stationary=north` (w), `streamed=west` (x) | `mxu.matmul`'s weight operand and acts |
| `card` `mul`, `reduce` | `mxu.matmul` within a K block; `vu.fma` into `%acc` across K blocks |
| `acc_edge (VU, VU)`, `cadence accum 8` | `%acc`, carried over the 8 K blocks |
| `mul3` (here bias and relu) | the epilogue nest after the K loop |
| loop order `mtile` outside `bin` | changed to `g` outside `kb` outside `i`: one weight latch serves a group's 4 tiles (outer-product order) |

The loop order is the one decision the conversion makes beyond renaming. With mcc's order (one tile at a time,
all K blocks), the weights are latched once per tile and K block: 16 · 8 = 128 latches per N block. Groups of 4
tiles take 32, as many as the VU's 16 registers allow; all 16 tiles at once take 8, with the partial sums in SP
([Appendix F](#appendix-f-next-partial-sums-in-sp)). (mcc's build of this shape also stops later: its SPSU
block grows to 390 instructions, over the 255-entry buffer.)

## Appendix B: other patterns

Each one: the kpl body, mcc's traced op, how its tiling maps to loops, and the fused loop IR of DNC `%d`. The
examples are written in the [canonical form](#canonical-form). Values carried across loops are register arrays,
as in the running example. What the conversion inserts is the prototype's output
([Appendix E](#appendix-e-prototype)).

### Fused elementwise

**kpl** ([`mcc/ew.py`](mlir-loop-ir/mcc/ew.py)), `x, r: [R = 2048, C = 64]`:

```python
return x.exp() * 0.5 + r
```

**mcc's traced op** ([`mcc/ew.out`](mlir-loop-ir/mcc/ew.out)):

```
Expr: x:in[R,C]  r:in[R,C]  exp1=exp(x)  mul2=mul(exp1,0.5)  add3=add(mul2,r)
tiled.trace  streamaddrs  C=64 R=2048        kind=streaming  units=NCLU,NCSU,VU
  roles     lane=C  shard=R
  spatial   dnc[16] = shard.R[16] × split.C[1]
  temporal  loop mtile.R[128]
              LEAF  R=1:line   reduce C.blk[1] × C.in[64]
Mdmap(levels=(Level(axis='M', count=16, kind='shard'),), m_split=Split(extent=2048, count=16))
StreamPlan: one compute pass [exp1, mul2, add3]
```

| mcc | Fused loop IR |
|---|---|
| `dnc[16] = shard.R[16]` | DNC `%d`'s rows `128·%d .. +127` |
| `loop mtile.R[128]`, `LEAF R=1:line` | 128 lines, one row each: `for c` (8 chunks of 16 lines, the NC transfer size) × `for l` (16) |
| `lane=C`, `C.in[64]` | a row's 64 values are one line |
| the pass's DAG | the VU ops on each line |

```mlir
primitive @ew attributes {spmd_dncs = 16} {
  %x    = alloc : memref<2048xvector<64xdlf16>, #shm>            // one line per row
  %r    = alloc : memref<2048xvector<64xdlf16>, #shm>
  %y    = alloc : memref<2048xvector<64xdlf16>, #shm>
  %sp_x = alloc : memref<128xvector<64xdlf16>, #sp>              // this DNC's 128 rows
  %sp_r = alloc : memref<128xvector<64xdlf16>, #sp>
  %sp_y = alloc : memref<128xvector<64xdlf16>, #sp>

  pipeline (%x, %r, %y, %sp_x, %sp_r, %sp_y) {
    for c = 0 .. 8 {                                             // 16-row chunk
      for l = 0 .. 16 {                                          // row 16c + l of this DNC
        nclu.load %sp_x[16*c + l], %x[128*%d + 16*c + l]      : vector<64xdlf16>
        nclu.load %sp_r[16*c + l], %r[128*%d + 16*c + l]      : vector<64xdlf16>
        %xl = splu.load %sp_x[16*c + l]                       : vector<64xdlf16>
        %rl = splu.load %sp_r[16*c + l]                       : vector<64xdlf16>
        %e  = vu.exp %xl                                      : vector<64xdlf16>     // exp1 (a VU sequence)
        %yl = vu.fma %e, 0.5, %rl                             : vector<64xdlf16>     // mul2, add3
        spsu.store %sp_y[16*c + l], %yl
        ncsu.store %y[128*%d + 16*c + l], %sp_y[16*c + l]     : vector<64xdlf16>
      }
    }
  }
}
```

Converted: FIFOs SPLU → VU (`%xl`, `%rl`) and VU → SPSU (`%yl`); `ready` channels for `%sp_x`, `%sp_r` (NCLU →
SPLU) and `%sp_y` (SPSU → NCSU); all once per `l`. With 16-line bands instead of whole tensors (`%sp_x[l]` in
every chunk, addresses without `c`), C7 adds `free` channels for `%sp_x` (SPLU → NCLU) and `%sp_y` (NCSU →
SPSU): the machine IR's sqrt example has these four channels, once per chunk after hoisting. Hoisting merges the
one-line transfers over `l` into one 16-line transfer per chunk, which moves the channels from `l` to `c`.

### Fused reduction: RMSNorm

**kpl** ([`mcc/rms2048.py`](mlir-loop-ir/mcc/rms2048.py), `tests/perf/rms_norm`'s kernel at `R = 2048`,
`K = 512`; input and output in rcl2's block layout `[K/64, R, 64]`):

```python
return x * ((x * x).reduce(axis="K", combine="add") * (1.0 / K) + EPS).rsqrt() * w
```

**mcc's traced op** ([`mcc/rms2048.out`](mlir-loop-ir/mcc/rms2048.out)):

```
Expr: input:in[R,K]  scale:in[K]  mul1=mul(input,input)  red2=reduce.add[K](mul1)  mul3=mul(red2,0.001953125)
      add4=add(mul3,1e-05)  rsqrt5=rsqrt(add4)  mul6=mul(input,rsqrt5)  mul7=mul(mul6,scale)
tiled.trace  streamaddrs  K=512 R=2048        kind=streaming  units=NCLU,NCSU,VU
  roles     lane=K  shard=R
  spatial   dnc[16] = shard.R[16] × split.K[1]
  temporal  loop mtile.R[128]
              LEAF  R=1:line   reduce K.blk[8] × K.in[64]   (leaf_K=512)
  accumulate acc_edge None  monoid=add  cadence={'accum': 1, 'npass': 2}
StreamPlan: chunks of 8 rows; pass 1 [mul1, red2, mul3, add4, rsqrt5], pass 2 [mul6, mul7]
```

| mcc | Fused loop IR |
|---|---|
| `dnc[16] = shard.R[16]` | DNC `%d`'s rows `128·%d .. +127` |
| `loop mtile.R[128]`, chunks of 8 rows | `for g = 0 .. 16` groups of 8 rows (`for r = 0 .. 8`) |
| `K.blk[8] × K.in[64]`, `lane=K` | a row's 512 values are 8 lines (`for kb = 0 .. 8`), 64 lanes each |
| `red2 = reduce.add[K]` over `K.blk` then `K.in` | across the 8 lines in VU registers, then across the 64 lanes (`vu.rsqrt_mean`) |
| `npass: 2`, pass 1 / pass 2 | two loops over `kb` in the group's body: statistics, then scaling; x read twice from SP |

The row statistics need all of a row before any output, so the pipeline reads each row twice from SP. Reading
SP twice is allowed (C6); the statistics stay in VU registers (C4). Groups of 8 rows keep them within the VU's
16 registers: the 8 sums, which the inverses then overwrite.

```mlir
primitive @rmsnorm attributes {spmd_dncs = 16} {
  %x     = alloc : memref<8x2048xvector<64xdlf16>, #shm>         // x[kb][r]: K values 64·kb .. +63 of row r
  %gamma = alloc : memref<8xvector<64xdlf16>, #shm>
  %y     = alloc : memref<8x2048xvector<64xdlf16>, #shm>
  %sp_x  = alloc : memref<8x128xvector<64xdlf16>, #sp>
  %sp_g  = alloc : memref<8xvector<64xdlf16>, #sp>
  %sp_y  = alloc : memref<8x128xvector<64xdlf16>, #sp>
  %ss    = vu.alloc_regs : !vu.regs<8 x vector<64xdlf16>>        // a group's 8 sums, then its 8 inverses

  pipeline (%x, %gamma, %y, %sp_x, %sp_g, %sp_y) {
    for g = 0 .. 16 {                                            // rows 8g .. 8g+7 of this DNC
      for r = 0 .. 8 {                                           // the sums start at 0
        vu.reg_write %ss[r], zero                                   : vector<64xdlf16>
      }
      for kb = 0 .. 8 {                                          // pass 1: sum of squares per row
        for r = 0 .. 8 {
          nclu.load %sp_x[kb, 8*g + r], %x[kb, 128*%d + 8*g + r]    : vector<64xdlf16>
          %xl = splu.load %sp_x[kb, 8*g + r]                        : vector<64xdlf16>
          %s  = vu.reg_read %ss[r]                                  : vector<64xdlf16>
          %s1 = vu.fma %xl, %xl, %s                                 : vector<64xdlf16>   // mul1, red2 over K blocks
          vu.reg_write %ss[r], %s1
        }
      }
      for r = 0 .. 8 {                                           // per row: lanes, mean, rsqrt
        %s   = vu.reg_read %ss[r]                                   : vector<64xdlf16>
        %inv = vu.rsqrt_mean %s {n = 512, eps = 1e-5}               : vector<64xdlf16>   // the same value in every lane
        vu.reg_write %ss[r], %inv
      }
      for kb = 0 .. 8 {                                          // pass 2: scale
        for r = 0 .. 8 {
          nclu.load %sp_g[kb], %gamma[kb]                           : vector<64xdlf16>
          %gl = splu.load %sp_g[kb]                                 : vector<64xdlf16>
          %xl = splu.load %sp_x[kb, 8*g + r]                        : vector<64xdlf16>   // the line pass 1 loaded
          %iv = vu.reg_read %ss[r]                                  : vector<64xdlf16>
          %t  = vu.fma %xl, %iv, 0.0                                : vector<64xdlf16>   // mul6
          %yl = vu.fma %t, %gl, 0.0                                 : vector<64xdlf16>   // mul7
          spsu.store %sp_y[kb, 8*g + r], %yl
          ncsu.store %y[kb, 128*%d + 8*g + r], %sp_y[kb, 8*g + r]   : vector<64xdlf16>
        }
      }
    }
  }
}
```

Converted: FIFOs SPLU → VU (`%xl` per row in both passes, `%gl` per row of pass 2) and VU → SPSU (`%yl`).
`%sp_x` gets two `ready` channels: per row of pass 1 for its own read, and per group (`put` after pass 1, `get`
before pass 2) for pass 2's. `%sp_g[kb]` is rewritten for every group and row, so it gets `ready` and `free` per
row; `%sp_y` gets `ready` per row. Hoisting gamma out of the nest leaves it resident, and its `free` channel
disappears.

**Softmax** has the same shape with three passes. mcc's traced op for
`tests/perf/softmax_last_axis_lanes/1x1x1024x512` ([`mcc/softmax.out`](mlir-loop-ir/mcc/softmax.out)):

```
Expr: red1=reduce.max[K](input)  sub2=sub(input,red1)  exp3=exp(sub2)  red4=reduce.add[K](exp3)
      recip5=recip(red4)  mul6=mul(exp3,recip5)
axes      lane=('K','k')  shard=('R','r')  reduce=(('K','k','lane'),)     ← the K reductions cross the lanes
spatial   dnc[16] = shard.R[16] × split.K[1], ncore[2]
temporal  loop mtile.R[8]
            LEAF  R=4:line   reduce K.blk[8] × K.in[64]
StreamPlan: chunks of 8; passes [red1] → [sub2, exp3, red4, recip5] → [mul6]
```

Each row's 512 values are 8 lines of 64 lanes; an NCore's 32 rows go 4 at a time (`R=4:line`). A group of 4
rows reads its lines three times: the maximum (across the 8 lines in VU registers, then across the lanes), the
sum of `exp(x − max)`, and the scaled output. The 4 maxima and 4 sums are the same in every lane and fit the
VU's registers.

## Appendix C: hoisting (later)

Hoisting turns the canonical form into the form that runs well: it moves a transfer or a load to an outer loop,
so that it runs once and its lines or its value are reused. It is a later step, outlined here.

**Hoisting** moves an NC transfer out of a loop:

| Kind | When | Effect |
|---|---|---|
| invariant | neither address uses the loop's index | the transfer runs once before the loop |
| coalescing | both addresses step by the transfer's own length with the loop's index | the loop's transfers merge into one burst before the loop (a store: after it) |
| out of a nest | for each value of some loops' indices, the lines all iterations of the other loops move are consecutive (and the same, where an index is unused) | one transfer per value of the kept indices, in a loop of its own before the nest |

The transfer still writes SP in the iteration of the loop that now holds it, before the reads, so C6 holds
before and after: hoisting never makes a pipeline unconvertible. It decides where the `ready` channel goes, and
it removes the `free` channel a repeated transfer would need. How far to hoist is the SP budget's decision.

| Example | Transfer | Hoisted to |
|---|---|---|
| elementwise | x, r loads; y store | coalesced over `l`: 16 lines per chunk |
| matmul | x tile (`kb, nc, g, i`) | out of the nest, keeping `kb`: per K block, `nc, g, i` cover 128 consecutive lines and `nb` repeats them: a loop of 8 128-line loads before the nest; all of x resident |
| | weight tile (`nc, kb, nb`) | invariant out of `g` and `i`; coalescing over `kb` fails (the lines step by 256, not 64), so it stays in `kb`'s body, or all of w goes resident out of the whole nest |
| | bias (`nc, nb`) | invariant out of `g` and `o`; coalesced over `nb`: 4 lines, resident |
| | y store (`nb, nc, g, o`) | coalesced over `o`: 16 lines after `for o` |
| RMSNorm | x (`g, kb, r`) | coalesced over `r`: 8 lines per `(g, kb)`; or out of the nest, keeping `kb`: all of x resident |

Hoisting a `splu.load` out of a loop makes its value a broadcast ([routing](#2-routing)):

| Example | Load | Hoisted to |
|---|---|---|
| matmul | `%wt` (`nc, kb, nb`) | out of `i`: the MXU latches it once per K block for the group's 4 tiles, `mxu.matmul {tiles = 4, m_rows = 4}` |
| | `%bl` (`nc, nb`) | out of `o` would make it a VU latch, but `%acc` holds all 16 VU registers: it stays per tile |
| RMSNorm | `%gl` (`kb`) | out of `r`: the VU latches it per K block of pass 2 |

Hoisting out of the spatial loop `nc` would let the NCores share one copy of w and the bias in SP, read by both
NCores' SPLUs. That needs C5 to allow one reader unit per NCore.

**Prefetch** issues a hoisted transfer one iteration early into a second SP band: double buffering, a `free`
channel with two credits instead of one.

**SP tiles.** The SP footprint is explicit: each `alloc … #sp` is a tile's size, and a band reused across
iterations is a transfer whose SP address omits that loop's index (C7). mcc's traced op names its SP buffers
without sizes; it keeps a matmul's weights resident for the whole build and refuses a shape whose weights
outgrow SP, and its `StreamPlan` chunks set the sync granularity. Choosing the tile sizes
(`Mt · Kt + Kt · Nt + Mt · Nt` lines within SP, twice the first two for double buffering) is the tiling pass's
job.

## Appendix D: where a pipeline must be cut

The conversion rejects a pipeline that breaks a constraint and names it. The compiler then cuts it into
pipelines whose boundary is an SP or SHM buffer, written by one and read by the next.

| Case | Constraint broken | Cut |
|---|---|---|
| Partial sums in SP: each K block reads what the previous one wrote | C6 | keep them in registers (the running example); or a sequence of pipelines; or the `accumulate` loop of [Appendix F](#appendix-f-next-partial-sums-in-sp) |
| RMSNorm feeding a matmul in one pipeline: the VU writes the normalized x to SP, the SPLU reads it for the MXU | C8: VU → SPSU → SPLU → XVU → MXU → VU | pipeline 1: RMSNorm into `%sp_xn`; pipeline 2: matmul reading `%sp_xn`. Or scale in the prologue when the scale reaches the XVU without the VU (gamma does; the per-row inverse does not) |
| Transpose through SP: rows written, then read back as columns | C8: SPLU → XVU → SPSU → SPLU | pipeline 1 writes the rows; pipeline 2 reads the columns |
| Data-dependent control (top-k, routing) | C2 | its own kernel |

A cut costs the pipeline's fill and drain at the boundary; the buffer between the two stays in SP.

**Example: RMSNorm feeding a matmul.** kpl ([`mcc/normmm.py`](mlir-loop-ir/mcc/normmm.py)):

```python
return (x * ((x * x).reduce(axis="K", combine="add") * (1.0 / 512) + 1e-5).rsqrt()) @ w
```

mcc refuses it before tiling ([`mcc/normmm.out`](mlir-loop-ir/mcc/normmm.out)): "`w` carries ['K', 'N'], none
of which is `M`, the level's streaming lane axis". The traced ops of the two halves are the RMSNorm and the
matmul above. After the cut:

```mlir
  %sp_xn = alloc : memref<8x128xvector<64xdlf16>, #sp>            // lives across both pipelines

  pipeline @norm (%x, %gamma, %sp_x, %sp_g, %sp_xn) {              // RMSNorm, its output kept in SP
    …
    spsu.store %sp_xn[kb, 8*g + r], %yl                              //   spsu.store into %sp_xn, no ncsu.store
  }
  pipeline @mm (%w, %y, %sp_xn, %sp_w, %sp_y) {                    // the matmul on %sp_xn: only read here
    …
    %xt = splu.load %sp_xn[kb, %m] : vector<4x64xdlf16>
    …
  }
```

In `@norm`, `%sp_xn` is only written; in `@mm`, only read. Each pipeline converts on its own.

## Appendix E: prototype

[`mlir-loop-ir/lower.py`](mlir-loop-ir/lower.py) converts the canonical form of the running example and of the examples of Appendix B and D.
It models a pipeline as loops (trip counts), ops (SSA values defined and used, carried values) and buffer
accesses (each with the loops its address uses). It checks C3–C6 and C8 (as its rules F1–F5), assigns units,
routes values, latches broadcasts, and inserts `ready` and `free` channels; its output is
[`mlir-loop-ir/lower.out`](mlir-loop-ir/lower.out).

| Example | Result | What it inserted, or why it refused |
|---|---|---|
| Elementwise, whole tensors in SP | convertible | 3 FIFOs; 3 `ready` channels per `l` |
| Elementwise, one SP band per tensor | convertible | 2 FIFOs; `ready` and `free` per `l` for both bands |
| Matmul + epilogue (the running example) | convertible | 5 FIFOs, no latch; `ready` and `free` per `i` for `%sp_w` and `%sp_x` (`%in_ready`, `%in_free` in the text), per `o` for `%sp_b`; `ready` per `o` for `%sp_y`; the VU carries `%acc` |
| RMSNorm, two passes | convertible | 4 FIFOs; `ready` for `%sp_x` per row and per group, `ready` and `free` for `%sp_g` per row, `ready` for `%sp_y` per row |
| Matmul with SP partial sums | refused | `sp_p` read before the write of the same iteration |
| RMSNorm → matmul in one pipeline | refused | VU → SPSU → SPLU → VU |
| Transpose through SP | refused | SPLU → XVU → SPSU → SPLU |

Not modeled: the `accumulate` loop of Appendix F; addresses (the
model takes the loops an address uses, not the expression); FIFO depths and SP capacity (P6, P7); register
counts beyond listing the carried values; merging channels.

## Appendix F: next, partial sums in SP

The running example latches each weight tile for a group of 4 tiles, because the VU holds only 4 tiles of
partial sums: 32 latches per N block. rcl2's dense matmul ("variant A" of
[`matmul-kouter-vp.md`](matmul-kouter-vp.md)) streams all 16 tiles of an NCore through each latch, 8 per N block,
and keeps their 64 lines of partial sums in SP. That breaks C6: each K block reads what the previous one wrote.
This appendix sketches how the fused loop IR could allow it; it is the next topic, not part of the design above.

The loop order becomes `nb`, `kb`, `t` (16 tiles), with an SP buffer `%sp_psum[nc][row]` for the sums:

```mlir
      for nb = 0 .. 4 {
        for t = 0 .. 16 {                                        // phase W: the sums start at 0
          spsu.store %sp_psum[nc, 4*t], zero                          : vector<4x64xdlf16>
        }
        for kb = 0 .. 8 accumulate(%sp_psum) {                      // phases RW: one per K block
          for t = 0 .. 16 {
            %m  = affine.apply 64*nc + 4*t
            nclu.load %sp_w[nc, kb, nb, 0], %w[kb, nb, 0]          : vector<64x64xdlf16>
            nclu.load %sp_x[kb, %m], %x[kb, 128*%d + %m]           : vector<4x64xdlf16>
            %wt = splu.load %sp_w[nc, kb, nb, 0]                   : vector<64x64xdlf16>
            %xt = splu.load %sp_x[kb, %m]                          : vector<4x64xdlf16>
            %p  = mxu.matmul %wt, %xt                              : vector<4x64xdlf16>
            %pp = splu.load %sp_psum[nc, 4*t]                         : vector<4x64xdlf16>   // the sum over 0 .. kb-1
            %s  = vu.fma %p, 1.0, %pp                              : vector<4x64xdlf16>
            spsu.store %sp_psum[nc, 4*t], %s                                                 // the sum over 0 .. kb
          }
        }
        for o = 0 .. 16 {                                        // phase R: the whole sums
          %a  = splu.load %sp_psum[nc, 4*o]                         : vector<4x64xdlf16>
          …                                                      // bias, relu, store to %sp_y and SHM
        }
      }
```

**`accumulate(%b)`** on a loop says: its iterations read `%b` and write it back. Inside one iteration of the loop
around it (`nb`), the nests that touch `%b` form **phases** in program order: W (the zero fill), RW once per K
block, R (the epilogue). The verifier would check:

| # | Rule | Here |
|---|---|---|
| A1 | Only the SPLU reads `%b` and only the SPSU writes it | yes |
| A2 | The phases are W, then RW any number of times, then R | W, RW × 8, R |
| A3 | Every phase covers the same lines: the same index over the same loop domain, without the `accumulate` loop's index | `[nc, 4*t]` over 16 tiles |
| A4 | Within a phase the index is injective | one tile per `t` |
| A5 | In an RW phase each stored value is computed from the value loaded at the same index | `%pp → %s` |

**Syncs**, one per phase rather than per tile, as rcl2 does (the SPSU signals the SPLU once per K block):

| Channel | `put` | `get` |
|---|---|---|
| `%psum_ready` (SPSU → SPLU) | after each W and RW phase | before each RW and R phase |
| `%psum_free` (SPLU → SPSU) | after each R phase | at the end of the same `nb`, before the next W |

Per NCore, `%psum_ready` has (1 + 8) · 4 = 36 `put`s and 36 `get`s, with at most 2 tokens waiting. Its `get` precedes its
`put` inside one iteration of `kb`, so P3 is walked over `nb`'s body, where the W phase's `put` comes first. The
cycle SPLU → VU → SPSU → SPLU through `%sp_psum` is allowed because `%psum_ready` orders whole phases. The cost: the first
read of a K block waits for the last store of the previous one. Once the weight load is hoisted out of `t` (one
latch for 16 tiles), moving it above `get %psum_ready` (it touches no partial sum) lets the MXU latch during that wait,
as rcl2 does.

Earlier write-ups of this topic:

- [`sp-psum-kblock.md`](mlir-loop-ir/sp-psum-kblock.md): the current design in full: the zero fill as one op,
  `psum.accumulate`, `psum.block` footprints that set the sync granularity (one token per G tiles), the unit blocks,
  counts and FIFO depths. It supersedes the `accumulate` loop sketched above.
- [`sp-psum.md`](mlir-loop-ir/sp-psum.md): one sync per tile, a channel with distance 1 on `kb`, guards or
  peeling at the first and last K block. Overlaps more, but is hard to generate and to check.
- [`sp-psum-queue.md`](mlir-loop-ir/sp-psum-queue.md): the partial sums as a queue in SP, with data and space
  semaphores. Still hard to check.

## Appendix G: resources and performance

**Resources.** Instruction buffer entries (255 per unit), address registers (NC descriptors, SP unit LRFs), VU
registers (16), sync FIFO depths (16 on one core, 4 + 2 across cores) and SP lines are known only after
projection and the unit-local passes. They can be counted at the dataflow loop IR, before emission, if no pass
expands code unseen:

- each op has a fixed cost per unit (instructions, temporary registers);
- the conversion adds only fixed things: per loop a counter and one address update per stream, the syncs, the
  setup;
- no implicit unrolling or peeling: a loop the hardware cannot run as a loop is refused, and unrolling is written
  in the IR by the user or an earlier pass.

Then each block's resources are sums: instructions = op costs plus loop overhead; address registers = access
streams; VU registers = register arrays plus latched values plus temporaries; channel depth = the tokens P6 counts.
mcc's SPSU block of 390 instructions is the case this excludes: an emitter's unrolling made it.

**Performance** depends on stalls (sync waits, full FIFOs, NC bandwidth) that are hard to predict statically. The
realistic route is fast feedback: a per-unit activity trace from the VP, with each interval mapped back to the
block and statement of the dataflow loop IR ("the SPLU waits 120 cycles at `get %acc` in `kb`'s body"). Since
projection is one-to-one, a wait in the trace points at a statement to move or a sync to coarsen.

## Appendix H: open points

- **VU register pressure.** Partial sums of 4 tiles fill the VU, so the example loads the bias line once per
  tile instead of latching it. An epilogue with more operands, or a temporary the epilogue cannot place in a
  finished accumulator, needs smaller groups (fewer tiles per weight latch) or SP partial sums.
- **Reduction across DNCs.** K is not split across DNCs here. Splitting it needs a cross-DNC reduction of the
  partial sums (rcl2's split-K), which the IR does not express yet.
- **Lane reductions.** RMSNorm and softmax need a sum or max across the 64 lanes of a line (`vu.rsqrt_mean`
  above). Which VU sequence does it, and at what cost, is not settled.
- **Prologues.** A per-K scale on the acts (`(x * gamma) @ w`) belongs on the XVU, before the MXU. It assumes
  the XVU can hold a gamma line in a register and use it as an `fma` operand.
- **Double buffering.** `free` channels serialize a reused band. Two bands with two credits are an optimization
  the conversion can apply when SP has room.
- **SP allocation.** The examples keep whole tensors in SP. The allocator can shrink a buffer to the lines one
  iteration uses when C7 adds `free` channels; the "Low-level dialects" document starts from full-size buffers.
- **Choosing cuts.** The conversion only reports a broken constraint; deciding where to cut, or changing the
  schedule instead, belongs to the tiling pass.
- **Hardware loops.** The nesting limit of hardware loops and `MVLOOPCNT`'s trip semantics are not checked.
