# DNC ISA 요약: sqrt.asm에 나오는 명령

- 대상: `examples/mcc/sqrt.asm`(줄마다 주석을 단 버전. 원본 디스어셈블은 `sqrt.raw.asm`, sqrt 예제 DNC 0을 `dnc_dec --all`로 디스어셈블한 결과, R=256·K=64 중 DNC당 64×64)
- 기준 저장소: `~/workspaces/codesigner` `dev` `aafd7348`. 경로는 이 저장소 루트 기준이다.
- 표기: `[hi:lo]`는 명령 word 안의 비트 위치, `σ`는 머신 상태, `LRF[r]`은 유닛 레지스터다.
- 확인 수준: **spec** = `dnc_spec/isa_spec` 문서, **enc** = `dnckit/isa_tables.py`, **idiom** = mcc 코드 주석에서 추론, **sqrt** = 이 예제 값으로 검산. 수치 semantics가 공식 문서로 확인되지 않은 것은 ⚠로 표시했다.

## 0. 문법(syntax)

텍스트 어셈블리 언어는 없다. 두 가지 표기가 같은 것을 가리킨다.

```
dnc_dec 출력 :  [ j] OPCODE  field=val field=val ...        # j = IBUFF 안의 명령 번호
작성 (Python):  rec(unit, "OPCODE", field=val, ...)         # dnckit.authoring, 빠진 필드는 0
```

- 유닛 block 머리줄: `== UNIT (unit-id) colN line=L | ib=<flit 수> lccr=<n> lrf=<n> lrf_idx=[..] ==`, 그 다음 줄 `LRF:`는 초기 레지스터 값이다.
- 명령 크기: SP/NC 유닛 32-bit(flit당 4개), VU/XVU 64-bit(flit당 2개). opcode는 항상 `[5:0]`.
- **같은 mnemonic도 유닛마다 opcode와 비트 위치가 다르다**(아래 표의 opcode 열).
- `be`(branch-end): loop body의 마지막 명령에 1. 32-bit 유닛은 bit 31, VU/XVU는 bit 35.
- 파일 첫 두 줄의 `RuntimeWarning`은 `python -m dnckit.dnc_dec` 실행 경고라 무시해도 된다.

### VU 피연산자 태그 (`src0/src1/src2`, `lrf_tgt`)

| 값 | 의미 |
|---|---|
| `0x0` | 상수 0 |
| `0x1` xvu · `0x2` tu · `0x3` nbr · `0x4` **splu** | FIFO/이웃 입력. `0x4`는 SPLU FIFO에서 1 beat pop |
| `0x6` slice_id · `0x8` nfwd · `0x9` reuse | 특수 소스 |
| `0xA–0xF` | 상수 레지스터(`src1/src2`만) |
| `0x10–0x1F` | `LRF[0..15]`. `lrf_tgt`도 같은 태그를 쓴다. `lrf_tgt=0`이면 LRF에 쓰지 않는다 |

XVU는 이 표와 다르다(`0x1`=splu). 출처: `dnckit/src/dnckit/authoring.py` `LREG` docstring.

## 1. 명령 목록

| 명령 | 유닛(opcode) | 한 줄 요약 |
|---|---|---|
| `MVLOOPCNT` | 전 유닛(NC 0x30, SP/VU 0x21) | 다음 명령부터 `be=1`까지를 n번 반복 |
| `RETURN` | 전 유닛(NC 0x37, SP/VU 0x3f) | 이 유닛 프로그램 종료 |
| `SYNC` | NC 0x0c, SP 0x26 | 유닛 간 카운팅 채널에 put/get |
| `LDMU` / `STMU` | NCLU / NCSU 0x23 | SHM → SP / SP → SHM, burst 줄 단위 |
| `LDU` / `STU` | SPLU / SPSU 0x11 | SP → compute FIFO / compute FIFO → SP |
| `IMMCOPY` | VU 0x25 | 즉값을 LRF에 broadcast |
| `FMA` | VU 0x04 | `src0·src1 + src2` |
| `FNMS` | VU 0x06 | `src2 − src0·src1` (디코더는 `FADDHP`로 표시) |
| `EE` | VU 0x0d | 지수 추출 ⚠ |
| `SHR` | VU 0x0f | 정수 오른쪽 shift ⚠ |
| `IME` | VU 0x09 | 지수 조작(2의 거듭제곱 곱) ⚠ |

## 2. 제어 명령

### MVLOOPCNT
```
fields  src0[9:6] typ1_imm[25:10] dynloop[26] force_jump[27] brk[30] cont[31]      (SP/NC)
        src0[10:6] typ1_imm[26:11] force_jump[27] dynloop[28] brk[34] cont[35]     (VU)
```
```
cnt := dynloop ? JCR[src0] : typ1_imm
push LOOP := (count=cnt, body=PC+1)     # body는 be=1인 명령에서 닫힌다
```
- 중첩 loop는 `MVLOOPCNT`를 쌓아서 만든다. `cont/brk`는 중첩 loop 조합용, `force_jump`는 무조건 jump.
- `be` 필드가 따로 없다. `cont`가 다른 명령의 `be`와 같은 비트를 쓴다.
- 실리콘에서는 loop open/close가 반드시 짝이 맞아야 한다. PrecSim은 짝이 안 맞아도 통과시킨다.
- `brk`/`cont` 시 jump 대상: `dynloop=1`이면 즉값, `dynloop=0`이면 `JCR[src0]`(Slack `#dnc_shm_work_group`, 2024-04).
- PC는 8-bit다. IBUFF가 128 entry인 유닛(VU 등)에서 PC ≥ 128이면 명령이 RETURN으로 바뀐다. PrecSim은 `%128`로 처리하므로 결과가 다르다.
- sqrt: NCLU/NCSU `typ1_imm=2`, SPLU/SPSU/VU `0x40`(64). 출처: spec C6, enc.

### RETURN
```
fields  be   →   이 유닛의 IBUFF sequencer 정지
```
출처: spec C5.

### SYNC
```
fields  typ1ac_imm[29:10] (NCLU/NCSU)   |   typ1_imm[25:10] (SPLU/SPSU)
imm bitmask:  bit0 SEND  bit1 RECV  bit2 NCLU  bit3 NCSU  bit4 SPLU0  bit5 SPSU0  bit6 SPLU1  bit7 SPSU1
```
```
SEND: {self}_{peer}_sync += 1                       # 채널이 가득 차면 stall
RECV: wait {peer}_{self}_sync > 0; then -= 1
```
- 채널은 정수 카운터라서 k번째 get이 k번째 put과 짝지어진다. 한 채널에 여러 edge를 섞으면 순서를 맞춰야 한다.
- VU/XVU에는 SYNC가 없다. FIFO backpressure만으로 순서가 정해진다.
- 작성할 때는 `authoring.sync_imm(send=, recv=, peers=[...])`를 쓴다.

| sqrt 줄 | imm | 뜻 |
|---|---|---|
| NCLU `[2] SYNC 0x11` | SEND+SPLU0 | 로드 끝, `nclu_splu0` put |
| SPLU `[0] SYNC 6` | RECV+NCLU | `nclu_splu0` get, 로드 끝날 때까지 대기 |
| SPSU `[2] SYNC 9` | SEND+NCSU | 저장 끝, `spsu0_ncsu` put |
| NCSU `[0] SYNC 0x22` | RECV+SPSU0 | `spsu0_ncsu` get |

출처: spec C2, enc.

## 3. 데이터 이동 명령

### LDMU (NCLU) / STMU (NCSU)
```
fields  src0[9:6] src1[13:10] src2[17:14] src3[21:18] burst[26:22] cache[28:27] qos_vae[30:29] be[31]
```
```
LDMU: for j in 0..n-1:  SP[sp_line + j]  := SHM[shm_line + j]
STMU: for j in 0..n-1:  SHM[shm_line + j] := SP[sp_line + j]
      n = (burst == 0) ? 32 : burst        # 5-bit, 31 초과 값은 조용히 잘린다
```
- 주소는 명령 필드가 아니라 **LRF descriptor**에서 온다. `src0..3`은 descriptor 번호(보통 0)다.
- descriptor(128-bit): `SAR[14:0]` `SBR[31:16]`(SP 쪽) · `CAR[51:32]` `CBR[83:64]`(SHM 쪽). `nc_desc(shm_line, sp_line)`은 `[83:80]=0x8`(SHM 영역), `[79:64]=SHM line`, `[27:16]=SP line`으로 만든다.
- burst만큼 주소가 자동으로 증가하고, 그 증가분은 다음 명령까지 유지된다. 그래서 연속 로드는 명령을 그냥 반복하면 된다.
- `cache`, `qos_vae`는 상태에 영향이 없다.

sqrt 검산:
- NCLU `LRF: 0x8100…010000` → SHM line `0x1000`, SP line 1. `MVLOOPCNT 2 × burst 32 = 64줄`(64행 × 64원소 dlf16).
- NCSU `LRF: 0x8110…420000` → SHM line `0x1100`, SP line `0x42`. 같은 방식으로 64줄을 쓴다.

출처: spec D1/D9, 주소 모델, `authoring.nc_desc`.

### LDU (SPLU)
```
fields  src0[9:6] src1[13:10] interleave_sz[15:14] burst[16] burst_sz[22:17] ld_rot[26:24] ld_type[28:27] ld_consumer[30:29] be[31]
```
```
LRF[src0] += LRF[src1]                          # 접근 전에 먼저 증가
blk := SP[LRF[src0] .. +size]                   # LRF[src0]은 byte 주소(line×0x80)
enqueue(FIFO[ld_consumer], layout(blk, ld_rot, interleave_sz))
size = burst ? (burst_sz or 64) : 1 line        # ×2/×4 if interleave_sz = 2/3
ld_consumer: 0 self · 1 xvu · 2 spsu · 3 vu
```
- 포인터가 **접근 전에** 증가하므로 시작 주소는 목표보다 한 줄 앞으로 잡는다.
- stride 레지스터가 0이면 매 beat 같은 줄을 다시 읽는다.
- sqrt: `LRF: 0x0 0x80` → 첫 beat가 byte `0x80` = SP line 1을 읽는다. NCLU가 채운 위치와 맞는다. `ld_consumer=3` → VU. 64번 반복하면 64줄.

출처: spec D2, families_operational.

### STU (SPSU)
```
fields  src0[9:6] src1[13:10] interleave_sz[15:14] burst[16] burst_sz[22:17] st_type[28:27] st_producer[30:29] be[31]
```
```
blk := dequeue(FIFO[st_producer])
LRF[src0] += LRF[src1];  SP[LRF[src0]] := layout(blk, interleave_sz)
st_producer: 0 zeros(FIFO 없음) · 1 xvu · 2 vu · 3 splu
```
- sqrt: `LRF: 0x2080 0x80` → 첫 쓰기가 `0x2100` = SP line `0x42`. NCSU가 읽는 위치와 맞는다. `st_producer=2` → VU.

출처: spec D8, families_operational.

## 4. VU 연산 명령

모든 VU 연산의 공통 필드와 동작:
```
fields  src0[10:6] src1[15:11] src2[20:16] out_nbr[21] out_sp[23:22] out_xvu[25:24]
        lrf_tgt[34:30] be[35] slice_en[43:36] mode|hpmode[44] url[50:45]
```
- 64 lane SIMD = slice 8개 × lane 8개. `slice_en=0xff`이면 전체 slice.
- `out_sp`/`out_xvu`: `3` = 계산 결과 출력, `1`/`2` = 통과(forward), `0` = 출력 안 함. `out_sp=3`이면 결과가 SPSU FIFO로 간다.
- `lrf_tgt ≥ 0x10`이면 결과를 `LRF[lrf_tgt−0x10]`에 쓴다.
- `url`: 하위 2비트 `n`이면 명령 하나가 `2^n` beat를 처리한다. 상위 비트는 반복마다 `src/tgt` 번호를 증가시킨다.
- FIFO 소스는 명령당 한 번만 pop된다(두 필드가 같은 FIFO를 가리켜도 한 번). 같은 값을 여러 번 쓰려면 먼저 LRF에 받아 둔다.

출처: spec D7, families_operational(vu-compute), enc.

### IMMCOPY
```
fields  typ1_imm[26:11] replica[29] lrf_tgt[34:30] be[35] slice_en[43:36]
LRF[lrf_tgt] := broadcast(typ1_imm)     # replica=1: 모든 lane, 0: lane 0만
```
- 상수는 반드시 `replica=1`로 쓴다. 0이면 lane 1–7에 이전 값이 남는다.
- sqrt의 상수(dlf16 = sign 1 | exp 6(bias 31) | mant 9):

| 줄 | 대상 | 값 | 뜻 |
|---|---|---|---|
| `[0]` | LRF0 | `0x3e00` | 1.0 |
| `[1]` | LRF1 | `0` | 0 |
| `[2]` | LRF2 | `0x3c00` | 0.5 |
| `[3]` | LRF3 | `0x3f00` | 1.5 |
| `[4]` | LRF4 | `0x3c80` | 0.625 (seed 보정 상수) |

출처: spec C3, dnc-programming-guide §3.1.

### FMA / FNMS
```
FMA  (0x04):  r := src0 · src1 + src2            (fused, 한 번만 반올림)
FNMS (0x06):  r := src2 − src0 · src1
```
- `FNMS`와 `FADDHP`는 opcode 6을 같이 쓰고 bit 44(`mode`/`hpmode`)로 구분한다. `hpmode=0`이면 FNMS다. `dnc_dec`는 이 opcode를 항상 `FADDHP`로 표시하므로, sqrt.asm의 `FADDHP ... hpmode=0`은 **FNMS**로 읽는다.
- `hpmode=1`(FMAHP/FADDHP/FRNDHP)은 더 넓은 누산기를 쓰는 고정밀 모드로, `LRF[tgt+8]`을 함께 쓴다.

- NaN 부호 규칙: `(x 또는 y가 NaN) && z≠NaN`이면 `sign = x^y^fnms`, `z=NaN`이면 `sign = z`(Slack `#dnc_shm_work_group`, 2023-10).

출처: spec D7, `isa_tables.py:279,291`, `reduction_and_mask_contract.md`(`FNMS(mask,1,1) = 1−mask`), Slack(FNMS = `−(src0·src1)+src2`).

### EE ⚠
```
r := exponent(src0)        # 지수를 정수로 추출. src1 = 모드(sqrt는 0), src2 = 0
```

### SHR ⚠
```
r := src0 >> src1          # 정수 shift. sqrt는 src1=1을 shift 양(즉값)으로 쓴다
```

### IME ⚠
```
r := src2 · 2^(−src0)      # src1 = 모드. mode 2만 확인됨
```
- 부호는 바꾸지 않고 src2의 부호를 그대로 쓴다(Slack `#dnc_shm_work_group`, 2023-10).
- 세 명령 모두 수치 semantics는 `dnc_spec` 범위 밖이다. 위 식은 mcc idiom 주석(`mcc/src/mcc/ops/sqrt/vu_idiom.py`, `recip/vu_idiom.py`)과 `dnc-programming-guide.md` §3.2에서 추론했다.
- `src1`이 소스 태그가 아니라 모드나 즉값으로 쓰인다는 점에 주의한다. `FMINMAX`도 같은 패턴이다.
- 확인되지 않은 것: `EE`의 bias와 0·NaN 처리, `SHR`이 산술/논리 shift 중 무엇인지, `IME`의 다른 모드. 공식 **Rebellions ISA Reference Manual**(Notion "DNC ISA Documentations"에 첨부된 PDF, 2024-08)로 확인해야 한다.

## 5. 부록: sqrt VU 프로그램 해설

`s`는 입력 원소, `y`는 `1/√s`의 근사값이다. 64번 반복하고, 한 번에 64 lane(한 줄)을 처리한다.

```
[0-4]  IMMCOPY ...                 상수 1.0, 0, 0.5, 1.5, 0.625
[5]    MVLOOPCNT 64                줄마다 한 번
[6]    FMA  splu·1.0 + 0  → LRF5   s 캡처 (FIFO는 한 번만 pop되므로)
[7]    EE   LRF5          → LRF6   e = exponent(s)
[8]    SHR  LRF6 >> 1     → LRF6   e' = floor(e/2)
[9]    IME  0.625·2^-e'   → LRF8   y0 (seed)
[10]   FMA  s·0.5 + 0     → LRF7   s/2
[11-22] ×4 Newton:
       FMA  y·y + 0        → LRF9  t = y²
       FNMS 1.5 − (s/2)·t  → LRF10 u
       FMA  y·u + 0        → LRF8  y ← y·(1.5 − s·y²/2)
[23]   FMA  s·y + 0       → LRF11  √s = s·(1/√s)
[24]   FMA  LRF11·1.0 + 0 → out_sp=3, be=1   SPSU로 출력, loop 닫기
[25]   RETURN
```

전체 데이터 흐름(DNC 0):
```
SHM[0x1000..] ─LDMU×2(32줄)→ SP[1..64] ─SYNC 0x11/6→ LDU×64 → VU×64 → STU×64 → SP[0x42..] ─SYNC 9/0x22→ STMU×2 → SHM[0x1100..]
```

## 5A. 부록: 수치 해석과 가이드 §3.2 비교

### 수식

입력을 `x = m·2^e`(`m ∈ [1, 2)`)로 둔다.

```
e' = ⌊e/2⌋                                   # [7] EE, [8] SHR
y₀ = 0.625 · 2^(−e')                          # [9] IME
yₖ₊₁ = yₖ · (1.5 − (x/2)·yₖ²),  k = 0..3      # [11–22] Newton, y → 1/√x
√x ≈ x · y₄                                   # [23]
```

- **seed 범위**: `y₀·√x = 0.625·√m`(e 짝수) 또는 `0.625·√(2m)`(e 홀수)이므로 참값의 **[0.625, 1.25]배**다.
- **0.625를 곱하는 이유**: Newton은 `y < √3/√x`일 때만 수렴한다. 보정 없는 `2^(−⌊e/2⌋)`는 참값의 [1, 2)배라서 일부 입력이 발산하고, 조용히 참값의 3배 근처에 수렴한다. 0.625를 곱하면 전부 수렴 구간에 들어온다(`mcc/src/mcc/ops/sqrt/vu_idiom.py` docstring).
- **수렴 속도**: 상대오차가 `ε' ≈ 1.5·ε²`로 줄어든다. 최악 0.375에서 시작해 4번이면 충분하다.
- **한 단계 3명령**: `(3 − x·y²)/2` 대신 `1.5 − (x/2)·y²`를 쓴다. `x/2`는 루프 밖에서 한 번 계산하고([10]), 2로 나누는 것은 오차가 없다.

### 검산 (Python, 2^±20 범위 입력 2만 개)

dlf16 반올림은 연산마다 근사로 적용했다(9-bit 가수).

| 반복 횟수 | 실수 연산 최대오차 | dlf16 최대오차 |
|---|---|---|
| 3 | 3.4e-3 | 4.8e-3 |
| 4 | 1.7e-5 | **2.3e-3** |
| 5 | 4.5e-10 | 2.3e-3 |

4번이면 dlf16 표현 한계(약 2e-3)에 도달하고, 더 반복해도 나아지지 않는다. mcc 주석의 수치(3회 4.8e-3, 4회 2.2e-3)와 일치한다.

⚠ 이 해석은 `EE`가 bias를 뺀 지수를 돌려주고(1.0 → 0) `SHR`이 산술 shift라는 가정에 기댄다. mcc 코드가 PrecSim에서 통과하므로 이 가정과 일관되지만, 공식 ISA 문서로 확인하지는 않았다.

### reduction이 있는가

- **범위 축소(range reduction)**: 없다. 입력 `x`를 줄이지 않고 그대로 Newton에 넣는다(`FNMS`의 피연산자가 `x/2`). 지수는 seed 크기를 맞추는 데만 쓴다. Newton 식은 `x·y²`만 보므로, seed가 `x`의 크기에 맞춰져 있으면 `x`의 크기와 관계없이 수렴한다. 줄이지 않았으니 되돌리는 단계도 없다.
- **데이터 reduction(sum/max 등)**: 없다. sqrt는 원소별 연산이라 lane 사이나 줄 사이에 값을 합치지 않는다(trace `kind=streaming`). reduction 예제는 softmax, RMSNorm(`mcc/tests/fixtures/for_llama_decoder_kpl_gap_test.py`)을 본다.

### `dnc-programming-guide.md` §3.2와 비교

같은 `√x = x·rsqrt(x)` + Newton이지만 다른 구현이다. 가이드는 예전에 손으로 쓴 XVU 커널을, sqrt.asm은 mcc가 생성한 VU 코드를 설명한다.

| | 가이드 §3.2 | sqrt.asm |
|---|---|---|
| 실행 유닛 | XVU | VU |
| 범위 축소 | `EE`, `LOGICAL`(홀짝 p), `SHR`, `IME`×2 → `r ∈ [0.5, 2)` | 없음 |
| seed | HW reciprocal-root lookup | `0.625·2^(−⌊e/2⌋)` (EE→SHR→IME) |
| Newton 한 단계 | `y·(3 − r·y²)·0.5`, 명령 4개 | `y·(1.5 − (x/2)·y²)`, 명령 3개 |
| 반복 횟수 | 8 | 4 |
| 마무리 | `IME`×2로 되돌린 뒤 `x·rsqrt` | `x·y` |
| 정확도 | 0.20% | 약 0.22% |

가이드 서술이 현재 코드와 맞지 않는 점:
- "3 ops"라고 쓰고 명령 4개를 나열한다.
- seed로 쓴다는 reciprocal-root lookup은 mcc 주석에 따르면 없다. 추정 명령 `FEST`에는 rsqrt 모드가 없어서 mcc는 seed를 직접 만든다.

## 6. 출처

원본 스냅샷과 Notion/Slack 정리는 `refs/`에 있다(`refs/README.md`).


- `dnc_spec/isa_spec/families_control.md`: C2 SYNC, C3 IMMCOPY, C5 RETURN, C6 MVLOOPCNT
- `dnc_spec/isa_spec/families_data.md`: 주소 모델, D1 LDMU, D2 LDU, D7 VU, D8 STU, D9 STMU
- `dnc_spec/isa_spec/families_operational.md`: `ld_consumer`/`st_producer` 값, VU `url`/출력 라우팅
- `PrimitiveAuthor/dnckit/src/dnckit/isa_tables.py`: opcode, 필드 목록, 비트 위치, NC descriptor 비트
- `PrimitiveAuthor/dnckit/src/dnckit/authoring.py`: VU/XVU 소스 태그, `nc_desc`, `sync_imm`
- `PrimitiveAuthor/mcc/src/mcc/ops/sqrt/vu_idiom.py`: sqrt VU 시퀀스와 EE/SHR/IME 용법
- `PrimitiveAuthor/docs/dnc-programming-guide.md` §3: dlf16, 초월함수 계산법(§3.2는 예전 XVU 구현, 5A절 참고)
- Notion "DNC ISA Documentations": 공식 ISA Reference Manual PDF(2024-08)와 mkdocs 웹 문서 안내
- Slack `#dnc_shm_work_group`: MVLOOPCNT cont/brk VP·RTL 차이(2024-04), FNMS NaN 부호 규칙(2023-10)

## 7. 남은 일

1. 공식 ISA PDF로 `EE`/`SHR`/`IME` 수치 semantics와 모드 표를 채운다.
2. `ld_rot`, `ld_type`, `st_type`, `interleave_sz`의 layout 변환을 정리한다(sqrt에서는 전부 0).
3. TU/XVU/ABLU/ABSU 명령을 matmul 예제로 같은 형식으로 추가한다.
