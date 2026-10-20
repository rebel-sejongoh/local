# DNC assembler core: plan and progress

Started 2026-10-17. Update the "Resume here" section after every stage.

## Resume here

- Worktree: `/home/sejongoh/workspaces/codesigner-binutils`, a git worktree of the main checkout
  `/home/sejongoh/workspaces/codesigner` (shared `.git`). Run commands inside the worktree.
- Branch: `dnc-asm-core`, from `origin/dev` at `dd7da5127`, rebuilt as 5 commits and force-pushed; head `5b9c27f98` (2026-10-19).
  Backups of the old history: local branches `dnc-asm-core-before-p8` (e6252ad97), `dnc-asm-core-new`, `dnc-asm-core-final`.
- Draft PR: https://github.com/rebellions-sw/codesigner/pull/2495, title set by the user
  ("refactor(dnc_binutils): restructuring internal framework"), labeled `cd-review: full`.
  The user edits the PR body on the web; fetch it (`gh pr view 2495 --json body`) before rewriting it.
- cd-review scratch files (contract, record of rounds 1-8, PR body drafts) are in the session scratchpad
  `.../scratchpad/cdreview/`; the record lists every finding kept and why.
- Uncommitted: `Instruction` docstring says "free top-level fields" again (the user agreed); ship it with the next change.
- Submodule `spec_source_inventory/dnc_isa_docs` is initialized at `2308c6357` in this worktree.
- Stages: P0-P6 and P8 done and in the PR. Next is P7. P8 replaced `_Slot` with `OperandInfo`/`AttrInfo`;
  `by_subfield` items expand statically at load (one info per subfield), SENDJCR has one `InstrDef` per `core_id`.
- Not done: the PR "Risk" review comment for kept findings (needs the user's go-ahead), VU/XVU RETURN word (open decision 1).

### Done since the first draft PR (2026-10-18/19)

- Operands vs attributes (user rule): operands are `src*`/`*_tgt` fields, other registers or units a value is
  read from or sent to, and `immediate` used as a value; the VU/XVU second opcode (SHR's shift amount included),
  `shamt`, `offset_imm`, modes, sync direction/masks are attributes. SPLU LD with consumer SELF and load_type 0
  writes `jcr_tgt=JCRn` (a subfield-table alias of `rotate`); ABSU STI `src2` is an LRF register.
- `all_of(Eq, ...)` constraints with a disjointness proof (`_excludes`); `F.x == v` replaced by `Eq("x", v)`.
- Renames: `UnitIsa` -> `UnitInstrEncodings`, `fixed`/`free` -> `mnemonic_fields`/`free_fields`,
  `path` -> `name`, `_decoder` -> `_mnemonic_table` + `_decode_mnemonic`.
- Fixes: `microcode_image.read` accepts a program whose last flit is zero; `dnc_asm.parse` reports bad `.target`
  as `AsmError`; `LOOP_NESTING` hook resolved per revision; required second opcode, `rsm_opcode`, `shamt`.

### Last verification (2026-10-19, head e6252ad97)

| Scope | Command | Result |
|---|---|---|
| dnc_binutils | `uv run pytest -q tests` | 4944 passed |
| mcc | `uv run pytest -q tests` | 1119 passed, 2 skipped |
| repo root | `moon run ':static-check-*' --affected` | passed |
| Random words | scratchpad `fuzz.py` (about 830k decodable words, all EVT1 units) | 0 mismatches |
| mcc perf images | scratchpad `images.py` (legacy assemble, new disassemble + assemble) | 95 identical, 353 RETURN word only, 0 other |
| Fixture images | `tests/test_core_asm.py` | 73 identical, 18 RETURN word only |

## Goal

One definition per instruction drives encoding, decoding, assembly syntax, printing and the grammar document.
One assembly syntax only: no `.raw`, no `fill=`, no `OPC_0x… <unknown-opc>`.
A word the ISA cannot describe is an error in the disassembler.

The current top-level modules stay for mcc, primitives, kcc and dnc_spec.
mcc will be refactored onto the new code later; the old modules are deleted then.

## Why

- `isa_tables.py` is a PrecSim snapshot whose fields are the union over a unit, not per instruction.
  Its names (`typ1ac_imm`) are not the ISA's (`immediate`, `dir`, `lsync_mask`).
- Typed-operand rules are spread over parsing, printing and test helpers. JCMP alone is handled in four places.
- Several syntaxes coexist: plain, `.raw`, `fill`, unknown opcodes, and TU forms with and without `.arch`.

## Terms

| Term | Meaning |
|---|---|
| ISA document | `http://192.168.49.21:8080/isa_documentations/`, built from `dnc_isa_docs/src/data.py` (bit tables) and `src/docs/*.md` (prose) |
| instruction encoding | One instruction of one unit and revision: its fields, generated from `data.py` |
| field | A named bit range of an instruction word. It may have a value the mnemonic fixes (opcode, mode), and parts |
| subfield | A field inside a field, such as `dir.put` or `unroll_control.degree` |
| asm syntax | How one instruction is written for the field values its constraints admit (`AsmSyntax`) |
| `Instruction` | An instruction encoding plus the integer values of its free fields |
| td | Target description: the files that describe instructions and their writing, prefixed `td_` |
| microcode image | The whole `init.bin`: lines of 8 columns of 16-byte flits |
| flit | One 16-byte cell of the microcode image |
| unit program | One unit's header, SPR, LCCR, LRF and instruction flits, consecutive in one column. Formerly "block" |
| segment | `.text_<unit>` in assembly; it describes one unit program |

Do not use "codec", "form" or "section".

## Design

### Layout

```
PrimitiveAuthor/dnc_binutils/
  scripts/
    gen_instr_encoding.py      data.py -> core/isa/rebel_evt{0,1}/td_instr_encoding.json
    isa_doc_site_diff.py       generated encoding vs every published REBEL page
  src/dnc_binutils/
    (current top-level modules, unchanged; legacy, used by mcc and others)
    core/
      microcode_image.py       microcode image format (tables in its docstring), UnitProgram, read, write
      isa/
        td_asm_types.py        Reg, Enum, Imm, Label, Either, LrfGroup …: integer <-> token, with format/parse hooks
        td_asm_syntax.py       AsmSyntax, Opd, Attr, constraints (F), check
        encoding.py            Field, InstrEncoding, UnitIsa: reads td_instr_encoding.json, applies errata
        instruction.py         Instruction: to_word/from_word, to_asm/from_asm, decode tree, BNF
        rebel_evt1/
          td_instr_encoding.json    generated; never edited
          td_nclu_asm.py … td_tu_asm.py    one file per unit, written by hand
    tools/
      dnc_asm.py dnc_disasm.py assembly_reference.py    new tools on core only (from P3)
      init_txt.py                                        image text form, shared
      legacy/                                            the current tools
```

- `td_` files describe instructions and their writing. They hold data, shared vocabulary and narrow hooks:
  a type's `format`/`parse` of one value, and constraint functions over field values.
  Statement parsing, syntax selection, word building, the decode tree and image layout are code outside `td_`.
- `core/isa` and `core/microcode_image.py` do not import each other; the image treats instruction slots as integers.
  The tools combine them. `core` imports nothing from the legacy modules, except tests that compare the two.

### Instruction encoding (generated)

`gen_instr_encoding.py` resolves `data.py`'s registrations into hierarchical fields:
`data.py` constants become fields with a fixed `value`, subfields become `parts`, and `addfields` tables
selected by another field's value become `parts_by`.

```python
@dataclass(frozen=True)
class Field:
    name: str
    hi: int
    lo: int                                # bit positions in the word, as the ISA document numbers them
    value: int | None = None               # fixed by the mnemonic: opcode, JSHR's mode=1
    parts: tuple[Field, ...] = ()
    parts_by: PartsBy | None = None        # SENDJCR consumer_mask's parts per core_id

@dataclass(frozen=True)
class InstrEncoding:
    unit: str
    mnemonic: str
    fields: tuple[Field, ...]

@dataclass(frozen=True)
class UnitIsa:
    name: str
    width: int                             # 32; VU/XVU 51
    instrs: Mapping[str, InstrEncoding]
```

Bits outside every field are reserved and must be zero. Deliberate departures from the ISA document live in
`encoding.py`'s errata, each with its issue number.

### Asm syntax (written by hand)

```python
# core/isa/rebel_evt1/td_nclu_asm.py
SYNTAX = [
    AsmSyntax("CXRREGCOPY", constraints=[F.isbr == 0],
              operands=[Opd("src0", Reg("CAR")), Opd("src1", Reg("CAR"))], attrs=[BE]),
    AsmSyntax("CXRREGCOPY", constraints=[F.isbr == 1],
              operands=[Opd("src0", Reg("CBR")), Opd("src1", Reg("CBR"))], attrs=[BE]),
    AsmSyntax("JCMP", constraints=[F.s0jcr == 1, F.is_imm == 0],
              operands=[Opd("pc_tgt", Label()), Opd("src0", Reg("JCR")), Opd("src1", Reg("JCR"))],
              attrs=[Attr("cmp_mode", CMP_MODE, default="ALWAYS"), BE]),
    AsmSyntax("SYNC", operands=[Opd("dir"), Opd("lsync_mask")], attrs=[BE]),
]
```

- An `AsmSyntax` applies to exactly the field values that satisfy all its constraints.
  `F.field == value` constraints also build the decode tree's OR nodes; named functions (TU `computes`) are evaluated at the leaf.
  Syntaxes of one mnemonic must not overlap, and must be distinguishable from their text.
- Operands and attributes name ISA fields and parts; there are no bit numbers here.
  Print order is the order written. `Opd` goes outside braces, `Attr` inside.
- A field used only in constraints (`isbr`) is not written; the chosen syntax implies it.
- Every field without a fixed value is an operand, an attribute or constrained in each syntax; a test checks this.
- Custom code lives only in types (`format`/`parse` pairs) and constraint functions. Nothing bypasses a syntax.

### Instruction

```python
@dataclass(frozen=True)
class Instruction:
    encoding: InstrEncoding
    fields: Mapping[str, int]       # free top-level fields

    def to_word(self) -> int: ...
    @classmethod
    def from_word(cls, isa: UnitIsa, word: int) -> Instruction: ...
    def to_asm(self) -> str: ...
    @classmethod
    def from_asm(cls, isa: UnitIsa, line: str) -> Instruction: ...
```

- `to_asm` selects the one syntax whose constraints hold, reads each operand's field or part,
  and lets its type format the value (`Reg("CBR")`: 5 -> `CBR5`).
- `from_asm` splits the line into the mnemonic and `key=value` items, finds the syntax whose types parse
  them and whose constraints hold, and fills the constrained fields.
- A `Label` operand may hold a symbol until the tool lays out the segment.

### Syntax

`MNEMONIC operand, operand {attribute, attribute}` with `key=value` items and ISA field names.
A field with parts is written by part: `field.part=value`.

```asm
CXRREGCOPY src0=CBR5, src1=CBR3
SYNC dir.put=1, dir.get=1, lsync_mask.ncsu=1 {be=1}
JCMP pc_tgt=@done, src0=JCR0, src1=JCR1 {cmp_mode=LT}
FMA lrf_tgt=LRF8, east_tgt=src2, src0=LRF[0:3], src1=#0, src2=FIFO_WEST {run_mode=2, unroll_control.degree=4, unroll_control.lrf_tgt=1}
SENDJCR consumer_mask.nclu=1, consumer_mask.ncsu=1 {core_id=nclsu, strb=0xf, offset_imm=0}
```

- The statement parser is small and hand-written; no Lark.
- The grammar document's per-instruction BNF is generated from the asm syntax.
- Tests generate values from each type's `examples()` and round-trip them; no grammar-based fuzzing.

### Microcode image

`core/microcode_image.py` states the format as constants with tables in its docstring:
header fields, `lrf_idx`, `target_unit` bits, and each unit's column and instruction slots.
A unit program is header, SPR, LCCR × `lccr_num`, LRF × `lrf_num`, instruction × `ibuff_num`.
Unit limits that are not format (instruction buffer depth, the SPR RUN bit) are not checked there.

## P8: MC-like design (agreed 2026-10-19)

Make the core read like a simplified LLVM MC layer, keeping our richer instruction definitions
(`Either`, constraints, the disjointness proof).

| LLVM | P8 | Now |
|---|---|---|
| TableGen `def ADDri : Instruction` | `InstrDef` (td, hand-written) | `AsmSyntax` |
| `Inst{...}` bit layout | `InstrEncoding` (generated JSON) | same |
| `MCInstrDesc` | `InstrDesc`: `InstrDef` + `InstrEncoding` + `OperandInfo`s + `AttrInfo`s, built and checked at load | `syntax_for` + `_check` |
| `MCOperandInfo` | `OperandInfo(name, field, type, default)`, `AttrInfo(name, field, type, default=0)` | `_Slot` |
| operand type, register class | `FieldType` (`Imm`, `Enum`, `Reg`, `Either`, `Label`, `RegGroup`); `OperandType = FieldType`, `AttrType = Imm \| Enum` | `AsmType` |
| `MCInst` | `Instruction(desc, operand_values, attr_values)`, tuples in `desc` order; `Instruction.build(desc, **values)`, `inst["name"]` | `Instruction(encoding, fields)` |
| `MCCodeEmitter` / `MCDisassembler` | `to_word` / `from_word` (decode mnemonic, pick the `InstrDesc` whose constraints hold) | encoding only |
| `MCInstPrinter` / `AsmParser` | `to_asm` / `from_asm` (no syntax search: the variant is known) | search per call |
| object writer, ELF | `microcode_image` | same |

Rules:
- `InstrDef` names fields only (no bit positions); `InstrDesc` resolves them once per revision and unit.
- One value per item: `OperandInfo`/`AttrInfo` hold no value; `Instruction` holds the values at the same index.
- No subfield expansion: drop `Subfields`/`BY_SUBFIELD`, `_leaves`, `expanded`, the word argument of `_slots`
  and the second fill in `_parse`. A subfield is written as its own item (`Attr("dir.get"), Attr("dir.put")`);
  a td helper may list a field's subfields. Subfields remain only as named bit ranges in the encoding.
- A field whose subfield table depends on other bits gets one `InstrDef` per selecting value
  (`Eq("core_id", v)` for NCSU SENDJCR, as SPLU LD already does); the loader checks that the `Eq`s select the table.
- The loader rejects two items of one `InstrDef` whose bits overlap.
- `from_word`: bits outside mnemonic fields, `Eq`s and items must be zero (reserved and unnamed bits in one check).
- Constraint-fixed fields and mnemonic fields carry no value in `Instruction`.

Files: `td_asm_syntax.py` -> `td_instr_def.py`; `td_asm_types.py` -> `td_field_types.py`;
`td_asm_common.py` -> `td_common_instrs.py`; `rebel_evt1/td_<unit>_asm.py` -> `td_<unit>_instrs.py`
(`SYNTAX` -> `INSTR_DEFS`); new `instr_desc.py` (`InstrDesc`, `OperandInfo`, `AttrInfo`, loading and checks);
`instruction.py` keeps `Instruction` and the word/asm conversions. `syntax_for` -> `instr_descs_for`.
AGENTS.md "Representations" changes: word conversion now uses the `InstrDesc`, since encoding and asm syntax
are defined together, as in TableGen.

Steps:
1. Renames and file moves (`AsmSyntax` -> `InstrDef`, `AsmType` -> `FieldType`, files above); behavior unchanged.
2. Subfield items: rewrite `BY_SUBFIELD` uses as listed items; split SENDJCR per `core_id`; drop `Subfields`.
3. `InstrDesc` with `OperandInfo`/`AttrInfo`; checks moved from `_check`; overlap check.
4. `Instruction(desc, operand_values, attr_values)` and the four conversions; `build` and `[]`.
5. AGENTS.md and docstrings; `values` and `Context` use item names.
Verification at each step: full tests, `fuzz.py`, `images.py`, fixture images byte-identical.
Open: whether P8 goes into PR #2495 or a follow-up PR.

## Verification

1. Generated encoding against every published REBEL page (`isa_doc_site_diff.py`, manual).
2. Encoding against legacy `isa_tables`: opcodes agree under pinned name differences.
3. Asm syntax against encoding: names exist, every free field is covered, syntaxes do not overlap.
4. Bytes: every frozen program image and every mcc perf image disassembles and reassembles to the same bytes with the new tools.
5. Words: the new encoder agrees with the legacy encoder on every instruction in those images.
6. Encoding patterns are regenerated from the encoding; reserved bits, unknown opcodes and undefined codes become rejection cases.
7. Round trip: values from each syntax's types print, parse, encode and decode back to themselves.

## Stages

| Stage | Content | Status |
|---|---|---|
| P0 | Move `tools/{dnc_asm,dnc_disasm,assembly_reference}.py` to `tools/legacy/`; update imports; CLI names keep pointing at legacy | done |
| P1 | `gen_instr_encoding.py` writes hierarchical fields to `core/isa/rebel_evt{0,1}/td_instr_encoding.json`; `encoding.py` reads it; comparison with the published site and with legacy opcodes | done |
| P2 | `core/microcode_image.py`: format tables, `UnitProgram`, `read`, `write`; byte-identical with legacy on all frozen images | done |
| P3 | `td_asm_types.py`, `td_asm_syntax.py`, `instruction.py`, NCLU/NCSU asm syntax, new tools | done |
| P4 | SP/AB asm syntax | done |
| P5 | VU/XVU asm syntax | done, but the mcc RETURN word |
| P6 | TU asm syntax (`run_mode`, `LRF[a:b]`, routing, #2182) | done |
| P7 | Switch `dnc-asm`/`dnc-disasm` to the new tools; regenerate the grammar document and `.s` fixtures | after P8 |
| P8 | MC-like design: `InstrDef`/`InstrDesc`/`Instruction`, static subfield expansion (section above) | done, in PR #2495 (reviewed rounds 9-10) |

## Findings so far

- P5: VU/XVU source selectors follow the ISA src* tables; XVU's depend on `mode` (16- and 32-bit tables), so XVU
  instructions with a free mode have one syntax per mode, with `mode` written in the 32-bit one.
  VU IMMCOPY with `const_wr=1` writes `lrf_tgt=CONSTn` when the valid bit is clear.
- P4: mcc writes `src0=15` in a discarding SPSU LRFCOPY (`consume=1`), whose `src0` the ISA leaves unused;
  `consume` is therefore an attribute and `src0` is always written.
- P3: in the encoding fixtures, the new decoder rejects 1,848 NC words with unknown opcodes, words setting
  reserved or unnamed bits, and MVLOOPCNT/JCMP field combinations no syntax writes. No real program uses them.
- P2: `core/microcode_image.py` reads and writes all 241 frozen fixture images and all 448 mcc perf images byte for byte,
  and its programs agree with the legacy decoder. No image uses a header bit outside the format's fields.
  `target_unit` is the unit's bit plus NCore select (0x80 NCore 0, 0x100 NCore 1).
- The published ISA site shows `master:2308c63`, the submodule's commit, yet differs from it in one place:
  NCSU SXRIMM EVT1 immediate is 24:10 on the page and 25:10 in `data.py`.
  Running the site generator's own query on that commit gives 25:10, so the site was likely built from uncommitted edits.
- `data.py` `addfields` are tables selected by another field's value: SENDJCR consumer bits per `core_id`,
  SPLU LD names per load type.
- Legacy opcodes agree with the document for every REBEL instruction. Names differ:
  AB `LDST*` (document `LD*`/`ST*`), NC `CARREGCOPY`/`SARREGCOPY`/`MODCARREG`/`MODSARREG`/`LOADJCR`,
  VU `F*HPBF` (document `F*BFHP`), XVU `COPY_LFSR`/`LOAD_LFSR`.
- Legacy VU/XVU fields extend past the document's 51-bit word in almost every instruction; P5 must explain this.
- Legacy fields wider than the ISA field or covering unassigned bits: NCLU/NCSU (ADD/SUB)SXRIMM, SYNC, SESYNC,
  LDC/LDCU `src2`, STC/STCU `src0`, JIMMCOPY `src0`, JSWAP bit 25, RETURN `be`. Only synthetic encoding fixtures use them.
- NCSU STC/STCU `qos` (30:29) is in the ISA but has no legacy field.
- mcc emits VU/XVU `RETURN {be=1, fill=0x3700000000}` (242 lines in fixtures). The ISA RETURN has no fields.
- #2182: TU FMA `src0` is the first register of the group, not a group index.

## Decisions

1. Mnemonics follow the ISA (`CXRREGCOPY`, `SXRREGCOPY`, `MODCXRREG`, `MODSXRREG`, `LDJCR`).
2. Operands are printed even when 0. Attributes and one-bit subfields at their default are omitted.
3. NCSU SXRIMM immediate: 16 bits (25:10), as `data.py`, EVT0 and NCSU ADDSXRIMM/SUBSXRIMM give, and as the
   toolchain's 16-bit SBR needs. The published EVT1 page shows 24:10; mcc's largest NCSU SXRIMM value is 0x4db.
   Recorded in a comment at the NCSU SXRIMM asm syntax.
4. A name with exactly its field's bits is an alias (`2nd opc`, `sar_idx`); assembly uses the field's name.
   Subfield names map mechanically: characters an identifier cannot hold become `_`, and a name after `.`
   may start with a digit (`consumer_mask.ncsu_vu`, `rotate.2B_splat`).
5. The term is "subfield", as the ISA document has it; there is no separate "part".
6. SENDJCR: `consumer_mask` is an operand written by subfield; `core_id` is an attribute with names
   (`nclsu`, `ncore0`, `ncore1`, `all`) and no default; it selects `consumer_mask`'s subfield names,
   and bits it leaves unnamed must be zero. P8 replaces this with one `InstrDef` per `core_id`.
7. Writing by subfield is chosen per item with the `Subfields` type (`Opd("dir", BY_SUBFIELD)`), not by
   whether a field has subfields: the ISA document also lists other views of a field's bits as subfields
   (JCMP's `src1` inside `immediate`). P8 drops `Subfields`: a subfield is written as its own item.

8. Asm syntax shared by units whose fields and Operation agree (J*, GETJCR, MVLOOPCNT, NOP, RETURN) is built by
   functions in `td_asm_common.py`; each unit file still lists every instruction by calling them.

9. TU FMA: `src0` is `RegGroup`, its size from `run_mode` per opcode; `run_mode` takes only the opcode's modes.
   A forwarding instruction (no LRF write, no result south) has its own syntax, with `run_mode` fixed to the
   opcode's one-register mode and `lrf_tgt` to NONE. `dot_len` is not used; `run_mode` is the ISA name.

## Open decisions

1. VU/XVU RETURN `0x3f0000003f` (574 words in fixture and perf images): bits 37:32 repeat the RETURN opcode.
   The ISA RETURN has no fields, and rebel_compute_lib2's `VUManager::RETURN` emits `vu_type1c(xvu_RETURN, 0, 0, 0, 0)`;
   where the high copy comes from is not found yet. mcc copies it (`_RET_FILL` with `be=1`).
   The new disassembler rejects the word; `tests/test_core_asm.py` pins it and replaces it with `0x3f` to check the rest.
   Options: drop it in mcc, or ask the ISA owner whether it means anything.
2. P7: switching `dnc-asm`/`dnc-disasm` to the new tools changes the syntax every `.s` file is written in.
   mcc's perf `.s` files and the fixture `.s` files are legacy syntax and are read by legacy tests and mcc's perf
   lane; they need regenerating, or the legacy tools stay under other names until mcc moves.
3. P7: the grammar document. `assembly-grammar.md` is legacy and its tests regenerate it from legacy tables;
   the new one is generated from the asm syntax (not written yet).
4. Revisions: REBEL evt1 asm syntax first, evt0 later; ATOM out of scope. `.arch` defaults to `rebel.evt1`.
