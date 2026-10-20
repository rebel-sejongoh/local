// sqrt 예제 DNC 0 디스어셈블 (mcc build examples/kpl/sqrt.py, R=256 K=64, DNC당 64행×64)
// dnc-disasm --arch rebel.evt0 출력에 사람이 주석을 단 것. dnc-asm으로 다시 assemble하면 같은 binary가 나온다.
// 해설: ../../docs/dnc-isa-sqrt.md
// 흐름: SHM[0x1000..] -NCLU LDMU×2-> SP[1..64] -SYNC-> SPLU LDU×64 -> VU×64 -> SPSU STU×64 -> SP[0x42..] -SYNC-> NCSU STMU×2 -> SHM[0x1100..]
// 문법: assembly-grammar.md (PrimitiveAuthor/dnc_binutils). MVLOOPCNT 아래 들여쓴 줄이 loop body이고, be=1이 body의 끝이다.

.arch rebel.evt0

// SPSU (Scratchpad store unit): SP에 결과 저장, VU FIFO → SP[0x42..], 끝나면 NCSU에 signal
// LRF0 = 쓰기 포인터 byte 0x2080 (접근 전 증가 → 첫 쓰기 0x2100 = SP line 0x42), LRF1 = stride 0x80 (한 줄)
.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x2080 0x80
// 64번 반복 (한 번에 한 줄)
MVLOOPCNT count=64
  // dequeue(VU FIFO) → SP[LRF0 += LRF1]; be=1 loop 끝
  STU src1=LRF1, src=FIFO_VU {be=1}
// SYNC 9 = SEND|NCSU: spsu0_ncsu put (저장 끝)
SYNC typ1_imm=9
RETURN

// SPLU (Scratchpad load unit): SP → VU FIFO 공급, NCLU 로드가 끝날 때까지 대기
// LRF0 = 읽기 포인터 byte 0 (접근 전 증가 → 첫 읽기 0x80 = SP line 1), LRF1 = stride 0x80
.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x0 0x80
// SYNC 6 = RECV|NCLU: nclu_splu0 get (로드 끝 대기)
SYNC typ1_imm=6
// 64번 반복
MVLOOPCNT count=64
  // LRF0 += LRF1; push(VU FIFO, SP[LRF0]); be=1 loop 끝
  LDU dst=VU, src1=LRF1 {be=1}
RETURN

// VU: √x = x·(1/√x). seed 0.625·2^-⌊e/2⌋ + Newton 4회. 64 lane, 한 줄씩
.text_vu
.target 0x82
.place col=4 line=0
.spr 0xff11ff
// 상수 broadcast (64 lane): LRF0 = 1.0, LRF1 = 0, LRF2 = 0.5, LRF3 = 1.5, LRF4 = 0.625 (seed 보정)
IMMCOPY dst=LRF0, typ1_imm=0x3e00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF1 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF2, typ1_imm=0x3c00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF3, typ1_imm=0x3f00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF4, typ1_imm=0x3c80 {replica=1, slice_en=0xff}
// 64번 반복 (SPLU가 보내는 줄마다)
MVLOOPCNT count=64
  // x = splu·1.0 + 0 → LRF5 (FIFO pop은 한 번뿐이라 레지스터에 받아 둠)
  FMA dst=LRF5, src0=FIFO_SPLU, src1=LRF0, src2=LRF1 {slice_en=0xff}
  // e = exponent(x) → LRF6 (src1=0 모드)  ⚠ bias 뺀 정수 지수로 가정
  EE dst=LRF6, src0=LRF5, src2=CONST0 {slice_en=0xff}
  // e' = e >> 1 = ⌊e/2⌋ → LRF6
  // ⚠ 실제 의미는 shift 양 src1=1인데, disassembler가 FIFO_XVU(code 1)로 출력한다.
  SHR dst=LRF6, src0=LRF6, src1=FIFO_XVU, src2=CONST0 {slice_en=0xff}
  // y0 = 0.625·2^-e' → LRF8 (IME mode 2: src2·2^-src0)
  // ⚠ 실제 의미는 mode src1=2인데, disassembler가 FIFO_TU(code 2)로 출력한다.
  IME dst=LRF8, src0=LRF6, src1=FIFO_TU, src2=LRF4 {slice_en=0xff}
  // xh = x·0.5 → LRF7
  FMA dst=LRF7, src0=LRF5, src1=LRF2, src2=LRF1 {slice_en=0xff}
  // Newton 1: t = y·y → LRF9, u = 1.5 − xh·t → LRF10, y = y·u → LRF8
  FMA dst=LRF9, src0=LRF8, src1=LRF8, src2=LRF1 {slice_en=0xff}
  FNMS dst=LRF10, src0=LRF7, src1=LRF9, src2=LRF3 {slice_en=0xff}
  FMA dst=LRF8, src0=LRF8, src1=LRF10, src2=LRF1 {slice_en=0xff}
  // Newton 2
  FMA dst=LRF9, src0=LRF8, src1=LRF8, src2=LRF1 {slice_en=0xff}
  FNMS dst=LRF10, src0=LRF7, src1=LRF9, src2=LRF3 {slice_en=0xff}
  FMA dst=LRF8, src0=LRF8, src1=LRF10, src2=LRF1 {slice_en=0xff}
  // Newton 3
  FMA dst=LRF9, src0=LRF8, src1=LRF8, src2=LRF1 {slice_en=0xff}
  FNMS dst=LRF10, src0=LRF7, src1=LRF9, src2=LRF3 {slice_en=0xff}
  FMA dst=LRF8, src0=LRF8, src1=LRF10, src2=LRF1 {slice_en=0xff}
  // Newton 4: y ≈ 1/√x
  FMA dst=LRF9, src0=LRF8, src1=LRF8, src2=LRF1 {slice_en=0xff}
  FNMS dst=LRF10, src0=LRF7, src1=LRF9, src2=LRF3 {slice_en=0xff}
  FMA dst=LRF8, src0=LRF8, src1=LRF10, src2=LRF1 {slice_en=0xff}
  // r = x·y ≈ √x → LRF11
  FMA dst=LRF11, src0=LRF5, src1=LRF8, src2=LRF1 {slice_en=0xff}
  // r·1.0 + 0 → SPSU FIFO, LRF 쓰기 없음; be=1 loop 끝
  FMA sp_tgt=RESULT, src0=LRF11, src1=LRF0, src2=LRF1 {slice_en=0xff, be=1}
RETURN

// NCSU: NC store unit, SP → SHM 저장 (uDMA)
// descriptor: CBR = 0x8_1100 → SHM line 0x1100, SBR = 0x42 → SP line 0x42 (LRF0: SAR=0, SBR=0x42, CAR=0, CBR=0x8_1100)
.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0
.lrf 0x811000000000000420000
// SYNC 0x22 = RECV|SPSU0: spsu0_ncsu get (SPSU 저장 끝 대기)
SYNC typ1ac_imm=0x22
// 2번 반복
MVLOOPCNT count=2
  // SHM[CAR+CBR+j] := SP[SAR+SBR+j], j<32 (burst=0 → 32줄); descriptor가 32줄 전진 → 총 64줄; be=1 loop 끝
  // CBR의 [83:80]=0x8은 SHM 영역 표시
  STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {be=1}
RETURN

// NCLU: SHM → SP 로드 (uDMA)
// descriptor: CBR = 0x8_1000 → SHM line 0x1000, SBR = 0x1 → SP line 1
.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0
.lrf 0x810000000000000010000
// 2번 반복
MVLOOPCNT count=2
  // SP[SAR+SBR+j] := SHM[CAR+CBR+j], j<32; descriptor += 32줄 → 총 64줄; be=1 loop 끝
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {be=1}
// SYNC 0x11 = SEND|SPLU0: nclu_splu0 put (로드 끝)
SYNC typ1ac_imm=0x11
RETURN
