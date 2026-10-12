== SPSU (0xc0) col2 line=0 | ib=1 lccr=0 lrf=2 lrf_idx=[0,1] ==
   SPR: 0xff01ff
   LRF: 0x4000 0x80
   [ 0] MVLOOPCNT  typ1_imm=0x3f
   [ 1] STU        src1=1 st_producer=2 be=1
   [ 2] SYNC       typ1_imm=9
   [ 3] RETURN

== SPLU (0xa0) col3 line=0 | ib=2 lccr=0 lrf=3 lrf_idx=[0,1,2] ==
   SPR: 0xff01ff
   LRF: 0x0 0x2000 0x80
   [ 0] SYNC       typ1_imm=6
   [ 1] MVLOOPCNT  typ1_imm=0x3f
   [ 2] LDU        src1=2 ld_consumer=3
   [ 3] LDU        src0=1 src1=2 ld_consumer=3 be=1
   [ 4] RETURN
   [ 5] MODLRFREG
   [ 6] MODLRFREG
   [ 7] MODLRFREG

== VU (0x82) col4 line=0 | ib=4 lccr=0 lrf=0 lrf_idx=[-] ==
   SPR: 0xff11ff
   [ 0] IMMCOPY    typ1_imm=0x3e00 replica=1 lrf_tgt=0x10 slice_en=0xff
   [ 1] IMMCOPY    replica=1 lrf_tgt=0x11 slice_en=0xff
   [ 2] MVLOOPCNT  typ1_imm=0x3f
   [ 3] FMA        src0=4 src1=0x10 src2=0x11 lrf_tgt=0x12 slice_en=0xff
   [ 4] FMA        src0=4 src1=0x10 src2=0x11 lrf_tgt=0x13 slice_en=0xff
   [ 5] FMA        src0=0x12 src1=0x10 src2=0x13 out_sp=3 slice_en=0xff be=1
   [ 6] RETURN
   [ 7] FMUL

== NCSU (0x400) col6 line=0 | ib=1 lccr=0 lrf=1 lrf_idx=[0] ==
   SPR: 0xff01ff
   LRF: 0x805ed0000000000810000
   [ 0] SYNC       typ1ac_imm=0x22
   [ 1] STMU
   [ 2] STMU       burst=0x1f
   [ 3] RETURN

== NCLU (0x200) col7 line=0 | ib=2 lccr=0 lrf=2 lrf_idx=[0,1] ==
   SPR: 0xff01ff
   LRF: 0x8007f0000000000010000 0x803360000000000410000
   [ 0] LDMU
   [ 1] LDMU       burst=0x1f
   [ 2] LDMU       src0=1 src1=1 src2=1 src3=1
   [ 3] LDMU       src0=1 src1=1 src2=1 src3=1 burst=0x1f
   [ 4] SYNC       typ1ac_imm=0x11
   [ 5] RETURN
   [ 6] SXRIMM
   [ 7] SXRIMM
