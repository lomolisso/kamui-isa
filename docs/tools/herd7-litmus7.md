# herd7, litmus7, diy7 (herdtools7)

## What it is

herdtools7 is the standard toolkit for memory-model litmus tests (Alglave, Maranget and
others, INRIA and Arm):

- **herd7** is a memory-model simulator. It takes a litmus test and a model written in
  the `.cat` language and enumerates every candidate execution, keeping those the model
  allows. It prints the final states that can occur and whether the test's condition can
  be satisfied.
- **litmus7** turns litmus tests into C programs with inline assembly that run the test
  millions of times on a real CPU and count the outcomes. It targets CPUs only (x86,
  Arm, Power, RISC-V, MIPS); it has no GPU back end today.
- **diy7** (and `diyone7`, `diycross7`) generates litmus tests from "cycles" of relations,
  for example all two-thread tests built from `PodWW Rfe PodRR Fre`.

For kamui-isa, herd7 is **the RVWMO oracle** (the RISC-V side of our mapping) and the
tool we would use if we wrote the Kamui memory model as a scoped `.bell`/`.cat` model.
It **cannot run PTX tests** (see "Limitations"); PTX verdicts come from Dartagnan
([dartagnan.md](dartagnan.md)) and Alloy ([alloy.md](alloy.md)). Words such as RVWMO,
litmus test and scope are explained in the [glossary](../glossary.md).

## Where it runs

Dev container (`kamui-isa-dev:0.2`, see [devcontainer.md](devcontainer.md)). herd7 needs
no hardware. litmus7 output would run on a RISC-V machine, which we do not have; we do
not use litmus7 today.

## Version pinned

| Item | Value |
|---|---|
| herdtools7 | **7.58**, installed with opam in the dev container image (`ARG HERDTOOLS_VERSION=7.58` in the Dockerfile) |
| Binaries | `herd7`, `litmus7`, `diy7`, `diyone7`, ... in `/opt/opam/default/bin` (on `PATH`) |
| Model library | `/opt/opam/default/share/herdtools7/herd/` (same content as `herd/libdir/` in the source tree), contains `riscv.cat`, `riscv-defs.cat`, `riscv-tso.cat`, ... |
| Source for reading | upstream https://github.com/herd/herdtools7 at commit [`6bea2e8`](https://github.com/herd/herdtools7/tree/6bea2e8131feaeb497a7bf86d52d94cdd8721a6c) (2026-10-29, `VERSION.txt` says `7.58+1`) |

Check with `herd7 -version` (prints `7.58, Rev: exported`).

## Commands we use

```bash
# run one RISC-V test against RVWMO
herd7 -model riscv.cat test.litmus

# several tests, keep only the verdict lines
herd7 -model riscv.cat tests/*.litmus | grep -E '^(Test|Observation)'

# write the executions that satisfy the condition as .dot graphs (the output directory must exist)
mkdir -p build/herd && herd7 -model riscv.cat -show prop -o build/herd test.litmus   # -> build/herd/<name>.dot

# use a model file from another directory (e.g. our own scoped model)
herd7 -I spec/models -model kamui.cat test.litmus

# generate a RISC-V test from a cycle of relations (prints an MP-shaped test)
diyone7 -arch RISCV PodWW Rfe PodRR Fre

# litmus7: produce a C harness for a real RISC-V machine (not used now; the output
# directory must exist, and -mach needs a <name>.cfg file, which 7.58 does not ship for riscv)
mkdir -p build/litmus7 && litmus7 -o build/litmus7 test.litmus
```

All commands above except the last were checked in the container on 2026-10-30
(`litmus7 -mach riscv` fails with `Cannot find file riscv.cfg`).

`riscv.cat` is found automatically in herd's library directory, so `-model riscv.cat` is
enough.

## Input formats

### RISC-V litmus syntax

Our example [MP+fence.w.w+fence.r.r.litmus](../examples/memory-model/riscv/MP+fence.w.w+fence.r.r.litmus):

```
RISCV MP+fence.w.w+fence.r.r
"Message passing with fences on both sides: stale data is forbidden by RVWMO."
{
0:x5=x; 0:x6=y;
1:x5=y; 1:x6=x;
}
 P0          | P1          ;
 ori x7,x0,1 | lw x7,0(x5) ;
 sw x7,0(x5) | fence r,r   ;
 fence w,w   | lw x8,0(x6) ;
 sw x7,0(x6) |             ;
exists (1:x7=1 /\ 1:x8=0)
```

- Line 1: architecture (`RISCV`) and name. Optional quoted comment.
- `{ ... }`: initial state. `0:x5=x` means "register x5 of thread 0 holds the address of
  location x". Memory locations are zero unless set (`x=1;`).
- Columns separated by `|`, one per thread, each row ends with `;`. Real RISC-V assembly:
  `lw`, `sw`, `amoadd.w.aq`, `lr.w`, `sc.w.rl`, `fence r,rw`, `fence.tso`, branches with
  labels.
- Final condition: `exists`, `~exists`, or `forall`, over `thread:register` and
  locations, with `/\` and `\/`. herd syntax uses `=` (Dartagnan accepts both).

A large public RISC-V corpus exists: https://github.com/litmus-tests/litmus-tests-riscv
(thousands of tests with expected results from the RVWMO model). The Dat3M copy in the
dev container also carries about 6850 RISC-V tests in `/opt/dat3m/litmus/RISCV/`.

### `.cat` models

A `.cat` file defines relations and axioms. herd's `riscv.cat`
(`/opt/opam/default/share/herdtools7/herd/riscv.cat`, upstream
[`herd/libdir/riscv.cat` lines 21 to 28](https://github.com/herd/herdtools7/blob/6bea2e8131feaeb497a7bf86d52d94cdd8721a6c/herd/libdir/riscv.cat#L21-L28)):

```
include "riscv-defs.cat"        (* defines ppo, the 13 preserved-program-order rules *)
include "cos-opt.cat"           (* computes coherence order *)
acyclic co|rf|fr|po-loc as Coherence
acyclic co|rfe|fr|ppo as Model
empty rmw & (fre;coe) as Atomic
```

### Scoped models in herd: `.bell` files and `scopes:`

herd7 has generic support for scope trees, used by its tutorial (and historically by
GPU models): a `.bell` file declares the scopes with `enum scopes` plus `narrower` and
`wider` functions, and tags fences or accesses with scopes; the litmus test, written in
the generic **LISA** language (header `LISA` or `Bell`), places threads in a tree with a
`scopes:` line. The `.cat` file then uses `tag2scope('cta')` to get "same CTA" relations.
Example from the upstream
[`catalogue/tutorial/`](https://github.com/herd/herdtools7/tree/6bea2e8131feaeb497a7bf86d52d94cdd8721a6c/catalogue/tutorial):

```
(* bells/jaguar.bell *)
enum scopes = 'cta || 'gpu || 'system
let narrower(s) = match s with || 'system -> 'gpu || 'gpu -> 'cta end
let wider(s) = match s with || 'gpu -> 'system || 'cta -> 'gpu end
instructions F[scopes]

(* tests/mp-mit-scopes+fcta+fgpu.litmus *)
Bell MP-mit-scopes+fcta+fgpu
{ x = 0; y = 0; }
 P0       | P1        ;
 w[] x 1  | r[] r1 y  ;
 f[cta]   | f[gpu]    ;
 w[] y 1  | r[] r2 x  ;
scopes: (system (gpu (cta P0) (cta P1)))
exists (1:r1 = 1 /\ 1:r2 = 0)
```

This is how a herd version of the PTX or Kamui model would be written: add `'cluster`
between `'cta` and `'gpu`, and annotate `R`, `W`, `F` with orderings and scopes. It is
an option for the Kamui memory model, not something that exists today.

## Output formats

```
Test MP Allowed                    <- name; "Allowed"/"Required" = what the test asks
States 4                           <- number of distinct final states the model allows
1:x7=0; 1:x8=0;
...
Ok                                 <- condition satisfied by at least one allowed execution
Witnesses
Positive: 1 Negative: 3            <- executions satisfying / not satisfying the condition
Condition exists (1:x7=1 /\ 1:x8=0)
Observation MP Sometimes 1 3       <- Never / Sometimes / Always
Time MP 0.00
Hash=55d3882e55247a23bf8e29b49cb9c3fd
```

How to read it:

- **Ok / No**: for an `exists` condition, `Ok` means the outcome is **allowed**, `No` means
  it is **forbidden**. For `~exists`, `Ok` means the outcome never happens (forbidden),
  `No` means it can happen. For `forall`, `Ok` means every allowed execution satisfies it.
- **Positive / Negative**: how many allowed executions do or do not satisfy the condition.
- **Observation Never / Sometimes / Always**: the same information as a word.
  `Never` = forbidden, `Sometimes` = allowed but not required, `Always` = required.
- **Hash**: identifies the test text; litmus7 logs carry the same hash so model results and
  hardware results can be joined.

## Worked example

Run on 2026-10-30 in `kamui-isa-dev:0.2` (herd7 7.58; H1 re-run through `tools/dev.sh` on
2026-10-31 with the command below, same output). The inputs are in
[docs/examples/memory-model/](../examples/memory-model/). From the repository root:

```bash
tools/dev.sh 'cd docs/examples/memory-model && herd7 -model riscv.cat riscv/MP+fence.w.w+fence.r.r.litmus'
```

**H1: MP with `fence w,w` and `fence r,r`, expected forbidden** (0.047 s wall):

```
Test MP+fence.w.w+fence.r.r Allowed
States 3
1:x7=0; 1:x8=0;
1:x7=0; 1:x8=1;
1:x7=1; 1:x8=1;
No
Witnesses
Positive: 0 Negative: 3
Condition exists (1:x7=1 /\ 1:x8=0)
Observation MP+fence.w.w+fence.r.r Never 0 3
Time MP+fence.w.w+fence.r.r 0.01
Hash=426c1bcfa7320f3c1dd50dba71d07397
```

The stale outcome `1:x7=1; 1:x8=0` is missing from the three states: **forbidden**.

**H2: the same test without fences ([MP.litmus](../examples/memory-model/riscv/MP.litmus),
`herd7 -model riscv.cat riscv/MP.litmus`), expected allowed** (0.016 s wall):

```
Test MP Allowed
States 4
1:x7=0; 1:x8=0;
1:x7=0; 1:x8=1;
1:x7=1; 1:x8=0;
1:x7=1; 1:x8=1;
Ok
Witnesses
Positive: 1 Negative: 3
Condition exists (1:x7=1 /\ 1:x8=0)
Observation MP Sometimes 1 3
Time MP 0.00
Hash=55d3882e55247a23bf8e29b49cb9c3fd
```

Dartagnan with its own `riscv.cat` gives the same two verdicts (FAIL = forbidden,
PASS = allowed; [dartagnan.md](dartagnan.md), example D6).

**H3: herd7 on a PTX test, expected to fail**
(`herd7 -model riscv.cat ptx/MP+rel.gpu+acq.gpu.litmus`, 0.014 s):

```
Fatal: File "ptx/MP+rel.gpu+acq.gpu.litmus" Adios
Fatal error: exception Failure("File \"ptx/MP+rel.gpu+acq.gpu.litmus\", line 2, character 0: Uncaught exception in splitter Misc.UserError(\"PTX is not an implemented architecture\")")
```

## How kamui-isa uses it

- **RVWMO side of the litmus suite**: every PTX test in the suite (planned under
  `tests/litmus/ptx/`) gets a RISC-V counterpart (planned under `tests/litmus/riscv/`)
  that uses the proposed lowering with plain RVWMO instructions (scopes erased to system
  scope). herd7 gives its RVWMO verdict. Check: every outcome forbidden by PTX is also
  forbidden by the RVWMO lowering. This proves nothing about scopes but catches mapping
  mistakes in the fence placement early. herd7 rows go into `tests/litmus/expected.csv`
  with `tool=herd7, tool_version=7.58, model=riscv.cat` (format in
  [dartagnan.md](dartagnan.md)).
- **Option for the Kamui memory model**: write `kamui.bell` plus `kamui.cat` (RVWMO
  events with `'cta 'cluster 'gpu 'sys` scope tags) for herd7, as a readable executable
  statement of the `Xkmscope` model. Alternatives: a Dartagnan cat (needs Java changes for
  scope tags) or Alloy ([alloy.md](alloy.md)). Open question: which of the three to use.
- **Kamui assembly litmus tests** (tier 2): the litmus suite lowered to Kamui assembly
  must give, on the functional simulator, only outcomes that the formal model allows.
  herd7's output format (state list plus Hash) is a convenient format for the
  simulator's litmus runner to emit, so results can be compared with `mcompare7`.

## Running litmus tests on the H100

litmus7 cannot target GPUs, and herdtools7 7.58 has no PTX architecture (H3 above), even
though `litmus/option.ml` still mentions `GPU_PTX`, a leftover of the GPU litmus support
that Alglave et al. used in 2015. Options surveyed:

| Option | What it is | Usable for us? |
|---|---|---|
| GPU litmus of Alglave et al., ASPLOS 2015 | an extended litmus tool that generated CUDA/OpenCL harnesses with "incantations": memory stress on other locations, bank-conflict generation, thread randomization, thread synchronization before each run | design reference only; the code is not in herdtools7 7.58 |
| Sorensen and Donaldson, PLDI 2016, "Exposing Errors Related to Weak Memory in GPU Applications" | systematic tuning of memory stress (which addresses, which access pattern) to raise weak-behaviour rates | design reference for the stress parameters |
| GPUHarbor / MC Mutants (Levine et al., ISSTA 2023 and ASPLOS 2023) | WebGPU and Vulkan litmus harness with a large parameter space (testing workgroups, stress workgroups, stress patterns, memory strides, thread permutation); mutation testing measures how good a parameter set is | best modern design; it runs WGSL/SPIR-V, not PTX, so reuse the method, not the code |
| Dartagnan / Alloy | formal tools | they are the oracle; they do not run hardware |
| Hand-written CUDA harness with inline PTX | our own generator | **used** (below) |

**Our harness** (tools/litmus/, described in [tests/litmus/README.md](../../tests/litmus/README.md)):

1. `tools/litmus/to_cuda.py` turns each test into one kernel (`tests/litmus/h100/<test>/kernel.cu`): every
   litmus thread is one `asm volatile` block with the exact PTX of the test, so clang cannot change the
   instructions under test. clang 20 compiles it to PTX 8.7 (committed as `kernel.ptx`), which the GPU driver JIT
   loads, as a PTX loader would.
2. `tools/litmus/runner/litmus_runner.c` launches a grid of 66 clusters of 4 CTAs of 256 threads. The host tells
   every GPU thread whether it is "role k of instance i" or a stress thread, following the test's placement (same
   CTA in different warps, different CTAs of one cluster, different clusters); 64 threads per CTA are always
   stress threads. Every location of every instance has its own 128-byte line.
3. Three configurations: `plain` (no stress, fixed placement), `stress` (the stress threads read and write a
   64 MiB scratch buffer), `shuffle` (stress plus a new random placement, location layout and per-thread start
   delay every launch). Each run counts every final state together with where the threads actually ran (same SM,
   same cluster, different clusters), read from `%smid` and `%clusterid`.
4. `jobs/litmus-h100.sh` runs it on the H100; `tools/litmus/observed.py` turns the histograms into
   `evidence/litmus-h100/observed.csv` and `summary.csv`, joined with the formal verdicts.
5. **Interpretation**: an outcome the formal model forbids but the H100 shows means a bug in the harness, the
   test, the model, or the hardware, and must be investigated; it never changes `expected.csv`. An allowed outcome
   that never shows up is normal and is only reported: the H100 is stronger than the PTX model.

## Limitations

- **No PTX**: herd7 7.58 rejects PTX tests (`PTX is not an implemented architecture`), and
  herd ships no PTX `.cat` except an old pre-Volta demo
  ([`catalogue/demo/cats/ptx.cat`](https://github.com/herd/herdtools7/blob/6bea2e8131feaeb497a7bf86d52d94cdd8721a6c/catalogue/demo/cats/ptx.cat),
  based on `membar.cta/gl/sys`, which is not the PTX 6.0+ model). Dat3M's PTX cat files
  use Dat3M-only relations and do not load in herd7.
- **No GPU back end** in litmus7.
- herd7 enumerates executions explicitly, so tests with many threads or loops get slow;
  Dartagnan scales better for those.
- The scope support (`.bell`, `scopes:`) works only with LISA tests, not with the RISCV
  front end, so a scoped Kamui model in herd would describe abstract events, not real
  Kamui assembly.

## References

- herdtools7: <https://github.com/herd/herdtools7>, manual at <https://diy.inria.fr/doc/herd.html>;
  source [`doc/herd.tex`](https://github.com/herd/herdtools7/blob/6bea2e8131feaeb497a7bf86d52d94cdd8721a6c/doc/herd.tex)
  (scopes: lines 1469-1515)
- Alglave, Maranget, Tautschnig, "Herding Cats", TOPLAS 2014
- Alglave et al., "GPU Concurrency: Weak Behaviours and Programming Assumptions", ASPLOS 2015
- Sorensen, Donaldson, "Exposing Errors Related to Weak Memory in GPU Applications", PLDI 2016
- Levine et al., "GPUHarbor: Testing GPU Memory Consistency at Large", ISSTA 2023, <https://doi.org/10.1145/3597926.3598095>
- RISC-V litmus tests: <https://github.com/litmus-tests/litmus-tests-riscv>
- [glossary](../glossary.md), [dartagnan.md](dartagnan.md), [alloy.md](alloy.md), [h100-jobs.md](h100-jobs.md)
