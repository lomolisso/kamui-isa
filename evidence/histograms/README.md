# evidence/histograms/

How often each SASS opcode executes in five real GPU workloads on the H100: which instruction classes, and so
which Kamui extension families, real kernels lean on. Only aggregated counts are stored here, never the SASS of the
library kernels.

| | |
|---|---|
| Job | `20261101T172729Z-q000033` (`jobs/nvbit-hist.sh`) on GPU 3 of the lab's H100 server (H100 NVL, driver 580.126.20); the cross-check `20261101T172845Z-q000034` (`MODE=ncu`, Nsight Compute 2025.2.1) |
| Tool | `kamui_sass_hist` (`tools/evidence/nvbit/`), NVBit 1.8.1; classes added by `python tools/evidence/classify.py` from `tools/evidence/opcode_classes.yaml` |
| Versions | CUDA 12.9.1, CUTLASS 4.4.2, torch 2.11.0+cu129, Triton 3.6.0, flash-attn 2.8.3.post2, FlashInfer 0.7.2.post1 (also in the header of every CSV) |

| File | Workload | Shape |
|---|---|---|
| `cutlass_gemm_tf32_2048.csv` | CUTLASS example 48: Hopper warp-specialized GEMM, float inputs on TF32 `wgmma`, TMA multicast, 128x128x32 tiles, 4x2 clusters | M = N = K = 2048 |
| `flashinfer_prefill_bf16.csv` | FlashInfer `single_prefill_with_kv_cache`, backend `fa3` (Hopper: `wgmma`, TMA, warp specialization) | 1 x 16 heads x 2048 x 128, bfloat16, causal |
| `flash_attn2_fwd_bf16.csv` | flash-attn 2 forward (Ampere-style `mma.sync`, `cp.async`, `ldmatrix`) | same |
| `triton_matmul_f16_2048.csv` | our Triton matmul (`tools/evidence/workloads/triton_kernels.py`), fixed 128x128x64 blocks | 2048^3, float16 in, float32 accumulate |
| `triton_softmax_f32_4096.csv` | our Triton row softmax, one program per row | 4096 x 4096 float32 |
| `ncu-crosscheck.csv` | the CUTLASS kernel's instruction totals from Nsight Compute next to NVBit's | |

Only the first launch of each kernel of interest is counted (`KAMUI_KERNELS` in the job script selects them);
each workload first runs once without the tool so that compilation caches are warm.

## Columns

| Column | Meaning |
|---|---|
| `workload` | the workload name (file name) |
| `kernel` | kernel name up to the first `(` or `<`, then `#` and a hash of the full mangled name |
| `sass_opcode` | the SASS opcode with its modifiers, operands dropped, as NVBit reports it |
| `opcode_class` | the class from `tools/evidence/opcode_classes.yaml` (which also names the Kamui families of each class) |
| `static_count` | how many instructions of the kernel have this opcode |
| `warp_inst_executed` | how many times a warp issued one of them (a predicated-off instruction still counts, as in Nsight Compute) |
| `thread_inst_executed` | the active threads of those issues, summed |
| `thread_inst_executed_pred_true` | the active threads whose guard predicate was true, summed |

## Cross-check with Nsight Compute

For the CUTLASS kernel, Nsight Compute counted 8,300,178 warp instructions and NVBit 8,388,993 (+1.07%); thread
counts differ by +1.23% and predicate-on thread counts by +0.68%. Both count the same kernel at the same size in
separate runs. The likely cause of the small excess is spin-wait loops (`mbarrier` try-wait polling), which run a
few more iterations while the instrumented kernel is slower.
