"""tiling / axis binding / seed(initial layout) / transforms / flood 결과를 단계별로 덤프.
실행: cd codesigner/PrimitiveAuthor/mcc && uv run python ~/workspaces/local/scripts/dump_layout_passes.py"""
import importlib.util, os
from mcc import spine, kpl_declaration
from mcc.grounding.place import derive_transforms
HERE = os.path.dirname(os.path.abspath(__file__))
def load(p, n):
    s = importlib.util.spec_from_file_location(n, p); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
sq = load('examples/kpl/sqrt.py', 'sq')
ex = load(os.path.join(HERE, '../examples/kpl/rmsnorm_softmax.py'), 'ex')
fx = load('tests/fixtures/for_llama_decoder_kpl_gap_test.py', 'fx')
cap = {}; orig = spine.synthesize
spine.synthesize = lambda t, a, **k: (cap.__setitem__('t', t), orig(t, a, **k))[1]
for name, D in [('sqrt', sq.MAIN), ('softmax', ex.SOFTMAX), ('matmul', kpl_declaration.declare(fx.gate_proj, R=64, K=64, I=64))]:
    kpl_declaration.build_sequential(D); t = cap.pop('t'); td = t.tiling
    print('#' * 12, name, D.workload)
    print('TilingDecision:', {k: getattr(td, k) for k in ('n_shards', 'reduce_size', 'shard_extent', 'lane_blocks', 'm_tiles', 'bin', 'active_dncs')})
    print('binding (outer→inner):')
    for ax, b in t.binding.items():
        print(f'   {ax}: ' + ' → '.join(f'{l.resource}{l.extent}{"" if l.in_leaf else "(out)"}' for l in b.levels) + ('  [reduced]' if b.reduced else ''))
    seeds = spine._ground_seeds(t)
    print('seeds (initial layouts):')
    for (u, tn), lay in seeds.items(): print(f'   ({u}, {tn}): {lay}')
    tr = derive_transforms(t, seeds)
    print('transforms:', tr or '{}')
