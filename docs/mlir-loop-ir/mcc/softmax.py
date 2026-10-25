"""`softmax_last_axis` at `[1, 1, 1024, 512]` in kpl, declared in rcl2's layout, for mcc to build.

It stands for the Qwen3-Next and Qwen3.5 MoE router, 512 experts, at 1024 tokens.

rcl2 takes the softmax over the last axis, so each of its 1024 rows is 512 contiguous values: 8 SHM lines. This
declaration puts `K` on the lanes and states both tensors `row`, so mcc reads and writes row `r` at
lines `8r` to `8r + 7` as rcl2 does.

Both codes approximate `exp` and the reciprocal, each its own way, so each is held to `reference`
instead of to the other's bits.
"""

from __future__ import annotations

import numpy as np
from kpl.surface import rb, spec

from mcc.kpl_declaration import declare
from mcc.kpl_machine import R100_EVT1, SHM

R, K, LANES = 1024, 512, 64

ROW = SHM.layout("row")


@rb.microcode(on=R100_EVT1.DNC)
def softmax(prog):
    @prog.symbol
    def _(ctx):
        ctx.add("R")
        ctx.add("K", lanes=True)

    @prog.signature
    def _(ctx):
        ctx.input("input", SHM.DLF16Tensor[spec(shape=("R", "K"), layout=ROW)])
        ctx.output("output", SHM.DLF16Tensor[spec(shape=("R", "K"), layout=ROW)])

    @prog.body(style="compute")
    def _(x):
        m = x.reduce(axis="K", combine="max")
        e = (x - m).exp()
        return e * e.reduce(axis="K", combine="add").recip()


MAIN = declare(softmax, R=R, K=K)


def reference(inputs: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    """The softmax of each row of `inputs["input"]`, in rcl2's layout, as `output`."""
    x = inputs["input"].reshape(R, K)
    e = np.exp(x - x.max(axis=1, keepdims=True))
    return {"output": (e / e.sum(axis=1, keepdims=True)).reshape(-1, LANES)}
