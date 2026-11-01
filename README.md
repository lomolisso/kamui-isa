# kamui-isa

The instruction set architecture of **Kamui**, an open-source RISC-V GPGPU that runs **PTX** (as emitted by clang
20 for `sm_90a`) with Hopper-class semantics.

This repository holds the ISA specification, the encodings, the golden models (a Sail model and a fast C++
functional simulator) and the conformance suite. The compiler (`kamui-llvm`) and the hardware (`kamui`) live in
their own repositories and depend on this one. Start with [docs/overview.md](docs/overview.md).

## Getting started

1. Get accounts on iacoma227 (where you edit and use git) and iacoma231 (the build host, where every build and
   container runs), and membership in the `docker` group on iacoma231. Set up passwordless ssh to iacoma231 as
   described in [docs/development.md](docs/development.md).
2. Clone with the dependencies (shallow, never `--recursive`):
   ```bash
   git clone git@github.com:lomolisso/kamui-isa.git
   cd kamui-isa
   git submodule update --init
   ```
3. Open a shell in the dev container (it runs on iacoma231 by itself):
   ```bash
   tools/dev.sh
   ```
4. Read [CONTRIBUTING.md](CONTRIBUTING.md) before your first change.

## Layout

| Path | Content |
|---|---|
| `docs/` | Project overview, development environment, tool guides, worked examples |
| `deps/` | Third-party dependencies as shallow submodules (`sail-riscv`, `riscv-opcodes`, `ptx-memory-model`) |
| `spec/` | The ISA specification; today the generated PTX side of the two-way table `spec/ptx-table.md` |
| `tests/corpus/` | The PTX feature catalog (`catalog.yaml`) and, feature by feature, its micro-kernels |
| `tests/litmus/` | PTX memory-model litmus tests and their verdicts from the formal models |
| `tools/` | Development scripts (`dev.sh`, `build-area.sh`), the catalog scripts (`tools/catalog/`) and their tests |
| `.devcontainer/` | The development image |
| `.github/` | Continuous integration |

## Versioning

The project follows [Semantic Versioning](https://semver.org). Versions stay at `0.x` while the ISA is unstable.
Changes are listed in [CHANGELOG.md](CHANGELOG.md).
