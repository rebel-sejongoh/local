"""Generic block-authoring helpers for hand-written DNC kernels (sandbox-local,
PrecSim-free). Complements dense_builder; this surface is the one the worked
`corpus/echo/` kernel uses, and is the convenient way to hand-author a kernel
from scratch.

  rec(unit, op, **fields)          one full-param instruction record
  make_block(uid, recs, lrf, idx)  a unit block dict the encoder consumes
  nc_desc(shm_line, sp_line)       an NCLU/NCSU LRF[0] load/store descriptor
  line_slots(line_int_list)        a 128B line's 8 words -> 64 DLF16 slots

Unit ids (the `target_unit` mask you pass to make_block):
  NCLU 0x200  NCSU 0x400  SPLU 0xa0  SPSU 0xc0  XVU 0x84  VU 0x82
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Sequence
from typing import Any

from . import dnc_dec, dnc_enc, memfile
from . import isa_tables as _isa

_dni = dnc_enc  # alias: the flit/codec module (HdrFlit/SPRFlit/size_dict)

NCLU_UID = 0x200
NCSU_UID = 0x400
SPLU_UID = 0xA0
SPSU_UID = 0xC0
XVU_UID = 0x84
VU_UID = 0x82
# fmt: off
TU_UID = 0x81          # the contraction-face systolic MAC unit (D6); see contraction_tu_mac
ABLU_UID = 0x88        # the AB load, from the AB banks to the TU's west feed. One actor, at column 1.
ABSU_UID = 0x90        # the AB store, from the XVU into the AB banks. One actor, at column 0.
# fmt: on
# The reverse of `UNIT_NAME`, from a unit name to its block UID. The ISA owns both directions, as
# it owns the LRF encoding in `LREG`, so an emitter that knows which unit it is can look up its own
# uid rather than being told. Building the reverse map in the spine and publishing the value
# per unit on the emit ctx, for four emitters whose own node already carried the name.
UNIT_NAME = {
    NCLU_UID: "NCLU",
    NCSU_UID: "NCSU",
    SPLU_UID: "SPLU",
    SPSU_UID: "SPSU",
    XVU_UID: "XVU",
    VU_UID: "VU",
    TU_UID: "TU",
    ABLU_UID: "ABLU",
    ABSU_UID: "ABSU",
}
# Each unit's home init2vec column. AB units are loader-asserted to these columns
# (ABLU=1, ABSU=0); the TU spans 0..7 (column index = systolic row, see program_lifecycle §A2).
COL = {
    NCLU_UID: 7,
    NCSU_UID: 6,
    XVU_UID: 5,
    VU_UID: 4,
    SPLU_UID: 3,
    SPSU_UID: 2,
    TU_UID: 0,
    ABLU_UID: 1,
    ABSU_UID: 0,
}
_SE = 255  # all 8 SIMD slices active
UNIT_UID = {name: uid for uid, name in UNIT_NAME.items()}


# The per-unit SPR word: the full byte masks plus the unit's run and precision nibble, and on the
# XVU an extra store-configuration nibble. It is an ISA fact, as the UIDs above are, saying how the
# unit runs rather than how an op maps onto it. This is its one home, beside `UNIT_UID`.
# fmt: off
UNIT_SPR = {
    "NCLU": 0xFF01FF, "NCSU": 0xFF01FF, "SPLU": 0xFF01FF, "SPSU": 0xFF01FF,
    "ABLU": 0xFF01FF, "ABSU": 0xFF01FF,
    "VU":   0xFF11FF,        # + the VU run/precision nibble (0x11)
    "TU":   0xFF21FF,        # + the TU run/precision nibble (0x21)
    "XVU":  0x70FF21FF,      # + XVU run/precision AND the store-config nibble (0x70)
}
# fmt: on


def LREG(r: int) -> int:
    """The operand-selector code for LRF register `r`, from 0 to 15, used the same way in both the
    source and the target fields of a VU or XVU compute op.

    On those units an operand slot is a class-tagged mux rather than a flat register index. The
    two ranges this function is about are SHARED by both units:

        0xA to 0xF    the constant registers, on `src1` and `src2` only -- `src0` has no
                      constant class, so a constant operand has to be the second or third
        0x10 to 0x1F  LRF 0 to 15, which this function returns

    So LRF r is `0x10 + r` whether it is read or written. Passing a raw `r` as the target
    aliases to a FIFO or constant class and the write is lost without an error, which is the
    canonical trap. Using this helper on both sides keeps the read and the write from
    diverging, and `rec()` and `const_lrf` reject a raw `r`.

    The codes below 0xA are per unit and the two units disagree, so there is no shared table
    to write here and this docstring must not be read as giving one:

        VU     0x1 xvu   0x2 tu    0x3 nbr   0x4 splu   0x6 slice_id   0x8 nfwd   0x9 reuse
        XVU    0x1 splu  0x4 nbr   0x5 vu    0x6 slice_id              0x8 nfwd   0x9 reuse

    An author who takes the VU's list for the XVU selects the NEIGHBOUR where they meant the
    SPLU, on a code that encodes and runs. This paragraph replaces a version that gave the VU's
    four FIFO classes as though they held for both, and omitted `slice_id`, `nfwd` and `reuse`
    entirely -- which reads as though 0x5 to 0x9 were free.

    `reuse` (0x9) is the one worth naming twice: it re-reads the PREVIOUS instruction's operand
    slot rather than any register, which is how a paired-issue idiom feeds two instructions from
    one operand pair. `flash_attn`'s Q.K transpose is built from 12 such pairs.

    The mux tables are not this file's to state. `dnc_spec/isa_spec/README.md` designates
    `prim_analyze/constr_<unit>.py` as their source; the two lines above are transcribed from
    `constr_vu.py` and `constr_xvu.py`, and a disagreement is theirs to settle, not this
    docstring's. The target side shares the source mux, which a round trip on the oracle confirms.
    """
    if not (0 <= r <= 15):
        raise ValueError(f"LREG: LRF register {r} out of range 0..15")
    return 0x10 + r


def _pd(unit: str, opcode: str) -> list[str]:
    pd = _isa.param_dict.get(unit, {})
    if opcode in pd:
        return pd[opcode]
    group = (
        "NC"
        if unit in ("NCLU", "NCSU")
        else "SP"
        if unit in ("SPLU", "SPSU")
        else "VU"
        if unit in ("VU", "XVU")
        else unit
    )
    return _isa.param_dict[group][opcode]


# The fields the encoder honors that the parameter table does not enumerate per op, keyed by
# opcode. Without them the unknown-field guard in `rec()` would reject established idioms. The NC
# SYNC's mask field is one: the parameter table names it one way but
# the authoring `sync_imm` idiom passes `typ1_imm`, which the encoder also honors; mode:
# IMMCOPY accepts it though param_dict omits it.)
_FIELD_ALIASES = {
    "SYNC": {"typ1_imm", "typ1ac_imm"},
    "IMMCOPY": {"mode"},
}


def rec(unit: str, opcode: str, *, fill: int = 0, **over: Any) -> dict[str, Any]:
    """Full-param instruction record: every decoder field for (unit, opcode)
    defaulted to 0, then overridden by **over. `fill` carries uncovered don't-care
    bits (e.g. the VU/XVU trailing-RETURN marker); keyword-only so it never
    collides with a param named `fill`."""
    # Reject field names not legal for THIS op. `encode_instr` does
    # `bit_set(w, bitpos_dict[unit][k], v)` per param, so a name valid for the *unit* but
    # wrong for the *op* is still encoded -- into its own bit-range, which **overlaps and
    # corrupts** the op's real field. The classic trap: TU.MVLOOPCNT's loop reg is
    # `jcr_src0`, not `src0`; passing `src0=` overwrote `typ1_imm` -> 0 -> a baffling
    # `loopzero` deadlock. `param_dict` (_pd) is the per-op field list; it has a few gaps
    # (encoder-honored fields it doesn't enumerate) -- allowlist those so we error only on
    # genuinely-wrong names.
    valid = set(_pd(unit, opcode)) | _FIELD_ALIASES.get(opcode, set())
    unknown = [k for k in over if k not in valid]
    if unknown:
        raise ValueError(
            f"{unit}.{opcode}: field(s) {unknown} not legal for this op (fields: "
            f"{sorted(valid)}). A wrong name is silently encoded into its own bits and "
            f"corrupts a real field. (Common trap: TU loop ops use `jcr_src0`, not `src0`.)"
        )
    params = {k: 0 for k in _pd(unit, opcode)}
    params.update(over)
    # Guard the operand class-mux on the target side of a VU or XVU op. LRF r is `0x10 + r`,
    # which `LREG` gives, and 0 is a null target that writes nothing, as an SP drain uses. A
    # target from 0x1 to 0xF selects a FIFO or constant class rather than a writable register,
    # so a write there is lost without an error, which is the canonical trap. This rejects it.
    # The SP and NC units address their pointer registers as raw 0 to 7, so the guard is scoped
    # to the VU and XVU.
    if unit in ("VU", "XVU"):
        _t = params.get("lrf_tgt")
        if _t is not None and 0x1 <= _t <= 0xF:
            raise ValueError(
                f"{unit}.{opcode}: lrf_tgt={_t:#x} selects a FIFO or constant operand class "
                f"rather than a writable register, so the write would be lost. On the VU and "
                f"XVU, lrf_tgt shares the source class-mux, where LRF[r] is 0x10+r. Pass "
                f"lrf_tgt=LREG(r); a raw r is the trap, and 0 as a null target is fine."
            )
    return {
        "opcode": opcode,
        "opc": _isa.opcode_dict[unit][opcode],
        "params": params,
        "fill": fill,
        "known": True,
    }


def rec_for(unit: str) -> Callable[..., dict[str, Any]]:
    """An `OpBuilder` bound to `unit`, so that `R = rec_for("SPSU")` then `R("STU", src1=15, be=1)`
    works. It curries `rec(unit, ...)` so an emitter names its unit once, and every call
    derives the opcode from the ISA table and validates the fields, so a caller never writes
    an opcode integer or a bit position. See `rec`."""

    def build(opcode: str, *, fill: int = 0, **over: Any) -> dict[str, Any]:
        return rec(unit, opcode, fill=fill, **over)

    return build


def _spr_vu() -> int:
    s = dnc_enc.SPRFlit()
    s.spr0_mask.set(0xFF)
    s.spr1_mask.set(0xFF)
    s.spr0_data.set(0x11)  # ovf_mode = saturate
    return s.get()


def default_spr(unit_id: int) -> int:
    """The unit's default SPR word: the run and precision word for the VU and XVU, and 0 for every
    other unit. The TU has no fixed default, since its word carries a control nibble, so a TU
    caller passes one explicitly. It is named because two callers want it."""
    return _spr_vu() if unit_id in (XVU_UID, VU_UID) else 0


def make_block(
    unit_id: int,
    instr_recs: list[dict[str, Any]],
    lrf_raw: list[int],
    lrf_idx: list[int],
    *,
    spr: int | None = None,
) -> dict[str, Any]:
    """Assemble a unit block from instruction records + LRF init values.

    `spr` overrides the SPR word; when None (the default) the VU/XVU run/precision
    SPR is applied and every other unit gets 0. The TU run/precision SPR is not a
    fixed default (it carries a control nibble), so the TU caller passes it
    explicitly."""
    unit = UNIT_NAME[unit_id]
    n_ib = n_ibuff(unit, len(instr_recs))  # the size_dict lookup's single home
    hdr = make_hdr(
        unit_id, lrf_idx, n_ib, lccr_num=0, lrf_num=len(lrf_raw)
    )  # the header's single home
    if spr is None:
        spr = default_spr(unit_id)
    return {
        "col": COL[unit_id],
        "unit_id": unit_id,
        "unit": unit,
        "hdr": hdr,
        "spr": spr,
        "lrf_idx": lrf_idx,
        "lccr_raw": [],
        "lrf_raw": lrf_raw,
        "instr_recs": instr_recs,
        "n_ib": n_ib,
    }


def nc_desc(shm_line: int, sp_line: int) -> int:
    """An NCLU/NCSU LRF[0] descriptor word: bits[83:80]=0x8 (SHM region),
    [79:64]=SHM line, [27:16]=SP line. Set it as lrf_raw[0] of an NCLU (load
    SHM->SP) or NCSU (store SP->SHM) block; the unit's LDMU/STMU burst count
    moves that many consecutive lines."""
    return (0x8 << 80) | (shm_line << 64) | (sp_line << 16)


SP_LINE_BYTES = 0x80  # one SP line = 128 bytes = 64 dlf16 slots


NC_BURST_MAX = 31  # NCLU/NCSU burst field is 5 bits ([26:22]); see nc_burst_chunks


def nc_burst_chunks(n_lines: int, *, cap: int = NC_BURST_MAX) -> list[int]:
    """Split an NC load or store of `n_lines` into a list of per-instruction burst sizes, each at
    most `cap`, which defaults to 31.

    The NC `burst` field is 5 bits, so a larger value is truncated to its low 5 bits without
    an error: 128 becomes 0, and a decoded 0 means the NC default of 32, so a burst of 128
    moves 32 lines. Emit one load or store, with an advanced descriptor, per returned chunk.

    So `nc_burst_chunks(128)` gives `[31, 31, 31, 31, 4]`, which sums to 128 with every chunk
    within the field."""
    if n_lines < 0:
        raise ValueError(f"nc_burst_chunks: n_lines must be >= 0, got {n_lines}")
    chunks: list[int] = []
    rem = n_lines
    while rem > 0:
        b = min(cap, rem)
        chunks.append(b)
        rem -= b
    return chunks


def chunk_ldmu(reg: int, n: int) -> list[dict[str, Any]]:
    """A consecutive copy of `n` lines from SHM into SP, as NCLU load-and-update chunks. The
    descriptor register auto-advances both its SHM and its SP cursor by its burst each chunk,
    so one register walks the whole span from its base.

    It uses a cap of 32 rather than the default 31, taking the encoding where a burst field of
    0 means 32, so a 32-line chunk packs into one instruction where the default cap would
    split it."""
    return [
        rec(
            "NCLU",
            "LDMU",
            src0=reg,
            src1=reg,
            src2=reg,
            src3=reg,
            burst=(0 if b == 32 else b),
        )
        for b in nc_burst_chunks(n, cap=32)
    ]


def sp_addr(line: int, *, slot: int = 0) -> int:
    """The SP-face address for an SPLU or SPSU read or write pointer, which is the value that goes
    in that unit's pointer register.

    The SP address model has two faces and they belong to different units.

      - An NC unit names an SP target by its line index directly, through `nc_desc`.
      - An SP unit holds a byte address in its pointer register, which is the line index times
        the line size, so a shift of 7. Its auto-increment register likewise holds a byte
        stride, the line count times the line size.

    Seeding an SP unit's pointer with a raw line index, so leaving out that scale, reads the
    wrong region and the operands come back as zeros. This helper applies the scale.

    `slot` adds an offset within the line, two bytes per slot, for sub-line addressing, and
    defaults to the line base."""
    return line * SP_LINE_BYTES + slot * 2


def sp_ld_base(line: int, *, stride_lines: int = 1) -> int:
    """The SPLU pointer seed that makes the first streamed beat read SP line `line`.

    The SP read and write pointer is pre-incremented: a load or store advances it by the
    stride before the access, so the first beat touches one stride past the seed. To land the
    first beat on a line, the seed is one stride below it.

    A raw `sp_addr(line)` therefore reads the next line and skips this one, and the operands
    come back as zeros, which is the canonical off-by-one. `stride_lines` defaults to the
    one-line sweep, and a wider step passes its real stride.

    The oracle confirms it: seeding one line below reads the line, and seeding the line reads
    the next."""
    return sp_addr(line - stride_lines)


def sp_st_base(line: int, *, stride_lines: int = 1) -> int:
    """SPSU `STU` pointer seed so the FIRST drained beat writes SP `line`. The store
    pointer pre-increments exactly like the load pointer (see `sp_ld_base`), so seed
    one stride below: `sp_addr(line - stride_lines)`."""
    return sp_addr(line - stride_lines)


# SYNC immediate is a bitmask (NOT a token id): bit0=SEND/put, bit1=RECV/get,
# bits2-7 = peer-select. Source: dnc_isa.py:1897-1906.
_SYNC_SEND, _SYNC_RECV = 0, 1
_SYNC_PEER_BIT = {"nclu": 2, "ncsu": 3, "splu0": 4, "spsu0": 5, "splu1": 6, "spsu1": 7}


def sync_imm(
    *, send: bool = False, recv: bool = False, peers: Iterable[str] = ()
) -> int:
    """Build a SYNC immediate from its meaning rather than by packing the bitmask by hand. `send`
    opens the put leg and `recv` the get leg, and `peers` lists the peer units this edge
    couples to, drawn from the NC units and the per-NCore SP loaders and storers.

    A put increments `{self}_{peer}_sync` for each peer, and a get decrements
    `{peer}_{self}_sync`. So every edge from one unit to one peer uses the same channel, and
    `dnc_spec/isa_spec/families_control.md` C2 states the order its gets must take.

    So the NCLU's load-done put is `sync_imm(send=True, peers=["splu0"])`, which is 0x11, and
    the SPLU's load-done get is `sync_imm(recv=True, peers=["nclu"])`, which is 0x06."""
    v = (int(bool(send)) << _SYNC_SEND) | (int(bool(recv)) << _SYNC_RECV)
    for p in peers:
        if p not in _SYNC_PEER_BIT:
            raise ValueError(
                f"unknown SYNC peer {p!r}; expected one of {list(_SYNC_PEER_BIT)}"
            )
        v |= 1 << _SYNC_PEER_BIT[p]
    return v


def const_lrf(
    unit: str, lrf_tgt: int, value: float, *, be: int = 0, dtype: str
) -> dict[str, Any]:
    """An `IMMCOPY` record that stages a scalar constant into a VU/XVU LRF register
    for use as an FMA source (compute ops take no literal operand). `value` is a Python
    float; the caller never supplies a bit pattern directly.

    A replica of 1 with a full slice enable broadcasts the constant to all 8 lanes of every
    slice. With a replica of 0 it lands in lane 0 alone and the compute reads whatever the
    other lanes held, which is the canonical trap for this instruction.

    `lrf_tgt` is the operand class-mux code rather than a raw register index, so the constant
    is staged to `LREG(r)`. A constant is useful only if it can be read back as an FMA source,
    so the target must be a real LRF register; a raw `r` aliases to a FIFO or constant class
    and the constant is discarded, which this rejects."""
    if not (0x10 <= lrf_tgt <= 0x1F):
        raise ValueError(
            f"const_lrf: lrf_tgt={lrf_tgt:#x} is not an LRF register code. A staged constant "
            f"must live in a readable LRF, so pass LREG(r), which is 0x10+r for an r in 0 to "
            f"15, rather than a raw r, which aliases to a FIFO or constant class and is lost."
        )
    import numpy as np
    from numux.dispatch import encode_of

    bits = int(encode_of(dtype)(np.array([value], dtype=np.float32))[0])
    return rec(
        unit,
        "IMMCOPY",
        typ1_imm=bits,
        replica=1,
        lrf_tgt=lrf_tgt,
        mode=0,
        slice_en=_SE,
        be=be,
    )


def line_slots(words: Iterable[int]) -> list[int]:
    """A 128B line (list of 8 little-endian 16B word ints) -> 64 DLF16 slots
    (slot k = word k//8, lane k%8)."""
    slots: list[int] = []
    for w in words:
        b = int(w).to_bytes(16, "little")
        slots.extend(int.from_bytes(b[2 * s : 2 * s + 2], "little") for s in range(8))
    return slots


# ===================================================================== #
# Program-level IR (folded from the matmul `dense_builder`, matmul-independent).
# A thin builder mirroring the device `*_mgr` emission API; `.build()` lowers to
# the byte-level block dict the encoder consumes. Header + n_ib are COMPUTED.
# ===================================================================== #
class Program:
    """A mirror of the device's own manager: its emission methods build the instruction stream and
    `.build()` lowers that to the full byte-level block dict. The header and the ibuff count
    are computed rather than carried, and the descriptors are packed from semantic values."""

    def __init__(
        self,
        unit: str,
        unit_id: int,
        *,
        lrf_idx: Iterable[int] = (),
        spr: int = 0,
        hdr_fill: int = 0,
    ):
        self.unit = unit
        self._uid = unit_id
        self._lrf_idx = list(lrf_idx)
        self._spr = spr
        self._hdr_fill = hdr_fill  # unit-specific header config bits (0 for AB)
        self._recs: list[dict[str, Any]] = []
        self._lrf: list[int] = []
        self._lccr: list[int] = []
        self._opc = _isa.opcode_dict[unit]  # unit-specific opcode space (codec)

    def _emit(self, op: str, _fill: int = 0, **params: Any) -> None:
        self._recs.append(
            {
                "opcode": op,
                "opc": self._opc[op],
                "params": params,
                "fill": _fill,
                "known": True,
            }
        )

    def lrf_init(self, values: Iterable[int], width: int | None = None) -> None:
        """The initial values of the LRF registers. Given a `width`, the values are packed in two's
        complement, so -16 becomes 0x3f0 in 10 bits, and without one they are stored as they
        are.

        An NC unit seeds its first register with `nc_desc(shm_line, sp_line)`. An SP unit seeds
        its read and write pointer registers with `sp_addr(line)`, which is a byte address
        rather than a raw line index, as `sp_addr` explains."""
        m = (1 << width) - 1 if width else None
        self._lrf = [(v & m) if m is not None else v for v in values]

    def lccr_init(self, values: Iterable[int]) -> None:
        self._lccr = list(values)

    def mvloopcnt(self, n: int) -> None:
        self._emit(
            "MVLOOPCNT", src0=0, typ1_imm=n, dynloop=0, cont=0, brk=0, force_jump=0
        )

    def sync(self, ch: int, be: int = 0) -> None:
        self._emit("SYNC", typ1_imm=ch, be=be)

    def ldstu(self, **params: Any) -> None:
        self._emit("LDSTU", **params)

    def nop(self, be: int = 1) -> None:
        self._emit("NOP", be=be)

    def ret(self, be: int = 0, fill: int = 0) -> None:
        self._emit("RETURN", _fill=fill, be=be)

    def pad_return(self, be: int = 0) -> None:
        """Pad with RETURNs to the next ibuff boundary (the device IBuffFinish tail)."""
        npi = dnc_enc.size_dict[self.unit]["INSTR_NUM_PER_IBUFF"]
        total = (len(self._recs) // npi + 1) * npi
        while len(self._recs) < total:
            self._emit("RETURN", be=be)

    def i(self, op: str, _fill: int = 0, **params: Any) -> None:
        self._emit(op, _fill=_fill, **params)

    def fcmp(self, **p: Any) -> None:
        self._emit("FCMP", **p)

    def fma(self, **p: Any) -> None:
        self._emit("FMA", **p)

    def immcopy(self, **p: Any) -> None:
        self._emit("IMMCOPY", **p)

    def logical(self, **p: Any) -> None:
        self._emit("LOGICAL", **p)

    def build(self) -> dict[str, Any]:
        n_ib = n_ibuff(self.unit, len(self._recs))  # DERIVED, not carried
        hdr = make_hdr(
            self._uid,
            self._lrf_idx,
            n_ib,
            lccr_num=len(self._lccr),
            lrf_num=len(self._lrf),
            hdr_fill=self._hdr_fill,
        )
        return {
            "col": 0,
            "unit": self.unit,
            "unit_id": self._uid,
            "hdr": hdr,
            "spr": self._spr,
            "lrf_idx": self._lrf_idx,
            "lrf_raw": self._lrf,
            "lccr_raw": self._lccr,
            "instr_recs": self._recs,
            "n_ib": n_ib,
        }


def make_hdr(
    unit_id: int,
    lrf_idx: Sequence[int],
    n_ib: int,
    *,
    lccr_num: int = 0,
    lrf_num: int | None = None,
    hdr_fill: int = 0,
) -> int:
    """The one header constructor: a header flit over the target unit and the three counts, with the
    descriptor-index slots set, combined with any configuration bits those fields do not carry.
    The descriptor count defaults to the length of the index list."""
    if len(lrf_idx) > dnc_enc.HdrFlit.MAX_LRF_SLOTS:
        raise ValueError(
            f"unit {unit_id:#x}: {len(lrf_idx)} descriptors do not fit the header's "
            f"{dnc_enc.HdrFlit.MAX_LRF_SLOTS}-slot index table. A descriptor is a slot, so a unit holding more "
            f"has to walk FEWER of them -- one cursor stepped between runs rather than one per run -- not be "
            f"emitted anyway. Emitting it raises IndexError here, which says nothing about which unit or why."
        )
    h = dnc_enc.HdrFlit(
        target_unit=unit_id,
        lccr_num=lccr_num,
        lrf_num=len(lrf_idx) if lrf_num is None else lrf_num,
        ibuff_num=n_ib,
    )
    for slot, idx in enumerate(lrf_idx):
        h.lrf_idx[slot].set(idx)
    return h.get() | hdr_fill


def spr(spr0_data: int, *, spr0_mask: int = 0xFF, spr1_mask: int = 0xFF) -> int:
    """The SPR word constructor, over the full-mask flit family. `spr0_data` is the unit's run and
    precision nibble, which is 0x01 on the AB units, 0x21 on the TU and 0x11 on the VU."""
    s = dnc_enc.SPRFlit()
    s.spr0_mask.set(spr0_mask)
    s.spr1_mask.set(spr1_mask)
    s.spr0_data.set(spr0_data)
    return s.get()


def n_ibuff(unit: str, n_recs: int) -> int:
    """The ibuff count, `ceil(n_recs / INSTR_NUM_PER_IBUFF)`, which is the one place that size is
    looked up."""
    npi = dnc_enc.size_dict[unit]["INSTR_NUM_PER_IBUFF"]
    return -(-n_recs // npi)


_IBUFF_HI, _IBUFF_LO = _isa.HDR_FIELDS["ibuff_num"]  # [84, 78]


def pad_return_recs(
    unit: str, recs: list[dict[str, Any]], *, end_fill: int | None = None
) -> list[dict[str, Any]]:
    """Pad `recs` with trailing full-param RETURNs to the unit's ibuff boundary.
    With `end_fill`, a FULL padding ibuff marks its last RETURN be=1 + fill=end_fill
    (the VU/XVU init2vec block-end marker)."""
    npi = dnc_enc.size_dict[unit]["INSTR_NUM_PER_IBUFF"]
    n = len(recs)
    pad = npi if n % npi == 0 else npi - n % npi
    rets = [rec(unit, "RETURN") for _ in range(pad)]
    if end_fill is not None and pad == npi:
        rets[-1]["params"]["be"] = 1
        rets[-1]["fill"] = end_fill
    return recs + rets


def build_block(
    unit: str,
    unit_id: int,
    lrf_idx: Iterable[int],
    lrf_raw: Iterable[int],
    recs: list[dict[str, Any]],
    *,
    spr: int,
    lccr_raw: Iterable[int] = (),
    hdr_fill: int = 0,
    pad: bool = True,
    end_fill: int | None = None,
) -> dict[str, Any]:
    """Assemble a full block dict from already-built records. It is the one block assembler, and
    `Program.build()` derives the header and the ibuff count."""
    if pad:
        recs = pad_return_recs(unit, recs, end_fill=end_fill)
    p = Program(unit, unit_id, lrf_idx=list(lrf_idx), spr=spr, hdr_fill=hdr_fill)
    p.lrf_init(lrf_raw)  # width=None -> stored verbatim
    p.lccr_init(lccr_raw)
    p._recs = recs
    return p.build()


def with_multi_tile(block: dict) -> dict:
    """Return a copy of `block` retargeted to NCore 1, which sets the 0x100 bit in its target unit,
    re-derived through `make_hdr`. The name is matmul's for that bit, and what it does is select
    the second NCore.

    The per-NCore units, the SP loaders and storers and the compute units, exist once per NCore:
    emit the NCore-0 copy of a block plain and pass it through here for the NCore-1 copy, on a
    disjoint SP and SHM region.

    The NC units are shared per DNC and have no per-NCore instance, so they must not carry this
    bit, and PrecSim asserts and exits if one does. One shared NC unit fans to both NCores
    through the per-NCore SYNC channels, and this helper raises if it is applied to an NC block.
    """
    base_uid = block["unit_id"] & ~0x100
    if base_uid in (NCLU_UID, NCSU_UID):
        raise ValueError(
            f"with_multi_tile: {UNIT_NAME.get(base_uid, hex(base_uid))} is DNC-shared "
            "(one per DNC) and cannot carry the 0x100 NCore-select bit (PrecSim exit 10). "
            "Emit ONE shared NCLU/NCSU that fans to both NCores via the splu0/splu1 and "
            "spsu0/spsu1 SYNC channels."
        )
    base = make_hdr(
        block["unit_id"],
        block["lrf_idx"],
        block["n_ib"],
        lccr_num=len(block["lccr_raw"]),
        lrf_num=len(block["lrf_idx"]),
    )
    residual = block["hdr"] ^ base
    c = dict(block)
    c["unit_id"] = block["unit_id"] | 0x100
    c["hdr"] = make_hdr(
        c["unit_id"],
        block["lrf_idx"],
        block["n_ib"],
        lccr_num=len(block["lccr_raw"]),
        lrf_num=len(block["lrf_idx"]),
        hdr_fill=residual,
    )
    return c


def with_col(block: dict, col: int) -> dict:
    """Return a copy of `block` with its init2vec `col` set (informational)."""
    c = dict(block)
    c["col"] = col
    return c


def build_block_pinned(
    unit: str,
    unit_id: int,
    lrf_idx: Sequence[int],
    lrf_raw: Iterable[int],
    recs: list[dict[str, Any]],
    *,
    spr: int,
    hdr: int,
    col: int = 0,
    lccr_raw: Sequence[int] = (),
    pad: bool = False,
) -> dict[str, Any]:
    """Assemble a block whose header must equal a PINNED value `hdr`; structural
    bits come from `make_hdr`, the remainder rides as the `hdr_fill` residual."""
    n_ib = n_ibuff(unit, len(recs))
    structural = make_hdr(unit_id, list(lrf_idx), n_ib, lccr_num=len(lccr_raw))
    blk = build_block(
        unit,
        unit_id,
        lrf_idx,
        lrf_raw,
        recs,
        spr=spr,
        lccr_raw=lccr_raw,
        hdr_fill=hdr ^ structural,
        pad=pad,
    )
    return with_col(blk, col)


# --- codec round-trip + SHM-vector helpers (used by worked examples) ---------- #
shm_line_vec = memfile.slots_to_line  # encode 64 DLF16 vals -> a 128B line (hex)


def check_codec_roundtrip(blocks: list[dict[str, Any]]) -> tuple[bool, list[str]]:
    """decode(encode(x)) == x for a list of authored blocks: every instruction
    re-encodes + re-decodes to itself, and the assembled image re-decodes to the
    same headers/LRF/records. Returns (ok, list_of_drift_messages)."""
    bad: list[str] = []
    for b in blocks:
        u = b["unit"]
        for i, r in enumerate(b["instr_recs"]):
            back = dnc_dec.decode_instr(u, dnc_enc.encode_instr(u, r))
            if (
                back["opcode"] != r["opcode"]
                or back["opc"] != r["opc"]
                or back["params"] != r["params"]
                or back["fill"] != r["fill"]
            ):
                bad.append(f"{u}[{i}] {r['opcode']}: round-trip drift")
    bytes_out, _n, _ = dnc_enc.build_init_bytes(blocks)
    by_uid = {d["unit_id"]: d for d in dnc_dec.decode(bytes_out)}
    for b in blocks:
        d = by_uid.get(b["unit_id"])
        if d is None:
            bad.append(f"uid {b['unit_id']:#x}: missing from re-decoded init.bin")
            continue
        if d["hdr"] != b["hdr"]:
            bad.append(f"uid {b['unit_id']:#x}: hdr drift")
        if d["lrf_raw"] != b["lrf_raw"]:
            bad.append(f"uid {b['unit_id']:#x}: lrf drift")
        for i, (rd, rb) in enumerate(zip(d["instr_recs"], b["instr_recs"])):
            if rd["opcode"] != rb["opcode"] or rd["params"] != rb["params"]:
                bad.append(f"uid {b['unit_id']:#x}[{i}]: rec drift")
                break
    return (not bad), bad
