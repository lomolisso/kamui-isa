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
| `expected.csv` | one verdict per (test, model, tool) |
| `manual-reasoning.yaml` | verdicts argued by hand from the PTX manual, for tests no tool can decide |
| `allowlist.yaml` | every known disagreement, with the reason |

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

Our own tests may also write `P0@cta 0,cluster 0,gpu 0` and use the `.cluster` scope, which Dartagnan does not
parse; such tests get verdicts from the other models only.

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
| `model` | `ptx-v7.5` (mixed-proxy PTX model, PTX ISA 7.5), `ptx-v6.0` (PTX ISA 6.0, no proxies), `manual-reasoning` |
| `model_version` | the model file and its sha256 prefix, or the manual version |
| `tool` | `dartagnan`, or `manual` |
| `tool_version` | e.g. `4.4.1` |
| `flags` | the exact tool flags |
| `result` | `allowed` (some execution the model accepts satisfies the condition), `forbidden` (none does), `unknown` (the tool could not decide), `error` |
| `runtime_s` | wall time of the tool run, in seconds |

`ptx-v7.5` runs on every test without `.cluster`; `ptx-v6.0` only on tests without proxy features (it does not
know proxies). Dartagnan runs with `--method=eager --bound=1 --solver=z3`, as in Dat3M's own tests.

Today: 393 tests; `ptx-v7.5` says 240 allowed, 152 forbidden, 1 unknown; `ptx-v6.0` (142 tests) agrees with
`ptx-v7.5` on every test both decide.

## Checks

`python tools/litmus/check_suite.py` (runs in CI, no Java needed) checks that every test parses and asks
`exists`, that `origin.csv` and `expected.csv` are complete and well formed, and that verdicts agree: with the
upstream verdict of each imported test (Dat3M's `PTXv7_5-expected.csv` and `PTXv6_0-expected.csv`, or the
mixedproxy annotation), and between models. Every disagreement must be listed in `allowlist.yaml` with a
reason. Today all 264 Dat3M verdicts and 127 of the 128 mixedproxy annotations match; the exceptions are:

- `Manual/MICRO24-Fig4b-correct` contains a compare-and-swap spin loop that Dartagnan can never unroll
  completely, so it answers `unknown` at any loop bound. Its verdict, forbidden, is argued in
  `manual-reasoning.yaml`.
- `mixedproxy/Release_acquire_pattern`: the mixedproxy annotation (and mixedproxy's own Alloy model) says the
  outcome is permitted; Dartagnan and Dat3M's copy of the same test say forbidden. In mixedproxy's model a fence
  has no proxy, so a fence is never "morally strong" with another thread's operation, and release and acquire
  patterns built from a fence never synchronize. The PTX manual (sections 8.7 and 8.8) lets fences take part in
  such patterns, so we follow Dartagnan. Details in `allowlist.yaml`.

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
