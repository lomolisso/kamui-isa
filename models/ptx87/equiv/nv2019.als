// Bounded comparison of the PTX 8.7 model (ptx87.als) with the PTX 6.0 model of Lustig, Sahasrabuddhe and Giroux,
// ASPLOS 2019 (deps/ptx-memory-model/ptx.als, NVlabs/PTXMemoryModel, BSD 3-Clause licence).
//
// The 2019 model is written here over the signatures of ptx87.als: its definitions are copied from ptx.als with an
// `nv_` prefix and no other change, and its facts become the predicate nv_wf. Both models then judge the same
// execution, on the fragment both describe (frag_core: generic proxy, no virtual aliases, no mixed-size accesses,
// no CTA or cluster barriers, no mbarrier, no asynchronous operations, global memory, all values 0, since neither
// model's axioms read values there).
//
// The 2019 model has a field `observation` that each execution chooses, constrained by three facts
// (obs_in_rf_rmw, rf_obs, rmw_obs). Its axioms only get harder to satisfy as `observation` grows (it occurs only
// positively in cause, and cause only on the left of `in` and inside irreflexive), so an execution has some
// suitable observation exactly when the least one works. nv_observation is that least relation:
// strong[rf].*(rmw.strong[rf]) satisfies the three facts and is contained in every relation that does.
//
// One fact of ptx.als is left out: `sig Address` requires every address to be accessed by two events and written
// once. It prunes the instances Alloy enumerates for a test generator; it is no rule of the model.
//
// Each check compares one direction of one axiom: `ours_X` asks whether our axiom X holds whenever the 2019 one
// does (a counterexample: the 2019 model allows an execution that ptx87 forbids, so ptx87 is stronger there),
// `nv_X` the converse (a counterexample: ptx87 allows an execution the 2019 model forbids, so ptx87 is weaker,
// the direction that could break a program). A counterexample must be explained by a decision of decisions.md, or
// it is a bug. `d42_*` compare ptx87 with the 2019 model in which atomicity uses the transitive coherence order
// (D42): both directions UNSAT means that on the fragment the two models differ only by D42. Run with check.sh
// (next to this file); README.md has the results.

module nv2019
open ptx87

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// The common fragment.

pred frag_core {
  no Mbar
  no AsyncUnit
  no Barrier + ClusterArrive + ClusterWait + Marker + AliasFence + PlainProxyFence + ProxyFence
  no SyncRestrictCta + SyncRestrictCluster + OpRestrictInit + TxAnchor
  no issue + done + gdep
  MemoryEvent.proxy in Generic
  no alias
  no acc
  no vacc
  Address.space in Global
  MemoryEvent.val in 0
  Address.init in 0
}

// The fragment with CTA barriers (bar.sync, bar.arrive): the 2019 model has them too, formalized by facts on
// `synchronizes`; ptx87.als builds `synchronizes` from barrier generations (D9).
pred frag_bar {
  no Mbar
  no AsyncUnit
  no ClusterArrive + ClusterWait + Marker + AliasFence + PlainProxyFence + ProxyFence
  no SyncRestrictCta + SyncRestrictCluster + OpRestrictInit + TxAnchor
  no issue + done + gdep
  MemoryEvent.proxy in Generic
  no alias
  no acc
  no vacc
  Address.space in Global
  MemoryEvent.val in 0
  Address.init in 0
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ptx.als (2019), with the prefix nv_. Names of ptx87.als that mean the same thing in the fragment are used as they
// are: Event, MemoryEvent, Read, Write, Acquire, Release, Fence, FenceAcq, FenceRel, FenceAcqRel, FenceSC, Barrier,
// BarrierArrive, BarrierWait, Scope, Thread, po, scope, subscope, start, address, rf, co, rmw, dep, sc,
// synchronizes.

// =Shortcuts=
fun nv_com : MemoryEvent->MemoryEvent { rf + ^co + nv_fr }
fun nv_same_thread [rel: Event->Event] : Event->Event { rel & (iden + ^po + ~^po) }
fun nv_location[rel: Event->Event] : Event->Event { rel & (address.~address) }

fun nv_System : Scope { Scope - Scope.subscope }
fun nv_po_loc : Event->Event { ^po & address.~address }
fun nv_fr : Read->Write {
  ~rf.^co
  +
  ((Read - (Write.rf)) <: (address.~address) :> Write)
}

// =PTX=
pred nv_no_thin_air { acyclic[rf + dep] }
pred nv_location_sc { acyclic[nv_strong[nv_com] + nv_po_loc] }
pred nv_atomicity   { no nv_strong[nv_fr].(nv_strong[co]) & rmw }
pred nv_coherence   { nv_location[Write <: nv_cause :> Write] in ^co }
pred nv_causality   { irreflexive[optional[nv_fr + rf].nv_cause] }
pred nv_ptx_mm {
  nv_no_thin_air and nv_location_sc and nv_atomicity and nv_coherence
  and nv_causality
}

// The 2019 model with D42: atomicity over the transitive coherence order between morally strong writes.
pred nv_atomicity_d42 { no nv_strong[nv_fr].(nv_strong[^co]) & rmw }
pred nv_ptx_mm_d42 {
  nv_no_thin_air and nv_location_sc and nv_atomicity_d42 and nv_coherence and nv_causality
}

// =Auxiliaries=
fun nv_observation : MemoryEvent->MemoryEvent { nv_strong[rf].*(rmw.(nv_strong[rf])) }

fun nv_prefix : Event->Event      { (Release <: optional[nv_po_loc] :> Write) + (nv_FenceRels <: ^po :> Write) }
fun nv_suffix : Event->Event      { (Read <: optional[nv_po_loc] :> Acquire) + (Read <: ^po :> nv_FenceAcqs) }
fun nv_Releasers : Event          { Release + nv_FenceRels + (nv_FenceRels.po.rmw)}
fun nv_Acquirers : Event          { Acquire + nv_FenceAcqs }
fun nv_sync[head: Event, tail: Event] : Event->Event {
  head <: nv_strong[nv_prefix.^nv_observation.nv_suffix] :> tail
}
fun nv_cause_base : Event->Event  {
  ^(*po.(synchronizes + sc + nv_sync[nv_Releasers,nv_Acquirers]).*po)
}
fun nv_cause : Event->Event {
  nv_cause_base + (nv_observation.(nv_po_loc + nv_cause_base))
}

fun nv_typed[rel: Event->Event, type: Event] : Event->Event {
  type <: rel :> type
}
fun nv_inside[s: Scope] : Event {
  s.*subscope.start.*po
}
fun nv_scoped[s: Scope] : Event {
  s.*~subscope.~scope
}
fun nv_strong_r : Event->Event {
  symmetric[scope.*subscope.start.*po]
}
fun nv_strong[r: Event->Event]: Event->Event {
  r & nv_strong_r
}

fun nv_FenceRels : Event { FenceAcqRel + FenceRel + BarrierWait }
fun nv_FenceAcqs : Event { FenceAcqRel + FenceAcq + BarrierWait }

// The facts of ptx.als (all of them, but the Address pruning; most are implied by those of ptx87.als).
pred nv_wf {
  one nv_System
  co + rf + nv_fr in address.~address                                      // com_addr
  acyclic[po]                                                              // po_acyclic
  all e: Event | one t: Thread | t->e in start.*po                         // some_thread
  rf.~rf in iden                                                           // lone_source_write
  dep in ^po                                                               // dep_facts
  rmw in po & dep & address.~address & scope.~scope                        // rmw_facts
  subscope.~subscope in iden                                               // inv_subscope
  no Thread.subscope                                                       // thread_subscope
  acyclic[subscope]                                                        // subscope_acyclic
  all f: Fence | some (Scope - Thread) => f.scope not in Thread            // sig Fence
  all r: Acquire | r.scope not in Thread                                   // sig Acquire
  all w: Release | w.scope not in Thread                                   // sig Release
  all a: Address | all s: Scope |                                          // co_per_scope
    total[co, nv_scoped[s] & nv_inside[s] & (a.~address & Write)]
  scope in *~po.~start.*~subscope                                          // scope_inclusion
  all b: BarrierArrive | some b.synchronizes                               // barrier facts
  all b: BarrierWait | some b.~synchronizes
  BarrierWait in BarrierArrive.(po & synchronizes)
  synchronizes.~synchronizes.synchronizes in synchronizes
  ~synchronizes.synchronizes.~synchronizes in ~synchronizes
  no ^po & synchronizes.~synchronizes
  no ^po & ~synchronizes.synchronizes
  synchronizes in nv_strong_r
  all disj f1, f2 : FenceSC | f1->f2 in nv_strong_r => (f1->f2 in sc or f2->f1 in sc)   // wf_sc
  sc in nv_typed[nv_strong_r, FenceSC]
  acyclic[sc]
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// The checks. `for 4` bounds the events by 4, as the 2019 paper's mapping check; scopes need room for a thread per
// event, the system and one level between (cta or gpu).

pred both_wf { frag_core and nv_wf }

// Well-formedness: an execution of the fragment that our facts accept and the 2019 facts reject.
wf_core_4: check { frag_core => nv_wf } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int

// The whole model, both directions.
ours_ptx_mm_4: check { (both_wf and nv_ptx_mm) => ptx_mm } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
nv_ptx_mm_4: check { (both_wf and ptx_mm) => nv_ptx_mm } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int

// The whole model against the 2019 model with D42, both directions.
d42_ours_4: check { (both_wf and nv_ptx_mm_d42) => ptx_mm } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
d42_nv_4: check { (both_wf and ptx_mm) => nv_ptx_mm_d42 } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int

// Axiom by axiom. The 2019 model has no Fence-SC axiom of its own (its causality axiom covers it, through `iden` in
// optional[fr + rf]), so ours_fence_sc compares ours with the whole 2019 model.
ours_no_thin_air_4: check { (both_wf and nv_no_thin_air) => no_thin_air } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
nv_no_thin_air_4: check { (both_wf and no_thin_air) => nv_no_thin_air } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
ours_sc_per_location_4: check { (both_wf and nv_location_sc) => sc_per_location } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
nv_sc_per_location_4: check { (both_wf and sc_per_location) => nv_location_sc } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
ours_atomicity_4: check { (both_wf and nv_atomicity) => atomicity } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
nv_atomicity_4: check { (both_wf and atomicity) => nv_atomicity } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
ours_coherence_4: check { (both_wf and nv_coherence) => coherence } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
nv_coherence_4: check { (both_wf and coherence) => nv_coherence } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
ours_causality_4: check { (both_wf and nv_causality) => causality } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
nv_causality_4: check { (both_wf and causality) => nv_causality } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
ours_fence_sc_4: check { (both_wf and nv_ptx_mm) => fence_sc } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int

// Bound 5 (5 events; a thread per event, the system, one level between).
wf_core_5: check { frag_core => nv_wf } for 5 but 7 Scope, 3 Address, 0 Access, 3 Int
nv_ptx_mm_5: check { (both_wf and ptx_mm) => nv_ptx_mm } for 5 but 7 Scope, 3 Address, 0 Access, 3 Int
d42_ours_5: check { (both_wf and nv_ptx_mm_d42) => ptx_mm } for 5 but 7 Scope, 3 Address, 0 Access, 3 Int
d42_nv_5: check { (both_wf and ptx_mm) => nv_ptx_mm_d42 } for 5 but 7 Scope, 3 Address, 0 Access, 3 Int

// CTA barriers.
pred both_wf_bar { frag_bar and nv_wf }
wf_bar_4: check { frag_bar => nv_wf } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
nv_ptx_mm_bar_4: check { (both_wf_bar and ptx_mm) => nv_ptx_mm } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
d42_ours_bar_4: check { (both_wf_bar and nv_ptx_mm_d42) => ptx_mm } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
d42_nv_bar_4: check { (both_wf_bar and ptx_mm) => nv_ptx_mm_d42 } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
wf_bar_5: check { frag_bar => nv_wf } for 5 but 7 Scope, 3 Address, 0 Access, 3 Int
d42_ours_bar_5: check { (both_wf_bar and nv_ptx_mm_d42) => ptx_mm } for 5 but 7 Scope, 3 Address, 0 Access, 3 Int
d42_nv_bar_5: check { (both_wf_bar and ptx_mm) => nv_ptx_mm_d42 } for 5 but 7 Scope, 3 Address, 0 Access, 3 Int
sanity_bar: run { both_wf_bar and ptx_mm and nv_ptx_mm and some synchronizes and some Read } for 5 but 7 Scope, 3 Address, 0 Access, 3 Int

// The checks are not vacuous: the fragment has consistent executions with a release/acquire synchronization, and
// with a fence.sc pair.
sanity_core_sync: run { both_wf and ptx_mm and nv_ptx_mm and some sync_pattern } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
sanity_core_sc: run { both_wf and ptx_mm and nv_ptx_mm and some sc } for 4 but 6 Scope, 3 Address, 0 Access, 3 Int
