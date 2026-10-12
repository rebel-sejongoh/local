"""Summarize sweep cases: shape, rcl2 plan (per axis), mcc plan, cycles."""
import json, math, re, sys
from pathlib import Path
root = Path(sys.argv[1]); cases = sys.argv[2:]  # each "name" or "name@sp"
def arr(log, key):
    m = re.search(rf"-- tiling {key}\s*: \[([^\]]*)\]", log)
    return [int(x) for x in m.group(1).split(",") if x]
def fmt(v): return "×".join(str(x) for x in v)
rows = []
for c in cases:
    n, _, sp = c.partition("@")
    d = root / n; log = (root / f"{n}.capture.log").read_text()
    man = json.loads((d / "base/manifest.json").read_text())
    dims = [int(x) for x in man["source"]["shapes"].split()[1].strip("<>").split("x")]
    it, dn, cl = arr(log, "iter"), arr(log, "dnc"), arr(log, "cluster")
    D = dims  # sub64 adds a trailing axis to the plan; it is never split, so the leading ones show it
    k = len(D)
    it, dn, cl = it[:k], dn[:k], cl[:k]
    per_cl = [math.ceil(x / c) for x, c in zip(D, cl)]
    per_dnc = [math.ceil(x / (c * q)) for x, c, q in zip(D, cl, dn)]
    temporal = [t // (c * q) for t, c, q in zip(it, cl, dn)]
    step = [math.ceil(x / t) for x, t in zip(D, it)]
    split = ", ".join(f"ax{i}:{c}cl×{q}dnc" for i, (c, q) in enumerate(zip(cl, dn)) if c * q > 1) or "—"
    loops = math.prod(temporal)
    ncl, ndnc = math.prod(cl), math.prod(dn)
    L = sum(1 for l in (d / "base/data/SHM_map.txt").read_text().splitlines() if not l.startswith("#")) // 3 - 2
    R, K = map(int, re.search(r"R=(\d+), K=(\d+)", (d / "kernel.py").read_text()).groups())
    mdnc = sum(1 for f in (d / "mcc-code").glob("init_*.s") if "== VU" in f.read_text())
    cyc = lambda f: json.loads((d / f).read_text())["cycles"] if (d / f).exists() else None
    b, m = cyc("base.json"), cyc("mcc.json")
    shape = fmt(dims) + (f" (SP {int(sp)//1024}KB)" if sp else "")
    rows.append(f"| {n} | {shape} | {L} | {split} | {ncl}×{ndnc} | {fmt(per_cl)} | {fmt(per_dnc)} | "
                f"{loops}" + (f" (ax{[i for i,t in enumerate(temporal) if t>1][0]}, step {fmt(step)})" if loops > 1 else "") +
                f" | {R}×{K}, {mdnc} DNC, {R//mdnc}×{K}/DNC | {b} | {m} | {m/b:.2f} |")
print("| case | shape | lines | rcl2 split | cl×dnc | per-cluster tile | per-DNC tile | rcl2 temporal | mcc | rcl2 cyc | mcc cyc | mcc/rcl2 |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
print("\n".join(rows))
