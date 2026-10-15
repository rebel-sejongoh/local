# The microcode image: a reference for its binary format

**What this is.** `init.bin` is the static microcode image a DNC executes: one
per-unit *program* for every compute/data-mover unit, for every DNC. This doc is
the bit-level reference for its layout on disk: the flit grid, the per-block
flit-section run, the block-dict schema the toolchain decodes it into, and the
exact header bitfields.

**Where it sits.** [`dnc-programming-guide.md`](../../PrimitiveAuthor/docs/dnc-programming-guide.md) §1.5
introduces the format conceptually (what a block *is*, the ISA, loops); this doc
is the **format SSOT** it defers to. For *instruction meaning* (FMA operand roles, the psum
chain), see [`dnc-isa-interpreted.md`](dnc-isa-interpreted.md). For how the matmul
generator *produces* these blocks and lays them out, see
[`matmul-template-design.md`](../../PrimitiveAuthor/docs/matmul-template-design.md).

---

## 1. The flit grid: lines × 8 columns

The granule is a flit, which is one 128-bit word of 16 bytes, stored
little-endian.

The image is a grid of **lines × 8 columns**:

- A column, one of eight. Each column
  belongs to one unit type. The fixed column map:

  | col | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
  |---|---|---|---|---|---|---|---|---|
  | unit | ABSU | ABLU | SPSU | SPLU | VU | XVU | NCSU | NCLU |

  The TU is the NCore's systolic array and spans all eight columns, one row per column, so
  its column cannot be inferred from the header and is forwarded explicitly during
  decode.

- A line, one row of the grid, which is 128 bytes over eight columns. The image is
  serialized line-by-line, column 0..7 within each line:

  ```python
  for li in range(n_lines):
      for c in range(8):
          out += col_lines[c].get(li, 0).to_bytes(16, "little")
  ```

This 128 B is also the hardware memory granule: one SHM/SP line = 128 B = 64
DLF16 values = exactly one 64-lane VU/XVU register
(`../../PrimitiveAuthor/docs/dnc-programming-guide.md` §1.3). The image geometry and the data geometry are
the same unit.

A unit's flits **stack down its own column** at consecutive lines; columns shorter
than the tallest are zero-padded (e.g. matmul aligns the TU section across all 8
columns, leaving the other columns zero-filled up to where the TU starts).

---

## 2. A block = one unit's flit run

One unit's program is a **block**: a contiguous run of flits down its column, in a
fixed section order:

| order | section | count field | holds |
|---|---|---|---|
| `line+0` | the header | one flit | the target unit id, the section counts and the register index map |
| `line+1` | the mode register | one flit | the mode bits, which set saturation and rounding on the compute units and do nothing on a mover |
| `line+2 …` | **LCCR** | `n_lccr` | constant-register seeds (compute units only) |
| the next run | the register file | as many as declared | the register seeds. On an NC unit these are address descriptors and on a compute unit they are working values |
| ` …` | **IBUFF** | `n_ib` | the instructions (NC/SP/AB/TU: 4 instr × 32 b per flit; VU/XVU: 2 × 64 b) |

The next block in the column starts at `line + 1 + n_lccr + n_lrf + n_ib + 1`
(the two extra flits are the header and the mode register).

### 2.1 The block-dict schema

`walk_flits` decodes each block into a dict; the
generator's `block_for` produces the same shape and `gen_flits`/`build_init_bytes`
serialize it back, **round-trip byte-exact**:

| key | type | meaning |
|---|---|---|
| `hdr` | `int` (128-bit) | the raw header flit, bit-packed (§3) |
| `unit_id` | `int` | one-hot target-unit mask = `hdr[95:85]` |
| `unit` | `str` | resolved unit name, e.g. `"NCLU0"` |
| `spr` | `int` | the SPR/mode flit |
| `lccr_raw` | `list[int]` | constant-pool flits (`n_lccr` of them) |
| `lrf_raw` | `list[int]` | the register seed flits: address descriptors on an NC unit and working values on a compute unit |
| `lrf_idx` | `list[int]` | per-LRF 4-bit index, one per LRF flit (from the header) |
| `ib_raw` | `list[int]` | raw IBUFF flits (`n_ib`) |
| `instr_recs` | `list[dict]` | decoded instructions, one per IBUFF slot incl. NOP padding (§4) |
| `n_ib` | `int` | IBUFF flit count |
| `col`, `line` | `int` | placement in the grid (`col` fixed by unit; `line` = block start) |

> Note: `hdr` is a packed **integer**, not a sub-dict. Its fields are read/written
> by bit position (§3), never as named dict keys.

---

## 3. The header (`hdr`) bitfields

All fields are extracted with `bit_acc(hdr, [hi, lo])`:

| field | bits | meaning |
|---|---|---|
| `target_unit_mask` (`unit_id`) | `[95:85]` | which physical unit runs this block (one-hot) |
| `n_ib` | `[84:78]` | number of IBUFF (instruction) flits |
| `n_lrf` | `[77:73]` | number of LRF flits |
| `n_lccr` | `[72:71]` | number of LCCR flits |
| `lrf_idx[i]` | `[4i+3 : 4i]` | 4-bit LRF index, one per LRF flit (`i in range(n_lrf)`) |
| the group flag | `1 << 93` | set on the compute units and the AB pair when a tile spans more than one row group |

A header whose target mask is zero marks a null slice, so that column has no block on
this line and is skipped. This is how shorter columns
read as zero-padding.

So the header is the block's self-description: it tells the decoder how many flits
of each section follow, so block boundaries are recoverable without external
metadata.

---

## 4. Instructions (`instr_recs`)

Each IBUFF flit packs `npi` instructions of `iw` bits each (per-unit, from
the size table: the movers and the TU take four 32-bit fields and the compute units two 64-bit
ones). Every slot, including trailing NOP padding, decodes to one record.

A record:

| key | meaning |
|---|---|
| `opcode` | mnemonic string (e.g. `FMA`, `MVLOOPCNT`, `LDMU`) |
| `opc` | numeric opcode |
| `params` | unit/opcode-specific field dict (`src0/src1/src2`, `typ1_imm`, `run_mode`, `out_*`, `lrf_tgt`, `slice_en`, `be`, …) |
| `fill` | the bits the emitter set outside the known opcode and parameter mask, reproduced byte for byte so that the codec round-trips |
| `known` | whether the opcode is in the ISA's `param_dict` |

**Opcode families** (`../../PrimitiveAuthor/docs/dnc-programming-guide.md` §1.5): movers carry
`LDMU/STMU/LDU/STU/CARREGCOPY/SXRIMM/IMMCOPY/MODLRFIMM/SYNC/MESYNC`; compute carry
`FMA/FNMS/FEST/EE/IME/LOGICAL/SHR/REDUCE/SELECT/…`. Operand tags: `0x0`=const-0,
`0x1`=SPLU FIFO, `0x10..0x1F`=LRF[0..15].

### 4.1 The FMA, which is the TU's MAC, whose operand roles do not follow the field order

From [`dnc-isa-interpreted.md`](dnc-isa-interpreted.md) §2 (derived from the ISA
wiring, not field names):

| field | role | values |
|---|---|---|
| `src0` | the first multiplicand | reads four consecutive registers, which are four consecutive values along the contraction |
| `src2` | multiplicand **B** | `0x2` = west (the streamed/broadcast B) |
| `src1` | the accumulator | a fresh zero on row 0, or the north neighbour's partial on the rest. This selector is the systolic chain |
| `run_mode` | products per FMA | `2` ⇒ 4 products (two FMAs ⇒ 8 K's, the 4+4 quad-MAC) |
| `tgts` | drain target | `3` = drain south (row→row; at row 7 round FP24→dlf16 once) |

### 4.2 Loops

`MVLOOPCNT` sets a trip count; the loop body's last instruction sets `be=1` to
close it. The count is a **static immediate** (`typ1_imm`) or **dynamic from JCR**
reading a runtime register. On silicon the loop nest must balance to zero, with every
push matched by a close (PrecSim is lenient and will not catch an imbalance,
`../../PrimitiveAuthor/docs/dnc-programming-guide.md` §1.5).

---

## 5. LRF semantics (NC vs compute)

The `lrf_raw` flits mean different things by unit class:

- On an NC unit the register file encodes address descriptors
  (`CAR`/`CBR`, etc.), generated per-DNC as an affine stride
  `base + rows_per_dnc · dnc` (`dnc-isa-interpreted.md` §5). This is how 16 DNCs
  each read their own slice from one contiguous DMA: the stride is baked into each
  DNC's own descriptor.
- On a compute unit it holds working values, such as the range-reduction
  constants, initial accumulators), initialized via `IMMCOPY` or an LCCR pool.

The `lrf_idx[]` map in the header indexes these flits into named LRF slots.

---

## 6. Assemble & decode

| function | direction | does |
|---|---|---|
| `walk_flits(memlines)` | bytes → blocks | parse the flit container column-major, decode each block to the §2.1 dict |
| `gen_flits(block, stats)` | block → flits | re-encode one block to its flit list: header, SPR, LCCR[], LRF[], IBUFF[] |
| `build_init_bytes(blocks)` | blocks → bytes | lay each block's flits into its column, assemble 128 B lines; returns `(init_bytes, n_lines, coverage_stats)` |

`build_init_bytes` has two modes: if **every** block carries
an absolute `line` (blocks from `walk_flits`, or from the generator's
`derive_slots`), the flits land at that line and any gap between blocks is zero-filled,
faithfully reproducing TU-aligned layouts. Otherwise blocks stack densely per
column (the legacy authored path).

---

## 7. The generator layer: block / slot / context, and the layout terms

`init.bin` is *flits*; the matmul generator adds a
vocabulary on top. The three core nouns first, then the layout terms
(`derive_slots`):

- A block is the bytes for one unit in one DNC's band, meaning one header, one mode register and
  LCCR/LRF/IBUFF flit run (§2), as the §2.1 dict. The emitter `block_for(slot,
  ctx)` produces it; `build_init_bytes` serializes it into the column. "What to
  compute" (`instr_recs`) + "how the unit is set up" (`hdr`/`lrf_raw`) = a block.
- A slot is where a block goes: the placement record naming the unit, the position, the line, the column and
  the target length. `derive_slots` produces that list, which is the image's skeleton,
  and `build_image` fills each by calling `block_for(slot, ctx)`. So slot = the
  address in the grid, block = the bytes that land there. (`target_len` is the
  per-DNC-uniform instruction count for the `uniform` units, below.)
- The context is the address scalars `prep` reads from
  `initgen_args.json` (the contract, §5), threaded into every `block_for` call so
  descriptor addresses come out as real numbers. M-split → `{nclu0, ncsu0,
  sp_addrs}` (the dnc0 bases); k256 / m128n128 → `{}` (their addresses are baked
  into the emitters). This is the only filesystem input on the generation path.

The pipeline ties them together: prepare the context, then derive the slots,
[slot…]`, then per slot `block_for(slot, ctx) → block`, then `build_init_bytes`.

The positional terms `derive_slots` works in:

- The line and the column are a block's grid coordinate from section 1. The unit fixes the column and the line
  is its flit-run start.
- A band is one DNC's horizontal strip of blocks, so 16 DNCs give 16 bands stacked
  down the image. Each DNC bakes `shm_base + stride·dnc` into its own NC
  descriptor, so the 16 programs are a uniform-stride concatenation
  (`../../PrimitiveAuthor/docs/dnc-programming-guide.md` §4.4).
- A section, in the layout sense, is a run of bands sharing one inventory and one TU flag.
  (This is a different sense of the word from section 2's, which is a run of flits.) It is
  what the `sections` recipe field (below) declares.

So: **`instr_recs` (what to compute) + `hdr`/`lrf_raw` (how the unit is set up) = a
block; blocks placed at `(line, col)` = a band; 16 bands × sections = the image.**

### 7.1 The emit recipe, one per family

`make_emit_recipe(dims, tiling)` classifies a shape into one of three families and
returns an `EmitRecipe`: the complete, **dump-free** description `generate_dense`
consumes. Two callables say *how to emit*; three descriptors say *how to lay out*;
one is a label. For *how* the fields are derived
from `(dims, tiling)` and *why*, see
[`matmul-template-design.md`](../../PrimitiveAuthor/docs/matmul-template-design.md) §3f.

| field | type | role |
|---|---|---|
| `name` | `str` | a display label alone, not a path. The verifier prints it and the routing checks match on it. |
| `block_for` | `(slot, ctx) → block` | the emitter. It returns one unit's block for a slot, with the addresses resolved from the context, and it is pure, opening no dump. This is where the families differ, one routing through the dense builder and the others through the per-unit emitters. |
| `prep` | `(initgen_dir) → ctx` | Reads `initgen_args.json` (the contract, §5) → the address scalars (`ctx`). M-split derives `{nclu0, ncsu0, sp_addrs}`; the dense families use the default no-op `{}`. The only filesystem touch. |
| `inv` | `{unit: npass}` or `None` | the inventory: how many blocks of each unit stack in one band's column, so a two-pass scratchpad stage gives two of each SP unit while the atom shape gives one of everything. It is unset only on the older decoded path, and every live regime sets it, so the layout is derived rather than decoded. |
| `uniform` | `set[unit]` or `None` | Units whose 16 per-DNC programs must be **padded to one length**: NCLU/NCSU differ in `n_ib` per DNC, but the grid must stay rectangular, so `derive_slots` pads all 16 to the max natural `len(instr_recs)` (the slot's `target_len`). |
| `sections` | `list[{n_bands, inv, tu}]` or `None` | **Multi-section layout.** `None` → one 16-band TU section built from `inv` (64³ / k256 / M-split). m128n128 sets two: the TU main band + a no-TU 2nd-tile/preload band `{SPSU:2, SPLU:2, XVU:2, NCSU:1, NCLU:1}`. |

---

## 8. See also

- section 1 of [`dnc-programming-guide.md`](../../PrimitiveAuthor/docs/dnc-programming-guide.md): the units, the ISA
  how a kernel runs (the conceptual on-ramp).
- [`dnc-isa-interpreted.md`](dnc-isa-interpreted.md): what each instruction means
  (FMA operand routing, the psum chain, the MESYNC barrier).
- [`matmul-template-design.md`](../../PrimitiveAuthor/docs/matmul-template-design.md): how the matmul
  generator emits and lays out these blocks.
