(** * A checker of the lowering on finite executions

    [b_lowering_ex FP FK FM lx ld] decides [lowering_ex] ([Lowering.v]) for a finite PTX execution [FP], a
    finite Kamui execution [FK] and a finite map [FM] between their events, with the sets [x] and [dropped]
    given as lists ([lx], [ld]). The two executions share their scopes, addresses and accesses: [align FK FP] is
    [FK] with the carriers of [FP]. Used to build counterexamples for the broken lowerings and examples of the
    lowering, all checked by computation. *)

From Stdlib Require Import Arith Bool List ZArith Lia.
From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87 Kamui Lowering.
From KamuiProof.lib Require Import Mat.
From KamuiProof.check Require Import FExec Check.
Import ListNotations.

Set Implicit Arguments.

Record FMap := { m_ev : list nat; m_pre : list (option nat); m_widen : list nat; m_relax : list nat }.

(** [FK] with the scopes, addresses and accesses of [FP]. *)
Definition align (FK FP : FExec) : FExec := {|
  ne := ne FK; ns := ns FP; na := na FP; nc := nc FP;
  f_skind := f_skind FK; f_subscope := f_subscope FK; f_start := f_start FK; f_alias := f_alias FK;
  f_space := f_space FK; f_owner := f_owner FK; f_init := f_init FK; f_kind := f_kind FK; f_po := f_po FK;
  f_scope := f_scope FK; f_issue := f_issue FK; f_done := f_done FK; f_gdep := f_gdep FK;
  f_address := f_address FK; f_proxy := f_proxy FK; f_val := f_val FK; f_acc := f_acc FK; f_rmw := f_rmw FK;
  f_dep := f_dep FK; f_rf := f_rf FK; f_co := f_co FK; f_sc := f_sc FK;
  f_SyncRestrictCta := f_SyncRestrictCta FK; f_SyncRestrictCluster := f_SyncRestrictCluster FK;
  f_OpRestrictInit := f_OpRestrictInit FK; f_ProxyFence := f_ProxyFence FK; f_dirs := f_dirs FK;
  f_pspace := f_pspace FK; f_paddr := f_paddr FK; f_bid := f_bid FK; f_bcount := f_bcount FK;
  f_bwait := f_bwait FK; f_bgen := f_bgen FK; f_synchronizes := f_synchronizes FK; f_cwait := f_cwait FK;
  f_cgen := f_cgen FK; f_ClusterArriveRelaxed := f_ClusterArriveRelaxed FK; f_Mbar := f_Mbar FK;
  f_iph := f_iph FK; f_ipend := f_ipend FK; f_iexp := f_iexp FK; f_itx := f_itx FK; f_MbarEv := f_MbarEv FK;
  f_ph := f_ph FK; f_pend := f_pend FK; f_expc := f_expc FK; f_tx := f_tx FK; f_MbarInit := f_MbarInit FK;
  f_MbarWait := f_MbarWait FK; f_wpar := f_wpar FK; f_wtok := f_wtok FK; f_TxAnchor := f_TxAnchor FK;
  f_txops := f_txops FK |}.

Definition ev_at (FM : FMap) (i : nat) : nat := nth i (m_ev FM) 0.
Definition pre_at (FM : FMap) (i : nat) : option nat := nth i (m_pre FM) None.
Definition first_at (FM : FMap) (i : nat) : nat := match pre_at FM i with Some f => f | None => ev_at FM i end.
Definition b_pre_is (FM : FMap) (i k : nat) : bool := match pre_at FM i with Some f => Nat.eqb f k | None => false end.

(** Every image and every inserted fence is a Kamui event. *)
Definition mvalid (nP nK : nat) (FM : FMap) : bool :=
  forallb (fun i => Nat.ltb (ev_at FM i) nK && match pre_at FM i with Some f => Nat.ltb f nK | None => true end)
    (List.seq 0 nP).

Lemma mvalid_ev nP nK FM (V : mvalid nP nK FM = true) i : i < nP -> ev_at FM i < nK.
Proof.
  intros H; unfold mvalid in V; rewrite forallb_forall in V.
  specialize (V i (proj2 (in_seq _ _ _) (conj (Nat.le_0_l i) H))); apply andb_true_iff in V.
  apply Nat.ltb_lt, V.
Qed.

Lemma mvalid_pre nP nK FM (V : mvalid nP nK FM = true) i f : i < nP -> pre_at FM i = Some f -> f < nK.
Proof.
  intros H E; unfold mvalid in V; rewrite forallb_forall in V.
  specialize (V i (proj2 (in_seq _ _ _) (conj (Nat.le_0_l i) H))); apply andb_true_iff in V.
  rewrite E in V; apply Nat.ltb_lt, V.
Qed.

Definition dmap nP nK FM (V : mvalid nP nK FM = true) : Map (Fin nP) (Fin nK) := {|
  ev := fun x => to_fin (@mvalid_ev nP nK FM V (fin_val x) (fin_lt x));
  pre := fun x => match pre_at FM (fin_val x) with Some f => fin_of nK f | None => None end;
  widen := fun x => mem1 (m_widen FM) (fin_val x) = true;
  relax := fun x => mem1 (m_relax FM) (fin_val x) = true |}.

(** ** Specifications by the value of each index

    [bspec (get M i j) (R x y)] whenever [M] computes [R] and [x], [y] have the values [i], [j]; the values are
    checked by [reflexivity], which covers every form of index ([ev], [scope], [first]). *)

Lemma gen_get {n m} M (R : Fin n -> Fin m -> Prop) x y i j :
  rspec M R -> fin_val x = i -> fin_val y = j -> bspec (get M i j) (R x y).
Proof. intros H <- <-; apply H. Qed.
Lemma gen_vget {n} v (Q : Fin n -> Prop) x i : sspec v Q -> fin_val x = i -> bspec (vget v i) (Q x).
Proof. intros H <-; apply H. Qed.
Lemma gen_eq {n} (x y : Fin n) i j : fin_val x = i -> fin_val y = j -> bspec (Nat.eqb i j) (x = y).
Proof. intros <- <-; apply bspec_fin_eq. Qed.
Lemma gen_mem1 {n} l (x : Fin n) i : fin_val x = i -> bspec (mem1 l i) (mem1 l (fin_val x) = true).
Proof. intros <-; unfold bspec; reflexivity. Qed.
Lemma gen_memp F (V : valid F = true) x i p : fin_val x = i -> bspec (memp (f_proxy F) i p) (proxy (denote F V) x p).
Proof. intros <-; unfold bspec; reflexivity. Qed.
Lemma gen_mems F (V : valid F = true) x i s : fin_val x = i -> bspec (mems (f_pspace F) i s) (pspace (denote F V) x s).
Proof. intros <-; unfold bspec; reflexivity. Qed.
Lemma gen_memd F (V : valid F = true) x i p q :
  fin_val x = i -> bspec (memd (f_dirs F) i p q) (dirs (denote F V) x p q).
Proof. intros <-; unfold bspec; reflexivity. Qed.

Section Spec.

Context (FP FK0 : FExec) (FM : FMap) (VP : valid FP = true) (VK : valid (align FK0 FP) = true)
        (VM : mvalid (ne FP) (ne FK0) FM = true).

Local Abbreviation FK := (align FK0 FP).
Local Abbreviation P := (denote FP VP).
Local Abbreviation K := (denote FK VK).
Local Abbreviation M := (@dmap (ne FP) (ne FK0) FM VM).

Lemma ev_val x : fin_val (ev M x) = ev_at FM (fin_val x). Proof. reflexivity. Qed.

Lemma pre_spec x k : b_pre_is FM (fin_val x) (fin_val k) = true <-> pre M x = Some k.
Proof.
  unfold b_pre_is; simpl; destruct (pre_at FM (fin_val x)) as [f |] eqn:E; [| split; congruence].
  unfold fin_of; destruct (lt_dec f (ne FK0)) as [H | H].
  - rewrite Nat.eqb_eq; split; [intros Hf; f_equal; apply fin_eq; exact Hf |].
    intros Hs; injection Hs as <-; reflexivity.
  - exfalso; apply H, (@mvalid_pre _ _ _ VM (fin_val x) f (fin_lt x) E).
Qed.

Lemma gen_pre x k i j : fin_val x = i -> fin_val k = j -> bspec (b_pre_is FM i j) (pre M x = Some k).
Proof. intros <- <-; apply pre_spec. Qed.

Lemma first_val x : fin_val (first M x) = first_at FM (fin_val x).
Proof.
  unfold first, first_at; simpl; destruct (pre_at FM (fin_val x)) as [f |] eqn:E; [| reflexivity].
  unfold fin_of; destruct (lt_dec f (ne FK0)) as [H | H]; [reflexivity |].
  exfalso; apply H, (@mvalid_pre _ _ _ VM (fin_val x) f (fin_lt x) E).
Qed.

Lemma gen_first x k i j : fin_val x = i -> fin_val k = j -> bspec (Nat.eqb (first_at FM i) j) (first M x = k).
Proof. intros <- <-; rewrite <- first_val; apply bspec_fin_eq. Qed.

Lemma gen_ev x k i j : fin_val x = i -> fin_val k = j -> bspec (Nat.eqb (ev_at FM i) j) (ev M x = k).
Proof. intros <- <-; rewrite <- ev_val; apply bspec_fin_eq. Qed.

(** [ev ↑ r] and [ev ↓ r] as matrices. *)
Definition d_collect (r : mat) : mat :=
  mk (ne FK0) (ne FK0) (fun k1 k2 => existsb (fun x => existsb (fun y =>
    get r x y && (Nat.eqb (ev_at FM x) k1 && Nat.eqb (ev_at FM y) k2)) (List.seq 0 (ne FP))) (List.seq 0 (ne FP))).
Definition d_map (r : mat) : mat := mk (ne FP) (ne FP) (fun x y => get r (ev_at FM x) (ev_at FM y)).

Lemma d_collect_spec r (R : relation (Fin (ne FP))) : rspec r R -> rspec (d_collect r) (ev M ↑ R).
Proof.
  intros H; apply rspec_mk; intros k1 k2.
  rewrite (existsb_fin _ (fun x => exists y, R x y /\ ev M x = k1 /\ ev M y = k2)); [reflexivity |].
  intros x; apply existsb_fin; intros y.
  rewrite !andb_true_iff, (H x y), !Nat.eqb_eq, <- !ev_val, <- !fin_eq_iff; reflexivity.
Qed.

Lemma d_map_spec r (R : relation (Fin (ne FK0))) : rspec r R -> rspec (d_map r) (ev M ↓ R).
Proof. intros H; apply rspec_mk; intros x y; rewrite <- !ev_val; apply H. Qed.

Lemma v_set_triv {n} l : sspec (v_set l n) (fun e : Fin n => mem1 l (fin_val e) = true).
Proof. apply v_set_spec; reflexivity. Qed.

End Spec.

(** ** Fields over all integers, said with finitely many cases *)

Definition oeqb (a b : option Z) : bool :=
  match a, b with Some x, Some y => Z.eqb x y | None, None => true | _, _ => false end.
Lemma bspec_oeq a b : bspec (oeqb a b) (a = b).
Proof. unfold bspec; destruct a, b; simpl; rewrite ?Z.eqb_eq; split; congruence. Qed.

Lemma z_field_iff {EP EK} (ev : EP -> EK) (BK : EK -> Prop) (BP : EP -> Prop) (fK : EK -> Z) (fP : EP -> Z) :
  (forall k z, (BK k /\ fK k = z) <-> exists e, ev e = k /\ BP e /\ fP e = z)
  <-> ((forall k, BK k -> exists e, ev e = k /\ BP e /\ fP e = fK k)
       /\ (forall e, BP e -> BK (ev e) /\ fK (ev e) = fP e)).
Proof.
  split.
  - intros H; split.
    + intros k Hk; apply H; auto.
    + intros e He; apply H; exists e; auto.
  - intros [H1 H2] k z; split.
    + intros [Hk <-]; apply H1, Hk.
    + intros [e [<- [He <-]]]; apply H2, He.
Qed.

Lemma o_field_iff {EP EK} (ev : EP -> EK) (BK : EK -> Prop) (BP : EP -> Prop) (fK : EK -> option Z)
  (fP : EP -> option Z) :
  (forall k z, (BK k /\ fK k = Some z) <-> exists e, ev e = k /\ BP e /\ fP e = Some z)
  <-> ((forall k, BK k -> ~ fK k = None -> exists e, ev e = k /\ BP e /\ fP e = fK k)
       /\ (forall e, BP e -> ~ fP e = None -> BK (ev e) /\ fK (ev e) = fP e)).
Proof.
  split.
  - intros H; split.
    + intros k Hk Hn; destruct (fK k) as [z |] eqn:E; [| congruence].
      destruct (proj1 (H k z) (conj Hk E)) as [e [Ee [He Hz]]]; exists e; auto.
    + intros e He Hn; destruct (fP e) as [z |] eqn:E; [| congruence].
      destruct (proj2 (H (ev e) z) (ex_intro _ e (conj eq_refl (conj He E)))) as [Hk Hz]; auto.
  - intros [H1 H2] k z; split.
    + intros [Hk Hz]; destruct (H1 k Hk ltac:(congruence)) as [e [Ee [He Hf]]]; exists e; split; [exact Ee |].
      split; [exact He | congruence].
    + intros [e [<- [He Hz]]]; destruct (H2 e He ltac:(congruence)) as [Hk Hf]; split; [exact Hk | congruence].
Qed.

Lemma rb_field_iff {EP EK} (ev : EP -> EK) (BK : EK -> Prop) (BP : EP -> Prop) (fK : EK -> Z) (fP : EP -> Z) :
  (forall e z, (BP e /\ fP e = z) <-> (BK (ev e) /\ fK (ev e) = z))
  <-> (forall e, (BP e <-> BK (ev e)) /\ (BP e -> fP e = fK (ev e))).
Proof.
  split.
  - intros H e; split; [split |].
    + intros He; apply (H e (fP e)); auto.
    + intros Hk; apply (H e (fK (ev e))); auto.
    + intros He; symmetry; apply (H e (fP e)); auto.
  - intros H e z; destruct (H e) as [[H1 H2] H3]; split.
    + intros [He <-]; split; [apply H1, He | symmetry; apply H3, He].
    + intros [Hk <-]; split; [apply H2, Hk | apply H3, H2, Hk].
Qed.

(** ** The checker *)

Section Fields.

Context (FP FK0 : FExec) (FM : FMap) (lx ld : list nat) (VP : valid FP = true) (VK : valid (align FK0 FP) = true)
        (VM : mvalid (ne FP) (ne FK0) FM = true).

Local Abbreviation FK := (align FK0 FP).
Local Abbreviation nP := (ne FP).
Local Abbreviation nK := (ne FK0).
Local Abbreviation nS := (ns FP).
Local Abbreviation nA := (na FP).
Local Abbreviation nC := (nc FP).

Definition b_bij_ev : bool := forallb (fun e1 => forallb (fun e2 => implb (Nat.eqb (ev_at FM e1) (ev_at FM e2)) (Nat.eqb e1 e2)) (List.seq 0 nP)) (List.seq 0 nP).
Definition b_bij_pre : bool := forallb (fun e1 => forallb (fun e2 => forallb (fun f => implb (b_pre_is FM e1 f) (implb (b_pre_is FM e2 f) (Nat.eqb e1 e2))) (List.seq 0 nK)) (List.seq 0 nP)) (List.seq 0 nP).
Definition b_bij_onto : bool := forallb (fun k => existsb (fun e => Nat.eqb (ev_at FM e) k) (List.seq 0 nP) || existsb (fun e => b_pre_is FM e k) (List.seq 0 nP)) (List.seq 0 nK).
Definition b_bij_disjoint : bool := forallb (fun e => forallb (fun e' => negb (b_pre_is FM e' (ev_at FM e))) (List.seq 0 nP)) (List.seq 0 nP).
Definition b_bij_relax_lone : bool := forallb (fun e1 => forallb (fun e2 => implb (mem1 (m_relax FM) e1) (implb (mem1 (m_relax FM) e2) (Nat.eqb e1 e2))) (List.seq 0 nP)) (List.seq 0 nP).
Definition b_bijections : bool := b_bij_ev && (b_bij_pre && (b_bij_onto && (b_bij_disjoint && (b_bij_relax_lone)))).
Definition b_st_skind : bool := forallb (fun s => skind_eqb (skind_at FK s) (skind_at FP s)) (List.seq 0 nS).
Definition b_st_subscope : bool := bsubset nS nS (d_subscope FK) (d_subscope FP) && bsubset nS nS (d_subscope FP) (d_subscope FK).
Definition b_same_scope_tree : bool := b_st_skind && (b_st_subscope).
Definition b_sl_alias : bool := bsubset nA nA (d_alias FK) (d_alias FP) && bsubset nA nA (d_alias FP) (d_alias FK).
Definition b_sl_space : bool := forallb (fun a => space_eqb (space_at FK a) (space_at FP a)) (List.seq 0 nA).
Definition b_sl_owner : bool :=
  let m0 := (d_owner FK) in let m1 := (d_owner FP) in 
  forallb (fun a => forallb (fun s => Bool.eqb (get m0 a s) (get m1 a s)) (List.seq 0 nS)) (List.seq 0 nA).
Definition b_sl_init : bool := forallb (fun a => Z.eqb (zat (f_init FK) a) (zat (f_init FP) a)) (List.seq 0 nA).
Definition b_sl_Mbar : bool :=
  let m0 := (d_Mbar FK) in let m1 := (d_Mbar FP) in 
  forallb (fun a => Bool.eqb (vget m0 a) (vget m1 a)) (List.seq 0 nA).
Definition b_sl_iph : bool :=
  let m0 := (d_Mbar FP) in 
  forallb (fun a => implb (vget m0 a) (Z.eqb (zat (f_iph FK) a) (zat (f_iph FP) a))) (List.seq 0 nA).
Definition b_sl_ipend : bool :=
  let m0 := (d_Mbar FP) in 
  forallb (fun a => implb (vget m0 a) (Z.eqb (zat (f_ipend FK) a) (zat (f_ipend FP) a))) (List.seq 0 nA).
Definition b_sl_iexp : bool :=
  let m0 := (d_Mbar FP) in 
  forallb (fun a => implb (vget m0 a) (Z.eqb (zat (f_iexp FK) a) (zat (f_iexp FP) a))) (List.seq 0 nA).
Definition b_sl_itx : bool :=
  let m0 := (d_Mbar FP) in 
  forallb (fun a => implb (vget m0 a) (Z.eqb (zat (f_itx FK) a) (zat (f_itx FP) a))) (List.seq 0 nA).
Definition b_same_locations : bool := b_sl_alias && (b_sl_space && (b_sl_owner && (b_sl_init && (b_sl_Mbar && (b_sl_iph && (b_sl_ipend && (b_sl_iexp && (b_sl_itx)))))))).
Definition b_so_po : bool :=
  let m0 := (d_po FK) in let m1 := (d_po FP) in 
  forallb (fun k1 => forallb (fun k2 => Bool.eqb (get m0 k1 k2) (existsb (fun e1 => existsb (fun e2 => Nat.eqb (ev_at FM e1) k1 && (get m1 e1 e2 && Nat.eqb (first_at FM e2) k2)) (List.seq 0 nP)) (List.seq 0 nP) || existsb (fun e => b_pre_is FM e k1 && Nat.eqb (ev_at FM e) k2) (List.seq 0 nP))) (List.seq 0 nK)) (List.seq 0 nK).
Definition b_so_start : bool :=
  let m0 := (d_start FK) in let m1 := (d_start FP) in 
  forallb (fun t => forallb (fun k => Bool.eqb (get m0 t k) (existsb (fun e => get m1 t e && Nat.eqb (first_at FM e) k) (List.seq 0 nP))) (List.seq 0 nK)) (List.seq 0 nS).
Definition b_so_pre_scope : bool :=
  let m0 := (d_System FK) in 
  forallb (fun e => forallb (fun f => implb (b_pre_is FM e f) (vget m0 (scope_at FK f))) (List.seq 0 nK)) (List.seq 0 nP).
Definition b_same_order : bool := b_so_po && (b_so_start && (b_so_pre_scope)).
Definition b_kd_kind : bool := forallb (fun e => implb (negb (mem1 lx e)) (kind_eqb (kind_at FK (ev_at FM e)) (kind_at FP e))) (List.seq 0 nP).
Definition b_kd_SyncRestrictCta : bool :=
  let m0 := (d_SyncRestrictCta FK) in let m1 := (d_SyncRestrictCta FP) in 
  forallb (fun e => implb (negb (mem1 lx e)) (Bool.eqb (vget m0 (ev_at FM e)) (vget m1 e))) (List.seq 0 nP).
Definition b_kd_SyncRestrictCluster : bool :=
  let m0 := (d_SyncRestrictCluster FK) in let m1 := (d_SyncRestrictCluster FP) in 
  forallb (fun e => implb (negb (mem1 lx e)) (Bool.eqb (vget m0 (ev_at FM e)) (vget m1 e))) (List.seq 0 nP).
Definition b_kd_OpRestrictInit : bool :=
  let m0 := (d_OpRestrictInit FK) in let m1 := (d_OpRestrictInit FP) in 
  forallb (fun e => implb (negb (mem1 lx e)) (Bool.eqb (vget m0 (ev_at FM e)) (vget m1 e))) (List.seq 0 nP).
Definition b_kd_ClusterArriveRelaxed : bool :=
  let m0 := (d_ClusterArriveRelaxed FK) in let m1 := (d_ClusterArriveRelaxed FP) in 
  forallb (fun e => implb (negb (mem1 lx e)) (Bool.eqb (vget m0 (ev_at FM e)) (vget m1 e))) (List.seq 0 nP).
Definition b_kd_MbarInit : bool :=
  let m0 := (d_MbarInit FK) in let m1 := (d_MbarInit FP) in 
  forallb (fun e => implb (negb (mem1 lx e)) (Bool.eqb (vget m0 (ev_at FM e)) (vget m1 e))) (List.seq 0 nP).
Definition b_kd_MbarWait : bool :=
  let m0 := (d_MbarWait FK) in let m1 := (d_MbarWait FP) in 
  forallb (fun e => implb (negb (mem1 lx e)) (Bool.eqb (vget m0 (ev_at FM e)) (vget m1 e))) (List.seq 0 nP).
Definition b_kd_TxAnchor : bool :=
  let m0 := (d_TxAnchor FK) in let m1 := (d_TxAnchor FP) in 
  forallb (fun e => implb (negb (mem1 lx e)) (Bool.eqb (vget m0 (ev_at FM e)) (vget m1 e))) (List.seq 0 nP).
Definition b_kd_ProxyFence : bool :=
  let m0 := (d_ProxyFence FK) in let m1 := (d_ProxyFence FP) in 
  forallb (fun e => implb (negb (mem1 lx e)) (Bool.eqb (vget m0 (ev_at FM e)) (vget m1 e))) (List.seq 0 nP).
Definition b_kd_pre : bool := forallb (fun e => forallb (fun f => implb (b_pre_is FM e f) (kind_eqb (kind_at FK f) KFenceSC)) (List.seq 0 nK)) (List.seq 0 nP).
Definition b_kinds : bool := b_kd_kind && (b_kd_SyncRestrictCta && (b_kd_SyncRestrictCluster && (b_kd_OpRestrictInit && (b_kd_ClusterArriveRelaxed && (b_kd_MbarInit && (b_kd_MbarWait && (b_kd_TxAnchor && (b_kd_ProxyFence && (b_kd_pre))))))))).
Definition b_sr_address : bool :=
  let m0 := (d_address FK) in let m1 := (d_address FP) in 
  forallb (fun k => forallb (fun a => Bool.eqb (get m0 k a) (existsb (fun e => Nat.eqb (ev_at FM e) k && get m1 e a) (List.seq 0 nP))) (List.seq 0 nA)) (List.seq 0 nK).
Definition b_sr_acc : bool :=
  let m0 := (d_acc FK) in let m1 := (d_acc FP) in 
  forallb (fun k => forallb (fun c => Bool.eqb (get m0 k c) (existsb (fun e => Nat.eqb (ev_at FM e) k && get m1 e c) (List.seq 0 nP))) (List.seq 0 nC)) (List.seq 0 nK).
Definition b_sr_rmw : bool := bsubset nK nK (d_rmw FK) (d_collect FP FK0 FM (d_rmw FP)) && bsubset nK nK (d_collect FP FK0 FM (d_rmw FP)) (d_rmw FK).
Definition b_sr_dep : bool := bsubset nK nK (d_dep FK) (d_collect FP FK0 FM (d_dep FP)) && bsubset nK nK (d_collect FP FK0 FM (d_dep FP)) (d_dep FK).
Definition b_sr_issue : bool := bsubset nK nK (d_issue FK) (d_collect FP FK0 FM (mseq nP nP nP (mdiag nP (vcompl nP (v_set ld nP))) (d_issue FP))) && bsubset nK nK (d_collect FP FK0 FM (mseq nP nP nP (mdiag nP (vcompl nP (v_set ld nP))) (d_issue FP))) (d_issue FK).
Definition b_sr_done : bool := bsubset nK nK (d_done FK) (d_collect FP FK0 FM (d_done FP)) && bsubset nK nK (d_collect FP FK0 FM (d_done FP)) (d_done FK).
Definition b_sr_gdep : bool := bsubset nK nK (d_gdep FK) (d_collect FP FK0 FM (d_gdep FP)) && bsubset nK nK (d_collect FP FK0 FM (d_gdep FP)) (d_gdep FK).
Definition b_sr_bid : bool :=
  let m0 := (d_BarrierArrive FK) in let m1 := (d_BarrierArrive FP) in 
  forallb (fun k => implb (vget m0 k) (existsb (fun e => Nat.eqb (ev_at FM e) k && (vget m1 e && Z.eqb (zat (f_bid FP) e) (zat (f_bid FK) k))) (List.seq 0 nP))) (List.seq 0 nK) && forallb (fun e => implb (vget m1 e) (vget m0 (ev_at FM e) && Z.eqb (zat (f_bid FK) (ev_at FM e)) (zat (f_bid FP) e))) (List.seq 0 nP).
Definition b_sr_bcount : bool :=
  let m0 := (d_BarrierArrive FK) in let m1 := (d_BarrierArrive FP) in 
  forallb (fun k => implb (vget m0 k) (implb (negb (is_none (oat (f_bcount FK) k))) (existsb (fun e => Nat.eqb (ev_at FM e) k && (vget m1 e && oeqb (oat (f_bcount FP) e) (oat (f_bcount FK) k))) (List.seq 0 nP)))) (List.seq 0 nK) && forallb (fun e => implb (vget m1 e) (implb (negb (is_none (oat (f_bcount FP) e))) (vget m0 (ev_at FM e) && oeqb (oat (f_bcount FK) (ev_at FM e)) (oat (f_bcount FP) e)))) (List.seq 0 nP).
Definition b_sr_bwait : bool := bsubset nK nK (d_bwait FK) (d_collect FP FK0 FM (d_bwait FP)) && bsubset nK nK (d_collect FP FK0 FM (d_bwait FP)) (d_bwait FK).
Definition b_sr_cwait : bool := bsubset nK nK (d_cwait FK) (d_collect FP FK0 FM (d_cwait FP)) && bsubset nK nK (d_collect FP FK0 FM (d_cwait FP)) (d_cwait FK).
Definition b_sr_wpar : bool :=
  let m0 := (d_MbarWait FK) in let m1 := (d_MbarWait FP) in 
  forallb (fun k => implb (vget m0 k) (implb (negb (is_none (oat (f_wpar FK) k))) (existsb (fun e => Nat.eqb (ev_at FM e) k && (vget m1 e && oeqb (oat (f_wpar FP) e) (oat (f_wpar FK) k))) (List.seq 0 nP)))) (List.seq 0 nK) && forallb (fun e => implb (vget m1 e) (implb (negb (is_none (oat (f_wpar FP) e))) (vget m0 (ev_at FM e) && oeqb (oat (f_wpar FK) (ev_at FM e)) (oat (f_wpar FP) e)))) (List.seq 0 nP).
Definition b_sr_wtok : bool :=
  let m0 := (d_MbarWait FK) in let m1 := (d_MbarWait FP) in 
  forallb (fun k => implb (vget m0 k) (implb (negb (is_none (oat (f_wtok FK) k))) (existsb (fun e => Nat.eqb (ev_at FM e) k && (vget m1 e && oeqb (oat (f_wtok FP) e) (oat (f_wtok FK) k))) (List.seq 0 nP)))) (List.seq 0 nK) && forallb (fun e => implb (vget m1 e) (implb (negb (is_none (oat (f_wtok FP) e))) (vget m0 (ev_at FM e) && oeqb (oat (f_wtok FK) (ev_at FM e)) (oat (f_wtok FP) e)))) (List.seq 0 nP).
Definition b_sr_txops : bool := bsubset nK nK (d_txops FK) (d_collect FP FK0 FM (d_txops FP)) && bsubset nK nK (d_collect FP FK0 FM (d_txops FP)) (d_txops FK).
Definition b_sr_proxy_fence : bool :=
  let m0 := (d_ProxyFence FP) in let m1 := (d_paddr FK) in let m2 := (d_paddr FP) in 
  forallb (fun e => implb (vget m0 e) (implb (negb (mem1 lx e)) (forallb (fun p => forallb (fun q => Bool.eqb (memd (f_dirs FK) (ev_at FM e) p q) (memd (f_dirs FP) e p q)) all_proxies) all_proxies && (forallb (fun s => Bool.eqb (mems (f_pspace FK) (ev_at FM e) s) (mems (f_pspace FP) e s)) all_spaces && forallb (fun a => Bool.eqb (get m1 (ev_at FM e) a) (get m2 e a)) (List.seq 0 nA))))) (List.seq 0 nP).
Definition b_same_relations : bool := b_sr_address && (b_sr_acc && (b_sr_rmw && (b_sr_dep && (b_sr_issue && (b_sr_done && (b_sr_gdep && (b_sr_bid && (b_sr_bcount && (b_sr_bwait && (b_sr_cwait && (b_sr_wpar && (b_sr_wtok && (b_sr_txops && (b_sr_proxy_fence)))))))))))))).
Definition b_px_same : bool :=
  let m0 := (d_MemoryEvent FP) in 
  forallb (fun e => implb (vget m0 e) (implb (negb (mem1 (m_relax FM) e)) (forallb (fun p => Bool.eqb (memp (f_proxy FK) (ev_at FM e) p) (memp (f_proxy FP) e p)) all_proxies))) (List.seq 0 nP).
Definition b_px_relax : bool :=
  let m0 := (d_Read FP) in let m1 := (d_Weak FP) in let m2 := (d_rmw FP) in 
  forallb (fun e => implb (mem1 (m_relax FM) e) (vget m0 e && (negb (existsb (fun w => get m2 e w) (List.seq 0 nP)) && (vget m1 e && (forallb (fun p => Bool.eqb (memp (f_proxy FP) e p) (proxy_eqb p Texture)) all_proxies && forallb (fun p => Bool.eqb (memp (f_proxy FK) (ev_at FM e) p) (proxy_eqb p Generic)) all_proxies))))) (List.seq 0 nP).
Definition b_proxies : bool := b_px_same && (b_px_relax).
Definition b_sc_same : bool := forallb (fun e => implb (negb (mem1 (m_widen FM) e)) (implb (negb (mem1 lx e)) (Nat.eqb (scope_at FK (ev_at FM e)) (scope_at FP e)))) (List.seq 0 nP).
Definition b_sc_widen : bool :=
  let m0 := (d_Weak FP) in let m1 := (d_subscope_star FK) in 
  forallb (fun e => implb (mem1 (m_widen FM) e) (implb (negb (mem1 lx e)) (negb (vget m0 e) && get m1 (scope_at FK (ev_at FM e)) (scope_at FP e)))) (List.seq 0 nP).
Definition b_sc_rmw : bool :=
  let m0 := (d_rmw FP) in 
  forallb (fun r => forallb (fun w => implb (get m0 r w) (Nat.eqb (scope_at FK (ev_at FM r)) (scope_at FK (ev_at FM w)))) (List.seq 0 nP)) (List.seq 0 nP).
Definition b_scopes : bool := b_sc_same && (b_sc_widen && (b_sc_rmw)).
Definition b_rb_rf : bool := bsubset nP nP (d_rf FP) (d_map FP FM (d_rf FK)) && bsubset nP nP (d_map FP FM (d_rf FK)) (d_rf FP).
Definition b_rb_co : bool := bsubset nP nP (d_co FP) (d_map FP FM (d_co FK)) && bsubset nP nP (d_map FP FM (d_co FK)) (d_co FP).
Definition b_rb_sc : bool := bsubset nP nP (d_sc FP) (minter nP nP (d_map FP FM (d_sc FK)) (d_ms_r FP)) && bsubset nP nP (minter nP nP (d_map FP FM (d_sc FK)) (d_ms_r FP)) (d_sc FP).
Definition b_rb_bgen : bool := bsubset nP nP (d_bgen FP) (d_map FP FM (d_bgen FK)) && bsubset nP nP (d_map FP FM (d_bgen FK)) (d_bgen FP).
Definition b_rb_cgen : bool := bsubset nP nP (d_cgen FP) (d_map FP FM (d_cgen FK)) && bsubset nP nP (d_map FP FM (d_cgen FK)) (d_cgen FP).
Definition b_rb_synchronizes : bool := bsubset nP nP (d_synchronizes FP) (d_map FP FM (d_synchronizes FK)) && bsubset nP nP (d_map FP FM (d_synchronizes FK)) (d_synchronizes FP).
Definition b_rb_val : bool :=
  let m0 := (d_MemoryEvent FK) in let m1 := (d_MemoryEvent FP) in 
  forallb (fun e => Bool.eqb (vget m1 e) (vget m0 (ev_at FM e)) && implb (vget m1 e) (Z.eqb (zat (f_val FP) e) (zat (f_val FK) (ev_at FM e)))) (List.seq 0 nP).
Definition b_rb_ph : bool :=
  let m0 := (d_MbarEv FK) in let m1 := (d_MbarEv FP) in 
  forallb (fun e => Bool.eqb (vget m1 e) (vget m0 (ev_at FM e)) && implb (vget m1 e) (Z.eqb (zat (f_ph FP) e) (zat (f_ph FK) (ev_at FM e)))) (List.seq 0 nP).
Definition b_rb_pend : bool :=
  let m0 := (d_MbarEv FK) in let m1 := (d_MbarEv FP) in 
  forallb (fun e => Bool.eqb (vget m1 e) (vget m0 (ev_at FM e)) && implb (vget m1 e) (Z.eqb (zat (f_pend FP) e) (zat (f_pend FK) (ev_at FM e)))) (List.seq 0 nP).
Definition b_rb_expc : bool :=
  let m0 := (d_MbarEv FK) in let m1 := (d_MbarEv FP) in 
  forallb (fun e => Bool.eqb (vget m1 e) (vget m0 (ev_at FM e)) && implb (vget m1 e) (Z.eqb (zat (f_expc FP) e) (zat (f_expc FK) (ev_at FM e)))) (List.seq 0 nP).
Definition b_rb_tx : bool :=
  let m0 := (d_MbarEv FK) in let m1 := (d_MbarEv FP) in 
  forallb (fun e => Bool.eqb (vget m1 e) (vget m0 (ev_at FM e)) && implb (vget m1 e) (Z.eqb (zat (f_tx FP) e) (zat (f_tx FK) (ev_at FM e)))) (List.seq 0 nP).
Definition b_read_back : bool := b_rb_rf && (b_rb_co && (b_rb_sc && (b_rb_bgen && (b_rb_cgen && (b_rb_synchronizes && (b_rb_val && (b_rb_ph && (b_rb_pend && (b_rb_expc && (b_rb_tx)))))))))).
Definition b_inserted : bool :=
  let m0 := (d_Acquire FP) in let m1 := (d_Release FP) in let m2 := (d_rmw FP) in 
  forallb (fun e => forallb (fun f => implb (b_pre_is FM e f) (vget m0 e && existsb (fun w => get m2 e w && vget m1 w) (List.seq 0 nP))) (List.seq 0 nK)) (List.seq 0 nP).
Definition b_lowering_ex : bool :=
  b_bijections && (b_same_scope_tree && (b_same_locations && (b_same_order && (b_kinds && (b_same_relations
  && (b_proxies && (b_scopes && (b_inserted && b_read_back)))))))).


Local Abbreviation P := (denote FP VP).
Local Abbreviation K := (denote FK VK).
Local Abbreviation M := (@dmap (ne FP) (ne FK0) FM VM).
Local Abbreviation X := (fun e : Fin (ne FP) => mem1 lx (fin_val e) = true).
Local Abbreviation D := (fun e : Fin (ne FP) => mem1 ld (fin_val e) = true).

Lemma l_ev_val x : fin_val (ev M x) = ev_at FM (fin_val x). Proof. reflexivity. Qed.

Lemma l_pre_spec x k : b_pre_is FM (fin_val x) (fin_val k) = true <-> pre M x = Some k.
Proof.
  unfold b_pre_is; simpl; destruct (pre_at FM (fin_val x)) as [f |] eqn:E; [| split; congruence].
  unfold fin_of; destruct (lt_dec f (ne FK0)) as [H | H].
  - rewrite Nat.eqb_eq; split; [intros Hf; f_equal; apply fin_eq; exact Hf |].
    intros Hs; injection Hs as <-; reflexivity.
  - exfalso; apply H, (@mvalid_pre _ _ _ VM (fin_val x) f (fin_lt x) E).
Qed.

Lemma l_gen_pre x k i j : fin_val x = i -> fin_val k = j -> bspec (b_pre_is FM i j) (pre M x = Some k).
Proof. intros <- <-; apply l_pre_spec. Qed.

Lemma l_first_val x : fin_val (first M x) = first_at FM (fin_val x).
Proof.
  unfold first, first_at; simpl; destruct (pre_at FM (fin_val x)) as [f |] eqn:E; [| reflexivity].
  unfold fin_of; destruct (lt_dec f (ne FK0)) as [H | H]; [reflexivity |].
  exfalso; apply H, (@mvalid_pre _ _ _ VM (fin_val x) f (fin_lt x) E).
Qed.

Lemma l_gen_first x k i j : fin_val x = i -> fin_val k = j -> bspec (Nat.eqb (first_at FM i) j) (first M x = k).
Proof. intros <- <-; rewrite <- l_first_val; apply bspec_fin_eq. Qed.

Lemma l_gen_ev x k i j : fin_val x = i -> fin_val k = j -> bspec (Nat.eqb (ev_at FM i) j) (ev M x = k).
Proof. intros <- <-; rewrite <- l_ev_val; apply bspec_fin_eq. Qed.

Lemma l_collect_spec r (R : relation (Fin (ne FP))) : rspec r R -> rspec (d_collect FP FK0 FM r) (ev M ↑ R).
Proof.
  intros H; apply rspec_mk; intros k1 k2.
  rewrite (existsb_fin _ (fun x => exists y, R x y /\ ev M x = k1 /\ ev M y = k2)); [reflexivity |].
  intros x; apply existsb_fin; intros y.
  rewrite !andb_true_iff, (H x y), !Nat.eqb_eq, <- !l_ev_val, <- !fin_eq_iff; reflexivity.
Qed.

Lemma l_map_spec r (R : relation (Fin (ne FK0))) : rspec r R -> rspec (d_map FP FM r) (ev M ↓ R).
Proof. intros H; apply rspec_mk; intros x y; rewrite <- !l_ev_val; apply H. Qed.

Ltac leaf := first [
  exact (d_CtaScope_spec FK VK)
  | exact (d_ClusterScope_spec FK VK)
  | exact (d_AsyncUnit_spec FK VK)
  | exact (d_Thread_spec FK VK)
  | exact (d_Acquire_spec FK VK)
  | exact (d_Read_spec FK VK)
  | exact (d_Release_spec FK VK)
  | exact (d_Write_spec FK VK)
  | exact (d_MemoryEvent_spec FK VK)
  | exact (d_FenceAcq_spec FK VK)
  | exact (d_FenceRel_spec FK VK)
  | exact (d_FenceSC_spec FK VK)
  | exact (d_FenceAcqRel_spec FK VK)
  | exact (d_Fence_spec FK VK)
  | exact (d_AliasFence_spec FK VK)
  | exact (d_PlainProxyFence_spec FK VK)
  | exact (d_BarrierArrive_spec FK VK)
  | exact (d_BarrierWait_spec FK VK)
  | exact (d_Barrier_spec FK VK)
  | exact (d_ClusterArrive_spec FK VK)
  | exact (d_ClusterWait_spec FK VK)
  | exact (d_Marker_spec FK VK)
  | exact (d_SyncRestrictCta_spec FK VK)
  | exact (d_SyncRestrictCluster_spec FK VK)
  | exact (d_OpRestrictInit_spec FK VK)
  | exact (d_ProxyFence_spec FK VK)
  | exact (d_ClusterArriveRelaxed_spec FK VK)
  | exact (d_MbarEv_spec FK VK)
  | exact (d_MbarInit_spec FK VK)
  | exact (d_MbarWait_spec FK VK)
  | exact (d_TxAnchor_spec FK VK)
  | exact (d_Mbar_spec FK VK)
  | exact (d_po_spec FK VK)
  | exact (d_issue_spec FK VK)
  | exact (d_done_spec FK VK)
  | exact (d_gdep_spec FK VK)
  | exact (d_rmw_spec FK VK)
  | exact (d_dep_spec FK VK)
  | exact (d_rf_spec FK VK)
  | exact (d_co_spec FK VK)
  | exact (d_sc_spec FK VK)
  | exact (d_bwait_spec FK VK)
  | exact (d_bgen_spec FK VK)
  | exact (d_synchronizes_spec FK VK)
  | exact (d_cwait_spec FK VK)
  | exact (d_cgen_spec FK VK)
  | exact (d_txops_spec FK VK)
  | exact (d_subscope_spec FK VK)
  | exact (d_start_spec FK VK)
  | exact (d_alias_spec FK VK)
  | exact (d_owner_spec FK VK)
  | exact (d_address_spec FK VK)
  | exact (d_acc_spec FK VK)
  | exact (d_paddr_spec FK VK)
  | exact (d_System_spec FK VK)
  | exact (d_aliases_spec FK VK)
  | exact (d_po_star_spec FK VK)
  | exact (d_thd_spec FK VK)
  | exact (d_same_alias_r_spec FK VK)
  | exact (d_same_location_r_spec FK VK)
  | exact (d_subscope_star_spec FK VK)
  | exact (d_cta_of_spec FK VK)
  | exact (d_same_cta_r_spec FK VK)
  | exact (d_cluster_of_spec FK VK)
  | exact (d_po_loc_spec FK VK)
  | exact (d_fr_spec FK VK)
  | exact (d_com_spec FK VK)
  | exact (d_Weak_spec FK VK)
  | exact (d_StrongW_spec FK VK)
  | exact (d_StrongR_spec FK VK)
  | exact (d_same_proxy_of_spec FK VK)
  | exact (d_same_proxy_spec FK VK)
  | exact (d_scope_incl0_spec FK VK)
  | exact (d_scope_incl_r_spec FK VK)
  | exact (d_same_acc_spec FK VK)
  | exact (d_footprint_spec FK VK)
  | exact (d_full_overlap_r_spec FK VK)
  | exact (d_overlap_ok_r_spec FK VK)
  | exact (d_ms_r_spec FK VK)
  | exact (d_FalseWaits_spec FK VK)
  | exact (d_RelFences_spec FK VK)
  | exact (d_AcqFences_spec FK VK)
  | exact (d_AcqReads_spec FK VK)
  | exact (d_rel_pattern_spec FK VK)
  | exact (d_acq_pattern_spec FK VK)
  | exact (d_obs_spec FK VK)
  | exact (d_sync_pattern_spec FK VK)
  | exact (d_cluster_sync_spec FK VK)
  | exact (d_sw_spec FK VK)
  | exact (d_RRel_spec FK VK)
  | exact (d_RAcq_spec FK VK)
  | exact (d_rleft0_spec FK VK)
  | exact (d_rleft_spec FK VK)
  | exact (d_rright0_spec FK VK)
  | exact (d_rright_spec FK VK)
  | exact (d_bco_plain_spec FK VK)
  | exact (d_sw_restricted_spec FK VK)
  | exact (d_cause_base_spec FK VK)
  | exact (d_GenericM_spec FK VK)
  | exact (d_AsyncW_spec FK VK)
  | exact (d_pf_space_ok_spec FK VK)
  | exact (d_pf_src0_spec FK VK)
  | exact (d_pf_dst0_spec FK VK)
  | exact (d_TmFence_spec FK VK)
  | exact (d_pf_src_spec FK VK)
  | exact (d_pf_dst_spec FK VK)
  | exact (d_ppbco_spec FK VK)
  | exact (d_cause_spec FK VK)
  | exact (d_AtomicR_spec FK VK)
  | exact (d_Atomics_spec FK VK)
  | exact (d_atomic_pair_r_spec FK VK)
  | exact (d_fpal_spec FK VK)
  | exact (d_unordered_spec FK VK)
  | exact (d_co_plus_spec FK VK)
  | exact (d_po_plus_spec FK VK)
  | exact (d_same_scope_spec FK VK)
  | exact (d_same_bid_spec FK VK)
  | exact (d_same_cluster_spec FK VK)
  | exact (d_CtaScope_spec FP VP)
  | exact (d_ClusterScope_spec FP VP)
  | exact (d_AsyncUnit_spec FP VP)
  | exact (d_Thread_spec FP VP)
  | exact (d_Acquire_spec FP VP)
  | exact (d_Read_spec FP VP)
  | exact (d_Release_spec FP VP)
  | exact (d_Write_spec FP VP)
  | exact (d_MemoryEvent_spec FP VP)
  | exact (d_FenceAcq_spec FP VP)
  | exact (d_FenceRel_spec FP VP)
  | exact (d_FenceSC_spec FP VP)
  | exact (d_FenceAcqRel_spec FP VP)
  | exact (d_Fence_spec FP VP)
  | exact (d_AliasFence_spec FP VP)
  | exact (d_PlainProxyFence_spec FP VP)
  | exact (d_BarrierArrive_spec FP VP)
  | exact (d_BarrierWait_spec FP VP)
  | exact (d_Barrier_spec FP VP)
  | exact (d_ClusterArrive_spec FP VP)
  | exact (d_ClusterWait_spec FP VP)
  | exact (d_Marker_spec FP VP)
  | exact (d_SyncRestrictCta_spec FP VP)
  | exact (d_SyncRestrictCluster_spec FP VP)
  | exact (d_OpRestrictInit_spec FP VP)
  | exact (d_ProxyFence_spec FP VP)
  | exact (d_ClusterArriveRelaxed_spec FP VP)
  | exact (d_MbarEv_spec FP VP)
  | exact (d_MbarInit_spec FP VP)
  | exact (d_MbarWait_spec FP VP)
  | exact (d_TxAnchor_spec FP VP)
  | exact (d_Mbar_spec FP VP)
  | exact (d_po_spec FP VP)
  | exact (d_issue_spec FP VP)
  | exact (d_done_spec FP VP)
  | exact (d_gdep_spec FP VP)
  | exact (d_rmw_spec FP VP)
  | exact (d_dep_spec FP VP)
  | exact (d_rf_spec FP VP)
  | exact (d_co_spec FP VP)
  | exact (d_sc_spec FP VP)
  | exact (d_bwait_spec FP VP)
  | exact (d_bgen_spec FP VP)
  | exact (d_synchronizes_spec FP VP)
  | exact (d_cwait_spec FP VP)
  | exact (d_cgen_spec FP VP)
  | exact (d_txops_spec FP VP)
  | exact (d_subscope_spec FP VP)
  | exact (d_start_spec FP VP)
  | exact (d_alias_spec FP VP)
  | exact (d_owner_spec FP VP)
  | exact (d_address_spec FP VP)
  | exact (d_acc_spec FP VP)
  | exact (d_paddr_spec FP VP)
  | exact (d_System_spec FP VP)
  | exact (d_aliases_spec FP VP)
  | exact (d_po_star_spec FP VP)
  | exact (d_thd_spec FP VP)
  | exact (d_same_alias_r_spec FP VP)
  | exact (d_same_location_r_spec FP VP)
  | exact (d_subscope_star_spec FP VP)
  | exact (d_cta_of_spec FP VP)
  | exact (d_same_cta_r_spec FP VP)
  | exact (d_cluster_of_spec FP VP)
  | exact (d_po_loc_spec FP VP)
  | exact (d_fr_spec FP VP)
  | exact (d_com_spec FP VP)
  | exact (d_Weak_spec FP VP)
  | exact (d_StrongW_spec FP VP)
  | exact (d_StrongR_spec FP VP)
  | exact (d_same_proxy_of_spec FP VP)
  | exact (d_same_proxy_spec FP VP)
  | exact (d_scope_incl0_spec FP VP)
  | exact (d_scope_incl_r_spec FP VP)
  | exact (d_same_acc_spec FP VP)
  | exact (d_footprint_spec FP VP)
  | exact (d_full_overlap_r_spec FP VP)
  | exact (d_overlap_ok_r_spec FP VP)
  | exact (d_ms_r_spec FP VP)
  | exact (d_FalseWaits_spec FP VP)
  | exact (d_RelFences_spec FP VP)
  | exact (d_AcqFences_spec FP VP)
  | exact (d_AcqReads_spec FP VP)
  | exact (d_rel_pattern_spec FP VP)
  | exact (d_acq_pattern_spec FP VP)
  | exact (d_obs_spec FP VP)
  | exact (d_sync_pattern_spec FP VP)
  | exact (d_cluster_sync_spec FP VP)
  | exact (d_sw_spec FP VP)
  | exact (d_RRel_spec FP VP)
  | exact (d_RAcq_spec FP VP)
  | exact (d_rleft0_spec FP VP)
  | exact (d_rleft_spec FP VP)
  | exact (d_rright0_spec FP VP)
  | exact (d_rright_spec FP VP)
  | exact (d_bco_plain_spec FP VP)
  | exact (d_sw_restricted_spec FP VP)
  | exact (d_cause_base_spec FP VP)
  | exact (d_GenericM_spec FP VP)
  | exact (d_AsyncW_spec FP VP)
  | exact (d_pf_space_ok_spec FP VP)
  | exact (d_pf_src0_spec FP VP)
  | exact (d_pf_dst0_spec FP VP)
  | exact (d_TmFence_spec FP VP)
  | exact (d_pf_src_spec FP VP)
  | exact (d_pf_dst_spec FP VP)
  | exact (d_ppbco_spec FP VP)
  | exact (d_cause_spec FP VP)
  | exact (d_AtomicR_spec FP VP)
  | exact (d_Atomics_spec FP VP)
  | exact (d_atomic_pair_r_spec FP VP)
  | exact (d_fpal_spec FP VP)
  | exact (d_unordered_spec FP VP)
  | exact (d_co_plus_spec FP VP)
  | exact (d_po_plus_spec FP VP)
  | exact (d_same_scope_spec FP VP)
  | exact (d_same_bid_spec FP VP)
  | exact (d_same_cluster_spec FP VP)].

Ltac mleaf := first [ apply l_collect_spec; mleaf | apply l_map_spec; mleaf | apply rspec_inter; mleaf
                    | apply rspec_seq; mleaf | apply rspec_diag; mleaf | apply sspec_compl; mleaf | apply v_set_triv
                    | leaf ].

Ltac lstep :=
  match goal with
  | |- bspec (_ && _) _ => apply bspec_and
  | |- bspec (_ || _) _ => apply bspec_or
  | |- bspec (negb _) _ => apply bspec_not
  | |- bspec (implb _ _) _ => apply bspec_imp
  | |- bspec (Bool.eqb _ _) _ => apply bspec_iff
  | |- bspec (forallb _ (List.seq 0 _)) _ => apply bspec_forallb; intro; cbv beta
  | |- bspec (existsb _ (List.seq 0 _)) _ => apply bspec_existsb; intro; cbv beta
  | |- bspec (forallb _ all_proxies) _ => apply bspec_foralll; [apply all_proxies_in | intro; cbv beta]
  | |- bspec (forallb _ all_spaces) _ => apply bspec_foralll; [apply all_spaces_in | intro; cbv beta]
  | |- bspec (Z.eqb _ _) _ => apply bspec_Zeq
  | |- bspec (oeqb _ _) _ => apply bspec_oeq
  | |- bspec (is_none _) _ => apply bspec_is_none
  | |- bspec (kind_eqb _ _) _ => apply kind_eqb_eq
  | |- bspec (skind_eqb _ _) _ => apply skind_eqb_eq
  | |- bspec (proxy_eqb _ _) _ => apply proxy_eqb_eq
  | |- bspec (space_eqb _ _) _ => apply space_eqb_eq
  | |- bspec (b_pre_is _ _ _) _ => eapply l_gen_pre; reflexivity
  | |- bspec (Nat.eqb (first_at _ _) _) _ => eapply l_gen_first; reflexivity
  | |- bspec (Nat.eqb (ev_at _ _) _) _ => eapply l_gen_ev; reflexivity
  | |- bspec (Nat.eqb _ _) _ => eapply gen_eq; reflexivity
  | |- bspec (mem1 _ _) _ => eapply gen_mem1; reflexivity
  | |- bspec (memp _ _ _) _ => first [eapply (@gen_memp FK VK); reflexivity | eapply (@gen_memp FP VP); reflexivity]
  | |- bspec (mems _ _ _) _ => first [eapply (@gen_mems FK VK); reflexivity | eapply (@gen_mems FP VP); reflexivity]
  | |- bspec (memd _ _ _ _) _ => first [eapply (@gen_memd FK VK); reflexivity | eapply (@gen_memd FP VP); reflexivity]
  | |- bspec (get _ _ _) _ => eapply gen_get; [leaf | reflexivity | reflexivity]
  | |- bspec (vget _ _) _ => eapply gen_vget; [leaf | reflexivity]
  | |- bspec (bsubset _ _ _ _) _ => apply bspec_subset; mleaf
  end.
Ltac lsolve := repeat lstep.

Ltac luse b H := eapply (@bspec_use b); [unfold b; cbv zeta; lsolve | exact H].
Ltac lback b p := let T := type of p in refine (@bspec_back b T _ p); unfold b; cbv zeta; lsolve.
Ltac luseZ b H := apply (proj2 (z_field_iff _ _ _ _ _)); luse b H.
Ltac luseO b H := apply (proj2 (o_field_iff _ _ _ _ _)); luse b H.
Ltac luseR b H := apply (proj2 (rb_field_iff _ _ _ _ _)); luse b H.
Ltac lbackZ b p := lback b (proj1 (z_field_iff _ _ _ _ _) p).
Ltac lbackO b p := lback b (proj1 (o_field_iff _ _ _ _ _) p).
Ltac lbackR b p := lback b (proj1 (rb_field_iff _ _ _ _ _) p).

Theorem b_bijections_spec : bspec b_bijections (bijections M).
Proof.
  split.
  - intros Hb; unfold b_bijections in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    apply andb_prop in Hb; destruct Hb as [H1 Hb].
    apply andb_prop in Hb; destruct Hb as [H2 Hb].
    apply andb_prop in Hb; destruct Hb as [H3 Hb].
    rename Hb into H4.
    constructor.
    + luse b_bij_ev H0.
    + luse b_bij_pre H1.
    + luse b_bij_onto H2.
    + luse b_bij_disjoint H3.
    + luse b_bij_relax_lone H4.
  - intros H; unfold b_bijections.
    apply andb_true_iff; split; [lback b_bij_ev (bij_ev H) |].
    apply andb_true_iff; split; [lback b_bij_pre (bij_pre H) |].
    apply andb_true_iff; split; [lback b_bij_onto (bij_onto H) |].
    apply andb_true_iff; split; [lback b_bij_disjoint (bij_disjoint H) |].
    lback b_bij_relax_lone (bij_relax_lone H).
Qed.

Theorem b_same_scope_tree_spec : bspec b_same_scope_tree (same_scope_tree P K).
Proof.
  split.
  - intros Hb; unfold b_same_scope_tree in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    rename Hb into H1.
    constructor.
    + luse b_st_skind H0.
    + luse b_st_subscope H1.
  - intros H; unfold b_same_scope_tree.
    apply andb_true_iff; split; [lback b_st_skind (st_skind H) |].
    lback b_st_subscope (st_subscope H).
Qed.

Theorem b_same_locations_spec : bspec b_same_locations (same_locations P K).
Proof.
  split.
  - intros Hb; unfold b_same_locations in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    apply andb_prop in Hb; destruct Hb as [H1 Hb].
    apply andb_prop in Hb; destruct Hb as [H2 Hb].
    apply andb_prop in Hb; destruct Hb as [H3 Hb].
    apply andb_prop in Hb; destruct Hb as [H4 Hb].
    apply andb_prop in Hb; destruct Hb as [H5 Hb].
    apply andb_prop in Hb; destruct Hb as [H6 Hb].
    apply andb_prop in Hb; destruct Hb as [H7 Hb].
    rename Hb into H8.
    constructor.
    + luse b_sl_alias H0.
    + luse b_sl_space H1.
    + luse b_sl_owner H2.
    + luse b_sl_init H3.
    + luse b_sl_Mbar H4.
    + luse b_sl_iph H5.
    + luse b_sl_ipend H6.
    + luse b_sl_iexp H7.
    + luse b_sl_itx H8.
  - intros H; unfold b_same_locations.
    apply andb_true_iff; split; [lback b_sl_alias (sl_alias H) |].
    apply andb_true_iff; split; [lback b_sl_space (sl_space H) |].
    apply andb_true_iff; split; [lback b_sl_owner (sl_owner H) |].
    apply andb_true_iff; split; [lback b_sl_init (sl_init H) |].
    apply andb_true_iff; split; [lback b_sl_Mbar (sl_Mbar H) |].
    apply andb_true_iff; split; [lback b_sl_iph (sl_iph H) |].
    apply andb_true_iff; split; [lback b_sl_ipend (sl_ipend H) |].
    apply andb_true_iff; split; [lback b_sl_iexp (sl_iexp H) |].
    lback b_sl_itx (sl_itx H).
Qed.

Theorem b_same_order_spec : bspec b_same_order (same_order P K M).
Proof.
  split.
  - intros Hb; unfold b_same_order in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    apply andb_prop in Hb; destruct Hb as [H1 Hb].
    rename Hb into H2.
    constructor.
    + luse b_so_po H0.
    + luse b_so_start H1.
    + luse b_so_pre_scope H2.
  - intros H; unfold b_same_order.
    apply andb_true_iff; split; [lback b_so_po (so_po H) |].
    apply andb_true_iff; split; [lback b_so_start (so_start H) |].
    lback b_so_pre_scope (so_pre_scope H).
Qed.

Theorem b_kinds_spec : bspec b_kinds (kinds P K M X).
Proof.
  split.
  - intros Hb; unfold b_kinds in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    apply andb_prop in Hb; destruct Hb as [H1 Hb].
    apply andb_prop in Hb; destruct Hb as [H2 Hb].
    apply andb_prop in Hb; destruct Hb as [H3 Hb].
    apply andb_prop in Hb; destruct Hb as [H4 Hb].
    apply andb_prop in Hb; destruct Hb as [H5 Hb].
    apply andb_prop in Hb; destruct Hb as [H6 Hb].
    apply andb_prop in Hb; destruct Hb as [H7 Hb].
    apply andb_prop in Hb; destruct Hb as [H8 Hb].
    rename Hb into H9.
    constructor.
    + luse b_kd_kind H0.
    + luse b_kd_SyncRestrictCta H1.
    + luse b_kd_SyncRestrictCluster H2.
    + luse b_kd_OpRestrictInit H3.
    + luse b_kd_ClusterArriveRelaxed H4.
    + luse b_kd_MbarInit H5.
    + luse b_kd_MbarWait H6.
    + luse b_kd_TxAnchor H7.
    + luse b_kd_ProxyFence H8.
    + luse b_kd_pre H9.
  - intros H; unfold b_kinds.
    apply andb_true_iff; split; [lback b_kd_kind (kd_kind H) |].
    apply andb_true_iff; split; [lback b_kd_SyncRestrictCta (kd_SyncRestrictCta H) |].
    apply andb_true_iff; split; [lback b_kd_SyncRestrictCluster (kd_SyncRestrictCluster H) |].
    apply andb_true_iff; split; [lback b_kd_OpRestrictInit (kd_OpRestrictInit H) |].
    apply andb_true_iff; split; [lback b_kd_ClusterArriveRelaxed (kd_ClusterArriveRelaxed H) |].
    apply andb_true_iff; split; [lback b_kd_MbarInit (kd_MbarInit H) |].
    apply andb_true_iff; split; [lback b_kd_MbarWait (kd_MbarWait H) |].
    apply andb_true_iff; split; [lback b_kd_TxAnchor (kd_TxAnchor H) |].
    apply andb_true_iff; split; [lback b_kd_ProxyFence (kd_ProxyFence H) |].
    lback b_kd_pre (kd_pre H).
Qed.

Theorem b_same_relations_spec : bspec b_same_relations (same_relations P K M X D).
Proof.
  split.
  - intros Hb; unfold b_same_relations in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    apply andb_prop in Hb; destruct Hb as [H1 Hb].
    apply andb_prop in Hb; destruct Hb as [H2 Hb].
    apply andb_prop in Hb; destruct Hb as [H3 Hb].
    apply andb_prop in Hb; destruct Hb as [H4 Hb].
    apply andb_prop in Hb; destruct Hb as [H5 Hb].
    apply andb_prop in Hb; destruct Hb as [H6 Hb].
    apply andb_prop in Hb; destruct Hb as [H7 Hb].
    apply andb_prop in Hb; destruct Hb as [H8 Hb].
    apply andb_prop in Hb; destruct Hb as [H9 Hb].
    apply andb_prop in Hb; destruct Hb as [H10 Hb].
    apply andb_prop in Hb; destruct Hb as [H11 Hb].
    apply andb_prop in Hb; destruct Hb as [H12 Hb].
    apply andb_prop in Hb; destruct Hb as [H13 Hb].
    rename Hb into H14.
    constructor.
    + luse b_sr_address H0.
    + luse b_sr_acc H1.
    + luse b_sr_rmw H2.
    + luse b_sr_dep H3.
    + luse b_sr_issue H4.
    + luse b_sr_done H5.
    + luse b_sr_gdep H6.
    + luseZ b_sr_bid H7.
    + luseO b_sr_bcount H8.
    + luse b_sr_bwait H9.
    + luse b_sr_cwait H10.
    + luseO b_sr_wpar H11.
    + luseO b_sr_wtok H12.
    + luse b_sr_txops H13.
    + luse b_sr_proxy_fence H14.
  - intros H; unfold b_same_relations.
    apply andb_true_iff; split; [lback b_sr_address (sr_address H) |].
    apply andb_true_iff; split; [lback b_sr_acc (sr_acc H) |].
    apply andb_true_iff; split; [lback b_sr_rmw (sr_rmw H) |].
    apply andb_true_iff; split; [lback b_sr_dep (sr_dep H) |].
    apply andb_true_iff; split; [lback b_sr_issue (sr_issue H) |].
    apply andb_true_iff; split; [lback b_sr_done (sr_done H) |].
    apply andb_true_iff; split; [lback b_sr_gdep (sr_gdep H) |].
    apply andb_true_iff; split; [lbackZ b_sr_bid (sr_bid H) |].
    apply andb_true_iff; split; [lbackO b_sr_bcount (sr_bcount H) |].
    apply andb_true_iff; split; [lback b_sr_bwait (sr_bwait H) |].
    apply andb_true_iff; split; [lback b_sr_cwait (sr_cwait H) |].
    apply andb_true_iff; split; [lbackO b_sr_wpar (sr_wpar H) |].
    apply andb_true_iff; split; [lbackO b_sr_wtok (sr_wtok H) |].
    apply andb_true_iff; split; [lback b_sr_txops (sr_txops H) |].
    lback b_sr_proxy_fence (sr_proxy_fence H).
Qed.

Theorem b_proxies_spec : bspec b_proxies (proxies P K M).
Proof.
  split.
  - intros Hb; unfold b_proxies in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    rename Hb into H1.
    constructor.
    + luse b_px_same H0.
    + luse b_px_relax H1.
  - intros H; unfold b_proxies.
    apply andb_true_iff; split; [lback b_px_same (px_same H) |].
    lback b_px_relax (px_relax H).
Qed.

Theorem b_scopes_spec : bspec b_scopes (scopes P K M X).
Proof.
  split.
  - intros Hb; unfold b_scopes in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    apply andb_prop in Hb; destruct Hb as [H1 Hb].
    rename Hb into H2.
    constructor.
    + luse b_sc_same H0.
    + luse b_sc_widen H1.
    + luse b_sc_rmw H2.
  - intros H; unfold b_scopes.
    apply andb_true_iff; split; [lback b_sc_same (sc_same H) |].
    apply andb_true_iff; split; [lback b_sc_widen (sc_widen H) |].
    lback b_sc_rmw (sc_rmw H).
Qed.

Theorem b_read_back_spec : bspec b_read_back (read_back P K M).
Proof.
  split.
  - intros Hb; unfold b_read_back in Hb.
    apply andb_prop in Hb; destruct Hb as [H0 Hb].
    apply andb_prop in Hb; destruct Hb as [H1 Hb].
    apply andb_prop in Hb; destruct Hb as [H2 Hb].
    apply andb_prop in Hb; destruct Hb as [H3 Hb].
    apply andb_prop in Hb; destruct Hb as [H4 Hb].
    apply andb_prop in Hb; destruct Hb as [H5 Hb].
    apply andb_prop in Hb; destruct Hb as [H6 Hb].
    apply andb_prop in Hb; destruct Hb as [H7 Hb].
    apply andb_prop in Hb; destruct Hb as [H8 Hb].
    apply andb_prop in Hb; destruct Hb as [H9 Hb].
    rename Hb into H10.
    constructor.
    + luse b_rb_rf H0.
    + luse b_rb_co H1.
    + luse b_rb_sc H2.
    + luse b_rb_bgen H3.
    + luse b_rb_cgen H4.
    + luse b_rb_synchronizes H5.
    + luseR b_rb_val H6.
    + luseR b_rb_ph H7.
    + luseR b_rb_pend H8.
    + luseR b_rb_expc H9.
    + luseR b_rb_tx H10.
  - intros H; unfold b_read_back.
    apply andb_true_iff; split; [lback b_rb_rf (rb_rf H) |].
    apply andb_true_iff; split; [lback b_rb_co (rb_co H) |].
    apply andb_true_iff; split; [lback b_rb_sc (rb_sc H) |].
    apply andb_true_iff; split; [lback b_rb_bgen (rb_bgen H) |].
    apply andb_true_iff; split; [lback b_rb_cgen (rb_cgen H) |].
    apply andb_true_iff; split; [lback b_rb_synchronizes (rb_synchronizes H) |].
    apply andb_true_iff; split; [lbackR b_rb_val (rb_val H) |].
    apply andb_true_iff; split; [lbackR b_rb_ph (rb_ph H) |].
    apply andb_true_iff; split; [lbackR b_rb_pend (rb_pend H) |].
    apply andb_true_iff; split; [lbackR b_rb_expc (rb_expc H) |].
    lbackR b_rb_tx (rb_tx H).
Qed.

Theorem b_inserted_spec : bspec b_inserted (inserted P M).
Proof. unfold b_inserted, inserted; cbv zeta; lsolve. Qed.

Theorem b_lowering_ex_spec : bspec b_lowering_ex (lowering_ex P K M X D).
Proof.
  unfold b_lowering_ex, lowering_ex.
  apply bspec_and; [apply b_bijections_spec |]; apply bspec_and; [apply b_same_scope_tree_spec |].
  apply bspec_and; [apply b_same_locations_spec |]; apply bspec_and; [apply b_same_order_spec |].
  apply bspec_and; [apply b_kinds_spec |]; apply bspec_and; [apply b_same_relations_spec |].
  apply bspec_and; [apply b_proxies_spec |]; apply bspec_and; [apply b_scopes_spec |].
  apply bspec_and; [apply b_inserted_spec | apply b_read_back_spec].
Qed.

End Fields.
