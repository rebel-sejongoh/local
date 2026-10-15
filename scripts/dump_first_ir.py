"""mcc 첫 IR(Expr DAG) 덤프. 실행: cd codesigner/PrimitiveAuthor/mcc && uv run python ~/workspaces/local/scripts/dump_first_ir.py"""
import sys, importlib.util
from mcc.grounding import kpl_translate, kpl_roles, trace_print
from mcc.grounding.trace import TracedOp
def load(p,name):
    s=importlib.util.spec_from_file_location(name,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
sq=load('examples/kpl/sqrt.py','sq')
fx=load('tests/fixtures/for_llama_decoder_kpl_gap_test.py','fx')
for tag,D in [('sqrt',sq.MAIN),('rms_norm_stats',fx.RMS_NORM_STATS),('rms_norm_apply',fx.RMS_NORM_APPLY),('gate_proj',fx.GATE_PROJ)]:
    print('#'*10,tag, D.workload)
    lv=D.microcode.level
    print('body:',lv.body,' exports:',lv.exports)
    a=kpl_translate.arithmetic_level_of(D.microcode,D.workload,{})
    L=kpl_roles.assign(a.level)
    print('roles:',kpl_roles.table(L),' arm:',kpl_roles.arm(L))
    nodes=kpl_translate.dag_of(L,a.extents)
    for n in nodes:
        d={k:v for k,v in n.__dict__.items() if v not in (None,(),False)} if hasattr(n,'__dict__') else n
        print('  Expr',d)
