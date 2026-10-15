"""The VU idiom for `recip`: a Newton reciprocal, seeded from the estimate unit."""

from __future__ import annotations

from .._isa import _SE, _c, _Tmpl
from ..idiom_registry import register_idiom


@register_idiom(
    "recip",
    scratch=("scratch.exp", "scratch.man", "scratch.seed", "scratch.rtmp"),
    consts=(("two", 2.0),),
    operand="s",
)
def recip_newton(
    *,
    s: int,
    zero: int,
    two: int,
    exp: int,
    man: int,
    seed: int,
    rtmp: int,
    out: int,
    slice_en: int = _SE,
) -> list[_Tmpl]:
    """`out = 1/s`: extract exponent/mantissa (EE/IME), FEST seed, then two Newton steps x·(2 − s·x)."""
    return [
        _c(
            "EE",
            src0=s,
            src1=0,
            src2=zero,
            lrf_tgt=exp,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
        _c(
            "IME",
            src0=exp,
            src1=2,
            src2=s,
            lrf_tgt=man,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
        _c(
            "FEST",
            src0=man,
            src1=2,
            src2=zero,
            lrf_tgt=seed,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
        _c(
            "FNMS",
            src0=man,
            src1=seed,
            src2=two,
            lrf_tgt=rtmp,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
        _c(
            "FMA",
            src0=seed,
            src1=rtmp,
            src2=zero,
            lrf_tgt=seed,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
        _c(
            "FNMS",
            src0=man,
            src1=seed,
            src2=two,
            lrf_tgt=rtmp,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
        _c(
            "FMA",
            src0=seed,
            src1=rtmp,
            src2=zero,
            lrf_tgt=seed,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
        _c(
            "IME",
            src0=exp,
            src1=2,
            src2=seed,
            lrf_tgt=out,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
    ]
