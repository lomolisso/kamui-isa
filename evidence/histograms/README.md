# evidence/histograms/

How often each SASS opcode executes in real GPU workloads on the H100: which instruction classes, and so which
Kamui extension families, real kernels lean on; and, in `kernels/`, what each kernel uses: registers, uniform
registers, spills, shared memory, launch shape. Only aggregated counts are stored here, never the SASS of the
library kernels. The first five workloads come from the first job; the others (and every kernel table) from the
second.

| | |
|---|---|
| Jobs | `20261101T172729Z-q000033` (`jobs/nvbit-hist.sh`, the first five workloads) on GPU 3 of the lab's H100 server (H100 NVL, driver 580.126.20); the cross-check `20261101T172845Z-q000034` (`MODE=ncu`, Nsight Compute 2025.2.1); `20261105T023255Z-q000231` (every other workload, and `kernels/` for all of them; the first five rerun there agree with q33 within 0.06% (CUTLASS -0.052%, FlashInfer +0.007%, the others exactly)); `20261105T030813Z-q000234` (`flashinfer_paged_bf16`, rerun after a fix); `20261105T042659Z-q000237` (the `fa3*` workloads, after FlashAttention-3 was added to the job image) |
| Tool | `kamui_sass_hist` (`tools/evidence/nvbit/`), NVBit 1.8.1; classes added by `python tools/evidence/classify.py` from `tools/evidence/opcode_classes.yaml` |
| Versions | CUDA 12.9.1, CUTLASS 4.4.2, torch 2.11.0+cu129, Triton 3.6.0, flash-attn 2.8.3.post2, FlashInfer 0.7.2.post1, and for `fa3*` FlashAttention-3 3.0.0b1 (`flash_attn_3`, built from flash-attention v2.8.3 `hopper/` into the job image on 2026-11-05) (also in the header of every CSV) |

| File | Workload | Shape |
|---|---|---|
| `cutlass_gemm_tf32_2048.csv` | CUTLASS example 48: Hopper warp-specialized GEMM, float inputs on TF32 `wgmma`, TMA multicast, 128x128x32 tiles, 4x2 clusters | M = N = K = 2048 |
| `flashinfer_prefill_bf16.csv` | FlashInfer `single_prefill_with_kv_cache`, backend `fa3` (Hopper: `wgmma`, TMA, warp specialization) | 1 x 16 heads x 2048 x 128, bfloat16, causal |
| `flash_attn2_fwd_bf16.csv` | flash-attn 2 forward (Ampere-style `mma.sync`, `cp.async`, `ldmatrix`) | same |
| `triton_matmul_f16_2048.csv` | our Triton matmul (`tools/evidence/workloads/triton_kernels.py`), fixed 128x128x64 blocks | 2048^3, float16 in, float32 accumulate |
| `triton_softmax_f32_4096.csv` | our Triton row softmax, one program per row | 4096 x 4096 float32 |
| `ncu-crosscheck.csv` | the CUTLASS kernel's instruction totals from Nsight Compute next to NVBit's | |
| `cutlass_exNN.csv` | CUTLASS Hopper examples 49 (collective builder), 54 (FP8 warp-specialized), 55 (mixed dtype), 56 (pointer-array batched), 57 (grouped), 61 (GEMM with top-k and softmax), 62 (sparse), 63 (weight prefetch), 67 (FP8 blockwise scaling), 88 (FMHA, the FlashAttention-3 style attention; `cutlass_ex88_bwd` is its backward pass), built in the job from the image's CUTLASS 4.4.2 | arguments in `jobs/nvbit-hist.sh` (`EXAMPLES`) |
| `flash_attn2_bwd_bf16.csv`, `flashinfer_decode_bf16.csv`, `flashinfer_paged_bf16.csv` | flash-attn 2 forward and backward; FlashInfer single decode; FlashInfer batch prefill on a paged KV cache (backend fa3) | `tools/evidence/workloads/attention.py` |
| `torch_*.csv` | PyTorch's own kernels: `cumsum`, `sort`, `topk`, `unique`, `nonzero` (CUB scans and sorts), `index_add`, `scatter_add`, `histc` (atomics), `embedding_bwd`, `layer_norm`, `softmax` | `tools/evidence/workloads/torch_ops.py` |
| `triton_splitk.csv`, `triton_queue.csv`, `triton_attention.csv` | our Triton split-K GEMM with atomic adds, a persistent kernel taking work from an atomic counter, and a fused attention forward | `tools/evidence/workloads/triton_kernels.py` |
| `div_*.csv` | our divergence-heavy CUDA kernels: BFS, Mandelbrot, CSR SpMV, bitonic sort, tree search. The lock-based hash insert (`hashlock`) has no histogram: it completes correctly without the tool (262,144, 65,536 and 4,096 keys in jobs q231, q234, q237), but under instrumentation its spin locks never finish, even with 4,096 keys, so the instrumented run is stopped after 15 minutes | `tools/evidence/workloads/divergence.cu` |
| `fa3*.csv` | FlashAttention-3 (`flash_attn_interface`, flash-attention v2.8.3 `hopper/`): forward, forward and backward, FP8 forward, KV-cache decode, head dimensions 64 and 256 | `tools/evidence/workloads/attention.py` |
| `kernels/<workload>.csv` | one row per counted kernel (columns below) | |
| `occupancy.csv` | Nsight Compute on the first launch of every kernel (jobs `20261105T032452Z-q000235` and, for `fa3*` and `div_hashlock`, `20261105T044339Z-q000238`; `MODE=occupancy`): registers per thread, the blocks per SM that registers, shared memory, warps and the block limit allow, which of them bind, and the achieved warp occupancy; written by `classify.py --occupancy` | |

Only the first launch of each kernel of interest is counted (the new workloads count every kernel they launch,
except cuBLAS and cuDNN kernels, which `KAMUI_EXCLUDE` leaves out by name) (`KAMUI_KERNELS` in the job script selects them);
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

## kernels/ columns

| Column | Meaning |
|---|---|
| `regs`, `local_bytes`, `shared_static_bytes`, `const_bytes`, `max_threads_per_block`, `ptx_version` | `cuFuncGetAttribute` of the kernel (registers per thread at launch; local memory, which includes spills) |
| `grid`, `block`, `cluster`, `dynamic_shared_bytes` | the first launch (cluster from the launch attribute; `required_cluster` from the kernel) |
| `max_r`, `max_ur`, `max_p`, `max_up` | the highest general, uniform, predicate and uniform-predicate register any instruction of the kernel names (RZ, URZ, PT, UPT excluded); `max_r` can exceed `regs` when the kernel raises its count with `setmaxnreg` |
| `static_instrs`, `setmaxnreg` | instructions in the kernel; the `setmaxnreg` values it uses |
| `n_<OPCODE>` | static count of instructions whose opcode starts with that word (`BSSY`, `BMOV`, `BREAK`, `WARPSYNC`, `YIELD`, `USETMAXREG`, `REDUX`, `S2UR`, `MEMBAR`, `CCTL`, `HGMMA`, `UTMALDG`, ...) |

`python tools/evidence/report_tables.py` summarises these files (tables "Registers per kernel", "Uniform
registers and setmaxnreg per kernel", "Execution-model instructions per workload", "What limits occupancy").
Nsight Compute's registers per thread agree with the NVBit tables (168 for the warp-specialized Hopper kernels,
255 for flash-attn 2, 200 for `radixSortKVInPlace`); registers are a binding occupancy limit for 111 of the 149
profiled kernels, and 17 fit only one block per SM because of registers (the warp-specialized Hopper kernels,
384 threads x 168 registers, and flash-attn 2's backward kernel, 256 threads x 255), with achieved warp occupancy
of 12 to 20%.

The job image runs NVIDIA library kernels (cuBLAS, cuBLASLt, cuDNN) too; the job counts them only on request
(`vendor_*` workloads, `tools/evidence/workloads/vendor_ops.py`) into a separate folder, and those results are not
part of this directory.

## Cross-check with Nsight Compute

For the CUTLASS kernel, Nsight Compute counted 8,300,178 warp instructions and NVBit 8,388,993 (+1.07%); thread
counts differ by +1.23% and predicate-on thread counts by +0.68%. Both count the same kernel at the same size in
separate runs. The likely cause of the small excess is spin-wait loops (`mbarrier` try-wait polling), which run a
few more iterations while the instrumented kernel is slower.
