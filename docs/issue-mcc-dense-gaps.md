mcc cannot build rebel_compute_lib2's single-token dense layer (M=1, K=1024, N=64)

## Motivation

- mcc's VP performance tests (#1953) compare mcc's code with code captured from rebel_compute_lib2, on the same op and shape.
- The first linear case to capture is rebel_compute_lib2's test `ci_rebel_evt1_dense_fp16_seq1_001`, in its `tests/src/develop/rebel/alpha_evt1/test_rbln_initgen_dense_fp16.py`.
  It has M = 1 (one token), K = 1024 and N = 64, on 2 clusters × 8 DNCs: the shape of a linear layer in a decode step.
- mcc cannot build it, for the two reasons below.
  Until it can, the performance tests will use a dense shape mcc can build, with rebel_compute_lib2's per-channel scale fixed to 1 and its offset to 0.

## What mcc refuses

1. **M = 1 with K = 1024.** rebel_compute_lib2 splits K over all 16 DNCs. mcc refuses in both ways it could build this:
   - Its default splits K over the 16 DNCs too. That needs a reduce across the two clusters, which mcc does not build:
     `cin_split=16 (K=1024 cross-DNC K-split > 8-way) is unvalidated: the CROSS-CLUSTER reduce ... is not built`
   - `build_sequential`'s `bin` option folds K into each DNC instead, so fewer DNCs split K and mcc splits M over the others. With `bin` 16, 8, 4 or 2, M = 1 cannot be split that way; for `bin` 16 the message is:
     `M=1 must be divisible by the M-shard count 16 (a ragged M-shard needs the pure-M box with a base<=Tr band)`

   With the default options, M = 16 and M = 64 at the same K and N do build.
2. **The per-channel scale and offset.** rebel_compute_lib2's dense computes `scale × (x @ w) + offset`, where `scale` and `offset` hold one value per output channel.
   Each is a third input to the matmul, but mcc's systolic matmul path takes exactly two.
   For `x @ w + offset`, declared as `x @ w + b`, the message is:
   `this seam derives a systolic placement for exactly one held and one streamed operand -- dense_offset traces 3 inputs ['b', 'w', 'x']`

   A constant multiplier, `(x @ w) * c`, does build.

To reproduce, run this from `PrimitiveAuthor/mcc` with `uv run python repro.py`. It prints the two refusals in 1, that M = 16 builds, and the refusal in 2.

```python
"""Run from PrimitiveAuthor/mcc: uv run python repro.py"""

from kpl.surface import rb, spec

from mcc import kpl_declaration
from mcc.kpl_declaration import declare
from mcc.kpl_machine import R100_EVT0, SHM


@rb.microcode(on=R100_EVT0.DNC)
def dense(prog):
    @prog.symbol
    def _(ctx):
        ctx.add("M")
        ctx.add("K")
        ctx.add("N")

    @prog.signature
    def _(ctx):
        ctx.input("x", SHM.F32Tensor[spec(shape=("M", "K"))])
        ctx.input("w", SHM.F32Tensor[spec(shape=("K", "N"))])
        ctx.output("y", SHM.F32Tensor[spec(shape=("M", "N"))])

    @prog.body(style="compute")
    def _(x, w):
        return x @ w


@rb.microcode(on=R100_EVT0.DNC)
def dense_offset(prog):
    @prog.symbol
    def _(ctx):
        ctx.add("M")
        ctx.add("K")
        ctx.add("N")

    @prog.signature
    def _(ctx):
        ctx.input("x", SHM.F32Tensor[spec(shape=("M", "K"))])
        ctx.input("w", SHM.F32Tensor[spec(shape=("K", "N"))])
        ctx.input("b", SHM.F32Tensor[spec(shape=("M", "N"))])
        ctx.output("y", SHM.F32Tensor[spec(shape=("M", "N"))])

    @prog.body(style="compute")
    def _(x, w, b):
        return x @ w + b


def build(label, entry, **knobs):
    try:
        kpl_declaration.build_sequential(entry, **knobs)
        print(f"{label}: builds")
    except NotImplementedError as e:
        print(f"{label}: {e}")


build("1, default", declare(dense, M=1, K=1024, N=64))
build("1, bin=16", declare(dense, M=1, K=1024, N=64), bin=16)
build("M=16, default", declare(dense, M=16, K=1024, N=64))
build("2", declare(dense_offset, M=64, K=1024, N=64))
```
