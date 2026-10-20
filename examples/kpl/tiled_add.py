"""Elementwise add, tiled by hand in space (over the DNCs) and in time (tiles one after another).

    x, y, out : [R, K]   K rides the 64 lanes of a DNC (streaming layout), R is the lines.

The tiling is written out, so the compiler has no tiling to choose:

    CP   : split R into DNC_COUNT parts            -> DNC.map(add_dnc, ...)    space
    DNC  : split its R / DNC_COUNT lines into T     -> TIME.map(add_tile, ...)  time
    tile : x + y on R / (DNC_COUNT * T) lines        compute

With R=1024, K=64, T=4: each DNC owns 64 lines and walks them as 4 tiles of 16 lines.
"""

from __future__ import annotations

import numpy as np
from kpl.reference import reference
from kpl.surface import even, rb, spec
from mcc.kpl_machine import HBM, R100_EVT0, SHM

#: Temporal tiles per DNC.
T = 4
DNC_COUNT = R100_EVT0.CP.dnc_count


def _streaming(space):
    return space.F32Tensor[spec(shape=("R", "K"), layout=space.layout("streaming"))]


@rb.microcode(on=R100_EVT0.DNC)
def add_tile(prog):
    """One tile on one DNC: `x + y` over the lines it is handed."""

    @prog.symbol
    def _(ctx):
        ctx.add("R")
        ctx.add("K", lanes=True)

    @prog.signature
    def _(ctx):
        ctx.input("x", _streaming(SHM))
        ctx.input("y", _streaming(SHM))
        ctx.output("out", _streaming(SHM))

    @prog.body(style="compute")
    def _(x, y):
        return x + y


@rb.microcode(on=R100_EVT0.DNC)
def add_dnc(prog):
    """One DNC's share, walked in time: its lines split into `T` tiles, `add_tile` on each in turn."""

    @prog.symbol
    def _(ctx):
        ctx.add("R")
        ctx.add("K", lanes=True)

    @prog.signature
    def _(ctx):
        ctx.input("x", _streaming(SHM))
        ctx.input("y", _streaming(SHM))
        ctx.output("out", _streaming(SHM))

    @prog.body(style="compose")
    def _(ctx, x, y):
        xs = ctx.split(x, "R", into=even(T))
        ys = ctx.split(y, "R", into=even(T))
        return ctx.TIME.map(add_tile, xs, ys)


@rb.kernel(on=R100_EVT0.CP)
def tiled_add(prog):
    """The whole problem: its lines split over every DNC, each DNC running `add_dnc` on its share."""

    @prog.symbol
    def _(ctx):
        ctx.add("R")
        ctx.add("K")

    @prog.signature
    def _(ctx):
        ctx.input("x", HBM.F32Tensor[spec(shape=("R", "K"))])
        ctx.input("y", HBM.F32Tensor[spec(shape=("R", "K"))])
        ctx.output("out", HBM.F32Tensor[spec(shape=("R", "K"))])

    @prog.body(style="compose")
    def _(ctx, x, y):
        xs = ctx.split(x, "R", into=even(DNC_COUNT))
        ys = ctx.split(y, "R", into=even(DNC_COUNT))
        return ctx.DNC.map(add_dnc, xs, ys)


@reference(tiled_add, workload={"R": 1024, "K": 64}, tolerance=lambda golden, got: (bool(np.allclose(golden, got)), ""))
def _tiled_add_ref(x, y):
    return x + y


MAIN = tiled_add
