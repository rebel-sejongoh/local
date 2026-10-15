# The SPLU ↔ XVU FIFO contract

> **Note on the `examples/` and `tools/` citations below.** Those trees were removed in `759ef3b0`,
> which replaced the example-per-algorithm approach with the `mcc` compiler. The file-and-line pointers
> in this document are therefore historical: they resolve against the repository before that commit
> (`git show 759ef3b0^:PrimitiveAuthor/<path>`), not against the working tree. The method they
> illustrate is unchanged, which is why they are kept rather than deleted.

Verified deep-dive into how SPLU pushes and XVU/VU pop the inter-unit
FIFO. Written 2026-05-29 while restructuring `flash_attn_recomp/s6_real_recomp.py`
after its 6-input cascade deadlocked.

Companion: [`reduction_and_mask_contract.md`](reduction_and_mask_contract.md)
covers what the XVU/VU *compute* once data is staged (FMINMAX/REDUCE reduction,
masking by substitution, and this doc covers how the data moves.

Every claim below cites the prec_sim source or DNC ISA spec it came
from; nothing is empirical conjecture, and nothing is sourced from the
the silicon primitive headers, which is the purity constraint the method sets; see
`examples/flash_attn_recomp/README.md`).


## TL;DR

| Side | Operation | Granularity |
|------|-----------|-------------|
| **Producer** (SPLU) | one `LDU` *instruction* with `burst=N` | pushes **N entries** into the destination FIFO |
| **Each FIFO entry** | one 128-byte SP line | = 8 words × 16 B = **64 DLF16 values** = one full VU/XVU SIMD register |
| **Consumer** (XVU/VU) | one `FMA` *execution* with `srcK = 0x1` | pops **exactly one entry** per `has_srcK = True` FIFO source |
| **`unroll(M)` on FMA** | runs the same instruction M times in one call | pops **M entries** per FIFO source |

So if your inner-iter compute needs to read **K distinct vectors** from
SP, the producer must push K entries before the consumer drains them,
and the consumer must execute K FMA pops in the same logical iteration.

The historical confusion ("1 push = 1 SIMD-8 vector consumed by ONE
FMA") collapsed two correct halves of the contract into a wrong whole:
each push is **one full SP line** (not one SIMD-8 vector), and each FMA
does pop exactly one entry, and that entry already holds a full
64-DLF16 register's worth of data distributed across 8 slices × 8 SIMD
lanes. There is no "pop one slot of a multi-slot entry" mode.


## 1. Where the contract lives

| Side | File | Lines |
|------|------|-------|
| SPLU LDU push | `third_party/rebel_prec_sim/prec_sim_process.py` | 666–784 (push at 780–783) |
| XVU/VU FMA pop | `third_party/rebel_prec_sim/prec_sim_process.py` | 1420–1710 (XVU); 1986–2305 (VU). Pop at 1534–1535, 1701–1708 |
| LDU address-gen | `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/init_decode.py` | 2240–2342 |
| `ld_consumer` → unit name | `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/dnc_isa.py` | `inst_param_tag` (search "ld_consumer") |
| FIFO routing model | `third_party/rebel_prec_sim/rebel_hw_util/tools/lib/prim_analyze/instr_pkt_v2.py` | 518–556 (SPLU `produce_to`) |


## 2. Anatomy of one FIFO entry

Read `prec_sim_process.py:692–755`. For a single LDU's `i`-th burst step,
the SPLU reads two 128-byte chunks from SP, applies `shift / align /
rotate` to handle `ld_type` and unaligned addresses, and ends with a
single `load_data` list whose shape is **`[8 × 16B]`**.

Then 780–783:

```python
for (unit, fifo) in ofifos.items():
    fifo.append((ctx.txn_id, [ split8(data_16B) for data_16B in load_data ] ))
```

`split8(16B)` decomposes each 16-byte word into 8 × 2-byte DLF16 values,
so an entry's payload is eight groups of eight values, 64 in all. Each
entry carries:

```
entry = (txn_id, [ [v00,v01,…,v07],     # slice 0, lanes 0..7
                   [v10,v11,…,v17],     # slice 1, lanes 0..7
                   …
                   [v70,v71,…,v77] ])   # slice 7, lanes 0..7
```

When XVU/VU consumes the entry, the consumer flattens this 8×8 layout
straight into a 64-element `in_x_arr` via `itertools.chain.from_iterable`
(`prec_sim_process.py:1818-1819, 1844-1847`), and the C++ FPU sim runs
**one parallel pass across 64 SIMD lanes**.

So 1 entry → 1 FMA execution → 1 full 64-lane vector compute. There is
no addressable "slot" inside an entry that a separate pop could grab.


## 3. The producer side: how the loader schedules its pushes

### 3.1 `LDU` instruction fields

The `LDU` opcode encodes a read into one of four FIFO targets via
`ld_consumer` (§3.3) plus a `burst` / `burst_sz` pair that sets how many
SP lines the single instruction reads. The authoritative expansion of
those fields into per-line reads is in `init_decode.py` (§3.2):

- `burst = 0` → one read (`bs = 1`), `burst_sz` ignored.
- `burst = 1` → `bs = burst_sz` reads (1..64; the bitfield can't encode
  more, as section 8.5 explains).

So a single `LDU` with `burst=1, burst_sz=N` packs N reads (N ∈ [1, 64])
into one instruction word. In our regime (single reads, or `burst_sz=4`)
we always land on the single-instruction case.

### 3.2 `init_decode.py:2300–2342` expands burst

```python
if not burst:
    bs = 1
else:
    bs = 64 if not burst_sz else burst_sz      # ← burst_sz is the actual N

for _ in range(bs):
    shadow_reg = self.LRF[src0]
    for gi in range(1, groups + 1):                          # groups derived from interleave_sz
        addr_i = self.LRF[src0] + (imm if is_imm else self.LRF[src1])
        addr_i, _ = self.update_LRF_value(addr_i, ...)        # SP wrap

        if is_update:                                         # LDU has the 'U' → update LRF[src0]
            self.update_LRF(PC, opcode_str, src0,
                            addr_i if (not interleave_sz or gi != groups)
                                   else shadow_reg + interleave_step,
                            lrf_type="SP")
        if is_read:
            self.mem_access(PC, opcode_str, "SP", "RD", addr_i)
```

Translating that:

- The burst size gives exactly that many reads per load instruction. A batched
  read sets `burst=1, burst_sz=4`, so `bs=4`.
- Each iteration computes `addr_i = LRF[src0] + LRF[src1]`. With the
  flash_attn convention (`src1 = 0xf`, `LRF[0xf] = 128`), the stride
  between consecutive reads is one 128-byte SP line.
- `LDU` (not `LD`) updates `LRF[src0] := addr_i` after each step, so
  the LRF marches one SP line per push. After the burst, `LRF[src0]`
  has advanced by `N × 128 B`.
- One read = one FIFO push (back in `prec_sim_process.py:780-783`).

Practical recipe: **to push K consecutive SP lines into the XVU FIFO,
set `LRF[s0] = base − 128`, `LRF[s1] = 128`, then emit an LDU record
with `src0=s0, src1=s1, ld_consumer=1, burst=1, burst_sz=K`.**

### 3.3 `ld_consumer` routing

From `dnc_isa.py`'s `inst_param_tag` (search "ld_consumer"):

| `ld_consumer` value | FIFO target |
|---|---|
| `0` | the loader's own internal path, as a transfer-register load or a self-write |
| `1` | `xvu{ncore}` |
| `2` | `spsu{ncore}` |
| `3` | `vu{ncore}` |

To route a read to the XVU FIFO, set `ld_consumer=1` in the LDU record
(s4's `lower_splu` and s6's `lower_splu_s6` both do this).

Per-DNC FIFO names (`prec_sim_process.py:1472`,
`fifo_name_remap`): `splu0_xvu0`, `splu0_xvu1`, `splu1_xvu0`, … There
is one FIFO per `(splu_src_ncore, consumer_ncore)` pair within a DNC.


## 4. The consumer side: how a compute unit drains the FIFO

### 4.1 src binding (`prec_sim_process.py:1452–1479`)

```python
src_dict, has_srcs, _ = ConstrVU.check_source(opcode, params)
src = {}
src_arr = []
for s, has_s in zip(["src0","src1","src2"], has_srcs):
    if not has_s:
        src[s] = params[s]
        src_arr.append([])
        continue
    for k, v in src_dict[s].items():
        if params[s] in v:
            src[s] = k                          # 'tu' / 'xvu' / 'splu' / 'lrf' / 'const_reg' / …

    if src[s] in ["tu", "xvu", "splu"]:
        fifo_name = self.fifo_name_remap(src[s], ctx.ncore_idx, ctx.row_idx)
        src_arr.append(ififos[fifo_name])      # ← bound to the actual deque
    else:
        has_srcs[i] = False
        src_arr.append([])
```

For an XVU FMA with `src0 = 0x1` the encoded source dictionary tag is
`"splu"`. The corresponding FIFO that comes back from
`fifo_name_remap("splu", ncore_idx, row_idx)` is `splu{ncore}_xvu{ncore}`
which is the same queue the producer pushed into.

### 4.2 Read + pop (`prec_sim_process.py:1523–1710`)

Inside `for i in range(curr_size, curr_size+amt):` (the per-call unroll
loop):

```python
if has_src0:
    src0_txn_id, src0_data = src_arr[0][0]            # peek head
elif src["src0"] == "lrf":
    src0_data = ctx.lrf[src0 - 0x10]                   # LRF read
…
# … compute via prec_sim.so …
if has_src0:
    src_arr[0].pop(0)                                  # pop one entry
if has_src1 and src["src1"] != src["src0"]:
    src_arr[1].pop(0)
if has_src2 and src["src2"] not in (src["src0"], src["src1"]):
    src_arr[2].pop(0)
```

The pop guards mean: **if two operands name the same source FIFO, the
operands share a single peek and a single pop** (one entry → both
`src0_data` and `src1_data`). Each *distinct* FIFO source contributes
exactly one pop per unrolled iteration. For our 1-FIFO-input cascades
this collapses to "one pop per unrolled iter."

### 4.3 The unroll field: the unroll count and the per-operand advance

Per `prec_sim_process.py:1486–1490`:

```python
url_amt = (params.get("url", 0) & 0b000011)            # bits[1:0]
url_s0  = (params.get("url", 0) & 0b000100) and url_amt
url_s1  = (params.get("url", 0) & 0b001000) and url_amt
url_s2  = (params.get("url", 0) & 0b010000) and url_amt
url_tgt = (params.get("url", 0) & 0b100000) and url_amt
```

`url_amt` is the unroll count (max 3 → up to 4 unrolled executions),
and the `url_s*` / `url_tgt` bits choose whether each operand index
advances per unroll step. The pop happens at the bottom of every
loop iteration, so:

- `url_amt = 0 / 1` → 1 execution → 1 pop per FIFO src
- `url_amt = 2` → 2 executions → 2 pops per FIFO src
- `url_amt = 3` → 3 executions → 3 pops per FIFO src

The `url_s0/url_s1/url_s2/url_tgt` bits (bits[2:5] of the `url` field)
do not change how many entries are popped, only which
LRF index is touched on each unrolled iter. The pop count is strictly
`url_amt × (# distinct FIFO sources)`.

### 4.4 LRF-vs-FIFO operand encoding

For XVU/VU instructions, an operand value in `0x0–0xF` is a non-LRF
source (FIFO or constant pool); `0x10–0x1F` is `LRF[0..15]`. The exact
mapping is in `ConstrVU.check_source` (`prim_analyze/constr_xvu.py`,
`constr_vu.py`). The canonical mappings you'll encounter in
flash_attn_*:

| `srcK` value | Meaning |
|---|---|
| `0x0` | constant 0 |
| `0x1` | SPLU FIFO (i.e., `splu{ncore}_xvu{ncore}` or `splu{ncore}_vu{ncore}`) |
| `0x2` | TU FIFO |
| `0x3` … `0xF` | other constants / immediates / NBR forwards (opcode-dependent) |
| `0x10` … `0x1F` | LRF[0]…LRF[15] |

In `s4_authored.py` line 120, `_SPLU_FIFO = 1` is set to exactly this
encoding.


## 5. Cross-side worked example: alpha-readout (s4, 1-input)

This is the simplest working cascade in the codebase. SHM → SP → XVU
→ SHM round-trip with one staged input per inner iter.

```
NCLU: LDMU burst=4               # 4 SHM lines → SP lines 0..3
SPLU: MVLOOPCNT(4)
        LDU src0=1, src1=3,      # LRF[1]=sp_dest-128, LRF[3]=128
            burst=0, ld_consumer=1, be=1
            → 1 push to xvu FIFO per iter
        (loop 4×: 4 pushes total)
XVU:  MVLOOPCNT(4)
        FMA(src0=1, ONE, ZERO → XL)      # pop 1 → XL = entry_data * 1 + 0
        FNMS(XL, C, ZERO → NEG_C_NEW)
        FMA(MAX_OLD, C, NEG_C_NEW → C_DIFF)
        ICVT(15, 7, C_DIFF → ALPHA)
        FMA(ALPHA, SUM_OLD, SUM_NEW → SUM_OUT)
        FMA(ALPHA, ATTN_OLD, ATTN_NEW → ATTN_OUT, out_sp=3, be=1)
        (four trips, so four pops in all, matching the four pushes)
SPSU: MVLOOPCNT(4)
        STU src0=2, src1=3, st_producer=1, be=1
            → 1 pop from xvu output FIFO per iter
NCSU: STMU burst=4               # 4 SP lines → 4 SHM lines
```

The two counts match exactly. Nothing is unrolled, and each call
is one execution. The XVU's FIRST `FMA(src0=1, …)` is the only FIFO
consumer in the cascade; the subsequent FMA/FNMS/ICVT/FMA/FMA chain all
read from LRF, so they don't touch the FIFO.

`PrimitiveAuthor/examples/flash_attn_recomp/s4_authored.py:244–251` and
`:337–344` are the source for this cascade. It runs end-to-end on
PrecSim (s5 confirms 16-DNC byte-exact).


## 6. A worked example across both sides: the six-input kernel, corrected

The s6 deadlock from session 2026-05-29 came from a cascade that pushed
4 entries per inner iter (one LDU, `burst=0`, `bs=1`, 4 iters) but
attempted 8 FMA(src0=1) pops per inner iter (32 pops total).

After the contract above, the fix is mechanical. Two equivalent
shapes work:

### 6.1 The first shape: six load instructions and no burst, which is that kernel's memory plan

```
SPLU: SYNC imm=6 (NCLU|RECV)
      MVLOOPCNT(4)            # 4 inner iters
        LDU src0=1,  src1=19, ld_consumer=1     # max_old
        LDU src0=4,  src1=19, ld_consumer=1     # max_new
        LDU src0=7,  src1=19, ld_consumer=1     # sum_old
        LDU src0=10, src1=19, ld_consumer=1     # sum_new
        LDU src0=13, src1=19, ld_consumer=1     # attn_old
        LDU src0=16, src1=19, ld_consumer=1, be=1   # attn_new (close loop)
      RETURN be=0
      # 6 pushes / iter × 4 iters = 24 entries

XVU:  IMMCOPYs (ZERO, C, ONE)
      MVLOOPCNT(4)
        FMA(1, ONE, ZERO → MAX_OLD)             # pop 1
        FMA(1, ONE, ZERO → MAX_NEW)             # pop 1
        FMA(1, ONE, ZERO → SUM_OLD)
        FMA(1, ONE, ZERO → SUM_NEW)
        FMA(1, ONE, ZERO → ATTN_OLD)
        FMA(1, ONE, ZERO → ATTN_NEW)            # 6 pops/iter, no discards
        FNMS(MAX_NEW, C, ZERO → NEG_C_NEW)
        FMA(MAX_OLD, C, NEG_C_NEW → C_DIFF)
        ICVT(15, 7, C_DIFF → ALPHA)
        FMA(ALPHA, SUM_OLD, SUM_NEW → SUM_OUT)
        FMA(ALPHA, ATTN_OLD, ATTN_NEW → ATTN_OUT, out_sp=3, be=1)
      RETURN be=0
      # 6 pops / iter × 4 iters = 24 entries
```

LRFs[1, 4, 7, 10, 13, 16] hold the six (pre-decremented) staging bases;
LRF[19] holds `stage_size = 0x80`. The 6 SHM input regions per DNC are
contiguous (24 lines total) so NCLU can drop them with `LDMU burst=24`.

### 6.2 The second shape: one load per variable with a burst of four, in the batched style

Instead of N separate single-read LDUs per inner iter, issue one
`burst`-batched LDU per variable that pushes all 4 rows at once
(`burst=1, burst_sz=4`, §3.2), and drain on the XVU side with `url_amt=2`
unrolled FMAs (§4.3):

```
SPLU: (no inner MVLOOPCNT)
        LDU src0=base0, src1=stride, burst=1, burst_sz=4, ld_consumer=1   # max_old × 4
        LDU src0=base1, src1=stride, burst=1, burst_sz=4, ld_consumer=1   # max_new × 4
        LDU src0=base2, src1=stride, burst=1, burst_sz=4, ld_consumer=1   # sum_old × 4
        LDU src0=base3, src1=stride, burst=1, burst_sz=4, ld_consumer=1   # sum_new × 4
        LDU src0=base4, src1=stride, burst=1, burst_sz=4, ld_consumer=1   # attn_old × 4
        LDU src0=base5, src1=stride, burst=1, burst_sz=4, ld_consumer=1   # attn_new × 4
        # 24 pushes total

XVU:  FMA(src0=1, …, url=url_amt2_bits)   # 2 pops max_old
        FMA(src0=1, …, url=url_amt2_bits) # 2 more pops max_old
        … etc, draining in the SAME order SPLU pushed
```

The pushes are issued back-to-back so the FIFO holds them in the order
[max_old0..3, max_new0..3, sum_old0..3, sum_new0..3, attn_old0..3,
attn_new0..3]; the XVU must consume in exactly that order, otherwise
it gets the wrong variable, since there is no random access into
the FIFO.

### 6.3 Which shape to pick

Shape A is closer to s4 and easier to reason about for the first
a correct run of that kernel, since every iteration of the inner loop has the same
push/pop count and the bookkeeping is uniform. Shape B reduces SPLU
instruction count but needs `url`-unroll plumbing on the XVU side and
per-variable LRF discipline. Recommend starting with Shape A; refactor
to Shape B if SPLU instruction budget becomes tight. **s6 implements
Shape A** and passes 16/16 DNCs bit-exact.


## 7. Authoring patterns (derived from prec_sim + ISA spec)

Patterns that fall straight out of §§2–4, useful when building a new
cascade. All of them come from this stack and the simulator, with no external source.

1. **Push order = pop order.** A `(splu, consumer)` pair shares a single
   FIFO deque (`prec_sim_process.py:780-783` append, `:1701-1708` pop).
   Pushes land in instruction order; the consumer must pop in that same
   order. So the SPLU LDU sequence (max_old, max_new, sum_old, sum_new,
   attn_old, attn_new) must be mirrored exactly by the XVU FMA pop
   sequence. Reordering on either side reads the wrong variable,
   silent (no deadlock), see §8.8.

2. **Per-variable LRF base bookkeeping.** Each `LDU` updates
   `LRF[src0] := addr` after every read (`init_decode.py:2323-2336`), so
   after a `burst_sz=N` read the base has advanced by `N × 128 B`. To
   march a base across outer iterations (or reset it), use an LRF-modify
   ISA op (`MODLRFIMM`, `SXRIMM`, …) between bursts to set the next
   starting point. The first shape sidesteps this entirely, since its six single reads
   LDUs each advance their own base by one line per inner iter, which is
   exactly the desired stride.

3. **`out_sp=3` routes the FMA result to the SPSU output FIFO**
   (`prec_sim_process.py:1499-1508, 1688-1690`), letting SPSU drain the
   computed value without a round-trip through SP. s4/s5/s6 all use it
   for the fused store of `attn_output`. (§8.7 has the full `out_sp`
   value table; s7 will use it for `sum_output` too.)

4. **One LDU pushes to exactly one FIFO.** There is no
   "broadcast to two consumers" mode: to route the same SP line to both
   XVU and VU, issue two LDUs (`ld_consumer=1` then `ld_consumer=3`).
   Each appends to its own `ofifo` in `prec_sim_process.py:780-783`.

5. **`ld_type=3` is a 16 B splat.** It triggers the splat path at
   `prec_sim_process.py:735-746`, broadcasting a single 16-byte word
   across all 8 slices of the entry. Use it when one DLF16 value must
   populate an entire SIMD vector (e.g. a splatted running max). s4/s5/s6
   use the default `ld_type=0` (full 128 B line copy) instead.


## 8. Pitfalls and non-obvious bits

### 8.1 The `burst` field bit vs the read count

The `burst` field is a single bit selecting the count *source*: when
`burst=0` the LDU does exactly one read; when `burst=1` it does
`burst_sz` reads (§3.2). It is NOT itself the read count. In our
PrimitiveAuthor records `burst=0` is the "single read" form; a batched
read is `burst=1, burst_sz=N`.

### 8.2 `burst_sz` is don't-care when `burst=0`

`init_decode.py:2300-2306`: `bs = 1` if `burst=0`, regardless of
`burst_sz`. So in our s4 SPLU record, `burst=0, burst_sz=0` is the
explicit "single read" form; the batched form is `burst=1, burst_sz=4`.

### 8.3 LRF base must be pre-decremented by stride

Every `LDU` with `src0=s0, src1=s1` computes the address as `LRF[s0] +
LRF[s1]` and **also** updates `LRF[s0] = address` after each step
(`init_decode.py:2323-2336`). So the FIRST step lands at
`LRF[s0]_initial + stride`, not at `LRF[s0]_initial`. Pre-decrement the
base by `stride` in the header LRF init. PrimitiveAuthor's s4 does this
via `sp_stage_in = sp_dest * 0x80 - stage_size`; s6's `_splu_var_base(v)
= (sp_dest + v*4) * 0x80 - stage_size` is the per-variable form.

### 8.4 Distinct FIFO sources are popped once each per unrolled iter

A `MERGE` or `FMA(src0=1, src1=2, src2=0x10)` instruction with two
*different* FIFO sources pops one entry from each FIFO per iter
(`prec_sim_process.py:1701-1708`). If `src0 == src1` (same FIFO),
only one pop happens, so both source registers see the same
peek. Useful for "two operands from the same vector," dangerous if
you forgot.

### 8.5 A single LDU can't encode more than 64 reads

`burst_sz` saturates at 64 (`init_decode.py:2306`: `bs = 64 if not
burst_sz else burst_sz`), and the field is too narrow to encode more.
For PrimitiveAuthor, if you ever need >64 staged inputs per loop body,
emit several loads, or wrap one in a loop, rather than relying on a
single record with `burst_sz>64`.

### 8.6 `splu0` and `splu1` have separate FIFOs

Per-DNC there are TWO SPLUs (`splu0`, `splu1`), one per NCore. Each has
its own pair of output FIFOs (`splu{i}_xvu{i}`, `splu{i}_vu{i}`,
`splu{i}_spsu{i}`). Cross-NCore data sharing goes through SHM, not
through the FIFO. If you need data from `splu0`'s read to land in
the second compute unit's consumer, which does not exist, since the first loader routes only to
`xvu0/vu0/spsu0`.

### 8.7 `out_sp` is XVU/VU's symmetric counterpart of `ld_consumer`

When XVU emits its result, `out_sp` (param 0..3) routes the output to
`spsu{ncore}` (= SPSU's input FIFO). Values mirror `ld_consumer`'s
encoding but on the producer side:

| `out_sp` | Meaning |
|---|---|
| `0` | no output to SP path |
| `1` | output entire src0 (passthrough) to SPSU |
| `2` | output entire src2 (passthrough) to SPSU |
| `3` | output computed result (`out_arr`) to SPSU |

See `prec_sim_process.py:1499-1508, 1613-1617, 1688-1690`. Symmetric
fields exist for `out_xvu`, `out_nbr`, `out_vu`, `out_ab`, `out_tu`.

### 8.8 FIFO ordering across multiple SPLU instructions

Pushes from a single SPLU happen in instruction order. Pushes from
`splu0` and `splu1` go to **different** FIFOs even if both target
the compute unit generically: they target one instance each, which are
distinct units. There is no merging.


## 9. Open questions

1. **Maximum FIFO depth.** `prim_random.py:840-843` references
   `PrimitiveRunState.max[f"splu0_{ld_consumer}0"]` for max FIFO
   capacity. The numeric limit (silicon-side) hasn't been read off
   yet, which matters when batching many pushes ahead of the drain.
   PrecSim itself appends without bound (Python list), but real
   silicon will stall the producer.
2. **Replenishment / back-pressure timing.** PrecSim is purely
   functional as far as the FIFO is concerned, so a push never blocks. On silicon the
   SPLU stalls if downstream is full. Our PrimitiveAuthor sims won't
   surface that class of bug.
3. **`unroll(M)` with `M > 1` and FIFO srcs on multiple operands.**
   Not yet exercised in our authored cascades. Per the source it
   should "just work" (M pops from each distinct FIFO source per
   call), but worth a targeted test before depending on it.
4. **`out_sp` of value 1 vs 2 vs 3 in PrimitiveAuthor.** s4 uses
   `out_sp=3` (computed result). Whether `out_sp=1` (passthrough src0)
   has a use in our cascades hasn't been explored.


## 10. Where to look if a future cascade deadlocks

A `PrimDeadlockError` after 60s (`prim_model.py:14`) means one unit's
the FIFO drained too few entries, so the consumer waits on a push that
never came, or the producer is waiting on a sync that never fired.

Triage steps:

1. **Count pushes vs pops** for every SPLU → XVU/VU/SPSU FIFO and every
   XVU/VU → SPSU FIFO over the full execution. Use the static
   a count taken before execution, from the instruction text, rather than a runtime trace,
   PrecSim doesn't get to deadlock-time.
   - Pushes: sum of `burst_sz` (or 1 if `burst=0`) over every LDU
     targeting that FIFO, multiplied by enclosing loop counts.
   - Pops: number of FMA/FNMS/etc. instructions with the matching FIFO
     operand, multiplied by `(url_amt+1)` and enclosing loop counts.
2. Verify the sync pairs: every send must have a matching receive and the reverse
   (`prim_analyze/instr_pkt_v2.py:300-465`). Missing pair → deadlock.
3. **Check FIFO ordering** if numerical output is wrong but no
   deadlock. Mismatched push/pop order is silent at the model level
   but produces nonsense values.

If counts match and SYNCs pair, the deadlock is probably elsewhere
(MESYNC, NCLU/NCSU descriptor, IBUFF padding).


## 11. Memory note refresh

The s6 restructuring plan was tracked in an agent-memory note (not a repo
file). The "1 push = 1 SIMD-8 vector" framing in that note should be read as
**"1 push = 1 entry = 1 full 64-DLF16 SP line"**;
the count of *entries* is correct in the plan (6 pushes / 6 pops per
iter), only the granularity description was misleading. The restructure
plan itself (Shape A in §6.1 above) stands.
