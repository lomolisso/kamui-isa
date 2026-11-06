# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Execution-model design decisions in `docs/design/`: H100 register model, 64-bit instructions, convergence, scopes,
  addressing and the uniform datapath.
- PTX 8.7 feature catalog with coverage checks against the manual, clang 20 and the release notes, and the
  generated PTX side of `spec/ptx-table.md`.
- PTX corpus build tools and the tier 1 micro-kernels, one per feature, compiled by clang 20.
- Tier 2 to 4 micro-kernels (memory model, MMA, wgmma, mbarrier, TMA, clusters), completing the PTX corpus.
- H100 environment probe job and its results: driver, toolkit and library versions, and a confirmed PTX 8.7 JIT.
- ptxas and SASS evidence for every corpus entry, and per-feature SASS observations with hidden mechanisms.
- Corpus runner and H100 golden outputs for every runnable corpus entry, with sanitizer and JIT SASS checks.
- NVBit instruction histograms of CUTLASS, FlashInfer, flash-attn 2 and Triton workloads on the H100.
- `tools/evidence/report_tables.py`, which prints the summary tables of the H100 evidence.
- PTX memory-model litmus suite (Dat3M and mixedproxy tests) with Dartagnan verdicts and consistency checks.
- PTX ISA 8.7 memory model in Alloy (`models/ptx87`) with its interpretation decisions, PTX 8.7 litmus tests and
  verdicts, the scoped C++ mapping check, and H100 runs of the new tests.
- Litmus test families over scopes and placements, hand-reasoned tests for sm_90 features, 2019 Alloy model and
  RVWMO baseline verdicts.
- H100 litmus harness (inline-PTX kernels, runner with stress and placement control, job) and its results.
- H100 litmus runs of the imported tests, CTA barriers, shared memory across CTAs, mixed sizes and mbarrier
  initialization, and a `spread` configuration; start delays now use `nanosleep`.
- PTX 8.7 memory model in a Dartagnan fork (`deps/dat3m`), written independently from the manual, with
  `ptx-v8.7` verdicts that agree with the Alloy model on every test both decide.
- Feature and NVIDIA-idiom litmus tests for every PTX 8.7 memory feature, a per-feature scorecard, mutation
  testing of both PTX 8.7 models, and H100 harness support for wgmma, tensor maps, multicast, griddepcontrol and
  virtual aliases.
- Per-kernel register and uniform-register counts and histograms of 40 more workloads (FlashAttention-3 added to the job image), and probe kernels for
  forward progress, reconvergence, address windows, scope costs and setmaxnreg, with their H100 results.

### Changed

- Base ISA: floating point in the integer registers (Zfinx, Zdinx, Zhinx) instead of F, D and Zfh, and more
  standard extensions (atomics, cache and hint extensions, counters).
- PTX 8.7 Alloy model: tensormap proxy fences act only as a release/acquire pair, and a mixed-size data race
  frees a program from the axioms but not from written values (decisions D37, D38).
- PTX 8.7 Alloy model: a bulk copy from `.shared::cta` into the issuing CTA is undefined behaviour, and a generic
  read is ordered before a later async-proxy write without a proxy fence (decisions D39, D40).

## [0.1.0] - 2026-10-31

### Added

- Development container with the PTX, RISC-V and formal memory-model toolchains.
- `tools/dev.sh` and `tools/build-area.sh` to build on the build host, with tests.
- Project overview, development guide and tool guides with worked examples.
- `sail-riscv`, `riscv-opcodes` and `ptx-memory-model` as shallow submodules.
- CI with lint and test checks.

[Unreleased]: https://github.com/lomolisso/kamui-isa/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lomolisso/kamui-isa/releases/tag/v0.1.0
