import sys; sys.path.insert(0, __file__.rsplit("/",1)[0])
exec(open(__file__.replace("ini.py","dump.py")).read())
from mcc.grounding import unit_layouts as UL
from mcc.lowering.initial import initial_ir, pretty
from mcc.grounding.mseq import passes
syn = CAP["synthesize"][0][0][0]
e = UL.unit_layouts(syn)
comp = dict(CAP["passes"][0][2])
for u in ("ABLU", "TU", "SPSU"):
    print(pretty(initial_ir(u, e, computes=comp.get(u))))
