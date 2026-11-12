(** * The lowering is correct

    The proofs of the statements of [Theorem.v]. In the setting of [Embedding.v] (a well-formed PTX program,
    a well-formed Kamui execution, a lowering between them):
    - each axiom of Kamui gives the same axiom of PTX, since every relation an axiom forbids grows under the
      lowering ([Derived.v]) and the relations an axiom requires ([co], [sc]) are read back;
    - undefined behaviour and mixed-size races of Kamui are ones of PTX;
    - the facts of the PTX execution follow from those of the Kamui execution ([wf_exec]). *)

From Stdlib Require Import ZArith List.
From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87 Kamui Lowering.
Require Import KamuiProof.Theorem.
From KamuiProof.proof Require Import Embedding Derived.

Set Implicit Arguments.

Section Main.

Context {EP EK S A C : Type} {P : Exec EP S A C} {K : Exec EK S A C} {M : Map EP EK} (HL : setting P K M).

Local Abbreviation ev := (ev M).

(** A cycle of the PTX execution is one of the Kamui execution. *)
Lemma irr_back (rP : relation EP) (rK : relation EK) : mono ev rP rK -> irreflexive rK -> irreflexive rP.
Proof. intros H Hi x Hx; exact (Hi _ (H _ _ Hx)). Qed.

(** ** The axioms *)

Lemma consistent_back : consistent K -> consistent P.
Proof.
  intros [Coh [Fsc [[At1 At2] [Nta [Scl Cau]]]]].
  split; [| split; [| split; [split | split; [| split]]]].
  - intros x y H; apply (co_plus_ev HL), Coh, (m_coherence HL), H.
  - intros x y [Hc Hms]; apply (sc_ev HL); split; [| exact Hms].
    apply Fsc; split; [apply (m_fence_sc HL), Hc | apply (m_ms_r HL), Hms].
  - intros r w H; apply (At1 (ev r) (ev w)), (m_atom1 HL), H.
  - intros r w H; apply (At2 (ev r) (ev w)), (m_atom2 HL), H.
  - apply (irr_back (m_thin_air HL)), Nta.
  - apply (irr_back (m_sc_loc HL)), Scl.
  - apply (irr_back (m_causality HL)), Cau.
Qed.

(** ** Undefined behaviour *)

Lemma undefined_back : undefined K -> undefined P.
Proof.
  unfold undefined, mb_undefined.
  intros [[k [Hr [Hm Hph]]] | [[k [Hw [Hm [Hi Hp]]]] | [k [t [Hw [Ht Hph]]]]]].
  - destruct (Read_image HL Hr) as [e <-]; left; exists e.
    rewrite (Read_ev HL), (MbarEv_ev HL) in *; rewrite (ph_ev HL e Hm) in Hph; auto.
  - destruct (Write_image HL Hw) as [e <-]; right; left; exists e.
    rewrite (Write_ev HL), (MbarEv_ev HL), (MbarInit_ev HL) in *; rewrite (pend_ev HL e Hm) in Hp; auto.
  - assert (Hr : Read K k) by (apply (decl_MbarWait (WFKp HL)), Hw).
    destruct (Read_image HL Hr) as [e <-]; right; right; exists e, t.
    rewrite (MbarWait_ev HL) in Hw.
    assert (Hm : MbarEv P e) by (apply (mbarrier_state_4 (WFP HL)); right; exact Hw).
    rewrite (wtok_ev HL e Hw), (ph_ev HL e Hm) in *; auto.
Qed.

(** ** Mixed-size races *)

Lemma race_back : mixed_size_race K -> mixed_size_race P.
Proof.
  intros [k1 [k2 [Hne [Hm1 [Hm2 [Hsl [Hfp [Hw Hun]]]]]]]].
  destruct (MemoryEvent_image HL Hm1) as [e1 <-], (MemoryEvent_image HL Hm2) as [e2 <-].
  exists e1, e2; split; [intros E; apply Hne; congruence |].
  rewrite (MemoryEvent_ev HL) in Hm1, Hm2; split; [exact Hm1 |]; split; [exact Hm2 |].
  split; [apply (same_location_r_ev HL), Hsl |].
  split.
  - intros Hall; apply Hfp; intros b.
    split; intros [a [Ha Hb]]; rewrite (footprint_ev HL) in Ha; rewrite (aliases_same HL) in Hb.
    + destruct (proj1 (Hall b) (ex_intro _ a (conj Ha Hb))) as [a' [Ha' Hb']].
      exists a'; rewrite (footprint_ev HL), (aliases_same HL); auto.
    + destruct (proj2 (Hall b) (ex_intro _ a (conj Ha Hb))) as [a' [Ha' Hb']].
      exists a'; rewrite (footprint_ev HL), (aliases_same HL); auto.
  - split; [rewrite !(Write_ev HL) in Hw; exact Hw |].
    intros H; apply Hun, (m_unordered HL), H.
Qed.

(** ** The facts of the PTX execution *)

Local Abbreviation WP := (WFP HL).
Local Abbreviation WKp := (WFKp HL).
Local Abbreviation WK := (WFKe HL).

(** An mbarrier has no other address, so a location in the same memory as an mbarrier is the mbarrier. *)
Lemma aliases_Mbar a1 a2 : aliases P a1 a2 -> Mbar P a2 -> a1 = a2.
Proof.
  intros H Hm; apply clos_rt_rtn1_iff in H; destruct H as [| y z Hyz _]; [reflexivity |].
  exfalso; destruct (mbarrier_state_2 WP z y Hm) as [H1 H2]; destruct Hyz as [Hyz | Hyz]; [exact (H1 Hyz) | exact (H2 Hyz)].
Qed.

Lemma address_unique e a a' : address P e a -> address P e a' -> a = a'.
Proof.
  intros H H'; assert (Hm : MemoryEvent P e) by (eapply decl_address; [exact WP | exact H]).
  destruct (decl_address_one WP Hm) as [b [_ Hb]]; rewrite (Hb a H), (Hb a' H'); reflexivity.
Qed.

Lemma MbarEv_address e a : MbarEv P e -> address P e a -> Mbar P a.
Proof.
  intros H Ha; apply (mbarrier_state_1 WP) in H; destruct H as [a' [Ha' Hm]].
  rewrite (address_unique _ _ _ Ha Ha'); exact Hm.
Qed.

Lemma rf_MbarEv w r : rf P w r -> MbarEv P r -> MbarEv P w.
Proof.
  intros Hrf Hm.
  assert (Hsl : same_location_r P w r).
  { apply (same_location_r_ev HL), (communication_1 WK); left; apply (rf_ev HL), Hrf. }
  destruct Hsl as [a1 [a2 [H1 [H2 H3]]]].
  rewrite (aliases_Mbar H2 (MbarEv_address _ _ Hm H3)) in H1.
  apply (mbarrier_state_1 WP); exists a2; split; [exact H1 | exact (MbarEv_address _ _ Hm H3)].
Qed.

Lemma no_rf_K r : ~ (exists w, rf P w r) -> ~ (exists k, rf K k (ev r)).
Proof.
  intros Hno [k Hk]; destruct (rf_images HL _ _ Hk) as [w [r' [<- E]]]; apply (ev_inj HL) in E; subst r'.
  apply Hno; exists w; apply (rf_ev HL), Hk.
Qed.

Lemma ct_transp {T} (r : relation T) x y : r⁻¹⁺ x y -> r⁺ y x.
Proof. intros H; induction H as [x y H | x y z _ IH1 _ IH2]; [apply t_step, H | eapply t_trans; eauto]. Qed.
Lemma ct_transp' {T} (r : relation T) x y : r⁺ y x -> r⁻¹⁺ x y.
Proof. intros H; induction H as [x y H | x y z _ IH1 _ IH2]; [apply t_step, H | eapply t_trans; eauto]. Qed.

(** Counting a set of images: [card_is] carries over through [ev], which is injective. *)
Lemma card_back (sK : EK -> Prop) n : card_is sK n -> (forall k, sK k -> exists e, ev e = k) ->
  card_is (fun e => sK (ev e)) n.
Proof.
  intros [l [Hnd [Hl Hn]]] Him.
  assert (G : forall l : list EK, (forall k, In k l -> exists e, ev e = k) -> exists l', map ev l' = l).
  { induction l0 as [| k l0 IH]; intros H; [exists nil; reflexivity |].
    destruct (H k (or_introl eq_refl)) as [e Ee]; destruct IH as [l' El]; [intros k' Hk'; apply H; right; exact Hk' |].
    exists (e :: l'); simpl; rewrite Ee, El; reflexivity. }
  destruct (G l (fun k Hk => Him k (proj2 (Hl k) Hk))) as [l' El]; subst l.
  exists l'; split; [eapply NoDup_map_inv; exact Hnd |]; split; [| rewrite length_map in Hn; exact Hn].
  intros e; rewrite (Hl (ev e)), in_map_iff; split.
  - intros [e' [E Hin]]; apply (ev_inj HL) in E; subst; exact Hin.
  - intros Hin; exists e; auto.
Qed.

Lemma wf_exec_back : wf_exec P.
Proof.
  constructor.
  - (* decl_rf *) intros w r H; apply (rf_ev HL) in H; destruct (decl_rf WK _ _ H) as [H1 H2].
    rewrite (Write_ev HL), (Read_ev HL) in *; auto.
  - (* decl_co *) intros w w' H; apply (co_ev HL) in H; destruct (decl_co WK _ _ H) as [H1 H2].
    rewrite !(Write_ev HL) in *; auto.
  - (* decl_sc *) intros f f' H; apply (sc_ev HL) in H; destruct (decl_sc WK _ _ (proj1 H)) as [H1 H2].
    rewrite !(FenceSC_ev HL) in *; auto.
  - (* decl_bgen *) intros a b H; apply (bgen_ev HL) in H; destruct (decl_bgen WK _ _ H) as [H1 H2].
    rewrite !(BarrierArrive_ev HL) in *; auto.
  - (* decl_synchronizes *) intros a w H; apply (synchronizes_ev HL) in H.
    destruct (decl_synchronizes WK _ _ H) as [H1 H2]; rewrite (BarrierArrive_ev HL), (BarrierWait_ev HL) in *; auto.
  - (* decl_cgen *) intros a b H; apply (cgen_ev HL) in H; destruct (decl_cgen WK _ _ H) as [H1 H2].
    rewrite !(ClusterArrive_ev HL) in *; auto.
  - (* mbarrier_state_3 *) intros r Hr Hm.
    assert (HrK : Read K (ev r)) by (apply (Read_ev HL), Hr).
    assert (HmK : MbarEv K (ev r)) by (apply (MbarEv_ev HL), Hm).
    destruct (mbarrier_state_3 WK HrK HmK) as [K1 K2]; split.
    + intros _ w Hrf.
      assert (Hmw : MbarEv P w) by exact (rf_MbarEv _ _ Hrf Hm).
      assert (HrfK : rf K (ev w) (ev r)) by (apply (rf_ev HL), Hrf).
      destruct (K1 (ex_intro (fun k => rf K k (ev r)) (ev w) HrfK) _ HrfK) as [E1 [E2 [E3 E4]]].
      rewrite (ph_ev HL r Hm), (ph_ev HL w Hmw), (pend_ev HL r Hm), (pend_ev HL w Hmw), (expc_ev HL r Hm),
        (expc_ev HL w Hmw), (tx_ev HL r Hm), (tx_ev HL w Hmw) in *; auto.
    + intros Hno a Ha.
      assert (HaK : address K (ev r) a) by (apply (address_ev HL), Ha).
      assert (Hma : Mbar P a) by exact (MbarEv_address _ _ Hm Ha).
      destruct (K2 (no_rf_K _ Hno) a HaK) as [E1 [E2 [E3 E4]]].
      rewrite (ph_ev HL r Hm), (pend_ev HL r Hm), (expc_ev HL r Hm), (tx_ev HL r Hm), (sl_iph (LL HL) a Hma),
        (sl_ipend (LL HL) a Hma), (sl_iexp (LL HL) a Hma), (sl_itx (LL HL) a Hma) in *; auto.
  - (* mbarrier_state_5 *) intros w Hw.
    assert (Hm : MbarEv P w) by (apply (mbarrier_state_4 WP); left; exact Hw).
    destruct (mbarrier_state_5 WK (ev w) (proj2 (MbarInit_ev HL w) Hw)) as [E1 [E2 E3]].
    rewrite (ph_ev HL w Hm), (tx_ev HL w Hm), (pend_ev HL w Hm), (expc_ev HL w Hm) in *; auto.
  - (* communication_1 *) intros x y H; apply (same_location_r_ev HL), (communication_1 WK).
    destruct H as [H | H]; [left; apply (rf_ev HL), H | right; apply (co_ev HL), H].
  - (* communication_2 *) intros w1 w2 r H1 H2; apply (ev_inj HL).
    apply (communication_2 WK _ _ (ev r)); apply (rf_ev HL); assumption.
  - (* communication_3 *) intros r Hr.
    assert (HrK : Read K (ev r)) by (apply (Read_ev HL), Hr).
    destruct (communication_3 WK HrK) as [K1 K2]; split.
    + intros _ w Hrf; assert (HrfK : rf K (ev w) (ev r)) by (apply (rf_ev HL), Hrf).
      assert (Hmw : MemoryEvent P w) by (apply (MemoryEvent_ev HL); right; exact (proj1 (decl_rf WK _ _ HrfK))).
      assert (Hmr : MemoryEvent P r) by (left; exact Hr).
      rewrite <- (val_ev HL Hmr), <- (val_ev HL Hmw); apply (K1 (ex_intro (fun k => rf K k (ev r)) (ev w) HrfK) _ HrfK).
    + intros Hno a Ha; assert (Hmr : MemoryEvent P r) by (left; exact Hr).
      rewrite <- (val_ev HL Hmr), <- (init_same HL); apply (K2 (no_rf_K _ Hno) a), (address_ev HL), Ha.
  - (* communication_4 *) apply (irr_back (m_co_plus HL)), (communication_4 WK).
  - (* co_strong_1 *) intros x y H; apply (m_co_strong HL), (co_strong_1 WK) in H.
    destruct H as [H | H]; [left; apply (co_plus_ev HL), H |].
    right; apply ct_transp', (co_plus_ev HL), ct_transp, H.
  - (* co_strong_2 *) intros c1 c2 [[w1 [w2 [H1 [H2 H3]]]] [w3 [w4 [H4 [H5 H6]]]]].
    apply (co_strong_2 WK c1 c2); split.
    + exists (ev w1), (ev w2); rewrite !(acc_ev HL); split; [exact H1 |]; split; [apply (m_co_plus HL), H2 | exact H3].
    + exists (ev w3), (ev w4); rewrite !(acc_ev HL); split; [exact H4 |]; split; [apply (m_co_plus HL), H5 | exact H6].
  - (* co_strong_3 *) intros c1 c2 [[w1 [w2 [H1 [H2 H3]]]] [w3 [w4 [H4 [H5 H6]]]]].
    apply (co_strong_3 WK c1 c2); split.
    + exists (ev w1), (ev w2); rewrite !(vacc_ev HL); split; [exact H1 |]; split; [apply (m_co_plus HL), H2 | exact H3].
    + exists (ev w3), (ev w4); rewrite !(vacc_ev HL); split; [exact H4 |]; split; [apply (m_co_plus HL), H5 | exact H6].
  - (* fence_sc_order_1 *) intros f1 f2 H1 H2 Hne Hms.
    assert (HK : sc K (ev f1) (ev f2) \/ sc K (ev f2) (ev f1)).
    { apply (fence_sc_order_1 WK); [apply (FenceSC_ev HL), H1 | apply (FenceSC_ev HL), H2 | | apply (m_ms_r HL), Hms].
      intros E; apply Hne, (ev_inj HL), E. }
    destruct HK as [HK | HK]; [left | right]; apply (sc_ev HL); split; auto; apply ms_r_sym, Hms.
  - (* fence_sc_order_2 *) intros x y H; apply (sc_ev HL) in H; apply H.
  - (* fence_sc_order_3 *) apply (irr_back (m_sc_plus HL)), (fence_sc_order_3 WK).
  - (* barriers_3 *) destruct (barriers_3 WK) as [B1 B2]; split; intros x y H; apply (bgen_ev HL) in H;
      apply (bgen_ev HL); [apply B1, H | apply B2, H].
  - (* barriers_4 *) intros a H; apply (bgen_ev HL), (barriers_4 WK), (BarrierArrive_ev HL), H.
  - (* barriers_5 *) intros a c [b [H1 H2]]; apply (bgen_ev HL), (barriers_5 WK); exists (ev b).
    split; apply (bgen_ev HL); assumption.
  - (* barriers_6 *) intros a b H; apply (bgen_ev HL), (barriers_6 WK) in H; destruct H as [H1 [H2 [H3 H4]]].
    split; [apply (same_cta_r_ev HL), H1 |]; rewrite (BarrierArrive_ev HL) in H2, H3.
    split; [exact H2 |]; split; [exact H3 |]; rewrite <- (bid_ev HL H2), <- (bid_ev HL H3); exact H4.
  - (* barriers_7 *) intros a b [H1 H2]; eapply (barriers_7 WK); split.
    + apply (m_po_plus HL), H1.
    + apply (bgen_ev HL), H2.
  - (* barriers_8 *) apply (irr_back (rK := (bgen K ⨾ ((po K)⁺ ∩ same_bid K))⁺)), (barriers_8 WK).
    apply mono_ct, mono_seq; [apply exact_mono, (bgen_ev HL) | apply mono_inter; [apply (m_po_plus HL) |]].
    intros a b [H1 [H2 H3]]; split; [apply (BarrierArrive_ev HL), H1 |]; split; [apply (BarrierArrive_ev HL), H2 |].
    rewrite (bid_ev HL H1), (bid_ev HL H2); exact H3.
  - (* barriers_9 *) intros a n Ha Hn.
    assert (HaK : BarrierArrive K (ev a)) by (apply (BarrierArrive_ev HL), Ha).
    pose proof (barriers_9 WK HaK (eq_trans (bcount_ev HL Ha) Hn)) as Hc.
    assert (E : forall b, bgen K (ev a) (ev b) <-> bgen P a b) by (intros b; apply (bgen_ev HL)).
    destruct (card_back Hc) as [l [Hnd [Hl Hlen]]].
    + intros k Hk; apply (BarrierArrive_image HL), (proj2 (decl_bgen WK _ _ Hk)).
    + exists l; split; [exact Hnd |]; split; [intros b; rewrite <- E; apply Hl | exact Hlen].
  - (* barriers_10 *) intros a Ha Hn t.
    assert (HaK : BarrierArrive K (ev a)) by (apply (BarrierArrive_ev HL), Ha).
    pose proof (barriers_10 WK HaK (eq_trans (bcount_ev HL Ha) Hn) t) as [B1 B2]; split.
    + intros [b [H1 H2]]; destruct (B1 (ex_intro _ (ev b) (conj (proj2 (bgen_ev HL a b) H1)
                                                         (proj2 (thd_ev HL b t) H2)))) as [Ht [k [Hk1 [Hk2 [Hk3 Hk4]]]]].
      destruct (BarrierArrive_image HL Hk1) as [b' <-]; rewrite (BarrierArrive_ev HL) in Hk1.
      split; [apply (Thread_same HL), Ht |]; exists b'; split; [exact Hk1 |]; split; [apply (thd_ev HL), Hk2 |].
      split; [rewrite <- (bid_ev HL Hk1), <- (bid_ev HL Ha); exact Hk3 | apply (same_cta_r_ev HL), Hk4].
    + intros [Ht [b [Hb1 [Hb2 [Hb3 Hb4]]]]].
      destruct B2 as [k [Hk1 Hk2]].
      { split; [apply (Thread_same HL), Ht |]; exists (ev b); split; [apply (BarrierArrive_ev HL), Hb1 |].
        split; [apply (thd_ev HL), Hb2 |]; split; [rewrite (bid_ev HL Hb1), (bid_ev HL Ha); exact Hb3 |].
        apply (same_cta_r_ev HL), Hb4. }
      destruct (BarrierArrive_image HL (proj2 (decl_bgen WK _ _ Hk1))) as [b' <-].
      exists b'; split; [apply (bgen_ev HL), Hk1 | apply (thd_ev HL), Hk2].
  - (* barriers_11 *) destruct (barriers_11 WK) as [B1 B2]; split.
    + intros a w H; apply (synchronizes_ev HL), B1 in H; destruct H as [k [H1 H2]].
      destruct (BarrierArrive_image HL (proj2 (decl_bgen WK _ _ H1))) as [b <-].
      exists b; split; [apply (bgen_ev HL), H1 | apply (bwait_ev HL), H2].
    + intros a w [b [H1 H2]]; apply (synchronizes_ev HL), B2; exists (ev b).
      split; [apply (bgen_ev HL), H1 | apply (bwait_ev HL), H2].
  - (* cluster_barriers_4 *) destruct (cluster_barriers_4 WK) as [B1 B2]; split; intros x y H; apply (cgen_ev HL) in H;
      apply (cgen_ev HL); [apply B1, H | apply B2, H].
  - (* cluster_barriers_5 *) intros a H; apply (cgen_ev HL), (cluster_barriers_5 WK), (ClusterArrive_ev HL), H.
  - (* cluster_barriers_6 *) intros a c [b [H1 H2]]; apply (cgen_ev HL), (cluster_barriers_6 WK); exists (ev b).
    split; apply (cgen_ev HL); assumption.
  - (* cluster_barriers_7 *) intros a b H; apply (cgen_ev HL), (cluster_barriers_7 WK) in H.
    destruct H as [c [H1 H2]]; exists c; rewrite (cluster_of_ev HL) in *; auto.
  - (* cluster_barriers_8 *) intros a b [H1 H2]; eapply (cluster_barriers_8 WK); split.
    + apply (m_po_plus HL), H1.
    + apply (cgen_ev HL), H2.
  - (* cluster_barriers_9 *) apply (irr_back (rK := (cgen K ⨾ (po K)⁺)⁺)), (cluster_barriers_9 WK).
    apply mono_ct, mono_seq; [apply exact_mono, (cgen_ev HL) | apply (m_po_plus HL)].
  - (* cluster_barriers_10 *) intros a Ha t.
    pose proof (cluster_barriers_10 WK (proj2 (ClusterArrive_ev HL a) Ha) t) as [B1 B2]; split.
    + intros [b [H1 H2]].
      destruct (B1 (ex_intro _ (ev b) (conj (proj2 (cgen_ev HL a b) H1) (proj2 (thd_ev HL b t) H2))))
        as [[c [Hc1 Hc2]] [Ht Hu]].
      split; [exists c; rewrite (cluster_of_ev HL), (subscope_rt_same HL) in *; auto |].
      rewrite (Thread_same HL), (AsyncUnit_same HL) in *; auto.
    + intros [[c [Hc1 Hc2]] [Ht Hu]].
      destruct B2 as [k [Hk1 Hk2]].
      { split; [exists c; rewrite (cluster_of_ev HL), (subscope_rt_same HL); auto |].
        rewrite (Thread_same HL), (AsyncUnit_same HL); auto. }
      destruct (ClusterArrive_image HL (proj2 (decl_cgen WK _ _ Hk1))) as [b <-].
      exists b; split; [apply (cgen_ev HL), Hk1 | apply (thd_ev HL), Hk2].
Qed.

End Main.

(** ** The statements of [Theorem.v] *)

Theorem lowering_correct : execution_level_statement.
Proof.
  intros EP EK S A C P K M WP L WK.
  assert (HL : setting P K M) by (split; [exact WP | split; [exact WK | exact L]]).
  split; [exact (wf_exec_back HL) |].
  split; [exact (consistent_back HL) |].
  split; [exact (undefined_back HL) | exact (race_back HL)].
Qed.

Theorem lowering_correct_programs : program_level_statement.
Proof.
  intros EP EK S A C progP outP progK outK HP HK
         [[X [Hp [Hwf [Hc Ho]]]] | [[X [Hp [Hwf [Hc Hr]]]] [Y [Hq [Hwf' Ho]]]]].
  - destruct (HK X Hp Hwf) as [P0 [M0 [HP0 [L0 Hout]]]].
    destruct (lowering_correct (HP P0 HP0) L0 Hwf) as [We [Cn [Ud _]]].
    left; exists P0; split; [exact HP0 |]; split; [split; [exact (HP P0 HP0) | exact We] |].
    split; [exact (Cn Hc) |]; destruct Ho as [Ho | Ho]; [left; exact (Hout Ho) | right; exact (Ud Ho)].
  - destruct (HK X Hp Hwf) as [P0 [M0 [HP0 [L0 _]]]].
    destruct (HK Y Hq Hwf') as [P1 [M1 [HP1 [L1 Hout]]]].
    destruct (lowering_correct (HP P0 HP0) L0 Hwf) as [We0 [Cn0 [_ Rc0]]].
    destruct (lowering_correct (HP P1 HP1) L1 Hwf') as [We1 _].
    right; split.
    + exists P0; split; [exact HP0 |]; split; [split; [exact (HP P0 HP0) | exact We0] |].
      split; [exact (Cn0 Hc) | exact (Rc0 Hr)].
    + exists P1; split; [exact HP1 |]; split; [split; [exact (HP P1 HP1) | exact We1] | exact (Hout Ho)].
Qed.
