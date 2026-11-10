#!/usr/bin/env bash
# Run the commands of a comparison file of this directory (nv2019.als, ...) with Alloy 6.2.0, one Alloy process
# per command, in parallel, in the build area. Run in the dev container (image 0.4 or later, for kissat):
#
#   tools/dev.sh 'models/ptx87/equiv/check.sh nv2019.als'                    # every check and run of the file
#   tools/dev.sh 'JOBS=16 models/ptx87/equiv/check.sh nv2019.als ours_atomicity_4 sanity_core_sc'
#   tools/dev.sh 'models/ptx87/equiv/check.sh build/x/other.als'        # a file elsewhere (a path with a /)
#
#   JOBS    commands run at once (default 8); each uses one CPU
#   LIMIT   time limit per command in seconds (default 3600; a command still running is reported as "no result")
#
# A check (`name: check ...`) passes with UNSAT. Its CNF is solved by kissat; a counterexample (SAT) is found again
# with glucose and kept, as Alloy's XML instance, in build/ptx87-equiv/cex/<file>/<command>/. A run (`sanity_*`) must
# be SAT and uses glucose. Prints one line per command (name, result, seconds), also appended to a results file in
# build/ptx87-equiv/. Exit status 1 if a sanity run is not SAT or a command has no result; a counterexample is a
# finding to explain, not a failure of the script.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
alloy_home="${ALLOY6_HOME:-/opt/alloy/alloy-6.2.0}"
jar="$alloy_home/lib/app/org.alloytools.alloy.dist.jar"
limit="${LIMIT:-3600}"
[ $# -ge 1 ] || { echo "usage: check.sh FILE.als [COMMAND...]" >&2; exit 2; }
file="$(basename "$1")"
if [ -f "$1" ] && [[ "$1" == */* ]]; then src="$(cd "$(dirname "$1")" && pwd)/$file"; else src="$here/$1"; fi
shift
[ -f "$src" ] || { echo "check.sh: no file $src" >&2; exit 2; }
cmds=("$@")
if [ ${#cmds[@]} -eq 0 ]; then
  mapfile -t cmds < <(grep -oE '^[a-z_0-9]+: check' "$src" | cut -d: -f1; grep -oE '^sanity_[a-z_0-9]+: run' "$src" | cut -d: -f1)
fi
base="$root/build/ptx87-equiv"
mkdir -p "$base/cex/${file%.als}"
out="$(mktemp -p "$base" results.XXXX)"
echo "results: $out" >&2

run_one() {
  local c="$1" w start log r t want ok s cnf
  w="$(mktemp -d -p "$base")"
  cp "$root"/models/ptx87/{ptx87,util}.als "$src" "$w/"
  start=$(date +%s)
  solve() {
    (cd "$w" && JAVA_TOOL_OPTIONS="-XX:ActiveProcessorCount=1" timeout "$limit" \
      java -Djava.io.tmpdir="$w" -Djava.library.path="$alloy_home/lib/runtime/lib" \
      -jar "$jar" exec -n -s "$1" -f -c "$c" -t text -o "$w/out" "$(basename "$src")" 2>&1 || true)
  }
  s=glucose
  case "$c" in
    sanity_*) want=SAT; log="$(solve glucose)" ;;
    *) want=UNSAT
       solve CNF > /dev/null
       cnf="$(find "$w/out" -name '*.cnf' | head -1)"
       if [ -z "$cnf" ]; then log=""
       elif ! grep -qvE '^(p cnf 0 0|c)' "$cnf"; then   # settled during translation: the CNF is empty
         log="$(solve glucose)"
         if grep -qw SAT <<< "$log" && ! grep -qw UNSAT <<< "$log"; then
           rm -rf "$base/cex/${file%.als}/$c"; cp -r "$w/out" "$base/cex/${file%.als}/$c"
         fi
       else
         s=kissat
         case "$(timeout "$limit" kissat -q "$cnf" | grep '^s ' || true)" in
           "s UNSATISFIABLE") log=UNSAT ;;
           "s SATISFIABLE") s=glucose; rm -rf "$w/out"; log="$(solve glucose)"
                            rm -rf "$base/cex/${file%.als}/$c"; cp -r "$w/out" "$base/cex/${file%.als}/$c" ;;
           *) log="" ;;
         esac
       fi ;;
  esac
  r=$(grep -oE '\b(UNSAT|SAT)\b' <<< "$log" | head -1 || true)
  t=$(( $(date +%s) - start ))
  ok=ok
  [ -z "${r:-}" ] && { r="no result"; ok=WRONG; }
  [ "$want" = SAT ] && [ "$r" != SAT ] && ok=WRONG
  [ "$want" = UNSAT ] && [ "$r" = SAT ] && ok=COUNTEREXAMPLE
  echo "$c: $r ($t s, $s) $ok" >> "$out"
  echo "$c: $r ($t s) $ok"
  rm -rf "$w"
}
export -f run_one
export base root here src file alloy_home jar limit out
printf '%s\n' "${cmds[@]}" | xargs -P "${JOBS:-8}" -I{} bash -c 'run_one "$@"' _ {}
! grep -q WRONG "$out"
