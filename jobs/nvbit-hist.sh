#!/usr/bin/env bash
# shellcheck disable=SC2086  # the workload commands are split into words on purpose
# jobs/nvbit-hist.sh : SASS instruction histograms and per-kernel register use of real GPU workloads, with our
#                      NVBit tool.
#
# Inputs (committed): tools/evidence/nvbit/kamui_sass_hist/, tools/evidence/workloads/; CUTLASS examples from
#                     the job image ($CUTLASS_PATH)
# Outputs (under $OUT): raw/<workload>.csv (one row per kernel and SASS opcode), kernels/<workload>.csv (one row
#                       per kernel: registers, uniform registers, spills, shared memory, launch shape, static
#                       counts of convergence, uniform and fence instructions), logs/<workload>.log,
#                       versions.yaml, manifest.yaml, job.log; with MODE=ncu: ncu/gemm.csv; with
#                       MODE=occupancy: ncu/<workload>.csv
# Runs on: the H100 job image with one GPU visible as device 0. See docs/tools/h100-jobs.md.
#
# Workloads (fixed shapes and seeds). The first five are the original set, counted the same way as before:
#   cutlass_gemm_tf32_2048       CUTLASS example 48: Hopper warp-specialized GEMM, float in (tf32 wgmma), 2048^3
#   flashinfer_prefill_bf16      FlashInfer single prefill, backend fa3 (wgmma + TMA), 1 x 16 heads x 2048 x 128
#   flash_attn2_fwd_bf16         flash-attn 2 forward (mma.sync + cp.async), same shape
#   triton_matmul_f16_2048       our Triton matmul, 2048^3, float16 in, float32 accumulate
#   triton_softmax_f32_4096      our Triton row softmax, 4096 x 4096 float32
# The others count every kernel they launch (cuBLAS and cuDNN kernels are excluded by name, KAMUI_EXCLUDE):
#   cutlass_exNN_*               CUTLASS Hopper examples 49, 54, 55, 56, 57, 61, 62, 63, 67 and 88 (fmha, the
#                                FlashAttention-3 style kernel, forward and backward)
#   flash_attn2_bwd_bf16, flashinfer_decode_bf16, flashinfer_paged_bf16   tools/evidence/workloads/attention.py
#   torch_*                      PyTorch's own kernels: CUB scans and sorts, atomics, reductions (torch_ops.py)
#   triton_{splitk,queue,attention}   our Triton kernels with atomics and a fused attention (triton_kernels.py)
#   div_*                        our divergence-heavy CUDA kernels (divergence.cu)
#   fa3*                         FlashAttention-3 (flash_attn_interface in the image): forward, backward, FP8,
#                                KV-cache decode, head dimensions 64 and 256 (attention.py)
#   vendor_*                     cuBLAS, cuBLASLt and cuDNN kernels through PyTorch (vendor_ops.py); counted with no
#                                exclusion and written to vendor/raw and vendor/kernels, which stay out of the
#                                repository (NVIDIA library kernels: aggregate counts only, kept apart)
# Only the first launch of each kernel of interest is counted. Each workload has a time limit (WL_TIMEOUT).
#
# MODE=ncu (submit with `h100 submit --profile`) instead runs Nsight Compute on the CUTLASS GEMM kernel, for the
# cross-check of NVBit's counts. MODE=occupancy (also --profile) runs Nsight Compute on the first launch of every
# kernel of the selected workloads and records registers per thread and what limits occupancy.
# WORKLOADS (space-separated names) selects workloads; DRY_RUN=1 prints the commands and builds nothing.
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
MODE=${MODE:-hist}
JOB_ID=${JOB_ID:-$(date -u +%Y%m%dT%H%M%SZ)${H100_JOB_ID:+-q$H100_JOB_ID}}
OUT=${OUT:-$HOME/kamui-jobs/nvbit-hist/$JOB_ID}
DRY_RUN=${DRY_RUN:-0}
if [[ "$DRY_RUN" == 1 ]]; then
    WORK=build OUT=/dev/null   # nothing is built or written
else
    WORK=${WORK:-$(mktemp -d)}
    mkdir -p "$OUT/raw" "$OUT/logs"
    exec > >(tee -a "$OUT/job.log") 2>&1
fi
export TRITON_CACHE_DIR=$WORK/triton NOBANNER=1
STARTED=$(date -Is)
echo "job: nvbit-hist  mode: $MODE  id: $JOB_ID  start: $STARTED"
cd "$REPO" || exit 1
[[ "$DRY_RUN" == 1 ]] || nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader | tee "$OUT/gpu.txt"
W=tools/evidence/workloads
CUTLASS=${CUTLASS_PATH:-/opt/cutlass}
GEMM_ARGS=(--m=2048 --n=2048 --k=2048 --iterations=1)
WL_TIMEOUT=${WL_TIMEOUT:-900}
export KAMUI_EXCLUDE=${KAMUI_EXCLUDE:-nvjet|xmma|cublas|cudnn|gemv2|gemmSN|splitKreduce|cutlass_80_tensorop}
ORIGINAL="cutlass_gemm_tf32_2048 flashinfer_prefill_bf16 flash_attn2_fwd_bf16 triton_matmul_f16_2048 triton_softmax_f32_4096"
TORCH_OPS="cumsum sort topk unique nonzero index_add scatter_add histc embedding_bwd layer_norm softmax"
DIV="bfs mandelbrot hashlock spmv bitonic tree"

# CUTLASS examples: name, source under examples/, extra nvcc flags, run arguments.
EXAMPLES=(
    "ex49|49_hopper_gemm_with_collective_builder/49_collective_builder.cu||--m=2048 --n=2048 --k=2048 --iterations=1"
    "ex54|54_hopper_fp8_warp_specialized_gemm/54_hopper_fp8_warp_specialized_gemm.cu||--m=2048 --n=2048 --k=2048 --iterations=1"
    "ex55|55_hopper_mixed_dtype_gemm/55_hopper_mixed_dtype_gemm.cu||--m=2048 --n=2048 --k=2048 --g=128 --mode=1 --iterations=1"
    "ex56|56_hopper_ptr_array_batched_gemm/56_hopper_ptr_array_batched_gemm.cu||--m=2048 --n=2048 --k=2048 --l=4 --iterations=1"
    "ex57|57_hopper_grouped_gemm/57_hopper_grouped_gemm.cu||--groups=16 --iterations=1"
    "ex61|61_hopper_gemm_with_topk_and_softmax/61_hopper_gemm_with_topk_and_softmax.cu||--m=2048 --n=8 --k=2048 --iterations=1"
    "ex62|62_hopper_sparse_gemm/62_hopper_sparse_gemm.cu||--m=2048 --n=2048 --k=2048 --iterations=1"
    "ex63|63_hopper_gemm_with_weight_prefetch/63_hopper_gemm_with_weight_prefetch.cu|-I$CUTLASS/examples/63_hopper_gemm_with_weight_prefetch|--m=8192 --n=64 --k=8192 --iterations=1"
    "ex67|67_hopper_fp8_warp_specialized_gemm_with_blockwise_scaling/67_hopper_fp8_warp_specialized_gemm_with_blockwise_scaling.cu||--m=2048 --n=2048 --k=2048 --iterations=1"
    "ex88|88_hopper_fmha/88_hopper_fmha.cu|--use_fast_math -I$CUTLASS/examples/88_hopper_fmha|--b=1 --h=16 --q=2048 --k=2048 --d=128 --iterations=1"
)
declare -A CMD KERNELS
CMD[cutlass_gemm_tf32_2048]="$WORK/gemm48 ${GEMM_ARGS[*]}";  KERNELS[cutlass_gemm_tf32_2048]="device_kernel"
CMD[flashinfer_prefill_bf16]="python3 $W/attention.py flashinfer"; KERNELS[flashinfer_prefill_bf16]="flashinfer|Prefill|prefill"
CMD[flash_attn2_fwd_bf16]="python3 $W/attention.py fa2";     KERNELS[flash_attn2_fwd_bf16]="flash_fwd"
CMD[triton_matmul_f16_2048]="python3 $W/triton_kernels.py matmul";   KERNELS[triton_matmul_f16_2048]="kamui_matmul"
CMD[triton_softmax_f32_4096]="python3 $W/triton_kernels.py softmax"; KERNELS[triton_softmax_f32_4096]="kamui_softmax"
NEW=""
for e in "${EXAMPLES[@]}"; do
    IFS='|' read -r n _ _ args <<< "$e"
    CMD[cutlass_$n]="$WORK/$n $args"; KERNELS[cutlass_$n]="."; NEW+=" cutlass_$n"
done
CMD[cutlass_ex88_bwd]="$WORK/ex88 --b=1 --h=16 --q=2048 --k=2048 --d=128 --iterations=1 --bwd"; KERNELS[cutlass_ex88_bwd]="."
CMD[flash_attn2_bwd_bf16]="python3 $W/attention.py fa2_bwd";       KERNELS[flash_attn2_bwd_bf16]="."
CMD[flashinfer_decode_bf16]="python3 $W/attention.py fi_decode";   KERNELS[flashinfer_decode_bf16]="."
CMD[flashinfer_paged_bf16]="python3 $W/attention.py fi_paged";     KERNELS[flashinfer_paged_bf16]="."
NEW+=" cutlass_ex88_bwd flash_attn2_bwd_bf16 flashinfer_decode_bf16 flashinfer_paged_bf16"
for op in $TORCH_OPS; do CMD[torch_$op]="python3 $W/torch_ops.py $op"; KERNELS[torch_$op]="."; NEW+=" torch_$op"; done
for t in splitk queue attention; do
    CMD[triton_$t]="python3 $W/triton_kernels.py $t"; KERNELS[triton_$t]="kamui_"; NEW+=" triton_$t"
done
for k in $DIV; do CMD[div_$k]="$WORK/divergence $k"; KERNELS[div_$k]="kamui_"; NEW+=" div_$k"; done
CMD[div_hashlock]="$WORK/divergence hashlock 12"   # 4096 keys: the instrumented spin locks finish in time
for a in fa3 fa3_bwd fa3_fp8 fa3_kvcache fa3_hdim64 fa3_hdim256; do
    CMD[$a]="python3 $W/attention.py $a"; KERNELS[$a]="."; NEW+=" $a"
done
VENDOR="vendor_matmul_bf16 vendor_matmul_fp8 vendor_sdpa_cudnn vendor_conv_bf16"
for v in $VENDOR; do CMD[$v]="python3 $W/vendor_ops.py ${v#vendor_}"; KERNELS[$v]="."; NEW+=" $v"; done
SELECTED=${WORKLOADS:-$NEW $ORIGINAL}

build_gemm() {
    nvcc -std=c++17 -O3 -arch=sm_90a --expt-relaxed-constexpr -DNDEBUG -I"$CUTLASS/include" \
        -I"$CUTLASS/tools/util/include" -I"$CUTLASS/examples/common" \
        "$CUTLASS/examples/48_hopper_warp_specialized_gemm/48_hopper_warp_specialized_gemm.cu" \
        -o "$WORK/gemm48" > "$OUT/logs/gemm-build.log" 2>&1
}

# Builds only what the selected workloads need; the CUTLASS examples build in parallel.
build_all() {
    local pids=() e n src flags
    [[ " $SELECTED " == *" cutlass_gemm_tf32_2048 "* ]] && { build_gemm || echo "gemm build failed (see logs/gemm-build.log)"; } &
    pids+=($!)
    for e in "${EXAMPLES[@]}"; do
        IFS='|' read -r n src flags _ <<< "$e"
        [[ " $SELECTED " == *" cutlass_$n "* || ( $n == ex88 && " $SELECTED " == *" cutlass_ex88_bwd "* ) ]] || continue
        ( nvcc -std=c++17 -O3 -arch=sm_90a --expt-relaxed-constexpr -DNDEBUG -I"$CUTLASS/include" \
            -I"$CUTLASS/tools/util/include" -I"$CUTLASS/examples/common" $flags "$CUTLASS/examples/$src" -lcuda \
            -o "$WORK/$n" > "$OUT/logs/$n-build.log" 2>&1 || echo "$n build failed (see logs/$n-build.log)" ) &
        pids+=($!)
    done
    if [[ " $SELECTED " == *" div_"* ]]; then
        ( nvcc -O3 -arch=sm_90a "$W/divergence.cu" -o "$WORK/divergence" > "$OUT/logs/divergence-build.log" 2>&1 \
            || echo "divergence build failed (see logs/divergence-build.log)" ) &
        pids+=($!)
    fi
    wait "${pids[@]}"
}

if [[ "$DRY_RUN" == 1 ]]; then
    for wl in $SELECTED; do
        [[ -n "${CMD[$wl]:-}" ]] || { echo "unknown workload: $wl"; exit 1; }
        echo "$wl: KAMUI_KERNELS='${KERNELS[$wl]}' ${CMD[$wl]}"
    done
    exit 0
fi

if [[ "$MODE" == ncu ]]; then
    mkdir -p "$OUT/ncu"
    build_gemm || { echo "gemm build failed"; exit 1; }
    ncu --clock-control none --kernel-name regex:device_kernel --launch-count 1 --csv --page raw \
        --print-units base --metrics smsp__inst_executed.sum,smsp__thread_inst_executed.sum,smsp__thread_inst_executed_pred_on.sum \
        "$WORK/gemm48" "${GEMM_ARGS[@]}" > "$OUT/ncu/gemm.csv" 2> "$OUT/logs/ncu.log"
    echo "ncu exit: $?"
elif [[ "$MODE" == occupancy ]]; then
    mkdir -p "$OUT/ncu"
    build_all
    for wl in $SELECTED; do
        ${CMD[$wl]} > "$OUT/logs/$wl.warmup.log" 2>&1
        start=$(date +%s)
        timeout -k 30 "$WL_TIMEOUT" ncu --clock-control none --kernel-id "::regex:${KERNELS[$wl]}:1" --csv --page raw \
            --print-units base --metrics launch__registers_per_thread,launch__occupancy_limit_registers,\
launch__occupancy_limit_shared_mem,launch__occupancy_limit_warps,launch__occupancy_limit_blocks,\
launch__occupancy_per_block_size,launch__block_size,launch__grid_size,launch__shared_mem_per_block_static,\
launch__shared_mem_per_block_dynamic,launch__cluster_size,sm__warps_active.avg.pct_of_peak_sustained_active \
            ${CMD[$wl]} > "$OUT/ncu/$wl.csv" 2> "$OUT/logs/$wl.ncu.log"
        rc=$?
        if [[ $wl == vendor_* ]]; then mkdir -p "$OUT/vendor/ncu" && mv "$OUT/ncu/$wl.csv" "$OUT/vendor/ncu/"; fi
        echo "$wl: ncu exit $rc, $(( $(date +%s) - start )) s"
    done
else
    cmake -S tools/evidence/nvbit -B "$WORK/nvbit" -G Ninja -DCMAKE_BUILD_TYPE=Release > "$OUT/logs/nvbit-build.log" 2>&1 \
        && cmake --build "$WORK/nvbit" >> "$OUT/logs/nvbit-build.log" 2>&1
    TOOL=$(find "$WORK/nvbit" -name kamui_sass_hist.so | head -1)
    if [[ -z "$TOOL" ]]; then
        echo "kamui_sass_hist build failed"
        tail -20 "$OUT/logs/nvbit-build.log"
        exit 1
    fi
    mkdir -p "$OUT/kernels" "$OUT/vendor/raw" "$OUT/vendor/kernels"
    build_all
    for wl in $SELECTED; do
        # Warm-up without the tool: JIT caches (Triton, FlashInfer) are filled outside the measured run.
        timeout -k 30 "$WL_TIMEOUT" ${CMD[$wl]} > "$OUT/logs/$wl.warmup.log" 2>&1
        dst=$OUT excl=$KAMUI_EXCLUDE
        [[ $wl == vendor_* ]] && dst=$OUT/vendor excl=
        start=$(date +%s)
        timeout -k 30 "$WL_TIMEOUT" env LD_PRELOAD="$TOOL" KAMUI_OUT="$dst/raw/$wl.csv" KAMUI_WORKLOAD="$wl" \
            KAMUI_KERNELS="${KERNELS[$wl]}" KAMUI_KERNELS_OUT="$dst/kernels/$wl.csv" KAMUI_EXCLUDE="$excl" \
            ${CMD[$wl]} > "$OUT/logs/$wl.log" 2>&1
        rc=$?
        echo "$wl: exit $rc, $(( $(date +%s) - start )) s, $(($(wc -l < "$dst/raw/$wl.csv" 2>/dev/null || echo 1) - 1)) rows"
    done
fi

# ---- versions and manifest -----------------------------------------------------
python3 - "$OUT" "$REPO" "$JOB_ID" "$STARTED" "$MODE" "$CUTLASS" <<'EOF'
import datetime, importlib, re, subprocess, sys
import yaml
out, repo, job_id, started, mode, cutlass = sys.argv[1:]
def sh(c):
    r = subprocess.run(c, shell=True, capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
name, driver, uuid, bus = (s.strip() for s in sh(
    "nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader").split(","))
v = {"gpu": name, "driver": driver, "cuda_toolkit": sh("nvcc --version | tail -1"),
     "nvbit": sh("grep -h 'define NVBIT_VERSION' $NVBIT_PATH/core/nvbit.h").split()[-1].strip('"'),
     "cutlass": ".".join(re.findall(r"CUTLASS_(?:MAJOR|MINOR|PATCH) (\d+)",
                                    open(f"{cutlass}/include/cutlass/version.h").read())),
     "ncu": sh("ncu --version | tail -1")}
for m in ("torch", "triton", "flash_attn", "flashinfer"):
    try:
        v[m] = str(importlib.import_module(m).__version__)
    except Exception as e:
        v[m] = f"not available ({type(e).__name__})"
yaml.safe_dump(v, open(f"{out}/versions.yaml", "w"), sort_keys=False)
m = {"job": "nvbit-hist", "mode": mode, "job_id": job_id, "started": started,
     "finished": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
     "git_commit": sh(f"git -C {repo} rev-parse HEAD"), "git_dirty": bool(sh(f"git -C {repo} status --porcelain")),
     "gpu": {"name": name, "uuid": uuid, "pci_bus_id": bus, "driver": driver}, "versions": v}
yaml.safe_dump(m, open(f"{out}/manifest.yaml", "w"), sort_keys=False, width=120)
EOF
rm -rf "$WORK"
echo "done: $(date -Is)"
