"""mcc env: write kernel.py for a captured add test case from its SHM_map, pick R x K."""
import sys
from pathlib import Path
tc = Path(sys.argv[1])
lines = (tc / "base/data/SHM_map.txt").read_text().splitlines()
starts, counts = {}, {}
for i, l in enumerate(lines):
    if l.startswith("# mem-map for ") and "dummy" not in l:
        t = l.split("for ")[1].split("::")[0]
        j = i + 1
        while lines[j].startswith("#"): j += 1
        k = j
        while k < len(lines) and not lines[k].startswith("#"): k += 1
        starts[t], counts[t] = int(lines[j].split()[0], 16), k - j
L = counts["input1"]
a = next(d for d in (32, 16, *range(15, 0, -1)) if L % d == 0)  # row groups of 64 lanes
R, K = 64 * a, L // a
src = (Path(__file__).parent / "kernel_tmpl.py").read_text()
src = src.replace("@R@", str(R)).replace("@K@", str(K)).replace("@I1@", hex(starts["input1"])) \
         .replace("@I2@", hex(starts["input2"])).replace("@O@", hex(starts["output"]))
(tc / "kernel.py").write_text(src)
print(f"lines={L} R={R} K={K} addrs={ {k: hex(v) for k, v in starts.items()} }")
