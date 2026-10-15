# The DNC ISA as interpreted: a bottom-up semantics reference

This file records the DNC ISA semantics **as derived by the matmul/sqrt interpretation
passes**: for each unit, what its instructions/fields *mean*, read off the bit-accurate
PrecSim model and corroborated by the byte-exact / bit-exact gates. It is the **bottom-up
seed of a DNC spec. Accumulated leaf by leaf, it should eventually feed, and be
reconciled against) the top-down `r100_spec/r100/r100/dnc.py`
(promotion into the specification is a separate, deliberate step, so do not write into that
tree casually).

It is **derived, not invented**: every entry cites where it is read from (`prec_sim_*`
`file:line`) and which gate corroborates it. It complements, and does not duplicate, the
conceptual [`dnc-programming-guide.md`](../../PrimitiveAuthor/docs/dnc-programming-guide.md) and the unit-specific
[`splu_xvu_fifo_contract.md`](splu_xvu_fifo_contract.md).

## How to read an entry: what each status means

Every fact carries a status, mirroring the proof's discharge kinds
([`correctness-proof-matmul.md`](../../PrimitiveAuthor/docs/correctness-proof-matmul.md)):

- Interpreted: derived from the PrecSim ISA model, which is the strongest status. The TU's
  operand routing). Provenance = `prec_sim_*:line`.
- A trusted primitive: an irreducible seam that is named and trusted rather than derived
  (validated separately against PrecSim/VP). The leaves below.
- An inherited residual: not modelled, or not faithfully modelled, by PrecSim, and carried to silicon
  by byte-identity (Ax-REBEL). Named so the gap is explicit, never hidden.

---

## 1. Trusted primitives (the irreducible seams)

These are the DNC's axioms, the base cases every interpretation bottoms out at.

- **(Ax-FMA)** the single TU MAC: `tu_fma(x,y,z) = z ⊕ (x⊗y)`, `⊗` = dlf16 multiply,
  the accumulate is at FP18, the TU's accumulator being that format (`fp.h:259`),
  `tu.cpp:44-127` `Z_tile`). `prec_sim_isa.cpp:9` (`tu_fma_0`) → `fpu.cpp:798/883`
  (`type2_op<FMA>`: `x*y+z`). The psum is **carried/drained on a 24-bit field** and the
  and the vector unit finishes it at FP24 (`fp.h:285`, `vu.h:26-27`), rounding to
  dlf16 **only at the drain, once**. So: TU accumulates FP18; VU drain = FP24 → dlf16.
  *Validated bit-exact vs PrecSim/VP.*
- **(Ax-SRC1)** the TU `src1` selector→source decode: `0xF` ↦ the zero constant (fresh
  psum), `0xD` ↦ the north-neighbour column's psum (the systolic chain). `constr_tu.py:87-89`.
- **(Ax-XFER)** a load/store is a **descriptor-addressed byte identity**: it copies the
  the lines its source address names, resolved through the address map, to its destination,
  `sp.buf[wr] = shm.buf[rd]` (`prec_sim_process.py:434-470`, NCLU; analogous for SP/AB).
  The address arithmetic (LRF `SAR/SBR/CAR/CBR`, the NC TLB at `:400`, `burst`) selects
  *which* lines; the transfer itself adds nothing. *The transfer leaf.*
- **(Ax-SYNC)** a `SYNC`/`MESYNC` with imm `T` decodes to a direction (`bit0=put`,
  `bit1=get`) + a target (`handle_sync`, `prec_sim_process.py:377-397`); the actual
  **ordering** is enforced by the packet scheduler (`prim_model.run_solve`, which
  "terminates on completion or deadlock"), not by the ISA handler (which is a logging
  stub). So: *topology* is decodable, *deadlock-freedom* is the scheduler's, and
  *silicon race-freedom* is an **inherited-residual** (Ax-REBEL). *The sync leaf.*

> Retired: the axiom about the TU's routing. That routing is now derived
> (see TU §2 below), not assumed; it was demoted from axiom to corollary by
> `proof_lcompute.interpret_within_column`.

---

## 1.5 The matmul pipeline (units in dataflow order)

The per-unit sections below are a *catalogue*; in the matmul they chain into one
`SHM → … → SHM` loop **per DNC**, run independently on all 16 DNCs (each owns a 4×64 tile),
then coordinated once at the end by MESYNC. The flow (and which §each is interpreted in):

1. The NC load of section 5 fetches this DNC's four rows from SHM into the scratchpad at its own offset, which is the placement map.
2. The AB load of section 4 fetches the other operand and broadcasts it, the same value to every DNC, into staging.
3. The staging step moves the scratchpad into the TU's input FIFO with the lane alignment its granule and rotation fields set.
4. The TU of section 2 runs the eight-row systolic MAC over the tile, which is the reduction.
5. The drain of section 3 casts the partial sum down to dlf16 and routes the result out.
6. The store of sections 4 and 5 moves the FIFO into the scratchpad and then into SHM, at this DNC's slice of the output.
7. The barrier of section 6 has the 16 DNCs rendezvous so that the dispatch finishes as one.

**Completion, not reduction.** At `K ≤ Tin` (`psum_depth = 0`) the 16 tiles are disjoint and
already complete, so the barrier at step 7 is one of completion and carries no data, rather than a
cross-DNC reduction. A `K`-split (`psum_depth > 0`) would instead use the sync fabric to
combine partial sums as a reduction tree, which is the open frontier and is absent at these shapes.
(Reader-facing walk of this pipeline + the barrier: the matmul reading guide, *Picture C*.)

---

## 2. The TU, which is the systolic MAC  ✅ interpreted

Geometry: 8 systolic rows (the K-segments) × 64 lanes (N) × a 4-row (M) tile (`Tr=4`);
`Tin=Tout=64`. (`src/threads/tu.h`.) The FMA's operand roles are **not** in declaration
order, read off the array wrapper at `prec_sim_isa_arr.cpp:65-89`:

| field | role | values seen / meaning | provenance |
|---|---|---|---|
| `src0` | the first multiplicand | four consecutive registers, holding four consecutive values along the contraction | isa_arr.cpp:65-68 |
| `src2` | **in_y** (multiplicand B) | `0x2`=west (the streamed B), lane-addressed | isa_arr.cpp:75-85; constr_tu.py:92 |
| `src1` | the accumulator | a fresh zero, or the north neighbour's partial, which is the chain | isa_arr.cpp:88; constr_tu.py:87-89 |
| `run_mode` | products per FMA | `>1` un-masks x2,x3 ⇒ **4 products** (`tu_qfma`) | prec_sim_isa.cpp:18-33 |
| `tgtrf` | LRF write target | `8` = the accumulator slot; `0xF` = none | prec_sim_process.py:2548 |
| `tgts` | south/store target | `3` = drain result south (→ next row / → VU at row 7) | prec_sim_process.py:2551-2565 |
| `tgte` | east/FIFO target | `2` = src2 east | prec_sim_process.py:2550 |
| `url`/`urldeg` | unroll + per-operand increments | `url = (unroll<<3)|(tgt_inc<<2|s1_inc<<1|s0_inc)` | prec_sim_process.py:2542-2577 |
| the drain | the rounding down to dlf16 | forced on the last row's draining FMA alone, so the rounding happens once, at the drain | prec_sim_process.py:2666 |

**Derived behaviour (the matmul leaf), all on the *generated* microcode:**
- Within a row there are two compute FMAs, each giving four products, whose first operand is the first four registers
  then `LRF[4..7]` ⇒ **8 K-values, 4+4**, `in_y`=west, accumulated onto the psum.
  (`proof_lcompute.interpret_within_column`.) This is what retired Ax-BILINEAR.
- Across rows the accumulator selector is a fresh zero on row 0 and the north chain on the rest, so
  `psum_after = ⊕_{j=0}^{7} P_j` in left-assoc order. (`proof_lcompute`, symbolic.)
- The drain reads its accumulator from the register the chain proved, so
  the value stored downstream *is* the chained psum. (`check_drain_reads_accumulator`.)

Corroborating this: the within-column probes are bit-exact, with an identity operand returning the other unchanged, which is the
staged operands carry the right A,B); `execution_gate` (mean_rel ≈3.4e-4).
**Residual:** the per-term FP magnitude (L-NUM) and silicon numerics (Ax-REBEL); the
single MAC is Ax-FMA.

---

## 3. The vector units, which drain the partial sum  ✅ the ops are interpreted and the operand plumbing corroborated

The TU drains its psum south (`tgts=3`) → VU at row 7 on a **24-bit field** (the FP18
accumulator widened for transfer); VU/XVU then finish it in `DlFloat24` (FP24) and round to
dlf16. Interpreted against `VUProcess`/`XVUProcess` (`prec_sim_process.py:1296/1933`):

| field/op | role | provenance | status |
|---|---|---|---|
| the operands of an FMA on these units | they follow the field order, unlike the TU's | prec_sim_process.py:1658-1660 | interpreted |
| the wide accumulator path | the FP24 partial arrives as a 16-bit half and an 8-bit one, assembled, which is what the TU drains | the simulator's own assembly of the two halves | interpreted |
| `roundup_24b = is_lrf_tgt` | write-to-LRF keeps 24b; write-to-**output** rounds to 16b ⇒ the **FP24→dlf16 round-once** happens here (the VU-side view of Ax-FMA's final round) | prec_sim_process.py:1668 | interpreted |
| `out_sp` / `out_tu` / `out_ab` | result destination select (`data_type` routes result/src to SP / TU / AB FIFO) | prec_sim_process.py:1606-1622 (output dict) | interpreted |

Derived: the three drain ops, all now read off the ISA.
- The vector FMA that stores out multiplies the wide partial by a splat of one
  ⇒ **stores the rounded dlf16 result to SP**: the FP24→dlf16 **cast**.
- The vector compare tests equality (`vu_fcmp`,
  `prec_sim_isa.cpp:300` → `fpu.cpp:963-1001`) producing a `0`/`0xffff` mask + `cmp_flag`.
  It guards on a comparison, likely for a special value, rather than clamping,
  correcting the earlier guess.
- The two logical ops on the extended unit are bitwise ORs (`fpu.cpp:1955`) of two
  operands, routed to the **TU** (`out_tu`, instr 3) and the **AB store path** (`out_ab`,
  registers. They are a guarded merge that forwards the drained data rather than a lane permute,
  since the per-lane ramp is data rather than this op's operand, which corrects an earlier guess.

**Residual (narrowed to dataflow wiring, corroborated end-to-end):** *which* runtime values
populate the VU/XVU `LRF` operands (the FCMP's `cmp_flag` has no in-program `SELECT`
consumer; the XVU OR reads `LRF[1]/LRF[10]`, filled at runtime from the drain FIFO, not the
authored constants). The *ops* are interpreted; the exact operand *plumbing* is confirmed
by Probe-I/IT/1 (bit-exact through VU/XVU) rather than traced. **Trusted base:** Ax-FMA (the
cast's MAC) + Ax-XFER (the SP/AB store).

## 4. The SP and AB units, which stage and transfer operands  ✅ interpreted

Data-movement movers; all are Ax-XFER (descriptor-addressed transfers) wrapped in
address-setup + a dynamic loop. Read off the unit processes:

| op | unit | effect | provenance |
|---|---|---|---|
| the load | the ABLU | it loads operands from the bank at the granule its type field sets, and its splat flag broadcasts one value across the lanes, which is how the second operand is broadcast, into the scratchpad or the FIFO | prec_sim_process.py:1142-1200 |
| `LDU` | SPLU | read SP at the descriptor addr, apply `ld_type`/`ld_rot` **sub-line alignment** (the lane layout), **push to the compute FIFO** (`ld_consumer`) | prec_sim_process.py:685-725 |
| `STU` | SPSU | **pop the unit FIFO** (`st_producer`) → **write SP** at the descriptor addr | prec_sim_process.py:1029-1090 |
| `LDSTU` (store) | ABSU | store the SP result back out | prec_sim_process.py:1241+ |
| `IMMCOPY` / `MODLRFIMM` | SP | set an LRF descriptor / **advance the address pointer each pass** (the per-pass delta `sp_movers` scales) | prec_sim_process.py (sp sim) |
| `JIMMCOPY` / `JCMP` + `dynloop` MVLOOPCNT | SP | seed a JCR (from `const_buf`) + branch ⇒ the **dynamic loop** over staging passes | prec_sim_process.py (jcr/jcmp) |
| the sync | the SP and AB units | the producer and consumer handshake over the FIFO, which is an axiom here | handle_sync:377 |

**Derived (the staging path):** ABLU loads A (per-DNC rows) and the broadcast B (`ld_splat`)
into SP; SPLU stages SP→TU-FIFO with the `ld_type`/`ld_rot` alignment that *is* the lane
layout the contract checks; the TU computes; SPSU stores the drained result FIFO→SP; ABSU
stores out. The address descriptors are set by `IMMCOPY` and advanced by `MODLRFIMM` per
pass, which is exactly the per-pass delta the movers generate. The pass count is seeded from a register and
dynamic loop.

**Corroboration:** the `sp_layout_contract` checker (the `ld_type`/`ld_rot` alignment = the
per-axis layout tags) + the numeric gate (operands arrive uncorrupted). **Residual:** the
the exact trip values and the per-pass descriptor arithmetic, which are confirmed byte-exact by
`sp_movers` and end-to-end by the gate, not independently re-derived. **Trusted base:**
Ax-XFER (the transfers) + Ax-SYNC (the FIFO handshakes).

## 5. The NC units, which transfer per-DNC placement  ✅ interpreted, and they realize the placement lemma

An NC unit is the transfer axiom with per-DNC address arithmetic, and it is where the tiling across DNCs lands.

| element | effect | provenance |
|---|---|---|
| `LDSU`/`LDC` (NCLU) | copy the 128-B SHM line(s) at the (TLB-resolved) read addr → SP: `sp.buf[wr]=shm.buf[rd]` | prec_sim_process.py:434-470 |
| `STSU` (NCSU) | the dual: SP → SHM store | prec_sim_process.py:486-520 |
| the address-register descriptor | the SHM line address, generated per DNC from its index and row count, so the stride between DNCs is the rows each holds | `nc_movers._nclu_lrf7`, checked byte-exact over all 16 |
| the two add-immediate ops | they advance the address registers once per four-row group, which is the walk across the tile's groups | nc_movers._NC_GROW |
| `apply_NC_TLB` | VA→PA page→frame translation (unless a `…G` opcode forces VA) | prec_sim_process.py:400 |
| the two sync ops | the handshakes, which are axiomatic here. The cross-DNC barrier lives on these units; see section 6 | handle_sync:377 |

Derived: the NC mover realizes the placement lemma's affine map. The descriptor's per-DNC
`CAR/CBR = base + dnc·(rows stride)` *is* L-PLACE's `base_A + (dρ+gTr)·K·2` for the DNC's
rows; `LDSU` copies exactly those SHM lines to SP (Ax-XFER); `ADDCXRIMM/ADDSXRIMM` step the
address across the groups. So the mover visits exactly the region it should, which connects the
already-index-arithmetic-proved addresses (L-PLACE P1/P2) to the actual transfer program.

**Corroboration:** `nc_movers` byte-exact at all 16 DNC (64³ + M=128 strides) + the numeric
gate (right rows → right output) + L-PLACE's partition proof. **Residual:** the exact `CAR`
bit-layout, the TLB map, and the address-register state machine (maintained by the
the scheduler rather than the unit's own handler. It is corroborated byte-exact rather than re-derived.
**Trusted base:** Ax-XFER.

## 6. The cross-DNC barrier  ◐ its topology is interpreted and its semantics inherited

The four NCLU variants encode a **two-level cluster-tree barrier** (16 DNCs = 2 clusters ×
8). Decoded MESYNC `typ1ad_imm` (`bit0=put`, `bit1=get`; target = `imm>>2`):

| variant | # MESYNC | pattern (put/get) | role |
|---|---|---|---|
| **leader** (dnc0, dnc8) | 3 | `get` · `put+get` · `put` | **gather** from followers · **inter-leader** rendezvous · **scatter** to followers |
| **follower** (dnc1…7, dnc9…15) | 1 | `put+get` | single **rendezvous** with its cluster leader |

So: followers post-and-wait once; each leader collects its 7 followers (`get`, target =
the follower mask `0x3fd`/`0x3fc01`), the two leaders rendezvous (`put+get`, cross-linked
targets `0x401`/`0x5`), then each leader releases its followers (`put`). A textbook
gather → inter-cluster → scatter tree.

What is interpreted: the topology, meaning the gather and scatter roles and the put and get directions,
read off the imm `bit0/bit1` + the leader/follower instruction-count and target structure.

**The honest wall (the key §8 finding):** PrecSim's `handle_sync` (`:377`) reads only
the two direction bits and ignores the target field, so the decode from a target to a DNC mask
(`0x3fd`, `0x401`, …) is **HW-spec, not modelled**, and the barrier's **blocking/ordering
semantics are not executed by PrecSim at all**. The cross-DNC ordering that makes the
multi-DNC sim correct comes from the packet **scheduler** (`prim_model.run_solve`, which
terminates ⇒ no deadlock), *not* from running the barrier. Therefore:
- **deadlock-freedom** = the scheduler's (observed via termination), not derived from MESYNC;
- Whether silicon is free of races is an inherited residual, and it is more inherited than every
  other unit, because PrecSim is **not** the source-of-truth for the barrier (unlike the
  FMA, where it is, modulo the dlf16 gap).

**This is where bottom-up interpretation hits its limit:** fully explaining MESYNC (the
target-bit layout + the barrier protocol) needs the **HW spec**, not the simulator. **And
the spec answers it; see section 9 and `r100_spec/r100/r100/dnc.py`
§MESYNC/WSYNC gives the `wsync_ots0` barrier protocol + the PSYNC packet layout. So the
residual is now *resolvable from the spec*, not open. **Trusted base:** Ax-SYNC + Ax-REBEL.

---

## 7. Relationship to the rest

- **Conceptual foundation:** [`dnc-programming-guide.md`](../../PrimitiveAuthor/docs/dnc-programming-guide.md) (the
  the machine, the units and the design model. This doc holds the measured ISA semantics under it.
- **Unit-specific contracts:** [`splu_xvu_fifo_contract.md`](splu_xvu_fifo_contract.md)
  the balance of the FIFO between the loader and the compute unit, which sections 3 and 4 reference rather than restate.
- **The proof that consumes these:** [`correctness-proof-matmul.md`](../../PrimitiveAuthor/docs/correctness-proof-matmul.md)
  and its compute, input, output and sync lemmas all cite the entries here.
- **The top-down spec, reconciled in §9:**
  `r100_spec/r100/r100/dnc.py`, and the cross-check is
  done (§9): it resolves our MESYNC protocol residual, and our decode is evidence for its
  deferred cluster tree. The actual promotion into `r100_spec/r100/r100/dnc.py` stays parked.

## 8. Status ledger

| unit | status | pass |
|---|---|---|
| TU (compute) | ✅ interpreted (Ax-FMA / Ax-SRC1 base) | done |
| the vector units, draining | ✅ interpreted: the casting FMA, the equality guard and the OR that routes onward. What remains is the operand plumbing, which the probes corroborate | #5 |
| the SP and AB units, staging and transferring | ✅ interpreted: the AB load with its broadcast, the loader into the FIFO with its alignment, the store back, and the dynamic-loop staging | #6 |
| the NC units, placing | ✅ interpreted: the load and store between SHM and the scratchpad, the per-DNC descriptor being the placement lemma's affine map, and the group walk | #7 |
| the cross-DNC barrier | its topology is interpreted, as a tree that gathers then scatters, and its protocol is now resolved from the DNC spec, as section 9 records. Whether silicon is free of races is still inherited | #8 and #11 |
| the transpose primitive | ◐ structurally interpreted: the repack is realized by the NC movers' address arithmetic, with no MAC and the compute unit passing through. Its closed-form strides and a byte-exact template are deferred; see section 10 | #12 |

---

## 9. Reconciliation with the DNC block spec (task #11)

Read-only cross-check of this bottom-up reference against the top-down
`r100_spec/r100/r100/dnc.py`, whose barrier rules that model marks provisional.
No edits were made to that tree: promotion is a separate step that has to
tier the source and keep the spec re-derivable. The cross-check converges **both ways**:

### (a) The spec RESOLVES our MESYNC residual (spec → here)
The handshake protocol I could *not* derive from PrecSim (which only logs put/get) is fully
in the spec:
- **PSYNC** is the cross-DNC barrier mechanism; **WSYNC (=MESYNC) = `SYNC_TYPE 0xDA`**.
- A barrier signal is a 32-bit `sync_data` packet written to a peer's PSYNC receive address
  (`+0x4` from TSYNC): `SRC_IDX[7:0]` · `DEST_IDX[17:10]` · `SYNC_TYPE[31:24]`.
- The algorithm is **`wsync_ots0`** (all-report-to-head): leaves send one WSYNC to DNC 0 and
  wait, the head counts the arrivals and broadcasts back, and all declare done, which is two packets per leaf.

This **matches our bottom-up topology** (§6): leaves do one rendezvous; the head gathers then
scatters. So the barrier is explainable end to end, citing the spec for the protocol and our
decode for the per-variant instruction shape. (The per-instruction `typ1ad_imm`→packet
mapping, our own target field against the spec's destination index, is the one seam neither side
fully pins; our masks look like peer-sets, consistent with "send to each of N−1 peers.")

### (b) Our decode is EVIDENCE for the spec's deferred item (here → spec)
The spec explicitly **defers the multi-level structure** and points back at us:
> *"The `wsync_ots0` algorithm is a flat, single-level barrier… The multi-level NCLU
> cluster tree the production 16-DNC kernels use (per-4-DNC cluster heads that rendezvous
> at a root, as this stack's own routing shows) is not pinned by the available sources…
> documented-but-deferred."*

Our byte-exact decode of the **4 NCLU variants** (`nc_movers`/`authored_skeletons`) is
dump-grounded evidence for exactly that tree: **2 clusters of 8**, heads at **dnc0 and dnc8**
(`leader ⇔ dnc%8==0`), each leader doing gather · inter-leader rendezvous · scatter.

**Concrete conflict to flag:** the spec's provisional note guesses **"per-4-DNC cluster
heads"**; our dump-grounded decode says **8-DNC clusters** (2 heads, 8 apart). The byte-exact
gate (4 distinct NCLU programs reproducing all 16 DNCs) backs the **8** reading.

### (c) Tiering caveat (why this is *assess*, not *promote*)
The source tiers forbid sim-derived `[T4]`/`[T5]` sources in a normative spec
([`r100_spec/docs/source-inventory.md`](../../r100_spec/docs/source-inventory.md) §1). Our MESYNC
*semantics* are PrecSim-adjacent (weak), **but** the *cluster structure* is decoded from the
the production compiler's own image, which is a stronger source than the simulator.
Whether the 8-DNC-cluster fact promotes (and at what tier) is a **deliberate spec-authoring
decision**, not a casual edit. The deliverable here is this report, and the actual
`spec.md` edit is the parked promotion step.

In sum, the two converge cleanly: the spec gives the barrier's protocol and this side gives the
spec dump-grounded evidence for its *deferred cluster tree*, with a `4`-vs-`8` discrepancy to
resolve. Both sides are `[T3 provisional]`; neither alone settles the barrier, together they
nearly do.

---

## 10. The transpose primitive, which repacks by permutation  ◐ structurally interpreted

A matmul with `N > Tout` (Cout > 1) does **not** lower to a single dense Compute. It
decomposes into **two chained Computes**: a standalone `rbln_initgen_transpose` that repacks
the kernel `B`, then the `rbln_initgen_dense_fp16`. **[DUMP-CONFIRMED]** from
`tests/data/dumps/kernel_matmul_m128n128` (M=N=128): `estimated_cycles_1_0.csv` lists both
ops (`transpose` 499 cyc, `dense_fp16` 213), and the transpose's `output.dst_address`
is the dense op's own kernel source address, so the transpose feeds the dense
kernel buffer.

**What it computes.** `B` enters as `[1, 64, 2, 64]` = `[1, K, Cout_tile, Tout]` and leaves
as four dimensions, and the permutation swaps the contraction with the
Cout-tile axes, so each `64×64` Cout kernel tile lands contiguous for the MAC. (`initgen_args.json`.)

**How it is realized (the interpretation): a *permuted-address copy*, not a new archetype.**
Decoding `init_1_0.bin` (`decode_spec.walk_flits`):

| evidence | reading |
|---|---|
| the TU block count is unchanged, all of it dense | the transpose does no MAC and touches no TU |
| transpose blocks are NCLU/NCSU + SPLU/SPSU + a pass-through XVU | a **pure-mover leaf** (mechanism #6), all **Ax-XFER** |
| the NC register walk adds three negative immediates, modulo the register width, alongside nested positive ones and a burst of eight | the permutation lives in the address arithmetic. Stepping forward and then wrapping back is the classic transpose read order, and the axis swap is encoded in that stride walk and nowhere else |
| XVU transpose blocks = one `LOGICAL` (an OR-move, per §3) or just an `MVLOOPCNT` loop | XVU is a **pass-through router** for the FIFO, **not** a cross-lane shuffle |

**So mechanism #3's "permutation-repack" combinator is the *existing* mover leaves with a
transposing address map, using the same transfer primitive the placement movers use
(§5), differing only in that the C/S-register walk is a permutation rather than a linear
per-DNC stride. There is **no new leaf archetype and no new unit**; a transpose template would
be `nc_movers` plus a permutation-driven address generator.

**Status: ◐ structurally interpreted, not templated.** The unit makeup, the no-MAC fact, and
the permutation-in-addressing are evidence-grounded. **Deferred** (not done): the exact
C/S-stride **closed form** as a function of `axes` + dims, and a **byte-exact** transpose leaf
gated against these blocks. **Trusted base:** Ax-XFER (the copies) + Ax-SYNC (the FIFO
handshakes). **Relation to the matmul's internal `transpose=True`:** that flag produces the
*output* in LANE_REVERSE (the flash N=1 bug class, `sp_layout_contract.py`'s guard); this §10
is the explicit standalone repack of an input. Both belong to the same family, where the layout is an interface,
realized by address/lane ordering rather than computation.
