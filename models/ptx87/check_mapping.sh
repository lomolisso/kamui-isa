#!/usr/bin/env bash
# Run the scoped C++ to PTX 8.7 mapping check (compile_src11_ptx87.als) with Alloy 6.2.0, one Alloy process per
# command, in parallel, in the build area. Run in the dev container:
#
#   tools/dev.sh 'models/ptx87/check_mapping.sh'                      # the quick checks and the sanity runs
#   tools/dev.sh 'models/ptx87/check_mapping.sh src11_ptx87_legal_sc' # some of them
#
# ALLOY6_SOLVER picks the SAT solver (default glucose; lingeling.parallel is plingeling, multi-threaded), CPUS a
# taskset core list for each Alloy process (for example 0-31), so that a parallel solver uses only those cores.
#
# Prints one line per command: the command, SAT or UNSAT, the time. A check passes with UNSAT (no counterexample
# within its bound); a sanity run passes with SAT (an instance exists, so the checks are not vacuous).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
alloy_home="${ALLOY6_HOME:-/opt/alloy/alloy-6.2.0}"
jar="$alloy_home/lib/app/org.alloytools.alloy.dist.jar"
solver="${ALLOY6_SOLVER:-glucose}"
pin=()
[ -n "${CPUS:-}" ] && pin=(taskset -c "$CPUS")
cmds=("$@")
if [ ${#cmds[@]} -eq 0 ]; then
  # the quick set; the longer checks (coherence_5, sc_5, *_5e7s, the bound 6 checks) run only when named, see
  # README.md for their times
  cmds=(coherence_4 atomicity_4 sc_4 atomicity_5 atomicity_5e7s src11_ptx87_legal_atomicity
        src11_ptx87_legal_no_thin_air sanity MP MP_cluster)
fi
base="$root/build/ptx87-mapping"
mkdir -p "$base"
for c in "${cmds[@]}"; do
  (
    w="$(mktemp -d -p "$base")"
    cp "$here"/{ptx87,util,src11,compile_src11_ptx87}.als "$w/"
    start=$(date +%s)
    out=$(cd "$w" && "${pin[@]}" java -Djava.io.tmpdir="$w" -Djava.library.path="$alloy_home/lib/runtime/lib" \
          -jar "$jar" exec -n -s "$solver" -f -c "$c" -o "$w/out" compile_src11_ptx87.als 2>&1 | grep -E '^[0-9]+\. ' || true)
    echo "$c: ${out:-no result} ($(( $(date +%s) - start )) s)"
    rm -rf "$w"
  ) &
done
wait
