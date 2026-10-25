"""`(x @ w) * 0.125` at M=128, K=64, N=64: the perf case `tests/perf/dense/m128_k64_n64` with a scale after the
contraction, so the build has an epilogue on the VU (`TracedOp.epilogue`)."""

from __future__ import annotations

from kpl.surface import rb, spec

from mcc.kpl_declaration import declare
from mcc.kpl_machine import R100_EVT1, SHM


@rb.microcode(on=R100_EVT1.DNC)
def dense_scale(prog):
    @prog.symbol
    def _(ctx):
        ctx.add("M")
        ctx.add("K")
        ctx.add("N")

    @prog.signature
    def _(ctx):
        ctx.input("input", SHM.DLF16Tensor[spec(shape=("M", "K"))])
        ctx.input("kernel", SHM.DLF16Tensor[spec(shape=("K", "N"))])
        ctx.output("output", SHM.DLF16Tensor[spec(shape=("M", "N"))])

    @prog.body(style="compute")
    def _(x, w):
        return (x @ w) * 0.125


MAIN = declare(dense_scale, M=128, K=64, N=64)
