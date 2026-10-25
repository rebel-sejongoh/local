"""Spy on mcc's pipeline and pickle every intermediate artifact for inspection."""
import importlib.util, json, sys, pickle
from pathlib import Path
from foundation import r100
from kpl import decl
from mcc import kpl_declaration, spine
from mcc.lowering import mpn_syncs
from mcc.grounding import mdmap_stream

case = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("k", case / "kernel.py")
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
shm = json.loads((case / "base" / "manifest.json").read_text())["shm"]
addresses = {b["tensor"]: b["start"] for b in shm["blocks"]
             if b["role"] == "output" or (b["role"] == "input" and "fill" not in b)}
last = shm["blocks"][-1]
HW = {decl.Machine.R100_EVT0: r100.DEFAULT_HW, decl.Machine.R100_EVT1: r100.EVT1_HW}
hw = HW[k.MAIN.microcode.level.machine]

CAP = {}
def spy(mod, name, key=None):
    orig = getattr(mod, name)
    def f(*a, **kw):
        r = orig(*a, **kw)
        CAP.setdefault(key or name, []).append((a, kw, r))
        return r
    setattr(mod, name, f)

spy(mdmap_stream, "plan")
spy(spine, "_run")
spy(spine, "passes")
spy(spine, "derive_unit")
spy(spine, "collect_programs")
spy(spine, "with_edges")
spy(spine, "bind_templates")
spy(spine, "synthesize")
spy(spine, "realize")
built = kpl_declaration.build(k.MAIN, addresses, red_addr=last["start"] + last["lines"] + 1, hw=hw)
print("images", [len(x) for x in built.dnc_images])
CAP["mapped"] = [(a, kw, r[0]) for a, kw, r in CAP["_run"]]
globals()["K"] = k
