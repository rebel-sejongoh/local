# REBEL programming challenges

What makes the REBEL DNC hard to program, at the level of the programming model rather than individual ISA
quirks. It folds in [codesigner#2399](https://github.com/rebellions-sw/codesigner/issues/2399)
("Programmability and architecture discussion topics") and what one worked kernel showed:
Llama `down_proj`, `x[4,256] @ w[256,64]` on 16 DNCs
([`examples/mcc/down_proj_m4_k256_n64.asm`](../examples/mcc/down_proj_m4_k256_n64.asm), the cleaned
[`.clean.asm`](../examples/mcc/down_proj_m4_k256_n64.clean.asm), and the
[mapping page](../examples/mcc/down_proj_m4_k256_n64.layout.html)).

Small architecture issues (an ISA table that disagrees with the VP, sync FIFO depths, address encodings) are
listed at the end only as pointers; they are not the subject.

## The machine as a program sees it

- A DNC has two NCores. Each NCore is a set of units with their own instruction streams: NCLU and NCSU
  (SHM <-> SP, shared by the DNC), SPLU and SPSU (SP <-> FIFOs), XVU, VU, ABSU and ABLU (activation buffer),
  and the TU, a systolic array of 8 rows, each row programmed separately.
- Units pass data through FIFOs and order memory accesses with counting syncs: `SYNC` between units of one
  DNC, `MESYNC` between the NC units of different DNCs. There is no shared program counter and no unit that
  issues work to the others.
- Every DNC loads its own init image. Nothing in the hardware tells a program which DNC, NCore or TU row it
  runs on.

So one operation is not one program. In `down_proj`, each DNC runs 16 unit programs (8 units plus 8 TU rows;
the second NCore is idle), 256 programs over the 16 DNCs. DNC 0's programs hold 345 instructions, of which 37
are `SYNC`/`MESYNC`; after removing dead and redundant code, 122 remain, 33 of them syncs.

## 1. No single instruction stream

The core difficulty: an operation is a set of cooperating programs, and its correctness is a property of the
set, not of any one program.

- **Correctness is a count invariant across programs.** Every FIFO needs as many pops as pushes and every sync
  channel as many gets as puts, across 9 or more programs written separately. A local edit that changes one
  side breaks the other side somewhere else. While cleaning `down_proj`, removing two VU -> SPSU stores on the
  VU side but miscounting them on the SPSU side did not deadlock: the VP finished, faster, with wrong outputs.
  Only a bit-compare against the original run caught it.
- **Failures are global and hard to localize.** A missing token shows up as a hang in a different unit, often
  in a different DNC (see the dense deadlock,
  [codesigner#2124](https://github.com/rebellions-sw/codesigner/issues/2124)). There is no single trace to
  read; the state is spread over unit PCs, FIFO occupancies and sync counters.
- **Ordering is implicit.** What runs "after" what is only defined through the syncs. Reading the code in
  program order per unit does not tell the reader the global order; the `down_proj` timeline had to be
  reconstructed by hand from the sync pairs.
- **Each unit's code must fit its own instruction buffer**, so code size is a per-unit constraint, not a
  per-kernel one ([codesigner#2331](https://github.com/rebellions-sw/codesigner/issues/2331),
  [#2333](https://github.com/rebellions-sw/codesigner/issues/2333)).

A TPU TensorCore, by contrast, runs one single-threaded instruction stream and gets its parallelism from
asynchronous DMAs that overlap with compute; the compiler schedules vector and matrix work in time on that one
stream. A GPU runs one kernel for all threads. In both, a kernel is one program.

## 2. Spatial dataflow: the mapping is the program

A REBEL kernel is a spatial pipeline: units are placed into a dataflow graph, and the code of each unit is its
role in that graph.

- **Pipelined regions are implicit.** Units joined by FIFOs run as one pipeline. A unit can hold only one role
  in a region, so a unit used twice (SPLU feeding w then x, VU adding the TU result then sibling partials)
  either serializes its roles or splits the program into regions joined through memory. In `down_proj`, one
  credit from NCSU back to NCLU turns the root's work into two regions that run in sequence. None of this is
  written anywhere; it falls out of the sync placement.
- **The dataflow choice is baked into every unit.** Weight-stationary TU rows each latch 8 weight lines and
  forward the rest (56 − 8r per row), activations go through AB with a fixed row split, and the VU drains a
  4-row tile. Changing the dataflow (another stationary operand, another K split, another tile height) means
  rewriting the programs of all units together, not changing a parameter.
- **Fixed tile shapes waste work at small M.** The drain tile is 4 rows. With one row per DNC, as in `down_proj`,
  3/4 of the TU and VU work processes padding rows. Because each M shard reads all of w again, the 16 DNCs
  also read w four times over. A better mapping exists (all 4 rows in one DNC, K split over 4 DNCs, a row-wise
  reduce-scatter), but it is a different code structure across units, not a knob.
- **Memory is part of the dataflow, not behind it.** SP and AB act as staging buffers between pipeline stages,
  handed over with sync tokens. Addresses, buffer reuse and the tokens that protect them are all explicit and
  per unit.

On a TPU the same choices (tiling, what stays resident, double buffering) exist, but they are expressed in one
program: a Pallas kernel is a grid of loop iterations whose `BlockSpec` maps each iteration to input and output
blocks, and the compiler builds the multi-buffered DMA pipeline. The spatial placement is not the programmer's
problem there.

## 3. Replication without spatial identity

From [codesigner#2399](https://github.com/rebellions-sw/codesigner/issues/2399): one program is copied once per
NCore, per TU row and per DNC, and the copies differ only slightly.

- **Per NCore:** SPLU/SPSU of the two NCores must use separate SP regions, the region base sits in the LRF, and a
  block cannot point at another block's instructions, so two blocks that differ only in LRF values each carry a
  full copy of the code.
- **Per TU row:** each of the 8 rows (16 per DNC) needs its own block; the programs differ in the forward count.
- **Per DNC:** each DNC has its own image; the copies usually differ only in SHM addresses.

The lack of ids also shapes the compiler. There is no `thread_id` to branch on, so any per-DNC difference must
be decided at compile time and emitted as a different image. An operation that is SPMD in its definition
becomes MIMD in the binary: a cross-DNC reduction, a collective in XLA, turns into root code (gather and add)
and leaf code (store and handshake) in different images. That is workable for static grids, and it is what mcc
does (role parameters bound per DNC), but it means every kernel ships 16 specialized images of 16 unit programs each, and every variant
must be checked for sync balance.

The issue proposes read-only spatial ids (`dnc`, `ncore`, `row`) and affine addresses
(`base + Σ stride_i × id_i`), so one image could be loaded everywhere; the TU would also need the id in loop
counts, not only in addresses.

## 4. Communication and collectives are built by hand

- **No collective primitive.** A reduction over DNCs is assembled from SHM stores, `MESYNC` handshakes, gather
  DMAs, SP staging and VU adds. In `down_proj` the root gathers its three siblings one after another, and each
  leaf waits until the root has taken its partial before it may reuse its buffer.
- **The algorithm is fixed into the code.** mcc builds a star; a tree or a batched gather is another code
  shape. A reduction group spanning both 8-DNC clusters is not built at all.
- **Groups and roles have no representation above the code.** In the IR they are implied by the tiling; in the
  binary they are `sync_mask` bits. Expressing "reduce over grid axis k, root at k = 0" as one operation, and
  deriving the per-DNC code and its sync check from it, is still to be designed.

TPUs and GPUs expose collectives as operations (XLA `all-reduce` over replica groups, NCCL on GPUs) whose
implementations are libraries or runtime code, and the per-device program stays uniform.

## 5. The ISA exposes the hardware, not a programming abstraction

Every address and count in the code needs decoding against unit-specific conventions: pointers that add their
stride before access, so a base is written as "start minus one stride"; 10-bit wrap-around buffer addresses
(`0x3f0` meaning −0x10); immediates scaled by 2 in some units; NC descriptors packing four fields into one LRF
word. Each is small, but together they mean the assembly cannot be read or written without a per-unit manual,
and the manual is incomplete exactly where the cross-unit model lives (the `SYNC` and `MESYNC` pages are
"TODO"; behavior had to be inferred from PrecSim and the VP).

## How much harder than TPU, GPU or Jalapeño

| | REBEL DNC | TPU (TensorCore) | GPU | Jalapeño |
|---|---|---|---|---|
| Instruction streams per core | one per unit: 16 per NCore (8 units + 8 TU rows) | one | one kernel, many SIMT threads | not public |
| What a kernel is | a set of cooperating unit programs | one program | one program | not public |
| Spatial identity in code | none; per-image specialization | core/device ids | `threadIdx`, `blockIdx` | not public |
| Intra-core ordering | explicit token syncs between units | program order + DMA semaphores | program order + barriers | not public |
| Pipelining memory and compute | hand-placed per unit | `BlockSpec` pipelines generated | async copies, often library | "model state explicitly placed and kept local" |
| Collectives | hand-built from stores, syncs, DMAs | `all-reduce` etc. as ops | NCCL | not public |
| Kernel language today | per-unit assembly, generated by mcc | Pallas / XLA | CUDA, Triton | "designed so AI could program it" |

The gap is not mainly in instruction count; `down_proj`'s 122 cleaned instructions on DNC 0 are short. It is in
what the programmer must hold consistent at once: one op becomes 256 programs, each written in its own unit's
conventions, whose correctness depends on matching counts across all of them, with no single trace to debug
against.

### The same layer in Pallas

[Pallas](https://docs.jax.dev/en/latest/pallas/tpu/quickstart.html) is JAX's kernel language: a `pallas_call`
wraps a kernel function that reads and writes on-chip buffers (`Ref`s), one program per core. An optional
`grid` with `BlockSpec`s maps each grid step to input and output blocks, and the compiler builds the
HBM -> VMEM copy pipeline around it. `down_proj` with REBEL's mapping (4 × 4 devices, x rows over `m`,
K over `k`, a reduction over `k`) would look like this (illustrative, not run; API names as in recent JAX):

```python
from functools import partial
import numpy as np
import jax, jax.numpy as jnp
from jax.experimental import pallas as pl
from jax.sharding import Mesh, PartitionSpec as P

def dot_kernel(x_ref, w_ref, o_ref):                 # one device's block: x [1,64], w [64,64]
    o_ref[...] = jnp.dot(x_ref[...], w_ref[...],
                         preferred_element_type=jnp.float32).astype(o_ref.dtype)

def local_dot(x, w):
    return pl.pallas_call(
        dot_kernel,
        out_shape=jax.ShapeDtypeStruct((x.shape[0], w.shape[1]), x.dtype),
    )(x, w)

mesh = Mesh(np.array(jax.devices()[:16]).reshape(4, 4), ("m", "k"))

@jax.jit
@partial(jax.shard_map, mesh=mesh,
         in_specs=(P("m", "k"), P("k", None)),      # x[4,256] -> [1,64] per device, w[256,64] -> [64,64]
         out_specs=P("m", None))                     # out[4,64]: rows over m, replicated over k
def down_proj(x, w):
    return jax.lax.psum(local_dot(x, w), "k")        # the cross-device reduction, one line
```

What each part stands for on REBEL:

| Pallas / JAX | REBEL `down_proj` |
|---|---|
| `Mesh(..., ("m", "k"))`, `in_specs` | the 16 DNC images' SHM addresses (NCLU descriptors), chosen per image |
| `dot_kernel` (one program) | NCLU, SPLU, XVU, ABSU, ABLU, 8 TU rows, VU, SPSU, NCSU programs, with the SYNCs between them |
| block movement HBM -> VMEM (generated) | NCLU LDMU, SP staging, SPLU windows, AB split, written per unit |
| `jax.lax.psum(..., "k")` | leaf STSU + MESYNC handshake, root MESYNC + LDMU gather + SPLU + VU adds, in separate root and leaf images |
| `out_specs=P("m", None)` | root NCSU writes `out[m, :]`; the result lives only on the root |

A larger layer adds a `grid` and `BlockSpec`s to the same `pallas_call`, for example
`grid=(K // bk,)` with `pl.BlockSpec((bm, bk), lambda k: (0, k))` and an accumulator, and the compiler
double-buffers the blocks. On REBEL the same change (an in-DNC K fold) changes the loop structure, buffers and
syncs of several unit programs at once.

Little is public about Jalapeño's programming model; OpenAI describes it as designed for LLM inference, with
model state explicitly placed and kept local, and "designed so AI could program it". Comparisons beyond that
would be guesses.

## Directions

These follow from the problems above; none is designed yet.

- **One logical program per DNC.** A front that writes an operation once, as a single stream or a small dataflow
  graph, and derives every unit's program and every sync from it, so count balance holds by construction. The appendix of
  [`mlir-machine-ir.md`](mlir-machine-ir.md) sketches this for `down_proj`.
- **Regions as a first-class IR level.** Make pipelined regions, their buffers and the tokens between them
  explicit, so the cost of a unit used twice, or of a credit, is visible and chosen rather than incidental.
- **Collective operations with grid axes.** `grid.reduce %p axes=[k] root=(k=0)` and friends, lowered to star,
  tree or batched code, with a static checker for sync balance and deadlock
  ([`examples/mcc/grid_reduce_template.py`](../examples/mcc/grid_reduce_template.py) is a first sketch).
- **Spatial ids and affine addresses in hardware** (codesigner#2399), so a program can be shared across NCores,
  rows and DNCs.
- **A global debug view.** A simulator trace that shows all units' PCs, FIFO occupancies and sync counters
  together, and names the channel a deadlock waits on.

## Small architecture issues (not the focus)

- TU FMA `src0` table in the ISA doc disagrees with the VP for `run_mode=2`
  ([codesigner#2182](https://github.com/rebellions-sw/codesigner/issues/2182)).
- Sync FIFO depths differ between sources (16 vs 4); MESYNC depth undocumented.
- The cross-DNC fence costs 266 cycles on `down_proj`
  ([codesigner#2254](https://github.com/rebellions-sw/codesigner/issues/2254)).
- AB pointers are 10-bit rings written as "start minus one stride".

## Sources

- [codesigner#2399](https://github.com/rebellions-sw/codesigner/issues/2399), Programmability and architecture discussion topics
- [Pallas Quickstart: TPU](https://docs.jax.dev/en/latest/pallas/tpu/quickstart.html),
  [JAX Pallas: TPU Pipelining](https://docs.jax.dev/en/latest/pallas/tpu/pipelining.html),
  [Pallas Async Operations](https://docs.jax.dev/en/latest/pallas/design/async_note.html),
  [Pallas Core-specific Programming](https://docs.jax.dev/en/latest/pallas/tpu/core_map.html)
- [OpenAI: OpenAI and Broadcom Jalapeño inference chip](https://openai.com/index/openai-broadcom-jalapeno-inference-chip/),
  [Jalapeño first results](https://openai.com/index/jalapeno-first-results/)
