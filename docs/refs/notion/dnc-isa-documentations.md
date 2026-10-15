# [Notion] DNC ISA Documentations (요약 발췌)

- 원문: https://app.notion.com/p/113494d2a63d8039b731d61e1682071f
- 위치: Engineering Wiki / DESIGN Group / LOGIC RBLN IP Design / DNC uArchitecture / Neural Core / NCORE_v1 / NCORE Verification
- 마지막 수정: 2025-01-08. 2026-09-30에 가져옴.

## 핵심
- DNC ISA의 공식 문서는 원래 LaTeX(Overleaf) PDF였고 김진석 님이 관리했다.
  - 첨부: **Rebellions_ISA_Reference_Manual-2.pdf** (2024-08-04 export). 명령 비트 필드와 동작 설명이 들어 있다.
  - 이 PDF는 Notion 페이지에서 직접 받아야 한다(이 세션에서는 받을 수 없었음).
- 그 뒤 코드 기반 문서로 옮기는 중이었다.
  - `data.py`: TinyDB(`db.json`)에 명령을 등록한다. 유닛, opcode, hex, 호환 디바이스/리비전(`ATOM:evt0/evt1/mass`, `REBEL:evt0`), bitfield, subfield, group.
  - `main.py`: DB에서 markdown 페이지를 생성한다(`docs/docs/`).
  - mkdocs로 HTML 사이트를 만든다(`make serve`, `make export_docs`).
  - 설명 markdown은 `src/docs/<unit>__<op>.md` → `<unit>.md` → `common.md` 순서로 찾는다.
- 웹 버전: `192.168.49.21/isa_documentations/index.html` (사내망. "[REBEL] DNC feature update" 페이지에 나옴)
- 이 도구의 소스는 codesigner 저장소의 `spec_source_inventory/dnc_isa_docs`로 참조되지만, 현재 checkout에서는 비어 있다.

## 등록 예시 (원문 그대로)
```python
db_c.register_instr("SPLU", "SYNC", "26", ["ATOM:evt0", "ATOM:evt1", "ATOM:mass", "REBEL:evt0"],
                    base=["", "NOP"], group="SPLU/SPSU:SYNC",
                    bitfields=f(lsync_mask=[17,12], dir=[11,10]),
                    subfields=f(nbr_spsu=17, self_spsu=15, nclu=12, get=11, put=10))
```

## 관련 Notion 페이지 (검색에서 나온 것)
- DNC uArchitecture: https://app.notion.com/p/cd16781650274b88b36a8f69685ad2a4
- [REBEL] DNC feature update: https://app.notion.com/p/0b06f02a3a60461aae6bd4e046ed48b0
- PMU E2 LRF bypass (EE/IME/SHR 등 E1에서 끝나는 명령 목록): https://app.notion.com/p/d5bdd5adeff44a318bccbc8010315525
- Compute units (TU, VU, XVU) — uArch spec: https://app.notion.com/p/2e9494d2a63d805784acdf15deb7a80e
- DNC Glimpse: https://app.notion.com/p/1a5494d2a63d806383a8d49097606559
- 4 · NPU Primitive & ISA — 도어벨에서 FMA까지: https://app.notion.com/p/3d9494d2a63d818f9118dd99130547b3
