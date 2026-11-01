#!/usr/bin/env bash
# jobs/litmus-h100.sh : run the litmus kernels on the H100 and count their outcomes.
#
# Inputs (committed): tests/litmus/h100/**/{kernel.ptx,spec.txt}, tools/litmus/runner/, tools/litmus/run_h100.py
# Outputs (under $OUT): results/<test path>/<config>.json (outcome histograms), run.yaml, run.log, build.log,
#                       gpu.txt, manifest.yaml, job.log
# Runs on: the H100 job image with one GPU visible as device 0. See docs/tools/h100-jobs.md.
#
# TESTS (a glob over test ids, default all), CONFIGS (default plain,stress,shuffle), INSTANCES (per test and
# configuration, default 1000000) and SHARD (K/N, default 0/1) select the work, so a large run can be split into
# several jobs. RESUME=1 with OUT set to an earlier run's folder finishes an interrupted run, skipping every
# test and configuration whose result is already complete. Nothing is timed: the results are outcome counts, so the job needs no clock lock.
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
JOB_ID=${JOB_ID:-$(date -u +%Y%m%dT%H%M%SZ)${H100_JOB_ID:+-q$H100_JOB_ID}}
OUT=${OUT:-$HOME/kamui-jobs/litmus-h100/$JOB_ID}
TESTS=${TESTS:-*}
CONFIGS=${CONFIGS:-plain,stress,shuffle}
INSTANCES=${INSTANCES:-1000000}
SHARD=${SHARD:-0/1}
RESUME=${RESUME:-0}
WORK=${WORK:-$(mktemp -d)}
export CUDA_CACHE_DISABLE=1
mkdir -p "$OUT"
exec > >(tee -a "$OUT/job.log") 2>&1
STARTED=$(date -Is)
echo "job: litmus-h100  id: $JOB_ID  start: $STARTED  tests: $TESTS  configs: $CONFIGS  instances: $INSTANCES  shard: $SHARD"
cd "$REPO" || exit 1
nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader | tee "$OUT/gpu.txt"

if ! { cmake -S tools/litmus/runner -B "$WORK/runner" -G Ninja -DCMAKE_BUILD_TYPE=Release > "$OUT/build.log" 2>&1 \
        && cmake --build "$WORK/runner" >> "$OUT/build.log" 2>&1; }; then
    echo "runner build failed"
    tail -20 "$OUT/build.log"
    exit 1
fi

EXTRA=()
[[ $RESUME == 1 ]] && EXTRA+=(--resume)
python3 tools/litmus/run_h100.py --runner "$WORK/runner/litmus_runner" --out "$OUT" --tests "$TESTS" \
    --configs "$CONFIGS" --instances "$INSTANCES" --shard "$SHARD" "${EXTRA[@]}" | tee -a "$OUT/run.log"
RC=${PIPESTATUS[0]}

python3 - "$OUT" "$REPO" "$JOB_ID" "$STARTED" "$RC" <<'PY'
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
    "job": "litmus-h100", "job_id": job_id, "started": started,
    "finished": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "git_commit": sh(f"git -C {repo} rev-parse HEAD"),
    "git_dirty": bool(sh(f"git -C {repo} status --porcelain")),
    "gpu": {"name": name, "uuid": uuid, "pci_bus_id": bus, "driver": driver},
    "cuda_toolkit": sh("nvcc --version | tail -1"),
    "run_exit": int(rc),
    "summary": summary[-1].split(":", 1)[1].strip() if summary else "",
}
yaml.safe_dump(m, open(f"{out}/manifest.yaml", "w"), sort_keys=False, width=120)
PY
rm -rf "$WORK"
echo "done: $(date -Is)  run exit: $RC"
exit "$RC"
