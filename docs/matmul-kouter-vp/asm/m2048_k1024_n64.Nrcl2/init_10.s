.arch rebel.evt1
.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0
.lrf 0x8895b000000000da80000
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=5}
SYNC {dir.put=1, lsync_mask.nclu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.nclu=1}
RETURN
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x880020000000001000000 0x805570000000003000000
MVLOOPCNT immediate=8
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=5}
  ADDCXRIMM src0=CAR1, immediate=0x6ab {be=1}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=5}
SYNC {dir.get=1, lsync_mask.ncsu=1}
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc8=1, sync_mask.nclu=1}
RETURN
RETURN
