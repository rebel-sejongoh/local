# The PrimitiveAuthor architecture, over two axes

The top-level architecture. Read this first, since it is the map of
the whole system, defines its terms as it goes, and points down into the detailed docs for
any piece. You do not need to have read the others first.

## 0. What this is, in one paragraph

DNCs are the compute cores inside Rebellions' AI chips (16 of them per device). To run a math
operation, which is a kernel such as a square root or attention, on those cores, someone has to write
the low-level program the cores execute (**microcode**, compiled into an image called
`init.bin`). That is slow, expert work, and most kernels are built from the same handful of
patterns, and this is a Python system for writing each pattern once and reusing it,
a *library of hand-written building blocks* (we call them **leaves**), plus the machinery to
*combine* them and *fit* them to a given problem size. This doc explains how those pieces fit
together and what is built vs. still to build.

> **If you know Halide:** leaves are the *algorithm*, the composition search is the
> *autoscheduler*, the **declaration** (§6) is the *schedule IR*, and the *dynamic column* (§5)
> is runtime-bound schedule parameters. PA is "Halide for DNC microcode," minus a built optimizer.

> **The one mental model to keep:** the system has a **static** side that *shapes* the
> computation, which is the full repertoire of what can run, and a dynamic side that, from the
> input given at runtime, decides *which* of it actually runs, *how many* times, and *at what
> addresses*. **What *can* happen is static; what *does* happen this input is dynamic.**

A short glossary of the terms that matter, each detailed later:

| term | one-line meaning |
|---|---|
| **DNC** | a compute core inside the chip (16 per device) |
| **kernel** | the program for one operation (sqrt, attention) |
| **microcode / `init.bin`** | the low-level per-core program / its compiled image |
| a compute | one dispatched microcode program, which is a single invocation of the cores |
| **command stream** | the runtime sequence of Compute + data-move commands the CP issues (DRAM→DRAM) |
| **leaf** | a hand-written microcode building block (one compute cascade or data-mover) |
| the command processor | the controller that dispatches work to the DNCs at runtime |
| **JCR** | the register that carries a runtime value (e.g. a loop count) into otherwise-fixed microcode |
| **LRF / SP / SHM** | the three on-chip memory tiers: registers → scratchpad → shared memory |
| a partial sum | an intermediate accumulator across a reduction |
| **TU / XVU / VU** | the matrix unit / transcendental+logic unit / vector unit |
| **dlf16** | the 16-bit float format the DNCs compute in |
| ahead of time | resolved at build, before anything runs |

**Status tags** used throughout: **EXISTS** (built + validated) · **PROTO** (partial reference
impl) · **PROPOSED** (design only) · **MISSING** (not yet designed) · **EXISTS-with-issues**.

### `sqrt`, walked through the model

A square root is one leaf, the cascade on the compute unit that computes it, as section 2 explains. It is a single stage, so there is
no **composition** to do and **search** is trivial; its shape is fixed, so nothing is **dynamic**.
It lowers straight to an image the cores run. A hard op, such as paged attention, exercises every
box: many leaves, a running-fold composition, a real tiling search, and a runtime block-count only
the CP knows (the dynamic column). **Same machine, opposite corners of the grid below.**

### The picture

```
                 binding-time  ──────────────────▶  (resolved when?)
                 STATIC (ahead-of-time)        DYNAMIC (runtime, on the CP)
  layering  ┌──────────────────────────────┬──────────────────────────────────┐
  (what a   │ Leaves   fixed-shape leaf     │ leaf with a runtime hole          │
   kernel   │          (sqrt)               │ (gather: index → address)         │
   is made  │ Compos.  fixed fusion/tiling  │ fold over a runtime block-count   │
   of)      │ Search   tiling chosen AOT    │ tiling/path chosen on the CP      │
    │       └──────────────────────────────┴──────────────────────────────────┘
    ▼                    │   the COMPOSITION DECLARATION   │
                         ▼   (the resolved plan, which is the seam) ▼
                  init.bin  +  command stream   ───▶   the DNCs
```

Two **orthogonal axes**. The **layering axis** (vertical) is *what* a kernel is made of:
leaves → compositions → search. The **binding-time axis** (horizontal) is *when* each field
resolves, whether ahead of time or at runtime. Control flow is not a fourth layer but
the **dynamic column** cutting through all three, run by a CP engine (§5). The **composition
declaration** (§6) is the seam where the two axes meet: the static side fills its AOT fields, the
dynamic side binds its runtime holes, and one lowering turns it into `init.bin` + command stream.

> Detail lives in: [`dnc-programming-guide.md`](dnc-programming-guide.md) (the machine + method),
> [`composable-microcode-templates.md`](composable-microcode-templates.md) (leaves/compositions),
> [`device-linking.md`](device-linking.md) + [`kernel-programming.md`](kernel-programming.md)
> (the dynamic/CP half). This model was derived from, and validated against, the rebel compiler's
> the shipped production mechanism, which section 9 covers as prior art.

---

## 1. The two axes (precisely)

Every field of a kernel has a position on both axes (the grid above). Spelled out:

| | **static** (AOT) | **dynamic** (runtime, CP) |
|---|---|---|
| **Leaves** | fixed-shape leaf (`sqrt`) | leaf with a JCR-seeded trip (a loop count supplied at runtime) / index hole (`gather`) |
| **Compositions** | fixed fusion / tiling | fold/psum over a runtime block count (paged attn) |
| **Search** | AOT tiling decision | runtime tiling / path selection on the CP |

The dynamic axis never authors new structure. It only selects and parameterizes what the static
building blocks. Even a runtime `WHILE` loop just repeats a *static* leaf with runtime-bound
counts/addresses. The static axis defines what is possible and the dynamic axis carves the realized shape
within it from the input handed to the DNCs.

## 2. The leaves, which are the building blocks

A **leaf** is a hand-authored, per-unit microcode building block: a compute cascade
(`lower_xvu`) or a mover/stage skeleton (`lower_nclu/ncsu/splu/spsu`, where SP = scratchpad,
SHM = shared memory). It is the irreducible authored unit; everything above it is mechanizable.

**There are far fewer leaves than ops.** A census of the rebel corpus (the closest existing
reference): 254 dispatchable primitives collapse to ~146 template classes and, at the
microcode-body level, **~83 distinct op-roots → ~11 families → a few dozen (~40) hand-authored
archetypes, from a census of the production corpus that section 9 describes. The list per archetype is an
internal figure, not yet documented separately). So the hand-authored investment PA must make and
cover is about 40 archetypes rather than 254 ops, and the breadth comes from sharing, in two ways.

1. Within a family, one parameterized leaf serves many ops, as a transcendental cascade
   covers 17 functions via an enum + coefficients; one reduction combine-op covers
   sum/max/min/mean; one arithmetic skeleton covers add/sub/mul/div + comparisons + bitwise).
2. Across families, whole classes reuse another's leaves: a convolution is a case of a matmul, pooling is a reduction,
   norm → reduce + accumulate, INT4-cast → the arithmetic leaf.

⇒ The leaf is **"skeleton + slot"** ([`composable-microcode-templates.md`](composable-microcode-templates.md)
§6.2). How much one parameterized leaf absorbs (which axes are a *parameter* vs a *structural
fork*) is a PA design lever. Empirically: **op/function** and **activation** parameterize cleanly;
the data type is a hybrid, being a parameter within a primitive and a structural fork at the extreme,
**operand count** and **axis-vs-lane** are structural forks.

Status: this exists in the worked ports (sqrt, the tiled and recomputing attention kernels), each
with its own per-unit lowering functions. Lowering to an image exists too
(`build_init_bytes`/`gen_flits`).

## 3. The compositions, which are the combinators

Compositions combine leaves. Like leaves, they decompose into a **small set of reusable
combinators** that recombine across all primitives:

- Reducing across DNCs: two passes over a partial sum, with explicit accumulator state and
  *tiling-derived* sync placement. Shared by reduce, GEMM-K, conv, norm, pool.
- Accumulating and rounding once: accumulating at high precision on the vector unit and rounding once at the
  end. The mitigation for the [dlf16-FMA gap](dlf16-fma-precsim-hw-gap.md). Shared by reduce,
  GEMM, norm, avgpool.
- A running-state fold: a serial scalar rescale across tiles, as an online softmax does, distinct from the
  parallel psum tree. PA has this in `flash_attn_recomp`.
- A window walk: iterating a spatial receptive field, as a convolution or a pooling does.
- A post-fuse: an affine scale and shift, or an activation, appended after a reduce or a compute.
- Two passes: a first pass and then a combine, as a mean feeding a variance does.
- A broadcast stage: aligning several operands through a scalar or lane broadcast and a FIFO per operand.
- A permutation repack: converting the layout between leaves through a cross-lane permute. The concrete
  realization of FLAT↔lane-reversed conversion.

…placed over the **staging tiers** that decide *where* a composition lives: **`fuse`**
(register/scratchpad-resident, one Compute) / **`restage`** (scratchpad round-trip, one Compute) /
**`chain`** (cross-Compute, command stream).

> A note on scope. Fusing and restaging live inside the image, being the composition operators of the microcode
> template. Chaining crosses computes and is realized in the command stream, so it belongs
> to the kernel-authoring layer ([`kernel-programming.md`](kernel-programming.md)), not the
> microcode template. The tier *decision* is made at instantiate/link time; `chain`'s *realization*
> is runtime.

Status: early or proposed. Reference semantics for chaining exist, in `phase_multi.py` and
`author_cmd.py:build_multi_cmd`); `fuse`/`restage`/`SpAllocator` are design-only
([`composable-microcode-templates.md`](composable-microcode-templates.md) §5/§6/§10). The
The scratchpad allocator, which replaces the frozen constants in `hw_movers.py`, is the prerequisite
for `fuse`.

## 4. The search over compositions, which is the seam open to negotiation

Search selects the tiling and tier (fuse/restage/chain) under the hard resource budget (16
registers / scratchpad / 128-instruction limit / 16 DNCs). The blueprint (from rebel, directly
portable):

- The objective is an analytical cost model, taking the maximum rather than the sum over the per-unit throughput,
  memory latencies, reduction-tree depth}. The K-reduction tree latency is separate from the M×N loop.
- The procedure has two levels: enumerate the tilings across DNCs, check that each fits, and where the scratchpad overflows
  recurse **intra-DNC** → score → pick min.
- Each class of op has its own slot in one shared framework, plugging in its own enumeration of candidates and
  cost terms (the leaf "skeleton + slot" pattern, applied to search). **Not** different algorithms
  per group.
- The output is a resolved declaration, which section 6 describes.

Search is the axis where the **static/dynamic line is drawn**. When the cost-relevant shape is
static, search resolves AOT. When the shape is runtime-bound (dynamic GEMM dims, paged-K), search
either provisions for the whole range and emits one image, which the dynamic column selects within, or
migrates part of the decision to the CP.

> The default decision: resolve the search ahead of time and provision for the whole range, migrating a decision to the
> CP **only** when the cost-relevant shape is intrinsically runtime-variable (paged / variable-K
> attention). See the decision-locus discussion, guide §4.8. (Rejected alternative: patching a
> a donor image instead of instantiating one; see section 1 of the templates doc.)

> **Cross-cutting validation caveat:** PA's gates are *functional-only*, and PrecSim is lenient
> about what silicon enforces (guide §3.5). **Every new piece's validation story must end on real
> hardware (CR03), not PrecSim.**

**Status:** MISSING. Tiling is host-enumerated today, not searched. **The first deliverable is the
cost model, since there is no cycle oracle here. The search over what is legal and what fits is buildable now, and the one over performance
search needs the cost model. rebel's `est_cycles` constants/structure are the seed.

## 5. The dynamic column, which is the control flow

Control flow is the **dynamic end** of the binding-time axis: the runtime-bound fields plus their
resolution. Even a branch or `WHILE` reduces to *binding a path/count at runtime*. It spans all
three layers (a leaf can take a JCR trip; a composition can fold over a runtime count; search can
defer to the CP), so it is a **column, not a layer**.

What it binds, from runtime input handed to the DNCs (via JCR / `const_buf`): dynamic trip counts
(dynamic-N), GEMM/attention dims, gather/scatter indices → addresses, paged block tables,
causal-mask offsets.

The one place "dynamic" is genuinely its own thing is **execution**: the runtime-bound fields need
an engine on the command processor, evaluating a predicate and executing a loop, which walks the control-flow graph the static
substrate lacks. So:

- **Authoring/structure:** one stack, one declaration with a binding-time axis. *Not* a separate pillar.
- Execution: the runtime end needs its own engine on that processor, and the split between static and dynamic linking
  ([`device-linking.md`](device-linking.md) §5): one object, one set of relocations, resolved at
  link time *or* load/run time.

**Status:** EXISTS-with-issues. `author_cmd.py` (the `JCRConstBuf__*` const_buf→JCR seed fields), `const_buf`/`CTRL_FLOW`
([`kernel-programming.md`](kernel-programming.md) §3.1, 6 known issues); the native-C CP framework is
proposed, and the formula that seeds the register has no oracle to validate it. This is the least validated frontier, and
the same JCR/CFG-walk territory the paged value gates cover at N>1, so there is a working reference.

## 6. The composition declaration, which is the central artifact

The seam between the two axes. A fully-resolved plan: **leaf selection + per-boundary tier
(fuse/restage/chain) + placement + tiling + psum depth + sync points**, each field tagged by binding
time (AOT-resolved vs runtime-hole).

One declaration has two producers. Searching automatically and authoring by hand are not rivals,
they emit the *same* object; one lowering (`declaration → init.bin + command stream`) consumes
either. Precedent: Halide's algorithm/schedule split; rebel does this internally (search fills the
the tiling or the caller supplies it, and both flow through the same lowering). That is what makes overriding a
search by hand cheap: dump the searched declaration, edit it and lower it again, which is the white-box
advantage, realized.

The declaration **spans both microcode and command-stream layers** (it records the in-`init.bin`
tiers within an image and the chain edges and dependency slots across computes, which is why a composition spans
both" holds even though `chain` realizes in the command stream.

Status: missing. There is no explicit declaration or plan IR today, only the image and its descriptors. Making
it first-class is a core deliverable.

---
---

# For implementers

*Everything above is the model; everything below is the build detail. A non-expert can stop here.*

## 7. Implementation status & build order

A self-contained build spec: where each piece stands, where to start, and how each is proven.

| element | status | entry point (file:symbol) | first move | validated by |
|---|---|---|---|---|
| the leaves, the lowering and the type checker | exists | `KernelToolchain/sp_layout_contract.py` | nothing | the sequence of checks in section 5.2 of the guide: round-trip, decode diff, PrecSim, then the device |
| `instantiate`, `chain` | **PROTO** | `build_dnc_blocks`; `build_multi_cmd` | promote `build_dnc_blocks` → `instantiate(t, ShapeSpec, Placement)` | re-lower `sqrt` at L=1,4 byte-identical (round-trip) |
| the composition declaration, as an IR | missing | new, beside the image-lowering code (`build_init_bytes`/`gen_flits`) | make it first-class, since it is the seam of section 6 | dump and re-lower an existing example, and the bytes match the hand-authored image |
| the scratchpad allocator | proposed | it replaces the frozen constants in `hw_movers.py` | build it, since fusing depends on it | fuse two leaves and decode-diff their scratchpad windows against a hand-placed reference |
| `fuse` / `restage` | **PROPOSED** | `composable-microcode-templates.md` §6 | after `SpAllocator` | PrecSim value-equivalence vs the `chain`ed version of the same op → **CR03** |
| **cost model + search** | **MISSING** | seed from rebel `est_cycles` (`rbln_initgen_gemm.h`) | legality/fit search first, then the cost model | predicted vs measured cycles on gem5 |
| dynamic column / CP engine | **EXISTS-with-issues** | `author_cmd.py` `JCRConstBuf__*` fields; kernel-programming §3.1 | validate the JCR-seed oracle | byte-exact dynamic-N handshake gate on **CR03** |

**Recommended sequence:** **declaration IR → `SpAllocator` → `fuse`/`restage` → cost model + search
→ harden the dynamic column.** Leaves are the standing investment (§2); secure the ~40-archetype set
as the foundation first.

## 8. The twelve mechanisms & the authoring order

### 8.1 The twelve mechanisms the design rests on

Mined from the rebel corpus (all op-classes), placed on the grid:

| # | mechanism | layer | binding | confirms / new for PA |
|---|---|---|---|---|
| 1 | psum / cross-DNC reduction | composition | both | confirms restage tier |
| 2 | HP/FP24 accumulate-round-once (`AccType`) | composition | static | **new** (dlf16-gap fix) |
| 3 | layout-as-ABI + permutation-repack | leaf+comp | static | sharpens layout contract |
| 4 | analytical cost model | search | static | **new** (automation enabler) |
| 5 | the TU compute unit | leaf | static | **new** (new unit) |
| 6 | no-compute (pure-mover) leaves | leaf | static | **new** |
| 7 | data-dependent control flow (JCR) | dynamic column | dynamic | **new** (frontier; paged value gate) |
| 8 | family parameterization (enum+coeffs) | leaf | static | confirms skeleton+slot |
| 9 | route through the declaration | seam | both | confirms the declaration model |
| 10 | running-state fold (online-softmax) | composition | static | confirms `flash_attn_recomp` |
| 11 | explicit dtype-conversion stage | leaf | static | **new** (cast instr family); dtype = hybrid |
| 12 | multi-operand staging + broadcast | leaf+comp | static | confirms operand-count = structural |

(Mining saturated: conv/pool/norm decompose entirely into the above; the last op-class added only #12.)

### 8.2 The order to author a new template in

Bottom-up, because you cannot compose leaves that don't exist or search over compositions that
don't exist:

0. Triage and decompose: map the op onto its class skeleton, its leaf slots and its composition, and decide
   *reuse vs new*; **partition static vs dynamic fields** (which become runtime holes). Given the
   sharing (§2), steps 1–2 are usually no-ops.
1. Ask whether new leaves are needed. Usually none are, and otherwise author them and validate them through the checks. Author the right holes
   for any dynamism decided at step 0.
2. Ask whether new combinators are needed. Usually none are, and otherwise implement them.
3. Search the compositions: the shared framework and the per-class slot resolve the static fields into
   declaration.

**Control flow bookends this:** its *requirements* are captured at step 0 (they shape how
leaves/compositions expose holes); its *logic* is built **last**, on the CP, over the finished
declaration. At kernel-build you emit the resolver + the runtime-input plumbing (const_buf → JCR);
at runtime the CP binds the actual values.

## 9. Prior art: the production template system, which validates this

rebel's `rebel_primitives` Conan package independently reached PA's core: a hand-authored fill-in
per-unit skeleton (`primitive_template.h`) + parametric instantiation binding shapes/addresses →
relocatable per-DNC microcode, behind a named registry (`RblnInitgenBase` + `rbln_initgen_adapter`
+ `RblnFuncMap::init_map`), with a pre-emit validation gate. Identical substrate (8 lanes / 16 DNC),
relocate-by-args, per-DNC base/size.

It **stops where PA's value begins**: no scratchpad-resident `fuse`, no `SpAllocator` (only
memory-*fit* checks), composition pushed up to the compiler (≈ `chain` only). So `fuse` +
`SpAllocator` are genuinely new, and PA's SP-arena / register-namespace open questions are
confirmed-unsolved upstream. Borrowable: the **info/initgen split** (plan separate from emit) and
the **tiling cost search**.

> **Guardrail.** rebel is prior art for *structure and interface shape* only. PA leaves stay
> independently authored and silicon-validated; rebel's microcode/coefficients are never transcribed.

## 10. Open questions

1. The allocator's model: a free arena against a fixed pool, and renaming registers against partitioning them statically
   (caps fusible pairs). (templates §11)
2. The cost model: which cycle oracle, and how it is validated, given that the checks here are functional alone (the
   PrecSim-≠-silicon caveat, §4)?
3. The data type: how far to parameterize before forking, which is the hybrid boundary.
4. An oracle for the register seed: the byte-exact or value validation for the dynamic-count handshake, and the
   precondition for trusting the dynamic column.
5. The threshold on leaf archetypes: pin the exact set to hand-author, around 40, and how far each is parameterized.
