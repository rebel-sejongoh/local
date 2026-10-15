# Authoring cheat-sheet: pointers into the sources, carrying no new facts

A quick reference for hand-authoring a DNC kernel. Every line here is **already**
specified in the family files or computable from the `dnckit` codec. This page only
*surfaces* the facts that are easy to miss, with the source pointer. It introduces no
new ISA fact (those live in the families docs; the encoder applies the mechanical ones).

## Streaming granularity  (`families_operational.md` SPLU/SPSU/NCLU/NCSU §in-ports/extent)
- Move data **one 128 B line (= 64 dlf16 slots) per beat**; wrap the mover body in
  `MVLOOPCNT(num_lines)`.
- **NC-face multi-chunk (`NCLU.LDMU` / `NCSU.STMU`, >31 lines):** the `burst` field is
  5-bit (max 31; `burst=32`→`0`→NC default 32), but the burst advance **persists across
  instructions**, so to load more than 31 contiguous lines emit back-to-back loads within the limit,
  (one per chunk) and they auto-continue contiguously, **no register-op between them**. Keep
  each leaving the source fields at zero, since those fields pick the descriptor's bank entry rather than a
  chunk index. Setting one to the chunk index
  reads an empty entry (= SHM line 0). `ADD{C,S}XRIMM` is for **strided/jump** access only
  (it over-advances a contiguous chain). (`families_data.md` §Address model.)
- **SP-face advance (`SPLU.LDU` / `SPSU.STU`):** the pointer advances per beat by a
  stride register the second source field selects, and it increments before the access rather than after.
  does `LRF[ptr] += LRF[stride]` *then* accesses `SP[LRF[ptr]]`, so the first beat lands on
  `seed + stride`, **not** `seed`. To sweep K consecutive lines starting at `line0`: seed
  `ptr = sp_ld_base(line0)` (= `sp_addr(line0 - 1)`; `sp_st_base` for `STU`), `stride = 0x80`
  (one line), `MVLOOPCNT(K)`. A raw `sp_addr(line0)` silently **skips `line0`** (first access is
  one line high, which is the common off-by-one.
  **The sweep comes from the stride and not from the burst.** With a
  0/unset stride all K beats re-read the *same* line ("pinned"). Re-streaming a window N times
  needs **N distinct pointer regs** (each advances only its own). (D2.)
- **NC-face advance (`LDMU`/`STMU`):** auto-advances by `burst` consecutive lines (one
  `nc_desc`); `burst ≤ 31` (D1).
- Beat count rule: `burst=0 → size 1`; `burst=1 → size = burst_sz (or 64 if 0)`
  (`instr_pkt_v2.py:545-551`). A mis-sized burst silently yields zeros, since there is no
  error, the output is just wrong. Stream per line until you have a reason not to.
- **NC `burst` is 5-bit (max 31)** (`bitpos_dict['NC']['burst']=[26,22]`). It's masked to
  those bits and a decoded 0 = the NC default 32, so `burst=128` moves `128&0x1f=0→32`
  lines (not 128, no error). To move >31 lines, split into multiple `LDMU`/`STMU` each
  each within the limit. `dnckit.authoring.nc_burst_chunks` returns the chunk sizes.

## Constants into compute  (`families_data.md` D7/§VU.FMA; codec `dlfloat16.codec`)
- Compute ops take **no literal operand**; `src1/src2` select `const_reg`/`LRF`, not an
  immediate (`⟦VU.FMA⟧: (select(src0)⊗select(src1))⊕select(src2)`).
- So stage a constant in an LRF first, then reference that LRF index as an FMA source.
  Use `dnckit.authoring.const_lrf`, which encodes the float through the
  dlf16 codec (don't hardcode `0x3E00`) **and** sets `replica=1` so the constant
  broadcasts to all 8 lanes. With `replica=0` the constant lands in lane 0 only and the
  other lanes read garbage (the canonical IMMCOPY trap two agents hit).

## Feeding two operands through the single SPLU FIFO
- A compute unit reads streamed operands from FIFO source classes (VU: `{splu, tu, xvu}`,
  XVU: `{splu, vu}`); its other operands come from registers (`LRF`/`const_reg`), **not**
  a FIFO. There is exactly **one `splu{ncore}` feeder FIFO** per compute unit.
- ⇒ A binary elementwise op fed **only from SP** has no second SPLU stream, so it must
  **interleave**: the SPLU loop pops one A-line then one B-line per iteration into the one
  FIFO (`a0,b0,a1,b1,…`), and the compute body pops twice per iteration (capture A into an
  LRF, then combine with B). (This is composition guidance, not an ISA primitive.)
- **The `splu` pop is deduped by src-class** (`families_operational.md:425`: "a src FIFO is
  popped only if its class differs from the lower src's class"). So **one** FMA with
  `src0=src2=splu` pops the FIFO **once** → you get `A+A`, not `A+B`. A binary op therefore
  needs **two separate FMAs** popping in sequence: `FMA(splu,1,0)→LRF` (pops A), then
  `FMA(splu,1,LRF)→out` (pops B). This is the trap that stalled the cold-start agent.

## Scratchpad addressing: the NC face against the SP face
- NC units (`nc_desc(shm_line, sp_line)`) name SP by **line index** directly.
- SP units (SPLU/SPSU) hold an SP **byte address = line · 0x80** in their pointer LRF.
  Seeding a raw line index reads zeros. Use `dnckit.authoring.sp_addr(line)`.
- **Pre-increment seed:** a *streamed* `LDU`/`STU` pointer advances by the stride **before** the
  first access, so to start a sweep on a line, seed it one line below with `sp_ld_base` or
  `sp_st_base(line)` (= `sp_addr(line-1)`). A raw `sp_addr(line)` skips the first line.

## SYNC handshake  (`families_control.md` C2; encoder `sync_imm`)
- The SYNC immediate is a **bitmask** (bit0=SEND/put, bit1=RECV/get, bits2-7=peer), not a
  token id. A put increments `{self}_{peer}_sync`, and a get decrements `{peer}_{self}_sync`.
- **A consumer must take its gets on one channel in the order of the edges' puts.** Every
  edge from one unit to one peer uses the same channel, and its counter pairs the k-th get
  with the k-th put. In a different order, a get can proceed before the put it was meant
  for, and PrecSim does not report an error. Build the immediate with
  `dnckit.authoring.sync_imm(send=, recv=, peers=[...])`, not hand-packed bits.
- A single-pipeline kernel has four edges: NCLU→SPLU (load-done), SPLU↔SPSU (implicit FIFO
  backpressure and no sync), and the drain-done edge from the SPSU to the NCSU, each with its wait leg.

## Loops & drains  (`families_control.md` C6; `families_data.md` D7)
- `MVLOOPCNT(n)` then the body; the body's **last** instruction carries `be=1` (the
  branch-end back edge, and every earlier one clears it. A RETURN runs with the loop retired,
  pad the block tail with `RETURN`s (`Program.pad_return`).
- Route an FMA result with the `out_*` **data_type** selector: `out_sp=3` drains the
  **computed** result to SP; `1`/`2` are forward/passthrough; `0` = channel off.
- **In a reduction, accumulate inside the loop and drain once afterwards.** A running accumulator (a sum through
  `FMA(x,1,acc)→acc`; max via `FMINMAX(acc,0x0,x)→acc`, `src1=0x0`=max) is correct only at the
  *last* beat. Do **not** drain it every beat: draining each beat then overwriting one SP line
  does **not** keep the last value (the collection keeps a *partial*), so the result is wrong.
  Loop the fold with `out_sp=0`, then **after** `MVLOOPCNT` emit one drain (`FMA(acc,1,0,…,
  out_sp=3)`). If a drain on every beat seems necessary, isolate-test the collection first, since it
  won't do what "last write wins" suggests.)

## Driving both NCores of a DNC
- A DNC has 2 NCores. SPLU/SPSU/VU/XVU/TU/AB are **per-NCore** (×2); **NCLU/NCSU are
  shared by the DNC, with one instance and no NCore index. One bit of the unit id selects the second NCore,
  `dnckit.authoring.with_multi_tile(block)`; it **raises** on NCLU/NCSU (they can't carry it).
- **The fork-and-join recipe:** emit each per-NCore pipeline twice, the first copy plain and the
  NCore-1 copy via `with_multi_tile`, on **disjoint SP/SHM regions**. One shared NCLU loads
  both halves and fans load-done to `splu0` *and* `splu1` (`sync_imm(send=True,
  peers=["splu0"])` + `…["splu1"]`); one shared NCSU gathers `spsu0` *and* `spsu1`. No
  sync across the NCores, so the two pipelines run freely between the fork and the join.
- **Footgun (column order):** two blocks of the same unit type share an init2vec column and
  are stacked in `blocks`-list order. Empirically the **NCore-1 (`0x100`) block must be
  emitted before** its NCore-0 sibling in the list, or NCore 0 silently zeros out. (Root
  cause = init2vec column parse × the bit-93 modify pass, `init_decode.py:276`; not yet a
  clean encoder fix, because reordering could disturb existing matmul kernels, so for now
  order the `0x100` block first by hand.)
- **TU = 8 blocks, one per row, placed in columns 0..7 (not 1, not stacked).** The systolic
  MAC is **8 TU blocks per NCore**, all `target_unit=0x81` (`|0x100` for NCore-1), each placed
  in a distinct column, through `with_col`, one per row index from 0 to 7. The column index
  selects the row (`dnc_enc.py:207` → `dnc_init.py:451` `TU{nc}_{col_idx}`). `target_unit` has
  no row field, and stacking order does not select the row, so putting all 8 in one column
  (e.g. the default `COL[TU_UID]`) collapses them onto `tu{nc}:0`, deletes rows 1..7, and the
  run **deadlocks (exit 44)** because the col-7→VU drain is unreachable (ruled out empirically:
  order/byte-distinctness/SPR/header-fill all irrelevant; only the column moves a block to
  another row). **All 8 columns required**; drain is row 7 only (`tgts>0` forwards south, col-7
  → VU, families_data §D6). Independent of M/N/K (K-depth is in MVLOOPCNT, not row count), so a
  a single-tile contraction still needs all 8 row blocks in 8 columns. The ABLU is the opposite case, below.
  See program_lifecycle §A2.
- **TU feeds: north is row-0-only, west is 8-wide & mandatory.** A TU FMA src resolves to a
  *channel* by its src-class (families_data §D6a): **W (west)** → the paired `ablu{nc}:{row}`
  fed by the single ABLU block at column 1, since `dnc_init.py:414/423` forces `is_ablu ⇒
  col_idx==1`, so there is exactly ONE ABLU block whose 8 row-engines `ablu{nc}:0..7` fan to
  the 8 TU rows. Do **NOT** place 8 ABLU blocks in cols 0..7 like TU (that hits the col-1
  assert → exit 10); ABLU is staged `XVU→ABSU→σ.AB→ABLU`. **N (north)** → `xvu`
  for **row 0 only**, else the previous row's `tu:row-1_south` (the systolic chain). Feeding
  XVU once does not propagate through all 8, since rows 1 to 7 read the south forward.
  A west-source read with no paired ABLU producing deadlocks, which PrecSim reports as exit 44, so a working MAC must
  wire BOTH the north feed (XVU→row 0 + south chain) AND the 8-wide ABLU west feed.
