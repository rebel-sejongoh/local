.arch rebel.evt1
.text_absu
.target 0x190
.place col=0 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x3f0 0x10
MVLOOPCNT immediate=0x4
  MVLOOPCNT immediate=0x10
    SYNC {dir.get=1}
    STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}
    SYNC {dir.put=1, be=1}
  NOP {be=1}
MVLOOPCNT immediate=0x2
  SYNC {dir.get=1, be=1}
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
MVLOOPCNT immediate=0x2
  SYNC {dir.put=1, be=1}
MVLOOPCNT immediate=0x4
  MVLOOPCNT immediate=0x10
    SYNC {dir.get=1}
    LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
    LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
    SYNC {dir.put=1, be=1}
  NOP {be=1}
RETURN
RETURN
RETURN

.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 0 1 15
.lrf 0x23f80 0x1ff80 0x80
MVLOOPCNT immediate=0x10
  STU producer=VU, src0=LRF1, src1=LRF15 {burst=1, burst_size=4}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
RETURN

.text_spsu
.target 0x140
.place col=2 line=6
.spr 0xff01ff
.lrf_idx 0 1 15
.lrf 0x25f80 0x21f80 0x80
MVLOOPCNT immediate=0x10
  STU producer=VU, src0=LRF1, src1=LRF15 {burst=1, burst_size=4}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
RETURN

.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 10
.lrf 0x7f80 0xff80 0x23f80 0x80
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    SYNC {dir.get=1, lsync_mask.nclu=1}
    LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=0x20}
    LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=0x20}
    LDU consumer=XVU, src0=LRF1, src1=LRF10 {burst=1, burst_size=0x8}
    MODLRFIMM src0=LRF1, immediate=0x1e00 {be=1}
  MODLRFIMM src0=LRF1, immediate=0x1f8200
  MODLRFIMM src0=LRF0, immediate=0x1fc000 {be=1}
RETURN
RETURN
RETURN

.text_splu
.target 0x120
.place col=3 line=9
.spr 0xff01ff
.lrf_idx 0 1 2 10
.lrf 0x7f80 0x11f80 0x25f80 0x80
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    SYNC {dir.get=1, lsync_mask.nclu=1}
    LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=0x20}
    LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=0x20}
    LDU consumer=XVU, src0=LRF1, src1=LRF10 {burst=1, burst_size=0x8}
    MODLRFIMM src0=LRF1, immediate=0x1e00 {be=1}
  MODLRFIMM src0=LRF1, immediate=0x1f8200
  MODLRFIMM src0=LRF0, immediate=0x1fc000 {be=1}
RETURN
RETURN
RETURN

.text_vu
.target 0x182
.place col=4 line=0
.spr 0xff11ff
.lccr 0xbe003e00410040003c000000
.lrf_idx 0
.lrf 0x0
FCMP lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=NONE, src0=LRF0, src2=CONST0 {immediate=4}
MVLOOPCNT immediate=0x8
  FMA lrf_tgt=LRF0, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=CONST0 {unroll_control.lrf_tgt=1, unroll_control.degree=2}
  FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=CONST0 {unroll_control.lrf_tgt=1, unroll_control.degree=2}
  MVLOOPCNT immediate=0x3
    FMA lrf_tgt=LRF0, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=LRF0 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2}
    FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
  FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF0, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
  FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2, be=1}
RETURN

.text_xvu
.target 0x184
.place col=5 line=0
.spr 0x70ff21ff
.lccr 0xbe003e00410040003c000000 0xbf803f80404040003f000000
.lrf_idx 11 12 13 14
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0xccc8c4c0bcb8b0004c4844403c383000
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    MVLOOPCNT immediate=0x40
      LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=NONE, tu_tgt=src0, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
    MVLOOPCNT immediate=0x8
      LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=src0, tu_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x828850000000004000000 0x828c50000000004400000
MVLOOPCNT immediate=0x10
  SYNC {dir.get=1, lsync_mask.spsu1=1, lsync_mask.spsu0=1}
  STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=4}
  STMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=4, be=1}
RETURN
RETURN
RETURN
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1 2
.lrf 0x820020000000001000000 0x807810000000002000000 0x807c10000000002400000
MVLOOPCNT immediate=0x4
  MVLOOPCNT immediate=0x4
    LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10, be=1}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x8}
  LDMU src0=SAR2, src1=SBR2, src2=CAR2, src3=CBR2 {burst=0x8}
  ADDSXRIMM src0=SAR1, immediate=0x78
  ADDSXRIMM src0=SAR2, immediate=0x78
  ADDCXRIMM src0=CAR1, immediate=0x7f8
  ADDCXRIMM src0=CAR2, immediate=0x7f8
  SYNC {dir.put=1, lsync_mask.splu1=1, lsync_mask.splu0=1, be=1}
ADDSXRIMM src0=SAR1, immediate=0x7e08
ADDSXRIMM src0=SAR2, immediate=0x7e08
ADDCXRIMM src0=CAR1, immediate=0xfe008
ADDCXRIMM src0=CAR2, immediate=0xfe008
MVLOOPCNT immediate=0x7
  MVLOOPCNT immediate=0x4
    LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x8}
    LDMU src0=SAR2, src1=SBR2, src2=CAR2, src3=CBR2 {burst=0x8}
    ADDSXRIMM src0=SAR1, immediate=0x78
    ADDSXRIMM src0=SAR2, immediate=0x78
    ADDCXRIMM src0=CAR1, immediate=0x7f8
    ADDCXRIMM src0=CAR2, immediate=0x7f8
    SYNC {dir.put=1, lsync_mask.splu1=1, lsync_mask.splu0=1, be=1}
  ADDSXRIMM src0=SAR1, immediate=0x7e08
  ADDSXRIMM src0=SAR2, immediate=0x7e08
  ADDCXRIMM src0=CAR1, immediate=0xfe008
  ADDCXRIMM src0=CAR2, immediate=0xfe008 {be=1}
RETURN

.text_tu
.target 0x181
.place col=0 line=18
.spr 0xff21ff
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
    MVLOOPCNT immediate=0x38
      FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
    MVLOOPCNT immediate=0x2
      FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=#0, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
      FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=1 line=18
.spr 0xff21ff
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
    MVLOOPCNT immediate=0x30
      FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
    MVLOOPCNT immediate=0x2
      FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
      FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=2 line=18
.spr 0xff21ff
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
    MVLOOPCNT immediate=0x28
      FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
    MVLOOPCNT immediate=0x2
      FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
      FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=3 line=18
.spr 0xff21ff
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
    MVLOOPCNT immediate=0x20
      FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
    MVLOOPCNT immediate=0x2
      FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
      FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=4 line=18
.spr 0xff21ff
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
    MVLOOPCNT immediate=0x18
      FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
    MVLOOPCNT immediate=0x2
      FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
      FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=5 line=18
.spr 0xff21ff
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
    MVLOOPCNT immediate=0x10
      FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
    MVLOOPCNT immediate=0x2
      FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
      FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=6 line=18
.spr 0xff21ff
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
    MVLOOPCNT immediate=0x8
      FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
    MVLOOPCNT immediate=0x2
      FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
      FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

.text_tu
.target 0x181
.place col=7 line=18
.spr 0xff21ff
MVLOOPCNT immediate=0x8
  MVLOOPCNT immediate=0x4
    FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
    MVLOOPCNT immediate=0x2
      FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
      FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
