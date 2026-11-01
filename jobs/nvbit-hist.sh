#!/usr/bin/env bash
# shellcheck disable=SC2086  # the workload commands are split into words on purpose
# jobs/nvbit-hist.sh : SASS instruction histograms of five real GPU workloads, with our NVBit tool.
#
# Inputs (committed): tools/evidence/nvbit/kamui_sass_hist/, tools/evidence/workloads/; CUTLASS example 48 from
#                     the job image ($CUTLASS_PATH)
# Outputs (under $OUT): raw/<workload>.csv (one row per kernel and SASS opcode, from kamui_sass_hist),
#                       logs/<workload>.log, versions.yaml, manifest.yaml, job.log; with MODE=ncu: ncu/gemm.csv
# Runs on: the H100 job image with one GPU visible as device 0. See docs/tools/h100-jobs.md.
#
# Workloads (fixed shapes and seeds):
#   cutlass_gemm_tf32_2048       CUTLASS example 48: Hopper warp-specialized GEMM, float in (tf32 wgmma), 2048^3
#   flashinfer_prefill_bf16      FlashInfer single prefill, backend fa3 (wgmma + TMA), 1 x 16 heads x 2048 x 128
#   flash_attn2_fwd_bf16         flash-attn 2 forward (mma.sync + cp.async), same shape
#   triton_matmul_f16_2048       our Triton matmul, 2048^3, float16 in, float32 accumulate
#   triton_softmax_f32_4096      our Triton row softmax, 4096 x 4096 float32
# Only the first launch of each kernel of interest is counted (KAMUI_KERNELS selects them).
#
# MODE=ncu (submit with `h100 submit --profile`) instead runs Nsight Compute on the CUTLASS GEMM kernel, for the
# cross-check of NVBit's counts. WORKLOADS (space-separated names) limits the histogram run.
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
MODE=${MODE:-hist}
JOB_ID=${JOB_ID:-$(date -u +%Y%m%dT%H%M%SZ)${H100_JOB_ID:+-q$H100_JOB_ID}}
OUT=${OUT:-$HOME/kamui-jobs/nvbit-hist/$JOB_ID}
WORK=${WORK:-$(mktemp -d)}
export TRITON_CACHE_DIR=$WORK/triton NOBANNER=1
mkdir -p "$OUT/raw" "$OUT/logs"
exec > >(tee -a "$OUT/job.log") 2>&1
STARTED=$(date -Is)
echo "job: nvbit-hist  mode: $MODE  id: $JOB_ID  start: $STARTED"
cd "$REPO" || exit 1
nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader | tee "$OUT/gpu.txt"
W=tools/evidence/workloads
CUTLASS=${CUTLASS_PATH:-/opt/cutlass}
GEMM_ARGS=(--m=2048 --n=2048 --k=2048 --iterations=1)

build_gemm() {
    nvcc -std=c++17 -O3 -arch=sm_90a --expt-relaxed-constexpr -DNDEBUG -I"$CUTLASS/include" \
        -I"$CUTLASS/tools/util/include" -I"$CUTLASS/examples/common" \
        "$CUTLASS/examples/48_hopper_warp_specialized_gemm/48_hopper_warp_specialized_gemm.cu" \
        -o "$WORK/gemm48" > "$OUT/logs/gemm-build.log" 2>&1
}

if [[ "$MODE" == ncu ]]; then
    mkdir -p "$OUT/ncu"
    build_gemm || { echo "gemm build failed"; exit 1; }
    ncu --clock-control none --kernel-name regex:device_kernel --launch-count 1 --csv --page raw \
        --print-units base --metrics smsp__inst_executed.sum,smsp__thread_inst_executed.sum,smsp__thread_inst_executed_pred_on.sum \
        "$WORK/gemm48" "${GEMM_ARGS[@]}" > "$OUT/ncu/gemm.csv" 2> "$OUT/logs/ncu.log"
    echo "ncu exit: $?"
else
    cmake -S tools/evidence/nvbit -B "$WORK/nvbit" -G Ninja -DCMAKE_BUILD_TYPE=Release > "$OUT/logs/nvbit-build.log" 2>&1 \
        && cmake --build "$WORK/nvbit" >> "$OUT/logs/nvbit-build.log" 2>&1
    TOOL=$(find "$WORK/nvbit" -name kamui_sass_hist.so | head -1)
    if [[ -z "$TOOL" ]]; then
        echo "kamui_sass_hist build failed"
        tail -20 "$OUT/logs/nvbit-build.log"
        exit 1
    fi
    build_gemm || echo "gemm build failed (see logs/gemm-build.log)"
    declare -A CMD=(
        [cutlass_gemm_tf32_2048]="$WORK/gemm48 ${GEMM_ARGS[*]}"
        [flashinfer_prefill_bf16]="python3 $W/attention.py flashinfer"
        [flash_attn2_fwd_bf16]="python3 $W/attention.py fa2"
        [triton_matmul_f16_2048]="python3 $W/triton_kernels.py matmul"
        [triton_softmax_f32_4096]="python3 $W/triton_kernels.py softmax"
    )
    declare -A KERNELS=(
        [cutlass_gemm_tf32_2048]="device_kernel"
        [flashinfer_prefill_bf16]="flashinfer|Prefill|prefill"
        [flash_attn2_fwd_bf16]="flash_fwd"
        [triton_matmul_f16_2048]="kamui_matmul"
        [triton_softmax_f32_4096]="kamui_softmax"
    )
    for wl in ${WORKLOADS:-cutlass_gemm_tf32_2048 flashinfer_prefill_bf16 flash_attn2_fwd_bf16 triton_matmul_f16_2048 triton_softmax_f32_4096}; do
        # Warm-up without the tool: JIT caches (Triton, FlashInfer) are filled outside the measured run.
        ${CMD[$wl]} > "$OUT/logs/$wl.warmup.log" 2>&1
        start=$(date +%s)
        env LD_PRELOAD="$TOOL" KAMUI_OUT="$OUT/raw/$wl.csv" KAMUI_WORKLOAD="$wl" KAMUI_KERNELS="${KERNELS[$wl]}" \
            ${CMD[$wl]} > "$OUT/logs/$wl.log" 2>&1
        rc=$?
        echo "$wl: exit $rc, $(( $(date +%s) - start )) s, $(($(wc -l < "$OUT/raw/$wl.csv" 2>/dev/null || echo 1) - 1)) rows"
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
