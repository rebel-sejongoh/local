== SPSU (0xc0) col2 line=0 | ib=1 lccr=0 lrf=2 lrf_idx=[0,1] ==
   SPR: 0xff01ff
   LRF: 0x300 0x80
   [ 0] MVLOOPCNT  typ1_imm=2
   [ 1] STU        src1=1 st_producer=2 be=1
   [ 2] SYNC       typ1_imm=9
   [ 3] RETURN

== SPLU (0xa0) col3 line=0 | ib=2 lccr=0 lrf=3 lrf_idx=[0,1,2] ==
   SPR: 0xff01ff
   LRF: 0x0 0x180 0x80
   [ 0] SYNC       typ1_imm=6
   [ 1] MVLOOPCNT  typ1_imm=2
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
   [ 2] MVLOOPCNT  typ1_imm=2
   [ 3] FMA        src0=4 src1=0x10 src2=0x11 lrf_tgt=0x12 slice_en=0xff
   [ 4] FMA        src0=4 src1=0x10 src2=0x11 lrf_tgt=0x13 slice_en=0xff
   [ 5] FMA        src0=0x12 src1=0x10 src2=0x13 out_sp=3 slice_en=0xff be=1
   [ 6] RETURN
   [ 7] FMUL

== NCSU (0x400) col6 line=0 | ib=1 lccr=0 lrf=1 lrf_idx=[0] ==
   SPR: 0xff01ff
   LRF: 0x800570000000000070000
   [ 0] SYNC       typ1ac_imm=0x22
   [ 1] STMU       burst=2
   [ 2] RETURN
   [ 3] SXRIMM

== NCLU (0x200) col7 line=0 | ib=1 lccr=0 lrf=2 lrf_idx=[0,1] ==
   SPR: 0xff01ff
   LRF: 0x800130000000000010000 0x800350000000000040000
   [ 0] LDMU       burst=2
   [ 1] LDMU       src0=1 src1=1 src2=1 src3=1 burst=2
   [ 2] SYNC       typ1ac_imm=0x11
   [ 3] RETURN
