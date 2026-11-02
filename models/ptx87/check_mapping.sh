#!/usr/bin/env bash
# Run the scoped C++ to PTX 8.7 mapping check (compile_src11_ptx87.als) with Alloy 6.2.0, one Alloy process per
# command, in parallel, in the build area. Run in the dev container:
#
#   tools/dev.sh 'models/ptx87/check_mapping.sh'                      # every check and sanity run
#   tools/dev.sh 'models/ptx87/check_mapping.sh src11_ptx87_legal_sc' # some of them
#
# Prints one line per command: the command, SAT or UNSAT, the time. A check passes with UNSAT (no counterexample
# within its bound); a sanity run passes with SAT (an instance exists, so the checks are not vacuous).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
alloy_home="${ALLOY6_HOME:-/opt/alloy/alloy-6.2.0}"
jar="$alloy_home/lib/app/org.alloytools.alloy.dist.jar"
cmds=("$@")
if [ ${#cmds[@]} -eq 0 ]; then
  cmds=(src11_ptx87_legal_coherence src11_ptx87_legal_atomicity src11_ptx87_legal_sc src11_ptx87_legal_no_thin_air
        coherence_4 coherence_5 atomicity_4 atomicity_5 sc_4 sc_5 sanity MP MP_cluster)
fi
base="$root/build/ptx87-mapping"
mkdir -p "$base"
for c in "${cmds[@]}"; do
  (
    w="$(mktemp -d -p "$base")"
    cp "$here"/{ptx87,util,src11,compile_src11_ptx87}.als "$w/"
    start=$(date +%s)
    out=$(cd "$w" && java -Djava.io.tmpdir="$w" -Djava.library.path="$alloy_home/lib/runtime/lib" -jar "$jar" \
          exec -n -s glucose -f -c "$c" -o "$w/out" compile_src11_ptx87.als 2>&1 | grep -E '^[0-9]+\. ' || true)
    echo "$c: ${out:-no result} ($(( $(date +%s) - start )) s)"
    rm -rf "$w"
  ) &
done
wait
