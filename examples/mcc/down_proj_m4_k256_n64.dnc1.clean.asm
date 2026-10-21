// down_proj DNC 1 (leaf, m = 0, k = 1): down_proj_m4_k256_n64.dnc1.raw.asm with dead and redundant instructions removed.
// Removed: leaf SPLU -> VU pushes the leaf VU never pops, and the self_spsu / self_splu syncs around them;
//   1-trip MVLOOPCNT frames; NCLU skeleton cursor and JCR writes and the CAR0 tile bump that nets to zero;
//   IMMCOPYs that rewrite a register's own init value; copies into registers nothing reads; the VU FCMP and LRF12 and the
//   acc zeroing (folded into the first accumulate as src2=CONST0); .lrf entries no instruction reads; trailing RETURNs.
// Checked on the VP (260521_vp_rebel_evt1_arbcal): cleaning all 16 DNCs the same way leaves the final SHM bit-identical,
//   on a rebuild of this commit with the same addresses and structure (1804 -> 1772 cycles) and on a later mcc build
//   (1867 -> 1849 cycles).
.arch rebel.evt1

.text_absu
.target 0x90
.place col=0 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x3f0 0x10
STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}
SYNC {dir.put=1}
SYNC {dir.get=1}
RETURN

.text_tu
.target 0x81
.place col=0 line=31
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
MVLOOPCNT immediate=0x38
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=#0, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN

.text_ablu
.target 0x88
.place col=1 line=0
.spr 0xff01ff
.lrf_idx 0 4 15
.lrf 0x3f0 0x3f8 0x10
SYNC {dir.put=1}
SYNC {dir.get=1}
LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
RETURN

.text_tu
.target 0x81
.place col=1 line=31
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
MVLOOPCNT immediate=0x30
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN

.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 1 15
.lrf 0x20c00 0x80
LRFREGCOPY src0=LRF0, src1=LRF1
STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4}
SYNC {dir.put=1, lsync_mask.ncsu=1}
RETURN

.text_tu
.target 0x81
.place col=2 line=31
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
MVLOOPCNT immediate=0x28
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN

.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 2 10
.lrf 0x1eb80 0x20b80 0x80
SYNC {dir.get=1, lsync_mask.nclu=1}
MVLOOPCNT immediate=0x40
  LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=1, be=1}
SYNC {dir.get=1, lsync_mask.nclu=1}
LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=4}
RETURN

.text_tu
.target 0x81
.place col=3 line=31
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
MVLOOPCNT immediate=0x20
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN

.text_vu
.target 0x82
.place col=4 line=0
.spr 0xff11ff
.lccr 0xbe003e00410040003c000000
FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=CONST0 {unroll_control.lrf_tgt=1, unroll_control.degree=2}
FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
RETURN

.text_tu
.target 0x81
.place col=4 line=31
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
MVLOOPCNT immediate=0x18
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN

.text_xvu
.target 0x84
.place col=5 line=0
.spr 0x70ff21ff
.lccr 0xbe003e00410040003c000000 0xbf803f80404040003f000000
MVLOOPCNT immediate=0x40
  LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=NONE, tu_tgt=src0, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
MVLOOPCNT immediate=4
  LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=src0, tu_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
RETURN

.text_tu
.target 0x81
.place col=5 line=31
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
MVLOOPCNT immediate=0x10
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN

.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 8
.lrf 0x10000000000010000 0x8011300000000
CXRREGCOPY src0=CAR11, src1=CAR8
SXRIMM src0=SAR11, immediate=0x418
SYNC {dir.get=1, lsync_mask.spsu0=1}
STSU src0=SAR11, src1=SBR0, src2=CAR11, src3=CBR0 {burst=1}
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1}
SYNC {dir.put=1, lsync_mask.nclu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.nclu=1}
RETURN

.text_tu
.target 0x81
.place col=6 line=31
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
MVLOOPCNT immediate=8
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 12
.lrf 0x800500000000003d80000 0x800040000000004180000
MVLOOPCNT immediate=2
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {be=1}
SYNC {dir.put=1, lsync_mask.splu0=1}
LDMU src0=SAR12, src1=SBR12, src2=CAR12, src3=CBR12 {burst=1}
SYNC {dir.put=1, lsync_mask.splu0=1}
SYNC {dir.get=1, lsync_mask.ncsu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1}
RETURN

.text_tu
.target 0x81
.place col=7 line=31
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=FIFO_NORTH, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
RETURN
