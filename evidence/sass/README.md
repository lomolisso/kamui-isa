# evidence/sass/

The SASS (Hopper machine code) of every corpus entry, as `cuobjdump` prints it from the cubin that ptxas built.
One file per entry directory of `tests/corpus/`, named after it (`atom.scope.cta.sass`). The kernels are our own;
no NVIDIA library code is stored here.

| | |
|---|---|
| Tools | `ptxas` (V12.8.93) and `cuobjdump` (V12.8.90) from CUDA 12.8, in the dev container |
| Command | `cuobjdump -sass -res-usage <id>.cubin`, the cubin coming from the command in [../ptxas/](../ptxas/README.md) |
| Produced by | `python tools/evidence/sass.py`, 2026-11-01 |
| Reproduce | `python tools/evidence/sass.py --verify` |

Each file starts with the resource usage (`REG`, `SHARED`, `CONSTANT[0]`, ...) and then lists every function: the
kernel and any subroutine ptxas generated (for example the slow path of `div.rn.f64`). Each instruction line has
its offset, the instruction, and its 128-bit encoding as two 64-bit comments. `docs/tools/cuobjdump.md` explains
how to read them.

This is the SASS of the offline ptxas in the dev container. The driver on the H100 compiles the same PTX with its
own, newer ptxas; the goldens job checks whether the two agree (`jit_matches_offline` in the observations).
