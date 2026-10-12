# dnckit → dnc_binutils 정리 (draft)

_2026-10-06, 검토 단계. 아직 착수 안 함._

## 목표
- dnckit을 binutils처럼 **image를 다루는 도구**로 좁힌다: `as`(asm text → init image), `objdump`(image → asm text), verifier, 나중에 `ld`.
- 코드 생성 도구(`authoring`의 대부분)는 mcc로 옮긴다.
- mcc와 dnc_binutils 사이 경계는 **asm text(ABI)** 로 한다. mcc는 `build_init_bytes`/`gen_flits`/`HdrFlit` 같은 내부를 직접 부르지 않는다.
- 단, 컴파일러가 컴파일 중에 알아야 하는 **target description**(ISA 사실)은 asm text로 대체할 수 없으므로 별도 층으로 공유한다 (LLVM `.td`에 해당).

## 현재 사용 현황 (2026-10-06 grep 기준)
| 노출 | 외부 사용 |
|---|---|
| top-level `build_init_bytes`, `decode`, `disasm` | 0 (모두 서브모듈로 직접 import) |
| `disasm`, `memfile` | 0 |
| `authoring` | mcc 대부분 (`rec` 28, `UNIT_SPR` 9, `sp_st_base`/`nc_burst_chunks` 7, `nc_desc` 6, `chunk_ldmu`, `UNIT_UID`, `LREG`, `build_block`, `make_hdr`, `sync_imm`, `const_lrf`, private `_SE`), primitives 1곳 |
| `dnc_enc` | mcc: `build_init_bytes`, `gen_flits`(flit 수), `HdrFlit.MAX_LRF_SLOTS`/`lrf_idx`, `encode_instr`. primitives: `HdrFlit` |
| `isa_tables` | mcc: `bitpos_dict`, `opcode_dict` 직접 |
| `nc_desc`, `sync_codec` | mcc (`pack`/`decompose`/`FIELDS`, `mesync_imm`), r100 verification (`sync_codec`) |
| `dnc_dec.decode` | 주로 primitives tests (생성 image 검사) |
| `silicon` | kcc, mcc, primitives |
| `conformance` | primitives tests, mcc tests |
| `dnc_asm` (신규) | perfreg |

## 목표 층 구조
| 층 | 내용 | 공개 API |
|---|---|---|
| `dnc_isa` (target description) | `isa_tables`, operand codec(`nc_desc`, `sync_codec`, `LREG`, `sync_imm`, `make_hdr`/`spr`), 크기 사실(LRF slot 수, `IBUFF_ENTRY`, instr/flit), unit id·home column | 라이브러리 (mcc, dnc_binutils 공유) |
| `dnc_binutils` | `as`, `objdump`(lossless dump + 읽기용 disasm), verifier(`silicon`, `conformance`), 이후 `ld` | CLI + 작은 API: `assemble`, `disassemble`, `check` |
| mcc | `authoring`의 code-gen 부분(`Program`, `make_block`/`build_block*`, `with_multi_tile`/`with_col`, `pad_return_recs`, `nc_burst_chunks`/`chunk_ldmu`, `sp_*` 주소 helper, `const_lrf`, `line_slots`) + asm text 생성 | — |

정리 대상:
- `memfile`: 사용처 없음. precsim `_slots_to_line`, `precsim_bridge.shm_codec`와 중복 → 삭제 또는 precsim 쪽으로 통합.
- `authoring.nc_desc`: `nc_desc` 모듈과 중복 → 통합.
- numux 의존: `const_lrf` 하나 때문 → mcc로 가면 binutils/isa는 의존성 없음.
- `UNIT_SPR`(기본 SPR)은 정책에 가까움 → isa에 둘지 mcc에 둘지 결정 필요.
- `conformance`는 production profile JSON을 들고 있음 → binutils의 lint로 둘지 별도 도구로 뺄지 결정.

## asm text를 ABI로 쓰려면 필요한 것
지금 `dnc_asm` 형식은 objdump 출력을 무손실로 옮긴 것(raw header 잔여 bit, raw LRF word, 절대 `col`/`line`)이라 컴파일러 출력 형식으로는 저수준이다.
- operand를 symbolic하게: NC descriptor `nc(shm=…, sp=…)`, SYNC `send peers=splu0`, LRF 슬롯 이름.
- 배치(`col`/`line`)는 as/ld가 결정. 컴파일러는 unit별 program만 낸다.
- 무손실 형식은 objdump/round-trip용으로 유지 (perfreg가 사용).
- in-process 빠른 경로(텍스트 거치지 않음)는 LLVM integrated assembler처럼 유지 가능. 단 parse된 AST와 같은 schema로 하고, "mcc 직접 결과 == asm text 거친 결과"를 테스트로 묶는다.

## `ld`가 필요한 이유
- 지금 mcc는 SHM 주소를 절대값으로 받는다 (`AddSpec(in1_addr=0x01, …)`).
- perfreg에서 rcl2와 mcc를 같은 메모리 배치로 비교하려면 주소 relocation이 필요하다.
- `ld`: DNC 16개 program 묶기 + tensor symbol → SHM/SP 주소 resolve + VP 입력 세트(`init_<d>.txt`) 생성.

## 진행 순서 (안)
1. 사용처 없는 노출 제거: top-level re-export, `disasm`(필요 시 objdump CLI로), `memfile`.
2. `authoring` 분할: ISA 부분 → `dnc_isa`, code-gen 부분 → mcc. 호출부 일괄 migrate (alias 남기지 않음).
3. mcc가 dnc_enc 내부(`gen_flits`, `HdrFlit`, `encode_instr`)를 쓰는 곳을 `dnc_isa`의 크기 사실로 대체.
4. 패키지 rename `dnckit` → `dnc_binutils`, CLI(`dnc-as`, `dnc-objdump`) 추가.
5. symbolic asm 형식 설계 → mcc가 asm text를 내도록 전환.
6. `ld` 설계 (relocation, VP 입력 세트 생성) — perfreg와 연결.

## 열린 질문
- `dnc_isa`를 별도 uv 패키지로 둘지, dnc_binutils의 하위 모듈로 둘지.
- `silicon` 검사를 `as`에 항상 걸지(현재 `build_init_bytes`가 항상 검사) 아니면 별도 `check` 단계로 둘지.
- mcc/primitives tests 13개 파일이 `dnc_dec.decode`로 emit image를 **컴파일러 IR과 같은 dict**로 되살려 컴파일러 결정(NCSU cursor reset, NCore broadcast bit, VU const pool, url unroll, feed order)을 검사한다. `realize`/`build_*`가 bytes만 돌려주기 때문의 우회. 문제: mcc IR = encoder 입력 = decoder 출력이 같은 schema라 테스트·컴파일러·binutils가 한 타입에 묶임.
  - 원칙: mcc IR과 binutils 표현(decode 결과/asm AST)을 다른 타입으로 분리, 접점은 asm text(ABI)뿐.
  - 컴파일러 결정 검사 → mcc IR(encode 전)에서. `build_*`가 IR도 돌려주게 하고 위 13개 파일 이전.
  - 산출물 검사 → asm text FileCheck 또는 byte golden. `decode`는 binutils 내부(as round-trip, verifier, objdump) API로 축소.
- `mcc/tests/test_dnckit_tiers.py`(dnckit은 자체 테스트 없이 ci-mcc/ci-primitives-bytes로 커버한다는 결정, #138)를 binutils 자체 테스트 lane으로 바꿀지.
