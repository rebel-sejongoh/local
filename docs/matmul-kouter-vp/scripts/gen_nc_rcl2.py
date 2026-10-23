"""NC-only lower bound with rcl2's DNC split: each DNC loads the w and x rcl2's NCLU loads and stores its
output rows (and, for a K split, a partial of its rows to SHM and its root loads the partners' partials).

    gen_nc_rcl2.py --case <case dir> --out <dir>

The split is read from rcl2's NCLU descriptors: per DNC, the first K block of w and x and the first row of
each NCore. No compute runs; the numbers bound what the NC traffic alone costs under rcl2's split.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
from pathlib import Path

from dnc_binutils.legacy.nc_desc import decompose, pack

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("gen_mm", HERE / "gen_nc.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

SHM = 0x80000


def split(case: Path, M: int, K: int, Ix: int, Iw: int):
    rows = {}
    for d in range(16):
        t = (case / "base" / "code" / f"init_{d}.s").read_text()
        seg = t[t.index(".text_nclu"):].split("\n\n")[0]
        m = re.search(r"^\.lrf (.*)$", seg, re.M)
        if not m:
            continue
        v = [decompose(int(x, 16)) for x in m.group(1).split()]
        wk = (v[0]["CBR"] - SHM - Iw) // 64
        x0 = v[2]["CBR"] - SHM - Ix
        x1 = v[3]["CBR"] - SHM - Ix
        rows[d] = (wk, x0 % M, x1 % M)
    kbs = sorted({r[0] for r in rows.values()})
    nk = (K // 64) // len(kbs)
    starts = sorted({r[1] for r in rows.values()}) + [M]
    out = {}
    for d, (wk, r0, r1) in rows.items():
        end = starts[starts.index(r0) + 1]
        out[d] = dict(kb0=wk, nkb=nk, r0=r0, n0=r1 - r0, r1=r1, n1=end - r1, ksplit=len(kbs), root=(wk == 0))
    return out


def bursts(n, b=16):
    q, r = divmod(n, b)
    return ([b] * q) + ([r] if r else [])


def gen(d, s, M, K, Ix, Iw, Io):
    W0, LINE = 0x100, 128
    XB = W0 + s["nkb"] * 64
    Md = s["n0"] + s["n1"]
    YB = XB + s["nkb"] * Md
    descs = [(0, pack({"SAR": 0, "SBR": W0, "CAR": 0, "CBR": SHM + Iw + s["kb0"] * 64})),
             (1, pack({"SAR": 0, "SBR": XB, "CAR": 0, "CBR": SHM + Ix + s["kb0"] * M + s["r0"]}))]
    body = []
    per_kb = [f"LDMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {{burst={b:#x}}}" for b in bursts(64)]
    per_kb += [f"LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {{burst={b:#x}}}" for b in bursts(Md)]
    per_kb += [f"ADDCXRIMM src0=CAR1, immediate={g.imm_bits(M - Md, 20)}"]
    body = g.loop(s["nkb"], per_kb)
    blocks = [g.block("NCLU", 0x200, 0xFF01FF, body, lrf=descs)]
    # output (root) or partial (non-root) store of the DNC's rows; a root also loads the partners' partials
    nd = [(0, pack({"SAR": 0, "SBR": YB, "CAR": 0, "CBR": SHM + Io + s["r0"]}))]
    nb = [f"STMU src0=SAR0, src1=SBR0, src2=CAR0, src3=CBR0 {{burst={b:#x}}}" for b in bursts(Md)]
    if s["ksplit"] > 1 and s["root"]:
        # partner partials, as many lines as the rows, once per partner, loaded before the store
        extra = g.loop(s["ksplit"] - 1, [f"LDMU src0=SAR1, src1=SBR1, src2=CAR1, src3=CBR1 {{burst={b:#x}}}" for b in bursts(Md)])
        blocks[0] = g.block("NCLU", 0x200, 0xFF01FF, body + extra, lrf=descs)
    blocks.append(g.block("NCSU", 0x400, 0xFF01FF, nb, lrf=nd))
    return g.place(blocks, [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    m = json.loads((a.case / "base" / "manifest.json").read_text())
    B = {b.get("tensor"): b for b in m["shm"]["blocks"] if b.get("tensor")}
    dims = m["source"]["shapes"].split("input <")[1].split(">")[0].split("x")
    K, M = int(dims[1]) * 64, int(dims[2])
    Ix, Iw, Io = B["input"]["start"], B["kernel"]["start"], B["output"]["start"]
    sp = split(a.case, M, K, Ix, Iw)
    a.out.mkdir(parents=True, exist_ok=True)
    for d in range(16):
        if d in sp:
            (a.out / f"raw_{d}.s").write_text(gen(d, sp[d], M, K, Ix, Iw, Io))
        else:
            (a.out / f"raw_{d}.s").write_text(".arch rebel.evt1\n.text_ncsu\n.target 0x400\n.place col=6 line=0\n.spr 0xff01ff\nRETURN\nRETURN\nRETURN\nRETURN\n\n.text_nclu\n.target 0x200\n.place col=7 line=0\n.spr 0xff01ff\nRETURN\nRETURN\nRETURN\nRETURN\n")
    print(json.dumps(sp))


if __name__ == "__main__":
    main()
