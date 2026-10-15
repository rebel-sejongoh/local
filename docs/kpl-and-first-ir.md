# kpl and mcc's First IR

- 기준: `~/workspaces/codesigner` `dev` `aafd7348`. 경로는 저장소 루트 기준이다.
- 예제 출력은 실제 실행 결과다: `../scripts/dump_first_ir.py`, `../examples/kpl/rmsnorm_softmax.py`.

## 1. Overview

- kpl은 NPU 엔진용 프로그램을 쓰는 **Python 내장 표기법**이다. 표준 라이브러리만 쓴다.
- 선언을 평가하면 숫자를 계산하는 대신 **dataflow graph를 만든다**(JAX, torch.fx 같은 trace 방식). 결과는 닫힌 데이터 구조 `decl.Program` / `decl.Level`이다. 하드웨어가 할 수 있는지 판단하는 것은 컴파일러(mcc)의 몫이다.
- 데코레이터가 실행 엔진을 정한다.
  - `@rb.microcode(on=R100.DNC)`: Compute Engine(DNC) 프로그램. mcc가 컴파일한다.
  - `@rb.kernel(on=R100.CP)`: 그것을 구동하는 Controller 프로그램(kcc 쪽).
- `on=`에 넘기는 객체(`mcc/kpl_machine.py`의 `R100.DNC`)가 그 레벨에서 쓸 수 있는 **메모리 공간**(DNC는 SHM)과 **연산 어휘**(`sqrt`, `exp`, `rsqrt` …)를 정한다. kpl 자신은 어떤 머신도 모른다.

## 2. Syntax

```python
@rb.microcode(on=R100.DNC)
def sqrt(prog):
    @prog.symbol                      # ① 축 이름 선언. 이름이 들어오는 유일한 곳
    def _(ctx):
        ctx.add("R"); ctx.add("K")

    @prog.signature                   # ② 텐서: 이름, 메모리, dtype, shape(축 이름)
    def _(ctx):
        ctx.input("inp",  SHM.F32Tensor[spec(shape=("R", "K"))])
        ctx.output("out", SHM.F32Tensor[spec(shape=("R", "K"))])

    @prog.body(style="compute")       # ③ 계산: dataflow graph를 만든다
    def _(a):
        return a.sqrt()

MAIN = declare(sqrt, R=256, K=64)     # ④ 축 크기 바인딩. mcc build는 모듈의 MAIN을 읽음
```

| 블록 | 하는 일 | 규칙 |
|---|---|---|
| `@prog.symbol` | 축 이름(`R`, `K`)을 연다 | `ctx.add(name, bind=…, spans=…)`. `spans="ol + tap"`은 conv의 window 축 |
| `@prog.signature` | 입력/출력 텐서 선언 | **메모리를 반드시 적는다**(`SHM.F32Tensor[...]`). **주소는 쓰지 않는다** |
| `@prog.body(style=…)` | 계산 | `compute`: 산술. `compose`: 하위 레벨 조합 |
| `declare(kernel, **workload)` | 축 크기를 정함 | 선언 하나가 여러 shape에 쓰인다 |

부가 기능: `ctx.region` + `of=`/`at=`(한 버퍼 안의 window로 텐서 배치), `ctx.constant`(커널이 공급하는 상수 텐서), `@prog.symbol_constraint`, `@prog.check`.

## 3. Semantics: the Body Builds a Dataflow Graph

`compute` body는 정의할 때 **한 번 실행되어 dataflow graph를 만든다.** 인자는 숫자가 아니라 graph 노드를 가리키는 **`Value`**이고, 연산할 때마다 노드(`decl.Op`)가 하나 추가되고 그 노드의 `Value`가 반환된다. 결과는 SSA 형태의 노드 리스트다.

- 노드 번호: 입력 `n`개가 `v0..v(n-1)`, body의 `i`번째 Op가 `v(n+i)`. edge는 `args`에 앞선 노드 번호로 적힌다.
- `Op(kind, args, axis, axis_offset, combine, imm)`
  - `imm`: 스칼라 리터럴(`x * 0.125`). 텐서가 아니므로 노드가 되지 않는다.
  - `axis`/`combine`: reduce의 축과 monoid.
- `Level.exports`: body가 반환한 노드 번호(출력).

### Compute body constructs

| 표기 | 노드 |
|---|---|
| `a + b`, `a - b`, `a * b`, `a / b` | `add`, `sub`, `mul`, `div` (상대가 숫자면 `imm`) |
| `a @ b` | `contract` |
| `a.sum(over="K")`, `.max/.min/.prod(over=)` | `reduce(axis="K", combine=add/max/min/mul)` |
| `a.sqrt()`, `a.exp()`, `a.op("max", b)` | 머신 어휘에 있는 idiom만 허용. 없으면 그 줄에서 에러 |
| `mask.where(v, otherwise)` | `where` (SELECT) |
| `x[a:b]`, `x[i]`, `x[..., :h]`, `y["name"]` | `slice`, `index`, 다중 출력 선택 `select` |

### Compose body constructs (combining levels)

| 표기 | decl 타입 | 뜻 |
|---|---|---|
| `ctx.split(v, "m", into=even(8))` | `Split` | 축을 나눔 → shard |
| `ctx.broadcast(v, over=)` | `Broadcast` | 없는 축을 같은 값으로 채움 |
| `ctx.merge(v, axes, into=)` | `Merge` | 인접한 두 축을 하나로 |
| `port.map(kernel, …)` / `apply` | `Map` / `Apply` | 하위 커널을 port의 각 unit에 적용 |
| `port.fold/scan(kernel, over=, start=)` | `Fold` | 상태를 들고 순차 결합 |
| `port.reduce(v, meet=, radix=)` | `Meet` | 트리 결합. monoid도 **커널 참조**로 지정 |
| `ctx.reorder` | `Reorder` | 기록은 되지만 현재 거부됨 |

### Axis roles are derived, not declared

`mcc/grounding/kpl_roles.assign`이 시그니처와 body로부터 정한다(우선순위 순).

| role | 조건 |
|---|---|
| `window` / `accum` | `spans="ol + tap"`로 선언된 물리 축 / 그 항들 |
| `step` | body가 fold/scan하거나 reduce하는 축 |
| `contract` | 입력에는 있고 출력에는 없는 축 |
| `shard` | body가 split한 축 |
| `free` | 입력과 출력 모두에 있는 축 |

**arm**도 여기서 정해진다: `contract` 축이 있으면 `systolic`(TU), 없으면 `streaming`(VU 등).

## 4. Examples with Several Ops

`../examples/kpl/rmsnorm_softmax.py`.

### Row softmax

```python
@prog.body(style="compute")
def _(x):
    e = (x - x.max(over="K")).exp()
    return e / e.sum(over="K")
```

```
kpl graph (decl.Level.body)              mcc first IR (Expr DAG)
  v1 = reduce(v0) axis=K max               x     : input  axes=(R,K)
  v2 = sub(v0, v1)                         red1  : reduce max  K   (x)
  v3 = exp(v2)                             sub2  : map sub         (x, red1)     # red1이 K로 broadcast
  v4 = reduce(v3) axis=K add               exp3  : map exp         (sub2)
  v5 = div(v3, v4)                         red4  : reduce add  K   (exp3)
  exports = (v5)                           recip_div5 : map recip  (red4)        # div → recip + mul
                                           div5  : map mul         (exp3, recip_div5)   out
roles: free=R, step=K, lane=R   arm: streaming
```

tiled trace(`mcc build` 성공):
```
spatial   dnc[4] = shard.R[4] × split.K[1]
temporal  LEAF R=64:lane, reduce K[64]
accumulate acc_edge (VU,VU,acc)  cadence={accum:1, npass:3}     # K를 3번 훑음: max, sum, normalize
```

### Fused RMSNorm

```python
@prog.body(style="compute")
def _(x, w):
    ms = (x * x).sum(over="K") * (1.0 / HIDDEN)
    r = (ms + 1e-6).rsqrt()
    return x * r * w
```

```
kpl graph                                mcc first IR
  v2 = mul(v0, v0)                         x, w  : input  axes=(R,K)
  v3 = reduce(v2) axis=K add               mul1  : map mul    (x, x)
  v4 = mul(v3) imm=1/64                    red2  : reduce add K (mul1)
  v5 = add(v4) imm=1e-6                    mul3  : map mul imm=0.015625 (red2)
  v6 = rsqrt(v5)                           add4  : map add imm=1e-06    (mul3)
  v7 = mul(v0, v6)                         rsqrt5: map rsqrt  (add4)
  v8 = mul(v7, v1)                         mul6  : map mul    (x, rsqrt5)
                                           mul7  : map mul    (mul6, w)   out
roles: free=R, step=K   arm: streaming
```

- 첫 IR과 tiling(`dnc[4] = shard.R[4]`, `npass: 2`)까지는 통과한다.
- 그러나 **`mcc build`는 실패**한다: `LREG: LRF register 16 out of range 0..15`. 한 레벨에 다 넣으면 VU 레지스터 16개를 넘는다.
- 그래서 저장소의 RMSNorm 예제(`mcc/tests/fixtures/for_llama_decoder_kpl_gap_test.py`)는 `rms_norm_stats` → `rms_norm_scale` → `rms_norm_apply` 세 레벨로 쪼개져 있다.

### What the examples show

- 축은 노드 사이에서 **합집합으로 broadcast**된다. reduce로 접힌 `(R)` 값과 `(R,K)` 값을 연산하면 자동으로 K에 퍼진다. `Broadcast` 노드는 만들어지지 않는다.
- 첫 IR은 kpl graph를 그대로 옮기지 않고 **하드웨어에 없는 연산을 바꾼다**: `div` → `recip` + `mul`(`lower_divide`, DNC에 나눗셈 유닛이 없음). `a @ b`도 `mul` + `reduce add`로 풀린다.
- 스칼라는 노드가 아니라 `imm`으로 붙는다. 노드 이름은 tracer가 `<op><번호>`로 붙인다.

## 5. mcc's First IR: the Expr DAG (`TracedOp`)

### Pipeline

```
Microcode ──.level──▶ decl.Level (kpl graph)
   └─ kpl_translate.arithmetic_level_of   compose면 map된 compute 레벨을 꺼냄
   └─ kpl_roles.assign                    축 role, arm
   └─ kpl_translate.dag_of                kpl graph를 mcc tracer로 replay
        └─ place.trace_op                 tracer.trace_np + lower_divide        → Expr 리스트   ← 첫 IR
   └─ TracedOp(nodes, axes, cross_dnc, spec, …)
   └─ .tiled(kpl_translate.tiling_for(...))   tiling 결정이 붙은 두 번째 상태
   └─ spine.synthesize                    → HGDG → … → image
```

### `Expr` node

| kind | 필드 | 뜻 |
|---|---|---|
| `input` | `axes` | 스트리밍 입력과 그 축 |
| `map` | `deps`, `op`, `imm` | 원소별 연산. `op`가 emit에서 ISA idiom으로 매핑됨 |
| `reduce` | `deps`, `axis`, `monoid` | 한 축을 접음. pass 경계 후보 |
| `slice` / `index` | `off`, `along`, `sel` | conv tap 같은 펼친 loop용. `reroll`이 지움 |

공통: `name`, `out=True`(출력 노드).

`TracedOp`은 노드 리스트에 annotation을 붙인 것이다: `axes`(어느 축이 어느 하드웨어 역할인지), `cross_dnc`(DNC 간 reduce 방식: gather/tree), `placement`, `lane`, `spec`, 그리고 `.tiled()` 뒤의 `tiling`.

## 6. What "Grounding" Means

mcc는 세 단계로 나뉜다(`mcc/ARCHITECTURE.md`): **grounding → lowering(emission, coordination) → assembling**.

- **grounding**: 추상적인 계산(trace)을 **실제 하드웨어에 "발 붙이게" 하는 단계**다. 즉 trace의 텐서를 256-node fabric의 유닛과 메모리에 배치하고, 각 dataflow edge에 layout(축, stride, 메모리)을 붙인다. 결과가 HGDG다.
  - 패키지 docstring: "Grounding: place a tiled trace onto the hardware fabric."
  - 들어 있는 것: trace IR과 tiling(`trace.py`, `tiling.py`), 하드웨어 기술(`fabric.py`, `machine.py`), layout 대수(`layouts.py` 등), 주소 모델(`sp_addr`, `shm_addr`, `nc_addr`), HGDG와 flood(`hgdg.py`), 배치(`place.py`), 그리고 kpl을 읽는 부분(`kpl_roles.py`, `kpl_translate.py`).
  - "flood": 경계에 seed layout을 정하고 dataflow edge를 따라 퍼뜨린다(propagate).
- kpl 쪽 문서에서 "OpVocabulary가 idiom을 ground한다"는 말도 같은 뜻이다. 이름(`sqrt`)을 실제로 계산할 수 있는 무언가(ISA 명령열)에 연결한다는 의미다.
- 계층 규칙: lowering은 grounding을 import할 수 있지만 반대는 안 된다. grounding이 체인의 바닥이다.

## 7. References

### kpl language constructs

| 구성 요소 | 파일 |
|---|---|
| `rb`(`Rb`: `microcode`, `kernel`, `tree`, `record`) | `KernelLanguage/src/kpl/surface.py:1607`, 인스턴스 `:1824` |
| `Prog`(`symbol`, `signature`, `body`, `check`, `level`) | `surface.py:1044` |
| `SymbolCtx.add` | `surface.py:411` |
| `SignatureCtx`(`input`, `output`, `region`, `constant`) | `surface.py:470` |
| `Value`(산술 연산자, `sum/max/min/prod`, `op`, `where`, `__getitem__`) | `surface.py:603` |
| `Port`(`map`, `apply`, `fold`, `scan`, `reduce`) | `surface.py:760` |
| `BodyCtx`(`split`, `broadcast`, `merge`, `reorder`, `window`, `at`) | `surface.py:906` |
| `spec`, `even` | `surface.py:1829`, `:1006` |
| `Space`, `Levels`(머신이 메모리/레벨 객체를 만들 때 씀) | `surface.py:263`, `:168` |
| graph 데이터 타입: `Symbol` `Axis` `Tensor` `Region` `Op` | `KernelLanguage/src/kpl/decl.py:207, 258, 271, 351, 380` |
| compose 타입: `Split` `Broadcast` `Merge` `Map` `Apply` `Fold` `Meet` `Reorder` | `decl.py:406, 420, 448, 478, 490, 508, 553, 565` |
| `Level`, `Program` | `decl.py:577`, `:686` |
| R100 머신 객체: `R100`, `SHM`/`SP`/`HBM`, `_SPACES` | `PrimitiveAuthor/mcc/src/mcc/kpl_machine.py:108`, `:77–79`, `:50` |
| `declare`, `Declared`, `build`, `build_sequential` | `PrimitiveAuthor/mcc/src/mcc/kpl_declaration.py:207, 196, 261, 356` |
| 연산 어휘(idiom 목록) | `PrimitiveAuthor/mcc/src/mcc/ops/` (`sqrt/`, `exp/`, `rsqrt/` …) |
| 튜토리얼 | `KernelLanguage/tests/test_tutorial.py` |

### mcc first IR

| 구성 요소 | 파일 |
|---|---|
| **`Expr` (첫 IR의 노드)** | `PrimitiveAuthor/mcc/src/mcc/grounding/tracer.py:25` |
| `trace_np` (tracer 본체) | `tracer.py:429` |
| **`TracedOp` (첫 IR 컨테이너)**, `.tiled` | `PrimitiveAuthor/mcc/src/mcc/grounding/trace.py:328`, `:1014` |
| `trace_op` (`trace_np` + `lower_divide`) | `PrimitiveAuthor/mcc/src/mcc/grounding/place.py:85` |
| `dag_of` (kpl graph → Expr), `arithmetic_level_of`, `tiling_for` | `PrimitiveAuthor/mcc/src/mcc/grounding/kpl_translate.py:810, 1061, 593` |
| `assign`, `table`, `arm` (role 유도) | `PrimitiveAuthor/mcc/src/mcc/grounding/kpl_roles.py:63, 169, 276` |
| `format_tiled` (사람이 읽는 출력) | `PrimitiveAuthor/mcc/src/mcc/grounding/trace_print.py:36` |

### Further reading

1. `KernelLanguage/src/kpl/surface.py` 모듈 docstring: 블록별 의도, address map, role 유도
2. `KernelLanguage/src/kpl/decl.py` 모듈 docstring: 데이터 타입 설계 이유
3. `KernelLanguage/docs/design-principle.md`
4. `PrimitiveAuthor/mcc/ARCHITECTURE.md`: 단계 구성, grounding(flood)
5. `PrimitiveAuthor/mcc/tests/fixtures/for_llama_decoder_kpl_gap_test.py`: RMSNorm(3 레벨), SwiGLU
6. `PrimitiveAuthor/primitives/tests/kpl_{reduction,unary,ternary}/`: 그 밖의 선언 예제

## 8. Current Limits (mcc side)

- 한 레벨에 contraction은 하나만(`attention`, `swiglu`는 leaf로 쪼개야 함).
- systolic seam은 plain matmul 모양만: `window`/`accum`/`step` role이 있으면 거부.
- conv는 1-D, stride 1, padding 없음(`primitives/conv_types.py`).
- 한 레벨의 VU 레지스터는 16개: fused RMSNorm처럼 중간값이 많으면 build 실패(4절).
