(** * Every derived relation of the model grows under the lowering

    [mono ev rP rK]: whenever [rP x y] holds in the PTX execution, [rK (ev x) (ev y)] holds in the Kamui one. This
    file shows it for every derived relation of [Ptx87.v], from the definitions: each relation is built from
    smaller ones by unions, intersections, compositions and closures, which keep [mono]. A set difference needs
    the subtracted part in the other direction ([rfl]: what holds of the images in Kamui holds in PTX); the
    model only subtracts sets that are the same on images (kinds, restricted fences), so it does. *)

From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87 Kamui Lowering.
From KamuiProof.proof Require Import Embedding.

Set Implicit Arguments.

(** ** Monotone maps of relations *)

Section Mono.

Context {EP EK : Type} (f : EP -> EK).

Definition mono (rP : relation EP) (rK : relation EK) : Prop := forall x y, rP x y -> rK (f x) (f y).
Definition rfl (rP : relation EP) (rK : relation EK) : Prop := forall x y, rK (f x) (f y) -> rP x y.
Definition smono (sP : EP -> Prop) (sK : EK -> Prop) : Prop := forall x, sP x -> sK (f x).
Definition srfl (sP : EP -> Prop) (sK : EK -> Prop) : Prop := forall x, sK (f x) -> sP x.

Lemma mono_union r1 r2 q1 q2 : mono r1 q1 -> mono r2 q2 -> mono (r1 ∪ r2) (q1 ∪ q2).
Proof. intros H1 H2 x y [H | H]; [left; apply H1, H | right; apply H2, H]. Qed.

Lemma mono_inter r1 r2 q1 q2 : mono r1 q1 -> mono r2 q2 -> mono (r1 ∩ r2) (q1 ∩ q2).
Proof. intros H1 H2 x y [Ha Hb]; split; [apply H1, Ha | apply H2, Hb]. Qed.

Lemma mono_seq r1 r2 q1 q2 : mono r1 q1 -> mono r2 q2 -> mono (r1 ⨾ r2) (q1 ⨾ q2).
Proof. intros H1 H2 x y [z [Ha Hb]]; exists (f z); split; [apply H1, Ha | apply H2, Hb]. Qed.

Lemma mono_inv r q : mono r q -> mono r⁻¹ q⁻¹.
Proof. intros H x y Hr; apply H, Hr. Qed.

Lemma mono_eqv s t : smono s t -> mono ⦗s⦘ ⦗t⦘.
Proof. intros H x y [<- Hs]; split; [reflexivity | apply H, Hs]. Qed.

Lemma mono_cr r q : mono r q -> mono r^? q^?.
Proof. intros H x y [<- | Hr]; [left; reflexivity | right; apply H, Hr]. Qed.

Lemma mono_ct r q : mono r q -> mono r⁺ q⁺.
Proof. intros H x y Hr; induction Hr as [x y Hr | x y z _ IH1 _ IH2]; [apply t_step, H, Hr | eapply t_trans; eauto]. Qed.

Lemma mono_rt r q : mono r q -> mono r＊ q＊.
Proof.
  intros H x y Hr; induction Hr as [x y Hr | x | x y z _ IH1 _ IH2].
  - apply rt_step, H, Hr.
  - apply rt_refl.
  - eapply rt_trans; eauto.
Qed.

Lemma mono_minus r1 r2 q1 q2 : mono r1 q1 -> rfl r2 q2 -> mono (r1 \ r2) (q1 \ q2).
Proof. intros H1 H2 x y [Ha Hb]; split; [apply H1, Ha | intros Hq; apply Hb, H2, Hq]. Qed.

(** [a \ (⦗s⦘ ⨾ r)] with [a] inside [r]: what is removed is the edges that start in [s]. *)
Lemma mono_minus_seql a r s a' r' s' : mono a a' -> srfl s s' -> (forall x y, a x y -> r x y) ->
  mono (a \ (⦗s⦘ ⨾ r)) (a' \ (⦗s'⦘ ⨾ r')).
Proof.
  intros H1 H2 Ha x y [Hxy Hn]; split; [apply H1, Hxy |].
  intros [z [[Ez Hs] _]]; apply Hn; exists x; split; [split; [reflexivity |] | apply Ha, Hxy].
  apply H2; exact Hs.
Qed.

Lemma mono_minus_seqr a r s a' r' s' : mono a a' -> srfl s s' -> (forall x y, a x y -> r x y) ->
  mono (a \ (r ⨾ ⦗s⦘)) (a' \ (r' ⨾ ⦗s'⦘)).
Proof.
  intros H1 H2 Ha x y [Hxy Hn]; split; [apply H1, Hxy |].
  intros [z [_ [Ez Hs]]]; apply Hn; exists y; split; [apply Ha, Hxy | split; [reflexivity |]].
  apply H2; rewrite <- Ez; exact Hs.
Qed.

Lemma smono_union s1 s2 t1 t2 : smono s1 t1 -> smono s2 t2 -> smono (s1 ∪₁ s2) (t1 ∪₁ t2).
Proof. intros H1 H2 x [H | H]; [left; apply H1, H | right; apply H2, H]. Qed.
Lemma smono_inter s1 s2 t1 t2 : smono s1 t1 -> smono s2 t2 -> smono (s1 ∩₁ s2) (t1 ∩₁ t2).
Proof. intros H1 H2 x [Ha Hb]; split; [apply H1, Ha | apply H2, Hb]. Qed.
Lemma smono_minus s1 s2 t1 t2 : smono s1 t1 -> srfl s2 t2 -> smono (s1 \₁ s2) (t1 \₁ t2).
Proof. intros H1 H2 x [Ha Hb]; split; [apply H1, Ha | intros Ht; apply Hb, H2, Ht]. Qed.
Lemma smono_compl s t : srfl s t -> smono (set_compl s) (set_compl t).
Proof. intros H x Hs Ht; apply Hs, H, Ht. Qed.

Lemma srfl_union s1 s2 t1 t2 : srfl s1 t1 -> srfl s2 t2 -> srfl (s1 ∪₁ s2) (t1 ∪₁ t2).
Proof. intros H1 H2 x [H | H]; [left; apply H1, H | right; apply H2, H]. Qed.
Lemma srfl_inter s1 s2 t1 t2 : srfl s1 t1 -> srfl s2 t2 -> srfl (s1 ∩₁ s2) (t1 ∩₁ t2).
Proof. intros H1 H2 x [Ha Hb]; split; [apply H1, Ha | apply H2, Hb]. Qed.
Lemma srfl_minus s1 s2 t1 t2 : srfl s1 t1 -> smono s2 t2 -> srfl (s1 \₁ s2) (t1 \₁ t2).
Proof. intros H1 H2 x [Ha Hb]; split; [apply H1, Ha | intros Hs; apply Hb, H2, Hs]. Qed.
Lemma srfl_compl s t : smono s t -> srfl (set_compl s) (set_compl t).
Proof. intros H x Ht Hs; apply Ht, H, Hs. Qed.

(** A set that is the same on images. *)
Lemma exact_smono s t : (forall x, t (f x) <-> s x) -> smono s t.
Proof. intros H x Hs; apply H, Hs. Qed.
Lemma exact_srfl s t : (forall x, t (f x) <-> s x) -> srfl s t.
Proof. intros H x Ht; apply H, Ht. Qed.
Lemma exact_mono r q : (forall x y, q (f x) (f y) <-> r x y) -> mono r q.
Proof. intros H x y Hr; apply H, Hr. Qed.
Lemma exact_rfl r q : (forall x y, q (f x) (f y) <-> r x y) -> rfl r q.
Proof. intros H x y Hq; apply H, Hq. Qed.

End Mono.

Create HintDb mono.

(** The structural steps, by the shape of both sides. *)
Ltac mstep :=
  match goal with
  | |- mono _ (_ ∪ _) (_ ∪ _) => apply mono_union
  | |- mono _ (_ ∩ _) (_ ∩ _) => apply mono_inter
  | |- mono _ (_ ⨾ _) (_ ⨾ _) => apply mono_seq
  | |- mono _ (_ ⁻¹) (_ ⁻¹) => apply mono_inv
  | |- mono _ ⦗_⦘ ⦗_⦘ => apply mono_eqv
  | |- mono _ (_ ^?) (_ ^?) => apply mono_cr
  | |- mono _ (_ \ (⦗_⦘ ⨾ _)) (_ \ (⦗_⦘ ⨾ _)) =>
      apply mono_minus_seql; [| | solve [intros ? ? Hx; exact Hx | intros ? ? [Hx _]; exact Hx]]
  | |- mono _ (_ \ (_ ⨾ ⦗_⦘)) (_ \ (_ ⨾ ⦗_⦘)) =>
      apply mono_minus_seqr; [| | solve [intros ? ? Hx; exact Hx | intros ? ? [Hx _]; exact Hx]]
  | |- smono _ (_ ∪₁ _) (_ ∪₁ _) => apply smono_union
  | |- smono _ (_ ∩₁ _) (_ ∩₁ _) => apply smono_inter
  | |- smono _ (_ \₁ _) (_ \₁ _) => apply smono_minus
  | |- smono _ (set_compl _) (set_compl _) => apply smono_compl
  | |- srfl _ (_ ∪₁ _) (_ ∪₁ _) => apply srfl_union
  | |- srfl _ (_ ∩₁ _) (_ ∩₁ _) => apply srfl_inter
  | |- srfl _ (_ \₁ _) (_ \₁ _) => apply srfl_minus
  | |- srfl _ (set_compl _) (set_compl _) => apply srfl_compl
  end.

(** The leaves are hints; closures come last, since [po⁺] has its own lemma. *)
Ltac mono_tac := repeat (solve [auto with mono] || mstep
                         || match goal with
                            | |- mono _ (_ ⁺) (_ ⁺) => apply mono_ct
                            | |- mono _ (_ ＊) (_ ＊) => apply mono_rt
                            end).

Section Derived.

Context {EP EK S A C : Type} {P : Exec EP S A C} {K : Exec EK S A C} {M : Map EP EK} (HL : setting P K M).

Local Abbreviation ev := (ev M).

(** ** The leaves *)

Lemma s_Read : smono ev (Read P) (Read K) /\ srfl ev (Read P) (Read K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (Read_ev HL). Qed.
Lemma s_Acquire : smono ev (Acquire P) (Acquire K) /\ srfl ev (Acquire P) (Acquire K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (Acquire_ev HL). Qed.
Lemma s_Write : smono ev (Write P) (Write K) /\ srfl ev (Write P) (Write K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (Write_ev HL). Qed.
Lemma s_Release : smono ev (Release P) (Release K) /\ srfl ev (Release P) (Release K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (Release_ev HL). Qed.
Lemma s_MemoryEvent : smono ev (MemoryEvent P) (MemoryEvent K) /\ srfl ev (MemoryEvent P) (MemoryEvent K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (MemoryEvent_ev HL). Qed.
Lemma s_FenceAcq : smono ev (FenceAcq P) (FenceAcq K) /\ srfl ev (FenceAcq P) (FenceAcq K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (FenceAcq_ev HL). Qed.
Lemma s_FenceRel : smono ev (FenceRel P) (FenceRel K) /\ srfl ev (FenceRel P) (FenceRel K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (FenceRel_ev HL). Qed.
Lemma s_FenceSC : smono ev (FenceSC P) (FenceSC K) /\ srfl ev (FenceSC P) (FenceSC K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (FenceSC_ev HL). Qed.
Lemma s_FenceAcqRel : smono ev (FenceAcqRel P) (FenceAcqRel K) /\ srfl ev (FenceAcqRel P) (FenceAcqRel K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (FenceAcqRel_ev HL). Qed.
Lemma s_AliasFence : smono ev (AliasFence P) (AliasFence K) /\ srfl ev (AliasFence P) (AliasFence K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (AliasFence_ev HL). Qed.
Lemma s_BarrierWait : smono ev (BarrierWait P) (BarrierWait K) /\ srfl ev (BarrierWait P) (BarrierWait K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (BarrierWait_ev HL). Qed.
Lemma s_ClusterArrive : smono ev (ClusterArrive P) (ClusterArrive K) /\ srfl ev (ClusterArrive P) (ClusterArrive K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (ClusterArrive_ev HL). Qed.
Lemma s_SyncRestrictCta : smono ev (SyncRestrictCta P) (SyncRestrictCta K)
                          /\ srfl ev (SyncRestrictCta P) (SyncRestrictCta K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (SyncRestrictCta_ev HL). Qed.
Lemma s_SyncRestrictCluster : smono ev (SyncRestrictCluster P) (SyncRestrictCluster K)
                              /\ srfl ev (SyncRestrictCluster P) (SyncRestrictCluster K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (SyncRestrictCluster_ev HL). Qed.
Lemma s_OpRestrictInit : smono ev (OpRestrictInit P) (OpRestrictInit K) /\ srfl ev (OpRestrictInit P) (OpRestrictInit K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (OpRestrictInit_ev HL). Qed.
Lemma s_ClusterArriveRelaxed : smono ev (ClusterArriveRelaxed P) (ClusterArriveRelaxed K)
                               /\ srfl ev (ClusterArriveRelaxed P) (ClusterArriveRelaxed K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact (ClusterArriveRelaxed_ev HL). Qed.
Lemma s_MbarInit : smono ev (MbarInit P) (MbarInit K) /\ srfl ev (MbarInit P) (MbarInit K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (MbarInit_ev HL). Qed.
Lemma s_TxAnchor : smono ev (TxAnchor P) (TxAnchor K) /\ srfl ev (TxAnchor P) (TxAnchor K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (TxAnchor_ev HL). Qed.
Lemma s_StrongW : smono ev (StrongW P) (StrongW K) /\ srfl ev (StrongW P) (StrongW K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (StrongW_ev HL). Qed.
Lemma s_StrongR : smono ev (StrongR P) (StrongR K) /\ srfl ev (StrongR P) (StrongR K). Proof. split; [apply exact_smono | apply exact_srfl]; exact (StrongR_ev HL). Qed.

Lemma GenericM_ev e : GenericM K (ev e) <-> GenericM P e. Proof. apply (proxy_ev HL). Qed.
Lemma s_GenericM : smono ev (GenericM P) (GenericM K) /\ srfl ev (GenericM P) (GenericM K). Proof. split; [apply exact_smono | apply exact_srfl]; exact GenericM_ev. Qed.

Lemma AsyncW_ev e : (fun e => proxy K e Async /\ Write K e) (ev e) <-> (fun e => proxy P e Async /\ Write P e) e.
Proof. simpl; rewrite (proxy_ev HL), (Write_ev HL); reflexivity. Qed.
Lemma s_AsyncW : smono ev (fun e => proxy P e Async /\ Write P e) (fun e => proxy K e Async /\ Write K e).
Proof. apply exact_smono, AsyncW_ev. Qed.

Lemma wait_true_ev e : MbarWait P e -> wait_true K (ev e) <-> wait_true P e.
Proof.
  intros H; unfold wait_true.
  assert (Hm : MbarEv P e) by (apply (mbarrier_state_4 (WFP HL)); right; exact H).
  rewrite (wpar_ev HL e H), (wtok_ev HL e H), (ph_ev HL e Hm); reflexivity.
Qed.

Lemma FalseWaits_ev e : FalseWaits K (ev e) <-> FalseWaits P e.
Proof.
  unfold FalseWaits; rewrite (MbarWait_ev HL); split; intros [Hw Hn]; split; auto.
  all: rewrite (wait_true_ev e Hw) in *; exact Hn.
Qed.
Lemma s_FalseWaits : smono ev (FalseWaits P) (FalseWaits K) /\ srfl ev (FalseWaits P) (FalseWaits K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact FalseWaits_ev. Qed.

Lemma TmFence_ev e : TmFence K (ev e) <-> TmFence P e.
Proof. unfold TmFence; rewrite (ProxyFence_ev HL), (dirs_ev HL); reflexivity. Qed.
Lemma s_TmFence : smono ev (TmFence P) (TmFence K) /\ srfl ev (TmFence P) (TmFence K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact TmFence_ev. Qed.

Lemma AtomicR_ev e : AtomicR K (ev e) <-> AtomicR P e.
Proof.
  unfold AtomicR; split.
  - intros [k [Hr Hw]]; destruct (Write_image HL Hw) as [w <-]; exists w.
    rewrite (rmw_ev HL), (Write_ev HL) in *; auto.
  - intros [w [Hr Hw]]; exists (ev w); rewrite (rmw_ev HL), (Write_ev HL); auto.
Qed.

Lemma Atomics_ev e : Atomics K (ev e) <-> Atomics P e.
Proof.
  unfold Atomics; rewrite AtomicR_ev; split; intros [H | [r [Hr Hw]]]; auto; right.
  - destruct (onto HL r) as [[r' <-] | [r' Hp]].
    + exists r'; rewrite AtomicR_ev, (rmw_ev HL) in *; auto.
    + exfalso; destruct Hr as [w [Hrw _]].
      destruct (decl_rmw (WFKp HL) _ _ Hrw) as [Hrd _].
      unfold Read in Hrd; rewrite (kind_pre HL r' Hp) in Hrd; destruct Hrd; discriminate.
  - exists (ev r); rewrite AtomicR_ev, (rmw_ev HL); auto.
Qed.
Lemma s_Atomics : smono ev (Atomics P) (Atomics K) /\ srfl ev (Atomics P) (Atomics K).
Proof. split; [apply exact_smono | apply exact_srfl]; exact Atomics_ev. Qed.

(** Sets of the model built from these. *)
Lemma s_RelFences : smono ev (RelFences P) (RelFences K) /\ srfl ev (RelFences P) (RelFences K).
Proof.
  unfold RelFences; destruct s_FenceRel as [a1 b1]; destruct s_FenceAcqRel as [a2 b2]; destruct s_BarrierWait as [a3 b3].
  split; [apply smono_union; [apply smono_union |] | apply srfl_union; [apply srfl_union |]]; assumption.
Qed.
Lemma s_AcqFences : smono ev (AcqFences P) (AcqFences K) /\ srfl ev (AcqFences P) (AcqFences K).
Proof.
  unfold AcqFences; destruct s_FenceAcq as [a1 b1]; destruct s_FenceAcqRel as [a2 b2]; destruct s_BarrierWait as [a3 b3].
  split; [apply smono_union; [apply smono_union |] | apply srfl_union; [apply srfl_union |]]; assumption.
Qed.
Lemma s_AcqReads : smono ev (AcqReads P) (AcqReads K) /\ srfl ev (AcqReads P) (AcqReads K).
Proof.
  unfold AcqReads; destruct s_Acquire as [a1 b1]; destruct s_FalseWaits as [a2 b2].
  split; [apply smono_minus | apply srfl_minus]; assumption.
Qed.
Lemma s_RRel : smono ev (RRel P) (RRel K) /\ srfl ev (RRel P) (RRel K).
Proof.
  unfold RRel; destruct s_SyncRestrictCta as [a1 b1]; destruct s_OpRestrictInit as [a2 b2]; destruct s_TxAnchor as [a3 b3].
  split; [apply smono_union; [apply smono_union |] | apply srfl_union; [apply srfl_union |]]; assumption.
Qed.
Lemma s_RAcq : smono ev (RAcq P) (RAcq K) /\ srfl ev (RAcq P) (RAcq K). Proof. apply s_SyncRestrictCluster. Qed.

Lemma s_CA_minus : smono ev (ClusterArrive P \₁ ClusterArriveRelaxed P) (ClusterArrive K \₁ ClusterArriveRelaxed K).
Proof. apply smono_minus; [apply s_ClusterArrive | apply s_ClusterArriveRelaxed]. Qed.

Lemma s_GenericRead : smono ev (GenericM P ∩₁ Read P) (GenericM K ∩₁ Read K).
Proof. apply smono_inter; [apply s_GenericM | apply s_Read]. Qed.
Lemma s_TmRel : smono ev (TmFence P ∩₁ FenceRel P) (TmFence K ∩₁ FenceRel K).
Proof. apply smono_inter; [apply s_TmFence | apply s_FenceRel]. Qed.
Lemma s_TmAcq : smono ev (TmFence P ∩₁ FenceAcq P) (TmFence K ∩₁ FenceAcq K).
Proof. apply smono_inter; [apply s_TmFence | apply s_FenceAcq]. Qed.

#[local] Hint Extern 1 (smono _ _ _) => first [exact (proj1 s_Read) | exact (proj1 s_Acquire) | exact (proj1 s_Write) | exact (proj1 s_Release) | exact (proj1 s_MemoryEvent) | exact (proj1 s_FenceAcq) | exact (proj1 s_FenceRel) | exact (proj1 s_FenceSC) | exact (proj1 s_FenceAcqRel) | exact (proj1 s_AliasFence) | exact (proj1 s_BarrierWait) | exact (proj1 s_ClusterArrive) | exact (proj1 s_SyncRestrictCta) | exact (proj1 s_SyncRestrictCluster) | exact (proj1 s_OpRestrictInit) | exact (proj1 s_ClusterArriveRelaxed) | exact (proj1 s_MbarInit) | exact (proj1 s_TxAnchor) | exact (proj1 s_StrongW) | exact (proj1 s_StrongR) | exact (proj1 s_GenericM) | exact (proj1 s_FalseWaits) | exact (proj1 s_TmFence) | exact (proj1 s_Atomics) | exact (proj1 s_RelFences) | exact (proj1 s_AcqFences) | exact (proj1 s_AcqReads) | exact (proj1 s_RRel) | exact (proj1 s_RAcq)] : mono.
#[local] Hint Extern 1 (srfl _ _ _) => first [exact (proj2 s_Read) | exact (proj2 s_Acquire) | exact (proj2 s_Write) | exact (proj2 s_Release) | exact (proj2 s_MemoryEvent) | exact (proj2 s_FenceAcq) | exact (proj2 s_FenceRel) | exact (proj2 s_FenceSC) | exact (proj2 s_FenceAcqRel) | exact (proj2 s_AliasFence) | exact (proj2 s_BarrierWait) | exact (proj2 s_ClusterArrive) | exact (proj2 s_SyncRestrictCta) | exact (proj2 s_SyncRestrictCluster) | exact (proj2 s_OpRestrictInit) | exact (proj2 s_ClusterArriveRelaxed) | exact (proj2 s_MbarInit) | exact (proj2 s_TxAnchor) | exact (proj2 s_StrongW) | exact (proj2 s_StrongR) | exact (proj2 s_GenericM) | exact (proj2 s_FalseWaits) | exact (proj2 s_TmFence) | exact (proj2 s_Atomics) | exact (proj2 s_RelFences) | exact (proj2 s_AcqFences) | exact (proj2 s_AcqReads) | exact (proj2 s_RRel) | exact (proj2 s_RAcq)] : mono.
#[local] Hint Resolve s_AsyncW s_CA_minus s_GenericRead s_TmRel s_TmAcq : mono.

(** Relations of the program and of the execution. *)
Lemma m_rf : mono ev (rf P) (rf K). Proof. apply exact_mono, (rf_ev HL). Qed.
Lemma m_co : mono ev (co P) (co K). Proof. apply exact_mono, (co_ev HL). Qed.
Lemma m_rmw : mono ev (rmw P) (rmw K). Proof. apply exact_mono, (rmw_ev HL). Qed.
Lemma m_dep : mono ev (dep P) (dep K). Proof. apply exact_mono, (dep_ev HL). Qed.
Lemma m_issue : mono ev (issue P) (issue K). Proof. apply exact_mono, (issue_ev HL). Qed.
Lemma m_done : mono ev (done P) (done K). Proof. apply exact_mono, (done_ev HL). Qed.
Lemma m_gdep : mono ev (gdep P) (gdep K). Proof. apply exact_mono, (gdep_ev HL). Qed.
Lemma m_cwait : mono ev (cwait P) (cwait K). Proof. apply exact_mono, (cwait_ev HL). Qed.
Lemma m_txops : mono ev (txops P) (txops K). Proof. apply exact_mono, (txops_ev HL). Qed.
Lemma m_cgen : mono ev (cgen P) (cgen K). Proof. apply exact_mono, (cgen_ev HL). Qed.
Lemma m_synchronizes : mono ev (synchronizes P) (synchronizes K). Proof. apply exact_mono, (synchronizes_ev HL). Qed.
Lemma m_sc : mono ev (sc P) (sc K). Proof. intros x y H; apply (sc_ev HL) in H; apply H. Qed.
Lemma m_same_location_r : mono ev (same_location_r P) (same_location_r K).
Proof. apply exact_mono, (same_location_r_ev HL). Qed.
Lemma m_same_alias_r : mono ev (same_alias_r P) (same_alias_r K). Proof. apply exact_mono, (same_alias_r_ev HL). Qed.
Lemma m_same_cta_r : mono ev (same_cta_r P) (same_cta_r K). Proof. apply exact_mono, (same_cta_r_ev HL). Qed.
Lemma m_same_acc : mono ev (same_acc P) (same_acc K). Proof. apply exact_mono, (same_acc_ev HL). Qed.
Lemma m_same_vacc : mono ev (same_vacc P) (same_vacc K). Proof. apply exact_mono, (same_vacc_ev HL). Qed.
Lemma m_scope_incl_r : mono ev (scope_incl_r P) (scope_incl_r K). Proof. exact (scope_incl_r_mono HL). Qed.
Lemma m_ms_r : mono ev (ms_r P) (ms_r K). Proof. exact (ms_r_mono HL). Qed.
Lemma m_po_plus : mono ev (po P)⁺ (po K)⁺. Proof. exact (po_plus_ev HL). Qed.
Lemma m_same_proxy : mono ev (fun e1 e2 => exists p, proxy P e1 p /\ proxy P e2 p)
                              (fun e1 e2 => exists p, proxy K e1 p /\ proxy K e2 p).
Proof. intros x y [p [H1 H2]]; exists p; rewrite !(proxy_ev HL); auto. Qed.

(** The reads that read from no write are the same. *)
Lemma r_codom_rf : srfl ev (codom_rel (⦗Write P⦘ ⨾ rf P)) (codom_rel (⦗Write K⦘ ⨾ rf K)).
Proof.
  intros r [k [k' [[<- Hw] Hrf]]]; destruct (Write_image HL Hw) as [w <-].
  exists w, w; split; [split; [reflexivity | apply (Write_ev HL), Hw] | apply (rf_ev HL), Hrf].
Qed.

#[local] Hint Resolve m_rf m_co m_rmw m_dep m_issue m_done m_gdep m_cwait m_txops m_cgen m_synchronizes m_sc
  m_same_location_r m_same_alias_r m_same_cta_r m_same_acc m_same_vacc m_scope_incl_r m_ms_r m_po_plus m_same_proxy
  r_codom_rf : mono.

(** ** The derived relations, in the order of [Ptx87.v] *)

Lemma m_po_loc : mono ev (po_loc P) (po_loc K). Proof. unfold po_loc, same_alias; mono_tac. Qed.
Lemma m_fr : mono ev (fr P) (fr K). Proof. unfold fr; mono_tac. Qed.
#[local] Hint Resolve m_po_loc m_fr : mono.
Lemma m_com : mono ev (com P) (com K). Proof. unfold com; mono_tac. Qed.
Lemma m_rel_pattern : mono ev (rel_pattern P) (rel_pattern K). Proof. unfold rel_pattern; mono_tac. Qed.
Lemma m_acq_pattern : mono ev (acq_pattern P) (acq_pattern K). Proof. unfold acq_pattern; mono_tac. Qed.
Lemma m_obs : mono ev (obs P) (obs K). Proof. unfold obs, strong; mono_tac. Qed.
#[local] Hint Resolve m_com m_rel_pattern m_acq_pattern m_obs : mono.
Lemma m_sync_pattern : mono ev (sync_pattern P) (sync_pattern K). Proof. unfold sync_pattern, strong; mono_tac. Qed.
Lemma m_cluster_sync : mono ev (cluster_sync P) (cluster_sync K). Proof. unfold cluster_sync, strong; mono_tac. Qed.
#[local] Hint Resolve m_sync_pattern m_cluster_sync : mono.
Lemma m_sw : mono ev (sw P) (sw K). Proof. unfold sw; mono_tac. Qed.
#[local] Hint Resolve m_sw : mono.

(** Restricted release and acquire *)
Lemma m_rleft0 : mono ev
  (fun x f => MemoryEvent P x /\ SyncRestrictCta P f
              /\ (forall s, (exists a, address P x a /\ space P a = s) <-> s = SShared)
              /\ (forall o, (exists a, address P x a /\ owner P a o) <-> cta_of P f o))
  (fun x f => MemoryEvent K x /\ SyncRestrictCta K f
              /\ (forall s, (exists a, address K x a /\ space K a = s) <-> s = SShared)
              /\ (forall o, (exists a, address K x a /\ owner K a o) <-> cta_of K f o)).
Proof.
  intros x f [H1 [H2 [H3 H4]]]; split; [apply (MemoryEvent_ev HL), H1 |].
  split; [apply (SyncRestrictCta_ev HL), H2 |]; split.
  - intros s0; rewrite <- H3; split; intros [a [Ha Hs]]; exists a.
    all: rewrite ?(address_ev HL), ?(space_same HL) in *; auto.
  - intros o; rewrite (cta_of_ev HL), <- H4; split; intros [a [Ha Ho]]; exists a.
    all: rewrite ?(address_ev HL), ?(owner_same HL) in *; auto.
Qed.

Lemma m_rright0 : mono ev
  (fun f y => SyncRestrictCluster P f /\ MemoryEvent P y
              /\ (forall s, (exists a, address P y a /\ space P a = s) <-> s = SShared)
              /\ (forall o, (exists a, address P y a /\ owner P a o) -> exists c, cluster_of P f c /\ (subscope P)＊ c o))
  (fun f y => SyncRestrictCluster K f /\ MemoryEvent K y
              /\ (forall s, (exists a, address K y a /\ space K a = s) <-> s = SShared)
              /\ (forall o, (exists a, address K y a /\ owner K a o) -> exists c, cluster_of K f c /\ (subscope K)＊ c o)).
Proof.
  intros f y [H1 [H2 [H3 H4]]]; split; [apply (SyncRestrictCluster_ev HL), H1 |].
  split; [apply (MemoryEvent_ev HL), H2 |]; split.
  - intros s0; rewrite <- H3; split; intros [a [Ha Hs]]; exists a.
    all: rewrite ?(address_ev HL), ?(space_same HL) in *; auto.
  - intros o [a [Ha Ho]]; rewrite (address_ev HL), (owner_same HL) in *.
    destruct (H4 o (ex_intro _ a (conj Ha Ho))) as [c [Hc1 Hc2]].
    exists c; rewrite (cluster_of_ev HL), (subscope_rt_same HL); auto.
Qed.

#[local] Hint Resolve m_rleft0 m_rright0 : mono.

Lemma m_rleft : mono ev (rleft P) (rleft K). Proof. unfold rleft; mono_tac. Qed.
Lemma m_rright : mono ev (rright P) (rright K). Proof. unfold rright; mono_tac. Qed.
#[local] Hint Resolve m_rleft m_rright : mono.

(** Base causality: program order maps into the closure of Kamui's program order. *)
Lemma m_bco_plain : mono ev (bco_plain P) (bco_plain K).
Proof.
  unfold bco_plain.
  set (rK := po K ∪ issue K ∪ done K ∪ gdep K ∪ ((sw K \ (⦗RRel K⦘ ⨾ sw K)) \ (sw K ⨾ ⦗RAcq K⦘))).
  assert (Hx : mono ev ((sw P \ (⦗RRel P⦘ ⨾ sw P)) \ (sw P ⨾ ⦗RAcq P⦘))
                       ((sw K \ (⦗RRel K⦘ ⨾ sw K)) \ (sw K ⨾ ⦗RAcq K⦘))) by mono_tac.
  assert (G : forall x y, (po P ∪ issue P ∪ done P ∪ gdep P ∪ ((sw P \ (⦗RRel P⦘ ⨾ sw P)) \ (sw P ⨾ ⦗RAcq P⦘))) x y ->
                          rK⁺ (ev x) (ev y)).
  { intros x y [[[[Hp | Hi] | Hd] | Hg] | Hs].
    - eapply clos_trans_mori; [| exact (m_po_plus (t_step _ _ _ _ Hp))].
      intros a b Hab; unfold rK; left; left; left; left; exact Hab.
    - apply t_step; unfold rK; left; left; left; right; apply m_issue, Hi.
    - apply t_step; unfold rK; left; left; right; apply m_done, Hd.
    - apply t_step; unfold rK; left; right; apply m_gdep, Hg.
    - apply t_step; unfold rK; right; apply Hx, Hs. }
  intros x y H; induction H as [x y H | x y z _ IH1 _ IH2]; [apply G, H | eapply t_trans; eauto].
Qed.
#[local] Hint Resolve m_bco_plain : mono.

Lemma m_sw_restricted : mono ev (sw_restricted P) (sw_restricted K). Proof. unfold sw_restricted; mono_tac. Qed.
#[local] Hint Resolve m_sw_restricted : mono.

Lemma m_cause_base : mono ev (cause_base P) (cause_base K). Proof. unfold cause_base; cbv zeta; mono_tac. Qed.
#[local] Hint Resolve m_cause_base : mono.

(** Proxy fences *)
Lemma m_pf_space_ok : mono ev (pf_space_ok P) (pf_space_ok K).
Proof.
  intros f m [H1 [H2 [H3 H4]]]; split; [apply (ProxyFence_ev HL), H1 |]; split; [apply (MemoryEvent_ev HL), H2 |].
  split.
  - destruct H3 as [H3 | H3]; [left; intros s0; rewrite (pspace_ev HL); apply H3 |].
    right; intros a Ha; rewrite (address_ev HL) in Ha; rewrite (pspace_ev HL), (space_same HL); apply H3, Ha.
  - destruct H4 as [H4 | H4]; [left; intros a; rewrite (paddr_ev HL); apply H4 |].
    right; intros a Ha; rewrite (address_ev HL) in Ha; rewrite (paddr_ev HL); apply H4, Ha.
Qed.

Lemma m_pf_src0 : mono ev
  (fun m f => MemoryEvent P m /\ ProxyFence P f /\ (forall p, proxy P m p -> dirs P f p Generic))
  (fun m f => MemoryEvent K m /\ ProxyFence K f /\ (forall p, proxy K m p -> dirs K f p Generic)).
Proof.
  intros m f [H1 [H2 H3]]; split; [apply (MemoryEvent_ev HL), H1 |]; split; [apply (ProxyFence_ev HL), H2 |].
  intros p Hp; rewrite (proxy_ev HL) in Hp; rewrite (dirs_ev HL); apply H3, Hp.
Qed.

Lemma m_pf_dst0 : mono ev
  (fun f m => ProxyFence P f /\ MemoryEvent P m /\ (forall p, proxy P m p -> dirs P f Generic p))
  (fun f m => ProxyFence K f /\ MemoryEvent K m /\ (forall p, proxy K m p -> dirs K f Generic p)).
Proof.
  intros f m [H1 [H2 H3]]; split; [apply (ProxyFence_ev HL), H1 |]; split; [apply (MemoryEvent_ev HL), H2 |].
  intros p Hp; rewrite (proxy_ev HL) in Hp; rewrite (dirs_ev HL); apply H3, Hp.
Qed.
#[local] Hint Resolve m_pf_space_ok m_pf_src0 m_pf_dst0 : mono.

Lemma m_pf_src : mono ev (pf_src P) (pf_src K). Proof. unfold pf_src; mono_tac. Qed.
Lemma m_pf_dst : mono ev (pf_dst P) (pf_dst K). Proof. unfold pf_dst; mono_tac. Qed.
#[local] Hint Resolve m_pf_src m_pf_dst : mono.

Lemma m_pf_dst_with cbP cbK : mono ev cbP cbK -> mono ev (pf_dst_with P cbP) (pf_dst_with K cbK).
Proof. intros H; unfold pf_dst_with; mono_tac. Qed.

Lemma m_ppbco_with cbP cbK : mono ev cbP cbK -> mono ev (ppbco_with P cbP) (ppbco_with K cbK).
Proof.
  intros H; pose proof (m_pf_dst_with H) as Hd.
  unfold ppbco_with, same_alias, same_location; mono_tac.
Qed.

Lemma m_ppbco : mono ev (ppbco P) (ppbco K). Proof. apply m_ppbco_with, m_cause_base. Qed.
#[local] Hint Resolve m_ppbco : mono.

Lemma m_cause : mono ev (cause P) (cause K). Proof. unfold cause; mono_tac. Qed.

(** The relations of the axioms *)
Lemma m_acc_lift rP rK : mono ev rP rK -> mono ev (acc_lift P rP) (acc_lift K rK).
Proof. intros H; unfold acc_lift; mono_tac. Qed.

Lemma m_atomic_pair_r : mono ev (atomic_pair_r P) (atomic_pair_r K).
Proof. unfold atomic_pair_r; mono_tac. Qed.

#[local] Hint Resolve m_cause m_atomic_pair_r m_acc_lift : mono.

(** ** The relations the axioms and facts are about *)

Lemma m_coherence : mono ev (same_location P (⦗Write P⦘ ⨾ cause P ⨾ ⦗Write P⦘))
                            (same_location K (⦗Write K⦘ ⨾ cause K ⨾ ⦗Write K⦘)).
Proof. unfold same_location; mono_tac. Qed.
Lemma m_fence_sc : mono ev (⦗FenceSC P⦘ ⨾ cause_base P ⨾ ⦗FenceSC P⦘) (⦗FenceSC K⦘ ⨾ cause_base K ⨾ ⦗FenceSC K⦘).
Proof. mono_tac. Qed.
Lemma m_atom1 : mono ev ((⦗Read P⦘ ⨾ ms_r P ⨾ ⦗Write P⦘) ∩ (acc_lift P (rf P)⁻¹ ∩ acc_lift P (fr P)))
                        ((⦗Read K⦘ ⨾ ms_r K ⨾ ⦗Write K⦘) ∩ (acc_lift K (rf K)⁻¹ ∩ acc_lift K (fr K))).
Proof. apply mono_inter; [mono_tac | apply mono_inter; apply m_acc_lift; mono_tac]. Qed.
Lemma m_atom2 : mono ev (((fr P ∩ atomic_pair_r P) ⨾ ((co P)⁺ ∩ atomic_pair_r P)) ∩ rmw P)
                        (((fr K ∩ atomic_pair_r K) ⨾ ((co K)⁺ ∩ atomic_pair_r K)) ∩ rmw K).
Proof. mono_tac. Qed.
Lemma m_thin_air : mono ev (rf P ∪ dep P)⁺ (rf K ∪ dep K)⁺. Proof. mono_tac. Qed.
Lemma m_sc_loc : mono ev (strong P (com P) ∪ po_loc P)⁺ (strong K (com K) ∪ po_loc K)⁺.
Proof. unfold strong; mono_tac. Qed.
Lemma m_causality : mono ev ((rf P ∪ fr P) ⨾ cause P) ((rf K ∪ fr K) ⨾ cause K). Proof. mono_tac. Qed.
Lemma m_unordered : mono ev (ms_r P ∪ cause P ∪ (cause P)⁻¹) (ms_r K ∪ cause K ∪ (cause K)⁻¹). Proof. mono_tac. Qed.
Lemma m_co_strong : mono ev (⦗Write P⦘ ⨾ ms_r P ⨾ ⦗Write P⦘) (⦗Write K⦘ ⨾ ms_r K ⨾ ⦗Write K⦘). Proof. mono_tac. Qed.
Lemma m_co_plus : mono ev (co P)⁺ (co K)⁺. Proof. mono_tac. Qed.
Lemma m_sc_plus : mono ev (sc P)⁺ (sc K)⁺. Proof. mono_tac. Qed.
Lemma m_co_ct : mono ev (co P)⁺ (co K)⁺. Proof. mono_tac. Qed.

End Derived.
