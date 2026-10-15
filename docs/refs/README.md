# refs: DNC ISA / mcc 참고 자료 모음

`../dnc-isa-sqrt.md`를 쓸 때 참고한 원본 자료다. 2026-09-30에 모았다.
로컬 파일은 `~/workspaces/codesigner` `dev` `aafd7348`(2026-09-29)에서 **복사한 스냅샷**이라, 최신본은 원래 경로에서 확인한다.

## dnc_spec/ (원본: `codesigner/dnc_spec/`)
| 파일 | 내용 |
|---|---|
| `isa_spec_README.md` | ISA spec의 목표, 출처 기준, 작성 방법 (`isa_spec/README.md`) |
| `families_control.md` | 제어 명령 C1–C6: JCR, **SYNC**, **IMMCOPY**, NC 주소 레지스터, **RETURN**, **MVLOOPCNT** |
| `families_data.md` | 데이터 명령 D1–D13과 주소 모델: **LDMU/LDU/STU/STMU**, VU FMA 계열, XVU, TU, AB |
| `families_operational.md` | 명령별 FIFO in/out-port, extent, fire rule (PrecSim 코드 줄 번호 포함) |
| `ncore_spec_skeleton.md` | 유닛별 전체 opcode·필드 목록 (자동 생성) |
| `authoring_cheatsheet.md` | FIFO/SYNC 실전 규칙 |
| `program_lifecycle.md` | image → load → 실행 → fork-join |
| `init-bin-format.md` | init image 비트 수준 포맷 (`dnc_spec/docs/`) |
| `dnc-isa-interpreted.md` | bottom-up ISA 해석 참고서 (`dnc_spec/docs/`) |
| `splu_xvu_fifo_contract.md` | SPLU↔XVU FIFO 계약 (`dnc_spec/docs/`) |
| `reduction_and_mask_contract.md` | reduction, mask, FNMS 사용 예 (`dnc_spec/docs/`) |

## primitiveauthor/ (원본: `codesigner/PrimitiveAuthor/docs/`)
| 파일 | 내용 |
|---|---|
| `dnc-programming-guide.md` | 머신 모델, dlf16, sqrt 계산법(EE/SHR/IME + Newton) |
| `architecture.md` | PrimitiveAuthor 전체 지도 |
| `mapping-algorithms-onto-an-npu.md` | matmul m128n768 유닛별 분석 |
| `npu-architecture-factcheck.md` | HW/ISA 주장 약 71개 검증 |
| `memory-and-dma-topology.md` | 메모리 계층, DMA, 동기화 |

## code/ (원본 경로)
| 파일 | 원본 |
|---|---|
| `isa_tables.py` | `PrimitiveAuthor/dnckit/src/dnckit/isa_tables.py` — opcode/필드/비트 위치(생성 파일) |
| `authoring.py` | `PrimitiveAuthor/dnckit/src/dnckit/authoring.py` — `rec`, `LREG`(VU/XVU 소스 태그), `nc_desc`, `sync_imm` |
| `sqrt_vu_idiom.py` | `PrimitiveAuthor/mcc/src/mcc/ops/sqrt/vu_idiom.py` — sqrt VU 시퀀스, EE/SHR/IME 용법 |
| `recip_vu_idiom.py` | `PrimitiveAuthor/mcc/src/mcc/ops/recip/vu_idiom.py` — EE/IME/FEST 용법 |

## notion/, slack/
- `notion/dnc-isa-documentations.md`: 공식 ISA Reference Manual PDF와 문서 생성 방식 요약, 관련 페이지 링크
- `slack/dnc_shm_work_group-notes.md`: MVLOOPCNT cont/brk와 PC 범위, FMA/FNMS NaN 부호 규칙, IME 부호

## 받지 못한 자료
- **Rebellions_ISA_Reference_Manual-2.pdf** (Notion 첨부): EE/SHR/IME 수치 semantics 확인에 필요. Notion에서 직접 받아 이 폴더에 넣으면 된다.
- PrecSim 원본 `third_party/rebel_prec_sim`, ISA 문서 소스 `spec_source_inventory/dnc_isa_docs`: 현재 checkout에서 비어 있음.
