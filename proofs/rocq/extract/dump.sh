#!/usr/bin/env bash
# Write the instances of Alloy litmus queries in the format of FORMAT.md (next to this file), with Alloy 6.2.0.
# Compiles AlloyDump.java into build/rocq-extract/classes/ (again only when the source changed), then runs it on
# each query in its own fresh directory under build/rocq-extract/, with the model files next to the query. The
# dump goes to stdout, Alloy's messages and the instance counts to stderr. Run in the dev container:
#
#   tools/dev.sh 'proofs/rocq/extract/dump.sh tests/litmus/alloy-ptx87/kamui/ptx87/rmw/add+st+st.weak.als'
#   tools/dev.sh 'proofs/rocq/extract/dump.sh --all --max 1000 Q1.als Q2.als > build/rocq-extract/out.txt'
#   tools/dev.sh 'proofs/rocq/extract/dump.sh --cmd test --solver sat4j Q.als'
#
# Options (passed to AlloyDump, the same for every query):
#   --cmd NAME   enumerate the instances of that run command (default: unconstrained)
#   --all        enumerate the instances of the facts alone (the scopes of unconstrained)
#   --max N      at most N instances per query; a query with more is reported as truncated (exit status 3)
#   --solver S   the SAT solver (default glucose)
#   --check      also evaluate with Alloy's plain evaluator, much slower, and fail if the answers differ
#   --pair       the query is the lowering check (models/kamui/compile_ptx87_kamui.als, or proofs/rocq/als/extra.als
#                which opens it) and --cmd names one of its runs: print the PTX execution, the Kamui execution and
#                the map between them (FORMAT.md), for example
#                  tools/dev.sh 'proofs/rocq/extract/dump.sh --pair --cmd broken_drop_acquire --max 1 \
#                                models/kamui/compile_ptx87_kamui.als'
#
# Exit status: 0 done, 2 error (the remaining queries are not run), 3 some query was truncated.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
alloy_home="${ALLOY6_HOME:-/opt/alloy/alloy-6.2.0}"
jar="$alloy_home/lib/app/org.alloytools.alloy.dist.jar"
native="$alloy_home/lib/runtime/lib"   # libglucose.so, libminisat.so
base="$root/build/rocq-extract"

opts=()
queries=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cmd|--max|--solver) [ $# -ge 2 ] || { echo "dump.sh: $1 needs a value" >&2; exit 2; }
                          opts+=("$1" "$2"); shift 2 ;;
    --all|--check|--pair) opts+=("$1"); shift ;;
    -*) echo "dump.sh: unknown option $1" >&2; exit 2 ;;
    *) queries+=("$1"); shift ;;
  esac
done
if [ ${#queries[@]} -eq 0 ]; then
  echo "usage: dump.sh [--cmd NAME | --all] [--max N] [--solver S] [--check] [--pair] QUERY.als..." >&2
  exit 2
fi

# The classes of each version of the source go to classes/<its sha256>/, so a change is compiled even when the
# source was edited on a host whose clock differs, and runs started at the same time do not see a half-written
# directory: the compiled directory is renamed into place in one step.
sum="$(sha256sum "$here/AlloyDump.java" | cut -c1-16)"
classes="$base/classes/$sum"
if [ ! -d "$classes" ]; then
  mkdir -p "$base/classes"
  tmp="$(mktemp -d -p "$base/classes" new.XXXXXX)"
  javac -nowarn -cp "$jar" -d "$tmp" "$here/AlloyDump.java"
  mv -T "$tmp" "$classes" 2>/dev/null || rm -rf "$tmp"   # another run was faster
  # Older versions stay (a few kilobytes each): a run that started earlier may still load classes from them.
fi

w=""
cleanup() { if [ -n "$w" ]; then rm -rf "$w"; fi; }
trap cleanup EXIT

status=0
for q in "${queries[@]}"; do
  [ -f "$q" ] || { echo "dump.sh: no file $q" >&2; exit 2; }
  w="$(mktemp -d -p "$base" run.XXXXXX)"
  cp "$root"/models/ptx87/{ptx87,util}.als "$root"/models/kamui/{kamui,compile_ptx87_kamui}.als "$w/"
  cp "$q" "$w/"
  start=$(date +%s)
  rc=0
  # The native solvers print to stdout, so the dump goes to a file first and Java's stdout to stderr.
  (cd "$w" && JAVA_TOOL_OPTIONS="-XX:ActiveProcessorCount=1" \
    java -Djava.io.tmpdir="$w" -Djava.library.path="$native" -Dorg.slf4j.simpleLogger.defaultLogLevel=warn \
    -cp "$jar:$classes" AlloyDump "${opts[@]}" --out "$w/dump.txt" "$(basename "$q")" >&2) || rc=$?
  echo "$q: $(( $(date +%s) - start )) s" >&2
  case "$rc" in 0|3) cat "$w/dump.txt" ;; esac
  rm -rf "$w"
  w=""
  case "$rc" in
    0) ;;
    3) status=3 ;;
    *) echo "dump.sh: AlloyDump failed on $q (exit $rc)" >&2; exit 2 ;;
  esac
done
exit "$status"
