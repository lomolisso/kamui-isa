# H100 jobs

## What it is

The H100 server is reachable only through a job system. A job runs a shell
script inside a container image on a machine with an H100. Everything that
needs the GPU is done this way: golden outputs, NVBit traces,
`compute-sanitizer`, `ncu`, litmus sanity runs. Everything else (clang to PTX,
`ptxas -v`, `cuobjdump`, `nvdisasm`, formal tools) runs in the dev container
(`tools/dev.sh`, see [devcontainer.md](devcontainer.md) and
[development.md](../development.md)) and must not use H100 time.

The H100 is the **oracle for outputs and feature existence** of race-free
kernels (with tolerances for `.approx`, `.ftz` and reduction order). It is
**not** the memory-model oracle; the formal PTX model is (see
[dartagnan.md](dartagnan.md)).

The names used in the rest of this file:

| Name | On the lab's H100 server |
|---|---|
| `<SUBMIT_CMD>` | `h100 submit --gpu 3 --`, the lab's per-user job queue. It returns a job id; `h100 wait <id>` waits for it, `h100 log <id>` shows its output, `h100 queue` shows the queue. Add `--profile` only for `ncu` (see below) |
| `<IMAGE>` | the one job image of the queue, `h100:cuda12.9.1-<hash>` (the tag is a hash of its Dockerfile). Each job is a fresh container of it, removed afterwards |
| `<REPO_IN_JOB>` | a clone of this repository in the server's home directory, checked out at the commit under test. Only the home directory is mounted in the job container; the job starts in the directory it was submitted from |
| `<RESULTS_DIR>` | `$HOME/kamui-jobs` on the server; each job writes to `$HOME/kamui-jobs/<job>/<JOB_ID>/` |
| `<JOB_ID>` | a UTC timestamp plus the queue's job id, for example `20261101T143905Z-q25` |

All jobs run on **GPU 3** of the server, an H100 NVL, so that every result
comes from the same card. The job container sees only that GPU, as device 0,
and its `manifest.yaml` records the card's UUID.

## Where it runs

On the H100 job image. The environment probe (`jobs/env-probe.sh`) records
its exact contents in `evidence/env/`. In short: CUDA 12.9.1 toolkit (`nvcc`,
`ptxas`, `nvdisasm`, `cuobjdump`, `cuda-gdb`, `compute-sanitizer`), Nsight
Compute (`ncu`), Nsight Systems (`nsys`), NVBit 1.8.1, clang 20, CUTLASS
v4.4.2 source, PyTorch, Triton, flash-attn, FlashInfer, Python 3.12 with
`pytest` and `pyyaml`. The driver is R580.

Three toolchains produce machine code from our PTX, and they are not the same
version:

| Where | ptxas | Used for |
|---|---|---|
| dev container | CUDA 12.8 | the SASS and `ptxas -v` files in `evidence/` |
| job image | CUDA 12.9 | offline cubins inside jobs (cross-checks only) |
| driver JIT | the one inside the R580 driver | everything that actually runs: goldens, NVBit, sanitizer |

When it matters that the SASS in `evidence/` is the SASS that ran, a job
dumps the JIT's cubin (NVBit `nvbit_dump_cubin`) and compares the two.

## Version pinned

Nothing is pinned by us inside the job image; we **record** versions. The
probe job writes them to `evidence/env/`, and every later job copies the
`evidence/env/` fields it depends on into its own `manifest.yaml`.

Requirement from the PTX pin (PTX ISA 8.7, see [clang-cuda.md](clang-cuda.md)):
the driver must JIT `.version 8.7` PTX, which means an **R570 or newer**
driver (CUDA 12.8 Update 1 lists `>= 570.124.06` on Linux; 12.8 GA lists
`>= 570.117`). If the probe shows an older driver, stop and tell the
maintainers.

**Confirmed** on 2026-11-01: the server's driver is 580.126.20 (CUDA 13.0
driver API) and it JIT-compiles and runs our `.version 8.7`, `.target sm_90a`
PTX (`evidence/env/jit-probe.txt`).

## Workflow

1. **Write** the job script in the dev container: `jobs/<name>.sh`
   (for example `jobs/goldens.sh`). It must be self-contained, take no
   interactive input, write only under `$OUT` (= `<RESULTS_DIR>/<name>/<JOB_ID>`),
   and finish with a `manifest.yaml`.
2. **Prepare inputs** in the dev container and commit them first: PTX files,
   cubins if needed, YAML descriptors, input data generators (with seeds).
   The job should not need clang unless the job's purpose requires it.
3. **Submit** from the clone on the server, at the commit under test:
   `h100 submit --gpu 3 -- bash jobs/<name>.sh`. Wait with `h100 wait <id>`.
   The queue runs one GPU job at a time and stops by itself if someone else
   starts using the GPU; a stopped job reruns from the start, so job scripts
   must be safe to rerun.
4. **Copy back**: the H100 host does **not** share the NFS home with the
   development machines (the machine where you edit and the build host), so
   results are copied back over ssh. Copy `<RESULTS_DIR>/<name>/<JOB_ID>/`
   into the repository at the committed path the job is for (for example
   `tests/goldens/`, `evidence/env/`, `evidence/histograms/`). Large raw
   outputs that only feed an analysis go to the build area on the build host
   (`build/` inside `tools/dev.sh`, see [development.md](../development.md)),
   not to NFS.
5. **Analyse** in the dev container (`tools/dev.sh`): scripts and report.
   Commit artifacts plus analysis together, citing the job id.

Rules:

- One job per question. Small, fast jobs are easier to rerun.
- Every artifact is reproducible from committed inputs plus the job script.
- Never commit SASS or per-instruction traces of NVIDIA library kernels
  (cuBLAS, cuDNN). Counts and histograms are fine.
- Deterministic inputs: fixed seeds, generated in the job by a committed
  script, or committed input files.

## Job script template

```bash
#!/usr/bin/env bash
# jobs/<name>.sh : <one-line purpose>
# Inputs (committed): <list>
# Outputs (under $OUT): <list>
# Runs on: <IMAGE> with one H100.
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
JOB_ID=${JOB_ID:-$(date -u +%Y%m%dT%H%M%SZ)${H100_JOB_ID:+-q$H100_JOB_ID}}
OUT=${OUT:-$HOME/kamui-jobs/<name>/$JOB_ID}
mkdir -p "$OUT"
exec > >(tee "$OUT/job.log") 2>&1

echo "job: <name>  id: $JOB_ID  host: $(hostname)  start: $(date -Is)"
nvidia-smi --query-gpu=name,driver_version,uuid --format=csv,noheader | tee "$OUT/gpu.txt"

# ---- work ----------------------------------------------------------------
cd "$REPO"
# example: build the runner and run every corpus entry
# cmake -S tools/runner -B "$OUT/build" -G Ninja && cmake --build "$OUT/build"
# python3 tools/goldens/run_all.py --runner "$OUT/build/runner" --corpus tests/corpus --out "$OUT/goldens"

# ---- manifest --------------------------------------------------------------
python3 - "$OUT" <<'EOF'
import sys, yaml, subprocess, datetime
out = sys.argv[1]
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
    except Exception as e: return f"error: {e}"
m = {
  "job": "<name>",
  "finished": datetime.datetime.now().isoformat(),
  "git_commit": sh("git -C ${REPO:-.} rev-parse HEAD"),
  "gpu": sh("nvidia-smi --query-gpu=name,driver_version --format=csv,noheader"),
  "nvcc": sh("nvcc --version | tail -2"),
}
yaml.safe_dump(m, open(f"{out}/manifest.yaml", "w"), sort_keys=False)
EOF
echo "done: $(date -Is)"
```

## The first job: environment probe (`jobs/env-probe.sh`)

Purpose: record everything later jobs depend on, and confirm the PTX pin.
The results are committed in [evidence/env/](../../evidence/env/README.md).

```bash
# on the H100 server, in the clone, at the commit under test
h100 submit --gpu 3 -- bash jobs/env-probe.sh
h100 submit --profile --gpu 3 -- env PROBE_STEPS="jit ncu" bash jobs/env-probe.sh   # ncu with counter access
```

It runs five steps and writes one line per check to `results.tsv`:

| Step | What it checks |
|---|---|
| `versions` | `nvidia-smi`, driver, toolkit tools, NVBit, CUTLASS, Python packages, the image's package list |
| `jit` | [tools/env/jit_probe.py](../../tools/env/jit_probe.py) loads `tests/corpus/base/app.vecadd/kernel.ptx` through the driver JIT, runs it and checks `c = a + b` on all 1000 elements; `docs/examples/cuda/bad.ptx` must be rejected |
| `nvbit` | builds NVBit's `instr_count` tool and preloads it into an nvcc-built program and into the JIT-loaded `app.vecadd` |
| `sanitizer` | `compute-sanitizer` memcheck and racecheck on `app.vecadd` |
| `ncu` | `ncu` collects instruction metrics on `app.vecadd` |

`jit_probe.py` uses `ctypes` on `libcuda.so.1`, so it needs neither the
toolkit nor a Python CUDA package:

```
$ python3 tools/env/jit_probe.py tests/corpus/base/app.vecadd/kernel.ptx --launch-vecadd
ptx: tests/corpus/base/app.vecadd/kernel.ptx  version 8.7  target sm_90a  entry k_app_vecadd  sha256 088f3463...
driver api version: 13.0  (13000)
device 0: NVIDIA H100 NVL  compute capability 9.0
cuModuleLoadDataEx: 0 (CUDA_SUCCESS)
jit info log:
ptxas info    : 0 bytes gmem
ptxas info    : Compiling entry function 'k_app_vecadd' for 'sm_90a'
...
ptxas info    : Used 12 registers, used 0 barriers
launch: 1000/1000 elements match
result: ok
```

`CUDA_ERROR_UNSUPPORTED_PTX_VERSION` (222) would mean the driver is too old
for PTX 8.7. `bad.ptx` gives `CUDA_ERROR_INVALID_PTX` (218), the same error
the offline `ptxas` reports (see [ptxas.md](ptxas.md)).

Results (2026-11-01, job `20261101T154126Z-q000027`): every check passes
except `ncu` without `--profile`, which fails with `ERR_NVGPUCTRPERM`
because the server restricts GPU performance counters to administrators.
With `--profile` it works, and on `app.vecadd` `ncu` and NVBit count the same
640 warp-level instructions.

## Loading our PTX on the H100

Two ways; the runner should support both and record which one produced a
golden.

### A. Driver JIT (default for goldens)

The PTX text is handed to the driver, which compiles it with its built-in
ptxas for the actual GPU. This is the path `kamui-llvm`'s loader mirrors
(PTX in, device code out), so goldens should come from it.

```c
// a sketch of what tools/runner/runner.c does (our own code, links -lcuda only)
#include <cuda.h>
char info[8192], err[8192];
CUjit_option opts[] = { CU_JIT_INFO_LOG_BUFFER, CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES,
                        CU_JIT_ERROR_LOG_BUFFER, CU_JIT_ERROR_LOG_BUFFER_SIZE_BYTES,
                        CU_JIT_LOG_VERBOSE };
void *vals[] = { info, (void*)(size_t)sizeof info, err, (void*)(size_t)sizeof err, (void*)1 };
cuInit(0); cuDeviceGet(&dev, 0); cuCtxCreate(&ctx, 0, dev);
CUresult r = cuModuleLoadDataEx(&mod, ptx_text /* NUL-terminated */, 5, opts, vals);
cuModuleGetFunction(&fn, mod, "toy");          // extern "C" name from the corpus
// allocate and fill buffers from the YAML descriptor, then:
cuLaunchKernel(fn, gx, gy, gz, bx, by, bz, smem_bytes, 0, args, NULL);
cuCtxSynchronize();
// copy outputs back and write them in the golden format
```

Cluster launches (tier 4) need `cuLaunchKernelEx` with a
`CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION` attribute; kernels using more than
48 KB of dynamic shared memory need `cuFuncSetAttribute(fn,
CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, n)`.

The `cuda.h` header comes from the job image's toolkit at build time; it is
never copied into the repository.

### B. Offline ptxas to cubin

`ptxas -arch=sm_90a -o k.cubin k.ptx` (in the dev container or in the job),
then `cuModuleLoad(&mod, "k.cubin")`. Use it when the JIT path fails, and to
check that the dev container's SASS (used as evidence) is the SASS that ran.
To do that check, dump the JIT-produced cubin with NVBit's
`nvbit_dump_cubin()` (NVBit 1.7.6 or newer, see [nvbit.md](nvbit.md)) and
compare its `nvdisasm` output with the dev container's. Reading the driver's
JIT cache directory is not a reliable alternative.

## Golden format

The goldens are in `tests/goldens/`; their format, how they are made and the tolerance classes are described in
[tests/goldens/README.md](../../tests/goldens/README.md). The runner is `tools/runner/runner.c` (driver API
only), driven by `tools/runner/run_all.py`, and the job is `jobs/goldens.sh`.

## How kamui-isa uses it

- **Environment probe**: the first job (above) records the toolchain, the
  driver and the libraries, and confirms that the driver accepts PTX 8.7.
- **Goldens**: H100 outputs for every corpus entry; NVBit histograms
  ([nvbit.md](nvbit.md)); `compute-sanitizer` checks that corpus kernels are
  race-free ([compute-sanitizer.md](compute-sanitizer.md)).
- **Litmus sanity runs**: observed outcome counts, never the forbidden set
  ([herd7-litmus7.md](herd7-litmus7.md)).
- **Later**: `ncu` timing calibration for the `kamui` timing simulator
  ([ncu.md](ncu.md)).

## Limitations and gotchas

- One GPU job runs at a time in the queue; batch many corpus entries per job.
- The job image's CUDA (12.9) is newer than the dev container's (12.8), and
  the driver JIT is newer still. SASS evidence comes from the dev container;
  the SASS that runs comes from the driver. Record both versions.
- The driver caches JIT results in the home directory. A cache hit returns an
  empty JIT log, so jobs set `CUDA_CACHE_DISABLE=1` when they need the log.
- `ncu` needs `h100 submit --profile` (the server sets
  `RmProfilingAdminOnly=1`); without it every metric fails with
  `ERR_NVGPUCTRPERM`. Use `--clock-control none`. NVBit (`LD_PRELOAD`) needs no
  special permission.
- Only the home directory is visible in a job; the container's `/tmp` is a
  RAM disk that disappears with the job. Write results under `$OUT`.
- Clocks vary. Nothing in the tier 1 ISA work depends on timing.

## References

- CUDA Driver API, module management (`cuModuleLoadDataEx`, JIT options):
  https://docs.nvidia.com/cuda/archive/12.8.1/cuda-driver-api/group__CUDA__MODULE.html
- CUDA 12.8.1 release notes (driver table):
  https://docs.nvidia.com/cuda/archive/12.8.1/cuda-toolkit-release-notes/index.html
- CUDA minor version compatibility (PTX needs a new enough driver):
  https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html
