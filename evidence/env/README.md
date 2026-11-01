# evidence/env/

The H100 job environment, recorded by [jobs/env-probe.sh](../../jobs/env-probe.sh) on 2026-11-01.

| | |
|---|---|
| Jobs | `20261101T154126Z-q000027` (this folder) and `20261101T154155Z-q000028` (`profile/`, the `ncu` check with counter access), both at commit `ff03ed7` |
| Commands | `h100 submit --gpu 3 -- bash jobs/env-probe.sh` and `h100 submit --profile --gpu 3 -- env PROBE_STEPS="jit ncu" bash jobs/env-probe.sh` |
| GPU | NVIDIA H100 NVL, compute capability 9.0, UUID `GPU-1241dcbc-33ea-80bf-5f87-37f7868c3126` (GPU 3 of the server), ECC on, MIG off, 400 W limit |
| Driver | 580.126.20 (CUDA 13.0 driver API) |
| Toolkit in the image | CUDA 12.9.1: nvcc and ptxas 12.9.86, Nsight Compute 2025.2.1, Nsight Systems 2025.1.3, compute-sanitizer 2025.2.1, clang 20.1.8 |
| Libraries | NVBit 1.8.1, CUTLASS v4.4.2 (source), torch 2.11.0+cu129, triton 3.6.0, flash-attn 2.8.3.post2, flashinfer 0.7.2.post1, Python 3.12.3 |

## Results

| Check | Result |
|---|---|
| Driver JIT of `app.vecadd` (PTX 8.7, `sm_90a`) | loads (`CUDA_SUCCESS`), 12 registers, and 1000 of 1000 outputs are correct. **The PTX 8.7 pin holds** |
| Driver JIT of `docs/examples/cuda/bad.ptx` | rejected with `CUDA_ERROR_INVALID_PTX` (218), as expected |
| Offline `ptxas` 12.9 on `app.vecadd` | 12 registers, the same as the JIT |
| NVBit `instr_count` | builds; counts 62588 instructions in NVBit's nvcc-built `vectoradd` and 640 in the JIT-loaded `app.vecadd` |
| `compute-sanitizer` memcheck and racecheck on `app.vecadd` | 0 errors, 0 hazards |
| `ncu` without `--profile` | fails with `ERR_NVGPUCTRPERM`: the server restricts performance counters to administrators |
| `ncu` with `--profile` | works; `smsp__inst_executed.sum` = 640, the same count as NVBit |

## Files

| File | Content |
|---|---|
| `results.tsv`, `manifest.yaml` | one line per check; commit, GPU, driver and results |
| `gpu.txt`, `gpu.csv`, `nvidia-smi.txt`, `nvidia-smi-q.txt` | the GPU as `nvidia-smi` reports it (serial numbers removed) |
| `driver-version.txt` | `/proc/driver/nvidia/version` |
| `nvcc.txt`, `ptxas.txt`, `nvdisasm.txt`, `cuobjdump.txt`, `compute-sanitizer.txt`, `ncu.txt`, `nsys.txt`, `clang.txt` | `--version` of each tool in the image |
| `nvbit.txt`, `cutlass.txt`, `python-packages.txt`, `image-manifest.txt` | library versions; the image's full package list |
| `jit-probe.txt`, `jit-probe-bad.txt`, `ptxas-vecadd.txt` | the JIT check and the offline `ptxas` run |
| `nvbit-build.txt`, `nvbit-nvcc-app.txt`, `nvbit-jit.txt` | the NVBit build and the two instrumented runs |
| `sanitizer-memcheck.txt`, `sanitizer-racecheck.txt` | the sanitizer runs |
| `ncu-metrics.txt` | the failed `ncu` run without counter access |
| `profile/` | the second job: the JIT check again and `ncu-metrics.txt` with all instruction metrics |
| `job.log` | the job's console output |
