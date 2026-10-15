# sqrt 예제 DNC 0 디스어셈블 (mcc build examples/kpl/sqrt.py, R=256 K=64, DNC당 64행×64)
# 원본: sqrt.raw.asm. '#' 뒤는 사람이 단 주석이다(dnc_dec 출력 아님).
# 해설: ../../docs/dnc-isa-sqrt.md
# 흐름: SHM[0x1000..] -NCLU LDMU×2-> SP[1..64] -SYNC-> SPLU LDU×64 -> VU×64 -> SPSU STU×64 -> SP[0x42..] -SYNC-> NCSU STMU×2 -> SHM[0x1100..]
#

# SPSU (Scratchpad store unit)
== SPSU (0xc0) col2 line=0 | ib=1 lccr=0 lrf=2 lrf_idx=[01] ==
   # SP에 결과 저장: VU FIFO → SP[0x42..], 끝나면 NCSU에 signal
   # LRF0 = 쓰기 포인터 byte 0x2080 (접근 전 증가 → 첫 쓰기 0x2100 = SP line 0x42), LRF1 = stride 0x80 (한 줄)
   LRF: 0x2080 0x80

   # 64번 반복 (한 번에 한 줄)
   # => push LOOP(count=64); body = 다음 명령 ~ be=1
   [ 0] MVLOOPCNT  src0=0 typ1_imm=0x40 dynloop=0 cont=0 brk=0 force_jump=0

   # dequeue(VU FIFO, st_producer=2) → SP[LRF0 += LRF1]; be=1 loop 끝
   # => LRF0 += LRF1; SP[LRF0] := pop(vu); be=1 → loop back-edge
   [ 1] STU        src0=0 src1=1 interleave_sz=0 burst=0 burst_sz=0 st_type=0 st_producer=2 be=1

   # SYNC 9 = SEND|NCSU: spsu0_ncsu put (저장 끝)
   # => spsu0_ncsu_sync += 1
   [ 2] SYNC       typ1_imm=9 be=0

   # 종료
   # => halt
   [ 3] RETURN     be=0

== SPLU (0xa0) col3 line=0 | ib=1 lccr=0 lrf=2 lrf_idx=[01] ==
   # SP → VU FIFO 공급, NCLU 로드가 끝날 때까지 대기
   # LRF0 = 읽기 포인터 byte 0 (접근 전 증가 → 첫 읽기 0x80 = SP line 1), LRF1 = stride 0x80
   LRF: 0x0 0x80

   # SYNC 6 = RECV|NCLU: nclu_splu0 get (로드 끝 대기)
   # => wait(nclu_splu0_sync > 0); nclu_splu0_sync -= 1
   [ 0] SYNC       typ1_imm=6 be=0

   # 64번 반복
   # => push LOOP(count=64); body = 다음 명령 ~ be=1
   [ 1] MVLOOPCNT  src0=0 typ1_imm=0x40 dynloop=0 cont=0 brk=0 force_jump=0

   # enqueue(VU FIFO, ld_consumer=3) ← SP[LRF0 += LRF1]; be=1 loop 끝
   # => LRF0 += LRF1; push(vu, SP[LRF0]); be=1 → loop back-edge
   [ 2] LDU        src0=0 src1=1 interleave_sz=0 burst=0 burst_sz=0 ld_rot=0 ld_type=0 ld_consumer=3 be=1

   # 종료
   # => halt
   [ 3] RETURN     be=0

== VU (0x82) col4 line=0 | ib=13 lccr=0 lrf=0 lrf_idx=[-] ==
   # √x = x·(1/√x). seed 0.625·2^-⌊e/2⌋ + Newton 4회. 64 lane, 한 줄씩
   # LRF0 = 1.0
   # => LRF0 := broadcast(1.0)  (64 lane)
   [ 0] IMMCOPY    typ1_imm=0x3e00 replica=1 lrf_tgt=0x10 slice_en=0xff be=0

   # LRF1 = 0
   # => LRF1 := broadcast(0)  (64 lane)
   [ 1] IMMCOPY    typ1_imm=0 replica=1 lrf_tgt=0x11 slice_en=0xff be=0

   # LRF2 = 0.5
   # => LRF2 := broadcast(0.5)  (64 lane)
   [ 2] IMMCOPY    typ1_imm=0x3c00 replica=1 lrf_tgt=0x12 slice_en=0xff be=0

   # LRF3 = 1.5
   # => LRF3 := broadcast(1.5)  (64 lane)
   [ 3] IMMCOPY    typ1_imm=0x3f00 replica=1 lrf_tgt=0x13 slice_en=0xff be=0

   # LRF4 = 0.625 (seed 보정)
   # => LRF4 := broadcast(0.625)  (64 lane)
   [ 4] IMMCOPY    typ1_imm=0x3c80 replica=1 lrf_tgt=0x14 slice_en=0xff be=0

   # 64번 반복 (SPLU가 보내는 줄마다)
   # => push LOOP(count=64); body = 다음 명령 ~ be=1
   [ 5] MVLOOPCNT  src0=0 typ1_imm=0x40 dynloop=0 cont=0 brk=0 force_jump=0

   # x = splu·1.0 + 0 → LRF5  (FIFO pop은 한 번뿐이라 레지스터에 받아 둠)
   # => LRF5 := pop(splu) × LRF0 + LRF1
   [ 6] FMA        src0=4 src1=0x10 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x15 slice_en=0xff mode=0 url=0 be=0

   # e = exponent(x) → LRF6  ⚠ bias 뺀 정수 지수로 가정
   # => LRF6 := exponent(LRF5)   (src1=0 모드)
   [ 7] EE         src0=0x15 src1=0 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x16 slice_en=0xff url=0 be=0

   # e' = e >> 1 = ⌊e/2⌋ → LRF6  (src1=1은 shift 양)
   # => LRF6 := LRF6 >> 1
   [ 8] SHR        src0=0x16 src1=1 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x16 slice_en=0xff url=0 be=0

   # y0 = 0.625·2^-e' → LRF8  (IME mode 2: src2·2^-src0)
   # => LRF8 := LRF4 × 2^(−LRF6)   (src1=2 모드)
   [ 9] IME        src0=0x16 src1=2 src2=0x14 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff url=0 be=0

   # xh = x·0.5 → LRF7
   # => LRF7 := LRF5 × LRF2 + LRF1
   [10] FMA        src0=0x15 src1=0x12 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x17 slice_en=0xff mode=0 url=0 be=0

   # Newton 1: t = y·y → LRF9
   # => LRF9 := LRF8 × LRF8 + LRF1
   [11] FMA        src0=0x18 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x19 slice_en=0xff mode=0 url=0 be=0

   # Newton 1: u = 1.5 − xh·t → LRF10  (디코더 표기 FADDHP, hpmode=0이라 실제는 FNMS)
   # => LRF10 := LRF3 − LRF7 × LRF9   (FNMS)
   [12] FADDHP     src0=0x17 src1=0x19 src2=0x13 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1a slice_en=0xff hpmode=0 hphigh=0 url=0 be=0

   # Newton 1: y = y·u → LRF8
   # => LRF8 := LRF8 × LRF10 + LRF1
   [13] FMA        src0=0x18 src1=0x1a src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff mode=0 url=0 be=0

   # Newton 2: t = y·y
   # => LRF9 := LRF8 × LRF8 + LRF1
   [14] FMA        src0=0x18 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x19 slice_en=0xff mode=0 url=0 be=0

   # Newton 2: u = 1.5 − xh·t (FNMS)
   # => LRF10 := LRF3 − LRF7 × LRF9   (FNMS)
   [15] FADDHP     src0=0x17 src1=0x19 src2=0x13 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1a slice_en=0xff hpmode=0 hphigh=0 url=0 be=0

   # Newton 2: y = y·u
   # => LRF8 := LRF8 × LRF10 + LRF1
   [16] FMA        src0=0x18 src1=0x1a src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff mode=0 url=0 be=0

   # Newton 3: t = y·y
   # => LRF9 := LRF8 × LRF8 + LRF1
   [17] FMA        src0=0x18 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x19 slice_en=0xff mode=0 url=0 be=0

   # Newton 3: u = 1.5 − xh·t (FNMS)
   # => LRF10 := LRF3 − LRF7 × LRF9   (FNMS)
   [18] FADDHP     src0=0x17 src1=0x19 src2=0x13 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1a slice_en=0xff hpmode=0 hphigh=0 url=0 be=0

   # Newton 3: y = y·u
   # => LRF8 := LRF8 × LRF10 + LRF1
   [19] FMA        src0=0x18 src1=0x1a src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff mode=0 url=0 be=0

   # Newton 4: t = y·y
   # => LRF9 := LRF8 × LRF8 + LRF1
   [20] FMA        src0=0x18 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x19 slice_en=0xff mode=0 url=0 be=0

   # Newton 4: u = 1.5 − xh·t (FNMS)
   # => LRF10 := LRF3 − LRF7 × LRF9   (FNMS)
   [21] FADDHP     src0=0x17 src1=0x19 src2=0x13 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1a slice_en=0xff hpmode=0 hphigh=0 url=0 be=0

   # Newton 4: y = y·u ≈ 1/√x
   # => LRF8 := LRF8 × LRF10 + LRF1
   [22] FMA        src0=0x18 src1=0x1a src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x18 slice_en=0xff mode=0 url=0 be=0

   # r = x·y ≈ √x → LRF11
   # => LRF11 := LRF5 × LRF8 + LRF1
   [23] FMA        src0=0x15 src1=0x18 src2=0x11 out_nbr=0 out_sp=0 out_xvu=0 lrf_tgt=0x1b slice_en=0xff mode=0 url=0 be=0

   # r·1.0 + 0 → SPSU FIFO (out_sp=3), LRF 쓰기 없음(lrf_tgt=0); be=1 loop 끝
   # => push(spsu) := LRF11 × LRF0 + LRF1; be=1 → loop back-edge
   [24] FMA        src0=0x1b src1=0x10 src2=0x11 out_nbr=0 out_sp=3 out_xvu=0 lrf_tgt=0 slice_en=0xff mode=0 url=0 be=1

   # 종료
   # => halt
   [25] RETURN     be=0


# NCSU: NC store unit coping lines from SP to SHM/DRAM
== NCSU (0x400) col6 line=0 | ib=1 lccr=0 lrf=1 lrf_idx=[0] ==
   # SP → SHM 저장 (uDMA)
   # descriptor: CBR = 0x8_1100 → SHM line 0x1100, SBR = 0x42 → SP line 0x42
   # LRF0 value: SAR=0, SBR=0x42, CAR=0, CBR=0x8_1100
   LRF: 0x811000000000000420000

   # SYNC 0x22 = RECV|SPSU0: spsu0_ncsu get (SPSU 저장 끝 대기)
   # => wait(spsu0_ncsu_sync > 0); spsu0_ncsu_sync -= 1
   [ 0] SYNC       typ1ac_imm=0x22 be=0

   # 2번 반복
   # => push LOOP(count=2); body = 다음 명령 ~ be=1
   [ 1] MVLOOPCNT  src0=0 typ1_imm=2 dynloop=0 cont=0 brk=0 force_jump=0

   # SHM[..] ← SP[..], burst=0 → 32줄; 주소 자동 증가 유지 → 총 64줄; be=1 loop 끝
   # sp_line  = LRF[src0].SAR + LRF[src1].SBR
   # shm_line = LRF[src2].CAR + LRF[src3].CBR          # CBR의 [83:80]=0x8은 SHM 영역 표시
   # for j in 0..n-1: 
   #   SHM[shm_line + j] := SP[sp_line + j]      # n = burst (0이면 32)
   # 그 뒤 descriptor 주소를 n줄만큼 전진 (U = update)
   [ 2] STMU       src0=0 src1=0 src2=0 src3=0 burst=0 cache=0 qos_vae=0 be=1

   # 종료
   # => halt
   [ 3] RETURN     be=0

== NCLU (0x200) col7 line=0 | ib=1 lccr=0 lrf=1 lrf_idx=[0] ==
   # SHM → SP 로드 (uDMA)
   # descriptor: CBR = 0x8_1000 → SHM line 0x1000, SBR = 0x1 → SP line 1
   LRF: 0x810000000000000010000

   # 2번 반복
   # => push LOOP(count=2); body = 다음 명령 ~ be=1
   [ 0] MVLOOPCNT  src0=0 typ1_imm=2 dynloop=0 cont=0 brk=0 force_jump=0

   # SP[..] ← SHM[..], burst=0 → 32줄; 주소 자동 증가 유지 → 총 64줄; be=1 loop 끝
   # => for j<32: SP[LRF0.SAR + LRF0.SBR + j] := SHM[LRF0.CAR + LRF0.CBR + j]; descriptor += 32줄; be=1 → loop back-edge
   [ 1] LDMU       src0=0 src1=0 src2=0 src3=0 burst=0 cache=0 qos_vae=0 be=1

   # SYNC 0x11 = SEND|SPLU0: nclu_splu0 put (로드 끝)
   # => nclu_splu0_sync += 1
   [ 2] SYNC       typ1ac_imm=0x11 be=0

   # 종료
   # => halt
   [ 3] RETURN     be=0

