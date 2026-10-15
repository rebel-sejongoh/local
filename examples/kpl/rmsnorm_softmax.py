"""두 개 이상의 op를 가진 kpl 예제: fused RMSNorm, row softmax.
실행: cd codesigner/PrimitiveAuthor/mcc && uv run python ~/workspaces/local/examples/kpl/rmsnorm_softmax.py"""
from kpl.surface import rb, spec
from mcc.kpl_machine import R100, SHM
from mcc.kpl_declaration import declare

HIDDEN = 64


@rb.microcode(on=R100.DNC)
def rmsnorm(prog):
    """out[r,k] = x[r,k] * rsqrt(mean_k(x[r,k]^2) + eps) * w[r,k]"""
    @prog.symbol
    def _(ctx):
        ctx.add("R"); ctx.add("K")

    @prog.signature
    def _(ctx):
        ctx.input("x", SHM.F32Tensor[spec(shape=("R", "K"))])
        ctx.input("w", SHM.F32Tensor[spec(shape=("R", "K"))])
        ctx.output("out", SHM.F32Tensor[spec(shape=("R", "K"))])

    @prog.body(style="compute")
    def _(x, w):
        ms = (x * x).sum(over="K") * (1.0 / HIDDEN)   # mean of squares, axis K collapses
        r = (ms + 1e-6).rsqrt()                       # per-row scale
        return x * r * w                              # r broadcasts back over K


@rb.microcode(on=R100.DNC)
def softmax(prog):
    """out[r,k] = exp(x[r,k] - max_k x[r,:]) / sum_k exp(x[r,k] - max_k x[r,:])"""
    @prog.symbol
    def _(ctx):
        ctx.add("R"); ctx.add("K")

    @prog.signature
    def _(ctx):
        ctx.input("x", SHM.F32Tensor[spec(shape=("R", "K"))])
        ctx.output("out", SHM.F32Tensor[spec(shape=("R", "K"))])

    @prog.body(style="compute")
    def _(x):
        e = (x - x.max(over="K")).exp()
        return e / e.sum(over="K")


RMSNORM = declare(rmsnorm, R=256, K=HIDDEN)
SOFTMAX = declare(softmax, R=256, K=HIDDEN)

if __name__ == "__main__":
    from mcc.grounding import kpl_translate, kpl_roles, trace_print
    from mcc.grounding.trace import TracedOp
    for D in (RMSNORM, SOFTMAX):
        lv = D.microcode.level
        print("#" * 8, lv.name, D.workload)
        for i, op in enumerate(lv.body, start=len(lv.inputs)):
            print(f"  v{i} = {op.kind}{tuple('v%d'%a for a in op.args)}"
                  + (f" axis={op.axis}" if op.axis else "") + (f" combine={op.combine}" if op.combine else "")
                  + (f" imm={op.imm}" if op.imm is not None else ""))
        print("  exports:", lv.exports)
        a = kpl_translate.arithmetic_level_of(D.microcode, D.workload, {})
        L = kpl_roles.assign(a.level)
        print("  roles:", kpl_roles.table(L), " arm:", kpl_roles.arm(L))
        nodes = kpl_translate.dag_of(L, a.extents)
        for n in nodes:
            print("  Expr", {k: v for k, v in vars(n).items() if v not in (None, (), False)})
        try:
            t = TracedOp(tuple(nodes)).tiled(kpl_translate.tiling_for(L, a.extents))
            print(trace_print.format_tiled(t))
        except Exception as ex:
            print("  (tiled 실패:", type(ex).__name__, str(ex)[:200], ")")
