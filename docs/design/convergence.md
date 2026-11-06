# Convergence and independent thread scheduling

Decided 2026-11-05.

## Question

How does a warp run code whose lanes take different paths? Either the warp keeps one program counter and a stack
of masks, splitting at a divergent branch and joining at the branch's immediate post-dominator (IPDOM, as in
Vortex), or every lane has its own program counter and lanes run together again only where the program says so
(independent thread scheduling, as in Volta and later NVIDIA GPUs, including the H100).

## Decision

Kamui does what the H100 does: **independent thread scheduling, required of every Kamui implementation from tier
1 on.**

- Every lane has its own program counter. The hardware runs together the lanes that are at the same program
  counter.
- **Forward progress inside a warp**, as PTX requires for `sm_70` and later: a lane that waits for another lane of
  its own warp (a spin lock, a flag) must eventually let that lane run. An implementation that keeps one program
  counter per warp and a mask stack does not meet the specification.
- Lanes run together again only at explicit **convergence barriers**, as on the H100:

| H100 | Kamui (names provisional) | What it does |
|---|---|---|
| `BSSY Bn, target` | `kbssy` | records the active lanes in convergence barrier `Bn` and the point where they meet again |
| `BSYNC Bn` | `kbsync` | waits until every lane recorded in `Bn` has arrived or left |
| `BREAK Bn` | `kbreak` | removes the executing lanes from `Bn` (early loop exit) |
| `WARPSYNC mask` | `kwarpsync` | `bar.warp.sync`: the lanes of the mask wait for each other, even from different program points |
| `BMOV` | `kbmov` | moves a convergence barrier to or from a general register (when more than 16 are live) |
| `YIELD` | `kyield` | lets other lanes of the warp run (marked spin loops) |

- 16 convergence barrier registers `B0` to `B15` per warp (a 4-bit field), each holding a lane mask.
- Every warp-collective instruction (`shfl.sync`, `vote.sync`, `match.sync`, `redux.sync`, `elect.sync`) takes
  PTX's member mask; the lanes of the mask take part, wherever they are.

## Why

PTX 8.7 for `sm_90a` assumes independent thread scheduling, and the H100 provides it (`evidence/probes/README.md`,
job q233):

- A spin lock between lanes of one warp gave the lock to all 32 lanes in every run (`its-lock-in-warp`); two sides
  of a branch that wait for each other both finished (`its-cross-branch-wait`); a hash table with per-bucket spin
  locks inserted every key correctly (`tools/evidence/workloads/divergence.cu`, `hashlock`).
- `bar.warp.sync` reached from two program points synchronized the two halves of the warp (`syncwarp-divergent`).
- The H100 reconverges only where the compiler put `BSSY`/`BSYNC`: after a divergent call, the warp stays split
  (`reconv-points`, `bmov-break`).
- `BSSY`/`BSYNC` bracket every divergent region in the SASS we collected (`evidence/sass-observations.csv`, 30
  rows tagged `convergence-barrier`) and appear in 157 of 182 workload kernels. `BMOV` appears in none of 206 real
  kernels; it needs more than 16 nested divergent regions (probe `bmov-deep`, job q236), so 16 barrier registers
  are enough.

An IPDOM stack cannot run the spin-lock programs above, and a design built on it cannot be extended to
independent scheduling later without a second, incompatible control-flow model. Requiring forward progress from
the start means every Kamui implementation runs every PTX program the H100 runs.

## Consequences

- Hardware: a program counter per lane (or an equivalent representation), the convergence barrier registers per
  warp, and a scheduler that picks which group of lanes runs next and switches away from a group that waits
  (`kyield`, or a hardware rule). The functional simulator does the same, for example round-robin over the groups.
- Compiler: inserts `kbssy`/`kbsync` around divergent regions (no structurization of the control flow is needed),
  `kbreak` on early exits, `kwarpsync` for `bar.warp.sync`, and spills barriers with `kbmov` past 16.
- Uniform instructions run per group of lanes; see [uniform-datapath.md](uniform-datapath.md).
- Tier table: independent thread scheduling moves from tier 2 into tier 1 ([overview](../overview.md)).
