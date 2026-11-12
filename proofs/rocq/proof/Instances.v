(** * Concrete executions, checked by computation

    Tools to state facts of the model about concrete finite executions and prove them by computation with the
    checkers of [check/], and three examples of the lowering: the hypothesis [lowering P K M] of the statements
    holds of real executions (the identity lowering, a scope widened to [.sys], a [fence.sc.sys] inserted before
    an acquire-release read-modify-write). *)

From Stdlib Require Import Arith Bool List ZArith Lia.
From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87 Kamui Lowering.
From KamuiProof.lib Require Import Mat.
From KamuiProof.check Require Import FExec Check CheckLowering.
Require Import KamuiProof.Theorem.
Import ListNotations.

Set Implicit Arguments.

(** [lowering_ex] only depends on its two sets through their elements. *)
Lemma lowering_ex_ext {EP EK S A C} (P : Exec EP S A C) (K : Exec EK S A C) (M : Map EP EK) x x' d d' :
  (forall e, x e <-> x' e) -> (forall e, d e <-> d' e) -> lowering_ex P K M x d -> lowering_ex P K M x' d'.
Proof.
  intros Hx Hd [B [T [Lc [O [Kd [R [Px [Sc [I Rb]]]]]]]]].
  assert (N : forall e, ~ x' e -> ~ x e) by (intros e H1 H2; apply H1, Hx, H2).
  split; [exact B |]; split; [exact T |]; split; [exact Lc |]; split; [exact O |].
  split.
  { destruct Kd as [k1 k2 k3 k4 k5 k6 k7 k8 k9 k10]; constructor; intros; eauto. }
  split.
  { destruct R as [r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 r13 r14 r15 r16]; constructor; auto.
    - assert (E : set_compl d ≡₁ set_compl d') by (split; intros e He H; apply He, Hd, H).
      rewrite r6, E; reflexivity. }
  split; [exact Px |]; split.
  { destruct Sc as [s1 s2 s3]; constructor; intros; eauto. }
  split; [exact I | exact Rb].
Qed.

(** ** From computations to facts *)

Lemma lowering_by_computation FP FK0 FM VP VK VM :
  b_lowering_ex FP FK0 FM [] [] = true -> m_relax FM = [] ->
  lowering (denote FP VP) (denote (align FK0 FP) VK) (@dmap (ne FP) (ne FK0) FM VM).
Proof.
  intros H R; split.
  - eapply lowering_ex_ext; [| | exact (proj1 (b_lowering_ex_spec FP FK0 FM [] [] VP VK VM) H)].
    all: intros e; simpl; split; [discriminate | intros []].
  - intros e; simpl; rewrite R; unfold mem1; simpl; discriminate.
Qed.

Lemma wf_prog_by_computation F V : b_wf_prog F = true -> wf_prog (denote F V).
Proof. apply (b_wf_prog_spec F V). Qed.
Lemma wf_by_computation F V : b_wf_prog F && b_wf_exec F = true -> wf (denote F V).
Proof. intros H; apply andb_true_iff in H; split; [apply (b_wf_prog_spec F V) | apply (b_wf_exec_spec F V)]; apply H. Qed.
Lemma consistent_by_computation F V : b_consistent F = true -> consistent (denote F V).
Proof. apply (b_consistent_spec F V). Qed.
Lemma inconsistent_by_computation F V : b_consistent F = false -> ~ consistent (denote F V).
Proof. intros H C; apply (b_consistent_spec F V) in C; congruence. Qed.

(** ** Examples of the lowering *)

(** Message passing: a relaxed store of [x] and a release store of [y] at [.gpu] in one thread; an acquire load
    of [y] and a relaxed load of [x] at [.gpu] in another; both loads read 1. Scopes: 0 the system, 1 a GPU, 2 and
    3 two CTAs, 4 and 5 the two threads. Events: 0 st x, 1 st.release y, 2 ld.acquire y, 3 ld x. *)
Definition mp : FExec := {|
  ne := 4; ns := 6; na := 2; nc := 0;
  f_skind := [SNode; SNode; SCta; SCta; SThread; SThread]; f_subscope := [(0, 1); (1, 2); (1, 3); (2, 4); (3, 5)];
  f_start := [(4, 0); (5, 2)]; f_alias := []; f_space := [SGlobal; SGlobal]; f_owner := []; f_init := [0; 0]%Z;
  f_kind := [KWrite; KRelease; KAcquire; KRead]; f_po := [(0, 1); (2, 3)]; f_scope := [1; 1; 1; 1];
  f_issue := []; f_done := []; f_gdep := []; f_address := [(0, 0); (1, 1); (2, 1); (3, 0)];
  f_proxy := [(0, Generic); (1, Generic); (2, Generic); (3, Generic)]; f_val := [1; 1; 1; 1]%Z; f_acc := []; f_vacc := [];
  f_rmw := []; f_dep := []; f_rf := [(1, 2); (0, 3)]; f_co := []; f_sc := [];
  f_SyncRestrictCta := []; f_SyncRestrictCluster := []; f_OpRestrictInit := []; f_ProxyFence := []; f_dirs := [];
  f_pspace := []; f_paddr := []; f_bid := []; f_bcount := []; f_bwait := []; f_bgen := []; f_synchronizes := [];
  f_cwait := []; f_cgen := []; f_ClusterArriveRelaxed := []; f_Mbar := []; f_iph := []; f_ipend := []; f_iexp := [];
  f_itx := []; f_MbarEv := []; f_ph := []; f_pend := []; f_expc := []; f_tx := []; f_MbarInit := []; f_MbarWait := [];
  f_wpar := []; f_wtok := []; f_TxAnchor := []; f_txops := [] |}.

(** The same program with the release store and the acquire load at [.sys], as the standard instructions are. *)
Definition mp_sys : FExec := {|
  ne := 4; ns := 6; na := 2; nc := 0;
  f_skind := [SNode; SNode; SCta; SCta; SThread; SThread]; f_subscope := [(0, 1); (1, 2); (1, 3); (2, 4); (3, 5)];
  f_start := [(4, 0); (5, 2)]; f_alias := []; f_space := [SGlobal; SGlobal]; f_owner := []; f_init := [0; 0]%Z;
  f_kind := [KWrite; KRelease; KAcquire; KRead]; f_po := [(0, 1); (2, 3)]; f_scope := [1; 0; 0; 1];
  f_issue := []; f_done := []; f_gdep := []; f_address := [(0, 0); (1, 1); (2, 1); (3, 0)];
  f_proxy := [(0, Generic); (1, Generic); (2, Generic); (3, Generic)]; f_val := [1; 1; 1; 1]%Z; f_acc := []; f_vacc := [];
  f_rmw := []; f_dep := []; f_rf := [(1, 2); (0, 3)]; f_co := []; f_sc := [];
  f_SyncRestrictCta := []; f_SyncRestrictCluster := []; f_OpRestrictInit := []; f_ProxyFence := []; f_dirs := [];
  f_pspace := []; f_paddr := []; f_bid := []; f_bcount := []; f_bwait := []; f_bgen := []; f_synchronizes := [];
  f_cwait := []; f_cgen := []; f_ClusterArriveRelaxed := []; f_Mbar := []; f_iph := []; f_ipend := []; f_iexp := [];
  f_itx := []; f_MbarEv := []; f_ph := []; f_pend := []; f_expc := []; f_tx := []; f_MbarInit := []; f_MbarWait := [];
  f_wpar := []; f_wtok := []; f_TxAnchor := []; f_txops := [] |}.

Definition map_id4 : FMap := {| m_ev := [0; 1; 2; 3]; m_pre := []; m_widen := []; m_relax := [] |}.
Definition map_wide : FMap := {| m_ev := [0; 1; 2; 3]; m_pre := []; m_widen := [1; 2]; m_relax := [] |}.

(** An acquire-release fetch-and-add at [.gpu] (events 0, the read, and 1, the write) in one thread; scopes:
    0 the system, 1 a GPU, 2 a CTA, 3 the thread. In Kamui a [fence.sc.sys] (event 0) comes first. *)
Definition aqrl : FExec := {|
  ne := 2; ns := 4; na := 1; nc := 0;
  f_skind := [SNode; SNode; SCta; SThread]; f_subscope := [(0, 1); (1, 2); (2, 3)]; f_start := [(3, 0)];
  f_alias := []; f_space := [SGlobal]; f_owner := []; f_init := [0]%Z;
  f_kind := [KAcquire; KRelease]; f_po := [(0, 1)]; f_scope := [1; 1];
  f_issue := []; f_done := []; f_gdep := []; f_address := [(0, 0); (1, 0)];
  f_proxy := [(0, Generic); (1, Generic)]; f_val := [0; 1]%Z; f_acc := []; f_vacc := [];
  f_rmw := [(0, 1)]; f_dep := [(0, 1)]; f_rf := []; f_co := []; f_sc := [];
  f_SyncRestrictCta := []; f_SyncRestrictCluster := []; f_OpRestrictInit := []; f_ProxyFence := []; f_dirs := [];
  f_pspace := []; f_paddr := []; f_bid := []; f_bcount := []; f_bwait := []; f_bgen := []; f_synchronizes := [];
  f_cwait := []; f_cgen := []; f_ClusterArriveRelaxed := []; f_Mbar := []; f_iph := []; f_ipend := []; f_iexp := [];
  f_itx := []; f_MbarEv := []; f_ph := []; f_pend := []; f_expc := []; f_tx := []; f_MbarInit := []; f_MbarWait := [];
  f_wpar := []; f_wtok := []; f_TxAnchor := []; f_txops := [] |}.

Definition aqrl_kamui : FExec := {|
  ne := 3; ns := 4; na := 1; nc := 0;
  f_skind := [SNode; SNode; SCta; SThread]; f_subscope := [(0, 1); (1, 2); (2, 3)]; f_start := [(3, 0)];
  f_alias := []; f_space := [SGlobal]; f_owner := []; f_init := [0]%Z;
  f_kind := [KFenceSC; KAcquire; KRelease]; f_po := [(0, 1); (1, 2)]; f_scope := [0; 1; 1];
  f_issue := []; f_done := []; f_gdep := []; f_address := [(1, 0); (2, 0)];
  f_proxy := [(1, Generic); (2, Generic)]; f_val := [0; 0; 1]%Z; f_acc := []; f_vacc := [];
  f_rmw := [(1, 2)]; f_dep := [(1, 2)]; f_rf := []; f_co := []; f_sc := [];
  f_SyncRestrictCta := []; f_SyncRestrictCluster := []; f_OpRestrictInit := []; f_ProxyFence := []; f_dirs := [];
  f_pspace := []; f_paddr := []; f_bid := []; f_bcount := []; f_bwait := []; f_bgen := []; f_synchronizes := [];
  f_cwait := []; f_cgen := []; f_ClusterArriveRelaxed := []; f_Mbar := []; f_iph := []; f_ipend := []; f_iexp := [];
  f_itx := []; f_MbarEv := []; f_ph := []; f_pend := []; f_expc := []; f_tx := []; f_MbarInit := []; f_MbarWait := [];
  f_wpar := []; f_wtok := []; f_TxAnchor := []; f_txops := [] |}.

Definition map_aqrl : FMap := {| m_ev := [1; 2]; m_pre := [Some 0; None]; m_widen := []; m_relax := [] |}.

(** Each example: both executions well-formed and consistent, and related by the lowering. *)
Definition example (FP FK : FExec) (FM : FMap) VP VK VM : Prop :=
  wf (denote FP VP) /\ kamui_wf (denote (align FK FP) VK) /\ consistent (denote FP VP)
  /\ kamui_consistent (denote (align FK FP) VK) /\ lowering (denote FP VP) (denote (align FK FP) VK) (@dmap (ne FP) (ne FK) FM VM).

Ltac by_computation :=
  split; [apply wf_by_computation; vm_compute; reflexivity |];
  split; [apply wf_by_computation; vm_compute; reflexivity |];
  split; [apply consistent_by_computation; vm_compute; reflexivity |];
  split; [apply consistent_by_computation; vm_compute; reflexivity |];
  apply lowering_by_computation; vm_compute; reflexivity.

Example lowering_identity : example mp mp map_id4 eq_refl eq_refl eq_refl.
Proof. by_computation. Qed.

Example lowering_widened : example mp mp_sys map_wide eq_refl eq_refl eq_refl.
Proof. by_computation. Qed.

Example lowering_inserted_fence : example aqrl aqrl_kamui map_aqrl eq_refl eq_refl eq_refl.
Proof. by_computation. Qed.

(** ** Counterexamples: what a broken lowering must give *)

(** A broken lowering fails the statement if it relates a well-formed PTX program to a well-formed Kamui
    execution that satisfies the Kamui model while the PTX execution read back does not satisfy the PTX model. *)
Lemma broken_by_computation (Lw : LoweringRel) FP FK0 FM VP VK VM :
  b_wf_prog FP = true -> b_wf_prog (align FK0 FP) && b_wf_exec (align FK0 FP) = true ->
  b_consistent (align FK0 FP) = true -> b_consistent FP = false ->
  Lw _ _ _ _ _ (denote FP VP) (denote (align FK0 FP) VK) (@dmap (ne FP) (ne FK0) FM VM) ->
  ~ correct_for Lw.
Proof.
  intros WP WK CK CP HL H.
  destruct (H _ _ _ _ _ _ _ _ (@wf_prog_by_computation FP VP WP) HL (@wf_by_computation _ VK WK)) as [_ [Hc _]].
  exact (@inconsistent_by_computation FP VP CP (Hc (@consistent_by_computation _ VK CK))).
Qed.

(** One-way checks of the conditions a broken lowering puts on the PTX program (its feature group). *)
Lemma h_no_set {n} v (Q : Fin n -> Prop) :
  sspec v Q -> forallb (fun i => negb (vget v i)) (List.seq 0 n) = true -> forall x, ~ Q x.
Proof.
  intros H B x Hx; rewrite forallb_forall in B.
  specialize (B (fin_val x) (proj2 (in_seq _ _ _) (conj (Nat.le_0_l _) (fin_lt x)))).
  apply H in Hx; rewrite Hx in B; discriminate.
Qed.

Lemma h_no_rel {n} m (R : relation (Fin n)) : rspec m R -> bnone n n m = true -> R ≡ ∅₂.
Proof. intros H B; split; [| basic_solver]; intros x y Hr; exact (proj1 (bspec_none H) B x y Hr). Qed.

Lemma h_proxies_in F V (ps : Proxy -> Prop) (psb : Proxy -> bool) : (forall p, psb p = true -> ps p) ->
  forallb (fun e => forallb (fun p => implb (memp (f_proxy F) e p) (psb p)) all_proxies) (List.seq 0 (ne F)) = true ->
  proxies_in (denote F V) ps.
Proof.
  intros Hp B e p Hpr; apply Hp; rewrite forallb_forall in B.
  specialize (B (fin_val e) (proj2 (in_seq _ _ _) (conj (Nat.le_0_l _) (fin_lt e)))).
  rewrite forallb_forall in B; specialize (B p (all_proxies_in p)).
  simpl in Hpr; rewrite Hpr in B; exact B.
Qed.

(** ** Facts about concrete executions, by computation

    [psolve leaf] proves [bspec ?b Q] for a proposition [Q] about concrete executions and builds the boolean [?b]
    from the shape of [Q]: [forall] and [exists] over a carrier become [forallb] and [existsb], the connectives
    become boolean ones, and each atom ([R x y], [Q x], [x = y]) becomes an entry of the matrix that a checker
    computes for it ([leaf] finds the checker's specification). [by_bool leaf] then proves [Q] by computing
    [?b]. *)

Lemma bf_forall {n} (p : nat -> bool) (P : Fin n -> Prop) :
  (forall i (x : Fin n), fin_val x = i -> bspec (p i) (P x)) -> bspec (forallb p (List.seq 0 n)) (forall x, P x).
Proof. intros H; apply bspec_forallb; intros x; apply (H _ x eq_refl). Qed.
Lemma bf_exists {n} (p : nat -> bool) (P : Fin n -> Prop) :
  (forall i (x : Fin n), fin_val x = i -> bspec (p i) (P x)) -> bspec (existsb p (List.seq 0 n)) (exists x, P x).
Proof. intros H; apply bspec_existsb; intros x; apply (H _ x eq_refl). Qed.
Lemma bf_forall_proxy (p : Proxy -> bool) (P : Proxy -> Prop) :
  (forall q, bspec (p q) (P q)) -> bspec (forallb p all_proxies) (forall q, P q).
Proof. intros H; apply bspec_foralll; [apply all_proxies_in | exact H]. Qed.
Lemma bspec_false' : bspec false False. Proof. unfold bspec; split; [discriminate | intros []]. Qed.

Lemma gen_pre_none nP nK FM (VM : mvalid nP nK FM = true) x i : fin_val x = i ->
  bspec (match pre_at FM i with Some f => negb (Nat.ltb f nK) | None => true end) (pre (@dmap nP nK FM VM) x = None).
Proof.
  intros <-; unfold bspec; simpl; destruct (pre_at FM (fin_val x)) as [f |] eqn:E; [| split; reflexivity].
  unfold fin_of; destruct (lt_dec f nK) as [H | H].
  - rewrite (proj2 (Nat.ltb_lt f nK) H); split; discriminate.
  - rewrite (proj2 (Nat.ltb_nlt f nK) H); split; reflexivity.
Qed.

Ltac solve_val := first [match goal with H : fin_val _ = _ |- _ => exact H end | reflexivity].

Ltac pstep leaf :=
  cbv beta;
  match goal with
  | |- bspec _ (forall x : Fin _, _) => refine (bf_forall (fun i => _) _ _); intros ? ? ?
  | |- bspec _ (forall q : Proxy, _) => refine (bf_forall_proxy (fun q => _) _ _); intros ?
  | |- bspec _ (exists x : Fin _, _) => refine (bf_exists (fun i => _) _ _); intros ? ? ?
  | |- bspec _ (_ /\ _) => refine (bspec_and _ _)
  | |- bspec _ (_ \/ _) => refine (bspec_or _ _)
  | |- bspec _ (~ _) => refine (bspec_not _)
  | |- bspec _ (_ <-> _) => refine (bspec_iff _ _)
  | |- bspec _ (_ -> _) => refine (bspec_imp _ _)
  | |- bspec _ True => exact bspec_true
  | |- bspec _ False => exact bspec_false'
  | |- bspec _ (same_relation _ _) => unfold same_relation
  | |- bspec _ (inclusion _ _) => unfold inclusion
  | |- bspec _ (set_union _ _ _) => unfold set_union
  | |- bspec _ (set_inter _ _ _) => unfold set_inter
  | |- bspec _ (set_minus _ _ _) => unfold set_minus
  | |- bspec _ (@eq (Fin _) _ _) => eapply gen_eq; solve_val
  | |- bspec _ (@eq Kind _ _) => apply kind_eqb_eq
  | |- bspec _ (@eq Proxy _ _) => apply proxy_eqb_eq
  | |- bspec _ (@eq bool (mem1 _ _) true) => eapply gen_mem1; solve_val
  | |- bspec _ (widen (dmap _ _ _ _) _) => cbn [widen dmap]
  | |- bspec _ (relax (dmap _ _ _ _) _) => cbn [relax dmap]
  | |- bspec _ (@eq (option _) (pre _ _) None) => eapply gen_pre_none; solve_val
  | |- bspec _ (proxy _ _ _) => eapply gen_memp; solve_val
  | |- bspec _ (dirs _ _ _ _) => eapply gen_memd; solve_val
  | |- bspec _ _ => first [eapply gen_get; [leaf | solve_val | solve_val] | eapply gen_vget; [leaf | solve_val]]
  end.

Ltac psolve leaf := repeat (pstep leaf).
Ltac by_bool leaf := eapply bspec_use; [solve [psolve leaf] | vm_compute; reflexivity].

(** [x] is the only element of [mem1 [fin_val x]]. *)
Lemma set1_mem {n} (a e : Fin n) : mem1 [fin_val a] (fin_val e) = true <-> set1 a e.
Proof.
  unfold mem1, set1; simpl; rewrite orb_false_r, Nat.eqb_eq; split; [intros E; apply fin_eq; auto | intros ->; reflexivity].
Qed.
Lemma none_mem {n} (e : Fin n) : mem1 [] (fin_val e) = true <-> (∅ : Fin n -> Prop) e.
Proof. simpl; split; [discriminate | intros []]. Qed.
