#!/usr/bin/env bash
# Compare the well-formedness of Ptx87.v (wf_prog and wf_exec, as extracted into the checker) with the facts of the
# Alloy model, on executions that are not well formed.
#
# The litmus comparison (litmus.py) shows that the checker accepts every execution Alloy finds; it cannot show that
# the checker rejects what Alloy rejects, so a fact missing from Ptx87.v would go unnoticed. Here AlloyDump makes
# mutants of the executions of some litmus tests (dump.sh --mutate: one field changed, by a removed, added or
# replaced tuple) and says for each whether it satisfies the model's facts, field declarations and signature facts.
# The checker must give the same answer on every mutant.
#
#   tools/dev.sh 'make -C proofs/rocq checker && proofs/rocq/extract/diff.sh --jobs 24'
#   tools/dev.sh 'proofs/rocq/extract/diff.sh --every 1 --mutate 3 --jobs 48'          # every test
#   tools/dev.sh 'proofs/rocq/extract/diff.sh tests/litmus/alloy-ptx87/kamui/hand/X.als'
#   proofs/rocq/extract/diff.sh --check proofs/rocq/extract/mutants.txt                  # a stored sample (CI)
#
# Options:
#   --every K    the default sample: every K-th query of tests/litmus/alloy-ptx87, by name (default 40)
#   --max N      at most N executions per query (default 2)
#   --mutate N   at most N mutants of each kind per field and execution (default 2)
#   --seed S     the seed of the random choice of mutants (default 1)
#   --jobs J     queries in parallel (default 8)
#   --out FILE   also write all the mutants, with Alloy's answers, to FILE (to store a sample for --check)
#   --check FILE run the checker on FILE (written by --out) instead of making mutants: needs no Alloy
#
# Prints the number of mutants per field and how many were rejected, then every disagreement. Exit status: 0 when
# the two agree on every mutant, 1 on a disagreement, 2 on an error.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
checker="$root/build/rocq/src/checker"
work="$root/build/rocq-extract/diff"

every=40 max=2 mutate=2 seed=1 jobs=8 out="" check=""
queries=()
while [ $# -gt 0 ]; do
  case "$1" in
    --every|--max|--mutate|--seed|--jobs|--out|--check)
      [ $# -ge 2 ] || { echo "diff.sh: $1 needs a value" >&2; exit 2; }
      v="$2"
      case "$1" in
        --every) every="$v" ;; --max) max="$v" ;; --mutate) mutate="$v" ;; --seed) seed="$v" ;;
        --jobs) jobs="$v" ;; --out) out="$v" ;; --check) check="$v" ;;
      esac
      shift 2 ;;
    -*) echo "diff.sh: unknown option $1" >&2; exit 2 ;;
    *) queries+=("$1"); shift ;;
  esac
done
[ -x "$checker" ] || { echo "diff.sh: no $checker (make -C proofs/rocq checker)" >&2; exit 2; }
if [ -n "$check" ]; then
  [ -f "$check" ] || { echo "diff.sh: no file $check" >&2; exit 2; }
  mkdir -p "$(dirname "$work")"
  input="$(mktemp -p "$(dirname "$work")" diff-input.XXXXXX)"
  cp "$check" "$input"
fi
rm -rf "$work"
mkdir -p "$work"

if [ -n "$check" ]; then
  mv "$input" "$work/all.dump"
else
  if [ ${#queries[@]} -eq 0 ]; then
    mapfile -t queries < <(find "$root/tests/litmus/alloy-ptx87" -name '*.als' | LC_ALL=C sort | awk -v k="$every" 'NR % k == 1')
  fi
  # One query: its mutants, then the checker's answers. dump.sh exits with 3 when a query has more than --max
  # executions, which is expected here.
  one() {
    local q="$1" n
    n="$(echo "${q#"$root"/}" | tr '/' '_')"
    rc=0
    "$here/dump.sh" --all --max "$max" --mutate "$mutate" --seed "$seed" "$q" > "$work/$n.dump" 2> "$work/$n.log" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
      echo "diff.sh: dump.sh failed on $q (see $work/$n.log)" >&2
      return 1
    fi
  }
  export -f one
  export here work max mutate seed root
  printf '%s\n' "${queries[@]}" | xargs -P "$jobs" -I{} bash -c 'one "$@"' _ {} || { echo "diff.sh: a dump failed" >&2; exit 2; }
  cat "$work"/*.dump > "$work/all.dump"
  [ -z "$out" ] || cp "$work/all.dump" "$out"
fi

"$checker" --wf < "$work/all.dump" > "$work/all.ans" || { echo "diff.sh: the checker failed" >&2; exit 2; }

# The two answers per block, in the order of the dump: <name> <number> <alloy wf> <rocq wf>.
awk '/^instance /{k=$2" "$3} /^alloy wf /{print k, $3}' "$work/all.dump" > "$work/alloy.txt"
awk '/^instance /{k=$2" "$3} /^rocq wf /{print k, $3}' "$work/all.ans" > "$work/rocq.txt"
if ! cmp -s <(cut -d' ' -f1,2 "$work/alloy.txt") <(cut -d' ' -f1,2 "$work/rocq.txt"); then
  echo "diff.sh: the checker's blocks are not those of the dump" >&2
  exit 2
fi
paste -d' ' "$work/alloy.txt" <(cut -d' ' -f3 "$work/rocq.txt") > "$work/both.txt"

# A mutant is named <query>.<field>.<del|add|rep><i>; an execution itself has the query's name.
awk '
  { n = split($1, p, ".")
    if (n >= 3 && p[n] ~ /^(del|add|rep)[0-9]+$/) f = p[n-1]; else f = "(none)"
    total[f]++; if ($3 == 0) rejected[f]++
    if ($3 != $4) { bad++; diff[bad] = $1 " " $2 ": Alloy wf " $3 ", Rocq wf " $4 }
    all++ }
  END {
    printf "%-22s %8s %8s\n", "field", "mutants", "rejected"
    for (f in total) printf "%-22s %8d %8d\n", f, total[f], rejected[f] | "sort"
    close("sort")
    printf "%d blocks (the executions are field (none)), %d disagreements\n", all, bad + 0
    for (i = 1; i <= bad; i++) print "  " diff[i]
    exit bad > 0 }' "$work/both.txt"
