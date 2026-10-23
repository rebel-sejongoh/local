.arch rebel.evt1
.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x824a50000000007000000 0x824b50000000007100000
MVLOOPCNT immediate=4
  STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=4}
  STMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=4, be=1}
SYNC {dir.put=1, lsync_mask.nclu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.nclu=1}
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1 2
.lrf 0x820020000000001000000 0x800a10000000005000000 0x800b10000000005100000
MVLOOPCNT immediate=0x10
  MVLOOPCNT immediate=4
    LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10, be=1}
  MVLOOPCNT immediate=2
    LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10, be=1}
  ADDCXRIMM src0=CAR1, immediate=0x1e0 {be=1}
SYNC {dir.get=1, lsync_mask.ncsu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1}
RETURN
RETURN
