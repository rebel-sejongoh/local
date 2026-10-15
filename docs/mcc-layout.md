# mcc Layout: Definition, Code, Tiling, Initial Layout

- 기준: `~/workspaces/codesigner` `dev` `aafd7348`. 경로는 `PrimitiveAuthor/mcc/src/mcc/` 기준.
- 예제 출력은 `../scripts/dump_layout_passes.py`(sqrt, softmax, matmul 64³)로 직접 실행한 결과다.

## 1. What a Layout Is

### 1.1 Definition

```python
@dataclass(frozen=True)
class Axis:            # grounding/layouts.py:45
    name: str          # 논리 축 이름: "R", "K", 분할되면 "K.grp", "K.in"
    size: int | str    # 크기(정수 또는 아직 기호)
    stride: int        # 부호 있음: +1 보통, -1 lane-reverse, 0 broadcast, n 건너뜀
    unit: str          # 이 축이 "무엇에" 쓰이는가 (아래 표)
    dim: object = None # 경계 layout에서만: 공유 텐서의 어느 차원인지

@dataclass(frozen=True)
class Layout:          # grounding/layouts.py:111
    axes: tuple[Axis]  # 바깥 → 안쪽
    mem: str           # "SHM" | "SP" | "FIFO" | "RF" | "DRAM"
    base: object       # 기준 주소 또는 버퍼 라벨("@kernel", "@inp")
```

표기: `[축=크기:stride단위 ...]·메모리 @base`. 예: `[R=64:1λ K=64:1L]·SP @inp`.

### 1.2 Semantics

> **한 layout은 텐서 전체가 아니라 "한 문맥(한 유닛, 한 pass, 한 beat)이 다루는 부분"이다.** 그래서 축은 *어디에 있는가*(공간)와 *언제 닿는가*(시간)를 같이 말한다. (`layouts.py` 모듈 docstring)

`unit`이 축의 의미를 정한다. 12종, 4가지 질문:

| 질문 | unit (기호) | 의미 |
|---|---|---|
| 주소 | `line` (L) | 메모리는 선형 주소. 모든 line 축이 하나의 affine 식으로 접힌다: **`line = base + Σ idx·stride`** |
| 병렬 | `lane` (λ) | 한 줄(128 B) 안의 64 lane. 명령 하나가 다 덮으므로 주소 비용 0 |
| 어느 유닛 | `row` (ρ), `col` (γ) | fabric의 물리 위치 (TU row/col 등) |
| 언제 | `stream` (⇢), `accum` (⊕), `trip` (τ), `pass` (∘), `mpass` (∘m), `cpass` (∘c), `batch`, `sfold` | 하드웨어가 유한해서 **시간으로 바뀐 인덱스**. 예: 8-row TU는 contraction 64를 `k.row` 8(공간) × `k.trip` 8(시간)으로 나눈다 |
| 복제 | `bcast` (★), `window` (⊞) | `bcast`는 stride 0: 같은 값을 여러 번(공유 피연산자). `window`는 conv 슬라이딩 창 |

정리하면 layout은 CuTe/Graphene 스타일의 **(shape, stride) 쌍 + 하드웨어 축 태그 + 메모리**다.
- `line` 축 → 주소 함수, `lane` 축 → SIMD 폭, 나머지 → 공간 배치나 반복(loop) 구조.
- 그래서 layout 하나에서 **명령의 반복 횟수(축 크기)**와 **주소 증가량(stride)**이 바로 나온다.

### 1.3 Comparison and well-formedness

| 함수 | 뜻 |
|---|---|
| `Layout.kind()` | 비교용 타입 = (mem, 각 축의 (name, stride, unit)). **크기와 base는 무시**(크기·배치에 대해 parametric) |
| `Layout.axes_kind()` | mem도 뺀 축 패턴. 메모리만 바꾸는 이동(SP→SHM)을 비교할 때 |
| `Layout.streams()` | `line` 축이 남아 있나 = reduce로 접혔나의 판정(rank 질문) |
| `violations()` | 메모리가 MEMS 중 하나, unit이 12종 중 하나, `bcast`의 stride = 0 |
| `boundary_violations()` | 경계(seam) 비교용 추가 규칙: lane 축 정확히 1개, 모든 축에 `dim`, 크기가 숫자이고 ≥1 |

### 1.4 Helpers

| 함수 | 하는 일 |
|---|---|
| `lane(name, size)`, `line(name, size)` | 축 생성자 |
| `line_map(layout)` | staging 맵 `{(line 인덱스…): line 번호}`. 계약: 각 인덱스가 서로 다른 줄(`deal.ensure`) |
| `dim_groups(layout)` | `{dim: 그 차원을 이루는 축들}`. 이름이 아니라 `dim`으로 분할을 복원 |
| `axis_root("K.grp.in") = "K"` | 분할된 축의 원래 축 |
| `feed_subaxis(axes, "grp"/"in")` | systolic feed의 분할 축 찾기 |
| `lane_reverse_strides`, `absu_strides` | AB west feed의 stride 인코딩 |

분할 접미사(`AXIS_PARTS`): `blk`/`in`(lane tile), `grp`/`in`(systolic feed), `col`/`beat`/`bin`(systolic 분해), `nc`(NCore fan), `row`.

## 2. Code Map

| 무엇 | 파일:줄 |
|---|---|
| `Axis`, `Layout`, unit 목록, well-formed 규칙, helper | `grounding/layouts.py` (45, 111, 189–313, 314–456) |
| 경계 layout 비교 | `grounding/seam.py` |
| layout transform 실행 `_apply_prims`(split/reverse/broadcast/memspace/riffle/transpose) | `grounding/hgdg.py:508` |
| layout flood `propagate` | `grounding/hgdg.py:930` |
| opcode별 layout transfer function(fold) | `grounding/opmodel.py` (`splu_fold`, `xvu_fold`, `tu_fold`) |
| 수작업 net-effect 규칙 + 추론(`LayoutError`) | `grounding/typing_rules.py` |
| 대수 설명, TU 규약 | `mcc/LAYOUT_ALGEBRA.md` |

## 3. The First Tiling Pass

tiling은 `spine` **앞에서**, op(혹은 kpl seam)가 정한다. 검색이 아니라 **closed-form 규칙**이다.

```
kpl_declaration.build
  └─ kpl_translate.tiling_for(level, extents)        grounding/kpl_translate.py:593
       ├─ systolic arm → fabric_tiling(ext, role_table)
       └─ streaming arm → fabric_tiling({__rows, __width=64}, shard=__rows, lane/contract=__width,
                                        active_dncs=lane_shard_count(rows), leaf_rows=64)
  └─ fabric_tiling(extents, roles)                   grounding/tiling.py:920   role 이름 → (m, n, k)
  └─ derive_fabric_tiling(m, n, k, **knobs)          grounding/tiling.py:962   → TilingDecision
  └─ TracedOp.tiled(decision)                        grounding/trace.py:1014   + verify_tiled (:1028)
  └─ TracedOp.binding  (= geometry.binding)          grounding/geometry.py:386 → {축: AxisBinding}
```

### 3.1 The rule

입력은 **역할별 크기** 세 개: `m` = shard할 free 축, `n` = lane 축, `k` = contraction 축.

| 단계 | 규칙 | 함수 |
|---|---|---|
| contraction 분할 | `cin_split = ceil(k / (64·bin))` DNC가 K를 나눠 가짐(`reduce_size`). K는 64의 배수, `bin ≤ 16` | `contraction_split`, `_resolve_contraction` |
| lane tile | `lane_blocks = ceil(n / 64)` (시간으로 도는 64-lane 출력 tile) | `lane_block_count` |
| free 축 DNC 분할 | `n_shards = 16 // cin_split`. M이 Tr(4) 단위로 안 나뉘면 나뉘는 최대 약수로 줄임 | `free_shard_count`, `_pick_m_shards*` |
| DNC 안 | `per_dnc_rows → m_tiles(시간) → tile_rows → numncores(NCore 2개) → ncore_rows(leaf)` | `derive_fabric_tiling` 본문 |
| streaming | 행이 lane에 실림. `active_dncs = ceil(rows/64)`(16 넘으면 시간으로 접음) | `lane_shard_count` |

`TilingDecision`(`tiling.py:130`): `n_shards`, `reduce_size`, `shard_extent`, `lane_blocks`, `m_tiles`, `bin`, `active_dncs`, `cout_spatial`, `batch`, … `n_shards × reduce_size = 활성 DNC 수`.

### 3.2 Axis binding: tiling을 축별로 다시 쓴 것

`AxisBinding(levels, reduced)`, `Level(resource, extent, in_leaf, trips)` (`geometry.py:332, 372`). 축마다 바깥→안쪽으로 **어떤 하드웨어 자원을 몇 배 쓰는가**. `(out)` = per-NCore leaf 밖.

```
sqrt    R=256 K=64      n_shards=4  active_dncs=4
  R: DNC_SHARD 4(out) → NCORE 1 → CPASS 1 → MPASS 1(out) → LANE 64
  K: BIN 1 → COL 1 → BEAT 64

softmax R=256 K=64      (같은 tiling)
  R: DNC_SHARD 4(out) → … → LANE 64
  K: BIN 1 → COL 1 → BEAT 64   [reduced]

matmul  R=64 K=64 I=64  n_shards=16  reduce_size=1
  I: NCORE 1 → CPASS 1 → LANE 64
  R: DNC_SHARD 16(out) → MPASS 1(out) → NCORE 1(out) → LEAF 4
  K: BIN 1 → COL 8 → BEAT 8   [reduced]        # TU 8열 × 8 beat
```

- streaming(sqrt/softmax)은 **행(R)이 lane**에 실리고 K가 시간(beat 64번)이다. 그래서 R=256이 64-lane 블록 4개 → DNC 4개.
- matmul은 출력 열(I)이 lane, 행(R)은 DNC 16개 × 4행, K는 TU의 8열(공간) × 8 beat(시간).
- `reduced` 축의 시간 레벨은 같은 tile에 누적, free 축의 시간 레벨은 다음 tile.

## 4. The Initial Layout Pass (Seeds)

`spine.realize`의 grounding에서 tiling 다음 단계. **seed** = 텐서가 *태어나는 곳*의 layout `{(unit, tensor): Layout}`.

```
spine._ground_seeds(trace)                                  spine.py:307
  systolic:  g = seed_ctx(trace, axes)                      place.py:116
             views = seed_views(g)              카테고리별 축 튜플   place.py:561
             origins = systolic_origin_set(trace, g)        place.py:640
             placement = trace.placement        (op 데이터)
  streaming: sc = streaming_ctx(trace, spec, axes)          place.py:222
             views = streaming_views(sc)        shape별 축 튜플     place.py:391
             origins, placement = streaming_origin_set(trace, sc.ax)   place.py:428
  seeds = {(u, t): place_seed(u, t, views[v], placement)}   place.py:208
spine._widen_to_group  → K-split이면 SPMD 그룹 seed 추가, check_seeds_cover_one_replica
```

### 4.1 Rules

- **seed는 한 DNC 몫.** binding에서 DNC 간 레벨(`DNC_SHARD` 등)을 나눠 뺀 나머지로 축을 렌더링한다. 그래서 모든 DNC가 같은 seed를 쓰고(SPMD), DNC별 차이는 나중에 주소(memmap)로만 들어간다. 위반은 `check_seeds_cover_one_replica`가 막는다.
- **경계 밖(external) seed는 전체 크기.** SHM은 모든 DNC가 공유하므로 거기 놓인 텐서는 선언된 전체 extent로 쓴다. 같은 shape라도 on-chip/external에 따라 extent가 다르다.
- **축 이름·stride·unit은 모두 binding의 projection.** fold의 stride = 그보다 안쪽 레벨 크기의 곱(`level_stride`). 크기 1인 레벨은 렌더링하지 않는다.
- **어디서 태어나나:**
  - streaming: 입력은 외부 메모리(SHM), 나머지는 그것을 export하는 pass의 compute 유닛(SP). pass는 `pass_schedule.derive_passes`가 reduce를 경계로 나눈다.
  - systolic: op가 `placement`로 선언(`{(unit, tensor): (mem, base)}`). matmul과 conv가 같은 유닛에서 다르게 놓기 때문.

### 4.2 Systolic seed categories (`seed_views`)

| category | 축 순서 | 누구 |
|---|---|---|
| `kernel_operand` | `[m.blk] lane, contract:line, accum…` | stationary(north) 피연산자 |
| `streamed_operand` | `[m.blk] shard(.nc), contract:line, accum…` | streamed(west) 피연산자 |
| `input_window` | `[m.blk] window, contract:line, bin-accum` | conv의 창 입력 |
| `seam_output` | `[m.blk] lane, shard(.nc):line, extra:stream` | MAC 유닛 출력 |
| `collapsed_output` | `[m.blk] lane, shard(.nc):line` | reduce 유닛/누산기 출력 |

### 4.3 Actual seeds

```
sqrt
  (SHM,  inp)        [R=256:1λ K=64:1L]·SHM @inp      # external: 전체
  (NCLU, inp)        [R=64:1λ  K=64:1L]·SP  @inp      # on-chip: 한 DNC 몫 (256/4)
  (VU0_sqrt, sqrt1)  [R=64:1λ  K=64:1L]·SP  @sqrt1

softmax                                             # pass 3개: max | sub·exp·sum·recip | mul
  (SHM,  x)          [R=256:1λ K=64:1L]·SHM @x
  (NCLU, x)          [R=64:1λ  K=64:1L]·SP  @x
  (VU0_max, red1)        [R=64:1λ]·SP @red1          # K가 접힘: line 축 없음
  (VU1_add, recip_div5)  [R=64:1λ]·SP @recip_div5
  (VU2_mul, div5)        [R=64:1λ K=64:1L]·SP @div5

matmul
  (NCLU, w)          [I=64:1λ K=64:1L]·SP @kernel     # kernel_operand
  (NCLU, x)          [R=4:1λ  K=64:1L]·SP @ab_bank    # streamed_operand
  (TU,   y)          [I=64:1λ R=4:1L]·SP  @tu_psum    # seam_output
```

## 5. From Seeds to Every Edge: Transforms and the Flood

seed 다음은 모든 edge의 layout을 정하는 단계다.

1. **`derive_transforms(trace, seeds)`** (`place.py:686`): 소비자가 요구하는 변환을 `{(consumer, tensor): (prim, …)}`로 선언한다. 전체 corpus에서 7개 prim뿐이다.
   ```
   softmax: (VU1_add, red1):       (broadcast K 64 bcast)        # 접힌 max를 K로 다시 펼침
            (VU2_mul, recip_div5): (broadcast K 64 bcast)
   matmul:  (TU, x):               (split K 8), (reverse K.in)   # TU west 규약
   sqrt:    {}
   ```
2. **routing**(`resolve_routing`, `route_dataflow`): 경로 위의 유닛이 mover가 된다.
3. **`propagate(edges, seeds, caps, transforms, …)`** (`hgdg.py:930`): seed에서 출발해 dataflow 순서로 퍼뜨린다.
   - **preserve**: mover에 capability도 transform도 없으면 layout을 그대로 전달한다.
   - **derive**: 소비자의 요구와 다르면, 선언된 transform을 경로상 **그것을 할 수 있는 mover**(`caps`)에 배정하고 `_apply_prims`로 실행한다.
     - `split K n` → `K.grp = K/n : stride·n`, `K.in = n : stride`
     - `reverse a` → stride 부호 반전
     - `broadcast a n` → `a = n : 0 bcast` 축 추가
     - `memspace m`, `riffle`/`transpose`(KV kernel 교환)
4. 결과가 HGDG의 edge 타입이다.
   ```
   matmul  XVU→ABSU   x [R=4:1λ K=64:1L]
           ABSU→ABLU  x [R=4:1λ K.grp=8:8L K.in=8:1L]     ← split
           ABLU→TU    x [R=4:1λ K.grp=8:8L K.in=8:-1L]    ← reverse (lane_reverse-8)
   softmax VU0_max→VU1_add  red1 [R=64:1λ K=64:0★]        ← broadcast
   ```

이후 emitter는 이 edge layout만 읽는다. **loop 횟수 = 축 크기, 주소 증가 = stride**이므로, tiling을 바꾸면 숫자만 바뀌고 코드는 그대로다.

## 6. One-Picture Summary

```
role 크기 (m, n, k)
   │ derive_fabric_tiling            closed-form: cin_split, n_shards, lane_blocks, m_tiles, …
TilingDecision
   │ geometry.binding                축마다 [자원×크기] 레벨 (DNC_SHARD, NCORE, LANE, COL, BEAT, …)
AxisBinding
   │ seed_views / streaming_views    DNC 간 레벨을 뺀 나머지를 축으로 렌더링 (한 DNC 몫)
   │ + origin set + placement        어느 유닛, 어느 메모리에서 태어나나
seeds {(unit, tensor): Layout}
   │ derive_transforms               소비자가 요구하는 변환 (split / reverse / broadcast …)
   │ propagate                       edge 따라 전파, 변환은 capable mover가 수행
HGDG edge types
```
