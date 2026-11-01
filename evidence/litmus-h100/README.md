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

- **Threads of one CTA never showed a weak outcome**, in any test or configuration: they share one SM and its L1.
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
- **One forbidden outcome observed, in three tests: `MP+mbarrier-rel-acq`** (and its `try_wait` and shared-memory
  variants), 0.13% to 1.1% of the instances. A thread whose `mbarrier.test_wait.acquire` (or `try_wait`) returns
  True can still read data older than what the arriving thread wrote before its `mbarrier.arrive.release`; PTX
  ISA 8.7 section 9.7.13.15.16 forbids this. In the SASS, the arrive (`SYNCS.ARRIVE`) has no memory barrier
  before it and the load after `SYNCS.PHASECHK` does not wait for its result. One `fence.acq_rel.cta`
  (`MEMBAR.ALL.CTA`) on either side removed the outcome in 3e6 instances. Details in `tests/litmus/allowlist.yaml`.
