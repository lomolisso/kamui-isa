(** The statements, printed in full, and the axioms of the theorems. [tools/proofs/check.sh] compiles this file
    and compares the output with [statement.txt] (the [Print]s) and [assumptions.txt] (the [Print Assumptions]). *)

From KamuiProof Require Import Ptx87 Kamui Lowering.
Require Import KamuiProof.Theorem.

Print LoweringRel.
Print correct_for.
Print execution_level_statement.
Print allowed.
Print program_level_statement.
Print broken_lowerings_fail.
