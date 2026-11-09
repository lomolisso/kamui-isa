#!/usr/bin/env bash
# Run the checks of extra.als (next to this file) with Alloy 6.2.0, one Alloy process per command, in parallel, in
# the build area. Run in the dev container:
#
#   tools/dev.sh 'proofs/rocq/als/check.sh'                     # every command of extra.als
#   tools/dev.sh 'proofs/rocq/als/check.sh broken sanity'       # the broken lowerings and the sanity runs
#   tools/dev.sh 'JOBS=24 proofs/rocq/als/check.sh std'         # the std checks (bound 3)
#   tools/dev.sh 'proofs/rocq/als/check.sh async_std_coherence_3'
#
#   JOBS    commands run at once (default 8); each solver uses one CPU
#   LIMIT   time limit per command in seconds (default 10800, 3 hours: a command still running is reported as
#           "no result")
#   SOLVER  the SAT solver of the checks: kissat (default; Alloy writes the CNF, kissat solves it) or an Alloy
#           solver name. Sanity runs and broken lowerings, which must find an instance, use glucose.
#
# Prints one line per command: the command, SAT or UNSAT, the time. A check passes with UNSAT, a sanity run and a
# broken lowering with SAT. The lines are also appended to a results file in build/rocq-als/. The exit status is 1
# if any command has the wrong result or no result.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
alloy_home="${ALLOY6_HOME:-/opt/alloy/alloy-6.2.0}"
jar="$alloy_home/lib/app/org.alloytools.alloy.dist.jar"
solver="${SOLVER:-kissat}"
limit="${LIMIT:-10800}"
src="$here/extra.als"
cmds=()
for a in "${@:-all}"; do
  case "$a" in
    all)    mapfile -t found < <(grep -oE '^[a-z_0-9]+_3:' "$src" | tr -d :); cmds+=("${found[@]}")
            mapfile -t found < <(grep -oE '^run [a-z_]+' "$src" | cut -d' ' -f2); cmds+=("${found[@]}") ;;
    std)    mapfile -t found < <(grep -oE '^[a-z_0-9]+_3:' "$src" | tr -d :); cmds+=("${found[@]}") ;;
    sanity) mapfile -t found < <(grep -oE '^run sanity_[a-z_]+' "$src" | cut -d' ' -f2); cmds+=("${found[@]}") ;;
    broken) mapfile -t found < <(grep -oE '^run broken_[a-z_]+' "$src" | cut -d' ' -f2); cmds+=("${found[@]}") ;;
    *)      cmds+=("$a") ;;
  esac
done
base="$root/build/rocq-als"
mkdir -p "$base"
out="$(mktemp -p "$base" results.XXXX)"
echo "results: $out" >&2

run_one() {
  local c="$1" w start s cnf log r t want ok
  w="$(mktemp -d -p "$base")"
  cp "$root"/models/ptx87/{ptx87,util}.als "$root"/models/kamui/{kamui,compile_ptx87_kamui}.als "$here/extra.als" "$w/"
  start=$(date +%s)
  s="$solver"; case "$c" in sanity_*|broken_*) s=glucose ;; esac
  solve() {
    (cd "$w" && JAVA_TOOL_OPTIONS="-XX:ActiveProcessorCount=1" timeout "$limit" \
      java -Djava.io.tmpdir="$w" -Djava.library.path="$alloy_home/lib/runtime/lib" \
      -jar "$jar" exec -n -s "$1" -f -c "$c" -o "$w/out" extra.als 2>&1 || true)
  }
  if [ "$s" = kissat ]; then   # Alloy writes the CNF, kissat solves it; a counterexample is found again with glucose
    solve CNF > /dev/null
    cnf="$(find "$w/out" -name '*.cnf' | head -1)"
    case "$(timeout "$limit" "${KISSAT:-kissat}" -q "$cnf" | grep '^s ' || true)" in
      "s UNSATISFIABLE") log=UNSAT ;;
      "s SATISFIABLE") s=glucose; log="$(solve glucose)" ;;
      *) log="" ;;
    esac
  else
    log="$(solve "$s")"
  fi
  r=$(grep -oE '\b(UNSAT|SAT)\b' <<< "$log" | head -1 || true)
  t=$(( $(date +%s) - start ))
  want=UNSAT; case "$c" in sanity_*|broken_*) want=SAT ;; esac
  ok=ok; [ "${r:-}" = "$want" ] || ok=WRONG
  [ -z "${r:-}" ] && { r="no result"; ok=WRONG; }
  echo "$c: $r ($t s, $s) $ok" >> "$out"
  echo "$c: $r ($t s) $ok"
  rm -rf "$w"
}
export -f run_one
export base root here alloy_home jar solver limit out
printf '%s\n' "${cmds[@]}" | xargs -P "${JOBS:-8}" -I{} bash -c 'run_one "$@"' _ {}
! grep -q WRONG "$out"
