# NCore op spec (operational-semantics, in progress)

The goal is an abstract-machine spec of NCore execution: define the architecture
state `sigma`, then specify each op as a state transition (what it reads, what it
writes). Numeric datatype semantics (`dlf16` rounding, the `*`/`+` of an FMA) are
deliberately **out of scope**; this captures *control + dataflow* only.

## What belongs here, and the criterion for promoting a fact into it

A fact enters `families_*` **iff it changes what a *single instruction* does or which
field values it legally accepts**, which is a per-instruction execution constraint (a field
encoding, legal range, state effect, a field-combination rule). Examples that qualify:
the SP byte-address scale, the `SYNC` immediate bitmask, the NC `burst` 5-bit/wrap, the
`out_*` data_type values, `IMMCOPY`'s `replica` broadcast, the VU src-class **dedup** rule.

Knowledge about **sequencing or combining** instructions into an algorithm (a streaming
reduction's accumulate-then-drain, the binary-op interleave, K-tiling, online rescale,
multi-NCore fork-join wiring) is composition, and it goes in the cheat-sheet or the op card,
**not** here. And anything that only affects *simulator timing* (the PrecSim beat
scheduler, the deadlock timeout, the packet counters) belongs to the bridge rather than the ISA; see
`program_lifecycle.md` Part B.

Test it: *"does this govern one instruction's effect/legal fields?"* → here; *"does it
only matter when I sequence instructions?"* → recipe layer.

## Sources of truth (do not invent state or ops)

| Layer | Source | What it gives |
|---|---|---|
| op inventory | `third_party/rebel_sim/.../lib/dnc_isa.py` (`opcode_dict`, `param_dict`, `bitpos_dict`) | every unit/opcode, its field list and bit-ranges |
| state `sigma` | `.../lib/prim_analyze/prim_run_state_v2.py` | inter-unit channels (FIFOs) + depths; register/mem state names |
| transition semantics | `.../lib/init_decode.py`, `.../prim_analyze/instr_pkt.py`, `prim_model*` | how fields map to indices / loops / targets / routing |
| mux tables | `.../prim_analyze/constr_tu.py` (and `constr_<unit>.py`) | source-select encodings (`north/west/lrf/reuse/zero` ...) |
| evidence | PrecSim `--log_decode --verbosity 4` per-DNC trace (`dncN.log`) | confirms each op's actual read/write routing |

## Method

1. **Skeleton** (`gen_skeleton.py`) auto-extracts the `(unit, op, fields)` inventory
   and the channel set into `ncore_spec_skeleton.md`. Re-run after a PrecSim bump.
2. **Collapse to families.** Ops sharing a `param_dict` signature share one
   transition shape (e.g. all TU `FMA*` datatype variants; `LDMU`/`LDSU`). The 20
   shared-control ops (`JADD/SYNC/NOP/...`) are written once and reused.
3. **Fill each family** by reading the transition semantics source, then
   **confirm against >=2 trace instances** (different field values, ideally a
   second kernel, since flash attention exercises ops the matmul never does). This
   de-confounding is mandatory: an instance is not the general rule.
4. **Compose (L2).** The per-op specs wire together through the channel set
   (`north/south/west`, `SP`/`AB`, `out_{nbr,sp,ab,vu,tu}`, `SYNC`) into the
   NCore-level dataflow, which is the execution model itself.

## Regenerate

```bash
uv run --project common/precsim python dnc_spec/isa_spec/gen_skeleton.py   # inventory
uv run --project common/precsim python dnc_spec/isa_spec/gen_coverage.py   # derived status
```

## Files

- `gen_skeleton.py` and `ncore_spec_skeleton.md`: the auto-extracted inventory (L0
  channels + L1 per-unit family stubs). Exposes `load_isa()` / `build_families()`
  so the coverage report groups against the same SSOT.
- `gen_coverage.py` and `coverage.md`: the derived completion status. It diffs the
  skeleton's 173 families against the inline `<!-- COV ... -->` tags in
  `families_control.md` / `families_data.md` and emits OPEN / partial /
  covered-but-weak / validated. A **second axis** rolls the `<!-- COVOP ... -->`
  tags in `families_operational.md` into the "Operational layer" section, graded
  by citation/validation tier (citation-clean > content-verified > review-residual),
  with a drift guard (tag count must equal `### operational(` section count). Never
  hand-edit `coverage.md`; tag where the work lives, then re-run.
- `families_control.md`: consolidated. The 20 shared-control ops are written once as 5 unit-agnostic
  families, plus C6 for the loop and sequencer control ops,
  `MVLOOPCNT`/`JCMP`).
- `families_data.md`: the matmul dataflow chain, complete. It holds the primary data family of
  each unit (D1–D9, + D6b TU write-mask) + the **Address model** (the load/store
  stride source) + the L2 composition diagram, all single-instance trace-confirmed
  (≥2-instance de-confounding still owed, step 3).
- `families_operational.md`: the operational layer. Per op family it gives
  dataflow-actor contract (FIFO ports, firing rule, backpressure, SYNC dependence,
  termination, Kahn class). Each block carries a `<!-- COVOP ... -->` tier tag
  surfaced in `coverage.md`.
- `program_lifecycle.md`: the whole-program arc, from format through load and execute to the spatial
  spread**: init-image layout, ibuff loading, the per-unit sequencer (PC 0 → `RETURN`),
  dataflow firing, and the NCore/DNC fork-join topology. Split into **Part A (ISA
  semantics)** and a hard-walled **Part B (PrecSim adoption / bridge)** so simulator
  artifacts (beat scheduler, packet counters, deadlock timeout, decode modify-pass) are
  never mistaken for ISA. Owns the spatial topology; `families_operational.md` stays
  per-op contracts.
- `authoring_cheatsheet.md`: a derived quick reference for hand-authoring, covering the streaming
  granularity, constants, the single-SPLU-FIFO interleave, SP addressing, SYNC bitmask).
  It introduces no new fact, every line pointing into the family files or the `dnckit` codec,
  the mechanical facts are encapsulated by `authoring.sp_addr` / `sync_imm` / `const_lrf` /
  `nc_burst_chunks` / `with_multi_tile`.
- `simulator_architecture_map.md`: how to navigate the PrecSim source, covering the two-pass
  PRE-EXEC/EXEC execution model (where address sweeps are generated vs where dataflow
  runs), a file→responsibility index, and the observability taps + trace. Read this before
  grepping the simulator when a kernel mis-behaves.
- `incremental_build_method.md`: the procedure for authoring a new op from scratch,
  the order that builds outward from the ends, the per-stage observables (two oracles, the arithmetic and
  mechanism), the controlled-input probe recipe (B=I / ones / one-hot for lane mapping),
  and the field-width/cadence gotchas. Extends `bottom_up_worked_example.md` with the
  that order and those observables.
- `optimization_loop.md`: the phase after correctness, which is how to drive a
  correct but slow kernel toward the hardware floor on your own. It covers the opportunity
  loop fed by the perf compass, and the five self-navigation rules (probe before you prove,
  measure before you name a bottleneck, build the simplest thing first, drive autonomously,
  never edit the gate). Read it when the kernel is green but slow.
- `tu_contraction.md`: the first op dataflow template, which is a category of doc beside the ISA
  reference and the method docs. It gives the one production TU systolic dataflow for matmul and conv.
  Section 1 covers weight-
  stationary dataflow (+ the A-on-north trap), §2 the load→skew→MAC schedule, §3 the operand
  layout as a demand plus a toolbox rather than a recipe, so the shaping is yours to derive, and section 5 the forced
  A-west/B-north port assignment. Distilled from production `GemmUtil`; validated by two
  from-scratch docs-only builds. Field codes live in `families_data §D6` / `isa_tables`; the
  plumbing gotchas (NC-wrap, RAW/WAR, ibuff/LRF widths) live in `incremental_build_method.md`.
  > **The principle these templates are authored under, a demand plus a toolbox:** withhold the
  > mechanism and let
  > the agent derive it), but **never withhold *why a step exists*.** If a step's motivation is
  > pruned (e.g. framing the M-batch as a "trivial reuse loop" instead of "the load/MAC-separation
  > step"), the agent never reaches for the toolbox to build it. Withhold mechanism, keep purpose.

## Status

**The status is derived rather than kept here.** Run `gen_coverage.py` and read
[`coverage.md`](coverage.md). It is computed by diffing the skeleton's 173
families against the inline `<!-- COV ... -->` tags, so it cannot drift from the
spec the way hand-counted prose does.

Two numbers, two different claims (see [`coverage.md`](coverage.md) for the live
split):

- Coverage means every family has at least a partial transition spec'd. This is a
  first-hand, mechanical check (the ledger): finishable now, and *honest* as long
  as it is not mistaken for validation.
- Validation means the spec rests on authoritative evidence, either the confirmed tier
  (`≥2` de-confounded trace instances) or `model-impl` (read straight from
  PrecSim's own execution code, the datapath in `src/isa/prec_sim_isa_arr.cpp` or
  the engine function in `sim_runtime.py`, over the whole input domain). Most of
  the spec is still **not** validated: it rests on a single matmul trace (`single`)
  plus decode-table inference (`source-read`), all listed under *"Covered but NOT
  validated"* in `coverage.md`. Completion-modulo-those is legitimate **only while
  they are named on the report**, which they are.

  Key reframing (it changes what the trace is *for*): every data op **is**
  implemented in PrecSim, so its reads and writes can be read directly from that code.
  `model-impl` is stronger than a single trace (whole domain vs one sample), and it
  needs no kernel run. The trace's unique job narrows to confirming the **decode
  binding**, meaning which channel or address entry the fields select in context, which lives
  in the decode layer, not the datapath) and **de-confounding**. First worked
  example is the cross-lane reduction of D10, read from `reduce_payload`, which desugars it
  into a D7/D3 op; filled `model-impl`, the first validated families.

Structural facts (ISA properties, not progress): **173 = 109 pure-control + 4
mixed + 60 pure-data**; the control side folds to **6 families** (C1–C6,
`families_control.md`); the matmul data chain is **D1–D9 + D6b**
(`families_data.md`).

What moves the needle, in order (per the systematic-completion plan):

1. **Read the engine implementation**, which is the strongest route and needs no trace. It is now
   demonstrated by D10 REDUCE. Most OPEN "other-kernel" ops (`MERGE`/`SHUFFLE`/
   `LDTRF`/`ZSFMA`/…) have a datapath/engine fn that *defines* their routing; read
   it and fill `model-impl`, validated-grade, over the whole domain.
2. **Fold the datatype variants**, tagged as variants where they share a parent shape,
   near-zero marginal work.
3. **Trace flash attention**, which is no longer the only way to fill the open ops. Its narrowed
   job is to confirm the **decode binding** (field → channel/`σ.ADDR` in context)
   and to **de-confound** the `single` families (`single` → `confirmed`).
4. **Source-read the field tables**: the two mode tables, the two address-register
   `CAR` role split + `isbr`, the `SETMASK`/`INCRMASK` mask `next()` step. The
   `source-read` residual; some may be unfalsifiable until a trace varies the mode
   field.
