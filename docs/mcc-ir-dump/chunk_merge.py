"""Which chunk boundaries of a systolic mseq the syncs depend on: merge each pair of adjacent chunks of DNC 0's
mseq, split it again (`mpn.split`), and list the processes whose syncs change. Run from `PrimitiveAuthor/mcc`:

    uv run python ~/workspaces/local/docs/mcc-ir-dump/chunk_merge.py [kernel.py]

The kernel defaults to `dense_scale_kernel.py` beside this script; it is placed by `build_sequential`."""
import sys, importlib.util
from dataclasses import replace
from pathlib import Path
from mcc import kpl_declaration, spine
from mcc.grounding import mpn as M, mseq_matmul
from mcc.grounding.mseq import Pass, Chunk, Loop
from mcc.grounding.machine import DEFAULT_HW
CAP = {}
def spy(mod, name):
    orig = getattr(mod, name)
    def f(*a, **kw):
        r = orig(*a, **kw); CAP[name] = (a, r); return r
    setattr(mod, name, f)
spy(spine, "_run"); spy(mseq_matmul, "chip")
path = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).parent / "dense_scale_kernel.py")
spec = importlib.util.spec_from_file_location("k", path)
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
kpl_declaration.build_sequential(k.MAIN, hw=DEFAULT_HW)
t = CAP["chip"][0][3]
print({f: getattr(t, f) for f in ("m_tiles", "bin", "lane_blocks", "reduce_size", "double_buffer")})
seq = CAP["_run"][1][0].seqs[0]
MOVES = ("load", "store", "stage", "write", "pop", "push")
def syncs(s):
    net = M.split(s, 1)
    return net, {p.unit: [e for e in M.protocol(M.events(p)) if e[0] not in MOVES] for p in net.processes}
def sites(body, at=()):
    """Every pair of adjacent chunks: the path of the body that holds them, and the first's index."""
    for i, it in enumerate(body):
        if isinstance(it, (Pass, Loop)):
            yield from sites(it.body, at + (i,))
        if i + 1 < len(body) and isinstance(it, Chunk) and isinstance(body[i + 1], Chunk):
            yield at, i
def merged(body, at, i):
    if not at:
        a, b = body[i], body[i + 1]
        return body[:i] + (replace(a, body=a.body + b.body),) + body[i + 2:]
    j = at[0]
    return body[:j] + (replace(body[j], body=merged(body[j].body, at[1:], i)),) + body[j + 1:]
net, base = syncs(seq)
print(f"as built: {len(net.channels)} channels, violations {M.violations(net)}")
for at, i in sites(seq.body):
    net, s = syncs(replace(seq, body=merged(seq.body, at, i)))
    changed = {u: (len(base[u]), len(s[u])) for u in base if base[u] != s[u]}
    print(f"body{list(at)} chunk {i}+{i + 1}: {len(net.channels)} channels, violations {M.violations(net)}, "
          f"syncs changed (before, after) {changed}")
