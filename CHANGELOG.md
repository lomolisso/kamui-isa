# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- PTX 8.7 feature catalog with coverage checks against the manual, clang 20 and the release notes, and the
  generated PTX side of `spec/ptx-table.md`.
- PTX corpus build tools and the tier 1 micro-kernels, one per feature, compiled by clang 20.
- Tier 2 to 4 micro-kernels (memory model, MMA, wgmma, mbarrier, TMA, clusters), completing the PTX corpus.
- H100 environment probe job and its results: driver, toolkit and library versions, and a confirmed PTX 8.7 JIT.

## [0.1.0] - 2026-10-31

### Added

- Development container with the PTX, RISC-V and formal memory-model toolchains.
- `tools/dev.sh` and `tools/build-area.sh` to build on the build host, with tests.
- Project overview, development guide and tool guides with worked examples.
- `sail-riscv`, `riscv-opcodes` and `ptx-memory-model` as shallow submodules.
- CI with lint and test checks.

[Unreleased]: https://github.com/lomolisso/kamui-isa/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lomolisso/kamui-isa/releases/tag/v0.1.0
