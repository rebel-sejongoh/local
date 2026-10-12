# Multi-DNC matmul tests: mcc and RCL2

Source inspection date: 2026-10-13. Checkout: `../codesigner/`.

The two primary executable suites are `ports.matmul` and `ports.dynamic_matmul_fp16` in `PrimitiveAuthor/primitives`. They build complete multi-DNC images through mcc, stage inputs in SHM, execute every active DNC through PrecSim, read back outputs, and compare them with a matrix-product reference. Running only mcc's unit tests does not execute these products.

This note inventories executable tests and analogous RCL2 cases. It does not report new correctness or performance measurements. RCL2 analogues below exercise similar distribution mechanisms; they are not established shape-for-shape or cycle comparisons.

## Shape notation and execution scope

All mcc shapes below use **`(M, N, K)`**, matching the validators: `A[M,K] @ B[K,N] -> C[M,N]`. RCL2 dimensions are recorded in their original blocked layouts. Do not compare the dimension lists directly.

PrecSim checks arithmetic and completion under its execution model. It has no cycle model. VP is needed for timing, including imbalance between DNCs. A VP configured with sixteen DNCs, or an image containing sixteen programs, does not by itself show that sixteen DNCs perform useful work.

## 1. Run the complete mcc-generated matmul suites

Prepare the package environments using the repository's Python 3.10 toolchain:

```bash
cd /home/sejongoh/workspaces/codesigner
moon run precsim:venv
cd PrimitiveAuthor/primitives
uv sync
```

Run both complete numeric grids:

```bash
uv run pytest \
  'tests/test_validators.py::test_precsim[ports.matmul]' \
  'tests/test_validators.py::test_precsim[ports.dynamic_matmul_fp16]' \
  -m precsim -v -s
```

Each pytest item runs its validator's entire `configs()` list. Pytest `-k` selects a validator, not an individual configuration inside that list. Both grids include single-DNC controls alongside multi-DNC cases.

For the build and byte-comparison grid without simulator execution:

```bash
uv run pytest \
  'tests/test_validators.py::test_bytecheck[ports.matmul]' \
  'tests/test_validators.py::test_bytecheck[ports.dynamic_matmul_fp16]' \
  -m bytecheck -v
```

Sources: [pytest entrypoints](../codesigner/PrimitiveAuthor/primitives/tests/test_validators.py), [validation instructions](../codesigner/PrimitiveAuthor/primitives/README.md), [matmul validator](../codesigner/PrimitiveAuthor/primitives/tests/ports/matmul_validate.py), [dynamic matmul validator](../codesigner/PrimitiveAuthor/primitives/tests/ports/dynamic_matmul_fp16_validate.py).

### Distributed cases in `ports.matmul`

| Mechanism | Representative configurations | What the complete numeric run checks |
|---|---|---|
| M sharding over sixteen DNCs | `(64,64,64)`, `(128,64,64)` | Four or eight rows per DNC; the latter also uses two NCores per band |
| Cross-DNC K reduction | `(64,64,128)`; `(64,64,256)` and `(64,64,512)` with `bin=1` | Two-, four-, and eight-DNC reduction groups |
| M sharding over both clusters plus K reduction | `(128,64,512)`, `bin=1` | Distinct M shards across two clusters, each with an eight-DNC reduction |
| Spatial K split plus temporal K fold | K=256/512/1024/2048 with `bin=2/4/8/16`, M=N=64 | A two-DNC reduction combined with multiple local K blocks |
| Wide M with temporal row tiles | M=256/384/512, N=K=64 | Rows distributed across DNCs, then processed in local M passes |
| Fewer active DNCs | `(512,64,64)` on 8; `(384,64,64)` on 12; `(256,64,64)` on 8 | Explicit resource limits and local temporal work |
| Automatic sub-sixteen M sharding | M=72/88/104/120, N=K=64 | Nine/eleven/thirteen/fifteen shards, each with eight rows |
| M, N, and K composition | `(128,128,128)`, `(128,512,256)` | Output-channel tiling composed with row sharding and K reduction |
| Dynamic uneven work | `(128,64,64)`, `raw=20/17/10/1` | Different per-group trip counts and DNCs with zero work |
| Dynamic uneven work plus reduction | `(128,64,256)`, `raw=10/2`, `m_tiles=4` | Uneven counts between four groups, with four-DNC reduction inside each group |
| EVT1 | Atom, M split, K split, M-tile and Cout variants with `hw=EVT1_HW` | Revision-specific images through the same arithmetic checks |

`cout_spatial=True` distributes Cout over **NCores inside a DNC**. Do not interpret that flag alone as output-channel partitioning between DNCs.

### Distributed cases in `ports.dynamic_matmul_fp16`

The grid runs both weight orientations and includes M=128/512, wide N, mixed M/N/K, batched problems, shared weights, caller-defined tensor placement, and page-form kernels.

| Mechanism | Representative configurations |
|---|---|
| M distribution and local passes | `(128,64,64)`, `(512,64,64)`, `(1024,128,64)` |
| Batch distribution | `(128,64,64), g=2`; `(256,64,64), g=4` |
| Guaranteed cross-DNC K split | `(256,64,128), bin=1, place="redmove"`; `(128,64,256), bin=1, place="redmove"` |
| Shared weights and nested problem layouts | `(512,64,128), g=8, ker_repeat=2, place="actnest"`; `(3072,64,256), g=12, ker_repeat=3, fold_tiles=True, place="actnest"` |
| A DNC band crossing problem boundaries | `(1536,128,64), g=6, ker_repeat=3, place="outnest"` |
| Page-form weights | K=64; M/N sweeps, batch and shared-weight cases |

**Pin `bin=1` when the purpose is cross-DNC K reduction.** At some N/K shapes, the current default folds K in time inside each DNC. An old comment naming a K split is not sufficient evidence of the resolved plan.

## 2. RCL2 counterparts

RCL2 checkout: `../codesigner/spec_source_inventory/rebel_compute_lib2/`. The paths in this section are relative to that checkout. The REBEL `alpha` tests carry EVT0 markers; `alpha_evt1` supplies EVT1 tests.

### Representative test IDs and distribution

| RCL2 file under `tests/src/develop/rebel/` | Exact test ID | Explicit distribution or behavior | Closest mcc coverage |
|---|---|---|---|
| `alpha/test_rbln_initgen_dense_fp16.py` | `rebel_dense_cluster_balance_cout` | Two clusters × eight DNCs available; automatic tiling | Wide-N/M composition; inspect resolved RCL2 tiling before comparing |
| same | `rebel_dense_cluster_balance_cin` | Explicit Cin partition over two clusters × eight DNCs | K reduction; RCL2's sixteen-way cross-cluster case exceeds the eight-way single-cluster example above |
| same | `ci_rebel_dense_fp16_seq1_001` | Cin partition over sixteen DNCs; input `[1,16,64]`, kernel `[16,1,64,64]` | Small-M, long-K linear; no established exact counterpart |
| same | `ci_rebel_dense_fp16_seq1_002` | Batch factor 4 × Cout factor 4; input `[7,2,64]`, kernel `[2,13,64,64]` | M and wide-N coverage, but mcc's spatial Cout is intra-DNC |
| same | `ci_rebel_dense_fp16_seq1_003` / `004` | Cin iteration factor 4 over two DNCs; Gelu epilogue | Spatial K split × temporal fold; fusion differs |
| `alpha/test_rbln_initgen_batch_matmul_fp16.py` | `rebel_ts_batchmatmul_Head_fusion_002` | Head partition over sixteen DNCs | Batched matmul and KPL head-batch coverage |
| same | `rebel_alpha_test_batchmatmul_fp16_head_test` | Head partition over eight DNCs | Batch sharding with fewer resources |
| same | `ci_rebel_batchmatmul_fp16_general_000` | Cin iteration factor 4 over two DNCs | K split × temporal fold |
| `alpha/test_rbln_initgen_dynamic_dense_fp16.py` | `ci_rebel_dynamic_batch_dense_fp16_multi_token_002` | Batch factor 2 × Cin factor 4 over eight DNCs, runtime count 61 | Dynamic M groups combined with K reduction |
| same | `ci_rebel_dynamic_batch_dense_fp16_multi_token_003` | Cout/row/Cin factors 2×2×2, runtime count 0; fused epilogue | Zero-count handling and composed folds; fusion differs |
| `alpha/test_rbln_initgen_matmul_fp16.py` | `rebel_dynamic_bmul_inter_cluster_cin_tile` | Explicit sixteen-way Cin partition, runtime Cin count and offset | Cross-DNC K reduction; runtime-K semantics differ |
| `alpha_evt1/test_rbln_initgen_dynamic_matmul_fp16.py` | `ci_rebel_evt1_dynamic_matmul_transpose_outpad_batch_dnc_split_006` | Explicit batch/output partition, transpose, output padding | Dynamic/batched orientation and placement coverage; no exact matching case |
| `alpha_evt1/test_rbln_initgen_in_memory_dynamic_batch_matmul_fp16.py` | `rebel_in_memory_dynamic_batch_matmul_REBEL_EVT1_000` / `001` / `002` | Two-DNC Cin, Cout, or head partition; memory-loaded runtime counts | Related batched distribution; runtime-count transport differs |

Sources: [dense](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha/test_rbln_initgen_dense_fp16.py), [batch matmul](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha/test_rbln_initgen_batch_matmul_fp16.py), [dynamic dense](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha/test_rbln_initgen_dynamic_dense_fp16.py), [matmul](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha/test_rbln_initgen_matmul_fp16.py), [EVT1 dynamic matmul](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha_evt1/test_rbln_initgen_dynamic_matmul_fp16.py), [EVT1 in-memory batch matmul](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha_evt1/test_rbln_initgen_in_memory_dynamic_batch_matmul_fp16.py).

EVT1 dense also has `ci_rebel_evt1_dense_fp16_seq1_001` through `004` in [its own suite](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha_evt1/test_rbln_initgen_dense_fp16.py). Additional family coverage lives in [EVT0 dynamic matmul](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha/test_rbln_initgen_dynamic_matmul_fp16.py), [EVT0 dynamic batch matmul](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha/test_rbln_initgen_dynamic_batch_matmul_fp16.py), [EVT1 dynamic dense](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha_evt1/test_rbln_initgen_dynamic_dense_fp16.py), and [EVT1 in-memory dynamic matmul](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/src/develop/rebel/alpha_evt1/test_rbln_initgen_in_memory_dynamic_matmul_fp16.py).

### Run RCL2 end to end

Use RCL2's prepared Python environment, built compute library, and installed backend. Its [README](../codesigner/spec_source_inventory/rebel_compute_lib2/README.md) describes setup. The [pytest options](../codesigner/spec_source_inventory/rebel_compute_lib2/tests/conftest.py) accept `vp` and `prec_sim` backends.

```bash
cd /home/sejongoh/workspaces/codesigner/spec_source_inventory/rebel_compute_lib2

# A specific distributed case: initgen, golden generation, backend, evaluation.
python -m pytest \
  'tests/src/develop/rebel/alpha/test_rbln_initgen_dense_fp16.py::test_rbln[rebel_dense_cluster_balance_cin]' \
  --backend=vp -v -s

# Complete EVT0 dense and batch-matmul suites.
python -m pytest \
  tests/src/develop/rebel/alpha/test_rbln_initgen_dense_fp16.py \
  tests/src/develop/rebel/alpha/test_rbln_initgen_batch_matmul_fp16.py \
  --backend=vp -v -s

# Complete EVT0 dynamic suites.
python -m pytest \
  tests/src/develop/rebel/alpha/test_rbln_initgen_dynamic_dense_fp16.py \
  tests/src/develop/rebel/alpha/test_rbln_initgen_dynamic_matmul_fp16.py \
  --backend=vp -v -s
```

Use `--backend=prec_sim` for numeric simulation instead of VP. Do not add `--only_compute_lib`, `--only_backend`, or `--only_eval` when the intent is the complete pipeline. The full RCL2 files also contain fused and mixed-precision cases beyond the mcc DLFloat16 matmul grids.

## 3. Structural tests and timing comparison

These tests supplement execution; they cannot establish numerical correctness or timing on their own:

| Component | Tests | Property |
|---|---|---|
| mcc | `test_m_distribution.py`, `test_dnc_group.py`, `test_fold_ssot.py`, `test_m_shard_cout_fold.py` | M coverage, group ownership, uneven addresses, shard selection |
| mcc | `test_kpl_long_contraction.py`, `test_reduce_recipe.py` | K split × local fold, reduction graph |
| primitives | `test_m_distribution.py`, `test_seed_one_replica.py`, `test_spmd_hierarchy.py` | An op's resolved distribution, each DNC's tensor share, reduction roots |
| primitives | `kpl_bridge/test_kpl_declaration_head_batch.py` | Head-batch and shared-weight image equivalence |

Run the mcc component suite separately:

```bash
cd /home/sejongoh/workspaces/codesigner/PrimitiveAuthor/mcc
uv sync
uv run pytest tests -q
```

For timing, [test_perf_vp.py](../codesigner/PrimitiveAuthor/mcc/tests/perf/test_perf_vp.py) compares mcc and captured RCL2 assembly on identical inputs, checks bit-identical final SHM, and applies a cycle bound. It records total completion cycles, slowest-DNC cycles, and DNC-0 cycles.

**Current matmul fixture gap:** `tests/perf/dense/` has no `kernel.py` or `base/manifest.json` in this checkout. The current [capture registry](../codesigner/PrimitiveAuthor/mcc/tests/perf/scripts/capture_rcl2.py) contains add cases only. Consequently, `uv run pytest tests/perf -m requires_vp -k dense` does not provide a runnable dense comparison.

To establish a paired matmul performance test, capture a selected RCL2 case, provide a matching KPL `MAIN` with the same tensor placement, and supply the fixture consumed by [build_mcc.py](../codesigner/PrimitiveAuthor/mcc/tests/perf/scripts/build_mcc.py) and [run_vp.py](../codesigner/PrimitiveAuthor/mcc/tests/perf/scripts/run_vp.py). Match revision, dtype, logical shape, epilogue, resource count, and input bits; inspect both resolved plans. Report the last-DNC completion cycle and imbalance, rather than DNC-0 timing alone.

The local untracked `run_llama_linear.py` uses `GATE_PROJ` at `(M,N,K)=(4,256,64)`. It is a small single-DNC linear example, not evidence of useful sixteen-DNC distribution. Its imports also use the older `dnckit` namespace.

## Verification status

The paths, test IDs, configurations, and entrypoints above were inspected from source. No full simulator grids were run for this note.

A collection-only attempt with the existing `PrimitiveAuthor/primitives/.venv/bin/python` failed while importing `tests/byte_goldens.py`: `ModuleNotFoundError: No module named 'dnc_binutils'`. The current environment needs synchronization before these suites can be collected. RCL2 commands were checked against source entrypoints and backend options, but were not executed.

## 4. DNC distribution of matmul tests (2026-10-13)

Inventory of matmul / linear / projection tests by how they spread over the 16 DNCs. Where no per-DNC artifacts are checked in, the split comes from running the repo's own tiling functions (`primitives.matmul._mm_fabric_of`, `dynamic_matmul_fp16_fabric_tiling`, `mcc.grounding.tiling.derive_fabric_tiling`), not from built images. `a×b` means `a` M-shards × `b` DNCs per K-reduction group.

### Tests with real per-DNC artifacts

| Test | Shape | DNCs | Evidence | Balance |
|---|---|---|---|---|
| `PrimitiveAuthor/dnc_binutils/tests/fixtures/programs/llama_down_proj` | [4,256]@[256,64], **EVT0 FP32** | 16 (4×4 K-split) | `dnc0.s`..`dnc15.s`, all distinct | Good: reduce roots dnc0/4/8/12 487 lines, others 479 |
| same, `llama_gate_proj`, `llama_up_proj` | [4,64]@[64,256], EVT0 | 1 | single `dnc0.s` | 15 DNCs idle |
| kcc bytecheck `matmul.sha256`, `matmul.r100-evt1.sha256` (`kernel_samples/matmul.py`) | 64³ | 16 (M-split) | 16 distinct `compute_0_dnc_*.bin` | Even |
| Production dumps `kernel_matmul`, `matmul__fp16dlf` (`tests/data/dumps`, `RebelCompilerSnapshots`) | 64³ | 16 | `init_0..15` same size | Even |
| Production snapshot `kernel_matmul__bf16` | 64³ bf16 | 10 of 16 | 6 inits ~816 B (empty) | Unbalanced |

### Tests whose split comes from the tiling decision

- `primitives` `ports.dynamic_matmul_fp16` (52 goldens): every config uses 16 DNCs. Mostly 16 M-shards with temporal M tiles and in-DNC K folds; 128³ is 8×2, 256³ is 4×4. EVT1 rows: `(64,64,64)`, `(128,64,64)`, `(64,128,64)`, `(64,64,128)` with `chip_rev="evt1"`.
- `primitives` `ports.matmul` (87 goldens):
  - 16 DNCs, pure M-split: 64³, M=128..512 at N=K=64, N sweeps at M=64/128, 256/512×128. EVT1 rows: 64³ atom, `(128,64,64)`, `(128,64,64) m_tiles=2`, Cout variants.
  - 16 DNCs with K-split (8×2, 4×4, 2×8): `(64,64,128)` (also EVT1), `(64,64,256) bin=1`, `(64,64,512) bin=1`, `(128,64,512) bin=1`, 128×128×128, etc.
  - Fewer than 16: `active_dncs` 8/12, M=72/88/104/120 → 9/11/13/15, M=2/10/17/18/23.
  - 1 DNC: M=4 rows and `active_dncs=1`.
- Llama decoder tests in `KernelAuthor/verification/tests` (`-m precsim`): R=64 e2e q/k/v/out 64³ → 16; gate/up 64×64×256 → 16; down 64×256×64 → 4×4. GQA and attention-loop q/k/v → 8×2. R=4 kpl-gap leaves q/k/v/out/gate/up → 1 DNC.
- `test_kpl_systolic_layout_values.py`: ATOM/PLAIN/PAGE 64³, K128, K256, N128, N1536 → 16; `SYSTOLIC_N32` → 1.

### Notes for VP perf

- `llama_down_proj` fails on the VP. Its fixture is R100 **EVT0 FP32** code (`.arch rebel.evt0`), while the VP is EVT1, and it also relies on a 4×4 cross-DNC K reduction.
- Candidates that use all 16 DNCs on EVT1 with no cross-DNC reduction: `ports.matmul` / `ports.dynamic_matmul_fp16` EVT1 `(64,64,64)` and `(128,64,64)`, `(64,128,64)`, and kcc `matmul.r100-evt1` (64³). Add the EVT1 K-split `(64,64,128)` once the M-split ones run.
- `PrimitiveAuthor/mcc/tests/perf/dense/m16_k1024_n64` lives on the `mcc-perf-dense` branch; mcc's build of it deadlocks on the VP (#2124).
