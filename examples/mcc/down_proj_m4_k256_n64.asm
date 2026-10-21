// Llama down_proj: out[M, N] = x[M, K] @ w[K, N],  M=4 K=256 N=64, dlf16.
// Source:  PrimitiveAuthor/mcc/tests/perf/dense/m4_k256_n64/kernel.py  (mcc build, codesigner dev c1ba98778)
// Syntax:  dnc_binutils new assembly syntax (codesigner origin/dev cb6b13364), converted from the legacy
//          disasm with tools.convert_legacy_asm, which checks that the result assembles back to the same bytes.
// Image:   78848 B over 16 DNCs. This file is DNC 0 (a reduce ROOT), dnc_binutils disasm + hand comments.
//          TU rows 1..7 are summarized, not listed, so this file does not reassemble; the complete
//          unedited disasm of DNC 0 and DNC 1 is in down_proj_m4_k256_n64.dnc0.raw.asm / .dnc1.raw.asm.
//          The leaf DNC 1 differs only where marked "leaf:" at the end.
//
// ══ Overview ══════════════════════════════════════════════════════════════════════════════════════
//
//   16 DNCs = 4 output rows (m) x 4 K chunks (k);  DNC d = 4m + k.
//   DNC d:   partial(m, k)[n] = sum_{q<64} x[m, 64k + q] * w[64k + q, n]        (n < 64)
//   Root d = 4m (k = 0) adds the 3 sibling partials and stores out[m, :].
//
//   Inside one DNC the TU is weight-stationary:
//     w   SHM -NCLU-> SP -SPLU-> XVU ──north──> TU rows 0..7            (stays in TU LRF)
//     x   SHM -NCLU-> SP -SPLU-> XVU -> ABSU -> AB -> ABLU ──west──> TU row r
//     sum TU row r ──south──> row r+1 ... row 7 ──south──> VU -> SPSU -> SP -NCSU-> SHM
//
//   Affine maps of the movement (one DNC; t = beat of the 4-beat row tile, r = TU row, i < 8, h < 2):
//
//   NCLU   SP[0x3d8 + q]       := SHM[0x10 + 64k + q]          = w[64k + q, :]            q < 64
//          SP[0x418]           := SHM[4k + m]                  = x[m, 64k .. 64k+63]
//   XVU    north beat q        := SP[0x3d8 + q]                                           q < 64
//          ABSU beat t         := SP[0x418 + t]                                           t < 4
//          Only t = 0 is data. The feed is padded to the 4-row drain tile (Tr = 4) and this DNC has
//          one row, so t = 1..3 carry whatever is in SP 0x419..0x41b. 3/4 of TU and VU work is padding.
//   ABSU   AB_r[0x10*t + 2*i]  := beat_t[8r + i]                 (= x[m, 64k + 8r + i] at t = 0)
//          One 128 B beat goes to the eight 1 KB AB regions in parallel, 16 B (8 lanes) each.
//          An AB address is a 10-bit byte pointer into one region (1 KB ring), so LRF0 = 0x3f0 is -0x10:
//          mcc writes base - stride (grounding/layouts.py _absu_values: -2*8, +2*8), and the pre-add
//          stride makes the first store land on 0x000. Real byte addresses: t -> 0x000, 0x010, 0x020, 0x030.
//   ABLU   Row r reads only its own region AB_r. Two bursts of 4, t = 0..3:
//          h = 0: AB_r[0x10*t + 0 .. +8)  = beat_t[8r + 0 .. 8r+3]     reads 0x000, 0x010, 0x020, 0x030
//          h = 1: AB_r[0x10*t + 8 .. +8)  = beat_t[8r + 4 .. 8r+7]     reads 0x008, 0x018, 0x028, 0x038
//          (LRF0 = 0x3f0 = -0x10, LRF4 = 0x3f8 = -0x08, stride LRF15 = 0x10; the stride is added first.)
//          load_type=1 loads 8 B (4 dlf16); replicate=1 duplicates them across the 16 B to the TU, so
//          both 4-lane halves of each 8-lane TU slice see the same 4 values: west Z = (a, a).
//          mcc's layout for this edge is [M=1:1λ K.grp=8:8L K.in=8:-1L]: K.in is reversed for the TU west
//          convention. How that matches the FMA's Z element order is not decoded here.
//   TU     row r, 64 N lanes:
//          prime  LRF[i]   := w[64k + 8r + i, :]       first 8 north beats; the next 56 - 8r go south
//          mac    LRF[8+t] := sum_{i<4}  LRF[i]   * Z_i + Y     Y = 0 on row 0, north link (row r-1) otherwise
//          drain  S[t]     := sum_{i<4}  LRF[4+i] * Z_i + LRF[8+t]
//          east   E        := Z                         x moves east to the next 8-lane slice
//          =>     S_r[t] = S_{r-1}[t] + sum_{i<8} w[64k + 8r + i, :] * beat_t[8r + i]
//          row 7: S_7[0] = partial(m, k)                (dlf18 inside the TU, dlf16 out of the last row)
//   VU     acc[t] (LRF4+t) := S_7[t]; root then acc[t] += sibling 1, 2, 3 (from SPLU)
//   SPSU   SP[0x419 + t]    := acc[t]
//   NCSU   root: SHM[0x110 + m] := SP[0x419]        leaf (m, k): SHM[0x113 + 3m + k] := SP[0x419]
//
//   Checked against the ISA doc (isa_documentations, REBEL/EVT1: ABSU/STU, ABLU/LDU, TU/FMA):
//     * ABSU STU: addr = LRF[src0] + LRF[src1] before the store; eight 1 KB regions written in parallel,
//       16 B each; address bits [9:4]. Which 16 B of the beat goes to which region is not stated;
//       chunk r -> region r (TU row r) is assumed above.
//     * ABLU LDU: each ABLU has its own 1 KB region and outputs 16 B to its TU row; load_type=1 is 8 B;
//       replicate=1 duplicates the loaded data across 16 B; address bits [3:1] pick the 8 B slice.
//     * TU FMA: Result = sum(Xi * Zi) + Y, N-element dot product (here N = 4, written src0=LRF[0:3]);
//       east_tgt=src2 sends Z to the East link; south_tgt=RESULT sends the result south.
//       (The doc's src0 table still reads src0 as a group index; the VP uses the first register,
//       which is what LRF[0:3] / LRF[4:7] mean here.)
//
// ── Root reduce timeline (DNC 0) ──────────────────────────────────────────────────────────────────
//   Units run concurrently; the order below is what the SYNC / MESYNC / FIFO dependencies force.
//   A  NCLU  LDMU src0=SAR0, .. x2 ; SYNC {dir.put=1, lsync_mask.splu0=1}     w -> SP 0x3d8..0x417
//      SPLU  SYNC {dir.get=1, lsync_mask.nclu=1} ; LDU consumer=XVU, .. x64    w -> XVU -> TU north
//      NCLU  LDMU src0=SAR12, .. ; SYNC put -> splu0                          x -> SP 0x418
//      SPLU  LDU consumer=XVU, src0=LRF2, .. {burst_size=4}                   SP 0x418..0x41b -> XVU -> ABSU
//   B  VU    FMA lrf_tgt=LRF4, src0=FIFO_TU, src1=CONST4, src2=LRF4 {..}      acc[t] := 0 + S_7[t]
//      VU    FMA sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {..}      store 1
//      SPSU  STU producer=VU, .. {burst_size=4} ; SYNC {dir.put=1, lsync_mask.ncsu=1}   SP 0x419..0x41c
//      NCSU  SYNC {dir.get=1, lsync_mask.spsu0=1} ; SYNC {dir.put=1, lsync_mask.nclu=1}  credit: NCLU may gather
//   C  for j = 1, 2, 3:
//      leaf  NCSU STSU .. ; MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1}
//                                                                             DNC j: SP 0x419 -> SHM 0x113+3m+j, tell root
//      NCLU  SYNC {dir.get=1, lsync_mask.ncsu=1}                              credit (once, before j = 1)
//      NCLU  MESYNC {dir.get=1, sync_mask.dncj=1, sync_mask.ncsu=1}            leaf j's partial is in SHM
//      NCLU  LDMU src0=SAR4, .. {burst=1} ; SYNC put -> splu0                 SHM 0x113+3m+j -> SP 0x420+j
//      NCLU  MESYNC {dir.put=1, sync_mask.dncj=1, sync_mask.ncsu=1}            release leaf j
//      SPLU  SYNC get <- nclu ; LDU consumer=VU, src0=LRF11, .. {burst_size=4} ; MODLRFIMM -3 lines
//      VU    FMA lrf_tgt=LRF4, src0=FIFO_SPLU, .. {..}                         acc[0] += partial(m, j)
//      VU    FMA sp_tgt=RESULT, ..  ->  SPSU STU ; SYNC put -> ncsu  ->  NCSU SYNC get    store j+1
//                                                                             (stores 2, 3 are never read)
//   D  NCSU  SYNC get <- spsu0 (store 4) ; STSU src0=SAR11, .. ; SYNC put -> nclu   SP 0x419 -> SHM 0x110+m
//      NCLU  SYNC {dir.get=1, lsync_mask.ncsu=1}
//   E  NCLU <-> NCSU  SYNC {dir.get=1, dir.put=1, ..}                          fence inside the DNC
//      NCLU  MESYNC get dnc0..7 ; MESYNC get+put dnc8 ; MESYNC put dnc0..7     cluster barrier
//   A leaf runs A and B, then stores its partial (C, "leaf" lines) and joins E.
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
//        partial line 0x113 + 3m + k    (leaf (m, k) scratch, k = 1..3; root m reads 0x114+3m .. +2)
//   SP   kernel  lines 0x3d8 .. 0x417   (64 lines)
//        x       line  0x418            (ab_bank)
//        psum    line  0x419 ..         (VU result band)
//        gather  line  0x421 ..         (root: sibling partials land here)
//   AB   row r   AB_r lines 0 .. 3      (16 B per line: x[m, 64k + 8r .. +7], then 3 padding lines)
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
// ── Notation in comments ──────────────────────────────────────────────────────────────────────────
//   R := e          register transfer;  SP[l], SHM[l] are 128 B lines;  N/W/S/E are the TU links
//   put(a->b), get(a->b)   SYNC on the counting channel a->b (+1 / wait > 0 then -1)
//   mput(d.U), mget(d.U)   MESYNC to/from unit U of DNC d
//   SP-unit LRF holds byte addresses: IMMCOPY/MODLRFIMM immediates are <<1; LDU/STU add the stride first.
//   "?" marks a reading not confirmed against the ISA doc.
//
// Units are listed in dataflow order, starting at NCLU: NCLU -> SPLU -> XVU -> ABSU -> ABLU -> TU -> VU -> SPSU -> NCSU.
// All units start together and run concurrently; the order is the data dependency, and FIFOs/SYNCs enforce it.

.arch rebel.evt1

// =================================================================================================
// NCLU (col 7): SHM -> SP. Stage kernel + activation, then (root) gather the 3 sibling partials.
// =================================================================================================
.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14
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
JIMMCOPY jcr_tgt=JCR14, immediate=1               // JCR14 := 1
CXRIMM src0=CAR15, immediate=0                    // CAR15 := 0                       dead
MVLOOPCNT immediate=1
  SXRIMM src0=SAR15, immediate=0                  // SAR15 := 0                       dead
  CXRREGCOPY src0=CAR5, src1=CAR3                 // CAR5  := CAR3 = 0x7ffff          dead (skeleton cursor)
  CXRREGCOPY src0=CAR6, src1=CAR3                 // CAR6  := CAR3 = 0x7ffff          dead
  CXRREGCOPY src0=CAR2, src1=CAR0                 // CAR2  := CAR0 = 0                dead
  CXRREGCOPY src0=CAR9, src1=CAR7                 // CAR9  := CAR7 = 0xfffff (-1)     dead
  CXRREGCOPY src0=CAR10, src1=CAR7                // CAR10 := CAR7                    dead
  CXRREGCOPY src0=CAR13, src1=CAR11               // CAR13 := CAR11 = 0               dead
  SXRIMM src0=SAR2, immediate=0                   // SAR2  := 0                       dead
  SXRIMM src0=SAR5, immediate=0x417               // SAR5  := 0x417 (x band - 1 line) dead
  SXRIMM src0=SAR6, immediate=0x417               // SAR6  := 0x417                   dead
  SXRIMM src0=SAR13, immediate=0                  // SAR13 := 0                       dead
  JIMMCOPY jcr_tgt=JCR4, immediate=0              // JCR4 := 0
  JIMMCOPY jcr_tgt=JCR4, immediate=1              // JCR4 := 1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=2
        // [64, 64] weight tile to SP
        LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {be=1}
                                                  // SP[0x3d8 + SAR0 ..+32] := SHM[0x10 + CAR0 ..+32]; SAR0 += 32; CAR0 += 32
                                                  // trip 1: w[0..31, :] -> SP 0x3d8..0x3f7;  trip 2: w[32..63, :] -> SP 0x3f8..0x417
      SYNC {dir.put=1, lsync_mask.splu0=1}        // put(nclu->splu0): kernel staged
      // [1, 64] x tile to SP
      LDMU src0=SAR12, src1=SBR12, src2=CAR12, src3=CBR12 {burst=1}
                                                  // SP[0x418 + SAR12] := SHM[0 + CAR12]; SAR12 += 1; CAR12 += 1
                                                  //   = SP 0x418 := x[m=0, 0..63]
      SYNC {dir.put=1, lsync_mask.splu0=1}        // put(nclu->splu0): activation staged
      ADDCXRIMM src0=CAR5, immediate=0xffffd      // CAR5 += -3                    dead
      ADDCXRIMM src0=CAR6, immediate=0xffffd      // CAR6 += -3                    dead
      NOP {be=1}
    JIMMCOPY jcr_tgt=JCR4, immediate=0            // JCR4 := 0
    NOP {be=1}
  JIMMCOPY jcr_tgt=JCR3, immediate=0              // JCR3 := 0
  SYNC {dir.get=1, lsync_mask.ncsu=1}             // get(ncsu->nclu): credit (root has stored its local partial)
  MESYNC {dir.get=1, sync_mask.dnc1=1, sync_mask.ncsu=1}
                                                  // mget(1.NCSU): DNC 1's partial is in SHM
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                                  // SP[0x421 + SAR4] := SHM[0x114 + CAR4]; SAR4 += 1; CAR4 += 1   = SP 0x421 := partial(DNC 1)
  SYNC {dir.put=1, lsync_mask.splu0=1}            // put(nclu->splu0)
  MESYNC {dir.put=1, sync_mask.dnc1=1, sync_mask.ncsu=1}
                                                  // mput(1.NCSU): consumed
  MESYNC {dir.get=1, sync_mask.dnc2=1, sync_mask.ncsu=1}
                                                  // mget(2.NCSU)
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                                  // SAR4 = 1, CAR4 = 1:  SP 0x422 := SHM 0x115 = partial(DNC 2)
  SYNC {dir.put=1, lsync_mask.splu0=1}
  MESYNC {dir.put=1, sync_mask.dnc2=1, sync_mask.ncsu=1}
                                                  // mput(2.NCSU)
  MESYNC {dir.get=1, sync_mask.dnc3=1, sync_mask.ncsu=1}
                                                  // mget(3.NCSU)
  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}
                                                  // SAR4 = 2, CAR4 = 2:  SP 0x423 := SHM 0x116 = partial(DNC 3)
  SYNC {dir.put=1, lsync_mask.splu0=1}
  MESYNC {dir.put=1, sync_mask.dnc3=1, sync_mask.ncsu=1}
                                                  // mput(3.NCSU)
  SYNC {dir.get=1, lsync_mask.ncsu=1}             // get(ncsu->nclu)
  ADDCXRIMM src0=CAR0, immediate=0x40             // CAR0  += 64   next output tile's w chunk (one tile here, so unused)
  ADDCXRIMM src0=CAR11, immediate=1               // CAR11 += 1                                       dead
  ADDCXRIMM src0=CAR7, immediate=1 {be=1}         // CAR7  += 1                                       dead
ADDCXRIMM src0=CAR0, immediate=0xfffc0            // CAR0  += -64  rewind after the tile loop
ADDCXRIMM src0=CAR11, immediate=0xfffff           // CAR11 += -1                                       dead
ADDCXRIMM src0=CAR7, immediate=0xfffff            // CAR7  += -1                                       dead
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}    // put+get(nclu<->ncsu): fence
MESYNC {dir.get=1, sync_mask.dnc7=1, sync_mask.dnc6=1, sync_mask.dnc5=1, sync_mask.dnc4=1, sync_mask.dnc3=1, sync_mask.dnc2=1, sync_mask.dnc1=1, sync_mask.dnc0=1, sync_mask.nclu=1}
                                                  // mget(0..7.NCLU)   cluster barrier: every DNC of cluster 0 is done
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc8=1, sync_mask.nclu=1}
                                                  // mput+mget(8.NCLU) exchange with the other cluster's head
MESYNC {dir.put=1, sync_mask.dnc7=1, sync_mask.dnc6=1, sync_mask.dnc5=1, sync_mask.dnc4=1, sync_mask.dnc3=1, sync_mask.dnc2=1, sync_mask.dnc1=1, sync_mask.dnc0=1, sync_mask.nclu=1}
                                                  // mput(0..7.NCLU)   release cluster 0
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN
RETURN

// =================================================================================================
// SPLU (col 3): SP -> XVU (kernel, activation), SP -> VU (gathered partials, root only)
// =================================================================================================
.text_splu
.target 0xa0
.place col=3 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 9 10 11 12 14 15
.lrf 0x1eb80 0x1eb80 0x20b80 0x20b80 0x20b80 0x20c00 0x20c00 0x3fff81 0x20d00 0x3fff81 0x80 0x3fff81 0x3fff81 0x3fff81 0x20d00
IMMCOPY src0=LRF0, immediate=0xf5c0               // LRF0 := 0x1eb80 = kernel base - 1 line (line 0x3d7)
IMMCOPY src0=LRF3, immediate=0x105c0              // LRF3 := 0x20b80 = x base - 1 line (line 0x417)
LRFREGCOPY src0=LRF2, src1=LRF3                   // LRF2 := LRF3
LRFREGCOPY src0=LRF5, src1=LRF6                   // LRF5 := LRF6
LRFREGCOPY src0=LRF8, src1=LRF15                  // LRF8 := LRF15
SYNC {dir.get=1, lsync_mask.nclu=1}               // get(nclu->splu): kernel staged
MVLOOPCNT immediate=0x40
  LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=1, be=1}
                                                  // LRF0 += 0x80; push(xvu, SP[LRF0])      kernel lines 0x3d8 .. 0x417
SYNC {dir.get=1, lsync_mask.nclu=1}               // get(nclu->splu): activation staged
MVLOOPCNT immediate=1
  LDU consumer=XVU, src0=LRF2, src1=LRF10 {burst=1, burst_size=4, be=1}
                                                  // for t < 4: LRF2 += 0x80; push(xvu, SP[LRF2])   lines 0x418 .. 0x41b
IMMCOPY src0=LRF11, immediate=0x10800             // LRF11 := 0x10800 << 1 = 0x21000 = SP line 0x420
                                                  //   = gather band (0x421 ..) minus one line, because LDU adds before it reads
//
// Root only: feed the three sibling partials to the VU, one per NCLU gather.
//   NCLU put one line per sibling:  SP 0x421 = partial(DNC 1), 0x422 = partial(DNC 2), 0x423 = partial(DNC 3)
//   The VU accumulates a 4-line tile (unroll degree 2 = 4 FIFO pops per step), so each step must push 4 lines.
//   SPLU therefore reads a 4-line window that starts at sibling j's line and slides by ONE line per step:
//     step 1: lines 0x421 .. 0x424    step 2: 0x422 .. 0x425    step 3: 0x423 .. 0x426
//   Line 0 of each window (VU acc[0], output row 0) is the right partial. Lines 1..3 land in acc[1..3],
//   the unused rows of the 4-row tile, which NCSU never stores (it writes one line). (inferred, not confirmed)
SYNC {dir.get=1, lsync_mask.nclu=1}               // get(nclu->splu): NCLU has put partial(DNC 1) in SP 0x421
MVLOOPCNT immediate=1
  LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4}
                                                  // burst=1 enables the burst, burst_size=4 repeats 4 times:
                                                  //   for i < 4: LRF11 += LRF10 (0x80); push(vu, SP[LRF11])
                                                  //   reads lines 0x421, 0x422, 0x423, 0x424; ends with LRF11 = 0x21200 (line 0x424)
  MODLRFIMM src0=LRF11, immediate=0x1fff40 {be=1}
                                                  // MODLRFIMM: LRF[src0] := LRF[src0] + (imm << 1)
                                                  //   imm = 0x1fff40 is -0xc0 in 21-bit two's complement, so (imm << 1) = -0x180 = -3 lines
                                                  //   LRF11 := 0x21200 - 0x180 = 0x21080 (line 0x421)
                                                  //   net per step: +4 lines (burst) - 3 lines = +1 line -> next window starts at 0x422
SYNC {dir.get=1, lsync_mask.nclu=1}               // get(nclu->splu): partial(DNC 2) is in SP 0x422
MVLOOPCNT immediate=1
  LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4}
                                                  //   reads lines 0x422 .. 0x425
  MODLRFIMM src0=LRF11, immediate=0x1fff40 {be=1}
                                                  //   back 3 lines -> LRF11 = line 0x422 -> next window at 0x423
SYNC {dir.get=1, lsync_mask.nclu=1}               // get(nclu->splu): partial(DNC 3) is in SP 0x423
MVLOOPCNT immediate=1
  LDU consumer=VU, src0=LRF11, src1=LRF10 {burst=1, burst_size=4, be=1}
                                                  //   reads lines 0x423 .. 0x426 (last step, no rewind)
RETURN
RETURN
RETURN
RETURN

// =================================================================================================
// XVU (col 5): SPLU -> TU north (kernel) and SPLU -> ABSU (activation). A pure router here: it computes
//              nothing that is used; each LOGICAL pops one line from SPLU and forwards it unchanged.
// =================================================================================================
//
// ── LOGICAL, as the ISA doc (REBEL/EVT1/XVU/LOGICAL) defines it ──────────────────────────────────────
//   X := src0,  Z := src2
//   Result := X op Z          op by immediate: 0 AND, 1 OR, 2 XNOR, 3 AND-NOT, 4..6 bit-field forms
//   for each of vu_tgt / sp_tgt / ab_tgt / tu_tgt:  0 NONE, 1 X, 2 Z, 3 Result  -> pushed to that unit's FIFO
//   lrf_tgt:  write Result to an LRF (NONE here)
//   The disassembler prints target code 1 (X) as "src0" and 3 as "RESULT".
//
// ── Operands used below ──────────────────────────────────────────────────────────────────────────
//   src0=FIFO_SPLU  X := pop(SPLU FIFO), one 128 B line (64 dlf16 lanes, 8 slices x 8 lanes)
//   src2=CONST0     Z := ConstReg16[0] = 0 (first .lccr word, low 16 bits; all slices share it)
//   immediate=1     OR, so Result = X | 0 = X. Result is computed but goes nowhere (every tgt is NONE or X).
//   tu_tgt=src0     push(TU north, X): the line enters TU row 0's north link
//   ab_tgt=src0     push(ABSU, X):     the line enters the ABSU FIFO, which STU pops
//   No slice_enable is printed, so it has its default: all 8 slices (all 64 lanes) move.
//   Forwarding X needs no conversion, so the result is bit-exact whatever the SPR's 16/32-bit mode.
//
// ── .lrf / .lccr ─────────────────────────────────────────────────────────────────────────────────
//   LRF11..14 and the ConstReg values are the image's fixed XVU init packet; only ConstReg16[0] = 0 is
//   read (as Z), and it does not change the forwarded data.
.text_xvu
.target 0x84
.place col=5 line=0
.spr 0x70ff21ff
.lccr 0xbe003e00410040003c000000 0xbf803f80404040003f000000
.lrf_idx 11 12 13 14
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0xccc8c4c0bcb8b0004c4844403c383000
MVLOOPCNT immediate=1                             // 1-trip frame loops (no tiling at this size)
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=0x40                      // for q < 64:
      LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=NONE, tu_tgt=src0, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
                                                  //   X := pop(splu)            = SP[0x3d8 + q] = w[64k + q, 0:64]
                                                  //   push(tu.N, X)             Result = X | 0, discarded
                                                  // TU row 0 keeps beats 0..7 and passes the rest south (see TU).
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=4                     // for t < 4:
          LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=src0, tu_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1, be=1}
                                                  //   X := pop(splu)            = SP[0x418 + t]
                                                  //   push(absu, X)             ABSU STU then writes it to AB line t
                                                  //
                                                  // How lines 1..3 get filled:
                                                  //   * 4 = Tr, the systolic drain tile (foundation.r100 HWSpec.tr = 4). mcc pads the
                                                  //     fed M rows up to Tr (emit_splu "feed_rows"); this DNC has m_rows = 1.
                                                  //   * Nothing writes padding. SPLU just reads 4 consecutive SP lines with one
                                                  //     LDU {burst_size=4} from 0x418, and XVU forwards whatever it pops:
                                                  //       t = 0: SP 0x418 = x[m, 64k .. 64k+63]     (staged by NCLU)
                                                  //       t = 1: SP 0x419  \
                                                  //       t = 2: SP 0x41a   } the psum band, which SPSU writes only later,
                                                  //       t = 3: SP 0x41b  /  after the TU: so they hold stale SP contents
                                                  //   * The garbage stays in its own row: the TU keeps row t in LRF[8+t], the VU in
                                                  //     acc[t], and NCSU stores only SP 0x419 (= acc[0]). Rows 1..3 never mix
                                                  //     into row 0 (but they still cost 3/4 of the TU and VU beats).
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

// =================================================================================================
// ABSU (col 0): XVU -> AB, one 128 B beat split over the 8 TU rows' AB regions (16 B each)
// =================================================================================================
.text_absu
.target 0x90
.place col=0 line=0
.spr 0xff01ff
.lrf_idx 0 1
.lrf 0x3f0 0x10                                   // LRF0 = AB write pointer = -0x10 (10-bit), LRF1 = stride 0x10 (one 16 B line)
MVLOOPCNT immediate=1                             // five 1-trip frame loops (batch, row, Cout, pass, …)
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}
                                                  // for t < 4: LRF0 += LRF1; AB_r[LRF0[9:4]] := beat_t[8r .. 8r+7] for all r < 8
                                                  //   -0x10 + 0x10 = 0x000: writes 0x000, 0x010, 0x020, 0x030 in every region
          SYNC {dir.put=1, be=1}                  // put(absu->ablu): AB written
        NOP {be=1}
      SYNC {dir.get=1}                            // get(ablu->absu): AB consumed (swap barrier)
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

// =================================================================================================
// ABLU (col 1): AB -> TU west. One program; each TU row's ABLU reads its own 1 KB AB region.
// =================================================================================================
.text_ablu
.target 0x88
.place col=1 line=0
.spr 0xff01ff
.lrf_idx 0 1 2 3 4 5 6 7 8 14 15
.lrf 0x3f0 0x3f2 0x3f4 0x3f6 0x3f8 0x3fa 0x3fc 0x3fe 0x0 0x8 0x10
                                                  // 10-bit two's complement: LRF0..7 = -0x10, -0x0e, .., -0x02 (mcc's reversed lane
                                                  // pointers, -2*(8-i)); LRF8, 14, 15 = 0, 8, 16 (tile strides)
                                                  // LRF0 = slice 0 (lanes 0..3), LRF4 = slice 8 B (lanes 4..7), LRF15 = stride
                                                  // LRF1..3, 5..7 (other 2 B offsets) are not used
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      SYNC {dir.put=1}                            // put(ablu->absu): AB may be reused
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          SYNC {dir.get=1}                        // get(absu->ablu): AB written
          LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}
                                                  // for t < 4: LRF0 += 0x10; a := AB_r[LRF0] (8 B = beat_t[8r .. 8r+3]); W := (a, a)
          LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4, be=1}
                                                  // for t < 4: LRF4 += 0x10; a := AB_r[LRF4] (8 B = beat_t[8r+4 .. 8r+7]); W := (a, a)
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN

// =================================================================================================
// TU row 0 (col 0): top of the 8-row systolic column. Rows 1..7 follow the same program (see below).
// =================================================================================================
//
// What the two compute FMAs of TU row r compute:
//   k  K chunk of this DNC (d = 4m + k): K = 64k .. 64k+63
//   r  TU row, 0..7: this row's 8 K are 64k + 8r + 0..7 (w latched in LRF0..7)
//   t  row of the 4-row M tile, 0..3: t = 0 is x[m, :], t = 1..3 are padding (the FMA unroll index)
//   n  output lane, 0..63 (8 slices x 8 lanes, SIMD)
//
//   FMA 1:  LRF[8+t][n] = x[t, 64k+8r+0 : +4] . w[64k+8r+0 : +4, n] + S_{r-1}[t][n]     (row 0: + 0)
//   FMA 2:  S_r[t][n]   = x[t, 64k+8r+4 : +8] . w[64k+8r+4 : +8, n] + LRF[8+t][n]       -> south
//   e.g. DNC 0, row 0, t = 0:  LRF8[n] = x[0, 0:4] . w[0:4, n];  S_0[0][n] = x[0, 4:8] . w[4:8, n] + LRF8[n]
//   Row 7 gives S_7[0][n] = x[m, 64k : 64k+64] . w[64k : 64k+64, n] = partial(m, k)[n].
//   (Pairing of x and w only; the order of the 4 x values inside Z, K.in reversed in mcc's layout,
//    is not decoded.)
//
.text_tu
.target 0x81
.place col=0 line=33
.spr 0xff21ff
MVLOOPCNT immediate=1
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 {unroll_control.degree=3, unroll_control.lrf_tgt=1}
                                                  // X=0, Y=N, Z=1.0  ->  for i < 8: LRF[i] := pop(N)
                                                  // latch this row's 8 kernel lines (w[64k + 8r + i, :])
      MVLOOPCNT immediate=0x38
        FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0 {be=1}
                                                  // S := pop(N)   pass kernel lines down to rows 1..7 (7 x 8 = 56)
      MVLOOPCNT immediate=1
        MVLOOPCNT immediate=1
          FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1=#0, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.lrf_tgt=1}
                                                  // 4-term dot (src0=LRF[0:3]).  for t < 4:
                                                  //   Z := pop(W);  E := Z
                                                  //   LRF[8+t] := sum_{i<4} LRF[i] * Z_i + 0          (row 0: Y = 0)
          FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST {unroll_control.degree=2, unroll_control.src1=1, be=1}
                                                  //   Z := pop(W);  E := Z
                                                  //   S := sum_{i<4} LRF[4+i] * Z_i + LRF[8+t]         (8-term partial over K)
        NOP {be=1}
      NOP {be=1}
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN
RETURN
RETURN

// TU rows 1..7 (cols 1..7) are the same program with two differences:
//   * the pass-down loop count is 8 * (7 - r): 48, 40, 32, 24, 16, 8, and row 7 has none
//   * the first compute FMA reads src1=FIFO_NORTH (Y := pop(N), the partial from the row above) instead of #0
//   Row 7's south output leaves the TU and enters the VU FIFO: 4 lines of  sum over this DNC's 64 K.

// =================================================================================================
// VU (col 4): accumulate. acc = local TU partial, then + each sibling partial; store after each step.
// =================================================================================================
// VU FMA (ISA REBEL/EVT1/VU/FMA): Result = X * Y + Z with X = src0, Y = src1, Z = src2; 8-lane SIMD per slice.
//   unroll_control.degree=2 runs 4 steps (t = 0..3); unroll_control.src0/src2/lrf_tgt=1 advance that register
//   by one per step. CONST4 = ConstReg[4] = 0x3e00 = 1.0 and CONST0 = 0, so "x * 1.0 + acc" is an add.
.text_vu
.target 0x82
.place col=4 line=0
.spr 0xff11ff
.lccr 0xbe003e00410040003c000000                  // CONST0..5 = 0, 0.5, 2.0, 3.0, 1.0, -1.0 (dlf16, low 16 bits first)
.lrf_idx 0 12 13 15
.lrf 0x0 0x3e003e003e003e003e003e003e003e00 0x0 0x7fff7fff7fff7fff7fff7fff7fff7fff
FCMP lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=NONE, src0=LRF0, src2=CONST0 {immediate=4}
                                                  // flag := cmp(LRF0, CONST0), mode immediate=4 ?; no target
IMMCOPY lrf_tgt=LRF12, immediate=0x3e00 {repl=1}  // LRF12 := 1.0
MVLOOPCNT immediate=1
  IMMCOPY lrf_tgt=LRF4, immediate=0 {repl=1}      // acc[0..3] := 0   (LRF4..7)
  IMMCOPY lrf_tgt=LRF5, immediate=0 {repl=1}
  IMMCOPY lrf_tgt=LRF6, immediate=0 {repl=1}
  IMMCOPY lrf_tgt=LRF7, immediate=0 {repl=1}
  MVLOOPCNT immediate=1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
                                                  // for t < 4: LRF[4+t] := pop(tu) * 1.0 + LRF[4+t]
                                                  //   acc[t] := 0 + S_7[t]: acc was just zeroed and the loop runs once, so this
                                                  //   is a copy. It has the same form as the sibling steps below; only the root's
                                                  //   later steps really add.
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
                                                  // for t < 4: push(spsu, LRF[4+t] * 1.0 + 0)           store 1
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
                                                  // for t < 4: LRF[4+t] += pop(splu)                    acc += sibling 1
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
                                                  //                                                     store 2
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
                                                  //                                                     acc += sibling 2
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
                                                  //                                                     store 3
    MVLOOPCNT immediate=1
      FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 {unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2, be=1}
                                                  //                                                     acc += sibling 3
    FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 {unroll_control.src0=1, unroll_control.degree=2}
                                                  //                                                     store 4 = final sum
    NOP {be=1}
  NOP {be=1}
RETURN
RETURN

// =================================================================================================
// SPSU (col 2): VU FIFO -> SP psum band. Root stores 4 times (local, then after each gather).
// =================================================================================================
.text_spsu
.target 0xc0
.place col=2 line=0
.spr 0xff01ff
.lrf_idx 1 3 15
.lrf 0x20c00 0x20d00 0x80                         // LRF1 = band base - 1 line (0x20c00 = line 0x418), LRF3, LRF15 = 1 line
IMMCOPY src0=LRF3, immediate=0x10680              // LRF3 := 0x20d00
IMMCOPY src0=LRF1, immediate=0x10600              // LRF1 := 0x20c00
MVLOOPCNT immediate=1                             // store 1: the local partial
  LRFREGCOPY src0=LRF0, src1=LRF1                 //   LRF0 := LRF1
  MVLOOPCNT immediate=1
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4, be=1}
                                                  //   for t < 4: LRF0 += 0x80; SP[LRF0] := pop(vu)   -> lines 0x419 .. 0x41c
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}       //   put(spsu->ncsu): store done
IMMCOPY src0=LRF1, immediate=0x10600              // stores 2..4: same band again (last write wins = final sum)
MVLOOPCNT immediate=1
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4, be=1}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
IMMCOPY src0=LRF1, immediate=0x10600
MVLOOPCNT immediate=1
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4, be=1}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
IMMCOPY src0=LRF1, immediate=0x10600
MVLOOPCNT immediate=1
  LRFREGCOPY src0=LRF0, src1=LRF1
  MVLOOPCNT immediate=1
    STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4, be=1}
  SYNC {dir.put=1, lsync_mask.ncsu=1, be=1}
MODLRFIMM src0=LRF3, immediate=0xc0               // LRF3 += 0x180 (next tile; unused at one tile)
RETURN
RETURN
RETURN
RETURN

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
MVLOOPCNT immediate=1
  CXRREGCOPY src0=CAR9, src1=CAR8                 // CAR9  := CAR8
  CXRREGCOPY src0=CAR11, src1=CAR9                // CAR11 := CAR9
  CXRREGCOPY src0=CAR12, src1=CAR9                // CAR12 := CAR9
  SXRIMM src0=SAR11, immediate=0x418              // SAR11 := 0x418   (psum line - 1)
  SXRIMM src0=SAR12, immediate=0x418              // SAR12 := 0x418
  SYNC {dir.get=1, lsync_mask.spsu0=1}            // get(spsu0->ncsu): store 1 (local partial) done
  SYNC {dir.put=1, lsync_mask.nclu=1}             // put(ncsu->nclu): credit, NCLU may start gathering
  SYNC {dir.get=1, lsync_mask.spsu0=1}            // get: store 2 done
  SYNC {dir.get=1, lsync_mask.spsu0=1}            // get: store 3 done
  MVLOOPCNT immediate=1
    SYNC {dir.get=1, lsync_mask.spsu0=1}          // get: store 4 (final sum) done
    STSU src0=SAR11, src1=SBR0, src2=CAR11, src3=CBR0 {burst=1}
                                                  // SAR11 += SBR0; CAR11 += CBR0;  SHM[CAR11] := SP[SAR11]
                                                  //   = SHM[0x110] := SP[0x419]    out[m=0, :]
    ADDCXRIMM src0=CAR11, immediate=0             // CAR11 += 0
    ADDCXRIMM src0=CAR12, immediate=0 {be=1}      // CAR12 += 0
  SYNC {dir.put=1, lsync_mask.nclu=1}             // put(ncsu->nclu)
  ADDCXRIMM src0=CAR8, immediate=1 {be=1}         // CAR8 += 1
SYNC {dir.get=1, dir.put=1, lsync_mask.nclu=1}    // put+get(ncsu<->nclu): fence (NC protocol frame)
RETURN
RETURN

// =================================================================================================
// leaf (DNC 1: m = 0, k = 1) differs from the root in these places
// =================================================================================================
//   NCLU  descriptors point at its own chunks: kernel SHM 0x50 (w chunk 1), x SHM 0x4.
//         No gather and no MESYNC pairs; it ends with the NCSU fence and
//         MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1} (hand-off with its root).
//   SPLU  no gather feed. Instead it waits get(spsu->splu) and pushes 3 + 4 lines to the VU
//         (LDU consumer=VU from LRF8, then LRF5), which the leaf VU never pops. A later mcc build no longer
//         emits these two LDUs.
//   VU    only the local step: acc := tu partial; push(spsu).
//   SPSU  one store of 4 lines, with put(spsu->splu) credits around it.
//   NCSU  get(spsu0->ncsu) (store done); STSU writes SP[0x419] -> SHM[0x114] (partial scratch for the root);
//         MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1} (signal the root); put(ncsu->nclu);
//         fence.
//
// Open points in these comments
//   * The 4-line moves (unroll degree 2 = 4 steps, burst_size=4) are the Tr = 4 row tile: emit_splu pads the
//     fed rows to the drain atom Tr (foundation.r100 HWSpec.tr = 4). With one real row per DNC, rows 1..3 are
//     padding.
//   * Which 16 B of an ABSU beat goes to which AB region, and how the reversed K.in in mcc's layout matches the
//     FMA's Z element order.
//   * LOGICAL's op on the XVU pass-through, and the FCMP mode immediate.
