# tools/

| Script | Purpose |
|---|---|
| `dev.sh` | Run a command or a shell in the dev container on the build host (works in worktrees; does the ssh hop itself) |
| `build-area.sh` | Show and clean the build area `/scratch/$USER/kamui-isa` on the build host (`status`, `clean`, `prune`, `ps`, `stop`) |
| `tests/run.sh` | Tests for the two scripts above (stub `docker` and `ssh`, no build host needed) |
| `catalog/` | Build and check the PTX feature catalog and generate `spec/ptx-table.md` (see [catalog/README.md](catalog/README.md)) |
| `corpus/` | Compile and check the corpus micro-kernels (`build.py`) and write their inputs (`gen_inputs.py`); see [tests/corpus/README.md](../tests/corpus/README.md) |
| `env/jit_probe.py` | Check that the CUDA driver JIT-compiles a PTX file and, for `app.vecadd`, runs it correctly; used by [jobs/env-probe.sh](../jobs/env-probe.sh) on the H100 server |
| `evidence/sass.py` | `ptxas -v` and SASS of every corpus entry, and the per-feature SASS observations (see [evidence/README.md](../evidence/README.md)) |
| `evidence/jit_compare.py` | Compare the SASS the H100 driver JIT produced with the offline SASS (`evidence/jit-comparison.tsv`) |
| `evidence/check_goldens.py` | Check that every runnable corpus entry has a current golden in `tests/goldens/` (no GPU needed) |
| `evidence/nvbit/` | Our NVBit tools, built in the H100 job image: `dump_cubin` writes the cubin the driver loaded; `kamui_sass_hist` counts executed SASS opcodes per kernel |
| `evidence/classify.py` | Classify the NVBit histograms with `evidence/opcode_classes.yaml` and write `evidence/histograms/` |
| `evidence/report_tables.py` | Print the summary tables of the H100 evidence (SASS observations, goldens, JIT comparison, histograms) as Markdown |
| `evidence/workloads/` | The workloads of the histograms: attention (FlashInfer, flash-attn 2) and two Triton kernels |
| `litmus/` | The memory-model litmus suite: `litmus.py` (parser), `import_tests.py`, `gen_families.py`, `to_alloy.py` (2019 Alloy model queries), `to_riscv.py` (RVWMO lowering), `run_formal.py` (Dartagnan, Alloy and herd7 verdicts into `expected.csv`), `check_suite.py` (see [tests/litmus/README.md](../tests/litmus/README.md)) |
| `runner/` | `runner.c` loads one corpus kernel through the CUDA driver API and writes its outputs; `run_all.py` builds the launch files, runs every entry and writes the goldens (see [tests/goldens/README.md](../tests/goldens/README.md)) |

Both scripts are described in [docs/development.md](../docs/development.md). Python code targets Python 3.12 (the
dev container venv); its unit tests run with `python -m pytest tools/`. Every script has a `--help` or a usage comment at the top.
