# MLIR machine IR example: NCLU and SPLU (sqrt R=2048, K=64, DNC 0)

Decisions applied
- Every unit is SSA. A value carried across a loop is a loop `iter` / `yield`; a value merged after a branch is a block argument.
- An op that updates a register in place returns the new value: `%sn, %cn = nclu.ldmu …`. Register allocation ties the result to the operand.
- Op syntax: `%results = <unit>.<opcode> dst, src, … {attrs} : result types`.
- Memory operands print as `SPACE[base + offset : length]`. NC: `SP[%sbr + %sar : N]`, `SHM[%cbr + %car : N]`, in lines, `N` = burst. SP units: `SP[%ptr + %stride]`, in bytes, the address the access actually uses. A strided NC transfer (`LDSU`/`STSU`) prints `SP[%sar, stride %sbr : N]`. The `+` is fixed syntax for the hardware's own addition, not a general expression.
- `alloc` returns the buffer's start address. SHM elements are `i1024` (line); SP elements are `i8` (byte). NC addresses SP in lines, so it uses `%bi / 128`.
- Types name the hardware storage: `!sar<i15>`, `!sbr<i16>`, `!car<i20>`, `!cbr<i20>` (NC descriptor fields), `!lrf<i32>` (SP unit LRF), `!jcr`. After allocation they carry the index: `!sar<i15, 0>`.
- Channels: the NC side lists SP units explicitly (`{splu0}`); NCore count is `ncores` on `pipeline`.
- Branches use our own terminators (`splu.jcmp`, `fallthrough`) with block arguments; hardware loops stay `loop` regions.

## Before register allocation

```mlir
kernel @sqrt attributes {spmd_dncs = 16} {
  %inp = alloc : !ptr<buffer<2048 x i1024>, #shm>
  %bi  = alloc {align = 128} : !ptr<buffer<8320 x i8>, #sp>      // 65 lines (64 + 1 guard)

  pipeline (%inp, %bi, …) attributes {ncores = 1} {
    %f_ld   = fifo splu -> vu : !fifo<splu -> vu, vector<64xdlf16>>
    %stage  = channel nclu -> {splu0}      // an input chunk is in SP
    %infree = channel {splu0} -> nclu      // the input band may be overwritten

    unit @nclu () {
      %sar0, %sbr, %car0, %cbr = nclu.addr_init sar = 0, sbr = %bi / 128,
                                                car = 0, cbr = %inp + 128 * %dnc_id
          : !sar<i15>, !sbr<i16>, !car<i20>, !cbr<i20>
      %sar3, %car3 = loop 2 iter(%sar1 = %sar0, %car1 = %car0) {               // pass
        %sar2, %car2 = loop 8 iter(%s = %sar1, %c = %car1) {                    // chunk
          %sn, %cn = nclu.ldmu SP[%sbr + %s : 8], SHM[%cbr + %c : 8] : !sar<i15>, !car<i20>
                                          // copy 8 lines SHM -> SP; returns s + 8, c + 8
          nclu.sync put %stage
          yield %sn, %cn
        }
        %sr = nclu.sxrimm 0 : !sar<i15>   // SP offset back to the band start; CAR keeps advancing
        nclu.sync get %infree
        yield %sr, %car2
      }
      nclu.return
    }

    unit @splu () {
      %p0, %st = splu.addr_init ptr = %bi - 128, stride = 128 : !lrf<i32>, !lrf<i32>
      %p3 = loop 2 iter(%p1 = %p0) {                                            // pass
        %p2 = loop 8 iter(%pc = %p1) {                                          // chunk
          splu.sync get %stage
          %pl = loop 8 iter(%p = %pc) {                                         // line
            %pn = splu.ldu %f_ld, SP[%p + %st] : !lrf<i32>   // pushes the line to vu; returns p + st
            yield %pn
          }
          yield %pl
        }
        %pr = splu.immcopy %bi - 128 : !lrf<i32>        // back to one line before the band
        splu.sync put %infree
        yield %pr
      }
      splu.return
    }
  }
}
```

## After register allocation

Every `iter`, `yield`, and result of one register coalesces into one physical register, so the loops carry nothing and no copy is needed. The IR is no longer SSA: a name is a physical register.

```mlir
kernel @sqrt attributes {spmd_dncs = 16} {
  %inp = alloc {addr = 0x1000} : !ptr<buffer<2048 x i1024>, #shm>
  %bi  = alloc {addr = 0x80}   : !ptr<buffer<8320 x i8>, #sp>      // line 1

  pipeline (%inp, %bi, …) attributes {ncores = 1} {
    %f_ld   = fifo splu -> vu : !fifo<splu -> vu, vector<64xdlf16>>
    %stage  = channel nclu -> {splu0}
    %infree = channel {splu0} -> nclu

    unit @nclu () {
      %sar, %sbr, %car, %cbr = nclu.addr_init sar = 0x0, sbr = 0x1, car = 0x0, cbr = 0x81000
          : !sar<i15, 0>, !sbr<i16, 0>, !car<i20, 0>, !cbr<i20, 0>
      loop 2 {
        loop 8 {
          %sar, %car = nclu.ldmu SP[%sbr + %sar : 8], SHM[%cbr + %car : 8] : !sar<i15, 0>, !car<i20, 0>
          nclu.sync put %stage
        }
        %sar = nclu.sxrimm 0 : !sar<i15, 0>
        nclu.sync get %infree
      }
      nclu.return
    }

    unit @splu () {
      %p, %st = splu.addr_init ptr = 0x0, stride = 0x80 : !lrf<i32, 0>, !lrf<i32, 1>
      loop 2 {
        loop 8 {
          splu.sync get %stage
          loop 8 {
            %p = splu.ldu %f_ld, SP[%p + %st] : !lrf<i32, 0>
          }
        }
        %p = splu.immcopy 0x0 : !lrf<i32, 0>
        splu.sync put %infree
      }
      splu.return
    }
  }
}
```

Assembly (B), for comparison:

```asm
.text_nclu                                  .text_splu
.lrf_idx 0                                  .lrf_idx 0 1
.lrf 0x810000000000000010000                .lrf 0x0 0x80
MVLOOPCNT count=2                           MVLOOPCNT count=2
  MVLOOPCNT count=8                           MVLOOPCNT count=8
    LDMU src0=SAR0, src1=SBR0,                  SYNC typ1_imm=6
         src2=CAR0, src3=CBR0 {burst=8}         MVLOOPCNT count=8
    SYNC typ1ac_imm=0x11 {be=1}                   LDU dst=VU, src1=LRF1 {be=1}
  SXRIMM                                        NOP {be=1}
  SYNC typ1ac_imm=0x12                        IMMCOPY dst=LRF0
  NOP {be=1}                                  SYNC typ1_imm=5
RETURN                                        NOP {be=1}
                                            RETURN
```

## SPLU with a runtime length (branch + block arguments)

From the runtime-length softmax (`tests/test_row_bands.py`, `_softmax(runtime="position")`): the trip is computed at run time from a JCR the host seeds, clamped, and used as a dynamic loop count.

```mlir
    unit @splu (%pos : !jcr) {                          // %pos: runtime value the host seeds
      %p0, %st = splu.addr_init ptr = …, stride = … : !lrf<i32>, !lrf<i32>
      %len0 = splu.jadd %pos, 1 {jcr_sel = 1} : !jcr   // length = position + 1
      splu.jcmp %len0, 128 {cmp_type = GE} ^go(%len0), ^clamp     // = JCMP
    ^clamp:
      %c = splu.jimmcopy 128 : !jcr
      fallthrough ^go(%c)                               // no instruction
    ^go(%len : !jcr):                                   // block argument = phi
      %t = splu.jadd %len, 63 : !jcr
      %n = splu.jshr %t, 6 : !jcr                       // ceil(len / 64)
      splu.sync get %stage
      %p1 = loop %n iter(%p = %p0) {                    // dynamic loop: MVLOOPCNT src0=JCR {dynloop=1}
        %pn = splu.ldu %f_ld, SP[%p + %st] {interleave_sz = 2} : !lrf<i32>
        yield %pn
      }
      splu.return
    }
```

After allocation `%len0`, `%c`, `%len`, `%t`, `%n` all sit in JCR5, so `fallthrough` and the block argument vanish, giving the assembly in `softmax_runtime_len.asm`:

```asm
JADD     jcr_tgt=5, typ1_imm=1 {jcr_sel=1}
JCMP     pc_tgt=@L_3, src0=JCR5, cmp_imm=0x80 {cmp_type=GE, isjcmpi=1}
JIMMCOPY jcr_tgt=5, typ1_imm=0x80
L_3:
JADD     jcr_tgt=5, src0=5, typ1_imm=0x3f {jcr_sel=1}
JSHR     jcr_tgt=5, src0=5 {shamt=6}
SYNC     typ1_imm=6
MVLOOPCNT src0=5, typ1_imm=8 {dynloop=1}
  LDU dst=VU, src1=LRF1 {interleave_sz=2, be=1}
```

Unverified: what `jcr_sel=1` with no `src0` reads, and whether `JCMP ... GE` jumps when the comparison holds.
