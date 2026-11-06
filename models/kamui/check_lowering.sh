#!/usr/bin/env bash
# Run the bounded check of the PTX 8.7 to Kamui lowering (compile_ptx87_kamui.als) with Alloy 6.2.0, one Alloy
# process per command, in parallel, in the build area. Run in the dev container:
#
#   tools/dev.sh 'models/kamui/check_lowering.sh all'      # every check at bound 4 (UNSAT) and the sanity runs (SAT)
#   tools/dev.sh 'models/kamui/check_lowering.sh broken'   # the broken lowerings (each must be SAT)
#   tools/dev.sh 'models/kamui/check_lowering.sh bound5'   # every check at bound 5 (long; see README.md)
#   tools/dev.sh 'models/kamui/check_lowering.sh core_causality_4 sanity_core'   # some commands by name
#
# ALLOY6_SOLVER picks the SAT solver (default lingeling.parallel, plingeling), CPUS a taskset core list for each
# Alloy process, LIMIT a time limit per command in seconds (default 43200, 12 hours: a command still running is
# stopped and reported as "no result"), JOBS the number of commands run at once (default 16).
#
# Prints one line per command: the command, SAT or UNSAT, the time. A check passes with UNSAT, a sanity run and a
# broken lowering with SAT. The exit status is 1 if any command has the wrong result.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
alloy_home="${ALLOY6_HOME:-/opt/alloy/alloy-6.2.0}"
jar="$alloy_home/lib/app/org.alloytools.alloy.dist.jar"
solver="${ALLOY6_SOLVER:-lingeling.parallel}"
limit="${LIMIT:-43200}"
jobs="${JOBS:-16}"
pin=()
[ -n "${CPUS:-}" ] && pin=(taskset -c "$CPUS")
src="$here/compile_ptx87_kamui.als"
names() { grep -oE "^$1" "$src" | sed 's/:$//' ; }
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
run_one() {
  c="$1"
  w="$(mktemp -d -p "$base")"
  cp "$root"/models/ptx87/{ptx87,util}.als "$here"/{kamui,compile_ptx87_kamui}.als "$w/"
  start=$(date +%s)
  r=$(cd "$w" && timeout "$limit" "${pin[@]}" java -Djava.io.tmpdir="$w" -Djava.library.path="$alloy_home/lib/runtime/lib" \
        -jar "$jar" exec -n -s "$solver" -f -c "$c" -o "$w/out" compile_ptx87_kamui.als 2>&1 | grep -oE '\b(UNSAT|SAT)\b' | head -1 || true)
  t=$(( $(date +%s) - start ))
  want=UNSAT; case "$c" in sanity_*|broken_*) want=SAT ;; esac
  ok=ok; [ "${r:-}" = "$want" ] || ok=WRONG
  [ -z "${r:-}" ] && { r="no result"; ok=WRONG; }
  echo "$c: $r ($t s) $ok" | tee -a "$out"
  rm -rf "$w"
}
export -f run_one; export base root here alloy_home jar solver limit out
export PIN="${pin[*]:-}"
printf '%s\n' "${cmds[@]}" | xargs -P "$jobs" -I{} bash -c 'pin=($PIN); run_one "$@"' _ {}
! grep -q WRONG "$out"
