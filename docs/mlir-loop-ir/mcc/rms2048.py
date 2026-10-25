"""Llama's RMSNorm at 1024 tokens of hidden size 128 in kpl, declared in rcl2's layout, for mcc to build.

rcl2's T5 layernorm is the same op. Its input and output are `[1, K/64, R, 64]`, blocks of 64 hidden values
outermost, which this declaration states as `block`.

Both codes approximate `rsqrt` each its own way, so each is held to `reference` instead of to the other's bits.
"""

from __future__ import annotations

import numpy as np
from kpl.surface import rb, spec

from mcc.kpl_declaration import declare
from mcc.kpl_machine import R100_EVT1, SHM

R, K, LANES = 2048, 512, 64
EPS = 1e-5  # RblnLayernormT5Args's default, which capture_rcl2.py leaves as is

BLOCK = SHM.layout("block")


@rb.microcode(on=R100_EVT1.DNC)
def rms_norm(prog):
    @prog.symbol
    def _(ctx):
        ctx.add("R")
        ctx.add("K", lanes=True)

    @prog.signature
    def _(ctx):
        ctx.input("input", SHM.DLF16Tensor[spec(shape=("R", "K"), layout=BLOCK)])
        ctx.input("scale", SHM.DLF16Tensor[spec(shape=("K",), layout=BLOCK)])
        ctx.output("output", SHM.DLF16Tensor[spec(shape=("R", "K"), layout=BLOCK)])

    @prog.body(style="compute")
    def _(x, w):
        return (
            x * ((x * x).reduce(axis="K", combine="add") * (1.0 / K) + EPS).rsqrt() * w
        )


MAIN = declare(rms_norm, R=R, K=K)


def reference(inputs: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    """RMSNorm of each token in `inputs["input"]`, with rcl2's epsilon, in rcl2's layout, as `output`."""
    x = inputs["input"].reshape(K // LANES, R, LANES).transpose(1, 0, 2).reshape(R, K)
    w = inputs["scale"].reshape(K)
    y = x / np.sqrt((x * x).mean(axis=1, keepdims=True) + EPS) * w
    return {
        "output": y.reshape(R, K // LANES, LANES).transpose(1, 0, 2).reshape(-1, LANES)
    }
