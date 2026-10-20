// Llama down_proj: out[M, N] = x[M, K] @ w[K, N],  M=4 K=256 N=64, dlf16.
// Source:  PrimitiveAuthor/mcc/tests/perf/dense/m4_k256_n64/kernel.py  (mcc build, codesigner dev c1ba98778)
// Image:   78848 B over 16 DNCs. This file is DNC 0 (a reduce ROOT), dnc_binutils disasm + hand comments.
//          TU rows 1..7 are summarized, not listed, so this file does not reassemble; the complete
//          unedited disasm of DNC 0 and DNC 1 is in down_proj_m4_k256_n64.dnc0.raw.asm / .dnc1.raw.asm.
//          The leaf DNC 1 differs only where marked "leaf:" at the end.
//
// ── Distribution over 16 DNCs (tiled trace) ───────────────────────────────────────────────────────
//   dnc[16] = shard.M[4] x split.K[4]
//     d = 4*m + k,  m in 0..3 (output row),  k in 0..3 (K chunk of 64)
//     DNC d computes  partial[m, :] = x[m, 64k .. 64k+63] @ w[64k .. 64k+63, :]      (1 x 64 x 64)
//     roots  d = 0, 4, 8, 12  (k = 0): gather the 3 sibling partials, add, store out[m, :]
//     leaves d = k != 0:              store the partial to SHM scratch, signal the root
//   In one DNC: N = 64 on lanes; K = 64 = 8 TU rows (K.col) x 8 per row (K.beat).
//
// ── Memory map seen from DNC 0 (lines of 128 B; SHM lines carry region tag 0x8 in the NC descriptor) ──
//   SHM  x       line 4k + m            (one line per (k, m): 64 K-values of row m)
//        w       lines 0x10 + 64k ..    (64 lines per K chunk, one K row per line, N on lanes)
//        out     line 0x110 + m         (written by root m)
//        partial line 0x114 + ...       (leaf scratch; root DNC 0 reads 0x114, 0x115, 0x116)
//   SP   kernel  lines 0x3d8 .. 0x417   (64 lines)
//        x       line  0x418            (ab_bank)
//        psum    line  0x419 ..         (VU result band)
//        gather  line  0x421 ..         (root: sibling partials land here)
//
// ── What differs per DNC: only the NCLU descriptor bases (CBR); every instruction is the same (SPMD) ──
//   d = 4m + k     w chunk  SHM 0x10 + 64k        x  SHM 4k + m      role
//   0  (m0 k0)     0x10                           0x0                root
//   1  (m0 k1)     0x50                           0x4                leaf
//   2  (m0 k2)     0x90                           0x8                leaf
//   3  (m0 k3)     0xd0                           0xc                leaf
//   4  (m1 k0)     0x10                           0x1                root
//   5  (m1 k1)     0x50                           0x5                leaf
//   …
//   15 (m3 k3)     0xd0                           0xf                leaf
//   (decoded from all 16 images; the 0x8 SHM tag in CBR[19:16] is dropped here)
//
// ── Dataflow per DNC ──────────────────────────────────────────────────────────────────────────────
//   SHM -NCLU-> SP -SPLU-> XVU -out_tu-> TU north (kernel, 64 lines)
//                          XVU -out_ab-> ABSU -> AB bank -> ABLU -> TU west (activation)
//   TU (8 rows, systolic over K) -south of row 7-> VU (acc) -> SPSU -> SP -NCSU-> SHM
//   root only: SHM partials -NCLU-> SP -SPLU-> VU (acc += partial), cross-DNC order by MESYNC
//
// ── Notation in comments ──────────────────────────────────────────────────────────────────────────
//   R := e          register transfer;  SP[l], SHM[l] are 128 B lines;  N/W/S/E are the TU links
//   put(a->b), get(a->b)   SYNC on the counting channel a->b (+1 / wait > 0 then -1)
//   mput(d.U), mget(d.U)   MESYNC to/from unit U of DNC d
//   SP-unit LRF holds byte addresses: IMMCOPY/MODLRFIMM immediates are <<1; LDU/STU add the stride first.
//   "?" marks a reading not confirmed against the ISA doc.
//
// Units are listed in dataflow order, starting at NCLU: NCLU -> SPLU -> XVU -> ABSU -> ABLU -> TU -> VU -> SPSU -> NCSU.
// All units start together and run concurrently; the order is the data dependency, and FIFOs/SYNCs enforce it.

// =================================================================================================
// NCLU (col 7): SHM -> SP. Stage kernel + activation, then (root) gather the 3 sibling partials.
// =================================================================================================
.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 0xa 0xb 0xc 0xd 0xe
.lrf 0x800100000000003d80000 0x800400000000003d80000 0x10000000000010000 0x7ffff00000000 0x801140000000004210000 0x0 0x801100000000004190000 0x80110000fffff04190000 0x41900000000041a0000 0x41900000000041a0000 0x0 0x0 0x800000000000004180000 0x0 0x0
//
// ── NCLU address registers ────────────────────────────────────────────────────────────────────────
// Every SAR/SBR/CAR/CBR is a field of an LRF descriptor word, loaded by .lrf at block start
// (SAR[14:0], SBR[31:16], CAR[51:32], CBR[83:64]; the 0x8 in CBR[19:16] tags SHM).
// SP line = SBR + SAR, SHM line = CBR + CAR; LDMU then advances SAR and CAR by the burst.
//
//   idx  SAR   SBR    CAR      CBR       role                        address = base + running offset
//   ---  ----  -----  -------  --------  --------------------------  -------------------------------------------
//   0    0     0x3d8  0        0x80010   kernel w, chunk k=0         SP 0x3d8 + SAR0  <-  SHM 0x10 + CAR0
//                                                                    = w[64k + i, :],  i = 0..63  (CAR0, SAR0 count i)
//   4    0     0x421  0        0x80114   gather: sibling partials    SP 0x421 + SAR4  <-  SHM 0x114 + CAR4
//                                                                    = partial of DNC 1, 2, 3     (one line each)
//   12   0     0x418  0        0x80000   activation x[m=0, k=0]      SP 0x418 + SAR12 <-  SHM 0 + CAR12
//                                                                    = x[m, 64k .. 64k+63]        (SHM line 4k + m)
//   others: not read by any transfer in this build (see "dead" below)
//     1    0     0x3d8  0        0x80040   kernel slot of another arm (SHM 0x40)
//     2    0     1      0        1         SBR/CBR = 1: a per-line stride pair (LDSU/STSU form)
//     3    0     0      0x7ffff  0         CAR = 0x7ffff
//     6,7  0     0x419  0 / -1   0x80110   out line 0x110 (reduce-root egress arm)
//     8,9  0     0x41a  0        0x419     SP-to-SP (reduce scratch arm)
//
// The set-up block and the -3 / +-1 cursor bumps come from the fixed 36-slot NCLU skeleton
// (mcc lowering/substrate.py _NCLU_SKELETON). In this build only the three LDMUs read descriptors
// 0, 4, and 12, so every write marked "dead" below changes a register nothing reads.
// num_insts = 64
JIMMCOPY jcr_tgt=0xe, typ1_imm=1        // JCR14 := 1
CXRIMM src0=0xf                         // CAR15 := 0                       dead
MVLOOPCNT count=1
  SXRIMM src0=0xf                       // SAR15 := 0                       dead
  CARREGCOPY src0=5, src1=3             // CAR5  := CAR3 = 0x7ffff          dead (skeleton cursor)
  CARREGCOPY src0=6, src1=3             // CAR6  := CAR3 = 0x7ffff          dead
  CARREGCOPY src0=2                     // CAR2  := CAR0 = 0                dead
  CARREGCOPY src0=9, src1=7             // CAR9  := CAR7 = 0xfffff (-1)     dead
  CARREGCOPY src0=0xa, src1=7           // CAR10 := CAR7                    dead
  CARREGCOPY src0=0xd, src1=0xb         // CAR13 := CAR11 = 0               dead
  SXRIMM src0=2                         // SAR2  := 0                       dead
  SXRIMM src0=5, typ1ac_imm=0x417       // SAR5  := 0x417 (x band - 1 line) dead
  SXRIMM src0=6, typ1ac_imm=0x417       // SAR6  := 0x417                   dead
  SXRIMM src0=0xd                       // SAR13 := 0                       dead
  JIMMCOPY jcr_tgt=4                    // JCR4 := 0
  JIMMCOPY jcr_tgt=4, typ1_imm=1        // JCR4 := 1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      MVLOOPCNT count=2
        // [64, 64] weight tile to SP
        LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {be=1}
                                        // SP[0x3d8 + SAR0 ..+32] := SHM[0x10 + CAR0 ..+32]; SAR0 += 32; CAR0 += 32
                                        // trip 1: w[0..31, :] -> SP 0x3d8..0x3f7;  trip 2: w[32..63, :] -> SP 0x3f8..0x417
      SYNC typ1ac_imm=0x11              // put(nclu->splu0): kernel staged
      // [1, 64] x tile to SP
      LDMU src0=SAR12, src1=SBR12, src2=CAR12, src3=CBR12 {burst=1}
                                        // SP[0x418 + SAR12] := SHM[0 + CAR12]; SAR12 += 1; CAR12 += 1
                                        //   = SP 0x418 := x[m=0, 0..63]
      SYNC typ1ac_imm=0x11              // put(nclu->splu0): activation staged
      ADDCXRIMM src0=5, typ1ac_imm=0xffffd   // CAR5 += -3                    dead
      ADDCXRIMM src0=6, typ1ac_imm=0xffffd   // CAR6 += -3                    dead
      NOP {be=1}
    JIMMCOPY jcr_tgt=4                  // JCR4 := 0
    NOP {be=1}
  JIMMCOPY jcr_tgt=3                    // JCR3 := 0
  SYNC typ1ac_imm=0xa                   // get(ncsu->nclu): credit (root has stored its local partial)
  MESYNC typ1ad_imm=0x2a                // mget(1.NCSU): DNC 1's partial is in SHM
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                        // SP[0x421 + SAR4] := SHM[0x114 + CAR4]; SAR4 += 1; CAR4 += 1   = SP 0x421 := partial(DNC 1)
  SYNC typ1ac_imm=0x11                  // put(nclu->splu0)
  MESYNC typ1ad_imm=0x29                // mput(1.NCSU): consumed
  MESYNC typ1ad_imm=0x4a                // mget(2.NCSU)
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                        // SAR4 = 1, CAR4 = 1:  SP 0x422 := SHM 0x115 = partial(DNC 2)
  SYNC typ1ac_imm=0x11
  MESYNC typ1ad_imm=0x49                // mput(2.NCSU)
  MESYNC typ1ad_imm=0x8a                // mget(3.NCSU)
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                        // SAR4 = 2, CAR4 = 2:  SP 0x423 := SHM 0x116 = partial(DNC 3)
  SYNC typ1ac_imm=0x11
  MESYNC typ1ad_imm=0x89                // mput(3.NCSU)
  SYNC typ1ac_imm=0xa                   // get(ncsu->nclu)
  ADDCXRIMM typ1ac_imm=0x40             // CAR0  += 64   next output tile's w chunk (one tile here, so unused)
  ADDCXRIMM src0=0xb, typ1ac_imm=1      // CAR11 += 1                                       dead
  ADDCXRIMM src0=7, typ1ac_imm=1 {be=1} // CAR7  += 1                                       dead
ADDCXRIMM typ1ac_imm=0xfffc0            // CAR0  += -64  rewind after the tile loop
ADDCXRIMM src0=0xb, typ1ac_imm=0xfffff  // CAR11 += -1                                       dead
ADDCXRIMM src0=7, typ1ac_imm=0xfffff    // CAR7  += -1                                       dead
SYNC typ1ac_imm=0xb                     // put+get(nclu<->ncsu): fence
MESYNC typ1ad_imm=0xff6                 // mget(0..7.NCLU)   cluster barrier: every DNC of cluster 0 is done
MESYNC typ1ad_imm=0x1007                // mput+mget(8.NCLU) exchange with the other cluster's head
MESYNC typ1ad_imm=0xff5                 // mput(0..7.NCLU)   release cluster 0
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
SXRIMM                                  // IBUFF fill
SXRIMM

// =================================================================================================
// SPLU (col 3): SP -> XVU (kernel, activation), SP -> VU (gathered partials, root only)
// =================================================================================================
.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 0xa 0xb 0xc 0xe 0xf
.lrf 0x1eb80 0x1eb80 0x20b80 0x20b80 0x20b80 0x20c00 0x20c00 0x3fff81 0x20d00 0x3fff81 0x80 0x3fff81 0x3fff81 0x3fff81 0x20d00
// num_insts = 28
IMMCOPY dst=LRF0, typ1a_imm=0xf5c0      // LRF0 := 0x1eb80 = kernel base - 1 line (line 0x3d7)
IMMCOPY dst=LRF3, typ1a_imm=0x105c0     // LRF3 := 0x20b80 = x base - 1 line (line 0x417)
LRFREGCOPY dst=LRF2, src1=LRF3          // LRF2 := LRF3
LRFREGCOPY dst=LRF5, src1=LRF6          // LRF5 := LRF6
LRFREGCOPY dst=LRF8, src1=LRF15         // LRF8 := LRF15
SYNC typ1_imm=6                         // get(nclu->splu): kernel staged
MVLOOPCNT count=64
  LDU dst=XVU, src1=LRF10 {burst=1, burst_sz=1, be=1}
                                        // LRF0 += 0x80; push(xvu, SP[LRF0])      kernel lines 0x3d8 .. 0x417
SYNC typ1_imm=6                         // get(nclu->splu): activation staged
MVLOOPCNT count=1
  LDU dst=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_sz=4, be=1}
                                        // for i < 4: LRF2 += 0x80; push(xvu, SP[LRF2])   lines 0x418 ..
IMMCOPY dst=LRF11, typ1a_imm=0x10800    // LRF11 := 0x10800 << 1 = 0x21000 = SP line 0x420
                                        //   = gather band (0x421 ..) minus one line, because LDU adds before it reads
//
// Root only: feed the three sibling partials to the VU, one per NCLU gather.
//   NCLU put one line per sibling:  SP 0x421 = partial(DNC 1), 0x422 = partial(DNC 2), 0x423 = partial(DNC 3)
//   The VU accumulates a 4-line tile (uc.degree=4: 4 FIFO pops per step), so each step must push 4 lines.
//   SPLU therefore reads a 4-line window that starts at sibling j's line and slides by ONE line per step:
//     step 1: lines 0x421 .. 0x424    step 2: 0x422 .. 0x425    step 3: 0x423 .. 0x426
//   Line 0 of each window (VU acc[0], output row 0) is the right partial. Lines 1..3 land in acc[1..3],
//   the unused rows of the 4-row tile, which NCSU never stores (it writes one line). (inferred, not confirmed)
SYNC typ1_imm=6                         // get(nclu->splu): NCLU has put partial(DNC 1) in SP 0x421
MVLOOPCNT count=1
  LDU dst=VU, src0=LRF11, src1=LRF10 {burst=1, burst_sz=4}
                                        // burst=1 enables the burst, burst_sz=4 repeats 4 times:
                                        //   for i < 4: LRF11 += LRF10 (0x80); push(vu, SP[LRF11])
                                        //   reads lines 0x421, 0x422, 0x423, 0x424; ends with LRF11 = 0x21200 (line 0x424)
  MODLRFIMM dst=LRF11, typ1a_imm=0x1fff40 {be=1}
                                        // MODLRFIMM: LRF[dst] := LRF[dst] + (imm << 1)
                                        //   imm = 0x1fff40 is -0xc0 in 21-bit two's complement, so (imm << 1) = -0x180 = -3 lines
                                        //   LRF11 := 0x21200 - 0x180 = 0x21080 (line 0x421)
                                        //   net per step: +4 lines (burst) - 3 lines = +1 line -> next window starts at 0x422
SYNC typ1_imm=6                         // get(nclu->splu): partial(DNC 2) is in SP 0x422
MVLOOPCNT count=1
  LDU dst=VU, src0=LRF11, src1=LRF10 {burst=1, burst_sz=4}
                                        //   reads lines 0x422 .. 0x425
  MODLRFIMM dst=LRF11, typ1a_imm=0x1fff40 {be=1}
                                        //   back 3 lines -> LRF11 = line 0x422 -> next window at 0x423
SYNC typ1_imm=6                         // get(nclu->splu): partial(DNC 3) is in SP 0x423
MVLOOPCNT count=1
  LDU dst=VU, src0=LRF11, src1=LRF10 {burst=1, burst_sz=4, be=1}
                                        //   reads lines 0x423 .. 0x426 (last step, no rewind)
RETURN
RETURN
RETURN
RETURN
MODLRFREG dst=LRF0

// =================================================================================================
// XVU (col 5): SPLU -> TU north (kernel) and SPLU -> ABSU (activation)
// =================================================================================================
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
                                        // push(tu.N, pop(splu) op 0)    pass 64 kernel lines through ?
    MVLOOPCNT count=1
      MVLOOPCNT count=1
        MVLOOPCNT count=4
          LOGICAL out_ab=1, src0=FIFO_SPLU, src1=FIFO_SPLU, src2=CONST0 {slice_en=0xff, be=1}
                                        // push(absu, pop(splu) op 0)    pass 4 activation lines ?
                                        // 4 = Tr, the systolic drain atom (foundation.r100 HWSpec.tr = 4): the feed is
                                        // m_rows padded to Tr (emit_splu "feed_rows"). Here m_rows = 1, so line 0 is
                                        // x[m, 64k..64k+63] and lines 1..3 are padding rows read from SP 0x419..0x41b.
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN {be=1, fill=0x3700000000}

// =================================================================================================
// ABSU (col 0): XVU -> AB bank
// =================================================================================================
.text_absu
.target 0x90
.place col=0 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x3f0 0x10                         // LRF0 = AB write address, LRF1 = AB stride
// num_insts = 16
MVLOOPCNT count=1                       // five 1-trip frame loops (batch, row, Cout, pass, …)
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          LDSTU src1=LRF1 {burst=1, burst_sz=4}
                                        // for i < 4: LRF0 += LRF1; AB[LRF0] := pop(xvu)      (4 activation beats)
          SYNC typ1_imm=1 {be=1}        // put(absu->ablu): bank written
        NOP {be=1}
      SYNC typ1_imm=2                   // get(ablu->absu): bank consumed (swap barrier)
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
MODLRFREG dst=LRF0                      // IBUFF fill, not executed
MODLRFREG dst=LRF0

// =================================================================================================
// ABLU (col 1): AB bank -> TU west
// =================================================================================================
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
      SYNC typ1_imm=1                   // get(absu->ablu): bank written
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          SYNC typ1_imm=2               // put(ablu->absu): bank may be reused
          LDSTU src1=LRF15 {burst=1, burst_sz=4, ld_type=1, ld_splat=1}
                                        // for i < 4: LRF0 += LRF15; W := splat(AB[LRF0])   ?
          LDSTU src0=LRF4, src1=LRF15 {burst=1, burst_sz=4, ld_type=1, ld_splat=1, be=1}
                                        // for i < 4: LRF4 += LRF15; W := splat(AB[LRF4])   ?
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0

// =================================================================================================
// TU row 0 (col 0): top of the 8-row systolic column. Rows 1..7 follow the same program (see below).
// =================================================================================================
.text_tu
.target 0x81
.place col=0 line=33
.spr 0xff21ff
// num_insts = 20
MVLOOPCNT count=1
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA lrf_tgt=LRF0, src0=15, src1=13, src2=3 {uc.degree=8, uc.lrf_dst_inc=1}
                                        // X=0, Y=N, Z=1.0  ->  for i < 8: LRF[i] := pop(N)
                                        // latch this row's 8 kernel lines (w[64k + 8r + i, :])
      MVLOOPCNT count=56
        FMA south_tgt=src0, src0=13, src1=15, src2=3 {be=1}
                                        // S := pop(N)   pass kernel lines down to rows 1..7 (7 x 8 = 56)
      MVLOOPCNT count=1
        MVLOOPCNT count=1
          FMA lrf_tgt=LRF8, east_tgt=src2, src0=0, src1=15, src2=2 {run_mode=2, uc.degree=4, uc.lrf_dst_inc=1}
                                        // run_mode=2: 4-term dot.  for j < 4:
                                        //   z := pop(W);  E := z
                                        //   LRF[8+j] := sum_{i<4} LRF[i] * z_i + 0          (row 0: Y = 0)
          FMA south_tgt=RESULT, east_tgt=src2, src0=4, src1=8, src2=2 {run_mode=2, uc.degree=4, uc.src1_inc=1, be=1}
                                        //   z := pop(W);  E := z
                                        //   S := sum_{i<4} LRF[4+i] * z_i + LRF[8+j]         (8-term partial over K)
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN
OPC_0x0 <unknown-opc>                   // IBUFF fill
OPC_0x0 <unknown-opc>

// TU rows 1..7 (cols 1..7) are the same 20 instructions with two differences:
//   * the pass-down loop count is 8 * (7 - r): 48, 40, 32, 24, 16, 8, and row 7 has none
//   * the first compute FMA reads src1=13 (Y := pop(N), the partial from the row above) instead of 15 (0)
//   Row 7's south output leaves the TU and enters the VU FIFO: 4 lines of  sum over this DNC's 64 K.

// =================================================================================================
// VU (col 4): accumulate. acc = local TU partial, then + each sibling partial; store after each step.
// =================================================================================================
.text_vu
.target 0x82
.place col=4 line=0
.spr 0xff11ff
.lccr 0xbe003e00410040003c000000        // CONST0..5 = 0, 0.5, 2.0, 3.0, 1.0, -1.0 (dlf16, low 16 bits first)
.lrf_idx 0 0xc 0xd 0xf
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0x7fff7fff7fff7fff7fff7fff7fff7fff
// num_insts = 24
FCMP src0=LRF0, src1=FIFO_SPLU, src2=CONST0 {slice_en=0xff}
                                        // flag := cmp(LRF0, CONST0); src1=1 is a mode immediate, shown as a class ?
IMMCOPY dst=LRF12, typ1_imm=0x3e00 {replica=1, slice_en=0xff}   // LRF12 := 1.0
MVLOOPCNT count=1
  IMMCOPY dst=LRF4 {replica=1, slice_en=0xff}                   // acc[0..3] := 0   (LRF4..7)
  IMMCOPY dst=LRF5 {replica=1, slice_en=0xff}
  IMMCOPY dst=LRF6 {replica=1, slice_en=0xff}
  IMMCOPY dst=LRF7 {replica=1, slice_en=0xff}
  MVLOOPCNT count=1
    MVLOOPCNT count=1
      FMA dst=LRF4, src0=FIFO_TU, src1=CONST4, src2=LRF4 {uc.degree=4, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
                                        // for j < 4: LRF[4+j] := pop(tu) * 1.0 + LRF[4+j]     acc += local partial
    FMA sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {uc.degree=4, uc.src0_inc=1, slice_en=0xff}
                                        // for j < 4: push(spsu, LRF[4+j] * 1.0 + 0)           store 1
    MVLOOPCNT count=1
      FMA dst=LRF4, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {uc.degree=4, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
                                        // for j < 4: LRF[4+j] += pop(splu)                    acc += sibling 1
    FMA sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {uc.degree=4, uc.src0_inc=1, slice_en=0xff}
                                        //                                                     store 2
    MVLOOPCNT count=1
      FMA dst=LRF4, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {uc.degree=4, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
                                        //                                                     acc += sibling 2
    FMA sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {uc.degree=4, uc.src0_inc=1, slice_en=0xff}
                                        //                                                     store 3
    MVLOOPCNT count=1
      FMA dst=LRF4, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {uc.degree=4, uc.src2_inc=1, uc.lrf_dst_inc=1, slice_en=0xff, be=1}
                                        //                                                     acc += sibling 3
    FMA sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {uc.degree=4, uc.src0_inc=1, slice_en=0xff}
                                        //                                                     store 4 = final sum
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN {be=1, fill=0x3700000000}

// =================================================================================================
// SPSU (col 2): VU FIFO -> SP psum band. Root stores 4 times (local, then after each gather).
// =================================================================================================
.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 1 3 0xf
.lrf 0x20c00 0x20d00 0x80               // LRF1 = band base - 1 line (0x20c00 = line 0x418), LRF3, LRF15 = 1 line
// num_insts = 32
IMMCOPY dst=LRF3, typ1a_imm=0x10680     // LRF3 := 0x20d00
IMMCOPY dst=LRF1, typ1a_imm=0x10600     // LRF1 := 0x20c00
MVLOOPCNT count=1                       // store 1: the local partial
  LRFREGCOPY dst=LRF0, src1=LRF1        //   LRF0 := LRF1
  MVLOOPCNT count=1
    STU src1=LRF15, src=FIFO_VU {burst=1, burst_sz=4, be=1}
                                        //   for i < 4: LRF0 += 0x80; SP[LRF0] := pop(vu)   -> lines 0x419 .. 0x41c
  SYNC typ1_imm=9 {be=1}                //   put(spsu->ncsu): store done
IMMCOPY dst=LRF1, typ1a_imm=0x10600     // stores 2..4: same band again (last write wins = final sum)
MVLOOPCNT count=1
  LRFREGCOPY dst=LRF0, src1=LRF1
  MVLOOPCNT count=1
    STU src1=LRF15, src=FIFO_VU {burst=1, burst_sz=4, be=1}
  SYNC typ1_imm=9 {be=1}
IMMCOPY dst=LRF1, typ1a_imm=0x10600
MVLOOPCNT count=1
  LRFREGCOPY dst=LRF0, src1=LRF1
  MVLOOPCNT count=1
    STU src1=LRF15, src=FIFO_VU {burst=1, burst_sz=4, be=1}
  SYNC typ1_imm=9 {be=1}
IMMCOPY dst=LRF1, typ1a_imm=0x10600
MVLOOPCNT count=1
  LRFREGCOPY dst=LRF0, src1=LRF1
  MVLOOPCNT count=1
    STU src1=LRF15, src=FIFO_VU {burst=1, burst_sz=4, be=1}
  SYNC typ1_imm=9 {be=1}
MODLRFIMM dst=LRF3, typ1a_imm=0xc0      // LRF3 += 0x180 (next tile; unused at one tile)
RETURN
RETURN
RETURN
RETURN
MODLRFREG dst=LRF0
MODLRFREG dst=LRF0

// =================================================================================================
// NCSU (col 6): SP -> SHM. Root: absorb 4 store-dones, release the loader credit after the first,
//               store the final line, fence with NCLU.
// =================================================================================================
.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 8
.lrf 0x10000000000010000 0x8010f00000000
                                        // LRF0: SBR = 1, CBR = 1  (the per-line strides STSU adds)
                                        // LRF8: CAR = 0x8010f     (out line 0x110 - 1)
// num_insts = 20
MVLOOPCNT count=1
  CARREGCOPY src0=9, src1=8             // CAR9  := CAR8
  CARREGCOPY src0=0xb, src1=9           // CAR11 := CAR9
  CARREGCOPY src0=0xc, src1=9           // CAR12 := CAR9
  SXRIMM src0=0xb, typ1ac_imm=0x418     // SAR11 := 0x418   (psum line - 1)
  SXRIMM src0=0xc, typ1ac_imm=0x418     // SAR12 := 0x418
  SYNC typ1ac_imm=0x22                  // get(spsu0->ncsu): store 1 (local partial) done
  SYNC typ1ac_imm=5                     // put(ncsu->nclu): credit, NCLU may start gathering
  SYNC typ1ac_imm=0x22                  // get: store 2 done
  SYNC typ1ac_imm=0x22                  // get: store 3 done
  MVLOOPCNT count=1
    SYNC typ1ac_imm=0x22                // get: store 4 (final sum) done
    STSU src0=0xb, src2=0xb {burst=1}   // SAR11 += SBR0; CAR11 += CBR0;  SHM[CAR11] := SP[SAR11]
                                        //   = SHM[0x110] := SP[0x419]    out[m=0, :]
    ADDCXRIMM src0=0xb                  // CAR11 += 0
    ADDCXRIMM src0=0xc {be=1}           // CAR12 += 0
  SYNC typ1ac_imm=5                     // put(ncsu->nclu)
  ADDCXRIMM src0=8, typ1ac_imm=1 {be=1} // CAR8 += 1
SYNC typ1ac_imm=7                       // put+get(ncsu<->nclu): fence (NC protocol frame)
RETURN
RETURN

// =================================================================================================
// leaf (DNC 1: m = 0, k = 1) differs from the root in four places
// =================================================================================================
//   NCLU  descriptors point at its own chunks: kernel SHM 0x50 (w chunk 1), x SHM 0x4.
//         No gather and no MESYNC pairs; it ends with  SYNC 0xb (fence)  and  MESYNC 0x17
//         (mput+mget(0.NCLU): hand-off with its root).
//   VU    only the local step: acc := tu partial; push(spsu).   (16 instructions)
//   SPSU  one store of 4 lines, with put(spsu->splu) credits around it.
//   NCSU  SYNC 0x22 (store done); STSU writes SP[0x419] -> SHM[0x114] (partial scratch for the root);
//         MESYNC 0x17 (signal the root); SYNC 5; fence SYNC 7.
//
// Open points in these comments
//   * The 4-line moves (uc.degree=4, burst_sz=4) are the Tr = 4 row tile: emit_splu pads the fed rows to the
//     drain atom Tr (foundation.r100 HWSpec.tr = 4). With one real row per DNC, rows 1..3 are padding.
//   * LDSTU ld_type/ld_splat, LOGICAL's op on the XVU pass-through, and the FCMP mode field.

