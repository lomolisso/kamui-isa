# models/ptx87/equiv/

Bounded comparisons of the PTX 8.7 model (`../ptx87.als`) with the two formal PTX models NVIDIA published:

| File | NVIDIA model | PTX version | What both describe (the fragment) |
|---|---|---|---|
| `nv2019.als` | Lustig, Sahasrabuddhe, Giroux, ASPLOS 2019 (`deps/ptx-memory-model/ptx.als`) | 6.0 | scope trees of any depth, weak and strong loads, stores and RMWs, `fence.acq_rel`, `fence.sc`, one-sided fences, CTA barriers |
| `mp2022.als` | Lustig, Cooksey, Giroux, ISCA 2022 (NVlabs/mixedproxy `alloy/ptx.als`, commit 0807da2) | 7.5 | system / device / block / thread, generic, texture, surface and constant proxies, virtual aliases, proxy and alias fences, `fence.acq_rel`, `fence.sc` |

## How it works

Litmus tests compare models on chosen programs. A bounded comparison compares them on **every** execution up to a
size: Alloy searches all executions with at most N events for one that the two models judge differently.

Each NVIDIA model is copied into the comparison file over the signatures of `ptx87.als`, with a prefix (`nv_`,
`mp_`) and only the names changed, so both models judge the same execution. Their facts become a predicate
(`nv_wf`, `mp_wf`). Two details are explained in the file headers:
- the 2019 model's free `observation` relation is replaced by its least value, which gives the same verdicts;
- one 2019 fact only prunes instances for test generation and is left out.

Each check asks one direction:
- `ours_X` (or `d42_ours`): an execution the NVIDIA model allows and ptx87 forbids, so ptx87 is **stronger**. This is
  harmless for programs.
- `nv_X`, `mp_X` (or `d42_nv`): an execution ptx87 allows and the NVIDIA model forbids, so ptx87 is **weaker**.
  This direction could break a program written for PTX.

Every counterexample must be explained by a decision of `../decisions.md`.

```bash
tools/dev.sh 'models/ptx87/equiv/check.sh nv2019.als'     # every check of the file; JOBS, LIMIT: see the script
tools/dev.sh 'models/ptx87/equiv/check.sh mp2022.als mp_ptx_mm_5'
```

Each check takes seconds (kissat 4.0.1, dev image 0.4). Counterexamples are kept in `build/ptx87-equiv/cex/`.

## Results (November 2026, bounds 4 and 5 events)

**Against the 2019 model: ptx87 is the 2019 model plus D42, exactly.**

| Check | Bound | Result | Meaning |
|---|---|---|---|
| `wf_core`, `wf_bar` | 4, 5 | UNSAT; SAT for `wf_bar` | our facts accept no execution of the core that the 2019 facts reject; with barriers, one more execution: a `bar.arrive` that nothing waits for (rejected by a 2019 fact against "isolated barrier pieces"), which orders nothing |
| `nv_ptx_mm`, `nv_ptx_mm_bar` | 4, 5 | UNSAT | ptx87 is never weaker than the 2019 model |
| `d42_ours`, `d42_nv` (core and barriers) | 4, 5 | UNSAT both ways | ptx87 judges every execution exactly as the 2019 model with RMW atomicity over `^co` (D42) |
| `ours_ptx_mm`, `ours_atomicity` | 4 | counterexample | D42: a weak write between two writes in coherence order hides an RMW violation in the 2019 model |
| `ours_coherence`, `ours_causality` | 4 | counterexample | axiom by axiom only: base causality includes program order in ptx87 (8.9.5) but needs a synchronization in the 2019 text; the 2019 model forbids the same executions by SC per location |
| `nv_causality` | 4 | counterexample | axiom by axiom only: a `fence.sc` cycle that the 2019 causality axiom forbids through `optional`, and ptx87 by its Fence-SC axiom (D3, D4) |
| other axioms, both ways | 4 | UNSAT | |

**Against the mixed-proxy model: ptx87 is weaker in exactly one way, virtual aliases.**

| Check | Bound | Result | Meaning |
|---|---|---|---|
| `wf_mp` | 4 | UNSAT | our facts accept no execution the mixed-proxy facts reject |
| `mp_ptx_mm` | 4, 5 | counterexample | ptx87 allows executions the mixed-proxy model forbids, all through virtual aliases (below) |
| `mp_ptx_mm_noalias` | 4, 5 | UNSAT | without aliases, ptx87 is never weaker |
| `mq_ptx_mm` | 4, 5 | UNSAT | the mixed-proxy model with morally strong limited to the same virtual address is never stronger than ptx87: aliases are the only difference in this direction |
| `ours_ptx_mm`, `ours_fence_sc` | 4 | counterexample | D3: the mixed-proxy Fence-SC axiom relates only memory operations, so it never applies to fences (empty); ptx87 uses base causality. Also D1: in the mixed-proxy model fences have no proxy, so a release or acquire pattern that starts or ends with a fence never synchronizes |

### The alias difference

Two operations on different virtual addresses of the same memory (aliases) are never morally strong in ptx87:
morally strong needs the same proxy, and "using distinct virtual addresses behaves as if using different proxies"
(8.6, 6779). In the mixed-proxy model, morally strong ignores addresses. An example the mixed-proxy model forbids
and ptx87 allows, one thread, `x` and `y` aliases:

```
ld.acquire.gpu r0, [x]    // reads 1, the value of the store below
st.release.gpu [y], 1
```

Without a `fence.proxy.alias`, ptx87 orders nothing between the two addresses, so the load may read the later
store. The mixed-proxy model treats the two as morally strong, so the store synchronizes with the load and the
load cannot read it. Its causality order, though, relates operations on aliases only through an alias fence (the
`same_location` clauses of `proxy_preserved_cause_base`), as ptx87 does: only its morally strong ignores the
address. The stronger reading is a candidate for the Kamui contract (decided with the other unsure readings).

### What these checks cannot see: final values

The checks compare executions. A litmus test also has a condition, and a condition on the final value of a
location (`x == 3`) needs a last write. Coherence order is partial (8.9.6): two writes that are not morally strong,
for example a weak surface write and a generic write, need not be ordered. Our queries read `x == 3` as "the write
of 3 follows every other write to x" (`final_cmp` in `tools/litmus/to_alloy87.py`). Dartagnan reads it as "no
write follows the write of 3", which also holds when the writes are unordered. The two models can then give
different verdicts on the same test while agreeing on every execution. In the suite this happens for two tests,
`CoWR+3writes+surface` and `RMW-atomicity+alias`; all other tests with a final-value condition get the same
verdict under both readings.
