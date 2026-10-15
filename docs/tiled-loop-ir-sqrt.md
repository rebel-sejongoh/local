# Fused IR example: sqrt R=2048, K=64

The fused IR is the same computation before it is split across units. It has one loop nest with sequential semantics: there are no units, FIFOs, or tokens yet. A value that crosses from one unit to another is an ordinary SSA value, and an ordering through a buffer is an ordinary memory dependence.

```mlir
primitive @sqrt attributes {spmd_dncs = 16} {
  %i0     = alloc : buffer<2048 x 64 x dlf16, #shm>
  %o0     = alloc : buffer<2048 x 64 x dlf16, #shm>
  %sp_in  = alloc : buffer<64 x !line, #sp>
  %sp_out = alloc : buffer<64 x !line, #sp>
  // size(%i0) + size(%o0) <= SHM_size
  // size(%sp_in) + size(%sp_out) <= SP_size

  pipeline(%i0, %o0, %sp_in, %sp_out) {
    %one  = vu.immcopy 1.0   : vector<64xdlf16>
    %zero = vu.immcopy 0.0   : vector<64xdlf16>
    %half = vu.immcopy 0.5   : vector<64xdlf16>
    %th   = vu.immcopy 1.5   : vector<64xdlf16>
    %seed = vu.immcopy 0.625 : vector<64xdlf16>

    for i = 0 .. 2 {                                    // pass: 64 rows
      for k = 0 .. 64 {                                 // line: one beat
        load.shm2sp %sp_in[k], %i0[128*%d + 64*i : 64 lanes, k]
        %x  = load.sp %sp_in[k]         : vector<64xdlf16>
        %e0 = vu.ee   %x                : vector<64xi16>
        %e1 = vu.shr  %e0, 1            : vector<64xi16>
        %y0 = vu.ime  %e1, 2, %seed     : vector<64xdlf16>
        %xh = vu.fma  %x, %half, %zero  : vector<64xdlf16>
        %t0 = vu.fma  %y0, %y0, %zero   : vector<64xdlf16>
        %u0 = vu.fnms %xh, %t0, %th     : vector<64xdlf16>
        %y1 = vu.fma  %y0, %u0, %zero   : vector<64xdlf16>
        %t1 = vu.fma  %y1, %y1, %zero   : vector<64xdlf16>
        %u1 = vu.fnms %xh, %t1, %th     : vector<64xdlf16>
        %y2 = vu.fma  %y1, %u1, %zero   : vector<64xdlf16>
        %t2 = vu.fma  %y2, %y2, %zero   : vector<64xdlf16>
        %u2 = vu.fnms %xh, %t2, %th     : vector<64xdlf16>
        %y3 = vu.fma  %y2, %u2, %zero   : vector<64xdlf16>
        %t3 = vu.fma  %y3, %y3, %zero   : vector<64xdlf16>
        %u3 = vu.fnms %xh, %t3, %th     : vector<64xdlf16>
        %y4 = vu.fma  %y3, %u3, %zero   : vector<64xdlf16>
        %r  = vu.fma  %x, %y4, %zero    : vector<64xdlf16>
        store.sp %sp_out[k], %r
        store.sp2shm %o0[128*%d + 64*i : 64 lanes, k], %sp_out[k]
      }
    }
  }
}
```

The loop nest is perfect: every op sits in the innermost body and moves one line. Loop-invariant constants are hoisted above it. Chunking is not in the fused IR; it is a scheduling decision made when lowering.

Lowering to the tiled loop IR below:
- Strip-mine `k` into `j` (chunk, 8) and `l` (line, 8) for the units that synchronize per chunk. The chunk size sets the token granularity.
- Coarsen the NC units' per-line moves over `l` into one 8-line burst (`load.shm2sp %sp_in[8*j : 8]`, `store.sp2shm … 8*j : 8`). The NC burst field caps a burst at 32 lines.
- Each op goes to the unit that executes it, and each unit keeps the loops around its ops. The VU keeps the unsplit 64-beat loop.
- An SSA value used by an op on another unit becomes a FIFO: `%x` (SPLU -> VU) and `%r` (VU -> SPSU).
  Where a FIFO value is read more than once, the consumer first copies it into a register. Here `%x` is read three times, so the VU starts with `%s = vu.fma %f_ld, %one, %zero`, and `%r` is pushed by `vu.fma %r, %one, %zero into %f_st`.
- A dependence through a buffer becomes a token pair:
  - read after write: `load.shm2sp` then `load.sp` on `%sp_in` gives `%in_ready`, and `store.sp` then `store.sp2shm` on `%sp_out` gives `%out_ready`. Both are signalled at the chunk level, where the write completes.
  - write after read across passes: pass `i+1` overwrites `%sp_in` and `%sp_out`, so it waits until pass `i` finished reading them. This gives `%in_free` and `%out_free` with `init 1`, at the pass level.

---

# Tiled Loop IR example: sqrt R=2048, K=64

One SPMD program per DNC (16 DNCs). Each DNC owns 128 rows = 2 passes x 64 lanes; K = 64 lines per pass, staged in 8 chunks of 8 lines.

Notation
- `buffer<…, #shm|#sp>`: memory region. `!line` = 128 B = 64 x dlf16.
- Affine accesses use `%d` (DNC id) and the enclosing loop indices. In a `!line`, lane `r` holds row `r` of the tile.
- `fifo a -> b`: hardware FIFO between two units. A FIFO operand pops one line; `into` pushes one line.
- `token [init N]`: counting token. `signal` adds 1; `await` waits until the count is positive, then subtracts 1. Placement in the loop nest sets the granularity.

```mlir
primitive @sqrt attributes {spmd_dncs = 16} {
  %i0     = alloc : buffer<2048 x 64 x dlf16, #shm>
  %o0     = alloc : buffer<2048 x 64 x dlf16, #shm>
  %sp_in  = alloc : buffer<64 x !line, #sp>        // input band, reused by both passes
  %sp_out = alloc : buffer<64 x !line, #sp>        // output band, reused by both passes
  // size(%i0) + size(%o0) <= SHM_size
  // size(%sp_in) + size(%sp_out) <= SP_size

  pipeline(%i0, %o0, %sp_in, %sp_out) {
    %f_ld      = fifo splu -> vu
    %f_st      = fifo vu -> spsu
    %in_ready  = token              // an input chunk landed in SP
    %in_free   = token init 1       // the input band may be overwritten
    %out_ready = token              // an output chunk was written to SP
    %out_free  = token init 1       // the output band may be overwritten

    // NCLU: SHM -> SP, one 8-line chunk per iteration
    for i = 0 .. 2 {
      await %in_free
      for j = 0 .. 8 {
        load.shm2sp %sp_in[8*j : 8], %i0[128*%d + 64*i : 64 lanes, 8*j : 8]
        signal %in_ready
      }
    }

    // SPLU: SP -> VU FIFO, one line per iteration
    for i = 0 .. 2 {
      for j = 0 .. 8 {
        await %in_ready
        for l = 0 .. 8 {
          load.sp %sp_in[8*j + l] into %f_ld
        }
      }
      signal %in_free
    }

    // VU: one line per beat; FIFO in, FIFO out, no tokens
    %one  = vu.immcopy 1.0   : vector<64xdlf16>
    %zero = vu.immcopy 0.0   : vector<64xdlf16>
    %half = vu.immcopy 0.5   : vector<64xdlf16>
    %th   = vu.immcopy 1.5   : vector<64xdlf16>
    %seed = vu.immcopy 0.625 : vector<64xdlf16>
    for i = 0 .. 2 {
      for b = 0 .. 64 {
        %s  = vu.fma  %f_ld, %one, %zero : vector<64xdlf16>   // pop one line
        %e0 = vu.ee   %s                 : vector<64xi16>     // exponent
        %e1 = vu.shr  %e0, 1             : vector<64xi16>
        %y0 = vu.ime  %e1, 2, %seed      : vector<64xdlf16>   // seed: 0.625 * 2^-e
        %xh = vu.fma  %s, %half, %zero   : vector<64xdlf16>   // s / 2
        %t0 = vu.fma  %y0, %y0, %zero    : vector<64xdlf16>   // Newton step 1
        %u0 = vu.fnms %xh, %t0, %th      : vector<64xdlf16>
        %y1 = vu.fma  %y0, %u0, %zero    : vector<64xdlf16>
        %t1 = vu.fma  %y1, %y1, %zero    : vector<64xdlf16>   // Newton step 2
        %u1 = vu.fnms %xh, %t1, %th      : vector<64xdlf16>
        %y2 = vu.fma  %y1, %u1, %zero    : vector<64xdlf16>
        %t2 = vu.fma  %y2, %y2, %zero    : vector<64xdlf16>   // Newton step 3
        %u2 = vu.fnms %xh, %t2, %th      : vector<64xdlf16>
        %y3 = vu.fma  %y2, %u2, %zero    : vector<64xdlf16>
        %t3 = vu.fma  %y3, %y3, %zero    : vector<64xdlf16>   // Newton step 4
        %u3 = vu.fnms %xh, %t3, %th      : vector<64xdlf16>
        %y4 = vu.fma  %y3, %u3, %zero    : vector<64xdlf16>   // rsqrt(s)
        %r  = vu.fma  %s, %y4, %zero     : vector<64xdlf16>   // sqrt(s) = s * rsqrt(s)
        vu.fma %r, %one, %zero into %f_st                     // push one line
      }
    }

    // SPSU: VU FIFO -> SP, one line per iteration
    for i = 0 .. 2 {
      await %out_free
      for j = 0 .. 8 {
        for l = 0 .. 8 {
          store.sp %sp_out[8*j + l] from %f_st
        }
        signal %out_ready
      }
    }

    // NCSU: SP -> SHM, one 8-line chunk per iteration
    for i = 0 .. 2 {
      for j = 0 .. 8 {
        await %out_ready
        store.sp2shm %o0[128*%d + 64*i : 64 lanes, 8*j : 8], %sp_out[8*j : 8]
      }
      signal %out_free
    }
  }
}
```

Checks on this IR
- Tokens: `signals - awaits == init` per token. `%in_ready`: 2*8 - 2*8 = 0. `%in_free`: 2 - 2 + 1 = 1 (one credit left at the end).
- FIFOs: pushes == pops. `%f_ld`: 2*8*8 = 128 = 2*64.
- Outstanding signals never exceed the channel depth: at most 8 for `%in_ready` and `%out_ready` (NC <-> SP depth is 16).
- Each VU instruction pops at most one FIFO operand.

Lowering to the machine-level IR
- Each loop nest becomes one `unit` region; the unit follows from the op (`load.shm2sp` -> NCLU, `load.sp` -> SPLU, `vu.*` -> VU, `store.sp` -> SPSU, `store.sp2shm` -> NCSU).
- Each token becomes a `channel` between the unit that signals and the unit that awaits; `signal` / `await` become `sync put` / `sync get`.
- `init N` becomes N `sync put` at the start of the producer's block, or the `await` moves to the end of the previous iteration (what mcc emits today).
- Affine accesses become address registers: the start goes into the unit's LRF preload, the innermost stride into the auto-increment, and outer strides into explicit register updates.
