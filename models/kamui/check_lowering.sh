#!/usr/bin/env bash
# Run the bounded check of the PTX 8.7 to Kamui lowering (compile_ptx87_kamui.als) with Alloy 6.2.0, one Alloy
# process per command, in parallel, in the build area. Run in the dev container:
#
#   tools/dev.sh 'models/kamui/check_lowering.sh all'      # every check at bound 4 (UNSAT) and the sanity runs (SAT)
#   tools/dev.sh 'models/kamui/check_lowering.sh broken'   # the broken lowerings (each must be SAT)
#   tools/dev.sh 'models/kamui/check_lowering.sh bound5'   # every check at bound 5 (long; see README.md)
#   tools/dev.sh 'CORES=0-47 PER=4 models/kamui/check_lowering.sh core_std_causality_4 sanity_core'
#
# Resources (pick them per host, leaving room for other users; see README.md):
#   CORES   the logical CPUs this run may use, as taskset writes them (for example 24-47,72-95), or `node<N>` for
#           a NUMA node (default: none, no pinning)
#   PER     logical CPUs per Alloy process (default 4). The CPUs are grouped into slots of whole physical cores
#           (both hyperthreads of each core, from /sys/devices/system/cpu/*/topology), PER CPUs per slot; each
#           process is pinned with taskset to one slot, held with flock while the command runs, so parallel solvers
#           never share a core. MAXJOBS caps the number of slots used. Without CORES, JOBS processes run unpinned
#           (default 4).
#   ALLOY6_SOLVER  the SAT solver of the checks (default lingeling.parallel, plingeling, multi-threaded; glucose is
#           single-threaded and was about 6 times slower on the PTX 8.7 mapping checks). Sanity runs and broken
#           lowerings, which must find an instance, always use glucose: plingeling cannot return one to Alloy.
#   LIMIT   time limit per command in seconds (default 43200, 12 hours: a command still running is stopped and
#           reported as "no result")
#
# Prints one line per command: the command, SAT or UNSAT, the time. A check passes with UNSAT, a sanity run and a
# broken lowering with SAT. Each line is also appended to a results file in build/kamui-lowering/ (named at the
# start), so results survive a lost connection. The exit status is 1 if any command has the wrong result.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
alloy_home="${ALLOY6_HOME:-/opt/alloy/alloy-6.2.0}"
jar="$alloy_home/lib/app/org.alloytools.alloy.dist.jar"
solver="${ALLOY6_SOLVER:-lingeling.parallel}"
limit="${LIMIT:-43200}"
per="${PER:-4}"
src="$here/compile_ptx87_kamui.als"
cmds=()
for a in "${@:-all}"; do
  case "$a" in
    all)    mapfile -t c < <(grep -oE '^[a-z_]+_4:' "$src" | tr -d :); cmds+=("${c[@]}")
            mapfile -t c < <(grep -oE '^run sanity_[a-z_]+' "$src" | cut -d' ' -f2); cmds+=("${c[@]}") ;;
    broken) mapfile -t c < <(grep -oE '^run broken_[a-z_]+' "$src" | cut -d' ' -f2); cmds+=("${c[@]}") ;;
    bound5) mapfile -t c < <(grep -oE '^[a-z_]+_5:' "$src" | tr -d :); cmds+=("${c[@]}") ;;
    *)      cmds+=("$a") ;;
  esac
done
base="$root/build/kamui-lowering"
mkdir -p "$base"
out="$(mktemp -p "$base" results.XXXX)"
echo "results: $out" >&2
slots=()
if [ -n "${CORES:-}" ]; then
  mapfile -t slots < <(python3 - "$CORES" "$per" "${MAXJOBS:-1000}" <<'PY'
import sys
from pathlib import Path
spec, per, cap = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def expand(s):
    out = set()
    for part in s.split(","):
        a, _, b = part.partition("-")
        out |= set(range(int(a), int(b or a) + 1))
    return out
cpu = Path("/sys/devices/system/cpu")
allowed = expand(Path(f"/sys/devices/system/node/{spec}/cpulist").read_text().strip()) if spec.startswith("node") else expand(spec)
cores = sorted({tuple(sorted(expand((cpu / f"cpu{c}/topology/thread_siblings_list").read_text().strip())))
                for c in allowed})
cores = [c for c in cores if set(c) <= allowed]          # whole physical cores only
flat = [c for core in cores for c in core]
slots = [flat[i:i + per] for i in range(0, len(flat) - per + 1, per)][:cap]
for s in slots:
    print(",".join(map(str, s)))
PY
)
  [ "${#slots[@]}" -gt 0 ] || { echo "no slot of $per CPUs in CORES=$CORES" >&2; exit 2; }
  jobs="${#slots[@]}"
  echo "slots: ${slots[*]}" >&2
else
  jobs="${JOBS:-4}"
fi
run_one() {
  c="$1"
  set -- "${SLOTS[@]:-}"
  pin=() lock=""
  if [ -n "${1:-}" ]; then   # take a free slot
    while :; do
      for s in "$@"; do
        exec {fd}>"$base/slot.$s.lock"
        if flock -n "$fd"; then pin=(taskset -c "$s"); lock="$fd"; break 2; fi
        exec {fd}>&-
      done
      sleep 1
    done
  fi
  w="$(mktemp -d -p "$base")"
  cp "$root"/models/ptx87/{ptx87,util}.als "$here"/{kamui,compile_ptx87_kamui}.als "$w/"
  start=$(date +%s)
  # plingeling cannot hand an instance back to Alloy ("Stream Closed"), so runs that expect one (sanity, broken)
  # use glucose, and a check on which plingeling fails (a counterexample) is solved again with glucose
  s="$solver"; case "$c" in sanity_*|broken_*) s=glucose ;; esac
  solve() {
    (cd "$w" && JAVA_TOOL_OPTIONS="-XX:ActiveProcessorCount=$PER_CORES" timeout "$limit" "${pin[@]}" \
      java -Djava.io.tmpdir="$w" -Djava.library.path="$alloy_home/lib/runtime/lib" \
      -jar "$jar" exec -n -s "$1" -f -c "$c" -o "$w/out" compile_ptx87_kamui.als 2>&1 || true)
  }
  log="$(solve "$s")"
  if [ "$s" != glucose ] && grep -q "could not be solved" <<< "$log"; then s=glucose; log="$(solve glucose)"; fi
  r=$(grep -oE '\b(UNSAT|SAT)\b' <<< "$log" | head -1 || true)
  t=$(( $(date +%s) - start ))
  [ -n "$lock" ] && exec {lock}>&-
  want=UNSAT; case "$c" in sanity_*|broken_*) want=SAT ;; esac
  ok=ok; [ "${r:-}" = "$want" ] || ok=WRONG
  [ -z "${r:-}" ] && { r="no result"; ok=WRONG; }
  echo "$c: $r ($t s, $s, ${pin[*]:-unpinned}) $ok" >> "$out"
  echo "$c: $r ($t s) $ok"
  rm -rf "$w"
}
export -f run_one
export base root here alloy_home jar solver limit out
export PER_CORES="$per" SLOTS_LIST="${slots[*]:-}"
printf '%s\n' "${cmds[@]}" | xargs -P "$jobs" -I{} bash -c 'read -ra SLOTS <<< "$SLOTS_LIST"; run_one "$@"' _ {}
! grep -q WRONG "$out"
