# tests/litmus/

Litmus tests for the PTX memory model, and the verdict of the formal models on each of them.

A **litmus test** is a tiny multi-threaded program plus a question about its final state. The classic one is
message passing (MP): thread 0 writes `data = 1` and then `flag = 1`; thread 1 reads `flag` and then `data`.
"Can thread 1 see `flag == 1` but `data == 0`?" A **memory model** answers *allowed* or *forbidden*. A formal
tool computes that answer by enumerating every possible execution and keeping those the model accepts. Running
the program on a GPU only shows which outcomes happened to occur, so the formal answer is the reference and
hardware runs are evidence only. Background: [docs/tools/dartagnan.md](../../docs/tools/dartagnan.md),
[docs/tools/alloy.md](../../docs/tools/alloy.md), [docs/tools/herd7-litmus7.md](../../docs/tools/herd7-litmus7.md).

Kamui's memory model for GPU memory is the PTX ISA 8.7 model (chapter 8 of the PTX manual). These tests and
verdicts are what a Kamui implementation, and the mapping from PTX instructions to Kamui instructions, are
checked against.

## Layout

| Path | Content |
|---|---|
| `ptx/imported/dat3m/` | the 265 safety tests of Dat3M (`litmus/PTX/{Manual,Nvidia,Memalloy,Barrier}`), same paths as upstream |
| `ptx/imported/mixedproxy/` | the 11 NVlabs/mixedproxy tests, expanded to 128 tests and translated to the Dat3M dialect; `src/` holds the originals |
| `ptx/imported/origin.csv` | where every imported test comes from, its licence, its original quantifier and the upstream verdicts |
| `ptx/kamui/families/` | 288 generated tests: 8 classic shapes x orderings x the 4 scopes x 3 thread placements (`tools/litmus/gen_families.py`) |
| `ptx/kamui/hand/` | 10 hand-written tests for features no formal model covers: `mbarrier`, `barrier.cluster`, the async proxy, `.volatile` |
| `alloy/` | the Alloy queries for the 2019 PTX model, generated from the tests (`tools/litmus/to_alloy.py`) |
| `riscv/` | the naive RISC-V lowering of each test, for herd7 and RVWMO (`tools/litmus/to_riscv.py`) |
| `h100/` | one CUDA kernel per runnable test (`kernel.cu`, the compiled `kernel.ptx`, `spec.txt`), for the H100 runs (`tools/litmus/to_cuda.py`) |
| `expected.csv` | one verdict per (test, model, tool) |
| `manual-reasoning.yaml` | verdicts argued by hand from the PTX manual, for tests no tool can decide |
| `allowlist.yaml` | every known disagreement (between tools, with upstream verdicts, or with the H100), with the reason |

## Test format

Tests use the PTX dialect of Dartagnan. Example (`ptx/imported/dat3m/Manual/MP-cta-gpu.litmus`):

```
PTX MP-cta-gpu
"Message passing, sync because release/acquire operations are morally strong"
{
x=0;
y=0;
P1:r1=0;
P1:r2=0;
}
 P0@cta 0,gpu 0         | P1@cta 0,gpu 0         ;
 st.weak x, 1           | ld.acquire.gpu r1, y   ;
 st.release.cta y, 1    | ld.weak r2, x          ;
exists
(P1:r1 == 1 /\ P1:r2 != 1)
```

- `{ ... }` is the initial state: locations and registers, zero unless set. `y @ surface aliases x` declares a
  second name for `x` that is accessed through the surface proxy.
- Each column is a thread. The first row places it: `P0@cta 0,gpu 0` is thread 0 in CTA 0 of GPU 0. Threads in
  different CTAs (or GPUs) are outside a `.cta` (or `.gpu`) scope of each other.
- Instructions are short forms of PTX: `st.weak x, 1`, `ld.acquire.gpu r1, y`, `atom.acq_rel.gpu.add r0, x, 1`,
  `red.relaxed.gpu.add x, 1`, `fence.sc.cta`, `fence.proxy.alias`, `bar.cta.sync 1`, and for loops `LC00:`,
  `beq r1, 1, LC00`, `goto LC00`. `ld r0, 1` puts a constant in a register.
- The last part is the question. **Every test here asks `exists C`**: can the final state satisfy `C`?

Our own tests also write `P0@cta 0,cluster 0,gpu 0` (thread 0 in CTA 0 of cluster 0) and may use the `.cluster`
scope, which Dartagnan does not parse. Cluster placement alone is erased before a test goes to Dartagnan (it
changes nothing when no instruction uses `.cluster`); tests with the `.cluster` scope get verdicts from the
other models only. The hand-written tests use real PTX mnemonics (`mbarrier.arrive.release.cta b`,
`barrier.cluster.wait`, `cp.async.bulk.global.shared::cta g, s`); no tool reads them, and their verdicts are
argued in `manual-reasoning.yaml`.

## Our test families

`ptx/kamui/families/<shape>/<shape>+<ordering>[.<scope>]+<placement>.litmus`, for example
`MP+rel-acq.gpu+same-cluster`: message passing where the flag is written with `st.release.gpu` and read with
`ld.acquire.gpu`, by two threads in different CTAs of one cluster. Shapes: MP, SB, LB, IRIW, CoRR, WRC, ISA2,
2+2W. Orderings: `weak`, `relaxed`, `rel-acq`, `fence-acq_rel`, `fence-sc`, and for MP `fence-rel-acq` (the PTX
8.6 `fence.release`/`fence.acquire`). Placements: `same-cta`, `same-cluster` (one CTA per thread, one cluster),
`diff-cluster` (one cluster per thread). The same tests are run on the H100 as evidence.

## How the imported tests were changed

Upstream tests use three quantifiers, and a tool's PASS/FAIL means different things for each. To make every
verdict read the same way, the final condition was rewritten (`tools/litmus/litmus.py`, `normalize`):

| Upstream | Rewritten as | An upstream "the test holds" means |
|---|---|---|
| `exists C` (175 tests) | `exists C` | allowed |
| `~exists C` (57 tests) | `exists C` | forbidden |
| `forall C` (33 tests) | `exists ~(C)` | forbidden |

Nothing else in a Dat3M file changed, except the name of `Manual/SB+sc-gpu-multiFence-TotalOrder`, which used the
same name as another test upstream.

A mixedproxy test is a template plus a table: each table row fills the template's `$0`, `$1`, ... and ends in
`permit` (the outcome must be possible) or `assert` (the condition must always hold). Every row became one test,
named `<template>+<row>`, with these translations: `[x]` becomes `x`; an access without an ordering becomes
`.weak`; `.volatile` becomes `.relaxed.sys` (PTX ISA 8.7 section 8.4.2); a load written `ld r0, [flag] == 1`
adds `P1:r0 == 1` to the condition; `permit C` gives expected verdict allowed and `assert C` gives
`exists ~(C)` with expected verdict forbidden.

`python tools/litmus/import_tests.py` redoes the import from the Dat3M tree in the dev container (`/opt/dat3m`)
and the vendored mixedproxy files; `--check` verifies the committed files.

## expected.csv

`python tools/litmus/run_formal.py` (dev container, about 35 s on 32 cores) runs every test through every model
that applies and writes this file; `--check` re-runs everything and fails if a row would change (ignoring
`runtime_s`).

| Column | Meaning |
|---|---|
| `test` | path under `tests/litmus/`, without `.litmus` |
| `source` | `dat3m`, `mixedproxy`, or `kamui` for our own tests |
| `condition` | the `exists` condition the verdict answers |
| `model` | see the table below |
| `model_version` | the model file and its sha256 prefix, or the manual version |
| `tool` | `dartagnan`, `alloy`, `herd7`, or `manual` |
| `tool_version` | e.g. `4.4.1`, `4.2 (artifact jar)`, `7.58` |
| `flags` | the exact tool flags |
| `result` | `allowed` (some execution the model accepts satisfies the condition), `forbidden` (none does), `unknown` (the tool could not decide), `error` |
| `runtime_s` | wall time of the tool run, in seconds |

| Model | What it is | Runs on |
|---|---|---|
| `ptx-v7.5` | Dartagnan with Dat3M's `ptx-v7.5.cat`, the mixed-proxy PTX model (PTX ISA 7.5) | tests Dartagnan parses: no `.cluster` scope, no PTX 8.6 fence |
| `ptx-v6.0` | Dartagnan with `ptx-v6.0.cat` (PTX ISA 6.0, no proxies) | the same, without proxy features |
| `ptx-2019-alloy` | the 2019 Alloy model (`deps/ptx-memory-model/ptx.als`, PTX ISA 6.0) with its own driver and Alloy 4.2 jar | tests `to_alloy.py` can express: loads, stores, fences, simple barriers, no proxies or read-modify-writes |
| `ptx-2019-alloy+ext` | the same model with our extensions: a cluster level in the scope tree, and `fence.acquire`/`fence.release` as the model's FenceAcq/FenceRel | tests with the `.cluster` scope or a PTX 8.6 fence |
| `rvwmo` | herd7 7.58 with RISC-V's `riscv.cat`, on the naive RISC-V lowering in `riscv/` (scopes erased) | tests `to_riscv.py` can lower |
| `manual-reasoning` | an argument from the PTX ISA 8.7 manual, in `manual-reasoning.yaml` | tests no tool decides |

Dartagnan runs with `--method=eager --bound=1 --solver=z3`, as in Dat3M's own tests. Alloy answers within a bound
that covers every event of the test. The Alloy jar is copied into the build area before a run, because Alloy
rewrites the jar it is started from (seen again here: the copy's checksum changes).

`rvwmo` is a baseline, not a PTX verdict: it answers the question for a different program, the test lowered to
plain RISC-V with C++-style fences (the mapping table is in `tools/litmus/to_riscv.py`).

Today: 691 tests, 1711 rows. The four PTX models agree on every test that more than one of them decides (the
2019 Alloy model on 367 tests, Dartagnan v7.5 on 606). On the 372 lowered tests, RVWMO forbids every outcome
that PTX forbids, so the naive lowering is sound; it also forbids 86 outcomes that PTX allows, from two sources:
scopes (for example `.cta` synchronization between different CTAs, which PTX does not order and RVWMO, having no
scopes, does) and multi-copy atomicity (IRIW with release/acquire, allowed in PTX, forbidden in RVWMO).

## Checks

`python tools/litmus/check_suite.py` (runs in CI, no Java needed) checks that every test parses and asks
`exists`, that `origin.csv` and `expected.csv` are complete and well formed, and that verdicts agree: with the
upstream verdict of each imported test (Dat3M's `PTXv7_5-expected.csv` and `PTXv6_0-expected.csv`, or the
mixedproxy annotation), and between the PTX models; that the RVWMO lowering forbids whatever PTX forbids; and
that no outcome observed on the H100 is forbidden by the formal verdict, unless the allow-list explains it.
`gen_families.py`, `to_alloy.py` and `to_riscv.py` each have a `--check` mode, also run in CI, that fails when a
committed generated file is stale. Every disagreement must be listed in `allowlist.yaml` with a
reason. Today all 264 Dat3M verdicts and 127 of the 128 mixedproxy annotations match; the exceptions are:

- `Manual/MICRO24-Fig4b-correct` contains a compare-and-swap spin loop that Dartagnan can never unroll
  completely, so it answers `unknown` at any loop bound. Its verdict, forbidden, is argued in
  `manual-reasoning.yaml`.
- `mixedproxy/Release_acquire_pattern`: the mixedproxy annotation (and mixedproxy's own Alloy model) says the
  outcome is permitted; Dartagnan and Dat3M's copy of the same test say forbidden. In mixedproxy's model a fence
  has no proxy, so a fence is never "morally strong" with another thread's operation, and release and acquire
  patterns built from a fence never synchronize. The PTX manual (sections 8.7 and 8.8) lets fences take part in
  such patterns, so we follow Dartagnan. Details in `allowlist.yaml`.

## Running the tests on the H100

The formal verdicts are the reference; running a test on a GPU only shows which outcomes that GPU produces. We run
our own tests (families and hand-written, 302) on the H100 to see which of the outcomes PTX allows the hardware
really shows, and to catch anything it shows that PTX forbids. Results and findings:
[evidence/litmus-h100/](../../evidence/litmus-h100/README.md).

- `tools/litmus/to_cuda.py` writes one kernel per test. Each litmus thread is one `asm volatile` block holding the
  test's exact PTX instructions (`st.release.gpu.global.u32`, `mbarrier.arrive.release.cta.shared::cta.b64`, ...),
  so clang cannot change them; clang 20 compiles the kernel to PTX 8.7 (`kernel.ptx`, committed), which the GPU
  driver compiles further when it loads it, as for any PTX program.
- `tools/litmus/runner/litmus_runner.c` runs a kernel about a million times in batches: each launch is 66 clusters
  of 4 CTAs of 256 threads, and the host decides which GPU thread plays which litmus thread of which instance,
  following the test's placement (`same-cta`: different warps of one CTA; `same-cluster`: different CTAs of one
  cluster; `diff-cluster`: different clusters). 64 threads of every CTA are stress threads. Every location of every
  instance has its own 128-byte line. Three configurations: `plain` (no stress, fixed placement), `stress` (the
  stress threads hammer a 64 MiB buffer), `shuffle` (stress, plus a new random placement, location layout and
  per-thread start delay every launch; for tests with a cluster barrier whole warps are shuffled, because
  `barrier.cluster.arrive.relaxed` needs a converged warp on the H100).
- Every run records each final state with where its threads actually ran (same SM, same cluster, different
  clusters). `tools/litmus/run_h100.py` drives the runs (`jobs/litmus-h100.sh` on the H100 server) and
  `tools/litmus/observed.py` joins them with the formal verdicts.

## The Fence-SC question

The 2019 Alloy model has no separate Fence-SC axiom ("the order of `fence.sc` operations cannot contradict
causality", PTX 8.7 section 8.10.2), while the cat models do. It does not need one: the model puts the Fence-SC
order `sc` inside `cause_base` and its Causality axiom makes `cause` irreflexive, so an `sc` edge against
causality would be a `cause` cycle. The suite agrees: the 2019 model and Dartagnan give the same verdict on all 31
of the 48 `fence.sc` tests the 2019 model can express.

## Origin and licences

| Group | Upstream | Version | Licence |
|---|---|---|---|
| `dat3m/` except `Nvidia/` | [Dat3M](https://github.com/hernanponcedeleon/Dat3M) `litmus/PTX/` | tag 4.4.1 (`d8de5e8`) | CeCILL-B, `ptx/imported/dat3m/LICENSE` |
| `dat3m/Nvidia/` | the same, written by NVIDIA from the mixedproxy tests | tag 4.4.1 | BSD 3-Clause, `ptx/imported/dat3m/Nvidia/LICENSE` |
| `dat3m/Memalloy/` | the same, written by the Dat3M authors from [memalloy](https://github.com/johnwickerson/memalloy) | tag 4.4.1 | CeCILL-B |
| `mixedproxy/` | [NVlabs/mixedproxy](https://github.com/NVlabs/mixedproxy) `tests/` | `0807da2` | BSD 3-Clause, `ptx/imported/mixedproxy/LICENSE` |

`origin.csv` columns: `test`; `source`; `upstream` (path in the upstream repository, and the table row for a
mixedproxy template); `upstream_ref`; `licence`; `quantifier` (the original one); `upstream_ptx_v7_5` and
`upstream_ptx_v6_0` (the upstream verdict translated to allowed/forbidden of our condition, empty when upstream
has none); `note` (what was changed).

Dat3M's verdicts come from its `dartagnan/src/test/resources/PTXv7_5-expected.csv` and `PTXv6_0-expected.csv`
at the same tag; they are stored, translated to allowed/forbidden, in `origin.csv`.
