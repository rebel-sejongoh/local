# mcc IRs from the kpl declaration down to JIR

- Base: `codesigner` `origin/dev` at `b13b33393` (2026-10-23). Paths are relative to `PrimitiveAuthor/mcc/src/mcc/`
  unless they start with `tests/`, which is `PrimitiveAuthor/mcc/tests/`.
- Method: four perf cases were built with spies on the `spine` passes and every level was printed.
  - `tests/perf/add_elementwise/1x16x2x64`: streaming, 16 DNCs.
  - `tests/perf/rms_norm/r1_k2048`: streaming reduce followed by a second pass, 1 DNC.
  - `tests/perf/dense/m128_k64_n64`: systolic, 16 DNCs (shows `mseq_matmul`).
  - `tests/perf/dense/m4_k256_n64` (Llama `down_proj`): systolic with a K split over 4 DNCs, so it shows the cross-DNC
    `Reduce`. Built with `reduce.py`.
  - `mcc-ir-dump/dense_scale_kernel.py`: `(x @ w) * 0.125` at M=128, K=64, N=64, the dense case of 3.3 with a scale
    after the contraction, so the build has an epilogue on the VU. Built with `matmul.py`.
- The scripts and full dumps are in [`mcc-ir-dump/`](mcc-ir-dump/).
  - `dump.py` wraps the `spine` functions (`_run`, `passes`, `with_edges`, …) and collects their arguments and results.
  - `pp.py` is a compact printer for `Mseq`, `Mpn`, `Script`, `UnitProgram` and `FabricProgram`.
  - `all.py` prints every level, ending with each DNC 0 process's `Script`; `reduce.py` adds the root's and a leaf's
    `Mseq` and the reduce units' full `Mpn` processes; `matmul.py` prints a systolic case from the mseq builder's
    inputs to the VU's template (3.5).
  - `ini.py`, which printed the systolic initial IR, is gone with that IR (`unit_layouts` and `lowering/initial.py`
    were removed in #2609).
  - Run from `PrimitiveAuthor/mcc`: `uv run python ~/workspaces/docs/mcc-ir-dump/all.py tests/perf/<case> [mseq_line_limit]`.
  - Full output: [`mcc-ir-dump/add.txt`](mcc-ir-dump/add.txt), [`mcc-ir-dump/rms.txt`](mcc-ir-dump/rms.txt),
    [`mcc-ir-dump/dense.txt`](mcc-ir-dump/dense.txt), [`mcc-ir-dump/down_proj.txt`](mcc-ir-dump/down_proj.txt),
    [`mcc-ir-dump/matmul.txt`](mcc-ir-dump/matmul.txt).
- The repo now has its own dump: `uv run python -m mcc build … --dump DIR` writes each pass's output of the mseq,
  mpn and JIR levels as `DIR/<nn>-<pass>.<level>.txt` (`grounding/passes.py`). Its mseq printer is coarser than
  `pp.py`'s (a statement is its repr), and its mpn printer lists only process and channel names.
- Related, older notes: [`mcc-internals.md`](mcc-internals.md), [`mcc-hgdg-jir-sqrt.md`](mcc-hgdg-jir-sqrt.md).

## 0. Terms: pass, chunk, band

mcc reuses general words in narrow senses. Each has a near counterpart in loop-transformation compilers
(Halide, TVM, MLIR's affine and memref) or in accelerator architecture. The memory sizes are from
`r100_spec/docs/rebel-h-sw-hw-interface.md` §7.

| mcc | What it is in mcc | Nearest common term |
|---|---|---|
| SHM | the Dcluster's 32 MB SRAM shared by its 8 DNCs, where a block's tensors live | shared on-chip memory used as the kernel's global memory (closest to a GPU's L2 that software addresses) |
| SP | one DNC's 4 MB scratchpad, software-managed; the NC units move lines between it and SHM | scratchpad, local buffer (GPU shared memory) |
| SP **band** | the SP slots one tensor takes on one NCore for one pass (`mseq.py:8`) | a tile buffer in local memory: Halide `store_at`, TVM `cache_read(.., "shared")`, an MLIR `memref.alloc` in a faster memory space |
| **`Pass`** (mseq) | one fill and use of the bands: the lines of one tile, then the next pass reuses the same bands (`mseq.py:8`) | one iteration of the outer tile loop after loop tiling (strip-mining): one tile resident in local memory |
| `Loop[mpass]`, `Loop[cpass]` | the loop over those passes (M-tiles, Cout tiles) | the tile loop itself (`for mo in tiles:`) |
| **`Chunk`** | the sync granularity inside a pass: what one unit writes to SP is handed to the next once per chunk (`mseq.py:4`) | a producer–consumer handshake unit: a pipeline stage boundary (CUDA `cp.async` group + barrier), a KPN token, a BSP superstep |
| FIFO **token** (`push=`/`pop=`, `toks=` in a dump: `w[i,…]`, `x`, `a`, `t`, `s`) | one line of data that one unit pushes into the hardware FIFO to the next unit (SPLU→XVU, XVU→TU:0, TU:r→TU:r+1, TU:7→VU, VU→SPSU, …). Backpressure is in hardware, so no SYNC instruction is emitted (`lowering/tokens.py`); `Channel.capacity` None means the FIFO's own depth | a message on a bounded KPN channel / a hardware stream FIFO |
| put/get **token** (`Sync put`/`get`) | no data: one count on a hardware SYNC counter between two units of a DNC. The data sits in SP or the AB bank, and the token says one chunk of it is ready. Depth is `machine.sync_depth` (e.g. NCLU→SPLU 16) | a counting-semaphore signal beside shared memory |
| compute pass (`mseq.passes`, `Compute.arith`) | one stage of a multi-pass algorithm: RMSNorm's "sum of squares, rsqrt", then "scale" | a pass over the data in a multi-pass reduction; the parts of loop fission (online softmax fuses them) |
| `Loop[run]` | a list of identical statements, one per line, written once | not a loop level; only a compact listing |
| `Mseq` | one DNC's whole schedule in one sequential order | a scheduled loop nest before it is split across threads |
| `Mpn` | that schedule split into one process per unit plus the channels between them | a Kahn process network / CSP program |
| `Script` | one process's statements, loops and syncs | one thread's code after splitting, with its barriers |

How they nest, for a streaming block:

```
Loop[mpass]                      tile loop                   SHM address moves on; SP bands reused
  Pass                           one tile in SP              bands: one per tensor per NCore
    Chunk                        one sync step               load ▸ stage+compute ▸ write ▸ store
      Dma / Stage / Compute / Write
```

Two cautions:

- "Pass" has two meanings. An mseq `Pass` is a band-reuse unit. A compute pass is an arithmetic stage. In RMSNorm
  (3.2), both compute passes sit in one mseq `Pass`, separated by chunks.
- `Chunk.lo` and `Chunk.n` are filled differently by each builder. `mseq_elementwise` puts a line range there. The
  softmax and flash-attention builders put the row group or block index in `lo` and 0 in `n`
  (`mseq_softmax.py:608`, `:633`); the lowering reads only `lo`, as the chunk's position.
- A sync does not sit at a chunk boundary. A chunk can hold an SP producer and its consumer. The producer puts after
  its last statement in the chunk, and the consumer gets before its first, both inside the chunk. In 3.5's first
  chunk, NCLU's `Dma load w; Sync put` and SPLU's `Sync get; Stage w` are an example. A chunk is the unit an SP
  hand-off is batched in, not a sync-free region. What a chunk does rule out is a sync in the middle of a unit's
  part of it: a unit's statements in one chunk run with gets (and credit releases) only at their head and puts
  (and credit acquisitions) only at their tail. FIFO streams (SPLU→XVU→TU, …) never depend on chunks: they move
  token by token under hardware backpressure, inside and across chunks.

## 1. The levels, top to bottom

| # | IR | Type | One instance is | Produced by | Printer |
|---|---|---|---|---|---|
| 1 | `Declared`, `kpl.decl.Level` | `kpl_declaration.py:390`, KernelLanguage `kpl/decl.py` | a kernel and its workload; `body` is a tuple of `decl.Op` (`Eltwise`, `Reduce`, `Contract`, …) | `declare` (:434) | dataclass repr |
| 2 | `Arithmetic` | `grounding/kpl_translate.py:2243` | the compute level that runs, with extents, knobs, problem, repeats and shard | `arithmetic_level_of` (:2285) | dataclass repr |
| 3 | `kpl_ir.Graph` | `grounding/kpl_ir/nodes.py:133` | one level's SSA graph (`InputNode`, `EltwiseOperNode`, `ReduceOperNode`, `ContractOperNode`, `ConstNode`) | `graph_of` (`walk.py:139`) | dataclass repr |
| 4 | `Expr` DAG | `grounding/tracer.py:25` | one numpy op per node; `kind` is input, map, reduce (slice, index) | `dag_of` (`kpl_translate.py:1984`) replaying the graph through the tracer | dataclass repr |
| 5 | `TracedOp`, with `TilingDecision` and `Mdmap` | `grounding/trace.py:328`, `tiling.py:111`, `mdmap.py:32` | one op: the DAG plus axes, `cross_dnc`, placement, spec, tiling; `Mdmap` splits each axis over DNCs | `_lowered` / `build` in `kpl_declaration.py`, then `.tiled` (`trace.py:1003`) | **`trace_print.format_tiled`** (`trace_print.py:36`) |
| 6 | `StreamBlock`, `StreamPlan` (streaming only) | `grounding/stream_block.py:27`, `grounding/mdmap_stream.py:172` | a streaming block: its passes, tensor ranks, K, route; the chunk plan and the VU beat | `mdmap_stream.plan(block_of(trace), io_shm)` (`mdmap_stream.py:190`, called at `block_chain/_streaming.py:51`) | dataclass repr |
| 7 | **`Mseq`**, in the mseq unit | `grounding/mseq.py:491`; the unit `_Unit` (:643) holds every DNC's | one DNC's sequential program: every unit's statements in one body, in program order | `mseq_*.chip`, then the mseq passes `addressed`, `stamped`, `gather` (`spine._PASSES`, `spine.py:292`) | `--dump` (`passes._format_mseq_unit`) |
| 8 | **`Mpn`**, in the mpn unit | `grounding/mpn.py:563` (`Process` :395, `Channel` :533); the unit `_Unit` (:549) | one DNC split into per-unit processes and the channels between them | the chain's split (`split_chip` :612, through `symsplit`), verified by the channel laws | `--dump` (names only) |
| 9 | **`Script`** | `grounding/script.py:486` (`Repetition` :470, `Sync` :458) | one process's statements, repetitions and SYNCs in program order, its fields affine in the repetition indices | `Process.script` / `Mapped.script`, built the first time it is read | none |
| 10 | `Mapped` | `grounding/block_chain/_chain.py:125` | the chain for one build: `seqs` (the refined mseqs), `mpn` (the mpn unit), `events`, `stream`, `barrier`, `rolled()`, `script()` | `block_chain.mapped` (`block_chain/__init__.py:36`), run by `spine._run` (`spine.py:295`) | none |
| 11 | `passes(seqs)` | `grounding/mseq.py:1006` | `((unit, arith), …)` for the build | walking the mseqs (`spine.py:660`) | tuple repr |
| 12 | `UnitProgram` | `ir/unit_program.py:14` | one unit instance; its `template` field is the JIR | `coordination.derive_unit` (`lowering/coordination.py:1011`), each unit lowered from its process's `Script` | dataclass repr |
| 13 | `FabricProgram` | `ir/coordination_ir.py:137` | the whole fabric: every `UnitProgram` plus coordination `Channel` (:87) and `Edge` (:72) | `collect_programs` (`lowering/coordination.py:64`) | dataclass repr; `--dump` (`spine._format_jir`) |

- The IRs strictly before JIR are levels 5 to 11.
- Levels 12 and 13 hold the JIR. A template is built from `jir.Tmpl`/`Label` and the authoring nodes in `ir/nodes.py`
  (`_Loop` :49, `_Frame` :141, `_Vocab` :18, `_SignalReduce` :31).
- The systolic initial IR (`unit_layouts`, `lowering/initial.py`) and the per-unit emitters (`emit_*.py`) are gone:
  every unit is now lowered from its process's `Script` (#2609, #2650 … #2698).
- Three levels are pass chains run by one pass manager (`grounding/passes.py`), each pass verified as it ends:
  - mseq: `addressed`, `stamped`, `gather`; then the split to the mpn unit (`spine._run`, `spine.py:295`).
  - JIR (`spine._jir_passes`, :497): `edges` (`with_edges`), `walks` (systolic, `walks_from_process`), verified by
    the emission laws and `mpn_syncs.check`; then `bind`, `frame`, `vocab`, `loops`, `signals`, `eval`, `block`,
    `alloc`, `retarget`, `patch`, `assemble`.
  - After the chain, `realize` runs the image laws: `check_compute_events`, `check_mtile_loops`, `check_nc_moves`,
    `check_sp_staged`, `check_sp_moves`.

## 2. Mseq

**What it is** (`grounding/mseq.py:1-95`, `Mseq` :491)

- One DNC's program in program order. Every statement names its unit, NCore, SP slot and tokens.
- A token is `(tensor, idx…)`.
- Fields: `dnc`, `op`, `tensors`, `body`, `ranks` (streaming only), `grid` (mdmap coordinates), `problems`,
  `addressed`/`lined` (tensors with real addresses).
- The mpn split and the test interpreter (`tests/mseq_interpret.py`) read the same order.
- The builders return an mseq unit (`_Unit`, :643): every DNC's mseq plus what the mseq passes read
  (`band_chunks`, `addresses`, `facts`) and produce (`gathered`, `numbered`).

**Vocabulary**

- Structure
  - `Pass(lo, n, body=Chunks)`: one SP band that is reused.
  - `Chunk(lo, n, body, via, whole)`: the unit of synchronization. `via` is a collective's give/take tag; `whole`
    names a unit that reads the chunk at once.
  - `Loop(unit, trips, body, count, lines, tokens, lo, slots, keys, chunk_lo, rows, lanes, ncs)` (:381): a stride
    compression of repeated statements. `unit` is `mpass`, `cpass`, `batch`, `sfold`, `accum`, `line`, `strip` or
    `run` (`run` compresses a list, it is not a level). `expand` (:877) unrolls the trips.
- Statements
  - `Dma(dst SP|SHM, tensor, lo, slot, n, nc, stride)`: an NC load or store.
  - `Stage(tensor, slots, toks, nc, dst, unit, splat, lanes, rows)`: SPLU/ABLU push into a FIFO.
  - `Compute(op, unit, nc, pops, pushes, to, arith)`.
  - `Write(tensor, slots, toks, nc, src, unit, rows)`: SPSU/ABSU.
  - `Reduce(group, instance, band, parts=Part…, leaf_lines, units, op, arith)`: a cross-DNC collective, expanded by
    `collective.gather`.
  - `Fence(dncs)`.
- Tensor ranks: `streamed`, `scalar`, `collapsed`, `staged`, `broadcast`, `republished`.
- The mpn adds `Put`/`Get` (`mpn.py:74`/`:82`), `Process`, `Channel` (transport FIFO or SP; protocol
  backpressure, put/get or credit), and the per-unit loop view `mpn.Level`/`unit_view` (:108/:137).
- A `Script` keeps an mseq statement per statement, wraps repeated ones in a `Repetition(index, trips, unit, count)`
  and states each `Put`/`Get` as a `Sync(kind, peers, dncs)`, one SYNC or MESYNC instruction.

**How `passes` is derived** (`mseq.py:1006`)

- Walk every mseq into its loops, passes and chunks.
- Collect each `Compute.arith` that is not `()`, deduplicated in first-seen order.
- Name the unit without its row suffix (`TU:3` → `TU`).
- `Compute.arith` is `TracedOp.arith` (`trace.py:893`), which `block_chain._chain.arith_of` (:44) turns into a tuple for the builder:
  - streaming: the DAG split per pass by `node_passes`, without the inputs;
  - systolic: `{TU: card}`, plus the epilogue on the drain unit when there is one.
- So `passes` is the trace's arithmetic after one round trip through the mseqs.

**Builders** (selection in `block_chain/_streaming.py:131-146`; systolic in `block_chain/_systolic.py`)

- systolic → `mseq_matmul`.
- streaming with one pass → `mseq_elementwise` if every output is streamed, else `mseq_reduce`.
- streaming with several passes → `mseq_softmax` if `mseq_softmax.form` matches, else `mseq_flash_attn`.
  RMSNorm takes the softmax builder.

| Builder | For | What it builds |
|---|---|---|
| `mseq_elementwise.chip` (:347) | one pass, every output streamed | Rows in lanes. A `Loop[mpass]` per tile (with problems), a `Loop[line]` per chunk, and Stage → VU Compute → Write per line. No collective, only a Fence. `walk` rebuilds it with the beat unroll. |
| `mseq_reduce.chip` (:286) | one pass, collapsed output | The same movement with a running sum on the VU, pushed after the last line and written and stored in the last chunk. The `across_lanes` variant adds a handoff band (`<out>.handoff`), a splat reload and a republished rank. |
| `mseq_softmax.chip` (:1025) | several passes in softmax form (RMSNorm included) | Per row group: A max → B exp + sum → C normalize (on the XVU or the VU), optionally skewing A one group ahead. In the rows-in-lanes form (`LaneMap`, `build_lanes`) the VU runs every pass. A per-row scalar is reloaded through SP (broadcast or staged rank). |
| `mseq_matmul.chip` (:1378) | systolic matmul and conv | One pass per N-tile × K-tile. w: SPLU → XVU → TU rows 0..7 (`tu_prime`, `pass`). x: XVU → ABSU → AB → ABLU row → TU (`tu_mac`, `tu_drain` chain). VU `accumulate` → SPSU → NCSU. A K split adds a `Reduce` (gather). M-tile loops, double buffering, `batch_sums`; `chip_nets` rebuilds after the symsplit depth analysis. `ranks` is empty and `grid` is set. TU and ABLU are per-row units (`TU:r`). |
| `mseq_flash_attn.chip` (:576) | other multi-pass ops (the flash-attention tiling half) | Pass A masked score + max, pass B exp + sum. A line arm (rows in lanes) and a lane arm (collapsed, handoff band, splat). `Chunk.whole` on the NCSU store chunk. |

## 3. Printed IR

### 3.1 add_elementwise 1x16x2x64 (R = 1024, K = 2)

`decl.Level.body`, `kpl_ir.Graph`, `Expr` DAG:

```
(Eltwise(args=(0, 1), op='add', imm=None),)
Graph inputs: (InputNode(name='input1', axes=('R','K')), InputNode(name='input2', axes=('R','K')))
   EltwiseOperNode(name='v0', op='add', deps=(InputNode(input1..), InputNode(input2..)))
Expr: input1:in[R,K] / input2:in[R,K] / add1=add(input1,input2)  [out]
  axes={'lane': ('R','r'), 'reduce': (('K','k','beat'),)} cross_dnc=None
  spec=StreamAddrs(in_addrs={'input1': 1, 'input2': 35}, out_addr=69, extents={'R': 1024, 'K': 2}, ...)
```

`format_tiled` (the repo's printer, verbatim):

```
tiled.trace  streamaddrs  R=1024 K=2        kind=streaming  units=NCLU,NCSU,VU
  dag
        input1:[R,K]
        input2:[R,K]
        add1 = add(input1, input2)                      → out
        card  None
        roles lane=R
  spatial
        dnc[16] = shard.R[16] × split.K[1]
  temporal
    LEAF  R=64:lane
            reduce K[2]   (leaf_K=2)
  accumulate
        acc_edge None   monoid=add   cadence={'accum': 1, 'npass': 1}   temporal_depth=1
  covers
        R     shard  leaf 64 × shard_extent 1024     ✓  shard_extent 1024 vs extent 1024
        K     plain  leaf 2                          ✓  leaf 2 vs extent 2
```

`Mdmap`, `StreamPlan`, `StreamBlock` (repr, Expr parts shortened):

```
Mdmap(levels=(Level(axis='M', count=16, kind='shard'),), m_split=Split(extent=1024, count=16, tie_break='first'))
chunks=StreamChunks(size=2, n_full=1, tail=0, compute_passes=1) unroll=1 walks=True tail=0 fold_walk=1
block: passes=[['add1=add(input1,input2)']] streamed=('input1','input2') K=2 ncores=1 outputs=(('add1', True),)
       units=('VU',) route=Route(loader='SPLU', storer='SPSU')
```

`Mseq` for DNC 0 (addressed; DNC 0 of 16, nothing else trimmed):

```
Mseq dnc=0 op=op tensors=('input1', 'input2', 'add1')
  ranks={'input1': 'streamed', 'input2': 'streamed', 'add1': 'streamed'} grid=() problems={'input1': 32, ...}
  Loop[mpass] x1 lines={'input1': 2, 'input2': 2, 'add1': 2} lo=2
    Pass lo=0 n=2
      Chunk lo=0 n=2
        Dma load  input1 shm[1:+2] -> nc0.sp[1:+2]
        Dma load  input2 shm[35:+2] -> nc0.sp[4:+2]
        Loop[run] x2 slots={'input1': 1, 'input2': 1, 'add1': 1} tokens={'input1': 1, 'input2': 1, 'add1': 1}
          Stage SPLU0 input1 sp[1] -> VU toks=input1[0]
          Stage SPLU0 input2 sp[4] -> VU toks=input2[0]
          Compute VU0 op=op pop=input1[0],input2[0] push=add1[0] -> SPSU arith=(add1=add(input1,input2))
          Write SPSU0 add1 sp[7] <- VU toks=add1[0]
        Dma store add1 shm[69:+2] <- nc0.sp[7:+2]
  Fence dncs=0..15
passes(seqs) = (('VU', (add1=add(input1,input2),)),)
```

`Mpn` for DNC 0. It is split from the builder's own numbering, before addressing, so lines and slots start at 0;
the `(pass, chunk)` prefix of each statement (`Process.where`) is omitted:

```
Mpn dnc=0: 5 processes, 4 channels
  process NCLU:  Dma load input1 shm[0:+2]->sp[0:+2]; Dma load input2 ...; Put -> SPLU0 tok=0; Fence
  process SPLU0: Get <- NCLU tok=0; Stage input1 sp[0]->VU; Stage input2 sp[0]->VU; Stage input1 sp[1]; Stage input2 sp[1]
  process VU0:   Compute pop=input1[0],input2[0] push=add1[0] -> SPSU; Compute ...[1]
  process SPSU0: Write add1 sp[0]; Write add1 sp[1]; Put -> NCSU tok=0
  process NCSU:  Get <- SPSU0 tok=0; Dma store add1 shm[0:+2]; Fence
  channel SPLU0->VU0  FIFO/backpressure cap=None tokens=4
  channel VU0->SPSU0  FIFO/backpressure cap=None tokens=2
  channel NCLU->SPLU0 SP/put/get cap=1 depth=16 in_flight=1 tokens=1
  channel SPSU0->NCSU SP/put/get cap=1 depth=16 in_flight=1 tokens=1
events (0,'NCLU',None) [('load',2,0), ('load',2,1), ('put',('splu0',)), ('fence',)]
       (0,'VU',0)      [('pop',1), ('pop',1), ('push',1), ('pop',1), ('pop',1), ('push',1)]
```

`FabricProgram` and `UnitProgram`, where JIR starts (4 of 32 channels and 2 of DNC 0's 5 units shown):

```
FabricProgram units=80 schedule_driven=True sp_fan=1 reduces=False mesync=NoneType
  channel c0 Signal ('NCLU',0)->('SPLU',0) roles=('stage','load') gran='' fires={0: 1}
  channel c1 Signal ('SPSU',0)->('NCSU',0) roles=('egress','drain') gran='per_tile' fires={0: 1}
UnitProgram VU dnc=0 ncore=0 col=4  framing={'unit_id': 130, ...} boundary[0]
    Tmpl IMMCOPY {typ1_imm=15872, replica=1, lrf_tgt=16, ...}
    Tmpl MVLOOPCNT {typ1_imm=2}
    Tmpl FMA {src0=4, src1=16, src2=17, lrf_tgt=18, out_sp=0, ...}
    Tmpl FMA {src0=18, src1=16, src2=4, lrf_tgt=0, out_sp=3, ..., be=1}
    Tmpl RETURN {be=0}
UnitProgram SPLU dnc=0: Tmpl SYNC_ROLE{ref=load}; MVLOOPCNT{2}; LDU ...; LDU ... be=1; RETURN
```

Here `boundary` is empty: the syncs are `SYNC_ROLE` nodes inside the template, lowered from each process's `Script`.

`Script` for each DNC 0 process, the step between the `Mpn` and the template. Each `Sync` is one SYNC instruction,
and each `Rep` a loop over `i1` whose statements read their slots and tokens affinely in it:

```
Script NCLU:  Dma load input1 shm[0:+2] -> nc0.sp[0:+2] ; Dma load input2 … ; Sync put splu0 ; Fence dncs=0..15
Script SPLU0: Sync get nclu
              Rep i1 x2 unit=run
                Stage SPLU0 input1 sp[i1] -> VU toks=input1[i1] ; Stage SPLU0 input2 sp[i1] -> VU toks=input2[i1]
Script VU0:   Rep i1 x2 unit=run
                Compute VU0 op=op pop=input1[i1],input2[i1] push=add1[i1] -> SPSU
Script SPSU0: Rep i1 x2 unit=run
                Write SPSU0 add1 sp[i1] <- VU toks=add1[i1]
              Sync put ncsu
Script NCSU:  Sync get spsu0 ; Dma store add1 shm[0:+2] <- nc0.sp[0:+2] ; Fence dncs=0..15
```

The one chunk shows as the `Sync put splu0` / `Sync get nclu` pair at its start and the `put ncsu` / `get spsu0`
pair at its end.

### 3.2 rms_norm r1_k2048 (a reduce, then a second pass)

Since the earlier base, the kernel adds the epsilon (`add4`), so the names after it moved up by one.

```
decl body: (Eltwise(mul,(0,0)), Reduce((2,),K,add), Eltwise((3,),mul,imm=0.000488), Eltwise((4,),add,imm=1e-05),
            Eltwise(rsqrt), Eltwise(mul,(0,6)), Eltwise(mul,(7,1)))
Expr: input:in[R,K] scale:in[K] mul1=mul(input,input) red2=reduce.add[K](mul1) mul3=mul(red2,0.00048828125)
      add4=add(mul3,1e-05) rsqrt5=rsqrt(add4) mul6=mul(input,rsqrt5) mul7=mul(mul6,scale)
  axes={'lane': ('K','k'), 'shard': ('R','r'), 'reduce': (('K','k','lane'),)}
format_tiled (excerpt): dnc[1] = shard.R[1] × split.K[1] / LEAF R=1:line, reduce K.blk[32] × K.in[64] / cadence npass=2
StreamBlock: passes=[[mul1, red2, mul3, add4, rsqrt5], [mul6, mul7]] shared=('scale',) broadcast=(('rsqrt5',0),) K=32 units=('VU','VU')
Mapped op=softmax
```

`Mapped op=softmax`: RMSNorm passes `mseq_softmax.form`, which matches the pass structure (reduce passes handing a
scalar on, then a map pass) whatever the maps compute, and `mseq_softmax.build` names every mseq it builds
"softmax".

`Mseq` for DNC 0 (nothing trimmed):

```
Mseq dnc=0 op=softmax tensors=('input', 'scale', 'mul7')
  ranks={'input': 'streamed', 'scale': 'streamed', 'rsqrt5': 'broadcast', 'mul7': 'streamed'}
  Loop[mpass] x1 lines={'input': 32, 'scale': 0, 'mul7': 32} tokens={...} lo=1
    Pass lo=0 n=32
      Chunk lo=0 n=0
        Dma load  input shm[1:+32] -> nc0.sp[1:+32]
        Dma load  scale shm[34:+32] -> nc0.sp[34:+32]
      Chunk lo=0 n=0
        Loop[run] x32 slots={'input': 1, 'scale': 1}
          Stage SPLU0 input sp[1] -> VU ; Stage SPLU0 scale sp[34] -> VU
          Compute VU0 op=max_acc pop=input[0,0],scale[0,0] push= -> SPSU arith=(mul1; red2; mul3; add4; rsqrt5)
        Compute VU0 op=max_out pop= push=rsqrt5[0] -> SPSU arith=(mul1; red2; mul3; add4; rsqrt5)
        Write SPSU0 rsqrt5 sp[67] <- VU
      Chunk lo=0 n=0
        Stage SPLU0 rsqrt5 sp[67] -> VU toks=rsqrt5[0] splat
        Compute VU0 op=hold_sum pop=rsqrt5[0] arith=(mul6; mul7)
        Loop[run] x32 ...
          Stage input / Stage scale
          Compute VU0 op=normalize pop=input[0,0],scale[0,0] push=mul7[0,0] -> SPSU arith=(mul6; mul7)
          Write SPSU0 mul7 sp[69] <- VU
      Chunk lo=0 n=0
        Dma store mul7 shm[67:+32] <- nc0.sp[69:+32]
  Fence dncs=0..0
passes = (('VU', (mul1, red2, mul3, add4, rsqrt5)), ('VU', (mul6, mul7)))
```

- The op labels (`max_acc`, `max_out`, `hold_sum`, `normalize`) are the softmax builder's names.
- `Compute ... op=max_out` after the first loop is the scalar work after the reduce (the epilogue). Its result goes
  through SP and comes back as a splat `Stage` in the next chunk.
- In the terms of section 0: one tile loop trip, one `Pass` (one set of bands), four `Chunk`s (load, compute pass 1,
  compute pass 2, store), and two compute passes.
- Every `Chunk` is `lo=0 n=0`: the builder puts the row group in `lo` and leaves `n` 0 (`mseq_softmax.py:608`,
  `:633`). The line ranges are in the statements.

`Mpn` for DNC 0 has 5 processes and 5 channels (SPLU0 has 131 statements and VU0 66; only the channel table is shown):

```
  SPLU0->VU0  FIFO/backpressure tokens=129
  VU0->SPSU0  FIFO/backpressure tokens=33     (rsqrt5 1 + mul7 32)
  NCLU->SPLU0 SP/put/get cap=1 depth=16
  SPSU0->NCSU SP/put/get cap=1 depth=16 first=[2]
  SPSU0->SPLU0 SP/put/get cap=1 depth=4       <- the broadcast scalar handed to the next pass through SP
FabricProgram: c2 Carried ('SPSU',0)->('SPLU',0) roles=('war','reload') gran='credit'
```

`Script`s for DNC 0. The chunk boundaries become the `Sync`s: `get nclu` (chunk 1 to 2), `put splu0` / `get
spsu0` (chunk 2 to 3, the scalar through SP), `put ncsu` (chunk 3 to 4):

```
Script SPLU0: Sync get nclu
              Rep i0 x32 unit=run:  Stage input sp[i0] -> VU ; Stage scale sp[i0] -> VU
              Sync get spsu0
              Stage rsqrt5 sp[0] -> VU splat
              Rep i1 x32 unit=run:  Stage input sp[i1] -> VU ; Stage scale sp[i1] -> VU
Script VU0:   Rep i0 x32: Compute max_acc ; Compute max_out push=rsqrt5[0] ; Compute hold_sum pop=rsqrt5[0]
              Rep i1 x32: Compute normalize push=mul7[0, i1]
Script SPSU0: Write rsqrt5 sp[0] ; Sync put splu0 ; Rep i1 x32: Write mul7 sp[i1] ; Sync put ncsu
```

### 3.3 dense m128_k64_n64 (systolic, `mseq_matmul`)

```
Graph: ContractOperNode(name='v0', lhs=InputNode(input,(M,K)), rhs=InputNode(kernel,(K,N)))
Expr (after renaming to handles): x:in[M,K] w:in[K,N] mul1=mul(x,w) y=reduce.add[K](mul1)
  axes={'lane': ('N','n'), 'shard': ('M','m'), 'contract': ('K','k')} cross_dnc=gather
format_tiled (excerpt): card ComputeOperands(combine='mul', reduce='add', stationary='north', streamed='west')
  spatial dnc[16] = shard.M[16] × split.K.beat[1], ncore[2] / temporal loop K.bin[1] (degenerate)
    LEAF N=64:lane · M=4:line, reduce K.col[8] × K.beat[8]
  buffers SP:kernel w @NCLU / SP:ab_bank x @NCLU / SP:tu_psum y @TU / SP:vu_acc acc @VU
```

`Mseq` for DNC 0 (the repeated lines for TU rows 1 to 6 are trimmed):

```
Mseq dnc=0 op=matmul tensors=('x','w','y')  ranks={} grid=(('M', 16, 0),)
  Pass lo=0 n=0
    Chunk lo=0 n=0
      Dma load  w shm[130:+64] -> nc0.sp[984:+64]
      Loop[run] x2 ... ncs=1
        Stage SPLU0 w sp[984..] -> XVU toks=w[0,0,0],..+61
        Loop[run] x64: Compute XVU0 op=pass pop=w[0,0,0] push=w[0,0,0] -> TU:0 arith=()
        Compute TU:00 op=tu_prime pop=w[0..7] -> None arith=()
        Loop[run] x56: Compute TU:00 op=pass ... -> TU:1
        ... (TU:1..TU:7 prime and forward the same way)
    Chunk lo=0 n=0
      Loop[run] x8 lines={'x':1} slots={'x':1}: Dma load x shm[1:+1] -> nc0.sp[1048:+1]
      Loop[run] x2 ... ncs=1
        Stage SPLU0 x sp[1048..1051] -> XVU
        Loop[run] x4: Compute XVU0 op=pass -> ABSU
        Write ABSU0 a sp[0,1,2,3] <- XVU
    Chunk lo=0 n=0
      Loop[run] x2 ... ncs=1
        Stage ABLU:00 a sp[0..3] -> TU:0 lanes=(0,4) ; Stage ABLU:00 ... lanes=(4,4)
        Compute TU:00 op=tu_mac  arith=(ComputeOperands(combine='mul', reduce='add', ...))
        Compute TU:00 op=tu_drain push=t[0,..] -> TU:1 arith=(ComputeOperands(...))
        Loop[run] x6 rows=1: (ABLU:r stage, TU:r tu_mac, TU:r tu_drain -> TU:r+1)
        ... TU:70 tu_drain -> VU
        Compute VU0 op=accumulate pop=t[7,..] push=s[0,..] -> SPSU arith=()
        Write SPSU0 y sp[1056..1059] <- VU
    Chunk lo=0 n=0
      Loop[run] x8: Dma store y shm[197:+1] <- nc0.sp[1056:+1]
  Fence dncs=0..15
passes = (('TU', (ComputeOperands(combine='mul', reduce='add', stationary='north', streamed='west'),)),)
```

- No epilogue here.
- `Mpn[0]` has 44 processes (NCLU, SPLU0/1, XVU0/1, ABSU0/1, ABLU0:0..7, TU0:0..7, VU, SPSU, NCSU, …) and 76 channels.
  16 of them are new since the earlier base: a credit from each ABLU row back to its ABSU
  (`ABLU0:r->ABSU0 SP/credit depth=4`), so the ABSU does not overwrite the AB bank before every row has read it.
  In the `Script`s, the ABLU's first `put` (`ahead=1`) and the ABSU's last `get` (`behind=1`) are the credit's
  once-a-block ends, outside every pass (`script.Script`):

  ```
  Script ABSU0 ahead=0 behind=1:  Write ABSU0 a sp[0,1,2,3] <- XVU ; Sync put ablu ; Sync get ablu
  Script ABLU0:0 ahead=1:         Sync put absu ; Sync get absu
                                  Rep i9 x2: Stage ABLU:00 a sp[0,1,2,3] -> TU:0 lanes=(4*i9, 4)
  ```
- `FabricProgram`: units=480, sp_fan=2, mesync=ClusterBarrier; channel flavors Barrier, Fan, Carried (credit), Gather.
  The templates hold `ir/nodes.py` nodes such as `_Frame axes=('Bmb','Br','Bout')`, `_Loop kind=axis axes=('Bout',)`
  and `_Vocab sp_immc {...}`.

### 3.4 dense m4_k256_n64 (`down_proj`: K split over DNCs, cross-DNC `Reduce`)

`x[4,256] @ w[256,64]`. M has only 4 rows, so mcc shards M over 4 DNCs and splits K over 4 more, and the partials
of each M row are summed across DNCs.

```
format_tiled (excerpt): card ComputeOperands(combine='mul', reduce='add', stationary='north', streamed='west')
  spatial dnc[16] = shard.M[4] × split.K.beat[4]
    role root (  4 dnc): gather[3] → acc, depth=4, monoid=add, egress
    role leaf ( 12 dnc): partial → root, no egress
  temporal loop K.bin[1] (degenerate)
    LEAF N=64:lane · M=1:line, reduce K.col[8] × K.beat[8] (leaf_K=64)
  accumulate acc_edge ('VU','VU','acc') monoid=add cadence={'accum': 4, 'npass': 1}
Mdmap(levels=(Level(axis='M', count=4, kind='shard'), Level(axis='K', count=4, kind='reduce')))
```

`Mseq` for DNC 0, a root (`grid=(('M', 4, 0), ('K', 4, 0))`; TU rows 1 to 6 trimmed). It is the dense pass of 3.3
with M = 1 padded to the 4-row tile, then a `Reduce` chunk and the store:

```
Mseq dnc=0 op=matmul tensors=('x', 'w', 'y')  grid=(('M', 4, 0), ('K', 4, 0))
  Pass lo=0 n=0
    Chunk: Dma load  w shm[18:+64] -> nc0.sp[984:+64]
           Stage SPLU0 w -> XVU ; Loop[run] x64: Compute XVU0 op=pass -> TU:0
           Compute TU:00 op=tu_prime pop=w[0..7] ; Loop[run] x56: Compute TU:00 op=pass -> TU:1 ; … TU:70 tu_prime
    Chunk: Dma load  x shm[1:+1] -> nc0.sp[1048:+1]
           Stage SPLU0 x sp[1048..1051] -> XVU toks=x[0,0,0], x['pad',…,1,0], x['pad',…,2,0], x['pad',…,3,0]
           Compute XVU0 op=pass -> ABSU (×4) ; Write ABSU0 a sp[0,1,2,3] <- XVU
    Chunk: Stage ABLU:00 a -> TU:0 lanes=(0,4) ; Stage ABLU:00 a -> TU:0 lanes=(4,4)
           Compute TU:00 op=tu_mac ; Compute TU:00 op=tu_drain -> TU:1 ; Loop[run] x6 (TU:1..TU:6) ; TU:70 tu_drain -> VU
           Compute VU0 op=accumulate pop=t[7,0,…] push=s[0,…] -> SPSU
           Write SPSU0 y sp[1049..1052] <- VU
    Chunk: Reduce group=(0, 1, 2, 3) inst=0 band=y op=add units=('SPLU', 'VU', 'SPSU') parts=1
    Chunk: Dma store y shm[277:+1] <- nc0.sp[1049:+1]
  Fence dncs=0..15
```

DNC 1, a leaf (`grid=(('M', 4, 0), ('K', 4, 1))`), differs in its slices (`w shm[82:+64]`, `x shm[5:+1]`), writes band
`q` instead of `y`, and has the same `Reduce` chunk but no `Dma store` of `y`.

The `Reduce` is a single node in the `Mseq`. `split_chip` lowers it into the root's and the leaves' processes. The
`Mpn` addresses are the build's own block-packed placement (x 0, w 16, out 272, partials 276..), not the manifest's
that the addressed `Mseq` above shows.

```
Mpn dnc=0 (root), the reduce part of each process:
  NCLU   Get <- (1,'NCSU') ; Dma load q shm[276:+1] -> sp[1057] ; Put -> SPLU0 ; Put -> (1,'NCSU')
         Get <- (2,'NCSU') ; Dma load q shm[277:+1] -> sp[1058] ; Put -> SPLU0 ; Put -> (2,'NCSU')
         Get <- (3,'NCSU') ; Dma load q shm[278:+1] -> sp[1059] ; Put -> SPLU0 ; Put -> (3,'NCSU')
  SPLU0  Get <- NCLU ; Stage q sp[1057..1060] -> VU   (line 0 = partial of DNC 1, lines 1..3 'pad')
         Get <- NCLU ; Stage q sp[1058..1061] -> VU   (DNC 2)
         Get <- NCLU ; Stage q sp[1059..1062] -> VU   (DNC 3)
  VU0    accumulate pop=t[7,…] (own TU) ; accumulate pop=q[1] ; pop=q[2] ; pop=q[3]   each push=s[i] -> SPSU
  SPSU0  Write y sp[1049..1052] ×4 ; Put -> NCSU
  NCSU   Get <- SPSU0 ; Dma store y shm[272:+1] <- sp[1049] ; Fence
Mpn dnc=1 (leaf) NCSU:
         Get <- SPSU0 ; Dma store q shm[276:+1] <- sp[1049] ; Put -> (0,'NCLU') ; Get <- (0,'NCLU') ; Fence
FabricProgram units=256 reduces=True reduce_monoid=add mesync=ClusterBarrier
  edges[12]: Reduce ('NCSU', 1)->('NCLU', 0), ('NCSU', 2)->('NCLU', 0), ('NCSU', 3)->('NCLU', 0), ('NCSU', 5)->('NCLU', 4), …
```

The `(dnc, 'unit')` peers become `MESYNC`s, `Put`/`Get` with a same-DNC peer become `SYNC`s, and the
`edges[12]` are the 3 leaves of each of the 4 groups.

#### How the reduction works

- **Grouping.** `Mdmap` levels `M shard 4 × K reduce 4` give `d = 4m + k`. The 4 DNCs with the same `m` form a group;
  the one with `k = 0` is the root (`star_reduce`: one level, the root gathers every leaf).
- **Every DNC** computes its partial `x[m, 64k:+64] @ w[64k:+64, :]` on a 4-row tile (row 0 real, 3 padding),
  accumulates it in the VU and stores it to SP through the SPSU.
- **A leaf** stores its line 0 to its SHM slot (`q`, line `276 + 3m + (k − 1)` in the block-packed placement), then
  `MESYNC`s with its root: put "ready", get "taken".
- **The root**, for each leaf in order: waits for "ready", loads that slot into SP, signals its SPLU, releases the
  leaf. The SPLU pushes a 4-line window starting at that partial; the VU adds it to the accumulator still holding the
  root's own partial; the SPSU rewrites the same 4 SP lines after every step.
- **Egress.** After the last step the root's NCSU stores SP line 0 (`out[m, :]`) to SHM. Leaves have no egress.
- **Fence.** All 16 DNCs close with the cluster barrier (`Fence dncs=0..15`).

#### Mapping

```
                 k = 0 (root)          k = 1              k = 2              k = 3
              K = 0..63             K = 64..127        K = 128..191       K = 192..255
 m = 0  ┌──────────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
 x[0,:] │ DNC 0            │  │ DNC 1        │  │ DNC 2        │  │ DNC 3        │
        │ TU: x·w partial  │  │ TU: partial  │  │ TU: partial  │  │ TU: partial  │
        │ VU acc  ◀────────┼──┤ NCSU→SHM 276 │  │ NCSU→SHM 277 │  │ NCSU→SHM 278 │
        │  += 276,277,278  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
        │ NCSU → SHM 272   │◀────────┴── MESYNC + NCLU load, one leaf at a time ──┘
        └──────────────────┘
 m = 1   DNC 4 (root)  ◀── DNC 5, 6, 7    slots 279..281   out 273
 m = 2   DNC 8 (root)  ◀── DNC 9, 10, 11  slots 282..284   out 274     (cluster 1)
 m = 3   DNC 12 (root) ◀── DNC 13, 14, 15 slots 285..287   out 275     (cluster 1)

 per DNC:  SHM ─NCLU─▶ SP ─SPLU─▶ XVU ─┬─▶ TU north (w, 64 lines)
                                       └─▶ ABSU ─▶ AB ─▶ ABLU ─▶ TU west (x, 4-row tile)
           TU row 7 ─▶ VU (acc) ─▶ SPSU ─▶ SP ─NCSU─▶ SHM (leaf: slot, root: out after the gather)
```

Slots and outputs are in the `Mpn`'s block-packed lines; groups never cross an 8-DNC cluster.

### 3.5 matmul with an epilogue: `(x @ w) * 0.125`, M=128 K=64 N=64

The dense case of 3.3 with one multiply after the contraction, followed from what the mseq builder receives to the
VU's template. The kernel is [`mcc-ir-dump/dense_scale_kernel.py`](mcc-ir-dump/dense_scale_kernel.py), placed by
`build_sequential`; the full output is [`mcc-ir-dump/matmul.txt`](mcc-ir-dump/matmul.txt).

**Upstream.** The `@` makes K a `contract` axis, so the level is systolic (`kpl_roles.arm`). The node after the
reduce is the epilogue (`TracedOp.epilogue`), which `TracedOp.arith` keys to the unit the TU drains into:

```
Expr: x:in[M,K]  w:in[K,N]  mul1=mul(x,w)  red2=reduce.add[K](mul1)  y=mul(red2,0.125)
format_tiled (excerpt):
  roles lane=N  shard=M  contract=K
  spatial   dnc[16] = shard.M[16] × split.K.beat[1], ncore[2]
  LEAF      N=64:lane · M=4:line, reduce K.col[8] × K.beat[8]
  buffers   SP:kernel w @NCLU / SP:ab_bank x @NCLU / SP:tu_psum y @TU / SP:vu_acc acc @VU
TracedOp.arith:
  TU: ComputeOperands(combine='mul', reduce='add', stationary='north', streamed='west')
  VU: (y=mul(red2,0.125),)                                     <- the epilogue
```

**What the mseq builder receives** (`mseq_matmul.chip(m, k, n, tiling, arith)`, called from
`block_chain/_systolic.py`). There is no `StreamBlock` or `StreamPlan` on this arm:

```
m=128 k=64 n=64
TilingDecision: every field at its default but shard_extent=128
  → per_dnc_rows 8, tile_rows 8, numncores 2, ncore_rows 4, active_dncs 16, sp_banks 2
Mdmap(levels=(Level(axis='M', count=16, kind='shard'),), m_split=Split(extent=128, count=16))
arith {'TU': (card,), 'VU': (y=mul(red2,0.125),)}
```

So each DNC takes 8 rows of M, 4 per NCore (one Tr atom each), all of K and all of N in one pass.

**`Mseq` for DNC 0** (TU rows 1 to 6 trimmed). One `Pass`; its four `Chunk`s are phases, as in the softmax builder,
not line ranges:

```
Pass lo=0 n=0
  Chunk   Dma load w shm[128:+64] -> sp[984:+64]
          Stage SPLU0 w -> XVU ; XVU0 pass ×64 -> TU:0
          TU:00 tu_prime (w rows 0..7) ; TU:00 pass ×56 -> TU:1 ; … ; TU:70 tu_prime      <- weights down the rows
  Chunk   Dma load x shm[0:+1] ×8 -> sp[1048..]
          Stage SPLU0 x sp[1048..1051] -> XVU ; XVU0 pass ×4 -> ABSU ; Write ABSU0 a sp[0..3]   <- x into the AB bank
  Chunk   Stage ABLU:00 a -> TU:0 lanes=(0,4),(4,4) ; TU:00 tu_mac ; TU:00 tu_drain -> TU:1
          … ABLU:r / TU:r for r = 1..7 …                                                 <- partials down the rows
          TU:70 tu_drain -> VU
          Compute VU0 op=accumulate pop=t[7,…] push=s[0,…] -> SPSU arith=(y=mul(red2,0.125))   <- epilogue here
          Write SPSU0 y sp[1056..1059] <- VU
  Chunk   Dma store y shm[192:+1] ×8 <- sp[1056..]
Fence dncs=0..15
```

The epilogue is no statement of its own: it is the `arith` of the VU's `accumulate`, the statement that takes the
last TU row's drain.

**`Mpn` for DNC 0**: 44 processes and 76 channels.

| channel | kind | count |
|---|---|---|
| SPLU→XVU→TU:0→…→TU:7 (weights), XVU→ABSU, ABLU:r→TU:r, TU:7→VU, VU→SPSU | FIFO / backpressure | per NCore |
| NCLU→SPLU0/1, SPSU0/1→NCSU | SP put/get, depth 16 | 4 |
| ABSU→ABLU:r | SP put/get (AB bank ready) | 16 |
| ABLU:r→ABSU | SP credit, depth 4 (AB bank free) | 16 |

**`Script`s for DNC 0** (NCore 0, rows 1 to 6 of the TU and the ABLU trimmed):

```
NCLU:     Dma load w shm[128:+64] ; Sync put splu0,splu1
          Rep i5 x8: Dma load x shm[i5:+1] -> sp[1048+i5:+1] ; Sync put splu0,splu1
          Sync get ncsu ; Sync putget ncsu ; MESYNC legs of the fence …       (behind=5)
SPLU0:    Sync get nclu ; Stage w -> XVU ; Sync get nclu ; Stage x -> XVU
XVU0:     Rep i2 x64: pass w[i2] -> TU:0 ; Rep i7 x4: pass x[i7] -> ABSU
ABSU0:    Write a sp[0..3] ; Sync put ablu ; Sync get ablu                    (behind=1: the credit's last get)
ABLU0:0:  Sync put absu ; Sync get absu ; Rep i9 x2: Stage a -> TU:0 lanes=(4*i9, 4)   (ahead=1: the first credit)
TU0:0:    tu_prime ; Rep i4 x56: pass w[8+i4] -> TU:1 ; tu_mac ; tu_drain -> TU:1
TU0:7:    tu_prime ; tu_mac ; tu_drain -> VU
VU0:      Compute accumulate pop=t[7,…] push=s[0,…] -> SPSU arith=(y=mul(red2,0.125))
SPSU0:    Write y sp[1056..1059] ; Sync put ncsu
NCSU:     Sync get spsu0,spsu1 ; Rep i13 x8: Dma store y shm[192+i13:+1] ; Sync put nclu ; Sync putget nclu
```

The NC units' Scripts end in the syncs of the cluster fence (`mpn.fenced`), the `dncs=` MESYNC legs.

**The VU template** (NCore 0, excerpt). The epilogue is the second `FMA`, against a constant the template loads first:

```
Tmpl IMMCOPY {typ1_imm=14336, lrf_tgt=27}                         <- the epilogue's constant
Tmpl IMMCOPY {typ1_imm=0, lrf_tgt=20} … {lrf_tgt=23}              <- the accumulators, zeroed
Tmpl MVLOOPCNT {typ1_imm=1} ×3
Tmpl FMA {src0=2,  src1=14, src2=20, lrf_tgt=20}                  <- accumulate the TU's drain
Tmpl FMA {src0=20, src1=27, src2=10, out_sp=3, lrf_tgt=0}         <- × the constant, out to the SPSU
```

`typ1_imm=14336` is 0.125 in dlf16 (`dlfloat16.codec.dlf16_to_ieee_f32`).

#### Why the pass has four chunks

**The model.** There are three parts: what the mseq means, how the split program runs, and what the split has to
guarantee.

1. **The mseq is a sequential program.** Run its statements one at a time in mseq order `<`, with each `Loop`
   expanded. Each statement reads and writes locations: SP slots `("sp", t, i)`, AB slots `("ab", t, n, i)` and FIFO
   tokens. A read sees the last write to its location before it. This run defines the result.
2. **The Mpn runs in parallel.** Process `P_U` holds unit `U`'s statements in `<` order, plus the syncs the split
   inserts, and runs them one after another. Only these primitives block:
   - FIFO `pop(tok)` waits until `tok` is pushed. `push` waits while the FIFO is full.
   - On a put/get channel `ch`, `put` adds one to `ch`'s counter and waits while the counter is at depth. `get`
     waits until the counter is above 0, then takes one.

   **Happens-before** (`hb`) is the transitive closure of three relations: each process's program order, the
   `i`-th `put` of a channel before its `i`-th `get`, and a token's `push` before its `pop`. Anything `hb` does not
   order may overlap.
3. **The obligation.** Let `U` read slot `ℓ` at `r`, and let `w` be the last write of `ℓ` before `r` in `<`, made
   by a different unit `V`. Then `w hb r` must hold. FIFO tokens meet this by themselves, since `push hb pop`. Only
   SP and AB slots need inserted syncs. A slot written again needs a WAR credit as well; every slot here is written
   once.

**A chunk groups obligations into one put/get pair.** Only sync tokens are grouped; FIFO tokens never depend on
chunks. A sync token carries no data and has no kind. It is one count on one SYNC counter, the channel `V→U`, and
the `i`-th put on that counter matches the `i`-th get. The split could insert one put/get pair per pair `(w, r)`.
Instead it gathers every pair with the same channel `V→U` and the same `c(w)`, the chunk holding `w`, under one put
and one get on that channel (`symsplit.crossings`, `syncs`, `channel_lists`):

- **Put.** `V` puts once, after its last statement in `c(w)`. That is after every `w` of the group, so `w ≤po put`.
- **Get.** `U` gets once, before its first statement in the chunk of its first read of the token. Every `r` of the
  group comes later in `U`'s program order, so `get ≤po r`.

Then `w ≤po put hb get ≤po r` for every pair, so every obligation holds whatever the chunks are. The chunks decide
only what more gets ordered: all of `V`'s work in `c(w)` comes before all of `U`'s work in the chunk of its first
read.

**Worked on 3.5, DNC 0.** These are all the cross-unit SP/AB reads in the mseq. XVU, TU and VU read FIFOs only.

| # | write `w` (unit, chunk) | read `r` (unit, chunk) | slots | token |
|---|---|---|---|---|
| O1 | NCLU `Dma load w` (1) | SPLU0 and SPLU1 `Stage w` (1) | sp 984–1047 | NCLU→SPLUn, chunk 1 |
| O2 | NCLU `Dma load x` ×8 (2) | SPLU0 `Stage x` 1048–1051, SPLU1 `Stage x` 1052–1055 (2) | sp 1048–1055 | NCLU→SPLUn, chunk 2 |
| O3 | ABSUn `Write a` (2) | ABLUn:r `Stage a` ×2, r = 0..7 (3) | sp 0–3 | ABSUn→ABLUn:r, chunk 2 (16 channels) |
| O4 | SPSUn `Write y` (3) | NCSU `Dma store y` ×8 (4) | sp 1056–1063 | SPSUn→NCSU, chunk 3 |

The rule places the syncs in the Scripts above:

```
O1  NCLU:  load w ; put splu0,splu1          SPLU0: get nclu ; Stage w        (same chunk, 1)
O2  NCLU:  load x ×8 ; put splu0,splu1       SPLU0: get nclu ; Stage x        (same chunk, 2)
O3  ABSU0: Write a ; put ablu                ABLU0:r: get absu ; Stage a ×2   (chunk 2 → chunk 3)
O4  SPSU0: Write y ; put ncsu                NCSU: get spsu0,spsu1 ; store ×8 (chunk 3 → chunk 4)
```

The two other syncs in ABSU's and ABLU's Scripts, ABLU's `put absu` and ABSU's `get absu`, are the AB bank's
declared credit (`Credit("a")`): one release at the start and one acquisition at the end. They are not in this
table.

What `hb` orders, and what it leaves free:

- **Ordered:** `load w hb Stage w` (O1) and `load x hb Stage x` (O2). SPLU's program order puts `Stage w` before
  `Stage x`, and XVU's puts its 64 `pass w` before its 4 `pass x`. So x reaches the ABSU after all of w has
  entered the XVU.
- **Free:** `load x` against `Stage w`, the XVU's w passes and TU priming. These overlap only because O1 and O2 are
  separate tokens.
- **The cost of grouping:** SPLU0 reads only rows 1048–1051, but O2's put follows all 8 `load x`. So SPLU0 also
  waits for rows 1052–1055, which only SPLU1 reads.

**The merge, as an example.** Put chunks 1 and 2 into one chunk. O1 and O2 then have the same `(NCLU, SPLUn,
chunk)`, so they become one token. Its put follows the 8th `load x`, and its get precedes `Stage w`, so
`load x hb Stage w`, and TU priming waits for x. This is the change `chunk_merge.py` shows: NCLU's syncs go from 3
to 2 and each SPLU's from 2 to 1. Merging chunks 2 and 3, or 3 and 4, leaves every token's put and get where they
were. ABSU and SPSU have no statement in the later chunk, and ABLU and NCSU have none in the earlier one.

The general test: merging adjacent chunks `a` and `b` changes a Script only if, for some token `V→U`, one of these
holds:

- `V` has groups into `U` in both `a` and `b`, so two tokens become one;
- `V` writes in `a` and still has statements in `b`, so its put moves later;
- `U` first reads in `b` and already has statements in `a`, so its get moves earlier.

The `Chunk.whole` and batched-channel rules refine the grouping. This mseq uses neither.

**How the builder makes four.** The tiling has one N-tile, one K-tile and one M-tile (`lane_blocks = bin = m_tiles =
1`) and no K split (`reduce_size = 1`). `mseq_matmul.build` then takes these branches:

| step | code | result |
|---|---|---|
| `upfront = steps > 1 or B > 1 or (MT > 1 and not double_buffer)` | `mseq_matmul.py:1025` | `False`: each load goes with the stage that reads it |
| `n_tile(0)`, `ti == 0` | `:1249` | `first = m_pass(0, 0)`, the only `Pass` |
| `m_pass` | `:1218` | `Pass(k_walk(0, 0) + reduce(0, 0))` |
| `k_walk`, `B < 2` | `:1144` | `chunks(0)`: a `Chunk` per entry of `(*stages(0, 0, 0), every_nc_products(0, 0, 0))` |
| `stages`, not `upfront`, first pass | `:1033` | two entries: `load_w + weights` and `load_x + inputs` |
| `every_nc_products` | | one entry: ABLU, TU, the VU's `accumulate`, the SPSU's write |
| `reduce`, group of one, root | `:968` | no `Reduce` chunk, and one store chunk per N-tile, so one |

That gives 2 + 1 + 1 = 4. Under `upfront` (more than one N-tile walked in time, more than one K-tile, or M-tiles
not double-buffered), `stages` returns the weights and the inputs as one chunk (`:1043`). `_lead` then puts
`load_w` and `load_x` ahead of it as two chunks of their own.

**Which boundaries carry weight.** Apply the merge test to each crossing:

| boundary | crossing at it | producer in both chunks? | consumer in both? | merging the two |
|---|---|---|---|---|
| 1 \| 2 | NCLU→SPLU0/1: w in 1, x in 2 | yes, NCLU loads in both | no | NCLU puts once, after loading x. SPLU stages w only once x is in SP, so the TU rows no longer prime while x loads |
| 2 \| 3 | ABSU→ABLU:r: `a` in 2 | no | no | none |
| 3 \| 4 | SPSU→NCSU: `y` in 3 | no | no | none |

[`mcc-ir-dump/chunk_merge.py`](mcc-ir-dump/chunk_merge.py) merges each adjacent pair, splits DNC 0 again, and lists
the processes whose syncs change ([`chunk_merge.txt`](mcc-ir-dump/chunk_merge.txt)):

```
body[0] chunk 0+1: 76 channels, violations [], syncs changed (before, after) {'NCLU': (3, 2), 'SPLU0': (2, 1), 'SPLU1': (2, 1)}
body[0] chunk 1+2: 76 channels, violations [], syncs changed (before, after) {}
body[0] chunk 2+3: 76 channels, violations [], syncs changed (before, after) {}
```

NCLU's count includes its fence. The same holds at N=256 (`lane_blocks` 4, five chunks in the first pass) and at
M=512 (`m_tiles` 4). In both, only the w | x boundary of the first pass changes a Script.

So one boundary here is a schedule decision: prime the TU rows before x arrives. The other two only label the
builder's phases.

A merge cannot break a RAW order, but it can deadlock. This happens when `V`, after its write, waits within the same
chunk on work that `U` does only after its get, for example through a FIFO. The split does not check for that:
`violations` checks rate balance and order agreement only.

**Compared with the streaming cases**

| | streaming (3.1, 3.2) | systolic (3.3 to 3.5) |
|---|---|---|
| builder inputs | `StreamBlock`, `StreamPlan`, `StreamIO`, tiling | `m, k, n`, tiling, `arith` |
| chunk | a line range (elementwise) or a phase (softmax) | a phase: weights, AB bank, MAC and drain, store |
| arithmetic | `Compute.arith` per pass on the VU | the card on the TU rows; the epilogue on the VU's `accumulate` |
| SP sync | per chunk (RAW), per pass when a band is reused (WAR) | the same, plus the AB bank's put/get and credit per ABLU row |

## 4. Not covered

- No mseq was printed for flash_attn or the softmax op itself; the rows above for those come from the code and
  docstrings. The cross-DNC `Reduce` is printed in 3.4.
- The JIR passes after `with_edges` (`bind` … `assemble`) were not printed; `--dump` prints them through
  `spine._format_jir`.
- `kpl.decl.Level` (KernelLanguage `src/kpl/decl.py`) was checked only through its repr.
