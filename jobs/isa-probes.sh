#!/usr/bin/env bash
# jobs/isa-probes.sh : run the probe kernels of tests/probes/ on the H100 with the corpus runner.
#
# The probes measure execution-model facts rather than instruction results: forward progress of the lanes of a
# warp, where lanes reconverge, bar.warp.sync from two program points, the generic address windows, the cost of
# scopes and fences, setmaxnreg waiting, and BREAK. Every spin loop in them is bounded, so a probe that cannot
# make progress ends and reports it instead of hanging.
#
# Inputs (committed): tests/probes/*/ (kernel.ptx, entry.yaml), tools/runner/
# Outputs (under $OUT): goldens/<probe>/{golden.yaml,outputs.bin} (the first of RUNS runs; tools/evidence/probes.py
#                       decodes them), runs/<probe>/run<k>.bin (every run, for run-to-run spread), run.log,
#                       gpu.txt, manifest.yaml, job.log
# Runs on: the H100 job image with one GPU visible as device 0. See docs/tools/h100-jobs.md.
# PROBES (space-separated probe names) selects probes; RUNS sets the runs per probe (default 5).
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
JOB_ID=${JOB_ID:-$(date -u +%Y%m%dT%H%M%SZ)${H100_JOB_ID:+-q$H100_JOB_ID}}
OUT=${OUT:-$HOME/kamui-jobs/isa-probes/$JOB_ID}
RUNS=${RUNS:-5}
WORK=${WORK:-$(mktemp -d)}
export CUDA_CACHE_DISABLE=1
mkdir -p "$OUT"
exec > >(tee -a "$OUT/job.log") 2>&1
STARTED=$(date -Is)
echo "job: isa-probes  id: $JOB_ID  start: $STARTED"
cd "$REPO" || exit 1
nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader | tee "$OUT/gpu.txt"

if ! { cmake -S tools/runner -B "$WORK/runner" -G Ninja -DCMAKE_BUILD_TYPE=Release > "$OUT/build.log" 2>&1 \
        && cmake --build "$WORK/runner" >> "$OUT/build.log" 2>&1; }; then
    echo "runner build failed"
    tail -20 "$OUT/build.log"
    exit 1
fi

SELECT=()
for p in ${PROBES:-$(find tests/probes -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)}; do
    SELECT+=("tests/probes/$p")
done
python3 tools/runner/run_all.py "${SELECT[@]}" --runner "$WORK/runner/runner" --out "$WORK/run" \
    --job-id "$JOB_ID" --runs "$RUNS" --timeout 60 | tee "$OUT/run.log"
RC=${PIPESTATUS[0]}
cp -r "$WORK/run/goldens" "$OUT/goldens"
for d in "$WORK"/run/work/*/; do
    n=$(basename "$d")
    mkdir -p "$OUT/runs/$n"
    cp "$d"/run*.bin "$OUT/runs/$n/" 2>/dev/null
done

python3 - "$OUT" "$REPO" "$JOB_ID" "$STARTED" "$RC" "$RUNS" <<'EOF'
import datetime, subprocess, sys
import yaml
out, repo, job_id, started, rc, runs = sys.argv[1:]
def sh(c):
    r = subprocess.run(c, shell=True, capture_output=True, text=True)
    return r.stdout.strip() or r.stderr.strip()
name, driver, uuid, bus = (s.strip() for s in sh(
    "nvidia-smi --query-gpu=name,driver_version,uuid,pci.bus_id --format=csv,noheader").split(","))
summary = [l for l in open(f"{out}/run.log") if l.startswith("summary:")]
m = {
    "job": "isa-probes", "job_id": job_id, "started": started,
    "finished": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "git_commit": sh(f"git -C {repo} rev-parse HEAD"),
    "git_dirty": bool(sh(f"git -C {repo} status --porcelain")),
    "gpu": {"name": name, "uuid": uuid, "pci_bus_id": bus, "driver": driver},
    "runs": int(runs), "run_all_exit": int(rc),
    "summary": summary[-1].split(":", 1)[1].strip() if summary else "",
}
yaml.safe_dump(m, open(f"{out}/manifest.yaml", "w"), sort_keys=False, width=120)
EOF
rm -rf "$WORK"
echo "done: $(date -Is)  run_all exit: $RC"
exit "$RC"
