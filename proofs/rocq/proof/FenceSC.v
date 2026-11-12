(** * Fence-SC restores sequential consistency

    The manual introduces [fence.sc] for this purpose (8.10.2): in a program whose memory operations are strong at
    the system scope, with a [fence.sc] between any two memory operations of a thread, every execution the model
    allows is sequentially consistent. This file proves it for the model of [Ptx87.v], for executions of any size
    ([models/ptx87/equiv/fence_sc.als] checks the same claim on small executions).

    The proof. In this fragment every communication edge ([rf], [co], [fr]) stays on one location, and any two
    distinct memory operations of one location are morally strong, as are any two distinct [fence.sc]s.
    - A memory operation [b] cannot come before [a] in base causality when [a] reaches [b] by communication
      ([no_bco_against_com]): base causality makes [b] cause [a], and each shape of the communication path breaks
      causality or coherence.
    - So for fences [f1 po a com* b po f2], [f2] cannot come before [f1] in the Fence-SC order, which is total on
      them: [f1] comes before [f2] ([fenced_path_sc]).
    - A cycle of program order and communication then gives a cycle of the Fence-SC order, which is acyclic; a
      cycle of communication alone breaks SC per location. *)

From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87.

Set Implicit Arguments.

Section Fragment.

Context {E S A C : Type} (X : Exec E S A C).

(** The fragment: generic accesses at the system scope, one virtual address per location, no access granule, and
    a [fence.sc] between any two memory operations of a thread. *)
Record sc_fenced : Prop := {
  scf_generic : forall e, MemoryEvent X e -> proxy X e Generic;
  scf_system : forall e, MemoryEvent X e \/ FenceSC X e -> System X (scope X e);
  scf_one_address : forall a1 a2, aliases X a1 a2 -> a1 = a2;
  scf_scalar : forall e c, ~ acc X e c;
  scf_fenced : forall e1 e2, MemoryEvent X e1 -> MemoryEvent X e2 -> (po X)⁺ e1 e2 ->
                 exists f, FenceSC X f /\ (po X)⁺ e1 f /\ (po X)⁺ f e2 }.

End Fragment.

Section Proof.

Context {E S A C : Type} {X : Exec E S A C}.
Context (WP : wf_prog X) (WE : wf_exec X) (CON : consistent X) (SF : sc_fenced X).

Local Abbreviation M := (MemoryEvent X).

(** ** Kinds *)

Lemma read_not_write {e} : Read X e -> Write X e -> False.
Proof. unfold Read, Write; intuition congruence. Qed.

Lemma fence_not_mem {e} : FenceSC X e -> M e -> False.
Proof. unfold FenceSC, MemoryEvent, Read, Write; intuition congruence. Qed.

Lemma rf_rw {w r} : rf X w r -> Write X w /\ Read X r.
Proof. apply (decl_rf WE). Qed.

Lemma co_t_ww {w w'} : (co X)⁺ w w' -> Write X w /\ Write X w'.
Proof.
  induction 1 as [x y H | x y z _ [H1 _] _ [_ H2]]; [apply (decl_co WE); auto | auto].
Qed.

(** [fr], spelled out: a read from [w0] before a later write, or a read of the initial value. *)
Lemma frE {r w} :
  fr X r w <-> (exists w0, rf X w0 r /\ (co X)⁺ w0 w)
               \/ (Read X r /\ ~ (exists w0, Write X w0 /\ rf X w0 r) /\ same_location_r X r w /\ Write X w).
Proof.
  unfold fr; split.
  - intros [[w0 [H1 H2]] | [r' [[<- [Rr N]] [w' [L [<- Ww]]]]]]; [left; exists w0; auto | right].
    splits; auto; intros [w0 [W0 R0]]; apply N; exists w0, w0; split; [split |]; auto.
  - intros [[w0 [H1 H2]] | [Rr [N [L Ww]]]]; [left; exists w0; auto | right].
    exists r; split; [split; [auto | split; auto] | exists w; split; [auto | split; auto]].
    intros [x [z [[<- Wx] Rf]]]; apply N; eauto.
Qed.

Lemma fr_rw {r w} : fr X r w -> Read X r /\ Write X w.
Proof.
  intros H; apply frE in H; destruct H as [[w0 [H1 H2]] | [R [_ [_ Wr]]]].
  - split; [apply (rf_rw H1) | apply (co_t_ww H2)].
  - split; auto.
Qed.

(** ** Locations: with no aliasing, a location is an address *)

Lemma loc_alias {x y} : same_location_r X x y -> same_alias_r X x y.
Proof.
  intros [a1 [a2 [H1 [H2 H3]]]]; apply (scf_one_address SF) in H2; subst; exists a2; auto.
Qed.

Lemma alias_loc {x y} : same_alias_r X x y -> same_location_r X x y.
Proof. intros [a [H1 H2]]; exists a, a; repeat split; auto; apply rt_refl. Qed.

Lemma alias_sym {x y} : same_alias_r X x y -> same_alias_r X y x.
Proof. intros [a [H1 H2]]; exists a; auto. Qed.

Lemma alias_trans {x y z} : same_alias_r X x y -> same_alias_r X y z -> same_alias_r X x z.
Proof.
  intros [a [H1 H2]] [b [H3 H4]].
  destruct (decl_address_one WP (decl_address WP _ _ H2)) as [c [_ U]].
  assert (a = b) as <- by (rewrite (U a H2), (U b H3); auto).
  exists a; auto.
Qed.

Lemma co_t_alias {x y} : (co X)⁺ x y -> same_alias_r X x y.
Proof.
  induction 1 as [x y H | x y z _ IH1 _ IH2].
  - apply loc_alias, (communication_1 WE); right; auto.
  - eapply alias_trans; eauto.
Qed.

Lemma rf_alias {x y} : rf X x y -> same_alias_r X x y.
Proof. intros H; apply loc_alias, (communication_1 WE); left; auto. Qed.

Lemma fr_alias {x y} : fr X x y -> same_alias_r X x y.
Proof.
  intros H; apply frE in H; destruct H as [[w0 [H1 H2]] | [_ [_ [L _]]]].
  - eapply alias_trans; [apply alias_sym, rf_alias, H1 | apply co_t_alias, H2].
  - apply loc_alias; auto.
Qed.

Lemma com_alias {x y} : com X x y -> same_alias_r X x y.
Proof.
  unfold com; intros [[H | H] | H]; [apply rf_alias | apply co_t_alias | apply fr_alias]; auto.
Qed.

Lemma com_mem {x y} : com X x y -> M x /\ M y.
Proof.
  unfold com, MemoryEvent; intros [[H | H] | H];
    [apply rf_rw in H | apply co_t_ww in H | apply fr_rw in H]; tauto.
Qed.

Lemma com_t_alias {x y} : (com X)⁺ x y -> same_alias_r X x y.
Proof.
  induction 1 as [x y H | x y z _ IH1 _ IH2]; [apply com_alias | eapply alias_trans]; eauto.
Qed.

(** ** Moral strength *)

Lemma system_scope {e1 e2} : M e1 \/ FenceSC X e1 -> M e2 \/ FenceSC X e2 -> scope_incl_r X e1 e2.
Proof.
  intros H1 H2.
  assert (Eq : scope X e1 = scope X e2).
  { destruct (scope_tree_1 WP) as [s [_ U]].
    rewrite (U _ (scf_system SF H1)), (U _ (scf_system SF H2)); auto. }
  destruct (threads_3 WP e1) as [t1 [T1 S1]]; destruct (threads_3 WP e2) as [t2 [T2 S2]].
  split; [exists t2; rewrite Eq | exists t1; rewrite <- Eq]; auto.
Qed.

Lemma footprint_address {e a} : footprint X e a <-> address X e a.
Proof.
  unfold footprint, same_acc; split.
  - intros [e' [[[c [H _]] | <-] H']]; [destruct (scf_scalar SF _ _ H) | auto].
  - intros H; exists e; auto.
Qed.

Lemma com_irr {x} : com X x x -> False.
Proof.
  unfold com; intros [[H | H] | H].
  - apply rf_rw in H; destruct H; eapply read_not_write; eauto.
  - apply (communication_4 WE H).
  - apply fr_rw in H; destruct H; eapply read_not_write; eauto.
Qed.

Lemma mem_ms {x y} : M x -> M y -> x <> y -> same_alias_r X x y -> ms_r X x y.
Proof.
  intros Mx My N A'.
  split; [left; apply system_scope; auto |].
  split; [exists Generic; split; left; split; auto; apply (scf_generic SF); auto |].
  split; [| auto].
  left; split; [auto |]; split; [auto |]; split; [apply alias_loc; auto |].
  split; [auto |]; split; [auto |].
  destruct A' as [a [Ha1 Ha2]].
  destruct (decl_address_one WP Mx) as [b [_ Ux]]; destruct (decl_address_one WP My) as [b' [_ Uy]].
  intros z; split; intros [a' [F Al]]; apply footprint_address in F; exists a'; split; auto;
    apply footprint_address.
  - assert (a' = a) as -> by (rewrite (Ux a' F), (Ux a Ha1); auto); auto.
  - assert (a' = a) as -> by (rewrite (Uy a' F), (Uy a Ha2); auto); auto.
Qed.

Lemma com_ms {x y} : com X x y -> ms_r X x y.
Proof.
  intros H; destruct (com_mem H); apply mem_ms; auto; [| apply com_alias; auto].
  intros <-; apply (com_irr H).
Qed.

Lemma fence_ms {f1 f2} : FenceSC X f1 -> FenceSC X f2 -> f1 <> f2 -> ms_r X f1 f2.
Proof.
  intros F1 F2 N; unfold ms_r; splits.
  - left; apply system_scope; auto.
  - exists Generic; split; right; (split; [intro H | auto]);
      first [exact (fence_not_mem F1 H) | exact (fence_not_mem F2 H)].
  - right; intros [M1 _]; exact (fence_not_mem F1 M1).
  - auto.
Qed.

(** ** Communication paths *)

Lemma rf_fr {w r w'} : rf X w r -> fr X r w' -> (co X)⁺ w w'.
Proof.
  intros H H'; apply frE in H'; destruct H' as [[w0 [H1 H2]] | [_ [N _]]].
  - rewrite (communication_2 WE _ _ _ H H1); auto.
  - destruct N; exists w; split; auto; apply (rf_rw H).
Qed.

Lemma fr_co {r w w'} : fr X r w -> (co X)⁺ w w' -> fr X r w'.
Proof.
  intros H H'; apply frE in H; apply frE; destruct H as [[w0 [H1 H2]] | [Hr [N [L _]]]].
  - left; exists w0; split; auto; eapply t_trans; eauto.
  - right; splits; auto; [| apply (co_t_ww H')].
    apply alias_loc; eapply alias_trans; [apply loc_alias, L | apply co_t_alias, H'].
Qed.

(** A communication path is [rf], or [co⁺] or [fr] followed by at most one [rf]. *)
Lemma com_path {x y} : (com X)⁺ x y -> rf X x y \/ exists z, ((co X)⁺ ∪ fr X) x z /\ (z = y \/ rf X z y).
Proof.
  intros H; apply clos_trans_tn1 in H; induction H as [y H | y z H _ IH].
  - destruct H as [[H | H] | H].
    + left; auto.
    + right; exists y; split; [left; auto | left; auto].
    + right; exists y; split; [right; auto | left; auto].
  - destruct IH as [R | [w [CF [<- | R]]]]; destruct H as [[H | H] | H].
    + exfalso; apply (read_not_write (proj2 (rf_rw R)) (proj1 (rf_rw H))).
    + exfalso; apply (read_not_write (proj2 (rf_rw R)) (proj1 (co_t_ww H))).
    + right; exists z; split; [left; eapply rf_fr; eauto | left; auto].
    + right; exists w; split; [auto | right; auto].
    + right; exists z; split; [| left; auto].
      destruct CF as [CF | CF]; [left; eapply t_trans; eauto | right; eapply fr_co; eauto].
    + exfalso; destruct CF as [CF | CF].
      * apply (read_not_write (proj1 (fr_rw H)) (proj2 (co_t_ww CF))).
      * apply (read_not_write (proj1 (fr_rw H)) (proj2 (fr_rw CF))).
    + exfalso; apply (read_not_write (proj2 (rf_rw R)) (proj1 (rf_rw H))).
    + exfalso; apply (read_not_write (proj2 (rf_rw R)) (proj1 (co_t_ww H))).
    + right; exists z; split; [| left; auto].
      assert (Co : (co X)⁺ w z) by (eapply rf_fr; eauto).
      destruct CF as [CF | CF]; [left; eapply t_trans; eauto | right; eapply fr_co; eauto].
Qed.

(** ** The key lemma: base causality never runs against communication *)

Lemma bco_ppbco {b a} : M a -> M b -> same_alias_r X b a -> bco_plain X b a -> ppbco X b a.
Proof.
  intros Ma Mb Al H.
  assert (I : same_alias X (⦗GenericM X⦘ ⨾ cause_base X ⨾ ⦗GenericM X⦘) ⊆ ppbco X)
    by (intros x y Hxy; unfold ppbco, ppbco_with; do 9 left; exact Hxy).
  apply I; split; auto; exists b; split; [split; auto; apply (scf_generic SF); auto |].
  exists a; split; [left; auto | split; auto; apply (scf_generic SF); auto].
Qed.

Lemma no_bco_against_com {a b} : M a -> M b -> (com X)⁺ a b -> bco_plain X b a -> False.
Proof.
  intros Ma Mb P B.
  destruct CON as [COH [_ [_ [_ [_ CAU]]]]].
  assert (Al : same_alias_r X b a) by (apply alias_sym, com_t_alias; auto).
  assert (Pba : ppbco X b a) by (apply bco_ppbco; auto).
  assert (Cba : cause X b a) by (left; auto).
  destruct (com_path P) as [R | [c [CF [<- | R]]]].
  - apply (CAU a); exists b; split; [left |]; auto.
  - destruct CF as [CF | CF].
    + destruct (co_t_ww CF) as [Wa Wc].
      assert (CO : (co X)⁺ c a) by (apply COH; split; [exists c; split; [split; auto |
        exists a; split; [auto | split; auto]] | apply alias_loc; auto]).
      eapply (communication_4 WE); eapply t_trans; eauto.
    + apply (CAU a); exists c; split; [right |]; auto.
  - assert (Cca : cause X c a).
    { right; exists b; split; [| exact Pba].
      exists b; split; [split; [auto | apply com_ms; left; left; auto] | apply rt_refl]. }
    destruct CF as [CF | CF].
    + destruct (co_t_ww CF) as [Wa Wc].
      assert (CO : (co X)⁺ c a).
      { apply COH; split; [exists c; split; [split; auto | exists a; split; [auto | split; auto]] |].
        apply alias_loc; eapply alias_trans; [apply rf_alias, R | auto]. }
      eapply (communication_4 WE); eapply t_trans; eauto.
    + apply (CAU a); exists c; split; [right |]; auto.
Qed.

(** ** Fences *)

Lemma po_bco {x y} : (po X)⁺ x y -> bco_plain X x y.
Proof.
  intros H; unfold bco_plain; eapply clos_trans_mon; [exact H | intros a b Hab; do 4 left; exact Hab].
Qed.

Lemma sc_bco {f1 f2} : sc X f1 f2 -> bco_plain X f1 f2.
Proof.
  intros H; destruct (decl_sc WE _ _ H) as [F1 F2]; apply t_step; right.
  assert (K1 : kind X f1 = KFenceSC) by auto; assert (K2 : kind X f2 = KFenceSC) by auto.
  split; [split; [do 3 left; auto |] |].
  - intros [x [[<- R] _]]; destruct R as [[R | R] | R].
    + apply (decl_SyncRestrictCta WP) in R; unfold FenceRel in R; congruence.
    + apply (decl_OpRestrictInit WP) in R; unfold FenceRel in R; congruence.
    + apply (decl_TxAnchor WP) in R; unfold Write in R; destruct R; congruence.
  - intros [x [_ [<- R]]]; apply (decl_SyncRestrictCluster WP) in R; unfold FenceAcq in R; congruence.
Qed.

Lemma fenced_path_sc {f1 a b f2} :
  FenceSC X f1 -> (po X)⁺ f1 a -> M a -> (com X)＊ a b -> M b -> (po X)⁺ b f2 -> FenceSC X f2 -> sc X f1 f2.
Proof.
  intros F1 P1 Ma CS Mb P2 F2.
  destruct CON as [_ [FSC _]].
  apply rtE in CS; destruct CS as [[<- _] | CP].
  - assert (P : (po X)⁺ f1 f2) by (eapply t_trans; eauto).
    apply FSC; split.
    + exists f1; split; [split; auto |]; exists f2; split; [left; apply po_bco; auto | split; auto].
    + apply fence_ms; auto; intros <-; apply (threads_1 WP P).
  - assert (Back : f1 = f2 \/ sc X f2 f1 -> False).
    { intros H; apply (no_bco_against_com Ma Mb CP).
      eapply t_trans; [apply po_bco, P2 |].
      destruct H as [<- | H]; [apply po_bco; auto |].
      eapply t_trans; [apply sc_bco, H | apply po_bco, P1]. }
    destruct (classic (f1 = f2)) as [Eq | N]; [destruct (Back (or_introl Eq)) |].
    destruct (fence_sc_order_1 WE F1 F2 N (fence_ms F1 F2 N)) as [H | H]; auto.
    destruct (Back (or_intror H)).
Qed.

Lemma com_acyclic : acyclic (com X).
Proof.
  destruct CON as [_ [_ [_ [_ [SCL _]]]]].
  eapply acyclic_mon; [apply SCL |]; intros x y H; left; split; auto; apply com_ms; auto.
Qed.

Lemma sequentially_consistent : acyclic (⦗M⦘ ⨾ ((po X)⁺ ∪ com X) ⨾ ⦗M⦘).
Proof.
  eapply acyclic_mon with (r := com X ∪ ⦗M⦘ ⨾ (po X)⁺ ⨾ ⦗M⦘); [| basic_solver].
  apply acyclic_union; [apply com_acyclic |].
  eapply acyclic_mon with
    (r := (⦗M⦘ ⨾ (po X)⁺ ⨾ ⦗FenceSC X⦘) ⨾ (⦗FenceSC X⦘ ⨾ (po X)⁺ ⨾ ⦗M⦘ ⨾ (com X)＊)).
  - apply acyclic_seqC; eapply acyclic_mon; [apply (fence_sc_order_3 WE) |].
    intros f1 f2 [b [[z1 [[E1 F1] [a [P1 [z3 [[E3 Ma] Cs]]]]]] [z4 [[E4 Mb] [z5 [P2 [E5 F2]]]]]]].
    subst; eapply fenced_path_sc; eauto.
  - intros x y [y0 [[x' [[E1 Mx] [z [P [E2 Mz]]]]] Cs]]; subst.
    destruct (scf_fenced SF Mx Mz P) as [f [F [P1 P2]]].
    exists f; split.
    + exists x'; split; [split; auto |]; exists f; split; [auto | split; auto].
    + exists f; split; [split; auto |]; exists y0; split; [auto |]; exists y0; split; [split; auto | auto].
Qed.

End Proof.

(** The theorem: every consistent execution of a program of the fragment is sequentially consistent. *)
Theorem fence_sc_restores_sc {E S A C} (X : Exec E S A C) :
  wf_prog X -> wf_exec X -> consistent X -> sc_fenced X ->
  acyclic (⦗MemoryEvent X⦘ ⨾ ((po X)⁺ ∪ com X) ⨾ ⦗MemoryEvent X⦘).
Proof. intros; apply sequentially_consistent; auto. Qed.
