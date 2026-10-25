"""Template: reduce over one axis of a DNC grid, emitted as per-DNC assembly fragments (new dnc_binutils syntax).

    python grid_reduce_template.py                      # the down_proj example: grid (m=4, k=4), reduce over k
    python grid_reduce_template.py --shape 2,2,4 --names c,h,k --axis k --algo batched

The collective is

    grid.reduce %p on @D axes=[axis] kind=add root=(axis = root)

Groups are the grid points that differ only in `axis`; each group has one root, and every other member is a leaf.
The code follows mcc's star reduce (the root gathers every leaf in one level), as in down_proj_m4_k256_n64.asm:

    leaf  NCSU  STSU SP psum -> SHM slot ; MESYNC {put, get} with root.NCLU  ("ready", then wait for "taken")
    root  NCLU  per leaf: MESYNC get leaf.NCSU ; LDMU slot -> SP gather ; SYNC put SPLU ; MESYNC put leaf.NCSU
          SPLU  per leaf: SYNC get NCLU ; LDU a tile-row window -> VU
          VU    per leaf: acc[t] += pop(SPLU)                     (acc already holds the local partial)
          SPSU  store acc -> SP psum ; SYNC put NCSU
          NCSU  SYNC get SPSU ; STSU SP psum -> SHM out

`--algo batched` waits for all leaves with one MESYNC (several peer bits), loads all slots with one LDMU and
releases them with one MESYNC. Fewer syncs, but nothing starts before the last leaf arrives. Not run on the VP.

Address conventions are this kernel's (verified on DNC 0/1 of the down_proj image):
  * NC descriptor LRF word: SAR[14:0] | SBR[31:16] | CAR[51:32] | CBR[83:64]; SHM lines carry tag 0x8 in bits [19:16]
    of CBR/CAR. LDMU reads SP[SBR+SAR] <- SHM[CBR+CAR], then advances SAR and CAR.
  * STSU adds the stride pair (descriptor 0: SBR = CBR = 1) first, so its SAR/CAR start one line before.
  * SP units hold byte addresses; IMMCOPY / MODLRFIMM immediates are the byte value >> 1; LDU adds the stride first.

The sync checker models every SYNC / MESYNC the template emits as a counting channel (put never blocks; get waits for
a token; put+get does the put first) and runs all units until they finish or deadlock. It checks only the template's
own syncs; the rest of each unit program (the compute that produces the local partial) is assumed balanced.
"""

from __future__ import annotations

import argparse
import itertools
import re
from dataclasses import dataclass, field

SHM_TAG = 0x80000          # CBR/CAR bits [19:16] = 0x8 mark an SHM line
SP_LINE = 0x80             # bytes per SP line
NC_UNITS = ("nclu", "ncsu")


# ───────────────────────────── grid and groups ─────────────────────────────

@dataclass(frozen=True)
class Grid:
    shape: tuple[int, ...]
    names: tuple[str, ...]
    dncs_per_cluster: int = 8

    def points(self):
        return list(itertools.product(*(range(n) for n in self.shape)))

    def dnc(self, p) -> int:
        """Logical point -> physical DNC id: row-major, which is how mcc numbers d = 4m + k."""
        d = 0
        for i, n in zip(p, self.shape):
            d = d * n + i
        return d

    def cluster(self, p) -> int:
        return self.dnc(p) // self.dncs_per_cluster


@dataclass
class Group:
    index: int                      # linear index over the non-reduced axes
    root: tuple
    leaves: list                    # in reduce order (axis coordinate ascending, root skipped)


def groups_of(grid: Grid, axis: str, root_at: int) -> list[Group]:
    a = grid.names.index(axis)
    others = [i for i in range(len(grid.shape)) if i != a]
    out = []
    for gi, fixed in enumerate(itertools.product(*(range(grid.shape[i]) for i in others))):
        def point(c):
            p = [0] * len(grid.shape)
            for i, v in zip(others, fixed):
                p[i] = v
            p[a] = c
            return tuple(p)
        members = [point(c) for c in range(grid.shape[a])]
        root = point(root_at)
        out.append(Group(gi, root, [p for p in members if p != root]))
    return out


# ───────────────────────────── encodings ─────────────────────────────

def nc_desc(sar=0, sbr=0, car=0, cbr=0) -> int:
    return (cbr << 64) | (car << 32) | (sbr << 16) | sar


def imm21(byte_delta: int) -> int:
    """MODLRFIMM immediate: (byte delta >> 1) in 21-bit two's complement."""
    return (byte_delta >> 1) & 0x1FFFFF


def mesync(peers: list[int], unit: str, put=False, get=False) -> str:
    dirs = [f"dir.{d}=1" for d, on in (("get", get), ("put", put)) if on]
    bits = [f"sync_mask.dnc{d}=1" for d in sorted(peers, reverse=True)]
    return "MESYNC {" + ", ".join(dirs + bits + [f"sync_mask.{unit}=1"]) + "}"


def sync(peer: str, put=False, get=False) -> str:
    dirs = [f"dir.{d}=1" for d, on in (("get", get), ("put", put)) if on]
    return "SYNC {" + ", ".join(dirs + [f"lsync_mask.{peer}=1"]) + "}"


# ───────────────────────────── emit ─────────────────────────────

@dataclass
class Layout:
    slot_base: int = 0x114      # SHM: leaf partial slots, (group, leaf order) packed
    out_base: int = 0x110       # SHM: reduced line of group g at out_base + g
    psum_line: int = 0x419      # SP: where SPSU stores acc (first line of the tile)
    gather_line: int = 0x421    # SP: where the root lands the gathered partials
    tile_rows: int = 4          # rows the VU accumulates per step (mcc's Tr); line 0 is the real row


@dataclass
class DncCode:
    dnc: int
    role: str
    units: dict = field(default_factory=dict)      # unit -> (directives, instructions)


def emit(grid: Grid, axis: str, root_at: int, lay: Layout, algo: str = "star") -> dict[int, DncCode]:
    code = {}
    groups = groups_of(grid, axis, root_at)
    n_leaf = len(groups[0].leaves)
    deg = (lay.tile_rows - 1).bit_length()          # unroll degree: 2**deg = tile_rows
    for g in groups:
        root = grid.dnc(g.root)
        leaves = [grid.dnc(p) for p in g.leaves]
        if len({grid.cluster(p) for p in [g.root, *g.leaves]}) > 1:
            print(f"warning: group {g.index} spans clusters ({root}, {leaves}); mcc does not build this")
        slot0 = lay.slot_base + g.index * n_leaf

        # leaf: store the local partial line, announce it, wait until the root took it
        for j, leaf in enumerate(leaves):
            c = DncCode(leaf, f"leaf {j + 1} of group {g.index} (root DNC {root})")
            c.units["ncsu"] = (
                [".lrf_idx 0 8",
                 f".lrf {hex(nc_desc(sbr=1, cbr=1))} {hex(nc_desc(car=SHM_TAG | (slot0 + j - 1)))}"],
                ["CXRREGCOPY src0=CAR11, src1=CAR8",
                 f"SXRIMM src0=SAR11, immediate={hex(lay.psum_line - 1)}",
                 sync("spsu0", get=True),                                   # local partial stored to SP
                 "STSU src0=SAR11, src1=SBR0, src2=CAR11, src3=CBR0 {burst=1}",
                 mesync([root], "nclu", put=True, get=True)])
            c.units["spsu"] = ([], [sync("ncsu", put=True)])               # the local store's done signal
            code[leaf] = c

        # root: gather, accumulate, store the reduced line
        c = DncCode(root, f"root of group {g.index} (leaves {leaves})")
        gdesc = hex(nc_desc(sbr=lay.gather_line, cbr=SHM_TAG | slot0))
        nclu = []
        if algo == "star":
            for leaf in leaves:
                nclu += [mesync([leaf], "ncsu", get=True),
                         "LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1}",
                         sync("splu0", put=True),
                         mesync([leaf], "ncsu", put=True)]
        else:                                                               # batched
            nclu += [mesync(leaves, "ncsu", get=True),
                     f"MVLOOPCNT immediate={n_leaf}",
                     "  LDMU src0=SAR4, src1=SBR4, src2=CAR4, src3=CBR4 {burst=1, be=1}",
                     sync("splu0", put=True),
                     mesync(leaves, "ncsu", put=True)]
        c.units["nclu"] = ([".lrf_idx 4", f".lrf {gdesc}"], nclu)

        win = lay.tile_rows
        splu = [f"IMMCOPY src0=LRF11, immediate={hex(((lay.gather_line - 1) * SP_LINE) >> 1)}"]
        for s in range(len(leaves)):
            if algo == "star" or s == 0:
                splu.append(sync("nclu", get=True))
            splu.append(f"LDU consumer=VU, src0=LRF11, src1=LRF10 {{burst=1, burst_size={win}}}")
            if s < len(leaves) - 1:
                splu.append(f"MODLRFIMM src0=LRF11, immediate={hex(imm21(-(win - 1) * SP_LINE))}")
        c.units["splu"] = ([".lrf_idx 10", f".lrf {hex(SP_LINE)}"], splu)

        acc = (f"FMA lrf_tgt=LRF4, xvu_tgt=NONE, sp_tgt=NONE, src0=FIFO_SPLU, src1=CONST4, src2=LRF4 "
               f"{{unroll_control.lrf_tgt=1, unroll_control.src2=1, unroll_control.degree={deg}}}")
        store = (f"FMA lrf_tgt=NONE, xvu_tgt=NONE, sp_tgt=RESULT, src0=LRF4, src1=CONST4, src2=CONST0 "
                 f"{{unroll_control.src0=1, unroll_control.degree={deg}}}")
        c.units["vu"] = ([], [acc] * len(leaves) + [store])

        c.units["spsu"] = (
            [".lrf_idx 1 15", f".lrf {hex((lay.psum_line - 1) * SP_LINE)} {hex(SP_LINE)}"],
            ["LRFREGCOPY src0=LRF0, src1=LRF1",
             f"STU producer=VU, src0=LRF0, src1=LRF15 {{burst=1, burst_size={win}}}",
             sync("ncsu", put=True)])
        c.units["ncsu"] = (
            [".lrf_idx 0 8",
             f".lrf {hex(nc_desc(sbr=1, cbr=1))} {hex(nc_desc(car=SHM_TAG | (lay.out_base + g.index - 1)))}"],
            ["CXRREGCOPY src0=CAR11, src1=CAR8",
             f"SXRIMM src0=SAR11, immediate={hex(lay.psum_line - 1)}",
             sync("spsu0", get=True),
             "STSU src0=SAR11, src1=SBR0, src2=CAR11, src3=CBR0 {burst=1}"])
        code[root] = c
    return code


# ───────────────────────────── sync check ─────────────────────────────

def sync_ops(dnc: int, unit: str, line: str):
    """The template's SYNC / MESYNC line as [(op, channel)], channel = (src dnc, src unit, dst dnc, dst unit)."""
    s = line.strip()
    if not (s.startswith("SYNC") or s.startswith("MESYNC")):
        return []
    put, get = "dir.put=1" in s, "dir.get=1" in s
    if s.startswith("MESYNC"):
        peer_unit = "nclu" if "sync_mask.nclu=1" in s else "ncsu"
        peers = [int(x) for x in re.findall(r"sync_mask\.dnc(\d+)=1", s)]
        targets = [(p, peer_unit) for p in peers]
    else:
        peer = re.search(r"lsync_mask\.(\w+)=1", s).group(1)
        peer = {"splu0": "splu", "spsu0": "spsu"}.get(peer, peer)
        targets = [(dnc, peer)]
    ops = [("put", (dnc, unit, d, u)) for d, u in targets] if put else []
    ops += [("get", (d, u, dnc, unit)) for d, u in targets] if get else []
    return ops


def check(code: dict[int, DncCode]) -> list[str]:
    progs = {}
    for c in code.values():
        for unit, (_, body) in c.units.items():
            progs[(c.dnc, unit)] = [op for line in body for op in sync_ops(c.dnc, unit, line)]
    tokens, pc = {}, {k: 0 for k in progs}
    moved = True
    while moved:
        moved = False
        for k, ops in progs.items():
            while pc[k] < len(ops):
                op, ch = ops[pc[k]]
                if op == "put":
                    tokens[ch] = tokens.get(ch, 0) + 1
                elif tokens.get(ch, 0) > 0:
                    tokens[ch] -= 1
                else:
                    break
                pc[k] += 1
                moved = True
    errs = [f"deadlock: DNC {k[0]} {k[1].upper()} waits at sync #{pc[k]} on {progs[k][pc[k]][1]}"
            for k in progs if pc[k] < len(progs[k])]
    errs += [f"unbalanced: {n} token(s) left on {ch}" for ch, n in tokens.items() if n]
    return errs


# ───────────────────────────── main ─────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--shape", default="4,4")
    ap.add_argument("--names", default="m,k")
    ap.add_argument("--axis", default="k")
    ap.add_argument("--root", type=int, default=0)
    ap.add_argument("--algo", choices=("star", "batched"), default="star")
    ap.add_argument("--dnc", type=int, nargs="*", help="print only these DNCs (default: the first group)")
    a = ap.parse_args()
    grid = Grid(tuple(int(x) for x in a.shape.split(",")), tuple(a.names.split(",")))
    code = emit(grid, a.axis, a.root, Layout(), a.algo)

    groups = groups_of(grid, a.axis, a.root)
    print(f"// grid {dict(zip(grid.names, grid.shape))}, reduce over {a.axis}, root {a.axis}={a.root}, algo {a.algo}")
    for g in groups:
        print(f"//   group {g.index}: root DNC {grid.dnc(g.root)}, leaves {[grid.dnc(p) for p in g.leaves]}")
    errs = check(code)
    print("// sync check: " + ("ok (every channel balanced, no deadlock)" if not errs else "; ".join(errs)))

    show = a.dnc if a.dnc else [grid.dnc(groups[0].root)] + [grid.dnc(p) for p in groups[0].leaves[:1]]
    for d in show:
        c = code[d]
        print(f"\n// ===== DNC {d}: {c.role} =====")
        for unit in ("nclu", "splu", "vu", "spsu", "ncsu"):
            if unit not in c.units:
                continue
            dirs, body = c.units[unit]
            print(f".text_{unit}   // reduce fragment; splice into the unit program after the local partial")
            for line in dirs + body:
                print(line)


if __name__ == "__main__":
    main()
