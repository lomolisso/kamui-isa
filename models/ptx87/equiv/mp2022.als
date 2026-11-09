// Bounded comparison of the PTX 8.7 model (ptx87.als) with the PTX 7.5 mixed-proxy model of Lustig, Cooksey and
// Giroux, ISCA 2022 (NVlabs/mixedproxy at 0807da2, alloy/ptx.als, BSD 3-Clause licence).
//
// As in nv2019.als, the mixed-proxy model is written over the signatures of ptx87.als: its definitions are copied
// with an `mp_` prefix and only the names changed (Op = Event, MemoryOp = MemoryEvent, ReadAcquire = Acquire,
// WriteRelease = Release, value = val, GenericProxy = Generic, ..., Block = CtaScope), and its facts become the
// predicate mp_wf. The fragment (frag_mp) is what both describe: the scope tree system / device / block / thread,
// the generic, texture, surface and constant proxies, virtual aliases, alias fences, proxy fences, fence.acq_rel and
// fence.sc, no barriers, global memory, all values 0 (the axioms do not read them).
//
// A mixed-proxy proxy fence names a set of proxies and orders each of them with the generic proxy in both
// directions; in ptx87.als that is a ProxyFence whose `dirs` are p -> Generic and Generic -> p for each p of the set,
// with no space or address restriction.
//
// `ours_X`: a counterexample is an execution the mixed-proxy model allows and ptx87 forbids (ptx87 stronger);
// `mp_X`: one ptx87 allows and the mixed-proxy model forbids (ptx87 weaker, the direction that could break a
// program). Each counterexample must be explained by a decision of decisions.md, or it is a bug.

module mp2022
open ptx87

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// The common fragment.

fun mp_pfp : ProxyFence->Proxy { { f: ProxyFence, p: Proxy | p != Generic and p->Generic in f.dirs } }

pred frag_mp {
  no Mbar
  no AsyncUnit
  no ClusterScope
  no Barrier + ClusterArrive + ClusterWait + Marker + FenceAcq + FenceRel
  no SyncRestrictCta + SyncRestrictCluster + OpRestrictInit + TxAnchor
  no issue + done + gdep
  MemoryEvent.proxy in Generic + Texture + Surface + Constant
  no acc
  Address.space in Global
  MemoryEvent.val in 0
  Address.init in 0
  // proxy fences: mixed-proxy form
  ProxyFence = PlainProxyFence
  all f: ProxyFence | no f.pspace and no f.paddr and f.dirs = f.mp_pfp->Generic + Generic->f.mp_pfp
  ProxyFence.mp_pfp in Texture + Surface + Constant    // the proxies of the mixed-proxy model
  // the scope tree: system, devices, blocks (CtaScope), threads
  System not in CtaScope + Thread
  System.subscope in Scope - CtaScope - Thread
  all c: CtaScope | c.~subscope in System.subscope
  all t: Thread | t.~subscope in CtaScope
  Scope = System + System.subscope + CtaScope + Thread
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// alloy/ptx.als of NVlabs/mixedproxy, with the prefix mp_.

fun mp_threads : CtaScope->Thread { CtaScope <: subscope :> Thread }
fun mp_GenericOps : set Event { Generic.~proxy }

fun mp_po_loc : Event->Event { mp_same_alias[^po] }
fun mp_fr : Read->Write {
  ~rf.^co
  +
  mp_same_location[(Read - (Write.rf))->Write]
}
fun mp_com : MemoryEvent->MemoryEvent { rf + ^co + mp_fr }

fun mp_ReleaseFences : Fence { FenceAcqRel + FenceSC }
fun mp_AcquireFences : Fence { FenceAcqRel + FenceSC }

pred mp_causality {
  irreflexive[optional[mp_com].mp_cause]
}
pred mp_atomicity {
  no mp_strong[mp_fr].(mp_strong[co]) & rmw
}
pred mp_coherence {
  mp_same_location[Write <: mp_cause :> Write] in ^co
}
pred mp_seq_cst {
  FenceSC <: mp_cause :> FenceSC in sc
}
pred mp_no_thin_air {
  acyclic[rf + dep]
}
pred mp_ptx_mm {
  mp_no_thin_air and mp_atomicity and mp_coherence and mp_causality and mp_seq_cst
}

fun mp_cause : Event->Event {
  optional[mp_observation].mp_proxy_preserved_cause_base
}
fun mp_sync : Event->Event {
  mp_strong[mp_release_sequence.^mp_observation.mp_acquire_sequence]
}
fun mp_release_sequence : Event->Event {
  mp_strong[Release <: optional[mp_po_loc] :> Write]
  + mp_strong[mp_ReleaseFences <: ^po :> Write]
}
fun mp_observation : Event->Event {
  mp_strong[rf] + rmw
}
fun mp_acquire_sequence : Event->Event {
  mp_strong[Read <: optional[mp_po_loc] :> Acquire]
  + mp_strong[Read <: ^po :> mp_AcquireFences]
}

fun mp_proxy_fence_ops : ProxyFence->Event {
  mp_pfp.~proxy
  & mp_same_block_r
}
fun mp_same_block_r : Event->Event {
  *~po.~start.~mp_threads.mp_threads.start.*po
}
fun mp_same_proxy_r : Event->Event {
  proxy.~proxy
}
fun mp_cause_base : Event->Event {
  ^po + *po.^((sc + mp_sync).*po)
}
fun mp_proxy_preserved_cause_base : Event->Event {
  mp_same_alias[mp_GenericOps <: mp_cause_base :> mp_GenericOps]
  + mp_same_alias[mp_cause_base & mp_same_block_r & mp_same_proxy_r]
  + mp_same_alias[(mp_cause_base & ~mp_proxy_fence_ops).mp_cause_base :> mp_GenericOps]
  + mp_same_alias[mp_GenericOps <: mp_cause_base.(mp_cause_base & mp_proxy_fence_ops)]
  + mp_same_alias[(mp_cause_base & ~mp_proxy_fence_ops).mp_cause_base.(mp_cause_base & mp_proxy_fence_ops)]
  + mp_same_location[mp_GenericOps <: mp_cause_base.(AliasFence <: mp_cause_base ) :> mp_GenericOps]
  + mp_same_location[(mp_cause_base & ~mp_proxy_fence_ops).(mp_cause_base :> AliasFence).mp_cause_base :> mp_GenericOps]
  + mp_same_location[mp_GenericOps <: mp_cause_base.(AliasFence <: mp_cause_base).(mp_cause_base & mp_proxy_fence_ops)]
  + mp_same_location[(mp_cause_base & ~mp_proxy_fence_ops).(mp_cause_base :> AliasFence).mp_cause_base.(mp_cause_base & mp_proxy_fence_ops)]
}

fun mp_same_location_r : Event->Event { address.aliases.~address }
fun mp_same_location[rel: Event->Event] : Event->Event { rel & mp_same_location_r }
fun mp_same_alias_r : Event->Event { address.~address }
fun mp_same_alias[rel: Event->Event] : Event->Event { rel & mp_same_alias_r }

fun mp_scopes : set Event->Scope {
  *~po.~start.*~subscope
}
fun mp_inside[s: Scope] : Event {
  s.~mp_scopes
}
fun mp_scoped[s: Scope] : Event {
  s.*~subscope.~scope
}
fun mp_strong_r : Event->Event {
  symmetric[scope.~mp_scopes] & proxy.~proxy
}
fun mp_strong[r: Event->Event]: Event->Event {
  r & mp_strong_r
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// The mixed-proxy model with one change: morally strong memory operations use the same virtual address (the
// reading of ptx87.als, from 8.6 "using distinct virtual addresses behaves as if using different proxies"). The
// checks mq_* ask whether this is the only way ptx87 is weaker than the mixed-proxy model.

fun mq_threads : CtaScope->Thread { CtaScope <: subscope :> Thread }
fun mq_GenericOps : set Event { Generic.~proxy }

fun mq_po_loc : Event->Event { mq_same_alias[^po] }
fun mq_fr : Read->Write {
  ~rf.^co
  +
  mq_same_location[(Read - (Write.rf))->Write]
}
fun mq_com : MemoryEvent->MemoryEvent { rf + ^co + mq_fr }

fun mq_ReleaseFences : Fence { FenceAcqRel + FenceSC }
fun mq_AcquireFences : Fence { FenceAcqRel + FenceSC }

pred mq_causality {
  irreflexive[optional[mq_com].mq_cause]
}
pred mq_atomicity {
  no mq_strong[mq_fr].(mq_strong[co]) & rmw
}
pred mq_coherence {
  mq_same_location[Write <: mq_cause :> Write] in ^co
}
pred mq_seq_cst {
  FenceSC <: mq_cause :> FenceSC in sc
}
pred mq_no_thin_air {
  acyclic[rf + dep]
}
pred mq_ptx_mm {
  mq_no_thin_air and mq_atomicity and mq_coherence and mq_causality and mq_seq_cst
}

fun mq_cause : Event->Event {
  optional[mq_observation].mq_proxy_preserved_cause_base
}
fun mq_sync : Event->Event {
  mq_strong[mq_release_sequence.^mq_observation.mq_acquire_sequence]
}
fun mq_release_sequence : Event->Event {
  mq_strong[Release <: optional[mq_po_loc] :> Write]
  + mq_strong[mq_ReleaseFences <: ^po :> Write]
}
fun mq_observation : Event->Event {
  mq_strong[rf] + rmw
}
fun mq_acquire_sequence : Event->Event {
  mq_strong[Read <: optional[mq_po_loc] :> Acquire]
  + mq_strong[Read <: ^po :> mq_AcquireFences]
}

fun mq_proxy_fence_ops : ProxyFence->Event {
  mp_pfp.~proxy
  & mq_same_block_r
}
fun mq_same_block_r : Event->Event {
  *~po.~start.~mq_threads.mq_threads.start.*po
}
fun mq_same_proxy_r : Event->Event {
  proxy.~proxy
}
fun mq_cause_base : Event->Event {
  ^po + *po.^((sc + mq_sync).*po)
}
fun mq_proxy_preserved_cause_base : Event->Event {
  mq_same_alias[mq_GenericOps <: mq_cause_base :> mq_GenericOps]
  + mq_same_alias[mq_cause_base & mq_same_block_r & mq_same_proxy_r]
  + mq_same_alias[(mq_cause_base & ~mq_proxy_fence_ops).mq_cause_base :> mq_GenericOps]
  + mq_same_alias[mq_GenericOps <: mq_cause_base.(mq_cause_base & mq_proxy_fence_ops)]
  + mq_same_alias[(mq_cause_base & ~mq_proxy_fence_ops).mq_cause_base.(mq_cause_base & mq_proxy_fence_ops)]
  + mq_same_location[mq_GenericOps <: mq_cause_base.(AliasFence <: mq_cause_base ) :> mq_GenericOps]
  + mq_same_location[(mq_cause_base & ~mq_proxy_fence_ops).(mq_cause_base :> AliasFence).mq_cause_base :> mq_GenericOps]
  + mq_same_location[mq_GenericOps <: mq_cause_base.(AliasFence <: mq_cause_base).(mq_cause_base & mq_proxy_fence_ops)]
  + mq_same_location[(mq_cause_base & ~mq_proxy_fence_ops).(mq_cause_base :> AliasFence).mq_cause_base.(mq_cause_base & mq_proxy_fence_ops)]
}

fun mq_same_location_r : Event->Event { address.aliases.~address }
fun mq_same_location[rel: Event->Event] : Event->Event { rel & mq_same_location_r }
fun mq_same_alias_r : Event->Event { address.~address }
fun mq_same_alias[rel: Event->Event] : Event->Event { rel & mq_same_alias_r }

fun mq_scopes : set Event->Scope {
  *~po.~start.*~subscope
}
fun mq_inside[s: Scope] : Event {
  s.~mq_scopes
}
fun mq_scoped[s: Scope] : Event {
  s.*~subscope.~scope
}
fun mq_strong_r : Event->Event {
  symmetric[scope.~mq_scopes] & proxy.~proxy
  & ((MemoryEvent->MemoryEvent & address.~address) + (Event->Event - MemoryEvent->MemoryEvent))
}
fun mq_strong[r: Event->Event]: Event->Event {
  r & mq_strong_r
}

// The facts of alloy/ptx.als (the signature facts included).
pred mp_wf {
  all r: Acquire | r.scope not in Thread
  all w: Release | w.scope not in Thread
  all f: Fence | f.scope not in Thread
  mp_com in mp_same_location_r
  acyclic[po]
  all o: Event | one t: Thread | t->o in start.*po
  dep in ^po
  rmw in mp_same_alias[po & dep & scope.~scope]
  subscope.~subscope in iden
  all s: Scope | System in s.*~subscope
  acyclic[subscope]
  (MemoryEvent + Fence) <: scope in mp_scopes
  rf.~rf in iden
  all r: Read | some r.~rf => r.val = r.~rf.val else r.val = 0
  all a: Address | all s: Scope | all p: Proxy |
    total[co, mp_scoped[s] & mp_inside[s] & p.~proxy & (a.~address & Write)]
  all s: Scope | total[sc, mp_scoped[s] & mp_inside[s] & FenceSC]
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// The checks. 4 events; scopes: a thread per event, a block per thread, a device and the system.

pred both_wf { frag_mp and mp_wf }

wf_mp_4: check { frag_mp => mp_wf } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
ours_ptx_mm_4: check { (both_wf and mp_ptx_mm) => ptx_mm } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_ptx_mm_4: check { (both_wf and ptx_mm) => mp_ptx_mm } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
ours_causality_4: check { (both_wf and mp_causality) => causality } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_causality_4: check { (both_wf and causality) => mp_causality } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
ours_coherence_4: check { (both_wf and mp_coherence) => coherence } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_coherence_4: check { (both_wf and coherence) => mp_coherence } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
ours_atomicity_4: check { (both_wf and mp_atomicity) => atomicity } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_atomicity_4: check { (both_wf and atomicity) => mp_atomicity } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
ours_fence_sc_4: check { (both_wf and mp_seq_cst) => fence_sc } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_fence_sc_4: check { (both_wf and fence_sc) => mp_seq_cst } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_ptx_mm_5: check { (both_wf and ptx_mm) => mp_ptx_mm } for 5 but 8 Scope, 3 Address, 0 Access, 3 Int

// Without virtual aliases. With them, ptx87 is weaker than the mixed-proxy model: two operations on aliases of the
// same memory are not morally strong in ptx87 ("using distinct virtual addresses behaves as if using different
// proxies", 8.6), while the mixed-proxy model's morally strong ignores addresses. README.md discusses it.
mp_ptx_mm_noalias_4: check { (both_wf and no alias and ptx_mm) => mp_ptx_mm } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_ptx_mm_noalias_5: check { (both_wf and no alias and ptx_mm) => mp_ptx_mm } for 5 but 8 Scope, 3 Address, 0 Access, 3 Int
mp_causality_noalias_4: check { (both_wf and no alias and causality) => mp_causality } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_coherence_noalias_4: check { (both_wf and no alias and coherence) => mp_coherence } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mp_atomicity_noalias_4: check { (both_wf and no alias and atomicity) => mp_atomicity } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int

mq_ptx_mm_4: check { (both_wf and ptx_mm) => mq_ptx_mm } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
mq_ptx_mm_5: check { (both_wf and ptx_mm) => mq_ptx_mm } for 5 but 8 Scope, 3 Address, 0 Access, 3 Int

sanity_mp_proxy: run { both_wf and ptx_mm and mp_ptx_mm and some ProxyFence and some proxy.Texture } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
sanity_mp_alias: run { both_wf and ptx_mm and mp_ptx_mm and some AliasFence and some alias } for 4 but 7 Scope, 3 Address, 0 Access, 3 Int
