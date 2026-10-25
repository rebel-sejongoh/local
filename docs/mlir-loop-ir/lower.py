"""A prototype of the fused-loop-IR lowering in `../mlir-loop-ir.md`.

    python3 lower.py            # lower every example, print what the lowering inserts and what it rejects

It lowers pipelines in the canonical form (perfect nests, every op in an innermost body). It models
only what the lowering decides: loops with static trip counts; ops with the SSA values they define and
use; the SP and SHM buffers they read and write, each with the loops whose index addresses it. For each example it
checks the fused-IR constraints (as F1–F5), assigns units, inserts the FIFOs, the register latches and the sync channels, and
runs the machine-IR checks it can decide here (P5, and P2 by construction). It does not produce addresses,
registers or code.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# ----------------------------------------------------------------------------- model


@dataclass
class Op:
    name: str                                                        # e.g. "splu.load", "vu.fma", "mxu.matmul"
    defs: list[str] = field(default_factory=list)
    uses: list[str] = field(default_factory=list)
    writes: list[tuple[str, set[str]]] = field(default_factory=list)  # (buffer, loops whose index addresses it)
    reads: list[tuple[str, set[str]]] = field(default_factory=list)
    carried: list[str] = field(default_factory=list)                 # loop-carried registers it updates
    rows: int = 1                                                    # lines per value: one burst / unroll
    note: str = ""


@dataclass
class Loop:
    name: str
    trip: int
    body: list


def unit_of(op: Op) -> str:
    return op.name.split(".")[0].upper()                             # nclu.load -> NCLU, vu.fma -> VU, ...


def sp_reader(op: Op) -> str:
    """The unit that reads SP for an op."""
    return unit_of(op)


# The links a FIFO can follow. The SPLU reaches the MXU and the SPSU through the XVU.
LINKS = {("SPLU", "XVU"), ("SPLU", "VU"), ("XVU", "MXU"), ("XVU", "VU"), ("XVU", "SPSU"),
         ("MXU", "VU"), ("VU", "SPSU"), ("VU", "XVU")}
ROUTE = {("SPLU", "MXU"): ["SPLU", "XVU", "MXU"], ("SPLU", "SPSU"): ["SPLU", "XVU", "SPSU"]}


def walk(body):
    """(op, enclosing loops outer -> inner, position) in program order."""
    pos = [0]

    def rec(b, ls):
        for x in b:
            if isinstance(x, Loop):
                yield from rec(x.body, ls + (x,))
            else:
                pos[0] += 1
                yield x, ls, pos[0]

    yield from rec(body, ())


def common(a, b):
    out = []
    for x, y in zip(a, b):
        if x is not y:
            break
        out.append(x)
    return out


def names(ls):
    return [l.name for l in ls]


# ----------------------------------------------------------------------------- lowering


def lower(name, body, shm_in, shm_out):
    ops = list(walk(body))
    errors, notes = [], []
    fifos, latches, channels, mxu = [], [], [], []
    defs = {v: (op, ls, p) for op, ls, p in ops for v in op.defs}

    # F2, F3, F4: SSA values between units become FIFOs along a link; a use deeper than the definition is a
    # broadcast, which the consumer latches into a register once per defining iteration
    for op, ls, p in ops:
        if op.rows not in (1, 2, 4, 8):                   # one instruction: a burst, unroll_degree, or AB block
            errors.append(f"`{op.name}` on {op.rows} lines: a tile is 1, 2, 4 or 8 lines")
        for v in op.uses:
            if v not in defs:
                continue                                  # a constant or a register set before the pipeline
            d, dls, _ = defs[v]
            du, uu = unit_of(d), unit_of(op)
            if du == uu:
                continue                                  # a register of one unit, may cross loops (F2)
            dn, un = names(dls), names(ls)
            if un[: len(dn)] != dn:
                errors.append(f"F3 `{v}`: defined by {d.name} ({du}) under {dn}, used by {op.name} ({uu}) under "
                              f"{un}: the use is outside the defining iteration")
                continue
            path = ROUTE.get((du, uu), [du, uu])
            for a, b in zip(path, path[1:]):
                if (a, b) not in LINKS:
                    errors.append(f"F4 `{v}`: no link {a} -> {b}")
            fifos.append((v, path, dn))
            if len(un) > len(dn):
                latches.append((v, uu, dn[-1] if dn else "pipeline"))
                if uu == "MXU":                           # a latched weight tile: the inner loops reuse it
                    tiles = 1
                    for l in ls[len(dls):]:
                        tiles *= l.trip
                    mxu.append((v, dn[-1] if dn else "pipeline", tiles, op.rows))

    # F1: SHM read only or written only; an SP buffer has one writer unit and one reader unit, every read reads
    # what a write of the same iteration wrote, and a rewrite in a later iteration gets a release channel
    bufs = {}
    for op, ls, p in ops:
        for b, ix in op.writes:
            bufs.setdefault(b, {"w": [], "r": []})["w"].append((op, ls, p, ix))
        for b, ix in op.reads:
            bufs.setdefault(b, {"w": [], "r": []})["r"].append((op, ls, p, ix))
    for b, acc in bufs.items():
        if b in shm_in or b in shm_out:
            if acc["w"] and acc["r"]:
                errors.append(f"F1 SHM `{b}` is read and written")
            continue
        wunits = {unit_of(o) for o, *_ in acc["w"]}
        runits = {sp_reader(o) for o, *_ in acc["r"]}
        if not wunits or not runits:
            notes.append(f"SP `{b}` is {'only read: written by an earlier' if runits else 'only written: read by a later'} pipeline")
            continue
        if len(wunits) != 1 or len(runits) != 1:
            errors.append(f"F1 SP `{b}`: writers {sorted(wunits)}, readers {sorted(runits)}: one of each")
            continue
        (wu,), (ru,) = wunits, runits
        for wo, wls, wp, wix in acc["w"]:
            for ro, rls, rp, rix in acc["r"]:
                c = common(wls, rls)
                cross = [l.name for l in c if (l.name in wix) != (l.name in rix)]
                if cross:
                    errors.append(f"F1 SP `{b}`: {ro.name} reads what {wo.name} wrote in another iteration of {cross}")
                    continue
                if rp < wp:
                    errors.append(f"F1 SP `{b}`: {ro.name} reads before the {wo.name} of the same iteration "
                                  f"(a value carried through memory)")
                    continue
                at = c[-1].name if c else "pipeline"
                # the channel's ops sit directly in L's body: after the statement there that holds the write (the
                # write or a loop around it) and before the one that holds the read
                wst = f"loop `{wls[len(c)].name}`" if len(wls) > len(c) else wo.name
                rst = f"loop `{rls[len(c)].name}`" if len(rls) > len(c) else ro.name
                channels.append((f"{b}.ready", wu, ru, at, f"put after {wst}, get before {rst}"))
                # a write address without the index of a loop around both rewrites the lines in a later
                # iteration: the writer waits for the reader, with one credit put at the pipeline's start
                rewrite = [l.name for l in c if l.name not in wix]
                if rewrite:
                    channels.append((f"{b}.free", ru, wu, at,
                                     f"put after {rst}, get before {wst}; rewritten across {rewrite}"))
    channels = list(dict.fromkeys(channels))

    # P5: no cycle through FIFOs and ready channels
    edges = {e for _, path, _ in fifos for e in zip(path, path[1:])}
    edges |= {(a, b) for c, a, b, *_ in channels if c.endswith(".ready")}
    cyc = find_cycle(edges)
    if cyc:
        errors.append("P5 cycle " + " -> ".join(cyc) + ": cut the pipeline")

    regs = {}
    for op, ls, p in ops:
        for v in op.carried:
            regs.setdefault(unit_of(op), set()).add(v)
    return dict(name=name, errors=errors, notes=notes, fifos=fifos, latches=latches, channels=channels, mxu=mxu,
                regs=regs)


def find_cycle(edges):
    g = {}
    for a, b in sorted(edges):
        g.setdefault(a, []).append(b)
    state, stack = {}, []

    def dfs(u):
        state[u] = 1
        stack.append(u)
        for v in g.get(u, []):
            if state.get(v) == 1:
                return stack[stack.index(v):] + [v]
            if not state.get(v):
                r = dfs(v)
                if r:
                    return r
        state[u] = 2
        stack.pop()
        return None

    for u in list(g):
        if not state.get(u):
            r = dfs(u)
            if r:
                return r
    return None


def show(res):
    print(f"=== {res['name']}: {'NOT LOWERABLE' if res['errors'] else 'lowerable'}")
    for e in res["errors"]:
        print("    error ", e)
    if not res["errors"]:
        for v, path, ls in res["fifos"]:
            print(f"    fifo   {' -> '.join(path):<20} `{v}`, once per iteration of `{ls[-1] if ls else 'pipeline'}`")
        for v, u, at in res["latches"]:
            print(f"    latch  `{v}` into a {u} register once per `{at}`, reused by the loops inside")
        for b, at, tiles, m_rows in res["mxu"]:
            print(f"    mxu    weight tile `{b}` latched once per `{at}`: "
                  f"mxu.matmul {{tiles = {tiles}, m_rows = {m_rows}}}")
        for c, a, b, at, how in res["channels"]:
            print(f"    chan   {c:<12} {a} -> {b:<5} per iteration of `{at}`: {how}")
        for u, vs in sorted(res["regs"].items()):
            print(f"    regs   {u} carries {sorted(vs)} across iterations")
    for n in res["notes"]:
        print("    note  ", n)


# ----------------------------------------------------------------------------- examples


def ex_elementwise():
    # y = exp(x) · 0.5 + r, DNC d's 128 rows in 8 chunks of 16 lines, one line per iteration of `l`
    return "elementwise: y = exp(x)·0.5 + r", [
        Loop("c", 8, [
            Loop("l", 16, [
                Op("nclu.load", writes=[("sp_x", {"c", "l"})], reads=[("x", {"c", "l"})]),
                Op("nclu.load", writes=[("sp_r", {"c", "l"})], reads=[("r", {"c", "l"})]),
                Op("splu.load", defs=["xl"], reads=[("sp_x", {"c", "l"})]),
                Op("splu.load", defs=["rl"], reads=[("sp_r", {"c", "l"})]),
                Op("vu.exp", defs=["e"], uses=["xl"]),
                Op("vu.fma", defs=["yl"], uses=["e", "rl"]),
                Op("spsu.store", uses=["yl"], writes=[("sp_y", {"c", "l"})]),
                Op("ncsu.store", reads=[("sp_y", {"c", "l"})], writes=[("y", {"c", "l"})]),
            ]),
        ])], {"x", "r"}, {"y"}


def ex_elementwise_band():
    # the same with one 16-line SP band per tensor, reused by every chunk
    return "elementwise, one SP band per tensor", [
        Loop("c", 8, [
            Loop("l", 16, [
                Op("nclu.load", writes=[("sp_x", {"l"})], reads=[("x", {"c", "l"})]),
                Op("splu.load", defs=["xl"], reads=[("sp_x", {"l"})]),
                Op("vu.exp", defs=["yl"], uses=["xl"]),
                Op("spsu.store", uses=["yl"], writes=[("sp_y", {"l"})]),
                Op("ncsu.store", reads=[("sp_y", {"l"})], writes=[("y", {"c", "l"})]),
            ]),
        ])], {"x"}, {"y"}


def ex_matmul():
    # y = relu(x @ w + bias), DNC d's 128 rows over 2 NCores; partial sums of a group of 4 tiles in VU registers.
    # Canonical form: every transfer in the innermost body that uses it. `nc` is spatial (one iteration per
    # NCore); the model treats it as a loop, and the SP buffers written inside it are indexed by it.
    return "matmul + epilogue (the running example)", [
        Loop("nc", 2, [Loop("nb", 4, [
            Loop("g", 4, [
                Loop("i0", 4, [Op("vu.reg_write", defs=["acc"], carried=["acc"], rows=4)]),
                Loop("kb", 8, [
                    Loop("i", 4, [                         # tile i: 4 lines (vector<4x64xdlf16>)
                        Op("nclu.load", writes=[("sp_w", {"nc", "nb", "kb"})], reads=[("w", {"nb", "kb"})]),
                        Op("nclu.load", writes=[("sp_x", {"kb", "nc", "g", "i"})], reads=[("x", {"kb", "nc", "g", "i"})]),
                        Op("splu.load", defs=["wt"], reads=[("sp_w", {"nc", "nb", "kb"})]),
                        Op("splu.load", defs=["xt"], reads=[("sp_x", {"kb", "nc", "g", "i"})], rows=4),
                        Op("mxu.matmul", defs=["p"], uses=["wt", "xt"], rows=4),
                        Op("vu.fma", defs=["acc"], uses=["p", "acc"], carried=["acc"], rows=4),
                    ]),
                ]),
                Loop("o", 4, [
                    Op("nclu.load", writes=[("sp_b", {"nc", "nb"})], reads=[("bias", {"nb"})]),
                    Op("splu.load", defs=["bl"], reads=[("sp_b", {"nc", "nb"})]),
                    Op("vu.fma", defs=["yb"], uses=["acc", "bl"], rows=4),
                    Op("vu.max", defs=["yr"], uses=["yb"], rows=4),
                    Op("spsu.store", uses=["yr"], writes=[("sp_y", {"nb", "nc", "g", "o"})], rows=4),
                    Op("ncsu.store", reads=[("sp_y", {"nb", "nc", "g", "o"})], writes=[("y", {"nb", "nc", "g", "o"})]),
                ]),
            ]),
        ])]),
    ], {"x", "w", "bias"}, {"y"}


def ex_rmsnorm():
    # y = x · rsqrt(mean(x²) + eps) · gamma for x[128, 512]: two passes over SP, 8 rows per group; the
    # statistics (8 VU registers, then rewritten in place by the 8 inverses) stay in the VU
    return "rmsnorm: two passes over SP", [
        Loop("g", 16, [
            Loop("r0", 8, [Op("vu.reg_write", defs=["ss"], carried=["ss"])]),
            Loop("kb", 8, [
                Loop("r", 8, [
                    Op("nclu.load", writes=[("sp_x", {"g", "kb", "r"})], reads=[("x", {"g", "kb", "r"})]),
                    Op("splu.load", defs=["xl"], reads=[("sp_x", {"g", "kb", "r"})]),
                    Op("vu.fma", defs=["ss"], uses=["xl", "ss"], carried=["ss"]),
                ]),
            ]),
            Loop("r2", 8, [Op("vu.rsqrt_mean", defs=["inv"], uses=["ss"], carried=["inv"])]),
            Loop("kb2", 8, [
                Loop("r3", 8, [
                    Op("nclu.load", writes=[("sp_g", {"kb2"})], reads=[("gamma", {"kb2"})]),
                    Op("splu.load", defs=["gl"], reads=[("sp_g", {"kb2"})]),
                    Op("splu.load", defs=["xl2"], reads=[("sp_x", {"g", "kb2", "r3"})]),
                    Op("vu.fma", defs=["t"], uses=["xl2", "inv"]),
                    Op("vu.fma", defs=["yl"], uses=["t", "gl"]),
                    Op("spsu.store", uses=["yl"], writes=[("sp_y", {"g", "kb2", "r3"})]),
                    Op("ncsu.store", reads=[("sp_y", {"g", "kb2", "r3"})], writes=[("y", {"g", "kb2", "r3"})]),
                ]),
            ]),
        ]),
    ], {"x", "gamma"}, {"y"}


def ex_sp_psum():
    # matmul with the partial sums in SP (variant A): sp_p is read and rewritten every K block
    return "matmul with SP partial sums", [
        Loop("kb", 8, [
            Loop("t", 32, [
                Op("splu.load", defs=["xt"], reads=[("sp_x", {"kb", "t"})]),
                Op("splu.load", defs=["wt"], reads=[("sp_w", {"kb"})]),
                Op("mxu.matmul", defs=["p"], uses=["wt", "xt"]),
                Op("splu.load", defs=["old"], reads=[("sp_p", {"t"})]),
                Op("vu.fma", defs=["new"], uses=["p", "old"]),
                Op("spsu.store", uses=["new"], writes=[("sp_p", {"t"})]),
            ]),
        ]),
    ], set(), set()


def ex_norm_then_matmul():
    # rmsnorm's output fed to a matmul through SP in the same pipeline
    return "rmsnorm -> matmul in one pipeline", [
        Loop("g", 8, [
            Loop("kb", 8, [
                Op("splu.load", defs=["xl"], reads=[("sp_x", {"g", "kb"})]),
                Op("vu.fma", defs=["yl"], uses=["xl"]),
                Op("spsu.store", uses=["yl"], writes=[("sp_xn", {"g", "kb"})]),
                Op("splu.load", defs=["xn"], reads=[("sp_xn", {"g", "kb"})]),
                Op("splu.load", defs=["wt"], reads=[("sp_w", {"kb"})]),
                Op("mxu.matmul", defs=["p"], uses=["wt", "xn"]),
                Op("vu.fma", defs=["acc"], uses=["p", "acc"], carried=["acc"]),
            ]),
        ]),
    ], set(), set()


def ex_transpose():
    # rows written to SP, then read back as columns in the same iteration
    return "transpose through SP", [
        Loop("t", 8, [
            Loop("r", 64, [
                Op("splu.load", defs=["xl"], reads=[("sp_x", {"t", "r"})]),
                Op("spsu.store", uses=["xl"], writes=[("sp_t", {"t", "r"})]),
            ]),
            Loop("c", 64, [
                Op("splu.load", defs=["col"], reads=[("sp_t", {"t", "c"})]),
                Op("spsu.store", uses=["col"], writes=[("sp_o", {"t", "c"})]),
            ]),
        ]),
    ], set(), set()


EXAMPLES = (ex_elementwise, ex_elementwise_band, ex_matmul, ex_rmsnorm, ex_sp_psum, ex_norm_then_matmul,
            ex_transpose)

if __name__ == "__main__":
    for ex in EXAMPLES:
        n, b, si, so = ex()
        show(lower(n, b, si, so))
        print()
