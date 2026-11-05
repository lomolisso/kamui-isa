# evidence/probes/

Results of the probe kernels in `tests/probes/` on the H100. Each job folder holds `goldens/<probe>/` (the runner's
`golden.yaml` with buffer offsets and the first run's `outputs.bin`), `runs/<probe>/run<k>.bin` (every run),
`run.log`, `gpu.txt`, `manifest.yaml`, and `results.md`, which `python tools/evidence/probes.py <job> --write`
makes from the outputs. All kernels are ours (clang 20 PTX, JIT-compiled by the driver).

| | |
|---|---|
| Job | `20261105T030701Z-q000233` (`jobs/isa-probes.sh`, 5 runs per probe) on GPU 3 of the lab's H100 server (H100 NVL, driver 580.126.20), commit `a78ab4b9` |
| Result | all 14 probes ran (`summary: ok 14`) |
| Job | `20261105T042645Z-q000236` (`PROBES=bmov-deep`, same settings), commit `29f1d5f4`: the deep-nesting probe added later |

## Findings

**Forward progress inside a warp.** The classic spin lock (`its-lock-in-warp`) gave the lock to all 32 lanes in
every run, one after another (lane order 0, 1, 2, ...; at most 33 tries; about 59,000 cycles). In
`its-cross-branch-wait` both sides of the branch finished in every run; the SASS shows a real divergent branch
(`BSSY B0`; one side spins on the flag the other side sets, each spin loop has a `YIELD`), so the H100 interleaves
the two sides. `its-producer-consumer` was not informative: the producer side ran first, so no consumer had to
wait.

**Reconvergence.** After an if/else, a loop with per-lane trip counts, a loop left by `break` and a nested branch,
the active mask is again `ffffffff` (`reconv-points`; the two sides of the first branch ran one after the other,
the `if` side first). After the divergent non-inlined call in `bmov-break` the warp stays split
(`49249249` and `b6db6db6`), and after the loop with `break` and `return` it is split into a group and single
lanes: the hardware reconverges where the compiler put a convergence barrier (`BSSY`/`BSYNC`), not by itself.
`bar.warp.sync -1` reached from two program points (`syncwarp-divergent`) synchronized the two halves (32 of 32
lanes read the other half's values), and right after the barrier each half still ran with its own mask
(`0000ffff`, `ffff0000`). The `bmov-break` kernels had 2 `BREAK` and no `BMOV`. `BMOV` appears only when
divergent regions nest deeper than the 16 convergence-barrier registers (`bmov-deep`, 24 levels and a recursive
call: 17 `BMOV.32`, 51 `BMOV.32.CLEAR`); that kernel computed the right result in all 32 lanes in every run, and the
warp was still split after the outermost level.

**Address windows** (`addr-windows`, values from one run; the high bits of the base vary from run to run):

| What | H100 |
|---|---|
| Shared window of one CTA | 16 MB, aligned to 16 MB: the CTA of rank r in its cluster has `base + r * 2^24`; static shared memory starts at offset `0x400` (after the 1 KB reserved area), dynamic shared memory after it |
| `cvta.to.shared` of a CTA's own variable | `0x400` for rank 0, `0x1000400` for rank 1: the shared address already contains the rank field (`r << 24`) |
| Cluster window (`isspacep.shared::cluster`) | 4 GB, aligned to 4 GB, containing all the CTAs' 16 MB windows; another CTA's address is in the cluster window but not in `isspacep.shared` |
| `mapa` | replaces the rank field: rank 0 `...00000400`, rank 1 `...01000400`, the same from every CTA |
| Local window | 16 MB, aligned; every thread sees its local array at the **same** generic address (`...6dfffcc0` in all lanes and CTAs), so the hardware adds the thread's slot |
| Global | `isspacep.global` is true for anything outside the shared and local windows, including address `0x1000` |
| Reserved shared memory | `%reserved_smem_offset_begin` 0, `_end` 0x120 (288 bytes in use), `_cap` 0x400 (1 KB) |
| Sizes | `%total_smem_size` 0x1400 (1 KB static + 4 KB dynamic), `%dynamic_smem_size` 0x1000, `%aggr_smem_size` 0x1800 (includes the 1 KB reserved) |

**Costs** (cycles per operation, one thread, median of 5 runs; `lat-scopes-1`):

| Operation | `.cta` | `.cluster` | `.gpu` | `.sys` |
|---|---|---|---|---|
| `ld.relaxed` (dependent chain; weak `ld` 68) | 59 | 309 | 309 | 309 |
| `ld.acquire` | 60 | 310 | 313 | 310 |
| `st.release` (issue; `st.relaxed` 0.1) | 15 | 554 | 554 | 1175 |
| `atom.relaxed.add` | 481 | 481 | 481 | 481 |
| `atom.acq_rel.add` | 485 | 1027 | 1024 | 1616 |
| `fence.acq_rel` | 10 | 282 | 275 | 1142 |
| `fence.sc` | 8 | 275 | 278 | 1138 |

Other operations: `ld.volatile` 308; `red.relaxed.gpu` 4.6 (issue), `red.release.gpu` 555; `fence.proxy.async`
157, `.global` 4.3, `.shared::cta` 12; `fence.proxy.alias` 187; `mbarrier.arrive` 5.8, arrive + `try_wait` 39.
`.cluster` costs the same as `.gpu` everywhere (the H100 has no cluster level), a relaxed atomic costs the same at
every scope (performed at the L2), and `.sys` doubles the release and fence costs. One warp on one word
(`lat-scopes-warp-same`) gives the same numbers; on separate lines (`-distinct`) loads cost about 60 cycles more.

Warp-wide operations (`lat-warp`): `redux.sync.add` 46.5 against 145 for the same sum with five shuffles,
`vote.sync.ballot` 22.6, `match.any.sync` 39.3, `activemask` 2.5, `bar.warp.sync` 1.1, `elect.sync` 2.6,
`%ctaid.x` 3.2.

**setmaxnreg.** With 168 registers at launch (the whole register file for one 384-thread CTA), an increase to 232
waited until the decrease to 40 was issued: median wait 260 cycles with no delay and 200,135 cycles when the
decrease came after 200,000 cycles (it was issued at cycle 200,144); a decrease takes about 60 cycles.
