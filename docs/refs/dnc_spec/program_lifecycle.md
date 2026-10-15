# The DNC program lifecycle: format, load and execute, and where the simulator differs

The full arc of a DNC program: how it is **encoded** into the init image, **loaded**
into each HW unit, **executed**, and **spread across the chip**.

Two parts, **hard wall between them**:

- Part A is the ISA model, which is hardware and architecture semantics. Cite it as ISA truth.
- Part B is how the simulator realizes part A.
  It is modeling rather than ISA, so never cite it as hardware behaviour.

The reason for the wall: the simulator's runtime engine is a packet scheduler with a beat
loop, FIFO counters, a randomized step order and a wall-clock deadlock timeout, none of
which is the ISA, yet all of which is easy to mistake for it (`families_operational.md`'s
per-op entries cite it as *evidence*). Read those as *"PrecSim realizes the ISA contract
via X,"* not *"the ISA does X."*

---

## Part A: the ISA model, which is hardware semantics end to end

### A1. Init-image format

A whole DNC's program is one **init image**: a sequence of **128 B lines**, each line =
**8 columns × 16 B**. Each HW unit owns a fixed **column** (`dnckit.authoring.COL`:
NCLU 7, NCSU 6, XVU 5, VU 4, SPLU 3, SPSU 2, TU 0; per-NCore units share their type's
column). A unit's program is a **vertical run of flits down its column**, in this order:

```
header → SPR → LCCR… → LRF… → IBUFF (instruction) flits
```

The header names the block that follows it. Its target field says which unit runs it,
including the `0x100` NCore-select bit, §A5), and the counts `lccr_num` / `lrf_num` /
`ibuff_num` of the following flit groups, plus `lrf_idx[]` (which LRF slots the LRF flits
initialize). Encoder: `dnckit.dnc_enc.build_init_bytes(blocks)` lays each block's flit
sequence into its column; `dnckit.dnc_dec.decode` reverses it.

### A2. Loading (image → ibuffs)

The loader walks **each column** top-to-bottom: read a **header** → it gives the
`target_unit` and how many LRF/IBUFF flits follow → load the LRF values into that unit's
registers and the IBUFF flits into that unit's **instruction buffer (ibuff)** → advance to
the next header in the column. Two blocks of the **same unit type** (e.g. NCore-0 and
NCore-1 VU) stack in the **same column**, routed apart by the `0x100` bit in each header's
`target_unit` (§A5). After load, each unit holds its own ibuff and runs it (§A3).

**A multi-row unit (TU, ABLU) is programmed as one block PER ROW, and the row is selected
by the block's column index, which `with_col` sets, and the
loader keys it to that unit's row `k`.** `target_unit` has no per-row field (it is 11 bits =
unit + NCore + NC only); the row comes from *which init2vec column the block sits in*
(`dnc_enc.py:207` lays a block's flits into `col_words[b["col"]]`; PrecSim's decoder keys the
actor as `TU{nc}_{col_idx}`, `dnc_init.py:451`, where `col_idx` is that column). The **TU
relies on this**: its systolic MAC chain is **8 TU blocks per NCore**, all with
`target_unit = 0x81` (`|0x100` for NCore-1), placed in **distinct columns 0..7** via
`with_col(tu_k, k)` → systolic rows `tu{nc}:0..7`. **All 8 must occupy distinct columns or
the chain cannot drain:** each FMA with `tgts>0` forwards its partial *south* to the next row,
and only row 7's south forward routes to the VU, which is the partial-sum drain of D6,
"row 7 → VU"). An un-programmed row actor is deleted at decode-init, so if you stack all 8 in
the SAME column (e.g. the unit's default `COL[TU_UID]`), they collapse onto `tu{nc}:0`, rows
1 to 7 are deleted, the drain is unreachable and the run deadlocks, which PrecSim reports as exit 44.
*regardless* of stacking order, byte-distinctness, SPR, or header fill (all empirically ruled
out, and only the column index moves a block to another row). This holds at every shape,
the K-contraction *depth* lives in the TU's MVLOOPCNT trip counts, not the row count, so even
a rank-1 (K=1) tile still needs all 8 row-programs in 8 columns (trip counts collapse to 1).
The west feed is the **opposite**: ABLU is a **single block fixed at column 1**
(`dnc_init.py:414/423` forces `is_ablu ⇒ col_idx==1`) whose 8 row-engines (`ablu{nc}:0..7`)
fan to the 8 TU rows, so do not replicate it across the columns, which trips the assertion on column 1
assert → exit 10). (NB: single-instance units VU/XVU/NCLU/ABSU/**ABLU** each live in their
one home column, and the mapping from column to row applies to the TU alone, over its 8 blocks in 8 columns.)

### A3. Per-unit execution: the instruction-buffer sequencer

After load, each unit runs its own program as a sequencer:

- **Start.** Begins at **PC 0** and executes the ibuff in order. No separate "start" signal
  is modeled, so a loaded unit runs its program.
- **Step.** Default advance is **PC + 1**. Control flow:
  - **`MVLOOPCNT(n)`** (C6) pushes a loop entry onto the per-unit **loop stack** (the LCCR,
    **≤ 16 deep**); the *following* body iterates `n` times. The body's **last** instruction
    sets the branch-end bit, which is the back edge to the instruction after the
    `MVLOOPCNT`; when the count exhausts, control falls through (PC + 1).
  - The compare-and-jump op is the data-dependent branch: compare two registers and jump to the target.
  - A loop count may be dynamic, taken from a register, which is a boundary case covered in
    Open questions.
- **End.** **`RETURN`** (C5) halts the unit's sequencer. Running off the ibuff end without a
  `RETURN` is malformed (the toolchain warns); pad the tail with `RETURN`s
  (`authoring.Program.pad_return`).

### A4. Firing, which is how the dataflow gates between units

A unit's data-moving instructions are gated by the inter-unit dataflow:

- An instruction **fires** only when its **inputs are available** (source FIFO/SP holds
  data) and its output has room, meaning the consumer's FIFO is not full, which is backpressure.
- **`SYNC`** (C2) adds explicit cross-unit ordering: a `get` leg **blocks** until the paired
  `put` has arrived on the `{peer}_{self}_sync` channel. Instructions between SYNCs free-run
  under back-pressure alone.
- A kernel is therefore a **network of communicating sequential units**; by Kahn
  process-network determinacy, these local contracts + the channel topology pin the result
  **independent of when each unit steps** (per-op contracts: `families_operational.md`).
- Work quantum: one instruction processes `url_deg` (compute) or `burst`/`burst_sz`
  (load/store) elements, decoded from its real fields (`families_data.md`).

**The pipeline (what the units *are*).** The units are not peers you call independently;
they are stages wired into one producer→consumer chain per NCore. The canonical compute row:

```
SHM →[NCLU]→ SP →[SPLU]→ ⟨FIFO⟩ →[VU/XVU]→ ⟨FIFO⟩ →[SPSU]→ SP →[NCSU]→ SHM
       load          stream         compute          drain          store
```

| stage | role | scope | moves |
|---|---|---|---|
| NCLU | the ingress from SHM into the scratchpad, addressed by line index | shared by the DNC | SHM lines into the scratchpad |
| SPLU | the feed from the scratchpad into a FIFO, through a byte-address pointer plus a stride register. A field picks which FIFO consumer it feeds | one per NCore | a scratchpad line into a compute FIFO |
| VU and XVU | the compute actors, mapping or folding the streamed tokens. They read their FIFO source classes plus the register file or a constant, and route the result out to the store unit, to each other, or to the TU | one per NCore | FIFO to FIFO |
| SPSU | the drain from a FIFO into the scratchpad. A field picks the producing unit | one per NCore | a compute FIFO into the scratchpad |
| NCSU | the egress from the scratchpad into SHM | shared by the DNC | the scratchpad into SHM lines |

(The TU is the systolic MAC for a contraction, fed by the AB units on its west and north, under the same dataflow
rules, off the VU row.)

**There are two kinds of edge and only one of them needs a sync.**

- **FIFO edges** (`SPLU → VU/XVU`, `VU/XVU → SPSU` via `out_sp`): a real streaming channel
  carrying both the data and the flow control. Backpressure alone couples them, with no sync.
- **Shared-buffer seams** (`NCLU → SPLU`, `SPSU → NCSU` on an **SP region**; `ABSU → ABLU` on
  the **σ.AB** buffer): the two stages do **not** share a FIFO; they rendezvous on shared
  **mutable memory**. Nothing makes the reader wait for the writer, so you must add an explicit
  an explicit sync: load-done into the SPLU, drain-done into the NCSU, and stage-done into the ABLU.
  This is exactly why a one-row kernel carries those SYNC edges and no others.

**Authoring a producer→consumer SYNC handshake (the recipe).** Whenever two async units
rendezvous on shared mutable state (an SP region or the `σ.AB` buffer), enforce write-before-
read with a matched pair of `SYNC` instructions (bitmask in `families_control §C2`: bit0 =
**SEND/put**, bit1 = **RECV/get**, plus the peer bits):

1. **Producer:** *after* the instruction that writes the buffer, issue `SYNC(send, peers=[the
   consumer])`, which signals that the data is ready.
2. **Consumer:** *before* the instruction that reads the buffer, issue `SYNC(recv, peers=[the
   producer])`, and its get leg blocks until the producer's matching put arrives on the
   `{producer}_{consumer}_sync` channel.
3. **The peers must match both ways.** The producer names the consumer and the consumer names
   the producer (`authoring.sync_imm(send=/recv=, peers=[...])` builds the immediate). The
   green `add` pipeline is the reference pair: `NCLU SYNC(send,[splu0])` ↔ `SPLU
   SYNC(recv,[nclu])`, and `SPSU SYNC(send,[ncsu])` ↔ `NCSU SYNC(recv,[spsu0])`.
4. **One handshake per consumer.** If a buffer feeds several consumers (e.g. the `σ.AB` tile
   read by the TU rows), the producer's sync fans over each consumer. See the per-channel
   names in the `ABSU.LDSTU` / `ABLU.LDSTU` operational entries (`absu↔ablu:{i}_sync`).

**The failure mode, and why this part cannot be derived.**
A get with no matching put, whether from the wrong direction, a wrong or missing peer, a wrong count,
or a producer that never runs, blocks forever and
`PrimDeadlockError` (PrecSim exit 44)**, and the simulator gives **no channel-level diagnostic**
of *which* edge is stuck. So a SYNC handshake is not probe-discoverable the way a data leaf is;
author it deliberately from this recipe, against the `add`-pair reference, and check every
`send` has its mirror `recv` (and vice versa) before running.

**Consequences to build and probe around, which follow from the Kahn model.**

1. **Firing is driven by input.** A stage fires by consuming its input stream, one pop per beat per
   active FIFO source, for as many beats as the loop count or the supply dictates,
   whether a given beat *emits* a downstream token is set by the instruction's `out_*` routing
   (a reduction consumes K beats but drains once). The invariant: **no input stream ⇒ the
   stage never fires ⇒ it emits nothing.**
2. **A starved stage deadlocks the chain.** Reads are blocking (Kahn). A unit with no upstream
   feed never fires, and any consumer parked on its never-produced output blocks forever, so the simulator
   reports a **deadlock/timeout, not a wrong value.**
3. **You cannot unit-test a downstream stage by deleting its feed.** Feed → compute → drain is
   **one coupled unit-of-test**, because the drain's output is clocked by the feed's input. To
   isolate a drain or a compute, give it a minimal known feed, streaming one known line,
   never *no* feed. A "drain-only, no feed" probe is ill-formed: it deadlocks regardless of
   whether the drain is correct, so it teaches you nothing about the drain. (Corollary for
   On the compute units a result reaches the scratchpad only as part of a fed and looped run, so a standalone constant op with
   nothing feeding it produces nothing; drain **after** the fed loop, never alone.)

### A5. Spatial structure & fork-join

The chip is **16 DNCs in 2 clusters (8 + 8)**; each DNC has **2 NCores**.

- Within a DNC, along the NCore axis, the two NC units are shared: there is one of each and no
  per-NCore instance, so they must not carry the NCore bit, which PrecSim asserts on and exits 10.
  **SPLU/SPSU/VU/XVU/TU/AB are per-NCore (×2)**; the NCore-1 instance is selected by the
  `0x100` unit-id bit (header bit 93; `dnckit.authoring.with_multi_tile`). A multi-NCore
  kernel **mirrors** each pipeline per NCore (identical program, disjoint SP/SHM) and
  **fork-joins**: the single NCLU fans load-done to `splu0` **and** `splu1`, the single NCSU
  gathers from both store units, and there is no sync across the NCores, so the two pipelines run freely
  between the fork and the join. (Source + trace verified: `dnc0.log` shows one `nclu`
  putting `0x11`=SEND|SPLU0 and `0x41`=SEND|SPLU1; one `ncsu` getting `0x22`+`0x82`.)
- Across DNCs, along the cluster axis, SHM is global and shared by every DNC in both
  clusters; this is what makes cross-DNC reduction possible. **SP is per-DNC** (the 2 NCores
  of a DNC share it). Each DNC runs **its own init image**. Cross-DNC ordering uses
  the cross-DNC barrier, which fans a token across up to 16 DNC-indexed channels on each NC unit.

---

## Part B: how PrecSim realizes part A (⚠ simulator modeling, not ISA)

> Everything here is how `rebel_prec_sim` *implements* Part A. Do not promote any of it into
> the ISA spec or cite it as hardware behavior.

### B1. Two-phase: decode-then-solve (loops unrolled)

PrecSim runs in two phases (`main_single.py:311` "PRE-EXEC" vs `:417` "EXEC"):

1. **Decode / PRE-EXEC** (`init_decode.py::run_instr`) is where the real §A3 sequencer
   lives: a true program counter from 0, the increment and the branch-end back edge, a loop stack of at most 16, the compare-and-jump,
   `RETURN` (`init_decode.py:1759-1815, 2012-2025, 2534-2575`). As it walks, it **emits one
   dataflow packet (`InstrPktV2`) per executed instruction** (`prec_sim_callback`,
   `main_common.py:998,1136`), so loops are unrolled into a flat per-unit packet list.
   Control-only opcodes (`MVLOOPCNT/NOP/RETURN/JCMP/J*`) emit **no** packet
   (`instr_pkt_v2.py:261`).
2. **Solve / EXEC** (`prim_model.py::run_solve`, the *root* `prim_model.py`, not the
   static-analysis one under `prim_analyze/`), which is a priority-scheduled FIFO dataflow solver
   over the pre-unrolled packets. It has no program counter, no branches and no loops, only a packet cursor
   `pkt_i` per unit.

### B2. The decode modify-pass (and the multi-NCore column footgun)

During decode-modify (`init_decode.py:269-314`), the loader reads each column header, and
for the multi-tile (`0x100`) bit it **clears header bit 93 and re-reads `target_unit`**
(`init_decode.py:276-278`). Because same-type blocks stack in one column (§A2) and the
encoder lays them in `blocks`-list order (`dnc_enc.py:207`), the **order of stacked
NCore-0 vs NCore-1 blocks interacts with this modify pass**: empirically the `0x100`
(NCore-1) block must be emitted **before** its NCore-0 sibling, or NCore-0 silently zeros
out. This is an ordering artifact of the loader and the encoder rather than an ISA rule, and it is not yet
auto-fixed because reordering could disturb existing matmul kernels.

### B3. Packet counters, scheduler, deadlock timeout

- **Counters.** Each packet carries `size (= url_deg)`, `done_read`, `done_write`;
  `is_done = (size == done_read == done_write)` (`instr_pkt_v2.py:15,28,164,207`). The ISA
  kernel underneath is just "fire when inputs ready + output room"; the per-element
  accounting is a solver device.
- **Scheduler.** A swappable unit-**priority policy** (default policy 2:
  `ncsu > nclu > spsu > compute/AB/TU/VU/XVU > splu`, reset-to-highest on progress,
  `prim_model.py:29,202-222`) picks which unit steps; a **20% random `force_blocked` stall**
  (`prim_model.py:40,236`) + a per-DNC RNG seed make the **step order non-deterministic**
  (only the final memory result is intended bit-accurate, not the interleaving).
- **Termination.** Sim ends when every unit's packets are exhausted AND decode is done
  (`all_finished`, `prim_model.py:354-379`). A **60 s wall-clock deadlock timeout**
  (`DEADLOCK_TIMEOUT_THRESHOLD`, `prim_model.py:14`) + `BLOCKED_IT_THRESHOLD=8` (`:16`)
  raises if all units are blocked with no progress. A wall-clock timeout is self-evidently
  not hardware.
- **`FAST_LOOP`.** A static loop whose body has no `JCR` op runs in ~2 iterations with a
  significance multiplier instead (`init_decode.py:1791-1793`), which accelerates the simulation.

### B4. Multi-DNC realization

The cross-chip topology of §A5 is realized as: one **init image per DNC** (the oracle's
`init_bins` list; broadcast form is one image to `active` DNCs), the cluster split
`_dcl_dnc(active)` = `(1, active)` if `active ≤ 8` else `(2, active-8)` (`oracle.py:57`),
and DNCs as **separate OS processes over shared-memory** (`SHM = 64 MB = 32 MB × 2 clusters`,
`SP = 4 MB/DNC` overridable via `PRECSIM_SP_SIZE`; `main_single.py:166-167`), with a
cross-DNC `states.blocked` early-return (`prim_model.py:283-287`).

---

## Open questions (ISA/bridge boundary not yet settled)

1. **Dynamic (`JCR`-sourced) `MVLOOPCNT` counts.** Data-dependent loop counts are
   ISA-plausible, but PrecSim implements them via a decode↔solve **feedback-queue handshake**
   (`main_common.py:1213-1216`, `main_single.py:339-367`) that is a modeling artifact. Where
   the ISA boundary sits for dynamic counts is unresolved.
2. **Scheduler priority order.** Whether `ncsu > nclu > … > splu` reflects real HW arbitration
   or is solver-convergence tuning is unknown (three swappable policies argue for tuning).

<!-- provenance: source-read 2026. Format/load: dnc_enc.py:70-77,118-144 (HdrFlit/gen_flits),
init_decode.py:269-314 (column header walk), authoring.COL. Lifecycle (ISA): init_decode.py:
1759-1815,2012-2025,2534-2575. Topology: main_common.py:528 (nc_tgts vs ncore_tgts), oracle.py:57
(_dcl_dnc), main_single.py:166-167 (SP/SHM sizes), dnc0.log trace (NCore fork-join). Bridge:
prim_model.py:14,16,29,40,202-222,236,283-287,354-388; instr_pkt_v2.py:15,28,261; init_decode.py:
276 (bit-93 modify). Conservative ISA/bridge tags; ambiguous items under Open questions. -->
