(** * Checkers of the PTX 8.7 model on finite executions

    For each definition of [Ptx87.v], a function that computes it on an [FExec] as a boolean, a vector or a
    matrix ([d_...] and [b_...]), and a proof that it computes exactly that definition on [denote F]
    ([..._spec]). The checkers are extracted to OCaml ([Extract.v]) and run on the executions Alloy finds, to
    test that [Ptx87.v] says what [ptx87.als] says. *)

From Stdlib Require Import Arith Bool List ZArith Lia.
From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87.
From KamuiProof.lib Require Import Mat.
From KamuiProof.check Require Import FExec.
Import ListNotations.

Set Implicit Arguments.

(** ** Boolean specifications of atoms *)

Lemma bspec_imp b c P Q : bspec b P -> bspec c Q -> bspec (implb b c) (P -> Q).
Proof. unfold bspec; intros Hb Hc; rewrite implb_true_iff, Hb, Hc; reflexivity. Qed.

Lemma bspec_iff b c P Q : bspec b P -> bspec c Q -> bspec (Bool.eqb b c) (P <-> Q).
Proof.
  unfold bspec; intros Hb Hc; rewrite eqb_true_iff; split.
  - intros E; rewrite <- Hb, <- Hc, E; reflexivity.
  - intros E; destruct b, c; try reflexivity; exfalso.
    + assert (true = true) as T by reflexivity; apply Hb, E, Hc in T; discriminate.
    + assert (true = true) as T by reflexivity; apply Hc, E, Hb in T; discriminate.
Qed.

Lemma bspec_Zeq a b : bspec (Z.eqb a b) (a = b).
Proof. apply Z.eqb_eq. Qed.
Lemma bspec_Zlt a b : bspec (Z.ltb a b) (a < b)%Z.
Proof. apply Z.ltb_lt. Qed.
Lemma bspec_Zgt a b : bspec (Z.gtb a b) (a > b)%Z.
Proof. unfold bspec; rewrite Z.gtb_ltb, Z.ltb_lt; lia. Qed.

Lemma bspec_fin_eq {m} (x y : Fin m) : bspec (Nat.eqb (fin_val x) (fin_val y)) (x = y).
Proof. unfold bspec; rewrite Nat.eqb_eq, fin_eq_iff; reflexivity. Qed.

Lemma bspec_get {n m} M (R : Fin n -> Fin m -> Prop) x y :
  rspec M R -> bspec (get M (fin_val x) (fin_val y)) (R x y).
Proof. intros H; apply H. Qed.

Lemma bspec_vget {n} v (P : Fin n -> Prop) x : sspec v P -> bspec (vget v (fin_val x)) (P x).
Proof. intros H; apply H. Qed.

Lemma bspec_existsl {T} (l : list T) p (P : T -> Prop) :
  (forall x, In x l) -> (forall x, bspec (p x) (P x)) -> bspec (existsb p l) (exists x, P x).
Proof. intros Hl H; apply existsb_list; [exact Hl | exact H]. Qed.

Lemma bspec_foralll {T} (l : list T) p (P : T -> Prop) :
  (forall x, In x l) -> (forall x, bspec (p x) (P x)) -> bspec (forallb p l) (forall x, P x).
Proof. intros Hl H; apply forallb_list; [exact Hl | exact H]. Qed.

(** ** The computations *)

Section Compute.
Context (F : FExec).

Local Abbreviation n := (ne F).
Local Abbreviation nS := (ns F).
Local Abbreviation nA := (na F).
Local Abbreviation nC := (nc F).

Definition kind_at (i : nat) : Kind := nth i (f_kind F) KMarker.
Definition skind_at (i : nat) : ScopeKind := nth i (f_skind F) SNode.
Definition scope_at (i : nat) : nat := nth i (f_scope F) 0.
Definition space_at (i : nat) : Space := nth i (f_space F) SGlobal.

(** Signatures *)
Definition v_kind (k : Kind) : vec := vmk n (fun i => kind_eqb (kind_at i) k).
Definition v_skind (k : ScopeKind) : vec := vmk nS (fun i => skind_eqb (skind_at i) k).
Definition v_set (l : list nat) (m : nat) : vec := vmk m (mem1 l).

Definition d_CtaScope := v_skind SCta.
Definition d_ClusterScope := v_skind SCluster.
Definition d_AsyncUnit := v_skind SAsyncUnit.
Definition d_Thread := vunion nS (v_skind SThread) (v_skind SAsyncUnit).

Definition d_Acquire := v_kind KAcquire.
Definition d_Read := vunion n (v_kind KRead) (v_kind KAcquire).
Definition d_Release := v_kind KRelease.
Definition d_Write := vunion n (v_kind KWrite) (v_kind KRelease).
Definition d_MemoryEvent := vunion n d_Read d_Write.
Definition d_FenceAcq := v_kind KFenceAcq.
Definition d_FenceRel := v_kind KFenceRel.
Definition d_FenceSC := v_kind KFenceSC.
Definition d_FenceAcqRel := vunion n (v_kind KFenceAcqRel) (v_kind KFenceSC).
Definition d_Fence := vunion n (vunion n d_FenceAcq d_FenceRel) d_FenceAcqRel.
Definition d_AliasFence := v_kind KAliasFence.
Definition d_PlainProxyFence := v_kind KPlainProxyFence.
Definition d_BarrierArrive := v_kind KBarrierArrive.
Definition d_BarrierWait := v_kind KBarrierWait.
Definition d_Barrier := vunion n d_BarrierArrive d_BarrierWait.
Definition d_ClusterArrive := v_kind KClusterArrive.
Definition d_ClusterWait := v_kind KClusterWait.
Definition d_Marker := v_kind KMarker.

Definition d_SyncRestrictCta := v_set (f_SyncRestrictCta F) n.
Definition d_SyncRestrictCluster := v_set (f_SyncRestrictCluster F) n.
Definition d_OpRestrictInit := v_set (f_OpRestrictInit F) n.
Definition d_ProxyFence := v_set (f_ProxyFence F) n.
Definition d_ClusterArriveRelaxed := v_set (f_ClusterArriveRelaxed F) n.
Definition d_MbarEv := v_set (f_MbarEv F) n.
Definition d_MbarInit := v_set (f_MbarInit F) n.
Definition d_MbarWait := v_set (f_MbarWait F) n.
Definition d_TxAnchor := v_set (f_TxAnchor F) n.
Definition d_Mbar := v_set (f_Mbar F) nA.

(** Fields that are relations *)
Definition d_rel (l : list (nat * nat)) (a b : nat) : mat := mk a b (mem2 l).
Definition d_po := d_rel (f_po F) n n.
Definition d_issue := d_rel (f_issue F) n n.
Definition d_done := d_rel (f_done F) n n.
Definition d_gdep := d_rel (f_gdep F) n n.
Definition d_rmw := d_rel (f_rmw F) n n.
Definition d_dep := d_rel (f_dep F) n n.
Definition d_rf := d_rel (f_rf F) n n.
Definition d_co := d_rel (f_co F) n n.
Definition d_sc := d_rel (f_sc F) n n.
Definition d_bwait := d_rel (f_bwait F) n n.
Definition d_bgen := d_rel (f_bgen F) n n.
Definition d_synchronizes := d_rel (f_synchronizes F) n n.
Definition d_cwait := d_rel (f_cwait F) n n.
Definition d_cgen := d_rel (f_cgen F) n n.
Definition d_txops := d_rel (f_txops F) n n.
Definition d_subscope := d_rel (f_subscope F) nS nS.
Definition d_start := d_rel (f_start F) nS n.
Definition d_alias := d_rel (f_alias F) nA nA.
Definition d_owner := d_rel (f_owner F) nA nS.
Definition d_address := d_rel (f_address F) n nA.
Definition d_acc := d_rel (f_acc F) n nC.
Definition d_paddr := d_rel (f_paddr F) n nA.

(** 8.5 Scopes, threads and locations *)
Definition d_System : vec := vmk nS (fun s => negb (existsb (fun p => get d_subscope p s) (List.seq 0 nS))).
Definition d_aliases : mat := mstar nA (munion nA nA d_alias (minv nA nA d_alias)).
Definition d_po_star : mat := mstar n d_po.
Definition d_thd : mat := mk n nS (fun e t => existsb (fun e0 => get d_start t e0 && get d_po_star e0 e) (List.seq 0 n)).
Definition d_same_alias_r : mat := mseq n nA n d_address (minv n nA d_address).
Definition d_same_location_r : mat := mseq n nA n (mseq n nA nA d_address d_aliases) (minv n nA d_address).
Definition d_subscope_star : mat := mstar nS d_subscope.
Definition d_cta_of : mat :=
  mk n nS (fun e c => existsb (fun t => get d_thd e t && get d_subscope_star c t) (List.seq 0 nS) && vget d_CtaScope c).
Definition d_same_cta_r : mat := mseq n nS n d_cta_of (minv n nS d_cta_of).
Definition d_cluster_of : mat :=
  mk n nS (fun e c => existsb (fun t => get d_thd e t && get d_subscope_star c t) (List.seq 0 nS) && vget d_ClusterScope c).
Definition d_po_loc : mat := minter n n (mplus n d_po) d_same_alias_r.

Definition d_fr : mat :=
  munion n n (mseq n n n (minv n n d_rf) (mplus n d_co))
    (mseq n n n (mdiag n (vminus n d_Read (vcodom n n (mseq n n n (mdiag n d_Write) d_rf))))
       (mseq n n n d_same_location_r (mdiag n d_Write))).
Definition d_com : mat := munion n n (munion n n d_rf (mplus n d_co)) d_fr.

(** 8.7 Morally strong *)
Definition d_Weak : vec := vmk n (fun e => vget d_Thread (scope_at e)).
Definition d_StrongW : vec := vinter n d_Write (vcompl n d_Weak).
Definition d_StrongR : vec := vinter n d_Read (vcompl n d_Weak).
Definition b_proxy_of (e : nat) (p : Proxy) : bool :=
  (vget d_MemoryEvent e && memp (f_proxy F) e p) || (negb (vget d_MemoryEvent e) && proxy_eqb p Generic).
Definition d_same_proxy_of : mat :=
  mk n n (fun i j => existsb (fun p => b_proxy_of i p && b_proxy_of j p) all_proxies).
Definition d_same_proxy : mat :=
  mk n n (fun i j => existsb (fun p => memp (f_proxy F) i p && memp (f_proxy F) j p) all_proxies).
Definition d_scope_incl0 : mat :=
  mk n n (fun i j => existsb (fun t => get d_subscope_star (scope_at i) t && get d_thd j t) (List.seq 0 nS)).
Definition d_scope_incl_r : mat := minter n n d_scope_incl0 (minv n n d_scope_incl0).
Definition d_same_acc : mat := mseq n nC n d_acc (minv n nC d_acc).
Definition d_footprint : mat := mseq n n nA (mopt n d_same_acc) d_address.
Definition d_full_overlap_r : mat :=
  mk n n (fun i j => vget d_MemoryEvent i && vget d_MemoryEvent j
                     && forallb (fun a => Bool.eqb (get d_footprint i a) (get d_footprint j a)) (List.seq 0 nA)).
Definition d_overlap_ok_r : mat :=
  mk n n (fun i j => (vget d_MemoryEvent i && vget d_MemoryEvent j && get d_same_alias_r i j && get d_full_overlap_r i j)
                     || negb (vget d_MemoryEvent i && vget d_MemoryEvent j)).
Definition d_ms_r : mat :=
  mk n n (fun i j => get d_scope_incl_r i j && get d_same_proxy_of i j && get d_overlap_ok_r i j && negb (Nat.eqb i j)).

End Compute.

(** ** The specifications *)

Section Spec.
Context (F : FExec) (V : valid F = true).

Local Abbreviation X := (denote F V).
Local Abbreviation n := (ne F).
Local Abbreviation nS := (ns F).
Local Abbreviation nA := (na F).
Local Abbreviation nC := (nc F).

Lemma v_kind_spec k : sspec (v_kind F k) (fun e => kind X e = k).
Proof. apply sspec_vmk; intros x; apply kind_eqb_eq. Qed.

Lemma v_skind_spec k : sspec (v_skind F k) (fun s => skind X s = k).
Proof. apply sspec_vmk; intros x; apply skind_eqb_eq. Qed.

Lemma mem1_spec l i : mem1 l i = true <-> In i l.
Proof.
  unfold mem1; rewrite existsb_exists; split.
  - intros [j [H E]]; apply Nat.eqb_eq in E; subst; exact H.
  - intros H; exists i; split; [exact H | apply Nat.eqb_refl].
Qed.

Lemma v_set_spec {m} l (P : Fin m -> Prop) : (forall x, P x <-> mem1 l (fin_val x) = true) -> sspec (v_set l m) P.
Proof. intros H; apply sspec_vmk; intros x; rewrite H; reflexivity. Qed.

Lemma d_rel_spec {a b} l (R : Fin a -> Fin b -> Prop) :
  (forall x y, R x y <-> mem2 l (fin_val x) (fin_val y) = true) -> rspec (d_rel l a b) R.
Proof. intros H; apply rspec_mk; intros x y; rewrite H; reflexivity. Qed.

Create HintDb chk.

Ltac base := first [apply v_set_spec | apply d_rel_spec]; intros; reflexivity.

Lemma d_CtaScope_spec : sspec (d_CtaScope F) (CtaScope X). Proof. apply v_skind_spec. Qed.
Lemma d_ClusterScope_spec : sspec (d_ClusterScope F) (ClusterScope X). Proof. apply v_skind_spec. Qed.
Lemma d_AsyncUnit_spec : sspec (d_AsyncUnit F) (AsyncUnit X). Proof. apply v_skind_spec. Qed.
Lemma d_Thread_spec : sspec (d_Thread F) (Thread X).
Proof. exact (sspec_union (v_skind_spec SThread) (v_skind_spec SAsyncUnit)). Qed.

Lemma d_Acquire_spec : sspec (d_Acquire F) (Acquire X). Proof. apply v_kind_spec. Qed.
Lemma d_Read_spec : sspec (d_Read F) (Read X).
Proof. exact (sspec_union (v_kind_spec KRead) (v_kind_spec KAcquire)). Qed.
Lemma d_Release_spec : sspec (d_Release F) (Release X). Proof. apply v_kind_spec. Qed.
Lemma d_Write_spec : sspec (d_Write F) (Write X).
Proof. exact (sspec_union (v_kind_spec KWrite) (v_kind_spec KRelease)). Qed.
Lemma d_MemoryEvent_spec : sspec (d_MemoryEvent F) (MemoryEvent X).
Proof. exact (sspec_union d_Read_spec d_Write_spec). Qed.
Lemma d_FenceAcq_spec : sspec (d_FenceAcq F) (FenceAcq X). Proof. apply v_kind_spec. Qed.
Lemma d_FenceRel_spec : sspec (d_FenceRel F) (FenceRel X). Proof. apply v_kind_spec. Qed.
Lemma d_FenceSC_spec : sspec (d_FenceSC F) (FenceSC X). Proof. apply v_kind_spec. Qed.
Lemma d_FenceAcqRel_spec : sspec (d_FenceAcqRel F) (FenceAcqRel X).
Proof. exact (sspec_union (v_kind_spec KFenceAcqRel) (v_kind_spec KFenceSC)). Qed.
Lemma d_Fence_spec : sspec (d_Fence F) (Fence X).
Proof.
  apply sspec_equiv with (1 := sspec_union (sspec_union d_FenceAcq_spec d_FenceRel_spec) d_FenceAcqRel_spec).
  unfold Fence; intros x; unfold set_union; tauto.
Qed.
Lemma d_AliasFence_spec : sspec (d_AliasFence F) (AliasFence X). Proof. apply v_kind_spec. Qed.
Lemma d_PlainProxyFence_spec : sspec (d_PlainProxyFence F) (PlainProxyFence X). Proof. apply v_kind_spec. Qed.
Lemma d_BarrierArrive_spec : sspec (d_BarrierArrive F) (BarrierArrive X). Proof. apply v_kind_spec. Qed.
Lemma d_BarrierWait_spec : sspec (d_BarrierWait F) (BarrierWait X). Proof. apply v_kind_spec. Qed.
Lemma d_Barrier_spec : sspec (d_Barrier F) (Barrier X).
Proof. exact (sspec_union d_BarrierArrive_spec d_BarrierWait_spec). Qed.
Lemma d_ClusterArrive_spec : sspec (d_ClusterArrive F) (ClusterArrive X). Proof. apply v_kind_spec. Qed.
Lemma d_ClusterWait_spec : sspec (d_ClusterWait F) (ClusterWait X). Proof. apply v_kind_spec. Qed.
Lemma d_Marker_spec : sspec (d_Marker F) (Marker X). Proof. apply v_kind_spec. Qed.

Lemma d_SyncRestrictCta_spec : sspec (d_SyncRestrictCta F) (SyncRestrictCta X). Proof. base. Qed.
Lemma d_SyncRestrictCluster_spec : sspec (d_SyncRestrictCluster F) (SyncRestrictCluster X). Proof. base. Qed.
Lemma d_OpRestrictInit_spec : sspec (d_OpRestrictInit F) (OpRestrictInit X). Proof. base. Qed.
Lemma d_ProxyFence_spec : sspec (d_ProxyFence F) (ProxyFence X). Proof. base. Qed.
Lemma d_ClusterArriveRelaxed_spec : sspec (d_ClusterArriveRelaxed F) (ClusterArriveRelaxed X). Proof. base. Qed.
Lemma d_MbarEv_spec : sspec (d_MbarEv F) (MbarEv X). Proof. base. Qed.
Lemma d_MbarInit_spec : sspec (d_MbarInit F) (MbarInit X). Proof. base. Qed.
Lemma d_MbarWait_spec : sspec (d_MbarWait F) (MbarWait X). Proof. base. Qed.
Lemma d_TxAnchor_spec : sspec (d_TxAnchor F) (TxAnchor X). Proof. base. Qed.
Lemma d_Mbar_spec : sspec (d_Mbar F) (Mbar X). Proof. base. Qed.

Lemma d_po_spec : rspec (d_po F) (po X). Proof. base. Qed.
Lemma d_issue_spec : rspec (d_issue F) (issue X). Proof. base. Qed.
Lemma d_done_spec : rspec (d_done F) (done X). Proof. base. Qed.
Lemma d_gdep_spec : rspec (d_gdep F) (gdep X). Proof. base. Qed.
Lemma d_rmw_spec : rspec (d_rmw F) (rmw X). Proof. base. Qed.
Lemma d_dep_spec : rspec (d_dep F) (dep X). Proof. base. Qed.
Lemma d_rf_spec : rspec (d_rf F) (rf X). Proof. base. Qed.
Lemma d_co_spec : rspec (d_co F) (co X). Proof. base. Qed.
Lemma d_sc_spec : rspec (d_sc F) (sc X). Proof. base. Qed.
Lemma d_bwait_spec : rspec (d_bwait F) (bwait X). Proof. base. Qed.
Lemma d_bgen_spec : rspec (d_bgen F) (bgen X). Proof. base. Qed.
Lemma d_synchronizes_spec : rspec (d_synchronizes F) (synchronizes X). Proof. base. Qed.
Lemma d_cwait_spec : rspec (d_cwait F) (cwait X). Proof. base. Qed.
Lemma d_cgen_spec : rspec (d_cgen F) (cgen X). Proof. base. Qed.
Lemma d_txops_spec : rspec (d_txops F) (txops X). Proof. base. Qed.
Lemma d_subscope_spec : rspec (d_subscope F) (subscope X). Proof. base. Qed.
Lemma d_start_spec : rspec (d_start F) (start X). Proof. base. Qed.
Lemma d_alias_spec : rspec (d_alias F) (alias X). Proof. base. Qed.
Lemma d_owner_spec : rspec (d_owner F) (owner X). Proof. base. Qed.
Lemma d_address_spec : rspec (d_address F) (address X). Proof. base. Qed.
Lemma d_acc_spec : rspec (d_acc F) (acc X). Proof. base. Qed.
Lemma d_paddr_spec : rspec (d_paddr F) (paddr X). Proof. base. Qed.

#[local] Hint Resolve d_CtaScope_spec d_ClusterScope_spec d_AsyncUnit_spec d_Thread_spec d_Acquire_spec d_Read_spec
  d_Release_spec d_Write_spec d_MemoryEvent_spec d_FenceAcq_spec d_FenceRel_spec d_FenceSC_spec
  d_FenceAcqRel_spec d_Fence_spec d_AliasFence_spec d_PlainProxyFence_spec d_BarrierArrive_spec
  d_BarrierWait_spec d_Barrier_spec d_ClusterArrive_spec d_ClusterWait_spec d_Marker_spec
  d_SyncRestrictCta_spec d_SyncRestrictCluster_spec d_OpRestrictInit_spec d_ProxyFence_spec
  d_ClusterArriveRelaxed_spec d_MbarEv_spec d_MbarInit_spec d_MbarWait_spec d_TxAnchor_spec d_Mbar_spec
  d_po_spec d_issue_spec d_done_spec d_gdep_spec d_rmw_spec d_dep_spec d_rf_spec d_co_spec d_sc_spec
  d_bwait_spec d_bgen_spec d_synchronizes_spec d_cwait_spec d_cgen_spec d_txops_spec d_subscope_spec : chk.

(** The structural steps: the matrix operation decides the lemma. *)
Ltac spec_step :=
  match goal with
  | |- rspec (munion _ _ _ _) _ => apply rspec_union
  | |- rspec (minter _ _ _ _) _ => apply rspec_inter
  | |- rspec (mminus _ _ _ _) _ => apply rspec_minus
  | |- rspec (minv _ _ _) _ => apply rspec_inv
  | |- rspec (mseq _ _ _ _ _) _ => apply rspec_seq
  | |- rspec (mdiag _ _) _ => apply rspec_diag
  | |- rspec (mopt _ _) _ => apply rspec_opt
  | |- rspec (mplus _ _) _ => apply rspec_plus
  | |- rspec (mstar _ _) _ => apply rspec_star
  | |- sspec (vunion _ _ _) _ => apply sspec_union
  | |- sspec (vinter _ _ _) _ => apply sspec_inter
  | |- sspec (vminus _ _ _) _ => apply sspec_minus
  | |- sspec (vcompl _ _) _ => apply sspec_compl
  | |- sspec (vcodom _ _ _) _ => apply sspec_codom_rel
  | |- sspec (vdom _ _ _) _ => apply sspec_dom_rel
  | |- bspec (_ && _) _ => apply bspec_and
  | |- bspec (_ || _) _ => apply bspec_or
  | |- bspec (negb _) _ => apply bspec_not
  | |- bspec (bsubset _ _ _ _) _ => apply bspec_subset
  | |- bspec (birrefl _ _) _ => apply bspec_irrefl
  | |- bspec (bacyclic _ _) _ => apply bspec_acyclic
  end.
Ltac spec := repeat (spec_step || solve [auto with chk]).

Lemma d_System_spec : sspec (d_System F) (System X).
Proof.
  apply sspec_vmk; intros s; unfold System; rewrite negb_true_iff, <- not_true_iff_false.
  rewrite (existsb_fin _ (fun p => subscope X p s)); [reflexivity |].
  intros p; apply d_subscope_spec.
Qed.

Lemma d_aliases_spec : rspec (d_aliases F) (aliases X).
Proof. unfold d_aliases, aliases; apply rspec_star, rspec_union; [| apply rspec_inv]; apply d_alias_spec. Qed.

Lemma d_po_star_spec : rspec (d_po_star F) (po X)＊.
Proof. apply rspec_star, d_po_spec. Qed.

Lemma d_thd_spec : rspec (d_thd F) (thd X).
Proof.
  apply rspec_mk; intros e t; apply existsb_fin; intros e0.
  rewrite andb_true_iff, (d_start_spec t e0), (d_po_star_spec e0 e); reflexivity.
Qed.

Lemma d_same_alias_r_spec : rspec (d_same_alias_r F) (same_alias_r X).
Proof. exact (rspec_seq_het d_address_spec (rspec_inv_het d_address_spec)). Qed.

Lemma d_same_location_r_spec : rspec (d_same_location_r F) (same_location_r X).
Proof.
  apply rspec_equiv with (1 := rspec_seq_het (rspec_seq_het d_address_spec d_aliases_spec)
                                             (rspec_inv_het d_address_spec)).
  unfold same_location_r; intros x y; split.
  - intros [a2 [[a1 [H1 H2]] H3]]; exists a1, a2; auto.
  - intros [a1 [a2 [H1 [H2 H3]]]]; exists a2; split; [exists a1; auto | exact H3].
Qed.

Lemma d_subscope_star_spec : rspec (d_subscope_star F) (subscope X)＊.
Proof. apply rspec_star, d_subscope_spec. Qed.

Lemma d_cta_of_spec : rspec (d_cta_of F) (cta_of X).
Proof.
  apply rspec_mk; intros e c; unfold cta_of; rewrite andb_true_iff, (d_CtaScope_spec c).
  rewrite (existsb_fin _ (fun t => thd X e t /\ (subscope X)＊ c t)).
  - split; [intros [[t [H1 H2]] H3]; exists t; auto | intros [t [H1 [H2 H3]]]; split; [exists t |]; auto].
  - intros t; rewrite andb_true_iff, (d_thd_spec e t), (d_subscope_star_spec c t); reflexivity.
Qed.

Lemma d_same_cta_r_spec : rspec (d_same_cta_r F) (same_cta_r X).
Proof. exact (rspec_seq_het d_cta_of_spec (rspec_inv_het d_cta_of_spec)). Qed.

Lemma d_cluster_of_spec : rspec (d_cluster_of F) (cluster_of X).
Proof.
  apply rspec_mk; intros e c; unfold cluster_of; rewrite andb_true_iff, (d_ClusterScope_spec c).
  rewrite (existsb_fin _ (fun t => thd X e t /\ (subscope X)＊ c t)).
  - split; [intros [[t [H1 H2]] H3]; exists t; auto | intros [t [H1 [H2 H3]]]; split; [exists t |]; auto].
  - intros t; rewrite andb_true_iff, (d_thd_spec e t), (d_subscope_star_spec c t); reflexivity.
Qed.

#[local] Hint Resolve d_System_spec d_aliases_spec d_thd_spec d_same_alias_r_spec d_same_location_r_spec
  d_cta_of_spec d_same_cta_r_spec d_cluster_of_spec : chk.

Lemma d_po_loc_spec : rspec (d_po_loc F) (po_loc X).
Proof. unfold d_po_loc, po_loc, same_alias; spec. Qed.

Lemma d_fr_spec : rspec (d_fr F) (fr X).
Proof. unfold d_fr, fr; spec. Qed.
#[local] Hint Resolve d_fr_spec : chk.

Lemma d_com_spec : rspec (d_com F) (com X).
Proof. unfold d_com, com; spec. Qed.

#[local] Hint Resolve d_po_loc_spec d_com_spec : chk.

Lemma scope_at_val e : scope_at F (fin_val e) = fin_val (scope X e).
Proof. reflexivity. Qed.

Lemma d_Weak_spec : sspec (d_Weak F) (Weak X).
Proof. apply sspec_vmk; intros e; rewrite scope_at_val; apply d_Thread_spec. Qed.

#[local] Hint Resolve d_Weak_spec : chk.

Lemma d_StrongW_spec : sspec (d_StrongW F) (StrongW X).
Proof. unfold d_StrongW; spec. Qed.
Lemma d_StrongR_spec : sspec (d_StrongR F) (StrongR X).
Proof. unfold d_StrongR; spec. Qed.

Lemma memp_spec e p : memp (f_proxy F) (fin_val e) p = true <-> proxy X e p.
Proof. reflexivity. Qed.

Lemma b_proxy_of_spec e p : b_proxy_of F (fin_val e) p = true <-> proxy_of X e p.
Proof.
  unfold b_proxy_of, proxy_of; rewrite orb_true_iff, !andb_true_iff, negb_true_iff, <- not_true_iff_false.
  rewrite (d_MemoryEvent_spec e), proxy_eqb_eq, memp_spec; reflexivity.
Qed.

Lemma d_same_proxy_of_spec : rspec (d_same_proxy_of F) (fun e1 e2 => exists p, proxy_of X e1 p /\ proxy_of X e2 p).
Proof.
  apply rspec_mk; intros x y; apply existsb_list; [apply all_proxies_in |]; intros p.
  rewrite andb_true_iff, !b_proxy_of_spec; reflexivity.
Qed.

Lemma d_same_proxy_spec : rspec (d_same_proxy F) (fun e1 e2 => exists p, proxy X e1 p /\ proxy X e2 p).
Proof.
  apply rspec_mk; intros x y; apply existsb_list; [apply all_proxies_in |]; intros p.
  rewrite andb_true_iff, !memp_spec; reflexivity.
Qed.

Lemma d_scope_incl0_spec : rspec (d_scope_incl0 F) (fun e1 e2 => exists t, (subscope X)＊ (scope X e1) t /\ thd X e2 t).
Proof.
  apply rspec_mk; intros x y; apply existsb_fin; intros t.
  rewrite andb_true_iff, scope_at_val, (d_subscope_star_spec (scope X x) t), (d_thd_spec y t); reflexivity.
Qed.

Lemma d_scope_incl_r_spec : rspec (d_scope_incl_r F) (scope_incl_r X).
Proof. exact (rspec_inter d_scope_incl0_spec (rspec_inv d_scope_incl0_spec)). Qed.

Lemma d_same_acc_spec : rspec (d_same_acc F) (same_acc X).
Proof. exact (rspec_seq_het d_acc_spec (rspec_inv_het d_acc_spec)). Qed.

Lemma d_footprint_spec : rspec (d_footprint F) (footprint X).
Proof.
  apply rspec_equiv with (1 := rspec_seq_het (rspec_opt d_same_acc_spec) d_address_spec).
  unfold footprint, clos_refl; intros x a; split; intros [e' [H1 H2]]; exists e'; split; tauto.
Qed.

Lemma d_full_overlap_r_spec : rspec (d_full_overlap_r F) (full_overlap_r X).
Proof.
  apply rspec_mk; intros x y; unfold full_overlap_r; rewrite !andb_true_iff, (d_MemoryEvent_spec x), (d_MemoryEvent_spec y).
  rewrite (forallb_fin _ (fun a => footprint X x a <-> footprint X y a)); [tauto |].
  intros a; apply bspec_iff; apply d_footprint_spec.
Qed.

Lemma d_overlap_ok_r_spec : rspec (d_overlap_ok_r F) (overlap_ok_r X).
Proof.
  apply rspec_mk; intros x y; unfold overlap_ok_r.
  rewrite orb_true_iff, !andb_true_iff, negb_true_iff, <- not_true_iff_false, andb_true_iff.
  rewrite (d_MemoryEvent_spec x), (d_MemoryEvent_spec y), (d_same_alias_r_spec x y), (d_full_overlap_r_spec x y).
  tauto.
Qed.

Lemma d_ms_r_spec : rspec (d_ms_r F) (ms_r X).
Proof.
  apply rspec_mk; intros x y; unfold ms_r.
  rewrite !andb_true_iff, negb_true_iff, <- not_true_iff_false, Nat.eqb_eq, <- fin_eq_iff.
  rewrite (d_scope_incl_r_spec x y), (d_same_proxy_of_spec x y), (d_overlap_ok_r_spec x y); tauto.
Qed.

#[local] Hint Resolve d_StrongW_spec d_StrongR_spec d_same_proxy_spec d_scope_incl_r_spec d_same_acc_spec
  d_footprint_spec d_ms_r_spec : chk.

End Spec.
