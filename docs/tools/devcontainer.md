# Dev container

## What it is

A Docker image, `kamui-isa-dev`, with every tool the development side of kamui-isa needs. No GPU is
needed. It is defined in [`.devcontainer/`](../../.devcontainer/):

| File | Purpose |
|---|---|
| [`.devcontainer/Dockerfile`](../../.devcontainer/Dockerfile) | The image. Every version is pinned with an `ARG` at the top of its stage. |
| [`.devcontainer/devcontainer.json`](../../.devcontainer/devcontainer.json) | Lets VS Code (or any devcontainer client) open the repository inside the image. |
| [`.devcontainer/requirements.txt`](../../.devcontainer/requirements.txt) | Pinned Python packages, installed into `/opt/venv`. |
| [`.devcontainer/bin/`](../../.devcontainer/bin/) | Small wrappers copied to `/usr/local/bin` (for example `dartagnan`). |
| [`.devcontainer/check-tools.sh`](../../.devcontainer/check-tools.sh) | Prints the version of every tool. Run it after every image change. |

Everything that needs the H100 (golden outputs, NVBit, `compute-sanitizer`, `ncu`) runs in the H100
job image instead; see [h100-jobs.md](h100-jobs.md).

The machines, the build area and its cleanup policy are described in
[docs/development.md](../development.md). This page covers the image itself.

## Build

The image lives on the build host, iacoma231, never on iacoma227 (see
[docs/development.md](../development.md)). Docker keeps its images on `/srv/docker`, which on
iacoma231 is the same disk as `/scratch`. From the repository root on iacoma227:

```bash
ssh iacoma231 df -h /srv/docker          # the image is about 16 GB; keep at least 100 GB free
ssh iacoma231 "cd $PWD && docker build \
  --build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g) \
  -t kamui-isa-dev:0.2 .devcontainer"
```

A clean build takes about 30 to 40 minutes (Spike, Dartagnan and herdtools7 are built from source).
The UID arguments make the files you create in the container belong to you on the host. `$PWD`
works on iacoma231 because the NFS home directory has the same path on both machines. To use the
image on another host, stream it there instead of rebuilding (see
[docs/development.md](../development.md)).

## Use

The easiest way, from the main checkout or any worktree under `.worktrees/`, is
[`tools/dev.sh`](../../tools/dev.sh):

```bash
tools/dev.sh                          # interactive shell, same directory
tools/dev.sh 'clang --version'        # one command
```

Called on iacoma227, `tools/dev.sh` runs itself on iacoma231 over ssh, in the same directory. It
mounts the main repository root at its own host path, so git works inside the container even in a
worktree. It also mounts the build area `/scratch/$USER/kamui-isa/build/<checkout>` over the
checkout's `build/`, so build outputs land on the local disk of iacoma231. The comment at the top of
`tools/dev.sh` lists its environment variables (build host, image tag, memory cap, extra mounts).
For the build area and its cleanup rules, see [docs/development.md](../development.md).

Use `tools/dev.sh` for everything. A plain `docker run` (for debugging the wrapper) must also run on
iacoma231, and it gets no build-area mount:

```bash
ssh iacoma231 "docker run --rm -v $PWD:/workspaces/kamui-isa -w /workspaces/kamui-isa kamui-isa-dev:0.2 \
  bash -lc 'clang --version'"
```

VS Code: connect to **iacoma231** with the Remote-SSH extension (not to iacoma227), open the
repository folder, and choose "Reopen in Container" (Dev Containers extension). It uses the image
already on iacoma231 if the tag matches; otherwise it builds one. That container does not mount the
build area, so run builds and tests through `tools/dev.sh` in a terminal.

## Pinned versions

| Component | Pin | Where it comes from |
|---|---|---|
| Base image | `nvidia/cuda:12.8.1-devel-ubuntu24.04` (digest `sha256:520292dbb4f7...ed66`) | Docker Hub |
| CUDA toolkit (no driver) | 12.8.1: nvcc, ptxas, nvdisasm, cuobjdump | base image |
| LLVM / clang | 20.1.8 (NVPTX and RISC-V targets) | apt.llvm.org `llvm-toolchain-noble-20` |
| RISC-V GNU toolchain | gcc 13.2.0, binutils 2.42, picolibc | Ubuntu 24.04 packages |
| Spike | commit `4c6a9bc79dab` of [riscv-isa-sim](https://github.com/riscv-software-src/riscv-isa-sim/tree/4c6a9bc79dab80616932949707e7c0471d8e9e54) | built from source, `/opt/riscv` |
| riscv-pk | commit `9c61d29846d8` | built from source, `/opt/riscv/riscv64-unknown-elf/bin/pk` |
| Sail | 0.20.3 (the version `deps/sail-riscv` requires) | official binary release, `/opt/sail` |
| z3 | 4.13.0 | Ubuntu package |
| herdtools7 (herd7, litmus7, diy7) | 7.58 | opam, system OCaml, `/opt/opam` |
| Java | OpenJDK 17 | Ubuntu package |
| Alloy | 6.2.0 | GitHub release, `/opt/alloy` |
| Dartagnan (Dat3M) | 4.4.1 | built from source with Maven, `/opt/dat3m` |
| CMake, Ninja, g++ | 3.28.3, 1.11.1, g++-14 14.2.0 | Ubuntu packages |
| Python | 3.12.3, venv `/opt/venv` with `requirements.txt` | Ubuntu package + pip |

Environment variables set in the image: `CUDA_HOME=/usr/local/cuda`, `DAT3M_HOME=/opt/dat3m`,
`DAT3M_OUTPUT=/tmp/dat3m-output` (inside the container), and `PATH` with all the tools above.
`clang` on the `PATH` is clang 20.

Tool pages: [sail.md](sail.md), [spike.md](spike.md), [riscv-opcodes.md](riscv-opcodes.md),
[binutils-insn.md](binutils-insn.md), [clang-cuda.md](clang-cuda.md).

## Worked example: check every tool

```bash
tools/dev.sh .devcontainer/check-tools.sh
```

Output (2026-10-29):

```text
clang-20                   Ubuntu clang version 20.1.8 (++20250804090239+87f0227cb601-1~exp1~20250804210352.139)
clang NVPTX target         nvptx backends: 2
clang RISC-V target        riscv backends: 2
llvm-mc                    Ubuntu LLVM version 20.1.8
nvcc (CUDA)                Cuda compilation tools, release 12.8, V12.8.93
ptxas                      Cuda compilation tools, release 12.8, V12.8.93
nvdisasm                   Cuda compilation tools, release 12.8, V12.8.90
cuobjdump                  Cuda compilation tools, release 12.8, V12.8.90
riscv64-unknown-elf-gcc    riscv64-unknown-elf-gcc (13.2.0-11ubuntu1+12) 13.2.0
riscv64-unknown-elf-as     GNU assembler (2.42-1ubuntu1+6) 2.42
spike                      Spike RISC-V ISA Simulator 1.1.1-dev
pk                         /opt/riscv/riscv64-unknown-elf/bin/pk
sail                       Sail 0.20.3 (sail2 @ 60695b1ea377048f0adc39c62671cd099b2ed9f6)
z3                         Z3 version 4.13.0 - 64 bit - build hashcode 3049f578a8f98a0b0992eca193afe57a73b30ca3
herd7                      7.58, Rev: exported
litmus7                    7.58
diy7                       7.58
java                       openjdk version "17.0.20.1" 2026-08-18
alloy                      alloy-6.2.0
dartagnan                  /opt/dat3m/dartagnan/target/dartagnan.jar
cmake                      cmake version 3.28.3
ninja                      1.11.1
g++-14                     g++-14 (Ubuntu 14.2.0-4ubuntu2~24.04.1) 14.2.0
python3                    Python 3.12.3
pandas                     2.2.3
```

## Changing the image

1. Edit `.devcontainer/Dockerfile` (change the `ARG` pin) or `requirements.txt`.
2. Rebuild on iacoma231 with a new tag (for example `kamui-isa-dev:0.3`) and run `check-tools.sh`.
   Then update the table above, the history below, and every reference to the tag
   (`grep -rl 'kamui-isa-dev:0' --exclude-dir=deps .`, including `tools/dev.sh`).
3. Remove the old tag on every host that has it: `ssh iacoma231 docker image rm kamui-isa-dev:<old>`.
   Update the image's row in the registry table of [docs/development.md](../development.md).

Image history:

| Tag | Change |
|---|---|
| `0.1` | First image. |
| `0.2` | Removed Jupyter (`jupyterlab`, `nbconvert`, `nbformat`, `ipykernel`): the project writes Markdown, not notebooks. Built on iacoma227, streamed to iacoma231 on 2026-10-31 and removed from iacoma227. |

## Gotchas

- Spike at the pinned commit needs its nested `berkeley-softfloat-3` submodule to build. The image
  build clones riscv-isa-sim and initializes that submodule inside the container.
- riscv-pk needs a C library to pass `configure`. The image passes `--specs=picolibc.specs`.
- clang 20 prints a warning that CUDA 12.8 is only partially supported. This is expected; see
  [clang-cuda.md](clang-cuda.md).
- The image has the CUDA toolkit but no driver and no GPU. Anything that launches a kernel fails
  here.
- The image user `dev` gets the UID passed at build time. If your UID differs from the one the image
  was built with, either rebuild with your own `--build-arg USER_UID=$(id -u)`, or add
  `--user "$(id -u):$(id -g)" -e HOME=/tmp` to `docker run` so that files written to the mount
  belong to you.
