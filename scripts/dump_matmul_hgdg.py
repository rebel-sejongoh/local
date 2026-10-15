"""matmul(gate_proj, 64x64x64)의 tiled trace, axis binding, HGDG edge layout 덤프. 실행: cd codesigner/PrimitiveAuthor/mcc && uv run python ~/workspaces/local/scripts/dump_matmul_hgdg.py"""
import importlib.util
from mcc import spine, kpl_declaration
from mcc.grounding import trace_print
s=importlib.util.spec_from_file_location('fx','tests/fixtures/for_llama_decoder_kpl_gap_test.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
cap={}; o=spine.synthesize
def syn(t,a,**k): cap['t']=t; return o(t,a,**k)
spine.synthesize=syn
D=kpl_declaration.declare(m.gate_proj, R=64, K=64, I=64)
r=kpl_declaration.build_sequential(D)
t=cap['t']; print(trace_print.format_tiled(t))
print('binding:'); [print('  ',k,v) for k,v in t.binding.items()]
_,h=spine.realize(t, __import__('mcc.assembling.image',fromlist=['DeviceAlloc']).DeviceAlloc(), return_hgdg=True)
for n in h.nodes.values() if isinstance(h.nodes,dict) else h.nodes: print('  NODE',n.unit,n.kind)
for k,lay in h.items(): print('  EDGE',k,'  ',lay)
