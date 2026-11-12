(** * What is proved

    This file states the theorems and proves nothing: each statement is a [Definition] of a proposition. [Main.v]
    proves them ([Theorem lowering_correct : execution_level_statement], and so on), and [statement.txt] holds
    their printed form, which CI compares. [STATEMENT.md] explains them in plain words. *)

From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87 Kamui Lowering.

(** A relation between a PTX execution [P], a Kamui execution [K] and the map [M] between their events. *)
Definition LoweringRel : Type :=
  forall (EP EK S A C : Type), Exec EP S A C -> Exec EK S A C -> Map EP EK -> Prop.

(** ** The execution level

    For every well-formed PTX program [P] and every well-formed execution [K] of its lowering, the PTX execution
    read back from [K] is well-formed (with no other assumption: this is what the outcomes of a program with a
    mixed-size data race need, D38); if [K] satisfies the Kamui model, it satisfies the PTX model; and undefined
    behaviour and mixed-size data races of [K] are ones of [P] too. *)
Definition correct_for (L : LoweringRel) : Prop :=
  forall (EP EK S A C : Type) (P : Exec EP S A C) (K : Exec EK S A C) (M : Map EP EK),
    wf_prog P -> L EP EK S A C P K M -> kamui_wf K ->
       wf_exec P
    /\ (kamui_consistent K -> consistent P)
    /\ (kamui_undefined K -> undefined P)
    /\ (kamui_mixed_size_race K -> mixed_size_race P).

Definition execution_level_statement : Prop :=
  correct_for (fun EP EK S A C P K M => lowering P K M).

(** ** The program level

    A program is a set of candidate executions (the program's own facts: its events, program order, locations,
    the values its read-modify-writes compute, ...), and an outcome a set of executions (the condition of a litmus
    test, on values and final memory). An outcome is [allowed] exactly when [tools/litmus/run_formal.py] says
    [allowed] for it: some execution of the program satisfies the model and has the outcome or undefined
    behaviour; or the program has a mixed-size data race (in an execution that satisfies the model) and some
    well-formed execution has the outcome, the axioms set aside (D38). *)
Definition allowed {E S A C} (prog out : Exec E S A C -> Prop) : Prop :=
  (exists X, prog X /\ wf X /\ consistent X /\ (out X \/ undefined X))
  \/ ((exists X, prog X /\ wf X /\ consistent X /\ mixed_size_race X) /\ (exists X, prog X /\ wf X /\ out X)).

(** If the PTX program is well-formed and every well-formed execution of the Kamui program is the lowering of an
    execution of the PTX program, with an outcome that maps to the PTX outcome, then every outcome the Kamui
    program allows, the PTX program allows. (That the Kamui program is the lowering of the PTX program, the
    hypothesis, is what a compiler must achieve; it is not proved here.) *)
Definition program_level_statement : Prop :=
  forall (EP EK S A C : Type)
         (progP outP : Exec EP S A C -> Prop) (progK outK : Exec EK S A C -> Prop),
    (forall P, progP P -> wf_prog P) ->
    (forall K, progK K -> kamui_wf K -> exists P M, progP P /\ lowering P K M /\ (outK K -> outP P)) ->
    allowed progK outK -> allowed progP outP.

(** ** The statement can fail

    For each broken lowering, the execution-level statement is false: some program and execution of its broken
    lowering are a counterexample. *)
Definition broken_lowerings_fail : Prop :=
     ~ correct_for (fun EP EK S A C P K M => broken_drop_acquire P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_narrow_fence P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_std_weak_load P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_mbar_relaxed P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_copy_unordered P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_drop_restrict P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_drop_proxy_fence P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_relax_nc P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_cluster_relaxed P K M)
  /\ ~ correct_for (fun EP EK S A C P K M => broken_drop_tensormap_release P K M).
