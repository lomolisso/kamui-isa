# evidence/ptxas/

`ptxas -v` output for every corpus entry: the registers, shared memory, stack and barriers that ptxas assigns to
our own kernels. One file per entry directory of `tests/corpus/`, named after it (`atom.scope.cta.txt`).

| | |
|---|---|
| Tool | `ptxas` from CUDA 12.8 (V12.8.93), in the dev container |
| Command | `ptxas -arch=sm_90a -v <compile.ptxas_flags of the entry> -o <id>.cubin tests/corpus/<family>/<id>/kernel.ptx` (the first line of each file repeats it) |
| Produced by | `python tools/evidence/sass.py`, 2026-11-01 |
| Reproduce | `python tools/evidence/sass.py --verify` rebuilds every file and compares it with the committed one |

The `Compile time` line is removed, because it changes from run to run. The registers and shared memory of each
entry are also columns of [../sass-observations.csv](../README.md).
