#!/usr/bin/env bash
# Check the Rocq proof of the PTX 8.7 to Kamui lowering after it is built (make -C proofs/rocq). In the dev container
# or in CI's Rocq image:
#
#   tools/dev.sh 'make -C proofs/rocq && tools/proofs/check.sh'
#   tools/dev.sh 'tools/proofs/check.sh --update'    # rewrite statement.txt and assumptions.txt (after an approved
#                                                     # change of a trusted file only; see proofs/rocq/STATEMENT.md)
#
# What it checks (each failure is printed; the exit status is 1 if any fails):
#   1. the trusted files (Ptx87.v, Kamui.v, Lowering.v, Theorem.v) match proofs/rocq/trusted.sha256;
#   2. models/kamui/kamui.als is models/ptx87/ptx87.als below the module line (Kamui.v relies on it);
#   3. no proof file uses a forbidden command (Admitted, admit, Axiom, Parameter, ...); comments are ignored;
#   4. rocqchk, the independent checker, re-checks every compiled file (hahn's too); the axioms it reports, those
#      of every loaded library, are the seven standard-library ones of STATEMENT.md section 7;
#   5. the printed statements match proofs/rocq/statement.txt and the printed axioms proofs/rocq/assumptions.txt.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$root/proofs/rocq"
out="${OUT:-$root/build/rocq}"
update=0; [ "${1:-}" = --update ] && update=1
fail=0
bad() { echo "FAIL: $*"; fail=1; }
whitelist='classic|functional_extensionality_dep|propositional_extensionality|constructive_definite_description'
# every axiom the loaded libraries declare (rocqchk); the theorems may use only the four above (Print Assumptions)
env_axioms='Stdlib\.Logic\.(Classical_Prop\.classic|FunctionalExtensionality\.functional_extensionality_dep|PropExtensionality\.propositional_extensionality|Description\.constructive_definite_description|IndefiniteDescription\.constructive_indefinite_description|RelationalChoice\.relational_choice|ClassicalUniqueChoice\.dependent_unique_choice|ExtensionalFunctionRepresentative\.extensional_function_representative)'

# 1. trusted files
if [ -f "$src/trusted.sha256" ]; then
  (cd "$src" && sha256sum --quiet -c trusted.sha256) || bad "a trusted file differs from trusted.sha256"
else
  bad "proofs/rocq/trusted.sha256 is missing"
fi

# 2. the Kamui model is the PTX model (K1)
body() { sed '0,/^module /d' "$1"; }
cmp -s <(body "$root/models/ptx87/ptx87.als") <(body "$root/models/kamui/kamui.als") \
  || bad "models/kamui/kamui.als differs from models/ptx87/ptx87.als below the module line"

# 3. forbidden commands, outside comments
forbidden='\b(Admitted|admit|give_up|Axiom|Axioms|Parameter|Parameters|Conjecture|Hypothesis|Hypotheses|Variable|Variables|native_compute|Abort|Program)\b|Unset\s+(Guard|Positivity|Universe)\s+Checking|bypass_check'
while IFS= read -r f; do
  perl -0777 -ne '1 while s/\(\*(?:(?!\(\*|\*\)).)*\*\)//gs; print' "$f" | grep -nP "$forbidden" \
    | sed "s|^|${f#"$root"/}: |" | grep . && bad "forbidden command in ${f#"$root"/}"
done < <(find "$src" -name '*.v' | sort)

# 4. rocqchk on every compiled file
if [ -d "$out/src" ] && [ -d "$out/hahn" ]; then
  mapfile -t hahn < <(cd "$out/hahn" && find . -name '*.vo' | sed 's|^\./||; s|\.vo$||; s|/|.|g; s|^|hahn.|' | sort)
  mapfile -t ours < <(cd "$out/src" && find . -name '*.vo' | sed 's|^\./||; s|\.vo$||; s|/|.|g; s|^|KamuiProof.|' | sort)
  chk="$(cd "$out" && rocqchk -silent -o -R hahn hahn -Q src KamuiProof "${hahn[@]}" "${ours[@]}" 2>&1)" \
    || { echo "$chk" | tail -20; bad "rocqchk rejected a file"; }
  extra="$(echo "$chk" | sed -n '/^\* Axioms:/,/^\* Constants/p' | grep -E '^ +[A-Za-z]' | grep -vxE " +$env_axioms" || true)"
  [ -z "$extra" ] || { echo "$extra"; bad "rocqchk reports an axiom outside STATEMENT.md section 7"; }
  # each of these lines ends in <none> unless some constant or inductive skips a check (type in type, an unguarded
  # fixpoint, an assumed positivity)
  unsafe="$(echo "$chk" | grep -E '^\* (Constants/Inductives relying|Inductives whose positivity)' | grep -v '<none>$' || true)"
  [ -z "$unsafe" ] || { echo "$unsafe"; bad "rocqchk reports a disabled check"; }
  echo "$chk" | grep -q '^\* Theory: Rewrite rules are not allowed' || bad "rocqchk reports rewrite rules"
else
  bad "no build in $out: run make -C proofs/rocq first"
fi

# 5. statements and axioms, printed by Print.v
if [ -d "$out/src" ]; then
  cp "$src/Print.v" "$out/src/Print.v"
  printed="$(cd "$out/src" && rocq compile -R ../hahn hahn -Q . KamuiProof Print.v 2>&1)" || { echo "$printed"; bad "Print.v failed"; }
  statement="$(echo "$printed" | sed '/^Axioms:\|^Closed under the global context/,$d')"
  assumptions="$(echo "$printed" | sed -n '/^Axioms:\|^Closed under the global context/,$p')"
  if [ "$update" = 1 ]; then
    echo "$statement" > "$src/statement.txt"; echo "$assumptions" > "$src/assumptions.txt"
    echo "wrote proofs/rocq/statement.txt and proofs/rocq/assumptions.txt"
  else
    diff <(echo "$statement") "$src/statement.txt" > /dev/null || bad "the printed statements differ from statement.txt"
    diff <(echo "$assumptions") "$src/assumptions.txt" > /dev/null || bad "the printed axioms differ from assumptions.txt"
  fi
  # one line per axiom, "Name : type", the name maybe qualified (Classical_Prop.classic)
  echo "$assumptions" | grep -E "^ *[A-Za-z_][A-Za-z0-9_.']* :" | grep -vE "^ *([A-Za-z0-9_']+\.)*($whitelist) :" \
    && bad "an axiom outside the whitelist"
fi

[ "$fail" = 0 ] && echo "proof checks passed"
exit "$fail"
