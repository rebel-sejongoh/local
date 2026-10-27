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

Moving a put later only delays the getter, so merging is always safe.

**Counting with loops.** Puts are numbered in program order within one iteration of the innermost loop
around all the counter's syncs, with a nested loop counting as its trip count times its tokens. P2
requires the puts and gets of each iteration to balance.

## 5. Slots and credits

A WAR needs a credit for each **slot**: each distinct set of lines the write fills before it starts
overwriting.

**One slot.** The write address ignores `i`, so every write overwrites the previous one:

```
for i = 0 .. 4:
  nclu.load %sp[0], %x[i]
  %v = splu.load %sp[0]
```

```
write  W0   W1   W2   W3
slot   0    0    0    0
waits  -    R0   R1   R2        credit 1
```

**Four slots.** The write address uses `i` but ignores `o`, so the writes of one `o` fill four slots, and
the next `o` overwrites them:

```
for o = 0 .. 2:
  for i = 0 .. 4:
    nclu.load %sp[i], %x[o, i]
    %v = splu.load %sp[i]
```

```
write  W(0,0) W(0,1) W(0,2) W(0,3) W(1,0) W(1,1) ...
slot   0      1      2      3      0      1
waits  -      -      -      -      R(0,0) R(0,1)          credit 4
```

The writer's j-th get takes the j-th free token. The first four are credits; after them, token j is the
put after read j − 4, the read of the same slot. So:

- **credit S is exact.** Write j waits for exactly the read it would overwrite.
- **a credit c < S is still safe.** Write j waits for read j − c, which comes later than read j − S, so
  the writer is held back further than needed. With credit 1 the four-slot case is correct, but the NCLU
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

The canonical lowering writes every SP buffer at `[%nc, 0]`, so S = 1 everywhere. Double buffering is a
later pass that makes S = 2, and needs no change to these rules.

## 6. The pass

```
insert_syncs(pipeline):
  for each SP buffer b:                                   # v1: one write W, one read R
    L = innermost loop around W and R, or the pipeline body
    refuse unless W's statement precedes R's in L's body, and R reads what W wrote (C6)
    add RAW: counter writer→reader, source W, dependent R
    S = slots(W, loops around W and R)
    if S > 0:
      add WAR: counter reader→writer, source R, dependent the next W, credit S
  for each counter c:
    puts:    one after each source statement, merged as in §4
    gets:    place_gets(c)
    credits: the reader puts them at the pipeline's start; the writer gets them back at its end
  check P2, P3, P6 per counter, and C8
```

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

## 8. Open

- **Completion.** "Put after the write" assumes the data is in SP when the token arrives, and "put after
  the read" that the read has finished. Check with SYNC's `be` bit on the VP.
- **Between pipelines.** Units do not wait for each other at a pipeline's end. An SP buffer one pipeline
  writes and the next reads, or SHM written by the NCSU and read by the NCLU, needs the same treatment
  over the kernel body. SHM makes the NCSU a writer and the NCLU a reader. Their counters would then carry
  both `ready` and `free` tokens, which §4's rule handles, since it never looks at a token's kind.
- **An oracle.** An interpreter mode that runs each unit on its own, with the real FIFO and counter
  depths, would report deadlocks and, through the order the tokens impose, races.
