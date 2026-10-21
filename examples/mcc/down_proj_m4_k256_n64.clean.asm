// Llama down_proj: out[M, N] = x[M, K] @ w[K, N],  M=4 K=256 N=64, dlf16.  DNC 0 (root), cleaned.
// The same program as down_proj_m4_k256_n64.asm with dead and redundant instructions removed; that file carries
// the full analysis (layouts, ISA checks, timeline). Complete cleaned code: down_proj_m4_k256_n64.dnc0.clean.asm
// (root) and .dnc1.clean.asm (leaf). TU rows 1..7 are summarized, so this file does not reassemble.
//
// Removed
//   * 1-trip MVLOOPCNT frames (the loop line and its closing be=1 or NOP)
//   * NCLU: the fixed skeleton's cursor writes (CAR2/5/6/7/9/10/11/13/15, SAR2/5/6/13/15), the JCR writes, and the
//     CAR0 += 64 / -= 64 tile bump, which nets to zero with no read after it
//   * SPLU/SPSU: IMMCOPYs that rewrite a register's own .lrf value, copies into LRF5/LRF8 that nothing reads, and the
//     SPSU LRF3 next-tile cursor
//   * VU: FCMP with no target, LRF12 := 1.0, and the acc zeroing, folded into the first accumulate (src2=CONST0)
//   * root: VU -> SPSU stores 2 and 3 and their syncs; store 4 overwrites them before NCSU reads SP
//   * leaf: SPLU -> VU pushes the leaf VU never pops, with their self_spsu / self_splu syncs
//   * .lrf entries no instruction reads, and the trailing RETURNs
// Checked on the VP (260521_vp_rebel_evt1_arbcal): cleaning all 16 DNCs the same way leaves the final SHM bit-identical,
// on a rebuild of this commit with the same addresses and structure (1804 -> 1772 cycles) and on a later mcc build
// (1867 -> 1849 cycles).
//
// ── One DNC (d = 4m + k): partial(m, k) = x[m, 64k:+64] [1,64] @ w[64k:+64, :] [64,64], on a 4-row tile ────────
//   SHM -NCLU-> SP -SPLU-> XVU -> TU north (w, stationary)
//                          XVU -> ABSU -> AB -> ABLU -> TU west (x)
//   TU rows 0..7 (psum south) -> VU -> SPSU -> SP -NCSU-> SHM
//   root (k = 0) also: SHM partials of DNC 4m+1..3 -MESYNC/NCLU-> SP -SPLU-> VU (acc +=), then out[m, :] -> SHM
//
// Notation: R := e register transfer; SP[l], SHM[l] 128 B lines; put/get(a->b) SYNC; mput/mget(d.U) MESYNC.

.arch rebel.evt1

// =================================================================================================
// NCLU: stage w and x into SP, then gather the 3 sibling partials (root)
// =================================================================================================
.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 4 12
.lrf 0x800100000000003d80000 0x801140000000004210000 0x800000000000004180000
                                                  // descriptor 0:  SP 0x3d8 <- SHM 0x10   (w chunk k)
                                                  // descriptor 4:  SP 0x421 <- SHM 0x114  (sibling partials)
                                                  // descriptor 12: SP 0x418 <- SHM 0x0    (x[m, 64k:+64])
MVLOOPCNT immediate=2
  LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {be=1}
                                                  // 2 x 32 lines: SP 0x3d8..0x417 := w[64k .. 64k+63, :]
SYNC {dir.put=1, lsync_mask.splu0=1}              // put(nclu->splu): w staged
LDMU src0=SAR12, src1=SBR12, src2=CAR12, src3=CBR12 {burst=1}
                                                  // SP 0x418 := x[m, 64k .. 64k+63]
SYNC {dir.put=1, lsync_mask.splu0=1}              // put(nclu->splu): x staged
SYNC {dir.get=1, lsync_mask.ncsu=1}               // get(ncsu->nclu): credit after store 1
MESYNC {dir.get=1, sync_mask.dnc1=1, sync_mask.ncsu=1}
                                                  // mget(1.NCSU): DNC 1's partial is in SHM
LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                                  // SP 0x421 := SHM 0x114 = partial(m, 1)
SYNC {dir.put=1, lsync_mask.splu0=1}
MESYNC {dir.put=1, sync_mask.dnc1=1, sync_mask.ncsu=1}
                                                  // mput(1.NCSU): taken, DNC 1 may finish
MESYNC {dir.get=1, sync_mask.dnc2=1, sync_mask.ncsu=1}
LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                                  // SP 0x422 := SHM 0x115 = partial(m, 2)
SYNC {dir.put=1, lsync_mask.splu0=1}
MESYNC {dir.put=1, sync_mask.dnc2=1, sync_mask.ncsu=1}
MESYNC {dir.get=1, sync_mask.dnc3=1, sync_mask.ncsu=1}
LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                                  // SP 0x423 := SHM 0x116 = partial(m, 3)
SYNC {dir.put=1, lsync_mask.splu0=1}
MESYNC {dir.put=1, sync_mask.dnc3=1, sync_mask.ncsu=1}
SYNC {dir.get=1, lsync_mask.ncsu=1}               // get(ncsu->nclu): out[m, :] stored
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}    // fence with NCSU
MESYNC {dir.get=1, sync_mask.dnc7=1, sync_mask.dnc6=1, sync_mask.dnc5=1, sync_mask.dnc4=1, sync_mask.dnc3=1, sync_mask.dnc2=1, sync_mask.dnc1=1, sync_mask.dnc0=1, sync_mask.nclu=1}
                                                  // mget(0..7.NCLU): cluster 0 done
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc8=1, sync_mask.nclu=1}
                                                  // exchange with cluster 1's head
MESYNC {dir.put=1, sync_mask.dnc7=1, sync_mask.dnc6=1, sync_mask.dnc5=1, sync_mask.dnc4=1, sync_mask.dnc3=1, sync_mask.dnc2=1, sync_mask.dnc1=1, sync_mask.dnc0=1, sync_mask.nclu=1}
                                                  // mput(0..7.NCLU): release cluster 0
RETURN

// =================================================================================================
// SPLU: SP -> XVU (w, then x), SP -> VU (sibling partials, root)
// =================================================================================================
.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 2 10
.lrf 0x1eb80 0x20b80 0x80                         // LRF0 = w base - 1 line, LRF2 = x base - 1 line, LRF10 = 1 line
SYNC {dir.get=1, lsync_mask.nclu=1}               // get(nclu->splu): w staged
MVLOOPCNT immediate=0x40
  LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=1, be=1}
                                                  // for q < 64: LRF0 += 0x80; push(xvu, SP[0x3d8 + q])
SYNC {dir.get=1, lsync_mask.nclu=1}               // get(nclu->splu): x staged
LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=4}
                                                  // for t < 4: push(xvu, SP[0x418 + t])   t = 0 is x, 1..3 stale padding
IMMCOPY src0=LRF11, immediate=0x10800             // LRF11 := line 0x420 (gather band - 1 line)
SYNC {dir.get=1, lsync_mask.nclu=1}               // partial(m, 1) in SP 0x421
LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4}
                                                  // push(vu, SP[0x421 .. 0x424]): a 4-line window, line 0 = partial
MODLRFIMM src0=LRF11, immediate=0x1fff40          // LRF11 -= 3 lines: the next window starts one line later
SYNC {dir.get=1, lsync_mask.nclu=1}               // partial(m, 2) in SP 0x422
LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4}
MODLRFIMM src0=LRF11, immediate=0x1fff40
SYNC {dir.get=1, lsync_mask.nclu=1}               // partial(m, 3) in SP 0x423
LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4}
RETURN

// =================================================================================================
// XVU: pass lines through; w -> TU north, x -> ABSU  (LOGICAL OR with CONST0 = 0, forwarding X unchanged)
// =================================================================================================
.text_xvu
.target 0x84
.place col=5 line=0
.spr 0x70ff21ff
.lccr 0xbe003e00410040003c000000 0xbf803f80404040003f000000
MVLOOPCNT immediate=0x40
  LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=NONE, tu_tgt=src0, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
                                                  // push(tu.N, pop(splu))   w[64k + q, :], q < 64
MVLOOPCNT immediate=4
  LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=src0, tu_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
                                                  // push(absu, pop(splu))   4-row x tile
RETURN

// =================================================================================================
// ABSU: XVU -> AB, one 128 B line split into 16 B for each TU row's 1 KB region
// =================================================================================================
.text_absu
.target 0x90
.place col=0 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x3f0 0x10                                   // LRF0 = -0x10 (10-bit), LRF1 = 0x10
STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}
                                                  // for t < 4: LRF0 += 0x10; AB_r[0x10*t + 2i] := line_t[8r + i]
SYNC {dir.put=1}                                  // put(absu->ablu): AB written
SYNC {dir.get=1}                                  // get(ablu->absu): AB consumed
RETURN

// =================================================================================================
// ABLU (one per TU row r): AB_r -> TU west, 8 B read and replicated to 16 B
// =================================================================================================
.text_ablu
.target 0x88
.place col=1 line=0
.spr 0xff01ff
.lrf_idx 0 4 15
.lrf 0x3f0 0x3f8 0x10                             // LRF0 = -0x10 (lanes 0..3), LRF4 = -0x08 (lanes 4..7), LRF15 = 0x10
SYNC {dir.put=1}                                  // put(ablu->absu): AB may be reused
SYNC {dir.get=1}                                  // get(absu->ablu): AB written
LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
                                                  // for t < 4: Z := (a, a), a = AB_r[0x10*t, +8 B) = x[t][8r + 0..3]
LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
                                                  // for t < 4: Z := (a, a), a = AB_r[0x10*t + 8, +8 B) = x[t][8r + 4..7]
RETURN

// =================================================================================================
// TU row 0: latch 8 w rows, pass 56 south, then an 8-K dot product per tile row t
// =================================================================================================
.text_tu
.target 0x81
.place col=0 line=33
.spr 0xff21ff
FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
                                                  // for i < 8: LRF[i] := pop(N) = w[64k + i, :]
MVLOOPCNT immediate=0x38
  FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
                                                  // S := pop(N)   pass 56 w lines to rows 1..7
FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=#0, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
                                                  // for t < 4: Z := pop(W); E := Z
                                                  //   LRF[8+t] := sum_{i<4} LRF[i] * Z_i + 0           (rows 1..7: + pop(N))
FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1}
                                                  //   S := sum_{i<4} LRF[4+i] * Z_i + LRF[8+t]         -> row 1
RETURN
// TU rows 1..7 (cols 1..7) run the same code, passing 48, 40, .., 8, 0 w lines, with the first dot product's
// src1=FIFO_NORTH (the row above's partial). Row 7's south output, 4 lines, is this DNC's sum over its 64 K.

// =================================================================================================
// VU: acc[t] := TU sum, store 1; root: acc += 3 sibling partials, store 4 (final)
// =================================================================================================
.text_vu
.target 0x82
.place col=4 line=0
.spr 0xff11ff
.lccr 0xbe003e00410040003c000000                  // CONST0 = 0, CONST4 = 1.0
FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=CONST0 {unroll_control.lrf_tgt=1, unroll_control.degree=2}
                                                  // for t < 4: LRF[4+t] := pop(tu) * 1.0 + 0        acc[t] := S_7[t]
FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
                                                  // for t < 4: push(spsu, acc[t])                   store 1
FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2}
                                                  // acc[t] += pop(splu)   partial(m, 1) in t = 0
FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2}
                                                  // acc[t] += pop(splu)   partial(m, 2)
FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2}
                                                  // acc[t] += pop(splu)   partial(m, 3)
FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
                                                  // push(spsu, acc[t])                              store 4 = out[m, :] in t = 0
RETURN

// =================================================================================================
// SPSU: VU -> SP 0x419..0x41c, twice (store 1, store 4)
// =================================================================================================
.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 1 15
.lrf 0x20c00 0x80                                 // LRF1 = psum band - 1 line (0x418), LRF15 = 1 line
LRFREGCOPY src0=LRF0, src1=LRF1                   // LRF0 := LRF1
STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4}
                                                  // for t < 4: LRF0 += 0x80; SP[LRF0] := pop(vu)   store 1 -> 0x419..0x41c
SYNC {dir.put=1, lsync_mask.ncsu=1}               // put(spsu->ncsu)
LRFREGCOPY src0=LRF0, src1=LRF1
STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4}
                                                  // store 4 over the same lines
SYNC {dir.put=1, lsync_mask.ncsu=1}
RETURN

// =================================================================================================
// NCSU: credit NCLU after store 1, write SP 0x419 (t = 0) to out[m, :] after store 4
// =================================================================================================
.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
.lrf_idx 0 8
.lrf 0x10000000000010000 0x8010f00000000          // LRF0: SBR = CBR = 1 (per-line stride), LRF8: CAR = out line - 1
CXRREGCOPY src0=CAR11, src1=CAR8                  // CAR11 := 0x10f
SXRIMM src0=SAR11, immediate=0x418                // SAR11 := psum line - 1
SYNC {dir.get=1, lsync_mask.spsu0=1}              // get(spsu->ncsu): store 1 done
SYNC {dir.put=1, lsync_mask.nclu=1}               // put(ncsu->nclu): credit, NCLU may gather
SYNC {dir.get=1, lsync_mask.spsu0=1}              // get(spsu->ncsu): store 4 done
STSU src0=SAR11, src1=SBR0, src2=CAR11, src3=CBR0 {burst=1}
                                                  // SHM[0x110] := SP[0x419]   out[m, :]
SYNC {dir.put=1, lsync_mask.nclu=1}               // put(ncsu->nclu): stored
SYNC {dir.get=1, dir.put=1, lsync_mask.nclu=1}    // fence with NCLU
RETURN

// =================================================================================================
// leaf (DNC 1: m = 0, k = 1), from down_proj_m4_k256_n64.dnc1.clean.asm
// =================================================================================================
//   NCLU  stages w chunk 1 (SHM 0x50) and x (SHM 0x4), then the fence and
//         MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1} (the cluster barrier leg to DNC 0).
//   SPLU  only the w and x feeds; no sibling partials.
//   VU    acc[t] := S_7[t] and one push: store 1 only.
//   SPSU  one store of 4 lines.
//   NCSU  get(store 1); STSU SHM[0x114] := SP[0x419] (its partial for the root);
//         MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1} (announce it, wait until the root took it);
//         put(ncsu->nclu); fence.
