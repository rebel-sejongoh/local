"""Print mcc's IR just before mseq for a kpl declaration: the traced op (Expr DAG), `format_tiled`, the Mdmap and,
on the streaming arm, the StreamPlan.

    cd PrimitiveAuthor/mcc && uv run python <this dir>/tiled.py <kernel.py>
"""
import sys
sys.path.insert(0, "/home/sejongoh/workspaces/local/docs/mcc-ir-dump")
import pp
from mcc import __main__ as cli, kpl_declaration, spine
from mcc.grounding import mdmap_stream, trace_print
from mcc.grounding.machine import DEFAULT_HW

CAP = {}
def spy(mod, name):
    orig = getattr(mod, name)
    def f(*a, **kw):
        rec = [a, kw, None]
        CAP.setdefault(name, []).append(rec)          # recorded before the call, so a failing call shows too
        rec[2] = orig(*a, **kw)
        return rec[2]
    setattr(mod, name, f)

spy(spine, "synthesize")
spy(mdmap_stream, "plan")
entry = cli.load_entry(sys.argv[1])
from mcc.grounding import kpl_ir, kpl_translate
print("# kpl body:", entry.microcode.level.body)
print("# Expr DAG (kpl_translate.dag_of, before tiling)")
for n in kpl_translate.dag_of(entry.microcode.level, dict(entry.workload)):
    print("  ", pp.ex(n))
err = None
try:
    kpl_declaration.build_sequential(entry, hw=DEFAULT_HW)
except Exception as e:                       # the IR before mseq still prints; report where the build stopped
    err = e
if not CAP.get("synthesize"):
    print(f"\n# refused before tiling: {type(err).__name__}: {err}")
    sys.exit(0)
syn = CAP["synthesize"][0][0][0]
print("\n# traced op: axes =", syn.axes)
print("\n# format_tiled")
print(trace_print.format_tiled(syn))
print("\n# Mdmap")
print(syn.tiling.mdmap)
if CAP.get("plan") and CAP["plan"][0][2] is not None:
    sp = CAP["plan"][0][2]
    b = sp.block
    print("\n# StreamPlan / StreamBlock")
    print(f"chunks={sp.chunks} unroll={sp.unroll} walks={sp.walks} tail={sp.tail}")
    print("passes =", [[pp.ex(e) for e in ps] for ps in b.passes])
if err is not None:
    print(f"\n# the build stopped after this IR: {type(err).__name__}: {err}")
