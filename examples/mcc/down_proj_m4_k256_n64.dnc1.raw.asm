// down_proj DNC 1, units in dataflow order (NCLU -> SPLU -> XVU -> ABSU -> ABLU -> TU rows 0..7 -> VU -> SPSU -> NCSU). Reassembles to the same bytes.
.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 0xa 0xb 0xc 0xd 0xe
.lrf 0x800500000000003d80000 0x800400000000003d80000 0x10000000000010000 0x8000000000000 0x0 0x0 0x801110000000004190000 0x801110000000004190000 0x841900000000041a0000 0x841900000000041a0000 0x0 0x0 0x800040000000004180000 0x0 0x0
// num_insts = 56
JIMMCOPY jcr_tgt=0xe, typ1_imm=1
CXRIMM src0=0xf
MVLOOPCNT count=1
  SXRIMM src0=0xf
  CARREGCOPY src0=5, src1=3
  CARREGCOPY src0=6, src1=3
  CARREGCOPY src0=2
  CARREGCOPY src0=9, src1=7
  CARREGCOPY src0=0xa, src1=7
  CARREGCOPY src0=0xd, src1=0xb
  SXRIMM src0=2
  SXRIMM src0=5, typ1ac_imm=0x417
  SXRIMM src0=6, typ1ac_imm=0x417
  SXRIMM src0=0xd
  JIMMCOPY jcr_tgt=4
  JIMMCOPY jcr_tgt=4, typ1_imm=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      MVLOOPCNT count=2
        LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {be=1}
      SYNC typ1ac_imm=0x11
      LDMU src0=SAR12, src1=SBR12, src2=CAR12, src3=CBR12 {burst=1}
      SYNC typ1ac_imm=0x11
      ADDCXRIMM src0=5, typ1ac_imm=0xffffd
      ADDCXRIMM src0=6, typ1ac_imm=0xffffd
      NOP {be=1}
    JIMMCOPY jcr_tgt=4
    NOP {be=1}
  JIMMCOPY jcr_tgt=3
  SYNC typ1ac_imm=0xa
  ADDCXRIMM typ1ac_imm=0x40
  ADDCXRIMM src0=0xb, typ1ac_imm=1
  ADDCXRIMM src0=7, typ1ac_imm=1 {be=1}
ADDCXRIMM typ1ac_imm=0xfffc0
ADDCXRIMM src0=0xb, typ1ac_imm=0xfffff
ADDCXRIMM src0=7, typ1ac_imm=0xfffff
SYNC typ1ac_imm=0xb
MESYNC typ1ad_imm=0x17
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
SXRIMM

.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 0xa 0xb 0xc 0xe 0xf
.lrf 0x1eb80 0x1eb80 0x20b80 0x20b80 0x20b80 0x20c00 0x20c00 0x3fff81 0x20d00 0x3fff81 0x80 0x3fff81 0x3fff81 0x3fff81 0x20d00
// num_insts = 52
IMMCOPY dst=LRF0, typ1a_imm=0xf5c0
IMMCOPY dst=LRF3, typ1a_imm=0x105c0
LRFREGCOPY dst=LRF2, src1=LRF3
LRFREGCOPY dst=LRF5, src1=LRF6
LRFREGCOPY dst=LRF8, src1=LRF15
SYNC typ1_imm=6
MVLOOPCNT count=64
  LDU dst=XVU, src1=LRF10 {burst=1, burst_sz=1, be=1}
SYNC typ1_imm=6
MVLOOPCNT count=1
  LDU dst=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_sz=4, be=1}
SYNC typ1_imm=0x22
MVLOOPCNT count=1
  LDU dst=VU, src0=LRF8, src1=LRF10 {burst=1, burst_sz=3}
  LDU dst=VU, src0=LRF5, src1=LRF10 {burst=1, burst_sz=4, be=1}
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN

.text_xvu
.target 0x84
.place col=5 line=0
.spr 0x70ff21ff
.lccr 0xbe003e00410040003c000000 0xbf803f80404040003f000000
.lrf_idx 0xb 0xc 0xd 0xe
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0xccc8c4c0bcb8b0004c4844403c383000
// num_insts = 14
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=64
      LOGICAL out_tu=1, src0=FIFO_SPLU, src1=FIFO_SPLU, src2=CONST0 {slice_en=0xff, be=1}
    MVLOOPCNT count=1
      MVLOOPCNT count=1
        MVLOOPCNT count=4
          LOGICAL out_ab=1, src0=FIFO_SPLU, src1=FIFO_SPLU, src2=CONST0 {slice_en=0xff, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN {be=1, fill=0x3700000000}

.text_absu
.target 0x90
.place col=0 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x3f0 0x10
// num_insts = 16
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          LDSTU src1=LRF1 {burst=1, burst_sz=4}
          SYNC typ1_imm=1 {be=1}
        NOP {be=1}
      SYNC typ1_imm=2
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0

.text_ablu
.target 0x88
.place col=1 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 0xe 0xf
.lrf 0x3f0 0x3f2 0x3f4 0x3f6 0x3f8 0x3fa 0x3fc 0x3fe 0x0 0x8 0x10
// num_insts = 16
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      SYNC typ1_imm=1
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          SYNC typ1_imm=2
          LDSTU src1=LRF15 {burst=1, burst_sz=4, ld_type=1, ld_splat=1}
          LDSTU src0=LRF4, src1=LRF15 {burst=1, burst_sz=4, ld_type=1, ld_splat=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0

.text_tu
.target 0x81
.place col=0 line=31
.spr 0xff21ff
// num_insts = 20
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
      MVLOOPCNT count=56
        FMA south_tgt=src0, src0=13, src1=15, src2=3 {be=1}
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=15, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
OPC_0x0 <unknown-opc>
OPC_0x0 <unknown-opc>

.text_tu
.target 0x81
.place col=1 line=31
.spr 0xff21ff
// num_insts = 20
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
      MVLOOPCNT count=48
        FMA south_tgt=src0, src0=13, src1=15, src2=3 {be=1}
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=13, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
OPC_0x0 <unknown-opc>
OPC_0x0 <unknown-opc>

.text_tu
.target 0x81
.place col=2 line=31
.spr 0xff21ff
// num_insts = 20
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
      MVLOOPCNT count=40
        FMA south_tgt=src0, src0=13, src1=15, src2=3 {be=1}
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=13, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
OPC_0x0 <unknown-opc>
OPC_0x0 <unknown-opc>

.text_tu
.target 0x81
.place col=3 line=31
.spr 0xff21ff
// num_insts = 20
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
      MVLOOPCNT count=32
        FMA south_tgt=src0, src0=13, src1=15, src2=3 {be=1}
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=13, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
OPC_0x0 <unknown-opc>
OPC_0x0 <unknown-opc>

.text_tu
.target 0x81
.place col=4 line=31
.spr 0xff21ff
// num_insts = 20
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
      MVLOOPCNT count=24
        FMA south_tgt=src0, src0=13, src1=15, src2=3 {be=1}
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=13, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
OPC_0x0 <unknown-opc>
OPC_0x0 <unknown-opc>

.text_tu
.target 0x81
.place col=5 line=31
.spr 0xff21ff
// num_insts = 20
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
      MVLOOPCNT count=16
        FMA south_tgt=src0, src0=13, src1=15, src2=3 {be=1}
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=13, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
OPC_0x0 <unknown-opc>
OPC_0x0 <unknown-opc>

.text_tu
.target 0x81
.place col=6 line=31
.spr 0xff21ff
// num_insts = 20
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
      MVLOOPCNT count=8
        FMA south_tgt=src0, src0=13, src1=15, src2=3 {be=1}
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=13, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
OPC_0x0 <unknown-opc>
OPC_0x0 <unknown-opc>

.text_tu
.target 0x81
.place col=7 line=31
.spr 0xff21ff
// num_insts = 16
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=13, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
OPC_0x0 <unknown-opc>
OPC_0x0 <unknown-opc>

.text_vu
.target 0x82
.place col=4 line=0
.spr 0xff11ff
.lccr 0xbe003e00410040003c000000
.lrf_idx 0 0xc 0xd 0xf
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0x7fff7fff7fff7fff7fff7fff7fff7fff
// num_insts = 16
FCMP src0=LRF0, src1=FIFO_SPLU, src2=CONST0 {slice_en=0xff}
IMMCOPY dst=LRF4 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF5 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF6 {replica=1, slice_en=0xff}
IMMCOPY dst=LRF7 {replica=1, slice_en=0xff}
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA dst=LRF4, src0=FIFO_TU, src1=CONST4, src2=LRF4 {uc.degree=4, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
    FMA sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {uc.degree=4, uc.src0_inc=1, slice_en=0xff}
    NOP {be=1}
  NOP {be=1}
IMMCOPY dst=LRF12, typ1_imm=0x3e00 {replica=1, slice_en=0xff}
RETURN
RETURN {be=1, fill=0x3700000000}
FMUL

.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 1 3 0xf
.lrf 0x20c00 0x20d00 0x80
// num_insts = 16
MVLOOPCNT count=1
  SYNC typ1_imm=0x11 {be=1}
IMMCOPY dst=LRF1, typ1a_imm=0x10600
IMMCOPY dst=LRF3, typ1a_imm=0x10680
MVLOOPCNT count=1
  LRFREGCOPY dst=LRF0, src1=LRF1
  MVLOOPCNT count=1
    STU src1=LRF15, src=FIFO_VU {burst=1, burst_sz=4}
    SYNC typ1_imm=9
    SYNC typ1_imm=0x11 {be=1}
  MODLRFIMM dst=LRF3, typ1a_imm=0xc0
  MODLRFIMM dst=LRF1, typ1a_imm=0x100 {be=1}
RETURN
RETURN
RETURN
RETURN

.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 8
.lrf 0x10000000000010000 0x8011300000000
// num_insts = 20
MVLOOPCNT count=1
  CARREGCOPY src0=9, src1=8
  CARREGCOPY src0=0xb, src1=9
  CARREGCOPY src0=0xc, src1=9
  SXRIMM src0=0xb, typ1ac_imm=0x418
  SXRIMM src0=0xc, typ1ac_imm=0x418
  MVLOOPCNT count=1
    SYNC typ1ac_imm=0x22
    STSU src0=0xb, src2=0xb {burst=1}
    ADDCXRIMM src0=0xb
    ADDCXRIMM src0=0xc {be=1}
  MESYNC typ1ad_imm=0x17
  SYNC typ1ac_imm=5
  ADDCXRIMM src0=8, typ1ac_imm=1 {be=1}
SYNC typ1ac_imm=7
RETURN
RETURN
RETURN
RETURN
SXRIMM

