"""Generate DNC assembly for y[M,64] = x[M,K] @ w[K,64] in two K-outer schedules.

    gen_mm.py --manifest <case>/base/manifest.json --variant {A,C} [--R 4] [--lead 8] --out <dir>

Work split: DNC d takes rows d*Md .. +Md (Md = M/16), NCore c rows c*Mc .. +Mc of those (Mc = Md/2),
T = Mc/4 tiles per NCore, KB = K/64 K blocks. K is never split across DNCs.

  A  (rcl2-like): loop kb { latch w(kb); loop t<T { tile } }, partial sums in SP (read by SPLU -> VU,
     written back by SPSU), one SPSU->SPLU sync per K block.
  C  (register blocking): loop g<T/R { loop kb { latch w(kb); loop i<R { tile } } }, the R tiles'
     accumulators in VU LRF0..4R-1. R = 1 is mcc's order (M outside K).

SP layout (lines, shared by both NCores): W0: w (K lines); XB: x, kb-major, Md lines per kb (NCore c at
+c*Mc); YB: y (Md lines); PB: psums (Md lines, A only).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from dnc_binutils.legacy.nc_desc import pack

SHM_BASE = 0x80000
W0 = 0x100
LINE = 128  # bytes per SP line

SLOTS = {"ABSU": 4, "ABLU": 4, "SPSU": 4, "SPLU": 4, "VU": 2, "XVU": 2, "NCSU": 4, "NCLU": 4, "TU": 4}
COL = {"ABSU": 0, "ABLU": 1, "SPSU": 2, "SPLU": 3, "VU": 4, "XVU": 5, "NCSU": 6, "NCLU": 7}


# ----------------------------------------------------------------------------- program text helpers
def with_be(line: str) -> str:
    if "{" in line:
        return line[:-1] + ", be=1}"
    return line + " {be=1}"


def loop(n: int, body: list[str]) -> list[str]:
    """A hardware loop of n trips around body; n == 1 inlines it, n == 0 drops it."""
    if n == 0 or not body:
        return []
    if n == 1:
        return list(body)
    out = list(body)
    if out[-1].startswith(" "):  # the body ends with an inner loop
        out.append("NOP {be=1}")
    else:
        out[-1] = with_be(out[-1])
    return [f"MVLOOPCNT immediate={n:#x}"] + ["  " + l for l in out]


def imm_lrf(nbytes: int) -> str:
    """MODLRFIMM immediate for a byte delta: (imm << 1) in 21-bit two's complement."""
    assert nbytes % 2 == 0
    return f"{(nbytes >> 1) & ((1 << 21) - 1):#x}"


def imm_bits(v: int, bits: int) -> str:
    return f"{v & ((1 << bits) - 1):#x}"


def block(unit, target, spr, body, *, lccr=(), lrf=()):
    body = list(body) + ["RETURN"]
    s = SLOTS[unit]
    body += ["RETURN"] * (-len(body) % s)
    head = [f".text_{unit.lower()}", f".target {target:#x}", "PLACE", f".spr {spr:#x}"]
    if lccr:
        head.append(".lccr " + " ".join(lccr))
    if lrf:
        head.append(".lrf_idx " + " ".join(str(i) for i, _ in lrf))
        head.append(".lrf " + " ".join(f"{v:#x}" for _, v in lrf))
    span = 2 + len(lccr) + len(lrf) + len(body) // s
    return {"unit": unit, "head": head, "body": body, "span": span}


# ----------------------------------------------------------------------------- per-unit programs
def gen_dnc(d: int, cfg: dict) -> str:
    M, K, var, R, L = cfg["M"], cfg["K"], cfg["variant"], cfg["R"], cfg["lead"]
    Ix, Iw, Io = cfg["Ix"], cfg["Iw"], cfg["Io"]
    Md, KB = M // 16, K // 64
    Mc = Md // 2
    T = Mc // 4
    XB = W0 + K
    YB = XB + KB * Md
    PB = YB + Md
    G = T // R if var == "C" else 1
    rem = T % R if var == "C" else 0      # a last, smaller group when R does not divide T
    def groups(f):
        """loop(G, f(R)) followed by f(rem) for the ragged last group"""
        return loop(G, f(R)) + (f(rem) if rem else [])
    assert Md % 16 == 0 and KB >= 2
    blocks = []

    # NCLU ------------------------------------------------------------------
    descs = [
        (0, pack({"SAR": 0, "SBR": W0, "CAR": 0, "CBR": SHM_BASE + Iw})),
        (1, pack({"SAR": 0, "SBR": XB, "CAR": 0, "CBR": SHM_BASE + Ix + d * Md})),
        (2, pack({"SAR": 0, "SBR": XB + Mc, "CAR": 0, "CBR": SHM_BASE + Ix + d * Md + Mc})),
    ]
    put_splu = "SYNC {dir.put=1, lsync_mask.splu1=1, lsync_mask.splu0=1}"
    w_load = loop(4, ["LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=0x10}"])
    if var == "A":
        x_load = loop(Md // 16, ["LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=0x10}"])
        body = loop(KB, w_load + x_load + [f"ADDCXRIMM src0=CAR1, immediate={imm_bits(M - Md, 20)}", put_splu])
    else:
      def nclu_grp(rg, with_w):
        b = 4 * rg
        x_grp = [
            f"LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {{burst={b:#x}}}",
            f"LDMU src0=SAR2, src1=SBR2, src2=CAR2, src3=CBR2 {{burst={b:#x}}}",
            f"ADDSXRIMM src0=SAR1, immediate={imm_bits(Md - b, 15)}",
            f"ADDSXRIMM src0=SAR2, immediate={imm_bits(Md - b, 15)}",
            f"ADDCXRIMM src0=CAR1, immediate={imm_bits(M - b, 20)}",
            f"ADDCXRIMM src0=CAR2, immediate={imm_bits(M - b, 20)}",
        ]
        nxt = [
            f"ADDSXRIMM src0=SAR1, immediate={imm_bits(-KB * Md + b, 15)}",
            f"ADDSXRIMM src0=SAR2, immediate={imm_bits(-KB * Md + b, 15)}",
            f"ADDCXRIMM src0=CAR1, immediate={imm_bits(-KB * M + b, 20)}",
            f"ADDCXRIMM src0=CAR2, immediate={imm_bits(-KB * M + b, 20)}",
        ]
        return loop(KB, (w_load if with_w else []) + x_grp + [put_splu]) + nxt
      sizes = [R] * G + ([rem] if rem else [])
      body = nclu_grp(sizes[0], True)
      body += loop(G - 1, nclu_grp(R, False))
      if rem:
          body += nclu_grp(rem, G == 0)
    blocks.append(block("NCLU", 0x200, 0xFF01FF, body, lrf=descs))

    # SPLU, SPSU per NCore ----------------------------------------------------
    for c in range(2):
        tgt_l = 0x20 | (0x80 if c == 0 else 0x100)
        tgt_s = 0x40 | (0x80 if c == 0 else 0x100)
        xb = XB + c * Mc
        lrf = [(0, (W0 - 1) * LINE), (1, (xb - 1) * LINE), (2, (PB + c * Mc - 1) * LINE), (10, LINE)]
        get_nclu = "SYNC {dir.get=1, lsync_mask.nclu=1}"
        w_feed = ["LDU consumer=XVU, src0=LRF0, src1=LRF10 {burst=1, burst_size=0x20}"] * 2
        if var == "A":
            x_tile = "LDU consumer=XVU, src0=LRF1, src1=LRF10 {burst=1, burst_size=4}"
            p_tile = "LDU consumer=VU, src0=LRF2, src1=LRF10 {burst=1, burst_size=4}"
            get_sp = "SYNC {dir.get=1, lsync_mask.self_spsu=1}"
            lead = min(L, T)
            k0 = [get_nclu] + w_feed + loop(T, [x_tile]) + [f"MODLRFIMM src0=LRF1, immediate={imm_lrf((Md - Mc) * LINE)}"]
            mid = loop(T - lead, [x_tile, p_tile])
            kk = [get_nclu] + w_feed + loop(lead, [x_tile]) + [get_sp] + mid + loop(lead, [p_tile])
            kk += [f"MODLRFIMM src0=LRF1, immediate={imm_lrf((Md - Mc) * LINE)}",
                   f"MODLRFIMM src0=LRF2, immediate={imm_lrf(-Mc * LINE)}"]
            body = k0 + loop(KB - 1, kk)
        else:
          def splu_grp(rg):
            b = 4 * rg
            kk = [get_nclu] + w_feed + [f"LDU consumer=XVU, src0=LRF1, src1=LRF10 {{burst=1, burst_size={b:#x}}}",
                                        f"MODLRFIMM src0=LRF1, immediate={imm_lrf((Md - b) * LINE)}"]
            grp = loop(KB, kk) + [f"MODLRFIMM src0=LRF1, immediate={imm_lrf((-KB * Md + b) * LINE)}",
                                  f"MODLRFIMM src0=LRF0, immediate={imm_lrf(-K * LINE)}"]
            return grp
          body = groups(splu_grp)
        blocks.append(block("SPLU", tgt_l, 0xFF01FF, body, lrf=lrf))

        slrf = [(0, (PB + c * Mc - 1) * LINE), (1, (YB + c * Mc - 1) * LINE), (15, LINE)]
        st_y = ["STU producer=VU, src0=LRF1, src1=LRF15 {burst=1, burst_size=4}", "SYNC {dir.put=1, lsync_mask.ncsu=1}"]
        if var == "A":
            st_p = loop(T, ["STU producer=VU, src0=LRF0, src1=LRF15 {burst=1, burst_size=4}"])
            body = loop(KB - 1, st_p + ["SYNC {dir.put=1, lsync_mask.self_splu=1}",
                                        f"MODLRFIMM src0=LRF0, immediate={imm_lrf(-Mc * LINE)}"])
            body += loop(T, st_y)
        else:
            body = loop(T, st_y)
        blocks.append(block("SPSU", tgt_s, 0xFF01FF, body, lrf=slrf))

    # XVU ---------------------------------------------------------------------
    to_tu = "LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=NONE, tu_tgt=src0, src0=FIFO_SPLU, src2=CONST0 {immediate=1}"
    to_ab = "LOGICAL lrf_tgt=NONE, vu_tgt=NONE, sp_tgt=NONE, ab_tgt=src0, tu_tgt=NONE, src0=FIFO_SPLU, src2=CONST0 {immediate=1}"
    if var == "A":
        body = loop(KB, loop(64, [to_tu]) + loop(4 * T, [to_ab]))
    else:
        body = groups(lambda rg: loop(KB, loop(64, [to_tu]) + loop(4 * rg, [to_ab])))
    blocks.append(block("XVU", 0x184, 0x70FF21FF, body,
                        lccr=("0xbe003e00410040003c000000", "0xbf803f80404040003f000000"),
                        lrf=[(11, 0), (12, 0x3E003E003E003E003E003E003E003E00), (13, 0),
                             (14, 0xCCC8C4C0BCB8B0004C4844403C383000)]))

    # ABSU, ABLU (both NCores) --------------------------------------------------
    # Half-ring handshake, as mcc and rcl2 do: the AB ring holds 16 blocks of 4 lines; the ABSU writes 8
    # blocks, then waits for the ABLUs to have released the half it is about to overwrite.
    nblk = KB * T
    if var == "C":
        # sync inside the existing loops: once per K block (B = R blocks), ABLU's credit first
        stu = ["STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}", "SYNC {dir.put=1}"]
        absu = groups(lambda rg: loop(KB, loop(rg, stu) + ["SYNC {dir.get=1}"])) + ["SYNC {dir.get=1}"]
        rd = ["SYNC {dir.get=1}",
              "LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}",
              "LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}"]
        ablu = ["SYNC {dir.put=1}"] + groups(lambda rg: loop(KB, loop(rg, rd) + ["SYNC {dir.put=1}"]))
        blocks.append(block("ABSU", 0x190, 0xFF01FF, absu, lrf=[(0, 0x3F0), (1, 0x10)]))
    else:
      H = 8
      assert nblk % H == 0
      absu = loop(nblk // H, loop(H, ["STU src0=LRF0, src1=LRF1 {burst_en=1, burst_size=4}", "SYNC {dir.put=1}"])
                  + ["SYNC {dir.get=1}"]) + ["SYNC {dir.get=1}"]
      blocks.append(block("ABSU", 0x190, 0xFF01FF, absu, lrf=[(0, 0x3F0), (1, 0x10)]))
      ablu = ["SYNC {dir.put=1}"] + loop(nblk // H, loop(H, [
          "SYNC {dir.get=1}",
          "LDU src0=LRF0, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}",
          "LDU src0=LRF4, src1=LRF15 {replicate=1, load_type=1, burst_en=1, burst_size=4}"]) + ["SYNC {dir.put=1}"])
    blocks.append(block("ABLU", 0x188, 0xFF01FF, ablu,
                        lrf=[(0, 0x3F0), (1, 0x3F2), (2, 0x3F4), (3, 0x3F6), (4, 0x3F8), (5, 0x3FA), (6, 0x3FC),
                             (7, 0x3FE), (8, 0), (14, 8), (15, 0x10)]))

    # VU (both NCores) ------------------------------------------------------------
    vhead = ["FCMP lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=NONE, src0=LRF0, src2=CONST0 {immediate=4}"]
    if var == "A":
        first = "FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=FIFO_TU, src1=CONST4, src2=CONST0 {unroll_control.degree=2}"
        acc = "FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=FIFO_TU, src1=CONST4, src2=FIFO_SPLU {unroll_control.degree=2}"
        body = vhead + loop(T, [first]) + loop(KB - 1, loop(T, [acc]))
    else:
      def vu_grp(R):
        init = [f"FMA lrf_tgt=LRF{4 * i}, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=CONST0 "
                "{unroll_control.lrf_tgt=1, unroll_control.degree=2}" for i in range(R)]
        acc = [f"FMA lrf_tgt=LRF{4 * i}, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_TU, src1=CONST4, src2=LRF{4 * i} "
               "{unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree=2}" for i in range(R)]
        out = [f"FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF{4 * i}, src1=CONST4, src2=CONST0 "
               "{unroll_control.src0=1, unroll_control.degree=2}" for i in range(R)]
        return init + loop(KB - 1, acc) + out
      body = vhead + groups(vu_grp)
    blocks.append(block("VU", 0x182, 0xFF11FF, body, lccr=("0xbe003e00410040003c000000",), lrf=[(0, 0)]))

    # NCSU --------------------------------------------------------------------------
    ndesc = [
        (0, pack({"SAR": 0, "SBR": YB, "CAR": 0, "CBR": SHM_BASE + Io + d * Md})),
        (1, pack({"SAR": 0, "SBR": YB + Mc, "CAR": 0, "CBR": SHM_BASE + Io + d * Md + Mc})),
    ]
    body = loop(T, ["SYNC {dir.get=1, lsync_mask.spsu1=1, lsync_mask.spsu0=1}",
                    "STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {burst=4}",
                    "STMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {burst=4}"])
    blocks.append(block("NCSU", 0x400, 0xFF01FF, body, lrf=ndesc))

    # TU rows -------------------------------------------------------------------------
    tu_blocks = []
    for r in range(8):
        latch = ["FMA lrf_tgt=LRF0, south_tgt=NONE, east_tgt=NONE, src0=#0, src1=FIFO_NORTH, src2=#1.0 "
                 "{unroll_control.degree=3, unroll_control.lrf_tgt=1}"]
        latch += loop(56 - 8 * r, ["FMA south_tgt=src0, east_tgt=NONE, src0=FIFO_NORTH, src1=#0, src2=#1.0"])
        y = "#0" if r == 0 else "FIFO_NORTH"
        tile = [f"FMA lrf_tgt=LRF8, south_tgt=NONE, east_tgt=src2, src0=LRF[0:3], src1={y}, src2=FIFO_WEST "
                "{unroll_control.degree=2, unroll_control.lrf_tgt=1}",
                "FMA lrf_tgt=NONE, south_tgt=RESULT, east_tgt=src2, src0=LRF[4:7], src1=LRF8, src2=FIFO_WEST "
                "{unroll_control.degree=2, unroll_control.src1=1}"]
        if var == "A":
            body = loop(KB, latch + loop(T, tile))
        else:
            body = groups(lambda rg: loop(KB, latch + loop(rg, tile)))
        b = block("TU", 0x181, 0xFF21FF, body)
        b["col"] = r
        tu_blocks.append(b)

    # placement -------------------------------------------------------------------------
    height = [0] * 8
    order = ["ABSU", "ABLU", "SPSU", "SPLU", "VU", "XVU", "NCSU", "NCLU"]
    out = [".arch rebel.evt1"]
    placed = []
    for u in order:
        for b in [x for x in blocks if x["unit"] == u]:
            col = COL[u]
            b["col"], b["line"] = col, height[col]
            height[col] += b["span"]
            placed.append(b)
    base = max(height)
    for b in tu_blocks:
        b["line"] = base
        placed.append(b)
    for b in placed:
        out += [h if h != "PLACE" else f".place col={b['col']} line={b['line']}" for h in b["head"]]
        out += b["body"] + [""]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--variant", choices=["A", "C"], required=True)
    ap.add_argument("--R", type=int, default=4)
    ap.add_argument("--lead", type=int, default=8)
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()
    m = json.loads(a.manifest.read_text())
    blocks = {b.get("tensor"): b for b in m["shm"]["blocks"] if b.get("tensor")}
    shapes = m["source"]["shapes"]
    # input <1x(K/64)xMx64>
    dims = shapes.split("input <")[1].split(">")[0].split("x")
    K, M = int(dims[1]) * 64, int(dims[2])
    cfg = dict(M=M, K=K, variant=a.variant, R=a.R, lead=a.lead,
               Ix=blocks["input"]["start"], Iw=blocks["kernel"]["start"], Io=blocks["output"]["start"])
    a.out.mkdir(parents=True, exist_ok=True)
    for d in range(16):
        (a.out / f"raw_{d}.s").write_text(gen_dnc(d, cfg))
    print(json.dumps(cfg))


if __name__ == "__main__":
    main()
