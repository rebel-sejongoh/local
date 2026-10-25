# MLIR machine IR for REBEL pipelines

A machine IR in which every unit's program is SSA: its notation, the rules a pipeline must meet and how they are
checked, and examples. The matrix unit (TU, ABSU, ABLUs) appears as one unit, the MXU, with one op, until the
image is emitted.

| Section | Contents |
|---|---|
| [Pipelines](#pipelines) | the sequential and distributed forms, the rules, a sqrt example |
| [The MXU](#the-mxu) | `mxu.matmul` |
| [Example: matmul](#example-matmul) | `x[128, 512] @ w[512, 256]`: sequential form, distributed form, checks |
| [Algorithms](#algorithms) | the checks and loop distribution |
| [Before](#before-register-allocation) / [after register allocation](#after-register-allocation) | the sqrt example allocated |
| [Emitting the MXU](#emitting-the-mxu) | the MXU's template and the example's TU, ABSU and ABLU programs |
| [Appendix A](#appendix-a-down_proj-as-one-spmd-program) | `down_proj` on 16 DNCs, written out per unit |
| [Appendix B](#appendix-b-macro-op-background-and-plan) | why a macro op, and the reduce collective |

It is a design sketch: only the generated assembly in [`matmul-kouter-vp.md`](matmul-kouter-vp.md) has run.

## Notation

- Every unit is SSA. A value carried across a loop is a loop `iter` / `yield`; a value merged after a branch is a block argument.
- An op that updates a register in place returns the new value: `%sn, %cn = nclu.ldmu …`. Register allocation ties the result to the operand.
- Op syntax: `%results = <unit>.<opcode> sinks, src0, src1, … {attrs} : result types`, with sources in ISA field order.
  The left-hand side holds only registers, or nothing: a FIFO is never a result, and the FIFO an op pushes to is an
  operand on the right.
  A register result is a `%result`, and every op with results shows their types after `:`. A FIFO sink is written
  first: `field = selected value -> %fifo` when the field selects a value (`sp_tgt = result -> %f_vs`), and
  `field = %fifo` when it only names the destination (`consumer = %f_ld`). A target on a fixed link (TU
  `south_tgt`, `east_tgt`) is an attribute. A memory destination (`SP[…]`, `AB[…]`, `SHM[…]`) is the first
  operand.
- Memory operands print as `SPACE[base + offset : length]`. NC: `SP[%sbr + %sar : N]`, `SHM[%cbr + %car : N]`, in
  lines, `N` = burst. SP and AB units: `SP[%ptr + %stride]`, `AB[%ptr + %stride]`, in bytes, the address the access
  actually uses (the unit adds the stride before each access); a burst is the `burst_size` attribute. A strided
  NC transfer (`LDSU`/`STSU`) prints `SP[%sar, stride %sbr : N]`. The `+` is fixed syntax for the hardware's own
  addition, not a general expression.
- `alloc` returns the buffer's start address. SHM elements are `i1024` (line); SP elements are `i8` (byte). NC addresses SP in lines, so it uses `%bi / 128`.
- Register initial values (the block's `.lrf` preload): `addr_init` for the NC descriptor fields (SAR, SBR, CAR, CBR),
  `reg_init` for an ordinary LRF.
- Types name the hardware storage: `!sar<i15>`, `!sbr<i16>`, `!car<i20>`, `!cbr<i20>` (NC descriptor fields),
  `!lrf<i32>` (SP unit LRF), `!jcr`. After allocation they carry the index: `!sar<i15, 0>`.
- The unit prefix of an op names the unit that runs it; `mxu.` names [the MXU](#the-mxu), which stands for the TU,
  ABSU and ABLUs together.
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

A value that must cross loop levels or iterations (an accumulator over K) is a register of one unit: P1 allows
it, and P2 does not see it. The MXU keeps its weights the same way, in TU registers, across the tiles of one op.

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
          %pn = splu.ldu consumer = %f_ld, SP[%p + %st] : !lrf<i32>
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

## The MXU

In a weight-stationary matmul the TU, ABSU and ABLU programs barely change with the shape
([Appendix B](#appendix-b-macro-op-background-and-plan)). The IR therefore treats the three as one unit, the
**MXU**, with one op, and keeps it that way through the checks, loop distribution and register allocation. Only
the emitter turns it into the ABSU, ABLU and TU programs ([Emitting the MXU](#emitting-the-mxu)).

```mlir
// Latch one 64×64 weight tile from %f_n0, then run `tiles` tiles of `m_rows` rows of x from %f_ab through it,
// pushing m_rows result lines per tile to %f_tv.
mxu.matmul out = %f_tv, weights = %f_n0, acts = %f_ab {tiles = n, m_rows = 4, dtype = dlf16}
    : (!fifo<tu -> vu, vector<64xdlf16>>, !fifo<xvu -> tu, vector<64xdlf16>>,
       !fifo<xvu -> absu, vector<64xdlf16>>) -> ()
```

| Operand, attribute | Meaning |
|---|---|
| `weights` | 64 lines: line `q` is `w[k0 + q, n0 .. n0+63]`, a 64×64 tile of one K block and one N block |
| `acts` | `tiles · m_rows` lines: line `j` of tile `t` is `x[row, k0 .. k0+63]`, the same K block |
| `out` | `tiles · m_rows` lines: `Σ_q x[row][k0 + q] · w[k0 + q][n0 ..]`, in DLFloat16 (DLFloat18 inside the array) |
| `m_rows` | rows per tile: 1, 2 or 4, bounded by the TU's four partial-sum registers (LRF8..11). 4 in practice |
| `tiles` | how many tiles reuse the latched weights: any count |

One op replaces TPU's `vmatpush` (load the weights), `vmatmul` (push LHS rows) and `vpop` (pop results), and
it replaces a separate weight load: the weights live only inside the op, so the IR carries no weight value
across loops, and weight reuse is the `tiles` attribute.

**As a unit.** The MXU's ops are `mxu.` ops. Its ports are two input FIFOs (`weights` from the XVU into TU row
0's north, `acts` from the XVU into the ABSU) and one output FIFO (`out`, from TU row 7's south to the VU). Its
registers (LRF0..11 of every TU row, the ABSU's and ABLUs' AB pointers) are fixed by its template and used by
nothing else, so register allocation leaves them alone.

**Port contracts**, used by the capacity check:

| Port | Per op | Progress |
|---|---|---|
| `weights` | pops 64 | a line at a time, latched or passed down; the first result needs all 64 |
| `acts` | pops `tiles · m_rows` | a tile at a time |
| `out` | pushes `tiles · m_rows` | a tile at a time, in tile order, after that tile's `acts` |

## Example: matmul

`y[128, 256] = x[128, 512] @ w[512, 256]` in DLFloat16, on one DNC and one NCore (`ncores = 1`).

**Tiling.** The MXU works on 64×64 weight tiles and on tiles of 4 rows of x:

| Symbol | Meaning | Value |
|---|---|---|
| `M` | rows per tile, `m_rows` | 4 |
| `T` | tiles: 128 rows / 4 | 32 |
| `KB` | K blocks of 64: 512 / 64 | 8 |
| `NB` | N blocks of 64, the output column blocks: 256 / 64 | 4 |
| `R` | tiles whose partial sums stay in the VU at once (4 LRFs each, of 16) | 4 |

**Schedule.** Register psum ([`matmul-k-outer-schedule.md`](matmul-k-outer-schedule.md), variant C): for each
output block and each group of `R` tiles, walk the K blocks; for each K block one `mxu.matmul` latches the
weight tile and runs the group's 4 tiles through it, and the VU adds each tile's result into that tile's four
registers. The loops, outer to inner:

| Loop | Trip count | Why |
|---|---|---|
| `nb` | 4 | N blocks, `256 / 64` |
| `g` | 8 | groups of `R` tiles, `T / R = 32 / 4` |
| `kb` | 8 | K blocks, `512 / 64`: one `mxu.matmul {tiles = 4}`, one weight tile |
| `i` | 4 | tiles in the group (SPLU, XVU, VU), `R` |
| `q` | 64 | weight lines of a tile (SPLU, XVU) |
| NCLU | 64, 128 | 16-line loads of x (1024 lines) and w (2048 lines) |
| NCSU | 32, one per `(nb, g)` | 16-line stores of y |

So the MXU runs 256 ops, each latching one weight tile and computing 4 tiles.

**Layout.** One line is 128 bytes, 64 DLFloat16 values.

| Tensor | SHM (lines) | SP (lines from the band's base) | Lines |
|---|---|---|---|
| x | `x[kb][m]` at `X + 128·kb + m`: row `m`, K values `64·kb .. +63` | same order at `X0` | 1024 |
| w | `w[kb][nb][q]` at `W + 256·kb + 64·nb + q`: K row `64·kb + q`, N values `64·nb .. +63` | same order at `W0` | 2048 |
| y | `y[nb][m]` at `Y + 128·nb + m` | same order at `Y0` | 512 |

**Addresses.** Each unit counts in its own unit; the comments in the code use these:

| Units | Address | Unit | Step |
|---|---|---|---|
| NCLU, NCSU | `SP[%sbr + %sar : N]`, `SHM[%cbr + %car : N]` | lines | the transfer advances `%sar` and `%car` by its `N` lines |
| SPLU, SPSU | `SP[%ptr + %stride]` | bytes (a line is 128) | adds `%stride` before each line; `modlrfimm` adds an immediate in bytes |
| XVU, MXU, VU | none: registers and FIFOs | | |

### Sequential form

The SPLU's pointers start one line before the first line they read (it adds the stride before reading); the
comments give the lines each op reads and how much it moves.

```mlir
kernel @mm {
  %x  = alloc : !ptr<buffer<1024 x i1024>, #shm>              // X: x[kb][m]
  %w  = alloc : !ptr<buffer<2048 x i1024>, #shm>              // W: w[kb][nb][q]
  %y  = alloc : !ptr<buffer<512 x i1024>, #shm>               // Y: y[nb][m]
  %xs = alloc {align = 128} : !ptr<buffer<131072 x i8>, #sp>  // X0: 1024 lines
  %ws = alloc {align = 128} : !ptr<buffer<262144 x i8>, #sp>  // W0: 2048 lines
  %ys = alloc {align = 128} : !ptr<buffer<65536 x i8>, #sp>   // Y0: 512 lines

  pipeline @mm (%x, %w, %y) attributes {ncores = 1} {
    %f_sx  = fifo splu -> xvu      : !fifo<splu -> xvu, vector<64xdlf16>>
    %f_n0  = fifo xvu -> tu.north  : !fifo<xvu -> tu, vector<64xdlf16>>    // MXU weights in
    %f_ab  = fifo xvu -> absu      : !fifo<xvu -> absu, vector<64xdlf16>>  // MXU acts in
    %f_tv  = fifo tu.south -> vu   : !fifo<tu -> vu, vector<64xdlf16>>     // MXU out
    %f_vs  = fifo vu -> spsu       : !fifo<vu -> spsu, vector<64xdlf16>>
    %stage = channel nclu -> {splu0} : !chan<nclu -> splu0>               // x, then w, is in SP
    %done  = channel spsu -> ncsu    : !chan<spsu -> ncsu>                // a group's 16 y lines are in SP

    // ---- SHM -> SP: all of x and w (3584 of the SP's 32768 lines) ----
    %s0, %sb, %c0, %cb = nclu.addr_init sar = 0, sbr = %xs / 128, car = 0, cbr = %x
        : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
    %s1, %c1 = loop 64 iter(%s = %s0, %c = %c0) {
      %sn, %cn = nclu.ldmu SP[%sb + %s : 16], SHM[%cb + %c : 16] : !sar<i15>, !car<i20>   // 16 lines, 2 KB
      yield %sn, %cn
    }
    nclu.sync put %stage
    %t0, %tb, %u0, %ub = nclu.addr_init sar = 0, sbr = %ws / 128, car = 0, cbr = %w
        : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
    %t1, %u1 = loop 128 iter(%t = %t0, %u = %u0) {
      %tn, %un = nclu.ldmu SP[%tb + %t : 16], SHM[%ub + %u : 16] : !sar<i15>, !car<i20>   // 16 lines, 2 KB
      yield %tn, %un
    }
    nclu.sync put %stage
    splu.sync get %stage
    splu.sync get %stage

    %xp0, %wp0, %st = splu.reg_init %xs - 128, %ws - 128, 128 : !lrf<i32>, !lrf<i32>, !lrf<i32>
    %o0, %ost       = spsu.reg_init %ys - 128, 128 : !lrf<i32>, !lrf<i32>
    %d0, %db, %e0, %eb = ncsu.addr_init sar = 0, sbr = %ys / 128, car = 0, cbr = %y
        : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>

    %xE, %wE, %oE, %dE, %eE = loop 4 iter(%xn = %xp0, %wn = %wp0, %on = %o0, %dn = %d0, %en = %e0) {   // nb
      %xG, %wG, %oG, %dG, %eG = loop 8 iter(%xg = %xn, %wg = %wn, %og = %on, %dg = %dn, %eg = %en) {  // g: tiles 4g .. 4g+3
        %z0, …, %z15 = vu.immcopy 0 {unroll = 16} : 16 x !vu.lrf<vector<64xdlf16>>   // accumulators := 0
        %xK, %wK, %acc0, …, %acc15 = loop 8 iter(%xk = %xg, %wk = %wg, %a0 = %z0, …, %a15 = %z15) {   // kb
          // weight tile (kb, nb): SP lines W0 + 256·kb + 64·nb .. +63
          %wk1 = loop 64 iter(%p = %wk) {                                         // q
            %pn = splu.ldu consumer = %f_sx, SP[%p + %st] : !lrf<i32>             // 1 line, 128 B
            xvu.logical tu_tgt = src0 -> %f_n0, %f_sx, CONST0 {immediate = 1}    // OR 0: pass it to the MXU
            yield %pn
          }
          // the group's tiles: SP lines X0 + 128·kb + 16·g + 4·i .. +3
          %xk1 = loop 4 iter(%q = %xk) {                                         // i
            %qn = splu.ldu consumer = %f_sx, SP[%q + %st] {burst_size = 4} : !lrf<i32>   // 4 lines, 512 B
            loop 4 {
              xvu.logical ab_tgt = src0 -> %f_ab, %f_sx, CONST0 {immediate = 1}  // pass a line to the MXU
            }
            yield %qn
          }
          mxu.matmul out = %f_tv, weights = %f_n0, acts = %f_ab {tiles = 4, m_rows = 4, dtype = dlf16}
              : (!fifo<tu -> vu, vector<64xdlf16>>, !fifo<xvu -> tu, vector<64xdlf16>>,
                 !fifo<xvu -> absu, vector<64xdlf16>>) -> ()
          loop 4 {                                                               // i: tile i's 4 lines
            %a<i> = vu.fma %f_tv, CONST4, %a<i> {unroll = 4} : 4 x !vu.lrf<vector<64xdlf16>>  // LRF 4i .. 4i+3 += lines
          }
          %wk2 = splu.modlrfimm %wk1, 192 * 128 : !lrf<i32>       // next K block of this column block: +256 − 64 lines
          %xk2 = splu.modlrfimm %xk1, 112 * 128 : !lrf<i32>       // next K block of these rows: +128 − 16 lines
          yield %xk2, %wk2, %a0, …, %a15
        }
        %oK = loop 4 iter(%o = %og) {                                            // i: the group's 4 tiles out
          vu.fma sp_tgt = result -> %f_vs, %acc<i>, CONST4, CONST0 {unroll = 4}   // 4 lines
          %on2 = spsu.stu SP[%o + %ost], %f_vs {burst_size = 4} : !lrf<i32>      // Y0 + 128·nb + 16·g + 4·i, 512 B
          yield %on2
        }
        spsu.sync put %done
        ncsu.sync get %done
        %dg2, %eg2 = ncsu.stmu SHM[%eb + %eg : 16], SP[%db + %dg : 16] : !sar<i15>, !car<i20>  // 16 lines to Y + 128·nb + 16·g
        %wg2 = splu.modlrfimm %wK, -2048 * 128 : !lrf<i32>        // the same column block again: −8 · 256 lines
        %xg2 = splu.modlrfimm %xK, -1008 * 128 : !lrf<i32>        // next group: −8 · 128 + 16 lines
        yield %xg2, %wg2, %oK, %dg2, %eg2
      }
      %wn2 = splu.modlrfimm %wG, 64 * 128 : !lrf<i32>             // next column block: +64 lines
      %xn2 = splu.modlrfimm %xG, -128 * 128 : !lrf<i32>           // back to tile 0: −8 · 16 lines
      yield %xn2, %wn2, %oG, %dG, %eG
    }
  }
}
```

`%a<i>` and `%acc<i>` name tile `i`'s four VU registers (LRF `4i .. 4i+3`); an op that redefines `%a<i>` in a
loop over `i` stands for the four ops the loop unrolls into, since the VU has no register indirection
([Algorithms](#algorithms), step 7).

### Distributed form

Each unit's program is its ops of the sequential form under the same loops. Register initialization and
pointer arithmetic are as above and left out where they repeat it.

```mlir
    unit @nclu () {                                     // SHM -> SP, lines
      loop 64 { ldmu SP[%sb + %s : 16], SHM[%cb + %c : 16] }      // x: 1024 lines
      sync put %stage
      loop 128 { ldmu SP[%tb + %t : 16], SHM[%ub + %u : 16] }     // w: 2048 lines
      sync put %stage
      return
    }

    unit @splu () {                                     // SP -> XVU, bytes
      sync get %stage ; sync get %stage
      loop 4 {                                          // nb
        loop 8 {                                        // g
          loop 8 {                                      // kb
            loop 64 { ldu consumer = %f_sx, SP[%wp + %st] }                    // weight tile: 64 lines, 8 KB
            loop 4 { ldu consumer = %f_sx, SP[%xp + %st] {burst_size = 4} }    // 4 tiles: 16 lines, 2 KB
            modlrfimm %wp, 192 * 128 ; modlrfimm %xp, 112 * 128
          }
          modlrfimm %wp, -2048 * 128 ; modlrfimm %xp, -1008 * 128
        }
        modlrfimm %wp, 64 * 128 ; modlrfimm %xp, -128 * 128
      }
      return
    }

    unit @xvu () {                                      // FIFO to FIFO
      loop 4 { loop 8 { loop 8 {                        // nb, g, kb
        loop 64 { logical tu_tgt = src0 -> %f_n0, %f_sx, CONST0 {immediate = 1} }            // weights
        loop 4 { loop 4 { logical ab_tgt = src0 -> %f_ab, %f_sx, CONST0 {immediate = 1} } }  // acts
      } } }
      return
    }

    unit @mxu () {                                      // expanded only at emission
      loop 4 { loop 8 { loop 8 {                        // nb, g, kb
        mxu.matmul out = %f_tv, weights = %f_n0, acts = %f_ab {tiles = 4, m_rows = 4, dtype = dlf16}
      } } }
      return
    }

    unit @vu () {                                       // LRF 4i .. 4i+3 hold tile i
      loop 4 { loop 8 {                                 // nb, g
        immcopy 0 {unroll = 16}
        loop 8 {                                        // kb; loop i unrolled
          fma lrf_tgt = LRF0,  %f_tv, CONST4, LRF0  {unroll = 4}
          fma lrf_tgt = LRF4,  %f_tv, CONST4, LRF4  {unroll = 4}
          fma lrf_tgt = LRF8,  %f_tv, CONST4, LRF8  {unroll = 4}
          fma lrf_tgt = LRF12, %f_tv, CONST4, LRF12 {unroll = 4}
        }
        fma sp_tgt = result -> %f_vs, LRF0,  CONST4, CONST0 {unroll = 4}
        fma sp_tgt = result -> %f_vs, LRF4,  CONST4, CONST0 {unroll = 4}
        fma sp_tgt = result -> %f_vs, LRF8,  CONST4, CONST0 {unroll = 4}
        fma sp_tgt = result -> %f_vs, LRF12, CONST4, CONST0 {unroll = 4}
      } }
      return
    }

    unit @spsu () {                                     // VU -> SP, bytes
      loop 4 { loop 8 {                                 // nb, g
        loop 4 { stu SP[%o + %ost], %f_vs {burst_size = 4} }   // 16 lines at Y0 + 128·nb + 16·g
        sync put %done
      } }
      return
    }

    unit @ncsu () {                                     // SP -> SHM, lines
      loop 4 { loop 8 {                                 // nb, g
        sync get %done
        stmu SHM[%eb + %e : 16], SP[%db + %d : 16]      // 16 lines to Y + 128·nb + 16·g
      } }
      return
    }
```

Checked against the rules:

| Rule | Check |
|---|---|
| P2 | per iteration of `kb`: `%f_sx` 64 + 16 pushed and popped; `%f_n0` 64 and 64; `%f_ab` 16 and 16; `%f_tv` 16 and 16. Per `i` of the output loop: `%f_vs` 4 and 4. Per `g`: `%done` 1 and 1. Pipeline body: `%stage` 2 and 2 |
| P3 | each `put` before its `get`; per K block the data order SPLU → XVU → MXU → VU |
| P4 | x, w: written by the NCLU, read by the SPLU, covered by `%stage`; y: SPSU, then NCSU, covered by `%done` |
| P5 | NCLU → SPLU → XVU → MXU → VU → SPSU → NCSU: acyclic |
| P6 | `%f_n0`: 1 line (the MXU takes weights as they come); `%f_ab`, `%f_tv`: 4 lines (a tile at a time, against the `loop 4`s of the XVU and VU); `%f_vs`: 4 |
| P7 | VU: LRF0..15 for the group's accumulators; MXU: its own; SP: 3584 lines |

## Algorithms

The input is a pipeline in sequential form. The checks run in order; each reports the op and the rule it
breaks. The MXU is one unit throughout.

**1. Check units (P1).** For each op, record its unit. For each register, the unit of its defining op (for a loop
result or `iter` argument, the unit of the `yield` operand) must equal the unit of every use. For each FIFO and
channel, collect its push (`put`) ops and pop (`get`) ops and check that each set has one unit, the one declared.

**2. Check FIFOs and channels (P2, P3).** For each FIFO or channel `c`:

- Token count of an op on `c`: the burst times the unroll for a FIFO op (for `mxu.matmul`, its port's count), 1
  for a `put` or `get`, multiplied by the trip counts of the loops between the op and the loop being checked. A
  trip count that is a register or a JCR must be the same value on both sides (the same `%n`), or the check fails.
- For each loop that contains at least one push and one pop of `c` (and for the pipeline body), the token counts
  of pushes and pops in one iteration must be equal (P2).
- Walk one iteration of each such loop in program order, adding pushes and subtracting pops, a nested loop of one
  side counted as one step with its full count; the running sum must never go below zero (P3).

**3. Check buffers (P4).** For each `alloc` used in the pipeline, collect the ops that read and write it. An SHM
buffer must have only reads or only writes. An SP buffer must have one writer unit `W` and one reader unit `R`.
For each write followed by a read in program order, there must be a channel from `W` to `R` with a `put` between
them in `W` and a `get` between them in `R`, in the program order of each unit; for each read followed by a write
(in a later iteration of some loop), a channel from `R` to `W` placed the same way. Both channels already passed
step 2. Overlap of address ranges is decided per buffer, not per line: a buffer counts as rewritten when any loop
around its writes runs more than once. The AB is inside the MXU and not checked here.

**4. Check cycles (P5).** Build a graph with one node per unit (the MXU is one) and one edge per FIFO (pusher →
popper) and per read-after-write channel of step 3 (`W` → `R`). It must be acyclic. With P2 and P3, a cycle
would not deadlock, but the units on it could not overlap iterations, so the pipeline would drain once per
iteration.

**5. Check capacity (P6).** <a id="capacity"></a>For each FIFO, walk one iteration of the loops of step 2 in
program order as in P3 and record the largest running sum, with one change: a pop that progresses one unit at a
time (an ISA op that pops one token per beat; the MXU's `weights`) is interleaved with the pushes before it, so the
pair adds at most 1, and one that progresses a tile at a time (the MXU's `acts` and `out`) adds one tile. The
largest sum must not exceed the FIFO's depth; for a channel, the largest number of `put`s ahead of `get`s must
not exceed its counter. P2 bounds every sum by the tokens of one loop iteration, so the walk never leaves one
loop body.

**6. Check resources (P7).** Count the registers live in each unit (the MXU's are its template's), and the SP
lines of the pipeline's buffers.

**7. Distribute loops.** For each unit `u`, copy the body and keep:

- the ops of `u`, in the same order;
- every loop that contains an op of `u`, with the same trip count; a loop without one is dropped;
- the `iter` / `yield` entries whose values are registers of `u`;

then append `u.return`. A loop whose index selects a register (the VU's `loop i` over `%acc<i>`) is unrolled.

Why the result runs to completion: each unit's program is its ops in the sequential order, and by P3 every pop in
that order comes after its push, so executing the sequential body op by op is one schedule of all the units. By P6
it fits the real FIFO depths and channel counters. The units are sequential programs that block on FIFOs and
channels (a Kahn process network), whose behavior does not depend on the schedule, so if one schedule completes,
every schedule does.

**Inserting channels.** A compiler can place the channels of step 3 itself instead of checking hand-written ones:
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
            %pn = splu.ldu consumer = %f_ld, SP[%p + %st] : !lrf<i32>   // pushes the line to vu; returns p + st
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
            %p = splu.ldu consumer = %f_ld, SP[%p + %st] : !lrf<i32, 0>
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
        %pn = splu.ldu consumer = %f_ld, SP[%p + %st] {interleave_sz = 2} : !lrf<i32>
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

## Emitting the MXU

After register allocation the emitter replaces the MXU's program by three: the ABSU's, one program for the
eight ABLUs, and one for the eight TU rows. Each copies the MXU program's loops and replaces every
`mxu.matmul` by that unit's part of the template below. The MXU's registers are fixed by the template, so the
three programs come out already allocated.

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

### The template

For `mxu.matmul {tiles = n, m_rows = M}`. A **block** is one tile in the AB: its `M` x lines, of which each TU
row's AB keeps that row's 8 values (16 bytes) per line, so `M · 16` bytes per row. A row's AB is a ring of 1 KB,
64 such 16-byte lines, `64 / M` blocks. The ABSU writes blocks while the ABLUs read them; so that it never
overwrites a block not yet read, the two hand the ring over in halves:

| Symbol | Meaning | `M = 4`, `n = 4` |
|---|---|---|
| `H` | blocks in half the ring, `32 / M` | 8 |
| `NH` | halves the op's `n` blocks fill, `⌈n / H⌉` | 1 |
| `L` | blocks in the last half, `n − (NH − 1) · H` | 4 |

```mlir
// TU, every row r: latch the weights, then n tiles
%w0, …, %w7 = tu.fma_r #0, %north, #1.0 {unroll = 8}     // LRF0..7 := weight lines 8r .. 8r+7 (row 0's north is weights)
loop (56 - 8 * %r) {
  tu.fma %north, #0, #1.0 {south_tgt = src0}               // pass a weight line to the rows below
}
loop n {
  %p0, …, %p<M-1> = tu.fma_r (%w0, %w1, %w2, %w3), select(%r == 0, #0, %north), %west
                              {east_tgt = src2, dot_len = 4, unroll = M}    // K 8r .. 8r+3, into LRF8 ..
  tu.fma (%w4, %w5, %w6, %w7), (%p0, …, %p<M-1>), %west
         {east_tgt = src2, south_tgt = result, dot_len = 4, unroll = M}     // K 8r+4 .. +7; row 7's south is out
}

// ABSU: n blocks, M lines each; pointer LRF0 (bytes in a row's AB, wraps at 1 KB), stride LRF1 = 16
loop (NH - 1) {
  loop H { absu.stu AB[LRF0 + LRF1], acts {burst_en = 1, burst_size = M} ; absu.sync put %abw }
  absu.sync get %abf                                     // the ABLUs have released the half written before
}
loop L { absu.stu AB[LRF0 + LRF1], acts {burst_en = 1, burst_size = M} ; absu.sync put %abw }
absu.sync get %abf

// ABLU, every row: pointers LRF0 and LRF4 (the line's two 8-byte halves), stride LRF15 = 16
ablu.sync put %abf                                       // the half the ABSU writes first is free
loop (NH - 1) {
  loop H { ablu.sync get %abw ; ablu.ldu consumer = west, AB[LRF0 + LRF15] {…, burst_size = M} ;
                                ablu.ldu consumer = west, AB[LRF4 + LRF15] {…, burst_size = M} }
  ablu.sync put %abf                                     // this half has been read
}
loop L { ablu.sync get %abw ; ablu.ldu … ; ablu.ldu … }
```

Per op the ABLUs put `%abf` `NH` times and the ABSU gets it `NH` times, so the counts close inside the op; the
pointers carry on from op to op, so the blocks keep filling the ring in order. The ABSU's get after half `h`
takes the release of half `h − 1` (or the op's opening put), so it runs at most `H` blocks ahead. `%abw` and
`%abf` live inside the MXU and never appear in the IR.

With `n ≤ H`, as in the example, `NH = 1`: the ABSU stores its `n` blocks and gets one token, the ABLUs put one
token and read `n` blocks. Measured on the VP ([`matmul-kouter-vp.md`](matmul-kouter-vp.md)): this form with
`n = 4` and `n = 2` per op gives the right outputs in the same cycles as one half-ring handshake over the whole
run. A version that handed the AB over one block at a time, with a fixed credit, hung on the VP.

### The example, emitted

The MXU program of [the matmul example](#distributed-form), `loop 4 { loop 8 { loop 8 { mxu.matmul {tiles = 4} } } }`,
becomes:

```mlir
    unit @absu () {                                     // .lrf: LRF0 = 0x3f0 (-16: stu adds first), LRF1 = 16
      loop 4 { loop 8 { loop 8 {                        // nb, g, kb: one op
        loop 4 {                                        // its 4 blocks
          absu.stu AB[LRF0 + LRF1], %f_ab {burst_en = 1, burst_size = 4}   // 4 lines, 64 B per row
          absu.sync put %abw
        }
        absu.sync get %abf
      } } }
      absu.return
    }

    unit @ablu attributes {rows = 8} () {               // .lrf: LRF0 = 0x3f0, LRF4 = 0x3f8, LRF15 = 16
      loop 4 { loop 8 { loop 8 {                        // nb, g, kb: one op
        ablu.sync put %abf
        loop 4 {
          ablu.sync get %abw
          ablu.ldu consumer = %f_w, AB[LRF0 + LRF15] {load_type = 1, replicate = 1, burst_en = 1, burst_size = 4}
          ablu.ldu consumer = %f_w, AB[LRF4 + LRF15] {load_type = 1, replicate = 1, burst_en = 1, burst_size = 4}
        }
      } } }
      ablu.return
    }

    unit @tu attributes {rows = 8, cols = 8} () {
      %r = tu.row_id : index
      loop 4 { loop 8 { loop 8 {                        // nb, g, kb: 256 weight tiles
        tu.fma_r #0, %north, #1.0 {unroll = 8}          // latch: LRF0..7
        loop (56 - 8 * %r) { tu.fma %north, #0, #1.0 {south_tgt = src0} }
        loop 4 {                                        // 4 tiles
          tu.fma_r (LRF0, LRF1, LRF2, LRF3), select(%r == 0, #0, %north), %west {east_tgt = src2, dot_len = 4, unroll = 4}
          tu.fma (LRF4, LRF5, LRF6, LRF7), (LRF8, LRF9, LRF10, LRF11), %west
                 {east_tgt = src2, south_tgt = result, dot_len = 4, unroll = 4}
        }
      } } }
      tu.return
    }
```

`%f_w` is the ABLU-to-TU-row link (the row's west), internal to the MXU. The assembler then unrolls `%r` into the
eight TU row blocks, as in [Appendix A](#emit-time-specialization).

## Appendix A: `down_proj` as one SPMD program

Written before the MXU op: the TU, ABSU and ABLU code below is spelled out per unit. With the MXU, R1's matrix
part is one `mxu.matmul {tiles = 1, m_rows = 4}`, which [Emitting the MXU](#emitting-the-mxu) turns into the same
blocks.

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
        %pn = splu.ldu consumer = %f_sx, SP[%p + %st] : !lrf<i32>   // push w line q to xvu
        yield %pn
      }
      %q0 = splu.immcopy %xs - 128 : !lrf<i32>
      splu.sync get %stage
      %q1 = splu.ldu consumer = %f_sx, SP[%q0 + %st] {burst_size = 4} : !lrf<i32>   // x tile rows t = 0..3
      splu.return
    }

    unit @xvu () {
      loop 64 {
        // <no_ref_def> = opcode %
        xvu.logical  %f_n0, %f_sx, CONST0 {tu_tgt = src0, immediate = 1}   // OR 0: pass the w line to the TU
      }
      loop 4 {
        xvu.logical %f_ab, %f_sx, CONST0 {ab_tgt = src0 ,immediate = 1}   // pass the x tile to ABSU
      }
      xvu.return
    }

    unit @absu () {
      %a0, %ast = absu.reg_init -16, 16 : !lrf<i10>, !lrf<i10>           // 10-bit ring, -16 = 0x3f0
      %a1 = absu.stu AB[%a0 + %ast], %f_ab {burst_en = 1, burst_size = 4} : !lrf<i10>  // line t: AB_r[16t + 2i] := line_t[8r + i]
      absu.sync put %abw
      absu.sync get %abf
      absu.return
    }

    unit @ablu attributes {rows = 8} () {                                 // one program; row r reads only AB_r
      %h0, %h1, %st = ablu.reg_init -16, -8, 16 : !lrf<i10>, !lrf<i10>, !lrf<i10>
      ablu.sync put %abf
      ablu.sync get %abw
      %h2 = ablu.ldu consumer = %f_w, AB[%h0 + %st] {load_type = 1, replicate = 1, burst_en = 1, burst_size = 4} : !lrf<i10>
                                                                          // t = 0..3: (a, a), a = x[t][8r + 0..3]
      %h3 = ablu.ldu consumer = %f_w, AB[%h1 + %st] {load_type = 1, replicate = 1, burst_en = 1, burst_size = 4} : !lrf<i10>
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
      vu.fma %f_vs, %f_tv, CONST4, CONST0 {sp_tgt = result, unroll = 4}   // S_7[t] · 1.0 + 0 -> spsu, t = 0..3
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
        %g1 = splu.ldu consumer = %f_gv, SP[%g0 + %st] {burst_size = 4} : !lrf<i32>
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
[MXU](#the-mxu), defines the reduce collective the same way, and lists how to get there.

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

[The MXU](#the-mxu) folds TPU's `vmatpush`, `vmatmul` and `vpop` into one op, `mxu.matmul`;
[Example: matmul](#example-matmul) uses it and [Emitting the MXU](#emitting-the-mxu) expands it.

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
      %gn = splu.ldu consumer = %f_gv, SP[%g + %stg] {burst_size = G} : !lrf<i32, 11>   // line l of members 0..G-1
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
2. **Define the ops and their expanders.** Add `mxu.matmul` and `grid.reduce` to the machine IR
   with their types and port contracts, and expanders that emit the unit programs. Check that the expansion is
   byte-identical to mcc's output on the corpus (`bytecheck`), so the ops add no behavior.
3. **Emit them from mcc.** Let mcc produce the macros where `emit_tu.py`, `emit_ab.py` and the reduce lowering now
   emit unit templates, and let the grid IR (Appendix A) refer to them.
4. **Check pipelines.** Implement [Algorithms](#algorithms) steps 1–7 on the machine IR. It must accept the sqrt
   and matmul examples and `down_proj`'s `@r1` and `@r2`, and reject an SP accumulator (variant A in
   [`matmul-k-outer-schedule.md`](matmul-k-outer-schedule.md)) and a channel matched across loop iterations.
5. **Hardware feedback.** With the macros as the only users of the TU and AB units, measure what a matrix-engine
   command (push and pop instructions like TPU's, or loading one TU block into all rows as codesigner#2399 proposes)
   would save in instruction-buffer space and per-row copies.

Open points: whether conv and attention fit the same parameters; AB capacity when blocks lap the 1 KB ring
(`refuse_ring_lap` in `emit_ab.py`); whether accumulation across K blocks belongs in `mxu.matmul` or stays in the VU;
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
