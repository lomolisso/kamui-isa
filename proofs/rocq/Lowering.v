(** * The PTX 8.7 to Kamui lowering, at the level of events

    A translation of the lowering of [models/kamui/compile_ptx87_kamui.als] ([lowering_ex] and the predicates it
    is made of), its feature groups and its broken lowerings. [models/kamui/lowering.yaml] (read through
    [models/kamui/instructions.yaml]) gives every PTX event an image in the Kamui program: an event of the same
    kind, on the same location, in the same thread and in the same place in program order. Everything else is the
    same, or one of the ways a Kamui program may be stronger:
    - a wider scope for a strong operation ([widen]; the standard instructions are at [.sys], K2);
    - a [fence.sc.sys] inserted before an acquire-release read-modify-write ([pre]; [.aqrl], K2).
    The execution of the Kamui program (reads-from, coherence, Fence-SC order, barrier generations, values and
    mbarrier states) is read back into the PTX program.

    Differences from the Alloy check, all of them making the statement cover more:
    - The two programs share their scopes, addresses and accesses (types [S], [A], [C]). Alloy's bijections [sm]
      and [ad] between them become the identity: any pair of programs related by bijections is isomorphic to one
      that shares them.
    - Mixed-size accesses are allowed: the access of each image is the access of its PTX event (Alloy has
      [no p/Access and no k/Access]).
    - [synchronizes] is read back too (in Alloy it follows from the facts of the PTX side, which Alloy assumes and
      this proof has to show).
    - [widen] may move any strong event to any enclosing scope, which covers every scope widening of
      [lowering.yaml]. *)

From hahn Require Import Hahn.
From KamuiProof Require Import Ptx87 Kamui.

Set Implicit Arguments.

(** [one sig Map { ev: p/Event -> one k/Event, pre: p/Event -> lone k/FenceSC, widen: set p/Event,
                   relax: lone p/Event }] *)
Record Map (EP EK : Type) := {
  ev : EP -> EK;               (* the image of a PTX event *)
  pre : EP -> option EK;       (* a fence.sc.sys inserted before the image (.aqrl) *)
  widen : EP -> Prop;          (* events whose image has a wider scope (std) *)
  relax : EP -> Prop;          (* a weak non-coherent read whose image reads the generic proxy (K9; not used) *)
}.

Section Lowering.

Context {EP EK S A C : Type} (P : Exec EP S A C) (K : Exec EK S A C) (M : Map EP EK).

Local Abbreviation ev := (ev M).
Local Abbreviation pre := (pre M).

(** [fun first : p/Event -> k/Event { mpre + ((p/Event - mpre.k/Event) <: m) }]: the first Kamui event of a PTX
    event's lowering. *)
Definition first (e : EP) : EK := match pre e with Some f => f | None => ev e end.

(** [pred bijections] (with the shared scopes and addresses, only the events are mapped) *)
Record bijections : Prop := {
  bij_ev : forall e1 e2, ev e1 = ev e2 -> e1 = e2;
  bij_pre : forall e1 e2 f, pre e1 = Some f -> pre e2 = Some f -> e1 = e2;
  bij_onto : forall k, (exists e, ev e = k) \/ (exists e, pre e = Some k);
  bij_disjoint : forall e e', pre e' <> Some (ev e);
  bij_relax_lone : forall e1 e2, relax M e1 -> relax M e2 -> e1 = e2;
}.

(** [pred same_scope_tree] *)
Record same_scope_tree : Prop := {
  st_skind : forall s, skind K s = skind P s;
  st_subscope : subscope K ≡ subscope P;
}.

(** [pred same_locations] (without [no p/Access and no k/Access]) *)
Record same_locations : Prop := {
  sl_alias : alias K ≡ alias P;
  sl_space : forall a, space K a = space P a;
  sl_owner : forall a s, owner K a s <-> owner P a s;
  sl_init : forall a, init K a = init P a;
  sl_Mbar : forall a, Mbar K a <-> Mbar P a;
  sl_iph : forall a, Mbar P a -> iph K a = iph P a;
  sl_ipend : forall a, Mbar P a -> ipend K a = ipend P a;
  sl_iexp : forall a, Mbar P a -> iexp K a = iexp P a;
  sl_itx : forall a, Mbar P a -> itx K a = itx P a;
}.

(** [pred same_order]: the image of a PTX event takes its place; an inserted fence comes just before it. *)
Record same_order : Prop := {
  so_po : forall k1 k2, po K k1 k2 <->
            (exists e1 e2, ev e1 = k1 /\ po P e1 e2 /\ first e2 = k2) \/ (exists e, pre e = Some k1 /\ ev e = k2);
  so_start : forall t k, start K t k <-> exists e, start P t e /\ first e = k;
  so_pre_scope : forall e f, pre e = Some f -> System K (scope K f);
}.

(** [pred kinds[x: set p/Event]]: the image has the same kind as the PTX event (events in [x] are left to a
    broken lowering); an inserted fence is a [FenceSC] ([pre: p/Event -> lone k/FenceSC]). *)
Record kinds (x : EP -> Prop) : Prop := {
  kd_kind : forall e, ~ x e -> kind K (ev e) = kind P e;
  kd_SyncRestrictCta : forall e, ~ x e -> SyncRestrictCta K (ev e) <-> SyncRestrictCta P e;
  kd_SyncRestrictCluster : forall e, ~ x e -> SyncRestrictCluster K (ev e) <-> SyncRestrictCluster P e;
  kd_OpRestrictInit : forall e, ~ x e -> OpRestrictInit K (ev e) <-> OpRestrictInit P e;
  kd_ClusterArriveRelaxed : forall e, ~ x e -> ClusterArriveRelaxed K (ev e) <-> ClusterArriveRelaxed P e;
  kd_MbarInit : forall e, ~ x e -> MbarInit K (ev e) <-> MbarInit P e;
  kd_MbarWait : forall e, ~ x e -> MbarWait K (ev e) <-> MbarWait P e;
  kd_TxAnchor : forall e, ~ x e -> TxAnchor K (ev e) <-> TxAnchor P e;
  kd_ProxyFence : forall e, ~ x e -> ProxyFence K (ev e) <-> ProxyFence P e;
  kd_pre : forall e f, pre e = Some f -> kind K f = KFenceSC;
}.

(** [pred same_relations[x: set p/Event, dropped: set p/Event]]: the program relations of each event carry over
    ([dropped]: issue edges a broken lowering drops); the access of each event too. *)
Record same_relations (x dropped : EP -> Prop) : Prop := {
  sr_address : forall k a, address K k a <-> exists e, ev e = k /\ address P e a;
  sr_acc : forall k c, acc K k c <-> exists e, ev e = k /\ acc P e c;
  sr_rmw : rmw K ≡ ev ↑ rmw P;
  sr_dep : dep K ≡ ev ↑ dep P;
  sr_issue : issue K ≡ ev ↑ (⦗set_compl dropped⦘ ⨾ issue P);
  sr_done : done K ≡ ev ↑ done P;
  sr_gdep : gdep K ≡ ev ↑ gdep P;
  sr_bid : forall k z, (BarrierArrive K k /\ bid K k = z) <-> exists e, ev e = k /\ BarrierArrive P e /\ bid P e = z;
  sr_bcount : forall k z, (BarrierArrive K k /\ bcount K k = Some z)
                          <-> exists e, ev e = k /\ BarrierArrive P e /\ bcount P e = Some z;
  sr_bwait : bwait K ≡ ev ↑ bwait P;
  sr_cwait : cwait K ≡ ev ↑ cwait P;
  sr_wpar : forall k z, (MbarWait K k /\ wpar K k = Some z) <-> exists e, ev e = k /\ MbarWait P e /\ wpar P e = Some z;
  sr_wtok : forall k z, (MbarWait K k /\ wtok K k = Some z) <-> exists e, ev e = k /\ MbarWait P e /\ wtok P e = Some z;
  sr_txops : txops K ≡ ev ↑ txops P;
  sr_proxy_fence : forall e, ProxyFence P e -> ~ x e ->
    (forall p q, dirs K (ev e) p q <-> dirs P e p q)
    /\ (forall s, pspace K (ev e) s <-> pspace P e s)
    /\ (forall a, paddr K (ev e) a <-> paddr P e a);
}.

(** [pred proxies]: the proxy of every access is the same, or (K9, [relax]) a weak read of the non-coherent path
    becomes a generic one. *)
Record proxies : Prop := {
  px_same : forall e, MemoryEvent P e -> ~ relax M e -> forall p, proxy K (ev e) p <-> proxy P e p;
  px_relax : forall e, relax M e ->
    Read P e /\ ~ (exists w, rmw P e w) /\ Weak P e /\ (forall p, proxy P e p <-> p = Texture)
    /\ (forall p, proxy K (ev e) p <-> p = Generic);
}.

(** [pred scopes[x: set p/Event]]: the scope of every image is the same, or (std) a wider one for a strong
    operation; the two halves of a read-modify-write stay at one scope. *)
Record scopes (x : EP -> Prop) : Prop := {
  sc_same : forall e, ~ widen M e -> ~ x e -> scope K (ev e) = scope P e;
  sc_widen : forall e, widen M e -> ~ x e -> ~ Weak P e /\ (subscope K)＊ (scope K (ev e)) (scope P e);
  sc_rmw : forall r w, rmw P r w -> scope K (ev r) = scope K (ev w);
}.

(** [pred inserted]: fences are inserted only before the read of an acquire-release read-modify-write. *)
Definition inserted : Prop :=
  forall e f, pre e = Some f -> Acquire P e /\ exists w, rmw P e w /\ Release P w.

(** [pred read_back]: the execution of the Kamui program, read back into the PTX program. *)
Record read_back : Prop := {
  rb_rf : rf P ≡ ev ↓ rf K;
  rb_co : co P ≡ ev ↓ co K;
  rb_sc : sc P ≡ (ev ↓ sc K) ∩ ms_r P;
  rb_bgen : bgen P ≡ ev ↓ bgen K;
  rb_cgen : cgen P ≡ ev ↓ cgen K;
  rb_synchronizes : synchronizes P ≡ ev ↓ synchronizes K;
  rb_val : forall e z, (MemoryEvent P e /\ val P e = z) <-> (MemoryEvent K (ev e) /\ val K (ev e) = z);
  rb_ph : forall e z, (MbarEv P e /\ ph P e = z) <-> (MbarEv K (ev e) /\ ph K (ev e) = z);
  rb_pend : forall e z, (MbarEv P e /\ pend P e = z) <-> (MbarEv K (ev e) /\ pend K (ev e) = z);
  rb_expc : forall e z, (MbarEv P e /\ expc P e = z) <-> (MbarEv K (ev e) /\ expc K (ev e) = z);
  rb_tx : forall e z, (MbarEv P e /\ tx P e = z) <-> (MbarEv K (ev e) /\ tx K (ev e) = z);
}.

(** [pred lowering_ex[x: set p/Event, dropped: set p/Event]] *)
Definition lowering_ex (x dropped : EP -> Prop) : Prop :=
  bijections /\ same_scope_tree /\ same_locations /\ same_order /\ kinds x /\ same_relations x dropped
  /\ proxies /\ scopes x /\ inserted /\ read_back.

(** [pred lowering { lowering_ex[none, none] }]; [pred std { lowering and no Map.relax }]: the lowering of
    [lowering.yaml], with its standard alternatives. *)
Definition lowering : Prop := lowering_ex ∅ ∅ /\ (forall e, ~ relax M e).

(** [pred ident { lowering and no Map.widen and no Map.pre and no Map.relax }]: Kamui instructions only. *)
Definition ident : Prop := lowering /\ (forall e, ~ widen M e) /\ (forall e, pre e = None).

End Lowering.

(** ** Feature groups: which PTX programs a group considers (the PTX side) *)

Section Groups.

Context {E S A C : Type} (P : Exec E S A C).

Definition no_async : Prop :=
  (forall s, ~ AsyncUnit P s) /\ issue P ≡ ∅₂ /\ done P ≡ ∅₂ /\ gdep P ≡ ∅₂
  /\ (forall e, ~ TxAnchor P e) /\ (forall e, ~ Marker P e).
Definition no_mbar : Prop := (forall a, ~ Mbar P a) /\ (forall e, ~ MbarInit P e) /\ (forall e, ~ MbarWait P e).
Definition no_barriers : Prop := forall e, ~ Barrier P e /\ ~ ClusterArrive P e /\ ~ ClusterWait P e.
Definition no_restrict : Prop :=
  forall e, ~ SyncRestrictCta P e /\ ~ SyncRestrictCluster P e /\ ~ OpRestrictInit P e.
Definition no_proxy_ops : Prop :=
  (forall e, ~ ProxyFence P e /\ ~ AliasFence P e /\ ~ PlainProxyFence P e) /\ (forall a b, ~ alias P a b).
Definition proxies_in (ps : Proxy -> Prop) : Prop := forall e p, proxy P e p -> ps p.
Definition generic_only : Prop := proxies_in (fun p => p = Generic).

Definition g_core : Prop :=
  no_async /\ no_mbar /\ no_barriers /\ no_restrict /\ no_proxy_ops /\ generic_only.
Definition g_proxies : Prop :=
  no_async /\ no_mbar /\ no_barriers /\ no_restrict
  /\ proxies_in (fun p => p = Generic \/ p = Texture \/ p = Surface \/ p = Constant).
Definition g_barriers : Prop := no_async /\ no_mbar /\ no_restrict /\ no_proxy_ops /\ generic_only.
Definition g_mbarrier : Prop := no_async /\ no_barriers /\ no_restrict /\ no_proxy_ops /\ generic_only.
Definition g_async : Prop :=
  no_barriers /\ no_restrict /\ (forall e, ~ AliasFence P e) /\ (forall a b, ~ alias P a b) /\ gdep P ≡ ∅₂
  /\ proxies_in (fun p => p = Generic \/ p = Async).
Definition g_restricted : Prop :=
  no_async /\ no_proxy_ops /\ generic_only
  /\ exists e, SyncRestrictCta P e \/ SyncRestrictCluster P e \/ OpRestrictInit P e.
Definition g_rest : Prop :=
  no_barriers /\ (forall e, ~ AliasFence P e) /\ (forall a b, ~ alias P a b)
  /\ proxies_in (fun p => p = Generic \/ p = Async \/ p = TensorMap).

End Groups.

(** ** Broken lowerings

    Each is a lowering relation that breaks one rule of [lowering.yaml]; [Theorem.v] states that the correctness
    statement fails for each of them, so that the statement can fail. The first eight are the [run broken_*]
    commands of [compile_ptx87_kamui.als]. The relation leaves the image of the broken event free except for what
    the comment says. *)

Section Broken.

Context {EP EK S A C : Type} (P : Exec EP S A C) (K : Exec EK S A C) (M : Map EP EK).

Local Abbreviation ev := (ev M).

Definition no_extras : Prop := (forall e, ~ widen M e) /\ (forall e, pre M e = None) /\ (forall e, ~ relax M e).
Definition set1 (a : EP) : EP -> Prop := fun e => e = a.

(** [broken_drop_acquire]: an acquire load lowered as a relaxed load (core). *)
Definition broken_drop_acquire : Prop :=
  exists a, Acquire P a /\ ~ (exists w, rmw P a w) /\ ~ MbarWait P a
    /\ g_core P /\ lowering_ex P K M (set1 a) ∅ /\ no_extras
    /\ Read K (ev a) /\ ~ Acquire K (ev a) /\ scope K (ev a) = scope P a.

(** [broken_narrow_fence]: a release, acquire or acq_rel fence at gpu or sys scope lowered at cta scope (core). *)
Definition broken_narrow_fence : Prop :=
  exists f, Fence P f /\ ~ FenceSC P f
    /\ g_core P /\ lowering_ex P K M (set1 f) ∅ /\ no_extras
    /\ Fence K (ev f) /\ ~ FenceSC K (ev f)
    /\ (forall c, cta_of P f c <-> c = scope K (ev f)) /\ ~ CtaScope P (scope P f)
    /\ (FenceAcq P f <-> FenceAcq K (ev f)) /\ (FenceRel P f <-> FenceRel K (ev f))
    /\ (FenceAcqRel P f <-> FenceAcqRel K (ev f)).

(** [broken_std_weak_load]: the standard alternative of an acquire load is a plain lw, which is weak (core, std). *)
Definition broken_std_weak_load : Prop :=
  exists a, Acquire P a /\ ~ (exists w, rmw P a w) /\ ~ MbarWait P a
    /\ g_core P /\ lowering_ex P K M (set1 a) ∅ /\ (forall e, ~ relax M e)
    /\ Read K (ev a) /\ ~ Acquire K (ev a) /\ (forall t, thd P a t <-> t = scope K (ev a)).

(** [broken_mbar_relaxed]: an mbarrier arrive lowered without its release (mbarrier). *)
Definition broken_mbar_relaxed : Prop :=
  exists w, Release P w /\ MbarEv P w /\ ~ MbarInit P w
    /\ g_mbarrier P /\ lowering_ex P K M (set1 w) ∅ /\ no_extras
    /\ Write K (ev w) /\ ~ Release K (ev w) /\ scope K (ev w) = scope P w.

(** [broken_copy_unordered]: an asynchronous copy performed without being ordered after the instruction that
    asked for it (async). *)
Definition broken_copy_unordered : Prop :=
  exists i, (exists e, issue P i e) /\ g_async P /\ lowering_ex P K M ∅ (set1 i) /\ no_extras.

(** [broken_drop_restrict]: a fence.release.sync_restrict::shared::cta dropped (restricted). *)
Definition broken_drop_restrict : Prop :=
  exists f, SyncRestrictCta P f
    /\ g_restricted P /\ lowering_ex P K M (set1 f) ∅ /\ no_extras
    /\ Marker K (ev f) /\ (forall t, thd P f t <-> t = scope K (ev f)).

(** [broken_drop_proxy_fence]: a fence.proxy.async dropped (async). *)
Definition broken_drop_proxy_fence : Prop :=
  exists f, PlainProxyFence P f /\ ~ (exists u, thd P f u /\ AsyncUnit P u)
    /\ g_async P /\ lowering_ex P K M (set1 f) ∅ /\ no_extras
    /\ Marker K (ev f) /\ (forall t, thd P f t <-> t = scope K (ev f)).

(** [broken_relax_nc]: a weak non-coherent read lowered as a generic one (the first version of K9; proxies). *)
Definition broken_relax_nc : Prop :=
  g_proxies P /\ lowering_ex P K M ∅ ∅ /\ (forall e, ~ widen M e) /\ (forall e, pre M e = None).

(** The two below are not in [compile_ptx87_kamui.als]; they are in [als/extra.als], where Alloy finds their
    counterexamples, so that every feature group has a broken lowering. *)

(** [broken_cluster_relaxed]: a barrier.cluster.arrive.release lowered as barrier.cluster.arrive.relaxed (barriers). *)
Definition broken_cluster_relaxed : Prop :=
  exists a, ClusterArrive P a /\ ~ ClusterArriveRelaxed P a
    /\ g_barriers P /\ lowering_ex P K M (set1 a) ∅ /\ no_extras
    /\ ClusterArrive K (ev a) /\ ClusterArriveRelaxed K (ev a) /\ ~ ProxyFence K (ev a)
    /\ scope K (ev a) = scope P a.

(** [broken_drop_tensormap_release]: a fence.proxy.tensormap::generic.release lowered as a plain release fence
    (rest). *)
Definition broken_drop_tensormap_release : Prop :=
  exists f, TmFence P f /\ FenceRel P f
    /\ g_rest P /\ lowering_ex P K M (set1 f) ∅ /\ no_extras
    /\ FenceRel K (ev f) /\ ~ ProxyFence K (ev f) /\ ~ SyncRestrictCta K (ev f) /\ ~ OpRestrictInit K (ev f)
    /\ scope K (ev f) = scope P f.

End Broken.
