# Mapping a dense matmul onto the REBEL NPU: a microcode-level case study at `m128n768`

An NPU is programmed in microcode rather than in a high-level language.
Microcode is a binary image of per-unit instruction streams that the hardware executes directly.

This case study maps a dense matrix multiply onto one such NPU, the REBEL architecture,
and traces the generated microcode end to end to show how and why it computes its product.
It is worked at one shape, `m128n768`, and verified byte-exact against the device:
the init image reconstructed from the tiling plan matches the device dump exactly.

The three parts mirror the work.
Section 1 describes the machine, which is what the problem has to fit.
Section 2 gives the mapping strategy for matmul, which is how the problem is reshaped to fit it.
Section 3 is the detailed illustration at `m128n768`, unit by unit, and is where the depth lies.

Correctness here is insight gained along the way rather than a formal proof.
Three things are out of scope and flagged where they arise:
whether the sync scaffold is free of deadlock, which is a timing question;
the numerical term that only silicon settles, which is how the rounding lands;
and how the mapping behaves across the whole space of shapes.

# 1. Basics of the NPU

## 1.1 The NCore: a weight-stationary systolic array

The atom of compute is the NCore, a small systolic array.
It multiplies two matrices by pinning one operand in place and streaming the other through it.
Its shape is fixed, and that fixed shape is the source of every later constraint.
It is 64 lanes wide, so one instruction drives 64 SIMD lanes in lockstep;
8 systolic stages deep, `tu0` through `tu7`;
and it takes the streamed operand four rows at a time, a quantum written `Tr = 4`.

That shape determines how a multiply happens.
The eight stages tile the contraction, each holding 8 of the 64 terms.
A streamed row enters from the side and meets the pinned weights,
and a partial sum descends the eight stages, gathering 8 more terms at each,
until the last stage holds the complete sum over all 64.
Meanwhile the 64 lanes produce 64 output columns in parallel,
so one pass of the array is exactly a 64 by 64 block of work.

The idea that drives every later decision is that the two operands are not symmetric.
Being weight-stationary, the array pins one operand into its cells,
which is a relatively expensive load, done once and held,
and streams the other past it, which is cheap and reusable traffic.
The economy is reuse: the pinned operand's load is amortized over every streamed row,
so the more rows go through one standing setup, the better that setup pays off.
Which operand is pinned is therefore the first and most consequential mapping decision,
because it fixes which axis is cheap to grow and which is not, as section 2.2 works through.
The two operands enter from orthogonal edges, the north feed pinned and the west feed streamed.

## 1.2 From the NCore to the chip

A DNC packages two NCores, P and Q, sharing one scratchpad, the inter-unit FIFOs, the NC movers and a
local sync fabric.
The cores are independent compute engines, which gives a rule the whole study leans on:
two cores can split a partition axis and never a reduction.
Independent output tiles go one to each core with no coordination.
Two halves of one contraction cannot, because they would have to add their partials
and the cores share no accumulator.
At small sizes only Q runs, and P wakes when the work needs a second core.

The chip is 16 DNCs in two clusters of 8, plus on-chip SHM, off-chip DRAM, a bulk mover,
and a command processor sequencing the command stream.
Two clusters of 8 DNCs of 2 cores gives 32 NCore slots,
which is the spatial budget the device fills before it ever loops in time.
These sizes never change with the problem.
The problem bends to fit them, which is why mapping is a discipline rather than a free choice.

One tile of work takes nine cooperating instruction streams, one per unit,
since a program is by definition exactly one stream per unit.
Three classes are the lens to read them through.

| class | units | role |
|---|---|---|
| movers | NCLU, NCSU | relocate bytes between DRAM or SHM and SP, never changing them. Their DMA descriptors live in their register file |
| stagers | SPLU, SPSU | move bytes between SP and the compute FIFOs |
| compute | TU, VU, XVU, and the AB pair | transform values: the systolic MAC on the TU, vector and transcendental work on the VU and XVU. In matmul the AB pair is a value-preserving feed into the TU |

Compute units sit at the bottom of the memory hierarchy and never touch DRAM or SHM directly,
since the bandwidth and the latency are both wrong for that.
Operands walk down through progressively smaller and faster stores, and results walk back up.

```
DRAM ──NCLU──► SHM ──NCLU──► SP ──SPLU──► FIFO ──► TU / VU / XVU ──► LRF
                                                          │
                                  SP ◄──SPSU── result ◄───┘  ──NCSU──► SHM ──► DRAM
```

Two facts make this tractable.
Everything moves in 128-byte lines, and one line is 64 dlf16 values,
which is exactly one 64-lane SIMD register of 8 slices by 8 lanes.
So the whole machine speaks one granule and a kernel is, in the end, a stream of these lines.
The FIFOs then decouple each mover from its consumer,
which is what lets movement and compute overlap in time, as section 2.3 describes.

One decision dominates a regular kernel: addressing is placement.
Regions are addressed from a zero base, and a cell forms a product only when its two matching elements
are co-located in it, so deciding which slot each element lands in is not bookkeeping around the work.
For matmul it very nearly is the work, since the multiply is trivial
and getting the right two numbers to meet is the whole problem.

There are two sync scopes and they match the two kinds of axis.
`SYNC` is the handshake inside a DNC, where every send needs a matching receive or the pipeline
deadlocks, and `MESYNC` is the cross-DNC barrier over the cluster tree.
A partition axis needs no cross-DNC barrier, since independent workers never agree on a value,
and a reduction that crosses DNCs does, that being the one moment parallel workers combine partials.

## 1.3 The microcode format

A DNC program is a binary image of instructions rather than compiled text.
It is assembled field by field, round-trips exactly through decode and encode, and needs no compiler.
That is what makes white-box authoring possible:
structured records go in, a pure assembler lays them out,
and what was written is exactly what executes, which is full control and full responsibility for every
field.

The image is a grid.
Columns are units, each running its own instruction stream and owning a vertical block of 16-byte flits,
and rows are tiles, where the per-unit blocks that cooperate on one tile read across as a band.
The TU is the exception, its 8 stage-programs spreading across all 8 columns.

The structural fact the whole study leans on is that a block keeps its three kinds of content in
physically separate regions: its addresses in the register-file flits, its instructions in the
instruction buffer, and its mode in the mode register.
That separation is why scaling is cheap.
Moving to a different tile, a different DNC or a larger problem changes only addresses, never the opcode
sequence, so one frozen program covers a family of shapes, re-placed by address arithmetic.

The smallest thing written is an instruction record, in which every field has a default so that the
round-trip stays exact.
Operand tags name where each operand comes from: a constant zero, a pop of the input FIFO, or a register.
A loop opens with a loop-count instruction carrying a trip count and closes with a block-end bit.
The count is either a static immediate or a runtime value read from the jump-condition register, which is
the one runtime-adjustable knob and the boundary between what is free at runtime and what needs a new
image.
Because the ISA's field names do not always match what the bits do, the rule throughout is to trust the
bit rather than the name.

So scaling a kernel physically means adding rows to the grid while the columns, which are the opcode
sequences, stay put.

# 2. The mapping strategy, for matmul

## 2.1 Tiling, and the classification that decides everything

The engine is a fixed size and the problem is not.
No single instruction does a whole matmul, the fast local store holds only a few lines,
and the array reduces a fixed depth per pass.
So the problem has to be broken into engine-sized tiles and the engine replayed over them.
Tiling is not an optimization that may be skipped; it is the only thing the hardware can do.
The payoff is that making one tile correct and fast covers the whole problem by repetition,
never by authoring a second kernel.

Which tiling is right is decided by one labelling pass over the axes,
because the two kinds of axis map straight onto the machine's cost structure.

- A partition axis, also called free, indexes independent outputs.
  Different values give different answer cells that share no work and need no coordination,
  so they spread across DNCs, cores and lanes at no cost.
- A reduction axis indexes terms that must combine into one answer.
  They need a place to meet and add, and on this machine that place is built exactly once:
  the array's chained partial sum from section 1.1,
  plus the cross-DNC barrier tree from section 1.2 when the reduction spans DNCs.

That labelling is what says, before any investment, whether an algorithm fits the hardware.
Mostly partition axes over one regular reduction suits it, and irregular reductions everywhere fight it.
Matmul is the best case, two partition axes over one perfectly regular reduction.

Each classified axis is then scaled one of two ways, and cost forces the choice.
Scaling spatially, a different worker per value, is parallel and cheap,
but the budget is finite at 32 NCore slots and 64 lanes inside each.
Scaling temporally, one worker looping over the values, is unbounded and serial.
Hence the sentence that organizes all of scaling:
fill the spatial budget first, then fall back to temporal loops.
Loop counts are the cheapest thing in the program to change,
so that fallback costs almost nothing to author.

## 2.2 The matmul hinge: pin C, stream B

For a product of an `[M,K]` input by a `[K,N]` weight, the array pins the weight and streams the input.
That one choice sorts the three axes by how expensive each is to grow,
and the ordering, cheapest first in M then N then K, is the whole strategy in miniature.

- M, the rows of the input, is not in the pinned operand.
  Growing it streams more rows past the standing weights, with no re-setup and pure reuse,
  at the fine quantum of 4 rows.
  This is the free axis a weight-stationary array exists to exploit.
- N, the columns of the weight, is the pinned dimension.
  A new block of N needs a fresh weight pinned into the array, a reload called a turn.
  The cost is moderate, since the setup is paid again but nothing has to be reduced.
- K, the contraction, is the worst, being in both operands and also the reduction.
  Growing it means reloading the weights, re-feeding the input and combining partials,
  through a longer chain or a cross-DNC barrier.
  It is the axis to split last.

The fixed hardware face then forces the tile size, and shows the tiling to be two-dimensional rather
than three.
The array bounds the two genuine tile axes:
N is capped by the 64 SIMD lanes and K by the 8 stages of 8, which is a reduction depth of 64,
so 64 by 64 is the hardware face.
M is not a third tile dimension but the stream length through that face,
unbounded and merely delivered 4 rows at a time, where the 4 is a delivery quantum and not a capacity.
That is the cost ordering restated:
N and K are genuine tiles because the hardware caps them, and M is free because it does not.

So the atom, which is one NCore's pass, is that 64 by 64 face streamed 4 rows deep.
Anything smaller pads up to it, and anything larger replicates the atom across NCores and loops in time.
The atom's opcode sequence does not change with M,
being identical from the smallest cubic tile up,
so scaling touches only loop counts and addresses and never the program's structure.

## 2.3 From tiling to microcode: read it, then realize it as bands

Two disciplines turn a tiling into a correct program.

Read the tiling rather than predicting it.
On silicon a cost model picks one tiling per shape,
balancing reuse against reload and spatial fill against loop overhead.
Reproducing that search is a trap.
A hand prediction is right on the clean shapes and silently wrong at the ragged boundaries,
an odd size, an uneven split, or a tie in how the leftovers are dealt out,
which are the cases hardest to notice and likeliest to be wrong.
So the resolved tiling is read out of a device dump and built to,
and then checked to cover the output exactly once.
Section 3.1 reads a real plan.

Then realize each tile as a band.
A tiling is abstract and the machine runs microcode.
Inside one DNC computing one tile there is a fixed four-station spine,
delivering, computing, draining and then egressing.
It is shaped that way because the expensive part is not the arithmetic
but getting operands to the multiplier and results back out.
The first and last stations are pure data movement, and they still do not dominate the clock,
because the stations are independent units coupled by FIFOs that hold many items
and synchronized point to point.
While the loader streams this tile's operands in, the compute unit is already consuming earlier ones,
so movement runs concurrently with the arithmetic and stays hidden behind it.

One tile's full set of per-unit blocks is a band, and the 16 DNCs run the same band at shifted addresses.
So realizing the whole dataflow means writing one DNC's band against its tile
and letting address arithmetic place the other fifteen.

Section 3 now reads a real tiling plan and traces the bands it produces down to the bytes each unit
runs.

# 3. Illustration: mapping `m128n768`

This is the heart of the study.
With the machine from section 1 and the strategy from section 2 in hand,
one shape is followed from the tiling the device chose down to the bytes each unit runs.

## 3.0 The whole picture, from the product down to the hardware facts

Start with the map.
The device computes the product top-down.
It carves the output into per-NCore pieces and computes each with one NCore's program,
and that program is the four-station spine.
Here is the whole decomposition, each piece pointing to the section that details it.

```
A = B·C
│
├─ carve A into 24 per-NCore bricks of 64 by 64, placed across the chip          → 3.2  placement
│
└─ each brick is one NCore's band: deliver, compute, drain, egress                → 3.3  the band
        ├─ deliver   feed the weight to each cell's north, the input to its west  → 3.4  input
        ├─ compute   contract the K-sum into the partial sum, at FP18             → 3.5  the TU brick
        ├─ drain     round the result to dlf16                                    → 3.6  output
        └─ egress    store it into the brick's local region                       → 3.6  output

  all of it rests on a few facts about how the silicon runs the bytes             → 3.7
```

The sections follow that tree from the top.
Section 3.1 reads the tiling the device chose and section 3.2 carves the output into its 24 bricks and
places them.
Section 3.3 shows how one NCore computes its brick, which the next three break out:
3.4 delivers, 3.5 computes, and 3.6 drains and egresses.
Section 3.7 lists the hardware facts they all lean on,
and section 3.8 weighs what is verified against what is left out.

## 3.1 The tiling plan

The tiling is the device cost model's choice, read off the dump as section 2.3 describes.
The bounded tile is the 64 by 64 face over N and K, with M streaming through it.
At M=128, N=768 and K=64 the plan handles each axis according to its kind.

- M is the streamed axis rather than a tile.
  It is distributed two ways across the cluster axis into row bands of 64,
  and then streamed 4 rows at a time within each, giving 16 groups per band.
- N is tiled onto the 64-wide face, split twelve ways into 64-wide output tiles and placed spatially:
  6 groups across DNCs, and within each DNC its 2 NCores take one tile each in parallel.
  That is what two turns means here, two tiles per group realized by the two NCores,
  rather than a temporal loop on one TU.
  A genuine temporal loop over the output tiles appears only from four turns up,
  once a DNC owns more tiles than it has NCores.
- K is already exactly the face's reduction depth, so it takes a single pass and no split.

So 24 NCores are active, each owning a 64 by 64 brick of the output, and the cover is exact,
24 bricks of 4096 elements being the 98304 the shape needs.
The 24 fit inside the 32-slot spatial budget with 8 idle,
so the assignment is entirely spatial: every brick gets its own NCore
and a DNC's two output tiles go one to each of its NCores, with no TU looping over a second tile.
The only temporal loop inside a band is the M stream, of 16 groups.
The rest of section 3 follows one such brick, through its placement, its band and its microcode.

## 3.2 Placement: the carve and the offset

A band computes one brick, a 64 by 64 slab, into its own local output region.
Placement is the level above the band.
It says which brick each NCore owns and where that brick lands in the global output.
That is two jobs: the carve, under which the 24 bricks tile the output exactly with no overlap and no
gap, and the offset, under which each brick's local region maps to its correct global rows and columns.
Placement belongs to no single band, being how the 24 bands' bricks assemble into the whole answer.

No unit runs it.
Unlike the feed and the egress chains, no mover executes the placement.
It is baked into the addresses, in the two ways below.

| level | how | in the bytes |
|---|---|---|
| per DNC, by cluster and group | a baked base offset | the 16 per-DNC init images differ, 14 of them distinctly, the 2 collisions being idle stubs. Each carries its DNC's group base and cluster-half base |
| per NCore, within a DNC | a positional offset | the TU program is byte-identical and broadcast to both NCores, and they still pin different output tiles. So the within-DNC offset selects the NCore's tile along N rather than a half of the rows, and both NCores share the band's 64 rows |

The carve first.
The partition map from a slot to a block of rows and a tile of columns is fixed by the tiling:
M splits two ways across clusters at 64 rows each,
and N splits twelve ways into 64-wide tiles, addressed as 6 groups across DNCs by the 2 NCores in each.
Laid out, that is a 2 by 12 grid of bricks over the output.

```
   The 24 bricks laid out over A, a 2 by 12 grid, each cell labelled with its N-tile index:

     N-tile:  0  1  2  3  4  5  6  7  8  9 10 11
            ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
   c=0 ───► │ 0│ 1│ 2│ 3│ 4│ 5│ 6│ 7│ 8│ 9│10│11│   rows 0–63    (M-block 0 = cluster 0)
            ├──┼──┼──┼──┼──┼──┼──┼──┼──┼──┼──┼──┤
   c=1 ───► │ 0│ 1│ 2│ 3│ 4│ 5│ 6│ 7│ 8│ 9│10│11│   rows 64–127  (M-block 1 = cluster 1)
            └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
   DNC d:      0     1     2     3     4     5      each DNC = an adjacent N-tile pair (g = 0,1)

   partition (c, d, g) ↦ (M-block c, N-tile 2d+g):  2 clusters × 6 DNCs × 2 NCores = 24 bricks of 64×64
   a bijection onto the grid. 24 bricks of 4096 is 98304, an exact cover with no overlap and no gap
```

The map is a bijection from the 24 slots onto the 24 axis-aligned bricks and the cover is exact,
since both divisions come out whole.
It is index arithmetic alone, with no operand value involved.

Then the offset.
Each slot's global base is a base plus an affine function of the slot index.
The cluster and group part is the baked per-DNC offset,
read straight off the differing init images as the stride over groups and cluster halves,
and the NCore part is the positional offset, one tile of 64 columns within the DNC's group.
The map is affine in the slot index and its image is exactly the disjoint cover above,
so each brick's local region lands at its correct global rows and columns.

What is trusted here against what is derived: the carve is arithmetic and needs no trust.
The offset leans on the per-DNC bases read off the differing init images,
and on the positional within-DNC offset being the device's addressing convention,
which sits in the trusted base that section 3.7 lists.
This is the one worked shape, and covering every shape's slot count and strides is separate work.

With the carve and the offset fixed, the 24 bands' bricks tile the whole output with none missing or
misplaced, which is what assembles the per-NCore results into the matmul.
Section 3.7 collects the hardware fact behind the positional offset.

## 3.3 The band: one NCore's spine

A band is one NCore's entire program, the four-station spine that turns this NCore's operands into its
brick, a 64 by 64 slab written into the NCore's local output region.
The three sections after this one break the stations out in detail, and this one is the whole they fit
into.

One trip's data runs through four stations, each with its own unit and its own section.

```
# one NCore's band
deliver:  feed the weight to each cell's north, the input to its west    → 3.4
compute:  the TU contracts the K-sum into the partial sum, at FP18       → 3.5
drain:    the VU rounds the result to dlf16                              → 3.6
egress:   store the rounded result into the local region                 → 3.6
```

The stations share no state and hand off only through FIFOs, the input queue feeding the TU and the
egress queue draining it.
Each reads its input queue and writes its output queue, and the spine works because walking it, each
station's output is exactly the next one's input:
delivering fills the cells' feeds, computing leaves a finished sum in the egress FIFO, draining rounds
it, and egress stores it.
Because the hand-off is a FIFO and nothing reaches into another unit's registers,
each station can be understood and built on its own.
That is why the drain-before-reuse question in section 3.5 can be reasoned out with its neighbours left
as black boxes.

One band produces one brick, and the full matmul runs 24 of them in parallel, one per active NCore.
The placement of section 3.2 puts each brick at its spot in the global output.

## 3.4 The feed

The TU does the arithmetic but assumes the right operands are already at its edges,
the weights pinned along the north and the input rows arriving from the west.
The feed is what makes that assumption true.
It is the deliver station of the band's spine, and for every trip it puts the right weight element on
the north of each cell and the right input element on the west.

This NCore computes one output tile, so it pins one weight tile and never re-pins per turn.
The DNC's other tile is its sibling NCore's job and the two run in parallel.
So the feed has two jobs, staging the input to the right lanes and pinning this NCore's weight.
Section 3.6 covers the mirror of this, getting results back out.

Unlike the TU, which is one unit with eight column programs, the feed is a chain of staging units,
each with its own instruction buffer and running in dataflow order.
The two feeds converge on the TU cells from the orthogonal edges of section 1.1.

```
   C (weights):  SHM ──NCLU──► SP ──SPLU──► FIFO ──XVU──► the NORTH edge
   B (input):    ─────────────────────────── ABLU/ABSU──► the WEST edge
```

- The NCLU moves the weight from SHM into the scratchpad, through load ops whose addresses come from
  the address-arithmetic ops beside them.
  It is a per-DNC unit, so it loads both NCores' weight tiles into the scratchpad
  and each NCore's SPLU then picks out its own.
- The SPLU streams this NCore's weight tile from the scratchpad into the TU's input FIFO,
  in load bursts of some number of 128-byte lines, stepping its address register between them.
  There is one tile, so no per-turn rebase.
- The XVU encodes that stream onto the north feed.
- The AB pair stages the input onto the west feed.

Seen whole, with both NCores of the DNC at once, that is one shared weight load,
two tiles picked out of it, and one shared input stream.
This is the spatial two-NCore split of section 3.2, drawn as a dataflow.

```
   one DNC, holding group d:
   │
   │   weight:  SHM ─NCLU─► SP        the NCLU loads BOTH output tiles into SP, being per-DNC
   │   input:   SHM ─AB───► west      the SAME 64 rows feed both NCores
   │
   ├─ NCore P:  its SPLU picks weight tile 2d    →XVU→ tu0   → output columns of tile 2d
   │
   └─ NCore Q:  its SPLU picks weight tile 2d+1  →XVU→ tu1   → output columns of tile 2d+1

   one weight load into shared SP, two tiles picked out of it, one input stream shared.
   tu0 and tu1 run in parallel over the same 64 rows, each writing a disjoint 64-column tile.
   A marker trace confirms it: tile 2d reaches only tu0 and tile 2d+1 only tu1.
```

So the per-DNC NCLU does the heavy load from SHM into the scratchpad once for both tiles,
and splitting into the two output tiles is the cheap part:
each NCore's SPLU picks its own tile out of the shared scratchpad and both read the single input stream.
The rest of sections 3.4 to 3.6 follows one of these two lanes,
and its sibling is the same program on the adjacent tile.

As with the TU, an opcode's name does not always match its job, so trust the bit.

The feed chain in pseudocode, one trip read as it runs:

```
# deliver the weight to each cell's north and the input to its west.
# SP is the scratchpad, the FIFO is the TU's input queue, the LRF holds the addresses.

# this NCore pins ONE output tile; its sibling pins the other, in parallel
NCLU loads   SHM -> SP        # the DNC's two weight tiles into the scratchpad
SPLU streams SP -> FIFO       # some lines per burst, in order, picking out THIS NCore's tile
XVU  encodes FIFO -> north    # format-convert onto the TU's north edge

for m_group in range(16):     # 64 rows, 4 at a time, shared with the sibling NCore
    ABLU stages input -> west # 4 rows onto the TU's west edge

# which streamed element lands on which cell is the port-to-cell wiring
# composed with the layout tag along K, either flat or lane-reversed.
# The checker requires the streamed and the pinned operand to agree on K.
```

Two things are worth understanding, and the rest of this section takes them in turn:
the stride map, which is the addresses, this NCore's single weight pin and its in-order walk over the
input rows, and the lane map, which is which streamed element reaches which cell.

Reading the program part by part.

First the stride map, which is the addresses.
Every staging address is an affine recurrence, a base plus a sum of strides times indices,
and the strides are exactly the decoded register increments, the
generator writing the operand layout straight into the address arithmetic. Two consequences:
- *Single `C` pin (no per-turn re-stage).* At `turns = 2` each NCore pins **one** tile's `C`; the two
  tiles are the two NCores, so there is no per-turn rebase.
  The two TUs carry distinct weight bases, each set once.
  A genuine per-turn rebase, on a back-edge over the turns with a stride linear in the contraction
  extent, appears only from four turns up, when a DNC owns more tiles than it has NCores.
  That was checked at four turns and at eight.
- The input rows are walked in order.
  The load op walks the row chunks in order and each once, one chunk of the burst size per pass,
  advancing the pointer by the row stride, so all 64 rows are fed with none dropped or duplicated.

Then the lane map, which is what makes the two operands agree on the contraction index.
Which streamed element reaches which cell is the fixed port-to-cell wiring,
modulated by the per-axis layout tag the SP layout contract carries.
For dense matmul the only non-trivial axis is the contraction.
The contract pins its layout, lane-reversed on the transpose path and flat otherwise,
and the checker statically requires the streamed operand and the pinned one to agree on it.
A disagreement is the silent bug the contract was built to catch.
Given agreement, the element at systolic step k pairs with the weight row at the matching k,
which is precisely the pairing the TU's contraction assumes.

Together the two maps deliver this NCore's weight tile and all 64 input rows, each to the right cell.
So the TU's assumption that its operands arrive is met and the deliver-to-compute path holds end to end.

Two loose ends.

The layout rules are trusted rather than derived.
The lane map rests on the flat and lane-reversed rules being the device's convention,
which the checker tests against by failing on a mismatch but does not prove from below.
It belongs in the trusted base with the other hardware facts.

Timing is a separate story.
Unlike the TU, the staging chain is full of sync, the ordering that keeps the scratchpad, the FIFO and
the feeds from racing.
That ordering, and whether it is free of deadlock, is the timing layer rather than the value map,
and is out of scope here.

## 3.5 The TU brick: the per-NCore contraction

The TU is the one place the multiply happens and the compute station of the band.
Its job is the contraction: take the pinned weights and the streamed input, sum along the contraction
axis, and leave the answer in the partial sum.
Once this NCore's TU program has run, every cell holds its own dot product,
at FP18 and unrounded for the VU to round later,
across the NCore's 64 rows and 64 columns, which is its one brick.

The DNC's other output tile is computed in parallel by the sibling NCore,
each NCore pinning its own tile's weights on an array of the same shape,
rather than one TU looping over two tiles.
The one thing the TU does not do is move data in or out.
It assumes the right operands arrive at its edges, delivery being the feed's job, and does the
arithmetic.

Before the behaviour, the shape on disk.
A band is nine per-unit instruction streams, one instruction buffer each, and the TU is the odd one out,
emitting eight near-identical sub-programs, one per systolic column.
That ratio of eight to one is how to spot the compute unit in raw microcode.

Each line of a buffer is an instruction record, an opcode plus its operand fields,
and only three opcodes appear here.
One sets a loop count.
The FMA is the workhorse, and its run mode and its source and target fields decide whether a given one
loads weights, skews them, or multiply-accumulates.
The third pads to the buffer boundary.
An opcode's name does not always match its job, so trust the bit.

The eight column programs sit on two orthogonal axes,
the reduction running down the 8 stages and the 64 outputs running across the lanes.

```
        the weights: pinned from the NORTH, skewed DOWN the stages
                                 │
                                 ▼     the 8 stages, stacked; the partial descends

            col 0 (tu0)  K[ 0:8 ]   seed the partial at 0   ┐
            col 1 (tu1)  K[ 8:16]   + the north partial     │ each col owns 8 of the 64
            col 2 (tu2)  K[16:24]   + the north partial     │ terms, adding them onto
              ⋮     ⋮        ⋮            ⋮                 │ the partial from above
            col 7 (tu7)  K[56:64]   + the north partial     ┘
                            │
                            ▼
                       egress to the VU    (the whole 64-term sum, FP18, unrounded)

        the input: streamed from the WEST. 64 lanes across are the 64 outputs, in parallel,
                   since every FMA is one SIMD op over all 64 lanes at once.

   Phase 1, the skew fill: each col latches its weight octet then forwards it south, so the 8
             octets land staggered in time. The skew depth runs 56, 48, down to 0, which col 7 skips.
   Phase 2, the MAC: the inner loop runs 16 groups, which is 64 rows at 4 each.
             The multiply is in dlf16 and the accumulate in FP18.
```

The ISA calls the 8 stages columns and emits one program each.
Geometrically each is a horizontal slice across the lanes; they stack top to bottom and the partial
descends the stack.
So a column here is the stage index rather than a vertical orientation.

The whole segment is loaded once, up front, being a column of the init image,
and then runs as pure dataflow with no sync.
Nothing stalls it on a barrier and each FMA fires as its operands arrive.
That alone sets it apart from the mover and stager streams, which are full of sync.

With the shape in hand, here is what one column computes.
Each loop in the pseudocode is one loop-count instruction,
the multiply is dlf16 and the accumulate FP18.

```
# one column's program, for col 0 to 7; all eight run concurrently
# Inputs: the weights pinned from the north, this NCore's one tile, fed as section 3.4 describes,
#         and the input streamed from the west.
# Lanes:  every phase-2 op is one SIMD instruction over all 64 lanes at once.
#   the per-lane weights pin one output column each, the input octet broadcasts to all lanes,
#   and the partial sum holds 64 values.

parallel for col in range(8):                         # 8 independent column programs, each its own ibuff   ← spatial ×8, NOT a loop

  for _ in range(1):                                  # leading level 0: the output or batch block
   for _ in range(1):                                 # leading level 1: N, folded here so one trip
    for _ in range(1):                                # leading level 2: K, unsplit here so one trip

        # phase 1 configures the systolic latch path, once and the same for every tile. The weight data is fed
        #           from the NORTH by NCLU→SPLU→XVU (§3.4); these FMAs latch & time it, they don't source it.
        latch the weight octet K[8*col : 8*col+8]     # capture this col's north octet. A zero first source
                                                      #   kills the product, so this also seeds the partial
        for _ in range((8-1-col)*8):                  # the skew depth: 56, 48, down to 0, which col 7 drops
            forward the octet south                   # set the column-skew timing. It carries no partial

        # phase 2, the MAC. The pinned weight is THIS NCore's one output tile.
        for m_group in range(16):                     # 16 groups, which is 64 rows at 4 each
            b = west_in[col]                          # 4 input rows, broadcast across all 64 lanes
            psum[:] = 0 if col == 0 else north_in[col][:]   # col 0 seeds fresh, cols 1-7 take the partial
            psum[:] += pinned_C[:, 0:4] * b           # the first K-half, accumulating at FP18
            psum[:] += pinned_C[:, 4:8] * b           # the second: 64 lanes by 4 products, 8 terms in all
            south_out[col][:] = psum[:]  if col <  7  # forward 64 partials down to the next stage
            egress_fifo.push(psum[:])    if col == 7  # col 7 pushes the whole 64-term sum to the VU

  # the trailing NOPs and RETURNs pad the buffer on every column; they are not a systolic flush
```

Which FMA is which is a question of fields rather than names.
All four labels are the same opcode, and the source, target and run-mode bits pick the job.
The table below was checked against the generator and against the decoded dump.

| label | src0 | src1 | src2 | target | job |
|---|---|---|---|---|---|
| the latch | zero | north, the weight | seed | the register file, seeding the partial | capture the weight octet. A zero first source kills the product |
| the skew | north, the weight | zero | seed | south | forward the weight south, which sets timing alone |
| the first MAC | the register file | zero on col 0, north on 1-7 | west, the input | the register file | the first K-half. Col 0 seeds the chain fresh |
| the second MAC | the register file | the register file, the chain | west, the input | south, or the VU | the second K-half. Forward it, or egress at col 7 |

The source multiplexer chooses among zero, north, west and the register file.
A nonzero target forwards south, and stage 7 targets the VU instead.
The MAC multiplies the pinned weight by the west input and adds the descending north partial.
The run mode gates it, so the same opcode is a no-op multiply in phase 1 and a real MAC in phase 2.

Read structurally, that nest is not one five-deep chain.
Three nested leading loops, all of one trip in this folded shape, wrap a body of two sequential phase
loops.

```
L0 (=1) contains L1 (=1) contains L2 (=1)
                     ├ the skew, 56 down to 0, which is the phase-1 fill
                     └ the inner loop, 16 trips, which is the phase-2 MAC
```

The parallel over columns is spatial hardware, the eightfold TU replication,
and the lane slices are SIMD.
Neither is a loop-count instruction.

The split between the outer and the inner loops follows the pinning rule.
The pinned axes take the outer slots and the streamed axis runs innermost,
which is why M is the inner count.
That count is 16, the 64 rows of this NCore's band streamed 4 at a time.
There is no factor of two for the two output tiles:
at two turns the tiles are spatial, this NCore taking one and its sibling the other,
so neither gets a loop level.
A genuine temporal loop over the output tiles takes an outer slot and appears only from four turns up,
and a split contraction likewise keeps its turns in an outer slot,
because its partials must accumulate across levels.

The eight columns are likewise not eight different programs but one template parameterized by the column
index.
Only three things differ: the skew depth, the seed, which is fresh on column 0 and the north partial
elsewhere, and the egress, which only column 7 does.
Column 7 also drops the skew and the second weight-load FMA.

At this shape only the skew fill and the inner loop actually iterate.
The rest is the frame the device scales:
an unfolded N raises the second level, a split contraction the third, and a larger M the inner count.
That is the one runtime knob over a frozen opcode sequence.

Two things are worth understanding, taken in turn below: the skew fill and the per-tile MAC.
There is no story about crossing tiles inside the TU,
since a DNC's two output tiles are two NCores running in parallel rather than two turns of one TU.

Phase 1 configures the latch path, and mistaking it for data movement is the easiest error here.
The two phase-1 FMAs look like the TU loading weights, but the weight data is sourced and timed by the
feed, and these two only capture and stagger what arrives on the north edge.
The first latches this column's 8-term octet into its cells, and because its first source is zero the
product is killed, so the same op also seeds the partial.
The skew loop then forwards the octet south so that the eight octets land staggered in time.

Staggering is needed because the array is a wavefront.
The input enters at column 0 and walks down the stages, so each column's weights must be in place
exactly when the input reaches it rather than all at once.
Column 7 has nothing downstream, so its skew count is zero and it skips the loop.
One consequence is easy to miss: the north edge does double duty,
carrying the weights into the cells in phase 1 and the descending partials in phase 2.
The skew primes this NCore's array once from cold, and the sibling NCore primes its own,
so there is no second skew for a second tile.

Phase 2 is where the contraction comes out right.
Each column owns 8 of the 64 terms.
Column 0 starts its running sum fresh and columns 1 to 7 take the partial from their north neighbour and
add their own 8 terms onto it.
By the time the partial reaches column 7 it has gathered all 64 terms,
which is the full reduction done as eight chained segments rather than eight separate sums.
Meanwhile the inner loop streams all 64 rows past the pinned weights
and the 64 lanes produce this tile's 64 output columns in parallel.
Nothing is rounded here: the TU leaves FP18 in the partial and the VU narrows it later.

The two output tiles are two NCores rather than two turns.
A DNC owns two 64-wide tiles and its two NCores compute them in parallel, each pinning its own.
A marker trace confirms the split, each tile's weights reaching only its own TU and both markers landing
in the output.
So a single TU never re-pins a second tile and there is no question of the two colliding,
since they run on different hardware and write disjoint output columns.
Each trip still re-seeds column 0 from zero, which is what keeps the row groups independent of one
another, and that is a per-trip property rather than a per-tile one.

That is the whole compute story for one NCore:
the right 64-term sum in every cell, all 64 rows of its one output tile covered, and FP18 left for the
VU.

Two things the walk above set aside.

There is no per-turn re-pin at two turns.
The single latch pins this NCore's one tile and the DNC's other tile is its sibling's, pinned by that
NCore's own latch, which the marker trace confirms.
A genuine per-turn re-stage of the feed appears only from four turns up, when a DNC owns more tiles than
NCores.
The skew is a matter of timing rather than of value, PrecSim being bit-accurate and not cycle-accurate,
so it belongs to the timing layer rather than to the product.

What is solid here and what rides on the feed:
the arithmetic the TU does by itself, which is each cell's sum, the row and column coverage and the FP18
result, reads straight off this program and does not depend on how the other units behave.
The two things it does not do, delivering the right input to each lane and pinning this NCore's weight,
are the feed's job.
Section 3.7 collects the hardware facts underneath: the FMA's zero seed, the systolic wiring and the
in-order execution.

One NCore's brick is a single 64 by 64 tile of the answer.
The band wraps this compute spine with its deliver, drain and egress stations,
and the placement puts each brick's slab at its place in the global output.

## 3.6 The egress, which mirrors the feed

Where the feed delivered operands to the cells, the egress carries each finished result from the cells
out to its place in the brick's local output region.
The TU drains a completed sum out of column 7, still at FP18, and the egress rounds it and stores it
where it belongs.
So it has two jobs mirroring the feed's two: the VU rounds the drained result,
and the store chain places it in the local region, writing this NCore's one output tile in two passes
over halves of its rows.
Where that region then sits in the global output is a level up, in the placement of section 3.2.

The egress is the store-side chain, the feed chain reversed,
its store units running in dataflow order, each with its own instruction buffer.

```
   result out:  TU col 7 ──drain──► FIFO ──VU·SPSU──► SP ──NCSU──► SHM ──DMA──► DRAM
```

Stacked against the feed, the egress is that chain run backwards,
each store unit mirroring a feed unit.

```
        the feed (3.4)                │  the egress (3.6)
        ─────────────────────         │  ─────────────────────
   SHM  ──NCLU(load)──►  SP           │  SP    ──NCSU(store)──► SHM ──►DRAM
   SP   ──SPLU(burst)─► FIFO          │  FIFO  ──SPSU(burst)──► SP
   FIFO ──XVU(encode)─► NORTH edge    │  col 7 ──VU(round)────► FIFO
        (input onto WEST via the AB)  │  (the TU drains col 7, FP18 to dlf16)

   The same chain reversed, each egress row mirroring the feed row beside it:
   NCLU against NCSU as the SHM mover, SPLU against SPSU as the SP burst,
   XVU against VU as the edge encode and the round.
   The feed reads downward into the cells and the egress reads the drain back out.
```

- The TU starts it. Column 7's drain pushes the finished sum out of the partial into the egress FIFO.
  That op is the TU's own, and the egress picks up from the FIFO.
- The VU rounds the drained result to dlf16, through a cast-store with a compare beside it.
  How accurate that round is belongs to the numerical question, and here it is the narrowing step alone.
- The SPSU streams the rounded rows from the FIFO into the scratchpad, in store bursts,
  stepping the address once per pass over a half of the rows. It mirrors the SPLU.
- The NCSU stores the scratchpad into SHM, in store pairs, mirroring the NCLU,
  and the output DMA then carries SHM out to DRAM.

The same caveat holds as everywhere: an opcode's name need not match its job, so trust the bit.

The egress chain in pseudocode, one trip's result on its way out:

```
# round each finished result and store it to the local output region.
# The FIFO is the TU's egress queue and SP is the scratchpad.

VU   rounds FIFO -> dlf16        # a cast-store with a compare: narrow this NCore's drained partials
for half in range(2):            # the store splits into 2 passes, each over a half of the rows
    SPSU stores FIFO -> SP       # burst the rows to the scratchpad, stepping the address per pass
    NCSU stores SP   -> SHM      # write this half of the tile's rows out, at the per-DNC placement
# The 2 passes are halves of the rows of this NCore's ONE output tile.
# They are not two output tiles; those are the two NCores. A per-tile store loop needs four turns.

# The output lane map: egress does not preserve position, the array draining in a fixed order.
#   A lane-reverse row permutation at the cells, then the output DMA's reorder.
#   Composed, the two are the identity onto the output, with nothing lost, duplicated or misrouted.
```

Mirroring the feed, two things are worth understanding:
the store-stride map, which is where each trip's result lands in the local region,
and the output lane map, which is the fixed drain order.

The store-stride map is the symmetric twin of the feed's staging stride:
the NCSU's store pair plus the SPSU's burst, split into two passes over halves of the rows,
each pass writing its half of this NCore's rows to its tile's columns,
by the per-DNC placement plus a per-pass row stride.
The same caution applies as on the feed side:
at two turns this two-pass split is the two-chunk store rather than two output tiles,
since the tiles are the two NCores, and a genuine per-tile store loop appears only from four turns up.

The output lane map is where egress differs from the feed: it does not preserve position,
because the array drains in a fixed order.
At the atom shape that order is a lane-reverse row permutation, confirmed bit-exact
by feeding an identity input and getting the lane-reversed weight back, at zero error.
The output DMA then applies a second reorder, and the two compose to the identity onto the output,
with nothing lost, duplicated or misrouted, corroborated byte-exact end to end.
So the store map is a bijection that matches the declared layout.

Together the store-stride map routes each trip to the local region and the lane map is a bijection over
layouts, so every drained result departs to its correct place there.
That is the mirror of the feed's guarantee that every operand arrives at its correct cell.

Three loose ends.

The drain order is trusted rather than derived.
As the feed leaned on the layout rules, the egress leans on the two permutations being the device's
conventions.
The byte-exact silicon result corroborates that they compose to the identity for the worked shape,
and the bijection across every shape is separate work.
Both sit in the trusted base.

This is placement rather than accuracy.
The egress covers where each value goes and not how exactly the VU's round came out,
which is the numerical question.

Timing is a separate story.
Like the feed, the store chain is full of sync, and that ordering, and whether it deadlocks,
is the timing layer and out of scope here.

The egress is the last of the band's four stations, mirroring the feed and picking up from the TU drain.
The offset from the brick's local region to the global output is one level up, in the placement.
Section 3.7 lists the hardware facts behind the maps.

## 3.7 The hardware facts it all rests on

Everything above rests on a small fixed set of facts about how the silicon executes the decoded bytes.
Each is a fact about the device rather than something derived here.
Each is validated bit-exact against the simulator model, which `../../dnc_spec/docs/dnc-isa-interpreted.md` describes,
and then taken as given.

First, compute, which is the within-tile contraction that section 3.5 uses.

- The MAC. One TU multiply-accumulate adds the product of two sources to a third.
  The multiplicands are the first and third source fields, holding the pinned weight and the streamed
  input, and the accumulator is the second, holding the partial sum.
  So the form is `src1 + src0 * src2` rather than `src0 * src1 + src2`, which the decode confirms,
  since both MAC ops read the weight from the register file and the input from the west.
  The multiply is dlf16 and the accumulate is FP18, which is the TU's partial-sum type.
  The wider FP24 field is the VU's drain type.
- The accumulator selector. Its zero setting reads the constant zero, giving a fresh partial that reads
  nothing prior, and its north setting reads the previous column's partial, which is the systolic chain.
- The systolic tile. The 8 columns of 8 rows tile the 64-term contraction.
  Weights are skew-loaded into the cells and each column's partial is forwarded south,
  so the chain spans the full reduction.
- Lane parallelism. The 64 lanes produce the active tile's 64 output columns in parallel, one each.
- Chunk enumeration. A loop of n trips enumerates its n chunks, each exactly once.

Execution, which is what makes a unit-local argument possible.
Section 3.5's drain-before-reuse argument uses these, as does the band composition of section 3.3.

- In-order execution. A unit executes its instruction buffer in program order,
  so within a loop trip and across trips, earlier ops complete before later ones.
- Private state. A unit's register file and partial sum are private,
  read and written by no other unit, since data crosses units only over the explicit FIFOs.
- Transfer. A store or forward op copies a value to the named destination,
  which is the south neighbour's partial, the egress FIFO, or the scratchpad or SHM,
  and that decouples the producer from the consumer.
  In the TU one field selects what is forwarded, either source or the result,
  and the forward from row 7 to the VU realigns the partial-sum field by a fixed shift.
  The store-side duals are verbatim 128-byte copies.

Addressing and placement, which the feed, the egress and the partition maps all use.

- SP transport. A transport op streams the scratchpad from the address in its register,
  some number of 128-byte lines in order and each once, to the consumer FIFO.
  One address op adds a constant to the register, another rebases it,
  and an enclosing loop re-runs the recurrence.
  Its store dual writes by the same rule.
- The wiring. The port-to-cell wiring is fixed: the west FIFO's element at systolic step k
  and the north weights enter the array at hardware-fixed lanes and cells,
  modulated by the per-axis lane layout, which is either flat or lane-reversed.
  That layout is a device convention, held as the rules in `KernelToolchain/sp_layout_contract.py`
  and statically enforced, since the checker fails when a consumer's two operands disagree on a shared
  axis.
  The tag itself is host-side metadata, PrecSim modelling only the underlying shuffle and not the tag.
- Placement by address. A unit's spatial position offsets its base address, and two facts are pinned by
  the decode.
  The per-DNC base is baked, since the 16 per-DNC init images differ, 14 of them distinctly and the 2
  collisions being idle stubs.
  The per-NCore base within a DNC is positional, since the TU programs are byte-identical and broadcast
  to both NCores and still pin different output tiles, which a marker trace shows.
  So the within-DNC offset selects the NCore's tile along N rather than a half of the rows,
  and both NCores share the band's rows.
  PrecSim runs both NCores from the same broadcast stream, so the positional fact is inherited hardware
  behaviour corroborated by the marker trace, and the baked per-DNC base is loader-level.

Two device conventions are taken as given the same way, statically checked rather than derived:
the lane-layout rules folded into the wiring fact above,
and the egress drain order with the output DMA's reorder from section 3.6.
That is the whole floor, and everything above it is read off the decoded bytes given these facts.

## 3.8 What's verified, and what's out of scope

What this account shows is the matmul's structure:
that the device places and contracts exactly the dot product it should, at this one shape,
traced from the tiling down to the bytes, with the reason for each piece visible along the way.
Those reasons are the fresh seed that severs the previous turn in the TU,
the in-order feed, and the disjoint carve.
It is backed concretely, since the init image reconstructed from the plan matches the device dump
byte-exact.

Three things are out of scope, and are flagged here rather than glossed over.

- Whether the sync and FIFO scaffold ever deadlocks, and whether it terminates.
  That is a timing property, separate from the value map.
  This account establishes what each unit computes, not the ordering that keeps them from racing.
- How exactly the error from the FP18 accumulate and the dlf16 round lands.
  This account covers where each value goes and not its last-bit accuracy.
- Every shape, rather than this one.
  The same machinery scales by changing counts and strides, through more bands and larger loop counts,
  but only one shape is worked here and the argument across all of them is not pursued.

# Conclusion

Mapping a matmul onto this NPU comes down to one decision applied consistently, which operand to pin.
Pinning the weight and streaming the input sorts the three axes by cost, fixes the atom of work,
and dictates the whole dataflow: which axis is free, which re-pins, and which reduces.

Every later decision follows from it.
The tiling carves the output into 24 independent bricks, each realized as one NCore's band,
and the microcode of the four stations is almost entirely the placement arithmetic
that gets operands to the multiplier and results back out.
The multiply itself is the small part.

Reading the generated microcode rather than predicting it is what makes the account trustworthy.
The device's tiling was read and the reconstructed image verified byte-exact,
rather than guessed at the ragged edges.
What remains, the deadlock question, the numerical term and the argument across all shapes,
is stated in section 3.8 and is where a follow-on would go.
