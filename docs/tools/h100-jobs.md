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

The cluster-specific parts are unknown at the time of writing and appear as
placeholders. Replace
them in this file once, when the maintainers provide them:

| Placeholder | Meaning |
|---|---|
| `<SUBMIT_CMD>` | Command that submits a job script (for example an `sbatch`-like or a custom CLI) |
| `<IMAGE>` | Name or tag of the H100 job container image |
| `<RESULTS_DIR>` | Directory where a job's artifacts land and from which we copy them back |
| `<REPO_IN_JOB>` | Path at which the repository (or a copy of it) is visible inside the job |
| `<JOB_ID>` | Identifier returned by `<SUBMIT_CMD>` |

## Where it runs

On the H100 job image. Known contents: CUDA 12.x toolkit
(`nvcc`, `ptxas`, `nvdisasm`, `cuobjdump`, `cuda-gdb`, `compute-sanitizer`),
Nsight Compute (`ncu`), Nsight Systems (`nsys`), NVBit, clang-20 with NVPTX,
CUTLASS source, PyTorch with CUDA, Triton, FlashAttention, Python 3 with
`pytest` and `pyyaml`. Exact versions are unknown until the environment probe
job below has run.

## Version pinned

Nothing is pinned by us inside the job image; we **record** versions. The
probe job writes them to `evidence/env/`, and every later job copies the
`evidence/env/` fields it depends on into its own `manifest.yaml`.

Requirement from the PTX pin (PTX ISA 8.7, see [clang-cuda.md](clang-cuda.md)):
the driver must JIT `.version 8.7` PTX, which means an **R570 or newer**
driver (CUDA 12.8 Update 1 lists `>= 570.124.06` on Linux; 12.8 GA lists
`>= 570.117`). If the probe shows an older driver, stop and tell the
maintainers.

## Workflow

1. **Write** the job script in the dev container: `jobs/<name>.sh`
   (for example `jobs/goldens.sh`). It must be self-contained, take no
   interactive input, write only under `$OUT` (= `<RESULTS_DIR>/<name>/<JOB_ID>`),
   and finish with a `manifest.yaml`.
2. **Prepare inputs** in the dev container and commit them first: PTX files,
   cubins if needed, YAML descriptors, input data generators (with seeds).
   The job should not need clang unless the job's purpose requires it.
3. **Submit**: `<SUBMIT_CMD> jobs/<name>.sh`. A contributor writes the job
   script; the maintainers submit it (or give contributors the submit
   command).
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

REPO=${REPO:-<REPO_IN_JOB>}
JOB_ID=${JOB_ID:-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:-<RESULTS_DIR>/<name>/$JOB_ID}
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

Purpose: record everything later work depends on, and confirm the PTX pin.
Outputs go to `$OUT/` and are copied back to `evidence/env/`.

Work section of the template:

```bash
E="$OUT"
nvidia-smi                                   > "$E/nvidia-smi.txt"
nvidia-smi -q                                > "$E/nvidia-smi-q.txt"
nvidia-smi --query-gpu=name,driver_version,compute_cap,clocks.max.sm,memory.total --format=csv > "$E/gpu.csv"
cat /proc/driver/nvidia/version              > "$E/driver-version.txt" 2>&1 || true
nvcc --version                               > "$E/nvcc.txt" 2>&1
ptxas --version                              > "$E/ptxas.txt" 2>&1
nvdisasm --version                           > "$E/nvdisasm.txt" 2>&1
cuobjdump --version                          > "$E/cuobjdump.txt" 2>&1
compute-sanitizer --version                  > "$E/compute-sanitizer.txt" 2>&1
ncu --version                                > "$E/ncu.txt" 2>&1
nsys --version                               > "$E/nsys.txt" 2>&1 || true
(clang++-20 --version || clang++ --version)  > "$E/clang.txt" 2>&1
ls -d /opt/nvbit* /usr/local/nvbit* 2>/dev/null > "$E/nvbit-path.txt" || true
find / -maxdepth 4 -name 'nvbit.h' 2>/dev/null | head -5 >> "$E/nvbit-path.txt" || true
grep -rh "NVBIT_VERSION\|define NVBIT_VER" $(dirname $(head -1 "$E/nvbit-path.txt"))/ 2>/dev/null | head -5 > "$E/nvbit-version.txt" || true
python3 - > "$E/python-packages.txt" 2>&1 <<'EOF'
import importlib, sys
print("python", sys.version.replace("\n", " "))
for m in ["torch", "triton", "flash_attn", "flash_attn_interface", "cutlass", "numpy", "yaml", "pytest"]:
    try:
        mod = importlib.import_module(m)
        print(m, getattr(mod, "__version__", "?"), getattr(mod, "__file__", ""))
    except Exception as e:
        print(m, "NOT AVAILABLE", type(e).__name__)
try:
    import torch
    print("torch.version.cuda", torch.version.cuda, "cudnn", torch.backends.cudnn.version())
    print("device", torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0))
except Exception as e:
    print("torch cuda check failed", e)
EOF
# CUTLASS source location and version
find / -maxdepth 4 -type d -name cutlass 2>/dev/null | head -5 > "$E/cutlass-path.txt" || true
for d in $(cat "$E/cutlass-path.txt"); do
  [ -f "$d/include/cutlass/version.h" ] && grep -E "CUTLASS_(MAJOR|MINOR|PATCH)" "$d/include/cutlass/version.h" >> "$E/cutlass-version.txt"
done
# PTX JIT check: does the driver accept .version 8.7 for sm_90a?
# toy.ptx is compiled in the dev container from docs/examples/cuda/toy.cu and committed before the job runs.
python3 tools/env/jit_probe.py tests/corpus/examples/toy.ptx > "$E/jit-probe.txt" 2>&1 || true
```

`tools/env/jit_probe.py` (planned; about 30 lines) uses `ctypes` on
`libcuda.so` to call `cuInit`, `cuDeviceGet`, `cuCtxCreate`,
`cuModuleLoadDataEx` on the PTX text with the JIT log options, and prints the
CUresult code, the JIT info log and the JIT error log. Success proves the
driver understands PTX 8.7 for sm_90a; `CUDA_ERROR_UNSUPPORTED_PTX_VERSION`
(222) means the driver is too old.

Expected output shape (**this runs on the H100 job image and has not been run
yet**): `gpu.csv` with a row like `NVIDIA H100 80GB HBM3, 570.xx.xx, 9.0, ...`;
`nvcc.txt` ending in `Cuda compilation tools, release 12.N, V12.N.xx`;
`python-packages.txt` with one line per package; `jit-probe.txt` with
`cuModuleLoadDataEx: 0 (CUDA_SUCCESS)` and an info log such as
`ptxas info : Used 14 registers ...`.

## Loading our PTX on the H100

Two ways; the runner should support both and record which one produced a
golden.

### A. Driver JIT (default for goldens)

The PTX text is handed to the driver, which compiles it with its built-in
ptxas for the actual GPU. This is the path `kamui-llvm`'s loader mirrors
(PTX in, device code out), so goldens should come from it.

```c
// tools/runner/runner.c (sketch; our own code, links -lcuda only)
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

## Golden format (proposal)

Per corpus entry, under `tests/goldens/<feature>/`:

- `inputs.bin` (or generated by `tests/corpus/<feature>/gen.py --seed N`),
- `outputs.bin`: raw little-endian buffers in descriptor order,
- `golden.yaml`: `feature`, `ptx_sha256`, `load_path` (`jit` or `cubin`),
  `driver`, `gpu`, `job_id`, `launch` (grid, block, cluster, smem), one entry
  per output buffer with `name`, `dtype`, `shape`, `sha256`, and the
  `tolerance` class from the corpus descriptor.

Raw binaries plus a YAML header keep the conformance diff runner simple and
exact; text dumps are generated for humans only.

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

- The job system's queueing time is unknown; batch many corpus entries per
  job.
- If the job image's CUDA is newer than 12.8, its `ptxas`/`nvdisasm` differ
  from the dev container's. SASS evidence comes from the dev container; JIT
  SASS on the H100 comes from the driver. Record both versions.
- `ncu` and NVBit need permissions the job may not have (performance
  counters, `LD_PRELOAD`). The probe job should try a trivial `ncu` run and
  report the error message if it fails.
- Clocks vary. Nothing in the tier 1 ISA work depends on timing.

## References

- CUDA Driver API, module management (`cuModuleLoadDataEx`, JIT options):
  https://docs.nvidia.com/cuda/archive/12.8.1/cuda-driver-api/group__CUDA__MODULE.html
- CUDA 12.8.1 release notes (driver table):
  https://docs.nvidia.com/cuda/archive/12.8.1/cuda-toolkit-release-notes/index.html
- CUDA minor version compatibility (PTX needs a new enough driver):
  https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html
