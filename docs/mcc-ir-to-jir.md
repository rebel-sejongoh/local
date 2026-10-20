# mcc IRs from the kpl declaration down to JIR

- Base: `codesigner` `origin/dev` at `0513ef38f` (2026-10-20). Paths are relative to `PrimitiveAuthor/mcc/`.
- Method: three perf cases were built with spies on the `spine` passes and every level was printed.
  - `tests/perf/add_elementwise/1x16x2x64`: streaming, 16 DNCs.
  - `tests/perf/rms_norm/r1_k2048`: streaming reduce followed by a second pass, 1 DNC.
  - `tests/perf/dense/m128_k64_n64`: systolic, 16 DNCs (shows `mseq_matmul`).
- The scripts and full dumps are in [`mcc-ir-dump/`](mcc-ir-dump/).
  - `dump.py` wraps the `spine` functions and collects their arguments and results.
  - `pp.py` is a compact printer for `Mseq`, `Mpn`, `UnitProgram` and `FabricProgram`. The repo has no printer for them.
  - `all.py` prints every level; `ini.py` prints the systolic initial IR.
  - Run from `PrimitiveAuthor/mcc`: `uv run python ~/workspaces/docs/mcc-ir-dump/all.py tests/perf/<case> [mseq_line_limit]`.
  - Full output: [`mcc-ir-dump/add.txt`](mcc-ir-dump/add.txt), [`mcc-ir-dump/rms.txt`](mcc-ir-dump/rms.txt),
    [`mcc-ir-dump/dense.txt`](mcc-ir-dump/dense.txt).
- Related, older notes: [`mcc-internals.md`](mcc-internals.md), [`mcc-hgdg-jir-sqrt.md`](mcc-hgdg-jir-sqrt.md).

## 1. The levels, top to bottom

| # | IR | Type | One instance is | Produced by | Printer |
|---|---|---|---|---|---|
| 1 | `Declared`, `kpl.decl.Level` | `kpl_declaration.py:316`, KernelLanguage `kpl/decl.py` | a kernel and its workload; `body` is a tuple of `decl.Op` (`Eltwise`, `Reduce`, `Contract`, …) | `declare` | dataclass repr |
| 2 | `Arithmetic` | `grounding/kpl_translate.py:2120` | the compute level that runs, with extents, knobs, problem, repeats and shard | `arithmetic_level_of` (:2161) | dataclass repr |
| 3 | `kpl_ir.Graph` | `grounding/kpl_ir/nodes.py:133` | one level's SSA graph (`InputNode`, `EltwiseOperNode`, `ReduceOperNode`, `ContractOperNode`, `ConstNode`) | `graph_of` (`walk.py:139`) | dataclass repr |
| 4 | `Expr` DAG | `grounding/tracer.py:25` | one numpy op per node; `kind` is input, map, reduce (slice, index) | `dag_of` (`kpl_translate.py:1865`) replaying the graph through the tracer | dataclass repr |
| 5 | `TracedOp`, with `TilingDecision` and `Mdmap` | `grounding/trace.py:329`, `tiling.py:112`, `mdmap.py:32` | one op: the DAG plus axes, `cross_dnc`, placement, `unit_data`, spec, tiling; `Mdmap` splits each axis over DNCs | `_lowered` / `build` in `kpl_declaration.py`, then `.tiled` (`trace.py:1011`) | **`trace_print.format_tiled`** (`trace_print.py:36`) |
| 6 | `StreamBlock`, `StreamPlan` (streaming only) | `grounding/beat.py:30`, `grounding/mdmap_stream.py:183` | a streaming block: its passes, tensor ranks, K, route; the chunk plan and the VU beat | `mdmap_stream.plan(block_of(trace))` (`spine.py:329`) | dataclass repr |
| 7 | **`Mseq`** | `grounding/mseq.py:288` | one DNC's sequential program: every unit's statements in one body, in program order | `mseq_*.chip`, then `at_addresses` (:376) | none |
| 8 | **`Mpn`** | `grounding/mpn.py:536` (`Process` :395, `Channel` :520) | one DNC split into per-unit processes and the channels between them | `split_chip` (:586), through `symsplit.assemble` | none |
| 9 | `Mapped` | `lowering/mpn_syncs.py:610` | the chain for one build: `op`, `seqs` (addressed mseqs), `nets` ({dnc: Mpn}), `events`, `rolled()`, `check` | `mpn_syncs.mapped` (:652, `spine.py:337`) | none |
| 10 | `passes(seqs)` | `grounding/mseq.py:542` | `((unit, arith), …)` for the build | walking the mseqs (`spine.py:377`) | tuple repr |
| 11 | `unit_layouts`, initial IR (systolic only) | `grounding/layouts.py`, `lowering/initial.py` | `{(producer, consumer, tensor): Layout}`; `UnitIR` per unit | `unit_layouts.unit_layouts`, `initial_ir` (:293) | **`Layout.__str__`**, **`initial.pretty`** (:348) |
| 12 | `UnitProgram` | `ir/unit_program.py:14` | one unit instance; its `template` field is the JIR | `coordination.derive_unit` (:1363) | dataclass repr |
| 13 | `FabricProgram` | `ir/coordination_ir.py:137` | the whole fabric: every `UnitProgram` plus coordination `Channel` (:87) and `Edge` (:72) | `collect_programs` (`spine.py:417`) | dataclass repr |

- The IRs strictly before JIR are levels 5 to 11.
- Levels 12 and 13 hold the JIR. A template is built from `jir.Tmpl`/`Label` and the authoring nodes in `ir/nodes.py`
  (`_Loop` :49, `_Frame` :146, `_Vocab` :18, `_SignalReduce` :31).
- After `collect_programs`, `spine.realize` runs `with_edges`, `fold_templates`, `resolve_kind_trips`,
  `walks_from_process` (systolic), `verify_emission`, `mapped.check` and `bind_templates` (:449), then JIR lowering.
- The repo's only printers on this path are `format_tiled`, `Layout.__str__` and `initial.pretty`.

## 2. Mseq

**What it is** (`grounding/mseq.py:1-104`, `Mseq` :288)

- One DNC's program in program order. Every statement names its unit, NCore, SP slot and tokens.
- A token is `(tensor, idx…)`.
- Fields: `dnc`, `op`, `tensors`, `body`, `ranks` (streaming only), `grid` (mdmap coordinates), `problems`,
  `addressed`/`lined` (tensors with real addresses).
- The mpn split and the test interpreter (`tests/mseq_interpret.py`) read the same order.

**Vocabulary**

- Structure
  - `Pass(lo, n, body=Chunks)`: one SP band that is reused.
  - `Chunk(lo, n, body, via, whole)`: the unit of synchronization. `via` is a collective's give/take tag; `whole`
    names a unit that reads the chunk at once.
  - `Loop(unit, trips, body, count, lines, tokens, lo, slots, keys, chunk_lo, rows, lanes, ncs)` (:233): a stride
    compression of repeated statements. `unit` is `mpass`, `cpass`, `batch`, `sfold`, `accum`, `line`, `strip` or
    `run` (`run` compresses a list, it is not a level). `expand` (:517) unrolls the trips.
- Statements
  - `Dma(dst SP|SHM, tensor, lo, slot, n, nc, stride)`: an NC load or store.
  - `Stage(tensor, slots, toks, nc, dst, unit, splat, lanes, rows)`: SPLU/ABLU push into a FIFO.
  - `Compute(op, unit, nc, pops, pushes, to, arith)`.
  - `Write(tensor, slots, toks, nc, src, unit, rows)`: SPSU/ABSU.
  - `Reduce(group, instance, band, parts=Part…, leaf_lines, units, op, arith)`: a cross-DNC collective, expanded by
    `collective.gather`.
  - `Fence(dncs)`.
- Tensor ranks: `streamed`, `scalar`, `collapsed`, `staged`, `broadcast`, `republished`.
- The mpn adds `Put`/`Get` (`mpn.py:71`/`:79`), `Process`, `Channel` (transport FIFO or SP; protocol
  backpressure, put/get or credit), and the per-unit loop view `mpn.Level`/`unit_view` (:105/:134).

**How `passes` is derived** (`mseq.py:542`)

- Walk every mseq into its loops, passes and chunks.
- Collect each `Compute.arith` that is not `()`, deduplicated in first-seen order.
- Name the unit without its row suffix (`TU:3` → `TU`).
- `Compute.arith` is `TracedOp.arith` (`trace.py:911`), which `mpn_syncs.arith_of` turns into a tuple for the builder:
  - streaming: the DAG split per pass by `node_passes`, without the inputs;
  - systolic: `{TU: card}`, plus the epilogue on the drain unit when there is one.
- So `passes` is the trace's arithmetic after one round trip through the mseqs.

**Builders** (selection in `mpn_syncs.mapped`, :716-732)

- systolic → `mseq_matmul`.
- streaming with one pass → `mseq_elementwise` if every output is streamed, else `mseq_reduce`.
- streaming with several passes → `mseq_softmax` if `mseq_softmax.form` matches, else `mseq_flash_attn`.
  RMSNorm takes the softmax builder.

| Builder | For | What it builds |
|---|---|---|
| `mseq_elementwise.chip` (:323) | one pass, every output streamed | Rows in lanes. A `Loop[mpass]` per tile (with problems), a `Loop[line]` per chunk, and Stage → VU Compute → Write per line. No collective, only a Fence. `walk` rebuilds it with the beat unroll. |
| `mseq_reduce.chip` (:248) | one pass, collapsed output | The same movement with a running sum on the VU, pushed after the last line and written and stored in the last chunk. The `across_lanes` variant adds a handoff band (`<out>.handoff`), a splat reload and a republished rank. |
| `mseq_softmax.chip` (:921) | several passes in softmax form (RMSNorm included) | Per row group: A max → B exp + sum → C normalize (on the XVU or the VU), optionally skewing A one group ahead. In the rows-in-lanes form (`LaneMap`, `build_lanes`) the VU runs every pass. A per-row scalar is reloaded through SP (broadcast or staged rank). |
| `mseq_matmul.chip` (:1232) | systolic matmul and conv | One pass per N-tile × K-tile. w: SPLU → XVU → TU rows 0..7 (`tu_prime`, `pass`). x: XVU → ABSU → AB → ABLU row → TU (`tu_mac`, `tu_drain` chain). VU `accumulate` → SPSU → NCSU. A K split adds a `Reduce` (gather). M-tile loops, double buffering, `batch_sums`; `chip_nets` rebuilds after the symsplit depth analysis. `ranks` is empty and `grid` is set. TU and ABLU are per-row units (`TU:r`). |
| `mseq_flash_attn.chip` (:550) | other multi-pass ops (the flash-attention tiling half) | Pass A masked score + max, pass B exp + sum. A line arm (rows in lanes) and a lane arm (collapsed, handoff band, splat). `Chunk.whole` on the NCSU store chunk. |

## 3. Printed IR

### 3.1 add_elementwise 1x16x2x64 (R = 1024, K = 2)

`decl.Level.body`, `kpl_ir.Graph`, `Expr` DAG:

```
(Eltwise(args=(0, 1), op='add', imm=None),)
Graph inputs: (InputNode(name='input1', axes=('R','K')), InputNode(name='input2', axes=('R','K')))
   EltwiseOperNode(name='v0', op='add', deps=(InputNode(input1..), InputNode(input2..)))
Expr: input1:in[R,K] / input2:in[R,K] / add1=add(input1,input2)  [out]
  axes={'lane': ('R','r'), 'reduce': (('K','k','beat'),)} cross_dnc=None unit_data={'VU': {'dtype': 'dlf16'}}
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

Here `boundary` is empty: the syncs are `SYNC_ROLE` nodes inside the template, derived from the processes
(`from_process`).

### 3.2 rms_norm r1_k2048 (a reduce, then a second pass)

```
decl body: (Eltwise(mul,(0,0)), Reduce((2,),K,add), Eltwise((3,),mul,imm=0.000488), Eltwise(rsqrt), Eltwise(mul,(0,5)), Eltwise(mul,(6,1)))
Expr: input:in[R,K] scale:in[K] mul1=mul(input,input) red2=reduce.add[K](mul1) mul3=mul(red2,0.00048828125)
      rsqrt4=rsqrt(mul3) mul5=mul(input,rsqrt4) mul6=mul(mul5,scale)
  axes={'lane': ('K','k'), 'shard': ('R','r'), 'reduce': (('K','k','lane'),)}
format_tiled (excerpt): dnc[1] = shard.R[1] × split.K[1] / LEAF R=1:line, reduce K.blk[32] × K.in[64] / cadence npass=2
StreamBlock: passes=[[mul1, red2, mul3, rsqrt4], [mul5, mul6]] shared=('scale',) broadcast=(('rsqrt4',0),) K=32 units=('VU','VU')
Mapped op=softmax
```

`Mapped op=softmax`: RMSNorm passes `mseq_softmax.form` and is built in the softmax builder's lane form.

`Mseq` for DNC 0 (nothing trimmed):

```
Mseq dnc=0 op=softmax tensors=('input', 'scale', 'mul6')
  ranks={'input': 'streamed', 'scale': 'streamed', 'rsqrt4': 'broadcast', 'mul6': 'streamed'}
  Loop[mpass] x1 lines={'input': 32, 'scale': 0, 'mul6': 32} tokens={...} lo=1
    Pass lo=0 n=32
      Chunk lo=0 n=0
        Dma load  input shm[1:+32] -> nc0.sp[1:+32]
        Dma load  scale shm[34:+32] -> nc0.sp[34:+32]
      Chunk lo=0 n=0
        Loop[run] x32 slots={'input': 1, 'scale': 1}
          Stage SPLU0 input sp[1] -> VU ; Stage SPLU0 scale sp[34] -> VU
          Compute VU0 op=max_acc pop=input[0,0],scale[0,0] push= -> SPSU arith=(mul1; red2; mul3; rsqrt4)
        Compute VU0 op=max_out pop= push=rsqrt4[0] -> SPSU arith=(mul1; red2; mul3; rsqrt4)
        Write SPSU0 rsqrt4 sp[67] <- VU
      Chunk lo=0 n=0
        Stage SPLU0 rsqrt4 sp[67] -> VU toks=rsqrt4[0] splat
        Compute VU0 op=hold_sum pop=rsqrt4[0] arith=(mul5; mul6)
        Loop[run] x32 ...
          Stage input / Stage scale
          Compute VU0 op=normalize pop=input[0,0],scale[0,0] push=mul6[0,0] -> SPSU arith=(mul5; mul6)
          Write SPSU0 mul6 sp[69] <- VU
      Chunk lo=0 n=0
        Dma store mul6 shm[67:+32] <- nc0.sp[69:+32]
  Fence dncs=0..0
passes = (('VU', (mul1, red2, mul3, rsqrt4)), ('VU', (mul5, mul6)))
```

- The op labels (`max_acc`, `max_out`, `hold_sum`, `normalize`) are the softmax builder's names.
- `Compute ... op=max_out` after the first loop is the scalar work after the reduce (the epilogue). Its result goes
  through SP and comes back as a splat `Stage` in the next chunk.

`Mpn` for DNC 0 has 5 processes and 5 channels (SPLU0 has 131 statements and VU0 66; only the channel table is shown):

```
  SPLU0->VU0  FIFO/backpressure tokens=129
  VU0->SPSU0  FIFO/backpressure tokens=33     (rsqrt4 1 + mul6 32)
  NCLU->SPLU0 SP/put/get cap=1 depth=16
  SPSU0->NCSU SP/put/get cap=1 depth=16 first=[2]
  SPSU0->SPLU0 SP/put/get cap=1 depth=4       <- the broadcast scalar handed to the next pass through SP
FabricProgram: c2 Carried ('SPSU',0)->('SPLU',0) roles=('war','reload') gran='credit'
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
unit_layouts (Layout.__str__, excerpt):
  ('NCLU','SPLU','w') -> [N=64:1λ K=64:1L]·SP @kernel
  ('ABSU','ABLU','x') -> [M.nc=2:4ρ M=4:1λ K.grp=8:8L K.in=8:1L]·SP @ab_bank
  ('ABLU','TU','x')   -> [M.nc=2:4ρ M=4:1λ K.grp=8:8L K.in=8:-1L]·SP @ab_bank
initial.pretty (TU):
  stream y: for N in 0..63: for M.nc in 0..1: for M in 0..3: for K in 0..63:
      read w[N:1λ K:1L] <- ; read x[M.nc:4row M:1λ K.grp:8L K.in:-1L] <- ; apply <tuple> ; write y[N:1λ M.nc:4row M:1L] ->
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
- `Mpn[0]` has 44 processes (NCLU, SPLU0/1, XVU0/1, ABSU0/1, ABLU0:0..7, TU0:0..7, VU, SPSU, NCSU, …) and 60 channels.
- `FabricProgram`: units=480, sp_fan=2, mesync=ClusterBarrier; channel flavors Barrier, Fan, Carried (credit), Gather.
  The templates hold `ir/nodes.py` nodes such as `_Frame axes=('Bmb','Br','Bout')`, `_Loop kind=axis axes=('Bout',)`
  and `_Vocab sp_immc {...}`.

## 4. Not covered

- No mseq was printed for flash_attn, the softmax op itself, or a cross-DNC `Reduce` (a K split); the three examples
  have none. The rows above for those come from the code and docstrings.
- `kpl.decl.Level` (KernelLanguage `src/kpl/decl.py`) was checked only through its repr.
