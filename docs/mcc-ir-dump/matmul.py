"""A systolic case from its declaration to its JIR: the mseq builder's inputs, DNC 0's mseq, every DNC 0 process's
Script, and the VU's template. Run from `PrimitiveAuthor/mcc`:

    uv run python ~/workspaces/docs/mcc-ir-dump/matmul.py [kernel.py] [mseq_line_limit]

The kernel defaults to `dense_scale_kernel.py` beside this script; it is placed by `build_sequential`."""
import sys, importlib.util, dataclasses
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import pp
from mcc import kpl_declaration, spine
from mcc.grounding import trace_print, mseq_matmul
from mcc.grounding.machine import DEFAULT_HW
CAP = {}
def spy(mod, name):
    orig = getattr(mod, name)
    def f(*a, **kw):
        r = orig(*a, **kw); CAP.setdefault(name, []).append((a, kw, r)); return r
    setattr(mod, name, f)
for mod, name in ((spine, "synthesize"), (spine, "_run"), (spine, "with_edges"), (mseq_matmul, "chip")):
    spy(mod, name)
path = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).parent / "dense_scale_kernel.py")
lim = int(sys.argv[2]) if len(sys.argv) > 2 else 80
spec = importlib.util.spec_from_file_location("k", path)
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
kpl_declaration.build_sequential(k.MAIN, hw=DEFAULT_HW)
SEP = lambda s: print(f"\n######## {s}")
syn = CAP["synthesize"][0][0][0]
SEP("Expr DAG"); [print(" ", pp.ex(n)) for n in syn.nodes]
SEP("format_tiled"); print(trace_print.format_tiled(syn))
SEP("TracedOp.arith (card on the TU, epilogue on the drain unit)")
for u, a in syn.arith.items(): print(f"  {u}: {a}")
(m, kk, n, tiling, arith), _kw, _ = CAP["chip"][0]
SEP(f"mseq_matmul.chip inputs: m={m} k={kk} n={n}")
t = tiling
print("  TilingDecision", {f.name: getattr(t, f.name) for f in dataclasses.fields(t)
                            if getattr(t, f.name) != f.default})
print("  derived", {p: getattr(t, p) for p in ("per_dnc_rows", "tile_rows", "numncores", "ncore_rows", "active_dncs", "sp_banks")})
print("  Mdmap", t.mdmap)
print("  arith", arith)
mp = CAP["_run"][0][2][0]
SEP("Mseq[0] (addressed)"); print(pp.mseq(mp.seqs[0], lim))
net = mp.mpn.nets[0]
SEP(f"Mpn[0]: {len(net.processes)} processes, {len(net.channels)} channels")
for c in net.channels: print(f"  {c.producer} -> {c.consumer} {c.transport}/{c.protocol} depth={c.depth}")
SEP("Scripts dnc 0")
for p in net.processes:
    print(pp.script(mp.script(0, p.unit), 24))
SEP("UnitProgram VU dnc 0")
for up in CAP["with_edges"][0][2].unit_programs:
    if up.dnc == 0 and up.unit == "VU": print(pp.unit(up))
