# tests/probes/

Small kernels that measure facts about the execution model rather than instruction results: whether the lanes of
one warp make independent progress, where they run together again after divergence, where the generic address
windows are, and what scopes, fences and warp-wide operations cost. They inform the ISA design choices
(register model, convergence, scope encoding, addressing, uniform datapath); they are not conformance tests.

Each probe is a folder in the corpus format (`kernel.cu`, the `kernel.ptx` clang 20 makes from it, and
`entry.yaml`), so the corpus tools work on it unchanged:

```bash
python tools/corpus/build.py tests/probes/*/            # clang 20 -> kernel.ptx, ptxas -v
python tools/runner/run_all.py tests/probes/*/ --dry-run  # launch files and buffer layouts, no GPU
bash jobs/isa-probes.sh                                 # on the H100 (see docs/tools/h100-jobs.md)
python tools/evidence/probes.py evidence/probes/<job>   # decode the outputs into tables
```

Every spin loop is bounded, so a probe that cannot make progress ends and reports it. Every probe's header
comment says what it measures and how its outputs are laid out.

| Probe | Question |
|---|---|
| `its-lock-in-warp` | Can the 32 lanes of one warp take a spin lock one after another with the classic `while (atomicCAS(...)) {}` loop? (With one program counter per warp and a reconvergence stack, the lock holder waits at the loop exit for lanes that spin forever.) |
| `its-lock-in-loop` | The same with the critical section inside the loop (works on any machine; the reference) |
| `its-cross-branch-wait` | The two sides of a divergent branch each wait for a flag the other side sets: possible only if the sides interleave |
| `its-producer-consumer` | Lane 0 produces a value for each of lanes 1 to 31 through shared memory |
| `reconv-points` | The active mask and the time at points after if/else, loops, `break`, nested branches, `__syncwarp` and an early `return` |
| `syncwarp-divergent` | One `bar.warp.sync -1` reached by the two halves of a warp from two program points |
| `addr-windows` | Generic addresses of static and dynamic shared memory, local memory and global memory; `cvta`, `mapa`, `isspacep` results and window bounds; the shared-memory special registers; launched as 2 clusters of 2 CTAs |
| `lat-scopes-1`, `lat-scopes-warp-same`, `lat-scopes-warp-distinct` | Cycles of loads, stores, atomics, reductions and fences at each scope and ordering, plus proxy fences and mbarrier: one thread; one warp on one word; one warp on separate lines |
| `lat-warp` | Cycles of `redux.sync`, a shuffle-tree sum, `vote`, `match`, `activemask`, `bar.warp.sync`, `elect.sync`, `%ctaid` |
| `setmaxnreg-nodelay`, `setmaxnreg-delay` | Does `setmaxnreg.inc` wait until another warpgroup of the CTA gives registers back (one CTA of 384 threads per SM, 168 registers at launch, decrease to 40 after 0 or 200,000 cycles, increase to 232)? |
| `bmov-break` | Control flow that makes ptxas emit `BREAK` (and was meant to provoke `BMOV`): a two-level loop exit, a divergent non-inlined call, a loop with `break` and `return` |
