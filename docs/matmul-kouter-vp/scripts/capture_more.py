"""Run capture_rcl2.py with extra dense shapes. usage: capture_more.py MxKxN ... --out DIR"""
import importlib.util, sys
P = "/home/sejongoh/workspaces/codesigner/PrimitiveAuthor/mcc/tests/perf/scripts/capture_rcl2.py"
spec = importlib.util.spec_from_file_location("capture_rcl2", P)
mod = importlib.util.module_from_spec(spec); sys.modules["capture_rcl2"] = mod; spec.loader.exec_module(mod)
shapes = [a for a in sys.argv[1:] if "x" in a and not a.startswith("-")]
rest = [a for a in sys.argv[1:] if a not in shapes]
for s in shapes:
    m, k, n = map(int, s.split("x"))
    mod.TEST_CASES[f"dense/m{m}_k{k}_n{n}"] = mod._dense(m, k, n)
for s in shapes:
    m, k, n = map(int, s.split("x"))
    sys.argv = [P, f"dense/m{m}_k{k}_n{n}", *rest]
    mod.main()
