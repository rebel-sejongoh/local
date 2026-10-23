.arch rebel.evt1
.text_absu
.target 0x190
.place col=0 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x3f0 0x10
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=8
          STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}
          SYNC {dir.put=1, be=1}
        SYNC {dir.get=1, be=1}
      MVLOOPCNT immediate=3
        STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}
        SYNC {dir.put=1, be=1}
      SYNC {dir.get=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN

.text_tu
.target 0x181
.place col=0 line=80
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x38
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=0xb
        FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=#0, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
        FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_ablu
.target 0x188
.place col=1 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 14 15
.lrf 0x3f0 0x3f2 0x3f4 0x3f6 0x3f8 0x3fa 0x3fc 0x3fe 0x0 0x8 0x10
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      MVLOOPCNT immediate=1
        SYNC {dir.get=1, dir.put=1}
        LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
        LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
        MVLOOPCNT immediate=7
          SYNC {dir.get=1}
          LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
          LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4, be=1}
        NOP {be=1}
      SYNC {dir.put=1}
      MVLOOPCNT immediate=3
        SYNC {dir.get=1}
        LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
        LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_tu
.target 0x181
.place col=1 line=80
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x30
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=0xb
        FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
        FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 1 3 15
.lrf 0x1e000 0x20a80 0x80
MVLOOPCNT immediate=1
  SYNC {dir.put=1, lsync_mask.self_splu=1, be=1}
IMMCOPY src0=LRF1, immediate=0xf000
IMMCOPY src0=LRF3, immediate=0x10540
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    LRFREGCOPY src0=LRF0, src1=LRF1
    LRFREGCOPY src0=LRF2, src1=LRF3
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=8
        STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4}
        STU producer=VU, src0=LRF2, src1=LRF15 {burst=1, burst_size=2, be=1}
      MVLOOPCNT immediate=2
        STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4}
        STU producer=VU, src0=LRF2, src1=LRF15 {burst=1, burst_size=2, be=1}
      STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=3}
      LRFCOPY src0=LRF15, producer=VU {consume=1}
      STU producer=VU, src0=LRF2, src1=LRF15 {burst=1, burst_size=2}
      MODLRFIMM src0=LRF0, immediate=0xa80
      SYNC {dir.put=1, lsync_mask.self_splu=1, be=1}
    NOP {be=1}
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=0x20, be=1}
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=0xb}
    LRFCOPY src0=LRF15, producer=VU {consume=1}
    MODLRFIMM src0=LRF0, immediate=0xa80
    SYNC {dir.put=1, lsync_mask.self_splu=1, be=1}
  MODLRFIMM src0=LRF3, immediate=0x580
  MODLRFIMM src0=LRF1, immediate=0x1540 {be=1}
SYNC {dir.put=1, lsync_mask.ncsu=1}
IMMCOPY src0=LRF1, immediate=0xf000
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      STU producer=VU, src0=LRF1, src1=LRF15 {burst=1, burst_size=0x20}
      SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
    STU producer=VU, src0=LRF1, src1=LRF15 {burst=1, burst_size=0xb}
    SYNC {dir.put=1, lsync_mask.ncsu=1}
    LRFCOPY src0=LRF15, producer=VU {consume=1}
    MODLRFIMM src0=LRF1, immediate=0xa80 {be=1}
  MODLRFIMM src0=LRF1, immediate=0 {be=1}
RETURN

.text_spsu
.target 0x140
.place col=2 line=16
.spr 0xff01ff
.lrf_idx 1 3 15
.lrf 0x1f580 0x21580 0x80
MVLOOPCNT immediate=1
  SYNC {dir.put=1, lsync_mask.self_splu=1, be=1}
IMMCOPY src0=LRF1, immediate=0xfac0
IMMCOPY src0=LRF3, immediate=0x10ac0
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    LRFREGCOPY src0=LRF0, src1=LRF1
    LRFREGCOPY src0=LRF2, src1=LRF3
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=8
        STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4}
        STU producer=VU, src0=LRF2, src1=LRF15 {burst=1, burst_size=2, be=1}
      MVLOOPCNT immediate=2
        STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4}
        STU producer=VU, src0=LRF2, src1=LRF15 {burst=1, burst_size=2, be=1}
      STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=2}
      LRFCOPY src0=LRF15, producer=VU {consume=1}
      LRFCOPY src0=LRF15, producer=VU {consume=1}
      STU producer=VU, src0=LRF2, src1=LRF15 {burst=1, burst_size=2}
      MODLRFIMM src0=LRF0, immediate=0xac0
      SYNC {dir.put=1, lsync_mask.self_splu=1, be=1}
    NOP {be=1}
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=0x20, be=1}
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=0xa}
    LRFCOPY src0=LRF15, producer=VU {consume=1}
    LRFCOPY src0=LRF15, producer=VU {consume=1}
    MODLRFIMM src0=LRF0, immediate=0xac0
    SYNC {dir.put=1, lsync_mask.self_splu=1, be=1}
  MODLRFIMM src0=LRF3, immediate=0x580
  MODLRFIMM src0=LRF1, immediate=0x1540 {be=1}
SYNC {dir.put=1, lsync_mask.ncsu=1}
IMMCOPY src0=LRF1, immediate=0xfac0
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      STU producer=VU, src0=LRF1, src1=LRF15 {burst=1, burst_size=0x20}
      SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
    STU producer=VU, src0=LRF1, src1=LRF15 {burst=1, burst_size=0xa}
    SYNC {dir.put=1, lsync_mask.ncsu=1}
    LRFCOPY src0=LRF15, producer=VU {consume=1}
    LRFCOPY src0=LRF15, producer=VU {consume=1}
    MODLRFIMM src0=LRF1, immediate=0xac0 {be=1}
  MODLRFIMM src0=LRF1, immediate=0 {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=2 line=80
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x28
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=0xb
        FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
        FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 10 11 12 14 15
.lrf 0x19e80 0x19e80 0x14800 0x14800 0x14800 0x1e000 0x1e000 0x1de80 0x20a80 0x1df00 0x80 0x3fff81 0x3fff81 0x3fff81 0x20a80
JIMMCOPY jcr_tgt=JCR0, immediate=2
JIMMCOPY jcr_tgt=JCR2, immediate=1
IMMCOPY src0=LRF0, immediate=0xcf40
IMMCOPY src0=LRF1, immediate=0xcf40
IMMCOPY src0=LRF6, immediate=0xf000
IMMCOPY src0=LRF7, immediate=0xef40
IMMCOPY src0=LRF9, immediate=0xef80
IMMCOPY src0=LRF12, immediate=0x1fffc0
IMMCOPY src0=LRF14, immediate=0x1fffc0
IMMCOPY src0=LRF15, immediate=0x10540
JIMMCOPY jcr_tgt=JCR1, immediate=1
SYNC {dir.get=1, lsync_mask.nclu=1}
LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1}
MVLOOPCNT immediate=1
  IMMCOPY src0=LRF3, immediate=0xa400
  LRFREGCOPY src0=LRF5, src1=LRF6
  LRFREGCOPY src0=LRF8, src1=LRF15
  LRFREGCOPY src0=LRF2, src1=LRF3
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=0x20, be=1}
    SYNC {dir.get=1, lsync_mask.nclu=1}
    LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=0xb}
    SYNC {dir.get=1, lsync_mask.self_spsu=1}
    MODLRFIMM src0=LRF2, immediate=0x1fc0 {be=1}
  SYNC {dir.get=1, lsync_mask.nclu=1}
  LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1}
  MODLRFIMM src0=LRF3, immediate=0x1540
  MVLOOPCNT src0=JCR1, immediate=@L_3e
    LRFREGCOPY src0=LRF5, src1=LRF6
    LRFREGCOPY src0=LRF8, src1=LRF15
    LRFREGCOPY src0=LRF2, src1=LRF3
    MVLOOPCNT immediate=1
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=0x20}
      SYNC {dir.get=1, lsync_mask.self_spsu=1}
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=0xb}
      MVLOOPCNT immediate=2
        LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=2}
        LDU consumer=VU, src0=LRF5, src1=LRF10 {burst=1, burst_size=4}
        NOP {be=1}
      LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=2}
      LDU consumer=VU, src0=LRF5, src1=LRF10 {burst=1, burst_size=4}
      JCMP pc_tgt=@L_2f, src0=LCCR0, immediate=1 {cmp_mode=NE}
      JCMP pc_tgt=@L_34, src0=LCCR1, immediate=1 {cmp_mode=EQ}
L_2f:
      JCMP pc_tgt=@L_34, src0=LCCR2, immediate=1 {cmp_mode=NE}
      JCMP pc_tgt=@L_32, src0=LCCR1, immediate=1 {cmp_mode=NE}
      MODLRFIMM src0=LRF0, immediate=0x1ff000
L_32:
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1}
L_34:
      MVLOOPCNT immediate=7
        LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=2}
        LDU consumer=VU, src0=LRF5, src1=LRF10 {burst=1, burst_size=4}
        NOP {be=1}
      LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=2}
      LDU consumer=VU, src0=LRF5, src1=LRF10 {burst=1, burst_size=3}
      SENDTRF consumer=VU, trf_src0=TRF0 {sendz=1, burst_size=1}
      MODLRFIMM src0=LRF2, immediate=0x1fc0
      MODLRFIMM src0=LRF5, immediate=0xa80 {be=1}
    MODLRFIMM src0=LRF3, immediate=0x1540 {be=1}
L_3e:
  MODLRFIMM src0=LRF15, immediate=0x580
  MODLRFIMM src0=LRF6, immediate=0x1540 {be=1}
MVLOOPCNT immediate=1
  IMMCOPY src0=LRF6, immediate=0xf000
  IMMCOPY src0=LRF8, immediate=0x10540
  MVLOOPCNT immediate=1
    IMMCOPY src0=LRF7, immediate=0xef40
    IMMCOPY src0=LRF9, immediate=0xef80
    MVLOOPCNT immediate=1
      JCMP pc_tgt=@L_4a, src0=LCCR0, immediate=1 {cmp_mode=NE}
      LDU consumer=VU, src0=LRF7, src1=LRF10 {burst_size=1}
      LDU consumer=VU, src0=LRF9, src1=LRF10 {burst_size=1}
L_4a:
      MVLOOPCNT immediate=1
        SYNC {dir.get=1, lsync_mask.nclu=1}
        LDU consumer=XVU, src0=LRF6, src1=LRF10 {burst=1, burst_size=0x20}
        LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=0x20}
        NOP {be=1}
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF6, src1=LRF10 {burst=1, burst_size=0xb}
      LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=0xb}
      SENDTRF consumer=XVU, trf_src0=TRF0 {sendz=1, burst_size=1}
      SENDTRF consumer=VU, trf_src0=TRF0 {sendz=1, burst_size=1}
      MODLRFIMM src0=LRF6, immediate=0xa80
      MODLRFIMM src0=LRF8, immediate=0xa80 {be=1}
    MODLRFIMM src0=LRF8, immediate=0 {be=1}
  NOP {be=1}
MVLOOPCNT immediate=1
  SYNC {dir.get=1, lsync_mask.self_spsu=1, be=1}
RETURN
RETURN

.text_splu
.target 0x120
.place col=3 line=40
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 10 11 12 14 15
.lrf 0x19e80 0x19e80 0x15d80 0x15d80 0x15d80 0x1f580 0x1f580 0x1de80 0x21580 0x1df00 0x80 0x1501 0x1501 0x3fff81 0x21580
JIMMCOPY jcr_tgt=JCR0, immediate=2
JIMMCOPY jcr_tgt=JCR2, immediate=1
IMMCOPY src0=LRF0, immediate=0xcf40
IMMCOPY src0=LRF1, immediate=0xcf40
IMMCOPY src0=LRF6, immediate=0xfac0
IMMCOPY src0=LRF7, immediate=0xef40
IMMCOPY src0=LRF9, immediate=0xef80
IMMCOPY src0=LRF12, immediate=0xa80
IMMCOPY src0=LRF14, immediate=0x1fffc0
IMMCOPY src0=LRF15, immediate=0x10ac0
JIMMCOPY jcr_tgt=JCR1, immediate=1
SYNC {dir.get=1, lsync_mask.nclu=1}
LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1}
MVLOOPCNT immediate=1
  IMMCOPY src0=LRF3, immediate=0xaec0
  LRFREGCOPY src0=LRF5, src1=LRF6
  LRFREGCOPY src0=LRF8, src1=LRF15
  LRFREGCOPY src0=LRF2, src1=LRF3
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=0x20, be=1}
    SYNC {dir.get=1, lsync_mask.nclu=1}
    LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=0xb}
    SYNC {dir.get=1, lsync_mask.self_spsu=1}
    MODLRFIMM src0=LRF2, immediate=0x1fc0 {be=1}
  SYNC {dir.get=1, lsync_mask.nclu=1}
  LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1}
  MODLRFIMM src0=LRF3, immediate=0x1540
  MVLOOPCNT src0=JCR1, immediate=@L_3e
    LRFREGCOPY src0=LRF5, src1=LRF6
    LRFREGCOPY src0=LRF8, src1=LRF15
    LRFREGCOPY src0=LRF2, src1=LRF3
    MVLOOPCNT immediate=1
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=0x20}
      SYNC {dir.get=1, lsync_mask.self_spsu=1}
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=0xb}
      MVLOOPCNT immediate=2
        LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=2}
        LDU consumer=VU, src0=LRF5, src1=LRF10 {burst=1, burst_size=4}
        NOP {be=1}
      LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=2}
      LDU consumer=VU, src0=LRF5, src1=LRF10 {burst=1, burst_size=4}
      JCMP pc_tgt=@L_2f, src0=LCCR0, immediate=1 {cmp_mode=NE}
      JCMP pc_tgt=@L_34, src0=LCCR1, immediate=1 {cmp_mode=EQ}
L_2f:
      JCMP pc_tgt=@L_34, src0=LCCR2, immediate=1 {cmp_mode=NE}
      JCMP pc_tgt=@L_32, src0=LCCR1, immediate=1 {cmp_mode=NE}
      MODLRFIMM src0=LRF0, immediate=0x1ff000
L_32:
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1}
L_34:
      MVLOOPCNT immediate=7
        LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=2}
        LDU consumer=VU, src0=LRF5, src1=LRF10 {burst=1, burst_size=4}
        NOP {be=1}
      LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=2}
      LDU consumer=VU, src0=LRF5, src1=LRF10 {burst=1, burst_size=3}
      SENDTRF consumer=VU, trf_src0=TRF0 {sendz=1, burst_size=1}
      MODLRFIMM src0=LRF2, immediate=0x1fc0
      MODLRFIMM src0=LRF5, immediate=0xa80 {be=1}
    MODLRFIMM src0=LRF3, immediate=0x1540 {be=1}
L_3e:
  MODLRFIMM src0=LRF15, immediate=0x580
  MODLRFIMM src0=LRF6, immediate=0x1540 {be=1}
MVLOOPCNT immediate=1
  IMMCOPY src0=LRF6, immediate=0xfac0
  IMMCOPY src0=LRF8, immediate=0x11000
  MVLOOPCNT immediate=1
    IMMCOPY src0=LRF7, immediate=0xef40
    IMMCOPY src0=LRF9, immediate=0xef80
    MVLOOPCNT immediate=1
      JCMP pc_tgt=@L_4a, src0=LCCR0, immediate=1 {cmp_mode=NE}
      LDU consumer=VU, src0=LRF7, src1=LRF10 {burst_size=1}
      LDU consumer=VU, src0=LRF9, src1=LRF10 {burst_size=1}
L_4a:
      MVLOOPCNT immediate=1
        SYNC {dir.get=1, lsync_mask.nclu=1}
        LDU consumer=XVU, src0=LRF6, src1=LRF10 {burst=1, burst_size=0x20}
        LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=0x20}
        NOP {be=1}
      SYNC {dir.get=1, lsync_mask.nclu=1}
      LDU consumer=XVU, src0=LRF6, src1=LRF10 {burst=1, burst_size=0xb}
      LDU consumer=VU, src0=LRF8, src1=LRF10 {burst=1, burst_size=0xb}
      SENDTRF consumer=XVU, trf_src0=TRF0 {sendz=1, burst_size=1}
      SENDTRF consumer=VU, trf_src0=TRF0 {sendz=1, burst_size=1}
      MODLRFIMM src0=LRF6, immediate=0xa80
      MODLRFIMM src0=LRF8, immediate=0xa80 {be=1}
    MODLRFIMM src0=LRF8, immediate=0 {be=1}
  NOP {be=1}
MVLOOPCNT immediate=1
  SYNC {dir.get=1, lsync_mask.self_spsu=1, be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=3 line=80
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x20
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=0xb
        FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
        FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_vu
.target 0x182
.place col=4 line=0
.spr 0xff11ff
.lccr 0xbe003e00410040003c000000
.lrf_idx 0 12 13
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0
FCMP lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=NONE, src0=LANE_ID, src2=CONST4 {immediate=5}
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=0xb
    FMAHP lrf_tgt=LRF0, xvu_tgt=NONE, sp_tgt=RESULT, src0=FIFO_TU, src1=CONST4, src2=CONST0 {unroll_control.lrf_tgt=1, unroll_control.degree=1}
    FMAHP lrf_tgt=LRF0, xvu_tgt=NONE, sp_tgt=RESULT, src0=FIFO_TU, src1=CONST4, src2=CONST0 {hp_high=1, unroll_control.lrf_tgt=1, unroll_control.degree=1}
    LOGICAL lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=src2, src0=REUSE, src2=LRF8 {immediate=1, unroll_control.src2=1, unroll_control.degree=1, be=1}
  MVLOOPCNT immediate=0xb
    LOGICAL lrf_tgt=LRF8, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1}
    MERGE lrf_tgt=LRF10, xvu_tgt=NONE, sp_tgt=NONE, src0=REUSE, src2=CONST0 {immediate=6}
    LOGICAL lrf_tgt=LRF9, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1}
    MERGE lrf_tgt=LRF11, xvu_tgt=NONE, sp_tgt=NONE, src0=REUSE, src2=CONST0 {immediate=6}
    FADDHP lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=FIFO_SPLU, src1=LRF8, src2=FIFO_TU {unroll_control.src1=1, unroll_control.degree=2, be=1}
  NOP {be=1}
MVLOOPCNT immediate=1
  LOGICAL lrf_tgt=LRF12, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1}
  LOGICAL lrf_tgt=LRF13, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1}
  MVLOOPCNT immediate=0xb
    FMA lrf_tgt=LRF0, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=FIFO_XVU {unroll_control.lrf_tgt=1, unroll_control.degree=2}
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF0, src1=LRF12, src2=LRF13 {unroll_control.src0=1, unroll_control.degree=2, be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=4 line=80
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x18
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=0xb
        FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
        FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_xvu
.target 0x184
.place col=5 line=0
.spr 0x70ff21ff
.lccr 0xbe003e00410040003c000000 0xbf803f80404040003f000000
.lrf_idx 11 12 13 14
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0xccc8c4c0bcb8b0004c4844403c383000
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=2
    MVLOOPCNT immediate=0x40
      LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=NONE, tu_tgt=src0, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=0x2b
        LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=src0, tu_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
      MVLOOPCNT immediate=1
        LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=src2, tu_tgt=NONE, src0=REUSE, src2=CONST0 {immediate=0, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=0xb
    LOGICAL lrf_tgt=NONE, vu_tgt=src0, sp_tgt=NONE, ab_tgt=NONE, tu_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1, unroll_control.degree=2, be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=5 line=80
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x10
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=0xb
        FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
        FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 1 8
.lrf 0x809b10000000003c10000 0x809dc0000000003ec0000 0x0
CXRREGCOPY src0=CAR11, src1=CAR8
SXRIMM src0=SAR12, immediate=0
CXRREGCOPY src0=CAR12, src1=CAR11
SYNC {dir.get=1, lsync_mask.spsu1=1, lsync_mask.spsu0=1}
SYNC {dir.put=1, lsync_mask.nclu=1}
SXRIMM src0=SAR12, immediate=0
CXRREGCOPY src0=CAR12, src1=CAR11
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      SYNC {dir.get=1, lsync_mask.spsu1=1, lsync_mask.spsu0=1}
      STM src0=SAR12, src1=SBR1, src2=CAR12, src3=CBR1
      STMU src0=SAR12, src1=SBR0, src2=CAR12, src3=CBR0 {be=1}
    SYNC {dir.get=1, lsync_mask.spsu1=1, lsync_mask.spsu0=1}
    STM src0=SAR12, src1=SBR1, src2=CAR12, src3=CBR1 {burst=0xa}
    STMU src0=SAR12, src1=SBR0, src2=CAR12, src3=CBR0 {burst=0xb}
    ADDCXRIMM src0=CAR12, immediate=0x1d5
    ADDSXRIMM src0=SAR12, immediate=0x2a {be=1}
  NOP {be=1}
SYNC {dir.put=1, lsync_mask.nclu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.nclu=1}
RETURN
RETURN
RETURN

.text_tu
.target 0x181
.place col=6 line=80
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=8
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=0xb
        FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
        FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14
.lrf 0x8080200000000033e0000 0x8080200000000033e0000 0x800ad0000000002910000 0x800d80000000002bc0000 0x809020000000003be0000 0x809020000000003be0000 0x809b10000000003c10000 0x809dc0000000003ec0000 0x203c10000000004160000 0x203ec0000000004410000 0x809030000000003bf0000 0x809030000000003bf0000 0xac0000000000000000 0xd700000000002b0000 0x0
JIMMCOPY jcr_tgt=JCR14, immediate=2
CXRIMM src0=CAR15, immediate=0
SXRIMM src0=SAR15, immediate=0
JIMMCOPY jcr_tgt=JCR3, immediate=1
CXRREGCOPY src0=CAR6, src1=CAR4
CXRREGCOPY src0=CAR3, src1=CAR0
CXRREGCOPY src0=CAR10, src1=CAR8
CXRREGCOPY src0=CAR14, src1=CAR12
SXRIMM src0=SAR3, immediate=0
SXRIMM src0=SAR6, immediate=0
SXRIMM src0=SAR10, immediate=0
SXRIMM src0=SAR14, immediate=0
JIMMCOPY jcr_tgt=JCR4, immediate=0
JIMMCOPY jcr_tgt=JCR4, immediate=1
MVLOOPCNT immediate=1
  CXRREGCOPY src0=CAR11, src1=CAR10
  SXRREGCOPY src0=SAR11, src1=SAR10
  JCMP pc_tgt=@L_14, src0=JCR3, immediate=1 {cmp_mode=NE}
  LDM src0=SAR15, src1=SBR4, src2=CAR15, src3=CBR4 {burst=1}
  LDMU src0=SAR15, src1=SBR10, src2=CAR15, src3=CBR10 {burst=1}
L_14:
  MVLOOPCNT immediate=2
    CXRREGCOPY src0=CAR7, src1=CAR6
    SXRREGCOPY src0=SAR7, src1=SAR6
    LDMU src0=SAR3, src1=SBR0, src2=CAR3, src3=CBR0
    LDMU src0=SAR3, src1=SBR0, src2=CAR3, src3=CBR0
    SYNC {dir.put=1, lsync_mask.splu1=1, lsync_mask.splu0=1}
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=1
        JCMP pc_tgt=@L_1f, src0=JCR4, immediate=1 {cmp_mode=NE}
        LDM src0=SAR7, src1=SBR3, src2=CAR7, src3=CBR3
        LDMU src0=SAR7, src1=SBR2, src2=CAR7, src3=CBR2
L_1f:
        SYNC {dir.put=1, lsync_mask.splu1=1, lsync_mask.splu0=1, be=1}
      JCMP pc_tgt=@L_23, src0=JCR4, immediate=1 {cmp_mode=NE}
      LDM src0=SAR7, src1=SBR3, src2=CAR7, src3=CBR3 {burst=0xa}
      LDMU src0=SAR7, src1=SBR2, src2=CAR7, src3=CBR2 {burst=0xb}
L_23:
      SYNC {dir.put=1, lsync_mask.splu1=1, lsync_mask.splu0=1}
      ADDCXRIMM src0=CAR7, immediate=0x7d5
      ADDSXRIMM src0=SAR7, immediate=0x7f {be=1}
    ADDCXRIMM src0=CAR6, immediate=0x200
    ADDSXRIMM src0=SAR6, immediate=0x55
    NOP {be=1}
  JIMMCOPY jcr_tgt=JCR4, immediate=0
  ADDCXRIMM src0=CAR3, immediate=0xfffc0
  ADDSXRIMM src0=SAR3, immediate=0x7fc0 {be=1}
JIMMCOPY jcr_tgt=JCR3, immediate=0
SXRIMM src0=SAR14, immediate=0
CXRIMM src0=CAR14, immediate=0x8000
SYNC {dir.get=1, lsync_mask.ncsu=1}
MESYNC {dir.get=1, sync_mask.dnc5=1, sync_mask.ncsu=1}
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      LDM src0=SAR14, src1=SBR9, src2=CAR14, src3=CBR9
      LDMU src0=SAR14, src1=SBR8, src2=CAR14, src3=CBR8
      SYNC {dir.put=1, lsync_mask.splu1=1, lsync_mask.splu0=1, be=1}
    LDM src0=SAR14, src1=SBR9, src2=CAR14, src3=CBR9 {burst=0xa}
    LDMU src0=SAR14, src1=SBR8, src2=CAR14, src3=CBR8 {burst=0xb}
    ADDCXRIMM src0=CAR14, immediate=0x2a
    ADDSXRIMM src0=SAR14, immediate=0x2a
    SYNC {dir.put=1, lsync_mask.splu1=1, lsync_mask.splu0=1, be=1}
  NOP {be=1}
MESYNC {dir.put=1, sync_mask.dnc5=1, sync_mask.ncsu=1}
SYNC {dir.get=1, lsync_mask.ncsu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1}
RETURN
RETURN
RETURN

.text_tu
.target 0x181
.place col=7 line=80
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=2
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0xb
        FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
        FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
