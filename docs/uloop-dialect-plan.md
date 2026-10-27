# Plan: a ULoop dialect prototype for the fused loop IR

Goal: define the fused loop IR of [`mlir-loop-ir.md`](mlir-loop-ir.md) as an MLIR dialect, ULoop, and lower mcc's
traced op (the level before mseq) into it. Matmul and elementwise unit tests verify the lowering.

ULoop is the first of three dialects: ULoop (microcode loop: the fused loop IR), UFlow (microcode dataflow: the
dataflow loop IR) and UMach (microcode machine code: the machine IR). UCommon holds what they share.

## Where

- Worktree: `/home/sejongoh/workspaces/codesigner-mlir`, branch `mcc-uloop`. It is a worktree of
  `/home/sejongoh/workspaces/codesigner`.
- The MLIR build is on dev (#2866): `PrimitiveAuthor/mcc/mlir/`, a CMake tree against a prebuilt LLVM/MLIR
  release, with lit tests, Python bindings and the `ci-mcc-mlir` lane. #2897 (open) builds that release in the
  repo; `mcc-uloop` forks from its branch `mcc-llvm-release` and moves onto dev once it merges.
- M2 is in its own worktree while M1 is under review: `/home/sejongoh/workspaces/codesigner-uloop`, branch
  `mcc-uloop-interp` (on `mcc-uloop` at `0dbf0d748`). It builds against the LLVM/MLIR installed by
  the `codesigner-mlir` worktree: `LLVM_PREFIX=/home/sejongoh/workspaces/codesigner-mlir/build/llvm/llvm-23.1.3-mlir-v1`.

## Layout

```
PrimitiveAuthor/mcc/mlir/
  CMakeLists.txt
  include/Dialect/UCommon/    # shared types and attributes: dlf16, (if needed) a vector type, #shm / #sp
  include/Dialect/ULoop/      # ULoopDialect.td, ULoopOps.td, headers
  include/mcc-c/Dialects.h    # C API
  lib/Dialect/{UCommon,ULoop}/
  lib/CAPI/
  tools/mcc-opt/              # one tool for ULoop, and later UFlow and UMach
  python/                     # bindings: mlir_mcc.dialects.{ucommon,uloop}
  scripts/{fetch_llvm,build}.sh
  tests/                      # renamed from test/
    ULoop/*.mlir              # lit: round trips, verifier errors
    python/                   # binding tests
    lowering/                 # pytest: interpreter, elementwise and matmul lowering
PrimitiveAuthor/mcc/src/mcc/uloop/   # Python: builders, interpreter, lowering from the traced op
```

## Decisions

| Item | Decision |
|---|---|
| Dialects | One dialect for the fused loop IR, `uloop`. Unit names go inside the op name: `uloop.nclu.load`, `uloop.spsu.store`, `uloop.vu.fma`, `uloop.mxu.matmul`, `uloop.psum.accumulate` |
| Shared types | `ucommon`: `!ucommon.dlf16`, memory spaces `#ucommon.shm` / `#ucommon.sp`; a vector type if the builtin one does not take dlf16 |
| Loops and addresses | No affine dialect. `uloop.for %i = 0 to n` (static bounds, step 1, always sequential). `%d = uloop.dnc_id` and `%nc = uloop.ncore_id` sit directly in a pipeline, whose `ncores` gives the NCore count. Access ops carry a builtin `AffineMap` attribute over loop indices, `%d` and `%nc`, printed as expressions with `parseAffineMapOfSSAIds` / `printAffineMapOfSSAIds`: `%sp_x[%kb, %nc * 64 + %g * 16 + %i * 4]` |
| Kernel | `func.func` with `uloop.spmd_dncs`; buffers from `uloop.alloc`; `uloop.pipeline` takes the buffers and has `%d` as its block argument |
| Element type | Try `vector<64x!ucommon.dlf16>` first. If the builtin vector rejects it, define `!ucommon.vec<…>` implementing `MemRefElementTypeInterface` |
| Tool | `mcc-opt` |
| Lowering | Python, through the MLIR Python bindings: `TracedOp` and `TilingDecision` are Python objects |
| Element types | bf16 first: lines, tiles and weight tiles take `bf16` as well as `!ucommon.dlf16` (both 128-byte lines). The interpreter runs a kernel whose lanes are all bf16 or all dlf16, rounding ties away from zero as the VP does (checked bit for bit against the VP on add) |
| Oracle | A C++ interpreter of ULoop (`lib/Interp`), called from Python as `_mccDialects.run(module, inputs)`; its result is compared with numpy. Python is too slow here: the ops are small (a 4x64 @ 64x64 matmul takes ~1 µs in numpy) and a large layer runs millions of them, so per-op dispatch dominates |
| Interpreter design | A pre-decode pass per module keeps the loop tree (no unrolling): each loop is `{trip count, iv slot, body}`, each access gets its buffer, base offset and one stride per enclosing loop (`addr = base + Σ stride_k · iv_k`); a non-affine index is refused there. Each (DNC, NCore) pair of a pipeline is a work item run with `llvm::ThreadPool`; each item has its own ivs and registers, the NCores of a DNC share its SP, and SHM is shared. Threading can be turned off (one thread, in order) for debugging; a debug option checks that items write disjoint SHM |

## Steps

| Step | Work | Tests |
|---|---|---|
| 0 (done, `727fe8b62`) | Replace `tst` with UCommon (`!ucommon.dlf16`) and ULoop (`uloop.for` only); `tst-opt` with `mcc-opt`; `mlir_tst` with `mlir_mcc` | `tests/UCommon/types.mlir` (dlf16 in vector and memref), `tests/ULoop/{roundtrip,invalid}.mlir`, `tests/python/build_and_run.py` |
| M1 (done, `727fe8b62`, `0dbf0d748`) | UCommon and ULoop: types, attributes, ops, verifiers, custom syntax. `0dbf0d748`: `uloop.dnc_id`/`uloop.ncore_id` replace `dnc(%d)` and spatial loops; `psum.block` splits into `psum.block_rw` and `psum.block_r` | `tests/ULoop/{roundtrip,invalid}.mlir` with the four examples of the design doc: elementwise, matmul with SP partial sums, matmul with register partial sums, RMSNorm |
| M2 (done, `mcc-uloop-interp`; dlf16 + `mcc-uloop-interp` CLI uncommitted) | bf16 in UCommon; the C++ interpreter and its Python entry; `src/mcc/uloop/`: Python builders | lit: bf16 round trips; `tests/lowering/test_interp.py`: hand-built bf16 IR (elementwise, matmul with SP and register partial sums, RMSNorm) against numpy, threaded and not |
| M3 | Elementwise lowering: the streaming `TracedOp` and its `StreamPlan` to ULoop (mapping: Appendix A of the design doc) | `tests/lowering/test_elementwise.py`: the 7 `tests/perf/add_elementwise` cases and a few kpl kernels (`exp(x) * 0.5 + r`, a scalar broadcast) |
| M4 | Matmul lowering: the systolic `TracedOp` (`dims(spec, axes)`, `epilogue`) to ULoop; SP partial sums by default, register partial sums as an option; G as an option | `tests/lowering/test_matmul.py`: the supported shapes of `test_mpn_matmul.py`'s `_TODAY`, both variants, against `x @ w` (+ bias, relu); unsupported tilings must be refused with a clear error |
| M5 (optional) | Checks C1–C8 and B1–B5 on a ULoop module (port of `lower.py`) | |

Every lowering test checks three things: the module verifies, the interpreter matches numpy (`allclose`: the
order of accumulation differs), and the loop trip counts and address strides are as expected.

The lowering tests need both the mcc package and the bindings: a moon task `mcc-mlir:test-lowering` runs them in
mcc's venv with the bindings on `PYTHONPATH`. mcc's own `pytest tests` does not collect them.

Supported tiling knobs at first: `n_shards`, `lane_blocks`, `m_tiles`, `bin`, `numncores`. Refused at first:
ragged splits (`m_valid`), `cout_spatial`, `transpose`, `tap`.

Out of scope: hoisting, UFlow (sync insertion, projection), UMach, emission.

M1 as built: accesses print their buffer types after the transfer type (`: T, <dst>, <src>`), since
MLIR needs an operand's type to parse it; elementwise operands are values or float immediates
(`imms`); `uloop.for` has no `iter` and there are no XVU ops yet (the four examples need neither);
the B1–B5 and C1–C8 checks are left to M5.

M2 as built: `uloop.alloc` takes an optional `name` (the interpreter's handle on an SHM buffer);
bf16 lines alias as `!line`/`!tileN`/`!wtile` and dlf16 ones as `!line_dlf16`, ...; the four
examples are bf16 now; an op's values and buffers must share a lane type. The interpreter is
`lib/Interp` + a C API (`mcc-c/Interp.h`) + `mlir_mcc.dialects.uloop.Interpreter`; SP and registers
start as NaN; partial sums accumulate in bf16 (as the VU's FMA does), so the error grows with K
(K = 4096: ~1.8% of the max). Builders: `mcc.uloop.Kernel`. `moon run mcc-mlir:test-lowering`
runs `tests/lowering/` and joins the `ci-mcc-mlir` lane, whose filter now covers
`src/mcc/uloop/`. Speed: an 8192x4096x512 matmul (1M `mxu.matmul`) runs in 1.85 s on one thread,
0.23 s on 14. The checks do not cover SP writes shared by the NCores of one DNC.

## Risks

- MXU accumulation precision: the TU's FMA (EVT1 ISA doc) says X, Y, Z and Result are all bf16 with SPR0[5] = 1, so the systolic chain may round at every step; the interpreter accumulates a matmul in f32 and rounds once. To confirm with the HW team, then match.
- dlf16 as a vector element: checked in step 0. `!ucommon.dlf16` implements `VectorElementTypeInterface` and
  `MemRefElementTypeInterface`, and `vector<64x!ucommon.dlf16>` round-trips; no `!ucommon.vec` is needed.
- The traced op may not carry enough to fix the loop order and G; they are lowering options.
- dev moves fast: the lowering reads only `TracedOp` and `TilingDecision` fields, nothing of mseq.

## Open

- The remote branch `mcc-mlir-dialect` is superseded by dev and `mcc-uloop`; delete it?

M2 follow-up (uncommitted): dlf16 lanes in the interpreter; `uloop.alloc`'s `shm_line` places an SHM
buffer in a memfile image; `tools/mcc-uloop-interp` runs a kernel on a VP `SHM_map.txt` and writes
an image that diffs against `SHM_final.txt`. `tests/Interp/add-vp.mlir` reproduces the VP perf
test add_elementwise/1x16x2x64 bit for bit. Next VP cases to port: dense, rms_norm, softmax.
