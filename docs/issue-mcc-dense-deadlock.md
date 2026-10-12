mcc's x @ w at M=16, K=1024, N=64 deadlocks on the VP

## Motivation

- mcc's VP performance tests (#1953) compare mcc's code with code captured from rebel_compute_lib2, on the same op and shape.
- Their first dense test case is M = 16, K = 1024, N = 64 on 2 clusters × 8 DNCs, with the scale and offset of rebel_compute_lib2's dense fixed to 1 and 0 so that it is the plain `x @ w` mcc can build (#2123).
  It is `dense/m16_k1024_n64` on branch `mcc-perf-dense` (5abc76232), not merged.
- rebel_compute_lib2's code for it finishes on the VP in 1993 cycles. mcc's code builds, but on the VP no unit advances after cycle 6486 and no DNC writes its output.
  The VP then runs on to its cycle limit, 125000. A 6000-cycle run of this code took about 7 minutes, so reaching that limit would take more than two hours.

## What the VP shows

The weight stream from XVU to the TU and the activation stream from ABLU to the TU both stall, so SPSU never receives a result.
Which waits close the cycle is not known yet.

In a run left for 30 minutes, ncore0's SPLU in each of the 16 DNCs issues all 1040 of its loads, and no DNC writes through SPSU or NCSU.
mcc's code programs only ncore0, so ncore1 stays idle as expected.
Cluster 1's DNCs stop later than cluster 0's: DNC 0 stops by cycle 4436, and the last unit to advance is DNC 15's VU, at cycle 6486.
With the VP's cycle limit set to 6000, DNC 0's ncore0 stops like this:

| unit | where it stops | from cycle |
|---|---|---|
| SPLU | done: all 1040 of its loads issued | |
| XVU | PC 3, `LOGICAL ... out_tu=1`, inside the 16 × 64 loop that sends the weight lines to the TU | 4411 |
| TU0–7 | PC 3 or 5, `FMA`, in the fetch stage | 4391–4423 |
| ABLU0–7 | PC 8, `LDSTU` | 4363–4418 |
| ABSU | PC 6, `SYNC` | 4356 |
| VU | PC 8, `FMA` | 4436 |
| SPSU | PC 1, its first `SYNC`, where it stays | 99 |

The VP's last quiesce report for DNC 0, at cycle 4417, lists every ncore0 unit but SPLU as still holding work.

## The split over DNCs is not the cause

With the same split over DNCs, rebel_compute_lib2's code finishes, so the stall comes from the program mcc generates for one DNC.

- **mcc's split.** mcc splits M over the 16 DNCs: each DNC reads one row of `x` across all of K and the whole of `w`, so no DNC waits on another for a partial sum.
  mcc's 16 DNC programs are identical except for their LRF values (the addresses) and their closing `MESYNC` barrier, so DNC 0's state above stands for all of them.
- **rebel_compute_lib2, same split.** Given a tiling that splits only M (`tiling_iter=[1, 1, 16, 1, 1]`, whose third axis is M; 2 over clusters, 8 over DNCs), each of its DNCs reads exactly the SHM lines mcc's does. It finishes on the VP in 4056 cycles.
- **rebel_compute_lib2, its own tiling.** Left to choose, it splits K over the 16 DNCs instead and reduces across both clusters. That is the 1993-cycle run in Motivation.

## To reproduce

On branch `mcc-perf-dense`, from `PrimitiveAuthor/mcc`, with the VP and `LD_LIBRARY_PATH` set up as `tests/perf/scripts/run_vp.py`'s docstring says:

```bash
uv run python tests/perf/scripts/build_mcc.py dense/m16_k1024_n64 --out /tmp/dense-mcc
uv run python tests/perf/scripts/run_vp.py dense/m16_k1024_n64 --code /tmp/dense-mcc --workdir /tmp/dense-run
```

`run_vp.py` writes the VP's inputs and the assembled code into `/tmp/dense-run` before it starts the VP, so it can be interrupted once the VP is running; otherwise it times out after 1800 wall seconds. Then run the VP binary on that directory yourself with a lower cycle limit (the 6000 below). From the repository root:

```bash
cd spec_source_inventory/rebel_compute_lib2/vp
./260521_vp_rebel_evt1_arbcal /tmp/dense-run 2 8 6000 2 0 0 1 0x3f8000 1.9
```

Each unit's state is then in `/tmp/dense-run/verif_files/DebugLog__*.txt` (the `[VPP],<cycle>,<unit>,...` lines and the `QUIESCE REPORT` lines).
