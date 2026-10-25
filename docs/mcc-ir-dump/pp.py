"""Compact printers for mcc IR levels that have none."""
from mcc.grounding import mseq as M
from mcc.grounding import mpn as P
from mcc.ir import nodes as N, jir as J

def ex(e):
    if e.kind == "input": return f"{e.name}:in[{','.join(e.axes)}]"
    if e.kind == "map": return f"{e.name}={e.op}({','.join(e.deps)}{'' if e.imm is None else ','+repr(e.imm)})"
    if e.kind == "reduce": return f"{e.name}=reduce.{e.monoid}[{e.axis}]({','.join(e.deps)})"
    return repr(e)

def ar(a):
    return "(" + "; ".join(ex(x) if hasattr(x, "kind") else str(x) for x in a) + ")"

def tk(ts, n=3):
    s = ",".join(f"{t[0]}{list(t[1:])}" for t in ts[:n])
    return s + (f",..+{len(ts)-n}" if len(ts) > n else "")

def stmt(s):
    if isinstance(s, M.Dma):
        return f"Dma {'load ' if s.dst=='SP' else 'store'} {s.tensor} shm[{s.lo}:+{s.n}{'' if s.stride==1 else ' s'+str(s.stride)}] {'->' if s.dst=='SP' else '<-'} nc{s.nc}.sp[{s.slot}:+{s.n}]"
    if isinstance(s, M.Stage):
        return f"Stage {s.unit}{s.nc} {s.tensor} sp{list(s.slots)[:4]}{'..' if len(s.slots)>4 else ''} -> {s.dst} toks={tk(s.toks)}{' splat' if s.splat else ''}{'' if s.lanes is None else ' lanes='+str(s.lanes)}"
    if isinstance(s, M.Compute):
        return f"Compute {s.unit}{s.nc} op={s.op} pop={tk(s.pops)} push={tk(s.pushes)} -> {s.to} arith={ar(s.arith) if s.arith else '()'}"
    if isinstance(s, M.Write):
        return f"Write {s.unit}{s.nc} {s.tensor} sp{list(s.slots)[:4]}{'..' if len(s.slots)>4 else ''} <- {s.src} toks={tk(s.toks)}"
    if isinstance(s, M.Reduce):
        return f"Reduce group={s.group} inst={s.instance} band={s.band} op={s.op} units={s.units} parts={len(s.parts)}"
    if isinstance(s, M.Fence):
        return f"Fence dncs={s.dncs[0]}..{s.dncs[-1]}"
    if isinstance(s, P.Put): return f"Put -> {s.peer} tok={s.token}"
    if isinstance(s, P.Get): return f"Get <- {s.peer} tok={s.token}"
    return repr(s)[:160]

def mseq(q, max_lines=60):
    out = [f"Mseq dnc={q.dnc} op={q.op} tensors={q.tensors}",
           f"  ranks={dict(q.ranks)} grid={q.grid} problems={dict(q.problems)}"]
    def walk(items, d):
        for s in items:
            p = "  " * d
            if isinstance(s, M.Loop):
                extra = " ".join(f"{k}={v}" for k, v in (("lines", dict(s.lines)), ("slots", dict(s.slots)), ("tokens", dict(s.tokens)), ("lo", s.lo), ("count", s.count), ("rows", s.rows), ("ncs", s.ncs)) if v)
                out.append(f"{p}Loop[{s.unit}] x{s.trips} {extra}")
                walk(s.body, d + 1)
            elif isinstance(s, M.Pass):
                out.append(f"{p}Pass lo={s.lo} n={s.n}")
                walk(s.body, d + 1)
            elif isinstance(s, M.Chunk):
                out.append(f"{p}Chunk lo={s.lo} n={s.n}{' via='+str(s.via) if s.via else ''}{' whole='+str(s.whole) if s.whole else ''}")
                walk(s.body, d + 1)
            else:
                out.append(p + stmt(s))
    walk(q.body, 1)
    if len(out) > max_lines:
        out = out[:max_lines] + [f"  ... ({len(out)-max_lines} more lines trimmed)"]
    return "\n".join(out)

def mpn(net, per=8):
    out = [f"Mpn dnc={net.dnc}: {len(net.processes)} processes, {len(net.channels)} channels"]
    for p in net.processes:
        out.append(f"  process {p.unit}: {len(p.body)} stmts")
        for s, w in list(zip(p.body, p.where))[:per]:
            out.append(f"    {str(w):<12} {stmt(s)}")
        if len(p.body) > per: out.append(f"    ... (+{len(p.body)-per})")
    for c in net.channels:
        out.append(f"  channel {c.producer[1]}->{c.consumer[1]} {c.transport}/{c.protocol} cap={c.capacity} depth={c.depth} in_flight={c.in_flight} tokens={len(c.produced)} first={c.produced[:3]}")
    return "\n".join(out)

def tmpl(t, d=0, max_n=30, acc=None):
    acc = [] if acc is None else acc
    for x in t:
        if len(acc) >= max_n: break
        p = "  " * d
        if isinstance(x, N._Frame):
            acc.append(f"{p}_Frame axes={x.axes} mvs={len(x.mvs)}"); tmpl(x.body, d+1, max_n, acc)
        elif isinstance(x, N._Loop):
            acc.append(f"{p}_Loop kind={x.kind} axes={x.axes} mv={x.mv} cascade={x.cascade}"); tmpl(x.body, d+1, max_n, acc)
        elif isinstance(x, N._Vocab):
            acc.append(f"{p}_Vocab {x.kind} {x.args}")
        elif isinstance(x, J.Tmpl):
            acc.append(f"{p}Tmpl {x.opcode} {{" + ", ".join(f"{k}={v}" for k, v in list(x.params.items())[:7]) + "}")
        else:
            acc.append(f"{p}{repr(x)[:150]}")
    return acc

def unit(up):
    out = [f"UnitProgram {up.unit} dnc={up.dnc} ncore={up.ncore} col={up.col} bd={getattr(up.bd,'params',up.bd)}",
           f"  boundary[{len(up.boundary)}]: " + "; ".join(f"{'MESYNC' if b.mesync else 'SYNC'} {b.role or '{}'} {b.pos}" for b in up.boundary[:4]),
           f"  env={dict(list(up.env.items())[:6])}{'...' if len(up.env)>6 else ''}",
           f"  lrf_raw[{len(up.lrf_raw)}] lccr_raw[{len(up.lccr_raw)}] framing={up.framing} fold={up.fold} loop={type(up.loop).__name__ if up.loop is not None else None}",
           f"  template ({len(up.template)} top-level nodes):"]
    out += ["    " + l for l in tmpl(up.template, max_n=14)]
    return "\n".join(out)

def fabric(fp):
    return "\n".join([f"FabricProgram units={len(fp.unit_programs)} schedule_driven={fp.schedule_driven} sp_fan={fp.sp_fan} reduces={fp.reduces} reduce_monoid={fp.reduce_monoid} mesync={type(fp.mesync).__name__} broadcast={set(fp.broadcast)} cout_spatial={fp.cout_spatial}",
        f"  units: " + ", ".join(f"{u.unit}{'' if u.ncore is None else u.ncore}@{u.dnc}" for u in fp.unit_programs[:12]) + " ...",
        f"  edges[{len(fp.edges)}]: " + "; ".join(f"{e.flavor} {e.src}->{e.dst} {e.tensor}" for e in fp.edges[:4])] +
        [f"  channel {c.id} {c.flavor} {c.src}->{c.dst} peers={c.peers} roles={c.roles} gran={c.granularity!r} fires={c.fires}" for c in fp.channels[:10]] +
        ([f"  ... (+{len(fp.channels)-10} channels)"] if len(fp.channels) > 10 else []))


def script(sc, max_lines=40):
    """A process's `script.Script`: its repetitions, syncs and statements, indented; or why it has none."""
    from mcc.grounding.script import Repetition, Script, Sync
    if not isinstance(sc, Script):
        return f"  (no Script: {sc})"
    out = [f"Script {sc.process} dnc={sc.dnc} counts={dict(sc.counts) or {}} ahead={sc.ahead} behind={sc.behind}"]
    def walk(items, d):
        for x in items:
            if len(out) > max_lines:
                return
            pad = "  " * d
            if isinstance(x, Repetition):
                cnt = f" count={x.count}" if x.count else ""
                out.append(f"{pad}Rep {x.index} x{x.trips} unit={x.unit}{cnt}")
                walk(x.body, d + 1)
            elif isinstance(x, Sync):
                dn = f" dncs={x.dncs}" if x.dncs else ""
                out.append(f"{pad}Sync {x.kind.value} {','.join(x.peers)}{dn}")
            else:
                out.append(f"{pad}{stmt(x.stmt)}")
    walk(sc.body, 1)
    if len(out) > max_lines:
        out.append("  ...")
    return "\n".join(out)
