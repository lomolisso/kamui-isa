# evidence/

Measurements of **our own** micro-kernels and of the H100 environment they run in. They are the facts the
execution-model decisions and the conformance suite rest on.

| Folder | Content | Produced by |
|---|---|---|
| `env/` | The H100 job environment: driver, toolkit and library versions, and whether the driver JIT, NVBit, `compute-sanitizer` and `ncu` work | `jobs/env-probe.sh` |

## Origin and licensing

- Every file here comes from kernels whose source lives in this repository (`tests/corpus/`, `docs/examples/`),
  from tool version queries, or from aggregated statistics.
- SASS of NVIDIA library kernels (CUTLASS, cuBLAS, FlashAttention, FlashInfer, Triton-generated kernels) is
  never stored here. For those workloads only aggregated opcode counts are kept.
- No NVIDIA SDK files and no CUDA headers.
- Each folder has a README naming the tool, its version, the command, the job id and the date.
