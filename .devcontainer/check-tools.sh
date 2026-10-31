#!/usr/bin/env bash
# Print the version of every tool in the kamui-isa dev image.
# Usage (from the repo root, on the host):
#   tools/dev.sh .devcontainer/check-tools.sh        (runs on the build host iacoma231)
set -u
row() { printf '%-26s %s\n' "$1" "$(eval "$2" 2>&1 | head -n 1)"; }
row "clang-20"                 "clang --version"
row "clang NVPTX target"       "llc --version | grep -c nvptx | sed 's/^/nvptx backends: /'"
row "clang RISC-V target"      "llc --version | grep -c riscv | sed 's/^/riscv backends: /'"
row "llvm-mc"                  "llvm-mc --version | grep -i version"
row "nvcc (CUDA)"              "nvcc --version | tail -n 2 | head -n 1"
row "ptxas"                    "ptxas --version | tail -n 2 | head -n 1"
row "nvdisasm"                 "nvdisasm --version | tail -n 2 | head -n 1"
row "cuobjdump"                "cuobjdump --version | tail -n 2 | head -n 1"
row "riscv64-unknown-elf-gcc"  "riscv64-unknown-elf-gcc --version"
row "riscv64-unknown-elf-as"   "riscv64-unknown-elf-as --version"
row "spike"                    "spike --help 2>&1 | head -n 1"
row "pk"                       "ls /opt/riscv/riscv64-unknown-elf/bin/pk"
row "sail"                     "sail --version"
row "z3"                       "z3 --version"
row "herd7"                    "herd7 -version"
row "litmus7"                  "litmus7 -version"
row "diy7"                     "diy7 -version"
row "java"                     "java -version"
row "alloy"                    "ls /opt/alloy"
row "dartagnan"                "ls \$DAT3M_HOME/dartagnan/target/dartagnan.jar"
row "cmake"                    "cmake --version"
row "ninja"                    "ninja --version"
row "g++-14"                   "g++-14 --version"
row "python3"                  "python3 --version"
row "pandas"                   "python3 -c 'import pandas; print(pandas.__version__)'"
