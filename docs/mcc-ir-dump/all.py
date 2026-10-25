import sys
sys.path.insert(0, __file__.rsplit("/",1)[0])
exec(open(__file__.replace("all.py","dump.py")).read())
import pp
from mcc.grounding import kpl_ir, trace_print
SEP = lambda s: print(f"\n######## {s}")
lvl = K.MAIN.microcode.level
SEP("kpl decl.Level body"); print(lvl.body if hasattr(lvl,'body') else None)
g = kpl_ir.graph_of(lvl)
SEP("kpl_ir.Graph")
print(" inputs:", g.inputs); 
for n in g.nodes: print("  ", n)
syn = CAP["synthesize"][0][0][0]
SEP("TracedOp.nodes (Expr DAG)")
for n in syn.nodes: print("  ", pp.ex(n))
print("  axes=", syn.axes, " cross_dnc=", syn.cross_dnc, " unit_data=", getattr(syn, "unit_data", "<gone>"))
SEP("format_tiled"); print(trace_print.format_tiled(syn))
SEP("Mdmap"); print(syn.tiling.mdmap)
if CAP.get("plan") and CAP["plan"][0][2] is not None:
    sp = CAP["plan"][0][2]
    b = sp.block
    SEP("StreamPlan / StreamBlock")
    print(f"chunks={sp.chunks} unroll={sp.unroll} walks={sp.walks} tail={sp.tail} fold_walk={sp.fold_walk}")
    print("block: passes=", [[pp.ex(e) for e in ps] for ps in b.passes])
    print(" ", {k: getattr(b,k,"<gone>") for k in ("streamed","scalars","shared","broadcast","staged","collapsed","K","fold","ncores","stream_passes","stream_iters","outputs","units","handoffs","route")})
mp = CAP["mapped"][0][2]
SEP(f"Mapped op={mp.seqs[0].op} seqs={len(mp.seqs)} nets={len(mp.mpn.nets)}")
SEP("Mseq[0] (addressed)"); print(pp.mseq(mp.seqs[0], int(sys.argv[2]) if len(sys.argv)>2 else 60))
SEP("passes(seqs)")
for u, a in CAP["passes"][0][2]: print(" ", u, pp.ar(a) if not isinstance(a, tuple) or (a and hasattr(a[0],'kind')) else a)
SEP("Mpn[0]"); print(pp.mpn(mp.mpn.nets[0]))
SEP("events (dnc 0)")
for key, ev in mp.events.items():
    if key[0] == 0: print(" ", key, ev[:10], "..." if len(ev) > 10 else "")
fp = CAP["with_edges"][0][2]
SEP("FabricProgram (after with_edges)"); print(pp.fabric(fp))
SEP("UnitPrograms dnc 0")
for up in fp.unit_programs:
    if up.dnc == 0: print(pp.unit(up))
SEP("Scripts dnc 0 (per mpn process)")
for p in mp.mpn.nets[0].processes:
    print(f"process {p.unit}:"); print(pp.script(mp.script(0, p.unit)))
