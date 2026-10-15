# [Slack] #dnc_shm_work_group 에서 찾은 ISA 관련 논의

2026-09-30에 검색해서 정리함. 원문 스레드 링크를 함께 적었다.

## 1. MVLOOPCNT cont/brk, 그리고 PC 범위 (2024-04-23)
- 링크: https://rebellions-ai.slack.com/archives/C048B1AGVS7/p1713850613044449
- 참여: Yashael Faith Arthanto, 김현성, 김진석
- 확인된 사실 (김현성 답: "Yes for all the three"):
  1. `MVLOOPCNT(dynloop=1, cont=0, brk=1)`: break 시 즉값 위치로 jump
  2. `MVLOOPCNT(dynloop=0, cont=0, brk=1)`: break 시 `JCR[src0]` 위치로 jump
  3. `cont=1`일 때도 dynloop의 효과는 위와 같다
- PC는 모든 유닛에서 8-bit다. IBUFF는 SPLU/SPSU/NCLU/NCSU가 256 entry, 나머지(VU 등)는 128 entry다.
  128 entry 유닛에서 PC의 MSB가 서 있으면 명령이 RETURN으로 mux된다. VP(PrecSim)는 segfault를 피하려고 `%128`을 하므로 동작이 다르다.
  → 128을 넘는 곳으로 jump하는 것은 invalid 동작으로 결론.

## 2. FMA/FNMS/FMUL의 NaN 부호 규칙 (2023-10-17~18)
- 링크: https://rebellions-ai.slack.com/archives/C048B1AGVS7/p1697599848497369?thread_ts=1695004345.991569&cid=C048B1AGVS7
- 참여: Karim Charfi, 김진석
- FNMS의 정의가 `−(src0·src1) + src2`임이 대화에서 확인된다.
- 합의된 규칙 (x·y+z 형태):
  - `(x 또는 y가 NaN) && z != NaN` → `result_sign = x_sign ^ y_sign ^ fnms` (FNMS면 부호 반전)
  - `z == NaN` → `result_sign = z_sign`
  - dlf16 NaN 표기: `0x7fff` / `0xffff`
- IME는 부호를 바꾸지 않는다. 부호는 src2에서 그대로 온다(Karim: "there is no sign change for IME. it's passed as is from src2"). −0.0 허용 여부도 논의됨.

## 3. 기타
- #dnc_shm_work_group, 2023-11-05 김진석: XVU/VU new ops 업데이트(`feature/xvuvu/newops`, RTL + VP `rebel_new`). 새 VU/XVU 연산이 들어온 시점.
- #dev_sw_primitive, 2025-07-16 방재호: `FOR_LOOP_ARGS(mvloopcnt_wrapper)` syntax change (rebel_compute_lib2 쪽 MVLOOPCNT 래퍼).
