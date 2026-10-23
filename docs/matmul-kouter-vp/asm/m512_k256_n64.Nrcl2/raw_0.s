.arch rebel.evt1
.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0
.lrf 0x8090500000000022c0000
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x6}
RETURN
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x808020000000001000000 0x800010000000001800000
MVLOOPCNT immediate=0x2
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
  LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x6}
  ADDCXRIMM src0=CAR1, immediate=0x1aa {be=1}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}
LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x6}
RETURN
RETURN
