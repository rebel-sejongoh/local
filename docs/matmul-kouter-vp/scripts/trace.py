"""Draw a per-unit activity timeline of one DNC from VP debug logs (`verif_files/DebugLog__*.txt`).

    trace.py --out ../trace_m2048_k1024.svg --dnc 0 --bin 20 \\
        "SP psum=<workdir>" "Register psum, R=4=<workdir>" "rcl2=<workdir>"

Each panel is one run; each row a unit of NCore 0 (and the DNC's NC units); each cell one bin of cycles, its
darkness the share of the bin's cycles in which the unit issued an instruction (NC units: SHM requests).
TU rows split the issue by role, read from the FMA's operand fields: latch (weights into LRF0..7), pass
(weights to the rows below), mac and drain (the two dot-product FMAs of a tile).
"""

from __future__ import annotations

import argparse
import glob
import re
from collections import defaultdict
from pathlib import Path

ROWS = [
    ("NCLU", "nclu", "load"),
    ("SPLU", "ncore0.splu", "issue"),
    ("XVU", "ncore0.xvu", "issue"),
    ("ABSU", "ncore0.absu", "issue"),
    ("ABLU row 0", "ncore0.ablu0", "issue"),
    ("TU row 0", "ncore0.tu0", "tu"),
    ("TU row 7", "ncore0.tu7", "tu"),
    ("VU", "ncore0.vu", "issue"),
    ("SPSU", "ncore0.spsu", "issue"),
    ("NCSU", "ncsu", "load"),
]
TU_COLORS = {"latch": "#d62728", "pass": "#ff9f40", "mac": "#2ca02c", "drain": "#1f77b4", "other": "#999"}
ISSUE_COLOR = "#3b5b92"
LOAD_COLOR = "#7b4f9d"


def tu_role(fields: list[str]) -> str:
    src = fields[:2]
    if src == ["f", "d"]:
        return "latch"
    if src == ["d", "f"]:
        return "pass"
    if src[0] == "0":
        return "mac"
    if src[0] == "4":
        return "drain"
    return "other"


def parse(workdir: str, dnc: int, binw: int):
    log = glob.glob(f"{workdir}/verif_files/DebugLog__*.txt")[0]
    pre = f"[VPP],"
    tag = f"dnc_2r[{dnc:02d}].dnc{dnc:02d}."
    counts = {name: defaultdict(lambda: defaultdict(int)) for name, _, _ in ROWS}
    unit_of = {f"{tag}{u}": (name, kind) for name, u, kind in ROWS}
    last = 0
    with open(log, errors="replace") as f:
        for line in f:
            if not line.startswith(pre) or tag not in line:
                continue
            p = line.rstrip().split(",")
            if len(p) < 4 or p[2] not in unit_of:
                continue
            name, kind = unit_of[p[2]]
            cyc = int(p[1])
            ev = p[3]
            b = cyc // binw
            if kind == "load":
                if ev == "REQ":
                    counts[name][b]["req"] += 1
            elif kind == "tu":
                if ev == "IF" and len(p) > 7 and p[4] == "1" and p[6] == "FMA":
                    counts[name][b][tu_role(p[7].split())] += 1
            else:
                if ev.startswith("IS2") and (len(p) < 5 or p[4] != "0"):
                    counts[name][b]["issue"] += 1
            last = max(last, cyc)
    stop = last
    m = re.search(r"Stopping simulation at cycle (\d+)", Path(workdir, "vp.log").read_text())
    if m:
        stop = int(m.group(1))
    return counts, stop


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--dnc", type=int, default=0)
    ap.add_argument("--bin", type=int, default=20)
    ap.add_argument("runs", nargs="+", help="label=workdir")
    a = ap.parse_args()
    runs = [(r.rsplit("=", 1)[0], *parse(r.rsplit("=", 1)[1], a.dnc, a.bin)) for r in a.runs]
    tmax = max(stop for _, _, stop in runs)
    nb = tmax // a.bin + 1
    left, right, rowh, gap, top = 110, 20, 16, 46, 50
    W = 1200
    pw = W - left - right
    cw = pw / nb
    H = top + len(runs) * (len(ROWS) * rowh + gap) + 70
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="sans-serif" font-size="11">',
           f'<rect width="{W}" height="{H}" fill="white"/>',
           f'<text x="{W/2}" y="22" text-anchor="middle" font-size="15" font-weight="bold">'
           f'VP activity of DNC {a.dnc}, NCore 0, m2048_k1024 (bins of {a.bin} cycles; darker = busier)</text>']
    y = top
    for label, counts, stop in runs:
        out.append(f'<text x="{left}" y="{y-8}" font-weight="bold" font-size="13">{label}: {stop} cycles</text>')
        for name, _, kind in ROWS:
            out.append(f'<text x="{left-6}" y="{y+rowh-4}" text-anchor="end">{name}</text>')
            out.append(f'<rect x="{left}" y="{y}" width="{pw}" height="{rowh-2}" fill="#f4f4f4"/>')
            for b, c in counts[name].items():
                x = left + b * cw
                if kind == "tu":
                    tot = sum(c.values())
                    role = max(c, key=c.get)
                    op = min(1.0, tot / a.bin)
                    out.append(f'<rect x="{x:.2f}" y="{y}" width="{cw+0.3:.2f}" height="{rowh-2}" '
                               f'fill="{TU_COLORS[role]}" fill-opacity="{0.25 + 0.75 * op:.2f}"/>')
                else:
                    tot = sum(c.values())
                    op = min(1.0, tot / a.bin)
                    col = LOAD_COLOR if kind == "load" else ISSUE_COLOR
                    out.append(f'<rect x="{x:.2f}" y="{y}" width="{cw+0.3:.2f}" height="{rowh-2}" '
                               f'fill="{col}" fill-opacity="{0.15 + 0.85 * op:.2f}"/>')
            y += rowh
        sx = left + stop / a.bin * cw
        out.append(f'<line x1="{sx:.1f}" x2="{sx:.1f}" y1="{y-len(ROWS)*rowh}" y2="{y}" stroke="black" stroke-dasharray="3,2"/>')
        y += gap
    for t in range(0, tmax + 1, 1000):
        x = left + t / a.bin * cw
        out.append(f'<line x1="{x:.1f}" x2="{x:.1f}" y1="{top-4}" y2="{y-gap+4}" stroke="#ccc" stroke-width="0.5"/>')
        out.append(f'<text x="{x:.1f}" y="{y-gap+18}" text-anchor="middle">{t}</text>')
    lx, ly = left, y - gap + 40
    items = [("instruction issue", ISSUE_COLOR), ("SHM request (NC)", LOAD_COLOR)] + \
            [(f"TU {k}", v) for k, v in TU_COLORS.items() if k != "other"]
    for i, (lab, col) in enumerate(items):
        cx = lx + i * 170
        out.append(f'<rect x="{cx}" y="{ly-10}" width="20" height="11" fill="{col}"/>')
        out.append(f'<text x="{cx+26}" y="{ly}">{lab}</text>')
    out.append(f'<text x="{lx}" y="{ly+20}">cycle</text>')
    out.append("</svg>")
    a.out.write_text("\n".join(out))
    print("wrote", a.out)


if __name__ == "__main__":
    main()
