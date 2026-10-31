# compute-sanitizer

## What it is

NVIDIA's runtime correctness checker for CUDA programs (successor of
`cuda-memcheck`). It runs the program on the GPU with instrumentation and
reports errors. Four tools:

| `--tool` | Checks |
|---|---|
| `memcheck` (default) | out-of-bounds and misaligned global/shared/local accesses, invalid frees, leaks (`--leak-check full`) |
| `racecheck` | shared-memory data races between threads of a CTA (hazards: write-after-write, read-after-write, write-after-read) |
| `synccheck` | illegal use of synchronization: divergent `__syncthreads`/`bar.sync`, invalid `.sync` masks, `__syncwarp` misuse |
| `initcheck` | reads of uninitialized global memory |

kamui-isa uses it to make sure **corpus kernels are race-free and
well-synchronized** before their H100 outputs become goldens. The H100 is the
oracle for outputs only when the test kernel is race-free: a golden from a
racy kernel is one allowed outcome, not *the* outcome.

## Where it runs

H100 job image only (it needs a GPU). The dev container has the binary
(useful for `--help`) but cannot run kernels. See [h100-jobs.md](h100-jobs.md).

## Version pinned

Dev container (CUDA 12.8.1): `NVIDIA (R) Compute Sanitizer, Version
2025.1.0.0 (build 35583870)`. The job image's version is recorded by the
environment probe job ([h100-jobs.md](h100-jobs.md)).

## Commands we use

`./build/runner` is Kamui's PTX runner (a small driver-API program that loads
a PTX file and launches one entry; see [h100-jobs.md](h100-jobs.md)).

```bash
CS="compute-sanitizer --error-exitcode 99 --print-limit 1000"
$CS --tool memcheck  --leak-check full           ./build/runner <file.ptx> <entry> <args>
$CS --tool racecheck --racecheck-report all      ./build/runner ...
$CS --tool synccheck                             ./build/runner ...
$CS --tool initcheck                             ./build/runner ...

# Machine-readable output for the evidence dataset:
$CS --tool racecheck --save "$OUT/sanitizer/<f>.racecheck.xml" --xml ./build/runner ...
# Or plain text to a file:
$CS --tool racecheck --log-file "$OUT/sanitizer/<f>.racecheck.txt" ./build/runner ...
```

Options used (from `compute-sanitizer --help`, 2025.1): `--tool`,
`--error-exitcode`, `--print-limit`, `--log-file`, `--save`, `--xml`,
`--leak-check full`, `--racecheck-report {analysis,hazard,all}`,
`--racecheck-detect-level {info,warn,error}`,
`--racecheck-memcpy-async yes` (checks `cp.async` hazards, default yes),
`--check-warpgroup-mma yes` ("Enables checks related to the PTX wgmma
instructions for sm_90a architecture", default yes),
`--target-processes all` (needed when the workload is a Python process that
spawns children), `--show-backtrace`.

## Input formats

Any CUDA program. Kernels loaded from PTX through the driver JIT (our runner)
are checked like any other. Line information appears only if the PTX carries
`.loc` (clang `-gline-tables-only`) and the JIT keeps it.

## Output formats

Text on stdout/stderr (or `--log-file`), one block per error, ending with an
`ERROR SUMMARY: N errors` line. With `--save --xml`, an XML record per error.
Exit code is `--error-exitcode` if any error was found, so job scripts can
fail fast.

## Worked example

**This runs on the H100 job image and has not been run yet.** The output
below is the expected shape from the Compute Sanitizer documentation, for the
toy kernel of [clang-cuda.md](clang-cuda.md)
([toy.cu](../examples/cuda/toy.cu)) run through the PTX runner:

```
$ compute-sanitizer --tool racecheck --racecheck-report all --error-exitcode 99 \
    ./build/runner toy.ptx toy
========= COMPUTE-SANITIZER
========= RACECHECK SUMMARY: 0 hazards displayed (0 errors, 0 warnings)
```

If the second `__syncthreads()` of `toy` were removed, the read of `cta_sum`
by thread 0 would race with the `atomicAdd` of other warps' leaders, and
racecheck would print a block of this shape (expected, not measured):

```
========= Error: Race reported between Write access at toy+0x2b0
=========     and Read access at toy+0x340 [N hazards]
=========     in __shared__ memory
...
========= RACECHECK SUMMARY: 1 hazard displayed (1 error, 0 warnings)
```

The offsets refer to SASS offsets (compare with `nvdisasm -c` of the same
cubin, [nvdisasm.md](nvdisasm.md)), which is another reason to keep the
dev-container SASS next to the golden.

## How kamui-isa uses it

- **Golden acceptance**: before a golden is accepted, its corpus entry passes
  `memcheck`, `racecheck` and `synccheck` with zero errors. The job writes
  `evidence/sanitizer/<feature>.{memcheck,racecheck,synccheck}.txt`. Entries
  that fail are fixed in the corpus, not tolerated.
- **Litmus tests**: litmus tests are *intentionally* racy (that is the point
  of a litmus test). Do not run racecheck on them as an acceptance gate;
  record its output only as information.
- **Warp-level features**: `synccheck` validates that `.sync` masks in
  `shfl.sync`, `vote.sync`, `match.sync` entries name exactly the
  participating lanes. The ISA spec should treat a mask violation as
  undefined behaviour, the same as PTX does.

## Limitations and gotchas

- `racecheck` checks **shared memory only**. Global-memory races (including
  racy global atomics mixed with plain loads) are not detected. Corpus
  kernels must be race-free on global memory by construction (each output
  element written by exactly one thread, or only by atomics).
- Slowdown is large (10x to 100x); use small launches.
- Asynchronous features (TMA, `mbarrier`, `wgmma`) have partial coverage;
  `--check-warpgroup-mma` exists for wgmma, but a clean report does not prove
  an async pipeline is race-free.
- Only one tool per run; run the job four times or loop over tools.
- Requires the same driver and permissions as normal CUDA; no special
  counters (unlike [ncu](ncu.md)).

## References

- NVIDIA, *Compute Sanitizer User Manual*:
  https://docs.nvidia.com/compute-sanitizer/ComputeSanitizer/index.html
- `compute-sanitizer --help` in the dev container.
