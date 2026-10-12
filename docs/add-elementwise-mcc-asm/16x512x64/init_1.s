== SPSU (0xc0) col2 line=0 | ib=2 lccr=0 lrf=2 lrf_idx=[0,1] ==
   SPR: 0xff01ff
   LRF: 0x10100 0x80
   [ 0] MVLOOPCNT  typ1_imm=2
   [ 1] MVLOOPCNT  typ1_imm=0x100
   [ 2] STU        src1=1 st_producer=2 be=1
   [ 3] SYNC       typ1_imm=9
   [ 4] IMMCOPY    typ1a_imm=0x8080
   [ 5] SYNC       typ1_imm=0xa
   [ 6] NOP        be=1
   [ 7] RETURN

== SPLU (0xa0) col3 line=0 | ib=3 lccr=0 lrf=3 lrf_idx=[0,1,2] ==
   SPR: 0xff01ff
   LRF: 0x0 0x8080 0x80
   [ 0] MVLOOPCNT  typ1_imm=2
   [ 1] SYNC       typ1_imm=6
   [ 2] MVLOOPCNT  typ1_imm=0x100
   [ 3] LDU        src1=2 ld_consumer=3
   [ 4] LDU        src0=1 src1=2 ld_consumer=3 be=1
   [ 5] IMMCOPY
   [ 6] IMMCOPY    src0=1 typ1a_imm=0x4040
   [ 7] SYNC       typ1_imm=5
   [ 8] NOP        be=1
   [ 9] RETURN
   [10] MODLRFREG
   [11] MODLRFREG

== VU (0x82) col4 line=0 | ib=5 lccr=0 lrf=0 lrf_idx=[-] ==
   SPR: 0xff11ff
   [ 0] IMMCOPY    typ1_imm=0x3e00 replica=1 lrf_tgt=0x10 slice_en=0xff
   [ 1] IMMCOPY    replica=1 lrf_tgt=0x11 slice_en=0xff
   [ 2] MVLOOPCNT  typ1_imm=2
   [ 3] MVLOOPCNT  typ1_imm=0x100
   [ 4] FMA        src0=4 src1=0x10 src2=0x11 lrf_tgt=0x12 slice_en=0xff
   [ 5] FMA        src0=4 src1=0x10 src2=0x11 lrf_tgt=0x13 slice_en=0xff
   [ 6] FMA        src0=0x12 src1=0x10 src2=0x13 out_sp=3 slice_en=0xff be=1
   [ 7] NOP        be=1
   [ 8] RETURN
   [ 9] FMUL

== NCSU (0x400) col6 line=0 | ib=2 lccr=0 lrf=1 lrf_idx=[0] ==
   SPR: 0xff01ff
   LRF: 0x842050000000002030000
   [ 0] MVLOOPCNT  typ1_imm=2
   [ 1] SYNC       typ1ac_imm=0x22
   [ 2] MVLOOPCNT  typ1_imm=8
   [ 3] STMU       be=1
   [ 4] SXRIMM
   [ 5] SYNC       typ1ac_imm=0x21
   [ 6] NOP        be=1
   [ 7] RETURN

== NCLU (0x200) col7 line=0 | ib=3 lccr=0 lrf=2 lrf_idx=[0,1] ==
   SPR: 0xff01ff
   LRF: 0x802010000000000010000 0x822030000000001020000
   [ 0] MVLOOPCNT  typ1_imm=2
   [ 1] MVLOOPCNT  typ1_imm=8
   [ 2] LDMU       be=1
   [ 3] MVLOOPCNT  typ1_imm=8
   [ 4] LDMU       src0=1 src1=1 src2=1 src3=1 be=1
   [ 5] SYNC       typ1ac_imm=0x11
   [ 6] SXRIMM
   [ 7] SXRIMM     src0=1
   [ 8] SYNC       typ1ac_imm=0x12
   [ 9] NOP        be=1
   [10] RETURN
   [11] SXRIMM
