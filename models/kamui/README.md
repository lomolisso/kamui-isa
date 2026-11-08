# models/kamui: the Kamui memory model and the PTX lowering

Kamui's memory model on GPU memory is the PTX ISA 8.7 model, exactly. This directory holds that model under
Kamui's name, the table that gives every Kamui instruction (and every standard RISC-V memory instruction) its
meaning in it, the lowering from PTX, and the checks that the lowering is correct. The prose version, for readers,
is [`spec/memory-model.md`](../../spec/memory-model.md).

| File | Content |
|---|---|
| `kamui.als` | the model: `models/ptx87/ptx87.als` below its `module` line, unchanged (`tools/litmus/check_suite.py` compares them) |
| `instructions.yaml` | every Kamui memory instruction and standard RISC-V memory instruction, with the PTX operation whose events it produces and the H100 instruction it copies |
| `lowering.yaml` | the lowering: one rule per PTX form (Kamui sequence, standard alternative, why), and the rules of every modelled feature of `models/ptx87/coverage.yaml` |
| `decisions.md` | design decisions K1 to K14 |
| `definitions.md` | one row per Alloy definition: the rule of the specification it encodes, its PTX section and decision |
| `compile_ptx87_kamui.als` | the bounded lowering check, its sanity runs and the broken lowerings |
| `check_lowering.sh` | runs them, one Alloy process per command |
| `LICENSE` | the BSD 3-Clause licence of the NVIDIA models the PTX model derives from |

## How the lowering is checked

**On every litmus test.** `tools/litmus/to_kamui.py` lowers each PTX test of `tests/litmus/ptx/` twice (Kamui
instructions only, and standard RISC-V instructions wherever `lowering.yaml` allows one), reads the result through
`instructions.yaml` (a separate table, so a mistake in one shows up as a disagreement) and writes Alloy queries
against `kamui.als`. `tools/litmus/run_formal.py` decides them (models `kamui-alloy`, `kamui-std-alloy`) and
`tools/litmus/check_suite.py` fails if a lowered test allows an outcome that PTX 8.7 forbids. Tests PTX allows and a
lowered program forbids are fine (Kamui may be stronger) and are listed by `check_suite.py --stronger`.

```bash
tools/dev.sh 'python tools/litmus/to_kamui.py --check'
tools/dev.sh 'python tools/litmus/run_formal.py --models kamui-alloy,kamui-std-alloy'
tools/dev.sh 'python tools/litmus/check_suite.py'
tools/dev.sh 'python tools/litmus/to_kamui.py --broken ld-acquire'    # a wrong rule: must report tests now allowed
```

**On all small programs.** `compile_ptx87_kamui.als` searches for a PTX program of one feature group and a Kamui
execution of its lowering whose execution, read back into the PTX program, breaks one of the six PTX axioms
(coherence, Fence-SC, atomicity, no thin air, SC per location, causality); undefined behaviour of the PTX program
allows every outcome. The lowering it checks is the event-level content of `lowering.yaml`: every PTX event has an
image of the same kind, location, thread and place in program order, possibly stronger in one of two ways: a
wider scope for a strong operation, or a `fence.sc.sys` before an acquire-release read-modify-write. (A third,
a weak generic read in place of a weak non-coherent read, was dropped when the `proxies` group showed it is not
stronger: K9.) The feature groups:

| Group | PTX programs | Lowering |
|---|---|---|
| `core` | loads, stores, read-modify-writes, fences, generic proxy, global memory | the Kamui instructions (identity) |
| `core_std` | the same | the standard alternatives: wider scopes, `.aqrl` |
| `proxies` | aliases, alias and proxy fences, the non-coherent path (`ld.global.nc`, `ldu`) | identity |
| `barriers` | CTA and cluster barriers | identity |
| `mbarrier` | mbarrier objects | identity |
| `async` | asynchronous copies, groups, complete-tx, async proxy | identity (the elect loop of K6 issues each thread's own copy) |
| `restricted` | `sync_restrict` and `mbarrier_init` fences | identity |
| `rest` | tensor maps, tensormap proxy, the remaining async forms | identity |

**Only `core_std` needs a solver.** In every other group the lowering is the identity at the level of events, and
then the Kamui program and its execution are a copy of the PTX ones: the correspondence part of
`compile_ptx87_kamui.als` (`bijections` to `read_back`) names every signature and every field of the PTX model,
which `check_suite.py` checks. The only parts it does not carry over are fixed by something else: `acc` (the
bounded check has no mixed-size accesses), `synchronizes` (defined by the model as `bgen.bwait`) and the abstract
signatures (made of their subsignatures). Since `kamui.als` is the same text as `ptx87.als`, every axiom has the
same truth value on both sides, for programs of every size. The identity groups therefore hold without a solver;
their bound-3 commands are kept as a test of the correspondence predicates themselves. What the identity groups do
not test is the instruction-level part of a rule (that `cp.async.wait_all` is a commit and a wait for zero groups,
or that the `tensormap.cp_fenceproxy` sequence has the events of the PTX instruction): that is the job of
`instructions.yaml` and the litmus suite above.

```bash
tools/dev.sh 'models/kamui/check_lowering.sh all'       # core_std at bound 4 must be UNSAT, every sanity run SAT
tools/dev.sh 'models/kamui/check_lowering.sh broken'    # every broken lowering must be SAT
tools/dev.sh 'models/kamui/check_lowering.sh identity'  # the identity groups at bound 3
tools/dev.sh 'models/kamui/check_lowering.sh bound5'    # core_std at bound 5
```

Bound 4 means at most 4 atoms per signature of each model, with 7 scope-tree nodes (two threads in two CTAs of one
cluster) and, in `core_std`, one more Kamui event (an inserted fence).

The check reads the execution back from the Kamui side, Fence-SC order included. That is exact for lowerings that
keep or widen every scope, as all of Kamui's do. A lowering that narrowed a `fence.sc` would leave the PTX side with
no Fence-SC order for the pair and no execution to check, so such a mistake is tested with a release or acquire
fence instead (`broken_narrow_fence`); the litmus suite tests narrowed `fence.sc` directly
(`to_kamui.py --broken fence-scope`).

**Broken lowerings** (in `compile_ptx87_kamui.als`, `run broken_*`), each of which must produce a counterexample:

| Run | Group | The mistake |
|---|---|---|
| `broken_drop_acquire` | core | an acquire load lowered as a relaxed one |
| `broken_narrow_fence` | core | a release, acquire or acq_rel fence at `.gpu` or `.sys` lowered at `.cta` |
| `broken_std_weak_load` | core | an acquire load replaced by a plain `lw` |
| `broken_mbar_relaxed` | mbarrier | an arrive lowered without its release |
| `broken_copy_unordered` | async | a copy not ordered after the instruction that asked for it (another thread issuing it without K6's rule) |
| `broken_drop_restrict` | restricted | `fence.release.sync_restrict::shared::cta` dropped |
| `broken_drop_proxy_fence` | async | `fence.proxy.async` dropped |
| `broken_relax_nc` | proxies | a weak non-coherent read lowered as a generic one (the first version of K9) |

## Results

**Litmus lowering.** 1665 PTX tests lowered both ways, plus the 8 hand tests of `tests/litmus/kamui-isa/hand/`:
no lowered test allows an outcome PTX 8.7 forbids. With Kamui instructions every verdict equals PTX's; with
standard instructions 92 tests are stronger (forbidden on Kamui, allowed by PTX), all from scopes widened to
`.sys`. The other PTX tests are outside the lowering: texture, surface and constant-proxy instructions of the
PTX 7.5 tests, loops, a barrier without a count. A broken rule is caught on the suite (tests PTX forbids that the
rule changes / of those, tests now allowed): `ld-acquire` 247 / 226, `fence-scope` 108 / 67, `mbar-relaxed` 99 /
33, `proxy-async` 35 / 24, `restrict` 8 / 8.

**Bounded check.** Times on one AMD EPYC 9454 host, one process per command, pinned to whole physical cores.

| Commands | Result | Solver and time per command |
|---|---|---|
| `core_std_*_4` (bound 4) | all 6 UNSAT | `fence_sc`, `no_thin_air`: 5 s (plingeling, 16 CPUs); `atomicity` 5442 s, `causality` 11117 s, `coherence` 11476 s, `sc_per_location` 21781 s (kissat, 1 CPU) |
| `core_std_*_3` (bound 3) | all 6 UNSAT | 4 s to 760 s (plingeling, 8 CPUs) |
| identity groups `*_3` (bound 3) | 38 of 42 UNSAT, 4 no result in 3 h | 3 s to 7249 s (plingeling, 8 CPUs); no result: `async_coherence`, `async_causality`, `rest_coherence`, `rest_causality`. These hold at every size anyway (above). |
| `sanity_*` | all 9 SAT | about 10 s (glucose) |
| `broken_*` | all 8 SAT | 9 s to 35 s (glucose), `broken_drop_restrict` 401 s |

Bound 5 is not run. From bound 3 to bound 4 kissat's time grew about 21 times (`core_std_atomicity`: 261 s, then
5442 s), so bound 5 would take roughly 30 to 130 hours per command, past the 12-hour limit.

Two problems were found by these checks before the results above were final, both now fixed: the PTX model's
Fence-SC axiom applied to every pair of `fence.sc` instead of morally strong pairs only (`models/ptx87`, D41; found
by `core_std_fence_sc_4`), and `ldu` lowered to a plain `kldg` is not stronger than PTX (K9; found by
`proxies_*_4`, kept as `broken_relax_nc`).

**Why some commands take hours.** The formulas are small (39 000 to 72 000 variables), but each holds two copies
of the same model, and a SAT solver proves that two copies of the same circuit agree only slowly; the axioms built
from transitive closures (coherence, causality, SC per location) suffer most. Kissat was 1 to 4 times faster than
plingeling while using one CPU instead of 8 or 16 (`core_std_atomicity_3` 261 s vs 268 s, `core_std_coherence_3`
414 s vs 750 s, `proxies_coherence_3` 1675 s vs 7249 s, `core_std_atomicity_4` 5442 s vs 14562 s). To use it,
build Kissat 4.0.1 in the build area and pass its path:

```bash
tools/dev.sh 'git clone --depth 1 -b rel-4.0.1 https://github.com/arminbiere/kissat build/kissat && cd build/kissat && ./configure && make'
tools/dev.sh 'KISSAT=build/kissat/build/kissat ALLOY6_SOLVER=kissat CORES=24-27,72-75 PER=2 models/kamui/check_lowering.sh all'
```
