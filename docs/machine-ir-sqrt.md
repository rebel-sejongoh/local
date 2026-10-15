# Machine-level IR 예제: sqrt R=2048, K=64 (DNC 0)

- 기준: `~/workspaces/codesigner` `dev` `81a6cc13c`의 실제 image(`mcc build` → `dnc_binutils.dnc_dec.disasm`).
- 단계
  - **A1. Machine IR, register allocation 전**: op 하나 = HW 명령 하나. VU 값은 `vector<64xdlf16>` SSA 값. sync 채널·FIFO는 기호.
  - **A2. Machine IR, register allocation 후**: A1과 명령이 같고, 타입이 물리 레지스터를 포함(`!vu.lrf<5, vector<64xdlf16>>`).
  - **B. Final Machine IR**: assembly와 같은 추상화. SYNC bitmask, `be` 비트, flat 명령 열. disasm과 1:1.
- 문법은 MLIR 스타일의 설명용 표기다. 실제 dialect 정의가 아니다.

## 규칙

| 요소 | 표현 | 이유 |
|---|---|---|
| SDF | `pipeline` | 안의 유닛은 동시에 실행. 버퍼 생성·해제 없음 |
| HW 유닛 | `unit @name (preload) { … }` | 유닛마다 PC가 따로(MIMD). region 인자 = block 시작 시 LRF에 실린 값(`.lrf`) |
| NCore | `pipeline … attributes {ncores = N}`에 한 번만. 유닛 이름은 번호 없이(`splu`, `vu`, `spsu`) | NCore마다 같은 프로그램을 실행하고, FIFO는 NCore를 넘지 않으며, SP 유닛의 SYNC peer bit는 NCore 상대값. 예외: DNC 공유 유닛(NCLU/NCSU)이 여러 NCore를 가리킬 때는 `splu[*]`처럼 적음 |
| 명령 | `<unit>.<opcode>` | 같은 mnemonic도 유닛마다 opcode·필드가 다름 |
| loop | `loop N { … }` | `MVLOOPCNT N` + body + 마지막 명령 `be`로 1:1 lowering |
| FIFO | `%f = fifo src -> dst` (타입 `!fifo<src -> dst>`는 유도). operand로 쓰면 pop 1회, `into %f`는 push | 이미 있는 HW FIFO에 이름을 붙이는 선언. depth는 HW 값이라 적지 않음. VU에서 FIFO는 operand class, 명령 하나 = pop 하나 |
| sync | `%c = channel src -> dst [init N]` (타입 `!chan<src -> dst>`는 유도), `<unit>.sync put/get %c`. `init`은 0이 아닐 때만 적음 | verifier가 채널별 `put − get == init` 검사 |
| channel depth (적지 않음) | 짝지어지지 않은 put을 몇 개까지 쌓을 수 있는지. 가득 차면 put이 멈춤. NC↔SP(LU/SU) 16, NCLU↔NCSU 16, SPLU↔SPSU(같은 NCore) 4, SPLU↔SPSU(다른 NCore) 32, ABLU↔ABSU 4 | 하드웨어 고정값(PrecSim `prim_run_state_v2.py` 기준). 컴파일러가 고르지 않음. 데이터 FIFO 깊이와는 별개 |
| VU 데이터 | A1: `vector<64xdlf16>`, `vector<64xi16>` 등 SSA 값. A2: `!vu.lrf<N, vector<…>>` | 원소 타입으로 op별 타입 검사(예: `ee`는 i16). allocation 후에도 값 타입 유지 |
| SP/NC 주소 | `!sp.ptr`, `!sp.stride`, `!nc.desc` 등 **변경 가능한 레지스터**. A2: `!sp.lrf<N, ptr>` | 명령이 레지스터를 직접 갱신(`LDU`: `ptr += stride` 후 load) |

타입 약칭

```mlir
!line   = !mem.line<128 B>               // 128 B = 64 x dlf16
```

---

## A1. Machine IR (register allocation 전)

`:` 뒤에는 결과 타입만 적는다(operand 타입은 생략). 결과가 없는 op에는 타입이 없다.

```mlir
kernel @sqrt attributes {spmd_dncs = 16} {
  %inp = alloc : buffer<2048 x 64 x dlf16, #shm>
  %out = alloc : buffer<2048 x 64 x dlf16, #shm>
  %bi  = alloc lines [1, 66)   : buffer<65 x !line, #sp>    // 입력 band (64 + guard 1)
  %bo  = alloc lines [66, 130) : buffer<64 x !line, #sp>    // 출력 band

  pipeline (%inp, %out, %bi, %bo) attributes {ncores = 1} {
    %f_ld   = fifo splu -> vu
    %f_st   = fifo vu -> spsu
    %stage  = channel nclu -> splu   // 입력 chunk 준비
    %infree = channel splu -> nclu   // 입력 band 비움
    %egress = channel spsu -> ncsu   // 출력 chunk 준비
    %ofree  = channel ncsu -> spsu   // 출력 band 비움

    // ── NCLU: SHM → SP
    unit @nclu (%d : !nc.desc = desc(src = %inp[128 * %dnc_id, 0], dst = %bi)) {
      loop 2 {                                        // pass (m.blk)
        loop 8 {                                      // chunk
          nclu.ldmu %d {burst = 8}                    // 8 line, desc 자동 증가
          nclu.sync put %stage
        }
        nclu.sxrimm %d.sar, 0                         // SP cursor → band 시작
        nclu.sync get %infree
      }
      nclu.return
    }

    // ── SPLU: SP → VU FIFO
    unit @splu (%p : !sp.ptr = %bi.base - 128, %st : !sp.stride = 128) {
      loop 2 {
        loop 8 {
          splu.sync get %stage
          loop 8 {
            splu.ldu %p, %st into %f_ld               // ptr += stride; load → vu
          }
        }
        splu.immcopy %p, %bi.base - 128               // ptr → band 시작
        splu.sync put %infree
      }
      splu.return
    }

    // ── VU: compute
    unit @vu () {
      %one  = vu.immcopy 1.0                : vector<64xdlf16>
      %zero = vu.immcopy 0.0                : vector<64xdlf16>
      %half = vu.immcopy 0.5                : vector<64xdlf16>
      %th   = vu.immcopy 1.5                : vector<64xdlf16>
      %seed = vu.immcopy 0.625              : vector<64xdlf16>
      loop 2 {
        loop 64 {                                     // beat = 1 line
          %s  = vu.fma  %f_ld, %one, %zero  : vector<64xdlf16>   // FIFO pop 1회
          %e0 = vu.ee   %s                  : vector<64xi16>     // 지수 (정수)
          %e1 = vu.shr  %e0, 1              : vector<64xi16>
          %y0 = vu.ime  %e1, 2, %seed       : vector<64xdlf16>   // 0.625 · 2^-e
          %xh = vu.fma  %s, %half, %zero    : vector<64xdlf16>   // s/2
          %t0 = vu.fma  %y0, %y0, %zero     : vector<64xdlf16>   // Newton 1
          %u0 = vu.fnms %xh, %t0, %th       : vector<64xdlf16>
          %y1 = vu.fma  %y0, %u0, %zero     : vector<64xdlf16>
          %t1 = vu.fma  %y1, %y1, %zero     : vector<64xdlf16>   // Newton 2
          %u1 = vu.fnms %xh, %t1, %th       : vector<64xdlf16>
          %y2 = vu.fma  %y1, %u1, %zero     : vector<64xdlf16>
          %t2 = vu.fma  %y2, %y2, %zero     : vector<64xdlf16>   // Newton 3
          %u2 = vu.fnms %xh, %t2, %th       : vector<64xdlf16>
          %y3 = vu.fma  %y2, %u2, %zero     : vector<64xdlf16>
          %t3 = vu.fma  %y3, %y3, %zero     : vector<64xdlf16>   // Newton 4
          %u3 = vu.fnms %xh, %t3, %th       : vector<64xdlf16>
          %y4 = vu.fma  %y3, %u3, %zero     : vector<64xdlf16>
          %r  = vu.fma  %s, %y4, %zero      : vector<64xdlf16>   // sqrt = s · rsqrt(s)
          vu.fma %r, %one, %zero into %f_st                      // push → spsu
        }
      }
      vu.return
    }

    // ── SPSU: VU FIFO → SP
    unit @spsu (%q : !sp.ptr = %bo.base - 128, %st : !sp.stride = 128) {
      loop 2 {
        loop 8 {
          loop 8 {
            spsu.stu %q, %st from %f_st
          }
          spsu.sync put %egress
        }
        spsu.immcopy %q, %bo.base - 128
        spsu.sync get %ofree
      }
      spsu.return
    }

    // ── NCSU: SP → SHM
    unit @ncsu (%d : !nc.desc = desc(src = %bo, dst = %out[128 * %dnc_id, 0])) {
      loop 2 {
        loop 8 {
          ncsu.sync get %egress
          ncsu.stmu %d {burst = 8}
        }
        ncsu.sxrimm %d.sar, 0
        ncsu.sync put %ofree
      }
      ncsu.return
    }
  }
}
```

A1에서 검사할 수 있는 것:
- 채널마다 `put − get == init`. `%stage`: put 2·8, get 2·8.
- FIFO마다 push == pop. `%f_ld`: SPLU 2·8·8 = 128, VU 2·64 = 128.
- VU: 한 명령의 FIFO operand는 하나(pop 1회).
- 원소 타입: `vu.ee`는 dlf16 → i16, `vu.ime`은 (i16, dlf16) → dlf16 등 op별 타입 규칙.
- 유닛마다 IBUF 명령 수 상한.

---

## A2. Machine IR (register allocation 후)

명령은 A1과 같다. 바뀌는 것은 두 가지다.
- 레지스터 타입이 물리 레지스터 번호와 값 타입을 함께 갖는다: `!vu.lrf<N, vector<64xdlf16>>`, `!sp.lrf<N, ptr>`.
  값 이름은 레지스터 이름과 같게 둔다(`%lrf5`). VU live range가 16개 안에 들어가야 한다.
- 레지스터 초기값(region 인자)이 즉값으로 바뀐다. 이것이 block의 `.lrf`다.

VU 할당 결과: `one→lrf0 zero→lrf1 half→lrf2 th→lrf3 seed→lrf4 s→lrf5 e→lrf6 xh→lrf7 y→lrf8 t→lrf9 u→lrf10 r→lrf11`.
`y0..y4`, `t0..t3`, `u0..u3`은 live range가 겹치지 않아 각각 하나로 합쳐진다.

```mlir
kernel @sqrt attributes {spmd_dncs = 16} {
  %inp = alloc : buffer<2048 x 64 x dlf16, #shm>
  %out = alloc : buffer<2048 x 64 x dlf16, #shm>
  %bi  = alloc lines [1, 66)   : buffer<65 x !line, #sp>
  %bo  = alloc lines [66, 130) : buffer<64 x !line, #sp>

  pipeline (%inp, %out, %bi, %bo) attributes {ncores = 1} {
    %f_ld   = fifo splu -> vu
    %f_st   = fifo vu -> spsu
    %stage  = channel nclu -> splu
    %infree = channel splu -> nclu
    %egress = channel spsu -> ncsu
    %ofree  = channel ncsu -> spsu

    // ── NCLU
    unit @nclu (%lrf0 : !nc.lrf<0, desc> = 0x810000000000000010000) {   // → SAR0 SBR0 CAR0 CBR0
      loop 2 {
        loop 8 {
          nclu.ldmu %sar0, %sbr0, %car0, %cbr0 {burst = 8}
          nclu.sync put %stage
        }
        nclu.sxrimm %sar0, 0
        nclu.sync get %infree
      }
      nclu.return
    }

    // ── SPLU
    unit @splu (%lrf0 : !sp.lrf<0, ptr> = 0x0, %lrf1 : !sp.lrf<1, stride> = 0x80) {
      loop 2 {
        loop 8 {
          splu.sync get %stage
          loop 8 {
            splu.ldu %lrf0, %lrf1 into %f_ld
          }
        }
        splu.immcopy %lrf0, 0x0
        splu.sync put %infree
      }
      splu.return
    }

    // ── VU
    unit @vu () {
      %lrf0  = vu.immcopy 1.0                  : !vu.lrf<0, vector<64xdlf16>>
      %lrf1  = vu.immcopy 0.0                  : !vu.lrf<1, vector<64xdlf16>>
      %lrf2  = vu.immcopy 0.5                  : !vu.lrf<2, vector<64xdlf16>>
      %lrf3  = vu.immcopy 1.5                  : !vu.lrf<3, vector<64xdlf16>>
      %lrf4  = vu.immcopy 0.625                : !vu.lrf<4, vector<64xdlf16>>
      loop 2 {
        loop 64 {
          %lrf5  = vu.fma  %f_ld, %lrf0, %lrf1 : !vu.lrf<5, vector<64xdlf16>>
          %lrf6  = vu.ee   %lrf5               : !vu.lrf<6, vector<64xi16>>
          %lrf6  = vu.shr  %lrf6, 1            : !vu.lrf<6, vector<64xi16>>
          %lrf8  = vu.ime  %lrf6, 2, %lrf4     : !vu.lrf<8, vector<64xdlf16>>
          %lrf7  = vu.fma  %lrf5, %lrf2, %lrf1 : !vu.lrf<7, vector<64xdlf16>>
          %lrf9  = vu.fma  %lrf8, %lrf8, %lrf1 : !vu.lrf<9, vector<64xdlf16>>
          %lrf10 = vu.fnms %lrf7, %lrf9, %lrf3 : !vu.lrf<10, vector<64xdlf16>>
          %lrf8  = vu.fma  %lrf8, %lrf10, %lrf1 : !vu.lrf<8, vector<64xdlf16>>
          %lrf9  = vu.fma  %lrf8, %lrf8, %lrf1 : !vu.lrf<9, vector<64xdlf16>>
          %lrf10 = vu.fnms %lrf7, %lrf9, %lrf3 : !vu.lrf<10, vector<64xdlf16>>
          %lrf8  = vu.fma  %lrf8, %lrf10, %lrf1 : !vu.lrf<8, vector<64xdlf16>>
          %lrf9  = vu.fma  %lrf8, %lrf8, %lrf1 : !vu.lrf<9, vector<64xdlf16>>
          %lrf10 = vu.fnms %lrf7, %lrf9, %lrf3 : !vu.lrf<10, vector<64xdlf16>>
          %lrf8  = vu.fma  %lrf8, %lrf10, %lrf1 : !vu.lrf<8, vector<64xdlf16>>
          %lrf9  = vu.fma  %lrf8, %lrf8, %lrf1 : !vu.lrf<9, vector<64xdlf16>>
          %lrf10 = vu.fnms %lrf7, %lrf9, %lrf3 : !vu.lrf<10, vector<64xdlf16>>
          %lrf8  = vu.fma  %lrf8, %lrf10, %lrf1 : !vu.lrf<8, vector<64xdlf16>>
          %lrf11 = vu.fma  %lrf5, %lrf8, %lrf1 : !vu.lrf<11, vector<64xdlf16>>
          vu.fma %lrf11, %lrf0, %lrf1 into %f_st
        }
      }
      vu.return
    }

    // ── SPSU
    unit @spsu (%lrf0 : !sp.lrf<0, ptr> = 0x2080, %lrf1 : !sp.lrf<1, stride> = 0x80) {
      loop 2 {
        loop 8 {
          loop 8 {
            spsu.stu %lrf0, %lrf1 from %f_st
          }
          spsu.sync put %egress
        }
        spsu.immcopy %lrf0, 0x2080
        spsu.sync get %ofree
      }
      spsu.return
    }

    // ── NCSU
    unit @ncsu (%lrf0 : !nc.lrf<0, desc> = 0x818000000000000420000) {
      loop 2 {
        loop 8 {
          ncsu.sync get %egress
          ncsu.stmu %sar0, %sbr0, %car0, %cbr0 {burst = 8}
        }
        ncsu.sxrimm %sar0, 0
        ncsu.sync put %ofree
      }
      ncsu.return
    }
  }
}
```

A2부터는 같은 이름에 여러 번 쓰므로 SSA가 아니다(`%lrf8`이 Newton마다 갱신). 이 시점부터 IR은 레지스터 기준의 명령 열이다.

---

## A2 → B lowering

| A2 | B |
|---|---|
| `loop N { body }` | `mvloopcnt N` + body, 마지막 명령에 `{be}`. body가 loop로 끝나면 `nop {be}` 추가 |
| `sync put/get %c` | `sync imm=<bitmask>`: bit0 put, bit1 get, bit2 nclu, bit3 ncsu, bit4 splu, bit5 spsu |
| `%f_ld` operand / `into %f_st` | operand class `FIFO_SPLU` / `sp_tgt=RESULT`, `consumer=VU` |
| region 인자 | block `.lrf` 초기값 |
| `vu.immcopy 1.0` | dlf16 비트 `0x3e00` |
| `splu.immcopy %lrf0, 0x2080` | 즉값 `0x2080 >> 1 = 0x1040` (HW가 `<< 1`) |

---

## B. Final Machine IR (assembly와 1:1)

```mlir
pipeline attributes {ncores = 1} {
  unit @nclu col=7 lrf=[0x810000000000000010000] {
    nclu.mvloopcnt 2
    nclu.mvloopcnt 8
    nclu.ldmu sar=SAR0 sbr=SBR0 car=CAR0 cbr=CBR0 burst=8
    nclu.sync imm=0x11 {be}
    nclu.sxrimm
    nclu.sync imm=0x12
    nclu.nop {be}
    nclu.return
  }
  unit @splu col=3 lrf=[0x0, 0x80] {
    splu.mvloopcnt 2
    splu.mvloopcnt 8
    splu.sync imm=0x6
    splu.mvloopcnt 8
    splu.ldu src0=LRF0 src1=LRF1 consumer=VU {be}
    splu.nop {be}
    splu.immcopy dst=LRF0 imm=0
    splu.sync imm=0x5
    splu.nop {be}
    splu.return
  }
  unit @vu col=4 {
    vu.immcopy dst=LRF0 imm=0x3e00
    vu.immcopy dst=LRF1 imm=0x0
    vu.immcopy dst=LRF2 imm=0x3c00
    vu.immcopy dst=LRF3 imm=0x3f00
    vu.immcopy dst=LRF4 imm=0x3c80
    vu.mvloopcnt 2
    vu.mvloopcnt 64
    vu.fma  dst=LRF5  src0=FIFO_SPLU src1=LRF0 src2=LRF1
    vu.ee   dst=LRF6  src0=LRF5 src2=CONST0
    vu.shr  dst=LRF6  src0=LRF6 src1=#1 src2=CONST0
    vu.ime  dst=LRF8  src0=LRF6 src1=#2 src2=LRF4
    vu.fma  dst=LRF7  src0=LRF5 src1=LRF2 src2=LRF1
    vu.fma  dst=LRF9  src0=LRF8 src1=LRF8 src2=LRF1
    vu.fnms dst=LRF10 src0=LRF7 src1=LRF9 src2=LRF3
    vu.fma  dst=LRF8  src0=LRF8 src1=LRF10 src2=LRF1
    vu.fma  dst=LRF9  src0=LRF8 src1=LRF8 src2=LRF1
    vu.fnms dst=LRF10 src0=LRF7 src1=LRF9 src2=LRF3
    vu.fma  dst=LRF8  src0=LRF8 src1=LRF10 src2=LRF1
    vu.fma  dst=LRF9  src0=LRF8 src1=LRF8 src2=LRF1
    vu.fnms dst=LRF10 src0=LRF7 src1=LRF9 src2=LRF3
    vu.fma  dst=LRF8  src0=LRF8 src1=LRF10 src2=LRF1
    vu.fma  dst=LRF9  src0=LRF8 src1=LRF8 src2=LRF1
    vu.fnms dst=LRF10 src0=LRF7 src1=LRF9 src2=LRF3
    vu.fma  dst=LRF8  src0=LRF8 src1=LRF10 src2=LRF1
    vu.fma  dst=LRF11 src0=LRF5 src1=LRF8 src2=LRF1
    vu.fma  sp_tgt=RESULT src0=LRF11 src1=LRF0 src2=LRF1 {be}
    vu.nop {be}
    vu.return
  }
  unit @spsu col=2 lrf=[0x2080, 0x80] {
    spsu.mvloopcnt 2
    spsu.mvloopcnt 8
    spsu.mvloopcnt 8
    spsu.stu src1=LRF1 src=FIFO_VU {be}
    spsu.sync imm=0x9 {be}
    spsu.immcopy dst=LRF0 imm=0x1040
    spsu.sync imm=0xa
    spsu.nop {be}
    spsu.return
  }
  unit @ncsu col=6 lrf=[0x818000000000000420000] {
    ncsu.mvloopcnt 2
    ncsu.mvloopcnt 8
    ncsu.sync imm=0x22
    ncsu.stmu sar=SAR0 sbr=SBR0 car=CAR0 cbr=CBR0 burst=8 {be}
    ncsu.sxrimm
    ncsu.sync imm=0x21
    ncsu.nop {be}
    ncsu.return
  }
}
```

B는 `dnc_binutils.dnc_dec.disasm` 출력과 줄 단위로 같다(`.text_<unit>` = `unit`, `.lrf` = `lrf=`).
disasm은 `SHR`/`IME`의 `src1` 즉값(1, 2)을 operand class(`FIFO_XVU`, `FIFO_TU`)로 표시하는데, B는 JIR 값대로 `#1`, `#2`로 적었다.
