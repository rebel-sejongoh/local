# MLIR machine IR for REBEL pipelines

A machine IR in which every unit's program is SSA: its notation, the rules a pipeline must meet and how they are
checked, and examples (sqrt, a matmul with macro ops, `down_proj` on 16 DNCs). It is a design sketch; none of the
code has been run.

Decisions applied
- Every unit is SSA. A value carried across a loop is a loop `iter` / `yield`; a value merged after a branch is a block argument.
- An op that updates a register in place returns the new value: `%sn, %cn = nclu.ldmu …`. Register allocation ties the result to the operand.
- Op syntax: `%results = <unit>.<opcode> sinks, src0, src1, … {attrs} : result types`, with sources in ISA field order.
  The left-hand side holds only registers, or nothing: a FIFO is never a result, and the FIFO an op pushes to is an
  operand on the right.
  A register result is a `%result`, and every op with results shows their types after `:`. A FIFO sink is written
  first, as `field = selected value -> %fifo` (`sp_tgt = result -> %f_vs`; `consumer -> %f_ld` when the field has one
  value). A target on a fixed link (TU `south_tgt`, `east_tgt`) is an attribute. A memory destination (`SP[…]`,
  `AB[…]`, `SHM[…]`) is the first operand.
- Memory operands print as `SPACE[base + offset : length]`. NC: `SP[%sbr + %sar : N]`, `SHM[%cbr + %car : N]`, in lines, `N` = burst. SP units: `SP[%ptr + %stride]`, in bytes, the address the access actually uses. A strided NC transfer (`LDSU`/`STSU`) prints `SP[%sar, stride %sbr : N]`. The `+` is fixed syntax for the hardware's own addition, not a general expression.
- `alloc` returns the buffer's start address. SHM elements are `i1024` (line); SP elements are `i8` (byte). NC addresses SP in lines, so it uses `%bi / 128`.
- Register initial values (the block's `.lrf` preload): `addr_init` for the NC descriptor fields (SAR, SBR, CAR, CBR),
  `reg_init` for an ordinary LRF.
- Types name the hardware storage: `!sar<i15>`, `!sbr<i16>`, `!car<i20>`, `!cbr<i20>` (NC descriptor fields), `!lrf<i32>` (SP unit LRF), `!jcr`. After allocation they carry the index: `!sar<i15, 0>`.
- Channels: the NC side lists SP units explicitly (`{splu0}`); NCore count is `ncores` on `pipeline`.
- Branches use our own terminators (`splu.jcmp`, `fallthrough`) with block arguments; hardware loops stay `loop` regions.

## Pipelines

A `pipeline` is one region of a kernel that the units run concurrently, passing data through FIFOs and SP or AB
buffers and ordering themselves with sync channels. It has two forms:

- **Sequential form.** One body with the ops of every unit, in one program order, under shared loops. The ops'
  unit prefixes (`nclu.`, `splu.`, `vu.`, …) say who runs them. This is the form a compiler writes and checks.
- **Distributed form.** One `unit` block per unit, each the sequential body restricted to that unit's ops. This is
  what the units execute, and the form of the [sqrt](#before-register-allocation) and
  [`down_proj`](#region-r1-every-dnc) code below.

Loop distribution derives the second from the first (see [Algorithms](#algorithms)). Writing the sequential form
gives every FIFO and channel one order that both of its ends follow, which is what makes the checks below local.

### Notation for TU rows and grouped registers

| Form | Meaning | Resolved at emit |
|---|---|---|
| `unit @tu attributes {rows = 8, cols = 8}`, `%r = tu.row_id` | one program for every TU row (8 slices each) | 8 row blocks, `.place col = r` |
| `loop (56 - 8 * %r)` | a trip count affine in the row index (or grid indices, Appendix A) | an immediate per copy; a trip of 0 drops the loop |
| `select(%r == 0, #0, %north)` | an operand chosen by a static predicate | the operand field per copy |
| `tu.north_link`, `tu.west_link` | the row's fixed input links; each use pops one entry | `FIFO_NORTH`, `FIFO_WEST` |
| `tu.fma_r` / `tu.fma` | TU `FMA` with register results / with link outputs only (`south_tgt`, `east_tgt`) | one `FMA` |
| `N x T` after `:` | N results of type T | |
| `(%w0, %w1, %w2, %w3)` as a `dot_len = 4` operand | the 4 registers of one dot product | consecutive LRFs, `src0=LRF[0:3]` |
| `(%p0, %p1, %p2, %p3)` under `unroll = 4` | the operand of unroll step `t` is `%p<t>` | consecutive LRFs, `unroll_control.src1=1` |
| `%r0, …, %rN = op … {unroll = N}` | one result register per unroll step | consecutive LRFs, `unroll_control.lrf_tgt=1` |

`CONST0` and `CONST4` are the VU/XVU constant registers (`.lccr`): 0 and 1.0.

### Constraints

A pipeline in sequential form must satisfy the rules below. They exclude some schedules on purpose (an SP
accumulator, a value passed between units across loop iterations), so that every rule is checked inside one loop
body; [Algorithms](#algorithms) gives the checks.

| # | Rule | What it prevents |
|---|---|---|
| P1 | **Units.** Every op belongs to one unit. A register is used only by ops of the unit that defines it, `iter` / `yield` included. A FIFO has one pushing unit and one popping unit, a channel one `put` unit and one `get` unit, as declared | a value no unit can reach |
| P2 | **Same iteration.** For every FIFO and channel, each loop that contains both a push and a pop of it pushes and pops the same number of tokens per iteration. A loop that contains only one side is local repetition (a burst written as a loop) | tokens matched across iterations: counters that grow with a trip count |
| P3 | **Order.** Within one iteration of such a loop, in program order, the pops so far never outnumber the pushes; a `get` never precedes its `put` | waits that no schedule can satisfy |
| P4 | **Buffers.** An SHM buffer of the pipeline is read only or written only. An SP or AB buffer has one writer unit and one reader unit; every read after a write is covered by a channel (`put` after the write, `get` before the read), and every rewrite after a read by a channel back (`put` after the read, `get` before the rewrite), both under P2–P3 | races; read-modify-write through memory |
| P5 | **No cycles.** The graph with units as nodes and FIFOs and read-after-write channels as edges is acyclic. Rewrite channels (P4's channel back) are not edges | a unit waiting on its own output; the pipeline drains once per iteration |
| P6 | **Capacity.** Along the program order, no FIFO holds more tokens than its depth and no channel more `put`s than its counter, counting as in [Capacity](#capacity) | stalls that become deadlocks with real FIFO depths |
| P7 | **Resources.** Registers per unit (TU 12 LRFs per row, VU 16), the AB ring (1 KB per row), SP lines | allocation failure |

A value that must cross loop levels or iterations (weights latched once and used by every tile, an accumulator over
K) is a register of one unit: P1 allows it, and P2 does not see it. A macro op (below) is such a case: its weights
are TU registers.

### Example: sqrt in sequential form

The input side of the sqrt kernel (NCLU loads 8-line chunks into an SP band, SPLU streams the lines to the VU).
The band is rewritten in each of the 2 passes. The distributed form is the code in
[Before register allocation](#before-register-allocation).

```mlir
kernel @sqrt attributes {spmd_dncs = 16} {
  %inp = alloc : !ptr<buffer<2048 x i1024>, #shm>
  %bi  = alloc {align = 128} : !ptr<buffer<8320 x i8>, #sp>      // 65 lines (64 + 1 guard)

  pipeline (%inp, %bi, …) attributes {ncores = 1} {
    %f_ld   = fifo splu -> vu : !fifo<splu -> vu, vector<64xdlf16>>
    %stage  = channel nclu -> {splu0}      // an input chunk is in SP
    %infree = channel {splu0} -> nclu      // the input band may be overwritten

    %sar0, %sbr, %car0, %cbr = nclu.addr_init sar = 0, sbr = %bi / 128,
                                              car = 0, cbr = %inp + 128 * %dnc_id
        : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
    %p0, %st = splu.reg_init %bi - 128, 128 : !lrf<i32>, !lrf<i32>
    %sar3, %car3, %p3 = loop 2 iter(%sar1 = %sar0, %car1 = %car0, %p1 = %p0) {             // pass
      %sar2, %car2, %p2 = loop 8 iter(%s = %sar1, %c = %car1, %pc = %p1) {                   // chunk
        %sn, %cn = nclu.ldmu SP[%sbr + %s : 8], SHM[%cbr + %c : 8] : !sar<i15>, !car<i20>
        nclu.sync put %stage
        splu.sync get %stage
        %pl = loop 8 iter(%p = %pc) {                                                          // line
          %pn = splu.ldu consumer -> %f_ld, SP[%p + %st] : !lrf<i32>
          %v  = vu.fma %f_ld, CONST4, CONST0 : vector<64xdlf16>       // pops the line
          …                                         // rest of the sqrt sequence and the output side
          yield %pn
        }
        yield %sn, %cn, %pl
      }
      %sr = nclu.sxrimm 0 : !sar<i15>
      %pr = splu.immcopy %bi - 128 : !lrf<i32>
      splu.sync put %infree
      nclu.sync get %infree
      yield %sr, %car2, %pr
    }
  }
}
```

| Rule | Check |
|---|---|
| P2 | `%stage`: the chunk loop has 1 `put` and 1 `get` per iteration. `%infree`: the pass loop has 1 and 1. `%f_ld`: the line loop pushes 1 and pops 1 |
| P3 | `put %stage` precedes `get %stage`; `put %infree` precedes `get %infree`; `ldu` precedes `fma` |
| P4 | `%bi`: written by NCLU, read by SPLU; read after write covered by `%stage`, the rewrite in the next pass by `%infree` |
| P5 | edges NCLU → SPLU (`%stage`), SPLU → VU (`%f_ld`); `%infree` is a rewrite channel. Acyclic |
| P6 | `%stage` and `%infree` hold at most 1 `put`; `%f_ld` at most 1 line |

### Macro ops

In a weight-stationary matmul the TU, ABSU and ABLU programs barely change with the shape
([Appendix B](#appendix-b-macro-op-background-and-plan)), so they are two macro ops in the push/pop style of TPU's MXU
(`vmatpush` loads weights, `vmatmul` pushes LHS rows, `vpop` pops results). A macro op is written in the
sequential form like any op and replaced by its template before the checks and loop distribution.

| Macro op | Role | TPU MXU counterpart |
|---|---|---|
| `tu.load_weights` | latch a 64×64 weight tile into TU LRF0..7 of every row | `vmatpush` |
| `tu.matmul` | stream `m_rows` activation lines through ABSU → AB → ABLU → TU; push `m_rows` result lines south | `vmatmul` |
| the VU's `%f_tv` operand | pop result lines out of row 7 | `vpop` |

| Type | Meaning |
|---|---|
| `!fifo<src -> dst, vector<64xdlf16>>` | a hardware FIFO of 128 B lines, as above |
| `!tu.wtile<64x64xdlf16>` | the weight tile held in TU LRF0..7 of all 8 rows (row r holds K rows `8r .. 8r+7`, slice c holds N columns `8c .. 8c+7`). It names the registers `%w0 .. %w7` of the expansion |
| `!tu.mrows<N>` | `N ∈ {1, 2, 4}`: rows per `tu.matmul`. Bounded by the TU's 4 partial-sum registers LRF8..11 and the unroll degrees 0..2 |

```mlir
// Latch one weight tile. Pops 64 lines from %f_n0; the tile is ready when all 64 have been taken.
%wt = tu.load_weights weights = %f_n0 {dtype = dlf16}
    : (!fifo<xvu -> tu, vector<64xdlf16>>) -> !tu.wtile<64x64xdlf16>

// One activation tile through the latched weights. Pops m_rows lines from %f_ab, pushes m_rows lines to %f_tv.
tu.matmul out = %f_tv, %wt, acts = %f_ab {m_rows = 4, dtype = dlf16}
    : (!fifo<tu -> vu, vector<64xdlf16>>, !tu.wtile<64x64xdlf16>, !fifo<xvu -> absu, vector<64xdlf16>>) -> ()
```

`%f_ab` line `t` holds activation row `t` over the tile's 64 K values; `%f_tv` line `t` is `Σ_k x[t][k] · w[k][:]`
over the 64 N columns, in DLFloat16 (DLFloat18 inside the array). The result is a FIFO operand on the right
(`out = %f_tv`); the left-hand side holds only the register tile `%wt`.

Port contracts, used by the capacity check:

| Op, port | Count per op | Block before progress |
|---|---|---|
| `load_weights`, `weights` | pops 64 | 1: each line is latched or passed as it arrives. The tile is ready after all 64; no `matmul` result leaves before that |
| `matmul`, `acts` | pops `m_rows` | `m_rows`: the ABSU stores the whole block, then signals the ABLUs |
| `matmul`, `out` | pushes `m_rows` | after row 7 drains: once all `m_rows` activation lines and the weight tile are in |

**Expansion.** Each macro becomes the ops below at its place in the sequential body, with registers fixed. The
template's register preload and its link and channel declarations move to the pipeline entry; its pointer
registers become loop-carried (`iter` / `yield`) through every loop around the site. Parameters: `M = m_rows`, the
AB base `A` (0 in the example below), the row index `%r`.

```mlir
// pipeline entry, once per pipeline
%f_w   = fifo ablu -> tu.west : !fifo<ablu -> tu, vector<8xdlf16>>     // per row
%abw   = channel absu -> ablu : !chan<absu -> ablu>                      // the block is in the AB
%abf   = channel ablu -> absu : !chan<ablu -> absu>                      // the ABLUs are ready for the block
%r     = tu.row_id : index
%north = tu.north_link : !tu.link<vector<8xdlf16>>
%west  = tu.west_link  : !tu.link<vector<8xdlf16>>
%a0, %ast       = absu.reg_init A - 16, 16 : !lrf<i10>, !lrf<i10>                  // 10-bit ring
%h0, %h1, %hst  = ablu.reg_init A - 16, A - 8, 16 : !lrf<i10>, !lrf<i10>, !lrf<i10>

// %wt = tu.load_weights weights = %f_n0: every TU row (row 0's north is %f_n0)
%w0, %w1, %w2, %w3, %w4, %w5, %w6, %w7 = tu.fma_r #0, %north, #1.0 {unroll = 8}
    : 8 x !tu.lrf<vector<8xdlf16>>                                     // LRF0..7: w[8r + i, :]
loop (56 - 8 * %r) {
  tu.fma %north, #0, #1.0 {south_tgt = src0}                           // pass a w line to the rows below
}

// tu.matmul out = %f_tv, %wt, acts = %f_ab {m_rows = M}; %a, %g0, %g1 are the carried AB pointers
ablu.sync put %abf
%an  = absu.stu AB[%a + %ast : M], %f_ab {burst_en = 1} : !lrf<i10>      // line t -> AB_r[16t + 2i] := line_t[8r + i]
absu.sync put %abw
absu.sync get %abf
ablu.sync get %abw
%g0n = ablu.ldu consumer -> %f_w, AB[%g0 + %hst : M] {load_type = 1, replicate = 1, burst_en = 1} : !lrf<i10>
%g1n = ablu.ldu consumer -> %f_w, AB[%g1 + %hst : M] {load_type = 1, replicate = 1, burst_en = 1} : !lrf<i10>
%p0, …, %p<M-1> = tu.fma_r (%w0, %w1, %w2, %w3), select(%r == 0, #0, %north), %west
                            {east_tgt = src2, dot_len = 4, unroll = M}
    : M x !tu.lrf<vector<8xdlf18>>                                     // LRF8 .. LRF8+M-1
tu.fma (%w4, %w5, %w6, %w7), (%p0, …, %p<M-1>), %west
       {east_tgt = src2, south_tgt = result, dot_len = 4, unroll = M}   // row 7's south is %f_tv
```

The `stu` and `ldu` return their pointers advanced by `M · 16` bytes, so consecutive `matmul`s use consecutive
blocks of the 1 KB ring. The `%abf` `put` comes first in each `matmul`, so the handshake meets P2 and P3 inside one
iteration and needs no exception. The TU's row-to-row links are internal to the TU program; their counts are
checked per row as in [Appendix A](#what-the-single-tu-program-lets-a-checker-prove).

### Example: matmul with macro ops

`y[32, 64] = x[32, 64] @ w[64, 64]` on one DNC and one NCore: the weights are latched once and 8 tiles of 4 rows
stream through them. The VU `fma` is where an epilogue (bias, activation, quantization) goes; replacing the XVU
`logical` on the activation path by an `fma` gives a prologue (a per-row scale).

```mlir
kernel @mm {
  %x  = alloc : !ptr<buffer<32 x i1024>, #shm>                 // x[t, :] at line t
  %w  = alloc : !ptr<buffer<64 x i1024>, #shm>                 // w[q, :] at line q
  %y  = alloc : !ptr<buffer<32 x i1024>, #shm>                 // y[t, :] at line t
  %ws = alloc {align = 128} : !ptr<buffer<8192 x i8>, #sp>    // 64 w lines
  %xs = alloc {align = 128} : !ptr<buffer<4096 x i8>, #sp>    // 32 x lines
  %ys = alloc {align = 128} : !ptr<buffer<4096 x i8>, #sp>    // 32 y lines

  pipeline @mm (%x, %w, %y) attributes {ncores = 1} {          // %x, %w read only; %y written only
    %f_sx  = fifo splu -> xvu      : !fifo<splu -> xvu, vector<64xdlf16>>
    %f_n0  = fifo xvu -> tu.north  : !fifo<xvu -> tu, vector<64xdlf16>>    // row 0's north
    %f_ab  = fifo xvu -> absu      : !fifo<xvu -> absu, vector<64xdlf16>>
    %f_tv  = fifo tu.south -> vu   : !fifo<tu -> vu, vector<64xdlf16>>     // row 7's south
    %f_vs  = fifo vu -> spsu       : !fifo<vu -> spsu, vector<64xdlf16>>
    %stage = channel nclu -> {splu0} : !chan<nclu -> splu0>
    %done  = channel spsu -> ncsu    : !chan<spsu -> ncsu>

    %s0, %sb, %c0, %cb = nclu.addr_init sar = 0, sbr = %ws / 128, car = 0, cbr = %w
        : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
    %t0, %tb, %u0, %ub = nclu.addr_init sar = 0, sbr = %xs / 128, car = 0, cbr = %x
        : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
    %wp0, %lst = splu.reg_init %ws - 128, 128 : !lrf<i32>, !lrf<i32>
    %xp0       = splu.reg_init %xs - 128 : !lrf<i32>
    %o0, %ost  = spsu.reg_init %ys - 128, 128 : !lrf<i32>, !lrf<i32>
    %d0, %db, %e0, %eb = ncsu.addr_init sar = 0, sbr = %ys / 128, car = 0, cbr = %y
        : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>

    // w: SHM -> SP -> XVU -> TU
    %s2, %c2 = loop 2 iter(%s = %s0, %c = %c0) {
      %sn, %cn = nclu.ldmu SP[%sb + %s : 32], SHM[%cb + %c : 32] : !sar<i15>, !car<i20>
      yield %sn, %cn
    }
    nclu.sync put %stage
    splu.sync get %stage
    %wp2 = loop 64 iter(%wp = %wp0) {
      %wpn = splu.ldu consumer -> %f_sx, SP[%wp + %lst] : !lrf<i32>             // w line q
      xvu.logical tu_tgt = src0 -> %f_n0, %f_sx, CONST0 {immediate = 1}         // OR 0: pass it to the TU
      yield %wpn
    }
    %wt = tu.load_weights weights = %f_n0 {dtype = dlf16}
        : (!fifo<xvu -> tu, vector<64xdlf16>>) -> !tu.wtile<64x64xdlf16>

    // x: SHM -> SP, then 8 tiles through the latched weights
    %t1, %u1 = nclu.ldmu SP[%tb + %t0 : 32], SHM[%ub + %u0 : 32] : !sar<i15>, !car<i20>
    nclu.sync put %stage
    splu.sync get %stage
    %xp2, %o2 = loop 8 iter(%xp = %xp0, %o = %o0) {                            // tile
      %xpn = splu.ldu consumer -> %f_sx, SP[%xp + %lst] {burst_size = 4} : !lrf<i32>
      loop 4 {
        xvu.logical ab_tgt = src0 -> %f_ab, %f_sx, CONST0 {immediate = 1}       // prologue: an fma here
      }
      tu.matmul out = %f_tv, %wt, acts = %f_ab {m_rows = 4, dtype = dlf16}
          : (!fifo<tu -> vu, vector<64xdlf16>>, !tu.wtile<64x64xdlf16>, !fifo<xvu -> absu, vector<64xdlf16>>) -> ()
      vu.fma sp_tgt = result -> %f_vs, %f_tv, CONST4, CONST0 {unroll = 4}       // epilogue goes here
      %on = spsu.stu SP[%o + %ost : 4], %f_vs : !lrf<i32>
      yield %xpn, %on
    }
    spsu.sync put %done
    ncsu.sync get %done
    %d1, %e1 = ncsu.stmu SHM[%eb + %e0 : 32], SP[%db + %d0 : 32] : !sar<i15>, !car<i20>
  }
}
```

After expansion, `%wt` is `%w0 .. %w7` (TU registers defined outside the tile loop and used in every tile: allowed
by P1), and the tile loop carries the AB pointers as well: `loop 8 iter(%xp = %xp0, %o = %o0, %a = %a0, %g0 = %h0,
%g1 = %h1)`.

| Rule | Check |
|---|---|
| P2 | `%f_sx`: the `loop 64` pushes and pops 1 per iteration; the tile loop pushes 4 (`burst_size = 4`) and pops 4 (`loop 4`, one-sided). `%f_ab`, `%f_w`, `%f_tv`, `%f_vs`, `%abw`, `%abf`: 4, 8, 4, 4, 1, 1 per tile on both sides. `%stage`: no loop holds both sides, so the pipeline body counts: 2 and 2 |
| P3 | each `put` precedes its `get`; in the tile loop the order is SPLU → XVU → ABSU/ABLU → TU → VU → SPSU, the order of the data |
| P4 | `%ws`, `%xs`: written by NCLU, read by SPLU, covered by `%stage`. `%ys`: written by SPSU, read by NCSU, covered by `%done`. AB: written by ABSU, read by the ABLUs, covered by `%abw`; the next block's write by `%abf`. No buffer is rewritten after a read in the same pipeline otherwise |
| P5 | NCLU → SPLU → XVU → {TU, ABSU → ABLU → TU} → VU → SPSU → NCSU. Acyclic; `%abf` is a rewrite channel |
| P6 | `%f_n0`: the `loop 64` pushes 1 line per iteration and `load_weights` takes each as it arrives (block 1). `%f_ab`: 4 (the `matmul` block). `%f_w`, `%f_tv`, `%f_vs`: 4. `%stage`: 1 |
| P7 | TU: LRF0..7 weights, LRF8..11 partial sums. AB: 64 B per block in a 1 KB ring. SP: 128 lines |

The distributed form, after expansion and loop distribution (SPLU, XVU, ABSU, ABLU, TU, VU; NCLU, SPSU and NCSU
keep their ops in the same way):

```mlir
    unit @splu () {
      %wp0, %lst = splu.reg_init %ws - 128, 128 : !lrf<i32>, !lrf<i32>
      %xp0       = splu.reg_init %xs - 128 : !lrf<i32>
      splu.sync get %stage
      %wp2 = loop 64 iter(%wp = %wp0) {
        %wpn = splu.ldu consumer -> %f_sx, SP[%wp + %lst] : !lrf<i32>
        yield %wpn
      }
      splu.sync get %stage
      %xp2 = loop 8 iter(%xp = %xp0) {
        %xpn = splu.ldu consumer -> %f_sx, SP[%xp + %lst] {burst_size = 4} : !lrf<i32>
        yield %xpn
      }
      splu.return
    }

    unit @xvu () {
      loop 64 {
        xvu.logical tu_tgt = src0 -> %f_n0, %f_sx, CONST0 {immediate = 1}
      }
      loop 8 {
        loop 4 {
          xvu.logical ab_tgt = src0 -> %f_ab, %f_sx, CONST0 {immediate = 1}
        }
      }
      xvu.return
    }

    unit @absu () {
      %a0, %ast = absu.reg_init -16, 16 : !lrf<i10>, !lrf<i10>
      %a2 = loop 8 iter(%a = %a0) {
        %an = absu.stu AB[%a + %ast : 4], %f_ab {burst_en = 1} : !lrf<i10>
        absu.sync put %abw
        absu.sync get %abf
        yield %an
      }
      absu.return
    }

    unit @ablu attributes {rows = 8} () {
      %h0, %h1, %hst = ablu.reg_init -16, -8, 16 : !lrf<i10>, !lrf<i10>, !lrf<i10>
      %g0e, %g1e = loop 8 iter(%g0 = %h0, %g1 = %h1) {
        ablu.sync put %abf
        ablu.sync get %abw
        %g0n = ablu.ldu consumer -> %f_w, AB[%g0 + %hst : 4] {load_type = 1, replicate = 1, burst_en = 1} : !lrf<i10>
        %g1n = ablu.ldu consumer -> %f_w, AB[%g1 + %hst : 4] {load_type = 1, replicate = 1, burst_en = 1} : !lrf<i10>
        yield %g0n, %g1n
      }
      ablu.return
    }

    unit @tu attributes {rows = 8, cols = 8} () {
      %r     = tu.row_id : index
      %north = tu.north_link : !tu.link<vector<8xdlf16>>
      %west  = tu.west_link  : !tu.link<vector<8xdlf16>>
      %w0, %w1, %w2, %w3, %w4, %w5, %w6, %w7 = tu.fma_r #0, %north, #1.0 {unroll = 8}
          : 8 x !tu.lrf<vector<8xdlf16>>
      loop (56 - 8 * %r) {
        tu.fma %north, #0, #1.0 {south_tgt = src0}
      }
      loop 8 {
        %p0, %p1, %p2, %p3 = tu.fma_r (%w0, %w1, %w2, %w3), select(%r == 0, #0, %north), %west
                                      {east_tgt = src2, dot_len = 4, unroll = 4}
            : 4 x !tu.lrf<vector<8xdlf18>>
        tu.fma (%w4, %w5, %w6, %w7), (%p0, %p1, %p2, %p3), %west
               {east_tgt = src2, south_tgt = result, dot_len = 4, unroll = 4}
      }
      tu.return
    }

    unit @vu () {
      loop 8 {
        vu.fma sp_tgt = result -> %f_vs, %f_tv, CONST4, CONST0 {unroll = 4}
      }
      vu.return
    }
```

Compared with `down_proj`'s [R1](#region-r1-every-dnc), which runs one tile, the only change is the tile loop
around the per-tile ops of each unit, and the weights stay outside it. A K longer than 64 adds a K loop and a VU
accumulator carried by `iter` / `yield`; the loop orders and their cost are in
[`matmul-k-outer-schedule.md`](matmul-k-outer-schedule.md).

### Algorithms

The input is a pipeline in sequential form. The steps run in order; each check reports the op and the rule it
breaks.

**1. Expand macros.** Replace each macro op by its template at the same place. Move the template's register
preload and declarations to the pipeline entry, and add its pointer registers to the `iter` / `yield` of every loop
around the site. Afterwards every op is an ISA op of one unit.

**2. Check units (P1).** For each op, record its unit. For each register, the unit of its defining op (for a loop
result or `iter` argument, the unit of the `yield` operand) must equal the unit of every use. For each FIFO and
channel, collect its push (`put`) ops and pop (`get`) ops and check that each set has one unit, the one declared.

**3. Check FIFOs and channels (P2, P3).** For each FIFO or channel `c`:

- Token count of an op on `c`: the burst times the unroll for a FIFO op, 1 for a `put` or `get`, multiplied by the
  trip counts of the loops between the op and the loop being checked. A trip count that is a register or a JCR
  must be the same value on both sides (the same `%n`), or the check fails.
- For each loop that contains at least one push and one pop of `c` (and for the pipeline body), the token counts
  of pushes and pops in one iteration must be equal (P2).
- Walk one iteration of each such loop in program order, adding pushes and subtracting pops, a nested loop of one
  side counted as one step with its full count; the running sum must never go below zero (P3).

**4. Check buffers (P4).** For each `alloc` used in the pipeline, collect the ops that read and write it. An SHM
buffer must have only reads or only writes. An SP or AB buffer must have one writer unit `W` and one reader unit
`R`. For each write followed by a read in program order, there must be a channel from `W` to `R` with a `put`
between them in `W` and a `get` between them in `R`, in the program order of each unit; for each read followed by
a write (in a later iteration of some loop), a channel from `R` to `W` placed the same way. Both channels already
passed step 3. Overlap of address ranges is decided per buffer, not per line: a buffer counts as rewritten when
any loop around its writes runs more than once.

**5. Check cycles (P5).** Build a graph with one node per unit and one edge per FIFO (pusher → popper) and per
read-after-write channel of step 4 (`W` → `R`); TU rows are one node. It must be acyclic. With P2 and P3, a cycle
would not deadlock, but the units on it could not overlap iterations, so the pipeline would drain once per
iteration.

**6. Check capacity (P6).** <a id="capacity"></a>For each FIFO, walk one iteration of the loops of step 3 in
program order as in P3 and record the largest running sum, with one change: a pop by an op whose port contract has
block 1 (an ISA op that pops one token per beat, `load_weights`) is interleaved with the pushes before it, so the
pair adds at most 1. A pop with block `b` (an ABSU `stu` of `b` lines, `matmul`'s `acts`) adds `b`. The largest sum
must not exceed the FIFO's depth; for a channel, the largest number of `put`s ahead of `get`s must not exceed its
counter. P2 bounds every sum by the tokens of one loop iteration, so the walk never leaves one loop body.

**7. Check resources (P7).** Count the registers live in each unit (`!tu.wtile` is LRF0..7 of every TU row), the
AB bytes per block against the ring, and the SP lines of the pipeline's buffers.

**8. Distribute loops.** For each unit `u`, copy the body and keep:

- the ops of `u`, in the same order;
- every loop that contains an op of `u`, with the same trip count; a loop without one is dropped;
- the `iter` / `yield` entries whose values are registers of `u`;

then append `u.return`. The TU program keeps `%r`; the emitter unrolls it into 8 row blocks.

Why the result runs to completion: each unit's program is its ops in the sequential order, and by P3 every pop in
that order comes after its push, so executing the sequential body op by op is one schedule of all the units. By P6
it fits the real FIFO depths and channel counters. The units are sequential programs that block on FIFOs and
channels (a Kahn process network), whose behavior does not depend on the schedule, so if one schedule completes,
every schedule does.

**Inserting channels.** A compiler can place the channels of step 4 itself instead of checking hand-written ones:
a `put` right after the write in `W` and a `get` right before the read in `R`, in the innermost loop that contains
both, and the reverse for a rewrite. P2 then holds by construction; P5 and P6 still need checking.

## Before register allocation

The input side of the [sqrt pipeline](#example-sqrt-in-sequential-form) in distributed form (R = 2048, K = 64,
DNC 0).

```mlir
kernel @sqrt attributes {spmd_dncs = 16} {
  %inp = alloc : !ptr<buffer<2048 x i1024>, #shm>
  %bi  = alloc {align = 128} : !ptr<buffer<8320 x i8>, #sp>      // 65 lines (64 + 1 guard)

  pipeline (%inp, %bi, …) attributes {ncores = 1} {
    %f_ld   = fifo splu -> vu : !fifo<splu -> vu, vector<64xdlf16>>
    %stage  = channel nclu -> {splu0}      // an input chunk is in SP
    %infree = channel {splu0} -> nclu      // the input band may be overwritten

    unit @nclu () {
      %sar0, %sbr, %car0, %cbr = nclu.addr_init sar = 0, sbr = %bi / 128,
                                                car = 0, cbr = %inp + 128 * %dnc_id
          : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
      %sar3, %car3 = loop 2 iter(%sar1 = %sar0, %car1 = %car0) {               // pass
        %sar2, %car2 = loop 8 iter(%s = %sar1, %c = %car1) {                    // chunk
          %sn, %cn = nclu.ldmu SP[%sbr + %s : 8], SHM[%cbr + %c : 8] : !sar<i15>, !car<i20>
                                          // copy 8 lines SHM -> SP; returns s + 8, c + 8
          nclu.sync put %stage
          yield %sn, %cn
        }
        %sr = nclu.sxrimm 0 : !sar<i15>   // SP offset back to the band start; CAR keeps advancing
        nclu.sync get %infree
        yield %sr, %car2
      }
      nclu.return
    }

    unit @splu () {
      %p0, %st = splu.reg_init %bi - 128, 128 : !lrf<i32>, !lrf<i32>
      %p3 = loop 2 iter(%p1 = %p0) {                                            // pass
        %p2 = loop 8 iter(%pc = %p1) {                                          // chunk
          splu.sync get %stage
          %pl = loop 8 iter(%p = %pc) {                                         // line
            %pn = splu.ldu consumer -> %f_ld, SP[%p + %st] : !lrf<i32>   // pushes the line to vu; returns p + st
            yield %pn
          }
          yield %pl
        }
        %pr = splu.immcopy %bi - 128 : !lrf<i32>        // back to one line before the band
        splu.sync put %infree
        yield %pr
      }
      splu.return
    }
  }
}
```

## After register allocation

Every `iter`, `yield`, and result of one register coalesces into one physical register, so the loops carry nothing and no copy is needed. The IR is no longer SSA: a name is a physical register.

```mlir
kernel @sqrt attributes {spmd_dncs = 16} {
  %inp = alloc {addr = 0x1000} : !ptr<buffer<2048 x i1024>, #shm>
  %bi  = alloc {addr = 0x80}   : !ptr<buffer<8320 x i8>, #sp>      // line 1

  pipeline (%inp, %bi, …) attributes {ncores = 1} {
    %f_ld   = fifo splu -> vu : !fifo<splu -> vu, vector<64xdlf16>>
    %stage  = channel nclu -> {splu0}
    %infree = channel {splu0} -> nclu

    unit @nclu () {
      %sar, %sbr, %car, %cbr = nclu.addr_init sar = 0x0, sbr = 0x1, car = 0x0, cbr = 0x81000
          : !sar<i15, 0>, !sbr<i16, 0>, !car<i20, 0>, !cbr<i20, 0>
      loop 2 {
        loop 8 {
          %sar, %car = nclu.ldmu SP[%sbr + %sar : 8], SHM[%cbr + %car : 8] : !sar<i15, 0>, !car<i20, 0>
          nclu.sync put %stage
        }
        %sar = nclu.sxrimm 0 : !sar<i15, 0>
        nclu.sync get %infree
      }
      nclu.return
    }

    unit @splu () {
      %p, %st = splu.reg_init 0x0, 0x80 : !lrf<i32, 0>, !lrf<i32, 1>
      loop 2 {
        loop 8 {
          splu.sync get %stage
          loop 8 {
            %p = splu.ldu consumer -> %f_ld, SP[%p + %st] : !lrf<i32, 0>
          }
        }
        %p = splu.immcopy 0x0 : !lrf<i32, 0>
        splu.sync put %infree
      }
      splu.return
    }
  }
}
```

Assembly (B), for comparison:

```asm
.text_nclu                                  .text_splu
.lrf_idx 0                                  .lrf_idx 0 1
.lrf 0x810000000000000010000                .lrf 0x0 0x80
MVLOOPCNT count=2                           MVLOOPCNT count=2
  MVLOOPCNT count=8                           MVLOOPCNT count=8
    LDMU src0=SAR0, src1=SBR0,                  SYNC typ1_imm=6
         src2=CAR0, src3=CBR0 {burst=8}         MVLOOPCNT count=8
    SYNC typ1ac_imm=0x11 {be=1}                   LDU dst=VU, src1=LRF1 {be=1}
  SXRIMM                                        NOP {be=1}
  SYNC typ1ac_imm=0x12                        IMMCOPY dst=LRF0
  NOP {be=1}                                  SYNC typ1_imm=5
RETURN                                        NOP {be=1}
                                            RETURN
```

## SPLU with a runtime length (branch + block arguments)

From the runtime-length softmax (`tests/test_row_bands.py`, `_softmax(runtime="position")`): the trip is computed at run time from a JCR the host seeds, clamped, and used as a dynamic loop count.

```mlir
    unit @splu (%pos : !jcr) {                          // %pos: runtime value the host seeds
      %p0, %st = splu.reg_init …, … : !lrf<i32>, !lrf<i32>
      %len0 = splu.jadd %pos, 1 {jcr_sel = 1} : !jcr   // length = position + 1
      splu.jcmp %len0, 128 {cmp_type = GE} ^go(%len0), ^clamp     // = JCMP
    ^clamp:
      %c = splu.jimmcopy 128 : !jcr
      fallthrough ^go(%c)                               // no instruction
    ^go(%len : !jcr):                                   // block argument = phi
      %t = splu.jadd %len, 63 : !jcr
      %n = splu.jshr %t, 6 : !jcr                       // ceil(len / 64)
      splu.sync get %stage
      %p1 = loop %n iter(%p = %p0) {                    // dynamic loop: MVLOOPCNT src0=JCR {dynloop=1}
        %pn = splu.ldu consumer -> %f_ld, SP[%p + %st] {interleave_sz = 2} : !lrf<i32>
        yield %pn
      }
      splu.return
    }
```

After allocation `%len0`, `%c`, `%len`, `%t`, `%n` all sit in JCR5, so `fallthrough` and the block argument vanish, giving the assembly in `softmax_runtime_len.asm`:

```asm
JADD     jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP     pc_tgt=@L_3, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_3:
JADD     jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR     jcr_tgt=5, src0=5 {shamt=6}
SYNC     typ1_imm=6
MVLOOPCNT src0=5, typ1_imm=8 {dynloop=1}
  LDU dst=VU, src1=LRF1 {interleave_sz=2, be=1}
```

Unverified: what `jcr_sel=1` with no `src0` reads, and whether `JCMP ... GE` jumps when the comparison holds.

## Appendix A: `down_proj` as one SPMD program

`down_proj` (`x[4,256] @ w[256,64]` on 16 DNCs, mcc's mapping: DNC `d = 4m + k` takes output row `m` and K chunk
`k`) written in the notation above, as one program for every DNC and one program for every TU row. The motivation
is in [`rebel-programming-challenges.md`](rebel-programming-challenges.md). It is a design sketch; the code it
implies has not been run.

Choices
- **One program for every DNC.** Per-DNC differences are grid indices (`%m`, `%k`) in address expressions, bound
  when each DNC's image is emitted. The compute region has no root or leaf code.
- **Every DNC stores its partial to SHM, the root included.** The compute region then ends the same way on all
  16 DNCs, and the reduction reads all four partials of a group from SHM. It costs the root one line stored and
  loaded.
- **One TU program for all 8 rows.** The row index `%r` is a value of the program: the weight lines a row passes
  down is the affine count `56 − 8·%r`, and the partial-sum operand is a static choice on `%r`. The assembler
  unrolls the program into the 8 row blocks the hardware needs.
- **ISA operations only**, in the operand syntax above: FIFO sinks first (`sp_tgt = result -> %f_vs`), fixed-link
  targets as attributes, then `src0, src1, src2`. The only non-ISA operations are `addr_init` / `reg_init` (the block's `.lrf` preload) and
  the `grid.*` intrinsics.

### Additions to the notation

The TU-row and grouped-register forms are in [Notation for TU rows and grouped registers](#notation-for-tu-rows-and-grouped-registers);
the grid adds:

| Form | Meaning | Resolved at emit |
|---|---|---|
| `grid @D (m = 4, k = 4)` | the DNC grid; DNC `d = 4m + k`, cluster `m / 2` | each point's DNC |
| `%m, %k = grid.index @D` | this DNC's coordinates | constants per image |
| `grid.reduce %v on @D axes = [k] kind = add root = (k = 0)` | a collective over the points that differ only in `k` | lowered as below |
| `grid.on @D (k == 0) { … }` | code only the selected points run | kept in or dropped from each image |
| `grid.channel @D ncsu -> nclu@(m, 0)`, `grid.signal put/get` | a sync channel to a unit of another point | `SYNC` if the same DNC, else `MESYNC` with the peer's bit |

### Region R1: every DNC

```mlir
kernel @down_proj {
  grid @D (m = 4, k = 4)
  %m, %k = grid.index @D : index, index

  %x   = alloc : !ptr<buffer<16 x i1024>, #shm>                // x[m, 64k:+64] at line 4k + m
  %w   = alloc : !ptr<buffer<256 x i1024>, #shm>               // w[64k + q, :] at line 64k + q
  %ps  = alloc : !ptr<buffer<16 x i1024>, #shm>                // partial(m, k) at line 4m + k
  %out = alloc : !ptr<buffer<4 x i1024>, #shm>                 // out[m, :] at line m
  %ws  = alloc {align = 128} : !ptr<buffer<8192 x i8>, #sp>    // 64 w lines
  %xs  = alloc {align = 128} : !ptr<buffer<512 x i8>, #sp>     // the 4-row x tile; row 0 is x[m, :]
  %pt  = alloc {align = 128} : !ptr<buffer<512 x i8>, #sp>     // the 4-row partial tile

  pipeline @r1 attributes {ncores = 1} {
    %f_sx  = fifo splu -> xvu      : !fifo<splu -> xvu, vector<64xdlf16>>
    %f_n0  = fifo xvu -> tu.north  : !fifo<xvu -> tu, vector<64xdlf16>>    // row 0's north
    %f_ab  = fifo xvu -> absu      : !fifo<xvu -> absu, vector<64xdlf16>>
    %f_w   = fifo ablu -> tu.west  : !fifo<ablu -> tu, vector<8xdlf16>>    // per row
    %f_tv  = fifo tu.south -> vu   : !fifo<tu -> vu, vector<64xdlf16>>     // row 7's south
    %f_vs  = fifo vu -> spsu       : !fifo<vu -> spsu, vector<64xdlf16>>
    %stage = channel nclu -> {splu0} : !chan<nclu -> splu0>
    %abw   = channel absu -> ablu   : !chan<absu -> ablu>
    %abf   = channel ablu -> absu   : !chan<ablu -> absu>
    %pdone = channel spsu -> ncsu   : !chan<spsu -> ncsu>

    unit @nclu () {
      %s0, %sb, %c0, %cb = nclu.addr_init sar = 0, sbr = %ws / 128, car = 0, cbr = %w + 64 * %k
          : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
      %s2, %c2 = loop 2 iter(%s = %s0, %c = %c0) {
        %sn, %cn = nclu.ldmu SP[%sb + %s : 32], SHM[%cb + %c : 32] : !sar<i15>, !car<i20>   // w[64k .. +63, :]
        yield %sn, %cn
      }
      nclu.sync put %stage
      %t0, %tb, %u0, %ub = nclu.addr_init sar = 0, sbr = %xs / 128, car = 0, cbr = %x + 4 * %k + %m
          : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
      %t1, %u1 = nclu.ldmu SP[%tb + %t0 : 1], SHM[%ub + %u0 : 1] : !sar<i15>, !car<i20>     // x[m, 64k:+64]
      nclu.sync put %stage
      nclu.return
    }

    unit @splu () {
      %p0, %st = splu.reg_init %ws - 128, 128 : !lrf<i32>, !lrf<i32>
      splu.sync get %stage
      %p1 = loop 64 iter(%p = %p0) {
        %pn = splu.ldu consumer -> %f_sx, SP[%p + %st] : !lrf<i32>   // push w line q to xvu
        yield %pn
      }
      %q0 = splu.immcopy %xs - 128 : !lrf<i32>
      splu.sync get %stage
      %q1 = splu.ldu consumer -> %f_sx, SP[%q0 + %st] {burst_size = 4} : !lrf<i32>   // x tile rows t = 0..3
      splu.return
    }

    unit @xvu () {
      loop 64 {
        // <no_ref_def> = opcode %
        xvu.logical tu_tgt = src0 -> %f_n0, %f_sx, CONST0 {immediate = 1}   // OR 0: pass the w line to the TU
      }
      loop 4 {
        xvu.logical ab_tgt = src0 -> %f_ab, %f_sx, CONST0 {immediate = 1}   // pass the x tile to ABSU
      }
      xvu.return
    }

    unit @absu () {
      %a0, %ast = absu.reg_init -16, 16 : !lrf<i10>, !lrf<i10>           // 10-bit ring, -16 = 0x3f0
      %a1 = absu.stu AB[%a0 + %ast : 4], %f_ab {burst_en = 1} : !lrf<i10>  // line t: AB_r[16t + 2i] := line_t[8r + i]
      absu.sync put %abw
      absu.sync get %abf
      absu.return
    }

    unit @ablu attributes {rows = 8} () {                                 // one program; row r reads only AB_r
      %h0, %h1, %st = ablu.reg_init -16, -8, 16 : !lrf<i10>, !lrf<i10>, !lrf<i10>
      ablu.sync put %abf
      ablu.sync get %abw
      %h2 = ablu.ldu consumer -> %f_w, AB[%h0 + %st : 4] {load_type = 1, replicate = 1, burst_en = 1} : !lrf<i10>
                                                                          // t = 0..3: (a, a), a = x[t][8r + 0..3]
      %h3 = ablu.ldu consumer -> %f_w, AB[%h1 + %st : 4] {load_type = 1, replicate = 1, burst_en = 1} : !lrf<i10>
                                                                          // t = 0..3: (a, a), a = x[t][8r + 4..7]
      ablu.return
    }

    // One TU row = 8 slices x 8 lanes running the same instruction; types are per slice (8 lanes).
    // A 128 B line on a FIFO outside the TU (%f_n0, %f_tv: vector<64xdlf16>) is 64 lanes; inside a row it is
    // 8 slices x 8 lanes, slice c holding lanes 8c..8c+7 (output column n = 8c + lane). A w line entering from
    // the north splits the same way, so slice c latches w[·, 8c..8c+7]. The west value Z (4 x values, duplicated
    // to 8 lanes) enters slice 0 and moves east slice by slice (east_tgt = src2), so every slice sees the same Z.
    // North and south are fixed links between rows: row 0's north is fed by XVU (%f_n0), row 7's south feeds
    // the VU (%f_tv), so every row reads `north` and writes `south_tgt` the same way.
    // tu.fma_r writes registers and has result types; tu.fma writes only links (south/east) and has none.
    // A use of a link value pops one entry.
    unit @tu attributes {rows = 8, cols = 8} () {
      %r     = tu.row_id : index                                       // pseudo op: 0..7, a constant per copy
      %north = tu.north_link : !tu.link<vector<8xdlf16>>              // w lines, then the psums of row r-1
      %west  = tu.west_link  : !tu.link<vector<8xdlf16>>              // Z = (a, a) from this row's ABLU

      %w0, %w1, %w2, %w3, %w4, %w5, %w6, %w7 = tu.fma_r #0, %north, #1.0 {unroll = 8}
          : 8 x !tu.lrf<vector<8xdlf16>>                               // %w<i> := 0·1.0 + pop(N) = w[64k + 8r + i, :]
      loop (56 - 8 * %r) {
        tu.fma %north, #0, #1.0 {south_tgt = src0}                     // forward a w line (X) to the rows below
      }
      %p0, %p1, %p2, %p3 = tu.fma_r (%w0, %w1, %w2, %w3), select(%r == 0, #0, %north), %west
                                    {east_tgt = src2, dot_len = 4, unroll = 4}
          : 4 x !tu.lrf<vector<8xdlf18>>                               // t = 0..3: %p<t> := Σ_{i<4} %w<i>·Z_i + Y
      tu.fma (%w4, %w5, %w6, %w7), (%p0, %p1, %p2, %p3), %west
             {east_tgt = src2, south_tgt = result, dot_len = 4, unroll = 4}
                                                                       // t = 0..3: Σ_{i<4} %w<4+i>·Z_i + %p<t> -> south
      tu.return
    }

    unit @vu () {
      vu.fma sp_tgt = result -> %f_vs, %f_tv, CONST4, CONST0 {unroll = 4}   // S_7[t] · 1.0 + 0 -> spsu, t = 0..3
      vu.return
    }

    unit @spsu () {
      %o0, %st = spsu.reg_init %pt - 128, 128 : !lrf<i32>, !lrf<i32>
      %o1 = spsu.stu SP[%o0 + %st : 4], %f_vs : !lrf<i32>
      spsu.sync put %pdone
      spsu.return
    }

    unit @ncsu () {
      %s0, %sb, %c0, %cb = ncsu.addr_init sar = 0, sbr = %pt / 128, car = 0, cbr = %ps + 4 * %m + %k
          : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
      ncsu.sync get %pdone
      %s1, %c1 = ncsu.stmu SHM[%cb + %c0 : 1], SP[%sb + %s0 : 1] : !sar<i15>, !car<i20>   // tile row 0 = partial(m, k)
      ncsu.return
    }
  }

  grid.reduce %ps on @D axes = [k] kind = add root = (k = 0) into %out[%m]
}
```

Every DNC runs `@r1` unchanged, and its only output is the SHM line `%ps[4m + k]`; no register state is left for
a later region. `@r1` meets the [pipeline rules](#constraints): its SHM inputs are only read and `%ps` is only
written, and the reduction, which reads other DNCs' partials, is a separate pipeline.

### The reduction, lowered

`grid.reduce` takes the group `{(m, j) | j < 4}` from `axes = [k]` and its root from `root = (k = 0)`. Lowered, it
adds a handshake at the end of every member's `@r1` and a region `@r2` that only the roots run:

```mlir
  %ready = grid.channel @D ncsu -> nclu@(m, 0) : !grid.chan<ncsu -> nclu@(m, 0)>   // member -> root: "my partial is in SHM"
  %taken = grid.channel @D nclu@(m, 0) -> ncsu : !grid.chan<nclu@(m, 0) -> ncsu>   // root -> member: "lines loaded"

  // appended to every member's @r1 NCSU, after its stmu
  grid.signal put %ready
  grid.signal get %taken                            // the SHM slot may be reused after this

  grid.on @D (k == 0) {
    %gs = alloc {align = 128} : !ptr<buffer<512 x i8>, #sp>         // the group's 4 partial lines
    %os = alloc {align = 128} : !ptr<buffer<128 x i8>, #sp>         // the reduced line

    pipeline @r2 attributes {ncores = 1} {
      %f_gv  = fifo splu -> vu  : !fifo<splu -> vu, vector<64xdlf16>>
      %f_vo  = fifo vu -> spsu  : !fifo<vu -> spsu, vector<64xdlf16>>
      %gin   = channel nclu -> {splu0} : !chan<nclu -> splu0>
      %odone = channel spsu -> ncsu   : !chan<spsu -> ncsu>

      unit @nclu () {
        grid.signal get %ready {from = group}                         // all 4 members, the root included
        %s0, %sb, %c0, %cb = nclu.addr_init sar = 0, sbr = %gs / 128, car = 0, cbr = %ps + 4 * %m
            : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
        %s1, %c1 = nclu.ldmu SP[%sb + %s0 : 4], SHM[%cb + %c0 : 4] : !sar<i15>, !car<i20>   // partial(m, 0..3)
        nclu.sync put %gin
        grid.signal put %taken {to = group}
        nclu.return
      }

      unit @splu () {
        %g0, %st = splu.reg_init %gs - 128, 128 : !lrf<i32>, !lrf<i32>
        splu.sync get %gin
        %g1 = splu.ldu consumer -> %f_gv, SP[%g0 + %st] {burst_size = 4} : !lrf<i32>
        splu.return
      }

      unit @vu () {                                                    // one row: no tile padding
        %a0 = vu.fma %f_gv, CONST4, CONST0 : vector<64xdlf16>
        %a1 = vu.fma %f_gv, CONST4, %a0 : vector<64xdlf16>
        %a2 = vu.fma %f_gv, CONST4, %a1 : vector<64xdlf16>
        vu.fma sp_tgt = result -> %f_vo, %f_gv, CONST4, %a2            // Σ_j partial(m, j) -> spsu
        vu.return
      }

      unit @spsu () {
        %o0, %st = spsu.reg_init %os - 128, 128 : !lrf<i32>, !lrf<i32>
        %o1 = spsu.stu SP[%o0 + %st : 1], %f_vo : !lrf<i32>
        spsu.sync put %odone
        spsu.return
      }

      unit @ncsu () {
        %s0, %sb, %c0, %cb = ncsu.addr_init sar = 0, sbr = %os / 128, car = 0, cbr = %out + %m
            : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
        ncsu.sync get %odone
        %s1, %c1 = ncsu.stmu SHM[%cb + %c0 : 1], SP[%sb + %s0 : 1] : !sar<i15>, !car<i20>   // out[m, :]
        ncsu.return
      }
    }
  }
```

A root runs `@r1` and then `@r2` in each unit's program order (each unit's `return` moves to the end of `@r2`);
the regions meet only through SHM `%ps` and the two grid channels. On the root, `%ready` and `%taken` to and from
itself become intra-DNC `SYNC`s between its NCSU and NCLU; to the other members they become `MESYNC`s. The root
waits for its three leaves with one `MESYNC` that sets three peer bits and loads the 4 lines with one transfer,
instead of the current one-by-one gather.

### Emit-time specialization

| In the IR | Emitted for DNC `d = 4m + k`, TU row `r` |
|---|---|
| `%w + 64 * %k`, `%x + 4 * %k + %m`, `%ps + 4 * %m + %k`, `%out + %m` | NC descriptor constants (`.lrf`) of that image |
| `grid.on @D (k == 0)` | `@r2` in images 0, 4, 8, 12 only |
| `grid.signal` on `%ready`, `%taken` | root: `SYNC` NCSU ↔ NCLU; member `k > 0`: `MESYNC` with `sync_mask.dnc<4m>`; the root's `{from = group}`: one `MESYNC get` with bits `dnc<4m+1..4m+3>` and one `SYNC get` |
| `tu.row`, `loop (56 - 8 * %r)` | 8 TU blocks, each with `MVLOOPCNT immediate = 56 − 8r`; row 7 has no loop |
| `select(%r == 0, #0, %north)` | `src1=#0` in row 0, `src1=FIFO_NORTH` in rows 1..7 |
| `{unroll = 4}`, `{unroll = 8}` | `unroll_control.degree = 2` or `3`; the results and register groups become consecutive LRFs (`%w0..%w7` → LRF0..7, `%p0..%p3` → LRF8..11, `(%w0, …, %w3)` → `LRF[0:3]`) |

TU row 3 as the assembler would unroll it (new syntax):

```asm
.text_tu
.target 0x81
.place col=3 line=33
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
MVLOOPCNT immediate=0x20                                         // 56 - 8·3
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN
```

### What the single TU program lets a checker prove

Counts are affine in `%r`, so one check covers all 8 rows. On the link from row `r` to row `r + 1` (`r < 7`):

- row `r` pushes south `(56 − 8r)` passed w lines `+ 4` partial sums `= 60 − 8r`
- row `r + 1` pops north `8` latched `+ (56 − 8(r + 1))` passed `+ 4` partial sums `= 60 − 8r`

Row 0 pops `8 + 56 = 64` w lines, which XVU pushes; row 7 pushes `0 + 4` lines, which the VU pops. On the west
link, ABLU pushes `2 · 4 = 8` entries per row and the row's two dot-product FMAs pop `4 + 4`. Every member puts
`%ready` once and gets `%taken` once; the root gets `%ready` four times and puts `%taken` four times.

### Compared with the current code

| | Current mcc code | This sketch |
|---|---|---|
| Programs | root and leaf images differ in NCLU, SPLU, VU, SPSU, NCSU | one program; `@r2` only under `grid.on (k == 0)` |
| Root's own partial | kept in VU registers into the gather | stored to SHM like every member's |
| Gather | 3 handshakes and 3 loads, one leaf after another | one wait on all members, one 4-line load |
| Reduction adds | 3 steps on the padded 4-row tile, a store after each | 4 single-row adds, one store |
| TU | 8 row blocks written separately | one program; counts affine in `%r` |

Not measured: the root's extra SHM round trip, and whether waiting for all members at once costs more than the
current overlap of the first leaf's add with the later leaves' arrival.

## Appendix B: macro op background and plan

In a weight-stationary matmul the TU, ABSU and ABLU programs barely change with the shape. Many architectures
expose the same function as one matrix unit with one interface. This appendix gives the evidence behind the
[macro ops](#macro-ops), defines the reduce collective the same way, and lists how to get there.

### What changes with the shape today

mcc emits the three from fixed templates. In `emit_tu.py` a TU row has four FMA roles (prime, forward, mac, drain);
the forward trip is a per-row formula `8 · (8 − 1 − row)`, and the only other trip is the pass loop, the product of
the output-tile and M-tile counts (`Bout · Br`). `emit_ab.py` gives the ABSU one 4-beat store and the ABLU a walk of
`k_in / burst` loads, both repeated once per output tile.

Building five `tests/perf/dense` shapes with mcc (`m4_k256_n64`, `m128_k64_n64`, `m128_k256_n64`, `m512_k64_n64`,
`m128_k1024_n64`) and comparing DNC 0's first ABSU, ABLU and TU row 0 blocks confirms it: the code differs only in
`MVLOOPCNT` trips (1, 4 or 16 passes), and once in where a 1-trip frame was dropped. Larger M and K add passes;
the instructions inside are the same. The variants mcc knows beyond this are few: the kernel arriving from the
west through the AB (a transposed or page-form tiling, `kernel_arm` in `emit_ab.py`), runtime trip counts
(`emit_dyn`), and the FMA opcode for the dtype (`FMA` / `FMABF`).

### How other architectures expose a matrix unit

| | Unit and interface | Who stages the operands | What the programmer writes |
|---|---|---|---|
| TPU v1 | 256×256 systolic matrix unit; CISC instructions from the host | `Read_Weights` fills a weight FIFO; `MatrixMultiply` streams B×256 inputs from the Unified Buffer into accumulators | a few instructions per layer; the skew and weight shifting are hardware |
| TPU (later generations) | MXU behind the vector unit; per-bundle push / pop ops | `vmatpush` pushes weights into the array, `vmatmul` pushes LHS rows, `vpop` pops results from a result FIFO (8 rows × 128 columns per pop on v6e) | MXU ops inside the compiler's VLIW bundles; Pallas and XLA hide them |
| NVIDIA Hopper | Tensor Cores via `wgmma`, one async instruction per 64×N×16 tile | A and B are read straight from shared memory through 64-bit descriptors (base, strides, swizzle) | one instruction plus fence / commit / wait |
| Tenstorrent | separate unpack, math and pack RISC-V threads around the matrix engine, close to REBEL's split units | the unpacker moves L1 data to the source registers, the packer moves results out | one compute kernel calling `matmul_tiles`; `UNPACK` / `MATH` / `PACK` macros compile the same source for the three cores, and the LLK handles their handshake |
| REBEL today | ABSU, 8 ABLUs and 8 TU rows, each its own program | the program writes every unit's loads, stores, FMAs and syncs | 17 programs per NCore |

The Tenstorrent case is the closest: several small sequencers around one matrix engine, but a library op (the LLK)
hides them, so a kernel names a tile operation rather than the per-engine code.

The macro ops follow TPU's MXU split (`vmatpush`, `vmatmul`, `vpop`); their types, port contracts and expansion
are in [Macro ops](#macro-ops), and [Example: matmul with macro ops](#example-matmul-with-macro-ops) uses them.

### The reduce collective as a template

`grid.reduce` from Appendix A, defined the same way: typed operands, a port contract, and an expansion with its
registers fixed. Parameters: the group size `G` (from `axes`), the lines per partial `L`, and `algo`.

```mlir
// Each grid point contributes L lines at %src[slot]; the root of each group writes their sum to %dst.
grid.reduce %src on @D axes = [k] kind = add root = (k = 0) into %dst {lines = L, algo = batched}
    : (!ptr<buffer<16 x i1024>, #shm>, !ptr<buffer<4 x i1024>, #shm>) -> ()
```

| Port | Count | When it can make progress |
|---|---|---|
| member's slot `%src[(m, j)]`, `L` lines | written by the member before `%ready` | the root starts only after all `G` members' `%ready` (batched) or member `j`'s (star, in order) |
| member's `%taken` | 1 get per member | the slot may be reused only after it |
| root's `%dst`, `L` lines | written once | after all `G · L` lines are summed |
| root's SPLU → VU FIFO | `G · L` lines | the VU emits output line `l` after its `G` inputs |

Expansion, `algo = batched` (slots laid out member-major: line `l` of member `j` at `%src + G·L·m + L·j + l`):

```mlir
%ready = grid.channel @D ncsu -> nclu@(m, 0) : !grid.chan<ncsu -> nclu@(m, 0)>
%taken = grid.channel @D nclu@(m, 0) -> ncsu : !grid.chan<nclu@(m, 0) -> ncsu>

// every member, after storing its L lines
grid.signal put %ready : !grid.chan<ncsu -> nclu@(m, 0)>
grid.signal get %taken : !grid.chan<nclu@(m, 0) -> ncsu>

grid.on @D (k == 0) {
  unit @nclu () {
    grid.signal get %ready {from = group} : !grid.chan<ncsu -> nclu@(m, 0)>        // G tokens
    %s0, %sb, %c0, %cb = nclu.addr_init sar = 0, sbr = %gs / 128, car = 0, cbr = %src + G * L * %m
        : !sar<i15, 4>, !sbr<i16, 4>, !car<i20, 4>, !cbr<i20, 4>                     // fixed: descriptor 4
    %s1, %c1 = nclu.ldmu SP[%sb + %s0 : G * L], SHM[%cb + %c0 : G * L] : !sar<i15, 4>, !car<i20, 4>
    nclu.sync put %gin : !chan<nclu -> splu0>
    grid.signal put %taken {to = group} : !grid.chan<nclu@(m, 0) -> ncsu>
  }

  unit @splu () {                                     // reorder to line-major: G entries per output line
    %g0, %stg = splu.reg_init %gs - L * 128, L * 128 : !lrf<i32, 11>, !lrf<i32, 10>
    splu.sync get %gin : !chan<nclu -> splu0>
    %g2 = loop L iter(%g = %g0) {
      %gn = splu.ldu consumer -> %f_gv, SP[%g + %stg] {burst_size = G} : !lrf<i32, 11>   // line l of members 0..G-1
      %gb = splu.modlrfimm %gn, -(G * L - 1) * 128 : !lrf<i32, 11>                      // back to line l+1 of member 0
      yield %gb
    }
  }

  unit @vu () {
    loop L {
      %a0 = vu.fma %f_gv, CONST4, CONST0 : !vu.lrf<vector<64xdlf16>, 4>
      %a2 = loop (G - 2) iter(%a = %a0) {
        %an = vu.fma %f_gv, CONST4, %a : !vu.lrf<vector<64xdlf16>, 4>                    // fixed: LRF4
        yield %an
      }
      vu.fma sp_tgt = result -> %f_vo, %f_gv, CONST4, %a2                                 // Σ_j line l of member j
    }
  }

  unit @spsu () {
    %o0, %st = spsu.reg_init %os - 128, 128 : !lrf<i32, 0>, !lrf<i32, 15>
    %o1 = spsu.stu SP[%o0 + %st : L], %f_vo : !lrf<i32, 0>
    spsu.sync put %odone : !chan<spsu -> ncsu>
  }

  unit @ncsu () {
    %s0, %sb, %c0, %cb = ncsu.addr_init sar = 0, sbr = %os / 128, car = 0, cbr = %dst + L * %m
        : !sar<i15, 0>, !sbr<i16, 0>, !car<i20, 0>, !cbr<i20, 0>
    ncsu.sync get %odone : !chan<spsu -> ncsu>
    %s1, %c1 = ncsu.stmu SHM[%cb + %c0 : L], SP[%sb + %s0 : L] : !sar<i15, 0>, !car<i20, 0>
  }
}
```

For `down_proj` the parameters are `G = 4`, `L = 1`: the SPLU loop runs once with a burst of 4, and the VU chain is
`G − 1 = 3` adds. `algo = star` replaces the root's single wait and load with `G` waits, loads and releases in
member order, and lets the VU start on member 0 before the later members arrive. The VU chain is a serial
dependence, and the ISA asks for at least 3 independent instructions between dependent VU operations, so with
`L ≥ 3` the template should interleave lines rather than run each line's chain back to back.

### Steps

1. **Inventory.** Normalize every ABSU, ABLU and TU program mcc emits across the dense, conv and attention test
   corpus (masking trip immediates, as in the comparison above) and cluster them into templates plus parameters.
   The output is the variant list the macros must cover; conv's `cin.in` and page-form primes are the likely extras.
2. **Define the ops and their expanders.** Add `tu.load_weights`, `tu.matmul` and `grid.reduce` to the machine IR
   with their types and port contracts, and expanders that emit the unit programs. Check that the expansion is
   byte-identical to mcc's output on the corpus (`bytecheck`), so the ops add no behavior.
3. **Emit them from mcc.** Let mcc produce the macros where `emit_tu.py`, `emit_ab.py` and the reduce lowering now
   emit unit templates, and let the grid IR (Appendix A) refer to them.
4. **Check pipelines.** Implement [Algorithms](#algorithms) steps 1–8 on the machine IR. It must accept the sqrt
   and matmul examples and `down_proj`'s `@r1` and `@r2`, and reject an SP accumulator (variant A in
   [`matmul-k-outer-schedule.md`](matmul-k-outer-schedule.md)) and a channel matched across loop iterations.
5. **Hardware feedback.** With the macros as the only users of the TU and AB units, measure what a matrix-engine
   command (push and pop instructions like TPU's, or loading one TU block into all rows as codesigner#2399 proposes)
   would save in instruction-buffer space and per-row copies.

Open points: whether conv and attention fit the same parameters; AB capacity when blocks lap the 1 KB ring
(`refuse_ring_lap` in `emit_ab.py`); whether accumulation across K passes belongs in `tu.matmul` or stays in the VU;
and the FIFO depths and sync counter sizes behind the port contracts and the capacity check (P6), which the ISA
documentation does not give yet.

Sources: [TPU v1 architecture](https://thechipletter.substack.com/p/googles-first-tpu-architecture),
[TPU lecture notes (NYCU)](https://people.cs.nycu.edu.tw/~ttyeh/course/2024_Fall/IOC5009/slide/lecture-5.pdf),
[TPU v6e-style MXU ops in a model (vcix-accelerator PR #28)](https://github.com/PSAL-POSTECH/vcix-accelerator/pull/28),
[Google patent: Low latency matrix multiply unit (matrix result FIFO)](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10635740),
[WGMMA tutorial (NVIDIA tilus)](https://nvidia.github.io/tilus/latest/tutorials/matmul-hopper/v1.html),
[WGMMADescriptor (Mojo)](https://docs.modular.com/mojo/std/gpu/compute/mma/WGMMADescriptor),
[TT-Metalium compute APIs](https://docs.tenstorrent.com/tt-metal/latest/tt-metalium/tt_metal/apis/kernel_apis/compute/compute.html),
[TT-Metalium matmul single core](https://docs.tenstorrent.com/tt-metal/latest/tt-metalium/tt_metal/examples/matmul_single_core.html),
[PyBuda terminology](https://docs.tenstorrent.com/pybuda/latest/terminology.html).
