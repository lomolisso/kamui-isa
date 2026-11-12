(** * Finite executions

    [FExec] is an execution written down as data: the sizes of the four carriers, lists of the values of the
    functions and lists of the tuples of the relations, with every atom a number. It is what the checker reads
    (see [extract/FORMAT.md]). [denote] turns it into an [Exec] over the carriers [Fin n], the numbers below
    [n]; the checkers are proved against [denote]. *)

From Stdlib Require Import Arith Bool List ZArith Lia.
From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87.
From KamuiProof.lib Require Import Mat.
Import ListNotations.

Set Implicit Arguments.

(** ** Equality tests for the enumerated types *)

Definition skind_eqb (a b : ScopeKind) : bool :=
  match a, b with
  | SNode, SNode | SCta, SCta | SCluster, SCluster | SThread, SThread | SAsyncUnit, SAsyncUnit => true
  | _, _ => false
  end.

Definition proxy_eqb (a b : Proxy) : bool :=
  match a, b with
  | Generic, Generic | Async, Async | TensorMap, TensorMap | Texture, Texture | Surface, Surface
  | Constant, Constant => true
  | _, _ => false
  end.

Definition space_eqb (a b : Space) : bool :=
  match a, b with
  | SGlobal, SGlobal | SShared, SShared | SLocal, SLocal | SConst, SConst | SParam, SParam => true
  | _, _ => false
  end.

Definition kind_eqb (a b : Kind) : bool :=
  match a, b with
  | KRead, KRead | KAcquire, KAcquire | KWrite, KWrite | KRelease, KRelease
  | KFenceAcq, KFenceAcq | KFenceRel, KFenceRel | KFenceAcqRel, KFenceAcqRel | KFenceSC, KFenceSC
  | KAliasFence, KAliasFence | KPlainProxyFence, KPlainProxyFence
  | KBarrierArrive, KBarrierArrive | KBarrierWait, KBarrierWait
  | KClusterArrive, KClusterArrive | KClusterWait, KClusterWait | KMarker, KMarker => true
  | _, _ => false
  end.

Lemma skind_eqb_eq a b : skind_eqb a b = true <-> a = b.
Proof. destruct a, b; simpl; split; congruence. Qed.
Lemma proxy_eqb_eq a b : proxy_eqb a b = true <-> a = b.
Proof. destruct a, b; simpl; split; congruence. Qed.
Lemma space_eqb_eq a b : space_eqb a b = true <-> a = b.
Proof. destruct a, b; simpl; split; congruence. Qed.
Lemma kind_eqb_eq a b : kind_eqb a b = true <-> a = b.
Proof. destruct a, b; simpl; split; congruence. Qed.

Definition all_proxies : list Proxy := [Generic; Async; TensorMap; Texture; Surface; Constant].
Definition all_spaces : list Space := [SGlobal; SShared; SLocal; SConst; SParam].

Lemma all_proxies_in p : In p all_proxies.
Proof. destruct p; simpl; tauto. Qed.
Lemma all_spaces_in s : In s all_spaces.
Proof. destruct s; simpl; tauto. Qed.

Lemma existsb_list {T} (l : list T) (p : T -> bool) (P : T -> Prop) :
  (forall x, In x l) -> (forall x, p x = true <-> P x) -> (existsb p l = true <-> exists x, P x).
Proof.
  intros Hall H; rewrite existsb_exists; split.
  - intros [x [_ Hx]]; exists x; apply H, Hx.
  - intros [x Hx]; exists x; split; [apply Hall | apply H, Hx].
Qed.

Lemma forallb_list {T} (l : list T) (p : T -> bool) (P : T -> Prop) :
  (forall x, In x l) -> (forall x, p x = true <-> P x) -> (forallb p l = true <-> forall x, P x).
Proof.
  intros Hall H; rewrite forallb_forall; split.
  - intros Hl x; apply H, Hl, Hall.
  - intros Hl x _; apply H, Hl.
Qed.

(** ** Finite executions *)

Record FExec := {
  ne : nat; ns : nat; na : nat; nc : nat;
  f_skind : list ScopeKind; f_subscope : list (nat * nat); f_start : list (nat * nat);
  f_alias : list (nat * nat); f_space : list Space; f_owner : list (nat * nat); f_init : list Z;
  f_kind : list Kind; f_po : list (nat * nat); f_scope : list nat;
  f_issue : list (nat * nat); f_done : list (nat * nat); f_gdep : list (nat * nat);
  f_address : list (nat * nat); f_proxy : list (nat * Proxy); f_val : list Z; f_acc : list (nat * nat);
  f_vacc : list (nat * nat);
  f_rmw : list (nat * nat); f_dep : list (nat * nat); f_rf : list (nat * nat); f_co : list (nat * nat);
  f_sc : list (nat * nat);
  f_SyncRestrictCta : list nat; f_SyncRestrictCluster : list nat; f_OpRestrictInit : list nat;
  f_ProxyFence : list nat; f_dirs : list (nat * Proxy * Proxy); f_pspace : list (nat * Space);
  f_paddr : list (nat * nat);
  f_bid : list Z; f_bcount : list (option Z); f_bwait : list (nat * nat); f_bgen : list (nat * nat);
  f_synchronizes : list (nat * nat);
  f_cwait : list (nat * nat); f_cgen : list (nat * nat); f_ClusterArriveRelaxed : list nat;
  f_Mbar : list nat; f_iph : list Z; f_ipend : list Z; f_iexp : list Z; f_itx : list Z;
  f_MbarEv : list nat; f_ph : list Z; f_pend : list Z; f_expc : list Z; f_tx : list Z;
  f_MbarInit : list nat; f_MbarWait : list nat; f_wpar : list (option Z); f_wtok : list (option Z);
  f_TxAnchor : list nat; f_txops : list (nat * nat);
}.

(** Membership in the lists of tuples. *)
Definition mem1 (l : list nat) (i : nat) : bool := existsb (Nat.eqb i) l.
Definition mem2 (l : list (nat * nat)) (i j : nat) : bool :=
  existsb (fun '(a, b) => Nat.eqb a i && Nat.eqb b j) l.
Definition memp (l : list (nat * Proxy)) (i : nat) (p : Proxy) : bool :=
  existsb (fun '(a, q) => Nat.eqb a i && proxy_eqb q p) l.
Definition mems (l : list (nat * Space)) (i : nat) (s : Space) : bool :=
  existsb (fun '(a, t) => Nat.eqb a i && space_eqb t s) l.
Definition memd (l : list (nat * Proxy * Proxy)) (i : nat) (p q : Proxy) : bool :=
  existsb (fun '(a, p', q') => Nat.eqb a i && proxy_eqb p' p && proxy_eqb q' q) l.

Definition zat (l : list Z) (i : nat) : Z := nth i l 0%Z.
Definition oat (l : list (option Z)) (i : nat) : option Z := nth i l None.

(** The one condition [denote] needs: every event's scope is a scope. The checker also checks the other indices
    (in the driver), but [denote] ignores a tuple out of range. *)
Definition valid (F : FExec) : bool := forallb (fun i => Nat.ltb (nth i (f_scope F) 0) (ns F)) (List.seq 0 (ne F)).

Lemma valid_scope F (V : valid F = true) i : i < ne F -> nth i (f_scope F) 0 < ns F.
Proof.
  intros H; unfold valid in V; rewrite forallb_forall in V.
  apply Nat.ltb_lt, V, in_seq; lia.
Qed.

Definition denote (F : FExec) (V : valid F = true) : Exec (Fin (ne F)) (Fin (ns F)) (Fin (na F)) (Fin (nc F)) := {|
  skind := fun s => nth (fin_val s) (f_skind F) SNode;
  subscope := fun s t => mem2 (f_subscope F) (fin_val s) (fin_val t) = true;
  start := fun t e => mem2 (f_start F) (fin_val t) (fin_val e) = true;
  alias := fun a b => mem2 (f_alias F) (fin_val a) (fin_val b) = true;
  space := fun a => nth (fin_val a) (f_space F) SGlobal;
  owner := fun a s => mem2 (f_owner F) (fin_val a) (fin_val s) = true;
  init := fun a => zat (f_init F) (fin_val a);
  kind := fun e => nth (fin_val e) (f_kind F) KMarker;
  po := fun e e' => mem2 (f_po F) (fin_val e) (fin_val e') = true;
  scope := fun e => to_fin (@valid_scope F V (fin_val e) (fin_lt e));
  issue := fun e e' => mem2 (f_issue F) (fin_val e) (fin_val e') = true;
  done := fun e e' => mem2 (f_done F) (fin_val e) (fin_val e') = true;
  gdep := fun e e' => mem2 (f_gdep F) (fin_val e) (fin_val e') = true;
  address := fun e a => mem2 (f_address F) (fin_val e) (fin_val a) = true;
  proxy := fun e p => memp (f_proxy F) (fin_val e) p = true;
  val := fun e => zat (f_val F) (fin_val e);
  acc := fun e c => mem2 (f_acc F) (fin_val e) (fin_val c) = true;
  vacc := fun e c => mem2 (f_vacc F) (fin_val e) (fin_val c) = true;
  rmw := fun e e' => mem2 (f_rmw F) (fin_val e) (fin_val e') = true;
  dep := fun e e' => mem2 (f_dep F) (fin_val e) (fin_val e') = true;
  rf := fun e e' => mem2 (f_rf F) (fin_val e) (fin_val e') = true;
  co := fun e e' => mem2 (f_co F) (fin_val e) (fin_val e') = true;
  sc := fun e e' => mem2 (f_sc F) (fin_val e) (fin_val e') = true;
  SyncRestrictCta := fun e => mem1 (f_SyncRestrictCta F) (fin_val e) = true;
  SyncRestrictCluster := fun e => mem1 (f_SyncRestrictCluster F) (fin_val e) = true;
  OpRestrictInit := fun e => mem1 (f_OpRestrictInit F) (fin_val e) = true;
  ProxyFence := fun e => mem1 (f_ProxyFence F) (fin_val e) = true;
  dirs := fun e p q => memd (f_dirs F) (fin_val e) p q = true;
  pspace := fun e s => mems (f_pspace F) (fin_val e) s = true;
  paddr := fun e a => mem2 (f_paddr F) (fin_val e) (fin_val a) = true;
  bid := fun e => zat (f_bid F) (fin_val e);
  bcount := fun e => oat (f_bcount F) (fin_val e);
  bwait := fun e e' => mem2 (f_bwait F) (fin_val e) (fin_val e') = true;
  bgen := fun e e' => mem2 (f_bgen F) (fin_val e) (fin_val e') = true;
  synchronizes := fun e e' => mem2 (f_synchronizes F) (fin_val e) (fin_val e') = true;
  cwait := fun e e' => mem2 (f_cwait F) (fin_val e) (fin_val e') = true;
  cgen := fun e e' => mem2 (f_cgen F) (fin_val e) (fin_val e') = true;
  ClusterArriveRelaxed := fun e => mem1 (f_ClusterArriveRelaxed F) (fin_val e) = true;
  Mbar := fun a => mem1 (f_Mbar F) (fin_val a) = true;
  iph := fun a => zat (f_iph F) (fin_val a);
  ipend := fun a => zat (f_ipend F) (fin_val a);
  iexp := fun a => zat (f_iexp F) (fin_val a);
  itx := fun a => zat (f_itx F) (fin_val a);
  MbarEv := fun e => mem1 (f_MbarEv F) (fin_val e) = true;
  ph := fun e => zat (f_ph F) (fin_val e);
  pend := fun e => zat (f_pend F) (fin_val e);
  expc := fun e => zat (f_expc F) (fin_val e);
  tx := fun e => zat (f_tx F) (fin_val e);
  MbarInit := fun e => mem1 (f_MbarInit F) (fin_val e) = true;
  MbarWait := fun e => mem1 (f_MbarWait F) (fin_val e) = true;
  wpar := fun e => oat (f_wpar F) (fin_val e);
  wtok := fun e => oat (f_wtok F) (fin_val e);
  TxAnchor := fun e => mem1 (f_TxAnchor F) (fin_val e) = true;
  txops := fun e e' => mem2 (f_txops F) (fin_val e) (fin_val e') = true;
|}.

(** ** Every element of a finite carrier, and counting *)

Definition fin_of (m i : nat) : option (Fin m) :=
  match lt_dec i m with left H => Some (to_fin H) | right _ => None end.

Definition fin_all (m : nat) : list (Fin m) :=
  flat_map (fun i => match fin_of m i with Some x => [x] | None => [] end) (List.seq 0 m).

Lemma fin_all_in m (x : Fin m) : In x (fin_all m).
Proof.
  unfold fin_all; apply in_flat_map; exists (fin_val x); split.
  - apply in_seq; pose proof (fin_lt x); lia.
  - unfold fin_of; destruct (lt_dec (fin_val x) m) as [H | H].
    + left; apply fin_eq; reflexivity.
    + exfalso; apply H, fin_lt.
Qed.

Lemma fin_all_vals m : map fin_val (fin_all m) = List.seq 0 m.
Proof.
  unfold fin_all.
  assert (G : forall k s, s + k <= m -> map fin_val (flat_map (fun i => match fin_of m i with
            Some x => [x] | None => [] end) (List.seq s k)) = List.seq s k).
  { induction k as [| k IH]; intros s Hs; [reflexivity |].
    change (List.seq s (S k)) with (s :: List.seq (S s) k); cbn [flat_map].
    unfold fin_of at 1; destruct (lt_dec s m) as [H | H]; [| lia].
    cbn [app map]; rewrite IH by lia; reflexivity. }
  apply G; lia.
Qed.

Lemma fin_all_nodup m : NoDup (fin_all m).
Proof.
  apply NoDup_map_inv with (f := fin_val); rewrite fin_all_vals; apply seq_NoDup.
Qed.

(** [card_is] on a finite carrier is a count. *)
Lemma card_is_count m (p : nat -> bool) (P : Fin m -> Prop) (k : Z) :
  (forall x, p (fin_val x) = true <-> P x) ->
  (card_is P k <-> Z.of_nat (length (filter (fun x => p (fin_val x)) (fin_all m))) = k).
Proof.
  intros H; split.
  - intros [l [Hnd [Hl Hk]]]; rewrite <- Hk; f_equal.
    apply Nat.le_antisymm; apply NoDup_incl_length.
    + apply NoDup_filter, fin_all_nodup.
    + intros x Hx; apply filter_In in Hx; apply Hl, H, Hx.
    + exact Hnd.
    + intros x Hx; apply filter_In; split; [apply fin_all_in | apply H, Hl, Hx].
  - intros Hk; exists (filter (fun x => p (fin_val x)) (fin_all m)); split; [| split].
    + apply NoDup_filter, fin_all_nodup.
    + intros x; rewrite filter_In, <- H; split; [intros Hx; split; [apply fin_all_in | exact Hx] | tauto].
    + exact Hk.
Qed.
