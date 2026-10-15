# mcc Internals: IRs, Passes, Lowering, Mapping

- 기준: `~/workspaces/codesigner` `dev` `aafd7348`. 경로는 `PrimitiveAuthor/mcc/` 기준.
- 1차 출처: `ARCHITECTURE.md`, `LAYOUT_ALGEBRA.md`, `ADDRESS_FACET.md`, `src/mcc/spine.py`(`realize`), 각 모듈 docstring.
- 예제 출력: sqrt는 `~/workspaces/docs/mcc/ir.txt`, matmul(64×64×64)은 `../scripts/dump_matmul_hgdg.py`로 직접 실행.

## 0. The Key Idea

> **Layout is a type, and synthesis is that type run forward.** (`ARCHITECTURE.md`)

- 텐서 layout = (축, 크기, stride, 하드웨어 축) + 메모리.
- 명령마다 transfer function이 있다: `(in_layouts, op-card, policy) → (out_layout, records)`.
  - 출력 layout만 계산하면 → 타입 검사.
  - records까지 만들면 → 코드 생성. mcc는 이 방향이다.
- 모든 반복 횟수와 주소가 layout 축 크기에서 나오므로, tiling을 바꾸면 숫자만 바뀌고 코드는 그대로다.
- 코드 어디에도 op 이름(matmul, softmax…)으로 분기하지 않는다(`check_op_agnostic.py`가 강제). 분기는 **dataflow 종류**(systolic / weight-streaming / streaming)로만 한다.

## 1. Intermediate IRs

| # | IR | 추상화 수준 (무엇을 말하나) | 핵심 타입 / 파일 |
|---|---|---|---|
| 0 | kpl `Level` | 사용자가 쓴 계산 graph. 하드웨어 없음 | `KernelLanguage/src/kpl/decl.py` |
| 1 | **Expr DAG / `TracedOp`** | 축 이름 위의 원소별 계산(map/reduce) | `grounding/tracer.py:25`, `grounding/trace.py:328` |
| 1' | **tiled `TracedOp`** | + 각 축을 어느 하드웨어 자원(DNC/NCore/lane/temporal)에 쓸지 | `grounding/tiling.py` `TilingDecision`, `grounding/geometry.py` `AxisBinding`/`Level` |
| 2 | **HGDG** | + 어느 유닛이 맡고, 각 edge에 layout(타입)·cadence·sync 방식. 한 DNC 기준 | `grounding/hgdg.py` `HGDG/DNode/DEdge`, `grounding/layouts.py` `Layout/Axis` |
| 3 | **JIR (unit template)** | 유닛별 명령 template: symbolic 즉값, label, loop/frame/address-intent 노드 | `ir/jir.py`, `ir/nodes.py`, `ir/expr.py` |
| 4 | **Coordination IR (`FabricProgram`)** | 전체 fabric의 `UnitProgram`들 + 유닛 간 sync channel | `ir/coordination_ir.py`, `ir/unit_program.py` |
| 5 | records → block → image | 구체 명령(opcode+필드), 프레임된 block, 바이트 | `dnckit.authoring.rec`, `assembling/` |

(보조: `lowering/initial.py`의 Initial IR = 유닛별 loop nest over effects. 검증·설명용.)

### 1.1 Expr DAG / TracedOp (IR 1)

- **syntax**: `Expr(name, kind ∈ {input, map, reduce, slice, index}, deps, axes, axis, monoid, op, imm, out)`.
- **semantics**: 원소별 함수. `map`의 축 = 피연산자 축의 합집합(broadcast), `reduce`는 한 축을 지운다.
- `TracedOp` annotation: `axes`(축 → 하드웨어 역할), `cross_dnc`(gather/tree), `placement`, `lane`, `spec`(주소 등), `.tiled()` 후 `tiling`.
- 출력 예(`trace_print.format_tiled`, matmul):
  ```
  dag      x:[R,K]  w:[K,I]  mul1 = mul(x,w)  y = reduce.add(mul1) → out
           card ComputeOperands(combine=mul, reduce=add, stationary=north, streamed=west)
           roles lane=I shard=R contract=K
  spatial  dnc[16] = shard.R[16] × split.K.beat[1]
  temporal LEAF I=64:lane · R=4:line ;  reduce K.col[8] × K.beat[8]
  buffers  SP:kernel w @NCLU ; SP:ab_bank x @NCLU ; SP:tu_psum y @TU ; SP:vu_acc acc @VU
  ```

### 1.2 Axis binding (IR 1', tiling의 내용)

축마다 **바깥→안쪽 레벨의 리스트**. 레벨 = (하드웨어 자원, 크기, leaf 안/밖, trip expr). matmul 실제 값:
```
R: DNC_SHARD 16 → MPASS 1 → NCORE 1 → LEAF 4          (free 축: 16 DNC에 나눠 각 4행)
I: NCORE 1 → CPASS 1 → LANE 64                         (lane 축: 64 lane SIMD)
K: BIN 1 → COL 8 → BEAT 8            reduced=True     (contract 축: TU 8열 × 8 beat)
```
자원 종류: `DNC_SHARD`(공간, DNC 간), `NCORE`, `LANE`, `COL`/`ROW`(TU), 시간 쪽 `BEAT`/`MPASS`/`CPASS`/`BIN`/`LEAF` 등. reduced 축의 시간 레벨은 "같은 tile에 누적", free 축의 시간 레벨은 "다음 tile".

### 1.3 HGDG (IR 2) — 빌드의 의미상 SSOT

- **syntax**: `DNode(unit, kind ∈ {boundary, mover, compute}, arith, broadcast)`, `DEdge(prod, cons, tensor, type: Layout, cadence, sync: Coupling)`.
- **semantics**: **한 DNC**가 하는 일의 dataflow. 노드는 유닛 *이름*(실제 블록 `HNode`는 matmul에서 480개지만 DNode는 9개). edge의 `type`이 그 지점에서 텐서가 놓인 모양.
- **Layout 문법**: `[축=크기:stride단위 ...]·메모리 @base`. 단위 기호:

  | 기호 | unit | 의미 |
  |---|---|---|
  | `L` | line | 주소에 기여 (`line = Σ idx·stride`) |
  | `λ` | lane | 한 줄 안의 64 lane, 주소 비용 없음 |
  | `ρ` `γ` | row, col | 어느 물리 유닛 |
  | `⇢ ⊕ τ ∘ ∘m ∘c` | stream, accum, trip, pass, mpass, cpass | **시간**: 하드웨어가 유한해서 시간으로 바뀐 인덱스 |
  | `★` `⊞` | bcast(stride 0), window | 복제, conv 창 |

- `Coupling`: edge의 동기화 방식. FIFO로 흐르면 backpressure로 충분(명령 불필요), 양쪽이 같은 메모리를 주소로 접근하면 SYNC가 필요.
- matmul 실제 edge(한 DNC):
  ```
  NCLU→SPLU→XVU→TU    w  [I=64:1λ K=64:1L]·SP @kernel                 # north, 평탄
  NCLU→SPLU→XVU→ABSU  x  [R=4:1λ K=64:1L]·SP @ab_bank
  ABSU→ABLU           x  [R=4:1λ K.grp=8:8L K.in=8:1L]                  # K를 8×8로 split
  ABLU→TU             x  [R=4:1λ K.grp=8:8L K.in=8:-1L]                 # 안쪽 8개 reverse
  TU→VU→SPSU→NCSU     y  [I=64:1λ R=4:1L]·SP @tu_psum                   # 출력: N이 lane, M이 line
  ```
- sqrt: `SHM ─[R=256 K=64]·SHM─▶ NCLU ─[R=64 K=64]·SP─▶ SPLU ─▶ VU0_sqrt ─▶ SPSU ─▶ NCSU ─▶ SHM`

### 1.4 JIR (IR 3)

- **syntax**:
  - `Tmpl(opcode, params)`: 명령 하나. params 값은 int, `Expr`(symbolic 즉값), `LabelRef`.
  - `Label`, `LabelRef`: jump 목표. `Repeat(count, body)`: 펼칠 반복. `VReg`: 가상 레지스터.
  - 구조 노드(`ir/nodes.py`): `_Loop(mv, body)` → `MVLOOPCNT`+body+`be=1`, `_Frame(mvs, body)` → 1-trip loop 골격 + NOP close, `_Vocab(kind, args)` → 주소 의도(`sp_immc`, `sp_mod`, `car_add`, `shm_advance` …), `_SignalReduce(legs)` → DNC 간 reduce 다리(MESYNC).
  - 유사 opcode `SYNC_ROLE{ref, _role{put,get,peers}}`: 아직 bitmask로 안 바뀐 동기화 의도.
- `ir/expr.py`의 즉값 언어: `Const`, `Param`(DNC별로 채울 구멍), `Reg`(실행 시 JCR), `Add/Sub/Mul/Min/Max/CeilDiv/And`.
- **semantics**: 한 유닛의 명령 열 *template*. DNC별 차이(`Param`)와 주소 계산(`_Vocab`)이 아직 기호로 남아 있다.
- 예(SPSU, sqrt):
  ```
  Tmpl(MVLOOPCNT, {typ1_imm: 64})
  Tmpl(STU, {src0: 0, src1: 1, st_producer: 2, burst: 0, be: 1})
  Tmpl(SYNC_ROLE, {ref: 'egress', _role: {put: True, peers: ['NCSU']}})   → 나중에 SYNC typ1_imm=9
  Tmpl(RETURN, {be: 0})
  ```

### 1.5 Coordination IR (IR 4)

- `FabricProgram(unit_programs, channels, edges, carried, sp_fan, mesync, reduces, …)`.
- `UnitProgram(unit, dnc, ncore, col, template, env, lrf_raw, lccr_raw, framing, …)`: 블록 하나의 순수 데이터.
- `Channel(id, flavor ∈ {Signal, Stream, Carried, …}, src, dst, tensor, initial, roles, fires)`: 유닛 간 동기화 사실 하나. sqrt: `Signal NCLU→SPLU (load)`, `Stream SPLU→VU→SPSU`, `Signal SPSU→NCSU (drain)`, `Carried SPSU→SPLU (WAR credit, initial=1)`.

## 2. Passes (`spine.realize` 순서)

### A. Grounding (`grounding/`)

| pass | 하는 일 |
|---|---|
| (pre) `kpl_translate.dag_of` → `place.trace_op` | kpl graph → Expr. `lower_divide`(div → recip·mul), `reroll`(펼친 loop 누적 → reduce 축, conv tap) |
| (pre) `tiling.derive_fabric_tiling` / `tiling_for` | shape → `TilingDecision`(shard 수, contraction split, tile 수, fan) |
| `require_tiled` | tiling 붙었는지 경계 검사 |
| `_ground_frame`: `substrate_frame`, `build_fabric` | 256-node fabric(`HNode`) 생성, SP memmap, SHM staging, MESYNC 토폴로지 |
| `_ground_seeds`: `seed_ctx`/`seed_views`/`place_seed` | **seed**: 각 텐서가 태어나는 (유닛, 텐서)의 Layout. DNC 간 레벨은 나눠 빼서 **한 DNC 몫**만 |
| `_widen_to_group` | DNC 간 reduce가 있으면(K-split) SPMD 그룹으로 확장, sibling edge 생성 |
| `io_memory_of`, `derive_transforms`, `temporal_readouts` | 외부 메모리 경계, mover가 해야 할 layout 변환(prim 목록), 시간 readout 표 |
| `_ground_flow`: `resolve_routing`, `route_dataflow` | **유일한 systolic/streaming 분기**. pass마다 fabric spine을 따라 경로를 잡고, 경로 위의 유닛이 **mover로 "떨어져 나온다"**(삽입하지 않음) |
| `schedule_cadence` | edge마다 시간 cadence(입력/출력/stationary …) |
| **`propagate`** (flood) | seed에서 출발해 모든 edge에 layout 타입을 붙임. mover가 transform 수행 |
| `couple` | edge마다 동기화 방식(FIFO / SYNC / cross-DNC handshake) |
| `HGDG(...)` | 타입·cadence·coupling이 붙은 **frozen** graph 생성 |

### B. Emission (`lowering/`)

| pass | 하는 일 |
|---|---|
| `systolic_emit_facets` / `streaming_emit_facets` | 유닛별 emit 문맥(facet) |
| `edge_layouts`, `reduce_edges` | emitter가 읽을 edge layout, DNC 간 rendezvous를 실제 DNC에 배치 |
| for SPMD group → DNC → unit: **`derive_unit`** | 유닛별 `emit_<unit>.derive_template` → JIR. 이 안에서 **7 derivation law**가 fatal check로 돈다(아래) |
| `check_unit_syncs`, `locate_unit` | sync law 재검사, 위치 정보 |
| `collect_programs` → `with_edges` | `FabricProgram` 조립, 토폴로지 부착 |
| `fold_templates` (`canon.py`) | 동일 반복을 loop로 접는 canonical form |
| `resolve_kind_trips`, `with_nclu_walks` | loop 종류별 trip 확정, NCLU 주소 walk 삽입 |
| `verify_emission` | **19개 emission law** 검사 |

7 derivation law (`lowering/<name>.py`):

| law | 질문 |
|---|---|
| `placement` | tiling이 각 유닛의 논리적 트래픽을 덮는가 |
| `nest` | loop 레벨마다 trip = 그것을 만든 축 크기인가 |
| `blocking` | beat가 머신에서 합법이고 burst 합과 맞는가 |
| `addressing` | store 주소 궤적이 독립적인 재구성과 일치하는가 |
| `selection` | 텐서 역할마다 descriptor 레지스터가 있는가 |
| `cadence` | channel 발사 속도가 loop nest와 맞는가 |
| `priming` | nest가 읽는 레지스터가 읽기 전에 초기화되는가 |

+ `tokens.py`: channel 보존 법칙(한쪽이 push한 만큼 다른 쪽이 pop).

### C. Binding

| pass | 하는 일 |
|---|---|
| `bind_templates` | `SYNC_ROLE` → channel 표 → 구체 `SYNC` bitmask |
| `record_fires` | channel별 발사 횟수 기록 |

### D. Per-unit lowering + assembly (`assembling/`)

| pass | 제거/생성 |
|---|---|
| `lower_frame` | `_Frame` → MVLOOPCNT 스택 + body + NOP close cascade |
| `lower_vocab` | `_Vocab` → 주소 레지스터 명령(`MODLRFIMM`, `ADDCXRIMM` …) |
| `lower_loops` | `_Loop` → `MVLOOPCNT` + body(`be=1`) |
| `lower_signals` | `_SignalReduce` → MESYNC 다리 |
| `partial_eval` | template + env → 구체 record. PC 배정, `Label` 해석, `Repeat` 전개, `Expr` 계산 |
| `fold_records` | DNC 안 시간 fold |
| `frame_block` | records → block(header/SPR/LCCR/LRF/IBUFF) |
| `alloc.apply` | 남은 자유도: LRF 슬롯 배정 |
| `retarget_block` | NCore 선택 / broadcast |
| `patch_dynloop_exit` | dynamic loop의 exit PC |
| `assemble` | flit 배치 → image + DNC별 bounds |

## 3. Abstraction Lowering Summary

각 단계가 **결정하는 것**과 **없애는 추상화**:

```
kpl Level        "무엇을 계산"            축 이름, 기호 크기, op 이름
   │  dag_of: op 이름 → 원소 연산(map/reduce), div/matmul 분해
Expr DAG         "원소별 계산"            하드웨어 없음
   │  tiling: 각 축 = 자원 레벨의 곱 (공간 DNC/NCore/lane/col, 시간 beat/pass)
tiled trace      "얼마나 나누나"          유닛·메모리·layout 없음
   │  grounding: 유닛 배치, 경로(mover), layout 타입(flood), cadence, sync 종류
HGDG             "어디서, 어떤 모양으로"   명령 없음, 한 DNC 기준
   │  emission: 유닛별 명령 template, loop nest, 주소 의도, sync 의도 / SPMD로 DNC 펼침
JIR + FabricProg "무슨 명령으로"          즉값 기호, label, 구조 노드, SYNC_ROLE 남음
   │  binding: SYNC_ROLE → bitmask
   │  lower_frame/vocab/loops/signals: 구조 노드 제거
   │  partial_eval: 기호 즉값·label·Repeat 제거
records          "구체 명령"              레지스터 슬롯, 블록 프레임 남음
   │  frame/alloc/retarget/assemble
image.bin        바이트
```

## 4. Mapping (Grounding) and Tensor Layout

### 4.1 문제를 이렇게 나눈다

| 하위 문제 | 푸는 방법 | 위치 |
|---|---|---|
| ① 축을 하드웨어 자원에 배분 | **closed-form 규칙**(검색 아님). role 크기 (m=shard 축, n=lane 축, k=contract 축) → `TilingDecision`. 결과는 축마다 자원 레벨 리스트(`AxisBinding`) | `tiling.py` `derive_fabric_tiling`, `geometry.binding` |
| ② 한 DNC의 몫 | DNC 간 레벨을 나눠 빼서 **seed는 한 DNC 몫**. 모든 DNC가 같은 seed(SPMD), DNC별 차이는 주소(memmap)로만 | `place.seed_views`, `check_seeds_cover_one_replica` |
| ③ 유닛 배치·경로 | 연산은 compute 유닛(VU/TU)에 고정. 입출력은 fabric spine을 따라 경로를 잡고 **경로상의 유닛이 mover가 된다**. 대부분 후계자가 하나라 선택지는 fan에서만 생김 | `resolve_routing`, `route_dataflow` |
| ④ layout 맞추기 | **타입 추론(flood)**. seed layout을 edge 따라 전파. 소비자가 요구하는 layout과 다르면 선언된 transform을 **그것을 할 수 있는 mover**(`caps`)에 배정 | `hgdg.propagate`, `place.derive_transforms` |
| ⑤ 시간·동기화 | edge cadence, coupling(FIFO vs SYNC) | `schedule_cadence`, `couple` |
| ⑥ 주소 | 주소는 명령이 아니라 **레지스터**에 있다. 주소 모델 = cursor 레지스터 프로그램(`_Vocab`). 값은 memmap의 projection | `sp_addr`, `shm_addr`, `nc_addr`, `ADDRESS_FACET.md` |

### 4.2 Layout transforms are a handful of prims

전체 corpus(matmul, conv, softmax)에서 mover가 하는 변환은 7개 prim뿐이고, 계열로는 아래 셋이다(`place.derive_transforms`).

- `("split", contraction, cols)` + `("reverse", inner)`: weight-stationary feed 규칙. 위 matmul의 `ABSU`(K → grp 8 × in 8)와 `ABLU`(안쪽 reverse)가 이것.
- `("broadcast", axis, extent, "bcast")`: reduce로 접힌 값을 다시 펼침(softmax의 `x − max`). stride 0 축으로 표현.
- 메모리 공간 변경(`memspace`)은 mover가 아니라 re-seed로 처리.

### 4.3 TU contraction 규약 (측정으로 확정)

| port | 피연산자 | free 축 | contraction 방향 layout |
|---|---|---|---|
| north | kernel(레지스터에 고정) | N → 출력 lane | 평탄, stride +1 |
| west | activation(스트리밍) | M → 출력 line | `lane_reverse-8` = `[grp:+8, in=8:-1]` |
| output | C | | `[N:lane, M:line]` |

- `tu_fold`가 강제하는 조건: 두 feed가 contraction 방향에서 **정확히 하나만 reverse**. 둘 다 평탄(알려진 silicon 버그)이나 둘 다 reverse는 거부.
- 근거: PrecSim trace, 비정사각 dump(M=128, N=64), 출력 영역 역독 검증.

### 4.4 검증

- layout 규칙은 `deal` design-by-contract로 쓰고, Hypothesis가 생성한 임의 layout으로 테스트(`layouts.py`, `seam.py`).
- `opmodel.py`의 opcode별 fold와 `typing_rules.py`의 수작업 규칙이 서로 일치해야 한다(`test_opmodel_fold.py`). 모델에 없는 opcode는 예외 → "자신 있게 틀린 layout"이 나올 수 없음.
- 7 derivation law, 19 emission law는 모두 fatal. 끄는 모드가 없다.

## 5. Where to Read Next

1. `src/mcc/spine.py` `realize` (L471–683): 전체 pass 체인이 한 함수에 순서대로 있다.
2. `ARCHITECTURE.md`, `LAYOUT_ALGEBRA.md`, `ADDRESS_FACET.md`, `SYNC_FINDINGS.md`, `OP_FRONT.md`.
3. `grounding/layouts.py` 모듈 docstring(12개 unit), `grounding/hgdg.py` `propagate`.
4. `lowering/emit_vu.py`, `emit_splu.py` (가장 단순한 streaming 경로부터).
