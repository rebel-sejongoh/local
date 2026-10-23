"""`dense` at input `[1, 16, 128, 64]` and kernel `[16, 1, 64, 64]` in kpl, for mcc to build.

One point of a K sweep. rcl2's dense is `scale × (input @ kernel) + offset`;
`base/manifest.json` fixes `scale` to 1 and `offset` to 0, so this is the plain `input @ kernel`.
Its tensors take rcl2's names.
"""

from __future__ import annotations

from kpl.surface import rb, spec

from mcc.kpl_declaration import declare
from mcc.kpl_machine import R100_EVT1, SHM


@rb.microcode(on=R100_EVT1.DNC)
def dense(prog):
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
        return x @ w


MAIN = declare(dense, M=512, K=256, N=64)
