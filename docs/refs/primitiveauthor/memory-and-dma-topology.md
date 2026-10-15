# Memory & DMA Topology

This note is a working map of **where data lives** in a REBEL chiplet and
**which engine is allowed to move it where**. It assembles the memory-partition
hierarchy (within and across chiplets), the three DMA engines and their
memory-scope rules, the reach of the microcode data-movers, and the
synchronization mechanisms that nest by physical distance.

Audience: an engineer who already understands *what* a command and a microcode
program are, and now needs the address-space and data-movement contract that
both are written against.

## 0. Scope — what this doc owns vs. defers

This doc owns the **memory / DMA / interconnect topology** axis. It deliberately
defers the adjacent concerns to the docs that already own them:

| Concern | Owner doc |
|---|---|
| Dispatch fabric, command types, the broadcast descriptor, MLIR→silicon | [`programming_16_dncs.md`](programming_16_dncs.md) |
| The KRT API surface and its descriptors | [`kernel-runtime.md`](../../KernelRuntime/docs/kernel-runtime.md) |
| Mover ISA internals (NCLU/SPLU records), FIFO↔XVU coupling | [`splu_xvu_fifo_contract.md`](../../dnc_spec/docs/splu_xvu_fifo_contract.md) |
| Relocation table (tag1/tag3), container layers | [`container-build-guide.md`](container-build-guide.md) |
| SoC sim as the dispatch/sync/completion oracle | [`soc-sim-reference.md`](soc-sim-reference.md) |

Hardware target: R100 / REBEL. Single chiplet = 16 DNCs (2 clusters × 8);
REBEL-Quad = 4 such chiplets. Address-map citations are from
`third_party/rebel_soc_sim/configs/rebel/rebel_common.py`.

## 1. The memory-partition hierarchy (within a chiplet)

Climbing from the compute datapath outward, each tier widens its sharing scope:
**private-per-DNC → shared-per-cluster → global-per-chiplet.** That gradient is
the reason the DMA engines split the way they do (§2).

| Tier | Partitioning | Sharing scope | Backing-store base |
|---|---|---|---|
| **FIFO / LRF** | per-DNC datapath | datapath-internal | (registers, no PA) |
| **SP** (scratchpad) | **per-DNC, private** | one DNC only | `SP_MEM_BASE = 0x1F_E000_0000` |
| **SHM** | **per-cluster bank** | all DNCs in chiplet (global PA) | `SHM_MEM_BASE[0]=0x1F_E400_0000`, `[1]=0x1F_E600_0000` |
| **DRAM** (HBM) | per-chiplet, channel-interleaved | all DNCs in chiplet | `0x00_0000_0000 – 0x10_0000_0000` |

(All ranges: `rebel_common.py:74-79`.)

### 1.1 SP — per-DNC private
Each DNC owns a **private 4 MiB SP slice** (`scratchpad_size="4MiB"`,
`DNC.py:66`). Addressing is a flat stride from one base:

```
SP_addr(dnc) = SP_MEM_BASE + dnc_id × 4 MiB        (DNC.py:337)
```

SP is **not** shared: a DNC cannot snoop or DMA into another DNC's SP partition.
Because the partition base is implicit in `dnc_id`, microcode addresses SP with
**partition-relative offsets** — the *same* offset on every DNC lands in that
DNC's own partition (this is why per-NCore SP stage addresses are authored as
DNC-invariant constants).

### 1.2 SHM — per-cluster banked, globally addressable
A chiplet has **two 32 MiB SHM banks**, one per cluster of 8 DNCs
(`SHM_MEM_BASE[0]/[1]`, `rebel_common.py:77-79`). Within a bank, SHM is
**slice-interleaved** (2 MiB granule × 16 slices, 4 SHM NIUs;
`num_rdsn_shm_niu=4`). The partitioning is for bandwidth/locality — **addressing
is uniform**: every DNC can name any SHM line by global PA. The cluster a DNC
belongs to determines which 32 MiB bank its working set falls in.

SHM is the **rendezvous tier**: it is the only on-chip memory both planes touch
(§4), and the only way the 16 DNCs communicate.

### 1.3 DRAM — per-chiplet, channel-interleaved
DRAM is **monolithic per chiplet**, interleaved across **16 HBM channels** at a
1024-byte granule (`num_hbm_channels=16`, `hbm_intlv_size=1024`). It is
partitioned **by channel for bandwidth, not by DNC or cluster** — all DNCs see
one global DRAM PA space; the controllers hash addresses across channels. DRAM
carries the named regions (`DRAM_INPUT/OUTPUT/KERNEL/INIT/INTMD/TENSOR`).

## 2. The DMA engines and their memory scope

Three DMA engines, distinguished first by **which hardware executes them**, and
second by **which memory tier each end may touch**.

| | **UDMA** | **DDMA / RBDMA** | **HDMA** |
|---|---|---|---|
| Command type | `UDMA`/`UDMA_LP`/`UDMA_ST` | `DDMA`/`DDMA_HIGHP` | `EXTENSION`→`HDMA` |
| Engine | the **DNC** (a DNC task) | the **RBDMA** engine | Host DMA controller (PCIe) |
| Descriptor home | 32B DNC task register (shared w/ COMPUTE) | RBDMA `Task_desc_conf` | `Hdma_task`/`Hdma_dyn_task` |
| Endpoints | **one end always SP**; other = SHM \| DRAM | SHM \| DRAM on both ends (**never SP**) | host ↔ DRAM |
| Sync | per-task TSYNC | TSYNC + RLSYNC + MSYNC | multi-device put/get sync |
| Role | compute-coupled SP staging | decoupled bulk mover | host-boundary crossing |

The endpoint rule is a **hard, descriptor-level constraint**, not a convention:

- **UDMA** — `krt_udma_desc` carries only *one* region field; the other end is
  hardwired to SP (`r100_krt.h:152-160`): `LDUDMA/LPUDMA` is `{SHM|DRAM} → SP`,
  `STUDMA` is `SP → {SHM|DRAM}`. **UDMA therefore cannot express DRAM↔SHM** —
  neither end would be SP.
- **RBDMA** — `krt_rbdma_desc.{src,dst}_region` are both free
  (`r100_krt.h:166-167`), so it spans DRAM↔SHM and DRAM↔DRAM, but it **never touches
  SP**.

### 2.1 Why two on-device DMA paths
UDMA and RBDMA both move data on-chip, so why both? The split is
**coupling**, not address range:

- **UDMA** is *compute-adjacent* — issued by the DNC, ordered in-line with
  COMPUTE through the same task queue and TSYNC machinery, used for the staging
  the microcode immediately needs (init load, SP fill).
- **RBDMA** is a *decoupled bulk engine* — runs in parallel on separate
  hardware, with cross-chiplet reach (§5) and richer sync (§6).

## 3. The reachability matrix

Putting the endpoint rules together: which moves are expressible, and by whom.

### Cross-region (the common case)
| Move | Engine |
|---|---|
| host ↔ DRAM | **HDMA** |
| DRAM ↔ SHM | **RBDMA** |
| {SHM \| DRAM} ↔ SP | **UDMA** |

### Intra-region (same region on both ends)
| Move | Engine | Note |
|---|---|---|
| DRAM ↔ DRAM | **RBDMA** | classic DDMA use (KV-cache, intermediates) |
| SHM ↔ SHM | RBDMA | descriptor permits it; uncommon in practice |
| **SP ↔ SP** | **none** | not a DMA op — the microcode datapath owns intra-SP movement (§4) |

Two walls fall out, and they recur throughout the stack:

- **SP is the wall no DMA self-loops.** No engine does SP↔SP; intra-SP movement
  is the microcode's job, not a command's.
- **SHM is the rendezvous.** Both planes reach it, from opposite sides — RBDMA
  from the DRAM side, the movers from the datapath side (§4).

## 4. Microcode movers vs. DMA — the data-plane reach

The per-DNC microcode (`init.bin`) contains its own data-movers — the data-plane
analog of DMA. They split into two families by which on-chip memory they touch,
and **none of them reach DRAM**.

| Mover family | Reaches | Cross-DNC? |
|---|---|---|
| **NCLU / NCSU** (NC Load/Store Unit) | **SHM** ↔ FIFO | ✓ — via SHM only |
| **SPLU / SPSU** (SP Load/Store Unit) | own DNC's **SP** ↔ FIFO | ✗ never |

(Mover address spaces are visible in
`PrimitiveAuthor/examples/sqrt/hw_movers.py` *(removed in `759ef3b0`)*: NCLU issues `LDMU` against a
`shm_line`; SPLU/SPSU stage at SP byte-addresses; both feed the XVU FIFO. DRAM
appears in no mover.)

Consequences:

- **The microcode address space is `{SHM, SP, FIFO/LRF}` — DRAM-free.** A kernel
  trusts that the command plane (RBDMA/UDMA) has already staged its inputs into
  SHM/SP before any compute runs.
- **Movers are confined to their own DNC.** SPLU/SPSU reach only the local SP
  partition; cross-DNC sharing goes through SHM: `NCSU` (DNC A) writes a line to
  SHM, `NCLU` (DNC B) reads it.
- **SHM is the two-plane handoff:**

  ```
  DRAM ─RBDMA→ SHM ─NCLU→ FIFO ─compute→ FIFO ─NCSU→ SHM ─RBDMA→ DRAM
                     └ SP staging via UDMA(cmd) ↔ SPLU/SPSU(microcode) ┘
  ```

Mover ISA detail (record formats, FIFO depth, burst) is in
[`splu_xvu_fifo_contract.md`](../../dnc_spec/docs/splu_xvu_fifo_contract.md).

## 5. Across chiplets (REBEL-Quad)

REBEL-Quad is **4 chiplets in a 2×2 mesh**, stitched by **uCIe links** through
the RBC (Rebel Bus Controller).

### 5.1 One global address space, chiplet selected by high bits
Each chiplet occupies a fixed `0x20_0000_0000` slice of a single shared PA space
(`rebel_common.py:83-87`):

| Chiplet | PA base |
|---|---|
| 0 | `0x00_0000_0000` |
| 1 | `0x20_0000_0000` |
| 2 | `0x40_0000_0000` |
| 3 | `0x60_0000_0000` |
| (global host) | `0x80_0000_0000`… |

Within each slice the local map of §1 repeats. So **chiplet N's DRAM/SHM =
local-offset + N × `0x20_0000_0000`** — it is one unified PA space, *not*
isolated domains. Any address is nameable from anywhere.

### 5.2 But only the bulk engines cross the boundary
Nameable ≠ reachable. The uCIe/RBC link is the boundary:

| Engine | Crosses chiplet boundary? |
|---|---|
| RBDMA / DDMA | ✅ routes over RBC uCIe |
| HDMA | ✅ host/device path |
| UDMA | ❌ bound to its DNC's local chiplet |
| microcode movers | ❌ strictly chiplet-local |

A DNC can never directly touch another chiplet's memory — not via its movers,
not via UDMA. **Off-chiplet movement is always an explicit RBDMA (or HDMA)
transfer.**

## 6. Synchronization nests by physical distance

Each memory scope has a matching synchronization mechanism. They nest:

| Scope | Mechanism | What it coordinates |
|---|---|---|
| intra-chiplet (DNC ↔ DNC) | **TSYNC** (token counters) | producer→consumer task ordering |
| intra-package (chiplet ↔ chiplet) | **RLSYNC** (remote-link) | RBDMA posts a counter to a *peer RBDMA* over uCIe |
| cross-device | **MSYNC** (multi-device) | HDMA `multi_device_put/get_sync` |

The farther data travels, the more sync machinery the descriptor carries —
mirroring the memory tiers exactly. (TSYNC/CPSYNC field-level detail and the
MLIR `dpdc_*`/`dep_slot_*` renames are in
[`programming_16_dncs.md`](programming_16_dncs.md) §2.5; the per-task token
fields are in §4.3 there.)

## 7. Implications and failure modes

The payoff of the contract above is that a whole class of bugs becomes legible.

- **SHM-base agreement (the green-on-PrecSim / 504-on-HW class).** The command
  plane lands input in SHM via RBDMA, whose SHM endpoint is filled at load time
  by the **tag3 reloc** ([`container-build-guide.md`](container-build-guide.md)
  §3 Step 3). The data plane reads that SHM line via **NCLU**, whose `shm_line`
  base is baked in the microcode. If the two disagree, the planes miss at the
  SHM rendezvous (§4). PrecSim models only the mover side, so the mismatch is
  **green on PrecSim and 504s on silicon** — the canonical symptom of this whole
  contract being violated.

- **PrecSim models the data plane, not the command plane.** PrecSim executes the
  microcode (SHM↔SP↔compute) but does not model RBDMA staging, the CP dispatch,
  or cross-chiplet routing. The SoC sim is the oracle for the command-plane half
  (see [`soc-sim-reference.md`](soc-sim-reference.md)).

- **Unit pitfalls.** Address fields mix units — DRAM offsets in 128-byte units,
  SHM/SP staging in bytes, reloc init values in **bytes** (not lines). A
  line-vs-byte (×128) confusion mis-addresses per-DNC init loads; always confirm
  the unit of any address field you author.

## 8. Source map

| Fact | Source |
|---|---|
| Chiplet PA map, SP/SHM/DRAM bases, chiplet slices | `rebel_common.py:74-87` |
| `num_dcluster=2`, `num_dncs=8`, HBM channels, SHM slices | `rebel_common.py:1031-1044` |
| Per-DNC SP stride, 4 MiB | `DNC.py:66,337` |
| UDMA one-end-SP rule | `krt/include/krt/r100_krt.h:152-160` |
| RBDMA free region fields | `krt/include/krt/r100_krt.h:166-167` |
| 32B DNC task descriptor (wire layout) | `programming_16_dncs.md` §4.3; `command.hh:3293-3307` |
| Mover address spaces (NCLU/SPLU) | `PrimitiveAuthor/examples/sqrt/hw_movers.py` *(removed in `759ef3b0`)* |
| uCIe / RBC chiplet links | `configs/rebel/rebel.py` connectChiplet; `rbc.hh` |
