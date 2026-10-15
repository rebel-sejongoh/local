"""The VU idioms for `sqrt` and `rsqrt`: an exponent-halved seed feeding a shared Newton loop on the inverse
square root, which `sqrt_newton` closes with one multiply and `rsqrt_newton` reads directly.
"""

from __future__ import annotations

from .._isa import _SE, _c, _Tmpl
from ..idiom_registry import register_idiom


def _sqrt_newton_iterate(
    *,
    s: int,
    zero: int,
    half: int,
    three_halves: int,
    seed_c: int,
    exp: int,
    xh: int,
    y: int,
    t: int,
    u: int,
    steps: int,
    slice_en: int = _SE,
) -> list[_Tmpl]:
    """The exponent-halved seed and the Newton loop `sqrt_newton`/`rsqrt_newton` share: both converge the
    SAME quantity into `y`, `1/sqrt(s)`, and differ only in what a caller does with it once it has --
    `sqrt_newton` multiplies by `s`, `rsqrt_newton` reads it as its own answer."""
    step = []
    for _ in range(steps):
        step += [
            _c(
                "FMA",
                src0=y,
                src1=y,
                src2=zero,
                lrf_tgt=t,
                out_sp=0,
                slice_en=slice_en,
                be=0,
            ),
            _c(
                "FNMS",
                src0=xh,
                src1=t,
                src2=three_halves,
                lrf_tgt=u,
                out_sp=0,
                slice_en=slice_en,
                be=0,
            ),
            _c(
                "FMA",
                src0=y,
                src1=u,
                src2=zero,
                lrf_tgt=y,
                out_sp=0,
                slice_en=slice_en,
                be=0,
            ),
        ]
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
            "SHR",
            src0=exp,
            src1=1,
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
            src2=seed_c,
            lrf_tgt=y,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
        _c(
            "FMA",
            src0=s,
            src1=half,
            src2=zero,
            lrf_tgt=xh,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        ),
    ] + step


# sqrt carries one more register than recip: it precomputes `s/2` so each Newton step costs three instructions
# rather than four, and it holds `y` across the steps where recip reuses its seed slot.
#
# 0.625 is the seed centring constant, not a tuning knob: a floor-halved exponent lands outside Newton's basin
# for a large fraction of inputs, and this slides it inside. See `sqrt_newton`'s own docstring for the
# measurement.
#
# It reads `s` three times -- EE, then `s/2`, then the final `s * y` -- which is why this registers
# `multi_read=True`.
@register_idiom(
    "sqrt",
    scratch=("scratch.exp", "scratch.xh", "scratch.y", "scratch.t", "scratch.u"),
    consts=(("half", 0.5), ("three_halves", 1.5), ("seed_c", 0.625)),
    multi_read=True,
    operand="s",
)
def sqrt_newton(
    *,
    s: int,
    zero: int,
    half: int,
    three_halves: int,
    seed_c: int,
    exp: int,
    xh: int,
    y: int,
    t: int,
    u: int,
    out: int,
    steps: int = 4,
    slice_en: int = _SE,
) -> list[_Tmpl]:
    """`out = sqrt(s)`: an exponent-halved seed, then Newton on the INVERSE square root, then one multiply.

    It cannot follow `recip_newton`, and the reason is a hardware fact rather than a preference. That idiom
    seeds itself with `FEST`, whose mode is chosen by `src1`, and the estimate unit offers ten modes -- two
    fractional powers of two, a reciprocal, two logs, a small reciprocal LUT, and sigmoid and tanh slope and
    offset. There is NO inverse-square-root mode, and `default:` falls back to mode 0. So the seed has to be
    built.

    The seed is an exponent, halved. `EE` yields the exponent as an integer, `SHR` by one halves it, and
    `IME(imm=2)` scales by `2^-e`, which together give `2^-floor(e/2)`. That is within a factor of two of
    `1/sqrt(s)`, and a factor of two is too far: Newton on the inverse square root converges only for
    `y < sqrt(3/s)`, about 1.732 times the answer, while a floor-halved exponent spans [1.000, 1.999] times it
    -- measured over 40k dlf16 values. So a large fraction of inputs DIVERGE, and they do not fail loudly:
    they settle at three times the answer, which is a plausible number.

    One multiply fixes it. Scaling the seed by `seed_c` slides the whole span inside the basin, and 0.625 is
    the value to pass: it is exactly representable in dlf16, it leaves nothing outside the basin, and it
    converges fastest of the values tried (4.8e-3 at three steps against 2.0e-2 at 0.707). At four steps it
    reaches 2.2e-3 relative, which is 2.3x the dlf16 representation floor of 9.8e-4 -- further steps do not
    improve it, because the iteration has reached the grid.

    The iteration is `y <- y * (1.5 - (s/2) * y^2)`, which is the standard `y * (3 - s*y^2) / 2` with the half
    folded into a precomputed `s/2` and the constant. That saves one instruction per step, three instead of
    four, and `s/2` is exact in binary floating point so it costs no accuracy.

    Why not `2^(0.5 * log2 s)`, which the estimate unit could seed directly with its log mode: at an IDEALISED
    exact log and exact power it reaches 3.3e-3, already worse than this, and the real form would compose the
    log LUT with the `exp_2pow` idiom, whose own tolerance is 3e-2. Two approximations multiply."""
    return _sqrt_newton_iterate(
        s=s,
        zero=zero,
        half=half,
        three_halves=three_halves,
        seed_c=seed_c,
        exp=exp,
        xh=xh,
        y=y,
        t=t,
        u=u,
        steps=steps,
        slice_en=slice_en,
    ) + [
        _c(
            "FMA",
            src0=s,
            src1=y,
            src2=zero,
            lrf_tgt=out,
            out_sp=0,
            slice_en=slice_en,
            be=0,
        )
    ]
