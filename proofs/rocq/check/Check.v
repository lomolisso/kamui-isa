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

Definition is_some (o : option Z) : bool := match o with Some _ => true | None => false end.
Definition is_none (o : option Z) : bool := match o with Some _ => false | None => true end.

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
Definition d_System : vec := let sub := d_subscope in vmk nS (fun s => negb (existsb (fun p => get sub p s) (List.seq 0 nS))).
Definition d_aliases : mat := mstar nA (munion nA nA d_alias (minv nA nA d_alias)).
Definition d_po_star : mat := mstar n d_po.
Definition d_thd : mat :=
  let st := d_start in let ps := d_po_star in
  mk n nS (fun e t => existsb (fun e0 => get st t e0 && get ps e0 e) (List.seq 0 n)).
Definition d_same_alias_r : mat := mseq n nA n d_address (minv n nA d_address).
Definition d_same_location_r : mat := mseq n nA n (mseq n nA nA d_address d_aliases) (minv n nA d_address).
Definition d_subscope_star : mat := mstar nS d_subscope.
Definition d_cta_of : mat :=
  let th := d_thd in let ss := d_subscope_star in let cs := d_CtaScope in
  mk n nS (fun e c => existsb (fun t => get th e t && get ss c t) (List.seq 0 nS) && vget cs c).
Definition d_same_cta_r : mat := mseq n nS n d_cta_of (minv n nS d_cta_of).
Definition d_cluster_of : mat :=
  let th := d_thd in let ss := d_subscope_star in let cs := d_ClusterScope in
  mk n nS (fun e c => existsb (fun t => get th e t && get ss c t) (List.seq 0 nS) && vget cs c).
Definition d_po_loc : mat := minter n n (mplus n d_po) d_same_alias_r.

Definition d_fr : mat :=
  munion n n (mseq n n n (minv n n d_rf) (mplus n d_co))
    (mseq n n n (mdiag n (vminus n d_Read (vcodom n n (mseq n n n (mdiag n d_Write) d_rf))))
       (mseq n n n d_same_location_r (mdiag n d_Write))).
Definition d_com : mat := munion n n (munion n n d_rf (mplus n d_co)) d_fr.

(** 8.7 Morally strong *)
Definition d_Weak : vec := let th := d_Thread in vmk n (fun e => vget th (scope_at e)).
Definition d_StrongW : vec := vinter n d_Write (vcompl n d_Weak).
Definition d_StrongR : vec := vinter n d_Read (vcompl n d_Weak).
Definition b_proxy_of (mem : vec) (e : nat) (p : Proxy) : bool :=
  (vget mem e && memp (f_proxy F) e p) || (negb (vget mem e) && proxy_eqb p Generic).
Definition d_same_proxy_of : mat :=
  let mem := d_MemoryEvent in mk n n (fun i j => existsb (fun p => b_proxy_of mem i p && b_proxy_of mem j p) all_proxies).
Definition d_same_proxy : mat :=
  mk n n (fun i j => existsb (fun p => memp (f_proxy F) i p && memp (f_proxy F) j p) all_proxies).
Definition d_scope_incl0 : mat :=
  let ss := d_subscope_star in let th := d_thd in
  mk n n (fun i j => existsb (fun t => get ss (scope_at i) t && get th j t) (List.seq 0 nS)).
Definition d_scope_incl_r : mat := minter n n d_scope_incl0 (minv n n d_scope_incl0).
Definition d_same_acc : mat := mseq n nC n d_acc (minv n nC d_acc).
Definition d_footprint : mat := mseq n n nA (mopt n d_same_acc) d_address.
Definition d_full_overlap_r : mat :=
  let mem := d_MemoryEvent in let fp := d_footprint in
  mk n n (fun i j => vget mem i && vget mem j
                     && forallb (fun a => Bool.eqb (get fp i a) (get fp j a)) (List.seq 0 nA)).
Definition d_overlap_ok_r : mat :=
  let mem := d_MemoryEvent in let sa := d_same_alias_r in let fo := d_full_overlap_r in
  mk n n (fun i j => (vget mem i && vget mem j && get sa i j && get fo i j) || negb (vget mem i && vget mem j)).
Definition d_ms_r : mat :=
  let si := d_scope_incl_r in let sp := d_same_proxy_of in let oo := d_overlap_ok_r in
  mk n n (fun i j => get si i j && get sp i j && get oo i j && negb (Nat.eqb i j)).

(** 8.15 mbarrier objects *)
Definition b_wait_true (e : nat) : bool :=
  match oat (f_wpar F) e with Some p => negb (Z.eqb (Z.rem (zat (f_ph F) e) 2) p) | None => false end
  || match oat (f_wtok F) e with Some t => Z.gtb (zat (f_ph F) e) t | None => false end.
Definition d_FalseWaits : vec := let mw := d_MbarWait in vmk n (fun e => vget mw e && negb (b_wait_true e)).
Definition b_mb_undefined : bool :=
  let rd := d_Read in let me := d_MbarEv in let wr := d_Write in let mi := d_MbarInit in let mw := d_MbarWait in
  existsb (fun r => vget rd r && (vget me r && Z.ltb (zat (f_ph F) r) 0)) (List.seq 0 n)
  || (existsb (fun w => vget wr w && (vget me w && (negb (vget mi w) && Z.ltb (zat (f_pend F) w) 0)))
        (List.seq 0 n)
      || existsb (fun r => vget mw r
                           && match oat (f_wtok F) r with Some t => Z.gtb (zat (f_ph F) r) (t + 1) | None => false end)
           (List.seq 0 n)).

(** 8.8 Release and acquire patterns, 8.9.3 observation, 8.9.4 synchronizes-with *)
Definition d_RelFences : vec := vunion n (vunion n d_FenceRel d_FenceAcqRel) d_BarrierWait.
Definition d_AcqFences : vec := vunion n (vunion n d_FenceAcq d_FenceAcqRel) d_BarrierWait.
Definition d_AcqReads : vec := vminus n d_Acquire d_FalseWaits.
Definition d_strong (r : mat) : mat := minter n n r d_ms_r.
Definition d_rel_pattern : mat :=
  munion n n (mseq n n n (mdiag n d_Release) (mseq n n n (mopt n d_po_loc) (mdiag n d_StrongW)))
             (mseq n n n (mdiag n d_RelFences) (mseq n n n (mplus n d_po) (mdiag n d_StrongW))).
Definition d_acq_pattern : mat :=
  munion n n (mseq n n n (mdiag n d_StrongR) (mseq n n n (mopt n d_po_loc) (mdiag n d_AcqReads)))
             (mseq n n n (mdiag n d_StrongR) (mseq n n n (mplus n d_po) (mdiag n d_AcqFences))).
Definition d_obs : mat := mseq n n n (d_strong d_rf) (mstar n (mseq n n n d_rmw (d_strong d_rf))).
Definition d_sync_pattern : mat := d_strong (mseq n n n d_rel_pattern (mseq n n n d_obs d_acq_pattern)).
Definition d_cluster_sync : mat :=
  munion n n (mseq n n n (mdiag n (vminus n d_ClusterArrive d_ClusterArriveRelaxed)) (mseq n n n d_cgen d_cwait))
    (d_strong (mseq n n n (mdiag n d_RelFences) (mseq n n n (mplus n d_po)
                 (mseq n n n (mdiag n d_ClusterArriveRelaxed) (mseq n n n d_cgen d_cwait))))).
Definition d_sw : mat := munion n n (munion n n (munion n n d_sc d_synchronizes) d_cluster_sync) d_sync_pattern.

(** Restricted release and acquire *)
Definition d_RRel : vec := vunion n (vunion n d_SyncRestrictCta d_OpRestrictInit) d_TxAnchor.
Definition d_RAcq : vec := d_SyncRestrictCluster.
Definition b_only_shared (ad : mat) (x : nat) : bool :=
  forallb (fun s => Bool.eqb (existsb (fun a => get ad x a && space_eqb (space_at a) s) (List.seq 0 nA))
                             (space_eqb s SShared)) all_spaces.
Definition d_rleft0 : mat :=
  let mem := d_MemoryEvent in let src := d_SyncRestrictCta in let ad := d_address in let ow := d_owner in
  let co := d_cta_of in
  mk n n (fun x f => vget mem x && (vget src f && (b_only_shared ad x
            && forallb (fun o => Bool.eqb (existsb (fun a => get ad x a && get ow a o) (List.seq 0 nA))
                                          (get co f o)) (List.seq 0 nS)))).
Definition d_rleft : mat :=
  munion n n (munion n n (minter n n d_rleft0 (mplus n d_po))
                         (mseq n n n (mdiag n d_MbarInit) (mseq n n n (mplus n d_po) (mdiag n d_OpRestrictInit))))
             (minv n n (mseq n n n (mdiag n d_TxAnchor) d_txops)).
Definition d_rright0 : mat :=
  let srl := d_SyncRestrictCluster in let mem := d_MemoryEvent in let ad := d_address in let ow := d_owner in
  let cl := d_cluster_of in let ss := d_subscope_star in
  mk n n (fun f y => vget srl f && (vget mem y && (b_only_shared ad y
            && forallb (fun o => implb (existsb (fun a => get ad y a && get ow a o) (List.seq 0 nA))
                                       (existsb (fun c => get cl f c && get ss c o) (List.seq 0 nS)))
                 (List.seq 0 nS)))).
Definition d_rright : mat := minter n n d_rright0 (mplus n d_po).

(** 8.9.5 Base causality order *)
Definition d_bco_plain : mat :=
  mplus n (munion n n (munion n n (munion n n (munion n n d_po d_issue) d_done) d_gdep)
                      (mminus n n (mminus n n d_sw (mseq n n n (mdiag n d_RRel) d_sw)) (mseq n n n d_sw (mdiag n d_RAcq)))).
Definition d_sw_restricted : mat := munion n n (mseq n n n (mdiag n d_RRel) d_sw) (mseq n n n d_sw (mdiag n d_RAcq)).
Definition d_cause_base : mat :=
  let left := munion n n (mseq n n n d_rleft (mdiag n d_RRel)) (mseq n n n (mstar n d_bco_plain) (mdiag n (vcompl n d_RRel))) in
  let right := munion n n (mseq n n n (mdiag n d_RAcq) d_rright) (mseq n n n (mdiag n (vcompl n d_RAcq)) (mstar n d_bco_plain)) in
  munion n n d_bco_plain (mseq n n n left (mseq n n n d_sw_restricted right)).

(** 8.9.5 Proxy-preserved base causality order *)
Definition d_GenericM : vec := vmk n (fun e => memp (f_proxy F) e Generic).
Definition d_AsyncW : vec := let wr := d_Write in vmk n (fun e => memp (f_proxy F) e Async && vget wr e).
Definition d_pf_space_ok : mat :=
  let pf := d_ProxyFence in let mem := d_MemoryEvent in let ad := d_address in let pa := d_paddr in
  mk n n (fun f m => vget pf f && (vget mem m
            && ((forallb (fun s => negb (mems (f_pspace F) f s)) all_spaces
                 || forallb (fun a => implb (get ad m a) (mems (f_pspace F) f (space_at a))) (List.seq 0 nA))
                && (forallb (fun a => negb (get pa f a)) (List.seq 0 nA)
                    || forallb (fun a => implb (get ad m a) (get pa f a)) (List.seq 0 nA))))).
Definition d_pf_src0 : mat :=
  let mem := d_MemoryEvent in let pf := d_ProxyFence in
  mk n n (fun m f => vget mem m && (vget pf f
            && forallb (fun p => implb (memp (f_proxy F) m p) (memd (f_dirs F) f p Generic)) all_proxies)).
Definition d_pf_src : mat := minter n n (minter n n d_pf_src0 d_same_cta_r) (minv n n d_pf_space_ok).
Definition d_pf_dst0 : mat :=
  let mem := d_MemoryEvent in let pf := d_ProxyFence in
  mk n n (fun f m => vget pf f && (vget mem m
            && forallb (fun p => implb (memp (f_proxy F) m p) (memd (f_dirs F) f Generic p)) all_proxies)).
Definition d_pf_dst : mat := minter n n (minter n n d_pf_dst0 d_same_cta_r) d_pf_space_ok.
Definition d_TmFence : vec := let pf := d_ProxyFence in vmk n (fun f => vget pf f && memd (f_dirs F) f Generic TensorMap).
Definition d_pf_dst_with (cb : mat) : mat :=
  munion n n (minter n n cb (mminus n n d_pf_dst (mseq n n n (mdiag n d_TmFence) d_pf_dst)))
    (mseq n n n (mdiag n (vinter n d_TmFence d_FenceRel))
       (mseq n n n cb (minter n n cb (mseq n n n (mdiag n (vinter n d_TmFence d_FenceAcq)) d_pf_dst)))).
Definition d_same_alias (r : mat) : mat := minter n n r d_same_alias_r.
Definition d_same_location (r : mat) : mat := minter n n r d_same_location_r.
Definition d_ppbco_with (cb : mat) : mat :=
  let pdw := d_pf_dst_with cb in
  let src := minter n n cb d_pf_src in
  let G := mdiag n d_GenericM in
  let AF := mdiag n d_AliasFence in
  munion n n (munion n n (munion n n (munion n n (munion n n (munion n n (munion n n (munion n n (munion n n
    (d_same_alias (mseq n n n G (mseq n n n cb G)))
    (d_same_alias (minter n n (minter n n (mseq n n n (mdiag n d_MemoryEvent) (mseq n n n cb (mdiag n d_MemoryEvent)))
                                         d_same_cta_r) d_same_proxy)))
    (d_same_alias (mseq n n n (mdiag n (vinter n d_GenericM d_Read)) (mseq n n n cb (mdiag n d_AsyncW)))))
    (d_same_alias (mseq n n n src (mseq n n n cb G))))
    (d_same_alias (mseq n n n G (mseq n n n cb pdw))))
    (d_same_alias (mseq n n n src (mseq n n n cb pdw))))
    (d_same_location (mseq n n n G (mseq n n n cb (mseq n n n (mseq n n n AF cb) G)))))
    (d_same_location (mseq n n n src (mseq n n n (mseq n n n cb AF) (mseq n n n cb G)))))
    (d_same_location (mseq n n n G (mseq n n n cb (mseq n n n (mseq n n n AF cb) pdw)))))
    (d_same_location (mseq n n n src (mseq n n n (mseq n n n cb AF) (mseq n n n cb pdw)))).
Definition d_ppbco : mat := d_ppbco_with d_cause_base.
Definition d_cause : mat := munion n n d_ppbco (mseq n n n d_obs d_ppbco).

(** 8.10 Axioms *)
Definition b_coherence : bool :=
  bsubset n n (d_same_location (mseq n n n (mdiag n d_Write) (mseq n n n d_cause (mdiag n d_Write)))) (mplus n d_co).
Definition b_fence_sc : bool :=
  bsubset n n (minter n n (mseq n n n (mdiag n d_FenceSC) (mseq n n n d_cause_base (mdiag n d_FenceSC))) d_ms_r) d_sc.
Definition d_acc_lift (r : mat) : mat := mseq n n n (mopt n d_same_acc) (mseq n n n r (mopt n d_same_acc)).
Definition d_AtomicR : vec :=
  let rm := d_rmw in let wr := d_Write in vmk n (fun e => existsb (fun w => get rm e w && vget wr w) (List.seq 0 n)).
Definition d_Atomics : vec :=
  let ar := d_AtomicR in let rm := d_rmw in
  vmk n (fun e => vget ar e || existsb (fun r => vget ar r && get rm r e) (List.seq 0 n)).
Definition d_atomic_pair_r : mat :=
  munion n n d_ms_r (mseq n n n (mdiag n d_Atomics)
                       (mseq n n n (minter n n (minter n n d_scope_incl_r d_same_proxy) d_same_location_r) (mdiag n d_Atomics))).
Definition b_atomicity : bool :=
  bnone n n (minter n n (mseq n n n (mdiag n d_Read) (mseq n n n d_ms_r (mdiag n d_Write)))
                        (minter n n (d_acc_lift (minv n n d_rf)) (d_acc_lift d_fr)))
  && bnone n n (minter n n (mseq n n n (minter n n d_fr d_atomic_pair_r) (minter n n (mplus n d_co) d_atomic_pair_r)) d_rmw).
Definition b_no_thin_air : bool := bacyclic n (munion n n d_rf d_dep).
Definition b_sc_per_location : bool := bacyclic n (munion n n (d_strong d_com) d_po_loc).
Definition b_causality : bool := birrefl n (mseq n n n (munion n n d_rf d_fr) d_cause).
Definition b_consistent : bool :=
  b_coherence && (b_fence_sc && (b_atomicity && (b_no_thin_air && (b_sc_per_location && b_causality)))).

Definition d_fpal : mat := mseq n nA nA d_footprint d_aliases.
Definition d_unordered : mat := munion n n (munion n n d_ms_r d_cause) (minv n n d_cause).
Definition b_mixed_size_race : bool :=
  let mem := d_MemoryEvent in let sl := d_same_location_r in let fa := d_fpal in let wr := d_Write in
  let un := d_unordered in
  existsb (fun e1 => existsb (fun e2 =>
    negb (Nat.eqb e1 e2) && (vget mem e1 && (vget mem e2 && (get sl e1 e2
    && (negb (forallb (fun b => Bool.eqb (get fa e1 b) (get fa e2 b)) (List.seq 0 nA))
    && ((vget wr e1 || vget wr e2) && negb (get un e1 e2))))))) (List.seq 0 n)) (List.seq 0 n).
Definition b_undefined : bool := b_mb_undefined.

(** Well-formedness: the facts of the model, one boolean per fact, in the order of [wf_prog] and [wf_exec] *)
Definition d_co_plus : mat := mplus n d_co.
Definition d_po_plus : mat := mplus n d_po.
Definition d_same_scope : mat := mk n n (fun i j => Nat.eqb (scope_at i) (scope_at j)).
Definition d_same_bid : mat :=
  let ba := d_BarrierArrive in mk n n (fun a b => vget ba a && (vget ba b && Z.eqb (zat (f_bid F) a) (zat (f_bid F) b))).
Definition d_same_cluster : mat := mseq n nS n d_cluster_of (minv n nS d_cluster_of).
Definition b_barriers_9 : bool :=
  let ba := d_BarrierArrive in let bg := d_bgen in
  forallb (fun a => implb (vget ba a) (match oat (f_bcount F) a with
     | Some k => Z.eqb (Z.of_nat (length (filter (fun b => get bg a b) (List.seq 0 n)))) k
     | None => true end)) (List.seq 0 n).
Definition b_decl_start : bool :=
  let d_Thread := d_Thread in let d_start := d_start in 
  forallb (fun t => forallb (fun e => implb (get d_start t e) (vget d_Thread t)) (List.seq 0 n)) (List.seq 0 nS).
Definition b_decl_start_one : bool :=
  let d_Thread := d_Thread in let d_start := d_start in 
  forallb (fun t => implb (vget d_Thread t) (existsb (fun e => get d_start t e && forallb (fun e' => implb (get d_start t e') (Nat.eqb e' e)) (List.seq 0 n)) (List.seq 0 n))) (List.seq 0 nS).
Definition b_decl_owner_lone : bool :=
  let d_owner := d_owner in 
  forallb (fun a => forallb (fun s1 => forallb (fun s2 => implb (get d_owner a s1) (implb (get d_owner a s2) (Nat.eqb s1 s2))) (List.seq 0 nS)) (List.seq 0 nS)) (List.seq 0 nA).
Definition b_decl_po_lone : bool :=
  let d_po := d_po in 
  forallb (fun e => forallb (fun e1 => forallb (fun e2 => implb (get d_po e e1) (implb (get d_po e e2) (Nat.eqb e1 e2))) (List.seq 0 n)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_address : bool :=
  let d_MemoryEvent := d_MemoryEvent in let d_address := d_address in 
  forallb (fun e => forallb (fun a => implb (get d_address e a) (vget d_MemoryEvent e)) (List.seq 0 nA)) (List.seq 0 n).
Definition b_decl_address_one : bool :=
  let d_MemoryEvent := d_MemoryEvent in let d_address := d_address in 
  forallb (fun e => implb (vget d_MemoryEvent e) (existsb (fun a => get d_address e a && forallb (fun a' => implb (get d_address e a') (Nat.eqb a' a)) (List.seq 0 nA)) (List.seq 0 nA))) (List.seq 0 n).
Definition b_decl_proxy : bool :=
  let d_MemoryEvent := d_MemoryEvent in 
  forallb (fun e => forallb (fun p => implb (memp (f_proxy F) e p) (vget d_MemoryEvent e)) all_proxies) (List.seq 0 n).
Definition b_decl_proxy_one : bool :=
  let d_MemoryEvent := d_MemoryEvent in 
  forallb (fun e => implb (vget d_MemoryEvent e) (existsb (fun p => memp (f_proxy F) e p && forallb (fun p' => implb (memp (f_proxy F) e p') (proxy_eqb p' p)) all_proxies) all_proxies)) (List.seq 0 n).
Definition b_decl_acc : bool :=
  let d_MemoryEvent := d_MemoryEvent in let d_acc := d_acc in 
  forallb (fun e => forallb (fun c => implb (get d_acc e c) (vget d_MemoryEvent e)) (List.seq 0 nC)) (List.seq 0 n).
Definition b_decl_acc_lone : bool :=
  let d_acc := d_acc in 
  forallb (fun e => forallb (fun c1 => forallb (fun c2 => implb (get d_acc e c1) (implb (get d_acc e c2) (Nat.eqb c1 c2))) (List.seq 0 nC)) (List.seq 0 nC)) (List.seq 0 n).
Definition b_decl_rmw : bool :=
  let d_Read := d_Read in let d_Write := d_Write in let d_rmw := d_rmw in 
  forallb (fun r => forallb (fun w => implb (get d_rmw r w) (vget d_Read r && vget d_Write w)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_rmw_lone : bool :=
  let d_rmw := d_rmw in 
  forallb (fun r => forallb (fun w1 => forallb (fun w2 => implb (get d_rmw r w1) (implb (get d_rmw r w2) (Nat.eqb w1 w2))) (List.seq 0 n)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_dep : bool :=
  let d_Read := d_Read in let d_dep := d_dep in 
  forallb (fun r => forallb (fun e => implb (get d_dep r e) (vget d_Read r)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_SyncRestrictCta : bool :=
  let d_FenceRel := d_FenceRel in let d_SyncRestrictCta := d_SyncRestrictCta in 
  forallb (fun e => implb (vget d_SyncRestrictCta e) (vget d_FenceRel e)) (List.seq 0 n).
Definition b_decl_SyncRestrictCluster : bool :=
  let d_FenceAcq := d_FenceAcq in let d_SyncRestrictCluster := d_SyncRestrictCluster in 
  forallb (fun e => implb (vget d_SyncRestrictCluster e) (vget d_FenceAcq e)) (List.seq 0 n).
Definition b_decl_OpRestrictInit : bool :=
  let d_FenceRel := d_FenceRel in let d_OpRestrictInit := d_OpRestrictInit in 
  forallb (fun e => implb (vget d_OpRestrictInit e) (vget d_FenceRel e)) (List.seq 0 n).
Definition b_decl_dirs : bool :=
  let d_ProxyFence := d_ProxyFence in 
  forallb (fun f => forallb (fun p => forallb (fun q => implb (memd (f_dirs F) f p q) (vget d_ProxyFence f)) all_proxies) all_proxies) (List.seq 0 n).
Definition b_decl_pspace : bool :=
  let d_ProxyFence := d_ProxyFence in 
  forallb (fun f => forallb (fun s => implb (mems (f_pspace F) f s) (vget d_ProxyFence f)) all_spaces) (List.seq 0 n).
Definition b_decl_paddr : bool :=
  let d_ProxyFence := d_ProxyFence in let d_paddr := d_paddr in 
  forallb (fun f => forallb (fun a => implb (get d_paddr f a) (vget d_ProxyFence f)) (List.seq 0 nA)) (List.seq 0 n).
Definition b_decl_bcount : bool :=
  let d_BarrierArrive := d_BarrierArrive in 
  forallb (fun e => implb (is_some (oat (f_bcount F) e)) (vget d_BarrierArrive e)) (List.seq 0 n).
Definition b_decl_bwait : bool :=
  let d_BarrierArrive := d_BarrierArrive in let d_BarrierWait := d_BarrierWait in let d_bwait := d_bwait in 
  forallb (fun a => forallb (fun w => implb (get d_bwait a w) (vget d_BarrierArrive a && vget d_BarrierWait w)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_bwait_lone : bool :=
  let d_bwait := d_bwait in 
  forallb (fun a => forallb (fun w1 => forallb (fun w2 => implb (get d_bwait a w1) (implb (get d_bwait a w2) (Nat.eqb w1 w2))) (List.seq 0 n)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_cwait : bool :=
  let d_ClusterArrive := d_ClusterArrive in let d_ClusterWait := d_ClusterWait in let d_cwait := d_cwait in 
  forallb (fun a => forallb (fun w => implb (get d_cwait a w) (vget d_ClusterArrive a && vget d_ClusterWait w)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_cwait_lone : bool :=
  let d_cwait := d_cwait in 
  forallb (fun a => forallb (fun w1 => forallb (fun w2 => implb (get d_cwait a w1) (implb (get d_cwait a w2) (Nat.eqb w1 w2))) (List.seq 0 n)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_ClusterArriveRelaxed : bool :=
  let d_ClusterArrive := d_ClusterArrive in let d_ClusterArriveRelaxed := d_ClusterArriveRelaxed in 
  forallb (fun e => implb (vget d_ClusterArriveRelaxed e) (vget d_ClusterArrive e)) (List.seq 0 n).
Definition b_decl_MbarEv : bool :=
  let d_MbarEv := d_MbarEv in let d_MemoryEvent := d_MemoryEvent in 
  forallb (fun e => implb (vget d_MbarEv e) (vget d_MemoryEvent e)) (List.seq 0 n).
Definition b_decl_MbarInit : bool :=
  let d_MbarInit := d_MbarInit in let d_Write := d_Write in 
  forallb (fun e => implb (vget d_MbarInit e) (vget d_Write e)) (List.seq 0 n).
Definition b_decl_MbarWait : bool :=
  let d_MbarWait := d_MbarWait in let d_Read := d_Read in 
  forallb (fun e => implb (vget d_MbarWait e) (vget d_Read e)) (List.seq 0 n).
Definition b_decl_wpar : bool :=
  let d_MbarWait := d_MbarWait in 
  forallb (fun e => implb (is_some (oat (f_wpar F) e)) (vget d_MbarWait e)) (List.seq 0 n).
Definition b_decl_wtok : bool :=
  let d_MbarWait := d_MbarWait in 
  forallb (fun e => implb (is_some (oat (f_wtok F) e)) (vget d_MbarWait e)) (List.seq 0 n).
Definition b_decl_TxAnchor : bool :=
  let d_TxAnchor := d_TxAnchor in let d_Write := d_Write in 
  forallb (fun e => implb (vget d_TxAnchor e) (vget d_Write e)) (List.seq 0 n).
Definition b_decl_txops : bool :=
  let d_TxAnchor := d_TxAnchor in let d_txops := d_txops in 
  forallb (fun e => forallb (fun e' => implb (get d_txops e e') (vget d_TxAnchor e)) (List.seq 0 n)) (List.seq 0 n).
Definition b_sig_Acquire : bool :=
  let d_Acquire := d_Acquire in let d_Thread := d_Thread in 
  forallb (fun e => implb (vget d_Acquire e) (negb (vget d_Thread (scope_at e)))) (List.seq 0 n).
Definition b_sig_Release : bool :=
  let d_Release := d_Release in let d_Thread := d_Thread in 
  forallb (fun e => implb (vget d_Release e) (negb (vget d_Thread (scope_at e)))) (List.seq 0 n).
Definition b_sig_Fence : bool :=
  let d_Fence := d_Fence in let d_Thread := d_Thread in 
  forallb (fun e => implb (vget d_Fence e) (negb (vget d_Thread (scope_at e)))) (List.seq 0 n).
Definition b_scope_tree_1 : bool :=
  let d_System := d_System in 
  existsb (fun s => vget d_System s && forallb (fun s' => implb (vget d_System s') (Nat.eqb s' s)) (List.seq 0 nS)) (List.seq 0 nS).
Definition b_scope_tree_2 : bool :=
  let d_subscope := d_subscope in 
  forallb (fun p1 => forallb (fun p2 => forallb (fun s => implb (get d_subscope p1 s) (implb (get d_subscope p2 s) (Nat.eqb p1 p2))) (List.seq 0 nS)) (List.seq 0 nS)) (List.seq 0 nS).
Definition b_scope_tree_3 : bool :=
  let d_Thread := d_Thread in let d_subscope := d_subscope in 
  forallb (fun t => forallb (fun s => implb (vget d_Thread t) (negb (get d_subscope t s))) (List.seq 0 nS)) (List.seq 0 nS).
Definition b_scope_tree_4 : bool := bacyclic nS d_subscope.
Definition b_scope_tree_5 : bool :=
  let d_start := d_start in 
  forallb (fun t1 => forallb (fun t2 => forallb (fun e => implb (get d_start t1 e) (implb (get d_start t2 e) (Nat.eqb t1 t2))) (List.seq 0 n)) (List.seq 0 nS)) (List.seq 0 nS).
Definition b_address_facts_1 : bool :=
  let d_aliases := d_aliases in 
  forallb (fun a => forallb (fun b => implb (get d_aliases a b) (Z.eqb (zat (f_init F) b) (zat (f_init F) a))) (List.seq 0 nA)) (List.seq 0 nA).
Definition b_address_facts_2 : bool :=
  let d_owner := d_owner in 
  forallb (fun a => Bool.eqb (space_eqb (space_at a) SShared || space_eqb (space_at a) SLocal) (existsb (fun s => get d_owner a s) (List.seq 0 nS))) (List.seq 0 nA).
Definition b_address_facts_3 : bool :=
  let d_CtaScope := d_CtaScope in let d_Thread := d_Thread in let d_owner := d_owner in 
  forallb (fun a => forallb (fun s => implb (get d_owner a s) ((space_eqb (space_at a) SShared && vget d_CtaScope s) || (space_eqb (space_at a) SLocal && vget d_Thread s))) (List.seq 0 nS)) (List.seq 0 nA).
Definition b_threads_1 : bool := bacyclic n d_po.
Definition b_threads_2 : bool :=
  let d_thd := d_thd in 
  forallb (fun e => existsb (fun t => get d_thd e t && forallb (fun t' => implb (get d_thd e t') (Nat.eqb t' t)) (List.seq 0 nS)) (List.seq 0 nS)) (List.seq 0 n).
Definition b_threads_3 : bool :=
  let d_subscope_star := d_subscope_star in let d_thd := d_thd in 
  forallb (fun e => existsb (fun t => get d_thd e t && get d_subscope_star (scope_at e) t) (List.seq 0 nS)) (List.seq 0 n).
Definition b_communication_5 : bool :=
  let d_Write := d_Write in let d_address := d_address in 
  forallb (fun w => forallb (fun a => implb (vget d_Write w) (implb (get d_address w a) (negb (space_eqb (space_at a) SConst) && negb (space_eqb (space_at a) SParam)))) (List.seq 0 nA)) (List.seq 0 n).
Definition b_dependencies_1 : bool := bsubset n n d_dep (mplus n d_po).
Definition b_dependencies_2 : bool := bsubset n n d_rmw (minter n n (minter n n (minter n n (minter n n d_po d_dep) d_same_alias_r) d_same_scope) d_same_proxy).
Definition b_mbarrier_state_1 : bool :=
  let d_Mbar := d_Mbar in let d_MbarEv := d_MbarEv in let d_address := d_address in 
  forallb (fun e => Bool.eqb (vget d_MbarEv e) (existsb (fun a => get d_address e a && vget d_Mbar a) (List.seq 0 nA))) (List.seq 0 n).
Definition b_mbarrier_state_2 : bool :=
  let d_Mbar := d_Mbar in let d_alias := d_alias in 
  forallb (fun a => forallb (fun b => implb (vget d_Mbar a) (negb (get d_alias b a) && negb (get d_alias a b))) (List.seq 0 nA)) (List.seq 0 nA).
Definition b_mbarrier_state_4 : bool :=
  let d_MbarEv := d_MbarEv in let d_MbarInit := d_MbarInit in let d_MbarWait := d_MbarWait in 
  forallb (fun e => implb (vget d_MbarInit e || vget d_MbarWait e) (vget d_MbarEv e)) (List.seq 0 n).
Definition b_barriers_1 : bool := bsubset n n d_bwait d_po.
Definition b_barriers_2 : bool :=
  let d_BarrierArrive := d_BarrierArrive in let d_BarrierWait := d_BarrierWait in let d_bwait := d_bwait in 
  forallb (fun w => implb (vget d_BarrierWait w) (existsb (fun a => vget d_BarrierArrive a && get d_bwait a w) (List.seq 0 n))) (List.seq 0 n).
Definition b_cluster_barriers_1 : bool := bsubset n n d_cwait (mplus n d_po).
Definition b_cluster_barriers_2 : bool :=
  let d_cwait := d_cwait in 
  forallb (fun a1 => forallb (fun a2 => forallb (fun w => implb (get d_cwait a1 w) (implb (get d_cwait a2 w) (Nat.eqb a1 a2))) (List.seq 0 n)) (List.seq 0 n)) (List.seq 0 n).
Definition b_cluster_barriers_3 : bool :=
  let d_ClusterArrive := d_ClusterArrive in let d_ClusterWait := d_ClusterWait in let d_cwait := d_cwait in 
  forallb (fun w => implb (vget d_ClusterWait w) (existsb (fun a => vget d_ClusterArrive a && get d_cwait a w) (List.seq 0 n))) (List.seq 0 n).
Definition b_async_units_2 : bool :=
  let d_AsyncUnit := d_AsyncUnit in let d_issue := d_issue in let d_thd := d_thd in 
  forallb (fun e => forallb (fun u => forallb (fun e' => implb (get d_thd e u) (implb (vget d_AsyncUnit u) (negb (get d_issue e e')))) (List.seq 0 n)) (List.seq 0 nS)) (List.seq 0 n).
Definition b_decl_rf : bool :=
  let d_Read := d_Read in let d_Write := d_Write in let d_rf := d_rf in 
  forallb (fun w => forallb (fun r => implb (get d_rf w r) (vget d_Write w && vget d_Read r)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_co : bool :=
  let d_Write := d_Write in let d_co := d_co in 
  forallb (fun w => forallb (fun w' => implb (get d_co w w') (vget d_Write w && vget d_Write w')) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_sc : bool :=
  let d_FenceSC := d_FenceSC in let d_sc := d_sc in 
  forallb (fun f => forallb (fun f' => implb (get d_sc f f') (vget d_FenceSC f && vget d_FenceSC f')) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_bgen : bool :=
  let d_BarrierArrive := d_BarrierArrive in let d_bgen := d_bgen in 
  forallb (fun a => forallb (fun b => implb (get d_bgen a b) (vget d_BarrierArrive a && vget d_BarrierArrive b)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_synchronizes : bool :=
  let d_BarrierArrive := d_BarrierArrive in let d_BarrierWait := d_BarrierWait in let d_synchronizes := d_synchronizes in 
  forallb (fun a => forallb (fun w => implb (get d_synchronizes a w) (vget d_BarrierArrive a && vget d_BarrierWait w)) (List.seq 0 n)) (List.seq 0 n).
Definition b_decl_cgen : bool :=
  let d_ClusterArrive := d_ClusterArrive in let d_cgen := d_cgen in 
  forallb (fun a => forallb (fun b => implb (get d_cgen a b) (vget d_ClusterArrive a && vget d_ClusterArrive b)) (List.seq 0 n)) (List.seq 0 n).
Definition b_mbarrier_state_3 : bool :=
  let d_MbarEv := d_MbarEv in let d_Read := d_Read in let d_address := d_address in let d_rf := d_rf in 
  forallb (fun r => implb (vget d_Read r) (implb (vget d_MbarEv r) ((implb (existsb (fun w => get d_rf w r) (List.seq 0 n)) (forallb (fun w => implb (get d_rf w r) (Z.eqb (zat (f_ph F) r) (zat (f_ph F) w) && (Z.eqb (zat (f_pend F) r) (zat (f_pend F) w) && (Z.eqb (zat (f_expc F) r) (zat (f_expc F) w) && (Z.eqb (zat (f_tx F) r) (zat (f_tx F) w)))))) (List.seq 0 n))) && (implb (negb (existsb (fun w => get d_rf w r) (List.seq 0 n))) (forallb (fun a => implb (get d_address r a) (Z.eqb (zat (f_ph F) r) (zat (f_iph F) a) && (Z.eqb (zat (f_pend F) r) (zat (f_ipend F) a) && (Z.eqb (zat (f_expc F) r) (zat (f_iexp F) a) && (Z.eqb (zat (f_tx F) r) (zat (f_itx F) a)))))) (List.seq 0 nA)))))) (List.seq 0 n).
Definition b_mbarrier_state_5 : bool :=
  let d_MbarInit := d_MbarInit in 
  forallb (fun w => implb (vget d_MbarInit w) (Z.eqb (zat (f_ph F) w) 0 && (Z.eqb (zat (f_tx F) w) 0 && Z.eqb (zat (f_pend F) w) (zat (f_expc F) w)))) (List.seq 0 n).
Definition b_communication_1 : bool := bsubset n n (munion n n d_rf d_co) d_same_location_r.
Definition b_communication_2 : bool :=
  let d_rf := d_rf in 
  forallb (fun w1 => forallb (fun w2 => forallb (fun r => implb (get d_rf w1 r) (implb (get d_rf w2 r) (Nat.eqb w1 w2))) (List.seq 0 n)) (List.seq 0 n)) (List.seq 0 n).
Definition b_communication_3 : bool :=
  let d_Read := d_Read in let d_address := d_address in let d_rf := d_rf in 
  forallb (fun r => implb (vget d_Read r) ((implb (existsb (fun w => get d_rf w r) (List.seq 0 n)) (forallb (fun w => implb (get d_rf w r) (Z.eqb (zat (f_val F) r) (zat (f_val F) w))) (List.seq 0 n))) && (implb (negb (existsb (fun w => get d_rf w r) (List.seq 0 n))) (forallb (fun a => implb (get d_address r a) (Z.eqb (zat (f_val F) r) (zat (f_init F) a))) (List.seq 0 nA))))) (List.seq 0 n).
Definition b_communication_4 : bool := bacyclic n d_co.
Definition b_co_strong_1 : bool := bsubset n n (mseq n n n (mdiag n d_Write) (mseq n n n d_ms_r (mdiag n d_Write))) (munion n n (mplus n d_co) (mplus n (minv n n d_co))).
Definition b_co_strong_2 : bool :=
  let d_acc := d_acc in let d_co_plus := d_co_plus in 
  forallb (fun c1 => forallb (fun c2 => negb ((existsb (fun w1 => existsb (fun w2 => get d_acc w1 c1 && (get d_co_plus w1 w2 && get d_acc w2 c2)) (List.seq 0 n)) (List.seq 0 n)) && (existsb (fun w1 => existsb (fun w2 => get d_acc w1 c2 && (get d_co_plus w1 w2 && get d_acc w2 c1)) (List.seq 0 n)) (List.seq 0 n)))) (List.seq 0 nC)) (List.seq 0 nC).
Definition b_fence_sc_order_1 : bool :=
  let d_FenceSC := d_FenceSC in let d_ms_r := d_ms_r in let d_sc := d_sc in 
  forallb (fun f1 => forallb (fun f2 => implb (vget d_FenceSC f1) (implb (vget d_FenceSC f2) (implb (negb (Nat.eqb f1 f2)) (implb (get d_ms_r f1 f2) (get d_sc f1 f2 || get d_sc f2 f1))))) (List.seq 0 n)) (List.seq 0 n).
Definition b_fence_sc_order_2 : bool := bsubset n n d_sc d_ms_r.
Definition b_fence_sc_order_3 : bool := bacyclic n d_sc.
Definition b_barriers_3 : bool := bsubset n n d_bgen (minv n n d_bgen) && bsubset n n (minv n n d_bgen) d_bgen.
Definition b_barriers_4 : bool :=
  let d_BarrierArrive := d_BarrierArrive in let d_bgen := d_bgen in 
  forallb (fun a => implb (vget d_BarrierArrive a) (get d_bgen a a)) (List.seq 0 n).
Definition b_barriers_5 : bool := bsubset n n (mseq n n n d_bgen d_bgen) d_bgen.
Definition b_barriers_6 : bool := bsubset n n d_bgen (minter n n d_same_cta_r d_same_bid).
Definition b_barriers_7 : bool :=
  let d_bgen := d_bgen in let d_po_plus := d_po_plus in 
  forallb (fun a => forallb (fun b => negb (get d_po_plus a b && get d_bgen a b)) (List.seq 0 n)) (List.seq 0 n).
Definition b_barriers_8 : bool := bacyclic n (mseq n n n d_bgen (minter n n (mplus n d_po) d_same_bid)).
Definition b_barriers_10 : bool :=
  let d_BarrierArrive := d_BarrierArrive in let d_Thread := d_Thread in let d_bgen := d_bgen in let d_same_cta_r := d_same_cta_r in let d_thd := d_thd in 
  forallb (fun a => implb (vget d_BarrierArrive a) (implb (is_none (oat (f_bcount F) a)) (forallb (fun t => Bool.eqb (existsb (fun b => get d_bgen a b && get d_thd b t) (List.seq 0 n)) (vget d_Thread t && existsb (fun b => vget d_BarrierArrive b && (get d_thd b t && (Z.eqb (zat (f_bid F) b) (zat (f_bid F) a) && get d_same_cta_r b a))) (List.seq 0 n))) (List.seq 0 nS)))) (List.seq 0 n).
Definition b_barriers_11 : bool := bsubset n n d_synchronizes (mseq n n n d_bgen d_bwait) && bsubset n n (mseq n n n d_bgen d_bwait) d_synchronizes.
Definition b_cluster_barriers_4 : bool := bsubset n n d_cgen (minv n n d_cgen) && bsubset n n (minv n n d_cgen) d_cgen.
Definition b_cluster_barriers_5 : bool :=
  let d_ClusterArrive := d_ClusterArrive in let d_cgen := d_cgen in 
  forallb (fun a => implb (vget d_ClusterArrive a) (get d_cgen a a)) (List.seq 0 n).
Definition b_cluster_barriers_6 : bool := bsubset n n (mseq n n n d_cgen d_cgen) d_cgen.
Definition b_cluster_barriers_7 : bool := bsubset n n d_cgen d_same_cluster.
Definition b_cluster_barriers_8 : bool :=
  let d_cgen := d_cgen in let d_po_plus := d_po_plus in 
  forallb (fun a => forallb (fun b => negb (get d_po_plus a b && get d_cgen a b)) (List.seq 0 n)) (List.seq 0 n).
Definition b_cluster_barriers_9 : bool := bacyclic n (mseq n n n d_cgen (mplus n d_po)).
Definition b_cluster_barriers_10 : bool :=
  let d_AsyncUnit := d_AsyncUnit in let d_ClusterArrive := d_ClusterArrive in let d_Thread := d_Thread in let d_cgen := d_cgen in let d_cluster_of := d_cluster_of in let d_subscope_star := d_subscope_star in let d_thd := d_thd in 
  forallb (fun a => implb (vget d_ClusterArrive a) (forallb (fun t => Bool.eqb (existsb (fun b => get d_cgen a b && get d_thd b t) (List.seq 0 n)) ((existsb (fun c => get d_cluster_of a c && get d_subscope_star c t) (List.seq 0 nS)) && (vget d_Thread t && negb (vget d_AsyncUnit t)))) (List.seq 0 nS))) (List.seq 0 n).
Definition b_wf_prog : bool := b_decl_start && (b_decl_start_one && (b_decl_owner_lone && (b_decl_po_lone && (b_decl_address && (b_decl_address_one && (b_decl_proxy && (b_decl_proxy_one && (b_decl_acc && (b_decl_acc_lone && (b_decl_rmw && (b_decl_rmw_lone && (b_decl_dep && (b_decl_SyncRestrictCta && (b_decl_SyncRestrictCluster && (b_decl_OpRestrictInit && (b_decl_dirs && (b_decl_pspace && (b_decl_paddr && (b_decl_bcount && (b_decl_bwait && (b_decl_bwait_lone && (b_decl_cwait && (b_decl_cwait_lone && (b_decl_ClusterArriveRelaxed && (b_decl_MbarEv && (b_decl_MbarInit && (b_decl_MbarWait && (b_decl_wpar && (b_decl_wtok && (b_decl_TxAnchor && (b_decl_txops && (b_sig_Acquire && (b_sig_Release && (b_sig_Fence && (b_scope_tree_1 && (b_scope_tree_2 && (b_scope_tree_3 && (b_scope_tree_4 && (b_scope_tree_5 && (b_address_facts_1 && (b_address_facts_2 && (b_address_facts_3 && (b_threads_1 && (b_threads_2 && (b_threads_3 && (b_communication_5 && (b_dependencies_1 && (b_dependencies_2 && (b_mbarrier_state_1 && (b_mbarrier_state_2 && (b_mbarrier_state_4 && (b_barriers_1 && (b_barriers_2 && (b_cluster_barriers_1 && (b_cluster_barriers_2 && (b_cluster_barriers_3 && (b_async_units_2))))))))))))))))))))))))))))))))))))))))))))))))))))))))).
Definition b_wf_exec : bool := b_decl_rf && (b_decl_co && (b_decl_sc && (b_decl_bgen && (b_decl_synchronizes && (b_decl_cgen && (b_mbarrier_state_3 && (b_mbarrier_state_5 && (b_communication_1 && (b_communication_2 && (b_communication_3 && (b_communication_4 && (b_co_strong_1 && (b_co_strong_2 && (b_fence_sc_order_1 && (b_fence_sc_order_2 && (b_fence_sc_order_3 && (b_barriers_3 && (b_barriers_4 && (b_barriers_5 && (b_barriers_6 && (b_barriers_7 && (b_barriers_8 && (b_barriers_9 && (b_barriers_10 && (b_barriers_11 && (b_cluster_barriers_4 && (b_cluster_barriers_5 && (b_cluster_barriers_6 && (b_cluster_barriers_7 && (b_cluster_barriers_8 && (b_cluster_barriers_9 && (b_cluster_barriers_10)))))))))))))))))))))))))))))))).

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

Lemma b_proxy_of_spec e p : b_proxy_of F (d_MemoryEvent F) (fin_val e) p = true <-> proxy_of X e p.
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

Lemma b_wait_true_spec e : b_wait_true F (fin_val e) = true <-> wait_true X e.
Proof.
  unfold b_wait_true, wait_true; rewrite orb_true_iff; simpl.
  destruct (oat (f_wpar F) (fin_val e)) as [p |], (oat (f_wtok F) (fin_val e)) as [t |].
  all: rewrite ?negb_true_iff, <- ?not_true_iff_false, ?Z.eqb_eq, ?Z.gtb_ltb, ?Z.ltb_lt.
  all: split; [intros [H | H] | intros [[q [Hq H]] | [u [Hu H]]]]; try discriminate.
  all: try (left; eexists; split; [reflexivity | exact H]); try (right; eexists; split; [reflexivity | lia]).
  all: try (injection Hq as <-; left; exact H); try (injection Hu as <-; right; lia).
Qed.

Lemma d_FalseWaits_spec : sspec (d_FalseWaits F) (FalseWaits X).
Proof.
  apply sspec_vmk; intros e; unfold FalseWaits.
  rewrite andb_true_iff, negb_true_iff, <- not_true_iff_false, (d_MbarWait_spec e), b_wait_true_spec; reflexivity.
Qed.
#[local] Hint Resolve d_FalseWaits_spec : chk.

Lemma b_mb_undefined_spec : bspec (b_mb_undefined F) (mb_undefined X).
Proof.
  unfold b_mb_undefined, mb_undefined; apply bspec_or; [| apply bspec_or].
  - apply bspec_existsb; intros r; apply bspec_and; [apply d_Read_spec | apply bspec_and; [apply d_MbarEv_spec |]].
    apply bspec_Zlt.
  - apply bspec_existsb; intros w; apply bspec_and; [apply d_Write_spec | apply bspec_and; [apply d_MbarEv_spec |]].
    apply bspec_and; [apply bspec_not, d_MbarInit_spec | apply bspec_Zlt].
  - apply bspec_equiv with (exists r, MbarWait X r /\ exists t, wtok X r = Some t /\ (ph X r > t + 1)%Z).
    + apply bspec_existsb; intros r; apply bspec_and; [apply d_MbarWait_spec |]; simpl.
      destruct (oat (f_wtok F) (fin_val r)) as [t |]; unfold bspec.
      * rewrite Z.gtb_ltb, Z.ltb_lt; split; [intros H; exists t; split; [reflexivity | lia] | intros [u [Hu H]]].
        injection Hu as <-; lia.
      * split; [discriminate | intros [u [Hu _]]; discriminate].
    + split; [intros [r [H1 [t H2]]]; exists r, t; tauto | intros [r [t H]]; exists r; split; [tauto | exists t; tauto]].
Qed.

Lemma d_RelFences_spec : sspec (d_RelFences F) (RelFences X). Proof. unfold d_RelFences, RelFences; spec. Qed.
Lemma d_AcqFences_spec : sspec (d_AcqFences F) (AcqFences X). Proof. unfold d_AcqFences, AcqFences; spec. Qed.
Lemma d_AcqReads_spec : sspec (d_AcqReads F) (AcqReads X). Proof. unfold d_AcqReads, AcqReads; spec. Qed.
#[local] Hint Resolve d_RelFences_spec d_AcqFences_spec d_AcqReads_spec : chk.

Lemma d_strong_spec r R : rspec r R -> rspec (d_strong F r) (strong X R).
Proof. intros H; unfold d_strong, strong; spec. Qed.

Ltac spec2 := repeat (spec_step || (match goal with |- rspec (d_strong _ _) _ => apply d_strong_spec end)
                      || solve [auto with chk]).

Lemma d_rel_pattern_spec : rspec (d_rel_pattern F) (rel_pattern X). Proof. unfold d_rel_pattern, rel_pattern; spec2. Qed.
Lemma d_acq_pattern_spec : rspec (d_acq_pattern F) (acq_pattern X). Proof. unfold d_acq_pattern, acq_pattern; spec2. Qed.
Lemma d_obs_spec : rspec (d_obs F) (obs X). Proof. unfold d_obs, obs; spec2. Qed.
#[local] Hint Resolve d_rel_pattern_spec d_acq_pattern_spec d_obs_spec : chk.
Lemma d_sync_pattern_spec : rspec (d_sync_pattern F) (sync_pattern X). Proof. unfold d_sync_pattern, sync_pattern; spec2. Qed.
Lemma d_cluster_sync_spec : rspec (d_cluster_sync F) (cluster_sync X). Proof. unfold d_cluster_sync, cluster_sync; spec2. Qed.
#[local] Hint Resolve d_sync_pattern_spec d_cluster_sync_spec : chk.
Lemma d_sw_spec : rspec (d_sw F) (sw X). Proof. unfold d_sw, sw; spec2. Qed.
Lemma d_RRel_spec : sspec (d_RRel F) (RRel X). Proof. unfold d_RRel, RRel; spec2. Qed.
Lemma d_RAcq_spec : sspec (d_RAcq F) (RAcq X). Proof. apply d_SyncRestrictCluster_spec. Qed.
#[local] Hint Resolve d_sw_spec d_RRel_spec d_RAcq_spec d_owner_spec d_address_spec d_subscope_star_spec : chk.

Lemma b_only_shared_spec x :
  b_only_shared F (d_address F) (fin_val x) = true <-> (forall s, (exists a, address X x a /\ space X a = s) <-> s = SShared).
Proof.
  apply bspec_foralll; [apply all_spaces_in |]; intros s; apply bspec_iff; [| apply space_eqb_eq].
  apply bspec_existsb; intros a; apply bspec_and; [apply d_address_spec | apply space_eqb_eq].
Qed.

Lemma d_rleft0_spec : rspec (d_rleft0 F) (fun x f => MemoryEvent X x /\ SyncRestrictCta X f
  /\ (forall s, (exists a, address X x a /\ space X a = s) <-> s = SShared)
  /\ (forall o, (exists a, address X x a /\ owner X a o) <-> cta_of X f o)).
Proof.
  apply rspec_mk; intros x f.
  rewrite !andb_true_iff, (d_MemoryEvent_spec x), (d_SyncRestrictCta_spec f), b_only_shared_spec.
  rewrite (forallb_fin _ (fun o => (exists a, address X x a /\ owner X a o) <-> cta_of X f o)); [reflexivity |].
  intros o; apply bspec_iff; [| apply d_cta_of_spec].
  apply bspec_existsb; intros a; apply bspec_and; [apply d_address_spec | apply d_owner_spec].
Qed.
#[local] Hint Resolve d_rleft0_spec : chk.

Lemma d_rleft_spec : rspec (d_rleft F) (rleft X). Proof. unfold d_rleft, rleft; spec2. Qed.

Lemma d_rright0_spec : rspec (d_rright0 F) (fun f y => SyncRestrictCluster X f /\ MemoryEvent X y
  /\ (forall s, (exists a, address X y a /\ space X a = s) <-> s = SShared)
  /\ (forall o, (exists a, address X y a /\ owner X a o) -> exists c, cluster_of X f c /\ (subscope X)＊ c o)).
Proof.
  apply rspec_mk; intros f y.
  rewrite !andb_true_iff, (d_SyncRestrictCluster_spec f), (d_MemoryEvent_spec y), b_only_shared_spec.
  rewrite (forallb_fin _ (fun o => (exists a, address X y a /\ owner X a o) -> exists c, cluster_of X f c
                                    /\ (subscope X)＊ c o)); [reflexivity |].
  intros o; apply bspec_imp.
  - apply bspec_existsb; intros a; apply bspec_and; [apply d_address_spec | apply d_owner_spec].
  - apply bspec_existsb; intros c; apply bspec_and; [apply d_cluster_of_spec | apply d_subscope_star_spec].
Qed.
#[local] Hint Resolve d_rleft_spec d_rright0_spec : chk.

Lemma d_rright_spec : rspec (d_rright F) (rright X). Proof. unfold d_rright, rright; spec2. Qed.
#[local] Hint Resolve d_rright_spec : chk.

Lemma d_bco_plain_spec : rspec (d_bco_plain F) (bco_plain X). Proof. unfold d_bco_plain, bco_plain; spec2. Qed.
Lemma d_sw_restricted_spec : rspec (d_sw_restricted F) (sw_restricted X).
Proof. unfold d_sw_restricted, sw_restricted; spec2. Qed.
#[local] Hint Resolve d_bco_plain_spec d_sw_restricted_spec : chk.

Lemma d_cause_base_spec : rspec (d_cause_base F) (cause_base X).
Proof. unfold d_cause_base, cause_base; cbv zeta; spec2. Qed.
#[local] Hint Resolve d_cause_base_spec : chk.

Lemma d_GenericM_spec : sspec (d_GenericM F) (GenericM X).
Proof. apply sspec_vmk; intros e; apply memp_spec. Qed.

Lemma d_AsyncW_spec : sspec (d_AsyncW F) (fun e => proxy X e Async /\ Write X e).
Proof. apply sspec_vmk; intros e; rewrite andb_true_iff, memp_spec, (d_Write_spec e); reflexivity. Qed.

Lemma mems_spec e s : mems (f_pspace F) (fin_val e) s = true <-> pspace X e s.
Proof. reflexivity. Qed.

Lemma memd_spec e p q : memd (f_dirs F) (fin_val e) p q = true <-> dirs X e p q.
Proof. reflexivity. Qed.

Lemma d_pf_space_ok_spec : rspec (d_pf_space_ok F) (pf_space_ok X).
Proof.
  apply rspec_mk; intros f m; unfold pf_space_ok.
  apply bspec_and; [apply d_ProxyFence_spec | apply bspec_and; [apply d_MemoryEvent_spec | apply bspec_and]].
  - apply bspec_or.
    + apply bspec_foralll; [apply all_spaces_in |]; intros s; apply bspec_not, mems_spec.
    + apply bspec_forallb; intros a; apply bspec_imp; [apply d_address_spec | apply mems_spec].
  - apply bspec_or.
    + apply bspec_forallb; intros a; apply bspec_not, d_paddr_spec.
    + apply bspec_forallb; intros a; apply bspec_imp; [apply d_address_spec | apply d_paddr_spec].
Qed.

Lemma d_pf_src0_spec : rspec (d_pf_src0 F)
  (fun m f => MemoryEvent X m /\ ProxyFence X f /\ (forall p, proxy X m p -> dirs X f p Generic)).
Proof.
  apply rspec_mk; intros m f.
  apply bspec_and; [apply d_MemoryEvent_spec | apply bspec_and; [apply d_ProxyFence_spec |]].
  apply bspec_foralll; [apply all_proxies_in |]; intros p; apply bspec_imp; [apply memp_spec | apply memd_spec].
Qed.

Lemma d_pf_dst0_spec : rspec (d_pf_dst0 F)
  (fun f m => ProxyFence X f /\ MemoryEvent X m /\ (forall p, proxy X m p -> dirs X f Generic p)).
Proof.
  apply rspec_mk; intros f m.
  apply bspec_and; [apply d_ProxyFence_spec | apply bspec_and; [apply d_MemoryEvent_spec |]].
  apply bspec_foralll; [apply all_proxies_in |]; intros p; apply bspec_imp; [apply memp_spec | apply memd_spec].
Qed.

Lemma d_TmFence_spec : sspec (d_TmFence F) (TmFence X).
Proof. apply sspec_vmk; intros f; unfold TmFence; rewrite andb_true_iff, (d_ProxyFence_spec f), memd_spec; reflexivity. Qed.
#[local] Hint Resolve d_GenericM_spec d_AsyncW_spec d_pf_space_ok_spec d_pf_src0_spec d_pf_dst0_spec d_TmFence_spec : chk.

Lemma d_pf_src_spec : rspec (d_pf_src F) (pf_src X). Proof. unfold d_pf_src, pf_src; spec2. Qed.
Lemma d_pf_dst_spec : rspec (d_pf_dst F) (pf_dst X). Proof. unfold d_pf_dst, pf_dst; spec2. Qed.
#[local] Hint Resolve d_pf_src_spec d_pf_dst_spec : chk.

Lemma d_pf_dst_with_spec cb R : rspec cb R -> rspec (d_pf_dst_with F cb) (pf_dst_with X R).
Proof. intros H; unfold d_pf_dst_with, pf_dst_with; spec2. Qed.

Lemma d_ppbco_with_spec cb R : rspec cb R -> rspec (d_ppbco_with F cb) (ppbco_with X R).
Proof.
  intros H; pose proof (d_pf_dst_with_spec H) as Hp.
  unfold d_ppbco_with, ppbco_with, d_same_alias, d_same_location, same_alias, same_location; cbv zeta.
  spec2.
Qed.

Lemma d_ppbco_spec : rspec (d_ppbco F) (ppbco X).
Proof. apply d_ppbco_with_spec, d_cause_base_spec. Qed.
#[local] Hint Resolve d_ppbco_spec : chk.

Lemma d_cause_spec : rspec (d_cause F) (cause X). Proof. unfold d_cause, cause; spec2. Qed.
#[local] Hint Resolve d_cause_spec : chk.

Lemma b_coherence_spec : bspec (b_coherence F) (coherence X).
Proof. unfold b_coherence, coherence, d_same_location, same_location; spec2. Qed.

Lemma b_fence_sc_spec : bspec (b_fence_sc F) (fence_sc X).
Proof. unfold b_fence_sc, fence_sc; spec2. Qed.

Lemma d_acc_lift_spec r R : rspec r R -> rspec (d_acc_lift F r) (acc_lift X R).
Proof. intros H; unfold d_acc_lift, acc_lift; spec2. Qed.

Lemma d_AtomicR_spec : sspec (d_AtomicR F) (AtomicR X).
Proof.
  apply sspec_vmk; intros e; unfold AtomicR; apply existsb_fin; intros w.
  rewrite andb_true_iff, (d_rmw_spec e w), (d_Write_spec w); reflexivity.
Qed.

Lemma d_Atomics_spec : sspec (d_Atomics F) (Atomics X).
Proof.
  apply sspec_vmk; intros e; unfold Atomics; apply bspec_or; [apply d_AtomicR_spec |].
  apply bspec_existsb; intros r; apply bspec_and; [apply d_AtomicR_spec | apply d_rmw_spec].
Qed.
#[local] Hint Resolve d_Atomics_spec : chk.

Lemma d_atomic_pair_r_spec : rspec (d_atomic_pair_r F) (atomic_pair_r X).
Proof. unfold d_atomic_pair_r, atomic_pair_r; spec2. Qed.
#[local] Hint Resolve d_atomic_pair_r_spec : chk.

Lemma b_atomicity_spec : bspec (b_atomicity F) (atomicity X).
Proof.
  unfold b_atomicity, atomicity; apply bspec_and; apply bspec_none.
  - apply rspec_inter; [spec2 | apply rspec_inter; apply d_acc_lift_spec; spec2].
  - spec2.
Qed.

Lemma b_no_thin_air_spec : bspec (b_no_thin_air F) (no_thin_air X).
Proof. unfold b_no_thin_air, no_thin_air; spec2. Qed.
Lemma b_sc_per_location_spec : bspec (b_sc_per_location F) (sc_per_location X).
Proof. unfold b_sc_per_location, sc_per_location; spec2. Qed.
Lemma b_causality_spec : bspec (b_causality F) (causality X).
Proof. unfold b_causality, causality; spec2. Qed.

Theorem b_consistent_spec : bspec (b_consistent F) (consistent X).
Proof.
  unfold b_consistent, consistent.
  apply bspec_and; [apply b_coherence_spec |]; apply bspec_and; [apply b_fence_sc_spec |].
  apply bspec_and; [apply b_atomicity_spec |]; apply bspec_and; [apply b_no_thin_air_spec |].
  apply bspec_and; [apply b_sc_per_location_spec | apply b_causality_spec].
Qed.

Lemma d_fpal_spec : rspec (d_fpal F) (fun e b => exists a, footprint X e a /\ aliases X a b).
Proof. exact (rspec_seq_het d_footprint_spec d_aliases_spec). Qed.

Lemma d_unordered_spec : rspec (d_unordered F) (ms_r X ∪ cause X ∪ (cause X)⁻¹).
Proof. unfold d_unordered; spec2. Qed.

Theorem b_mixed_size_race_spec : bspec (b_mixed_size_race F) (mixed_size_race X).
Proof.
  unfold b_mixed_size_race, mixed_size_race.
  apply bspec_existsb; intros e1; apply bspec_existsb; intros e2.
  apply bspec_and; [apply bspec_not, bspec_fin_eq |].
  apply bspec_and; [apply d_MemoryEvent_spec |]; apply bspec_and; [apply d_MemoryEvent_spec |].
  apply bspec_and; [apply d_same_location_r_spec |].
  apply bspec_and; [apply bspec_not, bspec_forallb; intros b; apply bspec_iff; apply d_fpal_spec |].
  apply bspec_and; [apply bspec_or; apply d_Write_spec | apply bspec_not, d_unordered_spec].
Qed.

Theorem b_undefined_spec : bspec (b_undefined F) (undefined X).
Proof. apply b_mb_undefined_spec. Qed.

(** ** Well-formedness *)

Lemma bspec_opt_forall (o : option Z) q Q : bspec q Q -> bspec (implb (is_some o) q) (forall k, o = Some k -> Q).
Proof.
  unfold bspec; destruct o as [k |]; simpl; intros H; split.
  - intros Hq k' _; apply H, Hq.
  - intros Hall; apply H, (Hall k eq_refl).
  - intros _ k' E; discriminate.
  - reflexivity.
Qed.

Lemma bspec_is_none (o : option Z) : bspec (is_none o) (o = None).
Proof. unfold bspec; destruct o; simpl; split; congruence. Qed.

Lemma bspec_get_scope {m} M (R : Fin nS -> Fin m -> Prop) e y :
  rspec M R -> bspec (get M (scope_at F (fin_val e)) (fin_val y)) (R (scope X e) y).
Proof. intros H; exact (H (scope X e) y). Qed.

Lemma bspec_vget_scope v (P : Fin nS -> Prop) e : sspec v P -> bspec (vget v (scope_at F (fin_val e))) (P (scope X e)).
Proof. intros H; exact (H (scope X e)). Qed.

Lemma d_co_plus_spec : rspec (d_co_plus F) (co X)⁺. Proof. apply rspec_plus, d_co_spec. Qed.
Lemma d_po_plus_spec : rspec (d_po_plus F) (po X)⁺. Proof. apply rspec_plus, d_po_spec. Qed.
Lemma d_same_scope_spec : rspec (d_same_scope F) (fun e1 e2 => scope X e1 = scope X e2).
Proof. apply rspec_mk; intros x y; rewrite Nat.eqb_eq, fin_eq_iff; reflexivity. Qed.
Lemma d_same_bid_spec : rspec (d_same_bid F) (same_bid X).
Proof.
  apply rspec_mk; intros a b; unfold same_bid.
  rewrite !andb_true_iff, (d_BarrierArrive_spec a), (d_BarrierArrive_spec b), Z.eqb_eq; reflexivity.
Qed.
Lemma d_same_cluster_spec : rspec (d_same_cluster F) (fun a b => exists c, cluster_of X a c /\ cluster_of X b c).
Proof. exact (rspec_seq_het d_cluster_of_spec (rspec_inv_het d_cluster_of_spec)). Qed.
#[local] Hint Resolve d_co_plus_spec d_po_plus_spec d_same_scope_spec d_same_bid_spec d_same_cluster_spec
  d_start_spec d_alias_spec d_acc_spec d_paddr_spec d_ms_r_spec : chk.

Lemma count_fin (p : nat -> bool) :
  length (filter (fun x : Fin n => p (fin_val x)) (fin_all n)) = length (filter p (List.seq 0 n)).
Proof.
  rewrite <- (fin_all_vals n); induction (fin_all n) as [| x l IH]; simpl; [reflexivity |].
  destruct (p (fin_val x)); simpl; rewrite IH; reflexivity.
Qed.

Lemma b_barriers_9_spec : bspec (b_barriers_9 F)
  (forall a n0, BarrierArrive X a -> bcount X a = Some n0 -> card_is (bgen X a) n0).
Proof.
  unfold b_barriers_9; cbv zeta.
  apply bspec_forallb; intros a; cbv beta; unfold bspec.
  rewrite implb_true_iff, (d_BarrierArrive_spec a).
  change (oat (f_bcount F) (fin_val a)) with (bcount X a).
  destruct (bcount X a) as [k |] eqn:E; split.
  - intros H k' Hba Hk; injection Hk as <-; specialize (H Hba); apply Z.eqb_eq in H.
    apply (card_is_count (fun b => get (d_bgen F) (fin_val a) b)); [intros b; apply d_bgen_spec |].
    rewrite count_fin; exact H.
  - intros H Hba; apply Z.eqb_eq; specialize (H k Hba eq_refl).
    rewrite <- count_fin.
    exact (proj1 (@card_is_count n (fun b => get (d_bgen F) (fin_val a) b) (bgen X a) k (fun b => d_bgen_spec a b)) H).
  - intros _ k' _ Hk; discriminate.
  - intros _ _; reflexivity.
Qed.

Ltac bstep :=
  match goal with
  | |- bspec (implb (is_some _) _) _ => apply bspec_opt_forall
  | |- bspec (is_none _) _ => apply bspec_is_none
  | |- bspec (_ && _) _ => apply bspec_and
  | |- bspec (_ || _) _ => apply bspec_or
  | |- bspec (negb _) _ => apply bspec_not
  | |- bspec (implb _ _) _ => apply bspec_imp
  | |- bspec (Bool.eqb _ _) _ => apply bspec_iff
  | |- bspec (forallb _ (List.seq 0 _)) _ => apply bspec_forallb; intro; cbv beta
  | |- bspec (existsb _ (List.seq 0 _)) _ => apply bspec_existsb; intro; cbv beta
  | |- bspec (forallb _ all_proxies) _ => apply bspec_foralll; [apply all_proxies_in | intro; cbv beta]
  | |- bspec (existsb _ all_proxies) _ => apply bspec_existsl; [apply all_proxies_in | intro; cbv beta]
  | |- bspec (forallb _ all_spaces) _ => apply bspec_foralll; [apply all_spaces_in | intro; cbv beta]
  | |- bspec (Z.eqb _ _) _ => apply bspec_Zeq
  | |- bspec (Nat.eqb _ _) _ => apply bspec_fin_eq
  | |- bspec (proxy_eqb _ _) _ => apply proxy_eqb_eq
  | |- bspec (space_eqb _ _) _ => apply space_eqb_eq
  | |- bspec (memp _ _ _) _ => apply memp_spec
  | |- bspec (mems _ _ _) _ => apply mems_spec
  | |- bspec (memd _ _ _ _) _ => apply memd_spec
  | |- bspec (get _ (scope_at _ _) _) _ => apply bspec_get_scope; solve [auto with chk spec]
  | |- bspec (vget _ (scope_at _ _)) _ => apply bspec_vget_scope; solve [auto with chk spec]
  | |- bspec (get _ _ _) _ => apply bspec_get; solve [auto with chk spec]
  | |- bspec (vget _ _) _ => apply bspec_vget; solve [auto with chk spec]
  | |- bspec (bsubset _ _ _ _) _ => apply bspec_subset; spec2
  | |- bspec (bacyclic _ _) _ => apply bspec_acyclic; spec2
  end.
Ltac bsolve := repeat bstep.

Lemma bspec_use b P : bspec b P -> b = true -> P.
Proof. intros H; apply H. Qed.
Lemma bspec_back b P : bspec b P -> P -> b = true.
Proof. intros H; apply H. Qed.

Ltac use b H := eapply (@bspec_use (b F)); [unfold b; cbv zeta; bsolve | exact H].
Ltac back b p := let T := type of p in refine (@bspec_back (b F) T _ p); unfold b; cbv zeta; bsolve.
Ltac use9 H := eapply bspec_use; [apply b_barriers_9_spec | exact H].
Ltac back9 p := refine (bspec_back b_barriers_9_spec p).

Theorem b_wf_prog_spec : bspec (b_wf_prog F) (wf_prog X).
Proof.
  split.
  - intros Hb; unfold b_wf_prog in Hb.
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
    apply andb_prop in Hb; destruct Hb as [H14 Hb].
    apply andb_prop in Hb; destruct Hb as [H15 Hb].
    apply andb_prop in Hb; destruct Hb as [H16 Hb].
    apply andb_prop in Hb; destruct Hb as [H17 Hb].
    apply andb_prop in Hb; destruct Hb as [H18 Hb].
    apply andb_prop in Hb; destruct Hb as [H19 Hb].
    apply andb_prop in Hb; destruct Hb as [H20 Hb].
    apply andb_prop in Hb; destruct Hb as [H21 Hb].
    apply andb_prop in Hb; destruct Hb as [H22 Hb].
    apply andb_prop in Hb; destruct Hb as [H23 Hb].
    apply andb_prop in Hb; destruct Hb as [H24 Hb].
    apply andb_prop in Hb; destruct Hb as [H25 Hb].
    apply andb_prop in Hb; destruct Hb as [H26 Hb].
    apply andb_prop in Hb; destruct Hb as [H27 Hb].
    apply andb_prop in Hb; destruct Hb as [H28 Hb].
    apply andb_prop in Hb; destruct Hb as [H29 Hb].
    apply andb_prop in Hb; destruct Hb as [H30 Hb].
    apply andb_prop in Hb; destruct Hb as [H31 Hb].
    apply andb_prop in Hb; destruct Hb as [H32 Hb].
    apply andb_prop in Hb; destruct Hb as [H33 Hb].
    apply andb_prop in Hb; destruct Hb as [H34 Hb].
    apply andb_prop in Hb; destruct Hb as [H35 Hb].
    apply andb_prop in Hb; destruct Hb as [H36 Hb].
    apply andb_prop in Hb; destruct Hb as [H37 Hb].
    apply andb_prop in Hb; destruct Hb as [H38 Hb].
    apply andb_prop in Hb; destruct Hb as [H39 Hb].
    apply andb_prop in Hb; destruct Hb as [H40 Hb].
    apply andb_prop in Hb; destruct Hb as [H41 Hb].
    apply andb_prop in Hb; destruct Hb as [H42 Hb].
    apply andb_prop in Hb; destruct Hb as [H43 Hb].
    apply andb_prop in Hb; destruct Hb as [H44 Hb].
    apply andb_prop in Hb; destruct Hb as [H45 Hb].
    apply andb_prop in Hb; destruct Hb as [H46 Hb].
    apply andb_prop in Hb; destruct Hb as [H47 Hb].
    apply andb_prop in Hb; destruct Hb as [H48 Hb].
    apply andb_prop in Hb; destruct Hb as [H49 Hb].
    apply andb_prop in Hb; destruct Hb as [H50 Hb].
    apply andb_prop in Hb; destruct Hb as [H51 Hb].
    apply andb_prop in Hb; destruct Hb as [H52 Hb].
    apply andb_prop in Hb; destruct Hb as [H53 Hb].
    apply andb_prop in Hb; destruct Hb as [H54 Hb].
    apply andb_prop in Hb; destruct Hb as [H55 Hb].
    apply andb_prop in Hb; destruct Hb as [H56 Hb].
    rename Hb into H57.
    constructor.
    + use b_decl_start H0.
    + use b_decl_start_one H1.
    + use b_decl_owner_lone H2.
    + use b_decl_po_lone H3.
    + use b_decl_address H4.
    + use b_decl_address_one H5.
    + use b_decl_proxy H6.
    + use b_decl_proxy_one H7.
    + use b_decl_acc H8.
    + use b_decl_acc_lone H9.
    + use b_decl_rmw H10.
    + use b_decl_rmw_lone H11.
    + use b_decl_dep H12.
    + use b_decl_SyncRestrictCta H13.
    + use b_decl_SyncRestrictCluster H14.
    + use b_decl_OpRestrictInit H15.
    + use b_decl_dirs H16.
    + use b_decl_pspace H17.
    + use b_decl_paddr H18.
    + use b_decl_bcount H19.
    + use b_decl_bwait H20.
    + use b_decl_bwait_lone H21.
    + use b_decl_cwait H22.
    + use b_decl_cwait_lone H23.
    + use b_decl_ClusterArriveRelaxed H24.
    + use b_decl_MbarEv H25.
    + use b_decl_MbarInit H26.
    + use b_decl_MbarWait H27.
    + use b_decl_wpar H28.
    + use b_decl_wtok H29.
    + use b_decl_TxAnchor H30.
    + use b_decl_txops H31.
    + use b_sig_Acquire H32.
    + use b_sig_Release H33.
    + use b_sig_Fence H34.
    + use b_scope_tree_1 H35.
    + use b_scope_tree_2 H36.
    + use b_scope_tree_3 H37.
    + use b_scope_tree_4 H38.
    + use b_scope_tree_5 H39.
    + use b_address_facts_1 H40.
    + use b_address_facts_2 H41.
    + use b_address_facts_3 H42.
    + use b_threads_1 H43.
    + use b_threads_2 H44.
    + use b_threads_3 H45.
    + use b_communication_5 H46.
    + use b_dependencies_1 H47.
    + use b_dependencies_2 H48.
    + use b_mbarrier_state_1 H49.
    + use b_mbarrier_state_2 H50.
    + use b_mbarrier_state_4 H51.
    + use b_barriers_1 H52.
    + use b_barriers_2 H53.
    + use b_cluster_barriers_1 H54.
    + use b_cluster_barriers_2 H55.
    + use b_cluster_barriers_3 H56.
    + use b_async_units_2 H57.
  - intros H; unfold b_wf_prog.
    apply andb_true_iff; split; [back b_decl_start (decl_start H) |].
    apply andb_true_iff; split; [back b_decl_start_one (decl_start_one H) |].
    apply andb_true_iff; split; [back b_decl_owner_lone (decl_owner_lone H) |].
    apply andb_true_iff; split; [back b_decl_po_lone (decl_po_lone H) |].
    apply andb_true_iff; split; [back b_decl_address (decl_address H) |].
    apply andb_true_iff; split; [back b_decl_address_one (decl_address_one H) |].
    apply andb_true_iff; split; [back b_decl_proxy (decl_proxy H) |].
    apply andb_true_iff; split; [back b_decl_proxy_one (decl_proxy_one H) |].
    apply andb_true_iff; split; [back b_decl_acc (decl_acc H) |].
    apply andb_true_iff; split; [back b_decl_acc_lone (decl_acc_lone H) |].
    apply andb_true_iff; split; [back b_decl_rmw (decl_rmw H) |].
    apply andb_true_iff; split; [back b_decl_rmw_lone (decl_rmw_lone H) |].
    apply andb_true_iff; split; [back b_decl_dep (decl_dep H) |].
    apply andb_true_iff; split; [back b_decl_SyncRestrictCta (decl_SyncRestrictCta H) |].
    apply andb_true_iff; split; [back b_decl_SyncRestrictCluster (decl_SyncRestrictCluster H) |].
    apply andb_true_iff; split; [back b_decl_OpRestrictInit (decl_OpRestrictInit H) |].
    apply andb_true_iff; split; [back b_decl_dirs (decl_dirs H) |].
    apply andb_true_iff; split; [back b_decl_pspace (decl_pspace H) |].
    apply andb_true_iff; split; [back b_decl_paddr (decl_paddr H) |].
    apply andb_true_iff; split; [back b_decl_bcount (decl_bcount H) |].
    apply andb_true_iff; split; [back b_decl_bwait (decl_bwait H) |].
    apply andb_true_iff; split; [back b_decl_bwait_lone (decl_bwait_lone H) |].
    apply andb_true_iff; split; [back b_decl_cwait (decl_cwait H) |].
    apply andb_true_iff; split; [back b_decl_cwait_lone (decl_cwait_lone H) |].
    apply andb_true_iff; split; [back b_decl_ClusterArriveRelaxed (decl_ClusterArriveRelaxed H) |].
    apply andb_true_iff; split; [back b_decl_MbarEv (decl_MbarEv H) |].
    apply andb_true_iff; split; [back b_decl_MbarInit (decl_MbarInit H) |].
    apply andb_true_iff; split; [back b_decl_MbarWait (decl_MbarWait H) |].
    apply andb_true_iff; split; [back b_decl_wpar (decl_wpar H) |].
    apply andb_true_iff; split; [back b_decl_wtok (decl_wtok H) |].
    apply andb_true_iff; split; [back b_decl_TxAnchor (decl_TxAnchor H) |].
    apply andb_true_iff; split; [back b_decl_txops (decl_txops H) |].
    apply andb_true_iff; split; [back b_sig_Acquire (sig_Acquire H) |].
    apply andb_true_iff; split; [back b_sig_Release (sig_Release H) |].
    apply andb_true_iff; split; [back b_sig_Fence (sig_Fence H) |].
    apply andb_true_iff; split; [back b_scope_tree_1 (scope_tree_1 H) |].
    apply andb_true_iff; split; [back b_scope_tree_2 (scope_tree_2 H) |].
    apply andb_true_iff; split; [back b_scope_tree_3 (scope_tree_3 H) |].
    apply andb_true_iff; split; [back b_scope_tree_4 (scope_tree_4 H) |].
    apply andb_true_iff; split; [back b_scope_tree_5 (scope_tree_5 H) |].
    apply andb_true_iff; split; [back b_address_facts_1 (address_facts_1 H) |].
    apply andb_true_iff; split; [back b_address_facts_2 (address_facts_2 H) |].
    apply andb_true_iff; split; [back b_address_facts_3 (address_facts_3 H) |].
    apply andb_true_iff; split; [back b_threads_1 (threads_1 H) |].
    apply andb_true_iff; split; [back b_threads_2 (threads_2 H) |].
    apply andb_true_iff; split; [back b_threads_3 (threads_3 H) |].
    apply andb_true_iff; split; [back b_communication_5 (communication_5 H) |].
    apply andb_true_iff; split; [back b_dependencies_1 (dependencies_1 H) |].
    apply andb_true_iff; split; [back b_dependencies_2 (dependencies_2 H) |].
    apply andb_true_iff; split; [back b_mbarrier_state_1 (mbarrier_state_1 H) |].
    apply andb_true_iff; split; [back b_mbarrier_state_2 (mbarrier_state_2 H) |].
    apply andb_true_iff; split; [back b_mbarrier_state_4 (mbarrier_state_4 H) |].
    apply andb_true_iff; split; [back b_barriers_1 (barriers_1 H) |].
    apply andb_true_iff; split; [back b_barriers_2 (barriers_2 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_1 (cluster_barriers_1 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_2 (cluster_barriers_2 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_3 (cluster_barriers_3 H) |].
    back b_async_units_2 (async_units_2 H).
Qed.

Theorem b_wf_exec_spec : bspec (b_wf_exec F) (wf_exec X).
Proof.
  split.
  - intros Hb; unfold b_wf_exec in Hb.
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
    apply andb_prop in Hb; destruct Hb as [H14 Hb].
    apply andb_prop in Hb; destruct Hb as [H15 Hb].
    apply andb_prop in Hb; destruct Hb as [H16 Hb].
    apply andb_prop in Hb; destruct Hb as [H17 Hb].
    apply andb_prop in Hb; destruct Hb as [H18 Hb].
    apply andb_prop in Hb; destruct Hb as [H19 Hb].
    apply andb_prop in Hb; destruct Hb as [H20 Hb].
    apply andb_prop in Hb; destruct Hb as [H21 Hb].
    apply andb_prop in Hb; destruct Hb as [H22 Hb].
    apply andb_prop in Hb; destruct Hb as [H23 Hb].
    apply andb_prop in Hb; destruct Hb as [H24 Hb].
    apply andb_prop in Hb; destruct Hb as [H25 Hb].
    apply andb_prop in Hb; destruct Hb as [H26 Hb].
    apply andb_prop in Hb; destruct Hb as [H27 Hb].
    apply andb_prop in Hb; destruct Hb as [H28 Hb].
    apply andb_prop in Hb; destruct Hb as [H29 Hb].
    apply andb_prop in Hb; destruct Hb as [H30 Hb].
    apply andb_prop in Hb; destruct Hb as [H31 Hb].
    rename Hb into H32.
    constructor.
    + use b_decl_rf H0.
    + use b_decl_co H1.
    + use b_decl_sc H2.
    + use b_decl_bgen H3.
    + use b_decl_synchronizes H4.
    + use b_decl_cgen H5.
    + use b_mbarrier_state_3 H6.
    + use b_mbarrier_state_5 H7.
    + use b_communication_1 H8.
    + use b_communication_2 H9.
    + use b_communication_3 H10.
    + use b_communication_4 H11.
    + use b_co_strong_1 H12.
    + use b_co_strong_2 H13.
    + use b_fence_sc_order_1 H14.
    + use b_fence_sc_order_2 H15.
    + use b_fence_sc_order_3 H16.
    + use b_barriers_3 H17.
    + use b_barriers_4 H18.
    + use b_barriers_5 H19.
    + use b_barriers_6 H20.
    + use b_barriers_7 H21.
    + use b_barriers_8 H22.
    + use9 H23.
    + use b_barriers_10 H24.
    + use b_barriers_11 H25.
    + use b_cluster_barriers_4 H26.
    + use b_cluster_barriers_5 H27.
    + use b_cluster_barriers_6 H28.
    + use b_cluster_barriers_7 H29.
    + use b_cluster_barriers_8 H30.
    + use b_cluster_barriers_9 H31.
    + use b_cluster_barriers_10 H32.
  - intros H; unfold b_wf_exec.
    apply andb_true_iff; split; [back b_decl_rf (decl_rf H) |].
    apply andb_true_iff; split; [back b_decl_co (decl_co H) |].
    apply andb_true_iff; split; [back b_decl_sc (decl_sc H) |].
    apply andb_true_iff; split; [back b_decl_bgen (decl_bgen H) |].
    apply andb_true_iff; split; [back b_decl_synchronizes (decl_synchronizes H) |].
    apply andb_true_iff; split; [back b_decl_cgen (decl_cgen H) |].
    apply andb_true_iff; split; [back b_mbarrier_state_3 (mbarrier_state_3 H) |].
    apply andb_true_iff; split; [back b_mbarrier_state_5 (mbarrier_state_5 H) |].
    apply andb_true_iff; split; [back b_communication_1 (communication_1 H) |].
    apply andb_true_iff; split; [back b_communication_2 (communication_2 H) |].
    apply andb_true_iff; split; [back b_communication_3 (communication_3 H) |].
    apply andb_true_iff; split; [back b_communication_4 (communication_4 H) |].
    apply andb_true_iff; split; [back b_co_strong_1 (co_strong_1 H) |].
    apply andb_true_iff; split; [back b_co_strong_2 (co_strong_2 H) |].
    apply andb_true_iff; split; [back b_fence_sc_order_1 (fence_sc_order_1 H) |].
    apply andb_true_iff; split; [back b_fence_sc_order_2 (fence_sc_order_2 H) |].
    apply andb_true_iff; split; [back b_fence_sc_order_3 (fence_sc_order_3 H) |].
    apply andb_true_iff; split; [back b_barriers_3 (barriers_3 H) |].
    apply andb_true_iff; split; [back b_barriers_4 (barriers_4 H) |].
    apply andb_true_iff; split; [back b_barriers_5 (barriers_5 H) |].
    apply andb_true_iff; split; [back b_barriers_6 (barriers_6 H) |].
    apply andb_true_iff; split; [back b_barriers_7 (barriers_7 H) |].
    apply andb_true_iff; split; [back b_barriers_8 (barriers_8 H) |].
    apply andb_true_iff; split; [back9 (barriers_9 H) |].
    apply andb_true_iff; split; [back b_barriers_10 (barriers_10 H) |].
    apply andb_true_iff; split; [back b_barriers_11 (barriers_11 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_4 (cluster_barriers_4 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_5 (cluster_barriers_5 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_6 (cluster_barriers_6 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_7 (cluster_barriers_7 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_8 (cluster_barriers_8 H) |].
    apply andb_true_iff; split; [back b_cluster_barriers_9 (cluster_barriers_9 H) |].
    back b_cluster_barriers_10 (cluster_barriers_10 H).
Qed.

End Spec.
