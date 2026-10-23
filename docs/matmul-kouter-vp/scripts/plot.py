"""Draw ../cycles.svg from ../results.tsv: cycles over rcl2's, per shape, for rcl2, A and C with R = 4..1,
with the NC floors as lines. No dependencies; writes SVG by hand."""
from pathlib import Path

HERE = Path(__file__).resolve().parent
rows = [l.split("\t") for l in (HERE.parent / "results.tsv").read_text().split("\n")[1:] if l.strip()]
head = (HERE.parent / "results.tsv").read_text().split("\n")[0].split("\t")
data = [dict(zip(head, r)) for r in rows]

bars = [("rcl2", "rcl2", "#4c4c4c"), ("A", "SP psum", "#d98c2b"), ("C4", "Register psum, R=4", "#1f5fa8"),
        ("C3", "Register psum, R=3", "#4a8fd4"), ("C2", "Register psum, R=2", "#8bb9e8"),
        ("C1", "Register psum, R=1", "#c9def4")]
W, H = 1060, 540
left, right, top, bottom = 70, 20, 75, 110
pw, ph = W - left - right, H - top - bottom
ymax = 3.2
gw = pw / len(data)
bw = gw * 0.8 / len(bars)


def y(v):
    return top + ph - v / ymax * ph


out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="sans-serif" font-size="12">',
       f'<rect width="{W}" height="{H}" fill="white"/>',
       f'<text x="{W/2}" y="24" text-anchor="middle" font-size="15" font-weight="bold">'
       'VP cycles over rcl2\'s, y[M,64] = x[M,K] @ w[K,64], 16 DNCs (labels: cycles)</text>']
for t in [0, 0.5, 1, 1.5, 2, 2.5, 3]:
    out.append(f'<line x1="{left}" x2="{W-right}" y1="{y(t)}" y2="{y(t)}" stroke="{"#888" if t == 1 else "#e3e3e3"}"/>')
    out.append(f'<text x="{left-8}" y="{y(t)+4}" text-anchor="end">{t:g}×</text>')
for gi, d in enumerate(data):
    base = float(d["rcl2"])
    x0 = left + gi * gw + gw * 0.1
    for bi, (k, _, col) in enumerate(bars):
        v = float(d[k])
        r = v / base
        x = x0 + bi * bw
        out.append(f'<rect x="{x:.1f}" y="{y(r):.1f}" width="{bw-2:.1f}" height="{y(0)-y(r):.1f}" fill="{col}" stroke="#333" stroke-width="0.5"/>')
        out.append(f'<text x="{x+bw/2-1:.1f}" y="{y(r)-4:.1f}" text-anchor="middle" font-size="10" '
                   f'transform="rotate(-90 {x+bw/2-1:.1f} {y(r)-4:.1f})" dx="22" dy="3">{int(v)}</text>')
    for k, dash, col in (("N", "6,3", "#c0392b"), ("Nrcl2", "2,3", "#555")):
        r = float(d[k]) / base
        out.append(f'<line x1="{x0-4:.1f}" x2="{x0+len(bars)*bw+2:.1f}" y1="{y(r):.1f}" y2="{y(r):.1f}" '
                   f'stroke="{col}" stroke-width="2" stroke-dasharray="{dash}"/>')
    out.append(f'<text x="{x0+len(bars)*bw/2:.1f}" y="{y(0)+18}" text-anchor="middle" font-weight="bold">{d["shape"].replace("_n64","")}</text>')
    out.append(f'<text x="{x0+len(bars)*bw/2:.1f}" y="{y(0)+33}" text-anchor="middle">T={d["T"]} tiles/NCore, KB={d["KB"]}</text>')
lx, ly = left, H - 40
items = [(lab, col, None) for _, lab, col in bars] + [("NC floor, M-only split (N)", "#c0392b", "6,3"),
                                                       ("NC floor, rcl2's split (Nrcl2)", "#555", "2,3")]
for i, (lab, col, dash) in enumerate(items):
    cx = lx + (i % 4) * 245
    cy = ly + (i // 4) * 18
    if dash:
        out.append(f'<line x1="{cx}" x2="{cx+22}" y1="{cy-4}" y2="{cy-4}" stroke="{col}" stroke-width="2" stroke-dasharray="{dash}"/>')
    else:
        out.append(f'<rect x="{cx}" y="{cy-11}" width="22" height="11" fill="{col}" stroke="#333" stroke-width="0.5"/>')
    out.append(f'<text x="{cx+28}" y="{cy}">{lab}</text>')
out.append("</svg>")
(HERE.parent / "cycles.svg").write_text("\n".join(out))
print("wrote", HERE.parent / "cycles.svg")


# ----------------------------------------------------------------------------- ../speed.svg
# Speed relative to SP psum (SP psum cycles / cycles; higher is better), per shape, for SP psum and register
# psum with R = 1..4 (no rcl2).
sbars = [("A", "SP psum", "#d98c2b"), ("C1", "Register psum, R=1", "#c9def4"), ("C2", "Register psum, R=2", "#8bb9e8"),
         ("C3", "Register psum, R=3", "#4a8fd4"), ("C4", "Register psum, R=4", "#1f5fa8")]
DARK = {"#d98c2b", "#1f5fa8"}  # bars whose labels are drawn white
W, H = 980, 500
left, right, top, bottom = 70, 20, 60, 100
pw, ph = W - left - right, H - top - bottom
ymax = 1.1
gw = pw / len(data)
bw = gw * 0.8 / len(sbars)


def ys(v):
    return top + ph - v / ymax * ph


out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="sans-serif" font-size="12">',
       f'<rect width="{W}" height="{H}" fill="white"/>',
       f'<text x="{W/2}" y="24" text-anchor="middle" font-size="15" font-weight="bold">'
       'Speed relative to SP psum (higher is better; labels: cycles)</text>']
for t in [0, 0.25, 0.5, 0.75, 1]:
    out.append(f'<line x1="{left}" x2="{W-right}" y1="{ys(t)}" y2="{ys(t)}" stroke="{"#888" if t == 1 else "#e3e3e3"}"/>')
    out.append(f'<text x="{left-8}" y="{ys(t)+4}" text-anchor="end">{t:g}×</text>')
for gi, d in enumerate(data):
    a = float(d["A"])
    x0 = left + gi * gw + gw * 0.1
    for bi, (k, _, col) in enumerate(sbars):
        v = float(d[k])
        r = a / v
        x = x0 + bi * bw
        out.append(f'<rect x="{x:.1f}" y="{ys(r):.1f}" width="{bw-2:.1f}" height="{ys(0)-ys(r):.1f}" fill="{col}" stroke="#333" stroke-width="0.5"/>')
        out.append(f'<text x="{x+bw/2-1:.1f}" y="{ys(r)-6:.1f}" text-anchor="middle" font-size="10">{r:.2f}</text>')
        out.append(f'<text x="{x+bw/2-1:.1f}" y="{ys(r)+14:.1f}" text-anchor="middle" font-size="9" fill="{"white" if col in DARK else "#222"}" '
                   f'transform="rotate(-90 {x+bw/2-1:.1f} {ys(r)+14:.1f})" dx="-14" dy="3">{int(v)}</text>')
    out.append(f'<text x="{x0+len(sbars)*bw/2:.1f}" y="{ys(0)+18}" text-anchor="middle" font-weight="bold">{d["shape"].replace("_n64","")}</text>')
    out.append(f'<text x="{x0+len(sbars)*bw/2:.1f}" y="{ys(0)+33}" text-anchor="middle">T={d["T"]} tiles/NCore, KB={d["KB"]}</text>')
for i, (_, lab, col) in enumerate(sbars):
    cx = left + i * 180
    cy = H - 30
    out.append(f'<rect x="{cx}" y="{cy-11}" width="22" height="11" fill="{col}" stroke="#333" stroke-width="0.5"/>')
    out.append(f'<text x="{cx+28}" y="{cy}">{lab}</text>')
out.append("</svg>")
(HERE.parent / "speed.svg").write_text("\n".join(out))
print("wrote", HERE.parent / "speed.svg")
