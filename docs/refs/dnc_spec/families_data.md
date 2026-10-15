# Data op families (matmul dataflow chain)

The primary data family of each unit, in execution order around the NCore loop.
Fields from `dnc_isa`; routing (reads/writes) **trace-confirmed** from the
`dnc0.log` `--verbosity 4` per-DNC log (the `SRC -> unit -> DST` lines).
Datatype variants (TU `IMA*/F8*/ZS*`, VU `FMABF`, …) share each shape below and
are not re-specified.

> This file is **denotational** (state + per-op effect). The **operational /
> concurrency layer** (FIFO ports, streaming extent, firing/backpressure, SYNC
> dependence, termination, Kahn class) lives in the companion
> [`families_operational.md`](families_operational.md).

## σ additions (data state)

```
σ.SHM[line] / σ.SP[line]   : chip-shared / DNC-local memory (128-B lines).      [C-doc]
σ.AB[idx]                   : AB staging register space between ABSU/ABLU & TU.
σ.LRF[unit][r]              : per-compute-unit tile register file (TU/VU/XVU).
σ.MASK[tu]                  : the TU's per-lane write-mask register. It gates D6's blend write,
                              deciding which lane group a given FMA commits; INCRMASK steps it.
σ.ADDR[unit][e]             : the per-unit address register bank, holding the source and
                              destination line addresses of every load and store. NC units pack it as
                              SAR/SBR/CAR/CBR subfields (see Address model); SP/AB units
                              hold the analogous LRF. Stepped by C3/C4 between loop trips.
σ.TRF[splu][0..7]           : the SPLU's transfer-register file, 8 entries of a valid bit and 8 words.
                              The staging bank for the LDTRF/SHUFFLE/MERGE/SENDTRF family.
σ.LDJCR[u] / σ.SJOFF[u]     : on the SPLU and the NCSU, the 128-byte load-JCR buffer, which the
                              SPLU primes with a load and the NCSU with its own opcode, and the
                              send offset register, running 0 to 15. Both feed the JCR broadcast.
σ.CMP_FLAG[vu|xvu][slice]   : per-slice compare predicate set by FCMP/ICMP, consumed by SELECT.
σ.LFSR[xvu]                 : PRNG state read/written by COPY_LFSR / LOAD_LFSR.
data channels               : splu_{xvu,vu}, xvu_{tu,absu,sp,vu}, ablu:N_tu:N,
                              tu:N_south, tu:7_vu, vu_{spsu,xvu}, absu_ab, ...  [L0]
```
`select(mux, …)` denotes the per-source multiplexer, whose table is per unit.
The arithmetic operators and the elementwise ops are left abstract, with no numeric semantics.

---

## The address model: where the load and store strides come from

The four load and store families below write addresses and strides that are not op fields.
They are read from the unit's address register bank.
Each NC unit carries a 15-entry bank of packed words, with four subfields per word,
and the SP and AB units carry the analogous per-unit register file.
An access resolves its line address as a per-axis affine map over the DNC's tiling coordinate.

```
addr(entry, coord) = base + Σ_axis coord[axis]·stride[axis]      (mod field width)
```

- The base is set offline by the argument parser's init record, one source and destination address
  per operand, and loaded into the bank up front. The repository's CLAUDE.md states that contract.
- Each stride is a function of the problem dimensions, mined from the production dense header:
  the input row stride, the kernel tile stride, which both the input and output channel axes walk,
  the output row stride, the partial-buffer stride, and unit selectors of 1 on the channel axes.
- The per-pass step advances the address register on each trip of an enclosing loop.
  There are two mechanisms and they should not be conflated.

  The first is the SP face's built-in advance, which is the common streaming case.
  An SP load or store advances its own pointer per beat by a stride held in a second register,
  adding that register into the pointer.
  That is how a sweep over K scratchpad lines is written: set the stride to one line, loop K times,
  and no separate advance op is needed.
  Setting the stride to zero, or selecting the wrong stride register, re-reads one line, pinning it.

  That advance happens before the access rather than after,
  so the first beat touches the seed plus the stride and not the seed itself.
  Seed the pointer one line below the target, which the two base helpers do,
  or the stream silently skips the first line and reads or writes one line high.
  This was verified on the oracle for both the load and the store.
  - **explicit register-op advance (irregular / cross-pass):** the **C3/C4 register ops**
    the two register ops on the SP and AB units and the four on the NC units, whose immediate is
    itself the stride, advance the register between trips where the built-in stride
    doesn't fit (e.g. NC `nc_desc` line stepping, gather/scatter).
  The multi-pass M-split steps by the per-half-pass row count `X = rows//2`.

So a load's `Δs`/`Δd` is the `SAR`/`CAR` delta the loop's address-step op applies each
trip; the **C6 trip count × this delta sweeps the operand region**.

**SAR/SBR vs CAR/CBR role split (resolved).** The two subfield pairs are the two *sides*
of an NC move: `SAR`+`SBR` form the **SP-side** address, `CAR`+`CBR` the **SHM-side**
address, the scratchpad side from the first two subfields and the SHM side from the last two,
where the four source fields
index the σ.ADDR bank entries summed for each side). This is why `nc_desc(shm_line,
sp_line)` packs `sp_line` into the SBR bits `[27:16]` and `shm_line` into the CBR bits
`[83:64]` with SAR/CAR = 0: a plain "SP line ← SHM line" descriptor. Confirmed by the
SHM-region handling on **CBR** specifically (`init_decode.py:543-550` wraps CBR by the
32 MB SHM region) and the `nc_desc` bit packing. (Residue: within a pair, the base-vs-
stride roles within each pair, and the broadcast bit, are in C4.)

**A load of more than 31 lines takes several chunks, and the burst advance persists across instructions
(oracle-verified).** The `burst` field is 5-bit (max 31; `burst=32`→`0`→NC default 32),
but a burst `LDMU`/`STMU` auto-advances its address by `burst` lines **and that advance
carries over to the next load or store on the same descriptor entry**.
So a contiguous load of more than 31 lines is just back-to-back loads, one per chunk,
each within the burst limit.
They walk from SHM into the scratchpad contiguously with no register op between them.

Two caveats, both verified on the oracle.

  - The source fields index entries of the address bank rather than chunk numbers.
    The descriptor lives in entry 0, so every chunk keeps all four fields at 0.
    Using the chunk number instead selects an empty entry, whose address is 0,
    so it reads SHM line 0 rather than the continuation.
  - The two add-offset ops, one on the SHM side and one on the scratchpad side, add an extra offset,
    and they are for strided, non-contiguous or reset-and-jump access alone,
    such as a gather or a load from a sibling's reduction region.
    On a contiguous chain they over-advance, the burst having stepped already,
    so do not insert them between contiguous chunks.

### The NC face and the SP face do not name a scratchpad line alike

The same scratchpad line is named in two different units depending on which side touches it,
and confusing them silently reads or writes the wrong region, so operands come back as zeros.

- On the NC face, the descriptor word names its scratchpad target by line index directly,
  and the load or store then moves that many consecutive lines.
  Nothing is scaled and a line index goes in verbatim.
- On the SP face, the read and write pointer register holds a scratchpad byte address,
  which is the line index times 128, one line being 128 bytes or 64 dlf16 slots.
  The paired auto-increment register is likewise a byte stride, the line count times 128.
  Seeding an SP-unit pointer with a raw line index, omitting that scale, is the common mistake:
  the access lands a hundred and twenty-eighth of the way into the region and reads zeros.

The encoder supports both. Author an SP-face pointer with `dnckit.authoring.sp_addr`, which applies
the scale, mirroring the descriptor helper for the NC face.

<!-- provenance: model-impl (source-read, whole-domain). SP-face byte scale +
increment: prim_analyze/template_splusu.py (SPLU/SPSU "LRF[0-7] = 0..(0x100000-0x8000)"
byte range, "LRF[8-9] = (0x1-0x4)<<7" increment); SP read/write indexing:
prec_sim_process.py (sp.buf[wr_addr*128 ...], (rd_addr)<<7). NC-face line index:
authoring.nc_desc bits[27:16]. This is the SP-address *scale* (model-impl); the
SPLU.LDU/SPSU.STU full transitions remain `single` (D2/D8), so no COV promotion. -->>

## D1, the NCLU's two load forms, moving SHM into the scratchpad
<!-- COV id=D1 targets=NCLU.LDMU,NCLU.LDSU status=single evidence=matmul-trace -->
<!-- COV id=D1 targets=NCLU.LDM,NCLU.LDS status=variant note=no-update-forms -->
<!-- COV id=D1 targets=NCLU.LDMG,NCLU.LDMGU status=source-read note=gather-form-same-NCLUProcess-loop-addressing-upstream -->
`LDMU=0x23`, `LDSU=0x27`. fields `src0..src3, burst, cache, qos_vae, be`.
The four source fields select the address-bank entry, which gives the SHM base and the scratchpad base,
as the address model above describes.
The burst is the line count, and the two attribute fields have no effect on state.
```
⟦LDMU⟧:  for j in 0..burst−1:  σ.SP[d+j]       := σ.SHM[s+j]          # contiguous (Δ=1)
⟦LDSU⟧:  for j in 0..burst−1:  σ.SP[d+j·Δd]    := σ.SHM[s+j·Δs]       # strided; Δs,Δd from σ.ADDR
```
Reads `σ.SHM` + `σ.ADDR[nclu]`; writes `σ.SP`. Trace: `SHM[40] -> SP[418]` (real dlf16 data).

The burst is a 5-bit field, so its maximum is 31, and it is masked to those bits.
A value above 31 silently truncates to its low 5 bits, and a decoded 0 means the NC default of 32.
So a burst of 128 moves 32 lines rather than 128, and raises nothing, while a burst of 33 moves 1.

To move more than 32 lines, split into several loads or stores, each within the limit,
each with its own advanced descriptor.
`dnckit.authoring.nc_burst_chunks` does the split. (This is one concrete instance of
the silent-truncation trap; the SP-face `LDU`/`STU` `burst` is a *different* field/rule.)
<!-- provenance: model-impl. bitpos dnc_isa.py:251; NC burst 0->32 + get_fld masking
instr_pkt_v2.py:290-298. Scale/wrap source-read; D1 op rollup stays `single`. -->

## D2, the SPLU's load, feeding the scratchpad into compute
<!-- COV id=D2 targets=SPLU.LDU status=single evidence=matmul-trace -->
<!-- COV id=D2 targets=SPLU.LD status=variant note=no-update-form -->
`LDU=0x11`. fields `src0,src1, interleave_sz, burst, burst_sz, ld_rot, ld_type, ld_consumer, be`.
Reads an SP region, applies a layout transform (`ld_rot` rotate, `interleave_sz`),
and **enqueues to a compute channel** chosen by `ld_consumer` (`splu_xvu` or `splu_vu`).
```
⟦LDU⟧:  blk := layout( σ.SP[src .. src+burst_sz], ld_rot, interleave_sz )   # src = σ.LRF[src0] (byte addr)
        enqueue( channel[ld_consumer], blk )     # → xvu | vu
        σ.LRF[src0] += σ.LRF[src1]               # PER-BEAT POINTER ADVANCE (stride = LRF[src1])
```
Reads `σ.SP`; writes a `splu_*` channel. Trace: `SP[1ec00] : SP[3d8], SP[3d9]`.

**A per-instruction constraint: how the SP-streaming pointer advances.**
The first source field is the read pointer register, holding a byte address, so use the helper that
scales one.
The second selects the stride register.
Each beat reads `σ.SP[LRF[src0]]` and then advances `LRF[src0] += LRF[src1]`. So to stream K
consecutive SP lines, set the stride LRF to `0x80` (one line) and wrap the `LDU` in
`MVLOOPCNT(K)`; the sweep comes from the **stride**, NOT from `burst` (`burst=0` = one line per
beat). With the second source pointing at a zero stride, or unset, all beats re-read the same line, the
"pinned to line 0" trap. To re-stream the same window N times, use **N distinct pointer LRFs**
(each `LDU` advances only its own `src0`). Symmetric for `SPSU.STU` (write pointer + stride).
<!-- provenance: confirmed by the oracle-green reference spine.splu_stage / echo_streamreduce
(LDU src0=ptr LRF, src1=stride LRF=0x80, MVLOOPCNT(K) sweeps K lines; "each LDU advances its own
src reg") + template_splusu.py SPLU "LD LRF SRC=[0-7], INCR SRC=[8-9]". model/reference-derived. -->

**A per-instruction constraint: `burst` is a mode flag, and in burst mode the size defaults to 64.**
`burst` does not carry a count; it selects lines-per-beat via `burst_sz` (the packet's per-beat SP
line count, `instr_pkt_v2.py:545-551`):
- With the flag clear, one line per beat, which is the case described above.
- `burst != 0` (burst mode) → `burst_sz` lines per beat, **but if `burst_sz` is absent/0 it DEFAULTS
  to 64** (8 for `SENDTRF`/`SHUFFLE`); `interleave_sz` 2/3 then ×2/×4.

So there are two ways to feed one line per beat: clear the flag, or set it with a size of 1. A burst-mode load
with `burst_sz` left unset reads **64** lines per beat, not 1. Composed with the streaming `MVLOOPCNT(K)`
above, that is `64·K` lines, which reads as an unbounded runaway relative to the intended K. (Concretely:
a `MVLOOPCNT(64)` cout-fold kernel feed with `burst=1` and no `burst_sz` fed ~8466 lines/pass instead
of 64, and setting the size to 1 fixed it.)
<!-- provenance: model-impl, source-read. instr_pkt_v2.py:545-551 (SP-face LD/LDU/ST/STU size: burst==0->1,
burst!=0→burst_sz or default 64/8, interleave ×2/×4). Reconciles the "burst=0 = one line/beat" note above:
burst is the mode flag, burst_sz the count, default 64. Observed on the conv Cout>64 cb-fold feed. -->

## D3, the XVU's whole compute family, transforming an operand onto the TU's north
<!-- COV id=D3 targets=XVU.FMA,XVU.FNMS,XVU.FMUL,XVU.FCMP,XVU.FMINMAX,XVU.GCVT,XVU.ICVT,XVU.EE,XVU.IME,XVU.SELECT,XVU.FCVT,XVU.LOGICAL,XVU.MERGE,XVU.COMPRESS,XVU.SHR,XVU.PACK,XVU.SPLAT,XVU.FEST,XVU.PERMUTE,XVU.COPY_LFSR,XVU.LOAD_LFSR,XVU.ILUT,XVU.ICMP,XVU.IMINMAX,XVU.IADD,XVU.FMABF,XVU.FNMSBF,XVU.FMULBF,XVU.EEBF,XVU.IMEBF,XVU.FESTBF status=model-impl note=XVUProcess.run-shared-compute-routing+LOGICAL-also-matmul-trace -->
All 31 ops of the XVU's compute family share this one transition, since `XVUProcess.run`
runs every opcode through the same path (muxed `src0/1/2` → `out_*` fan → `LRF[lrf_tgt]`,
below); only the numeric kernel `_sim(<op>_ARR_64)` differs, and numeric semantics are
out of scope. So the *routing* (what this spec captures) is `model-impl` for the whole
family, read from one place. `LOGICAL` is additionally matmul-trace-confirmed. Per-op
notes: `data_type` selects whether an `out_*` carries the computed result (3), `src0`
passthrough (1), or `src2` passthrough (2); `FCMP`/`ICMP` write `σ.CMP_FLAG`, `SELECT`
reads it; `COPY_LFSR`/`LOAD_LFSR` read/write `σ.LFSR`. Source: `sim_runtime.py:1605-1710`.

`LOGICAL=0x10`. fields `src0,src1,src2, out_{nbr,vu,sp,ab,tu}, lrf_tgt, slice_en, mode, url, be`.
Elementwise/logical op over three muxed sources (`splu` channel, `const_reg`, imm);
result fanned to every enabled `out_*` channel and/or `LRF[lrf_tgt]`.
```
⟦LOGICAL⟧:  r := op_mode( select(src0), select(src1), select(src2) )
            for ch in {nbr,vu,sp,ab,tu} if out_ch:  enqueue(channel[ch], r)
            if lrf_tgt valid:  σ.LRF[xvu][lrf_tgt].slice[slice_en] := r
```
Reads `splu` channel + `const_reg`/`LRF`; writes `out_*` channels (matmul: `out_tu` → TU north) + `LRF`.
Trace: `splu,1,const_reg -> xvu0 -> tu0:0`.

## D4 and D5, the AB pair: the store from the XVU into the bank, and the load out to the TU's west
<!-- COV id=D4 targets=ABSU.LDSTU status=single evidence=matmul-trace -->
<!-- COV id=D4 targets=ABSU.LDST status=variant note=no-update-form -->
<!-- COV id=D5 targets=ABLU.LDSTU status=single evidence=matmul-trace -->
<!-- COV id=D5 targets=ABLU.LDST status=variant note=no-update-form -->
Both `LDSTU=0x11`. ABSU fields `src0,src1,interleave_sz,burst,burst_sz,be`;
ABLU adds `ld_type, ld_splat`. They stage the **second matmul operand** into `σ.AB`
then feed it to the TU's west edge.
```
⟦ABSU.LDSTU⟧:  blk := dequeue(channel[xvu_absu]);  σ.AB[dst] := blk
⟦ABLU.LDSTU⟧:  blk := σ.AB[src] (ld_splat ? broadcast : as-is)
               enqueue( channel[ablu:N_tu:N], blk )      # per-lane west feed
```
ABSU: reads `xvu` channel, writes `σ.AB`. ABLU: reads `σ.AB`, writes `ablu:N_tu:N`.
Trace: `xvu0 -> absu0 -> AB[0]` ; `AB[0] -> ablu0:0 -> tu0:0`.

## D6, the TU's FMA, which is the systolic MAC
<!-- COV id=D6 targets=TU.FMA status=single evidence=matmul-trace -->
<!-- COV id=D6 targets=TU.FMABF,TU.IMA4,TU.IMA8,TU.IMA2,TU.IMA8HF,TU.IMA4HF,TU.IMA2HF,TU.F8FMA,TU.F8FMABF,TU.I4FMA,TU.I4FMABF,TU.I8FMA,TU.I8FMABF,TU.F8F8MA,TU.F8F8MABF status=variant note=datatype-variants-same-MAC-shape -->
Specified in detail in the session draft; recap of the *general* transition
(`url_deg=1<<url[28:27]` trips; LRF index `src+sNurl·i`; **`tgts`** branch:
`==0`→write `LRF[tgtrf]`, `>0`→forward south, **row 7 → VU**):
```
⟦FMA⟧:  for i in 0..url_deg−1:
            s0:=select(src0)@(idx+s0url·i)  s1:=select(src1)@(idx+s1url·i)  s2:=select(src2)
            # the ALU routing is gated by the run mode rather than fixed:
            #   run_mode=2 (matmul MAC):  r := s0 ⊗ s2 ⊕ s1   (pinned C[lrf] × west B ⊕ north partial)
            #   run_mode=0 (load/skew):   src0=zero ⇒ product killed ⇒ r := s2 (the seed)
            r := mac_route(run_mode, s0, s1, s2)
            tgts==0 ? σ.LRF[tu][tgtrf+tgturl·i].slice[tgts] := blend(·,r,mask)
                    : enqueue(channel[ row7 ? tu:7_vu : tu:N_south ], r)
            σ.reuse := r
```
Reads `north`(XVU)/`west`(ABLU)/`LRF`/`reuse`; writes `LRF` or south/VU channel.

### D6a, how the TU FMA's source classes resolve to channels

The source selection above is not a flat register read. Each slot resolves to a
**channel** by its src-CLASS, and the consume target differs **per TU row** (decisive source:
PrecSim `instr_pkt_v2.py:889-896`):

| src class | TU row 0 consumes | TU rows 1..7 consume |
|---|---|---|
| west  | `ablu0:0` | `ablu{nc}:{row}`, the paired ABLU for that row |
| north | `xvu{nc}`, the XVU's feed | `tu{nc}:{row-1}_south`, the previous row's south forward |
| self          | the register file, a constant, or a reuse; no channel | the same |

W and N are **FIFO in-ports**: the FMA blocks until its source produces (an unfed W or N
source stalls this op; the producers are covered by the AB and XVU operational entries).
`self` reads a resident register, no channel. (Which numeric `src` code maps to W/N/self is in
`isa_tables`.) The dataflow role of these ports is covered elsewhere:
west feeds a single 8-lane slice rather than broadcasting to all 64, so a full-width operand rides
north or the register file, as the preamble of `families_operational.md` explains;
north carries the accumulating partial; and the drain at row 7 is
the TU systolic-array model in `families_operational.md`; this entry states only the per-src channel binding.*

## D6b, the TU's write-mask register, seeded by one op and advanced by another
<!-- COV id=D6b targets=TU.SETMASK,TU.INCRMASK status=model-impl note=row_mask-low-slice-write-gate -->
`σ.MASK[tu]` is the **`row_mask`** register (a single value `0..7`), the low-slice
write-gate on D6's LRF commit. `SETMASK=0x23` seeds it from its immediate; `INCRMASK=0x22`
(which shares the `NOP/RETURN` signature, hence the mixed-family tag) advances it. Both
read straight from `TUProcess`, which resolves the formerly open
`next()`/seed item**: `next` is just `+1 mod 8`.
```
⟦SETMASK⟧:   σ.MASK[tu] := mask                      # immediate 0..7; no channel movement
⟦INCRMASK⟧:  σ.MASK[tu] := (σ.MASK[tu] + 1) mod 8    # advance the gate; no channel movement
```
How D6 consults it: on the FMA LRF write (`tgts==0`), only lane-**slices ≥ `row_mask`**
commit, and slices below the mask are held. So the blend in D6 is precisely
"`σ.LRF[tu][tgtrf].slice[s] := r` for `s ≥ row_mask`, else keep". Raising the mask masks
off the low slices; `INCRMASK` walks the boundary up one slice per call.
Reads/writes `σ.MASK[tu]`; touches no data channel.
Source: `sim_runtime.py:2713-2720` (set/incr), `:2842-2847` (the slice gate).

## D7, the VU's FMA and compare, which post-process a vector on the way to the SPSU
<!-- COV id=D7 targets=VU.FMA,VU.FNMS,VU.FMUL,VU.FMABF,VU.FNMSBF,VU.FMULBF status=model-impl note=VUProcess.run-shared-routing+FMA-matmul-trace -->
<!-- COV id=D7 targets=VU.FCMP,VU.FMINMAX,VU.GCVT,VU.ICVT,VU.EE,VU.IME,VU.SELECT,VU.LOGICAL,VU.MERGE,VU.COMPRESS,VU.SHR,VU.PACK,VU.SPLAT,VU.FEST,VU.ILUT,VU.ICMP,VU.IMINMAX,VU.IADD,VU.EEBF,VU.IMEBF,VU.FESTBF status=model-impl note=VU-ALU-family-uniform-routing -->
<!-- COV id=D7 targets=VU.FMAHP,VU.FADDHP,VU.FRNDHP,VU.FMAHPBF,VU.FADDHPBF,VU.FRNDHPBF status=model-impl note=hpmode-extended-precision-of-FMA/FNMS/FMUL -->
`FMA=0x04`, `FCMP=0x0A`. fields `src0,src1,src2, out_{nbr,sp,xvu}, lrf_tgt, slice_en, [mode,] url, be`.
The reduction/normalize/compare engine; consumes the TU drain (`tu:7_vu`).
```
⟦VU.FMA⟧:   r := (select(src0)⊗select(src1))⊕select(src2)   # src0=tu, src1/2=const_reg/lrf
            route r to out_* (matmul: out_sp → SPSU) and/or σ.LRF[vu][lrf_tgt]
⟦VU.FCMP⟧:  m := compare(select(src0), select(src1))         # → mask/predicate in LRF
```
Reads `tu` channel + `const_reg`/`LRF`; writes `out_*` channels (`vu_spsu`) + `LRF`.

**A per-instruction constraint: a FIFO source class is popped once.**
A FIFO source class is popped once per instruction even where two source fields name it,
since a source FIFO is
read only if its class differs from the lower src's class (`prec_sim_process.py:1714-1721`).
So one FMA with `src0=src2=splu` consumes **one** beat and feeds the same value to both
operands (→ `x⊗x`-shaped, not two distinct elements). To combine *two* streamed operands,
or to reuse one streamed value for two ops, **capture each beat into an LRF first**
(`FMA(fifo,1,0)→reg`), then operate on the register(s). Non-FIFO srcs (`const_reg`/`LRF`/
`nfwd`/`reuse`) are not popped and have no dedup.

The `out_{nbr,sp,xvu}` (VU) / `out_{nbr,sp,vu,tu}` (XVU) routing fields are **2-bit
`data_type` selectors, one bit each, one per output channel. See `dnc_isa.py:752-754`,
and the model literally binds the field value to `out_d["data_type"]`
(`prec_sim_process.py:1513-1517`). Value `3` = emit the **computed result** to that
channel (the SP-drain path, `:1700`); `1`/`2` = forward/passthrough variants
(`:1625-1630`); `0` = channel inactive. So an elementwise result is drained with
`out_sp=3`, and a pass-through forward sets `out_vu=1`. <!-- provenance: model-impl. field
widths dnc_isa.py:752-754,788-792; value→route in VUProcess.run prec_sim_process.py:1513-1517,1625-1630,1700. -->
Trace: `tu,const_reg,const_reg -> vu0 -> spsu0`.

**`FMAHP`/`FADDHP`/`FRNDHP`** (+`BF`) are not a separate datapath: `VUProcess`
re-wires `FMA`/`FNMS`/`FMUL` ⇄ the `HP` names purely on the `hpmode` bit
(`sim_runtime.py:1438-1445`). `hpmode` selects an extended-precision accumulate,
src2 reads its high 16 b from `LRF[tgt]` and an extra 8 b from the paired
`LRF[tgt+8]` (`hphigh` picks the byte, `:1570-1585`). Same D7 routing, wider
accumulator → tagged `model-impl`.

Like XVU (D3), the full **21-op VU ALU family** (`FCMP/FMINMAX/GCVT/ICVT/EE/IME/
SELECT/LOGICAL/MERGE/COMPRESS/SHR/PACK/SPLAT/FEST/…`) runs through this one
`VUProcess.run` path: the shared muxed source, the output routing and the register file write, with the
per-op numeric result
of scope, so the whole family is `model-impl`. The two compare ops set the compare flag,
`SELECT` reads it.

**A per-instruction constraint: how the min-or-max variant is selected.**
The two min-max ops take type-3 encoding: their operands are the first and third source fields,
and the second is not a data source but
it is the min/max variant selector**. **`src1 = 0x0` selects MAX** (`src1 = 0x1` selects min).
So a running per-lane max is `FMINMAX(src0=acc, src1=0x0, src2=cur, lrf_tgt=acc)`. (This is the
same selector the reduce table in D10 derives from its own opcode field.)
Setting that field to 1 for a maximum, which is the intuitive guess, gives the minimum instead.
<!-- provenance: max=0x0 confirmed by oracle-green echo_streamreduce ("0x0 selects the max
variant", correct max over K); type-3 / src1-not-a-data-source from constr_vu type3_opcodes +
meta_dict type="3"; D10 desugar table src1=rsm_opc−0x8. min=0x1 inferred (complementary), not
yet isolated-tested. model/reference-derived. -->

## D8, the SPSU's store, moving a compute result into the scratchpad
<!-- COV id=D8 targets=SPSU.STU status=single evidence=matmul-trace -->
<!-- COV id=D8 targets=SPSU.ST status=variant note=no-update-form -->
`STU=0x11`. fields `src0,src1, interleave_sz, burst, burst_sz, st_type, st_producer, be`.
Drains a compute channel (`st_producer` = `vu`|`xvu`) into SP.
```
⟦STU⟧:  blk := dequeue(channel[st_producer]);  σ.SP[dst] := layout(blk, interleave_sz)
```
Reads a `*_spsu` channel; writes `σ.SP`. Trace: `vu0 -> spsu0 -> SP[458]`.

## D9, the NCSU's two store forms, moving the scratchpad into SHM
<!-- COV id=D9 targets=NCSU.STSU,NCSU.STMU status=single evidence=matmul-trace -->
<!-- COV id=D9 targets=NCSU.STS,NCSU.STM status=variant note=no-update-forms -->
<!-- COV id=D9 targets=NCSU.STMG,NCSU.STMGU status=source-read note=scatter-form-same-NCSUProcess-loop -->
`STSU=0x27`, `STMU=0x23`. fields mirror NCLU. Output writeback.
```
⟦STSU⟧:  for j in 0..burst−1:  σ.SHM[d+j·Δd] := σ.SP[s+j·Δs]
```
Reads `σ.SP`; writes `σ.SHM`. Trace: `SP[498] -> SHM[301]`.

## The immediate-address variants of the SP and AB load and store
<!-- COV id=D2i targets=SPLU.LDI,SPLU.LDIU status=source-read note=D2-with-typ2_imm-address -->
<!-- COV id=D8i targets=SPSU.STI,SPSU.STIU status=source-read note=D8-with-typ2_imm-address -->
<!-- COV id=D5i targets=ABLU.LDSTI,ABLU.LDSTIU status=source-read note=D5-with-typ1a_imm-address -->
The **immediate-addressed** forms of the D2/D8/D5 streaming load/stores: identical
layout and routing, but the line address comes from an instruction immediate
instead of `σ.ADDR`/`src1`. **Source-confirmed, not trace-confirmed**
(`status=source-read`): `dnc_isa_api_util.splu_load_jcr` emits `LD/LDU` with
`src1,interleave_sz,burst` and `LDI/LDIU` with the *same* `ld_consumer/ld_type/ld_rot`
common args but `typ2_imm` in place of the address operands; `constr_spsu.py:33`
groups `ST/STU/STI/STIU` as one opcode set (STI = ST's immediate form);
`template_ablusu.py:316` uses `typ1a_imm` as the AB address increment.
```
⟦SPLU.LDI⟧   ≡ ⟦D2.LDU⟧    with src := typ2_imm        # immediate SP offset, not src1+burst
⟦SPSU.STI⟧   ≡ ⟦D8.STU⟧    with dst := typ2_imm
⟦ABLU.LDSTI⟧ ≡ ⟦D5.LDSTU⟧  with src := typ1a_imm       # immediate AB offset for the west feed
```
The `U` suffix is the address-register-update form (as elsewhere). The immediate's
low bits are line-aligned away (`constr_spsu.py:234` masks `[7-1:0]`,
`constr_ablu.py:204` masks `[4-1:0]`). **Not** folded here: `ABSU.LDSTI` carries
the three store-shape fields, which give a scatter-permute store, a richer shape left
OPEN for the flash_attn pass; and `SPLU.LDITRF` is the immediate form of the still-OPEN
`LDTRF`, so it waits on its parent.

## D10, the cross-lane reduction on the VU and the XVU
<!-- COV id=D10 targets=VU.REDUCE,XVU.REDUCE status=model-impl note=sim_runtime.reduce_payload-desugar-whole-domain -->
REDUCE is **not a distinct datapath**. PrecSim implements it
(`sim_runtime.py::VUProcess.reduce_payload`, XVU overrides) by **desugaring**
into an existing D7/D3 compute op chosen by `rsm_opc`, with the cross-lane carry
routed through the lane-**neighbor** source and an iterated `url` reduction tree. Its
transition is therefore that compute op's own, over a rewritten operand set. Read
straight from the engine (`status=model-impl`, every `rsm_opc`, **no trace needed**;
this is the strongest non-trace evidence: the oracle's own definition over the whole
input domain, not one sampled instance).

`reduce_imm` decode: `rsm_src=[4:0]`, `rsm_opc=[9:5]`, `rsm_url=[12:10]`,
`rsm_tgt=[17:13]`. Fixed rewrite: `src0:=rsm_src`, `src2:=SRC_NBR` (VU `0x3` / XVU `0x4`,
the lane-neighbor channel), `lrf_tgt:=rsm_tgt`, `url:=0b100111`. Then `rsm_opc` selects:

| rsm_opc | desugars to | reduction |
|---|---|---|
| 0x1 / 0x2 | `FMA` / `FMABF` (src1=0xE) | **sum** |
| 0x4 | `PACK` (src1=0x7) | pack |
| 0x5 | `PACK` (src0=NBR, src1=0x11, src2=rsm_src, url=0b110011) | pack (alt route) |
| 0x8–0xF | `FMINMAX` (src1 = rsm_opc−0x8) | **min / max** |
| 0x10 | `SELECT` (src1=0x0) | select |
| 0x14 / 0x15 | `FMUL` / `FMULBF` (src1=NBR, src2=0xA) | **product** |
| 0x18–0x1D | `LOGICAL` (src1 = rsm_opc−0x18) | **bitwise** |

```
⟦REDUCE⟧ ≡ ⟦{FMA|FMABF|PACK|FMINMAX|SELECT|FMUL|FMULBF|LOGICAL}⟧
            with (src0,src1,src2,lrf_tgt,url) := reduce_payload(rsm_opc, rsm_src, rsm_tgt)
            # each lane is fed its sibling's partial via SRC_NBR; iterated url-deg times
            # this is the log-tree reduction collapsing the lane axis → σ.LRF[unit][rsm_tgt].
```
Reads the compute channel (src0) + the neighbor lane (`SRC_NBR`); writes
`σ.LRF[unit][rsm_tgt]`. Source: `sim_runtime.py:1334-1390` (VU), `:1997` (XVU).

## D11, the SPLU's transfer-register-file ops: load, shuffle, merge, and the two sends
<!-- COV id=D11 targets=SPLU.LDTRF,SPLU.SHUFFLE,SPLU.MERGE,SPLU.SENDTRF status=model-impl note=sim_runtime.SPLUProcess-trf-datapath -->
<!-- COV id=D11 targets=SPLU.LDITRF status=model-impl note=LDTRF-with-typ2_imm-address -->
<!-- COV id=D11 targets=SPLU.SENDJCR status=model-impl note=cross-unit-JCR-broadcast -->
<!-- COV id=D11 targets=SPLU.LDUTRF,SPLU.LDIUTRF status=variant note=address-register-update-forms -->
<!-- note: each TRF-load family is {base, U-update}; LDUTRF/LDIUTRF are the U twins of LDTRF/LDITRF -->
SPLU's second role (beyond D2's compute-feed `LDU`): staging through the 8-entry
transfer-register file `σ.TRF[splu]` and the cross-unit JCR broadcast. All read
straight from `SPLUProcess` (`status=model-impl`); the granule permute/merge math is
a C kernel, which is out of scope, so what is specified here is the routing.

```
⟦LDTRF / LDUTRF⟧:   blk := layout(σ.SP[src..], ld_rot, ld_type)   # same SP read as D2
                    σ.TRF[splu][trf_dst1] := blk                  # → TRF instead of a compute channel
⟦LDITRF / LDIUTRF⟧: ≡ ⟦LDTRF⟧ with src := typ2_imm               # immediate-address form

⟦SHUFFLE⟧:  out := splu_shuffle(σ.TRF[splu][trf_src0], mgsh_ty)   # granule = {64,32,16}b per mgsh_ty
            ld_consumer==0 ? σ.TRF[splu][trf_dst0] := out         #   self-write back to TRF
                           : enqueue(channel[ld_consumer], out)   #   or stream to a compute unit
⟦MERGE⟧:    (o0,o1) := splu_merge(σ.TRF[splu][trf_src0], σ.TRF[splu][trf_src1], mgsh_ty)  # 64b granule
            σ.TRF[splu][trf_dst0] := o0 ;  σ.TRF[splu][trf_dst1] := o1   # two-register interleave
⟦SENDTRF⟧:  enqueue(channel[ld_consumer], sendz ? 0 : σ.TRF[splu][trf_src0])  # egress only; self = error

⟦SENDJCR⟧:  off := offset_imm + (offset_mode ? σ.SJOFF[splu] : 0)
            d8  := σ.LDJCR[splu][off>>1]  (off even ? low64 : high64)     # pick an 8-B JCR word
            for tgt in ncore units selected by consumer_mask:            # {spsu,splu,absu,ablu,xvu,vu,tu}
                σ.JCR[tgt] := lanes(d8, strb)                            # broadcast under the byte-strobe
            σ.SJOFF[splu] := offset_rst ? 0 : σ.SJOFF[splu] + (offset_inc ? 1 : 0)   (mod 16)
```
Reads `σ.TRF`/`σ.SP`/`σ.LDJCR`; writes `σ.TRF`, a compute channel, or peer `σ.JCR`.
`SENDJCR` is the cross-unit JCR-injection path (cf. paged-attention const-buffer routing).
Source, all in `sim_runtime.py`: the load at `:758-763`, the shuffle at `:819-871`, the merge at `:873-922`,
SENDTRF `:924-939`, SENDJCR `:941-1000`; `σ.TRF` init `:196`.

## D12, the NC units' constant fill and JCR injection
<!-- COV id=D12 targets=NCLU.LDC,NCSU.STC,NCSU.LOADJCR status=model-impl note=NC-const-fill+jcr-buffer -->
<!-- COV id=D12 targets=NCSU.SENDJCR status=model-impl note=cross-DNC-JCR-broadcast-core_id -->
<!-- COV id=D12 targets=NCLU.LDCU,NCSU.STCU status=variant note=address-register-update-forms -->
The NC units' constant-fill and JCR-injection ops are the siblings of the movers in D1 and D9, and they
synthesize data rather than copy it. All read from `NCLU/NCSUProcess`
(`status=model-impl`).
```
⟦LDC / LDCU⟧:   for j: σ.SP[wr+j]  := splat128(ld_const)    # broadcast an IMMEDIATE const into SP
⟦STC / STCU⟧:   for j: σ.SHM[wr+j] := splat128(st_const)    # …or into SHM (no SP read)
                # (the non-const LDC/STC path is exactly D1 / D9; the C-form skips the read)
⟦LOADJCR⟧:      σ.LDJCR[ncsu] := bigendian128(σ.SP[rd])     # prime the 128-B JCR buffer from SP
⟦SENDJCR⟧:      off := offset_imm + (offset_mode ? σ.SJOFF[ncsu] : 0)
                d8  := σ.LDJCR[ncsu][off>>1] (off even ? low64 : high64)
                for tgt in units selected by consumer_mask, on core core_id:   # cross-DNC reach
                    σ.JCR[core_id][tgt] := lanes(d8, strb)
                σ.SJOFF[ncsu] := offset_rst ? 0 : σ.SJOFF[ncsu] + (offset_inc ? 1 : 0)  (mod 16)
```
The NCSU's send is the SPLU's from D11 plus a core identifier, so it injects into a peer
DNC's* unit, the cross-DNC const-buffer routing behind paged attention. `ld_const`/`st_const`
arrive as the per-cmd const operand, not an opcode field. Source: `sim_runtime.py`
LDC `:425-440`, STC `:493-535`, LOADJCR `:557-572`, SENDJCR `:583-660`.

## D13, the SPSU's register copy, from a channel into the register file or the JCR
<!-- COV id=D13 targets=SPSU.LRFCOPY status=model-impl note=pop-ififo-write-lrf-or-jcr -->
The SP-store unit's register-write op: pops one value off its input channel and
lands it in a register rather than SP. Read from `SPSUProcess` (`status=model-impl`).
```
⟦LRFCOPY⟧:  (txn,v) := dequeue(ififo)
            (typ2a_jcr_tgt ? σ.JCR[spsu][src0] : σ.LRF[spsu][src0]) := v
            consume ? ∅ : forward v on the feedback path     # consume gates the self-forward
```
Reads an input channel; writes `σ.LRF`/`σ.JCR`. Source: `sim_runtime.py:1036-1052`.

## Unsupported / decode-only boundary  (`ZSFMA` · `ZSLD` · `ZSLDI` · `AB.LDST` · `ABSU.LDSTI`)
<!-- COV id=ZS targets=TU.ZSFMA,TU.ZSFMABF,ABLU.ZSLD,ABLU.ZSLDU,ABLU.ZSLDI,ABLU.ZSLDIU status=source-read note=zero-skip-NOT-executed-by-this-precsim-decode-only -->
<!-- COV id=ABx targets=AB.LDST,AB.LDSTI,AB.LDSTU,AB.LDSTIU status=source-read note=AB-is-a-decode-namespace-no-runtime-unit -->
<!-- COV id=ABx targets=ABSU.LDSTI,ABSU.LDSTIU status=source-read note=immediate+scatter-permute-store-form-of-D4 -->
What remains is tagged `source-read`, because the engine does not implement
them**, so they cannot be raised above field-table inference (and a trace can't
validate them either):

- The zero-skip ops for sparsity, one on the TU and two on the ABLU. PrecSim
  raises `InstrNotImplementedError` for them and `constr_tu`/`constr_ablu` mark them
  `TODO / NEED SPECIAL CONSTR`. From the decode tables they are the FMA / AB-load
  shapes plus a zero-operand selector (`src "zero" = 0xF/0x3`, `constr_tu.py:85-105`)
  and the `zs_slot/zs_len/zs_run/zs_reset` accumulator-slot fields. **Unsupported in
  this PrecSim build**, which makes it an axiom rather than a transition anything here can validate.
- The bare AB load-store. The AB unit is a decode namespace and there is no process for it at
  runtime. Its load/store executes split across `ABLU` (D5, → TU west) and `ABSU`
  (D4, XVU → AB). Nothing new to fill at the AB level.
- The ABSU's immediate form, which adds the immediate address and the scatter-permute fields
  store form of D4; handled by ABSU's generic store loop. `source-read` until the
  permute path is traced.

---

## L2, the composition: the NCore matmul loop, verified against a trace

```
        ┌────────────────────────── operand A path ──────────────────────────┐
 SHM ──NCLU.LDMU──▶ SP ──SPLU.LDU──▶ XVU.LOGICAL ──out_tu──▶ TU.north
                                         │
                                         └──out──▶ ABSU.LDSTU ──▶ AB ──ABLU.LDSTU──▶ TU.west
                                                              (operand B path)
 TU.FMA  (systolic, 8 lanes; row7 ──tu:7_vu──▶)  VU.FMA ──out_sp──▶ SPSU.STU ──▶ SP ──NCSU.STSU──▶ SHM
```
Ordering between stages is enforced by C2 sync tokens on the matching channels
(`nclu_splu0`, `splu0_spsu0`, `ablu0_absu0`, …).

## Remaining tail (not on this path)
The remaining data families are: (a) **datatype variants** of the above (TU
the TU's integer and 8-bit modes and the VU's bfloat mode, which share a transition and differ only in
the arithmetic type, so they fold in as variants; and the immediate-address forms, which fold
above as D2i/D8i/D5i (`source-read`); (c) **other-kernel ops** (`MERGE`,
`REDUCE`, `LDTRF`, `SHUFFLE`, `ZSLD/ZSFMA`, `SENDTRF/SENDJCR`, the scatter-permute
the ABSU's immediate form, which flash attention exercises and matmul does not. Those stay open, to fill against a
flash_attn trace by the identical method. See `coverage.md` for the live OPEN set.
