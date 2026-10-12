from kpl.surface import rb, spec
from mcc.kpl_declaration import declare
from mcc.kpl_machine import R100, SHM


@rb.microcode(on=R100.DNC)
def add(prog):
    @prog.symbol
    def _(ctx):
        ctx.add("R")
        ctx.add("K")

    @prog.signature
    def _(ctx):
        ctx.input("input1", SHM.F32Tensor[spec(shape=("R", "K"))])
        ctx.input("input2", SHM.F32Tensor[spec(shape=("R", "K"))])
        ctx.output("out", SHM.F32Tensor[spec(shape=("R", "K"))])

    @prog.body(style="compute")
    def _(a, b):
        return a + b


MAIN = declare(add, R=@R@, K=@K@)
ADDRESSES = {"input1": @I1@, "input2": @I2@, "out": @O@}
