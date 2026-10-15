# The DNC ISA's operational layer

This is the companion to `families_data.md`, which gives the architecture state and each op's effect on
it, and to `families_control.md`.
Those two say what each op computes.
This one says how an op behaves as a dataflow actor, which is the layer execution dynamics need.


<!-- ===================================================================== -->
## Operational / concurrency layer  (dataflow-actor contracts)

The entries in the companion files are denotational, giving the architecture state and each op's effect
on it.
This section adds the operational layer that execution dynamics need.
For each op family it gives the in and out FIFO ports, the streaming extent, the firing rule and its
backpressure, the SYNC dependence, the termination condition, and whether the op is Kahn-deterministic.

By the determinacy of a Kahn process network, these local contracts together with the channel topology
pin the functional execution independently of the scheduler.
An op marked as not Kahn is order-sensitive and does need the scheduler.

> **Provenance and status.**
> The contracts below were extracted from the PrecSim execution model:
> its scheduler loop, the packet model that defines the extent, the done condition and the read and
> write guards, and the per-unit run handlers.
> The extraction ran as three drafting and adversarial-review passes on 2026-06-22 and 23.
>
> The blocks carry one of four status tiers.
> - Citation-clean: verified, with citations that resolve.
> - Content-verified with working-tree-relative references, on the TU, VU, XVU and NCLU blocks.
>   Their fields are confirmed, but the line references into the handler file sit about 12 lines off
>   committed HEAD, because the simulator submodule was modified during extraction.
>   Re-anchor them once it is clean.
> - Review-flagged, on five blocks.
>   Their content is sound and each carries its reviewer's fix list,
>   mostly disambiguating the two files of the same name:
>   the skipped-opcode table is in the analysis package and the runtime scheduler is at the root.
> - Corrected after rejection, on the zero-port markers block.
>
> Three follow-ups remain, none needing a new extraction:
> re-anchor those line references once the submodule is committed,
> apply the five fix lists,
> and reconcile how the two blocks in the self-mutating-register class are classified,
> since one is tagged as Kahn-deterministic and the other is not.
<!-- ===================================================================== -->


> The spatial structure, meaning the fork and join across NCores and DNCs, is in
> [`program_lifecycle.md`](program_lifecycle.md).
> That covers the shared NC units against the two per-NCore copies, the mirrored pipelines,
> the fork and join through the per-NCore SP units, the global SHM, the per-DNC images and the
> cross-DNC barrier.
> This file stays on the per-op dataflow-actor contracts.


<!-- ===================================================================== -->
## The TU's systolic dataflow, meaning how the unit is meant to be driven

This is the starting point for a programming model of the TU:
enough of the dataflow shape to derive a program from, by then drilling into the per-op entries.
The TU's MAC and its mask are in `families_data.md`, the west feed through the AB is the ABLU entry
below together with its two sections there, and the north feed comes through the XVU.

It describes what the machine does rather than how any one algorithm maps onto it.
That mapping, which operand goes where and how an algorithm's axes bind to lanes, rows and beats,
is the programmer's to derive and is deliberately not stated here.

The TU is an 8-row systolic array of 64-lane SIMD processing elements.
A programmer binds work onto three structural axes.

- The inputs are two multiplicands arriving on two distinct ports.
  A MAC-mode FMA multiplies two of its inputs, and the candidate sources are the register file, which
  is resident and per-lane, the west feed from the ABLU, and north.

  One asymmetry matters, and it was corrected against the packet model, which is the engine the oracle
  runs: the west feed delivers an operand into one 8-lane slice only.
  The ABLU emits seven zero rows and then the data, so 56 of the 64 lanes are zero-padded,
  and the splat replicates the value only within that single slice.
  West is therefore not a 64-lane broadcast, and a west-fed FMA contributes to just 8 of the 64 output
  lanes.
  A value that must reach all 64 lanes rides north, per lane, by splatting a lane-uniform value through
  the SPLU and the XVU, or else sits in the register file. It does not ride west.
  Where this file speaks of broadcasting across lanes, that describes the operand's conceptual systolic
  role rather than what the west feed physically delivers.

  Note that this is the per-row feed.
  Each of the 8 rows has its own west port, and the production dense matmul does drive the west feed
  across the rows and is correct on the oracle.
  So west is the operand axis at the array level rather than an unused one,
  and the single-slice fact above is about one row rather than a reason to avoid west.

  West is supplied by a single ABLU at a fixed column, filled from a single ABSU at the column before
  it, and the loader asserts those columns.
  The operand is staged from the XVU through the ABSU and the AB bank into the ABLU.
- The reduction runs down the row chain on north, which carries the accumulating partial.
  North is not a fresh operand.
  Row 0's north is seeded from the XVU, and each lower row's north is the row above's south forward,
  so partials accumulate from row to row.
  A contraction's depth binds to the number of rows driven, and one row means no accumulation.
- The output drains at row 7 alone.
  A result reaches the VU only over that one edge, and the handoff applies the rounding that narrows
  the accumulator to 16 bits.
  From the VU the value follows the ordinary store half, out through the SPSU, the scratchpad and the
  NCSU into SHM, which is the same path an elementwise op takes.
  The row-mask register gates which lane slices commit, and so which outputs are valid.
- All 64 lanes run the same instruction in lockstep, so one FMA emits 64 results at once.
  The lane axis is free, giving a full row of 64 outputs per beat with no extra instructions.

### Deriving the two feeds, and why north is simple and west is not

Both feeds answer the same question, how to get an operand to a TU input at the array's rate without
races, and north and west answer it oppositely.
The whole difference traces to one fact: north is per-lane and reaches all 64 lanes,
while west delivers a single 8-lane slice rather than the 64-lane broadcast, as corrected above.

North, the per-lane reduction axis, is derivable end to end.

1. It is per-lane and enters at a single point, row 0, so it needs no reshape and one injection site.
2. So it takes a direct producer-to-consumer FIFO from the XVU into row 0, with no staging buffer.
3. Rows 1 to 7 are never separately fed, the partial propagating itself through the south forward,
   which is the systolic chain.
4. So it needs exactly one sync edge, from the XVU to row 0, an ordinary producer and consumer
   handshake.

West, the single-slice operand feed, needs staging machinery instead.
In the packet model it delivers one slice, so it is not how a full 64-lane operand is fed;
that goes through north or the register file.

1. The operand is staged through a buffer and broadcast within its slice on read.
2. A buffer between an asynchronous producer and the rate-locked array needs a write port and a read
   port, which is two units: the ABSU fills it from the XVU and the ABLU drains it to west.
3. A shared mutable buffer needs a read-after-write barrier between its writer and its reader,
   fanned over the consumer rows, which is the handshake between those two units.

So west is north's logic plus a buffer, two ports and that barrier,
and every extra piece follows from the broadcast requirement.
This is essential systolic structure rather than arbitrary design,
being the two orthogonal array axes, a self-timed per-lane chain against a distributed operand.
The only parts that cannot be derived and have to be looked up are the realizations:
the encoding of the sync handshake and the AB addressing.

**Loading & the deadlock rule.** The 8 TU rows are 8 blocks in **init2vec columns 0..7**
(column index = row, `program_lifecycle.md §A2`); **ABLU and ABSU are single blocks** at the
fixed columns **1 and 0**. Every TU input port a program reads must have its producer actually
running, or the FMA blocks and the run **deadlocks**; and because the drain is row-7-only, a
single-row compute must still forward south to row 7 to leave the array.
<!-- ===================================================================== -->

### operational(TU mask ops: SETMASK, INCRMASK)  · kahn: **NON-KAHN**
<!-- COVOP id=tu-mask tier=citation-clean kahn=no ops=SETMASK,INCRMASK -->

- **in-ports:** none. No FIFO in-ports. check_source returns ({},[False,False,False]) so run() never indexes ififos (constr_tu.py:1157-1175; dispatch prec_sim_process.py:2522-2523). The InstrPkt consume_from is the self-loop ['self'] (instr_pkt_v2.py:1033-1041); in run_read 'self' is a no-op pass with no state decrement (instr_pkt_v2.py:170-172) and in can_read 'self' always yields amt_remaining with no backpressure (instr_pkt_v2.py:105-107).
- **out-ports:** {} (no FIFO out-ports). produce_to is the self-loop ['self'] (instr_pkt_v2.py:1033-1041); run_write for 'self' is a no-op pass touching no FIFO/state (instr_pkt_v2.py:212-214); can_write returns amt_remaining unconditionally (instr_pkt_v2.py:133-136). sim_non_comp appends nothing to any ofifo (prec_sim_process.py:2722-2733).
- **reg/sp-write:** Writes the per-(ncore,row) TU context register ctx.row_mask ONLY. SETMASK <- params['mask'] (prec_sim_process.py:2726); INCRMASK <- (row_mask+1)%8, wraps mod 8 (prec_sim_process.py:2730). row_mask inits 0x0 per TU context (prec_sim_process.py:170). No LRF/SP/AB write by the mask op itself. Downstream consumer: TU FMA passes ctx.row_mask as the 'mask' arg to _sim (prec_sim_process.py:2841) and gates per-slice LRF writeback (slices with slice<row_mask are skipped, prec_sim_process.py:2855-2860).
- **extent:** size = url_deg = 1 per execution (instr_pkt_v2.py:1033-1041 set consume_from/produce_to=['self'] with size=None -> url_deg stays 1 per instr_pkt_v2.py:285,1106-1114; base size=url_deg instr_pkt_v2.py:15). Any enclosing MVLOOPCNT repeats the single-tick op verbatim per iteration (MVLOOPCNT is in ignored_opcodes for packetization, instr_pkt_v2.py:261-272; it is a control/loop-count op, not data extent). No dynloop / sigma.JCR dependence (these are not JCR ops).
- **fire-rule:** Always fires, unconditionally, in one solver tick. As a self:self pkt: can_read returns amt_remaining (=1) with no FIFO/SYNC gate (instr_pkt_v2.py:105-107), can_write returns amt_remaining unconditionally (instr_pkt_v2.py:133-136), so run_solve's blocked = (rd_amt==0 and wr_amt==0) is never true for it (prim_model.py:301-334). No backpressure / no stall source (no ext/sp/ab/jcr/south state touched). The handler is pure register assignment (prec_sim_process.py:2725-2730).
- **sync-dep:** none. No SYNC edge. handle_sync returns early for TU: opcode is not MESYNC and ctx.unit 'tu' matches none of the ab/sp/nc branches, hitting the bare 'return' (prec_sim_process.py:389-399). Ordering relative to the FMA that reads row_mask is implicit via TU program order (same ctx.row_mask register), not via a FIFO or SYNC edge.
- **terminates:** is_done when size==done_read and done_read==done_write (instr_pkt_v2.py:27-28); with size=1, after one read tick (run_read +=1, instr_pkt_v2.py:163-165) and one write tick (run_write +=1, instr_pkt_v2.py:205-207) the op is done in a single solver pass.
- **inferred / flags:**
  - KAHN classification = NON-KAHN: INFERRED. The op moves no data on any FIFO and has no SYNC edge; it is a pure control/state mutation of ctx.row_mask consumed implicitly by later FMA via program order, not a blocking FIFO+SYNC dependence. (basis: self-loop ports with no-op read/write, instr_pkt_v2.py:170-172,212-214; handle_sync early-return prec_sim_process.py:389-399).
  - 'Always fires / no backpressure': INFERRED from the generic self:self can_read/can_write returning amt_remaining with no state gate (instr_pkt_v2.py:105-107,133-136) combined with run_solve's blocked predicate (prim_model.py:334); there is no mask-op-specific firing code.
  - MVLOOPCNT acting as an outer repeat of the single-tick mask op: INFERRED from MVLOOPCNT being in ignored_opcodes (packetization skips it, instr_pkt_v2.py:261-272) and being a loop-count control op; no source line ties a specific MVLOOPCNT count to SETMASK/INCRMASK extent.
  - row_mask being per-(ncore,row) scoped: INFERRED from ctx being a UnitContext constructed with ncore_idx/row_idx (prec_sim_process.py:101-104) and row_mask living on that ctx (prec_sim_process.py:170); not stated as 'per-row' in a single line.
- **citations:**
  - `third_party/rebel_prec_sim/prec_sim_process.py:2722-2733 (sim_non_comp handler; SETMASK/INCRMASK row_mask update)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:2516-2523 (TUProcess.run dispatch to sim_non_comp on empty src_dict)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:170 (ctx.row_mask init 0x0)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:2841,2855-2860 (downstream FMA reads row_mask, gates per-slice LRF writeback)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:389-399 (handle_sync early-return for TU)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_tu.py:52-65 (common_opcodes incl INCRMASK/SETMASK)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_tu.py:1157-1175 (check_source returns empty for non-FMA)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:1033-1041 (consume_from/produce_to=['self'], size=None)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:1106-1114 (url_deg=size else 1)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:15,27-28 (size=url_deg; is_done)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:105-107,133-136 (can_read/can_write 'self' = no backpressure)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:170-172,212-214 (run_read/run_write 'self' = no-op pass)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:261-272 (MVLOOPCNT in ignored_opcodes)`
  - `third_party/rebel_prec_sim/prim_model.py:301-334 (run_solve rd_amt/wr_amt/blocked)`

---

### operational(ABLU.LDSTU (AB->TU west operand load with ld_splat broadcast))  · kahn: **yes**
<!-- COVOP id=ablu-ldstu tier=citation-clean kahn=yes ops=LDSTU -->

- **in-ports:** AB-memory read, NOT a FIFO in-port. Handler iterates ab_addrs and reads ab_map.mem_lines[rd_addr_8B] + next 8B line (prec_sim_process.py:1163-1166); ab_addrs = mem_txn[\"AB_ADDR\"][\"RD\"] slice (main_common.py:692). instr_pkt_v2 records consume_from=f\"ab{cur_ncore_idx}\" (instr_pkt_v2.py:967). ab0/ab1 are in c_list (no-stall memory class; can_read gates only on done_read<size, instr_pkt_v2.py:101-107). ABLU has no check_source (it is a memory-load unit, not north/west/lrf FIFO-fed). src0/src1 are LRF address registers (constr_ablu alignment block), not FIFO ports. Rate: 1 AB line-pair per ab_addr per fire.
- **out-ports:** FIFO out-port to the TU column it feeds: produce_to=f\"tu{cur_ncore_idx}:{row_idx}\" (instr_pkt_v2.py:968); ofifo keyed f\"{ablu_unit}-{tu_unit}\" from produce_to (main_common.py:549). Handler appends to every ofifo: fifo.append((ctx.txn_id, load_data)) (prec_sim_process.py:1248), rate 1 entry per ab_addr per fire. This is exactly TU's \"west\" source: TUProcess.fifo_name_remap(\"west\")=f\"ablu{ncore}:{row}\" (prec_sim_process.py:2500-2502). Payload = 8 rows x 16 lanes of 16b: load_data=[splat8(0)]*7 + [load_data] (prec_sim_process.py:1246) so loaded 16B sits in row 7, rows 0-6 zero-pad. ld_splat broadcast: ld_type==1 (8B) duplicates lo into hi half scaled by ld_splat (prec_sim_process.py:1184-1187); ld_type==2 (4B) replicates lo_2B across 8 lanes vs 2 when ld_splat (prec_sim_process.py:1205); ld_type==3 (2B) across 8 lanes vs 1 (prec_sim_process.py:1213).
- **reg/sp-write:** No SP/LRF write. Side effect on the AB read-access bookkeeping only: decrements ab_access[row_idx][rd_addr_1B][0] read-pending counter and emits WARN-UNINIT-AB if ab_lines[row_idx][rd_addr_1B] unset (prec_sim_process.py:1219-1234); increments ctx.txn_ctr (prec_sim_process.py:1249). src0/src1 LRF address regs are read, not written.
- **extent:** size = url_deg = (burst_sz if burst else 1), then x4 if interleave_sz==3 / x2 if interleave_sz==2 (instr_pkt_v2.py:958-961); burst_sz falls back to zs_burst_sz when 0 (instr_pkt_v2.py:954-955). size capped <=64 per constr (constr_ablu.py burst_sz assert). The handler's own loop is over ab_addrs (one AB line-pair each), i.e. the per-fire granularity; the burst extent (size) is the MVLOOPCNT-equivalent the scheduler drains. No dynloop on this op (LDSTU extent is static from burst_sz/interleave_sz fields).
- **fire-rule:** Scheduler run_solve loop: rd_amt=can_read then run_read, wr_amt=can_write then run_write (prim_model.py:301-313). can_read: AB is no-stall memory class so read is gated only by done_read<size, BUT first blocked by is_ofifo_stalled: if the downstream tu FIFO is full (state.state[ablu_unit_tu]==max) read returns 0 (instr_pkt_v2.py:91-95, 56-67). can_write gates on amt_remaining=done_read-done_write and downstream FIFO headroom (instr_pkt_v2.py:122-150). So: fire when AB has the line AND the target TU west FIFO has space; backpressure/stall = TU-west FIFO full (ofifo_stall). blocked = (rd_amt==0 and wr_amt==0) (prim_model.py:334).
- **sync-dep:** Implicit-via-FIFO for the AB->TU data edge (TU drains the ablu:row FIFO as its west operand). Explicit producer/consumer SYNC available via the ABLU SYNC opcode against ABSU: put -> f\"ablu{nc}:{row}_absu{nc}_sync\", get <- f\"absu{nc}_ablu{nc}:{row}_sync\" (instr_pkt_v2.py:990-998); handled by handle_sync with imm_fld=typ1_imm for ab units (prec_sim_process.py:391-409). The LDSTU data op itself emits no SYNC edge.
- **terminates:** is_done = (size==done_read) and (done_read==done_write) (instr_pkt_v2.py:28-30): all burst elements both read from AB and written into the TU-west FIFO.
- **inferred / flags:**
  - MVLOOPCNT framing: the prompt's 'extent = url_deg x Pi(MVLOOPCNT)' is mapped here onto burst_sz x interleave multiplier; ABLU LDSTU takes its extent from the burst/interleave instruction fields (instr_pkt_v2.py:958-961), and the per-fire handler loop is over ab_addrs. Reason: no explicit MVLOOPCNT consumption in the ABLU LDST* pkt path, so the loop-count is folded into size/burst, not a separate MVLOOPCNT register read in this op.
  - kahn=yes: the AB->TU data path is deterministic (AB memory read + bounded FIFO with blocking can_read/can_write backpressure, no non-blocking control). The ABLU GETJCR opcode (prec_sim_process.py:1155) IS the NON-KAHN control path for this unit, but it is a different opcode, out of scope for LDSTU. Reason: classification is per-op; LDSTU has no JCR/non-blocking branch.
  - ld_splat=broadcast semantics described at the dataflow-shape level (which lanes get duplicated) rather than value semantics, per the operational-only mandate. Reason: exact bit/encoding of the splat is denotational and excluded.
  - The 7 zero-pad rows + row-7 payload (prec_sim_process.py:1246) means the TU west operand arrives as a single populated row per FIFO entry; that TU consumes row 7 as the active west lane is inferred from the pad pattern, not asserted from a TU-side read of row index in this file region.
- **citations:**
  - `third_party/rebel_prec_sim/prec_sim_process.py:1154 (ABLUProcess.run handler entry)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:1161-1166 (ld_type/ld_splat read; ab_map.mem_lines read of rd_addr_8B + next 8B)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:1184-1187 (ld_type==1 8B ld_splat hi-half)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:1205 (ld_type==2 4B 8-vs-2 lane splat)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:1213 (ld_type==3 2B 8-vs-1 lane splat)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:1219-1234 (ab_access decrement + WARN-UNINIT-AB)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:1244-1249 (out FIFO append, [splat8(0)]*7+[load_data] pad, txn_ctr++)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:2500-2502 (TU fifo_name_remap west -> ablu{nc}:{row})`
  - `third_party/rebel_prec_sim/prec_sim_process.py:389-409 (handle_sync imm_fld typ1_imm for ab units)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:949-968 (ABLU LDST*/ consume_from=ab{nc}, produce_to=tu{nc}:row, size/burst/interleave extent)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:990-998 (ABLU SYNC put/get sync FIFO names vs ABSU)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:28-30 (is_done)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:84-119 (can_read + ab in c_list no-stall + ofifo_stall)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:56-67 (is_ofifo_stalled on tu target FIFO full)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:122-153 (can_write FIFO headroom)`
  - `third_party/rebel_prec_sim/prim_model.py:301-334 (run_solve rd_amt/wr_amt/blocked)`
  - `third_party/rebel_prec_sim/main_common.py:689-712 (ablu wrapper: ab_addrs slice, ofifos=get_io_fifos)`
  - `third_party/rebel_prec_sim/main_common.py:509-549 (get_io_fifos ofifo key {unit}-{produce_to})`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_ablu.py (LDSTU/ZSLDU src0!=src1; burst_sz<=64; ld alignment on src0/src1 LRF)`

---

### operational(ABSU.LDSTU, the coalesce-store of an XVU result into the AB tile)  · kahn: **yes**
<!-- COVOP id=absu-ldstu tier=citation-clean kahn=yes ops=LDSTU -->

- **in-ports:** {xvu{ncore}: data FIFO, 1 txn popped per AB write-addr, and consume_from is the single port "xvu{cur_ncore_idx}" (instr_pkt_v2.py:964-965); handler iterates ififos.items() and fifo.pop(0) for each (prec_sim_process.py:1264-1269). LRF src0/src1 (store base addresses) are NOT FIFO in-ports, being local LRF regs decoded as the AB write address (constr_absu.py:183-188); ab_addrs/wr_addrs are passed in by the caller from mem_txn["AB_ADDR"]["WR"] (main_common.py:717). For SYNC: consume_from="self" on put, "ablu{nc}:{i}_absu{nc}_sync" on get, fanned over 8 ABLU rows (instr_pkt_v2.py:998-1013).}
- **out-ports:** none, so there is no outgoing FIFO. produce_to = "ab{cur_ncore_idx}" (instr_pkt_v2.py:966), and ab0/ab1 are memory pseudo-targets in p_list, not FIFOs: run_write takes the "p in p_list" branch and updates NO fifo state, only last_diff bookkeeping (instr_pkt_v2.py:210-223). The store is a side effect into AB memory (see reg_sp_write). SYNC produces to "absu{nc}_ablu{nc}:{i}_sync" ×8 rows on put / "self" on get (instr_pkt_v2.py:1001-1013).
- **reg/sp-write:** AB tile write (the unit's sole effect): for each wr_addr (1B granule, >>3 to 8B), the popped raw_data (8 rows × 16×2B) is split into 1B halves and scattered as ab_map[i].mem_lines[wr_addr_8B + j//8].data_1byte[j%8] = data_1B, over i∈0..7 rows, j∈0..15 entries (16B per row → 2 AB 8B addresses) (prec_sim_process.py:1275-1283). RAW-hazard tracking side-writes ab_access[i] and ab_lines[i] under WARN_EN (prec_sim_process.py:1289-1295). No SP/SHM/LRF write. Note "# TODO: if coalesce" (prec_sim_process.py:1271): the coalesce semantics implied by LDSTU's name are not modeled in this handler; it stores raw_data verbatim.
- **extent:** size = url_deg = (burst_sz if burst else 1), then ×4 if interleave_sz==3, ×2 if interleave_sz==2 (instr_pkt_v2.py:958-962); burst_sz falls back to zs_burst_sz if 0 (instr_pkt_v2.py:954-955). This size is the per-packet beat count the scheduler streams (self.size, instr_pkt_v2.py:15). The enclosing MVLOOPCNT replays the whole packet N times, and MVLOOPCNT is in ignored_opcodes (instr_pkt_v2.py:262) so it produces no data packet; it is loop-count control. Total AB writes ≈ size × MVLOOPCNT. The inner 8×16 scatter (prec_sim_process.py:1275-1276) is the fixed 128B-per-beat geometry, independent of size.
- **fire-rule:** Scheduler streams the packet: rd_amt = can_read(); if rd_amt, run_read advances done_read; wr_amt = can_write(); if wr_amt, run_write advances done_write and triggers the absu() store (prim_model.py:301-313). can_read for the xvu port returns min(amt_remaining, state.state["xvu{nc}_absu{nc}"]), so it fires only while the XVU→ABSU FIFO is non-empty (instr_pkt_v2.py:104-120); also gated by is_ofifo_stalled (instr_pkt_v2.py:94-98). can_write to the ab memory-target is unconditional (p in p_list ⇒ can=True, amt=done_read-done_write), and an AB store never back-pressures on a FIFO (instr_pkt_v2.py:130-137). blocked = (rd_amt==0 and wr_amt==0) (prim_model.py:334). Per-write the handler warns (no stall) if a FIFO is empty (prec_sim_process.py:1265-1266).
- **sync-dep:** Explicit SYNC packets: ABSU SYNC fans over all 8 ABLU rows of its ncore: a put produces "absu{nc}_ablu{nc}:{i}_sync", get → consume "ablu{nc}:{i}_absu{nc}_sync" (instr_pkt_v2.py:998-1013). handle_sync decodes typ1_imm bits [0]=put/[1]=get and logs the direction; it has no data effect (prec_sim_process.py:392-409, dispatched at :1256-1257). Data-edge XVU→ABSU is implicit-via-FIFO (the xvu{nc} channel), ordered by the producer XVU's writes and this unit's pops.
- **terminates:** is_done = (size == done_read) and (done_read == done_write) (instr_pkt_v2.py:28-29), so the packet retires when all `size` beats have been both read from the XVU FIFO and written to AB. run_read asserts done_read ≤ size; run_write asserts done_write ≤ done_read (instr_pkt_v2.py:165, 208). The whole instruction (across MVLOOPCNT iterations) ends when the program's loop counter is exhausted (MVLOOPCNT control, not modeled in this packet).
- **inferred / flags:**
  - LDSTU is the coalesce/'update' store variant: INFERRED from name + constr_absu.py:108,162-166 enabling st_coalesce/forbidding src0==src1; the handler (prec_sim_process.py:1271 '# TODO: if coalesce') does NOT actually model coalescing, so the operational store is byte-verbatim regardless of variant.
  - Total AB-write extent = beat-size × MVLOOPCNT iterations: inferred, since MVLOOPCNT is an ignored (control) opcode (instr_pkt_v2.py:262) that replays the packet; the multiplication is not computed in any single line shown.
  - kahn=yes: inferred, since the data path is a single XVU->ABSU FIFO consumer with deterministic FIFO+SYNC ordering and no non-blocking control read on the store path; GETJCR (the NON-KAHN control op) is dispatched away at prec_sim_process.py:1254-1255 before the LDSTU store body, so the LDSTU op itself is Kahn-deterministic.
  - AB store cannot back-pressure: INFERRED from ab0/ab1 being in p_list (instr_pkt_v2.py:131) making can_write unconditional, so it is treated as local memory, not a bounded FIFO; only the upstream xvu FIFO can stall this unit.
  - 8x16 = 128B fixed beat geometry independent of size: inferred, since the i in range(8)/j in range(16) loop (prec_sim_process.py:1275-1276) is hardcoded per popped txn, while size controls how many txns/beats stream; source does not state the per-beat byte count as a field.
- **citations:**
  - `prec_sim_process.py:1253 (ABSUProcess.run signature: ab_addrs, ab_map, ififos)`
  - `prec_sim_process.py:1254-1257 (GETJCR/SYNC dispatch)`
  - `prec_sim_process.py:1264-1269 (pop one txn per input FIFO)`
  - `prec_sim_process.py:1271 (# TODO: if coalesce, coalesce not modeled)`
  - `prec_sim_process.py:1273-1283 (8x16 byte-scatter into ab_map mem_lines)`
  - `prec_sim_process.py:1289-1295 (ab_access/ab_lines RAW-hazard side-write)`
  - `prec_sim_process.py:392-409 (handle_sync put/get decode, log-only)`
  - `constr_absu.py:31 (opcode_options etc:etc = LDST/LDSTU/LDSTI/LDSTIU)`
  - `constr_absu.py:64-104 (burst_sz/interleave_sz field constraints)`
  - `constr_absu.py:162-166 (LDSTU: src0 != src1)`
  - `constr_absu.py:183-188 (src0/src1 are LRF store-base addresses, 16B aligned)`
  - `instr_pkt_v2.py:15 (size = url_deg)`
  - `instr_pkt_v2.py:28-29 (is_done)`
  - `instr_pkt_v2.py:84-120 (can_read; ofifo_stall; xvu FIFO gate)`
  - `instr_pkt_v2.py:122-154 (can_write; ab in p_list ⇒ unconditional)`
  - `instr_pkt_v2.py:949-969 (ABSU LDST family extent + consume xvu / produce ab)`
  - `instr_pkt_v2.py:262 (MVLOOPCNT in ignored_opcodes)`
  - `instr_pkt_v2.py:971-1013 (ABSU SYNC topology, 8-row ABLU fanout)`
  - `prim_model.py:301-334 (run_solve rd_amt/wr_amt/run_read/run_write/blocked)`
  - `main_common.py:458-459,714-733 (run_write -> absu() -> ABSUProcess.run, wr_addrs from mem_txn AB_ADDR WR)`

---

### operational(Control: SYNC / MESYNC)  · kahn: **yes**
<!-- COVOP id=sync-mesync tier=citation-clean kahn=yes ops=SYNC,MESYNC -->

- **in-ports:** put-leg consumes from "self" (sentinel: not a real FIFO; always ready, advances done_read up to size). get-leg consumes from `{peer}_{unit}_sync` counting-channel(s) at 1 decrement/beat, gated on state.state[ch]>0 (a matching peer put() has arrived). Channel set is imm-mask-decoded per unit: NCLU/NCSU SYNC mask_pair={nclu,ncsu,splu0,spsu0,splu1,spsu1} via typ1ac_imm (instr_pkt_v2.py:307-336,396-425); SPLU/SPSU SYNC mask_pair={nclu,ncsu,splu{cur},spsu{cur},splu{nbr},spsu{nbr}} via typ1_imm (518-593); ABLU SYNC=`absu{nc}_ablu{nc}:{row}_sync` (985-997); ABSU SYNC=8x `ablu{nc}:{i}_absu{nc}_sync` i in 0..7 (998-1013); MESYNC get=`d{i}_{nclu|ncsu}_nclu_sync` i in 0..15 (360-376,448-465). NO value/north/west/lrf source: control only (constr_nclu.py:44-67 constrains SYNC by mask, not check_source). put-only SYNC has empty consume_from except "self".
- **out-ports:** put-leg produces to `{unit}_{peer}_sync` counting-channel(s) at +1 increment/beat (run_write: state.state[ch]+=amt), gated on state.max[ch]-state.state[ch]>0 (channel not full). get-leg produces to "self" (sentinel, no real FIFO). Channels mirror in_ports by direction: NCLU put->`nclu_{tag}_sync` (instr_pkt_v2.py:327,333); NCSU put->`ncsu_{tag}_sync` (416,422); SPLU put->`splu{nc}_{tag}_sync` (584,590); ABLU put->`ablu{nc}:{row}_absu{nc}_sync` (988,994); ABSU put->8x `absu{nc}_ablu{nc}:{i}_sync` (1002,1008); MESYNC put->`nclu_d{i}_{nclu|ncsu}_sync` / `ncsu_d{i}_*` (366,373,455,462). both_sync (put&get set) splits into a 2-pkt InstrPktV2Vec: pkt0=put leg, pkt1=get leg, run in one scheduler step (1108-1114, 1133-1219).
- **reg/sp-write:** none. SYNC/MESYNC touch no SP/SHM/AB/LRF data memory; the only state mutated is the integer occupancy counter state.state[`*_sync`] of the control channels (instr_pkt_v2.py run_read:188 dec, run_write:229 inc). handle_sync writes nothing but the log (prec_sim_process.py:409).
- **extent:** size = url_deg = 1 per leg. SYNC blocks never assign `size`, so size stays None and the finalizer leaves url_deg at its default 1 (instr_pkt_v2.py:285,1105-1106) => one put-token and/or one get-token per SYNC instruction. No MVLOOPCNT multiply on the control path (sync is not a data-loop op). both_sync emits two such unit-size pkts (put leg + get leg), each size=1 (1108-1114). MESYNC fans the single put/get token across up to 16 DNC-indexed channels x {nclu,ncsu} targets, but each channel still moves 1 token (360-376).
- **fire-rule:** Beat fires when can_read>0 and/or can_write>0 (prim_model.py:332-335). get-leg readable iff every consumed `_sync` channel has state>0 (instr_pkt_v2.py can_read:110-116); put-leg writable iff every produced `_sync` channel has free space max-state>0 (can_write:140-147 => BACKPRESSURE: a put STALLS when the channel is full, e.g. depth 4 for SPLU<->SPSU, 16 for NC<->SP, 32 for SPLU<->SPSU-nbr). amt=min over channels (120,154). blocked = (rd_amt==0 and wr_amt==0); persistent all-units-blocked => DEADLOCK after threshold (prim_model.py:334-335,348-372,14). Sync channels are excluded from the ofifo-stall data-list, so they are gated only by their own counter, not by downstream data FIFOs (instr_pkt_v2.py:63,110,140,184,225).
- **sync-dep:** This op IS the sync edge. Edges = the named `{producer}_{consumer}_sync` channels with fixed capacities (the put/get rendezvous depth): SPLU<->SPSU & ABLU<->ABSU intra-ncore depth=4; NCLU<->NCSU and NC<->SP(LU/SU) depth=16; SPLU<->SPSU cross-ncore (nbr) depth=32 (prim_run_state_v2.py:36-40,65-69,77-96). MESYNC cross-DNC channels `nclu_d{i}_*_sync` are built dynamically and are NOT in that static max table (instr_pkt_v2.py:360-376 vs prim_run_state_v2.py:11-97); PrecSimPrimitiveRunState sets each one's capacity to 99999 instead (main_common.py:390-401). Producer put() advances the counter, consumer get() drains it => classic Kahn-style blocking rendezvous.
- **terminates:** is_done = (size==done_read) and (done_read==done_write), i.e. the (one) token has been both read and written on the leg (instr_pkt_v2.py:28-29). both_sync vec is done only when ALL legs done (InstrPktV2Vec.is_done:1148-1154). When a 2-leg sync vec completes, an extra finalize branch keyed on vec_size==2 runs (1219-1223).
- **inferred / flags:**
  - MESYNC = cross-DNC barrier semantics: stated in the handler hint and supported by the d{i} (i in 0..15 = per-DNC) channel fan-out, but PrecSim's handle_sync only logs MESYNC and does not itself enforce a barrier; the barrier emerges from the per-DNC put/get channels rendezvousing across DNC processes. Reason: no explicit barrier primitive in handle_sync (prec_sim_process.py:390-391 just selects typ1ad_imm).
  - Kahn classification = yes: SYNC put/get are blocking on bounded FIFO-like counters with deterministic min-amt firing (no data-dependent/non-blocking control like JCR's GETJCR). Reason: gating is purely on channel occupancy vs fixed capacity (can_read:110-116, can_write:140-147), which is the bounded-FIFO Kahn condition; contrast GETJCR which pops non-blockingly (prec_sim_process.py:377-386).
- **citations:**
  - `prec_sim_process.py:389-409 (handle_sync: imm decode + log only, no FIFO effect)`
  - `prec_sim_process.py:434-435,502-503,689-690,1045-1046,1157-1158,1256-1257 (every unit's run() dispatches SYNC -> handle_sync)`
  - `instr_pkt_v2.py:20 (type='sync' if 'SYNC' in opcode)`
  - `instr_pkt_v2.py:300-336 (NCLU SYNC mask_pair + put/get channel build)`
  - `instr_pkt_v2.py:338-376 (NCLU MESYNC: 16 DNC x {nclu,ncsu} cross-DNC channels via typ1ad_imm)`
  - `instr_pkt_v2.py:389-465 (NCSU SYNC + MESYNC, ncsu_* channels)`
  - `instr_pkt_v2.py:557-593 (SPLU SYNC, typ1_imm, cur/nbr ncore channels)`
  - `instr_pkt_v2.py:971-1013 (ABLU per-row + ABSU 8-row SYNC channels)`
  - `instr_pkt_v2.py:285,1105-1106 (size None default -> url_deg=1)`
  - `instr_pkt_v2.py:1108-1114 (both_sync -> 2-leg pkt list put/get)`
  - `instr_pkt_v2.py:28-29 (is_done), 84-120 (can_read gate), 122-154 (can_write/backpressure), 156-238 (run_read dec / run_write inc counter)`
  - `instr_pkt_v2.py:1133-1219 (InstrPktV2Vec: 2-leg both_sync execution + is_done all-legs)`
  - `prim_model.py:332-372 (scheduler: blocked = rd==0 and wr==0; all-blocked->deadlock)`
  - `prim_model.py:14 (DEADLOCK_TIMEOUT_THRESHOLD)`
  - `prim_run_state_v2.py:36-40,65-69,77-96 (sync channel capacities: 4 intra, 16 NC<->SP/NC<->NC, 32 SPLU<->SPSU-nbr)`
  - `main_common.py:390-401 (MESYNC cross-DNC channel capacities: 99999)`
  - `constr_nclu.py:44-67 (SYNC constrained by sync_mask, no value source-class)`
  - the SYNC immediate's bit positions: `families_control.md`'s C2 provenance comment for that immediate. MESYNC shares its put and get bits; its DNC target bits are built in the `instr_pkt_v2.py:338-376` entry above.

---

### operational(SPLU.LDU (SP -> compute feed))  · kahn: **yes**
<!-- COVOP id=splu-ldu tier=citation-clean kahn=yes ops=LDU -->

- **in-ports:** {sp: 1 read per beat}. consume_from is the literal string "sp" set in the SPLU load branch (instr_pkt_v2.py:532), which is the SP scratchpad and NOT a peer compute FIFO. The handler reads two 128B SP lines per address (rd_addr_128B and rd_addr_128B+1) to cover a sub-line spill, then byte-shifts/aligns/rotates per ld_type/ld_rot to form the 8x16B load_data (prec_sim_process.py:697-766). SPLU has no check_source source-class map (constr_splu.py defines only ncore_common@62, apply@202, unfit_opcode@392, make_meta@422, and there is no check_source); the single in-port is fixed by the descriptor via consume_from="sp" (instr_pkt_v2.py:532). src0/src1 are LRF entries holding the SP read address (not data FIFOs): they are aligned to the ld_type granule by the LRF alignment block (constr_splu.py:312-332, lrf[src0]["lrf"]=bit_set(...)). So there is exactly one in-port and it is memory-backed (SP), read at rate = size beats; "sp" sits in the can_read c_list so it contributes amt_remaining unconditionally and never stalls on an upstream FIFO occupancy (instr_pkt_v2.py:101-107).
- **out-ports:** {xvu|vu|spsu: 1 push/beat by ld_consumer; OR self}. produce_to = inst_param_tag(unit, opcode_str, "ld_consumer", ld_consumer) (instr_pkt_v2.py:536), with the cur_ncore_idx suffix appended for non-self targets (instr_pkt_v2.py:543); ld_consumer routes via ld_tgt {0:self, 1:xvu, 2:spsu, 3:vu} (constr_splu.py:55-59), and [cons] forces ld_consumer to follow pkt.produce_to (constr_splu.py:122-128). For ld_consumer!=0 the handler appends load_data (converted to 8 arrays of 2B) to EVERY ofifo in ofifos (prec_sim_process.py:792-795), which is the consumer NCore unit's input FIFO (xvu{nc}/vu{nc}/spsu{nc}). For ld_consumer==0 it is a self-write (no FIFO): ld_type=3 -> LRF[0], ld_type=0 -> JCR[ld_rot], ld_type=1 -> LoadJCR_Buffer; the handler returns (ctx.unit, load_data) instead of pushing a FIFO (prec_sim_process.py:797-814). (The LDUTRF/LDTRF family instead routes produce_to="self" and writes ctx.trf[trf_dst1], a separate path; the {xvu,vu,spsu,self} routing above is the LD/LDU/LDI/LDIU compute-feed path.)
- **reg/sp-write:** SP read decrements sp_access pending-count per 16B granule touched, breaking after the first granule when ld_type>1 (prec_sim_process.py:777-784) and warns on uninitialized SP read (prec_sim_process.py:789-790), and performs no SP store. Self-write side effects occur only when ld_consumer==0: LRF[0] (ld_type=3), JCR[ld_rot] (ld_type=0), or ctx.load_jcr_buffer (ld_type=1, prec_sim_process.py:797-811). LDU as a compute-feed (ld_consumer in {xvu,vu,spsu}) has no LRF/SP/JCR write, so its only effect is the FIFO push (prec_sim_process.py:792-795).
- **extent:** size = url_deg. InstrPktV2.__init__ sets self.size = self.url_deg, i.e. size is derived FROM the url_deg constructor param (instr_pkt_v2.py:15); it is not the other way round. The SPLU load branch computes that size value: burst=0 -> size=1; burst=1 -> size = burst_sz (or 64 if burst_sz==0) (instr_pkt_v2.py:545-551); interleave_sz==2 -> x2, interleave_sz==3 -> x4 (instr_pkt_v2.py:552-555); this size becomes url_deg in the pkt construction. Per-beat the handler iterates sp_addrs (one address per beat, prec_sim_process.py:697). Total elements = size x Pi(enclosing MVLOOPCNT). No data-dependent dynloop on the LDU load path (loop count is the static burst-derived size).
- **fire-rule:** Beat enabled when can_read>0 AND can_write>0. can_read: not ofifo-stalled and done_read<size; since the only in-port "sp" is in c_list it contributes amt_remaining unconditionally (no upstream FIFO occupancy gate) (instr_pkt_v2.py:84-120, c_list @101-107). Backpressure is on the OUTPUT: is_ofifo_stalled returns True when the consumer FIFO state.state[splu_{tgt}] == state.max[splu_{tgt}] (instr_pkt_v2.py:51-82, eq test @69); can_write caps the beat at amt_available = max - min(max,cur_state) for the produce_to FIFO (instr_pkt_v2.py:122-154, cap @147). So a full xvu/vu/spsu input FIFO stalls the load. run_read advances done_read; run_write pushes to the consumer FIFO and advances done_write (instr_pkt_v2.py:156-235). scheduler rd_amt/wr_amt/blocked computed in prim_model.run_solve.
- **sync-dep:** implicit-via-FIFO for the data feed (no SYNC edge inside the LDU path itself). Cross-unit ordering with the consumer (xvu/vu/spsu) is mediated by SP-side SYNC: a separate SPLU.SYNC instruction builds put/get edges to {nclu, ncsu, splu{nc}, spsu{nc}, nbr splu/spsu} via typ1_imm mask bits (instr_pkt_v2.py:557-593); handle_sync logs the (put/get) direction from typ1_imm bits 0/1 (prec_sim_process.py:389-409, put=&0b01 @401, get=&0b10 @403). The LDU producer and its consumer are FIFO-coupled (SPLU pushes, consumer pops), so determinism comes from FIFO+SYNC, not from any edge emitted by the LDU opcode.
- **terminates:** is_done = (size == done_read) and (done_read == done_write) (instr_pkt_v2.py:28-29), so all `size` beats have been read from SP and all have been written to the consumer FIFO (or self-written). run_read asserts done_read<=size (instr_pkt_v2.py:165), run_write asserts done_write<=done_read (instr_pkt_v2.py:208).
- **inferred / flags:**
  - LDU vs LD distinction (unbiased rounding / 'U') is the only per-variant difference; the source shares one handler so this is inferred from the opcode grouping ['LD','LDU','LDI','LDIU'] at prec_sim_process.py:798 and constr_splu.py:35, not from a documented semantic split.
  - 'No dynloop on the LDU feed path' is inferred: the SPLU branch derives size purely from static burst/burst_sz/interleave_sz fields (instr_pkt_v2.py:545-555) with no data-dependent loop, unlike JCR-driven dynloops elsewhere.
  - kahn=yes inferred: the LDU data path uses only FIFO push (produce_to) + SP read with deterministic blocking backpressure (can_write caps on FIFO max); no non-blocking JCR control is in the load path (GETJCR/SENDJCR are separate opcodes dispatched before this code, prec_sim_process.py:686-687).
  - MVLOOPCNT multiplier on extent is inferred from the general instr-packet model (size is per-issue; the enclosing MVLOOPCNT loop replays the packet), and the SPLU branch itself only sets the per-issue size.
  - Mapping ld_consumer integer -> {self=0,xvu=1,spsu=2,vu=3} for the out-port is taken from constr_splu.ld_tgt (constr_splu.py:55-59, the constraint/encoder side); the handler's actual routing uses inst_param_tag(...ld_consumer...) (instr_pkt_v2.py:536), assumed to be the inverse of the same table.
- **citations:**
  - `third_party/rebel_prec_sim/prec_sim_process.py:685 (SPLUProcess.run entry)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:692-694 (ld_consumer/ld_type/ld_rot params)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:697-766 (sp_addrs loop: SP 2-line read + shift/align/rotate -> load_data)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:777-784 (sp_access decrement per 16B granule, break when ld_type>1)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:789-790 (uninitialized-SP read warn)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:792-795 (push load_data to every ofifo)`
  - `third_party/rebel_prec_sim/prec_sim_process.py:797-814 (self-write JCR[ld_rot]/LRF[0]/LoadJCR_Buffer + return (ctx.unit, load_data))`
  - `third_party/rebel_prec_sim/prec_sim_process.py:389-409 (handle_sync; put=&0b01@401, get=&0b10@403)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_splu.py:35 (LD/LDU/LDI/LDIU opcode group)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_splu.py:37 (LDTRF/LDUTRF/LDITRF/LDIUTRF group)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_splu.py:55-59 (ld_tgt self/xvu/spsu/vu)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_splu.py:122-128 (ld_consumer forced to follow pkt.produce_to)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_splu.py:303-306 (LDU/LDUTRF src0!=src1)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/constr_splu.py:312-332 (ld_type alignment of LRF src0/src1 address entries)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:15 (self.size = self.url_deg)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:28-29 (is_done)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:51-82 (is_ofifo_stalled; ==max eq test @69)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:84-120 (can_read + c_list)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:101-107 (sp in c_list contributes amt_remaining unconditionally)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:122-154 (can_write backpressure; amt_available cap @147)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:156-235 (run_read/run_write; done_read<=size@165, done_write<=done_read@208)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:518-555 (SPLU load branch: consume_from=sp@532, produce_to=inst_param_tag(ld_consumer)@536, cur_ncore_idx suffix@543, size@545-555)`
  - `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py:557-593 (SPLU.SYNC mask edges)`

---

### operational(SPSU.STU / ST / STI / STIU / LRFCOPY (compute->SP store / drain))  · kahn: **yes**
<!-- COVOP id=spsu-store tier=citation-clean kahn=yes ops=STU,ST,STI,STIU,LRFCOPY -->

- **in-ports:** Exactly ONE FIFO in-port, selected by st_producer (prec_sim_process.py:1068 reads st_producer; dnc_isa.py:2301-2309 map: 0=zeros/'self'->NO fifo, synthesizes raw_data=[0]*8 prec_sim_process.py:1088-1090; 1=xvu; 2=vu; 3=splu). Resolved to same-NCore producer fifo {xvu|vu|splu}{cur_ncore_idx} (instr_pkt_v2.py:647-654; consume_from = that one unit). 'exactly one' is HARD-ASSERTED, not merely a single-field consequence: constr_spsu.py:117 `assert len(pkt.consume_from) == 1`. Rate: 1 fifo entry/beat popped (fifo.pop(0), prec_sim_process.py:1093); each entry = arr of 16B beats. LRFCOPY: same single producer fifo popped (prec_sim_process.py:1054-1060). SP is NOT a FIFO in-port but the random-access write TARGET, not a channel.
- **out-ports:** Store body: no FIFO out-port, since produce_to="sp" (instr_pkt_v2.py:655), a memory side-effect not a channel; is_ofifo_stalled treats 'sp' as non-stalling (instr_pkt_v2.py:55-61). LRFCOPY: out-port = feedback_q tuple (ctx.unit, raw_data) returned when consume==0, targeting LRF[src0] or JCR[src0] per typ2a_jcr_tgt (prec_sim_process.py:1049-1064); returns None when consume!=0. SYNC variant: writes credit-channel states spsu{i}_{tag}_sync (instr_pkt_v2.py:692-700). Pure data-store path FIFO out: {}.
- **reg/sp-write:** Primary effect: writes store_data (up to 8x16B beats; st_type selects 1/2/4/8 16B granules per beat, prec_sim_process.py:1077-1080) into SP at wr_addr, a 16B-granule offset within the line, spilling across two 128B lines when wr_addr_16B_offset+i exceeds 8 (prec_sim_process.py:1095-1122); sets SP line-valid bits sp_lines_arr[dnc_idx][wr_addr_16B]=True (prec_sim_process.py:1137); records sp_access and raises WARN-SP-RAW-HAZARD on overwrite (prec_sim_process.py:1126-1132). LRFCOPY: writes LRF[src0] or JCR[src0] via the returned feedback_q (prec_sim_process.py:1049-1064). No AB write.
- **extent:** size=url_deg=burst_sz (1..64) when burst set else 1, x interleave multiplier (x4 if interleave_sz==3, x2 if ==2) (instr_pkt_v2.py:656-663; device-side burst default is 64 at instr_pkt_v2.py:657; size==url_deg==self.size instr_pkt_v2.py:13-15). This size = total beats = length of the WR address list mem_txn['SP_ADDR']['WR'] sliced per firing as [curr_size:curr_size+write_amt] (main_common.py:672). The enclosing MVLOOPCNT loop replays the whole pkt per loop iteration (Pi over MVLOOPCNT). Not data-dependent (no dynloop on this path; st_type only sizes per-beat 16B count, not the loop). Inner per-beat granule count = data_16B_num in {1,2,4,8} (prec_sim_process.py:1077-1080).
- **fire-rule:** Scheduler drives pkt via can_read/can_write (prim_model.py:301-313). can_read returns min over consume_from of granted amt: stalls if ofifo (n/a here, only 'sp'), or if producer fifo state {producer}_spsu{i} <=0 (instr_pkt_v2.py:104-116), so there is backpressure on the upstream xvu/vu/splu->spsu credit running dry. can_write for produce_to=='sp' is always grantable (amt=done_read-done_write, no max cap, instr_pkt_v2.py:130-137). So SPSU stalls only when the source compute FIFO is empty; it never stalls on the SP write side. blocked = (rd_amt==0 and wr_amt==0) (prim_model.py:334). zeros-producer (st_producer==0) never reads a fifo so it is read-unconstrained (synthesizes zeros). NOTE: the handler's empty-fifo zeros fallback (prec_sim_process.py:1086-1090) is a defensive in-handler path subordinate to scheduler can_read backpressure (enforced upstream by the producer credit), so it does not weaken the Kahn/backpressure claim.
- **sync-dep:** Explicit SYNC opcode handled by handle_sync (prec_sim_process.py:1046 dispatch, base 389-409): SPSU uses typ1_imm ('sp' in unit -> imm_fld=typ1_imm, prec_sim_process.py:394-395); put/get bits decode to credit edges (prec_sim_process.py:402-405) over mask_pair {nclu, ncsu, splu{i}, spsu{i}, splu_nbr, spsu_nbr} (instr_pkt_v2.py:672-701; constr_spsu.py:43-48 sync_mask: nclu=0 ncsu=1 splu=2 spsu=3 nbr_splu=4 nbr_spsu=5). MESYNC uses typ1ad_imm (prec_sim_process.py:391). For the data-store path the producer->SPSU ordering is implicit-via-FIFO (the {xvu|vu|splu}_spsu credit channel), not an explicit SYNC.
- **terminates:** is_done when size==done_read and done_read==done_write (instr_pkt_v2.py:28-29), so all `size` beats have been read from the producer fifo AND written to SP. Vector-level done = all pkts done (instr_pkt_v2.py:1148-1154). run_read asserts done_read<=size (instr_pkt_v2.py:165), run_write asserts done_write<=done_read (instr_pkt_v2.py:208). The MVLOOPCNT loop terminates when its loop count is exhausted (pkt reset+replayed per iteration).
- **inferred / flags:**
  - MVLOOPCNT enclosure: INFERRED that the pkt is replayed once per MVLOOPCNT iteration, since main_common.py slices the WR address list per firing (write_amt, main_common.py:672) and the run_solve loop re-runs pkts; the explicit loop-count register isn't read inside SPSUProcess.run, so the per-loop replay is the engine's outer behavior, not visible in this unit's handler.
  - Kahn=yes: inferred, since the data-store path is FIFO-blocking (can_read stalls on the single producer credit, deterministic, instr_pkt_v2.py:104-116) with no non-blocking control branch; the in-handler empty-fifo zeros fallback (prec_sim_process.py:1086-1090) is defensive and subordinate to that upstream backpressure, so it does not introduce nondeterminism. LRFCOPY/GETJCR/SYNC are control ops but resolve through the same blocking fifo pop or credit-state edges, so the family stays deterministic. GETJCR is the only potential NON-KAHN sibling but it is a distinct opcode (handle_get_jcr, prec_sim_process.py:366), not part of the STU/LRFCOPY store family.
  - SPSU has no check_source: INFERRED that the in-port source-class is fully given by st_producer/inst_param_tag (dnc_isa.py:2301-2309) rather than a north/west/lrf check_source like TU/VU/XVU, confirmed by the absence of check_source in constr_spsu.py (only constr_tu.py/constr_xvu.py/constr_vu.py define it).
  - interleave_sz semantics: INFERRED that interleave x2/x4 multiplies the beat count (size) per instr_pkt_v2.py:660-663; the run() handler itself does not re-read interleave_sz, so the interleave reshaping is encoded entirely in the address-list length / pkt size upstream.
  - NOTE: the prior 'exactly one in-port' inference has been UPGRADED to source-backed, being a hard runtime assert at constr_spsu.py:117 (`assert len(pkt.consume_from) == 1`), not merely a consequence of st_producer being a single 2-bit field; it is therefore no longer carried as inferred.
- **citations:**
  - `prec_sim_process.py:1035 (class SPSUProcess)`
  - `prec_sim_process.py:1041 (run signature: sp_addrs, sp, sp_lines_arr, ififos, sp_access, sync_dir)`
  - `prec_sim_process.py:1042-1046 (GETJCR / SYNC early-out dispatch)`
  - `prec_sim_process.py:1049-1064 (LRFCOPY: pop one producer fifo, return feedback_q to LRF/JCR)`
  - `prec_sim_process.py:1067-1068 (st_type, st_producer read)`
  - `prec_sim_process.py:1077-1080 (st_type -> data_16B_num 1/2/4/8)`
  - `prec_sim_process.py:1082-1083 (st_producer==0 -> ififos={ctx.unit:[]} i.e. zeros)`
  - `prec_sim_process.py:1086-1094 (empty-fifo synthesizes zeros vs fifo.pop(0))`
  - `prec_sim_process.py:1093 (fifo.pop(0) store-path)`
  - `prec_sim_process.py:1095-1122 (SP 16B-granule write + 128B spill)`
  - `prec_sim_process.py:1126-1132 (WARN-SP-RAW-HAZARD)`
  - `prec_sim_process.py:1137 (sp_lines_arr valid-bit set)`
  - `prec_sim_process.py:389-409 (handle_sync, sp->typ1_imm, put/get decode); MESYNC->typ1ad_imm @391`
  - `prec_sim_process.py:366-388 (handle_get_jcr base, sibling early-out)`
  - `main_common.py:669-687 (spsu() dispatch); WR slice [curr_size:curr_size+write_amt] @672`
  - `instr_pkt_v2.py:13-15 (size=url_deg=self.size)`
  - `instr_pkt_v2.py:28-29 (is_done)`
  - `instr_pkt_v2.py:55-61 (is_ofifo_stalled: 'sp' non-stalling)`
  - `instr_pkt_v2.py:104-116 (can_read backpressure on producer credit; 'sp'/'self'/'ext' read-unconstrained)`
  - `instr_pkt_v2.py:130-137 (can_write 'sp' always grantable, amt=done_read-done_write)`
  - `instr_pkt_v2.py:165 (run_read assert done_read<=size)`
  - `instr_pkt_v2.py:208 (run_write assert done_write<=done_read)`
  - `instr_pkt_v2.py:639-663 (SPSU store pkt build: st_producer/burst/burst_sz/interleave_sz -> consume_from one unit, produce_to='sp', size; consume_from+=cur_ncore_idx @653-654)`
  - `instr_pkt_v2.py:665-701 (SPSU SYNC mask_pair credit edges)`
  - `instr_pkt_v2.py:1148-1154 (vec is_done)`
  - `prim_model.py:171-184 (init_policy__1: spsu{ncore} in ncore unit priority list @178)`
  - `prim_model.py:253-478 (run_solve); can_read/run_read/can_write/run_write @301-313, blocked=(rd_amt==0 and wr_amt==0) @334`
  - `dnc_isa.py:459 (st_producer bitpos [30,29])`
  - `dnc_isa.py:607 (param_dict SPSU LRFCOPY), 609-628 (ST/STU w/ src1), 629-630 (STI/STIU typ2_imm)`
  - `dnc_isa.py:2301-2309 (st_producer tag: 0=zeros 1=xvu 2=vu 3=splu)`
  - `constr_spsu.py:50-54 (st_src self=0/xvu=1/vu=2/splu=3)`
  - `constr_spsu.py:43-48 (sync_mask nclu=0..nbr_spsu=5)`
  - `constr_spsu.py:116-122 (st_producer forced to follow pkt.consume_from); hard assert len(pkt.consume_from)==1 @117`

---

### operational(NCSU.STSU (SP -> SHM store))  · kahn: **yes**
<!-- COVOP id=ncsu-stsu tier=citation-clean kahn=yes ops=STSU -->

- **in-ports:** {sp:burst/beat}, with consume_from="sp" (instr_pkt_v2.py:385). NOT a FIFO compute in-port: NCSU has no constr_ncsu.check_source (grep: only TU/VU/XVU define check_source); the read source is SP memory, addressed by sp_addrs. In run() the zip-loop header `for rd_addr, wr_addr in zip(sp_addrs, ext_addrs)` drives the iteration (prec_sim_process.py:502, committed HEAD); the actual SP byte-read sp.buf[rd_addr*128:+128] happens inside the branch bodies, at prec_sim_process.py:523 on the SHM-target path and prec_sim_process.py:545 on the cross-SP-target path (line 502 is only the loop driver, not itself a buf-read). "sp" is in can_read's local c_list so it never FIFO-stalls, contributing amt_remaining each beat (instr_pkt_v2.py:101,104-107).
- **out-ports:** {ext:burst/beat}, with produce_to="ext" (instr_pkt_v2.py:386). Destination resolved per-beat by apply_NC_TLB on the write addr (prec_sim_process.py:504): if wr_paddr>=REBEL_SHM_PA_BASE_128B -> SHM write shm.buf[shm_addr*128:+128]=sp.buf[rd_addr*128:+128] + shm_lines[shm_addr]=True (prec_sim_process.py:506,523-524); else cross-SP write sp_arr[wr_sp_idx].buf[...]=sp.buf[rd_addr...] (prec_sim_process.py:526-545). For STSU the SHM branch is the intended path (SP->SHM store). "ext" is in can_write's local p_list -> never FIFO-stalls (instr_pkt_v2.py:130,135-137). No DNC-peer / inter-unit FIFO is appended on the STSU path.
- **reg/sp-write:** SHM byte-store shm.buf[shm_addr*128 : +128] per beat + sets shm_lines[shm_addr]=True valid bit (prec_sim_process.py:523-524, committed HEAD); on the alternate (non-SHM) target, cross-SP byte-store sp_arr[wr_sp_idx].buf[...] (prec_sim_process.py:545). Read-side validity warn-only check WARN-UNINIT-SP on sp_lines_arr[dnc_idx] for rd_addr lines (prec_sim_process.py:547-553). No LRF/SP-of-own-unit register write (NCSU is an address/move unit).
- **extent:** size = url_deg = burst (instr_pkt_v2.py:15,387; the NCSU store pkt-build branch sets size=burst), where burst=get_fld(...,"burst") and burst==0 is remapped to 32 in the make_pkt_info NCSU branch (instr_pkt_v2.py:382-383). The inverse encode-side rule (burst==32 -> 0) is mirrored in the constraint generator (constr_ncsu.py:144-145). Range 1..32 (constr_ncsu.py:100 asserts 0<pkt.size<=32). Total transferred = burst (128B granules) x enclosing MVLOOPCNT iterations (MVLOOPCNT is in ignored_opcodes/self:self and sets the loop count, instr_pkt_v2.py:262, not a pkt). The per-packet extent is static, with no dynloop on the store path.
- **fire-rule:** Per beat the scheduler computes rd_amt=can_read, wr_amt=can_write; advances while either >0, blocked when both 0 (prim_model.py:301,308,334). can_read: src "sp" is local -> amt = size-done_read, only ofifo-stall gate applies (instr_pkt_v2.py:91-107); since produce_to="ext" is also local, is_ofifo_stalled returns no stall (instr_pkt_v2.py:55-59). can_write: "ext" local -> amt = done_read-done_write (instr_pkt_v2.py:129-137). Net: STSU is backpressure-free (both ports local memory, not credited FIFOs) and drains burst granules in lock-step read-then-write. Per-variant: STC/STCU instead splat a 16B const into sp_addrs and forbid ext txns (prec_sim_process.py:493-499), and STSU does NOT take that branch; STMG/STMGU set apply_NC_TLB va_force ("G" in opcode -> bypass TLB, prec_sim_process.py:401-403) whereas STSU goes through nc_tlb page translation.
- **sync-dep:** implicit-via-ordering on the store data path: STSU itself emits no SYNC/JCR edge. Cross-unit ordering with NCLU/SPLU/SPSU producers that filled SP is enforced by separate NCSU SYNC pkts: SYNC builds consume_from/produce_to "ncsu_<tag>_sync"/"<tag>_ncsu_sync" over mask_pair {nclu,ncsu,splu0,spsu0,splu1,spsu1} (instr_pkt_v2.py:389-425; constr_ncsu.sync_mask:44-50), and MESYNC adds per-DNC "ncsu_d{i}_{nclu|ncsu}_sync" edges (instr_pkt_v2.py:427-465). handle_sync only logs direction put/get from the imm field (prec_sim_process.py:377-397, committed HEAD). These SYNC pkts are real FIFO/credit edges; the STSU data pkt is not.
- **terminates:** pkt is_done when size==done_read and done_read==done_write (instr_pkt_v2.py:28-29), so all burst granules are read from SP and written to ext. run_solve completes when every unit's pkt iterator is exhausted AND init_decode done (all_finished, prim_model.py:349-363,377-378); else deadlock detection on no-progress all-blocked (prim_model.py:382-386).
- **inferred / flags:**
  - STSU specifically targets SHM (SP->SHM store) rather than the cross-SP branch. The reason: the SHM branch (prec_sim_process.py:506) is selected by wr_paddr>=SHM_BASE, which the SP-write store opcode is configured to hit; the handler body is address-class-dispatched, not opcode-dispatched, so source does not hard-code STSU=SHM.
  - The 'U' (update) suffix on STSU vs STS denotes a post-store address auto-increment (consistent with NCLU LDMU auto-advance noted in repo memory); the run() body here shows identical data-copy for both, so the increment is an addressing/decode-side effect not visible in this handler. This is inferred rather than stated in this file.
  - Per-beat granule = 128B fixed: derived from the slice width sp.buf[rd_addr*128:+128] / shm.buf[shm_addr*128:+128] (prec_sim_process.py:523,545), i.e. 1 granule per zipped (sp_addr,ext_addr) pair; burst = number of granules.
  - kahn=yes: the STSU data pkt has only local-memory ports (sp,ext) with no credited FIFO and no non-blocking control (no JCR on this path), and cross-unit ordering rides deterministic SYNC FIFO edges, hence deterministic. (GETJCR/SENDJCR in the same unit ARE the NON-KAHN control paths but are different opcodes, prec_sim_process.py:487-488,583-663.)
- **citations:**
  - `prec_sim_process.py:486 (NCSUProcess.run signature, committed HEAD)`
  - `prec_sim_process.py:487-488 (GETJCR dispatch -> handle_get_jcr)`
  - `prec_sim_process.py:493-499 (STC/STCU const branch, NOT taken by STSU)`
  - `prec_sim_process.py:502 (Basic ST zip-loop header: zip(sp_addrs, ext_addrs), the loop driver rather than a buf-read)`
  - `prec_sim_process.py:504 (apply_NC_TLB on write addr)`
  - `prec_sim_process.py:506,523-524 (SHM target branch: wr_paddr>=SHM_BASE, SP->SHM copy at 523, shm_lines[shm_addr]=True at 524)`
  - `prec_sim_process.py:526-545 (alternate cross-SP target; cross-SP SP-read+write at 545)`
  - `prec_sim_process.py:547-553 (WARN-UNINIT-SP read-validity check)`
  - `prec_sim_process.py:377-397 (handle_sync, log only)`
  - `prec_sim_process.py:400-409 (apply_NC_TLB; G->va_force bypass at 401-403)`
  - `instr_pkt_v2.py:378-387 (NCSU store pkt-build branch: opcode set {STM,STMU,STC,STCU,STS,STSU,STMG,STMGU} at 379, consume_from='sp' at 385, produce_to='ext' at 386, size=burst at 387)`
  - `instr_pkt_v2.py:382-383 (make_pkt_info NCSU branch: burst==0 -> burst=32, the correct burst remap; replaces the prior mis-cite to prec_sim_process.py:381-383, which is GETJCR feedback_key logic at committed HEAD lines 368-370)`
  - `instr_pkt_v2.py:15 (size=url_deg)`
  - `instr_pkt_v2.py:28-29 (is_done)`
  - `instr_pkt_v2.py:55-59,91-120 (can_read; sp/ext local, ofifo-stall)`
  - `instr_pkt_v2.py:122-154 (can_write)`
  - `instr_pkt_v2.py:262 (MVLOOPCNT in ignored_opcodes)`
  - `instr_pkt_v2.py:389-465 (NCSU SYNC at 389-425 / MESYNC at 427-465 edge construction)`
  - `constr_ncsu.py:37 (etc:etc store opcode set incl STS/STSU)`
  - `constr_ncsu.py:44-50 (sync_mask)`
  - `constr_ncsu.py:99-104,144-145 (burst spec: assert 0<size<=32 at 100; encode-side burst==32 -> 0 at 144-145)`
  - `prim_model.py:301,308,334 (run_solve rd_amt at 301 / wr_amt at 308 / blocked at 334)`
  - `prim_model.py:349-363,377-378 (all_finished termination)`
  - `prim_model.py:382-386 (deadlock detection)`

---

### operational(NC JCR control: LOADJCR / SENDJCR / GETJCR (NON-KAHN))  · kahn: **NON-KAHN**
<!-- COVOP id=nc-jcr tier=citation-clean kahn=no ops=LOADJCR,SENDJCR,GETJCR -->

- **in-ports:** LOADJCR: consume_from="sp", size=1 -- one 128B SP line at sp_addrs[0] (instr_pkt_v2.py:467-471; handler reads sp.buf[(rd_addr)<<7:(rd_addr+1)<<7] at prec_sim_process.py:580). SENDJCR: consume_from="self", NO FIFO read -- data from unit-local reg ctx.load_jcr_buffer set by prior LOADJCR (instr_pkt_v2.py:489; raises InstrUsageError if unset at prec_sim_process.py:604-605). GETJCR: reads ONE JCR FIFO, consume_from="uan_<unit><ncore?>[:row]_jcr" (instr_pkt_v2.py:1086-1094); handler ififo_name=f"uan_{ctx.unit}_jcr" (prec_sim_process.py:368; ABLU strips :0 at 369-370), pops 1 entry/fire (377). TU/ABLU dnc-scope carry :row_idx (instr_pkt_v2.py:1092-1093). Rate: GETJCR 1/fire; LOADJCR 1 SP line/fire.
- **out-ports:** LOADJCR: produce_to="self", {} no FIFO write -- side effect only (instr_pkt_v2.py:470; sets ctx.load_jcr_buffer at prec_sim_process.py:580). SENDJCR: produce_to = list of "uan_<tgt>[:i]_jcr" FIFOs; per fire pushes size=popcount(strb) 2B grains, EACH grain broadcast to every selected target (strb-bits x tgt_arr loop at prec_sim_process.py:666-672 / 1016-1022). Targets = consumer_mask (7 bits over [spsu,splu,absu,ablu,xvu,vu,tu]) gated by scope: NCSU uses core_id -- 0->{ncsu,nclu}; 3->NC units + BOTH ncores' 7 units (mask x3); else->ncore[core_id>>1]'s 7 units (prec_sim_process.py:647-653, instr_pkt_v2.py:492-513). SPLU targets ncore_idx-local 7 units only, no core_id (prec_sim_process.py:1000-1003, instr_pkt_v2.py:614-628). tu/ablu targets fan out to 8 rows (:0..:7) at dnc scope (prec_sim_process.py:659-663 / 1009-1013, instr_pkt_v2.py:509-511,624-626). GETJCR: produce_to=["self"] -- no FIFO; returns (feedback_key, jcr_data) to inter-proc feedback_q (instr_pkt_v2.py:1095; prec_sim_process.py:380-384).
- **reg/sp-write:** LOADJCR: writes unit-local ctx.load_jcr_buffer (8x16B, split8_rev of the 128B SP line) -- prec_sim_process.py:580. SENDJCR: read+modify ctx.send_jcr_offset_reg (mod-16 offset register; +1 if offset_inc, =0 if offset_rst, base if offset_mode==1) -- prec_sim_process.py:608-620 / 964-977; increments ctx.txn_ctr -- 675/1025. GETJCR: pops from JCR ififo (decrements its occupancy) and returns into feedback_q; no SP/AB/LRF write -- prec_sim_process.py:377-384. LOADJCR/SENDJCR read SP and unit regs only; no SHM/AB/LRF writes.
- **extent:** Per-fire url_deg from instr_pkt_v2 size: LOADJCR size=1 (instr_pkt_v2.py:471); SENDJCR size=popcount(strb), min 1 (instr_pkt_v2.py:480-486 / 602-608); GETJCR size unset -> url_deg=1 default (instr_pkt_v2.py:285,1086-1095,1105). Total = size x enclosing MVLOOPCNT iteration count (MVLOOPCNT is in ignored_opcodes, not a packet -- it sets the program loop counter that re-fires the JCR packets; instr_pkt_v2.py:261-272). No dynloop/data-dependent extent in these ops.
- **fire-rule:** Scheduler run_solve drives can_read then can_write per packet (prim_model.py:301-313). can_read: amt=min over consume_from of remaining vs FIFO occupancy; "jcr" channels keyed by raw name not unit-prefixed (instr_pkt_v2.py:110-111). LOADJCR fires when SP readable (sp is in c_list, always avail). SENDJCR consume_from="self" -> read trivially ready (instr_pkt_v2.py:105-107). GETJCR fires only when its source JCR FIFO occupancy>0 (instr_pkt_v2.py:115). Backpressure (can_write): SENDJCR is_ofifo_stalled checks each target "*_jcr" against state.max -> stalls if a target JCR FIFO is full (instr_pkt_v2.py:63-69,140-146). PrecSimPrimitiveRunState sets each JCR FIFO's state.max to 99999 (main_common.py:311-319). GETJCR_FIFO_DEPTH=4 is a soft warning only (prec_sim_process.py:46,374-375) -- pop is non-blocking, does not gate firing. blocked = (rd_amt==0 and wr_amt==0) (prim_model.py:334).
- **sync-dep:** No SYNC/MESYNC edges -- JCR ops never enter handle_sync (prec_sim_process.py:389-409 keys on opcode SYNC/MESYNC only; JCR opcodes route to handle_get_jcr / the LOADJCR/SENDJCR branches before any sync check at run() heads e.g. 499-503, 686-690). Ordering is implicit-via-FIFO occupancy only (JCR FIFO push/pop), with NO sync handshake gating producer vs consumer -- this is the NON-KAHN property (handler hint @640: non-blocking, no SYNC edge -> order-sensitive).
- **terminates:** Per-packet is_done when size==done_read==done_write (instr_pkt_v2.py:28-29): LOADJCR after 1 SP read+self-write; SENDJCR after popcount(strb) grains read-from-self and written to all targets; GETJCR after 1 pop. Program-level: the unit's pkt stream ends when the pkt iterator advances past the active pkt array -- the break on `states.pkt_i[u] >= len(p_arr)` (prim_model.py:322); the JCR loop region terminates when its MVLOOPCNT counter is exhausted. (prim_model.py:404-405 is only the all-blocked diagnostic pprint of the same pkt_i>=len / dcd_done condition, not the control-flow break.)
- **inferred / flags:**
  - TU SENDJCR: TUProcess run head dispatches GETJCR (prec_sim_process.py:2518) but I did not locate a TU-side SENDJCR branch; the producer SENDJCR handlers I confirmed live in NCSU and SPLU only -- TU appears consumer-only (GETJCR) in this source. Reason: grep found SENDJCR producer bodies at 595/953 (NCSU/SPLU) and no TU branch.
  - check_source classification: constr_ncsu.py / constr_splu.py have no live check_source mapping JCR src fields to north/west/lrf/reuse/zero. I classified SENDJCR src as 'self/register' (ctx.load_jcr_buffer) and GETJCR src as a 'jcr' FIFO directly from the handler + instr_pkt_v2 consume_from, since constr offered no field-level source map for these. Note: constr_splu.py:334-339 is a JADD/JSUB/JIMMCOPY/JSHR/JCMP/JSWAP/JARITH src0/src1 4-bit guard (J-register control ops), NOT a strb guard and NOT a JCR data-source map; the strb 4-bit handling lives in instr_pkt_v2 (format(strb,'04b'), instr_pkt_v2.py:478-481/600-603) and in the handlers (prec_sim_process.py:637/994). Reason: no check_source JCR entry in either constr file.
  - NON-KAHN justification: inferred from absence of any SYNC edge on JCR ops (handle_sync not reached) + non-blocking pop (GETJCR depth is warn-only) + handler hint, meaning producer/consumer interleaving is scheduler-order-sensitive rather than FIFO-blocking-deterministic. The FIFO push/pop itself IS bounded (can_write stalls on full), so partial determinism exists; the non-Kahn aspect is the lack of a blocking read handshake making cross-unit visibility order-dependent.
- **citations:**
  - `prec_sim_process.py:46 (GETJCR_FIFO_DEPTH=4)`
  - `main_common.py:311-319 (JCR FIFO capacities: 99999)`
  - `prec_sim_process.py:366-386 (handle_get_jcr: ififo_name, pop, feedback_key)`
  - `prec_sim_process.py:389-409 (handle_sync gates SYNC/MESYNC only)`
  - `prec_sim_process.py:498-503 (NCSU run head: GETJCR/SYNC dispatch)`
  - `prec_sim_process.py:569-592 (LOADJCR: SP->load_jcr_buffer)`
  - `prec_sim_process.py:595-675 (NCSU SENDJCR: core_id fanout, offset reg, strb x tgt push)`
  - `prec_sim_process.py:647-653 (NCSU core_id target sets)`
  - `prec_sim_process.py:659-663 (tu fan to 8 rows)`
  - `prec_sim_process.py:666-675 (grain x target broadcast + txn_ctr)`
  - `prec_sim_process.py:685-690 (SPLU run head)`
  - `prec_sim_process.py:953-1025 (SPLU SENDJCR: ncore-local fanout)`
  - `prec_sim_process.py:1000-1003 (SPLU ncore_idx targets)`
  - `prec_sim_process.py:1439/2005/2518 (GETJCR dispatch: VU/XVU/TU)`
  - `instr_pkt_v2.py:28-29 (is_done)`
  - `instr_pkt_v2.py:63-69,110-111,140-146,184-188,225-229 (jcr channel keying in stall/read/write)`
  - `instr_pkt_v2.py:261-272 (MVLOOPCNT in ignored_opcodes)`
  - `instr_pkt_v2.py:285,1105 (url_deg default 1; override if size set)`
  - `instr_pkt_v2.py:467-471 (LOADJCR consume=sp size=1)`
  - `instr_pkt_v2.py:473-516 (SENDJCR size=popcount(strb), core_id target build)`
  - `instr_pkt_v2.py:595-628 (SPLU SENDJCR target build)`
  - `instr_pkt_v2.py:1086-1095 (GETJCR consume_from jcr, produce self)`
  - `prim_model.py:301-313,334 (run_solve: can_read/can_write/blocked)`
  - `prim_model.py:322 (program-level termination break on pkt_i>=len(p_arr))`
  - `constr_ncsu.py / constr_splu.py: NO field-level check_source source-class map for LOADJCR/SENDJCR/GETJCR -- their consume/produce (self/sp/jcr) come from instr_pkt_v2, not a north/west/lrf/reuse/zero classifier (constr_ncsu.py:16-32 active self:self list omits all JCR opcodes; constr_splu.py:334-339 is a J-register-control src 4-bit guard, not a JCR data-source map)`

---

### operational(TU.FMA, the systolic MAC array, one actor per cell, 8 rows by 2 NCores per DNC)  · kahn: **yes**  · ⚠ citations working-tree-relative
<!-- COVOP id=tu-fma tier=content-verified kahn=yes ops=FMA note=wt-relative-refs -->

- **in-ports:** Up to 3 srcs; each src field is classified by ConstrTU.fma_src (constr_tu.py:81-94) into FIFO-port vs LRF/const. FIFO in-ports: first NORTH, with src0=0xD, src1=0xD, src2=0x1 → remapped (prec_sim_process.py:2488-2494) to `xvu{ncore}` if row_idx==0 else `tu{ncore}:{row-1}_south`; 1 elem/beat. Second WEST, with src1=0xE, src2=0x2 → `ablu{ncore}:{row_idx}` (prec_sim_process.py:2489-2490); 1 elem/beat, carries the stationary/streamed operand (the A·B west feed). Non-FIFO srcs (read from state, no FIFO pop): LRF (src0/src1=0x0..0xB, src2 has none), reuse (src0=0xC, last_src_reg), zero/one-const (src0=0xF, src1=0xF, src2=0x3). check_source returns has_src=[T,T,T] for every fma opcode (constr_tu.py:1171-1175); a src whose resolved type is not north/west is downgraded to has_srcs[i]=False at prec_sim_process.py:2531 so only north/west actually consume a FIFO. consume_from in the pkt is built identically at instr_pkt_v2.py:883-898 (W→ablu, N→xvu/tu_south, else self). Rate per FIFO src = url_amt elems over the instruction (1/beat).
- **out-ports:** Single south out-edge selected by row (prec_sim_process.py:2554-2565): `tu{ncore}:{row}_south` enabled when row_idx<7 (feeds the cell below), OR `vu{ncore}` enabled when row_idx==7 (drains the column accumulate into VU). Emission is gated by data_type=tgts (params:2551, written:2679-2698): tgts=0x1→forward src0_data, 0x2→forward src2_data, 0x3→forward computed result; tgts=0x0→no south write (out_data stays None, line 2695 `out_data is not None` AND `out_d['en']`). At the row7→VU drain the values are right-shifted >>2 for ALL nonzero tgts (tgts in {1,2,3}, the HP→16b accumulate-drain rounding): tgts==3 at 2680-2681, tgts==2 at 2685-2686, tgts==1 at 2690-2691, and each path applies `el >> 2` only when row_idx==7. Distinct from this is roundup_16b_force, which is set at :2666 for row7 & tgts==3 only (or ctx.rup16). produce_to in the pkt mirrors the row-select (instr_pkt_v2.py:905-911): south_tgt>0 → vu{ncore} if row7 else tu{ncore}:{row}_south, else 'self'. 1 elem/beat, url_amt total.
- **reg/sp-write:** LRF write-back: when is_tgtrf (tgtrf<=0xB, prec_sim_process.py:2548) the FMA result is written to LRF[tgtrf] inside sim() (the systolic-array partial-sum / weight register). tgtrf unrolls by tgturl across the url loop (2577). reuse-cache: ctx.last_src_reg['src0/1/2'] updated every beat (2640-2642) for src=reuse. No SP/SHM/AB writes from TU (those are SPSU/ABSU). skip_comp (2567) elides the compute+LRF write entirely when tgte==0 AND tgts==0 AND not is_tgtrf (a pure pass-through/NOP-ish cell).
- **extent:** Per-instruction size = url_deg = 1 << bit_acc(url,[4,3]) ∈ {1,2,4,8} (instr_pkt_v2.py:879; pkt.size=url_deg at :15). The run() loop `for i in range(curr_size, curr_size+amt)` (prec_sim_process.py:2572) processes the scheduler-granted chunk `amt` of that size; src/tgt addresses unrolled by url_s0/s1/s2/url_tgt (2542-2546, 2574-2577). Total work = url_deg elems × the enclosing MVLOOPCNT replication of the pkt at the scheduler level (MVLOOPCNT is a common_opcode handled outside run(), constr_tu.py:56 / instr_pkt_v2.py:262, and it re-issues the FMA pkt loop_cnt times). dynloop: NOT present for TU.FMA, since the extent is static (url_deg×MVLOOPCNT), no data-dependent JCR-driven loop count on the compute path.
- **fire-rule:** Scheduler-driven (prim_model.run_solve:253-336): the actor fires when rd_amt=can_read(...)>0 AND/OR wr_amt=can_write(...)>0; blocked = (rd_amt==0 and wr_amt==0) at :334. can_read (instr_pkt_v2.py:84-120) grants min over consume_from of available FIFO occupancy (state.state[c_unit]) capped at size-done_read; returns 0 (stall) if any input FIFO empty OR if is_ofifo_stalled. Backpressure: is_ofifo_stalled (51-82) blocks when any produce_to FIFO is full (state==max), AND specially when the TU's downstream `{unit}_vu{nc}` edge is full (72-80), so a row stalls if its south/VU consumer can't accept. run_read/run_write advance done_read/done_write; FIFO src popped at end of beat (2700-2707, with the src-aliasing guard: src1 not popped if it equals src0's FIFO, src2 not popped if equal to src1/src0).
- **sync-dep:** implicit-via-FIFO for the systolic dataflow (north/west/south edges are ordinary FIFOs; cross-row ordering is the tu:{row-1}_south → tu:{row} chain). TU.FMA itself emits no SYNC: handle_sync (prec_sim_process.py:377-387) returns immediately for `tu` units (only MESYNC/ab/sp/nc set an imm field; the else:return at 386-387 covers tu); GETJCR is dispatched separately (2505-2506) and is the only control-plane entry. So FMA has no MESYNC/SYNC edge of its own, and phase alignment with XVU (north feed at row0) and VU (south drain at row7) is carried entirely by FIFO occupancy/backpressure.
- **terminates:** pkt.is_done (instr_pkt_v2.py:28-29): size==done_read AND done_read==done_write, so the instruction completes when all url_deg elems have been both read and written through. The actor's whole program ends when its pkt index passes the decoded stream (run_solve all_finished/all_blocked bookkeeping :348-363); deadlock if all units blocked for BLOCKED_IT_THRESHOLD iterations (:382-386, threshold const at :16).
- **inferred / flags:**
  - The three named roles (weight-load / FMA_SYS-accumulate / accumulate-drain) map to ONE shared FMA instruction differentiated by port wiring, not distinct opcodes. Inferred: the source has a single fma_opcodes handler; 'weight-load' = LRF-targeted tgtrf write with reuse/lrf srcs, 'FMA_SYS' = north(prev-row south)+west feed with LRF accumulate, 'drain' = row7→vu with nonzero tgts and >>2 shift. No role tag exists in source.
  - MVLOOPCNT multiplies total extent by replicating the pkt at the scheduler. Inferred from MVLOOPCNT being a common_opcode (constr_tu.py:56) / ignored_opcode (instr_pkt_v2.py:262) handled outside TUProcess.run() and run() only covering one url_deg-sized pkt; the exact loop_cnt threading lives in the decode/scheduler layer not shown in run().
  - No dynloop on the FMA path. Inferred: the TU's only control entry is GETJCR (prec_sim_process.py:2505-2506) which feeds JCR control regs, but the compute extent is url_deg (static); no data-dependent loop bound is read in run().
  - Kahn=yes. Inferred: all TU.FMA edges are blocking FIFOs with occupancy-gated can_read/can_write and no non-blocking control writes on the compute path (GETJCR is a separate dispatch, not part of the FMA actor's data firing); determinism follows from FIFO+backpressure with no JCR side-channel in the MAC loop.
  - src2 'zero' slot actually injects a 1.0 constant (one_dl/one_bf/one_fp9) rather than 0. Inferred from prec_sim_process.py:2622-2626 comment '# actually one'; relevant because the multiply-by-one identity uses the same 0x3 encoding the constr labels 'zero'.
  - WEST=the A·B streamed operand and NORTH=the partial-sum from the row above. Inferred from the systolic topology (west=ablu load face, north=upstream tu south / xvu at row0); source gives the wiring but not the matmul-operand semantics.
- **citations:**
  - `constr_tu.py:68 (unit='TU')`
  - `constr_tu.py:81-94 (fma_src: src0 north=0xD/reuse=0xC/zero=0xF/lrf=0x0..0xB; src1 north=0xD/west=0xE/zero=0xF; src2 north=0x1/west=0x2/zero=0x3)`
  - `constr_tu.py:1166-1175 (check_source: fma_opcodes branch → has_src0/1/2=True at 1171-1173, return 1175)`
  - `constr_tu.py:33-44 (fma_opcodes datatype list FMA..F8F8MABF, shared handler)`
  - `constr_tu.py:38 (ZSFMA/ZSFMABF commented OUT of fma_opcodes)`
  - `constr_tu.py:49 (zs_opcodes = ['ZSFMA','ZSFMABF'], a separate list)`
  - `prec_sim_process.py:2488-2494 (TUProcess.fifo_name_remap: west→ablu{nc}:{row}, row0→xvu{nc}, else tu{nc}:{row-1}_south)`
  - `prec_sim_process.py:2504-2511 (run(); GETJCR dispatch at 2505-2506 + check_source/sim_non_comp dispatch)`
  - `prec_sim_process.py:2516-2533 (resolve src type; non-north/west downgraded has_srcs[i]=False at 2531, no FIFO appended)`
  - `prec_sim_process.py:2542-2551 (url_amt, url_s0/1/2/tgt, is_tgtrf/tgtrf/tgte/tgts)`
  - `prec_sim_process.py:2554-2565 (output dict: tu{nc}:{row}_south en=row<7, vu{nc} en=row==7, data_type=tgts)`
  - `prec_sim_process.py:2567 (skip_comp when tgte==0 and tgts==0 and not is_tgtrf)`
  - `prec_sim_process.py:2572-2577 (range(curr_size,curr_size+amt) + url unroll of src0/1/2/tgtrf)`
  - `prec_sim_process.py:2587-2628 (per-src read: FIFO src_arr[0][0] vs lrf/reuse/zero/one-const; src2 'zero'=one at 2622-2626)`
  - `prec_sim_process.py:2640-2642 (last_src_reg reuse-cache write)`
  - `prec_sim_process.py:2646-2668 (sim() compute + LRF write; TUInfo roundup_16b_force=(row7 & tgts==3) or ctx.rup16 at 2666)`
  - `prec_sim_process.py:2679-2698 (south/VU write gated by data_type/en; row7 >>2 drain shift for tgts==3 at 2680-2681, tgts==2 at 2685-2686, tgts==1 at 2690-2691; out gated by out_data is not None and en at 2695)`
  - `prec_sim_process.py:2700-2707 (FIFO pop with src-aliasing guard)`
  - `prec_sim_process.py:377-387 (handle_sync: else:return at 386-387 covers 'tu' units; no TU SYNC)`
  - `instr_pkt_v2.py:15 (size=url_deg)`
  - `instr_pkt_v2.py:28-29 (is_done = size==done_read and done_read==done_write)`
  - `instr_pkt_v2.py:51-82 (is_ofifo_stalled incl tu→vu full-stall 72-80)`
  - `instr_pkt_v2.py:84-120 (can_read min over inputs, stall on empty/ofifo)`
  - `instr_pkt_v2.py:122-154 (can_write min over outputs, backpressure on full)`
  - `instr_pkt_v2.py:879 (url_deg = 1<<bit_acc(url,[4,3]))`
  - `instr_pkt_v2.py:883-898 (consume_from: W→ablu{nc}:{row}, N→xvu{nc}|tu{nc}:{row-1}_south, else self)`
  - `instr_pkt_v2.py:905-911 (produce_to: south_tgt>0 → vu{nc} if row7 else tu{nc}:{row}_south, else self)`
  - `instr_pkt_v2.py:912 (ZSFMA routed through its own 2-src branch, distinct from fma)`
  - `prim_model.py:253-336 (run_solve fire: rd_amt=can_read/wr_amt=can_write, blocked=(rd_amt==0 and wr_amt==0) at 334)`
  - `prim_model.py:16,382-386 (BLOCKED_IT_THRESHOLD const + deadlock counter/threshold)`
  - `constr_tu.py:56 + instr_pkt_v2.py:262 (MVLOOPCNT is a common_opcode/ignored_opcode handled outside run())`

---

### operational(VU compute (FMA/FCMP + the ALU family, FMAHP hpmode))  · kahn: **yes**  · ⚠ citations working-tree-relative
<!-- COVOP id=vu-compute tier=content-verified kahn=yes ops=FMA,FCMP,ALU,FMAHP note=wt-relative-refs -->

- **in-ports:** FIFO in-ports decided by ConstrVU.check_source (constr_vu.py:568) + src_tag; only src classes in {xvu,tu,splu} are FIFO reads (prec_sim_process.py:1483-1485). nbr(0x3), lrf, nfwd, reuse, const_reg, slice_id, imm are NON-FIFO (read from ctx / params, no pop), and nbr is a candidate src class but is not in the [tu,xvu,splu] FIFO set (prec_sim_process.py:1483), so it is read as misc/non-FIFO like the others. Per FIFO src, run() pops 1 elem/iter via src_arr[k][0] then .pop(0) (:1485-1487, :1714-1721): tu -> fifo_name_remap=f"tu{ncore_idx}:7" (the TU drain port, row7) (:1338-1342); xvu -> f"xvu{ncore_idx}"; splu -> f"splu{ncore_idx}". Pkt-model consume_from = [f"{tag}{cur_ncore_idx}" for xvu/splu, f"tu{cur_ncore_idx}:7" for tu] (instr_pkt_v2.py:831-838); none -> "self" (self-clocked). Rate=1 pop/iter/active-FIFO-src; total iters = amt (= size on a full fire). type2 reads src0+src1+src2 (src0 from {xvu/tu/splu/nbr/nfwd/reuse/lrf}, src1 from {.../const_reg}, src2 from {.../nfwd}) per type2_src (constr_vu.py:104-117); type3 reads src0+src2, has_src1=False (:583-586). IADD is listed in type3_opcodes but check_source treats it as the type3 exception: it uses type2_src and re-enables has_src1, so it reads src0+src1+src2 like a type2 (constr_vu.py:592-594). FMUL/FMULBF drop src2; EE/SHR/SPLAT/FEST(+bf) drop src2; GCVT/ICVT/SELECT/LOGICAL conditionally drop a src (:595-605). Dedup: a src FIFO is popped only if its class differs from the lower src's class (:1714-1721).
- **out-ports:** Out dict keyed by ncore_idx (prec_sim_process.py:1511-1520): spsu{ncore_idx} (data_type=out_sp) and xvu{ncore_idx} (data_type=out_xvu). fifo handles from ofifos.get(...). Pkt-model produce_to (instr_pkt_v2.py:841-849): for tgt in {sp->spsu{idx}, xvu->xvu{idx}} with out_val>0; nbr excluded; none -> "self". A port is written only when out_data is non-None: data_type==3 -> computed result slices from self.out_arr masked by slice_en_mask (the active write at :1701; note :1703-1705 are commented-out dead code, the old elif==2/==1 branches); the data_type==2 passthrough copy of src2_data is at :1625 and data_type==1 passthrough of src0_data at :1630 (the live passthrough path in the main loop preamble, :1624-1633); ==0 -> not written. Append is (txn_id, out_data) at :1709. Rate=1 push/iter per enabled out-port. Note out_nbr exists in params but is NOT a FIFO port here (excluded from produce_to; only feeds skip_comp gating :1531).
- **reg/sp-write:** LRF write when is_lrf_tgt (lrf_tgt>=0x10): SPLAT writes ctx.lrf[lrf_tgt][slice][lane] directly (:1646-1656); sim_128b writes ctx.lrf[lrf_tgt] per slice_en (:1791-1793); sim() writes LRF (rounded to 24b when is_lrf_tgt, roundup_24b flag :1680); in hpmode the +8 companion LRF[(lrf_tgt+8)%16] is also written by sim() (gated opcode!=FRNDHP, evt1/evt0-dependent 8b-LSB path, :1912-1932. Note that :1693 is only a debug log of that companion, not the write). IMMCOPY (sim_non_comp) writes ctx.lrf[lrf_tgt] from immediate (:1726-1752). Side state: ctx.last_src_reg["src0/1/2"] updated each iter for the 'reuse' class (:1613-1615); ctx.cmp_flag_valid set True for FCMP/FMINMAX/ICMP/IMINMAX only (:1888), and SELECT is NOT in that set (SELECT appears only in is_using_cmp_flag at :1522, which gates a debug print, not state; :1689 is likewise a CMP_FLAG logging/read line, not the set); ctx.txn_ctr incremented per iter (:1723). No SP/SHM/AB direct memory writes (those go out via the spsu FIFO, drained by SPSU).
- **extent:** Per-pkt extent = url_deg = 1 << bit_acc(url,[1,0]) i.e. 2^(url&0b11) in {1,2,4,8} (instr_pkt_v2.py:824); pkt.size = url_deg (:15). Inside run() the per-instruction loop is for i in range(curr_size, curr_size+amt) (:1535), where curr_size=done_read and amt is the scheduler-granted read amount this tick. url-unroll bits (url&0b100/01000/10000/100000) bump src0/src1/src2/lrf_tgt by i per iteration (url_s0/s1/s2/url_tgt :1499-1503, :1537-1539). The MVLOOPCNT enclosing repeat-count is applied upstream by the pkt builder (MVLOOPCNT is in ignored_opcodes for pkt-making, instr_pkt_v2.py:261-262) -> total fires = MVLOOPCNT * url_deg. No data-dependent dynloop in the VU compute path (dynloop is a JCR/control-plane construct, absent here).
- **fire-rule:** Scheduler beat (prim_model.run_solve :295-336): rd_amt=pkt.can_read(states) then run_read(rd_amt); wr_amt=pkt.can_write then run_write(wr_amt); blocked = (rd_amt==0 and wr_amt==0) (:334). can_read returns min over consume_from of remaining vs available FIFO occupancy, and is gated by is_ofifo_stalled (instr_pkt_v2.py:84-120): VU stalls when any produce_to FIFO (spsu{idx}/xvu{idx}) is at max (backpressure). can_write returns min(done_read-done_write, out-FIFO free space) (:122-154). So VU fires when (its tu:7/xvu/splu input FIFOs are non-empty for every active src) AND (its spsu/xvu output FIFO has room); self-clocked ("self") pkts fire on done_read<size with no FIFO dependency.
- **sync-dep:** implicit-via-FIFO. handle_sync (prec_sim_process.py:389-407) returns early for unit=="vu" (only MESYNC / ab / sp / nc units pick an imm field; the trailing else: return at :397-398 covers vu) -> VU emits/consumes NO explicit SYNC tokens. Ordering vs producers (TU drain on tu:7, SPLU, peer XVU) and consumers (SPSU, XVU) is enforced purely by FIFO occupancy/backpressure in run_solve, not by SYNC edges.
- **terminates:** pkt.is_done = (size==done_read) and (done_read==done_write) (instr_pkt_v2.py:28-29). I.e. the VU instruction retires once all url_deg/amt elements have been read AND written out (or self-consumed). At the loop level, run() returns after the final i in range(curr_size,curr_size+amt) iteration with src FIFOs popped (:1714-1721) and txn_ctr advanced (:1723).
- **inferred / flags:**
  - MVLOOPCNT*url_deg = total fires: inferred, since MVLOOPCNT is in ignored_opcodes (instr_pkt_v2.py:261) so the repeat-count is applied by the pkt-replication layer outside this handler; the handler only sees per-tick (curr_size,amt) and per-pkt url_deg.
  - amt == size on a full fire: INFERRED from run_solve calling can_read which returns min(amt_remaining, available), so amt is the granted slice this tick, not necessarily the whole pkt; over the pkt's life the sum of amt == size.
  - out_nbr is not a FIFO port: inferred, since it is read into params and gates skip_comp (prec_sim_process.py:1531) but is explicitly excluded from produce_to (instr_pkt_v2.py:843 'if tgt != nbr'); the nbr path is the inter-slice forwarding handled inside prec_sim.so, not a unit-level FIFO.
  - no data-dependent dynloop: inferred, since VU compute opcodes carry a static url_deg; the only data-dependent loop construct (REDUCE) is statically expanded via reduce_payload into a fixed FMA/PACK/etc., not a runtime-variable trip count.
  - kahn=yes rationale: inferred, since the VU has no handle_sync edges and all I/O is through occupancy-gated FIFOs (blocking reads/writes in run_solve), which is the Kahn determinism condition; no non-blocking control (JCR is handled by the separate GETJCR path at :1438, not the compute loop).
- **citations:**
  - `prec_sim_process.py:1432 (VUProcess.run signature: ififos,ofifos,curr_size,amt)`
  - `prec_sim_process.py:1451-1453 (hpmode opcode rewrite FMA->FMAHP/FNMS->FADDHP/FMUL->FRNDHP)`
  - `prec_sim_process.py:1465-1467 (no src -> sim_non_comp branch)`
  - `prec_sim_process.py:1483-1485 (FIFO src classes tu/xvu/splu -> fifo_name_remap -> ififos[fifo_name]; nbr/others excluded)`
  - `prec_sim_process.py:1338-1342 (fifo_name_remap: tu->{u}{ncore}:7, else {u}{ncore})`
  - `prec_sim_process.py:1499-1503 (url unroll bits url_s0/s1/s2/url_tgt)`
  - `prec_sim_process.py:1511-1520 (output dict spsu{idx}/xvu{idx} with data_type out_sp/out_xvu)`
  - `prec_sim_process.py:1522 (is_using_cmp_flag list incl SELECT, which gates a debug print only)`
  - `prec_sim_process.py:1531 (skip_comp gate uses out_nbr/out_sp/out_xvu/lrf_tgt)`
  - `prec_sim_process.py:1535 (for i in range(curr_size, curr_size+amt))`
  - `prec_sim_process.py:1624-1633 (out_data passthrough data_type 2->src2 :1625, 1->src0 :1630)`
  - `prec_sim_process.py:1701 (data_type==3 -> out_arr masked by slice_en_mask; :1703-1705 commented-out dead code)`
  - `prec_sim_process.py:1709 (append (ctx.txn_id, out_data[out_unit]))`
  - `prec_sim_process.py:1714-1721 (src_arr pop with class-dedup)`
  - `prec_sim_process.py:1646-1656 (SPLAT direct LRF write)`
  - `prec_sim_process.py:1791-1793 (sim_128b LRF write)`
  - `prec_sim_process.py:1680 (roundup_24b = is_lrf_tgt)`
  - `prec_sim_process.py:1888 (ctx.cmp_flag_valid=True for FCMP/FMINMAX/ICMP/IMINMAX, with SELECT excluded)`
  - `prec_sim_process.py:1693 (debug log of LRF[(lrf_tgt+8)%16], NOT the write)`
  - `prec_sim_process.py:1912-1932 (sim() hpmode +8 companion LRF[(lrf_tgt+8)%16] write, opcode!=FRNDHP, evt1/evt0 8b-LSB path)`
  - `prec_sim_process.py:1613-1615 (last_src_reg src0/1/2 update)`
  - `prec_sim_process.py:1723 (ctx.txn_ctr += 1)`
  - `prec_sim_process.py:1726-1752 (IMMCOPY LRF write in sim_non_comp)`
  - `prec_sim_process.py:389-407 (handle_sync: vu falls to else->return at :397-398, no SYNC)`
  - `constr_vu.py:568 (check_source)`
  - `constr_vu.py:104-129 (type2_src/type3_src class->field maps: xvu0x1,tu0x2,nbr0x3,splu0x4,nfwd0x8,reuse0x9,lrf0x10-0x1F,const_reg0xA-0xF)`
  - `constr_vu.py:578-605 (has_src0/1/2 per opcode class + FMUL/EE/GCVT/ICVT/SELECT/LOGICAL special-casing)`
  - `constr_vu.py:592-594 (IADD exception: in type3_opcodes but uses type2_src + has_src1=True)`
  - `constr_vu.py:16-72 (type2_opcodes incl FMAHP/FADDHP/FRNDHP+bf at :37-50; type3_opcodes incl IADD at :51-72; ZSFMA not present in any list)`
  - `instr_pkt_v2.py:13-29 (url_deg/size, is_done at :28-29)`
  - `instr_pkt_v2.py:824 (url_deg = 1<<bit_acc(url,[1,0]))`
  - `instr_pkt_v2.py:831-838 (consume_from from src_tag xvu/splu->{tag}{idx}, tu->tu{idx}:7)`
  - `instr_pkt_v2.py:841-849 (produce_to sp->spsu{idx}/xvu, nbr excluded)`
  - `instr_pkt_v2.py:84-120 (can_read + is_ofifo_stalled backpressure)`
  - `instr_pkt_v2.py:122-154 (can_write free-space)`
  - `instr_pkt_v2.py:261-262 (MVLOOPCNT in ignored_opcodes for pkt-making)`
  - `prim_model.py:295-336 (run_solve: rd_amt/wr_amt beat; blocked=(rd_amt==0 and wr_amt==0) at :334)`

---

### operational(XVU compute (XVUProcess, subclass of VUProcess))  · kahn: **NON-KAHN**  · ⚠ citations working-tree-relative
<!-- COVOP id=xvu-compute tier=content-verified kahn=no ops=XVUProcess note=wt-relative-refs -->

- **in-ports:** No north/west mesh inputs (unlike TU). FIFO in-ports are intra-NCore: splu{ncore} and/or vu{ncore}, read from ififos[fifo_name], fifo_name=fifo_name_remap=f"{unit}{ncore}" (prec_sim_process.py:1980-1981). check_source FIFO tags: 'splu' (field 0x1; 0x1/0x2/0x3 mode=1) and 'vu' (0x5; 0x5/0x6/0x7 mode=1); ONLY these two are pulled from FIFOs (prec_sim_process.py:2035-2037, src tag in {vu,splu} -> ififos[fifo_name]). Rate=1 elem/fire-iter per active FIFO src; a FIFO shared across srcs popped once (prec_sim_process.py:2298-2305). Condition: src tag in {splu,vu} AND has_src[i] true (per opcode/mode). NON-FIFO src classes (not in-ports): lrf=0x10..0x1F (ctx.lrf), const_reg=0xA..0xF (ctx.const_reg[mode]), nfwd=0x8 (make_nfwd of ctx.lrf[lrf_tgt]), reuse=0x9 (ctx.last_src_reg), slice_id=0x6, raw immediate (field maps constr_xvu.py:110-158).
- **out-ports:** Output dict keyed spsu{ncore}, absu{ncore}, vu{ncore}, tu{ncore}:0 (prec_sim_process.py:2070-2087), each gated by data_type field out_sp/out_ab/out_vu/out_tu (params prec_sim_process.py:2059-2062). data_type semantics: 0=no write (skip); 1=forward src0_data (pass-through prec_sim_process.py:2177-2181); 2=forward src2_data (pass-through prec_sim_process.py:2172-2176); 3=compute result self.out_arr masked by slice_en (prec_sim_process.py:2282-2284). Write rate=1 elem/fire-iter per enabled tgt; appended as (txn_id, row-list) to out_d["fifo"] (prec_sim_process.py:2295). tu{} tgt re-packs 16B->18B rows (prec_sim_process.py:2293). out_nbr exists in params but NCLU neighbor path is forced 0 (constr_xvu.py:326-327) and never built into produce_to ('nbr' skipped, instr_pkt_v2.py:766). "{}" when out_sp=out_ab=out_vu=out_tu=0 and no lrf_tgt (consumer-only / pure-LRF op).
- **reg/sp-write:** LRF write-back (non-FIFO side effect): when is_lrf_tgt (params['lrf_tgt']>=0x10, prec_sim_process.py:2054), ctx.lrf[lrf_tgt] updated per slice gated by slice_en_mask (sim_xvu prec_sim_process.py:2450-2452, sim_128b prec_sim_process.py:2387-2389, SPLAT inline prec_sim_process.py:2211-2220). cmp_flag side effect is TWO distinct writes: (a) the cmp_flag DATA array is populated by the C func via the ctx.cmp_flag_ptr handed in at prec_sim_process.py:2413 (k["cmp_flag_arr_ptr"]=ctx.cmp_flag_ptr); (b) the cmp_flag_valid GATE is set True for FCMP/FMINMAX/ICMP/IMINMAX at prec_sim_process.py:2443-2444. SELECT only READS cmp_flag and raises if not cmp_flag_valid (prec_sim_process.py:2405-2406) -- i.e. set-vs-read are split: the compare opcodes SET the flag, SELECT READS it. ctx.last_src_reg['src0/1/2'] updated each iter for 'reuse' (prec_sim_process.py:2162-2164). LFSR opcodes touch ctx.lfsr via lfsr_arr_ptr (prec_sim_process.py:2414). IMMCOPY (sim_non_comp) writes ctx.lrf only (prec_sim_process.py:2338). No direct SP/SHM/AB memory write from XVU (those are SPSU/ABSU's job downstream of the FIFOs).
- **extent:** Per-fire extent (url_deg / pkt.size) on the GENERAL (non-REDUCE) path = 1 << bit_acc(url,[1,0]) in {1,2,4,8} (instr_pkt_v2.py:744; InstrPktV2.size=url_deg :15; the constraint set url_amts=[1,2,4,8] is enforced at constr_xvu.py:331-334). The REDUCE path is the exception: url_amts=[1,2,3,4] so size can also be 3 (constr_xvu.py:513-516, url_deg = index+1). This is the inner unroll loop: run() iterates for i in range(curr_size, curr_size+amt) (prec_sim_process.py:2103), and url_s0/s1/s2/tgt bits (url bits 2..5, prec_sim_process.py:2049-2053) add +i to each src/lrf_tgt addr per iter (prec_sim_process.py:2105-2108). Total work = pkt.size x enclosing MVLOOPCNT. MVLOOPCNT is an ignored_opcode for packet-building (instr_pkt_v2.py:262) i.e. a program-level repeat count applied outside the pkt, not in pkt.size. No data-dependent dynloop on the XVU compute path (REDUCE remaps to a fixed url_deg, constr_xvu.py:513-516).
- **fire-rule:** Driven by scheduler prim_model.run_solve (prim_model.py:298-335): per beat rd_amt=pkt.can_read(states), if >0 run_read; wr_amt=pkt.can_write(states), if>0 run_write (invokes the run() compute hook); blocked = (rd_amt==0 and wr_amt==0) (prim_model.py:334). can_read (instr_pkt_v2.py:84-120): amt_remaining=size-done_read; first checks is_ofifo_stalled (output FIFO at max -> rd_amt=0, BACKPRESSURE :94-98); then for each FIFO consume_from needs state.state[f"{c}_{unit}"]>0, returns min over srcs. can_write (instr_pkt_v2.py:122-154): amt=done_read-done_write, each produce_to needs free slots (max-cur)>0, returns min over tgts. So XVU stalls if any input FIFO empty OR any output FIFO full.
- **sync-dep:** handle_sync (prec_sim_process.py:377-387) returns early for XVU: it only handles units whose ctx.unit name contains 'ab'/'sp'/'nc' or the MESYNC opcode; XVU falls through the else -> return (no-op, prec_sim_process.py:386-387). Note the unit identity: self.unit='vu' (set at XVUProcess construction) while the per-instance name is ctx.unit (e.g. xvu{ncore}); the no-op holds either way because neither 'vu' nor 'xvu{n}' contains the substrings 'ab'/'sp'/'nc'. XVU compute has NO explicit SYNC edge handling in its run(); cross-unit ordering is implicit-via-FIFO (splu/vu input FIFOs + spsu/absu/tu/vu output FIFOs with the scheduler's backpressure). The only non-FIFO control edge is GETJCR (handle_get_jcr, prec_sim_process.py:354-374).
- **terminates:** InstrPktV2.is_done (instr_pkt_v2.py:28-29): (size==done_read) and (done_read==done_write) i.e. all url_deg elements read AND written. run_read asserts done_read<=size (instr_pkt_v2.py:165), run_write asserts done_write<=done_read (instr_pkt_v2.py:208). Whole-sim termination (prim_model.run_solve, all_finished at :377-378 / deadlock branch :382-386) = all units done or all_blocked (deadlock), with BLOCKED_IT_THRESHOLD deadlock counter.
- **inferred / flags:**
  - KAHN classification = NON-KAHN: the data ALU/encode path itself (splu/vu FIFOs in, spsu/absu/tu/vu FIFOs out, blocking can_read/can_write) is Kahn-deterministic, but the family's run() also dispatches GETJCR (prec_sim_process.py:1992-1993, handle_get_jcr) which is a non-blocking control-register pop into the inter-process feedback queue (warns rather than stalls when over GETJCR_FIFO_DEPTH, :362-363) and SELECT carries hidden control state via ctx.cmp_flag_valid set by a prior FCMP/compare (read+raise at :2405-2406, set at :2443-2444); these make the unit-as-a-whole non-Kahn. Reason: presence of JCR control-plane port + cross-instruction cmp_flag dependency.
  - Enclosing MVLOOPCNT supplies curr_size/amt to run(): inferred from MVLOOPCNT being an ignored_opcode (not a pkt) plus run() looping over a caller-supplied (curr_size,amt) window; the exact MVLOOPCNT->amt wiring is in the program decoder/dispatcher not shown in the read files. Reason: the loop variable origin is upstream of these handlers.
  - out_ports='{}' (consumer/LRF-only) case is inferred from data_type all-zero + is_lrf_tgt path writing only ctx.lrf; not an explicitly named branch. Reason: derived from the output-dict gating, not a labeled empty-output code path.
  - data_type==3 = 'computed result' vs 1/2 = 'pass-through src0/src2' interpretation inferred from the assignment sites (:2282-2284 reads self.out_arr; :2172-2181 copies src data). Reason: the field is numeric in source with no symbolic enum.
  - 'no data-dependent dynloop on XVU compute path' inferred from url_deg being a static field (1<<url bits) and REDUCE remapping to fixed url_deg (constr_xvu.py:513-516); no sigma.JCR-driven loop count seen in run(). Reason: absence of evidence in the read handler, not an explicit assertion.
- **citations:**
  - `prec_sim_process.py:1933 (class XVUProcess(VUProcess))`
  - `prec_sim_process.py:1986 (run signature: ififos,ofifos,curr_size,amt)`
  - `prec_sim_process.py:1989-1990 (mode, lanes)`
  - `prec_sim_process.py:1992-1993 (GETJCR -> handle_get_jcr)`
  - `prec_sim_process.py:2004-2006 (FMAHP/FADDHP/FRNDHP rewire)`
  - `prec_sim_process.py:2014-2015 (check_source -> src_dict[mode])`
  - `prec_sim_process.py:2017-2019 (no-src -> sim_non_comp)`
  - `prec_sim_process.py:2035-2037 (src tag in {vu,splu} -> ififos[fifo_name])`
  - `prec_sim_process.py:1980-1981 (fifo_name_remap)`
  - `prec_sim_process.py:2049-2053 (url_amt and url_s0/s1/s2/tgt unroll bits)`
  - `prec_sim_process.py:2054 (is_lrf_tgt = lrf_tgt>=0x10)`
  - `prec_sim_process.py:2059-2062 (out_sp/ab/vu/tu data_type params)`
  - `prec_sim_process.py:2070-2087 (output dict spsu/absu/vu/tu:0)`
  - `prec_sim_process.py:2103-2108 (for i in curr_size..+amt; per-iter unroll add)`
  - `prec_sim_process.py:2116-2123,2131-2137,2143-2152 (lrf/reuse/const_reg/nfwd src reads for src0/src1/src2)`
  - `prec_sim_process.py:2162-2164 (last_src_reg update for reuse)`
  - `prec_sim_process.py:2172-2181,2282-2284 (data_type 2/1 pass-through, 3 compute)`
  - `prec_sim_process.py:2293,2295 (tu 16B->18B repack; fifo.append((txn_id,data)))`
  - `prec_sim_process.py:2298-2305 (FIFO pop; shared-src pop-once)`
  - `prec_sim_process.py:2245-2246,2393,2399 (sim_vu/sim_xvu dispatch by mode; defs)`
  - `prec_sim_process.py:2405-2406 (SELECT reads cmp_flag, raises if not cmp_flag_valid)`
  - `prec_sim_process.py:2413 (cmp_flag DATA array via ctx.cmp_flag_ptr handed to C func)`
  - `prec_sim_process.py:2414 (lfsr_arr_ptr = ctx.lfsr_ptr)`
  - `prec_sim_process.py:2443-2444 (cmp_flag_valid=True set for FCMP/FMINMAX/ICMP/IMINMAX)`
  - `prec_sim_process.py:2450-2452 (sim_xvu LRF write-back, slice_en masked)`
  - `prec_sim_process.py:2387-2389 (sim_128b LRF write-back, slice_en masked)`
  - `prec_sim_process.py:2211-2220 (SPLAT inline LRF write-back)`
  - `prec_sim_process.py:2310-2346 (sim_non_comp IMMCOPY -> ctx.lrf write at :2338)`
  - `prec_sim_process.py:354-374 (handle_get_jcr, non-Kahn; GETJCR_FIFO_DEPTH warn :362-363)`
  - `prec_sim_process.py:377-387 (handle_sync no-op for non-ab/sp/nc unit; else->return :386-387)`
  - `constr_xvu.py:41-49 (class-level type2_opcodes; IADD commented out :48)`
  - `constr_xvu.py:50-76 (class-level type3_opcodes; IADD listed :75)`
  - `constr_xvu.py:110-158 (type2_src/type3_src: splu/vu/nbr/slice_id/nfwd/reuse/lrf/const_reg field maps, mode0/mode1)`
  - `constr_xvu.py:326-327 (out_nbr forced 0)`
  - `constr_xvu.py:331-334 (url -> url_deg = index of pkt.size in [1,2,4,8])`
  - `constr_xvu.py:513-516 (REDUCE url_amts=[1,2,3,4], size can be 3)`
  - `constr_xvu.py:704-761 (check_source: has_src0/1/2 per opcode and mode)`
  - `constr_xvu.py:728-730 (IADD override -> type2_src + has_src1=True, functionally 3-src)`
  - `instr_pkt_v2.py:7-15 (size=url_deg)`
  - `instr_pkt_v2.py:28-29 (is_done)`
  - `instr_pkt_v2.py:744 (XVU url_deg = 1<<bit_acc(url,[1,0]))`
  - `instr_pkt_v2.py:757-779 (consume_from splu/vu; produce_to spsu/absu/tu:0; 'nbr' skipped :766)`
  - `instr_pkt_v2.py:84-120 (can_read: ofifo_stall + per-src FIFO level)`
  - `instr_pkt_v2.py:122-154 (can_write: per-tgt free slots)`
  - `instr_pkt_v2.py:262 (MVLOOPCNT in ignored_opcodes)`
  - `prim_model.py:298-335 (run_solve rd_amt/wr_amt/blocked loop)`
  - `prim_model.py:377-386 (termination all_finished / deadlock)`

---

### operational(NCLU.LDMU/LDSU/LDM (SHM -> SP load; cross-DNC partial accumulate))  · kahn: **yes**  · ⚠ citations working-tree-relative
<!-- COVOP id=nclu-load tier=content-verified kahn=yes ops=LDMU,LDSU,LDM note=wt-relative-refs -->

- **in-ports:** consume_from="ext" (single logical in-port; instr_pkt_v2.py:296). "ext" is in the can_read local list c_list (instr_pkt_v2.py:101) so it carries NO FIFO backpressure, being a memory-read port, not an inter-unit FIFO. The actual read bytes come from ext_addrs = SHM_ADDR.RD + DRAM_ADDR.RD + LBUS_ADDR.RD sliced [curr_size:curr_size+write_amt] (main_common.py:576-582), each addr a 128B granule; after apply_NC_TLB (prec_sim_process.py:442) the read targets either shm.buf (prec_sim_process.py:455) or sp_arr[rd_sp_idx].buf (prec_sim_process.py:457-470). Cross-DNC: rd_sp_idx = (rd_paddr - REBEL_SP_PA_BASE_128B) >> 15 indexes the full sp_arr (all DNCs' SPs, prec_sim_process.py:459,470), so an LDS may read a peer DNC's SP by PA. LDC/LDCU take NO ext in-port: ld_const synthesizes the source (prec_sim_process.py:428-431, asserts ext_addrs empty at :426). SYNC variants instead consume from real *_nclu_sync FIFO ports (instr_pkt_v2.py:335) and GETJCR consumes from uan_nclu_jcr (instr_pkt_v2.py:1089-1094).
- **out-ports:** produce_to="sp" (single logical out-port; instr_pkt_v2.py:297). "sp" is in the can_write local list p_list (instr_pkt_v2.py:130) so it carries NO FIFO backpressure, so writes are unconditional memory writes, not credited FIFO pushes. Destination = sp_addrs = SP_ADDR.WR sliced [curr_size:curr_size+write_amt] (main_common.py:581-583); the write is a 128B byte-copy sp.buf[wr_addr*128 : +128] (prec_sim_process.py:455,470) into the LOCAL DNC SP (sp = sp_arr[dnc_idx], main_common.py:595). One sp.buf 128B write per (rd_addr,wr_addr) pair in the zip (prec_sim_process.py:434). No inter-unit FIFO is written by the load path; SYNC variants instead write nclu_<tgt>_sync FIFO ports (instr_pkt_v2.py:333) which DO hit max-credit backpressure.
- **reg/sp-write:** Primary side effect: SP byte-write into local DNC SP at wr_addr*128 (prec_sim_process.py:438 for LDC, :455 SHM-src, :470 SP-src). SP valid-line tracking: sp_lines_arr[dnc_idx][wr_addr_16B]=True for the 128 16B sublines, only when log_level<=DEBUG_LEVEL[3] (prec_sim_process.py:473-476). LDC/LDCU also mutate the local ext_addrs list in-place from the immediate (prec_sim_process.py:431). No LRF write on the load path. (SENDJCR/LOADJCR mutate ctx.load_jcr_buffer / ctx.send_jcr_offset_reg but those are NCSU ops, not NCLU.)
- **extent:** size = url_deg = burst, where burst = get_fld(...,"burst") with burst==0 remapped to 32 (instr_pkt_v2.py:292-294, :298, :1106; self.size=self.url_deg at instr_pkt_v2.py:15). Range 1..32 enforced (constr_nclu.py:106 assert 0<size<=32; burst==32→0 encoding at constr_nclu.py:150-151). One packet moves `burst` 128B granules (one per consumed unit). The enclosing MVLOOPCNT is a SEPARATE self:self NCLU opcode (constr_nclu.py:17, in opcode_options["self:self"]) that re-issues the load PC for K>burst, and it is NOT multiplied into url_deg here. No dynloop on the load path (NCLU loads have static burst extent; data-dependent dynloop applies to JCR/control opcodes, not LD).
- **fire-rule:** Beat: per run_solve (prim_model_v2.py:241), while not blocked: rd_amt=can_read; if rd_amt run_read; wr_amt=can_write; if wr_amt run_write (prim_model_v2.py:302-308). For loads, can_read returns amt_remaining=size-done_read because "ext" is in c_list (instr_pkt_v2.py:104-107,120) and can_write returns done_read-done_write because "sp" is in p_list (instr_pkt_v2.py:134-137), so a load NEVER stalls on its own memory ports; it streams its full burst in one shot. is_ofifo_stalled is vacuous here (no non-local produce target; instr_pkt_v2.py:59-61). blocked = (rd_amt==0 and wr_amt==0) (prim_model_v2.py:326) only after done_read==done_write==size. The ONLY backpressure/stall for NCLU is on the SYNC packets (real *_sync FIFO ports hit can_read state>0 / can_write max-credit, instr_pkt_v2.py:114-116,144-147), which serialize the load behind its producers/consumers.
- **sync-dep:** Explicit SYNC packets, not implicit-via-FIFO (the data ports are non-blocking local mem). NCLU SYNC (instr_pkt_v2.py:300-336) builds put/get edges over {nclu,ncsu,splu0,spsu0,splu1,spsu1} from typ1ac_imm bits (mask_pair at :307-314, cls.sync_mask at constr_nclu.py:50-56): put→produce nclu_<tgt>_sync (:333), get→consume <src>_nclu_sync (:335); both_sync (put&get) splits into a 2-pkt vec (:316-329, instr_pkt_v2.py:1108-1112). MESYNC (instr_pkt_v2.py:338-376) is the cross-DNC variant: per-DNC d{i} edges nclu_d{i}_<tgt>_sync for i in 0..15 (:360-376), i.e. how a load's SP-fill is fenced against a peer DNC writer/reader, and this is the synchronization backbone of the "cross-DNC partial accumulate" pattern. handle_sync (prec_sim_process.py:377-397) only logs; the real edge effect is the FIFO credit add/remove in run_read/run_write.
- **terminates:** is_done = (size==done_read) and (done_read==done_write) (instr_pkt_v2.py:28-29). For loads: done when burst granules have been read AND written, i.e. after one streaming beat (single run_read of rd_amt=size then run_write of size; prim_model_v2.py:302-308). For a both_sync vec, done only when ALL sub-pkts done (InstrPktV2Vec.is_done, instr_pkt_v2.py:1148-1154).
- **inferred / flags:**
  - The handler performs a PURE byte-copy (SHM->SP / SP->SP), NOT an arithmetic accumulate, since there is no add/psum in NCLUProcess.run (prec_sim_process.py:434-470). The family-name 'cross-DNC partial accumulate' is a USE-pattern realized by the address generator (ext_addrs may point at a peer DNC's SP via the >>15 index, prec_sim_process.py:459) plus downstream TU/VU summation; NCLU itself only moves bytes. Reason: no accumulate op appears in the handler.
  - 'ext' and 'sp' ports carry NO backpressure / are not real FIFOs. Inferred from their membership in the local c_list/p_list (instr_pkt_v2.py:101,130) where can_read/can_write return the full remaining amt unconditionally rather than a credited FIFO count, so a load fires in a single streaming beat. Reason: explicit branch in can_read/can_write treats these names as local memory, not state FIFOs.
  - url_deg is the per-instruction burst only; multi-granule K>32 loads are driven by a separate MVLOOPCNT self:self instruction re-issuing the PC, not by inflating url_deg. Inferred: MVLOOPCNT is listed as a distinct NCLU opcode (constr_nclu.py:17) and never multiplies size in make_pkt_info (instr_pkt_v2.py:289-298). Consistent with the LDMU burst auto-advance note in project memory (ceil(K/32) back-to-back bursts).
  - Kahn=yes classification: the only true blocking edges are SYNC/MESYNC FIFO credits (deterministic FIFO+SYNC), and the data move is a deterministic memory copy with statically-sized burst; no non-blocking control on the LOAD path. (The NON-KAHN control surface is GETJCR/JCR, dispatched at prec_sim_process.py:419 but belonging to the JCR family, not the load family.) Reason: load path has no non-blocking poll.
  - curr_size/write_amt slicing (main_common.py:582-583) implies the scheduler can split one logical burst across multiple run_read/run_write calls when partially drained; for NCLU loads with non-blocking ports this collapses to a single full-burst beat in practice. Inferred from the slice arithmetic + non-blocking can_read returning full amt_remaining.
- **citations:**
  - `prec_sim_process.py:412 (class NCLUProcess)`
  - `prec_sim_process.py:418 (run signature: ext_addrs, sp_addrs, shm, sp, sp_arr, sp_lines_arr, ififos, ld_const, sync_dir)`
  - `prec_sim_process.py:419-423 (GETJCR / SYNC dispatch)`
  - `prec_sim_process.py:425-431 (LDC/LDCU immediate->ext_addrs synthesis; assert no ext addrs at :426)`
  - `prec_sim_process.py:434 (zip ext_addrs,sp_addrs main move loop)`
  - `prec_sim_process.py:438 (LDC SP splat write)`
  - `prec_sim_process.py:442,444 (apply_NC_TLB then SHM-vs-SP physical branch)`
  - `prec_sim_process.py:455 (SHM->SP 128B copy)`
  - `prec_sim_process.py:457-470 (SP->SP copy via sp_arr[rd_sp_idx], cross-DNC index >>15 at :459)`
  - `prec_sim_process.py:473-476 (sp_lines_arr valid-line set, log-gated)`
  - `prec_sim_process.py:400-409 (apply_NC_TLB; G-suffix VA bypass at :401-403)`
  - `prec_sim_process.py:377-397 (handle_sync log-only)`
  - `prec_sim_process.py:354-374 (handle_get_jcr)`
  - `instr_pkt_v2.py:289-298 (NCLU LD pkt: consume_from='ext', produce_to='sp', size=burst, burst0->32)`
  - `instr_pkt_v2.py:300-336 (NCLU SYNC edge build, mask_pair, both_sync 2-pkt)`
  - `instr_pkt_v2.py:338-376 (MESYNC per-DNC d{i} edges)`
  - `instr_pkt_v2.py:1086-1095 (GETJCR consume uan_nclu_jcr)`
  - `instr_pkt_v2.py:1105-1114 (url_deg=size; both_sync returns 2 pkts)`
  - `instr_pkt_v2.py:15,28-29 (size=url_deg; is_done)`
  - `instr_pkt_v2.py:84-120 (can_read; ext in c_list non-blocking)`
  - `instr_pkt_v2.py:122-154 (can_write; sp in p_list non-blocking)`
  - `instr_pkt_v2.py:156-238 (run_read/run_write SP/ext no-state, sync state +/-)`
  - `constr_nclu.py:14-34 (opcode_options['self:self'] control opcodes incl MVLOOPCNT at :17)`
  - `constr_nclu.py:35-43 (opcode_options['etc:etc'] LDM/LDMU/LDS/LDSU/LDMG/LDMGU load family; LDC/LDCU commented out at :38)`
  - `constr_nclu.py:50-56 (sync_mask map)`
  - `constr_nclu.py:106,150-151 (burst constraint assert 0<size<=32; burst==32->0)`
  - `constr_nclu.py:154-155,159-162 (LDMG/LDMGU qos_vae=0 at :154-155, alias LDMG->LDM/LDMGU->LDMU at :159-162)`
  - `main_common.py:565-602 (nclu() builds ext_addrs from SHM/DRAM/LBUS RD, sp_addrs from SP WR, slices [curr_size:+write_amt] at :582-583, calls run with sp_arr; sp=sp_arr[dnc_idx] at :595)`
  - `prim_model_v2.py:241 (run_solve def)`
  - `prim_model_v2.py:294-331 (run_solve beat: while-not-blocked can_read->run_read->can_write->run_write at :302-308; blocked=(rd_amt==0 and wr_amt==0) at :326)`


<!-- round 3 (2026-06-23): control + data-tail families -->


---

### operational(C4 NC address-register control ops: SARREGCOPY (0x10), MODSARREG (0x11), CARREGCOPY (0x14), MODCARREG (0x15), unit NCLU/NCSU)  · kahn: **yes**
<!-- COVOP id=c4-addrreg tier=citation-clean kahn=yes ops=SARREGCOPY,MODSARREG,CARREGCOPY,MODCARREG -->

- **in-ports:** {} (self-loop). All four resolve to a self:self packet: consume_from=["self"], produce_to=["self"]. No FIFO is consumed. [src: instr_pkt_v2.py:1018-1041 the "LRF only instr (self -> self)" branch lists SARREGCOPY/MODSARREG/CARREGCOPY/MODCARREG and sets `consume_from=["self"]; produce_to=["self"]`; constr_nclu.py:14-33 places all four in `opcode_options["self:self"]`.]
- **out-ports:** {} (self-loop). produce_to=["self"]; no FIFO is produced. The op's only observable effect is the register write (see reg_sp_write). [src: instr_pkt_v2.py:~1037 `produce_to = ["self"]`; constr_nclu.py:14 self:self group; constr_ncsu.py:27-30 lists the same four in NCSU's group.]
- **reg/sp-write:** Writes sigma.LRF[src0][SAR|CAR] (the NC address register file), NOT SP and NOT a FIFO. Shared computation, per-variant operand: REGCOPY variants copy, MOD variants add. SARREGCOPY: LRF[src0][SAR] = LRF[src1][SAR] (lrf_type="SAR"). CARREGCOPY: LRF[src0][CAR] = LRF[src1][CAR] (lrf_type="CAR"). MODSARREG: LRF[src0][SAR] = LRF[src0][SAR] + LRF[src1][SAR]. MODCARREG: LRF[src0][CAR] = LRF[src0][CAR] + LRF[src1][CAR]. The written value is masked to the register bitwidth (two's-complement for negatives) via update_LRF_value. [src: init_decode.py:2191-2195 `elif opcode_str in ["LRFREGCOPY","SARREGCOPY","CARREGCOPY"]: self.update_LRF(...,src0, LRF_src1,...)` and `elif opcode_str in ["MODLRFREG","MODSARREG","MODCARREG"]: self.update_LRF(...,src0, LRF_src0 + LRF_src1,...)`; lrf_type select at init_decode.py:2167-2171 `elif "SAR" in opcode_str: lrf_type="SAR" / elif "CAR" in opcode_str: lrf_type="CAR"`; write at init_decode.py:1685-1686 `self.LRF[index][lrf_type] = value`; masking at init_decode.py:1662-1680 update_LRF_value bitwidth mod / two's-complement.]
- **extent:** size = url_deg = 1 (single fire, scalar register op). The self:self branch never assigns `size`, so the default `url_deg = 1` (set near instr_pkt_v2.py:285) is carried through to the packet, and InstrPktV2.__init__ sets self.size = self.url_deg = 1. [src: instr_pkt_v2.py:285 `url_deg = 1`; instr_pkt_v2.py:1105-1106 `if size is not None: url_deg = size` (size stays None for these → url_deg unchanged); instr_pkt_v2.py:13-15 `self.url_deg = url_deg; self.size = self.url_deg`.]
- **fire-rule:** Always-fires, no backpressure. consume_from/produce_to are both ["self"], and can_read/can_write treat "self" as in the always-available list `c_list/p_list = ["sp","self","ext",...]`: the predicate reduces to `done_read < size` / `done_read - done_write > 0`, i.e. one read-tick then one write-tick, gated by no external FIFO state. is_done = (size==done_read) and (done_read==done_write) → done after 1/1. [src: instr_pkt_v2.py:101-106 `c_list = ["sp","self","ext"]; ... if c in c_list: can = can and (self.done_read < self.size)`; instr_pkt_v2.py:122-135 can_write symmetric on `done_read - done_write`; instr_pkt_v2.py:28-29 `is_done: (size==done_read) and (done_read==done_write)`.] [INFERRED: that the "self" self-loop is unconditionally schedulable, derived from can_read/can_write membership in the always-available list, not from a dedicated comment.]
- **sync-dep:** None. These ops carry no SYNC token and impose no cross-unit ordering on the dataflow graph. The producer→consumer coupling is purely data-local (intra-NCore): the SAR/CAR value written here is read by a later LDM/STM/LDS in program order on the same unit; there is no FIFO or sync edge. SYNC handling in NCLU/NCSU run() is a separate branch (`elif "SYNC" in opcode: handle_sync(...)`) that these opcodes never reach. [src: prec_sim_process.py:430-435 (NCLU.run) and :498-503 (NCSU.run), where run() dispatches only GETJCR, SYNC, and LD/ST families; the SAR/CAR opcodes are absent from run() because they are resolved in the decode pass (init_decode.py:2138-2196), so they produce no sync_dir effect.]
- **terminates:** Yes, in exactly one schedule step. After one read-tick and one write-tick on the self port, done_read=done_write=size=1 so is_done becomes true and the actor retires. In the value/decode model the effect is a single synchronous LRF assignment (no loop, no burst). [src: instr_pkt_v2.py:28-29 is_done; init_decode.py:1685-1686 single LRF write (no iteration).]
- **inferred / flags:**
  - [INFERRED] Unconditional schedulability of the self:self self-loop: the spec has no explicit 'always fires' statement; derived from "self" being a member of the always-available c_list/p_list in can_read/can_write (instr_pkt_v2.py:101-135), so the fire predicate degenerates to the local done-counter and never stalls on FIFO state.
  - [INFERRED] sync_dep=None and scheduler-irrelevance: inferred from their absence, since these opcodes never appear in NCLU/NCSU run() (only GETJCR/SYNC/LD-ST are dispatched there, prec_sim_process.py:430-435/498-503) and are resolved entirely in the init_decode pass, so they emit no sync_dir token and create no inter-unit edge. Reason: no source line *asserts* zero sync; concluded from the dispatch tables not handling them.
  - [INFERRED] kahn=yes: a size-1 register write on a self-loop with no FIFO ports and no SYNC has deterministic, order-independent dataflow output (the value is consumed only by later same-unit program-order data ops), so it does not perturb the Kahn-network determinism. Reason: derived from the no-FIFO / no-sync facts above, not stated in source.
  - [INFERRED] isbr/be params (dnc_isa.py:313-316) select the SBR/CBR alias when isbr=1 (init_decode.py:2163-2166 `if "SXR"/"CXR" in opcode_str: lrf_type = "SBR"/"CBR" if isbr`); for the bare SAR*/CAR* opcodes the lrf_type branch keys on the opcode string and the isbr->bound-register variant is the value-layer concern, rather than operational. It is noted here and changes no port, firing rule or extent.
- **citations:**
  - `instr_pkt_v2.py:1018-1041, the `LRF only instr (self -> self)` branch lists SARREGCOPY/MODSARREG/CARREGCOPY/MODCARREG → consume_from=["self"], produce_to=["self"]`
  - `instr_pkt_v2.py:261-272 ignored_opcodes (MVLOOPCNT/NOP/RETURN/J* move zero FIFO data, a sibling control class; SAR/CAR handled via self:self not ignored-list)`
  - `instr_pkt_v2.py:285 `url_deg = 1` default; :1105-1106 `if size is not None: url_deg = size` (size None here); :13-15 size=url_deg`
  - `instr_pkt_v2.py:28-29 `is_done: (self.size == self.done_read) and (self.done_read == self.done_write)``
  - `instr_pkt_v2.py:101-106 / :122-135 can_read/can_write, where "self" is in the always-available c_list/p_list, predicate = done_read<size`
  - `constr_nclu.py:14-33 `opcode_options["self:self"]` includes SARREGCOPY/MODSARREG/CARREGCOPY/MODCARREG`
  - `constr_ncsu.py:27-30 same four in NCSU opcode group`
  - `init_decode.py:2148-2196 decode-time execution: lrf_type select (SAR/CAR), :2191 REGCOPY=copy src1, :2192-2193 MOD=src0+src1, via update_LRF`
  - `init_decode.py:1682-1696 update_LRF → `self.LRF[index][lrf_type] = value``
  - `init_decode.py:1662-1680 update_LRF_value, the bitwidth modulus and two's-complement masking`
  - `prec_sim_process.py:424-491 NCLUProcess.run / :492-580 NCSUProcess.run, dispatching only GETJCR/SYNC/LD-ST; SAR/CAR not present (resolved at decode)`
  - `dnc_isa.py:214-217 opcodes SARREGCOPY=0x10 MODSARREG=0x11 CARREGCOPY=0x14 MODCARREG=0x15; :313-316 params [src0,src1,isbr,be]; :1714-1717 type="1b"`

---

### operational(C1, the JCR register ops JADD, JSUB, JARITH, JSHR, JIMMCOPY and JSWAP, on any unit with a JCR file, which is all nine)  · kahn: **yes**
<!-- COVOP id=c1-jcr tier=citation-clean kahn=yes ops=JADD,JSUB,JARITH,JSHR,JIMMCOPY,JSWAP -->

- **in-ports:** {} (self-loop). These opcodes are never lowered to a FIFO packet: instr_pkt_v2.py:261 `ignored_opcodes = [MVLOOPCNT, NOP, RETURN, JCMP, JADD, JSUB, JIMMCOPY, JSWAP, JSHR, JARITH]`, and make_pkt_info() at instr_pkt_v2.py:1097 only raises NotImplementedError for opcodes NOT in this list, so the six JCR ops produce no consume_from/produce_to packet and consume nothing from any input FIFO. Firing class is self:self per constr_absu.py:15 `opcode_options["self:self"] = [... JADD, JSUB, JIMMCOPY, JSWAP, JSHR, JARITH ...]` (representative unit; the same self:self grouping holds for every unit's constr_<unit>.py). [INFERRED] reason: "{}" notation for in-ports follows the prompt's self-loop convention for control ops that read no FIFO.
- **out-ports:** {} (self-loop). Same source as in-ports: in ignored_opcodes (instr_pkt_v2.py:261), so produce_to is never set, so no downstream FIFO is written. The only effect is on the unit-local register file, not a channel. Distinct from the data-tail / sync JCR ops (SENDJCR/GETJCR) which DO carry a `_jcr` FIFO port (e.g. GETJCR consume_from `uan_<unit>..._jcr` at instr_pkt_v2.py:1087-1094), and those are out of scope for this C1 register-arith family.
- **reg/sp-write:** sigma.JCR (16-entry control register file; each entry signed 16-bit, wrapped/sign-extended by update_JCR at init_decode.py:1654-1657 `value = value % (1<<16); if value >= (1<<15): value -= 1<<16`). JCR file allocated 16-wide at init_decode.py:1538 `self.JCR = [jcr_init.get(i,0) for i in range(16)]`. Per-variant write target (init_decode.py:2027-2081, the authoritative offline arg-parser effect model, since the runtime data-path sim does NOT re-implement these):\n- JADD:  JCR[jcr_tgt] = typ1_imm + rhs           (init_decode.py:2062)\n- JSUB:  JCR[jcr_tgt] = typ1_imm - rhs           (init_decode.py:2063)\n- JIMMCOPY: JCR[jcr_tgt] = typ1_imm              (init_decode.py:2065)\n- JSHR:  JCR[jcr_tgt] = signed-shift(JCR[src0], shamt) then truncate tr_left/tr_right bits (init_decode.py:2067-2081; shamt signed 5-bit, negative = left shift)\n- JARITH: JCR[jcr_tgt] = JCR[src0] (+|-) JCR[src1] selected by jarsw_mode&1 / TU:jarsw_submode (init_decode.py:2051-2060)\n- JSWAP: swaps two entries, so JCR[src1]<-JCR[src0], JCR[src0]<-old JCR[src1] (init_decode.py:2047-2050; aliased with JCRSWAP)\nrhs operand select: jcr_sel ? JCR[src0] : LCCR[src0] (init_decode.py:2042-2045). Resource-validity side-effect: constr_common.py:160-161 mng_jcr marks `valid_jcr[jcr_tgt]=True` for JADD/JSUB/JIMMCOPY/JSHR (note JSWAP/JARITH not in that validity-mark set). There is no SP, SHM, AB or LRF write; the effect is on the JCR file alone.
- **extent:** size = url_deg = 1 (single fire). InstrPktV2.__init__ at instr_pkt_v2.py:13-15 sets `self.url_deg = url_deg; self.size = self.url_deg`, and make_pkt_info default is `url_deg = 1` (instr_pkt_v2.py:285), though that does not matter here since the op never reaches packet construction (ignored_opcodes short-circuit). [INFERRED] reason: extent=1 is the structural default; these control ops have no burst or loop field in the FIFO sense, so one decode is one JCR mutation. JSHR has internal shamt/tr_left/tr_right operands but they are intra-instruction bit-math, not extent.
- **fire-rule:** Always-fires, self:self, no backpressure. The instruction is classed self:self (constr_absu.py:15), consuming from no FIFO and produces to no FIFO, so can_read/can_write gating (instr_pkt_v2.py:84/122) is never exercised. As a control op it is decoded, mutates JCR, and retires unconditionally in program order; the dataflow scheduler treats it as skipped_opcodes (prim_model.py:332-344, prim_analyze) so it imposes no edge on the FIFO-readiness solve. [INFERRED] the reason it always fires and never back-pressures is derived from the absence of any FIFO port + presence in both ignored_opcodes and skipped_opcodes; the only ordering it carries is sequential PC advance within its own unit's instruction stream.
- **sync-dep:** none, so there is no FIFO or SYNC dependency. JCR arith ops are NOT sync ops: InstrPktV2 type is "sync" only when "SYNC" in opcode (instr_pkt_v2.py:20), false for J* arith. handle_sync is never invoked. The only data dependency is the implicit intra-unit RAW/WAW on the JCR file (a later GETJCR/SENDJCR or a JCMP branch reading JCR[k] depends on the producing JADD/JARITH/etc.), but that is sequential PC ordering inside one unit, not a cross-unit FIFO/SYNC handshake. [INFERRED] reason: the intra-unit JCR RAW chain is implied by JCR being a persistent register file read by JCMP (init_decode.py:2088-2091) and by SENDJCR; PrecSim enforces it via in-order single-unit PC execution, not via a packet edge.
- **terminates:** yes, in one step. Single decode → one update_JCR call (or one swap of two entries for JSWAP) → PC advance. No loop, no burst, no FIFO drain to wait on. Bounded by the 16-bit wrap in update_JCR (init_decode.py:1654). No deadlock surface (it is in skipped_opcodes so it can never stall the solver). [INFERRED] reason: termination-in-one-step follows from extent=1 + zero-FIFO + unconditional retire.
- **inferred / flags:**
  - in_ports/out_ports = {} self-loop: derived from presence in instr_pkt_v2.py:261 ignored_opcodes (no packet built) + self:self class in constr_absu.py:15; notation per prompt convention
  - extent=1: structural make_pkt_info default (url_deg=1), not directly exercised since the op is never packetized; these control ops carry no FIFO burst/loop field
  - fire-rule always-fires/no-backpressure: inferred from zero FIFO port + dual membership in ignored_opcodes and prim_model skipped_opcodes
  - sync_dep = intra-unit JCR RAW chain only: PrecSim enforces this via in-order single-unit PC execution (JCMP/SENDJCR read JCR[k]), not via a packet edge; no cross-unit FIFO/SYNC for the arith variants
  - terminates in one step: from extent=1 + zero-FIFO + unconditional retire (no drain/loop to await)
  - kahn=yes: a register-only single-unit no-port mutation is order-deterministic; the family's NON-KAHN sibling (SENDJCR cross-unit push) is explicitly out of scope per the prompt
  - init_decode.py is the OFFLINE arg-parser effect model, used here as the authoritative JCR-semantics source because the RUNTIME data-path sim (prec_sim_process.py) deliberately does not implement these control ops (sim_non_comp only handles IMMCOPY), so the denotational JCR effect lives in init_decode, the operational 'zero-FIFO / skipped' fact lives in instr_pkt_v2 + prim_model
- **citations:**
  - `instr_pkt_v2.py:261 `ignored_opcodes = [MVLOOPCNT, NOP, RETURN, JCMP, JADD, JSUB, JIMMCOPY, JSWAP, JSHR, JARITH]`, so all six become no FIFO packet`
  - `instr_pkt_v2.py:1097-1099 `if not_processed: if opcode_str not in cls.ignored_opcodes: raise NotImplementedError`, and ignored ops short-circuit before any consume_from/produce_to is built`
  - `instr_pkt_v2.py:13-15 `self.url_deg = url_deg; self.size = self.url_deg` and :285 `url_deg = 1`, the default extent of 1`
  - `instr_pkt_v2.py:20 `self.type = "sync" if ("SYNC" in self.opcode) else "data"`, so the arithmetic ops are not sync`
  - `instr_pkt_v2.py:28-29 is_done: `size == done_read and done_read == done_write`, the packet-done definition, not reached for these`
  - `prim_model.py:332-344 (prim_analyze/prim_model.py) `skipped_opcodes = [NOP, MVLOOPCNT, RETURN, JCMP, JADD, JSUB, JIMMCOPY, JCRSWAP, JSWAP, JSHR, JARITH ...]`, so the scheduler skips them as control flow`
  - `constr_absu.py:15-30 `opcode_options["self:self"] = [... JADD, JSUB, JIMMCOPY, JSWAP, JSHR, JARITH ...]`, the self:self firing class, with no FIFO`
  - `constr_absu.py:191-195, where JADD/JSUB/JIMMCOPY/JSHR use 4-bit src0; JCMP/JSWAP/JARITH use 4-bit src0+src1`
  - `constr_common.py:157-162 mng_jcr `if opcode_str in [JADD,JSUB,JIMMCOPY,JSHR]: valid_jcr[params['jcr_tgt']] = True`, the JCR validity side-effect (JSWAP/JARITH excluded)`
  - `init_decode.py:1538 `self.JCR = [jcr_init.get(i,0) for i in range(16)]`, the 16-entry JCR file`
  - `init_decode.py:1653-1657 update_JCR, the signed 16-bit wrap `value % (1<<16); if >= 1<<15: -= 1<<16``
  - `init_decode.py:2042-2045 rhs select `jcr_sel ? JCR[src0] : LCCR[src0]``
  - `init_decode.py:2047-2050 JSWAP/JCRSWAP swap JCR[src0]<->JCR[src1]`
  - `init_decode.py:2051-2060 JARITH `JCR[jcr_tgt] = JCR[src0] +/- JCR[src1]` by jarsw_mode/TU jarsw_submode`
  - `init_decode.py:2061-2066 JADD/JSUB/JIMMCOPY `JCR[jcr_tgt] = typ1_imm (+|-|=) rhs``
  - `init_decode.py:2067-2081 JSHR signed shift of JCR[src0] by shamt + tr_left/tr_right bit-truncation`
  - `prec_sim_process.py:1725-1758 sim_non_comp, where only IMMCOPY is implemented; JCR arith ops fall through to InstrNotImplementedError, i.e. runtime data-path sim does NOT execute them (they are filtered upstream by ignored/skipped lists)`

---

### operational(D13 SPSU.LRFCOPY (channel -> LRF/JCR), unit SPSU)  · kahn: **yes**
<!-- COVOP id=d13-lrfcopy tier=citation-clean kahn=yes ops=LRFCOPY -->

- **in-ports:** {producer}, which is exactly one ififo, selected by params.st_producer via constr_spsu.st_src {self:0(ZERO), xvu:1, vu:2, splu:3}. Per pkt-builder (instr_pkt_v2.py:642,647-654) consume_from = inst_param_tag(SPSU,LRFCOPY,st_producer,...); None/'zeros' -> 'self', else producer name + ncore_idx (e.g. 'xvu0','vu0','splu0'). run() iterates ififos.items() and pops the single producer FIFO (prec_sim_process.py:1054-1059 "should only have 1 unit"). [INFERRED] producer != self for a meaningful channel->LRF copy; self-source = ZERO (degenerate).
- **out-ports:** {} for the dataflow graph's data effect: the payload lands in a REGISTER (sigma.LRF[src0] or sigma.JCR[src0]), NOT a FIFO. Two physical out-edges: (1) feedback_q tuple (ctx.unit, raw_data) returned when consume==0 (prec_sim_process.py:1064), and the feedback mechanism writes it back to this unit's LRF (mirrors handle_get_jcr's feedback_key return at :384); (2) None when consume==1 (drop). NOTE/[per-variant]: the pkt-builder sets produce_to="sp" for the whole ST-family branch including LRFCOPY (instr_pkt_v2.py:655), which is a topology placeholder; the actual run() handler never touches sp.buf for LRFCOPY (it early-returns at :1064 before the SP-store block at :1066+). The real effect is reg-write to LRF/JCR.
- **reg/sp-write:** sigma.LRF[src0] when typ2a_jcr_tgt==0, else sigma.JCR[src0] (prec_sim_process.py:1062 lrfcopy_tgt = "JCR" if typ2a_jcr_tgt else "LRF"; src0 = params.get("src0",0) at :1050). Write occurs only when consume==0 (the (ctx.unit, raw_data) feedback return at :1064); consume==1 => no reg write, payload dropped. No SP write. [INFERRED] the LRF/JCR index is src0 (the log line :1063 prints LRF/JCR[{src0}]); the feedback return carries raw_data and the consumer-side feedback writer uses src0, consistent with the feedback path of GETJCR.
- **extent:** size = url_deg from the shared ST-family pkt-builder: burst ? (burst_sz or 64) : 1, then ×4 if interleave_sz==3, ×2 if interleave_sz==2 (instr_pkt_v2.py:656-663). Base pkt size = url_deg (instr_pkt_v2.py:15 self.size = self.url_deg). The run() handler itself pops exactly ONE FIFO entry per invocation (single fifo.pop(0) at :1059, no burst loop) and copies raw_data[0] worth to the reg, so the per-fire register effect is 1 element regardless of size; the size field governs FIFO read-credit accounting in can_read/can_write. [INFERRED] for the typical channel->LRF copy size=1 (burst=0); larger size is the staged-store accounting shared with ST and not exercised by the reg-write handler.
- **fire-rule:** FIFO-gated on the producer ififo (NOT a self-loop). LRFCOPY is NOT in ignored_opcodes (instr_pkt_v2.py:261-272), so it gets a real packet with consume_from={producer} -> standard backpressure: can_read fires only when the producer's inter-unit FIFO has credit (instr_pkt_v2.py:104-116, the consume_from-not-in-{sp,self,ext} branch checks state.state[st] > 0; here the producer channel must be non-empty). If the producer FIFO is empty, run() logs a warning and txn_id/raw_data are unbound (prec_sim_process.py:1055-1056), so the scheduler is expected to gate it; the handler does not stall internally. done when size==done_read==done_write (instr_pkt_v2.py:28-29 is_done).
- **sync-dep:** None intrinsic to LRFCOPY (it is opcode_options["etc:self"], constr_spsu.py:32, consuming from another unit and producing to self). Ordering against the producer is enforced by the producer FIFO credit, not by a SYNC. Cross-unit handshakes use the separate SPSU SYNC op (constr_spsu.py:36, handle_sync). [INFERRED] in practice LRFCOPY is preceded by an SP/SU<->XVU/VU/SPLU SYNC so the producer has actually pushed the channel payload before LRFCOPY reads it; that SYNC is a separate instruction, not part of this op's effect.
- **terminates:** Yes. Single fifo.pop(0) + single reg write per fire, no internal loop (prec_sim_process.py:1049-1064); pkt is_done when read==write==size (instr_pkt_v2.py:28-29). Bounded by producer FIFO availability; cannot spin.
- **inferred / flags:**
  - produce_to/out-port: pkt-builder declares produce_to="sp" for the whole ST-family (instr_pkt_v2.py:655), but the LRFCOPY run() handler early-returns at :1064 and never executes the SP-store block => real effect is a REG write (LRF/JCR) via the feedback_q tuple, not an SP FIFO write. The graph 'sp' edge is a topology placeholder.
  - reg index = src0: deduced from the log line (:1063 LRF/JCR[{src0}]) and the GETJCR feedback parallel; the handler returns raw_data without re-stating the index, the feedback writer applies it.
  - size=1 typical: handler pops exactly one entry (no burst loop), so the multi-element size from interleave/burst is FIFO-credit accounting inherited from ST, not a per-fire reg-write multiplicity.
  - SYNC precedence: no SYNC is part of this op; ordering vs the producer is via FIFO credit. A preceding cross-unit SYNC is the practical pattern but a separate instruction.
  - Kahn-determinism: asserted from single-input FIFO + fixed reg target; not contradicted by any non-blocking/order-sensitive path in the handler (contrast SENDJCR multicast).
- **citations:**
  - `prec_sim_process.py:1049 elif opcode == "LRFCOPY":`
  - `prec_sim_process.py:1050 src0 = params.get("src0",0)`
  - `prec_sim_process.py:1051 typ2a_jcr_tgt = params.get("typ2a_jcr_tgt",0)`
  - `prec_sim_process.py:1052 consume = params.get("consume",0)`
  - `prec_sim_process.py:1054-1059 for (unit,fifo) in ififos.items(): # should only have 1 unit ... txn_id,raw_data = fifo.pop(0)`
  - `prec_sim_process.py:1062 lrfcopy_tgt = "JCR" if typ2a_jcr_tgt else "LRF"`
  - `prec_sim_process.py:1063 log LRF/JCR[{src0}]`
  - `prec_sim_process.py:1064 return None if consume else (ctx.unit, raw_data)`
  - `prec_sim_process.py:1066+ st_type/st_producer SP-store block (NOT reached by LRFCOPY)`
  - `constr_spsu.py:32 opcode_options["etc:self"] = ["LRFCOPY"]`
  - `constr_spsu.py:50-54 st_src {self:0(ZERO), xvu:1, vu:2, splu:3}`
  - `instr_pkt_v2.py:640 SPSU branch in [ST,STI,STU,STIU,LRFCOPY]`
  - `instr_pkt_v2.py:647-654 consume_from = inst_param_tag(...st_producer...); None/'zeros'->'self'`
  - `instr_pkt_v2.py:655 produce_to = "sp" (ST-family placeholder; not the actual LRFCOPY reg effect)`
  - `instr_pkt_v2.py:656-663 size = burst?(burst_sz or 64):1; *4 if isz==3, *2 if isz==2`
  - `instr_pkt_v2.py:261-272 ignored_opcodes (LRFCOPY NOT listed => real pkt)`
  - `instr_pkt_v2.py:15 self.size = self.url_deg`
  - `instr_pkt_v2.py:28-29 is_done: size==done_read and done_read==done_write`
  - `instr_pkt_v2.py:104-116 can_read producer-channel credit gating`
  - `prec_sim_process.py:366-384 handle_get_jcr feedback_key return (parallel reg-feedback pattern)`


<!-- round 3 tail (2026-06-23): 2 REJECT corrected + 5 REVISE w/ residual-fix notes -->

---

### operational(C5, the zero-port markers NOP and RETURN)  · kahn: **yes**
<!-- COVOP id=zero-port tier=citation-clean kahn=yes ops=NOP,RETURN note=corrected-from-REJECT -->

> Supersedes the round-3 REJECTed drafts of `C5 flow` and `C2 SESYNC`. The drafts modeled these as self-firing size-1 packets; the review caught that as fabricated. Corrected model below, verified against source.

- **in-ports:** none, and not a self-loop either. Both the consume and the produce field are unset.
- **out-ports:** none, likewise.
- **reg/sp-write:** none in the simulator path. `run()` is never invoked for these ops.
- **extent:** **no dataflow packet at all.** `is_distributing = (consume_from != None) or (produce_to != None)` is **False** for both-`None` ports, so `from_instr` appends nothing and returns `None`; the op is dropped at packetization (`main_common` registers it as `None`).
- **fire-rule:** it never fires, being dropped before scheduling, so the scheduler never visits it.
- **sync-dep:** none in the modeled path. RETURN's role at the instruction-buffer boundary is resolved at decode and packetization rather than as a runtime FIFO or sync edge.
- **terminates:** not applicable, since no scheduled actor exists to terminate. The op vanishes at packetization.
- **kahn:** yes. A zero-port node that is never instantiated is trivially deterministic, since it perturbs nothing.
- **SESYNC:** PrecSim decodes its immediate, but packetization has no case for it. `make_pkt_info` does not branch for it, and it is absent from `instr_pkt_v2.py`'s `ignored_opcodes`. So `not_processed` stays set, packetization raises, and `main_common` re-raises that as `InstrNotImplementedError`. NOP and RETURN are dropped at that same step, whereas SESYNC aborts the run there.
- **citations:**
  - `instr_pkt_v2.py:24-25  is_distributing = (consume_from != None) or (produce_to != None)`
  - `instr_pkt_v2.py:1275-1281  from_instr: if pkt.is_distributing: pkt_vec.append(pkt) ... else return None`
  - `main_common.py:1214,1243  from_instr None -> "registered as None"`
  - `instr_pkt_v2.py:261-272  ignored_opcodes (NOP and RETURN listed, SESYNC not)`
  - `instr_pkt_v2.py:1097-1099  if not_processed and opcode not in ignored_opcodes -> raise NotImplementedError`
  - `main_common.py:1224-1227  except NotImplementedError -> raise InstrNotImplementedError("... is not ported yet!")`
  - SESYNC's immediate decode: `families_control.md`'s C2 provenance comment for that immediate. The `constr_nclu.py:102` and `constr_ncsu.py:96` branches naming SESYNC are unreachable: `constr_nclu.py:44` and `constr_ncsu.py:38` comment it out of the opcode options, and their branch body is `pass` in any case.
  - RETURN ibuff-end handled at decode (`prim_analyze.py ~694/753`); two `prim_model.py` exist, and `skipped_opcodes` is at `rebel_hw_util/.../prim_analyze/prim_model.py:332` (static tool), NOT the root `prim_model.py` (run_solve scheduler).
- **contrast (not this class):** `SETMASK`/`SARREGCOPY`/etc. use `['self']` ports → distributing → scheduled (they write a register a later op consumes); `SYNC`/`MESYNC` have real sync-channel ports → distributing. Only the truly effect-less markers are `None`-ported and dropped.

---

### operational(C6 loop/sequencer: MVLOOPCNT, JCMP)  · kahn: **yes**  · ⚠ review-flagged residual fixes
<!-- COVOP id=c6-loop tier=review-residual kahn=yes ops=MVLOOPCNT,JCMP note=two-prim_model-disambig -->

- **in-ports:** {} (self-loop). Both opcodes are in instr_pkt_v2.py ignored_opcodes, so make_pkt_info() never constructs an InstrPktV2 for them -- consume_from stays None (never assigned) and no FIFO is read. No input data channel; the only effective input is sequencer state sigma.LOOP/sigma.PC, not a FIFO port.
- **out-ports:** {} (self-loop). Same ignored_opcodes path -- produce_to stays None (never assigned), no FIFO write, no ofifo. No output data channel; the only effective output is mutated sequencer state (sigma.LOOP for MVLOOPCNT, sigma.PC for JCMP).
- **reg/sp-write:** MVLOOPCNT: writes sigma.LOOP -- pushes one entry (init value 1) onto the loop_cnt stack; hard cap depth 16 (mng_loop returns -1 beyond 16, else loop_cnt.append(1)). Trip count carried in param typ1_imm. No SP/LRF/PC write. JCMP: reads sigma.LOOP (active loop_cnt entry), tests/decrements it, and writes sigma.PC -- branches back to the loop head while the count is live, pops sigma.LOOP and falls through when exhausted. Loop-body boundary = the 'be' (block-end) bit on the body's terminal instruction (set during loop synthesis, prim_analyze.py:705-734). Neither op touches sigma.{SAR,CAR,JCR} or SP/SHM. [INFERRED: JCMP's read-of-sigma.LOOP + write-of-sigma.PC and the pop-on-exhaust -- source models loops at the synthesis/expansion layer (constr_common mng_loop pushes on MVLOOPCNT; prim_analyze pairs the 'be' bit as loop close) rather than via an explicit runtime JCMP interpreter, since both are skipped/ignored; reason: there is no JCMP branch executor in prec_sim_process.py or prim_model.run_solve, so the PC-rewrite semantics are reconstructed from the loop-stack discipline and the be-bit pairing, not from a literal sigma.PC mutation in source.]
- **extent:** size=1, scalar / single-shot. Because these are in ignored_opcodes, instr_pkt_v2 never sets size (url_deg default 1 is moot -- no packet is built). Operationally each MVLOOPCNT/JCMP is consumed once at its PC slot by the sequencer; it is not a streaming/burst op. The loop body it brackets has its own per-instruction extents; the control op itself moves no elements. MVLOOPCNT trip count (typ1_imm) sets how many times the bracketed body re-runs, but that multiplicity is realized in the body's packets, not in the control op's own extent.
- **fire-rule:** always-fires (self:self, no backpressure). Since no InstrPktV2 is built (ignored_opcodes) there is no can_read/can_write gate (instr_pkt_v2.py:84 can_read / :122 can_write are never reached) and is_done (instr_pkt_v2.py:28 size==done_read==done_write) is vacuous. At decode/sequencer time the op is consumed unconditionally as it is reached on the per-unit PC cursor (prim_model.run_solve walks pkt_i[u] over active_pkt_arr; control ops were already folded out during init_decode loop expansion). No FIFO occupancy, credit, or sync condition gates them. [INFERRED reason: firing is reconstructed from the absence of a packet/can_* path + the skipped_opcodes scheduler list; source has no explicit fire predicate for these ops because they never enter the dataflow scheduler.]
- **sync-dep:** none. Both are listed in prim_model.py skipped_opcodes under '# Control Flow' (alongside NOP, RETURN, JADD/JSUB/...), so run_solve never treats them as schedulable/sync-bearing packets. No handle_sync interaction (type != SYNC; instr_pkt_v2.py:20 type = 'sync' only if 'SYNC' in opcode, false here). No cross-unit dependency, no SEND/GET coupling. Loop semantics are entirely local to the issuing unit's own loop_cnt stack (sigma.LOOP) and PC; they do not wait on or signal any peer unit.
- **terminates:** yes. MVLOOPCNT bounded: pushes exactly one finite-count entry (typ1_imm, capped stack depth 16 via mng_loop), so the bracketed loop has a finite trip count and JCMP exhausts it after that many iterations (loop_cnt entry decremented to 0, popped, fall-through). No data-dependent / unbounded spin in the modeled path (dynloop param is forced 0 in the synthesized stream, prim_analyze.py:716 'dynloop':0). At runtime loops are already fully expanded into active_pkt_arr before run_solve, so the per-unit cursor pkt_i[u] strictly advances to len(active_pkt_arr[u]) and the unit terminates (prim_model.py:354 unit_run_done = pkt_i>=len). [INFERRED: termination for the dynamic-loop (dynloop=1) variant is not exercised in this source path; only static finite counts are modeled.]
- **⚠ residual fixes, from review, to apply on the next clean pass:**
  - Disambiguate the two prim_model.py files: change the skipped_opcodes citation to 'rebel_hw_util/tools/lib/prim_analyze/prim_model.py:332 skipped_opcodes' and keep the top-level 'third_party/rebel_prec_sim/prim_model.py:277/320/354' for run_solve cursor/termination. Both bare 'prim_model.py:...' citations currently read as one file.
  - Fix the sync_dep/fire_rule mechanism: state that run_solve never sees these ops because loops are pre-expanded at init_decode and control ops are absent from active_pkt_arr; the skipped_opcodes list is a constraint-emitter fact (prim_analyze/prim_model.py + prim_random_v2.py:69), NOT a run_solve runtime skip. Do not attribute the skip to run_solve.
  - Correct the loop-depth cap: mng_loop refuses (returns -1) only when len(loop_cnt) > 16 (i.e. permits up to 17 entries), not 'capped at 16'. State the exact predicate.
  - Drop the 'url_deg/size default 1' claim from the extent field and inferred[] (no such default in instr_pkt_v2.py); replace with 'size is never set because no InstrPktV2 is constructed (size=url_deg only on a built packet)'.
  - Reword in_ports/out_ports: 'consume_from/produce_to are None only because no packet object is constructed' rather than 'stays None (never assigned)' -- they are required ctor params, not default-None attributes.
- **citations:**
  - `instr_pkt_v2.py:261-272 ignored_opcodes = [..., 'MVLOOPCNT', ..., 'JCMP', 'JADD', 'JSUB', ...] -- listed control ops never build a packet`
  - `instr_pkt_v2.py:1097-1099 if not_processed: if opcode_str not in cls.ignored_opcodes: raise NotImplementedError -- ignored opcodes silently produce no InstrPktV2`
  - `instr_pkt_v2.py:28 @property is_done: return (self.size == self.done_read) and (self.done_read == self.done_write) -- vacuous for these (no packet)`
  - `instr_pkt_v2.py:84 def can_read / :122 def can_write -- never reached for control ops`
  - `instr_pkt_v2.py:20 self.type = 'sync' if ('SYNC' in self.opcode) else 'data' -- MVLOOPCNT/JCMP are 'data'-typed never-built, not sync`
  - `prim_model.py:332-362 constraints['skipped_opcodes'] = ['NOP','MVLOOPCNT','RETURN','JCMP','JADD','JSUB',...] under '# Control Flow' -- scheduler skips them`
  - `constr_common.py:99-107 mng_loop: if opcode_str=='MVLOOPCNT': if len(loop_cnt)>16: return -1 else loop_cnt.append(1) -- MVLOOPCNT pushes sigma.LOOP, depth cap 16`
  - `constr_common.py:101 unit_rsrc unpack (lrf, loop_cnt, valid_trf, valid_jcr, lastn_lrftgt) -- loop_cnt == sigma.LOOP per-unit stack`
  - `prim_analyze.py:705-734 pc==-999 -> emit MVLOOPCNT {'typ1_imm':size,'dynloop':0,...}; close loop by setting prior instr params['be']=1 -- JCMP/loop-close paired with block-end 'be' bit`
  - `prim_analyze.py:716 'params': {'src0':0,'typ1_imm':pkt.size,'dynloop':0,'cont':0,'brk':0,'force_jump':0} -- static finite loop, dynloop forced 0`
  - `prim_model.py:277,320 p_arr = self.active_pkt_arr[u]; states.pkt_i[u] += 1 -- runtime PC = cursor over pre-expanded packet array; control ops absent`
  - `prim_model.py:354 unit_run_done = (states.pkt_i[pu] >= len(self.active_pkt_arr[pu])) -- unit terminates when cursor exhausts the flat array`
  - `prec_sim_process.py (no MVLOOPCNT/JCMP branch in any *Process.run/handle_*) -- confirmed via grep: control ops have no unit-execution handler`

---

### operational(C3, the constant and scalar register writes IMMCOPY, MODLRFIMM, SUBLRFIMM, MODLRFREG and LRFREGCOPY, on any unit. The SP and AB units carry all five but SUBLRFIMM, which is SP-only, and the VU and XVU carry IMMCOPY alone)  · kahn: **yes**  · ⚠ review-flagged residual fixes
<!-- COVOP id=c3-const tier=review-residual kahn=yes ops=IMMCOPY,MODLRFIMM,SUBLRFIMM,MODLRFREG,LRFREGCOPY note=reviewer-fixlist -->

- **in-ports:** {} (self-loop). consume_from = ["self"]; "self" is in the no-backpressure c_list, so there is no real input FIFO. [instr_pkt_v2.py:1015-1040 "LRF only instr (self -> self): ... consume_from = ['self']"; instr_pkt_v2.py:101-107 "c_list=['sp','self','ext'] ... if c in c_list: amt.append(amt_remaining)"]. REDUCE/GETJCR (the other entries in the same group) DO take ports, but none of the C3 five do.
- **out-ports:** {} (self-loop). produce_to = ["self"]; "self" is in the no-backpressure p_list, so no real output FIFO is pushed and is_ofifo_stalled never trips. [instr_pkt_v2.py:1039-1040 "produce_to = ['self']"; instr_pkt_v2.py:130-137 "p_list=['sp','self','ext'] ... if p in p_list: amt.append(amt_remaining)"; instr_pkt_v2.py:59-62 is_ofifo_stalled skips p in p_list].
- **reg/sp-write:** VU/XVU IMMCOPY: writes sigma.LRF (the LRF DATA-register file) at ctx.lrf[lrf_tgt] for every enabled slice (lrf_tgt&0xF, gated by slice_en bitmask; lane-fill governed by replica/mode). [prec_sim_process.py:1728-1750 VU sim_non_comp IMMCOPY "ctx.lrf[lrf_tgt][i] = lrf_data"; prec_sim_process.py:2325-2350 XVU IMMCOPY adds mode!=0 odd-lane variant]. SP/AB-side IMMCOPY/MODLRF*/SUBLRFIMM/LRFREGCOPY: write the LRF ADDRESS-scratch register indexed by src0 (dnc_isa param_dict gives src0+typ1a_imm for IMMCOPY/MODLRFIMM/SUBLRFIMM, src0+src1 for MODLRFREG/LRFREGCOPY); used to compute SP/AB load/store addresses. [dnc_isa.py:492-497 param_dict["SP"]; dnc_isa.py:107-111 param_dict["AB"]; constr_splu.py:349-363 pre-instr "IMMCOPY ... make src0 aligned to 0x80", which confirms src0 is an address register]. [INFERRED: exact MODLRFIMM/SUBLRFIMM/MODLRFREG/LRFREGCOPY value math, since no executable handler exists in prec_sim_process.py; the denotational layer owns it.] None of these touch SP/SHM memory; reg-write only.
- **extent:** size = url_deg = 1 (single fixed-size beat). These opcodes are NOT in ignored_opcodes, so make_pkt_info emits a real packet with the default url_deg=1 (no size= override; size is overridden only for REDUCE). [instr_pkt_v2.py:261-272 ignored_opcodes = MVLOOPCNT/NOP/RETURN/J* only, with none of the C3 five listed; instr_pkt_v2.py:285 "url_deg = 1"; instr_pkt_v2.py:1105-1106 "if size is not None: url_deg = size" applies to REDUCE only].
- **fire-rule:** Always-fires, single tick, no backpressure. With self-only ports, can_read returns amt_remaining (= size − done_read = 1) and can_write returns amt_remaining unconditionally, and neither consults a sibling FIFO occupancy. [instr_pkt_v2.py:91 "amt_remaining = self.size - self.done_read"; instr_pkt_v2.py:104-107 self-branch appends amt_remaining; instr_pkt_v2.py:134-137 self-branch appends amt_remaining]. Self:self placement also exempts it from is_ofifo_stalled [instr_pkt_v2.py:51-82].
- **sync-dep:** None. type=="data" (no "SYNC" substring) [instr_pkt_v2.py:20 'self.type = "sync" if ("SYNC" in self.opcode) else "data"']. Does not go through handle_sync. No JCR/SAR/CAR consumer, no cross-unit dependency. [INFERRED from absence: no handle_sync / GETJCR path is taken for the C3 five, since those branch off opcode=="GETJCR"/"SYNC" in each Process.run before the LRF group; reason: grep of SPLU/SPSU/ABLU/ABSU run() bodies shows only GETJCR/SYNC/SHUFFLE/MERGE/SENDTRF/SENDJCR branches, prec_sim_process.py:686-690, 1154+, 1253+].
- **terminates:** yes, in a single beat, done after one fire (see fire_rule/extent).
- **⚠ residual fixes, from review, to apply on the next clean pass:**
  - Correct the scheduler citation file: change 'prim_model.py:332-348' to 'rebel_hw_util/tools/lib/prim_analyze/prim_model.py:332-362' and note the LRF block comment-out is at 345-348 (top-level prim_model.py named in the source map has no skipped_opcodes).
  - In reg_sp_write, replace 'sigma.LRF'/'sigma.LRF_c' with the actual symbol ctx.lrf (UnitContext.lrf), or explicitly mark sigma.LRF as a spec-side denotational alias for ctx.lrf.
  - Fix the gate description in reg_sp_write: the write is conditioned on `lrf_tgt >= 0x10` with `lrf_tgt -= 0x10` (prec_sim_process.py:1735/2332); replace the '(lrf_tgt&0xF ...)' phrasing.
  - Minor: in fire_rule, can_write's amt_remaining is `done_read - done_write` (line 129), not `size - done_read`; tighten the parenthetical (does not change the always-fires conclusion).
  - Optional: tighten is_ofifo_stalled line cite to 55-61 (block says 59-62/51-82); within drift tolerance.
- **citations:**
  - `instr_pkt_v2.py:1015-1040 'LRF only instr (self -> self): ... consume_from = ["self"]; produce_to = ["self"]' lists MODLRFREG/LRFREGCOPY/MODLRFIMM/SUBLRFIMM/IMMCOPY`
  - `instr_pkt_v2.py:261-272 ignored_opcodes = [MVLOOPCNT,NOP,RETURN,JCMP,JADD,JSUB,JIMMCOPY,JSWAP,JSHR,JARITH], with the C3 five absent, so they are packetized`
  - `instr_pkt_v2.py:285 'url_deg = 1' default size`
  - `instr_pkt_v2.py:15 'self.size = self.url_deg'; instr_pkt_v2.py:28-29 is_done == (size==done_read==done_write)`
  - `instr_pkt_v2.py:91,104-107 can_read self-branch amt_remaining; instr_pkt_v2.py:134-137 can_write self-branch amt_remaining (no FIFO check)`
  - `instr_pkt_v2.py:51-82 is_ofifo_stalled skips ports in p_list (incl 'self')`
  - `instr_pkt_v2.py:20 type='data' (no SYNC substring)`
  - `prec_sim_process.py:1467 VUProcess dispatch 'if (not src_dict): return self.sim_non_comp(...)'`
  - `prec_sim_process.py:1728-1750 VU sim_non_comp IMMCOPY: 'ctx.lrf[lrf_tgt][i] = lrf_data' across slice_en, repl/mode lane fill`
  - `prec_sim_process.py:2325-2350 XVU sim_non_comp IMMCOPY: adds mode!=0 odd-lane (j%2==1) variant`
  - `prec_sim_process.py:1757-1758 / 2357-2358 / 2733-2734 else-arm raises InstrNotImplementedError for non-IMMCOPY noncomp opcodes`
  - `prec_sim_process.py:686-690 SPLUProcess.run handles only GETJCR/SYNC before data ops (no LRF-reg branch)`
  - `dnc_isa.py:492-497 param_dict['SP']: MODLRFREG/LRFREGCOPY=[src0,src1,be]; MODLRFIMM/SUBLRFIMM/IMMCOPY=[src0,typ1a_imm,be]; dnc_isa.py:107-111 same for AB; dnc_isa.py:822 VU IMMCOPY=[typ1_imm,replica,lrf_tgt,slice_en,be]`
  - `dnc_isa.py:376-380 SP opcode_dict: SUBLRFIMM=0x0D present (SP-only); VU/XVU opcode_dict (652/706) list only IMMCOPY of the five`
  - `constr_splu.py:14-33 opcode_options['self:self'] includes all five; constr_vu.py:77-89 / constr_xvu.py:87-92 VU/XVU self:self list only IMMCOPY`
  - `constr_splu.py:349-363 IMMCOPY pre-instr 'make src0 aligned to 0x80' ⇒ src0 is an SP load-address register`
  - `prim_model.py:332-348 scheduler skipped_opcodes: control-flow J* skipped, the LRF block (MODLRFREG/LRFREGCOPY/MODLRFIMM/SUBLRFIMM/IMMCOPY/SXRIMM...) is COMMENTED OUT ⇒ NOT skipped, scheduled as normal self:self packets`

---

### operational(D10, the cross-lane tree reduction on either vector unit)  · kahn: **yes**  · ⚠ review-flagged residual fixes
<!-- COVOP id=d10-reduce tier=review-residual kahn=yes ops=REDUCE note=reviewer-fixlist -->

- **in-ports:** one compute-stream FIFO, and exactly one upstream FIFO, selected at decode from rsm_src0's source-class tag. instr_pkt_v2.py:1069-1084 maps the tag to a concrete consumer FIFO: "splu"→`splu{ncore}`, "vu"→`vu{ncore}`, "xvu"→`xvu{ncore}`, "tu"→`tu{ncore}:7`; tags not in that set fall back to "self" (no FIFO). For matmul reductions src0=splu → consume_from=[`splu{ncore_idx}`]. The sibling-lane neighbor input (`SRC_NBR`: 0x3 VU / 0x4 XVU, wired as src2 in reduce_payload, prec_sim_process.py:1355) is NOT a FIFO port but an intra-unit lane-shuffle read handled inside prec_sim.so (`s2nbr`, prec_sim_process.py:1822 "[NBR/Reduce] Read from prev output handled in prec_sim.so"), so it does not appear in consume_from.
- **out-ports:** {} (self-loop). produce_to = ["self"] (instr_pkt_v2.py:1045 `produce_to = ["self"]`). The reduction result is written to the LOCAL register file `sigma.LRF[rsm_tgt]`, not pushed to a downstream FIFO. (The generic VUProcess.run output dict can fan to spsu/xvu FIFOs via out_sp/out_xvu data_type≥1, prec_sim_process.py:1511-1520, but REDUCE's desugared params set lrf_tgt≥0x10 / no out_* so the result lands in LRF; the per-packet produce_to is self.)
- **reg/sp-write:** sigma.LRF[rsm_tgt]. reduce_payload sets `params["lrf_tgt"]=rsm_tgt` (prec_sim_process.py:1356); rsm_tgt = bits[13:17] of reduce_imm (prec_sim_process.py:1351). In run(), `is_lrf_tgt = params["lrf_tgt"] >= 0x10` (prec_sim_process.py:1503) gates the LRF write at sim()/sim_128b() (e.g. prec_sim_process.py:1794-1796 `ctx.lrf[lrf_tgt] = ...`). Across the url-unrolled iterations the tree accumulates into LRF[rsm_tgt - 0x10 (+ i if url_tgt)] (prec_sim_process.py:1540). No SP / SHM write. [INFERRED] the read-modify-write each step folds the prior LRF[tgt] with the SRC_NBR sibling lane (the make_nfwd sibling-permutation tables prec_sim_process.py:1405-1429 supply src0/src2 from LRF[lrf_tgt]), and the exact fold lives in prec_sim.so and is the value-semantics layer, not restated here.
- **extent:** size = min(rsm_url, 4), where rsm_url = bits[10:13] of reduce_imm (instr_pkt_v2.py:1049-1050 `rsm_url = (rsm_imm>>10)&0x7; size = min(rsm_url,4)`). This is url_deg = the log2 tree depth: the cross-lane reduction over up to 2^4=16 elements runs as `size` back-to-back log-tree stages. InstrPktV2.size = url_deg (instr_pkt_v2.py:15). The run() loop iterates `for i in range(curr_size, curr_size+amt)` (prec_sim_process.py:1535) applying url-unroll (url=0b100111 set in reduce_payload prec_sim_process.py:1357 → url_amt on src0/src1/tgt) so each of the `size` stages advances src/tgt by i.
- **fire-rule:** Fires when the upstream compute-stream FIFO has data AND the self-loop output slot is free. can_read (instr_pkt_v2.py:84-120): for the FIFO consumer `c`, requires `state.state[f"{c}_{unit}"] > 0`; amt = min(amt_remaining, available); for "self" consumers requires `done_read < size`. can_write (instr_pkt_v2.py:122-154): produce_to=["self"] is in p_list → always-writable (amt = done_read - done_write). is_done when `size == done_read == done_write` (instr_pkt_v2.py:28-29). So it is a backpressured data actor on the read side, free on the write side. Constraint helper allows REDUCE size>4 specially (constr_vu.py:544-545 `elif (pkt.size > 4) and (opcode_str=="REDUCE"): return True`), a multi-source-amt exemption distinct from the generic size==3 path.
- **sync-dep:** none intrinsic to the reduce, which carries no SYNC or MESYNC token (pkt.type = "data", not "sync"; instr_pkt_v2.py:20 sets type="sync" only when "SYNC" in opcode). Ordering w.r.t. the producer is enforced purely by FIFO backpressure on the consumed compute stream (the matmul/softmax producer, e.g. SPLU drain, must have pushed before REDUCE can read). [INFERRED] any global rendezvous is provided by separate VU/XVU SYNC ops in the program, not by this op.
- **terminates:** Yes. Bounded: exactly `size = min(rsm_url,4) ≤ 4` tree stages; is_done latches at `done_read==done_write==size` (instr_pkt_v2.py:28-29), done_read asserts `≤ size` (instr_pkt_v2.py:165). The per-iteration loop `range(curr_size, curr_size+amt)` is finite. No data-dependent loop count; rsm_url is a static immediate field.
- **⚠ residual fixes, from review, to apply on the next clean pass:**
  - Family header: replace 'reuses run/reduce_payload verbatim, differing only in SRC_NBR and fifo_name_remap' with what is actually the case: XVUProcess (1945) overrides run() at 1998 (different input-source set vu/splu at 2047 vs tu/xvu/splu at 1483, different output dict 2082-2099); only reduce_payload (2009) and make_nfwd are inherited. The OPERATIONAL fields here are decode-level (instr_pkt_v2.py:1042-1084) and ARE unit-shared, so state that explicitly rather than asserting handler-level verbatim reuse.
  - fire_rule: fix the constr_vu.py:544-545 gloss, since it is in unfit_opcode and REJECTS REDUCE with size>4 (enforcing the max-4-stage bound), it does not 'allow' it. Either drop the sentence or re-state as a hard upper bound consistent with size=min(rsm_url,4).
  - extent: correct 'url_amt on src0/src1/tgt' to 'url-unroll on src0 and lrf_tgt only (url=0b100111 ⇒ url_s0,url_tgt set; url_s1,url_s2 clear)'; fix the 1535-1540 citation gloss accordingly.
  - Optional: tighten rsm_tgt bit-range to [13:18) (5 bits) and re-attribute the '[NBR/Reduce]' comment line (1819/1783) vs s2nbr (1822).
- **citations:**
  - `prec_sim_process.py:1345-1346 SRC_NBR=0x3; def reduce_payload(self,params), the VU neighbour source and desugar entry`
  - `prec_sim_process.py:1347-1357 rsm_src/rsm_opc/rsm_url/rsm_tgt = bit-slices of reduce_imm; params src0=rsm_src, src2=SRC_NBR, lrf_tgt=rsm_tgt, url=0b100111`
  - `prec_sim_process.py:1358-1400 rsm_opc → concrete opcode (FMA/FMABF/PACK/FMINMAX/SELECT/FMUL/FMULBF/LOGICAL), the value layer`
  - `prec_sim_process.py:1441-1443 if opcode==REDUCE: is_reduce=True; opcode,params=self.reduce_payload(params)`
  - `prec_sim_process.py:1503 is_lrf_tgt = params['lrf_tgt'] >= 0x10, which gates the LRF write`
  - `prec_sim_process.py:1535-1540 for i in range(curr_size,curr_size+amt): url-unroll on src0/src1/tgt and lrf_tgt`
  - `prec_sim_process.py:1483-1485 fifo lookup for src in {tu,xvu,splu} via fifo_name_remap → ififos[fifo_name]`
  - `prec_sim_process.py:1794-1796 ctx.lrf[lrf_tgt]=..., the LRF[rsm_tgt] write`
  - `prec_sim_process.py:1822 s2nbr / '[NBR/Reduce] Read from prev output handled in prec_sim.so'`
  - `prec_sim_process.py:1338-1342 VUProcess.fifo_name_remap (tu→tu{nc}:7 else unit{nc})`
  - `prec_sim_process.py:1992-1996 XVUProcess.fifo_name_remap=unit{nc}; SRC_NBR=0x4, the per-variant difference`
  - `prec_sim_process.py:1945-1946 class XVUProcess(VUProcess), the shared handler`
  - `instr_pkt_v2.py:1042-1050 elif opcode_str=='REDUCE': consume_from=[]; produce_to=['self']; size=min(rsm_url,4)`
  - `instr_pkt_v2.py:1069-1084 src0_tag → consume_from.append(splu/vu/xvu/tu{nc} or 'self')`
  - `instr_pkt_v2.py:15 self.size=self.url_deg`
  - `instr_pkt_v2.py:28-29 is_done: size==done_read==done_write`
  - `instr_pkt_v2.py:84-120 can_read FIFO-occupancy gate`
  - `instr_pkt_v2.py:122-154 can_write self in p_list → free`
  - `instr_pkt_v2.py:20 type='sync' only if 'SYNC' in opcode (REDUCE→'data')`
  - `instr_pkt_v2.py:261-272 ignored_opcodes (REDUCE not listed)`
  - `constr_vu.py:131 reduce_opcodes set; :405-417 REDUCE reduce_imm packing; :107-108/122-123 src0 'nbr'=0x3 'splu'=0x4 source-class`
  - `constr_vu.py:544-545 elif pkt.size>4 and REDUCE: return True`

---

### operational(D11, the SPLU's transfer-register ops: LDTRF and its variants, SHUFFLE, MERGE, SENDTRF and SENDJCR)  · kahn: **NON-KAHN**  · ⚠ review-flagged residual fixes
<!-- COVOP id=d11-trf tier=review-residual kahn=no ops=LDTRF,SHUFFLE,MERGE,SENDTRF,SENDJCR note=reviewer-fixlist -->

- **in-ports:** Per-variant (consume_from in instr_pkt_v2.py SPLU block, lines 518-637):
• LDTRF and its variants take in={sp} and read SP. (instr_pkt_v2.py:532 "consume_from = sp"; the LD*TRF set forces produce_to=self at :533-534.)
• SHUFFLE: in={sp} declared by the shared LD branch (instr_pkt_v2.py:519,532 SHUFFLE in the LD opcode list, consume_from="sp"). NOTE the actual datum permuted is ctx.trf[trf_src0] read in run() (:844 get_trf_src) rather than SP, and the declared "sp" port is the packet front-end's generic read source; [INFERRED] the SP read is performed but its result is unused by the SHUFFLE tail, which reads TRF instead. Backpressure is still gated on the sp state.
• SENDTRF: in={sp} (same shared LD branch, :519,532); tail reads ctx.trf[trf_src0] via get_trf_src (:943). Same SP-port-declared-but-TRF-sourced pattern as SHUFFLE.
• MERGE takes in={} and is a self-loop. consume_from never assigned in the MERGE branch (instr_pkt_v2.py:630-637 sets only size+not_processed), so it falls through to None → resolves to self:self (constr_splu.py:14 lists MERGE under "self:self"). Reads ctx.trf[trf_src0] and [trf_src1] in run() (:886-887) with no FIFO read.
• SENDJCR: in={self} (instr_pkt_v2.py:611 "consume_from = self"); reads ctx.load_jcr_buffer register (:981), no FIFO read.
- **out-ports:** Per-variant (produce_to):
• LDTRF and its variants take out={self} and write ctx.trf[trf_dst1] in-unit (instr_pkt_v2.py:533-534 produce_to="self"; prec_sim_process.py:771-775 'if "TRF" in opcode: ctx.trf[trf_dst1]'). No outbound FIFO.
• SHUFFLE: out = ld_consumer-decoded target unit FIFO when ld_consumer!=0, else out={self} (TRF self-write). (instr_pkt_v2.py:536 produce_to=inst_param_tag(ld_consumer); prec_sim_process.py:832 'selfwrite = ld_consumer==0x0'; :876-878 selfwrite→ctx.trf[trf_dst0], else :880-882 fifo.append to each ofifo.)
• SENDTRF: out = ld_consumer target FIFO; out={self} is forbidden and raises InstrParamError on consumer==0 (prec_sim_process.py:945-946 "SENDTRF sending to self is not allowed!"; :948-950 fifo.append). Effective out = {<consumer unit FIFO>}.
• MERGE takes out={} as a self-loop and writes ctx.trf[trf_dst0] and ctx.trf[trf_dst1], no FIFO (prec_sim_process.py:927-930; produce_to unset in instr_pkt_v2.py:630-637 → self).
• SENDJCR: out = up to 7 per-NCore target JCR FIFOs "uan_{spsu|splu|absu|ablu|xvu|vu|tu}{ncore}_jcr", tu expands to 8 rows ":i_jcr" (prec_sim_process.py:1000-1024; instr_pkt_v2.py:619-628). Selected by 7-bit consumer_mask × strb. Out is the JCR control-fifo plane, not the data FIFO mesh.
- **reg/sp-write:** • LDTRF/LD*TRF: σ.TRF[trf_dst1] := load_data; valid:=True (prec_sim_process.py:772-774 'trf_dst1=(trf_dst1+curr_size+i)%8; ctx.trf[trf_dst1]["value"]=load_data'). Also decrements sp_access read-credit (:782-784). No SP write. [Note: the LD-family ld_type==1 self-write to ctx.load_jcr_buffer at :806-807 is the non-TRF LOADJCR-style path, not the LDTRF tail.]
• SHUFFLE: σ.TRF[trf_dst0] := permuted result, ONLY when selfwrite (ld_consumer==0) (:877-878). Otherwise no reg write (data leaves via FIFO).
• MERGE: σ.TRF[trf_dst0], σ.TRF[trf_dst1] := merge outputs, ALWAYS (no selfwrite gate) (:927-930).
• SENDTRF makes no register write, being a pure FIFO push from σ.TRF[trf_src0] (or zeros if params['sendz'], :939-943).
• SENDJCR: σ.send_jcr_offset_reg := next_offset_reg (the 16-entry SendJCR offset register; reset/inc per offset_rst/offset_inc, mod 16) (prec_sim_process.py:970-977). Reads (not writes) σ.load_jcr_buffer. No TRF/SP write. It mutates no other register file, being one dedicated offset register + FIFO emission.
• All: σ.txn_ctr incremented per processed element (:813,816,883,951,1025).
- **extent:** size = url_deg from instr_pkt_v2.py SPLU block:
• LDTRF/LD*TRF: burst? size = trf_burst_sz else 64; non-burst size=1; ×{1,2,4} by interleave_sz∈{_,2,3} (instr_pkt_v2.py:528-530 trf_burst_sz path, :545-555). TRF holds 8 entries so curr_size+i is %8 (prec_sim_process.py:772).
• SHUFFLE/SENDTRF: burst? size=trf_burst_sz else 8; non-burst size=1 (instr_pkt_v2.py:525-526,546-547). Loop 'for i in range(curr_size, curr_size+amt)' (:824).
• MERGE: burst? size=trf_burst_sz else 8; non-burst size=1 (instr_pkt_v2.py:630-636).
• SENDJCR: size = popcount(strb) over 4 bits, min 1 (instr_pkt_v2.py:480-486; prec_sim_process.py:1016 'for s,data in zip(strb,jcr_data_2B)'). Each set strb bit emits one 2B element to every masked target.
[INFERRED] None of these are in ignored_opcodes (instr_pkt_v2.py:261-272), so all carry a real url_deg≥1 and a packet, which confirms they are data-class rather than skipped.
- **fire-rule:** is_done: size==done_read==done_write (instr_pkt_v2.py:28-29 "is_done: (size==done_read) and (done_read==done_write)"). Firing per variant:
• MERGE, with neither port, is self:self, so can_read amt = size-done_read with consume "self" treated as always-available (instr_pkt_v2.py:104-107 'if c in ["sp","self","ext"]: amt=amt_remaining'); can_write "self" always True (:135-137). ⇒ always-fires, no backpressure.
• LDTRF/LD*TRF (in={sp} out={self}): read gated on SP state credit (instr_pkt_v2.py:104,110-116 sp is NOT in self-list so checks state.state[sp_splu]); write self always-ready. Fires when SP source has data.
• SHUFFLE/SENDTRF (in={sp} out=consumer): read gated on sp; write gated on the consumer ofifo not stalled (is_ofifo_stalled at can_read:94-98, and produce_to FIFO credit at can_write:139-143). Backpressure from downstream consumer FIFO.
• SENDJCR (in={self} out=jcr fifos): read self always-ready; write gated on each "uan_*_jcr" fifo, and the 'jcr' branch uses the bare tag as state key (can_write:140-143 'if "jcr" in p: st=p'). Fires when all masked JCR fifos have room.
All advance done_read then done_write incrementally (run_read:164, run_write:207, with assert done_write<=done_read<=size).
- **sync-dep:** These ops are NOT SYNC packets (type=="data" since "SYNC" not in opcode; instr_pkt_v2.py:20). SPLU SYNC is a separate opcode (instr_pkt_v2.py:557-593, handle_sync prec_sim_process.py:389-409 imm_fld="typ1_imm", put/get bits) and out of this family. Cross-unit dependency for the TRF family is carried implicitly:
• LDTRF/SHUFFLE/SENDTRF/MERGE producer-consumer ordering vs SP and vs the downstream consumer unit is enforced by FIFO credits + the surrounding SP SYNC fences, NOT by these ops themselves.
• TRF is a private register file of 8 entries, so a chain through it inside one SPLU have a true RAW dependency through ctx.trf that is NOT visible to the FIFO scheduler ([INFERRED] reg-level hazard; the simulator serializes by PC order within the unit so it is satisfied implicitly).
• SENDJCR→GETJCR is the JCR control handshake: SENDJCR pushes onto uan_*_jcr; the consumer's GETJCR pops it (handle_get_jcr prec_sim_process.py:366-386 'ififo.pop(0)'). This is an explicit cross-unit control dependency carried on the JCR fifo plane.
- **terminates:** yes, and bounded. Each variant's run() loops a finite number of times: LD-tail over sp_addrs (one per packet element), permute/send tail 'for i in range(curr_size, curr_size+amt)' with amt≤size (prec_sim_process.py:824), SENDJCR over the ≤4 strb bits × ≤7(or +8 for tu) targets (:1016-1024). size is a finite url_deg (≤64 for LDTRF, ≤8 for SHUFFLE/SENDTRF/MERGE, ≤4 for SENDJCR). is_done is monotone (done_read/done_write only increase, capped by asserts at :165,208). No unbounded/data-dependent loop. SENDJCR/SENDTRF raise (terminate the program) on misuse: SENDTRF self-send (:946), SENDJCR with unset load_jcr_buffer (:962).
- **⚠ residual fixes, from review, to apply on the next clean pass:**
  - out_ports SENDJCR: the prose says 'tu expands to 8 rows' but the packet builder (instr_pkt_v2.py ~607-610) expands BOTH tu and ablu to 8 at scope=='dnc'. Either widen the prose to 'tu and ablu expand to 8 rows at dnc scope' to match the citation, or note the handler/packet divergence explicitly.
  - Flag the handler/packet-builder mismatch: prec_sim_process.py:1009 expands only 'tu' (never ablu) to 8 JCR targets, whereas instr_pkt_v2.py expands tu AND ablu at dnc scope. This asymmetry holds and is currently unflagged, so surface it as an inferred divergence or a defect note.
  - inferred[2]: correct the exception name, since get_trf_src raises InstrParamError (prec_sim_process.py:1031), not InstrUsageError.
  - constr_splu citation: fix line ref (the active self:self list is ~16-34, not the commented line 14) and add that SHUFFLE appears in BOTH 'self:self' and 'self:etc' opcode_options, and the block currently lists SHUFFLE only under self:etc.
  - Optional: note that consume_from/produce_to for MERGE remain None (not the literal string 'self'); is_distributing returns False. The 'self:self' label comes from constr_splu, not from the packet's port strings, and the block's wording could read as if produce_to=='self'.
- **citations:**
  - `prec_sim_process.py:678 class SPLUProcess(UnitProcess)`
  - `prec_sim_process.py:685 def run(... sp_addrs, sp, ififos, ofifos, curr_size, amt, sp_access, sync_dir)`
  - `prec_sim_process.py:686-690 dispatch: GETJCR->handle_get_jcr, SYNC->handle_sync`
  - `prec_sim_process.py:771-775 LDTRF tail: 'if "TRF" in opcode: trf_dst1=(trf_dst1+curr_size+i)%8; ctx.trf[trf_dst1]["value"]=load_data'`
  - `prec_sim_process.py:818 'if opcode not in [SHUFFLE,MERGE,SENDTRF,SENDJCR]: return'`
  - `prec_sim_process.py:823-824 'if opcode in [SHUFFLE,MERGE,SENDTRF]: for i in range(curr_size, curr_size+amt)'`
  - `prec_sim_process.py:831-883 SHUFFLE: selfwrite=ld_consumer==0; _sim permute; selfwrite->ctx.trf[trf_dst0] else fifo.append`
  - `prec_sim_process.py:885-934 MERGE: get_trf_src(src0/src1); _sim; ctx.trf[trf_dst0]/[trf_dst1] both written (no consumer gate)`
  - `prec_sim_process.py:936-951 SENDTRF: send_zero? zeros : get_trf_src(src0); selfwrite raises InstrParamError; else fifo.append per ofifo`
  - `prec_sim_process.py:953-1025 SENDJCR: load_jcr_buffer guard; offset/send_jcr_offset_reg update %16; consumer_mask 7b × strb 4b -> uan_<tgt><ncore>_jcr (tu x8); ofifos[tgt].append((txn_id,data))`
  - `prec_sim_process.py:1028-1032 get_trf_src: raise if not ctx.trf[src]['valid'] else return value`
  - `prec_sim_process.py:366-386 handle_get_jcr: ififo.pop(0) JCR handshake consumer side`
  - `prec_sim_process.py:107-108 ctx.load_jcr_buffer/send_jcr_offset_reg init`
  - `instr_pkt_v2.py:7-29 InstrPktV2(consume_from,produce_to,url_deg); size=url_deg; is_done: size==done_read==done_write`
  - `instr_pkt_v2.py:20 type='sync' if 'SYNC' in opcode else 'data'`
  - `instr_pkt_v2.py:261-272 ignored_opcodes (none of LDTRF/SHUFFLE/MERGE/SENDTRF/SENDJCR present)`
  - `instr_pkt_v2.py:518-556 SPLU LD/SHUFFLE/SENDTRF: consume_from='sp'; LD*TRF produce_to='self'; else produce_to=ld_consumer tag; size=trf_burst_sz/64/8 × interleave`
  - `instr_pkt_v2.py:595-628 SPLU SENDJCR: consume_from='self'; size=popcount(strb); produce_to=uan_*_jcr per consumer_mask, tu/ablu x8 at dnc scope`
  - `instr_pkt_v2.py:630-637 SPLU MERGE: only size+not_processed set; consume_from/produce_to stay None -> self:self`
  - `instr_pkt_v2.py:84-120 can_read: 'self'/'sp'/'ext' in c_list always-amt; jcr/sync use bare tag state key; ofifo_stall gate`
  - `instr_pkt_v2.py:122-143 can_write: 'self' always True; jcr branch st=p`
  - `constr_splu.py:14 MERGE under opcode_options['self:self']`
  - `constr_splu.py:36-37 'self:etc'=[SHUFFLE,SENDTRF]; 'etc:self'=[LDTRF,LDUTRF,LDITRF,LDIUTRF]`
  - `prim_model.py:253 run_solve (scheduler; no per-opcode skip list for this family)`

---

### operational(D9, the NCSU's burst store from the scratchpad out to SHM, over several lines)  · kahn: **yes**  · ⚠ review-flagged residual fixes
<!-- COVOP id=d9-stmu tier=review-residual kahn=yes ops=STMU note=reviewer-fixlist -->

- **in-ports:** {sp}  (consume_from="sp"). Reads the resolved SP read-stream. Per-burst-line it copies one 128B SP granule (sp.buf[rd_addr*128 : rd_addr*128+128]). "sp" is a self-buffered endpoint (in can_read's c_list / run_read's c_list), so it is read at full amt_remaining without peer-FIFO backpressure. (instr_pkt_v2.py:385 consume_from="sp"; :104-106 c_list self-endpoint; prec_sim_process.py:514 `for rd_addr, wr_addr in zip(sp_addrs, ext_addrs)`)
- **out-ports:** {ext}  (produce_to="ext"). Destination is resolved per-line through apply_NC_TLB(wr_addr): if wr_paddr >= REBEL_SHM_PA_BASE_128B it writes SHM (shm.buf[shm_addr*128 : +128] = sp 128B, marks shm_lines[shm_addr]=True); else it writes SP (cross-DNC SP store, sp_arr[wr_sp_idx]). "ext" is also a self-buffered endpoint (in p_list), so it never stalls on a peer FIFO. Burst variant writes B contiguous 128B SHM lines. (instr_pkt_v2.py:386 produce_to="ext"; prec_sim_process.py:516 apply_NC_TLB, :518-536 SHM-write branch, :538-557 SP-write branch)
- **reg/sp-write:** SHM (or cross-DNC SP) is the destination rather than a state register, so this is a data store and not a control op. Writes sigma.SHM[shm_addr*128 .. +128] per burst line and sets shm_lines[shm_addr]=True (line-valid bit); STMU additionally implies addr-gen auto-advance ('U' = update) but the handler body is identical to STM (the advance is folded into sp_addrs/ext_addrs the scheduler hands in, and no further state mutation is visible in run()). No LRF/JCR/SAR/CAR/LOOP/PC/SYNC write. (prec_sim_process.py:535 `shm.buf[...] = sp.buf[...]`, :536 `shm_lines[shm_addr] = True`)
- **extent:** size = burst = field "burst" (if burst==0 → 32). One unit of extent = one 128B granule line; STMU streams B back-to-back 128B SP→SHM line copies. url_deg = size = burst. (instr_pkt_v2.py:381-387 `burst = get_fld(...,"burst"); if burst==0: burst=32; size = burst`; pkt url_deg=size at :1106/:1114)
- **fire-rule:** Self-paced, no peer backpressure. Both endpoints (sp in, ext out) are self-buffered, so can_read returns amt_remaining (= size - done_read) and can_write returns done_read - done_write each unstalled; is_ofifo_stalled is false (produce_to="ext" is in p_list). Read advances done_read, write advances done_write, asserting done_write <= done_read <= size. Effectively always-fires until the burst drains. (instr_pkt_v2.py:91 amt_remaining; :104-107 sp self-endpoint read; :134-137 ext self-endpoint write; :164-165 done_read; :207-208 done_write)
- **sync-dep:** None structural. STMU itself carries no SYNC dependency (SYNC is dispatched out the front of NCSUProcess.run before the store path: `elif "SYNC" in opcode: return self.handle_sync(...)`). Ordering vs producers of the SP read-data and consumers of the stored SHM is enforced separately by NCSU SYNC ops, not by STMU. [INFERRED: cross-unit producer→STMU→consumer ordering relies on surrounding SYNC barriers. The reason: this packet has no sync ports, type=="data".] (prec_sim_process.py:502-503 SYNC pre-dispatch)
- **terminates:** Yes. is_done := (size == done_read) and (done_read == done_write); the burst terminates after B lines are both read from SP and written to ext. Bounded by the static burst field (<=32 when 0). (instr_pkt_v2.py:28-29 is_done)
- **⚠ residual fixes, from review, to apply on the next clean pass:**
  - out_ports: drop or flag 'B contiguous 128B SHM lines' as inferred, since each line's destination is computed independently from each ext_addr (prec_sim_process.py:514-519), not guaranteed contiguous (STMG is the scatter sibling).
  - Optional: fix the prec_sim_process.py:498 signature citation to reflect actual param order, or trim to params actually relied on.
  - Optional precision: inferred[] note 'STMG/STMGU differ only in addr-stride/scatter shape' is incomplete, since the 'G' variants also bypass the NC TLB (apply_NC_TLB va_force = 'G' in opcode, prec_sim_process.py:413-415). It does not matter for STMU.
- **citations:**
  - `prec_sim_process.py:498 NCSUProcess.run signature (sp, shm, sp_arr, ext_addrs, sp_addrs)`
  - `prec_sim_process.py:502-503 `elif "SYNC" in opcode: return self.handle_sync(...)` (SYNC pre-dispatched, not STMU's concern)`
  - `prec_sim_process.py:513-514 `# Basic ST (SP -> SHM/EXT)` / `for rd_addr, wr_addr in zip(sp_addrs, ext_addrs)``
  - `prec_sim_process.py:516 `wr_paddr = self.apply_NC_TLB(pc, opcode, wr_addr, ctx)``
  - `prec_sim_process.py:518-519 `if wr_paddr >= REBEL_SHM_PA_BASE_128B: shm_addr = wr_paddr - REBEL_SHM_PA_BASE_128B``
  - `prec_sim_process.py:535 `shm.buf[shm_addr*128 : shm_addr*128 + 128] = sp.buf[rd_addr*128 : rd_addr*128 + 128].tobytes()``
  - `prec_sim_process.py:536 `shm_lines[shm_addr] = True``
  - `prec_sim_process.py:538-557 SP-destination (cross-DNC) branch when wr_paddr < SHM base`
  - `instr_pkt_v2.py:378-387 `elif unit == "NCSU": if opcode_str in [...,"STMU",...]: burst=get_fld(..."burst"); if burst==0: burst=32; consume_from="sp"; produce_to="ext"; size=burst``
  - `instr_pkt_v2.py:28-29 is_done: `(size==done_read) and (done_read==done_write)``
  - `instr_pkt_v2.py:104-107 can_read sp self-endpoint (no peer FIFO)`
  - `instr_pkt_v2.py:134-137 can_write ext self-endpoint (no peer FIFO)`
  - `instr_pkt_v2.py:261-272 ignored_opcodes (STMU NOT listed → real packet, moves FIFO data)`
  - `constr_ncsu.py:37 `opcode_options["etc:etc"] = ["STM","STMU","STC","STCU","STS","STSU","STMG","STMGU"]` (source-class etc:etc)`
