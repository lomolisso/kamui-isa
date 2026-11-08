(** * The Kamui memory model

    The Kamui memory model is the PTX ISA 8.7 model: [models/kamui/kamui.als] is [models/ptx87/ptx87.als] below
    its [module] line (decision K1 of [models/kamui/decisions.md]; [tools/proofs/check.sh] checks the two files).
    Its executions, well-formedness, axioms and undefined behaviour are those of [Ptx87.v], under Kamui names. What
    makes a Kamui program different is only which events its instructions produce ([models/kamui/instructions.yaml]),
    and so which PTX events the lowering ([Lowering.v]) maps to which Kamui events. *)

From KamuiProof Require Export Ptx87.

Definition kamui_wf {E S A C} (X : Exec E S A C) : Prop := wf X.
Definition kamui_consistent {E S A C} (X : Exec E S A C) : Prop := consistent X.
Definition kamui_undefined {E S A C} (X : Exec E S A C) : Prop := undefined X.
Definition kamui_mixed_size_race {E S A C} (X : Exec E S A C) : Prop := mixed_size_race X.
