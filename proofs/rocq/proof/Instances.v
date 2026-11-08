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
  { destruct R as [r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 r13 r14 r15]; constructor; auto.
    - assert (E : set_compl d ≡₁ set_compl d') by (split; intros e He H; apply He, Hd, H).
      rewrite r5, E; reflexivity. }
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
  f_proxy := [(0, Generic); (1, Generic); (2, Generic); (3, Generic)]; f_val := [1; 1; 1; 1]%Z; f_acc := [];
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
  f_proxy := [(0, Generic); (1, Generic); (2, Generic); (3, Generic)]; f_val := [1; 1; 1; 1]%Z; f_acc := [];
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
  f_proxy := [(0, Generic); (1, Generic)]; f_val := [0; 1]%Z; f_acc := [];
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
  f_proxy := [(1, Generic); (2, Generic)]; f_val := [0; 0; 1]%Z; f_acc := [];
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
