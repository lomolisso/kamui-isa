# Glossary

Short definitions of the terms used across kamui-isa.

| Term | Meaning |
|---|---|
| **PTX** | Parallel Thread Execution: NVIDIA's virtual GPU instruction set, emitted by compilers (here clang 20) and compiled to machine code by `ptxas` or the driver. Kamui's input format. |
| **SASS** | NVIDIA's real machine code for a specific GPU (here Hopper, `sm_90a`). We only read it as evidence; it is never translated. |
| **`sm_90a`** | The compile target for the H100 with arch-specific ("a") features such as `wgmma` and `setmaxnreg`. |
| **H100** | NVIDIA Hopper GPU we use as the oracle for outputs and feature existence. |
| **Golden (output)** | The output buffers an H100 produces for a corpus entry; the reference our models must match (within a tolerance). |
| **Corpus entry** | One small CUDA kernel exercising one PTX feature, with its PTX and a YAML descriptor. |
| **Two-way table** | `spec/ptx-table.md`: PTX feature to Kamui lowering, and Kamui instruction back to the PTX that justifies it. |
| **Lowering** | The sequence of Kamui instructions that implements one PTX instruction. |
| **Tier** | A milestone of the ISA: 1 (sm_50 class) to 4 (Hopper class). See `overview.md`. |
| **`Xkm*`** | Kamui's custom RISC-V extensions (vendor prefix `Xkm`), one per family (`Xkmsimt`, `Xkmwarp`, ...). |
| **Thread, lane, warp** | A thread runs one instance of a kernel. A warp is 32 threads that issue together; each thread's slot in the warp is its lane. |
| **CTA (thread block)** | Cooperative Thread Array: a group of warps sharing shared memory and barriers. |
| **Cluster** | Hopper: a group of CTAs that can access each other's shared memory (distributed shared memory, DSMEM). |
| **SIMT** | Single Instruction, Multiple Threads: the GPU execution model; Kamui implements it with scalar registers per thread. |
| **Divergence, reconvergence** | When lanes of a warp take different branch directions, and when they come back together. |
| **IPDOM** | Immediate post-dominator: the reconvergence point used by stack-based divergence (Vortex `split`/`join`). |
| **Independent thread scheduling (ITS)** | Volta-style model where each thread has its own PC and reconvergence is not guaranteed; SASS shows `BSSY`/`BSYNC`. |
| **Uniform datapath** | H100 registers and ALU (`UR*`, `S2UR`, `ULDC`) for values identical across the warp. |
| **Warp aggregation** | `ptxas` turning many lanes' atomics to one address into one atomic plus shuffles. |
| **Scope** | How far a memory operation's ordering must be visible: `.cta`, `.cluster`, `.gpu`, `.sys`. |
| **Memory model, RVWMO** | The rules for which values loads may return under concurrency. RVWMO is RISC-V's (weak) memory ordering. |
| **Litmus test** | A tiny concurrent program plus a question "can this outcome happen?". Formal tools answer allowed or forbidden. |
| **Proxy, async proxy** | PTX's name for different paths into memory (normal accesses vs. TMA, `wgmma`); crossing them needs `fence.proxy`. |
| **TMA** | Tensor Memory Accelerator: Hopper's descriptor-driven bulk copy engine (`cp.async.bulk.tensor`). |
| **`mbarrier`** | A barrier object in shared memory with phases and transaction counts, used with async copies. |
| **`wgmma`** | Warpgroup (4 warps) asynchronous matrix multiply on Hopper. |
| **Sail** | A language for ISA semantics; `sail-riscv` is the official RISC-V model. Our golden model extends it. |
| **Hart** | RISC-V's word for a hardware thread with its own registers and PC. In Kamui each lane behaves like a hart. |
| **riscv-opcodes** | The RISC-V project's encoding-table format and generators; used for `encodings/`. |
| **Spike** | The reference RISC-V instruction-set simulator. |
| **Dev container** | The Docker image `kamui-isa-dev` with all dev tools. See `tools/devcontainer.md`. |
| **Worktree** | A second checkout of the repository on its own branch (`git worktree`), under `.worktrees/`, one per change. |
