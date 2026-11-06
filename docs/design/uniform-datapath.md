# Uniform datapath

Decided 2026-11-05.

## Question

Many values in a GPU kernel are the same in every lane of a warp: kernel parameters, `%ctaid`, counters of
uniform loops, base addresses, TMA and `wgmma` descriptors, the result of `redux.sync`. The H100 keeps them in a
per-warp uniform register file and computes them once per warp. Does Kamui expose the same thing in the ISA?

## Decision

Yes, as on the H100.

| State, per warp | Kamui | H100 |
|---|---|---|
| Uniform registers | `UR0` to `UR62`, 32 bits each; 64-bit values in aligned pairs | the same |
| Uniform zero register | `URZ` (number 63) | the same |
| Uniform predicates | `UP0` to `UP6`; `UPT` (number 7) reads true | the same |

- A uniform register field is 6 bits, a uniform predicate field 3 bits.
- **Uniform instructions:** the integer ALU operations (the H100's `UIADD3`, `UMOV`, `ULOP3`, `USHF`, `UIMAD`
  and others), loads of constants and parameters (`ULDC`), moves between the files (`S2UR` from special registers,
  `R2UR` from a lane register, and the reverse), and uniform branches (`BRA.U`).
- **Uniform operands from the start** for the instructions that need one value per warp: TMA and bulk copies
  (descriptors and coordinates), `wgmma` descriptors, `mbarrier` addresses, `setmaxnreg`, and the results of
  `redux.sync` and `elect.sync`.
- Under independent thread scheduling ([convergence.md](convergence.md)), a uniform instruction runs once for the
  group of lanes that issues it. The uniform registers belong to the warp, so groups of one warp that run apart
  share them. The compiler uses a uniform register only for a value that is the same in all lanes that use it, as
  `ptxas` does.

## Why

Measured on the H100 (`evidence/histograms/README.md`, jobs q33, q231, q237):

- Uniform instructions are 20 to 54% of executed instructions in the CUTLASS Hopper GEMMs, 41 to 50% in cuBLAS's
  BF16 GEMM and cuDNN's convolution, 6.5 to 32.4% in FlashAttention-3 and 28.3% in a Triton matmul, but at most 11%
  in PyTorch operators and divergence-heavy kernels.
- 39 of 182 kernels name `UR56` or higher, most of them up to `UR62`, the last one: all warp-specialized
  CUTLASS GEMMs and attention kernels. So Kamui keeps all 63.
- `redux.sync` with its uniform result takes 46.5 cycles, against 145 for the same sum with shuffles (probe
  `lat-warp`, `evidence/probes/README.md`).
- TMA, bulk copies, `mbarrier` and `setmaxnreg` are issued with uniform operands (`evidence/sass-observations.csv`,
  rows `cp.async.bulk.*`, `setmaxnreg`).

PTX has no uniform registers; uniformity is a compiler decision. Defining the operand conventions of the
asynchronous and warp-level instructions with uniform operands now avoids a second form of each later.

## Consequences

- A second, smaller register file and integer ALU per warp, in hardware and in the simulator.
- The compiler needs a uniformity analysis (LLVM's `UniformityAnalysis`, as used for AMD GPUs) and moves between
  the files.
- No RISC-V extension, standard or vendor, defines warp-uniform registers for a GPU with scalar lanes; this is
  Kamui's own extension.
