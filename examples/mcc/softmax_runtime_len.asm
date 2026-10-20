// softmax with a runtime row length (tests/test_row_bands.py _softmax(runtime="position"), R=64 K=128, K on lanes), DNC 0
// codesigner dev c1ba98778; dnc_binutils.dnc_dec.disasm, unedited

.text_spsu
.target 0x140
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5
.lrf 0xc00 0x80 0x900 0x100 0xe00 0xf80
// num_insts = 16
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_3, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_3: // @0x3
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
STU src1=LRF1, src=FIFO_VU {burst=1, burst_sz=2}
SYNC typ1_imm=0x11
MVLOOPCNT src0=5, typ1_imm=9 {dynloop=1}
  STU src0=LRF2, src1=LRF3, src=FIFO_VU {interleave_sz=2, be=1}
STU src0=LRF4, src1=LRF1, src=FIFO_VU {burst=1, burst_sz=2}
SYNC typ1_imm=0x11
MVLOOPCNT src0=5, typ1_imm=0xd {dynloop=1}
  STU src0=LRF5, src1=LRF3, src=FIFO_XVU {interleave_sz=2, be=1}
SYNC typ1_imm=9
RETURN
MODLRFREG dst=LRF0

.text_spsu
.target 0xc0
.place col=2 line=12
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5
.lrf 0x300 0x80 0x0 0x100 0x500 0x680
// num_insts = 16
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_3, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_3: // @0x3
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
STU src1=LRF1, src=FIFO_VU {burst=1, burst_sz=2}
SYNC typ1_imm=0x11
MVLOOPCNT src0=5, typ1_imm=9 {dynloop=1}
  STU src0=LRF2, src1=LRF3, src=FIFO_VU {interleave_sz=2, be=1}
STU src0=LRF4, src1=LRF1, src=FIFO_VU {burst=1, burst_sz=2}
SYNC typ1_imm=0x11
MVLOOPCNT src0=5, typ1_imm=0xd {dynloop=1}
  STU src0=LRF5, src1=LRF3, src=FIFO_XVU {interleave_sz=2, be=1}
SYNC typ1_imm=9
RETURN
MODLRFREG dst=LRF0

.text_splu
.target 0x120
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9
.lrf 0x900 0x100 0xc80 0x0 0x80 0xc00 0x900 0xe80 0xe00 0x900
// num_insts = 20
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_3, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_3: // @0x3
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
SYNC typ1_imm=6
MVLOOPCNT src0=5, typ1_imm=8 {dynloop=1}
  LDU dst=VU, src1=LRF1 {interleave_sz=2, be=1}
SYNC typ1_imm=0x22
LDU dst=VU, src0=LRF5, src1=LRF4 {burst=1, burst_sz=2, ld_rot=1, ld_type=3}
MVLOOPCNT src0=5, typ1_imm=0xc {dynloop=1}
  LDU dst=VU, src0=LRF6, src1=LRF1 {interleave_sz=2, be=1}
SYNC typ1_imm=0x22
LDU dst=XVU, src0=LRF8, src1=LRF4 {burst=1, burst_sz=2, ld_rot=1, ld_type=3}
MVLOOPCNT src0=5, typ1_imm=0x10 {dynloop=1}
  LDU dst=XVU, src0=LRF9, src1=LRF1 {interleave_sz=2, be=1}
RETURN
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0

.text_splu
.target 0xa0
.place col=3 line=17
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9
.lrf 0x0 0x100 0x380 0x0 0x80 0x300 0x0 0x580 0x500 0x0
// num_insts = 20
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_3, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_3: // @0x3
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
SYNC typ1_imm=6
MVLOOPCNT src0=5, typ1_imm=8 {dynloop=1}
  LDU dst=VU, src1=LRF1 {interleave_sz=2, be=1}
SYNC typ1_imm=0x22
LDU dst=VU, src0=LRF5, src1=LRF4 {burst=1, burst_sz=2, ld_rot=1, ld_type=3}
MVLOOPCNT src0=5, typ1_imm=0xc {dynloop=1}
  LDU dst=VU, src0=LRF6, src1=LRF1 {interleave_sz=2, be=1}
SYNC typ1_imm=0x22
LDU dst=XVU, src0=LRF8, src1=LRF4 {burst=1, burst_sz=2, ld_rot=1, ld_type=3}
MVLOOPCNT src0=5, typ1_imm=0x10 {dynloop=1}
  LDU dst=XVU, src0=LRF9, src1=LRF1 {interleave_sz=2, be=1}
RETURN
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0

.text_vu
.target 0x102
.place col=4 line=0
.spr 0xff11ff
.lrf_idx 0xe
.lrf 0x4380430042804200410040003e000000
// num_insts = 72
IMMCOPY dst=LRF0, typ1_imm=0x3e00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF1 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF2, typ1_imm=0x54e3 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF3, typ1_imm=0x4000 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF4, typ1_imm=0xdbaa {replica=1, slice_en=0xff}
JADD jcr_tgt=6, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_8, src0=JCR6, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=6, typ1_imm=0x80
L_8: // @0x8
JADD jcr_tgt=6, src0=6, typ1_imm=0xffff {jcr_sel=1}
JSHR jcr_tgt=6, src0=6 {tr_left=0xa}
JADD jcr_tgt=6, src0=6, typ1_imm=1 {jcr_sel=1}
IMMCOPY dst=LRF15 {replica=1, slice_en=1}
IMMCOPY dst=LRF15, typ1_imm=0x4400 {replica=1, slice_en=2}
IMMCOPY dst=LRF15, typ1_imm=0x4600 {replica=1, slice_en=4}
IMMCOPY dst=LRF15, typ1_imm=0x4700 {replica=1, slice_en=8}
IMMCOPY dst=LRF15, typ1_imm=0x4800 {replica=1, slice_en=0x10}
IMMCOPY dst=LRF15, typ1_imm=0x4880 {replica=1, slice_en=0x20}
IMMCOPY dst=LRF15, typ1_imm=0x4900 {replica=1, slice_en=0x40}
IMMCOPY dst=LRF15, typ1_imm=0x4980 {replica=1, slice_en=0x80}
FMA dst=LRF14, src0=LRF14, src1=LRF0, src2=LRF15 {slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x16 {dynloop=1}
  FNMS dst=LRF14, src0=LRF0, src1=LRF0, src2=LRF14 {slice_en=0xff, be=1}
FCMP src0=LRF1, src1=7, src2=LRF14 {slice_en=0xff}
SELECT dst=LRF15, src0=LRF0, src2=LRF1 {slice_en=0xff}
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_1b, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_1b: // @0x1b
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
JADD jcr_tgt=6, src0=5, typ1_imm=0xffff {jcr_sel=1}
IMMCOPY dst=LRF5, typ1_imm=0xdbaa {replica=1, slice_en=0xff}
IMMCOPY dst=LRF6, typ1_imm=0xdbaa {replica=1, slice_en=0xff}
IMMCOPY dst=LRF7 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF8 {replica=1, slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x24 {dynloop=1}
  FMINMAX dst=LRF5, src0=LRF5, src2=FIFO_SPLU {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
FCMP src0=LRF15, src1=5, src2=LRF1 {slice_en=0xff}
SELECT dst=LRF14, src0=FIFO_SPLU, src2=LRF4 {slice_en=0xff}
FMINMAX dst=LRF5, src0=LRF5, src2=LRF14 {slice_en=0xff}
FCMP src0=LRF15, src1=5, src2=LRF1 {slice_en=0xff}
SELECT dst=LRF14, src0=FIFO_SPLU, src2=LRF4 {slice_en=0xff}
FMINMAX dst=LRF6, src0=LRF6, src2=LRF14 {slice_en=0xff}
FMINMAX dst=LRF5, src0=8, src2=LRF5 {uc.degree=2, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
FMINMAX dst=LRF5, src0=LRF5, src2=8 {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
FMINMAX dst=LRF5, src0=8, src2=8 {uc.degree=2, uc.lrf_dst_inc=1, slice_en=0xff}
REDUCE src0=0x15 {reduce_imm=0x2a915}
FMA sp_tgt=RESULT, src0=LRF5, src1=LRF0, src2=LRF1 {uc.degree=2, uc.src0_inc=1, slice_en=0xff}
FMA dst=LRF5, src0=FIFO_SPLU, src1=LRF0, src2=LRF1 {uc.degree=2, uc.lrf_dst_inc=1, slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x35 {dynloop=1}
  FNMS dst=LRF9, src0=LRF5, src1=LRF0, src2=FIFO_SPLU {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
  FMA dst=LRF9, src0=LRF9, src1=LRF2, src2=LRF1 {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
  ICVT out_sp=3, dst=LRF9, src0=0xf, src1=7, src2=LRF9 {uc.degree=2, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
  FMA dst=LRF7, src0=LRF9, src1=LRF0, src2=LRF7 {uc.degree=2, uc.src0_inc=1, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
FNMS dst=LRF9, src0=LRF5, src1=LRF0, src2=FIFO_SPLU {slice_en=0xff}
FMA dst=LRF9, src0=LRF9, src1=LRF2, src2=LRF1 {slice_en=0xff}
ICVT out_sp=3, dst=LRF9, src0=0xf, src1=7, src2=LRF9 {slice_en=0xff}
FCMP src0=LRF15, src1=5, src2=LRF1 {slice_en=0xff}
SELECT dst=LRF14, src0=LRF9, src2=LRF1 {slice_en=0xff}
FMA dst=LRF7, src0=LRF14, src1=LRF0, src2=LRF7 {slice_en=0xff}
FNMS dst=LRF10, src0=LRF6, src1=LRF0, src2=FIFO_SPLU {slice_en=0xff}
FMA dst=LRF10, src0=LRF10, src1=LRF2, src2=LRF1 {slice_en=0xff}
ICVT out_sp=3, dst=LRF10, src0=0xf, src1=7, src2=LRF10 {slice_en=0xff}
FCMP src0=LRF15, src1=5, src2=LRF1 {slice_en=0xff}
SELECT dst=LRF14, src0=LRF10, src2=LRF1 {slice_en=0xff}
FMA dst=LRF8, src0=LRF14, src1=LRF0, src2=LRF8 {slice_en=0xff}
FMA dst=LRF7, src0=8, src1=LRF0, src2=LRF7 {uc.degree=2, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
FMA dst=LRF7, src0=LRF7, src1=LRF0, src2=8 {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
FMA dst=LRF7, src0=8, src1=LRF0, src2=8 {uc.degree=2, uc.lrf_dst_inc=1, slice_en=0xff}
REDUCE src0=0x17 {reduce_imm=0x2e837}
FMA sp_tgt=RESULT, src0=LRF7, src1=LRF0, src2=LRF1 {uc.degree=2, uc.src0_inc=1, slice_en=0xff}
RETURN
FMUL

.text_vu
.target 0x82
.place col=4 line=39
.spr 0xff11ff
.lrf_idx 0xe
.lrf 0x4380430042804200410040003e000000
// num_insts = 72
IMMCOPY dst=LRF0, typ1_imm=0x3e00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF1 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF2, typ1_imm=0x54e3 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF3, typ1_imm=0x4000 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF4, typ1_imm=0xdbaa {replica=1, slice_en=0xff}
JADD jcr_tgt=6, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_8, src0=JCR6, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=6, typ1_imm=0x80
L_8: // @0x8
JADD jcr_tgt=6, src0=6, typ1_imm=0xffff {jcr_sel=1}
JSHR jcr_tgt=6, src0=6 {tr_left=0xa}
JADD jcr_tgt=6, src0=6, typ1_imm=1 {jcr_sel=1}
IMMCOPY dst=LRF15 {replica=1, slice_en=1}
IMMCOPY dst=LRF15, typ1_imm=0x4400 {replica=1, slice_en=2}
IMMCOPY dst=LRF15, typ1_imm=0x4600 {replica=1, slice_en=4}
IMMCOPY dst=LRF15, typ1_imm=0x4700 {replica=1, slice_en=8}
IMMCOPY dst=LRF15, typ1_imm=0x4800 {replica=1, slice_en=0x10}
IMMCOPY dst=LRF15, typ1_imm=0x4880 {replica=1, slice_en=0x20}
IMMCOPY dst=LRF15, typ1_imm=0x4900 {replica=1, slice_en=0x40}
IMMCOPY dst=LRF15, typ1_imm=0x4980 {replica=1, slice_en=0x80}
FMA dst=LRF14, src0=LRF14, src1=LRF0, src2=LRF15 {slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x16 {dynloop=1}
  FNMS dst=LRF14, src0=LRF0, src1=LRF0, src2=LRF14 {slice_en=0xff, be=1}
FCMP src0=LRF1, src1=7, src2=LRF14 {slice_en=0xff}
SELECT dst=LRF15, src0=LRF0, src2=LRF1 {slice_en=0xff}
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_1b, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_1b: // @0x1b
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
JADD jcr_tgt=6, src0=5, typ1_imm=0xffff {jcr_sel=1}
IMMCOPY dst=LRF5, typ1_imm=0xdbaa {replica=1, slice_en=0xff}
IMMCOPY dst=LRF6, typ1_imm=0xdbaa {replica=1, slice_en=0xff}
IMMCOPY dst=LRF7 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF8 {replica=1, slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x24 {dynloop=1}
  FMINMAX dst=LRF5, src0=LRF5, src2=FIFO_SPLU {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
FCMP src0=LRF15, src1=5, src2=LRF1 {slice_en=0xff}
SELECT dst=LRF14, src0=FIFO_SPLU, src2=LRF4 {slice_en=0xff}
FMINMAX dst=LRF5, src0=LRF5, src2=LRF14 {slice_en=0xff}
FCMP src0=LRF15, src1=5, src2=LRF1 {slice_en=0xff}
SELECT dst=LRF14, src0=FIFO_SPLU, src2=LRF4 {slice_en=0xff}
FMINMAX dst=LRF6, src0=LRF6, src2=LRF14 {slice_en=0xff}
FMINMAX dst=LRF5, src0=8, src2=LRF5 {uc.degree=2, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
FMINMAX dst=LRF5, src0=LRF5, src2=8 {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
FMINMAX dst=LRF5, src0=8, src2=8 {uc.degree=2, uc.lrf_dst_inc=1, slice_en=0xff}
REDUCE src0=0x15 {reduce_imm=0x2a915}
FMA sp_tgt=RESULT, src0=LRF5, src1=LRF0, src2=LRF1 {uc.degree=2, uc.src0_inc=1, slice_en=0xff}
FMA dst=LRF5, src0=FIFO_SPLU, src1=LRF0, src2=LRF1 {uc.degree=2, uc.lrf_dst_inc=1, slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x35 {dynloop=1}
  FNMS dst=LRF9, src0=LRF5, src1=LRF0, src2=FIFO_SPLU {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
  FMA dst=LRF9, src0=LRF9, src1=LRF2, src2=LRF1 {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
  ICVT out_sp=3, dst=LRF9, src0=0xf, src1=7, src2=LRF9 {uc.degree=2, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
  FMA dst=LRF7, src0=LRF9, src1=LRF0, src2=LRF7 {uc.degree=2, uc.src0_inc=1, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
FNMS dst=LRF9, src0=LRF5, src1=LRF0, src2=FIFO_SPLU {slice_en=0xff}
FMA dst=LRF9, src0=LRF9, src1=LRF2, src2=LRF1 {slice_en=0xff}
ICVT out_sp=3, dst=LRF9, src0=0xf, src1=7, src2=LRF9 {slice_en=0xff}
FCMP src0=LRF15, src1=5, src2=LRF1 {slice_en=0xff}
SELECT dst=LRF14, src0=LRF9, src2=LRF1 {slice_en=0xff}
FMA dst=LRF7, src0=LRF14, src1=LRF0, src2=LRF7 {slice_en=0xff}
FNMS dst=LRF10, src0=LRF6, src1=LRF0, src2=FIFO_SPLU {slice_en=0xff}
FMA dst=LRF10, src0=LRF10, src1=LRF2, src2=LRF1 {slice_en=0xff}
ICVT out_sp=3, dst=LRF10, src0=0xf, src1=7, src2=LRF10 {slice_en=0xff}
FCMP src0=LRF15, src1=5, src2=LRF1 {slice_en=0xff}
SELECT dst=LRF14, src0=LRF10, src2=LRF1 {slice_en=0xff}
FMA dst=LRF8, src0=LRF14, src1=LRF0, src2=LRF8 {slice_en=0xff}
FMA dst=LRF7, src0=8, src1=LRF0, src2=LRF7 {uc.degree=2, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
FMA dst=LRF7, src0=LRF7, src1=LRF0, src2=8 {uc.degree=2, uc.src0_inc=1, uc.lrf_dst_inc=1, slice_en=0xff}
FMA dst=LRF7, src0=8, src1=LRF0, src2=8 {uc.degree=2, uc.lrf_dst_inc=1, slice_en=0xff}
REDUCE src0=0x17 {reduce_imm=0x2e837}
FMA sp_tgt=RESULT, src0=LRF7, src1=LRF0, src2=LRF1 {uc.degree=2, uc.src0_inc=1, slice_en=0xff}
RETURN
FMUL

.text_xvu
.target 0x104
.place col=5 line=0
.spr 0xff11ff
.lrf_idx 0xe
.lrf 0x4380430042804200410040003e000000
// num_insts = 56
IMMCOPY dst=LRF0, typ1_imm=0x3e00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF1 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF2, typ1_imm=0x54e3 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF3, typ1_imm=0x4000 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF4, typ1_imm=0xdbaa {replica=1, slice_en=0xff}
JADD jcr_tgt=6, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_8, src0=JCR6, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=6, typ1_imm=0x80
L_8: // @0x8
JADD jcr_tgt=6, src0=6, typ1_imm=0xffff {jcr_sel=1}
JSHR jcr_tgt=6, src0=6 {tr_left=0xa}
JADD jcr_tgt=6, src0=6, typ1_imm=1 {jcr_sel=1}
IMMCOPY dst=LRF15 {replica=1, slice_en=1}
IMMCOPY dst=LRF15, typ1_imm=0x4400 {replica=1, slice_en=2}
IMMCOPY dst=LRF15, typ1_imm=0x4600 {replica=1, slice_en=4}
IMMCOPY dst=LRF15, typ1_imm=0x4700 {replica=1, slice_en=8}
IMMCOPY dst=LRF15, typ1_imm=0x4800 {replica=1, slice_en=0x10}
IMMCOPY dst=LRF15, typ1_imm=0x4880 {replica=1, slice_en=0x20}
IMMCOPY dst=LRF15, typ1_imm=0x4900 {replica=1, slice_en=0x40}
IMMCOPY dst=LRF15, typ1_imm=0x4980 {replica=1, slice_en=0x80}
FMA dst=LRF14, src0=LRF14, src1=LRF0, src2=LRF15 {slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x16 {dynloop=1}
  FNMS dst=LRF14, src0=LRF0, src1=LRF0, src2=LRF14 {slice_en=0xff, be=1}
FCMP src0=LRF1, src1=7, src2=LRF14 {slice_en=0xff}
SELECT dst=LRF15, src0=LRF0, src2=LRF1 {slice_en=0xff}
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_1b, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_1b: // @0x1b
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
JADD jcr_tgt=6, src0=5, typ1_imm=0xffff {jcr_sel=1}
FMA dst=LRF7, src0=FIFO_SPLU, src1=LRF0, src2=LRF1 {uc.degree=2, uc.lrf_dst_inc=1, slice_en=0xff}
EE dst=LRF9, src0=LRF7, src2=CONST0 {slice_en=0xff}
IME dst=LRF10, src0=LRF9, src1=2, src2=LRF7 {slice_en=0xff}
FEST dst=LRF11, src0=LRF10, src1=2, src2=CONST0 {slice_en=0xff}
FNMS dst=LRF12, src0=LRF10, src1=LRF11, src2=LRF3 {slice_en=0xff}
FMA dst=LRF11, src0=LRF11, src1=LRF12, src2=LRF1 {slice_en=0xff}
FNMS dst=LRF12, src0=LRF10, src1=LRF11, src2=LRF3 {slice_en=0xff}
FMA dst=LRF11, src0=LRF11, src1=LRF12, src2=LRF1 {slice_en=0xff}
IME dst=LRF5, src0=LRF9, src1=2, src2=LRF11 {slice_en=0xff}
EE dst=LRF9, src0=LRF8, src2=CONST0 {slice_en=0xff}
IME dst=LRF10, src0=LRF9, src1=2, src2=LRF8 {slice_en=0xff}
FEST dst=LRF11, src0=LRF10, src1=2, src2=CONST0 {slice_en=0xff}
FNMS dst=LRF12, src0=LRF10, src1=LRF11, src2=LRF3 {slice_en=0xff}
FMA dst=LRF11, src0=LRF11, src1=LRF12, src2=LRF1 {slice_en=0xff}
FNMS dst=LRF12, src0=LRF10, src1=LRF11, src2=LRF3 {slice_en=0xff}
FMA dst=LRF11, src0=LRF11, src1=LRF12, src2=LRF1 {slice_en=0xff}
IME dst=LRF6, src0=LRF9, src1=2, src2=LRF11 {slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x31 {dynloop=1}
  FMA sp_tgt=RESULT, src0=FIFO_SPLU, src1=LRF5, src2=LRF1 {uc.degree=2, uc.src1_inc=1, slice_en=0xff, be=1}
FMA dst=LRF14, src0=FIFO_SPLU, src1=LRF5, src2=LRF1 {slice_en=0xff}
FCMP src0=LRF15, src1=FIFO_VU, src2=LRF1 {slice_en=0xff}
SELECT out_sp=3, dst=LRF14, src0=LRF14, src2=LRF1 {slice_en=0xff}
FMA dst=LRF14, src0=FIFO_SPLU, src1=LRF6, src2=LRF1 {slice_en=0xff}
FCMP src0=LRF15, src1=FIFO_VU, src2=LRF1 {slice_en=0xff}
SELECT out_sp=3, dst=LRF14, src0=LRF14, src2=LRF1 {slice_en=0xff}
RETURN

.text_xvu
.target 0x84
.place col=5 line=31
.spr 0xff11ff
.lrf_idx 0xe
.lrf 0x4380430042804200410040003e000000
// num_insts = 56
IMMCOPY dst=LRF0, typ1_imm=0x3e00 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF1 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF2, typ1_imm=0x54e3 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF3, typ1_imm=0x4000 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF4, typ1_imm=0xdbaa {replica=1, slice_en=0xff}
JADD jcr_tgt=6, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_8, src0=JCR6, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=6, typ1_imm=0x80
L_8: // @0x8
JADD jcr_tgt=6, src0=6, typ1_imm=0xffff {jcr_sel=1}
JSHR jcr_tgt=6, src0=6 {tr_left=0xa}
JADD jcr_tgt=6, src0=6, typ1_imm=1 {jcr_sel=1}
IMMCOPY dst=LRF15 {replica=1, slice_en=1}
IMMCOPY dst=LRF15, typ1_imm=0x4400 {replica=1, slice_en=2}
IMMCOPY dst=LRF15, typ1_imm=0x4600 {replica=1, slice_en=4}
IMMCOPY dst=LRF15, typ1_imm=0x4700 {replica=1, slice_en=8}
IMMCOPY dst=LRF15, typ1_imm=0x4800 {replica=1, slice_en=0x10}
IMMCOPY dst=LRF15, typ1_imm=0x4880 {replica=1, slice_en=0x20}
IMMCOPY dst=LRF15, typ1_imm=0x4900 {replica=1, slice_en=0x40}
IMMCOPY dst=LRF15, typ1_imm=0x4980 {replica=1, slice_en=0x80}
FMA dst=LRF14, src0=LRF14, src1=LRF0, src2=LRF15 {slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x16 {dynloop=1}
  FNMS dst=LRF14, src0=LRF0, src1=LRF0, src2=LRF14 {slice_en=0xff, be=1}
FCMP src0=LRF1, src1=7, src2=LRF14 {slice_en=0xff}
SELECT dst=LRF15, src0=LRF0, src2=LRF1 {slice_en=0xff}
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_1b, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_1b: // @0x1b
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
JADD jcr_tgt=6, src0=5, typ1_imm=0xffff {jcr_sel=1}
FMA dst=LRF7, src0=FIFO_SPLU, src1=LRF0, src2=LRF1 {uc.degree=2, uc.lrf_dst_inc=1, slice_en=0xff}
EE dst=LRF9, src0=LRF7, src2=CONST0 {slice_en=0xff}
IME dst=LRF10, src0=LRF9, src1=2, src2=LRF7 {slice_en=0xff}
FEST dst=LRF11, src0=LRF10, src1=2, src2=CONST0 {slice_en=0xff}
FNMS dst=LRF12, src0=LRF10, src1=LRF11, src2=LRF3 {slice_en=0xff}
FMA dst=LRF11, src0=LRF11, src1=LRF12, src2=LRF1 {slice_en=0xff}
FNMS dst=LRF12, src0=LRF10, src1=LRF11, src2=LRF3 {slice_en=0xff}
FMA dst=LRF11, src0=LRF11, src1=LRF12, src2=LRF1 {slice_en=0xff}
IME dst=LRF5, src0=LRF9, src1=2, src2=LRF11 {slice_en=0xff}
EE dst=LRF9, src0=LRF8, src2=CONST0 {slice_en=0xff}
IME dst=LRF10, src0=LRF9, src1=2, src2=LRF8 {slice_en=0xff}
FEST dst=LRF11, src0=LRF10, src1=2, src2=CONST0 {slice_en=0xff}
FNMS dst=LRF12, src0=LRF10, src1=LRF11, src2=LRF3 {slice_en=0xff}
FMA dst=LRF11, src0=LRF11, src1=LRF12, src2=LRF1 {slice_en=0xff}
FNMS dst=LRF12, src0=LRF10, src1=LRF11, src2=LRF3 {slice_en=0xff}
FMA dst=LRF11, src0=LRF11, src1=LRF12, src2=LRF1 {slice_en=0xff}
IME dst=LRF6, src0=LRF9, src1=2, src2=LRF11 {slice_en=0xff}
MVLOOPCNT src0=6, typ1_imm=0x31 {dynloop=1}
  FMA sp_tgt=RESULT, src0=FIFO_SPLU, src1=LRF5, src2=LRF1 {uc.degree=2, uc.src1_inc=1, slice_en=0xff, be=1}
FMA dst=LRF14, src0=FIFO_SPLU, src1=LRF5, src2=LRF1 {slice_en=0xff}
FCMP src0=LRF15, src1=FIFO_VU, src2=LRF1 {slice_en=0xff}
SELECT out_sp=3, dst=LRF14, src0=LRF14, src2=LRF1 {slice_en=0xff}
FMA dst=LRF14, src0=FIFO_SPLU, src1=LRF6, src2=LRF1 {slice_en=0xff}
FCMP src0=LRF15, src1=FIFO_VU, src2=LRF1 {slice_en=0xff}
SELECT out_sp=3, dst=LRF14, src0=LRF14, src2=LRF1 {slice_en=0xff}
RETURN

.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x8100000000000000f0000 0x810040000000000210000
// num_insts = 28
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_3, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_3: // @0x3
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
JSUB jcr_tgt=6, src0=5, typ1_imm=2 {jcr_sel=1}
SYNC typ1ac_imm=0xa2
MVLOOPCNT src0=5, typ1_imm=9 {dynloop=1}
  STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=1, be=1}
MVLOOPCNT src0=6, typ1_imm=0xc {dynloop=1}
  ADDCXRIMM typ1ac_imm=1
  ADDSXRIMM typ1ac_imm=1 {be=1}
MVLOOPCNT src0=5, typ1_imm=0xe {dynloop=1}
  STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=1, be=1}
MVLOOPCNT src0=6, typ1_imm=0x11 {dynloop=1}
  ADDCXRIMM typ1ac_imm=1
  ADDSXRIMM typ1ac_imm=1 {be=1}
MVLOOPCNT src0=5, typ1_imm=0x13 {dynloop=1}
  STMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=1, be=1}
MVLOOPCNT src0=6, typ1_imm=0x16 {dynloop=1}
  ADDCXRIMM src0=1, typ1ac_imm=1
  ADDSXRIMM src0=1, typ1ac_imm=1 {be=1}
MVLOOPCNT src0=5, typ1_imm=0x18 {dynloop=1}
  STMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=1, be=1}
MVLOOPCNT src0=6, typ1_imm=0x1b {dynloop=1}
  ADDCXRIMM src0=1, typ1ac_imm=1
  ADDSXRIMM src0=1, typ1ac_imm=1 {be=1}
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x800010000000000020000 0x800050000000000140000
// num_insts = 28
JADD jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP pc_tgt=@L_3, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_3: // @0x3
JADD jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR jcr_tgt=5, src0=5 {shamt=6}
JSUB jcr_tgt=6, src0=5, typ1_imm=2 {jcr_sel=1}
MVLOOPCNT src0=5, typ1_imm=8 {dynloop=1}
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=1, be=1}
MVLOOPCNT src0=6, typ1_imm=0xb {dynloop=1}
  ADDCXRIMM typ1ac_imm=1
  ADDSXRIMM typ1ac_imm=1 {be=1}
MVLOOPCNT src0=5, typ1_imm=0xd {dynloop=1}
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=1, be=1}
MVLOOPCNT src0=6, typ1_imm=0x10 {dynloop=1}
  ADDCXRIMM typ1ac_imm=1
  ADDSXRIMM typ1ac_imm=1 {be=1}
MVLOOPCNT src0=5, typ1_imm=0x12 {dynloop=1}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=1, be=1}
MVLOOPCNT src0=6, typ1_imm=0x15 {dynloop=1}
  ADDCXRIMM src0=1, typ1ac_imm=1
  ADDSXRIMM src0=1, typ1ac_imm=1 {be=1}
MVLOOPCNT src0=5, typ1_imm=0x17 {dynloop=1}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=1, be=1}
MVLOOPCNT src0=6, typ1_imm=0x1a {dynloop=1}
  ADDCXRIMM src0=1, typ1ac_imm=1
  ADDSXRIMM src0=1, typ1ac_imm=1 {be=1}
SYNC typ1ac_imm=0x51
RETURN

