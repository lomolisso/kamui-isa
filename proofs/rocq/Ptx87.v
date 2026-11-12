(** * The PTX ISA 8.7 memory consistency model

    A translation of [models/ptx87/ptx87.als] (the Alloy model) into Rocq, one definition per Alloy definition, in
    the same order and with the same names. Each definition quotes the Alloy text it translates; the section
    numbers (8.x, 9.7.x) are those of the PTX ISA 8.7 manual, and D<n> are the interpretation decisions of
    [models/ptx87/decisions.md]. [STATEMENT.md] explains the translation rules; the main ones:

    - An execution is a record of sets and relations over four carrier types: events [E], scopes [S], addresses [A]
      and accesses [C]. The Alloy signatures that extend [Event] (and [Scope]) become a kind function, so that they
      are disjoint and cover their parent, as Alloy's [extends] and [abstract] say. The [in] signatures become
      predicates. [Proxy] and [Space] become inductive types.
    - A field with multiplicity [one] over a whole carrier ([scope], [space], [init]) and the integer fields
      become functions; every other field becomes a relation, with its typing and multiplicity as facts of
      [wf_prog] or [wf_exec] (Alloy states them in the field declarations). An integer field of a subset
      signature ([val], [ph], ...) is a total function whose value outside the subset is never used.
    - Alloy [Int] becomes [Z]. Alloy's [div] and [rem] truncate toward zero, as [Z.quot] and [Z.rem] do.
    - [*r] is [r＊], [^r] is [r⁺], [~r] is [r⁻¹], [r.s] is [r ⨾ s], [s <: r] is [⦗s⦘ ⨾ r], [r :> s] is [r ⨾ ⦗s⦘],
      [+] is [∪], [&] is [∩], [-] is [\]. Each fact may be read assuming the field multiplicities, which are
      facts too, so [wf] as a whole is the conjunction of Alloy's facts. *)

From Stdlib Require Import ZArith List.
From hahn Require Import Hahn.

Set Implicit Arguments.

(** ** 8.5 Scopes, 8.6 proxies, 5.1 state spaces *)

(** [Scope], [CtaScope], [ClusterScope], [Thread], [AsyncUnit] (an [AsyncUnit] is a [Thread], D21). *)
Inductive ScopeKind := SNode | SCta | SCluster | SThread | SAsyncUnit.

(** [abstract sig Proxy]; [one sig Generic, Async, TensorMap, Texture, Surface, Constant extends Proxy]. *)
Inductive Proxy := Generic | Async | TensorMap | Texture | Surface | Constant.

(** [abstract sig Space]; [one sig Global, Shared, Local, Const, Param extends Space] ([Global] and [Local] are
    Rocq keywords, hence the [S] prefix). *)
Inductive Space := SGlobal | SShared | SLocal | SConst | SParam.

(** The leaf signatures under [Event]: [Read] (proper), [Acquire], [Write] (proper), [Release], [FenceAcq],
    [FenceRel], [FenceAcqRel] (proper), [FenceSC], [AliasFence], [PlainProxyFence], [BarrierArrive],
    [BarrierWait], [ClusterArrive], [ClusterWait], [Marker]. *)
Inductive Kind :=
  | KRead | KAcquire | KWrite | KRelease
  | KFenceAcq | KFenceRel | KFenceAcqRel | KFenceSC
  | KAliasFence | KPlainProxyFence
  | KBarrierArrive | KBarrierWait | KClusterArrive | KClusterWait | KMarker.

(** ** Executions: every signature and field of the model *)

Record Exec (E S A C : Type) := {
  (* sig Scope { subscope: set Scope }; sig Thread extends Scope { start: one Event } *)
  skind : S -> ScopeKind;
  subscope : relation S;
  start : S -> E -> Prop;
  (* sig Address { alias: set Address, space: one Space, owner: lone Scope, init: one Int } *)
  alias : relation A;
  space : A -> Space;
  owner : A -> S -> Prop;
  init : A -> Z;
  (* abstract sig Event { po: lone Event, scope: one Scope, issue, done, gdep: set Event } *)
  kind : E -> Kind;
  po : relation E;
  scope : E -> S;
  issue : relation E;
  done : relation E;
  gdep : relation E;
  (* abstract sig MemoryEvent { address: one Address, proxy: one Proxy, val: one Int, acc: lone Access,
     vacc: lone VecAccess }; the atoms of Access and VecAccess share the carrier C (D43) *)
  address : E -> A -> Prop;
  proxy : E -> Proxy -> Prop;
  val : E -> Z;
  acc : E -> C -> Prop;
  vacc : E -> C -> Prop;
  (* sig Read { rmw: lone Write, dep: set Event }; sig Write { rf: set Read, co: set Write } *)
  rmw : relation E;
  dep : relation E;
  rf : relation E;
  co : relation E;
  (* sig FenceSC { sc: set FenceSC } *)
  sc : relation E;
  (* sig SyncRestrictCta in FenceRel; sig SyncRestrictCluster in FenceAcq; sig OpRestrictInit in FenceRel *)
  SyncRestrictCta : E -> Prop;
  SyncRestrictCluster : E -> Prop;
  OpRestrictInit : E -> Prop;
  (* sig ProxyFence in Event { dirs: Proxy -> Proxy, pspace: set Space, paddr: set Address } *)
  ProxyFence : E -> Prop;
  dirs : E -> Proxy -> Proxy -> Prop;
  pspace : E -> Space -> Prop;
  paddr : E -> A -> Prop;
  (* sig BarrierArrive { bid: one Int, bcount: lone Int, bwait: lone BarrierWait, bgen: set BarrierArrive,
     synchronizes: set BarrierWait } *)
  bid : E -> Z;
  bcount : E -> option Z;
  bwait : relation E;
  bgen : relation E;
  synchronizes : relation E;
  (* sig ClusterArrive { cwait: lone ClusterWait, cgen: set ClusterArrive }; sig ClusterArriveRelaxed in
     ClusterArrive *)
  cwait : relation E;
  cgen : relation E;
  ClusterArriveRelaxed : E -> Prop;
  (* sig Mbar in Address { iph, ipend, iexp, itx: one Int } *)
  Mbar : A -> Prop;
  iph : A -> Z;
  ipend : A -> Z;
  iexp : A -> Z;
  itx : A -> Z;
  (* sig MbarEv in MemoryEvent { ph, pend, expc, tx: one Int }; sig MbarInit in Write;
     sig MbarWait in Read { wpar: lone Int, wtok: lone Int } *)
  MbarEv : E -> Prop;
  ph : E -> Z;
  pend : E -> Z;
  expc : E -> Z;
  tx : E -> Z;
  MbarInit : E -> Prop;
  MbarWait : E -> Prop;
  wpar : E -> option Z;
  wtok : E -> option Z;
  (* sig TxAnchor in Write { txops: set Event } *)
  TxAnchor : E -> Prop;
  txops : relation E;
}.

(** util.als *)
Definition symmetric {T} (r : relation T) : relation T := r ∩ r⁻¹.     (* r & ~r *)
(* optional[f] = iden + f is f^?; irreflexive and acyclic are hahn's (acyclic r = irreflexive r⁺). *)

(** [#s = n]: the set [s] has exactly [n] elements. *)
Definition card_is {T} (s : T -> Prop) (n : Z) : Prop :=
  exists l : list T, NoDup l /\ (forall x, s x <-> In x l) /\ Z.of_nat (length l) = n.

Section Model.

Context {E S A C : Type} (X : Exec E S A C).

Local Abbreviation skind := (skind X).
Local Abbreviation subscope := (subscope X).
Local Abbreviation start := (start X).
Local Abbreviation alias := (alias X).
Local Abbreviation space := (space X).
Local Abbreviation owner := (owner X).
Local Abbreviation init := (init X).
Local Abbreviation kind := (kind X).
Local Abbreviation po := (po X).
Local Abbreviation scope := (scope X).
Local Abbreviation issue := (issue X).
Local Abbreviation done := (done X).
Local Abbreviation gdep := (gdep X).
Local Abbreviation address := (address X).
Local Abbreviation proxy := (proxy X).
Local Abbreviation val := (val X).
Local Abbreviation acc := (acc X).
Local Abbreviation vacc := (vacc X).
Local Abbreviation rmw := (rmw X).
Local Abbreviation dep := (dep X).
Local Abbreviation rf := (rf X).
Local Abbreviation co := (co X).
Local Abbreviation sc := (sc X).
Local Abbreviation SyncRestrictCta := (SyncRestrictCta X).
Local Abbreviation SyncRestrictCluster := (SyncRestrictCluster X).
Local Abbreviation OpRestrictInit := (OpRestrictInit X).
Local Abbreviation ProxyFence := (ProxyFence X).
Local Abbreviation dirs := (dirs X).
Local Abbreviation pspace := (pspace X).
Local Abbreviation paddr := (paddr X).
Local Abbreviation bid := (bid X).
Local Abbreviation bcount := (bcount X).
Local Abbreviation bwait := (bwait X).
Local Abbreviation bgen := (bgen X).
Local Abbreviation synchronizes := (synchronizes X).
Local Abbreviation cwait := (cwait X).
Local Abbreviation cgen := (cgen X).
Local Abbreviation ClusterArriveRelaxed := (ClusterArriveRelaxed X).
Local Abbreviation Mbar := (Mbar X).
Local Abbreviation iph := (iph X).
Local Abbreviation ipend := (ipend X).
Local Abbreviation iexp := (iexp X).
Local Abbreviation itx := (itx X).
Local Abbreviation MbarEv := (MbarEv X).
Local Abbreviation ph := (ph X).
Local Abbreviation pend := (pend X).
Local Abbreviation expc := (expc X).
Local Abbreviation tx := (tx X).
Local Abbreviation MbarInit := (MbarInit X).
Local Abbreviation MbarWait := (MbarWait X).
Local Abbreviation wpar := (wpar X).
Local Abbreviation wtok := (wtok X).
Local Abbreviation TxAnchor := (TxAnchor X).
Local Abbreviation txops := (txops X).

(** ** Signatures as sets *)

Definition CtaScope (s : S) := skind s = SCta.
Definition ClusterScope (s : S) := skind s = SCluster.
Definition AsyncUnit (s : S) := skind s = SAsyncUnit.
Definition Thread (s : S) := skind s = SThread \/ skind s = SAsyncUnit.

Definition Acquire (e : E) := kind e = KAcquire.
Definition Read (e : E) := kind e = KRead \/ kind e = KAcquire.
Definition Release (e : E) := kind e = KRelease.
Definition Write (e : E) := kind e = KWrite \/ kind e = KRelease.
Definition MemoryEvent (e : E) := Read e \/ Write e.
Definition FenceAcq (e : E) := kind e = KFenceAcq.
Definition FenceRel (e : E) := kind e = KFenceRel.
Definition FenceSC (e : E) := kind e = KFenceSC.
Definition FenceAcqRel (e : E) := kind e = KFenceAcqRel \/ kind e = KFenceSC.
Definition Fence (e : E) := FenceAcq e \/ FenceRel e \/ FenceAcqRel e.
Definition AliasFence (e : E) := kind e = KAliasFence.
Definition PlainProxyFence (e : E) := kind e = KPlainProxyFence.
Definition BarrierArrive (e : E) := kind e = KBarrierArrive.
Definition BarrierWait (e : E) := kind e = KBarrierWait.
Definition Barrier (e : E) := BarrierArrive e \/ BarrierWait e.
Definition ClusterArrive (e : E) := kind e = KClusterArrive.
Definition ClusterWait (e : E) := kind e = KClusterWait.
Definition Marker (e : E) := kind e = KMarker.

(** ** 8.5 Scopes *)

(** [fun System : Scope { Scope - Scope.subscope }] *)
Definition System (s : S) := ~ exists p, subscope p s.

(** ** 8.2.2, 8.6 Locations *)

(** [fun aliases : Address->Address { Address <: *(alias + ~alias) }] *)
Definition aliases : relation A := (alias ∪ alias⁻¹)＊.

(** ** Threads and locations of events *)

(** [fun thd : Event->Thread { *~po.~start }] *)
Definition thd (e : E) (t : S) : Prop := exists e0, start t e0 /\ po＊ e0 e.

(** [fun same_alias_r : Event->Event { address.~address }] (same virtual address) *)
Definition same_alias_r : relation E := fun e1 e2 => exists a, address e1 a /\ address e2 a.
(** [fun same_location_r : Event->Event { address.aliases.~address }] (same memory) *)
Definition same_location_r : relation E :=
  fun e1 e2 => exists a1 a2, address e1 a1 /\ aliases a1 a2 /\ address e2 a2.
Definition same_alias (r : relation E) : relation E := r ∩ same_alias_r.
Definition same_location (r : relation E) : relation E := r ∩ same_location_r.

(** [fun cta_of : Event->CtaScope { thd.*~subscope :> CtaScope }] *)
Definition cta_of (e : E) (c : S) : Prop := exists t, thd e t /\ subscope＊ c t /\ CtaScope c.
(** [fun same_cta_r : Event->Event { cta_of.~cta_of }] *)
Definition same_cta_r : relation E := fun e1 e2 => exists c, cta_of e1 c /\ cta_of e2 c.
(** [fun cluster_of : Event->ClusterScope { thd.*~subscope :> ClusterScope }] *)
Definition cluster_of (e : E) (c : S) : Prop := exists t, thd e t /\ subscope＊ c t /\ ClusterScope c.

(** [fun po_loc : Event->Event { same_alias[^po] }] *)
Definition po_loc : relation E := same_alias po⁺.

(** [fun fr : Read->Write { ~rf.^co + ((Read - Write.rf) <: same_location_r :> Write) }] *)
Definition fr : relation E :=
  (rf⁻¹ ⨾ co⁺) ∪ (⦗Read \₁ codom_rel (⦗Write⦘ ⨾ rf)⦘ ⨾ same_location_r ⨾ ⦗Write⦘).
(** [fun com : MemoryEvent->MemoryEvent { rf + ^co + fr }] *)
Definition com : relation E := rf ∪ co⁺ ∪ fr.

(** ** 8.7 Morally strong *)

(** [fun Weak : Event { (scope :> Thread).Thread }] *)
Definition Weak (e : E) := Thread (scope e).
Definition StrongW (e : E) := Write e /\ ~ Weak e.
Definition StrongR (e : E) := Read e /\ ~ Weak e.

(** [fun proxy_of : Event->Proxy { MemoryEvent <: proxy + (Event - MemoryEvent) -> Generic }] (D1) *)
Definition proxy_of (e : E) (p : Proxy) : Prop :=
  (MemoryEvent e /\ proxy e p) \/ (~ MemoryEvent e /\ p = Generic).

(** [fun scope_incl_r : Event->Event { symmetric[scope.*subscope.~thd] }] *)
Definition scope_incl_r : relation E :=
  symmetric (fun e1 e2 => exists t, subscope＊ (scope e1) t /\ thd e2 t).

(** [fun footprint : Event->Address { (acc.~acc + iden).address }] (D6) *)
Definition same_acc : relation E := fun e1 e2 => exists c, acc e1 c /\ acc e2 c.
Definition footprint (e : E) (a : A) : Prop := exists e', (same_acc e e' \/ e = e') /\ address e' a.
(** [fun full_overlap_r : MemoryEvent->MemoryEvent {
      { e1, e2: MemoryEvent | e1.footprint.aliases = e2.footprint.aliases } }] (D48) *)
Definition full_overlap_r : relation E :=
  fun e1 e2 => MemoryEvent e1 /\ MemoryEvent e2 /\
    (forall a, (exists a', footprint e1 a' /\ aliases a' a) <-> (exists a', footprint e2 a' /\ aliases a' a)).
(** [fun overlap_ok_r : Event->Event { (MemoryEvent->MemoryEvent & same_location_r & full_overlap_r)
                                       + (Event->Event - MemoryEvent->MemoryEvent) }] (D48) *)
Definition overlap_ok_r : relation E :=
  fun e1 e2 => (MemoryEvent e1 /\ MemoryEvent e2 /\ same_location_r e1 e2 /\ full_overlap_r e1 e2)
               \/ ~ (MemoryEvent e1 /\ MemoryEvent e2).
(** [fun MbarOps : MemoryEvent { MbarEv - (Write - Read.rmw) }] (D47) *)
Definition MbarOps (e : E) : Prop := MbarEv e /\ ~ (Write e /\ ~ (exists r, Read r /\ rmw r e)).
(** [fun ms_r : Event->Event { ((scope_incl_r + MbarOps->MbarOps) & proxy_of.~proxy_of & overlap_ok_r) - iden }]
    (D47) *)
Definition ms_r : relation E :=
  fun e1 e2 => (scope_incl_r e1 e2 \/ (MbarOps e1 /\ MbarOps e2)) /\ (exists p, proxy_of e1 p /\ proxy_of e2 p)
               /\ overlap_ok_r e1 e2 /\ e1 <> e2.
(** [fun strong[r: Event->Event] : Event->Event { r & ms_r }] *)
Definition strong (r : relation E) : relation E := r ∩ ms_r.

(** [fun inside[s: Scope] : Event { s.*subscope.~thd }]; [fun scoped[s: Scope] : Event { s.*~subscope.~scope }]
    (helpers of the 2019 model; not used by the axioms) *)
Definition inside (s : S) (e : E) : Prop := exists t, subscope＊ s t /\ thd e t.
Definition scoped (s : S) (e : E) : Prop := subscope＊ (scope e) s.

(** ** 8.15 mbarrier objects (9.7.13.15) *)

Open Scope Z_scope.

(** [pred mb_next[r: Read, w: Write, darr: Int, dexp: Int, dtx: Int]] (D13); used by the tests. *)
Definition mb_next (r w : E) (darr dexp dtx : Z) : Prop :=
  let p := pend r - darr in
  let e := expc r - dexp in
  let t := tx r + dtx in
  (p = 0 /\ t = 0 -> ph w = ph r + 1 /\ pend w = e /\ expc w = e /\ tx w = 0)
  /\ (~ (p = 0 /\ t = 0) -> ph w = ph r /\ pend w = p /\ expc w = e /\ tx w = t).
(** [pred mb_init[w: Write, count: Int]] (9.7.13.15.9) *)
Definition mb_init (w : E) (count : Z) : Prop := ph w = 0 /\ pend w = count /\ expc w = count /\ tx w = 0.
(** [pred mb_inval[w: Write]] (9.7.13.15.10) *)
Definition mb_inval (w : E) : Prop := ph w = -1 /\ pend w = 0 /\ expc w = 0 /\ tx w = 0.

(** [pred wait_true[r: Read] { (some r.wpar and rem[r.ph, 2] != r.wpar) or (some r.wtok and r.ph > r.wtok) }]
    (9.7.13.15.16) *)
Definition wait_true (r : E) : Prop :=
  (exists p, wpar r = Some p /\ Z.rem (ph r) 2 <> p) \/ (exists t, wtok r = Some t /\ ph r > t).
(** [fun FalseWaits : Read { { r: MbarWait | not wait_true[r] } }] *)
Definition FalseWaits (r : E) : Prop := MbarWait r /\ ~ wait_true r.

(** [pred mb_undefined] (D7, D15) *)
Definition mb_undefined : Prop :=
  (exists r, Read r /\ MbarEv r /\ ph r < 0)
  \/ (exists w, Write w /\ MbarEv w /\ ~ MbarInit w /\ pend w < 0)
  \/ (exists r t, MbarWait r /\ wtok r = Some t /\ ph r > t + 1).

(** [fun bitk], [bitand], [bitor], [bitxor]: Alloy's emulation of bitwise operations on values below 16 (D35),
    used by the tests. *)
Definition bitk (a k : Z) : Z := Z.rem (Z.quot a k) 2.
Definition bitand (a b : Z) : Z :=
  bitk a 1 * bitk b 1 + bitk a 2 * bitk b 2 * 2 + (bitk a 4 * bitk b 4 * 4 + bitk a 8 * bitk b 8 * 8).
Definition bitor (a b : Z) : Z := a + b - bitand a b.
Definition bitxor (a b : Z) : Z := a + b - bitand a b * 2.

Close Scope Z_scope.

(** ** 8.8 Release and acquire patterns *)

(** [fun RelFences : Event { FenceRel + FenceAcqRel + BarrierWait }] (D5, D10) *)
Definition RelFences : E -> Prop := FenceRel ∪₁ FenceAcqRel ∪₁ BarrierWait.
(** [fun AcqFences : Event { FenceAcq + FenceAcqRel + BarrierWait }] *)
Definition AcqFences : E -> Prop := FenceAcq ∪₁ FenceAcqRel ∪₁ BarrierWait.
(** [fun AcqReads : Read { Acquire - FalseWaits }] (D15) *)
Definition AcqReads : E -> Prop := Acquire \₁ FalseWaits.

(** [fun rel_pattern : Event->Write { (Release <: optional[po_loc] :> StrongW) + (RelFences <: ^po :> StrongW) }] *)
Definition rel_pattern : relation E :=
  (⦗Release⦘ ⨾ po_loc^? ⨾ ⦗StrongW⦘) ∪ (⦗RelFences⦘ ⨾ po⁺ ⨾ ⦗StrongW⦘).
(** [fun acq_pattern : Read->Event { (StrongR <: optional[po_loc] :> AcqReads) + (StrongR <: ^po :> AcqFences) }] *)
Definition acq_pattern : relation E :=
  (⦗StrongR⦘ ⨾ po_loc^? ⨾ ⦗AcqReads⦘) ∪ (⦗StrongR⦘ ⨾ po⁺ ⨾ ⦗AcqFences⦘).

(** [fun obs : Write->Read { strong[rf].*(rmw.(strong[rf])) }] (8.9.3) *)
Definition obs : relation E := strong rf ⨾ (rmw ⨾ strong rf)＊.

(** ** 8.9.4 Synchronizes-with *)

(** [fun sync_pattern : Event->Event { strong[rel_pattern.obs.acq_pattern] }] *)
Definition sync_pattern : relation E := strong (rel_pattern ⨾ obs ⨾ acq_pattern).

(** [fun cluster_sync : Event->Event { ((ClusterArrive - ClusterArriveRelaxed) <: cgen.cwait)
                                       + strong[(RelFences <: ^po :> ClusterArriveRelaxed).cgen.cwait] }] (D11) *)
Definition cluster_sync : relation E :=
  (⦗ClusterArrive \₁ ClusterArriveRelaxed⦘ ⨾ cgen ⨾ cwait)
  ∪ strong (⦗RelFences⦘ ⨾ po⁺ ⨾ ⦗ClusterArriveRelaxed⦘ ⨾ cgen ⨾ cwait).

(** [fun sw : Event->Event { sc + synchronizes + cluster_sync + sync_pattern }] *)
Definition sw : relation E := sc ∪ synchronizes ∪ cluster_sync ∪ sync_pattern.

(** ** Restricted release and acquire (D18, D19) *)

(** [fun RRel : Event { SyncRestrictCta + OpRestrictInit + TxAnchor }]; [fun RAcq : Event { SyncRestrictCluster }] *)
Definition RRel : E -> Prop := SyncRestrictCta ∪₁ OpRestrictInit ∪₁ TxAnchor.
Definition RAcq : E -> Prop := SyncRestrictCluster.

(** [fun rleft : Event->Event {
      ({ x: MemoryEvent, f: SyncRestrictCta | x.address.space = Shared and x.address.owner = f.cta_of } & ^po)
      + (MbarInit <: ^po :> OpRestrictInit) + ~(TxAnchor <: txops) }] *)
Definition rleft : relation E :=
  ((fun x f => MemoryEvent x /\ SyncRestrictCta f
               /\ (forall s, (exists a, address x a /\ space a = s) <-> s = SShared)
               /\ (forall o, (exists a, address x a /\ owner a o) <-> cta_of f o)) ∩ po⁺)
  ∪ (⦗MbarInit⦘ ⨾ po⁺ ⨾ ⦗OpRestrictInit⦘)
  ∪ (⦗TxAnchor⦘ ⨾ txops)⁻¹.
(** [fun rright : Event->Event {
      { f: SyncRestrictCluster, y: MemoryEvent | y.address.space = Shared
                                                 and y.address.owner in f.cluster_of.*subscope } & ^po }] *)
Definition rright : relation E :=
  (fun f y => SyncRestrictCluster f /\ MemoryEvent y
              /\ (forall s, (exists a, address y a /\ space a = s) <-> s = SShared)
              /\ (forall o, (exists a, address y a /\ owner a o) -> exists c, cluster_of f c /\ subscope＊ c o))
  ∩ po⁺.

(** ** 8.9.5 Base causality order *)

(** [fun bco_plain : Event->Event { ^(po + issue + done + gdep + (sw - RRel <: sw - sw :> RAcq)) }]
    (the restricted edges [RRel <: sw] and [sw :> RAcq] are removed from [sw]) *)
Definition bco_plain : relation E :=
  (po ∪ issue ∪ done ∪ gdep ∪ ((sw \ (⦗RRel⦘ ⨾ sw)) \ (sw ⨾ ⦗RAcq⦘)))⁺.
(** [fun sw_restricted : Event->Event { RRel <: sw + sw :> RAcq }] *)
Definition sw_restricted : relation E := (⦗RRel⦘ ⨾ sw) ∪ (sw ⨾ ⦗RAcq⦘).
(** [fun cause_base : Event->Event {
      let left = (rleft :> RRel) + ( *bco_plain :> (Event - RRel)),
          right = (RAcq <: rright) + ((Event - RAcq) <: *bco_plain) |
        bco_plain + left.sw_restricted.right }] *)
Definition cause_base : relation E :=
  let left := (rleft ⨾ ⦗RRel⦘) ∪ (bco_plain＊ ⨾ ⦗set_compl RRel⦘) in
  let right := (⦗RAcq⦘ ⨾ rright) ∪ (⦗set_compl RAcq⦘ ⨾ bco_plain＊) in
  bco_plain ∪ (left ⨾ sw_restricted ⨾ right).

(** ** 8.9.5 Proxy-preserved base causality order (D2, D37, D40) *)

(** [fun GenericM : MemoryEvent { proxy.Generic }] *)
Definition GenericM (e : E) : Prop := proxy e Generic.

(** [fun pf_space_ok : ProxyFence->MemoryEvent {
      { f: ProxyFence, m: MemoryEvent | (no f.pspace or m.address.space in f.pspace)
                                        and (no f.paddr or m.address in f.paddr) } }] *)
Definition pf_space_ok : relation E :=
  fun f m => ProxyFence f /\ MemoryEvent m
             /\ ((forall s, ~ pspace f s) \/ (forall a, address m a -> pspace f (space a)))
             /\ ((forall a, ~ paddr f a) \/ (forall a, address m a -> paddr f a)).
(** [fun pf_src : MemoryEvent->ProxyFence {
      { m: MemoryEvent, f: ProxyFence | m.proxy -> Generic in f.dirs } & same_cta_r & ~pf_space_ok }] *)
Definition pf_src : relation E :=
  (fun m f => MemoryEvent m /\ ProxyFence f /\ (forall p, proxy m p -> dirs f p Generic))
  ∩ same_cta_r ∩ pf_space_ok⁻¹.
(** [fun pf_dst : ProxyFence->MemoryEvent {
      { f: ProxyFence, m: MemoryEvent | Generic -> m.proxy in f.dirs } & same_cta_r & pf_space_ok }] *)
Definition pf_dst : relation E :=
  (fun f m => ProxyFence f /\ MemoryEvent m /\ (forall p, proxy m p -> dirs f Generic p))
  ∩ same_cta_r ∩ pf_space_ok.

(** [fun TmFence : ProxyFence { { f: ProxyFence | Generic -> TensorMap in f.dirs } }] *)
Definition TmFence (f : E) : Prop := ProxyFence f /\ dirs f Generic TensorMap.
(** [fun pf_dst_with[cb: Event->Event] : Event->MemoryEvent {
      (cb & (pf_dst - (TmFence <: pf_dst)))
      + ((TmFence & FenceRel) <: (cb.(cb & ((TmFence & FenceAcq) <: pf_dst)))) }] *)
Definition pf_dst_with (cb : relation E) : relation E :=
  (cb ∩ (pf_dst \ (⦗TmFence⦘ ⨾ pf_dst)))
  ∪ (⦗TmFence ∩₁ FenceRel⦘ ⨾ cb ⨾ (cb ∩ (⦗TmFence ∩₁ FenceAcq⦘ ⨾ pf_dst))).

(** [fun ppbco_with[cb: Event->Event] : MemoryEvent->MemoryEvent { ... }]: the ten clauses of the model *)
Definition ppbco_with (cb : relation E) : relation E :=
  (* no proxy fence or alias fence *)
  same_alias (⦗GenericM⦘ ⨾ cb ⨾ ⦗GenericM⦘)
  ∪ same_alias ((⦗MemoryEvent⦘ ⨾ cb ⨾ ⦗MemoryEvent⦘) ∩ same_cta_r ∩ (fun e1 e2 => exists p, proxy e1 p /\ proxy e2 p))
  (* a generic read before a write of the same address in any proxy (D40, D49) *)
  ∪ same_alias (⦗GenericM ∩₁ Read⦘ ⨾ cb ⨾ ⦗Write⦘)
  (* proxy fence for the source, for the destination, for both *)
  ∪ same_alias ((cb ∩ pf_src) ⨾ cb ⨾ ⦗GenericM⦘)
  ∪ same_alias (⦗GenericM⦘ ⨾ cb ⨾ pf_dst_with cb)
  ∪ same_alias ((cb ∩ pf_src) ⨾ cb ⨾ pf_dst_with cb)
  (* alias fence, alone or with proxy fences *)
  ∪ same_location (⦗GenericM⦘ ⨾ cb ⨾ (⦗AliasFence⦘ ⨾ cb) ⨾ ⦗GenericM⦘)
  ∪ same_location ((cb ∩ pf_src) ⨾ (cb ⨾ ⦗AliasFence⦘) ⨾ cb ⨾ ⦗GenericM⦘)
  ∪ same_location (⦗GenericM⦘ ⨾ cb ⨾ (⦗AliasFence⦘ ⨾ cb) ⨾ pf_dst_with cb)
  ∪ same_location ((cb ∩ pf_src) ⨾ (cb ⨾ ⦗AliasFence⦘) ⨾ cb ⨾ pf_dst_with cb).

(** [fun ppbco : MemoryEvent->MemoryEvent { ppbco_with[cause_base] }] *)
Definition ppbco : relation E := ppbco_with cause_base.

(** [fun cause : MemoryEvent->MemoryEvent { ppbco + obs.ppbco }] (8.9.6) *)
Definition cause : relation E := ppbco ∪ (obs ⨾ ppbco).

(** ** 8.10 Axioms *)

(** [pred coherence { same_location[Write <: cause :> Write] in ^co }] (8.10.1) *)
Definition coherence : Prop := same_location (⦗Write⦘ ⨾ cause ⨾ ⦗Write⦘) ⊆ co⁺.

(** [pred fence_sc { (FenceSC <: cause_base :> FenceSC) & ms_r in sc }] (8.10.2, D3, D41) *)
Definition fence_sc : Prop := (⦗FenceSC⦘ ⨾ cause_base ⨾ ⦗FenceSC⦘) ∩ ms_r ⊆ sc.

(** [fun acc_lift[r: Event->Event] : Event->Event {
      (acc.~acc + vacc.~vacc + iden).r.(acc.~acc + vacc.~vacc + iden) }] (D43) *)
Definition same_vacc : relation E := fun e1 e2 => exists c, vacc e1 c /\ vacc e2 c.
Definition acc_lift (r : relation E) : relation E := (same_acc ∪ same_vacc)^? ⨾ r ⨾ (same_acc ∪ same_vacc)^?.
(** [fun AtomicR : Read { rmw.Write }]; [fun Atomics : MemoryEvent { AtomicR + AtomicR.rmw }] *)
Definition AtomicR (e : E) : Prop := exists w, rmw e w /\ Write w.
Definition Atomics (e : E) : Prop := AtomicR e \/ exists r, AtomicR r /\ rmw r e.
(** [fun atomic_pair_r : Event->Event {
      ms_r + (Atomics <: (scope_incl_r & proxy.~proxy & same_location_r) :> Atomics) }] *)
Definition atomic_pair_r : relation E :=
  ms_r ∪ (⦗Atomics⦘ ⨾ (scope_incl_r ∩ (fun e1 e2 => exists p, proxy e1 p /\ proxy e2 p) ∩ same_location_r)
          ⨾ ⦗Atomics⦘).
(** [pred atomicity { no (Read <: ms_r :> Write) & acc_lift[~rf] & acc_lift[fr]
                      no (fr & atomic_pair_r).(^co & atomic_pair_r) & rmw }] (8.10.3, D6, D25, D42) *)
Definition atomicity : Prop :=
  (forall r w, ~ ((⦗Read⦘ ⨾ ms_r ⨾ ⦗Write⦘) r w /\ acc_lift rf⁻¹ r w /\ acc_lift fr r w))
  /\ (forall r w, ~ (((fr ∩ atomic_pair_r) ⨾ (co⁺ ∩ atomic_pair_r)) r w /\ rmw r w)).

(** [pred no_thin_air { acyclic[rf + dep] }] (8.10.4) *)
Definition no_thin_air : Prop := acyclic (rf ∪ dep).

(** [pred sc_per_location { acyclic[strong[com] + po_loc] }] (8.10.5) *)
Definition sc_per_location : Prop := acyclic (strong com ∪ po_loc).

(** [pred causality { irreflexive[(rf + fr).cause] }] (8.10.6, D4) *)
Definition causality : Prop := irreflexive ((rf ∪ fr) ⨾ cause).

(** [pred ptx_mm]: the model *)
Definition consistent : Prop :=
  coherence /\ fence_sc /\ atomicity /\ no_thin_air /\ sc_per_location /\ causality.

(** [pred mixed_size_race { some disj e1, e2: MemoryEvent |
      e1->e2 in same_location_r and e1.footprint.aliases != e2.footprint.aliases and some (e1 + e2) & Write
      and e1->e2 not in ms_r + cause + ~cause }] (8.7.2, D38) *)
Definition mixed_size_race : Prop :=
  exists e1 e2, e1 <> e2 /\ MemoryEvent e1 /\ MemoryEvent e2 /\ same_location_r e1 e2
    /\ ~ (forall b, (exists a, footprint e1 a /\ aliases a b) <-> (exists a, footprint e2 a /\ aliases a b))
    /\ (Write e1 \/ Write e2)
    /\ ~ (ms_r ∪ cause ∪ cause⁻¹) e1 e2.

(** [pred undefined { mb_undefined }] (D7; a mixed-size data race is handled per program, D38) *)
Definition undefined : Prop := mb_undefined.

(** ** Well-formedness: the facts of the model

    [wf_prog]: the facts about the program (the fields a test pins, and the facts and declarations that involve
    only them). [wf_exec]: the facts that involve the execution, that is the relations and values a run chooses:
    [rf], [co], [sc], [bgen], [cgen], [synchronizes], [val] and the mbarrier state [ph], [pend], [expc], [tx].
    Each conjunct is named after its Alloy fact or declaration. *)

Record wf_prog : Prop := {
  (* declarations: typing and multiplicities of the program fields *)
  decl_start : forall t e, start t e -> Thread t;
  decl_start_one : forall t, Thread t -> exists e, start t e /\ forall e', start t e' -> e' = e;
  decl_owner_lone : forall a s1 s2, owner a s1 -> owner a s2 -> s1 = s2;
  decl_po_lone : forall e e1 e2, po e e1 -> po e e2 -> e1 = e2;
  decl_address : forall e a, address e a -> MemoryEvent e;
  decl_address_one : forall e, MemoryEvent e -> exists a, address e a /\ forall a', address e a' -> a' = a;
  decl_proxy : forall e p, proxy e p -> MemoryEvent e;
  decl_proxy_one : forall e, MemoryEvent e -> exists p, proxy e p /\ forall p', proxy e p' -> p' = p;
  decl_acc : forall e c, acc e c -> MemoryEvent e;
  decl_acc_lone : forall e c1 c2, acc e c1 -> acc e c2 -> c1 = c2;
  decl_vacc : forall e c, vacc e c -> MemoryEvent e;
  decl_vacc_lone : forall e c1 c2, vacc e c1 -> vacc e c2 -> c1 = c2;
  decl_rmw : forall r w, rmw r w -> Read r /\ Write w;
  decl_rmw_lone : forall r w1 w2, rmw r w1 -> rmw r w2 -> w1 = w2;
  decl_dep : forall r e, dep r e -> Read r;
  decl_SyncRestrictCta : SyncRestrictCta ⊆₁ FenceRel;
  decl_SyncRestrictCluster : SyncRestrictCluster ⊆₁ FenceAcq;
  decl_OpRestrictInit : OpRestrictInit ⊆₁ FenceRel;
  decl_dirs : forall f p q, dirs f p q -> ProxyFence f;
  decl_pspace : forall f s, pspace f s -> ProxyFence f;
  decl_paddr : forall f a, paddr f a -> ProxyFence f;
  decl_bcount : forall e n, bcount e = Some n -> BarrierArrive e;
  decl_bwait : forall a w, bwait a w -> BarrierArrive a /\ BarrierWait w;
  decl_bwait_lone : forall a w1 w2, bwait a w1 -> bwait a w2 -> w1 = w2;
  decl_cwait : forall a w, cwait a w -> ClusterArrive a /\ ClusterWait w;
  decl_cwait_lone : forall a w1 w2, cwait a w1 -> cwait a w2 -> w1 = w2;
  decl_ClusterArriveRelaxed : ClusterArriveRelaxed ⊆₁ ClusterArrive;
  decl_MbarEv : MbarEv ⊆₁ MemoryEvent;
  decl_MbarInit : MbarInit ⊆₁ Write;
  decl_MbarWait : MbarWait ⊆₁ Read;
  decl_wpar : forall e n, wpar e = Some n -> MbarWait e;
  decl_wtok : forall e n, wtok e = Some n -> MbarWait e;
  decl_TxAnchor : TxAnchor ⊆₁ Write;
  decl_txops : forall e e', txops e e' -> TxAnchor e;
  (* sig Acquire { scope not in Thread }, sig Release { ... }, abstract sig Fence { ... } *)
  sig_Acquire : forall e, Acquire e -> ~ Thread (scope e);
  sig_Release : forall e, Release e -> ~ Thread (scope e);
  sig_Fence : forall e, Fence e -> ~ Thread (scope e);
  (* fact scope_tree *)
  scope_tree_1 : exists s, System s /\ forall s', System s' -> s' = s;     (* one System *)
  scope_tree_2 : forall p1 p2 s, subscope p1 s -> subscope p2 s -> p1 = p2;  (* subscope.~subscope in iden *)
  scope_tree_3 : forall t s, Thread t -> ~ subscope t s;                   (* no Thread.subscope *)
  scope_tree_4 : acyclic subscope;
  scope_tree_5 : forall t1 t2 e, start t1 e -> start t2 e -> t1 = t2;      (* start.~start in iden *)
  (* fact address_facts *)
  address_facts_1 : forall a b, aliases a b -> init b = init a;            (* a.aliases.init = a.init *)
  address_facts_2 : forall a, space a = SShared \/ space a = SLocal <-> exists s, owner a s;
  address_facts_3 : forall a s, owner a s -> (space a = SShared /\ CtaScope s) \/ (space a = SLocal /\ Thread s);
  (* fact threads *)
  threads_1 : acyclic po;
  threads_2 : forall e, exists t, thd e t /\ forall t', thd e t' -> t' = t; (* one e.thd *)
  threads_3 : forall e, exists t, thd e t /\ subscope＊ (scope e) t;       (* scope in thd.*~subscope *)
  (* fact communication, the part about the program *)
  communication_5 : forall w a, Write w -> address w a -> space a <> SConst /\ space a <> SParam;
  (* fact dependencies *)
  dependencies_1 : dep ⊆ po⁺;
  dependencies_2 : rmw ⊆ po ∩ dep ∩ same_alias_r ∩ (fun e1 e2 => scope e1 = scope e2)
                       ∩ (fun e1 e2 => exists p, proxy e1 p /\ proxy e2 p);
  (* fact mbarrier_state, the part about the program *)
  mbarrier_state_1 : forall e, MbarEv e <-> exists a, address e a /\ Mbar a; (* MbarEv = address.Mbar *)
  mbarrier_state_2 : forall a b, Mbar a -> ~ alias b a /\ ~ alias a b;      (* no Mbar & (Address.alias + alias.Address) *)
  mbarrier_state_4 : MbarInit ∪₁ MbarWait ⊆₁ MbarEv;
  (* fact barriers, the part about the program *)
  barriers_1 : bwait ⊆ po;
  barriers_2 : forall w, BarrierWait w -> exists a, BarrierArrive a /\ bwait a w;
  (* fact cluster_barriers, the part about the program *)
  cluster_barriers_1 : cwait ⊆ po⁺;
  cluster_barriers_2 : forall a1 a2 w, cwait a1 w -> cwait a2 w -> a1 = a2;
  cluster_barriers_3 : forall w, ClusterWait w -> exists a, ClusterArrive a /\ cwait a w;
  (* fact async_units *)
  async_units_2 : forall e u e', thd e u -> AsyncUnit u -> ~ issue e e';
}.

(** [bid.~bid] relates barrier arrivals with the same barrier resource. *)
Definition same_bid : relation E := fun a b => BarrierArrive a /\ BarrierArrive b /\ bid a = bid b.

Record wf_exec : Prop := {
  (* declarations: typing of the execution fields *)
  decl_rf : forall w r, rf w r -> Write w /\ Read r;
  decl_co : forall w w', co w w' -> Write w /\ Write w';
  decl_sc : forall f f', sc f f' -> FenceSC f /\ FenceSC f';
  decl_bgen : forall a b, bgen a b -> BarrierArrive a /\ BarrierArrive b;
  decl_synchronizes : forall a w, synchronizes a w -> BarrierArrive a /\ BarrierWait w;
  decl_cgen : forall a b, cgen a b -> ClusterArrive a /\ ClusterArrive b;
  (* fact mbarrier_state, the part about the execution *)
  mbarrier_state_3 : forall r, Read r -> MbarEv r ->
    ((exists w, rf w r) -> forall w, rf w r -> ph r = ph w /\ pend r = pend w /\ expc r = expc w /\ tx r = tx w)
    /\ (~ (exists w, rf w r) -> forall a, address r a ->
          ph r = iph a /\ pend r = ipend a /\ expc r = iexp a /\ tx r = itx a);
  mbarrier_state_5 : forall w, MbarInit w -> ph w = 0%Z /\ tx w = 0%Z /\ pend w = expc w;
  (* fact communication *)
  communication_1 : rf ∪ co ⊆ same_location_r;
  communication_2 : forall w1 w2 r, rf w1 r -> rf w2 r -> w1 = w2;         (* rf.~rf in iden *)
  communication_3 : forall r, Read r ->
    ((exists w, rf w r) -> forall w, rf w r -> val r = val w)
    /\ (~ (exists w, rf w r) -> forall a, address r a -> val r = init a);
  communication_4 : acyclic co;
  (* fact co_strong (D6, D43) *)
  co_strong_1 : ⦗Write⦘ ⨾ ms_r ⨾ ⦗Write⦘ ⊆ co⁺ ∪ co⁻¹⁺;
  co_strong_2 : forall c1 c2,
    ~ ((exists w1 w2, acc w1 c1 /\ co⁺ w1 w2 /\ acc w2 c2) /\ (exists w1 w2, acc w1 c2 /\ co⁺ w1 w2 /\ acc w2 c1));
  co_strong_3 : forall c1 c2,
    ~ ((exists w1 w2, vacc w1 c1 /\ co⁺ w1 w2 /\ vacc w2 c2) /\ (exists w1 w2, vacc w1 c2 /\ co⁺ w1 w2 /\ vacc w2 c1));
  (* fact fence_sc_order *)
  fence_sc_order_1 : forall f1 f2, FenceSC f1 -> FenceSC f2 -> f1 <> f2 -> ms_r f1 f2 -> sc f1 f2 \/ sc f2 f1;
  fence_sc_order_2 : sc ⊆ ms_r;
  fence_sc_order_3 : acyclic sc;
  (* fact barriers, the part about the execution (D9) *)
  barriers_3 : bgen ≡ bgen⁻¹;
  barriers_4 : forall a, BarrierArrive a -> bgen a a;
  barriers_5 : bgen ⨾ bgen ⊆ bgen;
  barriers_6 : bgen ⊆ same_cta_r ∩ same_bid;
  barriers_7 : forall a b, ~ (po⁺ a b /\ bgen a b);                        (* no ^po & bgen *)
  barriers_8 : acyclic (bgen ⨾ (po⁺ ∩ same_bid));
  barriers_9 : forall a n, BarrierArrive a -> bcount a = Some n -> card_is (bgen a) n;
  barriers_10 : forall a, BarrierArrive a -> bcount a = None ->
    forall t, (exists b, bgen a b /\ thd b t)
              <-> (Thread t /\ exists b, BarrierArrive b /\ thd b t /\ bid b = bid a /\ same_cta_r b a);
  barriers_11 : synchronizes ≡ bgen ⨾ bwait;
  (* fact cluster_barriers, the part about the execution *)
  cluster_barriers_4 : cgen ≡ cgen⁻¹;
  cluster_barriers_5 : forall a, ClusterArrive a -> cgen a a;
  cluster_barriers_6 : cgen ⨾ cgen ⊆ cgen;
  cluster_barriers_7 : cgen ⊆ (fun a b => exists c, cluster_of a c /\ cluster_of b c);
  cluster_barriers_8 : forall a b, ~ (po⁺ a b /\ cgen a b);
  cluster_barriers_9 : acyclic (cgen ⨾ po⁺);
  cluster_barriers_10 : forall a, ClusterArrive a ->
    forall t, (exists b, cgen a b /\ thd b t)
              <-> ((exists c, cluster_of a c /\ subscope＊ c t) /\ Thread t /\ ~ AsyncUnit t);
}.

Definition wf : Prop := wf_prog /\ wf_exec.

End Model.
