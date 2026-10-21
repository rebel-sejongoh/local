// down_proj DNC 0, unedited dnc_disasm output in the new syntax (units in image order). Reassembles to the same bytes.
.arch rebel.evt1
.text_absu
.target 0x90
.place col=0 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x3f0 0x10
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}
          SYNC {dir.put=1, be=1}
        NOP {be=1}
      SYNC {dir.get=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x81
.place col=0 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x38
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=#0, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_ablu
.target 0x88
.place col=1 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 14 15
.lrf 0x3f0 0x3f2 0x3f4 0x3f6 0x3f8 0x3fa 0x3fc 0x3fe 0x0 0x8 0x10
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      SYNC {dir.put=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          SYNC {dir.get=1}
          LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
          LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN

.text_tu
.target 0x81
.place col=1 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x30
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
        NOP {be=1}
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
.lrf 0x20c00 0x20d00 0x80
IMMCOPY src0=LRF3, immediate=0x10680
IMMCOPY src0=LRF1, immediate=0x10600
MVLOOPCNT immediate=1
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4, be=1}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
IMMCOPY src0=LRF1, immediate=0x10600
MVLOOPCNT immediate=1
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4, be=1}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
IMMCOPY src0=LRF1, immediate=0x10600
MVLOOPCNT immediate=1
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4, be=1}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
IMMCOPY src0=LRF1, immediate=0x10600
MVLOOPCNT immediate=1
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4, be=1}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
MODLRFIMM src0=LRF3, immediate=0xc0
RETURN
RETURN
RETURN
RETURN

.text_tu
.target 0x81
.place col=2 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x28
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
        NOP {be=1}
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
.lrf 0x1eb80 0x1eb80 0x20b80 0x20b80 0x20b80 0x20c00 0x20c00 0x3fff81 0x20d00 0x3fff81 0x80 0x3fff81 0x3fff81 0x3fff81 0x20d00
IMMCOPY src0=LRF0, immediate=0xf5c0
IMMCOPY src0=LRF3, immediate=0x105c0
LRFREGCOPY src0=LRF2, src1=LRF3
LRFREGCOPY src0=LRF5, src1=LRF6
LRFREGCOPY src0=LRF8, src1=LRF15
SYNC {dir.get=1, lsync_mask.nclu=1}
MVLOOPCNT immediate=0x40
  LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=1, be=1}
SYNC {dir.get=1, lsync_mask.nclu=1}
MVLOOPCNT immediate=1
  LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=4, be=1}
IMMCOPY src0=LRF11, immediate=0x10800
SYNC {dir.get=1, lsync_mask.nclu=1}
MVLOOPCNT immediate=1
  LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4}
  MODLRFIMM src0=LRF11, immediate=0x1fff40 {be=1}
SYNC {dir.get=1, lsync_mask.nclu=1}
MVLOOPCNT immediate=1
  LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4}
  MODLRFIMM src0=LRF11, immediate=0x1fff40 {be=1}
SYNC {dir.get=1, lsync_mask.nclu=1}
MVLOOPCNT immediate=1
  LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4, be=1}
RETURN
RETURN
RETURN
RETURN

.text_tu
.target 0x81
.place col=3 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x20
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_vu
.target 0x82
.place col=4 line=0
.spr 0xff11ff
.lccr 0xbe003e00410040003c000000
.lrf_idx 0 12 13 15
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0x7fff7fff7fff7fff7fff7fff7fff7fff
FCMP lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=NONE, src0=LRF0, src2=CONST0 {immediate=4}
IMMCOPY lrf_tgt=LRF12, immediate=0x3e00 {repl=1}
MVLOOPCNT immediate=1
  IMMCOPY lrf_tgt=LRF4, immediate=0 {repl=1}
  IMMCOPY lrf_tgt=LRF5, immediate=0 {repl=1}
  IMMCOPY lrf_tgt=LRF6, immediate=0 {repl=1}
  IMMCOPY lrf_tgt=LRF7, immediate=0 {repl=1}
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x81
.place col=4 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x18
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

.text_xvu
.target 0x84
.place col=5 line=0
.spr 0x70ff21ff
.lccr 0xbe003e00410040003c000000 0xbf803f80404040003f000000
.lrf_idx 11 12 13 14
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0xccc8c4c0bcb8b0004c4844403c383000
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=0x40
      LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=NONE, tu_tgt=src0, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=4
          LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=src0, tu_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x81
.place col=5 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=0x10
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
        NOP {be=1}
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
.lrf_idx 0 8
.lrf 0x10000000000010000 0x8010f00000000
MVLOOPCNT immediate=1
  CXRREGCOPY src0=CAR9, src1=CAR8
  CXRREGCOPY src0=CAR11, src1=CAR9
  CXRREGCOPY src0=CAR12, src1=CAR9
  SXRIMM src0=SAR11, immediate=0x418
  SXRIMM src0=SAR12, immediate=0x418
  SYNC {dir.get=1, lsync_mask.spsu0=1}
  SYNC {dir.put=1, lsync_mask.nclu=1}
  SYNC {dir.get=1, lsync_mask.spsu0=1}
  SYNC {dir.get=1, lsync_mask.spsu0=1}
  MVLOOPCNT immediate=1
    SYNC {dir.get=1, lsync_mask.spsu0=1}
    STSU src0=SAR11, src1=SBR0, src2=CAR11, src3=CBR0 {burst=1}
    ADDCXRIMM src0=CAR11, immediate=0
    ADDCXRIMM src0=CAR12, immediate=0 {be=1}
  SYNC {dir.put=1, lsync_mask.nclu=1}
  ADDCXRIMM src0=CAR8, immediate=1 {be=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.nclu=1}
RETURN
RETURN

.text_tu
.target 0x81
.place col=6 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=8
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
        NOP {be=1}
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
.lrf 0x800100000000003d80000 0x800400000000003d80000 0x10000000000010000 0x7ffff00000000 0x801140000000004210000 0x0 0x801100000000004190000 0x80110000fffff04190000 0x41900000000041a0000 0x41900000000041a0000 0x0 0x0 0x800000000000004180000 0x0 0x0
JIMMCOPY jcr_tgt=JCR14, immediate=1
CXRIMM src0=CAR15, immediate=0
MVLOOPCNT immediate=1
  SXRIMM src0=SAR15, immediate=0
  CXRREGCOPY src0=CAR5, src1=CAR3
  CXRREGCOPY src0=CAR6, src1=CAR3
  CXRREGCOPY src0=CAR2, src1=CAR0
  CXRREGCOPY src0=CAR9, src1=CAR7
  CXRREGCOPY src0=CAR10, src1=CAR7
  CXRREGCOPY src0=CAR13, src1=CAR11
  SXRIMM src0=SAR2, immediate=0
  SXRIMM src0=SAR5, immediate=0x417
  SXRIMM src0=SAR6, immediate=0x417
  SXRIMM src0=SAR13, immediate=0
  JIMMCOPY jcr_tgt=JCR4, immediate=0
  JIMMCOPY jcr_tgt=JCR4, immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=2
        LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {be=1}
      SYNC {dir.put=1, lsync_mask.splu0=1}
      LDMU src0=SAR12, src1=SBR12, src2=CAR12, src3=CBR12 {burst=1}
      SYNC {dir.put=1, lsync_mask.splu0=1}
      ADDCXRIMM src0=CAR5, immediate=0xffffd
      ADDCXRIMM src0=CAR6, immediate=0xffffd
      NOP {be=1}
    JIMMCOPY jcr_tgt=JCR4, immediate=0
    NOP {be=1}
  JIMMCOPY jcr_tgt=JCR3, immediate=0
  SYNC {dir.get=1, lsync_mask.ncsu=1}
  MESYNC {dir.get=1, sync_mask.dnc1=1, sync_mask.ncsu=1}
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
  SYNC {dir.put=1, lsync_mask.splu0=1}
  MESYNC {dir.put=1, sync_mask.dnc1=1, sync_mask.ncsu=1}
  MESYNC {dir.get=1, sync_mask.dnc2=1, sync_mask.ncsu=1}
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
  SYNC {dir.put=1, lsync_mask.splu0=1}
  MESYNC {dir.put=1, sync_mask.dnc2=1, sync_mask.ncsu=1}
  MESYNC {dir.get=1, sync_mask.dnc3=1, sync_mask.ncsu=1}
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
  SYNC {dir.put=1, lsync_mask.splu0=1}
  MESYNC {dir.put=1, sync_mask.dnc3=1, sync_mask.ncsu=1}
  SYNC {dir.get=1, lsync_mask.ncsu=1}
  ADDCXRIMM src0=CAR0, immediate=0x40
  ADDCXRIMM src0=CAR11, immediate=1
  ADDCXRIMM src0=CAR7, immediate=1 {be=1}
ADDCXRIMM src0=CAR0, immediate=0xfffc0
ADDCXRIMM src0=CAR11, immediate=0xfffff
ADDCXRIMM src0=CAR7, immediate=0xfffff
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}
MESYNC {dir.get=1, sync_mask.dnc7=1, sync_mask.dnc6=1, sync_mask.dnc5=1, sync_mask.dnc4=1, sync_mask.dnc3=1, sync_mask.dnc2=1, sync_mask.dnc1=1, sync_mask.dnc0=1, sync_mask.nclu=1}
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc8=1, sync_mask.nclu=1}
MESYNC {dir.put=1, sync_mask.dnc7=1, sync_mask.dnc6=1, sync_mask.dnc5=1, sync_mask.dnc4=1, sync_mask.dnc3=1, sync_mask.dnc2=1, sync_mask.dnc1=1, sync_mask.dnc0=1, sync_mask.nclu=1}
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN

.text_tu
.target 0x81
.place col=7 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
