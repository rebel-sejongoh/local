# NPU architecture fact-check

Fact-check of every concrete, falsifiable NPU-hardware/ISA claim asserted in
**(1)** the mapping textbook (`mapping-algorithms-onto-an-npu.md`) and
**(2)** the matmul generator's source annotations (`# FUNC`/`# LEAF` comments +
`arch_axioms.py`). The two claim sets are merged and deduplicated here (~71
distinct hardware claims).

**Sources.**
- The primary source is PrecSim, at `third_party/rebel_prec_sim`, submodule `a3a7ae6`. It is a hybrid
  Python (`rebel_hw_util/tools/lib/dnc_isa.py`, `.../prim_analyze/instr_pkt.py`,
  `prec_sim_process.py`) + C++ (`src/fp/fp.h`, `src/fpu/fpu.cpp`,
  `src/isa/prec_sim_isa.cpp`). PrecSim is a **bit-accurate compute simulator, not
  an RTL model**, so the chip topology, the FIFO depths and the cycle timing are frequently
  *not modeled*; absence there is recorded as UNSUPPORTED, never as a refutation.
- The secondary source is the conan primitives package,
  `~/.conan2/p/rebel540e6d53edd2e/s/include/src/develop/`. **Dual subtree**:
  `rebel/alpha/primitives/` and `atom/alpha/primitives/` carry the *same filenames
  with different content*. Conflicts between them are marked AMBIGUOUS; `atom/` is
  the active path. Line cites below are from `rebel/alpha/primitives/` unless noted.

**Verdicts.** `CONFIRMED` (a source states it as claimed) · `REFUTED` (a source
contradicts it) · `AMBIGUOUS` (sources disagree, or the claim is an interpretation
the source neither states nor denies, or the cite is mislocated) · `UNSUPPORTED`
(in neither source, so it needs an external hardware or ISA spec). The method is a direct source read.

---

## 1. Summary

| Verdict | Count |
|---|---:|
| CONFIRMED | ~49 |
| AMBIGUOUS / cite-issue | 6 |
| REFUTED (as stated / as scoped) | 1 |
| UNSUPPORTED (needs external HW spec) | 11 |
| **Total** | **~71** (+4 generator software-metrics ruled out of scope, see appendix B) |

### Actionable shortlist (the findings that matter)

1. **The consumer enum, where the seed sources conflicted, is resolved.** Two earlier reads
   disagreed (`2=SPSU,3=VU` vs `2=VU,3=SPSU`). PrecSim is decisive:
   `dnc_isa.py:2258-2266` → `0=self, 1=xvu, 2=spsu, 3=vu`. **`arch_axioms.py`
   `splu-ldu-route` is correct;** the alternate reading was wrong. (`st_producer`
   is a *different* field: `0=zeros,1=xvu,2=vu,3=splu`, `dnc_isa.py:2301-2309`.)

2. **`chunk-8row` axiom cite is mislocated (AMBIGUOUS).** `systolic-8x8`/`chunk-8row`
   cite `rebel_sp_dense_fp16_h1_bmb1.h:87,963`, but :87 is an `n_sync_Bi` parameter
   read and the other is the fold loop's count, and neither shows an 8-row boundary.
   The 8-row M-chunk (`ceil(rows/8)`) is a *large-M / M-split* construct in
   `dense_builder.py`, not visible on the 64³ path these lines belong to. The
   systolic-8x8 *fact* is sound (see #3); the cite for the 8-row M-chunk should be
   repointed at the M-split source. Affects C-D07, C-D10.

3. **"8×8 systolic" is grounded, not just inferred (CONFIRMED).** `…_h1_bmb1.h:21`
   states the pipeline `tu0 → … → tu7` (8 stages); `:1000` sets `unroll = 3`
   (comment: "Unrolling of 8"); `:1017` loops `if (j < 7) MVLOOPCNT((8-1-j)*(1<<unroll))`
   over the 8 stages. 8 stages × 8-way unroll = the 64 K-terms. The stage-7
   asymmetry (`j < 7`) is real, which substantiates the textbook's "stages 0–6 vs
   stage 7" claim, though the exact instruction counts are unverified,
   C-D08).

4. **`lane-parallel` axiom cites a design doc, not silicon (AMBIGUOUS).** Its cite is
   `PrimitiveAuthor/docs/matmul-template-design.md:245-246`. The fact (N is the
   64-wide lane axis, `Tout=64`) is independently CONFIRMED in conan
   (`rebel_sp_dense_fp16.h:120`), so repoint the cite there. C-D20.

5. **IMMCOPY `replica` is VU/XVU-only (REFUTED as stated for AB).** `dnc_isa.py`
   gives `replica` only to VU/XVU `IMMCOPY`; the AB/SP `IMMCOPY` (opcode `0x0C`) has
   no `replica` field. The textbook's "IMMCOPY with replica=1 broadcasts across
   lanes" (L556-559) is true only if scoped to VU/XVU. C-C09.

6. **LRF register count is AMBIGUOUS (16 vs 15).** Textbook/PrecSim-README say 16
   registers `[0..15]`; PrecSim init and the generator's `base_lrf` use 15-entry
   arrays, and some conan code indexes `0x1f`. Needs an HW-spec count. C-A08.

7. **The SHM size and granule need their level stated.** PrecSim's transfer line is 128 bytes
   (CONFIRMED) but its *SHM addressing granule* is 8 B (`MemLine8B`); these are
   different levels, not a contradiction. PrecSim's `SHM_SIZE` is a **sim config**
   (code 64 MB vs README 32 MB) and should not be read as a silicon constant. C-A12/13, C-A18.

8. **Chip-level topology is UNSUPPORTED by both sources** (neither a compute-sim nor
   the primitive emitters encode it): 4 chiplets, 16 DNCs/chiplet, 2 NCores/DNC,
   8 AB + 1 VU + 1 XVU per NCore, 2 clusters of 8. These need the external HW spec
   (appendix A). They are not wrong, merely unverifiable from these two sources.

---

## 2. Ledger

### 2.1 HW-unit counts · memory hierarchy · LRF / lanes / line-size

| id | claim | verdict | evidence |
|---|---|---|---|
| C-A01 | 4 chiplets per chip | UNSUPPORTED | topology not modeled in PrecSim; not in primitives. External HW spec needed. |
| C-A02 | chiplet 0 hosts 16 DNCs | UNSUPPORTED | as above. |
| C-A03 | each DNC = 2 NCores | UNSUPPORTED | as above. |
| C-A04 | each NCore carries 8 TU rows | UNSUPPORTED (count) | 8 TU *stages* are explicit (`…_h1_bmb1.h:21` `tu0..tu7`), but "8 TU rows per NCore" as a cardinality is not stated. |
| C-A05 | 1 VU per NCore | UNSUPPORTED | not encoded. |
| C-A06 | 1 XVU per NCore | UNSUPPORTED | not encoded. |
| C-A07 | 8 AB units per NCore | UNSUPPORTED | ABLU/ABSU modeled, cardinality not stated. |
| C-A08 | LRF = 16 regs, index `[0..15]`, on VU/XVU | **AMBIGUOUS** | PrecSim `README` describes 16 entries `[0..15]`; PrecSim init loops `range(15)`; generator `nclu_factors.py` `base_lrf=[0]*15`; conan indexes up to `0x1f`. 16-vs-15 unresolved → needs HW spec. |
| C-A09 | 16 DNCs = 2 clusters of 8 | UNSUPPORTED | clustering not in primitives/sim. (Cluster-split *behavior* exists in the generator, but the 2×8 topology constant isn't sourced here.) |
| C-A10 | SPMD over 16 DNCs | UNSUPPORTED | kernel-level model, above per-DNC sim scope. |
| C-A11 | 64-lane datapath per DNC | CONFIRMED (as `Tout/Tin=64`) | conan `rebel_sp_dense_fp16.h:119-120` `Tin=64; Tout=64`. The "64-lane" naming is the SIMD reading of the 64-wide tile. |
| C-A12 | 128 B lines stream through inter-unit FIFOs; FIFO entry = one 128 B line | CONFIRMED | PrecSim `prec_sim_process.py` byte-copies in 128 B units (`…[addr*128 : addr*128+128]`); README "8 entries × 16 B = 128 B". |
| C-A13 | one line is 128 bytes | CONFIRMED, at the transfer line | PrecSim uses a 128-byte transfer granule. Note that the SHM addressing granule is 8 bytes, which is a different level. |
| C-A14 | 128 B = 8 words × 16 B | CONFIRMED | PrecSim README LRF structure (8 slices × 16 B). |
| C-A15 | 128 B = 64 dlf16 values | CONFIRMED | 128 B / 2 B = 64; consistent with `Tin=64` FP16. |
| C-A16 | one line = one 64-lane SIMD register | CONFIRMED (interpretation) | PrecSim LRF entry = 8 slices × 8 lanes × 2 B = 128 B = 64 lanes. |
| C-A17 | one line laid out 8 slices × 8 lanes | CONFIRMED | PrecSim LRF literal `[[…8…] for _ in range(8)]`. |
| C-A18 | the total SHM size and the per-DNC scratchpad size | CONFIRMED, as simulator configuration and not as silicon | PrecSim sets 4 MB per DNC and 64 MB of SHM. Its README says 32 MB, which is stale or depends on the cluster count. Treat these as simulator configuration rather than silicon constants. |
| C-A19 | NC LDSU/STSU = verbatim 128 B byte-copy, no arithmetic | CONFIRMED | PrecSim `prec_sim_process.py:455,470,523,545` direct slice assignment, no transform. (`nc-ldsu-place`/`nc-stsu-place`, audit: decisive/convincing.) |
| C-A20 | SHM = cross-DNC shared region; SP = per-DNC scratchpad | CONFIRMED | PrecSim distinguishes `REBEL_SHM_PA_BASE` vs per-DNC `REBEL_SP_PA_BASE`; README "sp_arr … to allow DNC to write to another DNC's SP". |

### 2.2 Data formats · numeric / rounding behavior  *(all PrecSim-primary, strong)*

| id | claim | verdict | evidence |
|---|---|---|---|
| C-B01 | multiply operand = dlf16 (16-bit float) | CONFIRMED | `fp.h:259` `FloatType<uint16_t,uint16_t,6,9> DlFloat`. |
| C-B02 | accumulation = FP24 (24-bit) | CONFIRMED | `fp.h:285` `FloatType<uint32_t,uint32_t,6,17> DlFloat24`. |
| C-B03 | TU leaves results in FP24, no rounding in TU | CONFIRMED | `fpu.cpp:897` `vu_fmahp(...roundup_24b)`; TU `qfma` accumulates without final round. |
| C-B04 | VU rounds FP24→dlf16 exactly once; LRF target keeps 24b | CONFIRMED | `prec_sim_process.py:1668` `roundup_24b = is_lrf_tgt`. (`vu-fma-round`.) |
| C-B05 | dlf16(1.0) = 15872 (`0x3E00`) round constant | CONFIRMED | `prec_sim_process.py:2472` `"one_dl": 0x3E00 << 2`. |
| C-B06 | TU FMA unroll=8 latches 8 kernel k-values | CONFIRMED | `…_h1_bmb1.h:1000` `unroll = 3` ("Unrolling of 8"); `prec_sim_isa.cpp:22-23` qfma. |
| C-B07 | run_mode=2 = FP24 quad-MAC; 2 FMAs/trip, each = 4 FP24 products | CONFIRMED | `prec_sim_isa.cpp:18-21` gates `x2,x3,y2,y3` by `run_mode>1`; conan `…_h1_bmb1.h:1029` `.run_mode(2)`. |
| C-B08 | [4,64] block of FP24 partial sums sits unrounded in psum | CONFIRMED | `prec_sim_process.py:1630-1635` VU psum path. |
| C-B09 | dlf16 = 6-bit exponent, 9-bit mantissa | CONFIRMED | `fp.h:259` template `<…,6,9>` (1+6+9 = 16). |
| C-B10 | FP24 = 6-bit exponent, 17-bit mantissa | CONFIRMED | `fp.h:285` template `<…,6,17>` (1+6+17 = 24). |
| C-B11 | XVU LOGICAL = pure bit-level LUT remap, index-preserving, no round/rescale | CONFIRMED | `fpu.cpp` `ilut()` index map `*(in_z+lut_idx)`. (`xvu-logical-lut`, audit: decisive.) |
| C-B12 | run_mode selects FP24(2) vs other; qfma pairs 4→2 by `run_mode<3` | CONFIRMED | `fpu.cpp:509-540` `add_pair(..., run_mode<3)`. |

### 2.3 ISA opcodes · routing fields · sync / loop / branch · DMA

| id | claim | verdict | evidence |
|---|---|---|---|
| C-C01 | the consumer routing enum | CONFIRMED as `0=self,1=xvu,2=spsu,3=vu` | an explicit chain at `dnc_isa.py:2258-2266`. It resolves the seed conflict in favour of the axiom source. |
| C-C02 | `st_producer` enum `0=zeros,1=xvu,2=vu,3=splu` | CONFIRMED | `dnc_isa.py:2301-2309`; bitpos `[30,29]`. |
| C-C03 | SPSU STU size = burst_sz else 64; stores rows verbatim | CONFIRMED | `prec_sim_process.py:1261` `store_data=raw_data`; `instr_pkt.py:512` `size = burst_sz if burst_sz else 64`. |
| C-C04 | SPLU LDU size = burst_sz else 64; non-burst 1; interleave scales | CONFIRMED | `instr_pkt.py:449-459`; `dnc_isa.py:2276-2284` interleave enum. |
| C-C05 | SP LDU transfers burst_sz *consecutive* M-band rows | CONFIRMED (conan) | conan `rebel_sp_dense_fp16.h:415` `.burst(...)`. PrecSim tracks size, not row-contiguity → contiguity is a conan-level property. |
| C-C06 | MVLOOPCNT = static immediate OR dynamic JCR-driven; body closed `be=1` | CONFIRMED | `dnc_isa.py` `dynloop` field (`bitpos [26,26]`) in MVLOOPCNT param set. |
| C-C07 | JCMP = loop-control branch (not data-dependent), PC targets | CONFIRMED | `dnc_isa.py` JCMP params `cmp_typ,pc_tgt,isjcmpi`; no payload read. |
| C-C08 | MODLRFIMM modifies a CAR address register by an immediate | CONFIRMED | `dnc_isa.py:31` opcode `0x08`; params `src0,typ1a_imm,be`; conan usage `rebel_sp_dense_fp16.h:412`. |
| C-C09 | IMMCOPY replica=1 broadcasts across lanes | **REFUTED as stated / CONFIRMED for VU·XVU** | `replica` field exists only on VU/XVU IMMCOPY; AB/SP IMMCOPY (`0x0C`) has no `replica`. **Reflected:** textbook L556-560 now scopes the `replica=1` broadcast to the VU/XVU and notes AB/SP `0x0C` lacks the field. |
| C-C10 | program ends RETURN + IBuffFinish tail (fixed padding, unit-agnostic) | CONFIRMED | conan `rebel_sp_dense_fp16.h:1118-1119` `RETURN(); IBuffFinish(...)`. (`ibuff-finish`, audit: decisive.) |
| C-C11 | init.bin = 128-bit flits, column-major (per-unit columns) | CONFIRMED | PrecSim `walk_flits` column-major; `INIT_PCKT_WIDTH=128`. |
| C-C12 | NC/SP/AB/TU pack 4 instr × 32 bits / flit | CONFIRMED | PrecSim `dnc_init.py` `INSTR_NUM_PER_IBUFF=4`, `INSTR_WIDTH=32` (4×32 = 128). |
| C-C13 | VU/XVU pack 2 instr × 64 bits / flit | CONFIRMED | PrecSim VU/XVU 64-bit instruction width (dual-issue vs 4-issue). |
| C-C14 | MESYNC = cluster-tree barrier for K-axis reduction | CONFIRMED | `dnc_isa.py:220` MESYNC `0x0A` (NC); `instr_pkt.py:461-497` mask-based multi-target barrier. |
| C-C15 | SENDTRF sends a transfer-group (sub-Tr spill) | CONFIRMED | `dnc_isa.py:399` SENDTRF `0x2F` (SPLU); generator `splu_factors.py:486,551`. |
| C-C16 | ABLU = value-preserving fan-out; ABSU = verbatim store byte-copy; rows = burst_sz | CONFIRMED | PrecSim `prec_sim_process.py:1261-1271` `store_data=raw_data`. (`ab-ldstu`.) |
| C-C17 | slice_en=0xff enables all 8 slices (= 64 lanes); per-slice write mask | CONFIRMED | `prec_sim_process.py:1690` slice mask over `range(0,64,8)`; default `0xFF`. (`slice-en-all-lanes`.) |
| C-C18 | DMA brackets the program, staging the operands before and the result after | UNSUPPORTED, being outside the ISA's scope | PrecSim does not model it and the primitives assume memory is pre-loaded, DMA belonging to the driver and the runtime. This matches the staging claim being weakly grounded. |

### 2.4 Systolic / pipeline · tiling · hardwired constants  *(conan-primary; corrected after direct read)*

| id | claim | verdict | evidence |
|---|---|---|---|
| C-D01 | systolic array = 8×8 = 64 cells | CONFIRMED (grounded) | `…_h1_bmb1.h:21` `tu0..tu7` (8 stages) + `:1000` `unroll=3` ("Unrolling of 8") + `:1017` `j`-loop. 8 stages × 8 k/stage = 64. |
| C-D02 | fixed 64-lane SIMD width | CONFIRMED | conan `rebel_sp_dense_fp16.h:119-120` `Tin=64; Tout=64`. |
| C-D03 | fixed 8-deep systolic pipeline (8 stages) | CONFIRMED | `…_h1_bmb1.h:21` explicit `tu0 → … → tu7`. |
| C-D04 | 8 stages × 64 lanes; each stage holds 8 of 64 k (8×8) | CONFIRMED | as C-D01/D02; the `j`-loop puts 8 k-values per stage. |
| C-D05 | K=64 fills the 8-stage pipeline in one pass (64³) | CONFIRMED | 8 stages × 8 = 64; `psum` holds one K=64 contraction. |
| C-D06 | kernel C split into 8 stage-slices [8k×64n], one pinned per stage (weight-stationary) | CONFIRMED | `…_h1_bmb1.h:21` `Kernel: …→tu0..tu7` (kernel flows into the 8 TU stages = weight-stationary). *(Batch agent's REFUTED overturned by direct read.)* |
| C-D07 | input B arrives from west as M-chunks ≤ 8 rows | AMBIGUOUS | the "8-row" boundary is not at the cited 64³ lines; on the 64³ path M/DNC = 4 rows (Tr=4). The ≤8-row chunk is a large-M / M-split construct. Repoint to the M-split source. |
| C-D08 | the 8 TU stage-programs sum to 124 instr (0-6 ≈ 16 ea, 7 = 12) | CONFIRMED (structure) / AMBIGUOUS (counts) | stage-7 asymmetry confirmed by `…_h1_bmb1.h:1017` `if (j < 7)`; exact counts 124/16/12 not line-verified. |
| C-D09 | TU emits one program per stage (8 programs) | CONFIRMED | `j`-loop over 8 stages (`…_h1_bmb1.h:1017`); pipeline `tu0..tu7`. *(REFUTED overturned.)* |
| C-D10 | M-row chunk boundary = 8; outer trip ceil(rows/8) | AMBIGUOUS | `chunk-8row` cites `…_h1_bmb1.h:87,963` but :87 = `n_sync_Bi` read, :963 = Bin-loop. The ceil(rows/8) chunk lives in `dense_builder.py` (M-split), not at this 64³ cite. Cite mislocated. |
| C-D11 | Tr = 4 transfer-row group | CONFIRMED | conan `rebel_sp_dense_fp16.h:121` `int Tr = 4;`. |
| C-D12 | tile = 64 columns wide (Tout=64); Cout partitions n_cout = Bout/Tout | CONFIRMED | conan `rebel_sp_dense_fp16.h:120` `Tout=64`; `MVLOOPCNT(Bout_loopcnt/Tout)`. (`c-shuttle-cout-cover`.) |
| C-D13 | Tin = 64 (input tile width) | CONFIRMED | conan `rebel_sp_dense_fp16.h:119` `Tin=64`. |
| C-D14 | 32-row spatial chunk: Br_div_32 = ceil(Br_loopcnt/32)-1 | CONFIRMED | conan `rebel_sp_dense_eager.h:133`. (`sp-spatial-chunk-32`.) |
| C-D15 | Br_odd = (Br%2 && Br!=Br_loopcnt); gates partial-pointer rewind | CONFIRMED | conan `rebel_sp_dense_fp16.h:100` + usage :158,:815. (`br-odd-overcount`, `partial-ptr-rewind`.) |
| C-D16 | psum_depth = per-DNC table controlling partial-sum depth | CONFIRMED | conan `rebel_sp_dense_fp16.h` dissect of `psum_depth`. |
| C-D17 | K-reduction = binary psum tree, depth log2(Cin); cin_depth ∈ {0..3} | CONFIRMED | `max_psum_depth = log2(loop_iter_out.back())`, loop_dnc ∈ {1,2,4,8} → {0..3}. |
| C-D18 | 64³ matmul = 262,144 MACs | CONFIRMED | 64³ = 262,144 (arithmetic; dump-validated). |
| C-D19 | 64³: M=64 split 16 ways = 4 rows/DNC; 16 parallel tiles | CONFIRMED | tiling `Nmb=8 × cluster 2 = 16`, 4 rows each. |
| C-D20 | lane-parallel: N free (lanes), no N loop; K=64 fills 8 rows | AMBIGUOUS (cite) | the *fact* is CONFIRMED via `Tout=64` (C-D02/D12); but `lane-parallel` cites a **design doc** (`matmul-template-design.md:245-246`), not silicon. Repoint the cite. |
| C-D21 | ABSU/ABLU loop 32-row chunks + remainder, Tr=4 | CONFIRMED | conan `rebel_sp_dense_eager.h:135` `ceil(Br_loopcnt/Tr)`; `ab-spatial-chunk`. |

---

## Appendix A: claims neither source supports, which need an external hardware or ISA spec

These claims are **not contradicted** by either source; they simply lie outside
what a bit-accurate compute-sim and the primitive emitters encode. They require the
silicon HW spec / ISA manual to settle:

- Chip topology: **4 chiplets** (C-A01); **16 DNCs per chiplet** (C-A02);
  **2 NCores per DNC** (C-A03); **8 TU rows / 1 VU / 1 XVU / 8 AB units per NCore**
  (C-A04–A07); **2 clusters of 8 DNCs** (C-A09).
- Execution model: **SPMD over 16 DNCs** (C-A10).
- The DMA bracketing of the program, from C-C18, which belongs to the driver and the runtime rather than the ISA.

## Appendix B: out of scope, being software and generator metrics rather than hardware

Collected from the textbook but ruled non-hardware; verify via `verify_dense.py` /
`health.py`, not against silicon source:

- "195 distinct block-bodies", "93 distinct opcode-sequences", "~9 unit emitters",
  the count of byte-verified points. These describe the generator
  and its coverage, not the NPU.
- Which shapes the dense primitive accepts, and the byte-verified counts per family.

## Appendix C: a cross-check against the existing audit

For the ~23 axiom-backed claims, this independent direct read **agrees** with the
audit's `axiom-adequacy@v1` verdicts, with these notes:
- Audit's 8 "undersupported" axioms (`tr-group-drain`, `ab-spatial-chunk`,
  `dma-stage`, `sp-spatial-chunk-32`, `partial-ptr-rewind`, `vu-fma-round`,
  `splu-dynloop-cover`, `ab-ldstu`) all have a *located* source here and verify
  confirmed at the level of the fact, so what they lack is a tight citation rather than a
  wrong fact. (`dma-stage` is the exception: genuinely outside ISA scope, C-C18.)
- Two cites should be **repointed** (findings #2, #4): `chunk-8row` → the M-split
  source in `dense_builder.py`; `lane-parallel` → `rebel_sp_dense_fp16.h:120`.
- `ld_consumer` ordering is confirmed exactly as `arch_axioms` states it (#1).
