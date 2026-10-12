# add shape sweep: rcl2 vs mcc on the VP

_2026-10-08 측정. VP EVT1 (`260521_vp_rebel_evt1_arbcal`), 2 cluster × 8 DNC, DLFP16._

## 목적

- add를 여러 shape으로 키우고, rcl2 code와 mcc code의 VP cycle을 비교한다.
- rcl2가 shape마다 고른 tiling(`tiling_in_primitive=True`)을 그 shape의 최적 계획으로 가정한다.
- 공간 분할(cluster × DNC)이 충분하고 시간 반복(temporal iteration)이 있는 경우도 포함한다.

## 방법

1. **rcl2 capture:** `PrimitiveAuthor/mcc/tests/perf/scripts/capture_rcl2.py`로 code, data, golden을 capture한다.
   - 일반 add는 `RblnAddArgs`, 마지막 축이 8인 경우는 `RblnAddSub64Args`(sub64)를 쓴다.
   - 시간 반복이 필요한 case는 `sp_alloc`(DNC당 SP 할당)을 작게 줘서, rcl2가 스스로 DNC 안 tiling을 고르게 한다.
2. **mcc build:** 같은 SHM 배치를 kpl add(`R×K`)로 읽는다.
   - `R = 64 × a`이고, `a`는 32, 16, 15, …, 1 중 SHM line 수를 나누는 첫 값이다. `K = line 수 / a`이다.
   - 주소는 capture한 `SHM_map.txt`의 tensor 시작 line을 그대로 쓴다.
   - 일이 없는 DNC에는 RETURN만 있는 빈 program을 넣었다(t7, t8). mcc code에는 DNC 사이 MESYNC가 없다.
3. **VP 실행:** `run_vp.py`로 base(rcl2)와 mcc를 각각 돌린다.
   - `cycles` = VP가 멈춘 cycle, 즉 모든 DNC가 끝난 시점이다.
   - 모든 case에서 두 code 모두 SHM golden과 bit 단위로 일치했다.

## rcl2 `Tiling` 필드의 뜻

출처는 rcl2 `python/rbln_primitives_template.py`의 `Tiling`이다. 배열은 tensor 축마다 값이 하나씩이다.

| 필드 | 뜻 |
|---|---|
| `tiling_cluster[i]` | 축 i를 cluster 몇 개에 나누는지 (공간) |
| `tiling_dnc[i]` | 축 i를 cluster 안의 DNC 몇 개에 나누는지 (공간) |
| `tiling_iter[i]` | 축 i를 자른 조각 수 전체 (공간 + 시간) |
| `tiling_intra = iter ÷ (cluster × dnc)` | DNC 하나가 그 축에서 순서대로 도는 조각 수 (시간 반복) |

rcl2 add의 tiling 결정(`include/src/develop/rebel/alpha/rebel_initgen_arithmetic_plain.h`):

- 마지막 축을 64로 나눠 line 단위로 본다(vector 폭 64 element, 128B line).
- `set_inter_tiling`: 안쪽 축부터 크기를 곱해 "DNC 16개로 나눠도 DNC당 32 line 이상"이 되는 축을 기준으로 정한다. 그 축과 바깥 축 중 큰 축부터 cluster와 DNC에 나눈다.
- `set_full_tiling`: DNC tile이 SP 할당에 들어가지 않을 때만 DNC 안에서 시간 반복을 넣는다.
- add는 tensor가 3개라 기본 SP(약 4MB)로는 시간 반복이 생기지 않는다. 생기려면 tensor 하나가 약 21MB를 넘어야 하는데, 그러면 셋이 64MB SHM을 넘는다.

DNC 안의 instruction 수준 반복은 tiling과 별개다. 예를 들어 t1의 rcl2 VU는 `MVLOOPCNT 32` × `url=2`(instruction당 4번 unroll) = 128 line을 처리한다.

## 결과

| case | shape | SHM line | rcl2 분할 축 | cl×dnc | cluster당 tile | DNC당 tile | rcl2 시간 반복 | mcc (R×K, DNC, DNC당) | rcl2 cyc | mcc cyc | mcc/rcl2 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| t1 | 4×512×64 | 2048 | ax1: 2cl×8dnc | 2×8 | 4×256×64 | 4×32×64 | 1 | 2048×64, 16, 128×64 | 1600 | 2083 | 1.30 |
| t2 | 16×128×64 | 2048 | ax0: 2cl×8dnc | 2×8 | 8×128×64 | 1×128×64 | 1 | 2048×64, 16, 128×64 | 1600 | 2083 | 1.30 |
| t3 | 1×2048×64 | 2048 | ax1: 2cl×8dnc | 2×8 | 1×1024×64 | 1×128×64 | 1 | 2048×64, 16, 128×64 | 1600 | 2083 | 1.30 |
| t4 | 64×32×64 | 2048 | ax0: 2cl×8dnc | 2×8 | 32×32×64 | 4×32×64 | 1 | 2048×64, 16, 128×64 | 1600 | 2083 | 1.30 |
| t5 | 8×256×128 | 4096 | ax1: 2cl×8dnc | 2×8 | 8×128×128 | 8×16×128 | 1 | 2048×128, 16, 128×128 | 2366 | 3535 | 1.49 |
| t6 | 16×512×64 | 8192 | ax1: 2cl×8dnc | 2×8 | 16×256×64 | 16×32×64 | 1 | 2048×256, 16, 128×256 | 3696 | 6172 | 1.67 |
| u4 | 64×512×64 | 32768 | ax1: 2cl×8dnc | 2×8 | 64×256×64 | 64×32×64 | 1 | 2048×1024, 16, 128×1024 | 6129 | 16910 | 2.76 |
| t7 | 3×231×64 | 693 | ax1: 2cl×8dnc | 2×8 | 3×116×64 | 3×15×64 | 1 | 704×63, 11, 64×63 | 1072 | 1113 | 1.04 |
| t8 | 7×33×192 | 693 | ax0: 1cl×7dnc | 1×7 | 7×33×192 | 1×33×192 | 1 | 704×63, 11, 64×63 | 904 | 1113 | 1.23 |
| t9 | 128×128×8 (sub64) | 2048 | ax0: 2cl×8dnc | 2×8 | 64×128×8 | 8×128×8 | 1 | 2048×64, 16, 128×64 | 1600 | 2083 | 1.30 |
| t10 | 512×32×8 (sub64) | 2048 | ax0: 2cl×8dnc | 2×8 | 256×32×8 | 32×32×8 | 1 | 2048×64, 16, 128×64 | 1600 | 2083 | 1.30 |
| u1 | 16×512×64, SP 64KB | 8192 | ax1: 2cl×8dnc | 2×8 | 16×256×64 | 16×32×64 | 4 (ax1, 한 번에 16×8×64) | 2048×256, 16, 128×256 | 4516 | 6172 | 1.37 |
| u2 | 16×512×64, SP 32KB | 8192 | ax1: 2cl×8dnc | 2×8 | 16×256×64 | 16×32×64 | 7 (ax1, 16×5×64) | 2048×256, 16, 128×256 | 6699 | 6172 | 0.92 |
| u3 | 16×512×64, SP 16KB | 8192 | ax1: 2cl×8dnc | 2×8 | 16×256×64 | 16×32×64 | 16 (ax1, 16×2×64) | 2048×256, 16, 128×256 | 9007 | 6172 | 0.69 |
| u5 | 64×512×64, SP 96KB | 32768 | ax1: 2cl×8dnc | 2×8 | 64×256×64 | 64×32×64 | 8 (ax0, 8×32×64) | 2048×1024, 16, 128×1024 | 7986 | 16910 | 2.12 |

- "ax1: 2cl×8dnc"는 축 1을 cluster 2개로, 각 cluster 안에서 DNC 8개로 나눴다는 뜻이다.
- SP 표시가 있는 case(u1~u3, u5)는 rcl2에만 SP 할당을 작게 줬다. mcc는 이 제한 없이 빌드해서, u1~u3의 mcc cycle은 t6과 같다.
- 같은 날 먼저 돌린 4D shape(`[4,16,32,64]`, `[8,16,32,64]`, `[16,16,32,64]`)은 같은 line 수의 3D case(t1, t5, t6)와 cycle이 같았다.

## 관찰

1. **rank와 축 배치는 영향이 없다.** 같은 2048 line인 t1~t4와 sub64 t9, t10은 rcl2와 mcc 모두 cycle이 같다.
2. **크기가 커질수록 mcc가 더 뒤처진다.** DNC당 line이 128 → 256 → 512 → 2048로 늘 때 mcc/rcl2는 1.30 → 1.49 → 1.67 → 2.76이다.
   - mcc cycle은 line 수에 거의 비례한다(약 8.2 cycle/line).
   - rcl2는 덜 늘어난다(DNC당 2048 line에서 6129 cycle).
   - mcc의 DNC 안 처리(burst 크기, unroll, pipeline 겹침)에 개선 여지가 있어 보인다. 원인은 아직 분석하지 않았다.
3. **rcl2도 시간 반복이 많아지면 느려진다.** t6 크기에서 시간 반복 1 → 4 → 7 → 16일 때 3696 → 4516 → 6699 → 9007 cycle이다. SP 16~32KB에서는 mcc가 더 빠르다(u2, u3). 단, mcc는 SP 제한을 받지 않아 공정한 비교는 아니다.
4. **나누어떨어지지 않는 크기:**
   - t8에서 rcl2는 DNC 7개만 쓴다(축 0, 크기 7만 나눌 수 있음).
   - mcc는 지금의 `R×K` 방식으로 693 line을 DNC 11개에만 나눌 수 있다.
5. **mcc는 DNC 사이 불균형이 크다.** DNC 0보다 가장 느린 DNC가 계속 늦다(예: t1 1443 대 2025). rcl2는 이 차이가 작다(1455 대 1540).

## 다음 단계 후보

- 2번 원인 분석: t6이나 u4에서 rcl2 code와 mcc code의 unit별 loop, burst, unroll을 나란히 비교한다.
- `tests/perf`에 정식 test case로 넣을 shape을 고른다. 후보는 u4(차이가 가장 큼), u5(시간 반복), t8(홀수 크기)이다. mcc가 느린 case는 tolerance를 정해야 한다.

## 재현

script는 [`add-shape-sweep/`](add-shape-sweep/)에 있다.

| 파일 | 역할 |
|---|---|
| `sweep.sh` | case마다 capture → kernel.py 생성 → mcc build → VP 두 번 |
| `capture_one.py` | rcl2 interpreter에서 한 shape을 capture (`dims@sp_alloc`) |
| `mcc_one.py`, `kernel_tmpl.py` | SHM_map에서 주소와 line 수를 읽어 `kernel.py` 생성 |
| `table.py` | capture log와 결과 json으로 위 표 생성 |

```bash
~/workspaces/docs/add-shape-sweep/sweep.sh t1:4x512x64 u1:16x512x64@65536 ...   # 결과는 /tmp/perf-sweep/
python3 ~/workspaces/docs/add-shape-sweep/table.py /tmp/perf-sweep t1 u1@65536 ...
```

- `capture_one.py`는 `capture_rcl2.py`의 `TestCase.test_id`가 `None`을 받는 버전이 필요하다. 이 변경은 2026-10-08 기준 working tree에만 있다(commit 전).
- t7, t8의 mcc는 `sweep.sh`가 자동으로 처리하지 않는다. `mcc-code/init_11.s`~`init_15.s`에 아래 빈 program을 넣고 `run_vp.py`를 다시 돌렸다.

```
== NCLU (0x200) col7 line=0 | ib=1 lccr=0 lrf=0 lrf_idx=[-] ==
   SPR: 0xff01ff
   [ 0] RETURN
   [ 1] RETURN
   [ 2] RETURN
   [ 3] RETURN
```
