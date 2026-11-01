# evidence/

Measurements of **our own** micro-kernels and of the H100 environment they run in. They are the facts the
execution-model decisions and the conformance suite rest on.

| Folder | Content | Produced by |
|---|---|---|
| `env/` | The H100 job environment: driver, toolkit and library versions, and whether the driver JIT, NVBit, `compute-sanitizer` and `ncu` work | `jobs/env-probe.sh` |
| `litmus-h100/` | Outcome counts of the memory-model litmus tests on the H100, joined with the formal verdicts; the findings are in its README | `jobs/litmus-h100.sh`, `tools/litmus/observed.py` |
| `ptxas/` | `ptxas -v` output of every corpus entry: registers, shared memory, stack | `tools/evidence/sass.py` (dev container) |
| `sass/` | The SASS of every corpus entry (`cuobjdump -sass -res-usage`) | `tools/evidence/sass.py` (dev container) |
| `sass-observations.csv` | One row per in-scope catalog feature: which SASS implements it, how its modifiers are encoded, and which hidden mechanisms appear | `tools/evidence/sass.py` |
| `jit-comparison.tsv` | For every kernel run on the H100: whether the driver JIT produced the same SASS as the offline ptxas (columns in `tools/evidence/jit_compare.py`) | `jobs/goldens.sh` + `tools/evidence/jit_compare.py` |
| `histograms/` | SASS opcode histograms of five real workloads (CUTLASS, FlashInfer, flash-attn 2, Triton), aggregated counts only | `jobs/nvbit-hist.sh` + `tools/evidence/classify.py` |

## sass-observations.csv

`python tools/evidence/sass.py` writes it from the files above (`--annotate` alone rewrites it without running
the CUDA tools; `--check` checks it without any tool, and runs in CI). The matching rules are in
[tools/evidence/annotate.py](../tools/evidence/annotate.py) and
[tools/evidence/sass_classes.yaml](../tools/evidence/sass_classes.yaml); rows decided by hand are in
[tools/evidence/sass-review.yaml](../tools/evidence/sass-review.yaml).

| Column | Meaning |
|---|---|
| `feature_id` | catalog id (`tests/corpus/catalog.yaml`) |
| `family`, `tier`, `kind` | copied from the catalog |
| `entry` | the corpus entry whose kernel was read; rows that share another row's kernel name that kernel |
| `ptx_instr` | the PTX instructions of interest in that kernel (distinct opcodes, `;`-separated) |
| `ptx_count` | how many such PTX instructions the kernel has (for a special register: how many times it is read) |
| `sass_sequence` | the SASS instructions found for them, with predicate and modifiers, distinct, in program order |
| `sass_len` | how many SASS instructions were found (all instances, address arithmetic excluded) |
| `sass_per_ptx` | `sass_len / ptx_count`. 1.00 means one SASS instruction per PTX instruction; below 1 means ptxas merged or removed some (an address `add` folded into a load offset); above 1 means a sequence |
| `modifiers_encoding` | how each PTX modifier shows up in SASS, for example `.cta -> STRONG.SM`, `.acquire -> CCTL.IVALL after`, `.rz -> .RZ`. For a special register: the SASS register or constant-bank slot it is read from |
| `hidden_mechanism` | what ptxas added that the PTX did not ask for, `;`-separated (list below), found in the instructions or within three instructions of them |
| `regs` | registers per thread (`ptxas -v`) |
| `shared_bytes` | shared memory the kernel declares (`ptxas -v`) |
| `shared_bytes_resusage` | shared memory per block in the cubin (`cuobjdump -res-usage`): 1 KB more than `shared_bytes`, the space Hopper reserves in every block that uses shared memory |
| `jit_matches_offline` | whether the driver JIT on the H100 produced the same SASS (filled by the goldens job) |
| `status` | `auto` (matched by the rules), `reviewed` (decided by hand, see `notes`), `pending` (no corpus entry yet) |
| `notes` | how the row was matched, the reason for a `software-sequence`, or the review decision |

Hidden mechanisms:

| Value | SASS that shows it |
|---|---|
| `none` | nothing beyond the instruction itself |
| `convergence-barrier` | the instruction sits between `BSSY` and `BSYNC`, or next to `WARPSYNC`: the hardware regroups the threads of a warp around it |
| `uniform-datapath` | uniform registers (`UR`, `UP`) or uniform instructions (`U...`, `S2UR`): one value per warp, computed once |
| `warp-aggregation` | an atomic preceded by `VOTE.ANY` and `FLO`/`POPC` or `REDUX`: one lane does the atomic for the whole warp and the result is shuffled back |
| `elect-loop` | `ELECT` plus a `BRA.U.ANY` loop: the instruction is issued by one lane at a time until every lane's request is done |
| `memory-barrier` | `MEMBAR`, `ERRBAR`, `CGAERRBAR` or `FENCE.VIEW` around the instruction |
| `cache-maintenance` | `CCTL` (cache invalidation, prefetch, eviction priority) |
| `scoreboard` | `DEPBAR`, `LDGDEPBAR`, `WARPGROUP.DEPBAR`, `ARRIVES.LDGSTSBAR`: waits on asynchronous operations |
| `syncs-unit` | `SYNCS.*`: the Hopper unit that implements `mbarrier` |
| `descriptor` | a matrix or tensor descriptor operand (`gdesc[UR]` on `HGMMA`, the tensor map of `UTMA*`) |
| `cga` | cluster hardware: `UCGABAR_*` or `SR_CgaCtaId` |
| `constant-bank` | a special register that is not a hardware register but a value the driver writes into constant bank 0 |
| `software-sequence` | no SASS instruction of its own: a sequence of ordinary instructions or a call to a subroutine (the reason is in `notes`) |

## Origin and licensing

- Every file here comes from kernels whose source lives in this repository (`tests/corpus/`, `docs/examples/`),
  from tool version queries, or from aggregated statistics.
- SASS of NVIDIA library kernels (CUTLASS, cuBLAS, FlashAttention, FlashInfer, Triton-generated kernels) is
  never stored here. For those workloads only aggregated opcode counts are kept.
- No NVIDIA SDK files and no CUDA headers.
- Each folder has a README naming the tool, its version, the command, the job id and the date.
