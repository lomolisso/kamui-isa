# NVBit (NVIDIA Binary Instrumentation Tool)

## What it is

NVBit is a research library from NVIDIA's Architecture Research Group that
instruments the SASS of a running CUDA program. When a GPU function is loaded
for the first time, NVBit hands its SASS instructions to an *NVBit tool* (a
shared library you write). The tool can insert calls to its own device
functions before or after any SASS instruction. Because it works on SASS at
load time, it needs no source code and works for any compiler: nvcc, clang,
Triton's JIT, PyTorch's precompiled kernels, CUTLASS.

kamui-isa uses NVBit for one thing: **counting which SASS instructions real
workloads execute** (instruction histograms collected on the H100). It is not
used to understand PTX semantics.

- Paper: Villa, Stephenson, Nellans, Keckler, "NVBit: A Dynamic Binary
  Instrumentation Framework for NVIDIA GPUs", MICRO 2019.
  https://github.com/NVlabs/NVBit/releases/download/v1.0/MICRO_19_NVBit.pdf
- Releases and README: https://github.com/NVlabs/NVBit (only the README is
  in git; the library, headers and example tools ship as release tarballs).
- License: covered by the CUDA Toolkit EULA. **Do not commit NVBit headers,
  libraries or its example tools into kamui-isa.** Our own tool source
  (planned under `tools/evidence/nvbit/`) is fine; it is built on the H100 job
  image against the NVBit that the image provides.

## Where it runs

**H100 job image only** (see [h100-jobs.md](h100-jobs.md)). NVBit instruments
code that is actually loaded on a GPU, so it cannot run in the dev container.
You could compile an NVBit tool in the dev container only if you had the NVBit
headers there, which we do not install (licensing and simplicity). Build and
run it inside the job.

## Version pinned

- The job image provides NVBit; its version is unknown until the environment
  probe job (`jobs/env-probe.sh`, see [h100-jobs.md](h100-jobs.md)) records it
  into `evidence/env/`.
- Latest releases at the time of writing (GitHub release notes, read
  2026-10-29): **v1.8.1** (2026-09-29, build system switched from Makefile to
  CMake, `nvbit_set_tool_pthread` renamed `nvbit_set_tool_thread`), v1.8
  (2026-04-06, alpha TMA support for Hopper/Blackwell, `getSassBinary()`),
  v1.7.7.x (2026-02), v1.7.6 (2025-09, `nvbit_dump_cubin()`; note: line info
  is "not available" directly on Hopper, disassemble the dumped cubin with
  `nvdisasm` instead), v1.7.5 (2025-06, "NVBit serializes all kernel
  launches", SASS strings now match `nvdisasm`), v1.7.4 (2025-02).
- README requirements: compute capability 3.5 to 12.1, x86_64 or aarch64
  Linux, GCC >= 8.5, **CUDA >= 12.0**, `nvcc` >= 10.2 to compile tools.
- Recommendation: use whatever the image has if it is >= 1.7.5 (so SASS
  strings match `nvdisasm`, which our SASS parser also reads). If it is older,
  ask the maintainers for 1.7.5 or newer. Record the exact version with every
  histogram.

## Commands we use

Building a tool (NVBit < 1.8.1, Makefile layout of the release tarball):

```bash
export NVBIT_PATH=/opt/nvbit_release      # wherever the image unpacks NVBit; the probe job finds it
cd tools/evidence/nvbit/kamui_sass_hist
make NVBIT_PATH=$NVBIT_PATH ARCH=90a      # produces kamui_sass_hist.so
```

Building with NVBit >= 1.8.1 (CMake):

```bash
cmake -S tools/evidence/nvbit/kamui_sass_hist -B build/nvbit -DNVBIT_PATH=$NVBIT_PATH
cmake --build build/nvbit -j
```

Running: NVBit tools are injected with `LD_PRELOAD`. The tool `.so` is loaded
into the host process, intercepts the CUDA driver API, and instruments each
`CUfunction` the first time it is launched.

```bash
# Any CUDA program, including Python:
LD_PRELOAD=$PWD/build/nvbit/kamui_sass_hist.so \
  KAMUI_OUT=<RESULTS_DIR>/nvbit/cutlass_gemm.csv \
  ./cutlass_gemm_binary --m=4096 --n=4096 --k=4096

LD_PRELOAD=$PWD/build/nvbit/kamui_sass_hist.so \
  KAMUI_OUT=<RESULTS_DIR>/nvbit/triton_matmul.csv \
  python3 tools/workloads/triton_matmul.py
```

Common NVBit environment variables (read by the example tools through
`GET_VAR_INT`; our tool should accept the same names):

| Variable | Meaning |
|---|---|
| `NOBANNER=1` | Do not print the NVBit banner |
| `TOOL_VERBOSE=1` | Print each instrumented function and instruction |
| `KERNEL_BEGIN`, `KERNEL_END` | Instrument only kernel launches with index in [begin, end) |
| `INSTR_BEGIN`, `INSTR_END` | Instrument only instructions with index in [begin, end) of each function |
| `COUNT_WARP_LEVEL` | 1 = count once per warp (default in `instr_count`), 0 = count per thread |
| `EXCLUDE_PRED_OFF` | 1 = do not count lanes whose guard predicate is false |
| `ACTIVE_FROM_START` | 0 = start disabled until the app calls the start marker |

## Input formats

- Any dynamically linked CUDA application (driver or runtime API). Kernels
  loaded from PTX by the driver JIT (our runner, Triton) are instrumented
  too, after JIT.
- The tool sees, per `CUfunction`, a vector of `Instr*` objects. Useful
  accessors: `getSass()` (full SASS string, for example
  `HGMMA.64x128x16.F32 R24, gdesc[UR4], R24, gsb0 ;`), `getOpcode()`
  (`HGMMA.64x128x16.F32`), `getOpcodeShort()` (`HGMMA`), `getOffset()`,
  `getIdx()`, `hasPred()`, `getPredNum()`, `isLoad()`, `isStore()`,
  `getMemorySpace()`, `getNumOperands()` and `getOperand(i)`.

## Output formats

NVBit itself writes nothing. Each tool prints or writes its own format.

### The example `opcode_hist` tool (shipped in the release tarball)

Expected shape (from the tool source in the tarball; to be confirmed on the
job image). After every kernel it prints one header line and one line per
short opcode:

```
kernel 0 - toy(int const*, int*, unsigned int*) - #thread-blocks 4,  kernel instructions 5376, total instructions 5376
  IMAD = 512
  SHFL = 640
  ...
```

This counts by `getOpcodeShort()` only, which throws away the modifiers we
care about (`.STRONG.GPU`, `.E.ADD.F32.FTZ.RN`, scopes, cache hints). That is
why we write our own tool.

### Our tool: `kamui_sass_hist` (planned)

Proposed CSV, one row per static SASS instruction per kernel launch, written
to `$KAMUI_OUT`:

| Column | Type | Meaning |
|---|---|---|
| `workload` | str | Workload id passed in `KAMUI_WORKLOAD` (for example `cutlass_gemm_f16_4096`) |
| `launch_id` | int | Kernel launch index in the process |
| `kernel` | str | Mangled kernel name |
| `pc` | hex | Offset of the instruction in the function |
| `sass` | str | Full `getSass()` string |
| `opcode` | str | `getOpcode()` (base plus modifiers) |
| `opcode_short` | str | `getOpcodeShort()` |
| `warp_execs` | int | Number of times a warp issued this instruction |
| `thread_execs` | int | Sum over issues of active lanes |
| `thread_execs_pred_on` | int | Sum over issues of active lanes whose guard predicate was true |

Classes (see "How kamui-isa uses it") are added offline by a classification
script (planned as `tools/evidence/classify.py`), never inside the tool, so we
can change the class map without rerunning on the H100.

## Worked example

**This runs on the H100 job image and has not been run yet.** The environment
probe job ([h100-jobs.md](h100-jobs.md)) builds the stock `instr_count` and
`opcode_hist` tools from the image's NVBit and runs them on the toy kernel
from [clang-cuda.md](clang-cuda.md) loaded through our PTX runner:

```bash
cd $NVBIT_PATH/tools/opcode_hist && make ARCH=90a
LD_PRELOAD=$NVBIT_PATH/tools/opcode_hist/opcode_hist.so NOBANNER=1 \
  ./build/runner toy.ptx toy > <RESULTS_DIR>/nvbit/toy_opcode_hist.txt
```

Expected output shape (one block per kernel launch): the header line shown
above, followed by lines such as `SHFL = <n>`, `BAR = <n>`, `ATOMS = <n>`,
`REDG = <n>` (or `RED`), `VOTE = <n>`, `EXIT = <n>`. The SASS for the same
kernel, produced in the dev container, is in [cuobjdump.md](cuobjdump.md);
the opcode names in the histogram must match it. If they do not, the NVBit
version is older than 1.7.5 or the driver JIT produced different SASS from
the dev container's `ptxas` (record both).

## How kamui-isa uses it

- **H100 evidence**: instruction histograms for
  1. a CUTLASS 3.x Hopper GEMM (warp-specialized, TMA + `wgmma`), for example
     CUTLASS example `48_hopper_warp_specialized_gemm` or the
     `cutlass_profiler` kernel `cutlass3x_sm90_tensorop_gemm_f16_f16_f32_*`;
  2. a FlashAttention forward kernel. Note: the `flash_attn` 2.x package runs
     its Ampere-style kernels (`mma.sync`, `cp.async`, `ldmatrix`) even on
     H100; FlashAttention-3 (the `hopper/` directory, `flash_attn_interface`)
     is the one with `wgmma`, TMA and warp specialisation. Trace whichever is
     installed and record which; trace both if both are installed, because
     the contrast is itself evidence for tier 3 versus tier 4;
  3. two Triton kernels: tutorial 03 (matrix multiplication; on Hopper,
     recent Triton lowers `tl.dot` to `wgmma` and may use TMA) and tutorial
     02 (fused softmax; a reduction-heavy kernel with no tensor cores). Pin
     the Triton version (record `triton.__version__`) because Triton's
     lowering changes between releases.
- The histograms answer: which SASS classes dominate (and therefore which
  Kamui extensions matter most), how often uniform-datapath (`U*`) and
  convergence (`BSSY`, `BSYNC`, `WARPSYNC`) instructions appear, and how much
  of a kernel is async machinery (`SYNCS`, `UTMALDG`, `UBLKCP`,
  `WARPGROUP.ARRIVE`, `HGMMA`).
- Proposed opcode classes for the classification script (start from
  Accel-Sim's `hopper_opcode.h` map, then split it along Kamui extension
  families): `int_alu` (IADD3, IMAD, LOP3, SHF, LEA, ISETP, IMNMX,
  POPC, FLO, BREV, PRMT, SEL), `fp32` (FADD, FMUL, FFMA, FSETP, FMNMX), `fp16x2`
  (HADD2, HMUL2, HFMA2, HMNMX2), `fp64` (D*), `mufu` (MUFU.*), `convert`
  (F2F, F2I, I2F, F2FP, I2FP), `move` (MOV, S2R, CS2R, S2UR, R2UR, LDC),
  `uniform` (all U* except UTMA*/UBLK*), `warp` (SHFL, VOTE, VOTEU, MATCH,
  REDUX, ELECT), `barrier` (BAR, WARPSYNC, ARRIVES), `convergence` (BSSY,
  BSYNC, BREAK, BMOV), `branch` (BRA, BRX, JMP, CALL, RET, EXIT, YIELD,
  NANOSLEEP), `mem_global` (LDG, STG, LD, ST), `mem_shared` (LDS, STS, LDSM,
  STSM), `mem_local` (LDL, STL), `mem_const` (LDC, ULDC), `atomic` (ATOM,
  ATOMG, ATOMS, RED, REDG), `fence` (MEMBAR, FENCE, ERRBAR, CCTL), `async_copy`
  (LDGSTS, LDGDEPBAR, DEPBAR), `tma` (UTMALDG, UTMASTG, UTMAPF, UTMAREDG,
  UBLKCP, UBLKPF, UBLKRED, UTMACCTL), `mbarrier` (SYNCS.*), `mma` (HMMA, IMMA,
  DMMA, BMMA), `wgmma` (HGMMA, QGMMA, IGMMA, BGMMA, WARPGROUP.*),
  `dsmem` (instructions with distributed shared memory operands), `other`.
  Each class maps to one or two `Xkm*` families; the evidence report should
  show the histogram per class and per family.

## Limitations and gotchas

- **Per-instruction overhead is large.** Instrumenting every instruction of a
  CUTLASS GEMM slows it by 10x to 100x. Use small problem sizes and
  `KERNEL_BEGIN`/`KERNEL_END` to skip warm-up and autotuning launches.
- **Python workloads launch many kernels** (PyTorch initialisation, Triton
  autotuning). Filter by kernel name in the tool (env var `KAMUI_KERNEL_REGEX`)
  and disable Triton autotuning by fixing the config.
- NVBit 1.7.5 and later **serialize all kernel launches**; concurrency
  effects do not matter for counting but timing is meaningless under NVBit.
- Line information is not available directly on Hopper (v1.7.6 notes); use
  `nvbit_dump_cubin()` plus `nvdisasm -g` if you need source lines.
- TMA instrumentation is "alpha" in v1.8. We only count TMA instructions;
  we do not need their addresses.
- Instrumentation changes register allocation of the instrumented function
  (NVBit saves and restores state around each call). It does not change which
  SASS instructions the original code executes, which is all we count.
- The H100 driver JIT may generate slightly different SASS from the dev
  container's `ptxas` for the same PTX if the driver is newer than 12.8. The
  histogram is about real workloads (precompiled SASS mostly), so this only
  matters when comparing to our own corpus.
- Do not commit traces of NVIDIA library kernels' full SASS (licensing rule).
  Histograms (counts per opcode) are fine; per-instruction CSVs of CUTLASS,
  FlashAttention, PyTorch or Triton kernels stay as job artifacts outside git
  unless the maintainers decide otherwise. CUTLASS and FlashAttention are open
  source (BSD), but cuBLAS/cuDNN kernels that PyTorch may call are not;
  filter them out.

## References

- NVBit README and release notes: https://github.com/NVlabs/NVBit and
  https://github.com/NVlabs/NVBit/releases
- NVBit MICRO 2019 paper (link above).
- Accel-Sim tracer (an NVBit tool that writes full SASS traces) and its
  `hopper_opcode.h` opcode map: `util/tracer_nvbit/` in
  https://github.com/accel-sim/accel-sim-framework. Paper: Khairy, Shen,
  Aamodt, Rogers, "Accel-Sim: An Extensible Simulation Framework for
  Validated GPU Modeling", ISCA 2020.
- [ncu](ncu.md) as an independent cross-check of per-opcode counts.
