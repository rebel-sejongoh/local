# Shared-control op families (consolidated)

The 20 control ops recur across units with **identical field signatures** (only
the opcode byte differs; TU spells `src0` as `jcr_src0`, same role).

> Operational/concurrency contracts for SYNC/MESYNC + the NC JCR control ops
> the three JCR ops, which are not Kahn-deterministic, are in the companion
> [`families_operational.md`](families_operational.md). They touch
only registers and sync tokens, never the data channels. So they
consolidate to **5 unit-agnostic families**, written once here.

Collapse: of the skeleton's 173 raw `(unit, signature)` families, **109 are
pure-control** and fold into the 5 below; **4 are mixed** (a control op sharing a
signature with a non-control op, which is the three register ops on the SP units and the TU's own
trio); and 60 are pure data and remain to fill.
Those add to the 173, recomputed against the live ISA table.
The two non-control ops hiding in the mixed families are
specified below (C3) and in `families_data.md` (D6b) respectively.

## σ additions (control state)

```
σ.JCR[unit][0..n]  : the per-unit jump-control registers, small integers for loop counters
                     and address-index arithmetic. Every unit has a bank.
σ.SAR[*], σ.CAR[*]  : NC-unit address registers (store/source addr; count/coord addr).
                      Feed LDMU/LDSU/STSU address generation. `isbr` = broadcast flag.
σ.LRF_c[unit][r]    : AB/SP-family unit's const/scalar register bank (distinct from the
                      compute units' tile LRF).
σ.SYNC[token]       : barrier tokens (already in σ; see channel set).
```

`be` (bit 31) is the per-op enable/predicate on every family below; omitted from
the bodies for brevity (op is a no-op when disabled).

---

## C1, the JCR register ops
<!-- COV id=C1 targets=*.JADD,*.JSUB,*.JSWAP,*.GETJCR status=single evidence=matmul-trace -->
<!-- COV id=C1 targets=*.JARITH,*.JSHR,*.JIMMCOPY status=source-read note=jarsw/jimmy-mode-tables-open -->
**Units:** all 12. **State:** reads/writes `σ.JCR[unit]` (+ immediate).
The per-unit integer ALU used to compute loop bounds and memory-address indices.
```
JADD (src0, typ1_imm, jcr_sel, jcr_tgt):  JCR[jcr_tgt] := JCR[src0] + typ1_imm
JSUB (src0, typ1_imm, jcr_sel, jcr_tgt):  JCR[jcr_tgt] := JCR[src0] − typ1_imm
JARITH(src0, src1, jarsw_mode, jcr_tgt):  JCR[jcr_tgt] := JCR[src0] ∘ JCR[src1]   (∘ per jarsw_mode/submode)
JSHR (src0, shamt, tr_left, tr_right, jimmy_mode, jcr_tgt):
                                          JCR[jcr_tgt] := truncate(JCR[src0] ≫ shamt, [tr_left:tr_right])
JIMMCOPY(src0, typ1_imm, jimmy_mode, jcr_tgt): JCR[jcr_tgt] := compose(typ1_imm, JCR[src0])   (per jimmy_mode)
JSWAP(src0, src1, jarsw_mode):            JCR[src0], JCR[src1] := JCR[src1], JCR[src0]
GETJCR(src0):                             expose JCR[src0] to the unit's address/use path   (read-only)
```
Open: the exact `∘` table for `jarsw_mode/submode` and the `jimmy_mode` compose
rule (mode-indexed; ground from the model when a data family needs it).

## C2, the sync and barrier ops
<!-- COV id=C2 targets=*.SYNC,*.MESYNC,*.SESYNC status=single evidence=matmul-trace -->
**Units:** `SYNC` ∈ {AB,ABLU,ABSU,SP,SPLU,SPSU,NC,NCLU,NCSU}; `MESYNC`,`SESYNC` ∈ {NC,NCLU,NCSU}.
**State:** reads/writes `σ.SYNC`. No data movement.
```
SYNC   imm (NC: typ1ac_imm; SP: typ1_imm):   a bitmask rather than a token id:
         bit0 = SEND (put leg)        bit2 = peer NCLU     bit5 = peer SPSU0
         bit1 = RECV (get leg)        bit3 = peer NCSU     bit6 = peer SPLU1
         (both bits set = bidirectional) bit4 = peer SPLU0  bit7 = peer SPSU1
MESYNC (typ1ad_imm):            multi-engine (cross-DNC) barrier; per-DNC peer bits
SESYNC (typ1ad_imm):            one peer, addressed by chiplet, DNC and unit; not a mask:
         bit0 = SEND (put leg)        bit5:2 = target DNC index
         bit1 = RECV (get leg)        bit7:6 = target unit: nclu, ncsu, rbdma
                                      bit9:8 = target chiplet id
```
Each set peer bit selects a counting channel,
which is named by its producing unit and then its consuming unit.
A put (`SEND`) increments `{self}_{peer}_sync`,
and a get (`RECV`) waits until `{peer}_{self}_sync` is non-zero and then decrements it.
E.g. an NCLU `SYNC` with `bit0|bit4 = 0x11` puts on `nclu_splu0_sync`; the
SPLU's own sync gets on it, which is the load-done edge.

**A consumer must take its gets on one channel in the order of the edges' puts.**
The channel holds an integer count,
so it pairs the k-th get with the k-th put, whichever edge each one was meant for.
If the consumer takes its gets in a different edge order from the producer's puts,
a get can proceed before the put it was meant for.
PrecSim does not report an error,
and the consumer can use a buffer that the producer has not finished with.
Sharing a channel causes a deadlock only when the channel is full and a put stalls,
as one edge with too many outstanding puts does.
Author the immediate with
`dnckit.authoring.sync_imm(send=, recv=, peers=[...])` rather than hand-packing bits.

<!-- provenance: model-impl, the pairing of gets with puts on one channel. The put stall on a
full channel, the get's non-zero wait and decrement, and the integer count are the fire-rule and
reg/sp-write bullets of families_operational.md's SYNC/MESYNC contract. Status stays `single` on
the C2 op rollup; this sub-fact is model-impl-read and is not trace-confirmed. -->

The operational layer states no contract for `SESYNC`; `families_operational.md`'s
`zero-port` block says why, in its `SESYNC` bullet.

<!-- provenance: model-impl, the SESYNC immediate. The layout is from PrecSim's own decoder,
init_decode.py:1242-1266, whose bit_acc reads are immediate-relative; typ1ad_imm is
instruction bits [30,10] (dnc_isa.py:260). It agrees with the official ISA doc's
registration, which gives the same chiplet_id at instruction bits 19:18
(spec_source_inventory/dnc_isa_docs/src/data.py:568). The decoder's own assert states the
target index space: "0~15: nclu of each dnc, 16~31: ncsu of each dnc, 32: rbdma".
Caution for authors: rebel_compute_lib2's encoder disagrees, writing a 1-bit nclu/ncsu
target at instruction bit 12 and its 6-bit `_imm` argument at 18:13, with no separate chiplet
argument, so `_imm` bit 5 lands on the decoder's chiplet bit 0
(spec_source_inventory/rebel_compute_lib2/include/common/src/rebel_nc_isa.cc:428-441). -->

<!-- provenance: model-impl, the SYNC immediate. Bit positions SYNC_MASK_SEND=0, RECV=1, NCLU=2, NCSU=3,
SPLU0=4, SPSU0=5, SPLU1=6, SPSU1=7 in dnc_isa.py:1897-1906; channel-name + put/get
construction in prim_analyze/instr_pkt_v2.py:300-336 (NC, typ1ac_imm), :518-593 (SP,
typ1_imm). Status stays `single` on the C2 op rollup (full transition is matmul-trace);
this is the immediate-encoding sub-fact, model-impl-read. -->

## C3, the constant and scalar register ops
<!-- COV id=C3 targets=*.IMMCOPY,*.LRFREGCOPY status=single evidence=matmul-trace -->
<!-- COV id=C3 targets=*.MODLRFIMM,*.SUBLRFIMM,*.MODLRFREG status=source-read note=modify-f-op-open -->
**Units:** the AB and SP families. The copy-from-immediate also appears on the VU and XVU, in a richer form.
**State:** reads/writes `σ.LRF_c[unit]`.
```
IMMCOPY (src0, typ1a_imm):       LRF_c[src0] := typ1a_imm
   VU/XVU form (typ1_imm, replica, lrf_tgt, slice_en, mode):
                                 broadcast typ1_imm into LRF[lrf_tgt] across slice_en slices
   # CONSTRAINT (per-instruction): replica=1 writes the immediate to ALL 8 lanes of each
   #   enabled slice; replica=0 writes lane 0 ONLY (other lanes keep their prior/garbage
   #   value). A constant later read per-lane (e.g. an FMA src) MUST use replica=1, else
   #   lanes 1..7 read garbage. Encoder: authoring.const_lrf sets replica=1.
MODLRFIMM (src0, typ1a_imm):     LRF_c[src0] := f(LRF_c[src0], typ1a_imm)
SUBLRFIMM (src0, typ1a_imm):     LRF_c[src0] := LRF_c[src0] − typ1a_imm   (the subtract form of MODLRFIMM)
MODLRFREG (src0, src1):          LRF_c[src0] := f(LRF_c[src0], LRF_c[src1])
LRFREGCOPY(src0, src1):          LRF_c[src0] := LRF_c[src1]
```
Open: the `f` (modify) operation; the VU/XVU `IMMCOPY` is arguably a compute-unit
family, which broadcasts across a slice; cross-link it when filling in the VU and XVU.

Note: `SUBLRFIMM=0x0D` (SP/SPLU/SPSU) is semantically a const-reg op like the rest
of C3, but it is **not** in `gen_skeleton.py::CTRL`, so the generator currently
tags its `MODLRFIMM/SUBLRFIMM/IMMCOPY` signature as one of the 4 *mixed* families.
Adding it to `CTRL` (a one-line change, then re-run) would reclassify those 3
families pure-control (→ `112 + 1 + 60`). Left as-is until the generator is bumped,
so the reported `109/4/60` matches the live tool.

## C4, the NC address-register ops
<!-- COV id=C4 targets=*.SXRIMM,*.ADDSXRIMM,*.SUBSXRIMM,*.CXRIMM,*.ADDCXRIMM,*.SUBCXRIMM status=single evidence=m128n768-dump -->
<!-- COV id=C4 targets=*.SARREGCOPY,*.MODSARREG,*.CARREGCOPY,*.MODCARREG status=source-read note=sar-vs-car-role+modify-f-RESOLVED -->
**Units:** {NC,NCLU,NCSU}. **State:** reads/writes `σ.SAR` / `σ.CAR`.
```
SARREGCOPY(src0, src1, isbr):  SAR[src0] := SAR[src1]
MODSARREG (src0, src1, isbr):  SAR[src0] := SAR[src0] + SAR[src1]   # f = ADD
CARREGCOPY(src0, src1, isbr):  CAR[src0] := CAR[src1]
MODCARREG (src0, src1, isbr):  CAR[src0] := CAR[src0] + CAR[src1]   # f = ADD
```
**RESOLVED** (source-read `init_decode.py` NC load/store address formation, confirmed
by the store-address tap in `cerun.precsim_taps`):

- **`SAR` = the SP-side (scratchpad) address register; `CAR` = the external/SHM address
  register.** A store forms `SP_addr = SAR[src0] + SBR[src1] + i·stride_sp` and
  `EXT_addr = CAR[src2] + CBR[src3] + i·stride_ex`, then moves `SP[SAR] → SHM[CAR]`
  (`STM/STS/STSU`); a load is the reverse `SHM[CAR] → SP[SAR]` (`LDM/LDS/...`). So **SAR/CAR
  is the source and destination split rather than an inner and outer one**, the store being a copy with one
  address register per side.
- **`SBR`/`CBR`** are the `isbr=1` sibling registers (set/added by the same ops with `isbr`
  set); for the stride forms (`LDS/STS`) they carry the **per-element stride** (`stride_sp =
  SBR[src1]`, `stride_ex = CBR[src3]`), and they also serve as the per-side base offset.
- **The `f` modify op = ADDITION**: `MOD{S,C}ARREG` do `reg[src0] += reg[src1]`; `ADD{S,C}XRIMM`
  add an immediate; `{S,C}XRIMM` set from an immediate; `*REGCOPY` copy.

`isbr` selects the broadcast (`SBR`/`CBR`) bank / broadcasts the update across the NC array.
The output **lane/line orientation** lives in the `CAR` (SHM-dest) sweep specifically; the
`store_addr` tap observes the real `CAR`-derived SHM-WR addresses (it confirmed the NCSU store
count scales with M, at 4 addresses on the atom shape against 8 at M=128, which is consistent with M as the iterated
dimension), though the full per-element sweep is bounded by the offline arg_parser's check.

**Also in C4 (omitted from the initial enumeration):** the **immediate-arithmetic**
forms of the same family, which are the actual address-stride ops in NCLU/NCSU
(decode-confirmed against the m128n768 dump): `CXRIMM`/`SXRIMM` (set CAR/SAR from
an immediate) and `ADDCXRIMM`/`ADDSXRIMM` (add an immediate to CAR/SAR). These
write `σ.CAR`/`σ.SAR` exactly like the `*REGCOPY`/`MOD*REG` forms.

## C5, the flow ops
<!-- COV id=C5 targets=*.NOP,*.RETURN status=single evidence=matmul-trace -->
**Units:** all 12. **State:** none / sequencer.
```
NOP:     identity transition (σ unchanged)
RETURN:  halt this unit's ibuff sequencer (end of program)
```

## C6, the loop and sequencer control ops
<!-- COV id=C6 targets=*.MVLOOPCNT status=single evidence=matmul-decode -->
<!-- COV id=C6 targets=*.JCMP status=source-read note=data-branch-not-exercised-by-matmul -->
**Units:** all 12. **State:** reads/writes `σ.LOOP[unit]` (the per-unit ibuff loop
stack) and the program counter. Neither touches a data channel, both being in
`instr_pkt_v2.ignored_opcodes` (zero FIFO movement), the model treats them as pure
sequencer control.
```
MVLOOPCNT (typ1_imm, src0, dynloop, cont, brk, force_jump):
    cnt := dynloop ? σ.JCR[src0] : typ1_imm        # immediate, or dynamic count from a JCR
    push σ.LOOP[unit] := (count = cnt, body = PC+1) # the FOLLOWING body iterates `cnt` times;
                                                    #   cont/brk compose nested loops; force_jump = uncond.
JCMP (src0, src1, cmp_imm, cmp_typ, pc_tgt, isjcmpi):   # the data-dependent sibling
    if compare(σ.JCR[src0], isjcmpi ? cmp_imm : σ.JCR[src1], cmp_typ):  σ.PC[unit] := pc_tgt
```
A loop **nest** is just stacked `MVLOOPCNT`s read in order: each sets the trip count
of the body that follows it. This is **the** place the tiling enters the program as
numbers. The TU's five, from D6 of the data families, are `3 leading = (total_iter, Cout/Tout,
OUTPUT-PASS count)`, `skew = (8−1−col)·8`, `inner = ceil(rows_per_ncore/Tr)`. Trip
count × the per-iteration address step (C3/C4) = the swept operand region (see the
Address model in `families_data.md`).

**The third leading slot is the output-pass count rather than the contraction count**, as the
provenance below records.
It carries the product of the two output-tile counts: the number of output tiles the unit
sweeps, fusing the Cout and M-tile axes when both fold. The **contraction axis is not in
the TU nest at all**. A split contraction is expressed in the reduce and sync path, through cross-DNC
legs and the in-DNC bin staging), not as a TU loop level. An earlier reading of this slot
as `Cin/Tin` came from a single matmul decode on a shape where the two counts coincide.
<!-- provenance: DE-CONFOUNDED by synthesis measurement over the mcc byte corpus
(138 configs, matmul+conv+softmax; PrimitiveAuthor/mcc/LOOP_NEST.md §E). 1792 TU
instances have BOTH a contraction count >1 and cout·mt >1; on 1024 of them the two DIFFER
(slot=2 while the contraction count is 4 or 8), and the slot tracks cout_pass·mt_x on all
1792. Those images are PrecSim-green, and a slot carrying the contraction axis at 2 where
the contraction is 4 would under-accumulate and break the numerics, so the slot cannot be
Cin/Tin. This satisfies the `confirmed` bar (>=2 de-confounded instances) for the SLOT
ASSIGNMENT specifically; the MVLOOPCNT transition itself is untouched by this evidence and
keeps its own status. Corroborated by the emitters' own axis inventory, which already
placed Bin/Tin in the reduce/sync path (mcc `nodes._Frame`). -->

**A dynamic loop bound is a register-computed constant rather than a data-dependent count, and it is
set locally, in the same block.**
In that mode the count is read from a runtime register, but that register is loaded by the block's own
JCR arithmetic, whose inputs are immediates, and every
JCR op "touches only registers, never the data channels" (§header). So the loop bound is **independent
of the tensor DATA**: it is a compile-time constant expressed through the JCR integer ALU rather than
baked into `typ1_imm`. Concretely, the matmul SPLU's steady-state `MVLOOPCNT(dynloop=1, src0=1)` reads
that same register, which the same block set from immediates, so the immediate field on the
dynloop is ignored, and the real count is JCR-computed locally. Consequence for tooling: the count is
**statically determinable in principle** (trace the JCR arithmetic), but NOT by a naive scan of
`MVLOOPCNT` immediates, and fully recovering it needs the `jimmy_mode` compose rule (C1, marked *open*)
from the model. <!-- provenance: source-read families_control C6/C1 + matmul SPLU decode
(dnc_realize.py software-pipelined skeleton; JIMMCOPY jcr_tgt=1 at the prologue feeds the dynloop). The
skeleton itself is a structure-invariant template TRANSCRIBED from the rebel_compiler matmul dump
("verified against the dump, all 16 DNCs") = template(structure) + addresses(memmap); its
JCR/dynloop internals were matched rather than re-derived, which is why the ISA-derived type-check treats it
as an arity-1 pass-through rather than counting it. -->


**The branch-end field, which is the loop's back edge.** Every instruction carries a
per-instruction `be` bit (`bitpos_dict[unit]["be"]`, preserved across init-modify at
`init_decode.py:683`). It marks the instruction that *closes* an `MVLOOPCNT` body: the
**last** instruction of a loop body sets `be=1` (the back-edge to the loop head), every
earlier body instruction `be=0`. A `RETURN` runs with the loop stack empty (after the
loop has retired), so the encoder pads the block tail with `RETURN`s (`pad_return`). A
mis-placed `be` (set on a non-final body instr, or omitted on the last) is caught by the
init-decode branch checker. <!-- provenance: be field name "Branch-End" + preservation
at init_decode.py:683; loop-body placement observed across add-synth agents, runtime
back-edge handler not yet line-cited, so full validation is owed. -->

**Loop balance must be reasoned on the EXECUTED (jump-inclusive) path, not the static listing.**
With `JCMP` (absolute `pc_tgt`), the run-time push/pop sequence of `σ.LOOP` differs from the
straight-line order of `MVLOOPCNT`/`be` instructions: a jump can skip an `MVLOOPCNT` (open) or a
`be` (close), so a block whose *static* opens==closes can still **underflow** the loop stack at
run time (`init_decode.end_loop`: `BE=1 when Current Loop Iterator is already zero`, process exit
10). A static balance scan is therefore necessary but NOT sufficient. Corollary: an outer
`MVLOOPCNT` wrapped around a JCMP-containing skeleton whose jumps assume a fixed depth breaks this
invariant. <!-- provenance: observed directly. Wrapping the SPLU
staging skeleton (pc_tgt=26/35/38) in an outer MVLOOPCNT(cb) → exit-10 `[CHECKER][SPLU0][49]
BE=1 when Current Loop Iterator is already zero`, while the static open/close depth was 0. -->

**A burst-mode feed bounded by a loop count needs its burst size set explicitly**, as D2 of
`families_data.md` resolves.
The burst field is a mode flag rather than a count: clear it for one line per beat, set it for as many
lines per beat as the size field says,
with `burst_sz` **defaulting to 64** when unset (`instr_pkt_v2.py:545-551`). So a burst-mode LDU inside
a loop of K trips with no size set feeds 64 times K lines rather than K,
which is the runaway that fed about 8466 lines where 64 were wanted, and setting the size to 1 fixes it.
The full rule is in D2, and it is noted here because it interacts with the loop bound above.

Note: like the C4 address-immediates and `SUBLRFIMM`, `MVLOOPCNT`/`JCMP` are
sequencer-control (no data) but are **not** in `gen_skeleton.py::CTRL`, so the
generator counts them among the 60 data families, which is the same one-line gap in that table.
The reported split is left as the live tool's answer.

---

**Result:** the 20 control ops fold to 5 families, C1 through C5, and the two loop and sequencer ops
add C6, for 6 control families in all. Combined with the
**60 pure-data** families (plus the non-control ops riding the 4 mixed families,
`SUBLRFIMM`/`INCRMASK`), the full NCore op set is **~67 distinct transition shapes**,
not 343 opcodes.
