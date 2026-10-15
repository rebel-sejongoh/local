# The reduction & mask-substitution contract (FMINMAX / REDUCE / mask)

> **Note on the `examples/` and `tools/` citations below.** Those trees were removed in `759ef3b0`,
> which replaced the example-per-algorithm approach with the `mcc` compiler. The file-and-line pointers
> in this document are therefore historical: they resolve against the repository before that commit
> (`git show 759ef3b0^:PrimitiveAuthor/<path>`), not against the working tree. The method they
> illustrate is unchanged, which is why they are kept rather than deleted.

Verified deep-dive into how the `flash_attn_tile` reduction (`max_K`, `sum_K`)
and its masking by substitution are realized in DNC microcode. It was written while
authoring `PrimitiveAuthor/examples/flash_attn_tiling/` *(deleted)*
from scratch (no compiler-emitted `compute_54` scaffold).

Companion to [`splu_xvu_fifo_contract.md`](splu_xvu_fifo_contract.md): that doc
covers how data *moves* (SPLU↔XVU/VU FIFO); this one covers what the XVU/VU
*compute* once the K-axis data is staged.

Every claim cites `third_party/rebel_prec_sim/` or the DNC ISA spec
(`lib.dnc_isa` / `lib.dnc_isa_api_util`). Nothing here is read from the conan
the silicon primitive headers or from a compiled binary, so the
purity constraint the method sets.


## TL;DR

| Question | Answer |
|---|---|
| How is the reduction over the streamed axis done? | Two ways. Accumulating a line at a time, one comparator or FMA per staged line, elementwise, which the tiling experiment uses. Or the reduce op, which folds the 8 lanes of one register through a neighbour-forward tree, which the production primitive uses to pack the axis across lanes. |
| Which is simpler to author from the public ISA? | Accumulating a line at a time, being repeated comparators or FMAs, identical in shape to a plain cascade. The reduce op is an 8-deep forwarding tree with a forced unroll and is awkward to drive by hand. |
| Is `REDUCE` required? | No. It is an **8×-fewer-lines optimization** (K packed across lanes). line-accumulate is functionally identical. |
| How does FMINMAX pick max? | `FMINMAX(src0=A, src1=imm, src2=B)` = `fminmax(imm, A, B)`; **`imm=0` returns the greater** (max). `fpu.cpp:1006`. |
| How is the mask applied? | Either the hardware `SELECT`/`FCMP`/`cmp_flag` path, **or** arithmetically: `masked = score − (1−mask)·BIG`. The from-scratch work uses the arithmetic form and no select. |


## 1. The comparator op

`FMINMAX` is an XVU/VU op with the data operands in **`src0` and `src2`** and a
**mode immediate in `src1`** (`prec_sim_process.py` binds `in_x=src0_data`,
`in_z=src2_data`; the sim calls `FPU::fminmax(imm=src1, in_x, in_z)`).

Modes, from `src/fpu/fpu.cpp:1006-1062`:

| `src1` (imm) | semantics |
|:--:|---|
| `0x0` | compare `>` on **value**, return the greater → **MAX** |
| `0x1` | compare `>` on `abs`, return the (signed) greater-abs |
| `0x2` | compare `>` on `abs`, return `abs` of greater |
| `0x3` | compare `>` on value, return `neg` of greater |
| `0x4` | compare `<=` on value, return the lesser → **MIN** |
| `0x5` | compare `<=` on `abs`, return the (signed) lesser-abs |
| `0x6` | compare `<=` on `abs`, return `abs` of lesser |
| `0x7` | compare `<=` on `abs`, return `abs` of lesser with `sign0` |

So a running **max** over K is `FMINMAX(MAXACC, 0x0, CUR → MAXACC)`, seeded with
`MAXACC = −∞` (DLF16 `0xFFFE`).


## 2. The first option: accumulate a line at a time, which is the from-scratch baseline

Lay the tile so **rows map to the 8 SIMD slices** and **K maps to staged lines**
(one SHM line per K-position, each broadcasting row `r`'s value across slice
the register's 8 lanes, through `authoring.shm_line_vec`. Then a running reduction is one
accumulate op per line:

```
MAXACC = −∞
for each K-line:  CUR = pop(fifo);  MAXACC = FMINMAX_max(MAXACC, CUR)   # max over K
SUMACC = 0
for each K-line:  E = exp(...);     SUMACC = FMA(E, 1, SUMACC)          # sum over K
```

After the loop, slice `r` holds `reduce_K(row r)`. **No `REDUCE` op, no
neighbour-forward, no `url` games.** Push/pop balance is the ordinary FIFO
contract (`splu_xvu_fifo_contract.md`): K pushes from SPLU, K pops on the XVU
FMINMAX/FMA. This is what `flash_attn_tiling/s4`–`s7` use; it runs
bit-exact on PrecSim.

Cost: one staged line per K-position (vs 8 K-values per line if packed across
lanes), and at a large extent that is more lines, which is what motivates the second option.


## 3. The second option: the reduce op, which packs across lanes

`REDUCE` folds the **8 lanes of one register** into lane 0, so K can be packed
8-per-line. It is genuinely intricate; documented here so the line-accumulate
choice is an informed one, not an ignorant one.

### 3.1 `reduce_imm` encoding

From `lib.dnc_isa_api_util.xvvu_reduce` (`:595`):

```python
reduce_imm = (rsm_tgt << 13) | (rsm_url_deg << 10) | (rsm_opcode << 5) | rsm_src
```

`rsm_opcode` selects the fold op (`dnc_isa_api_util:93-103`):
`RSM_FMA=0x1`, `RSM_PACK_0=0x4`, `RSM_PACK_1=0x5`, `RSM_FMINMAX_8..F = 0x8..0xF`
(→ `FMINMAX` with `src1 = rsm_opcode − 0x8`, so `RSM_FMINMAX_8` = max),
`RSM_SELECT=0x10`, `RSM_FMUL=0x14`, `RSM_LOGICAL_*`.

### 3.2 What `reduce_payload` does (`prec_sim_process.py:1334-1390`)

On opcode `REDUCE` the unit unpacks `reduce_imm` into
`rsm_src/rsm_opc/rsm_url/rsm_tgt`, then sets `src0=rsm_src`, `src2=SRC_NBR`,
`lrf_tgt=rsm_tgt`, and **forces `url = 0b100111`** (the `rsm_url` field is read
but not used to drive the loop). The resolved op is `FMA`/`FMINMAX`/… per
`rsm_opc`.

### 3.3 Neighbour-forward (`make_nfwd`, `:1393-1417`)

The `src2=SRC_NBR` operand resolves to `make_nfwd(2, ctx.lrf[lrf_tgt])` for
the comparator (`:1577-1579`) or a zero one for the FMA (`:1539-1541`), so the
op reads a **lane-shuffled copy of its own target register**. The shuffle maps
(per slice) output lane `j` ← input lane `NFWD_MAP[src][j]`:

```
NFWD_MAP[0] = [2,3,0,1,6,7,6,7]   # FMA reduce  (sum)
NFWD_MAP[2] = [4,5,3,3,5,5,6,7]   # FMINMAX reduce (max)
```

Combined with the forced `url` (`url_amt = url & 0b11 = 3`; `url_s0/url_s2/
the unroll targets set so that source and target advance per step, at `:1486-1490`) and the
per-op unroll count `amt = pkt.size = 2**(url & 3) = 8` (`constr_xvu.py:543`),
the op performs a multi-step in-register fold across the 8 lanes.

### 3.4 The canonical driver

`rebel_hw_util/tools/verif_prim/xvvu_reduce_test/ncore_xvvu_reduce_test.py` is
the reference: it populates a stick of registers from the FIFO, then calls
`xvvu_reduce(unit, rsm_tgt, rsm_url_deg, rsm_opcode, rsm_src, …)`. If you ever
need the lane-packing form, mirror that rather than hand-rolling the unroll and forwarding plumbing.


## 4. Mask-by-substitution without SELECT

`flash_attn_tile` applies `masked = where(mask != 0, score, MASK_VALUE)`
(`silicon_models.flash_attn_tiling.apply_mask_numpy`; `MASK_VALUE ≈ −8.58e9`).
Two ways to realize it:

### 4.1 Hardware path

`FCMP` (compare mask vs 0) sets `ctx.cmp_flag` per slice/lane; `SELECT` then
picks `src0` or `src2` by that flag. compute_54 does this; the surviving
op-mirror of that path is `flash_attn_tiling/s2_op_mirror.py` (the `SELECT`
mask-by-substitution branch).

### 4.2 Arithmetic path (what `flash_attn_tiling` uses)

No `cmp_flag` state needed:

```
OM     = FNMS(mask, 1, 1) = 1 − mask          # mask ∈ {0,1}  → OM ∈ {0,1}, exact
masked = FMA(OM, −BIG, score) = score − (1−mask)·BIG     # BIG = 1e4
```

- A kept lane multiplies the large negative constant by zero and adds nothing, so the score is exact with no
  rounding.
- A masked lane lands near minus ten thousand, which never wins the running maximum, and
  `exp(c·(−1e4 − max))` underflows to DLF16 `0x0000`. Identical *outputs* to the
  `MASK_VALUE` substitution.

**Why not a large additive sentinel directly** (`masked = mask ? score :
SENTINEL` via `SENTINEL + mask·(score − SENTINEL)`): with `SENTINEL = −1e4`,
`score − SENTINEL ≈ 1e4` rounds away `score`'s small magnitude in DLF16, then
adding the sentinel cancels catastrophically and the kept lanes come out wrong. The
multiply-add `score − (1−mask)·BIG` form avoids this because the kept-lane path
multiplies `BIG` by **exactly 0**.


## 5. Pitfalls

### 5.1 NC `LDMU`/`STMU` burst is 5-bit

`bitpos_dict['NC']['burst'] = [26, 22]` → max 31. A single-burst mover therefore
caps the per-DNC line count at 31; larger counts must chunk the burst into a
`MVLOOPCNT` loop (see the reference `xvvu_reduce_test` NCLU:
`with nclu.mvloopcnt(...): ldmu(burst=0)`). `flash_attn_tiling` caps
K at 15 (`N_IN = 2K ≤ 31`) for single-burst simplicity.

### 5.2 SHM input/output regions share one SHM across all DNCs

A 16-DNC run lays every DNC's input and output lines in the *same* SHM. The
input span `[shm_in_base, +in_stride·16)` must not overlap
`[shm_out_base, +out_stride·16)`, or one DNC's output overwrites another's input
mid-run (observed as ~7/16 DNCs failing). Keep `shm_out_base` clear of the input
span (`flash_attn_tiling/s5._TILE_PLAN`).

### 5.3 The exp pre-scale constant

`exp(x)` is `ICVT` mode-7 (`fast_exp`) of `c·x` with `c = 2^11/ln2`, DLF16-rounded
to `0x54E3` (`precsim_ops.SCALE`). The pre-subtract is done in DLF16 FNMS/FMA
(`y = FMA(score, c, FNMS(max, c, 0)) = c·(score − max)`), matching the silicon
rounding path; see the mirror module's exponential for the
bit-exact derivation and `splu_xvu_fifo_contract.md` for how the result is
drained.

### 5.4 Masked lanes and the running max

The arithmetic mask (§4.2) leaves masked lanes at `≈ −1e4`, which is below any
real score but **not** `−∞`. That is fine for `max_K` as long as ≥1 lane per row
is kept (the fixtures force `mask[:,0]=1`); a fully-masked row would reduce to
`≈ −1e4` rather than the spec's `MASK_VALUE`. Seed `MAXACC = −∞` (`0xFFFE`) so an
all-masked row still produces a defined (very negative) max rather than garbage.


## 6. Where this is exercised

- `PrimitiveAuthor/examples/flash_attn_tiling/s4_max_reduce_dnc.py` *(deleted)*
  covers the line-accumulated maximum of section 2, on a single DNC under PrecSim.
- `PrimitiveAuthor/examples/flash_attn_tiling/s5_full_cascade_dnc.py` *(deleted)*
  covers the max, exponential and sum of section 2 and the exponential chain of section 5.3.
- `PrimitiveAuthor/examples/flash_attn_tiling/s7_real_tile.py` *(deleted)*
  covers the arithmetic mask of section 4.2 on a full 16-DNC tile.
- The production primitive covers the lane packing of section 3 and
  §4.1 `SELECT` mask, for contrast.
