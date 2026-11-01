#!/usr/bin/env bash
# jobs/goldens.sh : run every corpus entry on the H100 and record its golden outputs.
#
# Inputs (committed): tests/corpus/**/{kernel.ptx,entry.yaml}, tools/runner/, tools/corpus/gen_inputs.py,
#                     tools/evidence/nvbit/dump_cubin/
# Outputs (under $OUT): goldens/<id>/{outputs.bin,golden.yaml}, goldens/manifest.yaml, jit-sass/<id>.json
#                       (nvdisasm -json of the code the driver JIT produced), run.log, manifest.yaml, job.log
# Runs on: the H100 job image with one GPU visible as device 0. See docs/tools/h100-jobs.md.
#
# Each entry runs 3 times with zeroed output buffers and once with 0xA5-filled ones (run_all.py), once under
# compute-sanitizer memcheck and racecheck, and once under the NVBit cubin dump. ENTRIES (space-separated entry
# directories) limits the run to some entries; SANITIZER="" skips the sanitizer runs.
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
JOB_ID=${JOB_ID:-$(date -u +%Y%m%dT%H%M%SZ)${H100_JOB_ID:+-q$H100_JOB_ID}}
OUT=${OUT:-$HOME/kamui-jobs/goldens/$JOB_ID}
SANITIZER=${SANITIZER-memcheck,racecheck}
WORK=${WORK:-$(mktemp -d)}
export CUDA_CACHE_DISABLE=1
mkdir -p "$OUT"
exec > >(tee -a "$OUT/job.log") 2>&1
STARTED=$(date -Is)
echo "job: goldens  id: $JOB_ID  start: $STARTED"
cd "$REPO" || exit 1
nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader | tee "$OUT/gpu.txt"

# ---- build -------------------------------------------------------------------
cmake -S tools/runner -B "$WORK/runner" -G Ninja -DCMAKE_BUILD_TYPE=Release > "$OUT/build.log" 2>&1 \
    && cmake --build "$WORK/runner" >> "$OUT/build.log" 2>&1 || { echo "runner build failed"; tail -20 "$OUT/build.log"; exit 1; }
DUMP=
if cmake -S tools/evidence/nvbit -B "$WORK/nvbit" -G Ninja -DCMAKE_BUILD_TYPE=Release >> "$OUT/build.log" 2>&1 \
    && cmake --build "$WORK/nvbit" >> "$OUT/build.log" 2>&1; then
    DUMP=$(find "$WORK/nvbit" -name dump_cubin.so | head -1)
fi
echo "runner: built; nvbit dump tool: ${DUMP:-not built (see build.log)}"

# ---- run ---------------------------------------------------------------------
read -r -a SELECT <<< "${ENTRIES:-}"
[[ ${#SELECT[@]} -eq 0 ]] && SELECT=(--all)
ARGS=(--runner "$WORK/runner/runner" --out "$WORK/run" --job-id "$JOB_ID" --runs 3 --timeout 30
      --sanitizer "$SANITIZER")
[[ -n "$DUMP" ]] && ARGS+=(--nvbit-dump "$DUMP" --jit-sass-dir "$OUT/jit-sass")
python3 tools/runner/run_all.py "${SELECT[@]}" "${ARGS[@]}" | tee "$OUT/run.log"
RC=${PIPESTATUS[0]}
cp -r "$WORK/run/goldens" "$OUT/goldens"

# ---- manifest ----------------------------------------------------------------
python3 - "$OUT" "$REPO" "$JOB_ID" "$STARTED" "$RC" <<'EOF'
import datetime, subprocess, sys
import yaml
out, repo, job_id, started, rc = sys.argv[1:]
def sh(c):
    r = subprocess.run(c, shell=True, capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
name, driver, uuid, bus = (s.strip() for s in sh(
    "nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader").split(","))
summary = [l for l in open(f"{out}/run.log") if l.startswith("summary:")]
m = {
    "job": "goldens", "job_id": job_id, "started": started,
    "finished": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "git_commit": sh(f"git -C {repo} rev-parse HEAD"),
    "git_dirty": bool(sh(f"git -C {repo} status --porcelain")),
    "gpu": {"name": name, "uuid": uuid, "pci_bus_id": bus, "driver": driver},
    "cuda_toolkit": sh("nvcc --version | tail -1"),
    "run_all_exit": int(rc),
    "summary": summary[-1].split(":", 1)[1].strip() if summary else "",
}
yaml.safe_dump(m, open(f"{out}/manifest.yaml", "w"), sort_keys=False, width=120)
EOF
rm -rf "$WORK"
echo "done: $(date -Is)  run_all exit: $RC"
exit "$RC"
