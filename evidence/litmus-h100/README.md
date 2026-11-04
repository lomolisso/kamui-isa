# evidence/litmus-h100/

Outcome counts of the litmus tests run on the H100: which outcomes the hardware actually produced, next to the
verdict of the formal models. This is evidence about one GPU, never a verdict: an outcome the formal model
allows but the H100 never showed is normal (the H100 is stronger than the PTX model in many places), and an
outcome the formal model forbids but the H100 showed is a finding to investigate. How the tests are run:
[tests/litmus/README.md](../../tests/litmus/README.md#running-the-tests-on-the-h100).

| | |
|---|---|
| Jobs | `20261101T211753Z-q000037` (first half of the tests, commit `881a95c`), `20261101T212423Z-q000038` (second half; 418 runs at `881a95c`, the 35 runs left after an interruption by the resume run at `a74e002`, which changed only the driver) |
| Commands | `h100 submit --gpu 3 -- env SHARD=0/2 bash jobs/litmus-h100.sh`, the same with `SHARD=1/2`, then `RESUME=1 OUT=<the second job's folder>` |
| GPU | NVIDIA H100 NVL, GPU 3 of the lab server (`GPU-1241dcbc-33ea-80bf-5f87-37f7868c3126`), not clock-locked (nothing is timed) |
| Driver, toolkit | 580.126.20 (the PTX is JIT-compiled by the driver), CUDA 12.9.1 job image |
| Work | 302 tests x 3 configurations x 1,013,760 instances (about 1e6) = 906 runs, 9.2e8 instances, about 15 minutes of GPU time |
| PTX 8.7 tests | job `20261102T022710Z-q000042` (commit `3efb161`): the 52 runnable tests of `tests/litmus/ptx/kamui/ptx87/`, 156 runs, about 3 minutes; command `h100 submit --gpu 3 -- env TESTS='ptx/kamui/ptx87/*' bash jobs/litmus-h100.sh`. Two earlier runs of the same tests were replaced: one stopped by the queue's watchdog, one with a kernel bug in the copy tests (fixed in `tools/litmus/to_cuda.py`) |
| Cache hints | job `20261103T024058Z-q000087` (commit `60a260c`): the 16 tests of `tests/litmus/ptx/kamui/ptx87/hints/`, 48 runs; command `h100 submit --gpu 2 -- env TESTS='ptx/kamui/ptx87/hints/*' bash jobs/litmus-h100.sh`. Job `20261103T024305Z-q000088` reran them in the shuffle configuration with 1e7 instances each (`CONFIGS=shuffle INSTANCES=10000000`); its counts are in `jobs/20261103T024305Z-q000088/hints-shuffle.csv` |
| `2+add.gpu` | job `20261103T041314Z-q000089` (commit `f2ece0b`): `tests/litmus/ptx/kamui/ptx87/rmw/2+add.gpu`, 3 runs; command `h100 submit --gpu 2 -- env TESTS='ptx/kamui/ptx87/rmw/2+add.gpu' bash jobs/litmus-h100.sh`. Its kernel folder was hidden by the `*.gpu` rule of `.gitignore` until then |
| Imported tests | job `20261103T042800Z-q000090` (commit `cbde6eb`), stopped by us at a Dat3M test that deadlocks by design (`PC-bar-sync-sync-3`, now skipped), and resumed into the same folder by job `q000091` (commit `ab5f07a`): the 111 runnable tests of `tests/litmus/ptx/imported/`, 333 runs, about 2 minutes; command `h100 submit --gpu 2 -- env TESTS='ptx/imported/*' bash jobs/litmus-h100.sh`, then the same with `RESUME=1 OUT=<the folder>` |
| Shared memory across CTAs | job `20261103T045153Z-q000092` (commit `29b3ef5`): the 25 PTX 8.7 tests that use the shared memory of another CTA of the cluster, and 2 `bar` tests, 81 runs; `TESTS` lists them, comma-separated |
| Start delays | job `20261103T045407Z-q000093` (commit `ce19777`) ran the new `spread` configuration and showed no change at all: ptxas had removed the empty loop that was meant to delay each thread's start, so no `shuffle` run before it had a start delay. Job `20261103T050216Z-q000094` (commit `49ee74a`, the delay now a `nanosleep`) reran `shuffle` and `spread` on all 509 runnable tests, 1018 runs, 9 minutes; its results replace the earlier `shuffle` results and those of job q000093 |
| Remaining PTX 8.7 forms | job `20261103T053509Z-q000095` (commit `95d8aeb`): 15 tests with mixed sizes and tearing, vector stores, `atom.cas.b128`, several atomic operations on one register, `discard`, mbarrier `init`/`inval` and the state token, in all four configurations, 60 runs |
| Feature and idiom tests | folder `20261104T180346Z-q000157`, filled by several jobs that resume into it: q000157 (the new harness features first: wgmma, `ldmatrix`, tensor maps and tensor copies, multicast, griddepcontrol, generic aliases, the idiom tests), q000213 (the same, after the harness fixes below), q000219 (all of `tests/litmus/ptx/kamui/features/`) and q000227 (the 10 PTX 8.7 tests that the new harness features made runnable); 4940 runs in all four configurations, at commit `983703c` and earlier commits that changed only other kernels. Runs that failed before five harness fixes were run again, and the results of the six tests the last fix affects were deleted and run again: the kernel wrote the test's initial value over the tensor map; tensor-copy buffers in shared memory were 16-byte aligned (the hardware needs 128); a tensor copy or tensor-map prefetch issued by a diverged warp hung; a CTA could exit while a copy into its shared memory was still in flight; and in one-CTA tests the multicast mask named CTA rank 0 instead of the instance's own CTA. The final value of a tensor-map location (the map's first word, part of an address) is recorded as 0; the runs made before the runner did so were rewritten the same way, merging the outcomes that became equal |

## Files

| File | Content |
|---|---|
| `results/<test path>/<config>.json` | the runner's histogram for one test and configuration: each distinct final state (`values`, in the order of `reg` and `gloc` in the test's `spec.txt`), where the instance's threads ran (`class`) and how often (`count`) |
| `observed.csv` | the same histograms with names and the verdict, one row per final state (columns below) |
| `summary.csv` | one row per test and configuration (columns below) |
| `jobs/<job id>/` | each job's `manifest.yaml` (commit, GPU, driver, toolkit, exit), `run.yaml` (every run with its exit status and time) and `gpu.txt` |

`python tools/litmus/observed.py --write` rebuilds both CSV files from `results/`; without `--write` it checks them
(in CI). `python tools/litmus/check_suite.py` fails on any forbidden outcome observed that
`tests/litmus/allowlist.yaml` does not explain.

`observed.csv`: `test`; `config` (`plain`, `stress`, `shuffle`); `class` (where the threads of the instance actually
ran: `same-sm`, `same-cluster` for one cluster on several SMs, `diff-cluster`); `outcome` (the final state, e.g.
`P1:r0=1 P1:r1=0`); `count` (instances with that state); `total` (instances of that test, configuration and
class); `observed_weak` (`yes` if the state satisfies the test's condition); `model_verdict` (the formal verdict
for the condition).

`summary.csv`: `test`, `config`, `instances`, `weak` (instances whose state satisfies the condition), `rate`
(weak / instances), `verdict`, and `status`: `weak-seen` (allowed and observed), `weak-unseen` (allowed, never
observed), `ok` (forbidden, never observed) or `forbidden-observed`.

## What the runs show

Tables: `python tools/litmus/report_tables.py --table h100` and `--table h100-families`.

- **Threads of one CTA never showed a weak outcome in the classic shapes** (`kamui/families/`), in any
  configuration, also with real start delays: they share one SM and its L1.
- **Across CTAs, the H100 shows the weak outcomes PTX allows**: store buffering (SB) up to 3e-3 of the instances,
  message passing (MP), load buffering (LB) and 2+2W around 1e-4 to 5e-4, ISA2 with weak accesses up to 4e-3;
  more often between clusters than inside one. LB is a hardware effect: ptxas keeps the load before the store
  (`LDG; STG`), and the store reaches memory while the load is still in flight.
- **The H100 is stronger than PTX in several places**: synchronization at `.cluster` scope between different
  clusters never failed (the H100 implements cluster scope as gpu scope); SB with `fence.acq_rel` at gpu or sys
  scope never failed; IRIW and read-read coherence (CoRR) never showed a weak outcome.
- **Hopper features**: a cluster barrier with a relaxed arrive lets stale data through (up to 16%), the default
  (release) arrive or a fence before the relaxed arrive never did; `cp.async.bulk` reading shared memory written
  just before by the same thread without `fence.proxy.async` copied the old value in 3 of 3e6 instances, never
  with the fence.
- **PTX 8.7 tests (`kamui/ptx87/`)**: of 52 tests, 156 runs, 37 show an allowed weak outcome and 16 a forbidden
  one. All 16 are the mbarrier case below, met again through a bulk copy's complete-tx (`TMA-load+*`), the
  asynchronous arrive of `cp.async.mbarrier.arrive`, and several arrivals (`MP2+*`): with one
  `fence.acq_rel.cta` after the wait, each shows the outcome in 0 of about 3 million instances. The tests that need
  distributed shared memory, wgmma, tensor maps, multimem or grids have no kernel (formal verdicts only).
- **Cache hints (`kamui/ptx87/hints/`)**: each test is MP across two CTAs with one hint on the data accesses.
  Prefetches (`prefetch` L1, L2, L2 with eviction priority, `prefetchu`, `applypriority`,
  `cp.async.bulk.prefetch`) and the `.cv` and `.lu` loads never showed the forbidden outcome, in about 1.3e7
  instances each. The other eight tests (`.ca`, `.wb`, `.wt`, L1 eviction priorities, `L1::no_allocate` on a
  store, `L2::cache_hint`) read `x` before and after the acquire with the same instruction, and **ptxas (CUDA 12.8,
  and the JIT of driver 580) merges the two loads**: the SASS has one `LDG` of `x` before `LDG.STRONG.GPU;
  CCTL.IVALL` and none after, and every observed outcome has `r1 == r2`. When the writer's two stores fall between
  the first load and the flag read, the merged code returns the forbidden outcome: 1 to 4 times per 1e7 instances
  in 7 of the 8 tests, 14 times in all. With `.cv` or `.lu` the second load differs, ptxas keeps both, and the
  same window gives the allowed `r2=0 r0=1 r1=1` (3 per 1e7) and never the forbidden one. PTX does not make the
  race on `x` undefined, so the model keeps the verdict forbidden; these eight hints are not measured on the H100
  (the manual's statement that they do not change memory behaviour, 15572, 15696, 16674, is the basis). No other
  test of the suite has two weak loads of one address around an acquire or a fence in one thread.
- **Coverage**: 1591 of the 1916 tests run (`python tools/litmus/to_cuda.py --why` lists the rest with the
  reason; see `tests/litmus/README.md`).
- **Imported tests**: no outcome the formal models forbid; 65 of 444 runs show an allowed weak outcome.
- **Shared memory of another CTA** (`st.weak.shared::cluster`, remote `mbarrier.arrive`, `st.async`,
  `red.async`, bulk copies into another CTA, restricted fences): no forbidden outcome. In several of these tests
  the reader almost never sees the writer's flag (the writer's remote store and release take longer than the
  reader's whole program), so they show little; the `TMA-store+*` tests never reached that state in 4e6
  instances.
- **Mixed sizes**: no torn value in `tearing+weak` or `tearing+relaxed` (4e6 instances each), although PTX
  allows one for weak accesses; `atom.cas.b128` behaves as one atomic operation; `discard.global.L2` drops the
  preceding store in 99.8% of the instances, which the manual allows (the line's data becomes undefined).
- **Real start delays** (`shuffle`, `spread`) make the mbarrier gap below show in two more tests,
  `MP+mbarrier-expect-complete-tx` (about 9%) and `MP+mbarrier-token` (0.2% to 0.3%), and in more runs of the
  tests that already showed it.
- **Feature and idiom tests** (`kamui/features/`, `kamui/idioms/`; 1045 tests, 4180 runs): 177 of the 406
  tests the models allow show their weak outcome. The outcome the models forbid appears in 21 tests, all with the
  mbarrier gap below: an `.acquire.cta` mbarrier wait with no fence after it, after a bulk, tensor or multicast
  copy, `st.async`, `red.async`, `cp.async.mbarrier.arrive.noinc` or `arrive_drop`. Over all the H100 runs, the
  gap shows in 33 of the 62 tests that end an acquire at such a wait, in none of the 8 with a fence after the
  wait, and in none of the 27 that wait at `.cluster` scope.
- **wgmma**: a generic store to the operand tile and then a wgmma that reads it, without `fence.proxy.async`
  between them, reads the old value in the `stress`, `shuffle` and `spread` configurations, with or without
  `wgmma.fence`; with `fence.proxy.async` and `wgmma.fence` it never did. This is the async proxy fence the
  manual asks for (`wgmma.fence`, 33416-33443).
- **Tensor maps**: a copy never used the old map after `tensormap.replace`, even without the proxy fences
  (`fence.proxy.tensormap::generic`) that the manual requires; the models allow that outcome, the H100 does not
  show it.
- **griddepcontrol**: the dependent grid reads a stale value without `griddepcontrol.wait` and never with it.
- **Generic aliases** (one memory mapped at two virtual addresses): no weak outcome in the 13 tests that run
  (Dat3M's `proxy` alias tests and mixedproxy's `synonym` tests).
- **mbarrier state**: the state that `mbarrier.arrive` returns is an opaque 64-bit value on the GPU, so the 6 tests
  whose condition reads it are not run.
- **One forbidden outcome observed, in three tests: `MP+mbarrier-rel-acq`** (and its `try_wait` and shared-memory
  variants), 0.13% to 1.1% of the instances. A thread whose `mbarrier.test_wait.acquire` (or `try_wait`) returns
  True can still read data older than what the arriving thread wrote before its `mbarrier.arrive.release`; PTX
  ISA 8.7 section 9.7.13.15.16 forbids this. In the SASS, the arrive (`SYNCS.ARRIVE`) has no memory barrier
  before it and the load after `SYNCS.PHASECHK` does not wait for its result. One `fence.acq_rel.cta`
  (`MEMBAR.ALL.CTA`) on either side removed the outcome in 3e6 instances. Details in `tests/litmus/allowlist.yaml`.
