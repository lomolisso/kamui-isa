# Tool guides

How the project uses each third-party tool: concrete commands, input and output formats, and a worked example with
real output. Tools marked "dev container" run in `kamui-isa-dev:0.2` on the build host, through `tools/dev.sh` (see
[../development.md](../development.md)). Tools marked "H100" need the GPU and run as H100 jobs.

| Tool | Guide | Runs in |
|---|---|---|
| Dev container | [devcontainer.md](devcontainer.md) | build host (Docker) |
| clang 20 (CUDA to PTX) | [clang-cuda.md](clang-cuda.md) | dev container |
| `ptxas` | [ptxas.md](ptxas.md) | dev container |
| `nvdisasm` | [nvdisasm.md](nvdisasm.md) | dev container |
| `cuobjdump` | [cuobjdump.md](cuobjdump.md) | dev container |
| `compute-sanitizer` | [compute-sanitizer.md](compute-sanitizer.md) | H100 |
| NVBit | [nvbit.md](nvbit.md) | H100 |
| `ncu` (Nsight Compute) | [ncu.md](ncu.md) | H100 |
| H100 job workflow | [h100-jobs.md](h100-jobs.md) | H100 |
| Sail and sail-riscv | [sail.md](sail.md) | dev container |
| riscv-opcodes | [riscv-opcodes.md](riscv-opcodes.md) | dev container |
| Spike and pk | [spike.md](spike.md) | dev container |
| binutils `.insn` (and LLVM) | [binutils-insn.md](binutils-insn.md) | dev container |
| herd7, litmus7, diy7 | [herd7-litmus7.md](herd7-litmus7.md) | dev container |
| Alloy | [alloy.md](alloy.md) | dev container |
| Dartagnan | [dartagnan.md](dartagnan.md) | dev container |

Inputs for the worked examples are in [../examples/](../examples/).
