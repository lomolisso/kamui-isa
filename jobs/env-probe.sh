#!/usr/bin/env bash
# jobs/env-probe.sh : record the H100 job environment and check the tools later jobs depend on.
#
# Inputs (committed): tests/corpus/base/app.vecadd/kernel.ptx, docs/examples/cuda/bad.ptx, tools/env/jit_probe.py
# Outputs (under $OUT): tool and library versions, nvidia-smi records, one log per check, results.tsv,
#                       manifest.yaml, job.log
# Runs on: the H100 job image with one GPU visible as device 0. See docs/tools/h100-jobs.md.
#
# Checks (PROBE_STEPS, default all of them, in this order):
#   versions   toolkit, driver, NVBit, CUTLASS and Python package versions
#   jit        the driver JIT accepts our PTX 8.7 for sm_90a and app.vecadd gives the right answer;
#              bad.ptx is rejected
#   nvbit      NVBit's instr_count tool builds and counts instructions, both in an nvcc-built program
#              and in a kernel the driver JIT-compiled from our PTX
#   sanitizer  compute-sanitizer memcheck and racecheck on app.vecadd
#   ncu        Nsight Compute collects instruction metrics on app.vecadd (needs CAP_SYS_ADMIN on hosts where
#              profiling is restricted to administrators; the check records the error otherwise)
#
# The job fails (exit 1) only when the jit check fails; every other result is recorded in results.tsv.
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
JOB_ID=${JOB_ID:-$(date -u +%Y%m%dT%H%M%SZ)${H100_JOB_ID:+-q$H100_JOB_ID}}
OUT=${OUT:-$HOME/kamui-jobs/env-probe/$JOB_ID}
PROBE_STEPS=${PROBE_STEPS:-versions jit nvbit sanitizer ncu}
WORK=${WORK:-$(mktemp -d)}
# The driver caches JIT results in the home directory; a cache hit returns an empty JIT log. Every load here
# should compile, so the logs show what ptxas did.
export CUDA_CACHE_DISABLE=1
mkdir -p "$OUT"
exec > >(tee -a "$OUT/job.log") 2>&1

VECADD=tests/corpus/base/app.vecadd/kernel.ptx
BAD=docs/examples/cuda/bad.ptx
PROBE=(python3 tools/env/jit_probe.py "$VECADD" --launch-vecadd)
STARTED=$(date -Is)
printf 'step\tcheck\tstatus\tdetail\n' > "$OUT/results.tsv"

result() {  # result <step> <check> <ok|failed|skipped> <detail>
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$OUT/results.tsv"
    echo "== $1/$2: $3 ($4)"
}
has_step() { [[ " $PROBE_STEPS " == *" $1 "* ]]; }

echo "job: env-probe  id: $JOB_ID  start: $STARTED  steps: $PROBE_STEPS"
cd "$REPO" || exit 1
nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader | tee "$OUT/gpu.txt"

# ---- versions ----------------------------------------------------------------
if has_step versions; then
    nvidia-smi > "$OUT/nvidia-smi.txt" 2>&1
    # Serial numbers are left out; the UUID identifies the card.
    nvidia-smi -q 2>&1 | grep -v -i 'serial number' > "$OUT/nvidia-smi-q.txt"
    nvidia-smi --query-gpu=name,driver_version,compute_cap,clocks.max.sm,clocks.max.mem,memory.total,power.limit,ecc.mode.current,mig.mode.current \
        --format=csv > "$OUT/gpu.csv" 2>&1
    cat /proc/driver/nvidia/version > "$OUT/driver-version.txt" 2>&1
    for t in nvcc ptxas nvdisasm cuobjdump compute-sanitizer ncu nsys; do
        "$t" --version > "$OUT/$t.txt" 2>&1 || echo "$t: not available" > "$OUT/$t.txt"
    done
    (clang++-20 --version || clang++ --version) > "$OUT/clang.txt" 2>&1
    {
        echo "NVBIT_PATH=${NVBIT_PATH:-}"
        grep -h 'define NVBIT_VERSION' "${NVBIT_PATH:-/opt/nvbit}/core/nvbit.h" 2>&1
    } > "$OUT/nvbit.txt"
    {
        echo "CUTLASS_PATH=${CUTLASS_PATH:-}"
        grep -hE 'define CUTLASS_(MAJOR|MINOR|PATCH) ' "${CUTLASS_PATH:-/opt/cutlass}/include/cutlass/version.h" 2>&1
    } > "$OUT/cutlass.txt"
    [[ -f /opt/env-manifest.txt ]] && cp /opt/env-manifest.txt "$OUT/image-manifest.txt"
    python3 - > "$OUT/python-packages.txt" 2>&1 <<'EOF'
import importlib, sys
print("python", sys.version.split()[0])
for m in ["torch", "triton", "flash_attn", "flashinfer", "cutlass", "numpy", "yaml", "pytest"]:
    try:
        mod = importlib.import_module(m)
        print(m, getattr(mod, "__version__", "?"))
    except Exception as e:
        print(m, "NOT AVAILABLE", type(e).__name__)
try:
    import torch
    print("torch.version.cuda", torch.version.cuda, "cudnn", torch.backends.cudnn.version())
    print("torch device", torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0))
except Exception as e:
    print("torch cuda check failed", e)
EOF
    result versions record ok "$(head -1 "$OUT/gpu.txt")"
fi

# ---- jit ---------------------------------------------------------------------
JIT_OK=1
if has_step jit; then
    if "${PROBE[@]}" > "$OUT/jit-probe.txt" 2>&1; then
        result jit vecadd ok "$(grep -m1 '^cuModuleLoadDataEx' "$OUT/jit-probe.txt"); $(grep -m1 '^launch' "$OUT/jit-probe.txt")"
    else
        JIT_OK=0
        result jit vecadd failed "$(grep -m1 -E '^(cuModuleLoadDataEx|result)' "$OUT/jit-probe.txt")"
    fi
    if python3 tools/env/jit_probe.py "$BAD" --expect-fail > "$OUT/jit-probe-bad.txt" 2>&1; then
        result jit bad-ptx ok "$(grep -m1 '^cuModuleLoadDataEx' "$OUT/jit-probe-bad.txt")"
    else
        JIT_OK=0
        result jit bad-ptx failed "$(grep -m1 '^result' "$OUT/jit-probe-bad.txt")"
    fi
    # The image's offline ptxas on the same file, for comparison with the driver JIT.
    if ptxas -arch=sm_90a -v -o "$WORK/vecadd.cubin" "$VECADD" > "$OUT/ptxas-vecadd.txt" 2>&1; then
        result jit offline-ptxas ok "$(grep -m1 'Used' "$OUT/ptxas-vecadd.txt" | sed 's/^ptxas info *: //')"
    else
        result jit offline-ptxas failed "$(tail -1 "$OUT/ptxas-vecadd.txt")"
    fi
fi

# ---- nvbit -------------------------------------------------------------------
if has_step nvbit; then
    NB=${NVBIT_PATH:-/opt/nvbit}
    if cmake -S "$NB/tools" -B "$WORK/nvbit" -DCMAKE_BUILD_TYPE=Release > "$OUT/nvbit-build.txt" 2>&1 \
        && cmake --build "$WORK/nvbit" --target instr_count -j 8 >> "$OUT/nvbit-build.txt" 2>&1; then
        SO=$(find "$WORK/nvbit" -name 'instr_count.so' | head -1)
    else
        SO=
    fi
    if [[ -z "$SO" ]]; then
        result nvbit build failed "see nvbit-build.txt"
    else
        result nvbit build ok "${SO#"$WORK"/}"
        if nvcc -arch=sm_90a -O2 -o "$WORK/vectoradd" "$NB/test-apps/vectoradd/vectoradd.cu" > "$OUT/nvbit-nvcc-app.txt" 2>&1 \
            && LD_PRELOAD=$SO "$WORK/vectoradd" >> "$OUT/nvbit-nvcc-app.txt" 2>&1 \
            && grep -qE 'total instructions [1-9]' "$OUT/nvbit-nvcc-app.txt"; then
            result nvbit nvcc-app ok "$(grep -m1 -oE 'total instructions [0-9]+' "$OUT/nvbit-nvcc-app.txt")"
        else
            result nvbit nvcc-app failed "see nvbit-nvcc-app.txt"
        fi
        if LD_PRELOAD=$SO "${PROBE[@]}" > "$OUT/nvbit-jit.txt" 2>&1 \
            && grep -qE 'total instructions [1-9]' "$OUT/nvbit-jit.txt"; then
            result nvbit jit-ptx ok "$(grep -m1 -oE 'total instructions [0-9]+' "$OUT/nvbit-jit.txt")"
        else
            result nvbit jit-ptx failed "see nvbit-jit.txt"
        fi
    fi
fi

# ---- sanitizer ---------------------------------------------------------------
if has_step sanitizer; then
    for tool in memcheck racecheck; do
        if compute-sanitizer --tool "$tool" --error-exitcode 3 "${PROBE[@]}" > "$OUT/sanitizer-$tool.txt" 2>&1; then
            result sanitizer "$tool" ok "$(grep -m1 'ERROR SUMMARY\|RACECHECK SUMMARY' "$OUT/sanitizer-$tool.txt")"
        else
            result sanitizer "$tool" failed "$(grep -m1 'ERROR SUMMARY\|RACECHECK SUMMARY\|Error' "$OUT/sanitizer-$tool.txt")"
        fi
    done
fi

# ---- ncu ---------------------------------------------------------------------
if has_step ncu; then
    cap=$(awk '/^CapEff/ {print $2}' /proc/self/status)
    if ncu --clock-control none --csv --page raw --print-units base \
        --metrics smsp__inst_executed.sum,sass__inst_executed_per_opcode "${PROBE[@]}" > "$OUT/ncu-metrics.txt" 2>&1 \
        && grep -q 'smsp__inst_executed.sum' "$OUT/ncu-metrics.txt"; then
        result ncu metrics ok "CapEff=$cap"
    else
        result ncu metrics failed "CapEff=$cap; $(grep -m1 -E 'ERR_|==ERROR==' "$OUT/ncu-metrics.txt")"
    fi
fi

# ---- manifest ----------------------------------------------------------------
python3 - "$OUT" "$REPO" "$JOB_ID" "$STARTED" "$PROBE_STEPS" <<'EOF'
import csv, datetime, subprocess, sys
import yaml
out, repo, job_id, started, steps = sys.argv[1:]
def sh(c):
    r = subprocess.run(c, shell=True, capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
name, driver, uuid, bus = (s.strip() for s in sh(
    "nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader").split(","))
m = {
    "job": "env-probe",
    "job_id": job_id,
    "started": started,
    "finished": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "git_commit": sh(f"git -C {repo} rev-parse HEAD"),
    "git_dirty": bool(sh(f"git -C {repo} status --porcelain")),
    "gpu": {"name": name, "uuid": uuid, "pci_bus_id": bus, "driver": driver},
    "cuda_toolkit": sh("nvcc --version | tail -1"),
    "steps": steps.split(),
    "results": list(csv.DictReader(open(f"{out}/results.tsv"), delimiter="\t")),
}
yaml.safe_dump(m, open(f"{out}/manifest.yaml", "w"), sort_keys=False, width=120)
EOF
rm -rf "$WORK"
echo "done: $(date -Is)  jit: $([[ $JIT_OK == 1 ]] && echo ok || echo FAILED)  results: $OUT/results.tsv"
[[ $JIT_OK == 1 ]]
