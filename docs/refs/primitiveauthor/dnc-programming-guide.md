# DNC Programming Guide

How to program a Rebellions **DNC** (Dataflow Neural Core) from scratch: what the
machine is, what it is good at, how to map an algorithm onto it (numerics +
structure), and the method/workflow that gets a kernel from idea to silicon.

> The whole-system map is in [`architecture.md`](architecture.md), which gives the two-axis model
> (leaves/compositions/search × static/dynamic). This guide is its conceptual foundation.

This is the conceptual foundation of the PrimitiveAuthor stack: the machine,
the algorithm shapes, the mapping strategy, and the design model. The **concrete
authoring API** (the `Template` / `instantiate` / `fuse` / `chain` abstractions +
a worked Python `sqrt`) lives in
[`composable-microcode-templates.md`](composable-microcode-templates.md), which is
*re-derived* from this foundation. Read this first; then that doc for the API;
then [`correctness-proof.md`](correctness-proof.md) for the proof structure that makes
an authored kernel *trustworthy*.

> **Scope & honesty.** Three algorithm classes (elementwise, reduction,
> running-state fold) are grounded in device-proven ports. The GEMM/TU class and
> the multi-level cross-DNC barrier topology are **hardware-supported but not yet
> characterized in PrimitiveAuthor**, which is flagged inline. The defining caveat of the
> whole stack is that the value simulator (PrecSim) is *lenient* about things
> silicon *enforces*; §3.5 and §5.4 are where that bites.

---

## 1. The DNC machine

### 1.1 What a DNC is

A DNC is a **spatial / streaming dataflow engine**, not a Von-Neumann core. It is
a column of independent functional units, each running **its own private
instruction stream**, that communicate by **streaming 128-byte lines through
inter-unit FIFOs** and rendezvous via **SYNC** opcodes. There is no shared
program counter and no register file shared across units.

Topology (CR03 target, `correctness-proof.md:38-43`):
- **Chip** = 4 chiplets; **chiplet 0 hosts 16 DNCs** (chiplets 1–3 are 128-B
  stubs).
- **DNC** = 2 NCores × { 8 TU rows, 1 VU, 1 XVU, 8 AB } + shared movers.
- A **Command Processor (CP)** sequences the command stream and enforces
  inter-command synchronization.

### 1.2 Functional units

Each unit has a fixed one-hot init-ID and a fixed column (`lib/dnc_init.py:9-20`):

| Unit | Class | Role |
|---|---|---|
| **NCLU** | data-path (mover) | DRAM/SHM → SP **load**; holds uDMA descriptors in its LRF |
| **NCSU** | data-path (mover) | SP → SHM/DRAM **store** |
| **SPLU** | data-path (stager) | SP → compute-FIFO **load** (pushes 128-B lines into XVU/VU/SPSU FIFOs) |
| **SPSU** | data-path (drainer) | compute-FIFO → SP **store** (drains results to SP) |
| VU | compute | the vector unit: the FMA family, compares, converts, the reduce, the select, the logical ops and the shift |
| XVU | compute | the extended vector unit: everything the VU has plus the exponent extract, the power-of-two scale, the reciprocal-root seed, the permute and the convert. It is the transcendental and elementwise workhorse |
| TU | compute | the tensor unit, which multiplies and accumulates over 8 rows per NCore. ⚠ not yet worked here |
| **AB(LU/SU)** | compute/addr | Arithmetic/bitwise + scalar-address load/store |

> **Naming caveat (settle once).** PrecSim's decoder labels init bit `0x2`→"VU"
> and `0x4`→"XVU"; the silicon conan headers use the opposite op↔name mapping.
> **The bit in the init flit is authoritative for what physically executes**, so stamp the
> program by the PrecSim bit, not the conan name.

### 1.3 Memory hierarchy

Data flows down a strict hierarchy, and a compute unit never touches DRAM or SHM directly:

```
DRAM (per-chiplet; DRAM_INPUT / OUTPUT / INIT / INTMD / TENSOR sub-regions)
  │  NCLU (uDMA descriptor in NC LRF)
  ▼
SHM (on-chip shared memory, one global space, 128-byte lines)
  │  NCLU
  ▼
SP  (per-DNC scratchpad, addressed in 128-B lines)
  │  SPLU (LDU, ld_consumer → FIFO)
  ▼
inter-unit FIFO  (one 128-B line = one entry = one full SIMD register)
  │  VU/XVU/TU consume (srcK = 0x1 pops one entry)
  ▼
LRF (the local register file, one per unit, with 16 registers on the compute units)
  │  VU/XVU (out_sp = 3 routes result back to the SPSU FIFO)
  ▼
SP → NCSU (STMU) → SHM → DRAM_OUTPUT
```

**The universal granule:** one SHM/SP line = 128 B = 8 words × 16 B = **64 DLF16
values = exactly one VU/XVU 64-lane SIMD register**, laid out 8 slices × 8 lanes
(`../../dnc_spec/docs/splu_xvu_fifo_contract.md:19-36`). Everything you map onto the DNC is ultimately
a stream of these lines.

### 1.4 Concurrency model

- **Per-unit private streams.** Each unit fetches/retires from its own IBUFF; no
  cross-unit PC. A unit makes progress until it needs data (FIFO empty) or a
  rendezvous (SYNC).
- **FIFO communication.** One `(producer, consumer)` pair = one dedicated deque.
  FIFOs are per-NCore (`splu0` routes only to `xvu0/vu0/spsu0`); cross-NCore data
  goes through SHM, never the FIFO (`../../dnc_spec/docs/splu_xvu_fifo_contract.md:151-156`).
- **Intra-DNC rendezvous = SYNC.** A unit blocks on a SYNC SEND/RECV mask until
  its partner posts the matching half. **Every SEND needs a matching RECV** or the
  model deadlocks.
- **Cross-DNC barrier = MESYNC** (cluster-tree; §4.4).
- **SPMD over 16 DNCs.** The same per-DNC program runs on all active DNCs over a
  *partitioned* data slice; per-DNC programs differ only in their baked SHM base
  offsets (`base + n_lines·dnc`).

### 1.5 The ISA & program structure

**The init image (`init.bin`)** is a sequence of 128-bit flits, laid out
column-major so each unit's flits stack in its own column. One unit's block is an
ordered flit run (`lib/dnc_init.py`). (The bit-level format reference, covering the flit grid, the block
schema and the exact header fields, is in
[`init-bin-format.md`](../../dnc_spec/docs/init-bin-format.md).)*

| Flit | Holds |
|---|---|
| **Header** | target unit ID + section counts + the `lrf_idx[]` map |
| **SPR** | mode bits (VU/XVU saturate/rounding; movers inert) |
| **LCCR** | constant-register seeds (VU/XVU only) |
| **LRF** | register seeds; **for NC units this encodes SP/SHM descriptors (addresses)** |
| **IBUFF** | the instructions (NC/SP/AB/TU: 4 instr × 32 b/flit; VU/XVU: 2 × 64 b) |

**The authoring atom** is one instruction record:

```python
rec(unit, opcode, **fields)   # every decoder field defaulted to 0 → decode(encode(rec)) == rec
```

`make_block(...)` assembles a unit block; `build_init_bytes(blocks)` generates
every flit and lays them out, exactly round-tripping and needing no compiler.
Opcode families: movers carry
`LDMU/STMU/LDU/STU/CARREGCOPY/SXRIMM/IMMCOPY/MODLRFIMM/SYNC/MESYNC`; compute carry
`FMA/FNMS/FEST/EE/IME/LOGICAL/SHR/REDUCE/SELECT/…`. Operand tags: `0x0`=const-0,
`0x1`=SPLU FIFO, `0x10..0x1F`=LRF[0..15].

A loop opens with a loop-count instruction and the body's last instruction sets the branch-end bit to
close it. The count is a **static immediate** (`typ1_imm`) or **dynamic from JCR**
(`src0=JCR[0], dynloop=1`).

> **Balancing the loop nest, which matters on silicon alone.** On silicon the loop nest
> must balance to zero, every open matched by a close. **PrecSim
> is lenient and won't catch an imbalance**, so a PrecSim-green program can fault
> on HW. The sqrt XVU therefore emits a 3-deep prologue closed by the body's
> `be=1` + two trailing `NOP be=1`.

**The JCR register** is the one runtime-dynamic seed: initialized via
`JIMMCOPY`/`LOADJCR`, published with `SENDJCR`, read with `GETJCR`, and is the
canonical source for a dynamic loop count. It is how a single static init adapts
to a runtime parameter (e.g. number of active blocks).

### 1.6 How a kernel runs

The canonical pipeline is a Kahn process network free of deadlock: five units
running concurrently with matched FIFO counts:

```
NCLU  LDMU burst=L                          # L SHM lines → L SP lines
SPLU  MVLOOPCNT(L){ LDU ld_consumer=XVU }   # L pushes into the XVU FIFO
XVU   MVLOOPCNT(L){ FMA src0=1 (pop) → cascade → out_sp=3 (drain) }
SPSU  MVLOOPCNT(L){ STU st_producer=XVU }   # L pops from the XVU output FIFO
NCSU  STMU burst=L                          # L SP lines → L SHM lines
```

Correctness is **by construction** when push count = pop count and every SYNC
SEND has a RECV. Completion is a separate, silicon-only concern (§5.4): each
NCLU/NCSU emits a `RETURN_REBEL` MESYNC barrier before `RETURN` when >1 DNC
participates, so all DNCs quiesce together for the CP's `WaitForCompletion`. **A
a bare return passes PrecSim and hangs on hardware**, which is the largest gap between what the value
green, silicon hangs" trap.

---

## 2. Primary target algorithms

The DNC is built for dense, regular, line-streamed tensor work. Four classes,
three of them device-proven:

| Class | Worked example | Access pattern | Parallelism | Fit |
|---|---|---|---|---|
| Elementwise, a per-element transcendental | the square root | a plain chain of load, stage, compute, drain and store, with no dependence across lanes or lines | fully parallel: 16 DNCs partition the rows and 64 lanes cover each line | the best fit, being free of deadlock by construction and needing only the completion barrier |
| A reduction, masking then taking a maximum, an exponential and a sum | the tiled attention kernel | two passes over the staged lines, the first folding the maximum and the second the exponential and the sum | rows map to slices and the reduced axis to staged lines, and the fold accumulates across lines | it stresses the DNC, needing a running accumulator, double staging, a balanced FIFO and the cross-DNC barrier |
| A running-state fold, rescaling an online softmax | the recomputing attention kernel | a short chain per row, independent of the others, with no fold over the reduced axis | each row is independent, so no data crosses DNCs | moderate: it needs a balanced FIFO across several inputs and outputs, and economy in the 16 registers |
| A matmul on the tensor unit | ⚠ none worked here | a contraction on the TU | the TU is its own compute unit, which the XVU routes into | ⚠ the hardware supports it and this stack has not characterized it. The second matmul of attention is out of scope in both worked kernels, so treat the TU's access pattern and numerics as needing their own source |

**The unifying fact:** one FIFO entry = one 128-B line = 64 DLF16 = one SIMD
register (8 slices × 8 lanes). The two ways examples map a tensor onto this
register are *"rows→slices, K→lines"* (reduction) and *"rows→lanes within a line"*
(the recomp vector tile). Choosing this mapping is the first design decision of
any port.

---

## 3. Mapping strategy: the numerics

### 3.1 Working in DLF16

DLF16 = e6m9 (`sign | exp(6, bias 31) | mant(9)`). The 9-bit mantissa gives a
a noise floor near 2e-3, which is the best any kernel in this format can do.
All compute is 64-lane SIMD; an `IMMCOPY`
with `replica=1` broadcasts a scalar across all 64 lanes (else only lane 0
survives, which is a common bug).

### 3.2 Transcendentals via seed + Newton + range reduction (sqrt, worked)

The XVU computes `√x = x·rsqrt(x)`:

1. Reduce the range by exponent arithmetic, which does not change the answer and touches no mantissa
   rounding): `e = EE(x)`, `p = e&1` (`LOGICAL`), `s = e>>1` (`SHR`), then
   `r = x·2^-e·2^-p ∈ [0.5, 2)` via two `IME`.
2. Seed from the hardware's reciprocal-root lookup.
3. **Newton refinement:** `y ← y·(3 − r·y²)·0.5`, **8 iterations** (matches the
   layernorm primitive; empirically converged to the noise floor). Each step is 3
   ops: `FMA(y,y,0)`, `FNMS(r,y²,3)`, `FMA(·,0.5,0)`, `FMA(y,·,0)`.
4. **Recombine:** `rsqrt(x) = y·2^-s·2^-p` (two `IME`), then `√x = x·rsqrt(x)`
   (`FMA`, `out_sp=3` drain).

The result is 0.20% against the numpy reference under PrecSim, which is the residual of the seed and the Newton steps
at 8 iterations.

### 3.3 Cancellation-safe forms

The cascade is built from fused `FMA`/`FNMS` precisely to avoid double rounding.
The canonical case is **mask-by-substitution** (`../../dnc_spec/docs/reduction_and_mask_contract.md`):
`OM = FNMS(mask,1,1) = 1−mask`, then `masked = FMA(OM, −BIG, score)`. Kept lanes
(`OM=0`) multiply BIG by *exactly 0* → no rounding; masked lanes go to `−BIG` and
`exp` underflows to 0. **Do not** use a direct sentinel `SENTINEL + mask·(score −
the sentinel, since subtracting it rounds the score's own magnitude away in this format and the
kept lanes come out wrong.

### 3.4 Reduction numerics

Sequential line-accumulate into a running register: max via `FMINMAX(MAXACC, CUR)`
seeded at negative infinity rather than at a large negative value, so a fully masked row stays
well-defined); sum via `FMA(E, 1, SUMACC)` seeded 0. `fast_exp(x) = ICVT(c·x,
mode=7)` with `c = 2^11/ln2` (DLF16-rounded), the pre-subtract `c·(score−max)`
done in fused FNMS/FMA to match silicon's rounding path. A lane-tree `REDUCE` op
exists (8× fewer lines) but is fiddly to drive by hand and unused by the worked
example.

### 3.5 The numeric gap between PrecSim and silicon, which is the caveat that matters most

PrecSim is a **value** simulator, bit-accurate for the DNC ISA **except one
characterized gap, and it models only the value dataflow of one image,
not dispatch, sync, completion, relocation, or the package.

- **The characterized gap (dlf16 FMA):** the exact shipped sqrt microcode is 0.20%
  in PrecSim but the **same bytes** on CR03 give `√x · ~1.22`
  (`dlf16-fma-precsim-hw-gap.md`). The container/movers/reloc are proven correct
  by a three-copy identity, which is exact on the device, so the divergence lies purely in how the
  dlf16 FMA behaves on chip.
- **Scope it precisely:** the `×1.22` is tied to the **register-source Newton FMA
  in pure dlf16**. The flash_attn folds (FMA/FNMS/ICVT chains) ran **HW-correct at
  the noise floor on the device, so do not over-generalize this into every FMA in the format being broken.
- The bfloat FMA is unaffected: a round trip that stays in bfloat, casting in,
  math, cast out) is HW-correct today; a pure-dlf16 Newton is blocked until the
  register-source FMA law is characterized.
- **The "modulo ε" the proof defers:** ε splits into the algorithmic floor (visible
  in PrecSim, fully discharged) and the silicon-only dlf16-FMA deviation (named as
  an explicit open item). Never widen a tolerance to absorb it; attribute it to
  a named gap.** That is the line between honest scope and test-hacking.

What to do about it: passing under PrecSim is not passing on hardware, so budget a device debugger walk for
every new kernel.

---

## 4. Mapping strategy: reorganizing the structure

Mapping an algorithm onto the DNC is organizing it across a **stack of four
three levels of parallelism, and the rest of this section details each:

| Level | Parallelism form | Across what | Detailed in |
|---|---|---|---|
| **Composition** (distinct stages) | sequential (task) | stages, ordered by dependency | §4.5–§4.6 |
| **Within one stage** (data parallel) | **SPMD** | the 16 DNCs (partition the data) | §4.4 |
| | **SIMD** | the 64 lanes (one instruction, 64 elements) | §4.1–§4.2 |
| **Streaming** (the substrate) | **pipeline** | the units, via FIFO (NCLU→SPLU→XVU→SPSU→NCSU) | §4.3 |

Three things to keep straight: (1) **sequential is *between* stages; SPMD and SIMD
are within a stage, since a stage runs across DNCs and lanes inside itself and composes sequentially
outside, so they stack rather than being alternatives you pick one of; (2) **the
the FIFO pipeline is a distinct form running concurrently with the lane parallelism: while the compute unit
does the 64-lane math on line *i*, SPLU stages line *i+1* and NCSU stores line
*i−1*; (3) **stage-boundary sharpness tracks the composition tier** (§4.5): hard at
`chain` (a memory boundary), at SP for `restage`, soft at `fuse` (a shared-LRF
boundary). The hand-authored XVU cascade (the "leaf") is the *compute box* of the
streaming pipeline; everything above it is reusable parallelism patterns.

### 4.1 Tiling

Map the two tensor axes onto two different machine resources: **rows → SIMD
slices, K → staged lines.** A `[512,64]` problem becomes 16 DNCs × per-DNC
row-tiles, each tile a set of 128-B lines; burst ties to tile height, per-DNC
offset to tile index (`correctness-proof.md:226-236`).

**Tiling is bounded by registers, not cleverness.** The XVU has only **16 LRF
registers**. When an output set won't fit, the lever is the *staging* (re-stage to
re-read), not more registers (`reduction-cascade-on-hw.md:127-133`):

- **Multi-pass re-read (`_splu_2pass`):** NCLU-dropped SP lines *persist* (`LDU`
  reads SP→FIFO, it does not consume SP), so pass B just **resets the element
  pointer and re-issues the load, rather than advancing it.
- **On-device intermediates stay in SHM:** a value feeding a downstream on-chip op
  is simply never DMA'd out (a two-stride scheme: `cas_out_stride` what the cascade
  writes vs `host_out_stride` what crosses to host).

Burst dimensions scale with interleave/output count, hard-capped at **31** (5-bit
NC field).

### 4.2 SIMD lane layout and the FLAT/LANE_REVERSE hazard

A FIFO entry is `8 slices × 8 lanes`. The **lane-order convention** is a per-axis
tag the SP-layout checker tracks (`KernelToolchain/sp_layout_contract.py`):

| Tag | Meaning |
|---|---|
| flat | the natural order in memory, and the default for any buffer loaded from DRAM |
| lane-reversed | fully reversed on the contraction axis, which is the silicon convention for that primitive's output |
| `AGNOSTIC` | size-1 / broadcast axis |
| `UNKNOWN` | unregistered primitive |

**The hazard (silent wrong values):** a producer's `LANE_REVERSE` output feeding a
consumer's `FLAT` input zips at the byte level with *no per-primitive verification
firing*. The canonical case: `flash_attn_tiling` pairs a `FLAT` mask with a
`LANE_REVERSE` scores buffer (the matmul output convention) on the reduction axis
→ silently wrong attention. The checker (`sp_layout_contract.py:_RULES`, lift-side
`RBLN_LIFT_LAYOUT_CHECK`) is the SSOT for these contracts and is exactly the
"type-checker" the template model attaches at the producer→consumer seam.
(There is no separate spec for this, so `sp_layout_contract.py`
+ `KernelToolchain/CLAUDE.md`'s "SP-layout contract" section are authoritative.)*

### 4.3 Pipelining across units: the FIFO streaming contract

Work overlaps along the whole chain of units. The contract that governs it
(`../../dnc_spec/docs/splu_xvu_fifo_contract.md`):

| Side | Operation | Granularity |
|---|---|---|
| Producer (SPLU) | one `LDU burst=N` | pushes **N entries** |
| each entry | one 128-B SP line | 64 DLF16 = one register |
| Consumer (XVU) | one FMA `srcK=0x1` | pops **exactly one entry** per FIFO source |
| `url`/unroll(M) | M executions | pops **M entries** per source |

Routing: `ld_consumer` selects the FIFO (1=xvu, 2=spsu, 3=vu); `out_sp=3` routes
the result straight to the store unit's FIFO. One load pushes to exactly one FIFO, with no
broadcast.**

> **The rule that governs everything here: the pop order is the push order.** Reordering reads the wrong variable,
> **silent, no deadlock.** A count mismatch *does* deadlock (`PrimDeadlockError`
> after 60 s); triage by statically counting pushes vs pops per FIFO. Watch the
> LRF base pre-decrement: `LDU` updates `LRF[s0]` *after* each step, so the first
> read lands one stride past the base, so pre-decrement the seed by one stride.

Staging shapes: elementwise = one pass; reduction = 2-pass re-read; multi-input
fold = N interleaved inputs (balance total pushes = total pops, e.g. the recomp
24-push/24-pop fix for an 8-input chain).

### 4.4 Data-parallelism across 16 DNCs (SPMD)

The 16-DNC layout is not a hardware scatter. Each DNC reads its own slice by
baking `shm_base + stride·dnc` into its *own* NCLU/NCSU descriptor, so the 16
programs are a uniform-stride concatenation and the DMA-in is one contiguous block
(`container-build-guide.md:170-177`).

The cross-DNC barrier (`r100_spec/r100/r100/dnc.py`, the MESYNC/WSYNC rules) locks the DNCs in step with the first
as head: the leaves gather to the head, which broadcasts, and then
release (`2(N−1)` PSYNC packets). A cluster of barrier-armed Computes all stall at
the compute from reporting done until the last arrives, which is the completion barrier a 16-DNC kernel uses
between phases.

> **⚠ Topology under-determined above one level.** The spec models a flat,
> single-level barrier (every leaf → DNC 0). The multi-level cluster tree the
> production 16-DNC kernels actually use is documented-but-deferred; PrimitiveAuthor's
> practical encoding ("3 MESYNC for cluster heads 0/8, 1 for leaves") is validated
> only at the full 16-DNC config.

Sizing the burst: the inbound block size is the DNC count times the extent, and not a constant, so hardcoding one
single-DNC size silently corrupts a 16-DNC reduction). Multi-output: lay regions
contiguously so one DMA-out + one host op covers them.

### 4.5 Composing stages: fusing, restaging and chaining

When an algorithm has several stages (elementwise → reduction → fold, or a matmul
feeding a softmax), they stitch at one of **three tiers**, distinguished by *where
the inter-stage intermediate rests* (§1.3) and *how many Compute commands it
costs*:

| Tier | Stages separated by | # init segments / Computes | Bounded by |
|---|---|---|---|
| **Fuse** | LRF register handoff | **1** | 16 LRF registers |
| **Intra-Compute restage** | an SP/SHM round-trip *inside one program* | **1** | SP capacity + IBUFF instr count |
| **Chain** | a cross-Compute SHM/DRAM handoff | **multiple** | SHM/DRAM + dep-slot orchestration |

- Fusing puts the stages in consecutive instructions on one compute unit, and the
  intermediate is an LRF register that never leaves the unit. Smallest, fastest;
  capped by the 16-register file.
- Restaging inside one compute drains the producing stage to the scratchpad and has the
  consuming stage re-reads it (SPLU re-stage), all *within one init segment*. The
  2-pass reduction (`_splu_2pass`, §4.3) is exactly this: `flash_attn_tiling`'s
  mask + max + exp + sum (elementwise + two reductions, with a reduction-barrier
  between) is **one Compute**. A reduction-barrier (downstream needs the reduced
  scalar) forces a restage but **not** a new command.
- Chaining uses a second compute, handing off through SHM, which persists across
  Computes; §4.4) or DRAM_INTMD, ordered by dep-slots.

**What forces a second Compute command** (when restage is not enough):

1. The instruction-buffer ceiling: a compute unit's buffer caps at 128 instructions
   (>128 → a 504; container-build §5.8); movers at 256. A program too long to fit
   must split. The most common forcing function.
2. An exchange of data across DNCs: if a stage needs each DNC to read data another
   DNCs produced (a reduction over a DNC-partitioned axis, then redistribute), the
   all-finished barrier + re-DMA can't be expressed by one segment's *baked*
   its own mover descriptors, which is the natural compute boundary.
3. A different dispatch granularity: a large matmul with its own tiling
   (why full flash splits QK^T / softmax / P·V).
4. An overflow of the registers or the scratchpad, where even a restage cannot hold the working set.
5. **Data-dependent structure** the static init can't encode (JCR covers dynamic
   *counts* within one segment, §1.5; this is only for data-dependent *shape*).

**Decision rule:** prefer one Compute (fuse, then restage) until a wall; the first
walls are usually the **128-instruction IBUFF budget** and **cross-DNC movement**,
*not* SHM capacity. The cost gradient LRF → SHM → DRAM (§1.3) is the price of each
boundary, so keep the intermediate as high up the hierarchy as it fits. (Orthogonal
overhead: any MESYNC-bearing multi-DNC kernel needs ≥3 Computes for completion
regardless, which is the rule about flanking a compute, and that is fixed independently of the stage
count.)

### 4.6 Four worked decompositions, one per algorithm shape, from the top down

The nesting is always *mapping outermost, numerics innermost*, but the
**algorithm class (§2) fixes the shape of the mapping (L1–L3)** while the **leaf
(L4–L5) is the per-op hand work.** Four worked shapes:

The square root, an elementwise op, which is the simplest case.
```
√x = x·rsqrt(x)
└ L1 partition ELEMENTS across 16 DNCs        (embarrassingly parallel)
  └ L2 one line = 64 elements in the SIMD register; loop the DNC's lines
    └ L3 a single pass, with no barrier and one input and output
      └ L4 per-line: range-reduce → FEST seed → 8× Newton → recombine
        └ L5 EE / SHR / LOGICAL / IME / FEST / FMA / FNMS
```
Mapping is trivial; all depth is in the leaf, which is cheap → fuses in one Compute.

A Lambert W, elementwise with a heavy leaf. This is a design projection rather than worked code.
```
solve W·e^W = x
└ L1–L2 identical to sqrt (partition elements; SIMD line-loop)
  └ L3 a single pass, but watch the 128-instruction buffer cap
    └ L4 per-line: region-seed (SELECT-blended) → 2–3× Halley
      └ L5 each iter = exp (ICVT) + reciprocal (FEST+Newton) + FMAs
```
Same *shape* as sqrt, but the leaf is heavy enough that its **own instruction
count can force a restage or a chain, which is the first case where the composition tier is
driven by leaf size, not cross-stage structure. Region seeding is per-lane
`SELECT` (SIMD can't branch); the reciprocal step rides the dlf16-FMA gap (§3.5)
and likely needs the bf16 round-trip.

The tiled attention kernel, a reduction.
```
softmax stats over a masked [rows × K] tile
└ L1 partition ROWS across DNCs               (keeps the K-reduction DNC-local)
  └ L2 rows → SIMD register, K → a line-loop
    └ L3 TWO passes (reduction barrier): A = max, B = exp + sum
      └ L4 per-K-line: mask / exp + one fold step (FMINMAX / FMA)
        └ L5 FNMS / FMA / FMINMAX / ICVT / EE / IME
```
Mapping carries the structure; the reduction barrier resolves to a 2-pass
**restage** in one Compute.

The recomputing attention kernel, a running-state fold.
```
fold a new block's (max, sum, attn) into running state
└ L1 partition ROWS across DNCs               (each row independent → no cross-DNC sync)
  └ L2 rows → a per-row loop; head_dim=128 → 2 chunks / attn
    └ L3 a single pass with no barrier, marshalling eight inputs and three outputs
      └ L4 per-row: α = exp(Δmax); sum = α·sum_old + sum_new; attn = α·attn_old + attn_new
        └ L5 FNMS → ICVT → FMA → FMA (×2 chunks), ≤ 16 LRF
```
No barrier; one Compute bounded by register pressure (the 8 inputs), not a restage.

**The pattern across all four:**

| | mapping (L1–L3) | where the depth is | what forces the tier |
|---|---|---|---|
| the square root | none | a cheap leaf | nothing, so it fuses |
| `lambertw` | none | leaf (**heavy**) | **leaf footprint** (IBUFF / LRF) |
| `tiling` | reduction barrier | mapping | cross-stage **barrier** → restage |
| `recomp` | multi-input fold | mapping | register pressure |

Two conclusions. First, the class of algorithm fixes the mapping skeleton: an elementwise op
→ SPMD-over-elements + line-loop + single pass; reduction → SPMD-over-rows +
a loop over the reduced axis and a restage, and a fold gets rows across DNCs, a per-row loop and several
inputs, so the three levels are
reusable per class and the leaf is the only per-op hand work; (2) **the
composition tier is forced by *either* cross-stage structure (a barrier, a
cross-DNC reduction) *or* the leaf's own footprint**, so you cannot pick
fuse/restage/chain without knowing both the class *and* the leaf's
instruction/register cost.

**These classes are reusable *defaults*, not a closed taxonomy.** They capture the
common shapes; an algorithm with a novel or *composite* structure gets a
a top-level composition the user authors, by orchestrating the same
mechanisms (SPMD / SIMD / restage / chain) with class skeletons and leaves as
sub-pieces. Full flash attention is the example. Its top level, the online-softmax loop over each block
of the reduced axis, is not any single
class; it is a custom composition that *uses* `tiling` and `recomp` as sub-pieces.
So the two hand-authored ends are the **leaf** (the cascade) and the **top-level
composition** (when novel); the class skeletons are the mechanizable middle someone
already wrote down.

### 4.7 The design model (synthesis)

Putting §4.1–§4.6 together: a kernel is a **tree**.

- The internal nodes are composition operators: fusing, restaging and chaining, plus
  loops (§4.5). They orchestrate how stages relate in time and where each
  intermediate rests (LRF / SP / SHM-DRAM).
- The leaves are compute cascades, which is the per-stage arithmetic on the compute units
  box of the streaming pipeline).
- The edges are the mapping: each leaf becomes a running stage through the mechanizable
  middle: SPMD × SIMD × the FIFO pipeline (§4.1–§4.4), through the per-class
  skeleton (§4.6).

So a kernel has **two hand-authored ends around a mechanizable middle**:

- The first hard part is the top-level composition, which is the tree's shape: deriving a correct
  (sound dependency/sync DAG; a barrier where a reduction feeds downstream; a
  cross-DNC combine where a reduction crosses the partition) and *optimized*
  (put each handoff as high in the hierarchy as it fits, keep a reduction inside one DNC,
  fewest boundaries; all three parallelism axes saturated; within the 16-LRF /
  128-instr budgets) orchestration. A class skeleton for common shapes; a
  user-authored composition for novel/composite ones (§4.6).
- The second hard part is the leaves, which is the numerics: the range reduction, the seed and its iteration,
  cancellation-safe forms, the dlf16-FMA gap (§3). Authored once per primitive,
  then reused.
- The middle, meaning the three levels of parallelism, the class skeletons, the framing and the choice of
  tier, is mechanizable.

**Composition is the key, but it co-designs with the leaves.** "First compose,
then map" is the *forward* direction: given a fixed tree, the mapping drops out
mechanically. Arriving at the tree, though, is a co-design loop, since a boundary's
placement depends on a leaf's footprint (its instruction count, set by the SIMD
layout, decides whether a stage fuses or has to restage, as the Lambert W case in section 4.6 shows).
Which end dominates depends on regime: with a **mature leaf library**, new
algorithms are almost entirely composition work; **growing the library** is
leaf-authoring.

Where a runtime-variable count sits: it is not a new kind of node but a
**static/dynamic attribute on a *loop node*** (trip baked at instantiate, vs
supplied at runtime from `JCR[0]`; §1.5). Loops live at two levels, so it has two
homes: on a **leaf's inner loop** → the leaf is trip-polymorphic (a minor
authoring extension; the movers/DMA must also size to N), or on a **composition
(outer) loop** → a property of the tree's shape (HARD #1), realized by a JCR outer
loop with dynamic addressing or by the CP's CTRL_FLOW / `const_buf`-gated
command-walk. The deep tie: the **running-state fold is the structural enabler of
such a count over a reduction axis, since it keeps the memory bounded so the count can be
runtime-variable, and the fold's outer loop is exactly where dynamic-N lives
(paged or flash attention). One caveat: everything proven here is static;
the JCR-seed handshake is the least-exercised path.

### 4.8 Dynamic shape (eager mode): online mapping and where the decision lives

> The essence of eager mode is **dynamic shape**; this section is really about the
> static↔dynamic spectrum. Which *application framework* carries the dynamic
> control flow (the command stream's `const_buf` vs a native C/C++ kernel) is
> [`kernel-programming.md`](kernel-programming.md).

Sections 4.1 to 4.7 assume instantiation ahead of time, where the shape is known, so
re-run `lower_*` per shape offline. **Eager mode** breaks that: the shape arrives
at call time and you cannot compile per call. The job becomes *project a runtime
shape onto pre-populated templates with as little online work as possible, which means running the tree of section 4.7
mechanizable middle (shape → mapping) at runtime, **not** the leaf authoring.

What is offline against what is online: the arithmetic and the shape of the artifact are offline, and only the
*parameters*, and (for composite ops) the *composition choice*, are online:

| Offline (populate once) | Online (per call) |
|---|---|
| the leaf(s) (cascade × dtype), the class skeleton, and either a fully-dynamic-tile `init.bin` or a small instance cache | tiling / partition of the runtime shape, DMA sizing, `MM_A` / `JCR`, dispatch count, and (composite ops) *which* composition to use |

Where the online decision lives, meaning the runtime bind times, now exercised
online, form a **host → CP → microcode** spectrum:

| Decider | Decides | Cost / limit |
|---|---|---|
| the host runtime | anything: the tile plan, the transfer sizes, selecting or compiling an instance, and emitting the whole command stream | the most flexible, at the cost of per-shape host logic, which a cache from shape to plan amortizes |
| the command processor | data-driven dispatch through its control-flow op and a constant buffer, looping over a runtime tile count | no host round trip per step, but limited to what in-stream control flow can encode, and less validated |
| **microcode** (DNC) | the loop trip (`JCR`, §1.5) + dynamic addressing | finest grain; counts / addresses only; unvalidated frontier |

The further down a decision is pushed the cheaper each call becomes, and the more it has to
be pre-encoded as data, and the less flexible.

**The decision locus migrates with composition-dependence** (across §4.6's ops):

| Op | runtime-varying | composition online? | online decider |
|---|---|---|---|
| `sqrt` | element count | no | **host** (tile + size) |
| `lambertw` | element count | no | **host** (heaviness / dtype absorbed offline) |
| `flash_attn_tiling` | rows × K | **yes if K large** (single-pass vs blocked + fold) | host + **CP loop over K-blocks** |
| the recomputing kernel and full attention | a variable number of blocks | yes: the fold loop is the composition | a runtime count driven by the command processor, with a host buffer and the microcode register |

So the two elementwise kernels are resolved on the host, their composition being trivial: emit a
fully-resolved stream per shape, cache by shape). `flash_attn_tiling` adds a real
online *composition* decision: `burst ≤ 31` caps K per load, so **large K forces
tiling the reduced axis into blocks and folding, which is the online-softmax loop of section 4.6, and the host
picks the block count and the **CP loops** over blocks. Full attention's trip (N
blocks) is intrinsically runtime-variable, so it is **CP-driven dynamic-N** with
the running state in a host-placed buffer and the per-block index seeded into
`JCR`.

**Honesty caveat.** The **host path is the proven one**; the **CP loop
(`CTRL_FLOW`/`const_buf`) and microcode `JCR` are the unvalidated frontier**
(the paged-attention value gate exercises them, but with a golden-selected
`JCR := T1` and no byte-exact oracle here), and the **TU matmul is
uncharacterized** (§2). So a first eager implementation should host-resolve as
much as possible and cache by shape; only attention with large/variable K *forces*
the CP/microcode path, because it cannot be fully host-resolved without a block
loop.

---

## 5. The programming method / workflow

### 5.1 The proof-structured method + the §7 checklist

The method (`correctness-proof.md`) is a proof: Theorem → Lemmas → leaf
obligations, each discharged by a named oracle. It factors into two separable
halves:

- **L-LIVE** (does it run to its terminator with valid memory): L-PARSE, L-RELOC,
  L-SYNC, L-DISPATCH.
- **L-FUNC** (given it runs, are the right bytes computed/moved): L-PLACE, L-IN,
  L-COMPUTE, L-OUT, L-NUM.

The **§7 algorithm-agnostic checklist** discharges these in order, each naming its
oracle: author the package spine (byte-exact vs a topology-matched reference) →
enumerate every dereferenced address and author DRAM (tag1) + SHM (tag3) reloc →
author the producer→Compute→consumer→EOCS wait DAG → determine the dispatch shape
(the flanked-Compute rule) → prove per-DNC tiling is a partition → author movers
(decode-diff vs a reference + a copy-chain identity control) → implement math in
XVU (bit-exact in PrecSim vs an op-mirror) → state `ε_alg` and attribute device
residual to a named gap.

Two recurring disciplines: **own no math** (import the primitive reference verbatim
as SSOT so you can't drift) and **climb in de-risking order** (get the riskiest new
idea green first).

### 5.2 The order to check in: the cheapest oracle first

| Step | Oracle | Cost | Answers | Blind to |
|---|---|---|---|---|
| 1 | codec round-trip (S/R/C) | free | field at right bit/width | wrong *value* in a right field |
| 1 | structural byte-exact vs a **topology-matched** donor | free | structural fields match a known-good file | context-dependent fields (the byte-exact trap) |
| 2 | PrecSim value gate | free | the microcode computes the intended math | any silicon-only deviation |
| 3 | real loader parse (`load_meta`) | free | the `.rbln` parses | case-insensitivity vs device |
| 4 | SoC sim (gem5 fork) | offline | dispatch / SYNC / completion | no IOMMU → can't see SMMU faults |
| 5 | the device with its debugger and firmware log | a timeout locks the chip | completion, the actual numbers, and faults in the scratchpad or the memory unit | nothing: it is the ground truth, though a coarse one |

Spend the device **only** on the irreducibly-silicon obligations (L-DISPATCH,
L-NUM). **The byte-exact trap:** a structural gate proves a field right *only if
the reference shares your topology* (same buffer set / Compute count / SHM-endpoint
count and the host's I/O arity, rather than the same shape and type); otherwise a passing check copies
the donor's context and hides the bug. Use **bisection** to turn one coarse device
bit into a localized claim.

### 5.3 The container-build path

A `.rbln` is four authored artifacts wrapped in one file
(`container-build-guide.md`): **init.bin** (L-COMPUTE), **command stream**
(L-SYNC), **package/host-graph** (L-PARSE), **reloc table** (L-RELOC). The 6-step
sequence: microcode (16 DNCs at uniform stride + the RETURN_REBEL barrier +
HW-proven SP staging) → command stream (`Cs_Hdr · uDMA · DMA-in×n · Compute×N ·
DMA-out · Nop`, the completion handshake chain) → reloc (tag1 DRAM + tag3 SHM,
both required; init reloc is a **byte** offset) → package (buffers + the authored
host-op bridge routing device output through an identity HOST op) → assemble +
seal (reloc bit-offsets computed from the *encoded* cmd so they can't drift) →
device.

The converged recipe in one line: **16 DNCs + RETURN_REBEL MESYNC barrier +
3-Compute flank + tag1/tag3 reloc + HW-proven movers + authored host-op bridge +
all-4-chiplet dispatch.**

### 5.4 The common walls

The dominant wall is the **504** (`SYS_TASK_ABORTED … Failed to
a timeout waiting for completion, which appears in four guises: a barrier hang with no
RETURN_REBEL), SMMU fault (missing tag3 reloc), lone-Compute (no downstream
Compute to complete the MESYNC), and IBUFF overflow (>128 compute instr / >256
mover). A timeout locks the device and needs a soft reset, so run device probes one at a
time.

- **One-vs-multi-compute completion:** a 16-DNC MESYNC-bearing Compute completes
  only as the middle compute of three, with a setup before it and a
  done-poster after (`[copy][op][copy]`). The prior Compute's content is irrelevant.
  ⚠ This is not universal, since an existing kernel is a lone compute that does run. It is a
  property of the MESYNC-bearing segment, established empirically (firmware-internal,
  not spec-derived).
- PrecSim is more lenient than the hardware, and the rule that follows is to separate validating the value from
  STAGING validation.* PrecSim does not model `burst_sz` (it advances the FIFO by
  `MVLOOPCNT` trip count alone), the loop-nest/IBUFF cap, WSync/completion,
  dispatch, reloc, or SMMU. **Keep the XVU byte-identical between the PrecSim
  value check and the hardware segment, letting only the mover style differ. That is why
  the flash cascades landed first-device-try.
- **Debugging on silicon:** `cdb` is cid-granular (arm the breakpoint *first*, then
  launch, so if the count stalls, the next command is the faulting one). The firmware log is finer and names
  the faulting engine + descriptor + fault type + IOVA via SMMU events. `soft_reset`
  after every run.

---

## 6. From this guide to the microcode-template model

The template model (`composable-microcode-templates.md`) is the *engineering
consequence* of this guide, re-derivable from it:

- **The 7 components** are exactly the program structure of §1.5–§1.6 grouped by
  who varies them: the compute cascade (§3.2, hand-authored), its constants (§3.1,
  dtype-bound), the data-movement/staging (§4.3, the mover skeleton), iteration
  (§1.5 `MVLOOPCNT`, static or JCR), the two sync layers (§4.4 MESYNC intra-DNC +
  the command-stream completion handshake of §5.3), placement/topology (§4.1/§4.4
  SHM stride), and framing (§1.5 flits).
- **Instantiation** is §4.1 with the shape (`n_lines`) and placement (SHM bases,
  SP plan) lifted to parameters; `build_init_bytes` is the engine.
- The type checker is the layout contract of section 4.2, which is the producer-to-consumer
  layout gate.
- **The hard seam** is §5.4's rule: the *math* (compute cascade) is the irreducible
  a hand-authored leaf, validated through the checks of section 5.2, and everything else
  (placement, framing, iteration, container) is mechanizable glue.
- Fusing against chaining are the composition tiers of section 4.5, where fusing covers
  the single-Compute tiers (LRF handoff, and intra-Compute SP restage), `chain()`
  the cross-Compute SHM/DRAM handoff; the tier boundaries (16 LRF, the
  128-instruction IBUFF cap, cross-DNC movement) are what force a `chain`.

So: this guide teaches you to author and bring up a single DNC kernel; the template
model is how you make those validated kernels reusable and composable afterward.

---

## Sources

This guide synthesizes the PrimitiveAuthor corpus; consult the originals for depth:
- Machine/ISA: `lib/dnc_isa.py`, `lib/dnc_init.py` (the spec).
- FIFO/streaming: `../../dnc_spec/docs/splu_xvu_fifo_contract.md`.
- Numerics: `docs/correctness-proof.md`, `docs/dlf16-fma-precsim-hw-gap.md`,
  `../../dnc_spec/docs/reduction_and_mask_contract.md`, `docs/precsim-to-hw-gaps.md`.
- Structure/parallelism: `docs/reduction-cascade-on-hw.md`,
  `KernelToolchain/sp_layout_contract.py`, `r100_spec/r100/r100/dnc.py`.
- Method/workflow: `docs/correctness-proof.md` (§7), `docs/container-build-guide.md`,
  `docs/one-vs-multi-compute-completion.md`, `docs/cdb-debugging-cr03.md`.
