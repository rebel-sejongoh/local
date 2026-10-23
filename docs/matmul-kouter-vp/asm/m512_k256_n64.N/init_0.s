.arch rebel.evt1
.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x809050000000002800000 0x809150000000002900000
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
.lrf 0x808020000000001000000 0x800010000000002000000 0x800110000000002100000
MVLOOPCNT immediate=4
  MVLOOPCNT immediate=4
    LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10, be=1}
  MVLOOPCNT immediate=2
    LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10, be=1}
  ADDCXRIMM src0=CAR1, immediate=0x1e0 {be=1}
SYNC {dir.get=1, lsync_mask.ncsu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}
MESYNC {dir.get=1, sync_mask.dnc7=1, sync_mask.dnc6=1, sync_mask.dnc5=1, sync_mask.dnc4=1, sync_mask.dnc3=1, sync_mask.dnc2=1, sync_mask.dnc1=1, sync_mask.dnc0=1, sync_mask.nclu=1}
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc8=1, sync_mask.nclu=1}
MESYNC {dir.put=1, sync_mask.dnc7=1, sync_mask.dnc6=1, sync_mask.dnc5=1, sync_mask.dnc4=1, sync_mask.dnc3=1, sync_mask.dnc2=1, sync_mask.dnc1=1, sync_mask.dnc0=1, sync_mask.nclu=1}
RETURN
RETURN
