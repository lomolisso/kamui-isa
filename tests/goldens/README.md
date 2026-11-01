# tests/goldens/

The outputs of every corpus kernel on a real H100: the reference that the Sail model, the functional simulator and
the conformance suite are compared against. One folder per corpus entry, named after the entry directory
(`tests/corpus/xkmwarp/shfl.sync.bfly/` gives `tests/goldens/shfl.sync.bfly/`).

| File | Content |
|---|---|
| `<id>/outputs.bin` | the final contents of the entry's `output` and `inout` buffers, in the order of `params` in its `entry.yaml`, raw little-endian, no padding |
| `<id>/golden.yaml` | how the golden was made and what it holds (below) |
| `manifest.yaml` | the job id, the GPU, and the sha256 of every `golden.yaml` and `outputs.bin` |
| `job.yaml` | the job that produced the committed goldens: commit, GPU, driver, toolkit, start and end time |

The committed goldens come from job `20261101T164620Z-q000031` on GPU 3 of the lab's H100 server (an H100 NVL,
driver 580.126.20): 252 entries ran correctly and `trap` failed as it should; every deterministic entry gave the
same bytes in all three runs, and memcheck and racecheck found nothing in any kernel except the intended trap.

The inputs are not stored: `tools/corpus/gen_inputs.py` regenerates them from the seeds in `entry.yaml`, and
`golden.yaml` records their sha256. Compile-only entries (`run: false`) have no golden.

## How they are made

`jobs/goldens.sh` on the H100 server (see [docs/tools/h100-jobs.md](../../docs/tools/h100-jobs.md)) builds
`tools/runner/` and runs `tools/runner/run_all.py`. For each entry the runner loads `kernel.ptx` through the
driver's JIT compiler (`cuModuleLoadDataEx`), the path a PTX loader takes, encodes any tensor map on the host,
launches with `cuLaunchKernelEx` (with the cluster shape when there is one), and copies the outputs back.

- Output buffers are cleared to zero before the launch. Each entry runs three times; a deterministic entry must
  give the same bytes every time.
- A fourth run fills the output buffers with `0xA5` first. Bytes that differ from the zero-filled run were never
  written by the kernel; `golden.yaml` counts them per buffer (`unwritten_bytes`). A model must leave those bytes
  as they were.
- Each entry also runs once under `compute-sanitizer` memcheck and racecheck, to show the kernels are free of
  memory errors and shared-memory races.

`python tools/evidence/check_goldens.py` (run in CI) checks that every runnable entry has a golden made from its
current `kernel.ptx` and inputs, and that the files match their sha256.

## golden.yaml

| Field | Meaning |
|---|---|
| `feature`, `entry` | the catalog id and the entry directory |
| `ptx_sha256`, `inputs_sha256` | the kernel.ptx and inputs.bin the golden was made from |
| `load_path` | `jit` (PTX through the driver) or `cubin` (offline ptxas, a cross-check only) |
| `gpu`, `job_id` | the GPU (name, UUID, driver) and the job that produced the golden |
| `launch` | grid, block, cluster and dynamic shared memory, from `entry.yaml` |
| `result` | `ok`, or `launch-error <code> <name>` (expected only for `property:launch_fails`) |
| `deterministic`, `runs`, `runs_identical` | whether the entry must repeat exactly, how many runs, whether they did |
| `tolerance` | how a model's output is compared with this golden (below) |
| `outputs` | per buffer: `name`, `dtype`, `count`, `offset` and `bytes` in outputs.bin, `sha256`, `unwritten_bytes` |
| `outputs_sha256` | sha256 of outputs.bin |
| `jit_registers` | registers per thread that the driver's JIT allocated |
| `sanitizer` | the memcheck and racecheck summary lines |
| `jit_cubin_dumped` | whether the JIT's cubin was captured for the SASS comparison (`evidence/jit-comparison.tsv`) |

## Tolerance classes

The `tolerance_class` of each entry says how a model's output is compared with the golden:

| Class | Comparison | Used for |
|---|---|---|
| `exact` | bit for bit | integer, logic and bit operations, conversions with an explicit rounding mode, IEEE-correct `.rn` add, mul, fma, div and sqrt, shuffles, votes, `redux`, `prmt`, loads and stores, fixed special registers |
| `ulp:<n>` | at most `n` units in the last place from the golden, per element | `.approx` operations of the special function unit (`sin`, `cos`, `ex2`, `lg2`, `rcp`, `rsqrt`, `tanh`) and `div.approx`/`div.full`; `n` follows the maximum error the PTX manual states for the instruction over the entry's input range |
| `ftz` | exact on normal results; denormal inputs and results must be flushed to zero with the sign kept | entries that test `.ftz` |
| `reduction` | relative error against a float64 reference of the same sum, because the order of a floating-point reduction is not specified | float atomics and `red`, `mma`/`wgmma` accumulation. The inputs are chosen so most sums are exact |
| `property:<name>` | a property instead of values, named after the check: `atomic` (the set of returned old values is a valid serialization), `range`, `monotonic`, `uniform`, `activemask`, `mbarrier`, `completes`, `launch_fails` | special registers and timers that change from run to run, atomics whose return order depends on scheduling, and kernels that must trap |

For a `property` entry the golden still holds the bytes of one run; the comparison rule decides which parts are
checked exactly (the notes of each `entry.yaml` say which).
