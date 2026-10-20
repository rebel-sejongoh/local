// sqrt DNC 0 disassembly: mcc build examples/kpl/sqrt.py with R=2048 K=64 (16 DNCs, 128 rows per DNC = 2 passes x 64 lanes)
// codesigner dev c1ba98778; dnc_binutils.dnc_dec.disasm, unedited

.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x2080 0x80
// num_insts = 12
MVLOOPCNT count=2
  MVLOOPCNT count=8
    MVLOOPCNT count=8
      STU src1=LRF1, src=FIFO_VU {be=1}
    SYNC typ1_imm=9 {be=1}
  IMMCOPY dst=LRF0, typ1a_imm=0x1040
  SYNC typ1_imm=0xa
  NOP {be=1}
RETURN
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0

.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x0 0x80
// num_insts = 12
MVLOOPCNT count=2
  MVLOOPCNT count=8
    SYNC typ1_imm=6
    MVLOOPCNT count=8
      LDU dst=VU, src1=LRF1 {be=1}
    NOP {be=1}
  IMMCOPY dst=LRF0
  SYNC typ1_imm=5
  NOP {be=1}
RETURN
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0

.text_vu
.target 0x82
.place col=4 line=0
.spr 0xff11ff
// num_insts = 28
IMMCOPY dst=LRF0, typ1_imm=0x3e00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF1 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF2, typ1_imm=0x3c00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF3, typ1_imm=0x3f00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF4, typ1_imm=0x3c80 {replica=1, slice_en=0xff}
MVLOOPCNT count=2
  MVLOOPCNT count=64
    FMA dst=LRF5, src0=FIFO_SPLU, src1=LRF0, src2=LRF1 {slice_en=0xff}
    EE dst=LRF6, src0=LRF5, src2=CONST0 {slice_en=0xff}
    SHR dst=LRF6, src0=LRF6, src1=FIFO_XVU, src2=CONST0 {slice_en=0xff}
    IME dst=LRF8, src0=LRF6, src1=FIFO_TU, src2=LRF4 {slice_en=0xff}
    FMA dst=LRF7, src0=LRF5, src1=LRF2, src2=LRF1 {slice_en=0xff}
    FMA dst=LRF9, src0=LRF8, src1=LRF8, src2=LRF1 {slice_en=0xff}
    FNMS dst=LRF10, src0=LRF7, src1=LRF9, src2=LRF3 {slice_en=0xff}
    FMA dst=LRF8, src0=LRF8, src1=LRF10, src2=LRF1 {slice_en=0xff}
    FMA dst=LRF9, src0=LRF8, src1=LRF8, src2=LRF1 {slice_en=0xff}
    FNMS dst=LRF10, src0=LRF7, src1=LRF9, src2=LRF3 {slice_en=0xff}
    FMA dst=LRF8, src0=LRF8, src1=LRF10, src2=LRF1 {slice_en=0xff}
    FMA dst=LRF9, src0=LRF8, src1=LRF8, src2=LRF1 {slice_en=0xff}
    FNMS dst=LRF10, src0=LRF7, src1=LRF9, src2=LRF3 {slice_en=0xff}
    FMA dst=LRF8, src0=LRF8, src1=LRF10, src2=LRF1 {slice_en=0xff}
    FMA dst=LRF9, src0=LRF8, src1=LRF8, src2=LRF1 {slice_en=0xff}
    FNMS dst=LRF10, src0=LRF7, src1=LRF9, src2=LRF3 {slice_en=0xff}
    FMA dst=LRF8, src0=LRF8, src1=LRF10, src2=LRF1 {slice_en=0xff}
    FMA dst=LRF11, src0=LRF5, src1=LRF8, src2=LRF1 {slice_en=0xff}
    FMA sp_tgt=RESULT, src0=LRF11, src1=LRF0, src2=LRF1 {slice_en=0xff, be=1}
  NOP {be=1}
RETURN

.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0
.lrf 0x818000000000000420000
// num_insts = 8
MVLOOPCNT count=2
  MVLOOPCNT count=8
    SYNC typ1ac_imm=0x22
    STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=8, be=1}
  SXRIMM
  SYNC typ1ac_imm=0x21
  NOP {be=1}
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0
.lrf 0x810000000000000010000
// num_insts = 8
MVLOOPCNT count=2
  MVLOOPCNT count=8
    LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=8}
    SYNC typ1ac_imm=0x11 {be=1}
  SXRIMM
  SYNC typ1ac_imm=0x12
  NOP {be=1}
RETURN

