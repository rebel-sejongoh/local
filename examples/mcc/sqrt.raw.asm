/Users/sejongoh/.local/share/uv/python/cpython-3.10-macos-aarch64-none/lib/python3.10/runpy.py:126: RuntimeWarning: 'dnckit.dnc_dec' found in sys.modules after import of package 'dnckit', but prior to execution of 'dnckit.dnc_dec'; this may result in unpredictable behaviour
  warn(RuntimeWarning(msg))
== SPSU (0xc0) col2 line=0 | ib=1 lccr=0 lrf=2 lrf_idx=[01] ==
   LRF: 0x2080 0x80
   [ 0] MVLOOPCNT  src0=0 typ1_imm=0x40 dynloop=0 cont=0 brk=0 force_jump=0
   [ 1] STU        src0=0 src1=1 interleave_sz=0 burst=0 burst_sz=0 st_type=0 st_producer=2 be=1
   [ 2] SYNC       typ1_imm=9 be=0
   [ 3] RETURN     be=0

== SPLU (0xa0) col3 line=0 | ib=1 lccr=0 lrf=2 lrf_idx=[01] ==
   LRF: 0x0 0x80
   [ 0] SYNC       typ1_imm=6 be=0
   [ 1] MVLOOPCNT  src0=0 typ1_imm=0x40 dynloop=0 cont=0 brk=0 force_jump=0
   [ 2] LDU        src0=0 src1=1 interleave_sz=0 burst=0 burst_sz=0 ld_rot=0 ld_type=0 ld_consumer=3 be=1
   [ 3] RETURN     be=0

== VU (0x82) col4 line=0 | ib=13 lccr=0 lrf=0 lrf_idx=[-] ==
   [ 0] IMMCOPY    typ1_imm=0x3e00 replica=1 lrf_tgt=0x10 slice_en=0xff be=0
   [ 1] IMMCOPY    typ1_imm=0 replica=1 lrf_tgt=0x11 slice_en=0xff be=0
   [ 2] IMMCOPY    typ1_imm=0x3c00 replica=1 lrf_tgt=0x12 slice_en=0xff be=0
   [ 3] IMMCOPY    typ1_imm=0x3f00 replica=1 lrf_tgt=0x13 slice_en=0xff be=0
   [ 4] IMMCOPY    typ1_imm=0x3c80 replica=1 lrf_tgt=0x14 slice_en=0xff be=0
   [ 5] MVLOOPCNT  src0=0 typ1_imm=0x40 dynloop=0 cont=0 brk=0 force_jump=0
   [ 6] FMA        src0=4 src1=0x10 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x15 slice_en=0xff mode=0 url=0 be=0
   [ 7] EE         src0=0x15 src1=0 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x16 slice_en=0xff url=0 be=0
   [ 8] SHR        src0=0x16 src1=1 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x16 slice_en=0xff url=0 be=0
   [ 9] IME        src0=0x16 src1=2 src2=0x14 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff url=0 be=0
   [10] FMA        src0=0x15 src1=0x12 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x17 slice_en=0xff mode=0 url=0 be=0
   [11] FMA        src0=0x18 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x19 slice_en=0xff mode=0 url=0 be=0
   [12] FADDHP     src0=0x17 src1=0x19 src2=0x13 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1a slice_en=0xff hpmode=0 hphigh=0 url=0 be=0
   [13] FMA        src0=0x18 src1=0x1a src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff mode=0 url=0 be=0
   [14] FMA        src0=0x18 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x19 slice_en=0xff mode=0 url=0 be=0
   [15] FADDHP     src0=0x17 src1=0x19 src2=0x13 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1a slice_en=0xff hpmode=0 hphigh=0 url=0 be=0
   [16] FMA        src0=0x18 src1=0x1a src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff mode=0 url=0 be=0
   [17] FMA        src0=0x18 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x19 slice_en=0xff mode=0 url=0 be=0
   [18] FADDHP     src0=0x17 src1=0x19 src2=0x13 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1a slice_en=0xff hpmode=0 hphigh=0 url=0 be=0
   [19] FMA        src0=0x18 src1=0x1a src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff mode=0 url=0 be=0
   [20] FMA        src0=0x18 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x19 slice_en=0xff mode=0 url=0 be=0
   [21] FADDHP     src0=0x17 src1=0x19 src2=0x13 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1a slice_en=0xff hpmode=0 hphigh=0 url=0 be=0
   [22] FMA        src0=0x18 src1=0x1a src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff mode=0 url=0 be=0
   [23] FMA        src0=0x15 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1b slice_en=0xff mode=0 url=0 be=0
   [24] FMA        src0=0x1b src1=0x10 src2=0x11 out_nbr=0 out_sp=3 out_xvu=0 lrf_tgt=0 slice_en=0xff mode=0 url=0 be=1
   [25] RETURN     be=0

== NCSU (0x400) col6 line=0 | ib=1 lccr=0 lrf=1 lrf_idx=[0] ==
   LRF: 0x811000000000000420000
   [ 0] SYNC       typ1ac_imm=0x22 be=0
   [ 1] MVLOOPCNT  src0=0 typ1_imm=2 dynloop=0 cont=0 brk=0 force_jump=0
   [ 2] STMU       src0=0 src1=0 src2=0 src3=0 burst=0 cache=0 qos_vae=0 be=1
   [ 3] RETURN     be=0

== NCLU (0x200) col7 line=0 | ib=1 lccr=0 lrf=1 lrf_idx=[0] ==
   LRF: 0x810000000000000010000
   [ 0] MVLOOPCNT  src0=0 typ1_imm=2 dynloop=0 cont=0 brk=0 force_jump=0
   [ 1] LDMU       src0=0 src1=0 src2=0 src3=0 burst=0 cache=0 qos_vae=0 be=1
   [ 2] SYNC       typ1ac_imm=0x11 be=0
   [ 3] RETURN     be=0

