# TU FMA 계열: `run_mode` > 0일 때 `src0` 해석이 ISA 문서와 다름

_2026-10-12, REBEL EVT1. VP `260521_vp_rebel_evt1_arbcal`로 확인._

## 요약

- ISA 문서(isa_documentations, `rebel/evt1/tu/FMA.html`)의 `src0` 표는, `run_mode` > 0일 때 `src0`를 **register group 번호**로 읽는 것처럼 적혀 있습니다.
  - 예: `run_mode`==2(N=4)에서 `src0` 0x0 → {LRF[3..0]}, 0x1 → {LRF[7..4]}, 0x2 → {LRF[11..8]}.
- 실제 VP와 rebel_compute_lib2(rcl2), PrecSim은 `src0`를 **group의 시작 LRF 번호**로 씁니다.
  - 예: `run_mode`==2에서 `src0`=4 → {LRF[7..4]}.
- VP에서 rcl2의 dense code를 문서 해석대로(`src0`=1) 바꿔 돌리면 결과가 틀리고, rcl2 원본(`src0`=4)은 golden과 일치합니다.
- 문서의 `src0` 표 수정을 부탁드립니다. 같은 형식의 표를 쓰는 다른 FMA 계열(FMABF, I8FMA, F8FMA, I4FMA, F8F8MA 등)도 함께 확인 부탁드립니다.

## 문서 내용

`rebel/evt1/tu/FMA.html`의 `src0` 표 (발췌):

| `src0` | `run_mode`==0 | `run_mode`==1 | `run_mode`==2 |
|---|---|---|---|
| 0x0 ~ 0x2 | LRF[0] ~ LRF[2] | {LRF[1],LRF[0]} ~ {LRF[5],LRF[4]} | {LRF[3]..LRF[0]} ~ {LRF[11]..LRF[8]} |
| 0x3 ~ 0x5 | LRF[3] ~ LRF[5] | {LRF[7],LRF[6]} ~ {LRF[11],LRF[10]} | N/A |
| 0x6 ~ 0xB | LRF[6] ~ LRF[11] | N/A | N/A |

이 표대로라면 `run_mode`==2에서 `src0`=4는 정의되지 않은 값입니다.

## 실제 code가 쓰는 encoding

rcl2가 생성한 dense(`RblnDenseFp16Args`, M=16, K=1024, N=64) code의 TU program에는 다음 두 FMA가 있습니다. 두 FMA는 TU row마다(8개) 있고, 16개 DNC 모두 같습니다.

```asm
// dnc-disasm 출력. 첫 번째: src0 생략(=0), run_mode=2 → X = {LRF[3..0]}
FMA  src1=0xd src2=2 tgte=2 tgtrf=8 url=0x14 urldeg=2 tgturl=1 run_mode=2
// 두 번째: src0=4, run_mode=2 → 의도는 X = {LRF[7..4]}
FMA  src0=4 src1=8 src2=2 tgte=2 tgts=3 tgtrf=0xf url=0x12 urldeg=2 s1url=1 run_mode=2 be=1
```

- 첫 번째 FMA는 X = {LRF[3..0]}로 4-원소 dot product를 계산해 LRF8~11에 씁니다(4x unroll, `lrf_tgt` 증가).
- 두 번째 FMA는 X = {LRF[7..4]}, Y = LRF8~11(4x unroll, `src1` 증가)로 나머지 4개를 더해 South로 내보냅니다.
- 문서 해석이라면 두 번째 FMA는 `src0`=1이어야 합니다. 하지만 rcl2는 `src0`=4를 쓰고, 그 결과가 golden과 맞습니다.

PrecSim(`rebel_prec_sim`, `prec_sim_process.py`)도 같은 방식으로 해석합니다.

```python
src0_data  = ctx.lrf[src0]
src0_data1 = ctx.lrf.get(src0 + 1, 0)
src0_data2 = ctx.lrf.get(src0 + 2, 0)
src0_data3 = ctx.lrf.get(src0 + 3, 0)
```

## VP 실험

rcl2 dense(위와 같은 case)를 rcl2가 만든 입력(`SHM_map.txt`)으로 VP에서 두 번 돌렸습니다.

1. **원본:** rcl2 code 그대로(`src0`=4).
2. **변경:** `run_mode`=2인 위의 두 번째 FMA 128개(16 DNC × 8 TU row)의 `src0`만 4 → 1로 바꾸고 나머지는 그대로 assemble.

VP 실행:

```bash
cd rebel_compute_lib2/vp
./260521_vp_rebel_evt1_arbcal <workdir> 2 8 125000 2 0 0 1 0x3f8000 1.9   # skip_tu=0
```

출력(16 line × 64 원소)을 rcl2 golden(`SHM_golden.txt`)과 비교한 결과:

| code | 최대 오차 / golden RMS | 평균 오차 / golden RMS | golden과의 상관계수 |
|---|---|---|---|
| 원본 `src0`=4 | 0.0056 | 0.00057 | 1.00000 |
| 변경 `src0`=1 | 2.72 | 0.47 | 0.80 |

- 두 경우 모두 cycle 수(1993)와 출력 외 SHM 영역은 같고, 출력 값만 다릅니다.
- 원본은 반올림 수준의 차이로 golden과 일치합니다.
- `src0`=1은 문서 해석이라면 {LRF[7..4]}여야 하지만 결과가 틀립니다. 시작 LRF 번호 해석({LRF[4..1]})이라면 LRF4 하나만 겹치므로, 상관계수 0.8이 남는 것과도 맞습니다.

## 요청

1. TU FMA의 `src0` 표를, `run_mode` > 0일 때 `src0`가 group의 시작 LRF 번호라는 실제 동작에 맞게 수정해 주세요.
   - 시작 번호가 정렬(예: N=4에서 0, 4, 8)되어야 하는지도 명시해 주시면 좋겠습니다. 이번 실험에서는 0과 4만 확인했습니다.
2. 같은 형식의 `src0` 표를 가진 FMA 계열 opcode(FMABF, I8FMA/I8FMABF, F8FMA/F8FMABF, I4FMA/I4FMABF, F8F8MA/F8F8MABF)도 같은지 확인해 주세요.
3. unroll의 "`src0` may increase by >1 depending on `run_mode`" 설명이 시작 번호 해석에서 정확히 얼마씩 증가하는지도 함께 적어 주시면 좋겠습니다.
