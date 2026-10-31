# ncu (Nsight Compute)

## What it is

Nsight Compute's command-line profiler. It replays each selected kernel
launch several times and reads the GPU's hardware performance counters:
instruction counts per pipeline and per SASS opcode, memory traffic per cache
level, stall reasons, occupancy, and per-SASS-instruction execution counts.

In Kamui, **`ncu` is for later timing calibration, not for ISA design.** In
kamui-isa it has two uses: (1) an independent cross-check of the
[NVBit](nvbit.md) instruction histograms, using exact hardware counts per
opcode; (2) later, calibration data for the `kamui` timing simulator
(outside this repository's scope, but the jobs that collect it live here).

## Where it runs

H100 job image only (see [h100-jobs.md](h100-jobs.md)). The dev container
has `ncu` (useful for `--help`, `--query-metrics --chip gh100`, and for
reading `.ncu-rep` files with `ncu -i`), but it cannot profile without a GPU.

## Version pinned

Dev container: `NVIDIA (R) Nsight Compute Command Line Profiler, Version
2025.1.1.0 (build 35528883)`. The job image's version is recorded by the
environment probe job. Reports (`.ncu-rep`) can be opened by the same or newer
`ncu`, so the dev container can read reports produced by a job image with
2025.1 or older.

## Commands we use

`./build/runner` is Kamui's PTX runner ([h100-jobs.md](h100-jobs.md)).

```bash
# Instruction mix per SASS opcode for one kernel (cheap: one section)
ncu --section InstructionStats -k regex:'^toy$' -c 1 \
    -o "$OUT/ncu/toy" -f ./build/runner toy.ptx toy

# Per-SASS-instruction execution counts (Source Counters)
ncu --section SourceCounters -k regex:gemm -s 5 -c 1 -o "$OUT/ncu/gemm" -f ./cutlass_gemm ...

# Specific metrics only
ncu --metrics smsp__inst_executed.sum,sm__inst_executed_pipe_tensor_op_gmma.sum,sm__inst_executed_pipe_uniform.sum,sm__sass_inst_executed_op_global_atom.sum \
    -k regex:toy -c 1 ./build/runner ...

# Everything (slow, about 40 replay passes)
ncu --set full -k regex:toy -c 1 -o "$OUT/ncu/toy_full" -f ./build/runner ...

# Export in the dev container (no GPU needed):
ncu -i toy.ncu-rep --csv --page raw                      > toy_raw.csv
ncu -i toy.ncu-rep --csv --page details                  > toy_details.csv
ncu -i gemm.ncu-rep --page source --print-source sass --csv > gemm_sass_counts.csv
```

Key options (from `ncu --help`, 2025.1.1): `-k`/`--kernel-name`
(`regex:` prefix allowed), `--kernel-name-base {function,demangled,mangled}`,
`-s`/`--launch-skip`, `-c`/`--launch-count`, `--section`, `--set {basic,
detailed,full,nvlink,pmsampling,roofline}`, `--metrics`, `-o`/`--export`,
`-f`, `-i`/`--import`, `--csv`, `--page {details,raw,source,...}`,
`--print-source {sass,ptx,cuda,...}`, `--target-processes all` (Python
workloads), `--replay-mode {kernel,application,range}`,
`--cache-control {all,none}` (default flushes caches between replays),
`--clock-control {base,none}` (default locks clocks to base).

Metric names for Hopper that are useful to us (verified with
`ncu --query-metrics --chip gh100` in the dev container):

| Metric | Meaning |
|---|---|
| `smsp__inst_executed.sum` | Warp-level instructions executed |
| `sass__inst_executed_per_opcode` | Instanced metric: warp instructions per base SASS opcode (used by the InstructionStats section's opcode chart) |
| `inst_executed`, `thread_inst_executed`, `thread_inst_executed_true` | Per SASS instruction (SourceCounters page): warp executions, active-thread executions, and executions with guard predicate true |
| `sm__inst_executed_pipe_{alu,fma,fp64,xu,uniform,tensor}` | Warp instructions per pipeline |
| `sm__inst_executed_pipe_tensor_op_gmma` | HGMMA/QGMMA/IGMMA/BGMMA warp instructions |
| `sm__sass_inst_executed_op_{global_atom,global_red,ld,ldgsts,ldsm,...}` | Warp instructions by memory operation class |
| `sm__sass_inst_executed_op_dshared_{ld,st,atom,redas,stas,tma_st,tma_red}` | Distributed shared memory (cluster) accesses |
| `l1tex__data_bank_conflicts_pipe_lsu_mem_shared_op_gmma` | Shared-memory bank conflicts caused by GMMA operand fetch |

The SourceCounters columns map one-to-one to our NVBit CSV
(`warp_execs` = `inst_executed`, `thread_execs` = `thread_inst_executed`,
`thread_execs_pred_on` = `thread_inst_executed_true`, see
[nvbit.md](nvbit.md)), which makes the cross-check direct.

## Input formats

Any CUDA program (including Python with `--target-processes all`).

## Output formats

- `.ncu-rep` binary report (`-o`), opened with `ncu -i` or the Nsight Compute
  GUI.
- Text to stdout by default: per kernel launch, a header line
  `toy (4, 1, 1)x(128, 1, 1), Context 1, Stream 7, Device 0, CC 9.0` followed
  by one table per section with `Metric Name`, `Metric Unit`, `Metric Value`.
- CSV with `--csv` (`--page raw` gives one row per kernel and one column per
  metric; `--page source --print-source sass` gives one row per SASS
  instruction with its counters).

## Worked example

**This runs on the H100 job image and has not been run yet.** Expected output
shape (from the Nsight Compute CLI documentation) for the toy kernel of
[clang-cuda.md](clang-cuda.md) with 128 threads per CTA and 4 CTAs:

```
$ ncu --section InstructionStats -k regex:toy -c 1 ./build/runner toy.ptx toy
==PROF== Connected to process 1234 (./build/runner)
==PROF== Profiling "toy": 0%....50%....100% - N passes
==PROF== Disconnected from process 1234
  toy (4, 1, 1)x(128, 1, 1), Context 1, Stream 7, Device 0, CC 9.0
    Section: Instruction Statistics
    ---------------------------------------- ----------- ------------
    Metric Name                              Metric Unit Metric Value
    ---------------------------------------- ----------- ------------
    Executed Instructions                           inst          <n>
    Issued Instructions                             inst          <n>
    ...
```

For `toy` the exact counts are predictable from the SASS in
[cuobjdump.md](cuobjdump.md) (16 warps, each executes the straight-line part;
the leader-only block runs once per warp; the final block once per CTA).
Compute the expected count from the SASS and the launch configuration and
compare it with `smsp__inst_executed.sum` as a sanity check of the
measurement pipeline.

## How kamui-isa uses it

- **NVBit cross-check** (optional): on one or two workloads (CUTLASS GEMM, one
  Triton kernel), per-opcode warp counts from `sass__inst_executed_per_opcode`
  or the SourceCounters page must match the NVBit tool's counts. Disagreement
  means a bug in our NVBit tool.
- **Later, in the `kamui` repository**: timing calibration (latency and
  throughput per class). Not used for ISA design decisions.

## Limitations and gotchas

- **Permissions**: reading performance counters needs either root, the
  driver option `NVreg_RestrictProfilingToAdminUsers=0`, or (in containers)
  `CAP_SYS_ADMIN`. Otherwise `ncu` prints `ERR_NVGPUCTRPERM`. The environment
  probe job should test this.
- Replay: `--set full` replays each kernel tens of times; kernels with side
  effects that are not idempotent (atomics into the output) are saved and
  restored by ncu, but this costs time. Profile one launch (`-c 1`).
- Clocks are locked to base by default; timing numbers are not peak numbers.
  For calibration use `--clock-control none` and record it.
- `ncu` and NVBit cannot be combined in one run.
- Per-opcode counts are by *base* opcode; modifiers (`.STRONG.GPU`) are only
  visible in the SourceCounters per-instruction view, by joining on the SASS
  text.

## References

- NVIDIA, *Nsight Compute CLI* documentation:
  https://docs.nvidia.com/nsight-compute/NsightComputeCli/index.html
- NVIDIA, *Kernel Profiling Guide* (metric naming, `smsp__` vs `sm__`):
  https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html
- `ncu --help` in the dev container.
