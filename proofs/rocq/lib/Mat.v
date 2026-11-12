(** * Finite relations as boolean matrices

    The checkers compute the model's sets and relations on a finite execution as lists of booleans ([vec]) and
    matrices of booleans ([mat]). This file defines the operations and proves each one against the relation it
    computes, as a pointwise specification: [rspec M R] says that entry [(x, y)] of [M] is [true] exactly when
    [R x y] holds. Elements of a carrier of size [n] are the numbers below [n] ([Fin n]). *)

From Stdlib Require Import Arith Bool List Lia.
From Stdlib Require Eqdep_dec.
From hahn Require Import Hahn.
Import ListNotations.

Set Implicit Arguments.

(** ** Finite carriers *)

Definition Fin (n : nat) := { i : nat | Nat.ltb i n = true }.

Definition fin_val {n} (x : Fin n) : nat := proj1_sig x.

Lemma fin_lt {n} (x : Fin n) : fin_val x < n.
Proof. destruct x as [i H]; simpl; now apply Nat.ltb_lt. Qed.

Lemma fin_eq {n} (x y : Fin n) : fin_val x = fin_val y -> x = y.
Proof.
  destruct x as [i Hi], y as [j Hj]; simpl; intros <-.
  f_equal; apply Eqdep_dec.UIP_dec, bool_dec.
Qed.

Lemma fin_eq_iff {n} (x y : Fin n) : x = y <-> fin_val x = fin_val y.
Proof. split; [now intros -> | apply fin_eq]. Qed.

Definition to_fin {n} (i : nat) (H : i < n) : Fin n := exist _ i (proj2 (Nat.ltb_lt i n) H).

Lemma to_fin_val {n} i (H : i < n) : fin_val (to_fin H) = i.
Proof. reflexivity. Qed.

(** [existsb] and [forallb] over [0 .. n-1] are [exists] and [forall] over [Fin n]. *)
Lemma existsb_fin {n} (p : nat -> bool) (P : Fin n -> Prop) :
  (forall x : Fin n, p (fin_val x) = true <-> P x) ->
  (existsb p (List.seq 0 n) = true <-> exists x, P x).
Proof.
  intros H; rewrite existsb_exists; split.
  - intros [i [Hin Hp]]; apply in_seq in Hin.
    assert (Hl : i < n) by lia.
    exists (to_fin Hl); apply H; exact Hp.
  - intros [x Px]; exists (fin_val x); split.
    + apply in_seq; pose proof (fin_lt x); lia.
    + now apply H.
Qed.

Lemma forallb_fin {n} (p : nat -> bool) (P : Fin n -> Prop) :
  (forall x : Fin n, p (fin_val x) = true <-> P x) ->
  (forallb p (List.seq 0 n) = true <-> forall x, P x).
Proof.
  intros H; rewrite forallb_forall; split.
  - intros Hall x; apply H, Hall, in_seq; pose proof (fin_lt x); lia.
  - intros Hall i Hin; apply in_seq in Hin.
    assert (Hl : i < n) by lia.
    exact (proj2 (H (to_fin Hl)) (Hall _)).
Qed.

(** ** Vectors and matrices *)

Definition vec := list bool.
Definition mat := list (list bool).

Definition vget (v : vec) (i : nat) : bool := nth i v false.
Definition get (m : mat) (i j : nat) : bool := nth j (nth i m []) false.

Definition vmk (n : nat) (f : nat -> bool) : vec := map f (List.seq 0 n).
Definition mk (n m : nat) (f : nat -> nat -> bool) : mat := map (fun i => map (f i) (List.seq 0 m)) (List.seq 0 n).

Lemma nth_map_seq {T} (f : nat -> T) n i d : i < n -> nth i (map f (List.seq 0 n)) d = f i.
Proof.
  intros H.
  rewrite nth_indep with (d' := f 0) by (rewrite length_map, length_seq; lia).
  rewrite map_nth, seq_nth by lia; reflexivity.
Qed.

Lemma vget_vmk n f i : i < n -> vget (vmk n f) i = f i.
Proof. apply nth_map_seq. Qed.

Lemma get_mk n m f i j : i < n -> j < m -> get (mk n m f) i j = f i j.
Proof. intros Hi Hj; unfold get, mk; rewrite nth_map_seq by exact Hi; now apply nth_map_seq. Qed.

(** ** Specifications *)

Definition sspec {n} (v : vec) (P : Fin n -> Prop) : Prop := forall x, vget v (fin_val x) = true <-> P x.
Definition rspec {n m} (M : mat) (R : Fin n -> Fin m -> Prop) : Prop :=
  forall x y, get M (fin_val x) (fin_val y) = true <-> R x y.
Definition bspec (b : bool) (P : Prop) : Prop := b = true <-> P.

Lemma sspec_equiv {n} v (P Q : Fin n -> Prop) : sspec v P -> (forall x, P x <-> Q x) -> sspec v Q.
Proof. intros H E x; rewrite (H x); apply E. Qed.

Lemma rspec_equiv {n m} M (R R' : Fin n -> Fin m -> Prop) :
  rspec M R -> (forall x y, R x y <-> R' x y) -> rspec M R'.
Proof. intros H E x y; rewrite (H x y); apply E. Qed.

Lemma rspec_same {n} M (R R' : relation (Fin n)) : rspec M R -> R ≡ R' -> rspec M R'.
Proof. intros H [E1 E2]; apply rspec_equiv with (1 := H); intros x y; split; [apply E1 | apply E2]. Qed.

Lemma sspec_same {n} v (P Q : Fin n -> Prop) : sspec v P -> P ≡₁ Q -> sspec v Q.
Proof. intros H [E1 E2]; apply sspec_equiv with (1 := H); intros x; split; [apply E1 | apply E2]. Qed.

Lemma bspec_equiv b (P Q : Prop) : bspec b P -> (P <-> Q) -> bspec b Q.
Proof. unfold bspec; intros H E; rewrite H; exact E. Qed.

(** A specification built pointwise from a boolean function. *)
Lemma sspec_vmk {n} f (P : Fin n -> Prop) : (forall x, f (fin_val x) = true <-> P x) -> sspec (vmk n f) P.
Proof. intros H x; unfold sspec, rspec, bspec in *; rewrite vget_vmk by apply fin_lt; apply H. Qed.

Lemma rspec_mk {n m} f (R : Fin n -> Fin m -> Prop) :
  (forall x y, f (fin_val x) (fin_val y) = true <-> R x y) -> rspec (mk n m f) R.
Proof. intros H x y; unfold sspec, rspec, bspec in *; rewrite get_mk by apply fin_lt; apply H. Qed.

(** ** Sets *)

Definition vfull n : vec := vmk n (fun _ => true).
Definition vempty n : vec := vmk n (fun _ => false).
Definition vunion n (a b : vec) : vec := vmk n (fun i => vget a i || vget b i).
Definition vinter n (a b : vec) : vec := vmk n (fun i => vget a i && vget b i).
Definition vminus n (a b : vec) : vec := vmk n (fun i => vget a i && negb (vget b i)).
Definition vcompl n (a : vec) : vec := vmk n (fun i => negb (vget a i)).
Definition vdom n m (r : mat) : vec := vmk n (fun i => existsb (fun j => get r i j) (List.seq 0 m)).
Definition vcodom n m (r : mat) : vec := vmk m (fun j => existsb (fun i => get r i j) (List.seq 0 n)).

Section Sets.
Context {n : nat}.

Lemma sspec_full : sspec (vfull n) (fun _ : Fin n => True).
Proof. apply sspec_vmk; tauto. Qed.

Lemma sspec_empty : sspec (vempty n) (fun _ : Fin n => False).
Proof. apply sspec_vmk; intuition discriminate. Qed.

Lemma sspec_union a b (P Q : Fin n -> Prop) : sspec a P -> sspec b Q -> sspec (vunion n a b) (P ∪₁ Q).
Proof. intros Ha Hb; unfold sspec, rspec, bspec in *; apply sspec_vmk; intros x; rewrite orb_true_iff, Ha, Hb; reflexivity. Qed.

Lemma sspec_inter a b (P Q : Fin n -> Prop) : sspec a P -> sspec b Q -> sspec (vinter n a b) (P ∩₁ Q).
Proof. intros Ha Hb; unfold sspec, rspec, bspec in *; apply sspec_vmk; intros x; rewrite andb_true_iff, Ha, Hb; reflexivity. Qed.

Lemma sspec_minus a b (P Q : Fin n -> Prop) : sspec a P -> sspec b Q -> sspec (vminus n a b) (P \₁ Q).
Proof.
  intros Ha Hb; unfold sspec, rspec, bspec in *; apply sspec_vmk; intros x; rewrite andb_true_iff, negb_true_iff, Ha, <- not_true_iff_false, Hb.
  reflexivity.
Qed.

Lemma sspec_compl a (P : Fin n -> Prop) : sspec a P -> sspec (vcompl n a) (set_compl P).
Proof. intros Ha; unfold sspec, rspec, bspec in *; apply sspec_vmk; intros x; rewrite negb_true_iff, <- not_true_iff_false, Ha; reflexivity. Qed.

End Sets.

Lemma sspec_dom {n m} r (R : Fin n -> Fin m -> Prop) :
  rspec r R -> sspec (vdom n m r) (fun x => exists y, R x y).
Proof. intros H; unfold sspec, rspec, bspec in *; apply sspec_vmk; intros x; apply existsb_fin; intros y; apply H. Qed.

Lemma sspec_codom {n m} r (R : Fin n -> Fin m -> Prop) :
  rspec r R -> sspec (vcodom n m r) (fun y => exists x, R x y).
Proof. intros H; unfold sspec, rspec, bspec in *; apply sspec_vmk; intros y; apply existsb_fin; intros x; apply H. Qed.

Lemma sspec_dom_rel {n} r (R : relation (Fin n)) : rspec r R -> sspec (vdom n n r) (dom_rel R).
Proof. apply sspec_dom. Qed.

Lemma sspec_codom_rel {n} r (R : relation (Fin n)) : rspec r R -> sspec (vcodom n n r) (codom_rel R).
Proof. apply sspec_codom. Qed.

(** ** Relations *)

Definition mempty n m : mat := mk n m (fun _ _ => false).
Definition munion n m (a b : mat) : mat := mk n m (fun i j => get a i j || get b i j).
Definition minter n m (a b : mat) : mat := mk n m (fun i j => get a i j && get b i j).
Definition mminus n m (a b : mat) : mat := mk n m (fun i j => get a i j && negb (get b i j)).
Definition minv n m (a : mat) : mat := mk m n (fun i j => get a j i).
Definition mseq n m p (a b : mat) : mat :=
  mk n p (fun i k => existsb (fun j => get a i j && get b j k) (List.seq 0 m)).
Definition mdiag n (v : vec) : mat := mk n n (fun i j => Nat.eqb i j && vget v i).
Definition mopt n (a : mat) : mat := mk n n (fun i j => Nat.eqb i j || get a i j).
Definition mcross n m (a : vec) (b : vec) : mat := mk n m (fun i j => vget a i && vget b j).

Section Rels.
Context {n : nat}.

Lemma rspec_empty : rspec (mempty n n) (fun _ _ : Fin n => False).
Proof. apply rspec_mk; intuition discriminate. Qed.

Lemma rspec_union a b (R S : relation (Fin n)) : rspec a R -> rspec b S -> rspec (munion n n a b) (R ∪ S).
Proof. intros Ha Hb; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x y; rewrite orb_true_iff, Ha, Hb; reflexivity. Qed.

Lemma rspec_inter a b (R S : relation (Fin n)) : rspec a R -> rspec b S -> rspec (minter n n a b) (R ∩ S).
Proof. intros Ha Hb; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x y; rewrite andb_true_iff, Ha, Hb; reflexivity. Qed.

Lemma rspec_minus a b (R S : relation (Fin n)) : rspec a R -> rspec b S -> rspec (mminus n n a b) (R \ S).
Proof.
  intros Ha Hb; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x y.
  rewrite andb_true_iff, negb_true_iff, Ha, <- not_true_iff_false, Hb; reflexivity.
Qed.

Lemma rspec_inv a (R : relation (Fin n)) : rspec a R -> rspec (minv n n a) R⁻¹.
Proof. intros Ha; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x y; apply Ha. Qed.

Lemma rspec_seq a b (R S : relation (Fin n)) : rspec a R -> rspec b S -> rspec (mseq n n n a b) (R ⨾ S).
Proof.
  intros Ha Hb; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x z; apply existsb_fin; intros y.
  rewrite andb_true_iff, Ha, Hb; reflexivity.
Qed.

Lemma rspec_diag v (P : Fin n -> Prop) : sspec v P -> rspec (mdiag n v) ⦗P⦘.
Proof.
  intros Hv; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x y.
  rewrite andb_true_iff, Nat.eqb_eq, Hv, <- fin_eq_iff; unfold eqv_rel; split; intros [-> H]; auto.
Qed.

Lemma rspec_opt a (R : relation (Fin n)) : rspec a R -> rspec (mopt n a) R^?.
Proof. intros Ha; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x y; rewrite orb_true_iff, Nat.eqb_eq, Ha, <- fin_eq_iff; reflexivity. Qed.

Lemma rspec_cross a b (P Q : Fin n -> Prop) : sspec a P -> sspec b Q -> rspec (mcross n n a b) (P × Q).
Proof. intros Ha Hb; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x y; rewrite andb_true_iff, Ha, Hb; reflexivity. Qed.

End Rels.

(** Heterogeneous composition and inverse, for the relations between carriers ([start], [address], ...). *)
Lemma rspec_seq_het {n m p} a b (R : Fin n -> Fin m -> Prop) (S : Fin m -> Fin p -> Prop) :
  rspec a R -> rspec b S -> rspec (mseq n m p a b) (fun x z => exists y, R x y /\ S y z).
Proof.
  intros Ha Hb; unfold sspec, rspec, bspec in *; apply rspec_mk; intros x z; apply existsb_fin; intros y.
  rewrite andb_true_iff, Ha, Hb; reflexivity.
Qed.

Lemma rspec_inv_het {n m} a (R : Fin n -> Fin m -> Prop) : rspec a R -> rspec (minv n m a) (fun y x => R x y).
Proof. intros Ha; unfold sspec, rspec, bspec in *; apply rspec_mk; intros y x; apply Ha. Qed.

(** ** Transitive closure: Warshall's algorithm

    After step [k], entry [(i, j)] says whether a path of [R] goes from [i] to [j] through intermediate nodes below
    [k] only, that is [(R ⨾ ⦗below k⦘)＊ ⨾ R]. After [n] steps every node is allowed: [R⁺]. *)

Definition wstep n (w : mat) (k : nat) : mat := mk n n (fun i j => get w i j || (get w i k && get w k j)).
Fixpoint wsh n (w : mat) (k : nat) : mat := match k with 0 => w | S k => wstep n (wsh n w k) k end.
Definition mplus n (a : mat) : mat := wsh n (mk n n (get a)) n.
Definition mstar n (a : mat) : mat := mopt n (mplus n a).

Section Warshall.
Context {n : nat} (R : relation (Fin n)).

Let below (k : nat) : Fin n -> Prop := fun x => fin_val x < k.
Let W k := (R ⨾ ⦗below k⦘)＊ ⨾ R.

Lemma W_step_back k : W k ⨾ ⦗below k⦘ ⨾ R ⊆ W k.
Proof.
  unfold W; intros x z [y [[y' [Hxy' Hy'y]] [y2 [[<- Hb] Hyz]]]].
  exists y; split; [| exact Hyz].
  apply rt_trans with y'; [exact Hxy' | apply rt_step; exists y; split; [exact Hy'y | split; auto]].
Qed.

Lemma W_succ k (kk : Fin n) : fin_val kk = k ->
  W (S k) ≡ W k ∪ (W k ⨾ ⦗eq kk⦘ ⨾ W k).
Proof.
  intros Hk; unfold sspec, rspec, bspec in *; split.
  - (* a path through nodes below k+1: induction on the path, step by step from its start *)
    unfold W at 1; intros x z [y [Hxy Hyz]].
    revert z Hyz; apply clos_rt_rtn1_iff in Hxy; induction Hxy as [| y y' Hstep _ IH]; intros z Hyz.
    + left; exists x; split; [apply rt_refl | exact Hyz].
    + destruct Hstep as [y0 [Hyy0 [<- Hb]]].
      specialize (IH _ Hyy0).
      assert (Rk : forall u v, R u v -> W k u v) by (intros u v H; exists u; split; [apply rt_refl | exact H]).
      destruct (Nat.eq_dec (fin_val y0) k) as [E | E].
      * assert (y0 = kk) by (apply fin_eq; lia); subst y0.
        destruct IH as [IH | [x' [IH1 [x'' [[<- Hkx] IH2]]]]].
        -- right; exists kk; split; [exact IH | exists kk; split; [split; auto | apply Rk, Hyz]].
        -- subst x'; right; exists kk; split; [exact IH1 | exists kk; split; [split; auto | apply Rk, Hyz]].
      * assert (Hb' : below k y0) by (unfold below in *; lia).
        destruct IH as [IH | [x' [IH1 [x'' [[<- Hkx] IH2]]]]].
        -- left; apply W_step_back; exists y0; split; [exact IH | exists y0; split; [split; auto | exact Hyz]].
        -- right; exists x'; split; [exact IH1 | exists x'; split; [split; auto |]].
           apply W_step_back; exists y0; split; [exact IH2 | exists y0; split; [split; auto | exact Hyz]].
  - assert (Mon : W k ⊆ W (S k)).
    { unfold W; apply seq_mori; [| reflexivity]; apply clos_refl_trans_mori.
      unfold below; basic_solver. }
    apply inclusion_union_l; [exact Mon |].
    intros x z [y [H1 [y' [[<- <-] H2]]]].
    apply Mon in H1; apply Mon in H2.
    destruct H1 as [u [Hxu Hu]], H2 as [v [Hkv Hv]].
    exists v; split; [| exact Hv].
    apply rt_trans with kk; [| exact Hkv].
    apply rt_trans with u; [exact Hxu | apply rt_step; exists kk; split; [exact Hu | split; [reflexivity |]]].
    unfold below; pose proof (fin_lt kk); lia.
Qed.

Lemma rspec_wsh a : rspec a R -> forall k, k <= n -> rspec (wsh n a k) (W k).
Proof.
  intros Ha; unfold sspec, rspec, bspec in *; induction k as [| k IH]; intros Hk.
  - simpl; apply rspec_equiv with (1 := Ha); intros x y; unfold W; split.
    + intros H; exists x; split; [apply rt_refl | exact H].
    + intros [x' [Hx H]]; apply clos_rt_rtn1_iff in Hx; destruct Hx as [| u u' [z [_ [_ Hb]]] _].
      * exact H.
      * unfold below in Hb; lia.
  - assert (Hk' : k < n) by lia.
    specialize (IH ltac:(lia)); simpl.
    apply rspec_same with (R := W k ∪ (W k ⨾ ⦗eq (to_fin Hk')⦘ ⨾ W k)).
    2: { symmetry; apply W_succ; reflexivity. }
    apply rspec_mk; intros x y; rewrite orb_true_iff, andb_true_iff.
    pose proof (IH x (to_fin Hk')) as E1; pose proof (IH (to_fin Hk') y) as E2.
    change (fin_val (to_fin Hk')) with k in E1, E2.
    rewrite (IH x y), E1, E2; split.
    + intros [H | [H1 H2]]; [left; exact H | right; exists (to_fin Hk'); split; [exact H1 |]].
      exists (to_fin Hk'); split; [split; reflexivity | exact H2].
    + intros [H | [z [H1 [z' [[<- <-] H2]]]]]; [left; exact H | right; split; assumption].
Qed.

End Warshall.

Lemma rspec_mk_get {n} a (R : relation (Fin n)) : rspec a R -> rspec (mk n n (get a)) R.
Proof. intros Ha; unfold sspec, rspec, bspec in *; apply rspec_mk; apply Ha. Qed.

Lemma rspec_plus {n} a (R : relation (Fin n)) : rspec a R -> rspec (mplus n a) R⁺.
Proof.
  intros Ha; unfold mplus.
  apply rspec_same with (R := (R ⨾ ⦗fun x : Fin n => fin_val x < n⦘)＊ ⨾ R).
  { apply rspec_wsh; [apply rspec_mk_get; exact Ha | reflexivity]. }
  assert (E : R ⨾ ⦗fun x : Fin n => fin_val x < n⦘ ≡ R).
  { split; [basic_solver |]. intros u v H; exists v; split; [exact H | split; [reflexivity | apply fin_lt]]. }
  rewrite E, <- ct_end; reflexivity.
Qed.

Lemma rspec_star {n} a (R : relation (Fin n)) : rspec a R -> rspec (mstar n a) R＊.
Proof.
  intros Ha; unfold sspec, rspec, bspec in *; unfold mstar; apply rspec_same with (R := R⁺^?).
  - apply rspec_opt, rspec_plus; exact Ha.
  - rewrite <- cr_of_ct; reflexivity.
Qed.

(** ** Properties *)

Definition bsubset n m (a b : mat) : bool :=
  forallb (fun i => forallb (fun j => implb (get a i j) (get b i j)) (List.seq 0 m)) (List.seq 0 n).
Definition birrefl n (a : mat) : bool := forallb (fun i => negb (get a i i)) (List.seq 0 n).
Definition bacyclic n (a : mat) : bool := birrefl n (mplus n a).
Definition bnone n m (a : mat) : bool := forallb (fun i => forallb (fun j => negb (get a i j)) (List.seq 0 m)) (List.seq 0 n).

Section Props.
Context {n : nat}.

Lemma bspec_subset a b (R S : relation (Fin n)) : rspec a R -> rspec b S -> bspec (bsubset n n a b) (R ⊆ S).
Proof.
  intros Ha Hb; unfold sspec, rspec, bspec in *; unfold bspec, bsubset.
  rewrite (forallb_fin _ (fun x => forall y, R x y -> S x y)).
  - split; intros H; [intros x y; apply H | intros x y; apply H].
  - intros x; rewrite (forallb_fin _ (fun y => R x y -> S x y)); [reflexivity |].
    intros y; rewrite implb_true_iff, Ha, Hb; reflexivity.
Qed.

Lemma bspec_irrefl a (R : relation (Fin n)) : rspec a R -> bspec (birrefl n a) (irreflexive R).
Proof.
  intros Ha; unfold sspec, rspec, bspec in *; unfold bspec, birrefl, irreflexive; apply forallb_fin; intros x.
  rewrite negb_true_iff, <- not_true_iff_false, Ha; split; auto.
Qed.

Lemma bspec_acyclic a (R : relation (Fin n)) : rspec a R -> bspec (bacyclic n a) (acyclic R).
Proof. intros Ha; unfold sspec, rspec, bspec in *; apply bspec_irrefl, rspec_plus; exact Ha. Qed.

Lemma bspec_none {m} a (R : Fin n -> Fin m -> Prop) : rspec a R -> bspec (bnone n m a) (forall x y, ~ R x y).
Proof.
  intros Ha; unfold sspec, rspec, bspec in *; unfold bspec, bnone; apply forallb_fin; intros x; apply forallb_fin; intros y.
  rewrite negb_true_iff, <- not_true_iff_false, Ha; reflexivity.
Qed.

End Props.

Lemma bspec_and b c P Q : bspec b P -> bspec c Q -> bspec (b && c) (P /\ Q).
Proof. unfold bspec; intros Hb Hc; rewrite andb_true_iff, Hb, Hc; reflexivity. Qed.

Lemma bspec_or b c P Q : bspec b P -> bspec c Q -> bspec (b || c) (P \/ Q).
Proof. unfold bspec; intros Hb Hc; rewrite orb_true_iff, Hb, Hc; reflexivity. Qed.

Lemma bspec_not b P : bspec b P -> bspec (negb b) (~ P).
Proof. unfold bspec; intros Hb; rewrite negb_true_iff, <- not_true_iff_false, Hb; reflexivity. Qed.

Lemma bspec_true : bspec true True.
Proof. unfold bspec; tauto. Qed.

Lemma bspec_existsb {n} p (P : Fin n -> Prop) :
  (forall x, bspec (p (fin_val x)) (P x)) -> bspec (existsb p (List.seq 0 n)) (exists x, P x).
Proof. intros H; unfold sspec, rspec, bspec in *; apply existsb_fin, H. Qed.

Lemma bspec_forallb {n} p (P : Fin n -> Prop) :
  (forall x, bspec (p (fin_val x)) (P x)) -> bspec (forallb p (List.seq 0 n)) (forall x, P x).
Proof. intros H; unfold sspec, rspec, bspec in *; apply forallb_fin, H. Qed.

Create HintDb spec.
Global Hint Resolve sspec_full sspec_empty sspec_union sspec_inter sspec_minus sspec_compl
  sspec_dom_rel sspec_codom_rel
  rspec_empty rspec_union rspec_inter rspec_minus rspec_inv rspec_seq rspec_diag rspec_opt rspec_cross
  rspec_plus rspec_star
  bspec_subset bspec_irrefl bspec_acyclic bspec_and bspec_or bspec_not bspec_true : spec.
