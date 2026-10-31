# ptxas

## What it is

`ptxas` is NVIDIA's PTX assembler and optimiser. It turns PTX text into a
**cubin** (an ELF file with SASS machine code for one GPU architecture). It
does real compilation work: register allocation, scheduling, instruction
selection into SASS, and some surprising rewrites (warp-aggregated atomics,
`atom` to `RED`, extra fences), which is why its output is design evidence
for us.

kamui-isa uses `ptxas` for three things, and never as part of the Kamui
toolchain itself:

1. **Syntax oracle**: if `ptxas -arch=sm_90a` rejects a PTX file, the file is
   not valid PTX 8.7 for `sm_90a`. Mandatory for every inline-asm corpus
   entry, because clang does not check inline asm.
2. **Resource usage** (`-v`): registers, shared memory, barriers, stack and
   spills per kernel. Evidence for the register-model decision (how many
   registers real kernels need, compared with the 32 registers of RISC-V).
3. **Cubin producer** for SASS inspection with [cuobjdump](cuobjdump.md) and
   [nvdisasm](nvdisasm.md).

## Where it runs

Dev container (`/usr/local/cuda/bin/ptxas`). The H100 job image also has one
(its version may differ; the environment probe job records it). The driver on
the H100 contains its own JIT copy of ptxas, used when we load PTX with
`cuModuleLoadDataEx` (see [h100-jobs.md](h100-jobs.md)).

## Version pinned

```
ptxas: NVIDIA (R) Ptx optimizing assembler
Cuda compilation tools, release 12.8, V12.8.93
Build cuda_12.8.r12.8/compiler.35583870_0
```

It accepts `.version` up to 8.7 and rejects newer (recorded when the test file
was at `out/v90.ptx`):

```
ptxas out/v90.ptx, line 1; fatal   : Unsupported .version 9.0; current version is '8.7'
```

## Commands we use

```bash
# Syntax check + cubin + resource usage (the standard corpus step):
ptxas -arch=sm_90a -v -o k.cubin k.ptx

# Syntax check only (discard output):
ptxas -arch=sm_90a -o /dev/null k.ptx

# Warn on spills and local memory (useful for register-pressure evidence):
ptxas -arch=sm_90a -v --warn-on-spills --warn-on-local-memory-usage -o k.cubin k.ptx

# Register cap experiments (register-model decision):
ptxas -arch=sm_90a -v -maxrregcount=32 -o k.cubin k.ptx

# Keep line info so nvdisasm -g can map SASS back to PTX/CUDA lines:
ptxas -arch=sm_90a -v -lineinfo -o k.cubin k.ptx
```

Useful options from `ptxas --help` (12.8): `-arch` (`--gpu-name`), `-v`
(`--verbose`), `-O<N>` (default 3), `-lineinfo`, `-g` (device debug, disables
optimisation), `-maxrregcount`, `--warn-on-spills`,
`--warn-on-local-memory-usage`, `--fmad <true|false>`, `-Werror`,
`--suppress-async-bulk-multicast-advisory-warning`.

## Input formats

PTX text. The `.target` line must not be higher than `-arch`:
`ptxas -arch=sm_80` on an `sm_90a` file fails with
`ptxas fatal : SM version specified by .target is higher than default SM version assumed`.

## Output formats

- A cubin (ELF, `ELF 64-bit LSB executable, NVIDIA CUDA architecture`), read
  with `cuobjdump`/`nvdisasm`.
- With `-v`, lines on stderr. Annotated real output for `toy.ptx`
  (from [clang-cuda.md](clang-cuda.md)):

```
ptxas info    : 0 bytes gmem                                  <- __device__ globals in this module
ptxas info    : Compiling entry function 'toy' for 'sm_90a'   <- one block per .entry
ptxas info    : Function properties for toy
    0 bytes stack frame, 0 bytes spill stores, 0 bytes spill loads   <- local-memory use; spills mean register pressure
ptxas info    : Used 14 registers, used 1 barriers, 4 bytes smem     <- per-thread registers, named barriers (bar.sync ids), static shared memory
ptxas info    : Compile time = 4.376 ms
```

Notes on reading it:

- "Used N registers" is per thread, after allocation, out of a 255 maximum on
  sm_90 (256 including the zero register RZ). For `wgmma` kernels expect
  values near 168 to 255 and look for `setmaxnreg` effects.
- "used 1 barriers" counts named barrier ids (0 to 15) used by `bar`/`barrier`.
- "4 bytes smem" is the kernel's static shared memory only. `cuobjdump
  -res-usage` reports `SHARED:1028` for the same kernel because sm_90 reserves
  1 KB of shared memory per CTA at offset 0 (`.nv.shared.reserved.0`,
  symbol `.nv.reservedSmem.offset0`). That reserved window is why our SASS
  computes shared addresses as `0x400 + ...` (see [cuobjdump.md](cuobjdump.md)).
- `cmem[0]` size appears in `cuobjdump -res-usage` as `CONSTANT[0]:552`:
  kernel parameters start at `c[0x0][0x210]` on sm_90.
- Informational codes such as
  `ptxas info : (C7508) Potential Performance Loss: 'setmaxnreg' ignored; unable to determine register count at entry.`
  mean ptxas silently dropped an instruction. Record these in the evidence:
  the SASS will not contain the feature.

## Worked example

Working directory and `$EX` as set up in [clang-cuda.md](clang-cuda.md)
(`build/examples/cuda` inside the dev container, sources in
[docs/examples/cuda/](../examples/cuda/)).

```
$ ptxas -arch=sm_90a -v -o toy.cubin toy.ptx
ptxas info    : 0 bytes gmem
ptxas info    : Compiling entry function 'toy' for 'sm_90a'
ptxas info    : Function properties for toy
    0 bytes stack frame, 0 bytes spill stores, 0 bytes spill loads
ptxas info    : Used 14 registers, used 1 barriers, 4 bytes smem
ptxas info    : Compile time = 4.376 ms
```

As a syntax oracle: [bad.ptx](../examples/cuda/bad.ptx) is a hand-written file
with three Hopper-era lines:

```
	atom.acq_rel.gpu.global.add.u32 %r1, [%rd1], 1;   // valid
	fence.acq_rel.cluster;                            // valid
	shfl.sync.bfly.b32 %r2, %r1, 1, 31;               // invalid: membermask missing
```

```
$ cp $EX/bad.ptx . && ptxas -arch=sm_90a -o /dev/null bad.ptx
ptxas bad.ptx, line 11; error   : Arguments mismatch for instruction 'shfl'
ptxas fatal   : Ptx assembly aborted due to errors
```

After adding the mask (`..., 1, 31, -1;`) the file assembles:

```
$ sed 's/, 1, 31;/, 1, 31, -1;/' bad.ptx > good.ptx
$ ptxas -arch=sm_90a -v -o good.cubin good.ptx
ptxas info    : 0 bytes gmem
ptxas info    : Compiling entry function 'bad' for 'sm_90a'
ptxas info    : Function properties for bad
    0 bytes stack frame, 0 bytes spill stores, 0 bytes spill loads
ptxas info    : Used 8 registers, used 0 barriers
ptxas info    : Compile time = 1.852 ms
```

The `.version 9.0` check above is the same file with the version changed:
`sed 's/.version 8.7/.version 9.0/' good.ptx > v90.ptx`.

Architecture checks are explicit. `wgmma_sm90.ptx` is the `llc-20` output of
[wgmma_intrinsics.ll](../examples/cuda/wgmma_intrinsics.ll) (see
[clang-cuda.md](clang-cuda.md)) with the target changed to plain `sm_90`:

```
$ sed 's/sm_90a/sm_90/' wgmma_intrinsics.ptx > wgmma_sm90.ptx
$ ptxas -arch=sm_90 -o /dev/null wgmma_sm90.ptx
ptxas wgmma_sm90.ptx, line 21; error   : Instruction 'setmaxnreg.inc' not supported on .target 'sm_90'
ptxas wgmma_sm90.ptx, line 22; error   : Instruction 'wgmma.fence' not supported on .target 'sm_90'
...
```

Register cap:

```
$ ptxas -arch=sm_90a -v -maxrregcount=8 -o /dev/null toy.ptx
ptxas warning : For profile sm_90a adjusting per thread register count of 8 to lower bound of 24
...
```

So sm_90a has a floor of 24 registers per thread for `-maxrregcount`.

## How kamui-isa uses it

- **PTX corpus**: every corpus PTX file must pass `ptxas -arch=sm_90a`; the
  corpus build fails otherwise. Keep the `-v` output next to the PTX.
- **H100 evidence**: `ptxas -v` lines per corpus entry go into
  `evidence/ptxas/<feature>.txt` and into the per-feature dataset (columns
  `regs`, `smem_static`, `barriers`, `stack`, `spill_st`, `spill_ld`,
  `ptxas_info_codes`). The cubin feeds `cuobjdump`/`nvdisasm`.
- **Register-model decision**: register counts of real kernels (CUTLASS,
  FlashAttention) from `cuobjdump -res-usage` on their binaries, compared with
  the 32-register RISC-V files.
- **Litmus tests**: syntax check of the PTX litmus kernels before the H100 run
  ([herd7-litmus7.md](herd7-litmus7.md)).

## Limitations and gotchas

- `ptxas` checks syntax and target support, not semantics. A race or a wrong
  mask in a `.sync` instruction assembles fine.
- `ptxas` reports the first error per line and may stop early; fix and rerun.
- `-arch=compute_90a` (listed in `--help` as parse-only) was rejected by
  12.8.93 with `Unsupported gpu architecture 'compute_90a'`. Use
  `-arch=sm_90a -o /dev/null` for parse-only checks.
- The dev container's `ptxas` (12.8) and the H100 driver's JIT may differ if
  the driver is newer. SASS evidence is taken from the dev container cubin;
  record the driver version with every H100 result.
- ptxas rewrites matter for evidence: unused-result `atom` becomes `RED`,
  uniform-address atomics become warp-aggregated, `wgmma.commit_group` with no
  preceding `wgmma.mma_async` gets a dummy `HGMMA` inserted, and `setmaxnreg`
  may be dropped (C7508). Always read the SASS, not only the PTX.

## References

- NVIDIA, *CUDA Compiler Driver NVCC* and *PTX Compiler API* docs (ptxas
  options): https://docs.nvidia.com/cuda/archive/12.8.1/cuda-compiler-driver-nvcc/index.html
- `ptxas --help` in the dev container.
- PTX ISA 8.7 manual: https://docs.nvidia.com/cuda/archive/12.8.1/parallel-thread-execution/index.html
