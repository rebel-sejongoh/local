# mcc HGDG와 JIR: pass별 덤프와 annotation (sqrt)

- 기준: `~/workspaces/codesigner` `dev` `344c1a2f2` (2026-10-06). 경로는 `PrimitiveAuthor/mcc/src/mcc/` 기준.
- 예제: `examples/kpl/sqrt.py` (`R=256, K=64`). `mcc build` 결과는 7680 B / DNC 4개로, 이전 문서(`aafd7348`)와 같다.
- 덤프 스크립트: `~/workspaces/local/docs/mcc/dump_passes.py`. 전체 출력: `~/workspaces/local/docs/mcc/sqrt_passes.txt`(DNC 0만, 647줄).

```bash
cd ~/workspaces/codesigner/PrimitiveAuthor/mcc
uv run python ~/workspaces/local/docs/mcc/dump_passes.py examples/kpl/sqrt.py [--dnc N] > out.txt
```

스크립트는 `mcc.spine` 모듈에서 각 pass의 이름을 래퍼로 바꿔 끼운다. `realize`가 pass를 그 모듈의 전역 이름으로 찾기 때문에 이 방식이 통한다. 래퍼는 pass가 끝나는 즉시 결과를 출력한다. `fold_templates` 같은 pass는 `UnitProgram.template`을 제자리에서 고치므로, 결과를 나중에 모아서 찍으면 앞 단계의 상태를 볼 수 없다.

## 0. Pass 지도 (`spine.realize`, `spine.py:471`)

| 덤프 | pass | 입력 → 출력 | sqrt에서 일어난 일 |
|---|---|---|---|
| H0 | (입력) tiled `TracedOp` | | `sqrt1 = sqrt(inp)`, `dnc[4] = shard.R[4]`, `LEAF R=64:lane`, `K[64]` |
| H1 | `_ground_seeds` | trace → `{(unit, tensor): Layout}` | seed 3개. SHM은 전체 크기, on-chip은 DNC 하나의 몫 |
| H2 | `_widen_to_group` | seeds → (seeds, sibling, width) | DNC 간 reduce가 없어서 `width=1`, sibling 없음 |
| H3 | `derive_transforms` | → `{(consumer, tensor): prims}` | `{}`. layout 변환이 필요 없다 |
| H4 | `_ground_flow` (routing) | → edge 목록 `(prod, cons, tensor)` | 6개. NCLU/SPLU/SPSU/NCSU는 경로 위에 있어서 mover가 된다 |
| H5 | `schedule_cadence` | → `{edge: cadence 이름}` | stage / signal / stream / drain / signal / egress |
| H6 | `propagate` (flood) | → `{edge: (Layout, tap)}` | 모든 edge에 타입이 붙는다. 변환이 없으므로 seed layout이 그대로 전파된다 |
| H7 | `couple` | → `{edge: Coupling}` | dma / memory / fifo / fifo / memory / dma |
| H8 | `HGDG(...)` | 위 결과를 합친 **frozen graph** | DNode 6개, DEdge 6개 |
| J1 | `derive_unit` (`emit_<unit>.derive_template`) | HGDG → 유닛별 raw JIR | 유닛 5개 × DNC 4개. `SYNC_ROLE`은 아직 symbolic |
| J2 | `fold_templates` (`canon.fold`) | 반복되는 명령을 `_Loop`로 접는다 | NCLU/NCSU의 `LDMU×2`/`STMU×2`가 `loop 2 {…}`로 바뀐다 |
| J3 | `resolve_kind_trips` | formula/policy 종류 loop의 trip을 생성 | 변화 없음 |
| J4 | `with_nclu_walks` | systolic NCLU에 LDMU walk를 끼워 넣는다 | 변화 없음. streaming 경로라서 해당하지 않는다 |
| J5 | `bind_templates` | channel 표를 보고 `SYNC_ROLE`의 `_role{put, get, peers}`를 채운다 | 4개 role이 해석된다 |
| J6a–d | `lower_frame` / `lower_vocab` / `lower_loops` / `lower_signals` | 구조 노드를 하나씩 없앤다 | `lower_loops`만 효과가 있다(NC 유닛의 `_Loop`). 나머지는 변화 없음 |
| J7 | `partial_eval` | template + env → 구체 record(opcode 번호, PC) | `SYNC_ROLE`가 `SYNC imm`(bitmask)로 바뀐다 |

이 뒤로 `fold_records`, `frame_block`, `alloc.apply`, `retarget_block`, `patch_dynloop_exit`, `assemble`가 이어지는데, 여기부터는 record와 block 수준이라 이 문서에서 다루지 않는다.

> sqrt는 가장 단순한 streaming 예제다. 그래서 transform, sibling, `_Frame`, `_Vocab`, `_SignalReduce`, `Repeat`, `Param`이 하나도 나오지 않는다. 이런 구성 요소의 문법은 아래 §2에 정리했다. 실제 사용 예를 보려면 matmul이나 softmax를 덤프해야 한다.

---

## 1. HGDG (Hardware-Grounded Dataflow Graph)

정의는 `grounding/hgdg.py`에 있다: `Coupling`(:26), `DEdge`(:148), `DNode`(:180), `HGDG`(:208). 레이아웃은 `grounding/layouts.py`에 있다.

### 1.1 Syntax

```
HGDG      ::= nodes: {unit ↦ DNode}   edges: {(prod, cons, tensor) ↦ DEdge}   trace: TracedOp
DNode     ::= unit  kind ∈ {boundary, mover, compute}  arith  broadcast:bool
DEdge     ::= prod → cons : tensor
              type    : Layout                       # 무엇이 흐르나   (propagate)
              cadence : {tap, accum?, hold?, drains?, windows?, resolutions?}   # 어떤 리듬으로   (schedule_cadence → temporal_readouts)
              sync    : Coupling                     # 어떻게 동기화하나 (couple)
Layout    ::= '[' Axis* ']' '·' Mem ' @' base        # 축 순서: streaming seed는 선언한 dim 순서. 물리 배치는 순서가 아니라 unit(λ/L)과 stride가 정한다
Axis      ::= name '=' size ':' stride unit-symbol   # 예: K=64:1L,  K.in=8:-1L,  K=64:0★
Mem       ::= SHM | SP | FIFO | RF | DRAM
Coupling  ::= kind ∈ {fifo, dma, bank, memory, credit, fence}
              scope ∈ {intra, cross}   cadence ∈ {per_tile, lowered, none}
              roles = (producer 쪽 이름, consumer 쪽 이름)   handshake = ReduceHandshake | None
```

축 unit 기호: `L` line(주소), `λ` lane, `ρ`/`γ` row/col, `⇢ ⊕ τ ∘ ∘m ∘c` 시간(stream, accum, trip, pass, mpass, cpass), `★` bcast(stride 0), `⊞` window. 자세한 내용은 `mcc-layout.md` §1을 보라.

### 1.2 Semantics

- **graph는 DNC 하나가 하는 일을 나타낸다.** SPMD라서 모든 DNC가 같은 graph를 쓰고, DNC 사이의 차이는 나중에 memmap(주소)과 `Param`으로만 들어간다.
- **노드는 유닛의 이름이지 물리 블록이 아니다.** sqrt는 DNode 6개이고, 물리 블록 `HNode`는 DNC당 유닛 5개 × 4 DNC다. 둘은 `unit` 필드로만 연결된다.
- **`kind`는 따로 저장하지 않고 집합에서 계산한다.** compute 집합에 있으면 `compute`, 메모리 경계 집합에 있으면 `boundary`, 둘 다 아니면 `mover`다. mover는 누가 끼워 넣는 것이 아니라, routing 경로 위에 놓였다는 사실에서 정해진다.
- **`arith`는 compute 노드에만 있다.** streaming이면 그 pass의 Expr sub-DAG이고, systolic이면 `ComputeOperands`(op-card)다.
- **edge 타입(`Layout`)은 텐서 전체가 아니라 한 문맥(유닛, pass, beat)이 다루는 조각이다.** 그래서 같은 텐서라도 SHM edge는 `R=256`이고 SP edge는 `R=64`다.
- **`cadence.tap`이 시간 동작을 정한다**(`layouts.temporal_readouts`, :457).

  | schedule 이름 | tap | 뜻 |
  |---|---|---|
  | stage | `stage` | 외부 메모리에서 staging |
  | signal | `invariant` | mover끼리의 넘김. 시간에 따라 변하지 않는다 |
  | stream | `re-read+shear`, `windows=accum` | compute로 들어가는 스트림. accum 횟수만큼 다시 읽는다 |
  | drain | `drain-cadence`, `drains=npass·accum` | compute에서 나오는 결과 |
  | egress | `folded` | 외부 메모리로 내보내기 |
  | future / accum | `re-prime` / `accumulate` | stationary 재적재 / reduction 누산기 (sqrt에는 없음) |

- **`Coupling`은 그 edge에 동기화 명령이 필요한지를 하드웨어 규칙으로 정한다.**
  - `fifo`: compute 유닛에 닿는 edge. backpressure로 충분해서 명령이 필요 없다.
  - `dma`: SHM에 닿는 edge. mover 자신의 전송이라 상대편이 없다.
  - `memory`: mover에서 mover로 SP나 SHM을 거치는 edge. 아무도 stall되지 않으므로 producer는 put, consumer는 get을 해야 한다. 이것이 JIR의 `SYNC_ROLE`이 된다.
  - `roles`: emitter가 channel에 연결될 때 쓰는 이름.
  - `cadence`(rendezvous 빈도): `per_tile`은 tiling이 정한다. `lowered`는 lowering 단계에서 정해지고, `none`은 rendezvous가 없다는 뜻이다.
- **불변식:** HGDG는 생성될 때 이미 타입, cadence, coupling이 모두 붙어 있고 frozen이다. 부분적으로만 타입이 붙은 상태는 없다. 예외는 NC protocol frame의 `credit`/`fence` edge로, 텐서를 나르지 않으므로 `type=None`이다.

### 1.3 sqrt HGDG annotation (H1 → H8)

```
# H1 seeds: 텐서가 "태어나는" 자리의 layout
(SHM, inp)        [R=256:1λ K=64:1L]·SHM @inp     # external: 선언된 전체 크기. R은 lane 축, K는 line 64개
(NCLU, inp)       [R=64:1λ  K=64:1L]·SP  @inp     # on-chip: DNC_SHARD 4를 나눠 뺀 한 DNC의 몫(256/4)
(VU0_sqrt, sqrt1) [R=64:1λ  K=64:1L]·SP  @sqrt1   # pass 0의 compute 유닛 VU가 export하는 출력
                                                  # "VU0_sqrt" = VU + pass 번호 0 + 대표 op 이름
# H2 sibling=() width=1      → K를 DNC 사이에 나누지 않으므로 cross-DNC reduce가 없다
# H3 transforms={}           → 소비자가 요구하는 layout이 seed와 같다 (matmul이면 split/reverse가 생긴다)

# H4 routing: compute_units=('VU0_sqrt',). fabric spine을 따라가며 경로 위 유닛이 mover가 된다
SHM ─▶ NCLU ─▶ SPLU ─▶ VU0_sqrt ─▶ SPSU ─▶ NCSU ─▶ SHM

# H8 최종 HGDG
DNode SHM       boundary
DNode NCLU      mover                 # SHM → SP   (uDMA, LDMU)
DNode SPLU      mover                 # SP → VU FIFO (LDU)
DNode VU0_sqrt  compute arith=[sqrt1 = map.sqrt(inp)]
DNode SPSU      mover                 # VU FIFO → SP (STU)
DNode NCSU      mover                 # SP → SHM   (STMU)

DEdge SHM → NCLU : inp
  type    [R=256:1λ K=64:1L]·SHM @inp    # SHM 쪽에서 본 전체 텐서
  cadence {tap: stage}
  sync    dma                             # NCLU의 LDMU가 직접 전송한다. 상대편 없음, 명령 없음
DEdge NCLU → SPLU : inp
  type    [R=64:1λ K=64:1L]·SP @inp      # 메모리가 SHM에서 SP로 바뀐다(이 DNC의 몫만)
  cadence {tap: invariant}
  sync    memory, lowered, roles=(stage, load)
                                          # 둘 다 SP를 주소로 접근하므로 rendezvous가 필요하다
                                          # NCLU 'stage' put → SPLU 'load' get. 빈도는 LDMU 그룹 수가 정하므로 lowered
DEdge SPLU → VU0_sqrt : inp
  type    [R=64:1λ K=64:1L]·SP @inp
  cadence {tap: re-read+shear, windows: 1} # 스트림 operand. accum=1이라 한 번 읽는다
  sync    fifo                            # FIFO backpressure. 명령 없음
DEdge VU0_sqrt → SPSU : sqrt1
  type    [R=64:1λ K=64:1L]·SP @sqrt1
  cadence {tap: drain-cadence, drains: 1}  # npass·accum = 1
  sync    fifo
DEdge SPSU → NCSU : sqrt1
  type    [R=64:1λ K=64:1L]·SP @sqrt1
  cadence {tap: invariant}
  sync    memory, per_tile, roles=(egress, drain)
                                          # 출력 tile마다 한 번: SPSU 'egress' put → NCSU 'drain' get
DEdge NCSU → SHM : sqrt1
  type    [R=64:1λ K=64:1L]·SP @sqrt1
  cadence {tap: folded}
  sync    dma
```

**emitter가 이 graph에서 읽는 것**
- loop 횟수 = 축 크기. `K=64:1L`이므로 VU, SPLU, SPSU는 `MVLOOPCNT 64`가 되고, 한 iteration이 line 하나(lane 64개 = R 64행)를 처리한다.
- 주소 증가량 = stride. `K`의 stride가 1 line이다.
- 동기화 = `Coupling`. `memory` edge 2개만 `SYNC_ROLE`이 된다.

---

## 2. JIR (unit template IR)

정의:
- `ir/jir.py`: `Tmpl`, `Label`, `LabelRef`, `VReg`, `Repeat`
- `ir/nodes.py`: `_Loop`, `_Frame`, `_Vocab`, `_SignalReduce`
- `ir/expr.py`: 즉값 식
- 상위 컨테이너: `ir/unit_program.py` `UnitProgram`, `ir/coordination_ir.py` `FabricProgram`/`Channel`

### 2.1 Syntax

```
UnitProgram ::= unit dnc ncore col   template: Node*   env: {param ↦ int}
                lrf_raw lccr_raw framing fold boundary loop
Node     ::= Tmpl(opcode, {field ↦ Value})              # 명령 하나(또는 의사 명령)
           | Label(name)                                 # 위치 표시. 명령을 만들지 않는다
           | Repeat(count: Expr|int, body: Node*)        # partial_eval에서 count번 펼친다. body에 label은 못 넣는다
           | _Loop(mv, body, cascade, kind, axes)        # 하드웨어 counter loop
           | _Frame(mvs, body, axes)                     # 1-trip loop N개 골격 + NOP close cascade
           | _Vocab(kind, args)                          # 주소 의도(sp_immc, sp_mod, car_add, shm_advance …)
           | _SignalReduce(legs)                         # cross-DNC reduce 다리(MESYNC)
Value    ::= int | Expr | LabelRef(name) | VReg(name)
Expr     ::= Const(n) | Param(name) | Reg(jcr)           # Param = DNC별로 채울 구멍, Reg = 실행 시점 JCR 값
           | Neg | Add | Sub | Mul | And | Min | Max | CeilDiv
의사 opcode:
  SYNC_ROLE{ref: 채널 쪽 이름, _role: {put, get, peers} (bind 이후)}
```

### 2.2 Semantics

- **template은 유닛 하나가 실행할 명령 열의 틀이다.** 같은 template이 여러 DNC에서 재사용되고, DNC마다 다른 값은 `Param`으로 남겨 둔다. 값은 `env`가 준다(sqrt에서는 env가 `{}`).
- **`Tmpl.params`는 그 유닛 ISA의 필드 이름을 그대로 쓴다**(`typ1_imm`, `src0`, `lrf_tgt`, `be` …). opcode 번호와 비트 위치는 유닛마다 다르므로, `partial_eval`에서 `net_build_for(unit)`를 통해 정해진다.
- **`be`(beat-end)는 loop의 마지막 명령에 1로 붙어 loop를 닫는다.** 그래서 `MVLOOPCNT n ; A ; B(be=1)`은 `for _ in range(n): A; B`라는 뜻이다. JIR에 `_Loop`가 있으면 `lower_loops`가 `be`를 자동으로 찍어 주므로, close가 빠지거나 두 번 들어가는 실수가 생길 수 없다.
- **`_Loop.kind`는 trip이 어디서 오는지 밝힌다.**
  - `axis`: 축 extent의 곱. `check_loop_nest`가 검사한다.
  - `formula`, `policy`, `lrf`: 생성된다(`resolve_kind_trips`).
  - `close`: trip = 1.
  - `dbuf`: 저자가 직접 쓴다.
  - `fold`: canonical fold가 만든 것이다(sqrt의 NC 유닛).
- **`SYNC_ROLE`은 아직 bitmask가 정해지지 않은 동기화 의도다.**
  - `ref`는 HGDG `Coupling.roles`의 이름 중 하나(`stage`/`load`/`egress`/`drain`)다.
  - `bind_templates`가 `FabricProgram.channels`에서 그 이름을 가진 channel을 찾아 `put/get/peers`를 채운다.
  - `partial_eval`가 그것을 `SYNC imm`으로 인코딩한다(`dnckit/sync_codec.py`).
    ```
    imm bit0 = put(SEND), bit1 = get(RECV), bit2..7 = peer
    peer bit (NC와 SP 공통, ncore 0 기준): 2 nclu, 3 ncsu, 4 splu0, 5 spsu0, 6 splu1, 7 spsu1
    ```
- **lowering 순서는 노드가 서로를 담을 수 있는 관계로 정해진다.** `_Frame`은 `_Loop`를 담을 수 있고, `_Loop` body는 `_SignalReduce`를 담을 수 있다. 그래서 frame → vocab → loops → signals 순서로 제거한다. `partial_eval`은 구조 노드가 모두 사라진 뒤에야 PC를 매길 수 있다.
- **`partial_eval`의 출력 record는 `{opcode, opc(유닛별 opcode 번호), params(전체 필드, 기본값 0 포함), fill, known}`이다.**

### 2.3 sqrt JIR annotation (DNC 0, J1 → J7)

유닛 5개의 block column: SPSU col2, SPLU col3, VU col4, NCSU col6, NCLU col7. NCLU/NCSU는 DNC가 공유하므로 J2부터 `ncore=None`이다.

#### NCLU (col 7): SHM → SP staging
```
# J1 derive_unit
LDMU  src0=0 src1=0 src2=0 src3=0 burst=0   # src0..3 = 디스크립터 레지스터 번호(SHM/SP 주소는 LRF에 있음, lrf_raw)
LDMU  src0=0 src1=0 src2=0 src3=0 burst=0   # burst 필드는 5-bit이고 32줄을 0으로 쓴다. 64줄 = 32 × 2
SYNC_ROLE ref='stage'                       # HGDG edge NCLU→SPLU의 producer 쪽
RETURN be=0
# J2 fold_templates: 똑같은 LDMU 두 개를 loop로 접는다
loop mv={typ1_imm:2} kind='fold' { LDMU … }
# J5 bind: SYNC_ROLE ref='stage' _role={put:True, get:False, peers:['SPLU0']}
# J6c lower_loops: _Loop → MVLOOPCNT 2 ; LDMU … be=1
# J7 records
0  MVLOOPCNT opc=48 typ1_imm=2              # NC 유닛의 MVLOOPCNT opcode는 48 (SP/VU는 33)
1  LDMU      opc=35 … be=1                  # loop close. 디스크립터가 실행마다 주소를 자동으로 증가시킨다
2  SYNC      opc=12 typ1ac_imm=17           # 17 = 0b010001 = put + peer bit4(splu0): "SPLU0야, 데이터 다 올렸다"
3  RETURN    opc=55
```

#### SPLU (col 3): SP → VU FIFO
```
# J1
SYNC_ROLE ref='load'                         # edge NCLU→SPLU의 consumer 쪽
MVLOOPCNT typ1_imm=64                        # K=64 line. HGDG type의 K 축 크기와 같다
LDU src0=0 src1=1 ld_consumer=3 burst=0 be=1 # 한 iteration에 SP line 하나를 VU FIFO로 보낸다. be=1로 loop를 닫는다
RETURN be=0
# J5 bind: _role={put:False, get:True, peers:['NCLU']}
# J7
0  SYNC      opc=38 typ1_imm=6               # 6 = 0b110 = get + peer bit2(nclu): NCLU의 stage put을 기다린다
1  MVLOOPCNT opc=33 typ1_imm=64
2  LDU       opc=17 ld_consumer=3 be=1
3  RETURN    opc=63
```
SYNC opcode는 SP 유닛에서 38, NC 유닛에서 12다. 즉값 필드 이름도 `typ1_imm`과 `typ1ac_imm`으로 다르다. JIR은 이런 차이를 숨기고 mnemonic 수준에서만 다룬다.

#### VU (col 4): sqrt 계산 (`ops/sqrt/vu_idiom.py` `sqrt_newton`, steps=4)
상수는 dlf16 인코딩이다: `0x3E00`=1.0, `0x3C00`=0.5, `0x3F00`=1.5, `0x3C80`=0.625. 피연산자 태그 `0x10+i`는 LRF[i]를 뜻하고, `4`는 SPLU FIFO pop을 뜻한다.
```
IMMCOPY typ1_imm=15872(0x3E00 = 1.0)   lrf_tgt=16    # LRF0 = one
IMMCOPY typ1_imm=0     (0.0)           lrf_tgt=17    # LRF1 = zero
IMMCOPY typ1_imm=15360(0x3C00 = 0.5)   lrf_tgt=18    # LRF2 = half
IMMCOPY typ1_imm=16128(0x3F00 = 1.5)   lrf_tgt=19    # LRF3 = three_halves
IMMCOPY typ1_imm=15488(0x3C80 = 0.625) lrf_tgt=20    # LRF4 = seed_c
MVLOOPCNT typ1_imm=64                                 # line 64개 = K 축. 한 iteration이 64 lane(R 64행)
  FMA  src0=4(splu)  src1=16(1.0) src2=17(0) → 21    # s = pop·1 + 0.  FIFO는 한 번만 pop되는데 s는 3번 쓰이므로(multi_read) LRF에 복사
  EE   src0=21 src2=10(16-bit)       → 22            # e = exponent(s)
  SHR  src0=22 src1=1                → 22            # e >>= 1
  IME  src0=22 src1=2 src2=20(0.625) → 24            # y0 = 0.625 · 2^-e   (rsqrt seed. 0.625로 Newton 수렴 범위 안에 넣는다)
  FMA  src0=21 src1=18(0.5) src2=17  → 23            # xh = s/2
  ┌ ×4 (Repeat가 아니라 idiom이 Python에서 펼친 것. JIR에는 이미 12개 명령으로 들어 있다)
  │ FMA  24·24 + 0      → 25                         # t = y²
  │ FNMS 19 − 23·25     → 26                         # u = 1.5 − xh·t      (dnc_dec는 FADDHP로 출력함. opcode 6 공유)
  │ FMA  24·26 + 0      → 24                         # y = y·u
  └
  FMA  src0=21 src1=24 src2=17 → 27                  # out = s · y = sqrt(s)
  FMA  src0=27 src1=16(1.0) src2=17 lrf_tgt=0 out_sp=3 be=1
                                                      # out·1 + 0을 SPSU FIFO로 보낸다(out_sp). be=1로 64-loop를 닫는다
RETURN be=0
```
J1부터 J7까지 VU template은 바뀌지 않는다. 구조 노드도 SYNC_ROLE도 없기 때문이다. 동기화는 양쪽 FIFO(`fifo` coupling)의 backpressure로만 이루어진다.

#### SPSU (col 2): VU FIFO → SP
```
MVLOOPCNT typ1_imm=64
STU src0=0 src1=1 st_producer=2 burst=0 be=1    # VU 결과 한 line을 SP @sqrt1에 저장
SYNC_ROLE ref='egress'                          # edge SPSU→NCSU의 producer 쪽 (per_tile)
RETURN be=0
# J5: _role={put:True, get:False, peers:['NCSU']}
# J7: SYNC opc=38 typ1_imm=9   # 9 = 0b1001 = put + peer bit3(ncsu)
```

#### NCSU (col 6): SP → SHM
```
SYNC_ROLE ref='drain'                           # 'egress'의 consumer 쪽
loop mv={typ1_imm:2} kind='fold' { STMU … }     # J2에서 STMU×2를 접은 것. 32줄 × 2
RETURN be=0
# J5: _role={put:False, get:True, peers:['SPSU0']}
# J7: SYNC opc=12 typ1ac_imm=34  # 34 = 0b100010 = get + peer bit5(spsu0)
#     MVLOOPCNT 2 ; STMU be=1 ; RETURN
```

### 2.4 Coordination (J5에서 출력한 channel 표)

DNC마다 channel이 5개씩 있고, DNC가 4개라서 모두 20개다.

| flavor | src → dst | roles | granularity | template에 나타나는 것 |
|---|---|---|---|---|
| Signal | NCLU → SPLU | (stage, load) | `''` (`lowered`) | NCLU `SYNC 17` / SPLU `SYNC 6` |
| Stream | SPLU → VU0_sqrt | () | | 없음 (FIFO) |
| Stream | VU0_sqrt → SPSU | () | | 없음 (FIFO) |
| Signal | SPSU → NCSU | (egress, drain) | `per_tile` | SPSU `SYNC 9` / NCSU `SYNC 34` |
| Carried | SPSU → SPLU | (war, reload) initial=1 | `credit` | sqrt template에는 `war`/`reload` SYNC_ROLE이 없다. 출력 tile이 하나뿐이라 SP를 다시 쓰는 일이 없기 때문으로 보인다(추정) |

전체 동기화 사슬을 정리하면 다음과 같다.
```
NCLU: LDMU×2 → SYNC put→SPLU ┐
SPLU:          SYNC get←NCLU ┘ → LDU×64 ─FIFO─▶ VU ×64 ─FIFO─▶ SPSU: STU×64 → SYNC put→NCSU ┐
NCSU:                                                                     SYNC get←SPSU ┘ → STMU×2
```

---

## 3. 정리: 단계마다 무엇이 정해지는가

```
HGDG edge type [R=64:1λ K=64:1L]·SP   ──▶ MVLOOPCNT 64 (K 크기), line 하나 = lane 64개 (R)
HGDG Coupling memory(stage,load)       ──▶ SYNC_ROLE ref=stage/load ──bind──▶ _role{put,peers} ──eval──▶ SYNC imm 17 / 6
HGDG Coupling fifo                     ──▶ 명령 없음 (FIFO backpressure)
NC burst cap 32 line                   ──▶ LDMU×2 ──fold──▶ _Loop(2) ──lower_loops──▶ MVLOOPCNT 2 + be=1
DNode.arith  sqrt1 = map.sqrt(inp)     ──▶ VU idiom sqrt_newton (seed + Newton 4회)
```

- HGDG는 무엇이 어디서 어떤 모양과 리듬으로 흐르고 어떻게 동기화되는지를 정한다. 명령은 아직 없다.
- JIR은 유닛별 명령의 틀이다. 남아 있는 기호는 세 가지다: 동기화 의도(`SYNC_ROLE`), DNC별 값(`Param`), 구조 노드(`_Loop`/`_Frame`/`_Vocab`). 바인딩, lower, partial_eval이 이것들을 차례로 없앤다.
- sqrt는 SPMD라서 DNC 4개의 template이 모두 같다. 주소 차이는 NCLU/NCSU의 LRF descriptor(`lrf_raw`)에만 있다.
