from kpl.surface import rb, spec
from mcc.kpl_declaration import declare
from mcc.kpl_machine import R100_EVT1, SHM

@rb.microcode(on=R100_EVT1.DNC)
def ew(prog):
    @prog.symbol
    def _(ctx):
        ctx.add("R")
        ctx.add("C", lanes=True)

    @prog.signature
    def _(ctx):
        ctx.input("x", SHM.DLF16Tensor[spec(shape=("R", "C"))])
        ctx.input("r", SHM.DLF16Tensor[spec(shape=("R", "C"))])
        ctx.output("y", SHM.DLF16Tensor[spec(shape=("R", "C"))])

    @prog.body(style="compute")
    def _(x, r):
        return x.exp() * 0.5 + r

MAIN = declare(ew, R=2048, C=64)
