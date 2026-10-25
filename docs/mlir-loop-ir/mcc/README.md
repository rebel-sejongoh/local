mcc's IR just before mseq (and the Expr DAG before tiling) for the examples of `../../mlir-loop-ir.md`, printed by `../tiled.py`:

    cd PrimitiveAuthor/mcc && uv run python <docs>/mlir-loop-ir/tiled.py <docs>/mlir-loop-ir/mcc/<kernel>.py

| Kernel | Body | `.out` |
|---|---|---|
| `ew.py` | `x.exp() * 0.5 + r`, R = 2048 | the traced op |
| `rms2048.py` | RMSNorm, R = 2048, K = 512 (`tests/perf/rms_norm`'s kernel at this size) | the traced op |
| `mm2048.py` | `(x @ w) * 0.125`, M = 2048, K = 512, N = 256 | the traced op; the build stops later (SPSU block over 255 instructions) |
| `mm2048relu.py` | `((x @ w) * 0.125).max(0.0)` | the traced op; the build stops later (the VU cannot lower `maximum` in a drain) |
| `mm1.py` | `((x * gamma) @ w + bias).max(0.0)` | the Expr DAG; refused before tiling |
| `normmm.py` | RMSNorm, then `@ w` | the Expr DAG; refused before tiling |
| `softmax.py` | `tests/perf/softmax_last_axis_lanes/1x1x1024x512`: softmax over K = 512, R = 1024 | the traced op |
