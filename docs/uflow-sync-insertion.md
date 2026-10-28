# Sync insertion: from ULoop to UFlow

A ULoop pipeline is one sequential loop nest. After projection to UFlow, each unit runs its own part of
that nest concurrently with the others. Units pass values through FIFOs, which order themselves, but SP
buffers have no such ordering: a unit can read lines before another has written them, or overwrite lines
before another has read them. Sync insertion adds the `SYNC` puts and gets that prevent both. It runs on the
ULoop nest, before projection, so that every check walks a single program order.

Based on `mlir-loop-ir.md` §3 (sync insertion) and the EVT1 ISA's `SYNC`. It fixes two gaps there: shared
counters (§3) and buffers with more than one slot (§4).

## 1. Who writes and who reads SP

The load and store units are named for the direction of their transfer, not for SP: the NCLU *loads* from
SHM *into* SP, so it writes SP.

| Unit | Transfer | Writes or reads SP |
|---|---|---|
| NCLU | SHM → SP | writes |
| SPLU | SP → FIFO (XVU, VU) | reads |
| SPSU | FIFO (VU) → SP | writes |
| NCSU | SP → SHM | reads |

So every SP buffer has a writer in {NCLU, SPSU} and a reader in {SPLU, NCSU} (C5: one writer unit, one
reader unit per buffer).

## 2. The hardware: one counter per unit pair

There is one SYNC FIFO (a **counter**) per ordered pair of units, per NCore. A **token** is one entry in
a counter: a `SYNC put` adds one to each counter its mask names, and a `SYNC get` waits for one from each
counter its mask names and removes it. A token carries no data and no name. It is not a data FIFO's entry:
data FIFOs (SPLU → XVU, VU → SPSU, ...) order themselves and get no syncs.

The two directions of a pair are two counters. A `ready` (writer → reader) and a `free` (reader → writer)
therefore never share tokens. Since §1 fixes which units write SP and which read it, a counter carries
only `ready` tokens or only `free` tokens.

| Counter | Depth |
|---|---|
| NCLU ↔ NCSU | 16 |
| NCLU → SPLU, NCSU → SPSU, SPLU → NCLU, SPSU → NCSU | 4 + 2 |
| SPLU ↔ SPSU, same NCore | 16 |
| SPLU ↔ SPSU, the other NCore | 4 + 2 |

Every writer and reader pair of §1 has a counter in both directions. A `put` blocks only when its counter
is full.

## 3. Two dependences per buffer

For an SP buffer with write `W` (on the writer) and read `R` (on the reader), let `L` be the innermost
loop around both, or the pipeline body if no loop contains both.

- **RAW** (`ready`): `R` reads lines `W` wrote in the same iteration of `L`. The writer puts after `W`,
  and the reader gets before `R`.
- **WAR** (`free`): a later `W` overwrites lines an earlier `R` read. The reader puts after `R`, and the
  writer gets before `W`. The first writes take **credits**: tokens the reader puts at the pipeline's
  start, which the writer gets back at its end.

**Footprint.** The footprint of an access is the set of buffer lines it touches. It is a function of the
indices of the loops around it, and of `%d` and `%nc`. An access `%b[e0, ..., en] : T` touches the
lines from `(e0, ..., en)` onward, as many along the last dimension as `T` has lines (1 for a line, `N`
for a tile of `N` lines, 64 for a weight tile):

```
nclu.load %sp_x[%nc, 4 * %t], ... : !tile4      footprint(nc, t) = {(nc, 4t), ..., (nc, 4t + 3)}
```

The footprint of a statement of `L`'s body is the union of its accesses' footprints over the loops
inside the statement. It is then a function of `L`'s index and the indices outside `L`:

```
for o:                                          L
  for t = 0 .. 4:                               a statement of L's body
    spsu.store %sp_y[%nc, 4 * %t], %v : !tile4  footprint(nc) = {(nc, 0), ..., (nc, 15)}
```

This is the same notion as a `psum.block`'s footprint, the lines one sync token covers, except that here
it is computed and not declared.

In `L`'s body, `W` and `R` sit in different statements, and `W`'s statement must come first. A read that
comes first would read the previous iteration's lines; outside partial sums, that is refused.

## 4. Shared counters: the k-th get takes the k-th put

All the dependences between two units share one counter. A `get` takes whichever token arrives next, so
**the k-th get on a counter is satisfied by the k-th put**, whatever buffer either was meant for.

**The race.** Placing each buffer's syncs independently breaks when the reader takes buffers in a
different order from the writer:

```
for i:
  nclu.load %a[0], ...           W_a
  put nclu→splu                  token 1, for a
  nclu.load %b[0], ...           W_b
  put nclu→splu                  token 2, for b
  get nclu→splu                  meant for b
  %vb = splu.load %b[0]          R_b
  get nclu→splu                  meant for a
  %va = splu.load %a[0]          R_a
```

```
NCLU  ──[ W_a ]──put1──[ W_b ...................]──put2──
SPLU               get1──[ R_b ]
                    ▲        ▲
                    │        └ reads b while the NCLU is still writing it
                    └ token 1 was put for a
```

**The rule.** Number the puts on a counter in program order. Each statement that depends on the counter
**needs** the number of the latest put it depends on. Before the statement, the getter issues gets until
it has taken that many:

```
place_gets(counter c):
  taken = 0
  for each statement s of c's getter, in program order:
    n = need(s)                      # the number of the latest put s depends on (0: none)
    while taken < n:
      insert "get c" before s
      taken += 1
```

In the example, `R_b` needs put 2, so two gets go before it, and `R_a` needs none:

```
  ...
  get nclu→splu ; get nclu→splu      take put 1 and put 2
  %vb = splu.load %b[0]
  %va = splu.load %a[0]
```

**Merging puts.** A put whose first dependent statement comes after the next put on the same counter adds
nothing. It merges into that next put, and both tokens become one:

```
  nclu.load %a[0], ...
  nclu.load %b[0], ...
  put nclu→splu                      covers a and b
  get nclu→splu
  %vb = splu.load %b[0]
  %va = splu.load %a[0]
```

Moving a put later only delays the getter, so merging is always safe. §6 gives both steps in full:
merging (`plan_puts`), then placing gets from the merged puts (`place_gets`).

**Counting with loops.** Puts are numbered in program order within one iteration of the innermost loop
around all the counter's syncs, with a nested loop counting as its trip count times its tokens. P2
requires the puts and gets of each iteration to balance.

## 5. Slots and credits

A WAR needs a credit for each **slot**: each distinct footprint the write fills before it starts
overwriting.

**One slot.** The write address ignores `i`, so every write overwrites the previous one:

```
for i = 0 .. 4:                             L
  nclu.load %sp[0], %x[i]                   W(i)
  %v = splu.load %sp[0]                     R(i)
```

With syncs:

```
put splu→nclu ×1                            credit
for i = 0 .. 4:
  get splu→nclu                             free: R(i − 1) has read the slot
  nclu.load %sp[0], %x[i]
  put nclu→splu                             ready
  get nclu→splu
  %v = splu.load %sp[0]
  put splu→nclu                             free
get splu→nclu ×1                            credit back
```

**Four slots.** The write address uses `i` but ignores `o`, so the writes of one `o` fill four slots, and
the next `o` overwrites them:

```
for o = 0 .. 2:
  for i = 0 .. 4:                           L
    nclu.load %sp[i], %x[o, i]              W(o, i)
    %v = splu.load %sp[i]                   R(o, i)
```

With syncs, the code is the one-slot code with `%sp[i]` and a credit of 4:

```
put splu→nclu ×4
for o = 0 .. 2:
  for i = 0 .. 4:
    get splu→nclu
    nclu.load %sp[i], %x[o, i]
    put nclu→splu
    get nclu→splu
    %v = splu.load %sp[i]
    put splu→nclu
get splu→nclu ×4
```

Each access waits for one earlier access:

| Access | Slot | Waits for (RAW) | Waits for (WAR) |
|---|---|---|---|
| W(0,0) … W(0,3) | 0 … 3 | | a credit |
| R(0,0) | 0 | W(0,0) | |
| R(0,1) | 1 | W(0,1) | |
| W(1,0) | 0 | | R(0,0) |
| W(1,1) | 1 | | R(0,1) |

So R(0,0) starts as soon as W(0,0) has finished, while the NCLU goes on with W(0,1) … W(0,3).

The writer's j-th get takes the j-th free token. The first four are credits; after them, token j is the
put after read j − 4, the read of the same slot. So:

- **credit S is exact.** Write j waits for exactly the read it would overwrite.
- **a credit c < S is still safe.** Write j waits for read j − c, which comes later than read j − S, so
  the writer is held back further than needed. With credit 1, the four-slot code is correct, but the NCLU
  can never run ahead of the SPLU.

**Computing S.** Let `C` be the loops around both `W` and `R`, outer to inner.

```
slots(W, C):
  k = innermost loop in C whose iterations (outer indices fixed) write overlapping lines
  if no such loop: return 0          # every write fills new lines: no WAR
  return the number of distinct footprints W writes in one iteration of k
         # the product of the trip counts of the loops of C inside k
```

If two footprints overlap only in part, S is not defined, and the pass refuses.

**Credit.** The credit is `min(S, depth − tokens the counter's other dependences hold)` (P6).

The canonical lowering writes every SP buffer at `[%nc, 0]`, so S = 1 everywhere.

### n-way buffering

To buffer a loop n ways, split it into a loop over groups of n and a loop over the n slots, and index the
SP buffer by the slot. The write address then ignores the group loop, so `slots()` gives S = n. All
indices stay affine with constant strides, without `mod`. The trip count must be a multiple of n.

A streaming add over 16 tiles, double buffered (n = 2):

```
for j0 = 0 .. 8:                            the address ignores j0: it reuses the slots
  for s = 0 .. 2:                           L; the slot
    nclu.load %sp_a[s], %a[4 * (2 * j0 + s)] : !tile4
    %va = splu.load %sp_a[s] : !tile4
    ...
```

With syncs, the only differences from one slot are the address and a credit of 2:

```
put splu→nclu ×2
for j0 = 0 .. 8:
  for s = 0 .. 2:
    get splu→nclu
    nclu.load %sp_a[s], %a[4 * (2 * j0 + s)] : !tile4
    put nclu→splu
    get nclu→splu
    %va = splu.load %sp_a[s] : !tile4
    put splu→nclu
get splu→nclu ×2
```

If a write takes 1 time step and a read 2, the NCLU's work is hidden behind the SPLU's:

```
step      0   1   2   3   4   5   6   7
1 slot
  NCLU    W0  .   .   W1  .   .   W2  .
  SPLU    .   R0  R0  .   R1  R1  .   R2
2 slots
  NCLU    W0  W1  .   W2  .   W3  .   W4
  SPLU    .   R0  R0  R1  R1  R2  R2  R3
```

With 2 slots, W2 waits for R0 to free slot 0, and from then on the SPLU never waits. More slots help only
when the writer's time varies, as an SHM transfer's does. S is bounded by the SP lines and by the credit
limit above: the NCLU's `free` counter is 4 + 2 deep.

## 6. The pass

The pass first decides every sync and only then changes the IR. Phases 1–3 build plain records.
Phase 4 writes all the sync ops in one go. Gets are placed after puts are merged, so no get ever has to
be removed.

```
insert_syncs(pipeline):
  # 1. Dependences: records only, the IR is untouched.
  deps = []
  for each SP buffer b:                                   # v1: one write W, one read R
    L = innermost loop around W and R, or the pipeline body
    w, r = the statements of L's body that hold W and R
    refuse unless w precedes r, and r's footprint lies in w's (C6)
    deps += Dep(kind=RAW, counter=(unit(W) → unit(R), %nc), source=w, dependent=r, body=L)
    S = slots(W, loops around W and R)
    if S > 0:
      deps += Dep(kind=WAR, counter=(unit(R) → unit(W), %nc), source=r, dependent=w, body=L, slots=S)

  for each counter c, with the deps D on it:              # v1: all of D share one body L
    # 2. Puts: positions in L's body.
    puts = plan_puts(D)
    # 3. Gets: positions in L's body, from the merged puts.
    gets = place_gets(D, puts)
    credit = S × len(puts) if D are WAR, else 0           # S: the smallest of D's slots

  # 4. Write the IR: every put, get and credit becomes a sync op tagged with its unit.
  # 5. Check P2, P3, P6 per counter, and C8.
```

A **Dep** says: "the getter must not start `dependent` until the putter has finished `source`". For a
RAW, the source and the dependent are in the same iteration of `L`. For a WAR, the dependent is in a
later iteration: the write that reuses the slot the read has just finished with.

**plan_puts.** Puts go right after each source statement. A put then merges into the next put if no
dependent of its own lies between the two:

```
plan_puts(D):
  puts = []                                     # in L's body order; each covers some deps
  for each source statement s of D, in body order:
    if puts and no dependent of puts[-1] lies between puts[-1].position and s:
      puts[-1].position = after s               # merge: move the last put down to s
      puts[-1].deps += deps whose source is s
    else:
      puts += Put(position = after s, deps = deps whose source is s)
  return puts
```

A WAR's dependent lies in the next iteration, never between two puts of one body, so all the WAR puts of
one body merge into one, after the last read.

**place_gets.** Number the merged puts 1, 2, … in body order. Each dependent statement **needs** the
largest number among the puts covering its deps. Walking the body, the getter takes gets until it has
taken that many:

```
place_gets(D, puts):
  need = {}
  for i, p in enumerate(puts, start=1):
    for d in p.deps:
      need[d.dependent] = max(need.get(d.dependent, 0), i)
  gets, taken = [], 0
  for each statement s of L's body, in body order:
    while taken < need.get(s, 0):
      gets += Get(position = before s)
      taken += 1
  assert taken == len(puts)                     # P2: every put is taken in the same iteration
  return gets
```

For a WAR, the numbers count the puts of the iteration that freed the slot. The credits make up the
difference: S slots and P puts per iteration give S × P credits, so the k-th get of iteration i takes
the k-th put of iteration i − S.

**A worked trace.** The §4 example: the NCLU writes `a`, then `b`, and the SPLU reads `b`, then `a`.

| Step | Result |
|---|---|
| deps | RAW a: source `W_a`, dependent `R_a`. RAW b: source `W_b`, dependent `R_b` |
| plan_puts | a's put goes after `W_a`. No dependent of a (`R_a`) lies between `W_a` and `W_b`, so it moves after `W_b`: one put, number 1, covering a and b |
| place_gets | need(`R_b`) = 1, need(`R_a`) = 1. The walk reaches `R_b` first and puts one get before it; `R_a` needs nothing more |
| IR | `W_a; W_b; put; get; R_b; R_a` |

In the dense kernel of §7, `%sp_w` and `%sp_x` merge the same way on both of their counters.

Partial sums in SP (`psum.*`, B1–B5) keep their own placement in `mlir-loop-ir.md` and are refused in v1.

## 7. Example: the lowered dense kernel

`dense/m128_k256_n64` as `lower()` emits it, with its syncs, for NCore `%nc`. `%sp_w` and `%sp_x` share
both of their counters, and their tokens merge.

```
put splu→nclu ×1                                   @splu   credit for sp_w, sp_x
put ncsu→spsu ×1                                   @ncsu   credit for sp_y
for mt, t:
  vu.reg_write acc, zero
  for kb:
    get splu→nclu                                  @nclu   free: sp_w, sp_x
    nclu.load %sp_w[%nc, 0], %w[0, kb, 0]
    nclu.load %sp_x[%nc, 0], %x[kb, row]
    put nclu→splu                                  @nclu   ready: sp_w, sp_x
    get nclu→splu                                  @splu
    %wt = splu.load %sp_w[%nc, 0]
    %xt = splu.load %sp_x[%nc, 0]
    put splu→nclu                                  @splu   free
    acc += mxu.matmul %wt, %xt
  get ncsu→spsu                                    @spsu   free: sp_y
  spsu.store %sp_y[%nc, 0], acc
  put spsu→ncsu                                    @spsu   ready: sp_y
  get spsu→ncsu                                    @ncsu
  ncsu.store %y[row], %sp_y[%nc, 0]
  put ncsu→spsu                                    @ncsu   free
get splu→nclu ×1                                   @nclu   credits back
get ncsu→spsu ×1                                   @spsu
```

With one slot, a tile's load and read run one after the other. Overlapping them is the job of a later
pass that adds slots, as in §5.

## 8. Hoisted transfers

Hoisting moves a load or store out of the loop it would otherwise sit in, so that it moves more lines
less often. Placement still works on the statements of `L`'s body. The only change is that one of those
statements can now be a loop. Its **footprint** is the union of the lines its accesses touch over the
loops inside it.

- **RAW (C6):** the read statement's footprint must lie inside the write statement's footprint, for the
  same iteration of `L`.
- **Slots (§5):** computed from statement footprints instead of op footprints.

**Both hoisted** (a weight loaded once per K block and latched):

```
for kb:                                     L
  get splu→nclu
  nclu.load %sp_w[0], %w[kb]                W
  put nclu→splu
  get nclu→splu
  %wt = splu.load %sp_w[0]                  R
  put splu→nclu
  for t: ... %wt ...                        a broadcast (routing), no sync
```

The syncs run once per `kb`, not once per tile.

**The write hoisted, the reads not** (one transfer of four tiles, read a tile at a time):

```
for o:                                      L
  get splu→nclu
  nclu.load %sp_x[0 .. 4], %x[o, 0 .. 4]    W: 4 tiles
  put nclu→splu
  get nclu→splu                             before the statement holding R
  for t = 0 .. 4:
    %xt = splu.load %sp_x[t]                R: footprint over t = 4 tiles
  put splu→nclu                             after it
```

**The store hoisted** (the SPSU writes tiles, the NCSU stores them in one transfer):

```
for o:                                      L
  get ncsu→spsu
  for t = 0 .. 4:
    spsu.store %sp_y[t], %v                 W: footprint over t = 4 tiles
  put spsu→ncsu
  get spsu→ncsu
  ncsu.store %y[o, 0 .. 4], %sp_y[0 .. 4]   R
  put ncsu→spsu
```

What hoisting costs:

- **Coarser syncs.** A sync covers a whole statement, so the SPLU waits for all four tiles of the transfer
  before it reads the first. Getting overlap back takes more slots (§5), so that the next transfer fills
  one slot while the SPLU reads the other.
- **Slots, not prefetch.** Moving the write of iteration `i + 1` above the read of iteration `i` makes
  the read come first in `L`'s body, which is refused. A credit of 2 on two slots lets the writer run one
  iteration ahead with the code in canonical order, so prefetch needs no IR change.
- **Hoisting out of every loop.** If no loop contains both the write and the read (an input loaded once
  at the pipeline's start), `L` is the pipeline body: one `ready` and no `free`.

The ULoop verifier currently limits an NC transfer to the line counts of a line, a tile or a weight
tile, so it must accept other line counts before hoisted transfers can be expressed (§9).

## 9. Hoisting NC transfers, then double buffering

An `LDMU` or `STMU` moves N lines in one instruction, up to 32 (`burst = 0` means 32), contiguous in both
SP and SHM. The canonical form moves one tile, 4 lines, per transfer. Two passes on ULoop, run before sync
insertion, make the transfers larger and overlap them with compute:

1. **hoist_nc** merges the NC transfers of n consecutive iterations into one transfer of n tiles.
2. **buffer** gives the SP buffer of that transfer 2 slots (or n), so that the next transfer fills one
   slot while the SP units work on the other.

Sync insertion then runs unchanged: `slots()` finds S = 2 and gives a credit of 2.

### hoist_nc

```
hoist_nc(X, n):            # X: an nclu.load (or ncsu.store) in loop j, trip T; n tiles per transfer
  require T % n == 0, and n × lines(X) ≤ 32 (or a multiple of 32, emitted as several LDMUs)
  require X's SHM footprint over n consecutive j to be contiguous
  split j: j = n · j1 + j2, with j1 = 0 .. T/n and j2 = 0 .. n
  B = a new SP buffer of n × lines(X) lines
  for a load:
    put "nclu.load B[0], <X's SHM address at j2 = 0> : n × lines(X) lines" in j1's body, before the j2 loop
    the SPLU reads B[lines(X) × j2] instead of X's SP buffer
  for a store:
    the SPSU writes B[lines(X) × j2] instead of X's SP buffer
    put "ncsu.store <X's SHM address at j2 = 0>, B[0] : n × lines(X) lines" in j1's body, after the j2 loop
  delete X
```

### buffer

```
buffer(B, j1, m):          # m slots for B, used in turn over loop j1, trip T1
  require T1 % m == 0
  split j1: j1 = m · j0 + s, with j0 = 0 .. T1/m and s = 0 .. m
  give B a leading dimension of m, and index every access to B by s
```

The slot index `s` is a loop index, so every address stays affine with constant strides, without `mod`.

### Example: a streaming add

`c = a + b` on one DNC's block of K = 256 lines (64 tiles), as `lower()` emits it:

```
for j = 0 .. 64:
  nclu.load %sp_a[0], %a[blk, 4 · j] : !tile4
  nclu.load %sp_b[0], %b[blk, 4 · j] : !tile4
  %va = splu.load %sp_a[0] : !tile4
  %vb = splu.load %sp_b[0] : !tile4
  %vc = vu.fma %va, 1.0, %vb : !tile4
  spsu.store %sp_c[0], %vc : !tile4
  ncsu.store %c[blk, 4 · j], %sp_c[0] : !tile4
```

**After hoist_nc, n = 8** (32 lines, one `LDMU` or `STMU` per transfer):

```
for j1 = 0 .. 8:
  nclu.load %sp_a[0], %a[blk, 32 · j1] : 32 lines
  nclu.load %sp_b[0], %b[blk, 32 · j1] : 32 lines
  for j2 = 0 .. 8:
    %va = splu.load %sp_a[4 · j2] : !tile4
    %vb = splu.load %sp_b[4 · j2] : !tile4
    %vc = vu.fma %va, 1.0, %vb : !tile4
    spsu.store %sp_c[4 · j2], %vc : !tile4
  ncsu.store %c[blk, 32 · j1], %sp_c[0] : 32 lines
```

**After buffer, m = 2** (`%sp_a`, `%sp_b`, `%sp_c`: 2 slots × 32 lines each):

```
for j0 = 0 .. 4:
  for s = 0 .. 2:
    nclu.load %sp_a[s, 0], %a[blk, 32 · (2 · j0 + s)] : 32 lines
    nclu.load %sp_b[s, 0], %b[blk, 32 · (2 · j0 + s)] : 32 lines
    for j2 = 0 .. 8:
      %va = splu.load %sp_a[s, 4 · j2] : !tile4
      %vb = splu.load %sp_b[s, 4 · j2] : !tile4
      %vc = vu.fma %va, 1.0, %vb : !tile4
      spsu.store %sp_c[s, 4 · j2], %vc : !tile4
    ncsu.store %c[blk, 32 · (2 · j0 + s)], %sp_c[s, 0] : 32 lines
```

**After insert_syncs.** `L` is the loop `s` for all three buffers. Their footprints differ across `s`
and repeat across `j0`, so `slots()` gives S = 2 for each:

| Buffer | Write, read (statements of `s`'s body) | Counters |
|---|---|---|
| `%sp_a`, `%sp_b` | the `nclu.load`s; the `j2` loop | ready NCLU → SPLU (merged), free SPLU → NCLU (merged, credit 2) |
| `%sp_c` | the `j2` loop; the `ncsu.store` | ready SPSU → NCSU, free NCSU → SPSU (credit 2) |

```
put splu→nclu ×2                            @splu   credits: 2 slots of %sp_a, %sp_b
put ncsu→spsu ×2                            @ncsu   credits: 2 slots of %sp_c
for j0 = 0 .. 4:
  for s = 0 .. 2:
    get splu→nclu                           @nclu   slot s of a, b is free
    nclu.load %sp_a[s, 0], ...
    nclu.load %sp_b[s, 0], ...
    put nclu→splu                           @nclu   slot s of a, b is loaded
    get nclu→splu                           @splu
    get ncsu→spsu                           @spsu   slot s of c is free
    for j2 = 0 .. 8:
      splu.load ×2, vu.fma, spsu.store
    put splu→nclu                           @splu   slot s of a, b has been read
    put spsu→ncsu                           @spsu   slot s of c is written
    get spsu→ncsu                           @ncsu
    ncsu.store %c[...], %sp_c[s, 0]
    put ncsu→spsu                           @ncsu   slot s of c has been stored
get splu→nclu ×2                            @nclu   credits back
get ncsu→spsu ×2                            @spsu
```

If a 32-line load takes 1 time step, the 8 tiles of compute 2, and a store 1, the compute never waits
after the first load:

```
step       0    1    2    3    4    5    6    7    8
NCLU       L0   L1   .    L2   .    L3   .    L4   .
compute    .    C0   C0   C1   C1   C2   C2   C3   C3
NCSU       .    .    .    S0   .    S1   .    S2   .
```

L2 waits for C0 to free slot 0 of `a` and `b`, and C2 needs S0 to have freed slot 0 of `c`, which it
has by then. Neither wait stalls the compute.

SP use: 3 buffers × 2 slots × 32 lines = 192 lines per NCore. The credits, 2 per counter, fit the 4 + 2
deep counters to the NC units.

### What the passes need

- **Transfers of any line count.** ULoop's NC ops move a line, a tile or a weight tile. They must take n
  tiles, and the verifier must check that the SHM footprint is contiguous.
- **Order.** hoist_nc, then buffer, then insert_syncs. The first two produce plain ULoop, so the
  interpreter can check each of them against the canonical kernel before any sync exists.
- **Choosing n and m.** n is bounded by 32 lines per instruction (or SP space, if one transfer is
  several instructions), and m by SP space and the counters' depth. Choosing them is a cost question,
  left to the caller.

## 10. Open

- **Completion.** "Put after the write" assumes the data is in SP when the token arrives, and "put after
  the read" that the read has finished. Check with SYNC's `be` bit on the VP.
- **Between pipelines.** Units do not wait for each other at a pipeline's end. An SP buffer one pipeline
  writes and the next reads, or SHM written by the NCSU and read by the NCLU, needs the same treatment
  over the kernel body. SHM makes the NCSU a writer and the NCLU a reader. Their counters would then carry
  both `ready` and `free` tokens, which §4's rule handles, since it never looks at a token's kind.
- **An oracle.** An interpreter mode that runs each unit on its own, with the real FIFO and counter
  depths, would report deadlocks and, through the order the tokens impose, races.
