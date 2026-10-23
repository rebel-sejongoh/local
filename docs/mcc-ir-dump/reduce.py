"""all.py, then the root's and a leaf's Mseq and the reduce edges: for a K-split (cross-DNC reduce) case."""
import sys
__file__ = __file__.replace("reduce.py", "all.py")
exec(open(__file__).read())
lim = int(sys.argv[2]) if len(sys.argv) > 2 else 200
by = {s.dnc: s for s in mp.seqs}
for d in (0, 1):
    SEP(f"Mseq dnc={d} (addressed)"); print(pp.mseq(by[d], lim))
SEP("Mpn[1] (a leaf)"); print(pp.mpn(mp.nets[1]))
SEP("Mpn dnc=0 reduce units (full)")
net0 = next(n for n in mp.nets.values() if n.dnc == 0) if isinstance(mp.nets, dict) else mp.nets[0]
for p in net0.processes:
    if p.unit in ("NCLU", "SPLU0", "VU", "VU0", "SPSU0", "NCSU"):
        print(f"  process {p.unit}: {len(p.body)} stmts")
        for s, w in zip(p.body, p.where):
            print(f"    {str(w):<12} {pp.stmt(s)}")
net1 = mp.nets[1]
SEP("Mpn dnc=1 NCSU (full)")
for p in net1.processes:
    if p.unit == "NCSU":
        for s, w in zip(p.body, p.where):
            print(f"    {str(w):<12} {pp.stmt(s)}")
SEP("FabricProgram reduce edges (all)")
print(" ", fp.edges if hasattr(fp, "edges") else None)
