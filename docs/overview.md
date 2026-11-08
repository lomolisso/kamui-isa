# Kamui ISA overview

Kamui is an open-source RISC-V GPGPU. Its input format is **PTX text, as emitted by clang 20 for `sm_90a`**, with
Hopper-class semantics. This repository is the **architecture**: the ISA specification, the golden models, the
encodings, and the conformance suite. It is a specification that implementations are checked against, never a
description of whatever a compiler or a chip happens to do.

## Three repositories, one dependency direction

| Repository | Owns | Depends on |
|---|---|---|
| `kamui-isa` (this one) | the ISA specification, the golden models (Sail and a C++ functional simulator), the encodings, the conformance suite | nothing of ours |
| `kamui-llvm` | the PTX lifter, the LLVM back end, the driver-API loader | `kamui-isa` |
| `kamui` | the hardware, RTL, and timing simulator | `kamui-isa` |

`kamui-llvm` and `kamui` use this repository as a pinned git submodule. Nothing here may depend on them: no
compiler-specific pragmas, no hardware-specific timing. If the compiler or the hardware needs something the ISA does
not provide, the fix is a change to this repository.

## Goals

- **Near term (tier 1):** a written specification, a Sail model, a fast functional simulator, encoding tables, and
  a conformance suite, such that hand-written Kamui programs for the tier 1 PTX corpus produce the same outputs as
  an NVIDIA H100.
- **Long term (tiers 2 to 4):** up to `wgmma`, TMA, `mbarrier`, and clusters with distributed shared memory, with
  the memory model checked against the formal PTX memory model.

## Input format and the role of the H100

- The input is **PTX text** pinned to the PTX ISA version clang 20 emits for `--cuda-gpu-arch=sm_90a`. Not SASS,
  not NVVM IR, not SPIR-V. The proposed pin is **PTX ISA 8.7** (CUDA 12.8), forced with `--cuda-feature=+ptx87`.
  It is confirmed once the H100 environment reports its CUDA and driver versions (see `tools/clang-cuda.md`).
- All PTX in the corpus is produced by **clang, not nvcc**. `nvcc` and `ptxas` are used only to collect evidence
  and as a syntax oracle.
- **SASS is never an input** and is never translated. It is design evidence: how one PTX instruction becomes one
  instruction or a sequence, how modifiers are encoded, and which hidden mechanisms (convergence barriers, the
  uniform datapath, descriptor-based copies) sit behind the PTX.
- The H100 is the **oracle for outputs and for feature existence**, with tolerances for `.approx`, `.ftz` and
  reduction order, on race-free kernels. It is **not** the memory-model oracle; the formal PTX model is.
- Nsight Compute (`ncu`) is for later timing calibration, not for ISA design.

## Base ISA and register model

- **RV64** with I, M, A, Zicsr, Zfinx, Zdinx, Zhinx, Zba, Zbb, Zbs, Zicond, Zacas, Zalasr, Zabha, Zawrs, Zicntr,
  Zihpm, Zicbop, Zicbom, Zihintntl, Zihintpause, Zbkb and Zbkx. No C. No V. No F or D (floating point lives in the
  integer registers). No RV32.
- **The H100's registers per thread:** `R0` to `R254` (32 bits each) and a zero register, 64-bit values in register
  pairs, predicates `P0` to `P6`. The standard registers `x1` to `x31` are the pairs `R0:R1` to `R60:R61`
  ([design/register-model.md](design/register-model.md)).
- **Kamui instructions are 64 bits long**, in the custom space of the RISC-V long-instruction draft, with 8-bit
  register fields ([design/long-instructions.md](design/long-instructions.md)). Standard RISC-V instructions stay
  32 bits long.
- **Scalar registers per thread** (SIMT), not RVV-wide warps, plus a uniform register file per warp.
- **Warp width is fixed at 32.**
- Shared and local memory are **address windows in a flat address space**, laid out as on the H100, with
  space-specific loads and stores as well as generic ones ([design/addressing.md](design/addressing.md)).

## Extension families and tiers

Custom extensions use the RISC-V vendor prefix `Xkm`. Each family has one specification file.

| Extension | PTX features |
|---|---|
| `Xkmsimt` | warp spawn, convergence barriers and independent thread scheduling, predicate registers and guards, special-register CSRs (`%tid`, `%ntid`, `%ctaid`, `%laneid`, `%warpid`, `%smid`, `%clock64`, `%globaltimer`, cluster ids) |
| `Xkmwarp` | `shfl.sync`, `vote.sync`, `match.sync`, `redux.sync`, `activemask`, `elect.sync` |
| `Xkmbar` | named barriers with counts, `bar.arrive`, `bar.red`, `barrier.cluster` |
| `Xkmscope` | scoped and ordered `ld`, `st`, `atom`, `red`, `fence`, `fence.proxy`, in global, shared (own CTA), local and generic forms |
| `Xkmuni` | uniform registers and predicates, uniform integer instructions, moves between the files, uniform branches |
| `Xkmmbar` | `mbarrier` init, arrive, `arrive.expect_tx`, `try_wait`, `test_wait` with phase parity |
| `Xkmasync` | `cp.async`, `cp.async.bulk`, tensor TMA, commit and wait groups |
| `Xkmmma` | `mma.sync`, `ldmatrix`, `stmatrix`, `wgmma` with descriptors and async completion |
| `Xkmcluster` | cluster CSRs, `mapa`, `shared::cluster` access, distributed shared memory |
| `Xkmmufu` | approximate `rcp`, `rsqrt`, `ex2`, `lg2`, `sin`, `cos`, `tanh` with `.ftz` |
| `Xkmmisc` | `prmt`, `brev`, `bfe`, `bfi`, `nanosleep`, `setmaxnreg`, FP8 and TF32 conversions, packed `f16x2`/`bf16x2` |

| Tier | Class | Contents |
|---|---|---|
| 1 | sm_50 | scalar SIMT, independent thread scheduling, `bar.sync`, shared memory, atomics, `shfl`, `vote`, the uniform datapath; `Xkmsimt`, `Xkmwarp`, `Xkmbar`, `Xkmuni`, minimal `Xkmscope`, `Xkmmufu`, parts of `Xkmmisc` |
| 2 | Volta | the full scoped memory model, `mma.sync`, `ldmatrix` |
| 3 | Ampere | `cp.async`, BF16, TF32, L2 cache hints |
| 4 | Hopper | `wgmma` with the async proxy, `cp.async.bulk` and TMA, `mbarrier`, clusters with distributed shared memory, `setmaxnreg`, FP8 |

## The two-way table

`spec/ptx-table.md` will be a two-way table:

- every Kamui instruction names the PTX construct that justifies it;
- every in-scope PTX instruction has a documented lowering into a bounded number of Kamui instructions.

A change that adds an instruction updates the specification, the Sail model, the encoding table, the two-way table
and the conformance suite **together**. Each instruction should have an obvious NVVM intrinsic or LLVM IR construct
behind it, so the compiler in `kamui-llvm` can target it directly.

## Golden models

- **Sail** gives per-instruction semantics, generated documentation, and later an RTL lockstep reference. Sail
  models one hart. Warps, barriers, `mbarrier` phases, async engines and tensor units are modelled by a SIMT
  scheduler outside Sail that steps per-lane Sail state. See `tools/sail.md`.
- A **fast C++ functional simulator** (C++20, CMake, no dependencies beyond the standard library and a test
  framework) runs the full SIMT model at CUTLASS-GEMM scale. It is checked against Sail lane by lane on the
  conformance suite.

## Design decisions

The execution model was decided on 2026-11-05, one document per question, in [design/](design/README.md). The
guiding rule is that Kamui works like the H100 while staying a RISC-V ISA.

1. **Register model** ([register-model.md](design/register-model.md)): the H100's 255 32-bit registers per thread,
   predicates and guards, 64-bit instructions with 8-bit register fields
   ([long-instructions.md](design/long-instructions.md)).
2. **Convergence** ([convergence.md](design/convergence.md)): independent thread scheduling with convergence
   barriers, required from tier 1.
3. **Memory scopes** ([scope-encoding.md](design/scope-encoding.md)): scope and ordering fields in every memory
   instruction; all GPU memory follows the PTX 8.7 memory model; plain RISC-V loads and stores are `.weak`. The
   memory model itself, every memory instruction's meaning and the lowering from PTX are in
   [spec/memory-model.md](../spec/memory-model.md).
4. **Addressing** ([addressing.md](design/addressing.md)): the H100's windows and its global, shared, local and
   generic instructions.
5. **Uniform datapath** ([uniform-datapath.md](design/uniform-datapath.md)): the H100's uniform registers,
   predicates and instructions.
