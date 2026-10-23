"""Compare a run's output with numpy x @ w from the same SHM inputs. usage: check.py CASE_DIR WORKDIR"""
import json, sys
import numpy as np
from dlfloat16 import codec
from dnc_binutils.memfile import read_memfile
case, wd = sys.argv[1], sys.argv[2]
m = json.load(open(f"{case}/base/manifest.json"))
B = {b.get("tensor"): b for b in m["shm"]["blocks"] if b.get("tensor")}
dims = m["source"]["shapes"].split("input <")[1].split(">")[0].split("x")
K, M = int(dims[1]) * 64, int(dims[2])
shm = read_memfile(f"{wd}/SHM_final.txt")
dec = codec.dlf16_to_ieee_f32
def rows(start, n):
    return np.stack([np.asarray(dec(np.array(shm[start + i], dtype=np.uint16)), dtype=np.float64) for i in range(n)])
x = rows(B["input"]["start"], K // 64 * M).reshape(K // 64, M, 64).transpose(1, 0, 2).reshape(M, K)
w = rows(B["kernel"]["start"], K)  # N = 64
y = rows(B["output"]["start"], M)
ref = x @ w
err = np.abs(y - ref)
scale = np.abs(ref).max()
print(f"max_abs_err/max|ref| = {err.max()/scale:.3e}  mean = {err.mean()/scale:.3e}  rows_bad(>2^-6) = {int((err.max(1)/scale > 2**-6).sum())}")
