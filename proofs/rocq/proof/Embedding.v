(** * What a lowering preserves, event by event

    Throughout: a well-formed PTX program [P], a well-formed Kamui execution [K] and a lowering [M] from [P] to
    [K] ([lowering P K M]). This file shows what the lowering keeps on the image [ev e] of each PTX event [e]: its
    kind and every set of the model, its thread, its location, its footprint; its scope is the same or an
    enclosing one. A Kamui event that is no image is a fence inserted before an image ([pre]): a [FenceSC]. *)

From Stdlib Require Import ZArith.
From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87 Kamui Lowering.

Set Implicit Arguments.

(** The setting of the whole proof: the hypotheses of the statement. *)
Definition setting {EP EK S A C} (P : Exec EP S A C) (K : Exec EK S A C) (M : Map EP EK) : Prop :=
  wf_prog P /\ wf K /\ lowering P K M.

Section Embedding.

Context {EP EK S A C : Type} {P : Exec EP S A C} {K : Exec EK S A C} {M : Map EP EK} (HL : setting P K M).

Lemma WFP : wf_prog P. Proof. apply HL. Qed.
Lemma WFK : wf K. Proof. apply HL. Qed.
Lemma L : lowering P K M. Proof. apply HL. Qed.

Local Abbreviation ev := (ev M).
Local Abbreviation pre := (pre M).

Lemma WFKp : wf_prog K. Proof. apply WFK. Qed.
Lemma WFKe : wf_exec K. Proof. apply WFK. Qed.

Lemma LB : bijections M. Proof. apply L. Qed.
Lemma LT : same_scope_tree P K. Proof. apply L. Qed.
Lemma LL : same_locations P K. Proof. apply L. Qed.
Lemma LO : same_order P K M. Proof. apply L. Qed.
Lemma LK : kinds P K M ∅. Proof. apply L. Qed.
Lemma LR : same_relations P K M ∅ ∅. Proof. apply L. Qed.
Lemma LX : proxies P K M. Proof. apply L. Qed.
Lemma LS : scopes P K M ∅. Proof. apply L. Qed.
Lemma LI : inserted P M. Proof. apply L. Qed.
Lemma LRB : read_back P K M. Proof. apply L. Qed.
Lemma Lrelax e : ~ relax M e. Proof. apply L. Qed.

Lemma nx (e : EP) : ~ (∅ : EP -> Prop) e. Proof. intros H; exact H. Qed.

(** ** Events *)

Lemma ev_inj e1 e2 : ev e1 = ev e2 -> e1 = e2. Proof. apply LB. Qed.

Lemma pre_inj e1 e2 f : pre e1 = Some f -> pre e2 = Some f -> e1 = e2. Proof. apply LB. Qed.

Lemma pre_not_ev e e' : pre e' <> Some (ev e). Proof. apply LB. Qed.

Lemma onto k : (exists e, ev e = k) \/ (exists e, pre e = Some k). Proof. apply LB. Qed.

Lemma kind_ev e : kind K (ev e) = kind P e. Proof. apply LK, nx. Qed.

Lemma kind_pre e f : pre e = Some f -> kind K f = KFenceSC. Proof. apply LK. Qed.

(** A Kamui event of any kind but [FenceSC] is an image. *)
Lemma image_of k : kind K k <> KFenceSC -> exists e, ev e = k.
Proof.
  intros H; destruct (onto k) as [Hk | [e Hk]]; [exact Hk |].
  exfalso; apply H; eapply kind_pre; eauto.
Qed.

(** Every set of the model defined from [kind] is the same on an image. *)
Ltac kind_exact := intros e; unfold MemoryEvent, Fence, Barrier; unfold Read, Acquire, Write, Release, FenceAcq,
  FenceRel, FenceSC, FenceAcqRel, AliasFence, PlainProxyFence, BarrierArrive, BarrierWait, ClusterArrive,
  ClusterWait, Marker; rewrite kind_ev; reflexivity.

Lemma Read_ev : forall e, Read K (ev e) <-> Read P e. Proof. kind_exact. Qed.
Lemma Acquire_ev : forall e, Acquire K (ev e) <-> Acquire P e. Proof. kind_exact. Qed.
Lemma Write_ev : forall e, Write K (ev e) <-> Write P e. Proof. kind_exact. Qed.
Lemma Release_ev : forall e, Release K (ev e) <-> Release P e. Proof. kind_exact. Qed.
Lemma MemoryEvent_ev : forall e, MemoryEvent K (ev e) <-> MemoryEvent P e. Proof. kind_exact. Qed.
Lemma FenceAcq_ev : forall e, FenceAcq K (ev e) <-> FenceAcq P e. Proof. kind_exact. Qed.
Lemma FenceRel_ev : forall e, FenceRel K (ev e) <-> FenceRel P e. Proof. kind_exact. Qed.
Lemma FenceSC_ev : forall e, FenceSC K (ev e) <-> FenceSC P e. Proof. kind_exact. Qed.
Lemma FenceAcqRel_ev : forall e, FenceAcqRel K (ev e) <-> FenceAcqRel P e. Proof. kind_exact. Qed.
Lemma Fence_ev : forall e, Fence K (ev e) <-> Fence P e. Proof. kind_exact. Qed.
Lemma AliasFence_ev : forall e, AliasFence K (ev e) <-> AliasFence P e. Proof. kind_exact. Qed.
Lemma PlainProxyFence_ev : forall e, PlainProxyFence K (ev e) <-> PlainProxyFence P e. Proof. kind_exact. Qed.
Lemma BarrierArrive_ev : forall e, BarrierArrive K (ev e) <-> BarrierArrive P e. Proof. kind_exact. Qed.
Lemma BarrierWait_ev : forall e, BarrierWait K (ev e) <-> BarrierWait P e. Proof. kind_exact. Qed.
Lemma Barrier_ev : forall e, Barrier K (ev e) <-> Barrier P e. Proof. kind_exact. Qed.
Lemma ClusterArrive_ev : forall e, ClusterArrive K (ev e) <-> ClusterArrive P e. Proof. kind_exact. Qed.
Lemma ClusterWait_ev : forall e, ClusterWait K (ev e) <-> ClusterWait P e. Proof. kind_exact. Qed.
Lemma Marker_ev : forall e, Marker K (ev e) <-> Marker P e. Proof. kind_exact. Qed.

Lemma SyncRestrictCta_ev e : SyncRestrictCta K (ev e) <-> SyncRestrictCta P e. Proof. apply LK, nx. Qed.
Lemma SyncRestrictCluster_ev e : SyncRestrictCluster K (ev e) <-> SyncRestrictCluster P e. Proof. apply LK, nx. Qed.
Lemma OpRestrictInit_ev e : OpRestrictInit K (ev e) <-> OpRestrictInit P e. Proof. apply LK, nx. Qed.
Lemma ClusterArriveRelaxed_ev e : ClusterArriveRelaxed K (ev e) <-> ClusterArriveRelaxed P e. Proof. apply LK, nx. Qed.
Lemma MbarInit_ev e : MbarInit K (ev e) <-> MbarInit P e. Proof. apply LK, nx. Qed.
Lemma MbarWait_ev e : MbarWait K (ev e) <-> MbarWait P e. Proof. apply LK, nx. Qed.
Lemma TxAnchor_ev e : TxAnchor K (ev e) <-> TxAnchor P e. Proof. apply LK, nx. Qed.
Lemma ProxyFence_ev e : ProxyFence K (ev e) <-> ProxyFence P e. Proof. apply LK, nx. Qed.

(** Reads and writes are images. *)
Lemma MemoryEvent_image k : MemoryEvent K k -> exists e, ev e = k.
Proof.
  intros H; apply image_of; intros E; unfold MemoryEvent, Read, Write, FenceSC in *; rewrite E in H.
  intuition discriminate.
Qed.

Lemma Read_image k : Read K k -> exists e, ev e = k.
Proof. intros H; apply MemoryEvent_image; left; exact H. Qed.
Lemma Write_image k : Write K k -> exists e, ev e = k.
Proof. intros H; apply MemoryEvent_image; right; exact H. Qed.
Lemma BarrierArrive_image k : BarrierArrive K k -> exists e, ev e = k.
Proof. intros H; apply image_of; unfold BarrierArrive in H; congruence. Qed.
Lemma BarrierWait_image k : BarrierWait K k -> exists e, ev e = k.
Proof. intros H; apply image_of; unfold BarrierWait in H; congruence. Qed.
Lemma ClusterArrive_image k : ClusterArrive K k -> exists e, ev e = k.
Proof. intros H; apply image_of; unfold ClusterArrive in H; congruence. Qed.

(** ** Relations of the program *)

Lemma collect_ev (r : relation EP) x y : (ev ↑ r) (ev x) (ev y) <-> r x y.
Proof.
  split.
  - intros [x' [y' [H [Ex Ey]]]]; apply ev_inj in Ex; apply ev_inj in Ey; subst; exact H.
  - intros H; exists x, y; auto.
Qed.

Lemma collect_same (rK : relation EK) (rP : relation EP) : rK ≡ ev ↑ rP -> forall x y, rK (ev x) (ev y) <-> rP x y.
Proof. intros [H1 H2] x y; split; intros H; [apply collect_ev, H1, H | apply H2, collect_ev, H]. Qed.

Lemma collect_images (rK : relation EK) (rP : relation EP) : rK ≡ ev ↑ rP ->
  forall k1 k2, rK k1 k2 -> exists x y, ev x = k1 /\ ev y = k2 /\ rP x y.
Proof. intros [H1 _] k1 k2 H; destruct (H1 _ _ H) as [x [y [Hr [E1 E2]]]]; exists x, y; auto. Qed.

Lemma rmw_ev x y : rmw K (ev x) (ev y) <-> rmw P x y. Proof. apply collect_same, LR. Qed.
Lemma dep_ev x y : dep K (ev x) (ev y) <-> dep P x y. Proof. apply collect_same, LR. Qed.
Lemma done_ev x y : done K (ev x) (ev y) <-> done P x y. Proof. apply collect_same, LR. Qed.
Lemma gdep_ev x y : gdep K (ev x) (ev y) <-> gdep P x y. Proof. apply collect_same, LR. Qed.
Lemma bwait_ev x y : bwait K (ev x) (ev y) <-> bwait P x y. Proof. apply collect_same, LR. Qed.
Lemma cwait_ev x y : cwait K (ev x) (ev y) <-> cwait P x y. Proof. apply collect_same, LR. Qed.
Lemma txops_ev x y : txops K (ev x) (ev y) <-> txops P x y. Proof. apply collect_same, LR. Qed.

Lemma issue_same : issue K ≡ ev ↑ issue P.
Proof.
  rewrite (sr_issue LR); split; [apply collect_rel_mori; [reflexivity | basic_solver] |].
  apply collect_rel_mori; [reflexivity |]; intros x y H; exists x; split; [split; [reflexivity | apply nx] | exact H].
Qed.
Lemma issue_ev x y : issue K (ev x) (ev y) <-> issue P x y. Proof. apply collect_same, issue_same. Qed.

Lemma address_ev e a : address K (ev e) a <-> address P e a.
Proof.
  rewrite (sr_address LR); split; [intros [e' [E H]]; apply ev_inj in E; subst; exact H | intros H; exists e; auto].
Qed.
Lemma address_image k a : address K k a -> exists e, ev e = k.
Proof. rewrite (sr_address LR); intros [e [E _]]; exists e; exact E. Qed.

Lemma acc_ev e c : acc K (ev e) c <-> acc P e c.
Proof. rewrite (sr_acc LR); split; [intros [e' [E H]]; apply ev_inj in E; subst; exact H | intros H; exists e; auto]. Qed.
Lemma acc_image k c : acc K k c -> exists e, ev e = k.
Proof. rewrite (sr_acc LR); intros [e [E _]]; exists e; exact E. Qed.

Lemma vacc_ev e c : vacc K (ev e) c <-> vacc P e c.
Proof. rewrite (sr_vacc LR); split; [intros [e' [E H]]; apply ev_inj in E; subst; exact H | intros H; exists e; auto]. Qed.
Lemma vacc_image k c : vacc K k c -> exists e, ev e = k.
Proof. rewrite (sr_vacc LR); intros [e [E _]]; exists e; exact E. Qed.

Lemma proxy_ev e p : proxy K (ev e) p <-> proxy P e p.
Proof.
  split; intros H.
  - assert (Hm : MemoryEvent P e) by (apply MemoryEvent_ev; eapply decl_proxy; [apply WFKp | exact H]).
    apply (px_same LX Hm (Lrelax e)), H.
  - assert (Hm : MemoryEvent P e) by (eapply decl_proxy; [apply WFP | exact H]).
    apply (px_same LX Hm (Lrelax e)), H.
Qed.

Lemma pf_fields_ev e : ProxyFence P e ->
  (forall p q, dirs K (ev e) p q <-> dirs P e p q) /\ (forall s, pspace K (ev e) s <-> pspace P e s)
  /\ (forall a, paddr K (ev e) a <-> paddr P e a).
Proof. intros H; eapply (sr_proxy_fence LR); [exact H | apply nx]. Qed.

Lemma dirs_ev e p q : dirs K (ev e) p q <-> dirs P e p q.
Proof.
  split; intros H.
  - assert (Hf : ProxyFence P e) by (apply ProxyFence_ev; eapply decl_dirs; [apply WFKp | exact H]).
    apply (pf_fields_ev e Hf), H.
  - assert (Hf : ProxyFence P e) by (eapply decl_dirs; [apply WFP | exact H]). apply (pf_fields_ev e Hf), H.
Qed.
Lemma pspace_ev e s : pspace K (ev e) s <-> pspace P e s.
Proof.
  split; intros H.
  - assert (Hf : ProxyFence P e) by (apply ProxyFence_ev; eapply decl_pspace; [apply WFKp | exact H]).
    apply (pf_fields_ev e Hf), H.
  - assert (Hf : ProxyFence P e) by (eapply decl_pspace; [apply WFP | exact H]). apply (pf_fields_ev e Hf), H.
Qed.
Lemma paddr_ev e a : paddr K (ev e) a <-> paddr P e a.
Proof.
  split; intros H.
  - assert (Hf : ProxyFence P e) by (apply ProxyFence_ev; eapply decl_paddr; [apply WFKp | exact H]).
    apply (pf_fields_ev e Hf), H.
  - assert (Hf : ProxyFence P e) by (eapply decl_paddr; [apply WFP | exact H]). apply (pf_fields_ev e Hf), H.
Qed.

Lemma bid_ev e : BarrierArrive P e -> bid K (ev e) = bid P e.
Proof. intros H; apply (proj2 (sr_bid LR (ev e) (bid P e))); exists e; auto. Qed.

Lemma bcount_ev e : BarrierArrive P e -> bcount K (ev e) = bcount P e.
Proof.
  intros H; destruct (bcount P e) as [z |] eqn:E.
  - apply (proj2 (sr_bcount LR (ev e) z)); exists e; auto.
  - destruct (bcount K (ev e)) as [z |] eqn:E'; [| reflexivity].
    destruct (proj1 (sr_bcount LR (ev e) z) (conj (proj2 (BarrierArrive_ev e) H) E')) as [e' [Ee [_ Hz]]].
    apply ev_inj in Ee; subst; congruence.
Qed.

Lemma wpar_ev e : MbarWait P e -> wpar K (ev e) = wpar P e.
Proof.
  intros H; destruct (wpar P e) as [z |] eqn:E.
  - apply (proj2 (sr_wpar LR (ev e) z)); exists e; auto.
  - destruct (wpar K (ev e)) as [z |] eqn:E'; [| reflexivity].
    destruct (proj1 (sr_wpar LR (ev e) z) (conj (proj2 (MbarWait_ev e) H) E')) as [e' [Ee [_ Hz]]].
    apply ev_inj in Ee; subst; congruence.
Qed.

Lemma wtok_ev e : MbarWait P e -> wtok K (ev e) = wtok P e.
Proof.
  intros H; destruct (wtok P e) as [z |] eqn:E.
  - apply (proj2 (sr_wtok LR (ev e) z)); exists e; auto.
  - destruct (wtok K (ev e)) as [z |] eqn:E'; [| reflexivity].
    destruct (proj1 (sr_wtok LR (ev e) z) (conj (proj2 (MbarWait_ev e) H) E')) as [e' [Ee [_ Hz]]].
    apply ev_inj in Ee; subst; congruence.
Qed.

(** ** Values and mbarrier states, read back *)

Lemma val_ev e : MemoryEvent P e -> val K (ev e) = val P e.
Proof. intros H; exact (proj2 (proj1 (rb_val LRB e (val P e)) (conj H eq_refl))). Qed.

Lemma MbarEv_ev e : MbarEv K (ev e) <-> MbarEv P e.
Proof.
  rewrite (mbarrier_state_1 WFKp), (mbarrier_state_1 WFP).
  split; intros [a [Ha Hm]]; exists a; split; try (apply address_ev; exact Ha); apply (sl_Mbar LL); exact Hm.
Qed.

Lemma MbarOps_ev e : MbarOps K (ev e) <-> MbarOps P e.
Proof.
  unfold MbarOps; rewrite MbarEv_ev, Write_ev.
  assert (R : (exists r, Read K r /\ rmw K r (ev e)) <-> (exists r, Read P r /\ rmw P r e)).
  { split.
    - intros [k [Hk1 Hk2]]; destruct (Read_image Hk1) as [r <-]; exists r; rewrite <- Read_ev, <- rmw_ev; auto.
    - intros [r [Hr1 Hr2]]; exists (ev r); rewrite Read_ev, rmw_ev; auto. }
  rewrite R; reflexivity.
Qed.

Lemma ph_ev e : MbarEv P e -> ph K (ev e) = ph P e.
Proof. intros H; exact (proj2 (proj1 (rb_ph LRB e (ph P e)) (conj H eq_refl))). Qed.
Lemma pend_ev e : MbarEv P e -> pend K (ev e) = pend P e.
Proof. intros H; exact (proj2 (proj1 (rb_pend LRB e (pend P e)) (conj H eq_refl))). Qed.
Lemma expc_ev e : MbarEv P e -> expc K (ev e) = expc P e.
Proof. intros H; exact (proj2 (proj1 (rb_expc LRB e (expc P e)) (conj H eq_refl))). Qed.
Lemma tx_ev e : MbarEv P e -> tx K (ev e) = tx P e.
Proof. intros H; exact (proj2 (proj1 (rb_tx LRB e (tx P e)) (conj H eq_refl))). Qed.

(** ** The execution, read back *)

Lemma map_same (rK : relation EK) (rP : relation EP) : rP ≡ ev ↓ rK -> forall x y, rK (ev x) (ev y) <-> rP x y.
Proof. intros [H1 H2] x y; split; [apply H2 | apply H1]. Qed.

Lemma rf_ev x y : rf K (ev x) (ev y) <-> rf P x y. Proof. apply map_same, LRB. Qed.
Lemma co_ev x y : co K (ev x) (ev y) <-> co P x y. Proof. apply map_same, LRB. Qed.
Lemma bgen_ev x y : bgen K (ev x) (ev y) <-> bgen P x y. Proof. apply map_same, LRB. Qed.
Lemma cgen_ev x y : cgen K (ev x) (ev y) <-> cgen P x y. Proof. apply map_same, LRB. Qed.
Lemma synchronizes_ev x y : synchronizes K (ev x) (ev y) <-> synchronizes P x y.
Proof. apply map_same, LRB. Qed.
Lemma sc_ev x y : sc P x y <-> sc K (ev x) (ev y) /\ ms_r P x y.
Proof. destruct (rb_sc LRB) as [H1 H2]; split; [apply H1 | apply H2]. Qed.

Lemma rf_images k1 k2 : rf K k1 k2 -> exists x y, ev x = k1 /\ ev y = k2.
Proof.
  intros H; destruct (decl_rf WFKe _ _ H) as [Hw Hr].
  destruct (Write_image Hw) as [x Ex], (Read_image Hr) as [y Ey]; eauto.
Qed.
Lemma co_images k1 k2 : co K k1 k2 -> exists x y, ev x = k1 /\ ev y = k2.
Proof.
  intros H; destruct (decl_co WFKe _ _ H) as [Hw Hw'].
  destruct (Write_image Hw) as [x Ex], (Write_image Hw') as [y Ey]; eauto.
Qed.

(** A relation of Kamui that only relates images: its transitive closure, on images, is that of its PTX
    counterpart (the nodes in between are images too). *)
Lemma ct_target (rK : relation EK) :
  (forall k1 k2, rK k1 k2 -> exists x y, ev x = k1 /\ ev y = k2) ->
  forall k1 k2, rK⁺ k1 k2 -> exists y, ev y = k2.
Proof.
  intros Him k1 k2 H; apply clos_trans_tn1_iff in H; destruct H as [k2 H | k2 k3 H _].
  - destruct (Him _ _ H) as [_ [y [_ E]]]; eauto.
  - destruct (Him _ _ H) as [_ [y [_ E]]]; eauto.
Qed.

Lemma ct_images (rK : relation EK) (rP : relation EP) :
  (forall k1 k2, rK k1 k2 -> exists x y, ev x = k1 /\ ev y = k2) ->
  (forall x y, rK (ev x) (ev y) <-> rP x y) ->
  forall x y, rK⁺ (ev x) (ev y) <-> rP⁺ x y.
Proof.
  intros Him Hr x y; split.
  - intros H.
    assert (G : forall k1 k2, rK⁺ k1 k2 -> forall x y, k1 = ev x -> k2 = ev y -> rP⁺ x y).
    { intros k1 k2 H'; induction H' as [k1 k2 H' | k1 k2 k3 H1 IH1 H2 IH2]; intros x' y' E1 E2; subst.
      - apply t_step, Hr, H'.
      - destruct (ct_target Him H1) as [z Ez].
        apply t_trans with z; [apply IH1 | apply IH2]; auto. }
    exact (G _ _ H x y eq_refl eq_refl).
  - intros H; induction H as [x' y' H | x' y' z' _ IH1 _ IH2]; [apply t_step, Hr, H | eapply t_trans; eauto].
Qed.

Lemma co_plus_ev x y : (co K)⁺ (ev x) (ev y) <-> (co P)⁺ x y.
Proof. apply ct_images; [exact co_images | exact co_ev]. Qed.

(** ** The scope tree and the locations: shared *)

Lemma same_rt {T} (r r' : relation T) : (forall x y, r x y <-> r' x y) -> forall x y, r＊ x y <-> r'＊ x y.
Proof.
  intros E x y; split; intros H; induction H as [x y H | x | x y z _ IH1 _ IH2].
  all: try (apply rt_step, E, H); try apply rt_refl; eapply rt_trans; eauto.
Qed.

Lemma skind_same s : skind K s = skind P s. Proof. apply LT. Qed.
Lemma subscope_same s t : subscope K s t <-> subscope P s t.
Proof. destruct (st_subscope LT) as [H1 H2]; split; [apply H1 | apply H2]. Qed.
Lemma subscope_rt_same s t : (subscope K)＊ s t <-> (subscope P)＊ s t.
Proof. apply same_rt, subscope_same. Qed.

Lemma Thread_same s : Thread K s <-> Thread P s. Proof. unfold Thread; rewrite skind_same; reflexivity. Qed.
Lemma CtaScope_same s : CtaScope K s <-> CtaScope P s. Proof. unfold CtaScope; rewrite skind_same; reflexivity. Qed.
Lemma ClusterScope_same s : ClusterScope K s <-> ClusterScope P s.
Proof. unfold ClusterScope; rewrite skind_same; reflexivity. Qed.
Lemma AsyncUnit_same s : AsyncUnit K s <-> AsyncUnit P s. Proof. unfold AsyncUnit; rewrite skind_same; reflexivity. Qed.
Lemma System_same s : System K s <-> System P s.
Proof. unfold System; split; intros H [p Hp]; apply H; exists p; apply subscope_same; exact Hp. Qed.

Lemma alias_same a b : alias K a b <-> alias P a b.
Proof. destruct (sl_alias LL) as [H1 H2]; split; [apply H1 | apply H2]. Qed.
Lemma space_same a : space K a = space P a. Proof. apply LL. Qed.
Lemma owner_same a s : owner K a s <-> owner P a s. Proof. apply LL. Qed.
Lemma init_same a : init K a = init P a. Proof. apply LL. Qed.
Lemma Mbar_same a : Mbar K a <-> Mbar P a. Proof. apply LL. Qed.

Lemma aliases_same a b : aliases K a b <-> aliases P a b.
Proof. apply same_rt; intros x y; unfold union, transp; rewrite !alias_same; reflexivity. Qed.

Lemma same_alias_r_ev x y : same_alias_r K (ev x) (ev y) <-> same_alias_r P x y.
Proof. unfold same_alias_r; split; intros [a [H1 H2]]; exists a; rewrite ?address_ev in *; auto. Qed.

Lemma same_location_r_ev x y : same_location_r K (ev x) (ev y) <-> same_location_r P x y.
Proof.
  unfold same_location_r; split; intros [a1 [a2 [H1 [H2 H3]]]]; exists a1, a2.
  all: rewrite ?address_ev, ?aliases_same in *; auto.
Qed.

Lemma same_acc_ev x y : same_acc K (ev x) (ev y) <-> same_acc P x y.
Proof. unfold same_acc; split; intros [c [H1 H2]]; exists c; rewrite ?acc_ev in *; auto. Qed.

Lemma same_vacc_ev x y : same_vacc K (ev x) (ev y) <-> same_vacc P x y.
Proof. unfold same_vacc; split; intros [c [H1 H2]]; exists c; rewrite ?vacc_ev in *; auto. Qed.

Lemma footprint_ev x a : footprint K (ev x) a <-> footprint P x a.
Proof.
  unfold footprint; split.
  - intros [k [Hk Ha]]; destruct (@address_image _ _ Ha) as [e Ee]; subst k.
    exists e; rewrite address_ev in Ha; split; [| exact Ha].
    destruct Hk as [Hk | Hk]; [left; apply same_acc_ev, Hk | right; apply ev_inj, Hk].
  - intros [e [He Ha]]; exists (ev e); rewrite address_ev; split; [| exact Ha].
    destruct He as [He | ->]; [left; apply same_acc_ev, He | right; reflexivity].
Qed.

Lemma footprint_aliases_ev x a :
  (exists a', footprint K (ev x) a' /\ aliases K a' a) <-> (exists a', footprint P x a' /\ aliases P a' a).
Proof. split; intros [a' [H1 H2]]; exists a'; rewrite ?footprint_ev, ?aliases_same in *; auto. Qed.

Lemma full_overlap_r_ev x y : full_overlap_r K (ev x) (ev y) <-> full_overlap_r P x y.
Proof.
  unfold full_overlap_r; rewrite !MemoryEvent_ev.
  split; intros [H1 [H2 H3]].
  - split; [exact H1 |]; split; [exact H2 |]; intros a; rewrite <- !footprint_aliases_ev; apply H3.
  - split; [exact H1 |]; split; [exact H2 |]; intros a; rewrite !footprint_aliases_ev; apply H3.
Qed.

Lemma overlap_ok_r_ev x y : overlap_ok_r K (ev x) (ev y) <-> overlap_ok_r P x y.
Proof. unfold overlap_ok_r; rewrite !MemoryEvent_ev, same_location_r_ev, full_overlap_r_ev; reflexivity. Qed.

Lemma proxy_of_ev x p : proxy_of K (ev x) p <-> proxy_of P x p.
Proof. unfold proxy_of; rewrite MemoryEvent_ev, proxy_ev; reflexivity. Qed.

(** ** Program order and threads *)

Lemma po_ev_step x y : po P x y -> (po K)⁺ (ev x) (ev y).
Proof.
  intros H.
  assert (H1 : po K (ev x) (first M y)) by (apply (so_po LO); left; exists x, y; auto).
  unfold first in H1; destruct (pre y) as [f |] eqn:E.
  - apply t_trans with f; apply t_step; [exact H1 |]; apply (so_po LO); right; exists y; auto.
  - apply t_step, H1.
Qed.

Lemma po_plus_ev x y : (po P)⁺ x y -> (po K)⁺ (ev x) (ev y).
Proof. intros H; induction H as [x y H | x y z _ IH1 _ IH2]; [apply po_ev_step, H | eapply t_trans; eauto]. Qed.

Lemma po_rt_ev x y : (po P)＊ x y -> (po K)＊ (ev x) (ev y).
Proof. intros H; apply clos_rt_rt1n_iff in H; induction H as [| x y z H _ IH]; [apply rt_refl |].
  apply rt_trans with (ev y); [apply inclusion_t_rt, po_ev_step, H | exact IH]. Qed.

Lemma first_po e : (po K)＊ (first M e) (ev e).
Proof.
  unfold first; destruct (pre e) as [f |] eqn:E; [| apply rt_refl].
  apply rt_step, (so_po LO); right; exists e; auto.
Qed.

(** From the first Kamui event of a PTX event, program order reaches only images and inserted fences of PTX
    events after it. *)
Lemma po_from_first e0 k : (po K)＊ (first M e0) k ->
  (exists e, ev e = k /\ (po P)＊ e0 e) \/ (exists e, pre e = Some k /\ (po P)＊ e0 e).
Proof.
  intros H; apply clos_rt_rtn1_iff in H; induction H as [| k k' Hk _ IH].
  - unfold first; destruct (pre e0) as [f |] eqn:E; [right | left]; exists e0; split; auto; apply rt_refl.
  - apply (so_po LO) in Hk; destruct Hk as [[e1 [e2 [E1 [Hpo E2]]]] | [e [Ep Ee]]].
    + destruct IH as [[e' [Ee' Hr]] | [e' [Ep' _]]].
      * rewrite <- E1 in Ee'; apply ev_inj in Ee'; subst e'.
        assert (Hr2 : (po P)＊ e0 e2) by (eapply rt_trans; [exact Hr | apply rt_step, Hpo]).
        rewrite <- E2; unfold first; destruct (pre e2) as [f |] eqn:E; [right | left]; exists e2; auto.
      * exfalso; rewrite <- E1 in Ep'; exact (pre_not_ev _ _ Ep').
    + destruct IH as [[e' [Ee' _]] | [e' [Ep' Hr]]].
      * exfalso; rewrite <- Ee' in Ep; exact (pre_not_ev _ _ Ep).
      * left; exists e; split; [exact Ee |]; rewrite (@pre_inj e e' k Ep Ep'); exact Hr.
Qed.

Lemma thd_ev e t : thd K (ev e) t <-> thd P e t.
Proof.
  unfold thd; split.
  - intros [k0 [Hs Hpo]]; apply (so_start LO) in Hs; destruct Hs as [e0 [Hs <-]].
    exists e0; split; [exact Hs |].
    destruct (@po_from_first e0 (ev e) Hpo) as [[e' [E Hr]] | [e' [E _]]].
    + apply ev_inj in E; subst; exact Hr.
    + exfalso; exact (pre_not_ev _ _ E).
  - intros [e0 [Hs Hpo]]; exists (first M e0); split.
    + apply (so_start LO); exists e0; auto.
    + eapply rt_trans; [apply first_po | apply po_rt_ev, Hpo].
Qed.

Lemma cta_of_ev e c : cta_of K (ev e) c <-> cta_of P e c.
Proof.
  unfold cta_of; split; intros [t [H1 [H2 H3]]]; exists t.
  all: rewrite ?thd_ev, ?subscope_rt_same, ?CtaScope_same in *; auto.
Qed.

Lemma cluster_of_ev e c : cluster_of K (ev e) c <-> cluster_of P e c.
Proof.
  unfold cluster_of; split; intros [t [H1 [H2 H3]]]; exists t.
  all: rewrite ?thd_ev, ?subscope_rt_same, ?ClusterScope_same in *; auto.
Qed.

Lemma same_cta_r_ev x y : same_cta_r K (ev x) (ev y) <-> same_cta_r P x y.
Proof. unfold same_cta_r; split; intros [c [H1 H2]]; exists c; rewrite ?cta_of_ev in *; auto. Qed.

(** ** Scopes: the same or an enclosing one *)

Lemma scope_anc e : (subscope P)＊ (scope K (ev e)) (scope P e).
Proof.
  destruct (classic (widen M e)) as [Hw | Hw].
  - apply subscope_rt_same, (sc_widen LS e Hw (@nx e)).
  - rewrite (sc_same LS e Hw (@nx e)); apply rt_refl.
Qed.

(** A thread has no subscope, so the only scope below a thread is the thread itself. *)
Lemma thread_rt_eq (X : Exec EP S A C) s t : wf_prog X -> Thread X s -> (subscope X)＊ s t -> s = t.
Proof.
  intros W Ht H; apply clos_rt_rt1n_iff in H; destruct H as [| x y z Hxy _]; [reflexivity |].
  exfalso; eapply scope_tree_3; eauto.
Qed.

Lemma Weak_ev e : Weak K (ev e) <-> Weak P e.
Proof.
  unfold Weak; rewrite Thread_same.
  destruct (classic (widen M e)) as [Hw | Hw]; [| rewrite (sc_same LS e Hw (@nx e)); reflexivity].
  destruct (sc_widen LS e Hw (@nx e)) as [Hn _]; unfold Weak in Hn; split; [| tauto].
  intros Ht; exfalso; apply Hn.
  rewrite <- (thread_rt_eq WFP Ht (scope_anc e)); exact Ht.
Qed.

Lemma StrongW_ev e : StrongW K (ev e) <-> StrongW P e.
Proof. unfold StrongW; rewrite Write_ev, Weak_ev; reflexivity. Qed.
Lemma StrongR_ev e : StrongR K (ev e) <-> StrongR P e.
Proof. unfold StrongR; rewrite Read_ev, Weak_ev; reflexivity. Qed.

Lemma scope_incl_r_mono x y : scope_incl_r P x y -> scope_incl_r K (ev x) (ev y).
Proof.
  assert (G : forall x y, (exists t, (subscope P)＊ (scope P x) t /\ thd P y t) ->
                          exists t, (subscope K)＊ (scope K (ev x)) t /\ thd K (ev y) t).
  { intros x' y' [t [H1 H2]]; exists t; rewrite thd_ev, subscope_rt_same; split; [| exact H2].
    eapply rt_trans; [apply scope_anc | exact H1]. }
  intros [H1 H2]; split; [apply G, H1 | apply G, H2].
Qed.

Lemma ms_r_mono x y : ms_r P x y -> ms_r K (ev x) (ev y).
Proof.
  intros [H1 [[p [Hp1 Hp2]] [H3 H4]]]; split.
  { destruct H1 as [H1 | [Hm1 Hm2]]; [left; apply scope_incl_r_mono, H1 | right; rewrite !MbarOps_ev; auto]. }
  split; [exists p; rewrite !proxy_of_ev; auto |].
  split; [apply overlap_ok_r_ev, H3 | intros E; apply H4, ev_inj, E].
Qed.

End Embedding.

Lemma aliases_sym {E S A C} (X : Exec E S A C) a b : aliases X a b -> aliases X b a.
Proof.
  unfold aliases; intros H; induction H as [x y H | x | x y z _ IH1 _ IH2].
  - apply rt_step; destruct H as [H | H]; [right | left]; exact H.
  - apply rt_refl.
  - eapply rt_trans; eauto.
Qed.

Lemma ms_r_sym {E S A C} (X : Exec E S A C) x y : ms_r X x y -> ms_r X y x.
Proof.
  intros [H1 [[p [Hp1 Hp2]] [H3 H4]]]; split.
  { destruct H1 as [[Ha Hb] | [Hm1 Hm2]]; [left; split; assumption | right; split; assumption]. }
  split; [exists p; auto |]; split; [| intros Heq; apply H4; congruence].
  unfold overlap_ok_r, full_overlap_r, same_location_r in *.
  destruct H3 as [[Hm1 [Hm2 [[a1 [a2 [Ha1 [Ha2 Ha3]]]] [_ [_ Hf]]]]] | H3]; [left | right; tauto].
  split; [tauto |]; split; [tauto |].
  split; [exists a2, a1; split; [exact Ha3 |]; split; [apply aliases_sym, Ha2 | exact Ha1] |].
  split; [tauto |]; split; [tauto |]; intros b; rewrite Hf; reflexivity.
Qed.
