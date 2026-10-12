"""rcl2 interpreter: capture one DLFP16 add of the given dims as test case `name` under `out`."""
import importlib.util, sys, os
from pathlib import Path
name, spec_, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
dims_s, _, sp = spec_.partition("@")
dims = [int(x) for x in dims_s.split("x")]
scripts = Path.home() / "workspaces/codesigner/PrimitiveAuthor/mcc/tests/perf/scripts"
spec = importlib.util.spec_from_file_location("capture_rcl2", scripts / "capture_rcl2.py")
c = importlib.util.module_from_spec(spec); sys.modules["capture_rcl2"] = c; spec.loader.exec_module(c)
sub64 = dims[-1] < 64
def args():
    from python import RblnAddArgs, RblnAddSub64Args, TensorInitgen
    if sub64:
        last = len(dims) - 1
        t = lambda **k: TensorInitgen(align_pad_amount=0, align_pad_axes=[last], **k)
        return RblnAddSub64Args(validate_args=True, ncluster=2, ndnc_per_cluster=8, tiling_in_primitive=True,
                                input1=t(dims=dims), input2=t(dims=dims), output=t())
    a = RblnAddArgs(ncluster=2, ndnc_per_cluster=8, tiling_in_primitive=True,
                    input1=TensorInitgen(dims=dims), input2=TensorInitgen(dims=dims))
    if sp:  # an SP budget smaller than the default makes rcl2 tile within a DNC
        a.sp_alloc = int(sp)
    return a
test = "test_rbln_initgen_add_sub64.py" if sub64 else "test_rbln_initgen_add.py"
c.TEST_CASES[name] = c.TestCase(test="tests/src/develop/rebel/alpha/" + test, test_id=None,
                                mode="ALPHA", device_mode="REBEL_EVT1", vp_skip_tu=True, args=args)
rcl2 = c.DEFAULT_RCL2.resolve(); sys.path.insert(0, str(rcl2)); os.chdir(rcl2)
print("captured", c.capture(name, rcl2, out.resolve(), True))
