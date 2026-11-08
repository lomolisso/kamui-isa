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

End Main.
