from kpl.surface import rb, spec
from mcc.kpl_declaration import declare
from mcc.kpl_machine import R100_EVT1, SHM

@rb.microcode(on=R100_EVT1.DNC)
def mm(prog):
    @prog.symbol
    def _(ctx):
        ctx.add("M")
        ctx.add("K")
        ctx.add("N")

    @prog.signature
    def _(ctx):
        ctx.input("x", SHM.DLF16Tensor[spec(shape=("M", "K"))])
        ctx.input("w", SHM.DLF16Tensor[spec(shape=("K", "N"))])
        ctx.output("y", SHM.DLF16Tensor[spec(shape=("M", "N"))])

    @prog.body(style="compute")
    def _(x, w):
        return ((x @ w) * 0.125).max(0.0)

MAIN = declare(mm, M=2048, K=512, N=256)
