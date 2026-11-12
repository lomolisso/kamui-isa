// The bounded check of the PTX 8.7 to Kamui lowering: a search for a PTX program (of one feature group) and a
// Kamui execution of its lowering whose execution, read back into the PTX program, violates the PTX 8.7 model.
//
// The lowering (models/kamui/lowering.yaml, read through models/kamui/instructions.yaml) gives every PTX event
// an image in the Kamui program: an event of the same kind, on the same location, in the same thread and in the
// same place in program order. Everything else is either the same or one of the three ways a Kamui program may
// be stronger:
//   - a wider scope for a strong operation (the standard instructions are at .sys, K2);
//   - a fence.sc.sys inserted before an acquire-release read-modify-write (`.aqrl`, K2).
// (`relax` below, a weak generic read in place of a weak non-coherent read, is not used by the lowering: the
// `proxies` group showed it is not stronger, K9; `broken_relax_nc` keeps that counterexample.)
// Rules that are one-to-one at the level of events (membar = fence.sc, .volatile, cp.async.wait_all, the
// tensormap.cp_fenceproxy sequence, red on shared memory as an atomic with no result, the elect loop of K6, ...)
// are covered by the identity. The execution (reads-from, coherence, Fence-SC order, barrier generations, values
// and mbarrier states) is chosen on the Kamui side and read back. A check passes with UNSAT: no counterexample
// within its bound.
//
// Shape of compile_src11_ptx87.als in models/ptx87 (from the 2019 artifact of Lustig, Sahasrabuddhe and
// Giroux); both models are the PTX 8.7 model (K1), opened twice so that two executions exist side by side.

module compile_ptx87_kamui
open util
open ptx87 as p
open kamui as k

one sig Map {
  ev: p/Event -> one k/Event,         // the image of a PTX event
  pre: p/Event -> lone k/FenceSC,     // a fence.sc.sys inserted before the image (.aqrl)
  ad: p/Address -> one k/Address,
  sm: p/Scope -> one k/Scope,
  widen: set p/Event,                 // events whose image has a wider scope (std)
  relax: lone p/Event                 // a weak non-coherent read whose image reads the generic proxy (K9)
}

fun m : p/Event -> k/Event { Map.ev }
fun mpre : p/Event -> k/Event { Map.pre }
fun ma : p/Address -> k/Address { Map.ad }
fun ms : p/Scope -> k/Scope { Map.sm }
// the first Kamui event of a PTX event's lowering
fun first : p/Event -> k/Event { mpre + ((p/Event - mpre.k/Event) <: m) }
fun mp : p/Proxy -> k/Proxy {
  p/Generic -> k/Generic + p/Async -> k/Async + p/TensorMap -> k/TensorMap + p/Texture -> k/Texture
  + p/Surface -> k/Surface + p/Constant -> k/Constant
}
fun msp : p/Space -> k/Space {
  p/Global -> k/Global + p/Shared -> k/Shared + p/Local -> k/Local + p/Const -> k/Const + p/Param -> k/Param
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// The two programs correspond.

pred bijections {
  m.~m in iden and mpre.~mpre in iden and ma.~ma in iden and ms.~ms in iden
  k/Event = p/Event.m + p/Event.mpre and no p/Event.m & p/Event.mpre
  k/Address = p/Address.ma and k/Scope = p/Scope.ms
}

pred same_scope_tree {
  (k/Scope <: subscope) = ~ms.((p/Scope <: subscope)).ms
  k/CtaScope = p/CtaScope.ms and k/ClusterScope = p/ClusterScope.ms
  k/Thread = p/Thread.ms and k/AsyncUnit = p/AsyncUnit.ms
}

pred same_locations {
  (k/Address <: alias) = ~ma.((p/Address <: alias)).ma
  (k/Address <: space) = ~ma.((p/Address <: space)).msp
  (k/Address <: owner) = ~ma.((p/Address <: owner)).ms
  (k/Address <: init) = ~ma.((p/Address <: init))
  k/Mbar = p/Mbar.ma
  (k/Mbar <: iph) = ~ma.((p/Mbar <: iph)) and (k/Mbar <: ipend) = ~ma.((p/Mbar <: ipend)) and (k/Mbar <: iexp) = ~ma.((p/Mbar <: iexp)) and (k/Mbar <: itx) = ~ma.((p/Mbar <: itx))
  no p/Access and no k/Access    // no mixed-size accesses in the bounded check
  no p/VecAccess and no k/VecAccess    // no atomic vector accesses either (D43; the Rocq proof covers them)
}

// program order and threads: the image of a PTX event takes its place; an inserted fence comes just before it
pred same_order {
  (k/Event <: po) = ~m.((p/Event <: po)).first + ~mpre.m
  (k/Thread <: start) = ~ms.((p/Thread <: start)).first
  all f: p/Event.mpre | f.((k/Event <: scope)) = k/System
}

// the image has the same kind as the PTX event (events in x are left to a broken lowering)
pred kinds[x: set p/Event] {
  let e = p/Event - x, img = e.m {
    (p/Read & e).m = k/Read & img and (p/Write & e).m = k/Write & img
    (p/Acquire & e).m = k/Acquire & img and (p/Release & e).m = k/Release & img
    (p/FenceAcq & e).m = k/FenceAcq & img and (p/FenceRel & e).m = k/FenceRel & img
    (p/FenceAcqRel & e).m = k/FenceAcqRel & img and (p/FenceSC & e).m = k/FenceSC & img
    (p/SyncRestrictCta & e).m = k/SyncRestrictCta & img and (p/SyncRestrictCluster & e).m = k/SyncRestrictCluster & img
    (p/OpRestrictInit & e).m = k/OpRestrictInit & img
    (p/AliasFence & e).m = k/AliasFence & img and (p/PlainProxyFence & e).m = k/PlainProxyFence & img
    (p/BarrierArrive & e).m = k/BarrierArrive & img and (p/BarrierWait & e).m = k/BarrierWait & img
    (p/ClusterArrive & e).m = k/ClusterArrive & img and (p/ClusterArriveRelaxed & e).m = k/ClusterArriveRelaxed & img
    (p/ClusterWait & e).m = k/ClusterWait & img and (p/Marker & e).m = k/Marker & img
    (p/MbarInit & e).m = k/MbarInit & img and (p/MbarWait & e).m = k/MbarWait & img
    (p/TxAnchor & e).m = k/TxAnchor & img and (p/ProxyFence & e).m = k/ProxyFence & img
  }
}

// the program relations of each event carry over
pred same_relations[x: set p/Event, dropped: set p/Event] {
  (k/MemoryEvent <: address) = ~m.((p/MemoryEvent <: address)).ma
  (k/Read <: rmw) = ~m.((p/Read <: rmw)).m and (k/Read <: dep) = ~m.((p/Read <: dep)).m
  (k/Event <: issue) = ~m.((p/Event - dropped) <: (p/Event <: issue)).m and (k/Event <: done) = ~m.((p/Event <: done)).m and (k/Event <: gdep) = ~m.((p/Event <: gdep)).m
  (k/BarrierArrive <: bid) = ~m.((p/BarrierArrive <: bid)) and (k/BarrierArrive <: bcount) = ~m.((p/BarrierArrive <: bcount)) and (k/BarrierArrive <: bwait) = ~m.((p/BarrierArrive <: bwait)).m and (k/ClusterArrive <: cwait) = ~m.((p/ClusterArrive <: cwait)).m
  (k/MbarWait <: wpar) = ~m.((p/MbarWait <: wpar)) and (k/MbarWait <: wtok) = ~m.((p/MbarWait <: wtok))
  (k/TxAnchor <: txops) = ~m.((p/TxAnchor <: txops)).m
  all e: p/ProxyFence - x | e.m.((k/ProxyFence <: dirs)) = ~mp.(e.((p/ProxyFence <: dirs))).mp and e.m.((k/ProxyFence <: pspace)) = e.((p/ProxyFence <: pspace)).msp
                        and e.m.((k/ProxyFence <: paddr)) = e.((p/ProxyFence <: paddr)).ma
}

// the proxy of every access is the same, or (K9) a weak read of the non-coherent path becomes a generic one
pred proxies {
  all e: p/MemoryEvent - Map.relax | e.m.((k/MemoryEvent <: proxy)) = e.((p/MemoryEvent <: proxy)).mp
  all e: Map.relax | e in p/Read - ((p/Read <: rmw)).p/Event and e in p/Weak and e.((p/MemoryEvent <: proxy)) = p/Texture
                     and e.m.((k/MemoryEvent <: proxy)) = k/Generic
}

// the scope of every image is the same, or (std) a wider one for a strong operation
pred scopes[x: set p/Event] {
  all e: p/Event - Map.widen - x | e.m.((k/Event <: scope)) = e.((p/Event <: scope)).ms
  all e: Map.widen - x | e not in p/Weak and e.m.((k/Event <: scope)) in e.((p/Event <: scope)).ms.*~((k/Scope <: subscope))
  // the two halves of a read-modify-write stay at one scope (the model requires it)
  all r: ((p/Read <: rmw)).p/Event | r.m.((k/Event <: scope)) = r.((p/Read <: rmw)).m.((k/Event <: scope))
}

// inserted fences: only before the read of an acquire-release read-modify-write
pred inserted { mpre.k/Event in p/Acquire & ((p/Read <: rmw)).p/Release }

// the execution of the Kamui program, read back into the PTX program
pred read_back {
  (p/Write <: rf) = m.((k/Write <: rf)).~m and (p/Write <: co) = m.((k/Write <: co)).~m
  (p/FenceSC <: sc) = m.((k/FenceSC <: sc)).~m & p/ms_r
  (p/BarrierArrive <: bgen) = m.((k/BarrierArrive <: bgen)).~m and (p/ClusterArrive <: cgen) = m.((k/ClusterArrive <: cgen)).~m
  (p/MemoryEvent <: val) = m.((k/MemoryEvent <: val))
  (p/MbarEv <: ph) = m.((k/MbarEv <: ph)) and (p/MbarEv <: pend) = m.((k/MbarEv <: pend)) and (p/MbarEv <: expc) = m.((k/MbarEv <: expc)) and (p/MbarEv <: tx) = m.((k/MbarEv <: tx))
}

// x: events whose kind and scope a broken lowering changes; dropped: issue edges a broken lowering drops
pred lowering_ex[x: set p/Event, dropped: set p/Event] {
  bijections and same_scope_tree and same_locations and same_order and kinds[x] and same_relations[x, dropped]
  proxies and scopes[x] and inserted
  read_back
}
pred lowering { lowering_ex[none, none] }

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Feature groups: which PTX programs a check considers (the PTX side; the Kamui side follows the map).

pred no_async { no p/AsyncUnit and no (p/Event <: issue) and no (p/Event <: done) and no (p/Event <: gdep) and no p/TxAnchor and no p/Marker }
pred no_mbar { no p/Mbar and no p/MbarInit and no p/MbarWait }
pred no_barriers { no p/Barrier and no p/ClusterArrive and no p/ClusterWait }
pred no_restrict { no p/SyncRestrictCta and no p/SyncRestrictCluster and no p/OpRestrictInit }
pred no_proxy_ops { no p/ProxyFence and no p/AliasFence and no p/PlainProxyFence and no p/Address.((p/Address <: alias)) }
pred generic_only { p/MemoryEvent.((p/MemoryEvent <: proxy)) in p/Generic }

pred g_core { no_async and no_mbar and no_barriers and no_restrict and no_proxy_ops and generic_only }
pred g_proxies { no_async and no_mbar and no_barriers and no_restrict
                 and p/MemoryEvent.((p/MemoryEvent <: proxy)) in p/Generic + p/Texture + p/Surface + p/Constant }
pred g_barriers { no_async and no_mbar and no_restrict and no_proxy_ops and generic_only }
pred g_mbarrier { no_async and no_barriers and no_restrict and no_proxy_ops and generic_only }
pred g_async { no_barriers and no_restrict and no p/AliasFence and no p/Address.((p/Address <: alias)) and no (p/Event <: gdep)
               and p/MemoryEvent.((p/MemoryEvent <: proxy)) in p/Generic + p/Async }
pred g_restricted { no_async and no_proxy_ops and generic_only and some p/SyncRestrictCta + p/SyncRestrictCluster + p/OpRestrictInit }
pred g_rest { no_barriers and no p/AliasFence and no p/Address.((p/Address <: alias))
              and p/MemoryEvent.((p/MemoryEvent <: proxy)) in p/Generic + p/Async + p/TensorMap }

// the lowerings checked: the identity (Kamui instructions) and the standard alternatives (std)
pred ident { lowering and no Map.widen and no Map.pre and no Map.relax }
pred std { lowering and no Map.relax }
pred nc { lowering and no Map.widen and no Map.pre }

pred ptx_ok { p/ptx_mm or p/undefined }

pred core      { g_core and ident and k/ptx_mm }
pred core_std  { g_core and std and k/ptx_mm }
pred proxies_  { g_proxies and ident and k/ptx_mm }
pred barriers  { g_barriers and ident and k/ptx_mm }
pred mbarrier  { g_mbarrier and ident and k/ptx_mm }
pred async     { g_async and ident and k/ptx_mm }
pred restricted { g_restricted and ident and k/ptx_mm }
pred rest      { g_rest and ident and k/ptx_mm }

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// The checks: one per group and PTX axiom. `undefined` behaviour of the PTX program allows every outcome.

assert core_coherence { core => (p/coherence or p/undefined) }
assert core_fence_sc { core => (p/fence_sc or p/undefined) }
assert core_atomicity { core => (p/atomicity or p/undefined) }
assert core_no_thin_air { core => (p/no_thin_air or p/undefined) }
assert core_sc_per_location { core => (p/sc_per_location or p/undefined) }
assert core_causality { core => (p/causality or p/undefined) }
assert core_std_coherence { core_std => (p/coherence or p/undefined) }
assert core_std_fence_sc { core_std => (p/fence_sc or p/undefined) }
assert core_std_atomicity { core_std => (p/atomicity or p/undefined) }
assert core_std_no_thin_air { core_std => (p/no_thin_air or p/undefined) }
assert core_std_sc_per_location { core_std => (p/sc_per_location or p/undefined) }
assert core_std_causality { core_std => (p/causality or p/undefined) }
assert proxies_coherence { proxies_ => (p/coherence or p/undefined) }
assert proxies_fence_sc { proxies_ => (p/fence_sc or p/undefined) }
assert proxies_atomicity { proxies_ => (p/atomicity or p/undefined) }
assert proxies_no_thin_air { proxies_ => (p/no_thin_air or p/undefined) }
assert proxies_sc_per_location { proxies_ => (p/sc_per_location or p/undefined) }
assert proxies_causality { proxies_ => (p/causality or p/undefined) }
assert barriers_coherence { barriers => (p/coherence or p/undefined) }
assert barriers_fence_sc { barriers => (p/fence_sc or p/undefined) }
assert barriers_atomicity { barriers => (p/atomicity or p/undefined) }
assert barriers_no_thin_air { barriers => (p/no_thin_air or p/undefined) }
assert barriers_sc_per_location { barriers => (p/sc_per_location or p/undefined) }
assert barriers_causality { barriers => (p/causality or p/undefined) }
assert mbarrier_coherence { mbarrier => (p/coherence or p/undefined) }
assert mbarrier_fence_sc { mbarrier => (p/fence_sc or p/undefined) }
assert mbarrier_atomicity { mbarrier => (p/atomicity or p/undefined) }
assert mbarrier_no_thin_air { mbarrier => (p/no_thin_air or p/undefined) }
assert mbarrier_sc_per_location { mbarrier => (p/sc_per_location or p/undefined) }
assert mbarrier_causality { mbarrier => (p/causality or p/undefined) }
assert async_coherence { async => (p/coherence or p/undefined) }
assert async_fence_sc { async => (p/fence_sc or p/undefined) }
assert async_atomicity { async => (p/atomicity or p/undefined) }
assert async_no_thin_air { async => (p/no_thin_air or p/undefined) }
assert async_sc_per_location { async => (p/sc_per_location or p/undefined) }
assert async_causality { async => (p/causality or p/undefined) }
assert restricted_coherence { restricted => (p/coherence or p/undefined) }
assert restricted_fence_sc { restricted => (p/fence_sc or p/undefined) }
assert restricted_atomicity { restricted => (p/atomicity or p/undefined) }
assert restricted_no_thin_air { restricted => (p/no_thin_air or p/undefined) }
assert restricted_sc_per_location { restricted => (p/sc_per_location or p/undefined) }
assert restricted_causality { restricted => (p/causality or p/undefined) }
assert rest_coherence { rest => (p/coherence or p/undefined) }
assert rest_fence_sc { rest => (p/fence_sc or p/undefined) }
assert rest_atomicity { rest => (p/atomicity or p/undefined) }
assert rest_no_thin_air { rest => (p/no_thin_air or p/undefined) }
assert rest_sc_per_location { rest => (p/sc_per_location or p/undefined) }
assert rest_causality { rest => (p/causality or p/undefined) }

// Which checks need a solver. With the identity lowering (every group but core_std) the Kamui program and its
// execution are a copy of the PTX ones: the correspondence above names every signature and field of the PTX model
// (tools/litmus/check_suite.py checks this), and kamui.als is ptx87.als, so each axiom has the same truth value on
// both sides at every size. Those checks hold without a solver; their bound-3 commands below are kept as a test of
// the correspondence predicates. Only core_std (wider scopes, an inserted fence.sc.sys) can find a lowering bug,
// so only it has bound-4 and bound-5 commands.
//
// Bound 4: at most 4 atoms of each signature of each model, except the scope tree, which gets 7 nodes (enough for
// two threads in two CTAs of one cluster: system, GPU, cluster, two CTAs, two threads; plain `for 4` would allow
// only single-CTA programs at cluster scope), and, in core_std, the Kamui events, which get one more (an
// inserted fence).
// Signatures a group's programs cannot contain get 0 atoms, so that the solver does not carry their relations (the
// group predicates exclude them anyway; the bound only makes the problem smaller). The `3` and `5` commands are the
// same at bounds 3 and 5.
core_std_coherence_4: check core_std_coherence for 4 but 7 p/Scope, 7 k/Scope, 5 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_fence_sc_4: check core_std_fence_sc for 4 but 7 p/Scope, 7 k/Scope, 5 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_atomicity_4: check core_std_atomicity for 4 but 7 p/Scope, 7 k/Scope, 5 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_no_thin_air_4: check core_std_no_thin_air for 4 but 7 p/Scope, 7 k/Scope, 5 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_sc_per_location_4: check core_std_sc_per_location for 4 but 7 p/Scope, 7 k/Scope, 5 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_causality_4: check core_std_causality for 4 but 7 p/Scope, 7 k/Scope, 5 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait

core_coherence_3: check core_coherence for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_fence_sc_3: check core_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_atomicity_3: check core_atomicity for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_no_thin_air_3: check core_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_sc_per_location_3: check core_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_causality_3: check core_causality for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_coherence_3: check core_std_coherence for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_fence_sc_3: check core_std_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_atomicity_3: check core_std_atomicity for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_no_thin_air_3: check core_std_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_sc_per_location_3: check core_std_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_causality_3: check core_std_causality for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_coherence_3: check proxies_coherence for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_fence_sc_3: check proxies_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_atomicity_3: check proxies_atomicity for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_no_thin_air_3: check proxies_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_sc_per_location_3: check proxies_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_causality_3: check proxies_causality for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
barriers_coherence_3: check barriers_coherence for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_fence_sc_3: check barriers_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_atomicity_3: check barriers_atomicity for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_no_thin_air_3: check barriers_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_sc_per_location_3: check barriers_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_causality_3: check barriers_causality for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
mbarrier_coherence_3: check mbarrier_coherence for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_fence_sc_3: check mbarrier_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_atomicity_3: check mbarrier_atomicity for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_no_thin_air_3: check mbarrier_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_sc_per_location_3: check mbarrier_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_causality_3: check mbarrier_causality for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_coherence_3: check async_coherence for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_fence_sc_3: check async_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_atomicity_3: check async_atomicity for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_no_thin_air_3: check async_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_sc_per_location_3: check async_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_causality_3: check async_causality for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
restricted_coherence_3: check restricted_coherence for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_fence_sc_3: check restricted_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_atomicity_3: check restricted_atomicity for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_no_thin_air_3: check restricted_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_sc_per_location_3: check restricted_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_causality_3: check restricted_causality for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
rest_coherence_3: check rest_coherence for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_fence_sc_3: check rest_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_atomicity_3: check rest_atomicity for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_no_thin_air_3: check rest_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_sc_per_location_3: check rest_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_causality_3: check rest_causality for 3 but 7 p/Scope, 7 k/Scope, 3 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait

core_std_coherence_5: check core_std_coherence for 5 but 7 p/Scope, 7 k/Scope, 6 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_fence_sc_5: check core_std_fence_sc for 5 but 7 p/Scope, 7 k/Scope, 6 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_atomicity_5: check core_std_atomicity for 5 but 7 p/Scope, 7 k/Scope, 6 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_no_thin_air_5: check core_std_no_thin_air for 5 but 7 p/Scope, 7 k/Scope, 6 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_sc_per_location_5: check core_std_sc_per_location for 5 but 7 p/Scope, 7 k/Scope, 6 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
core_std_causality_5: check core_std_causality for 5 but 7 p/Scope, 7 k/Scope, 6 k/Event, 0 p/Access, 0 k/Access, 0 p/VecAccess, 0 k/VecAccess, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Sanity: each group has lowered programs whose PTX side synchronizes (the checks are not vacuous).

run sanity_core { core and some p/sync_pattern } for 4 but 5 k/Event
run sanity_core_std { core_std and some p/sync_pattern and some Map.pre and some e: Map.widen | e.m.((k/Event <: scope)) != e.((p/Event <: scope)).ms } for 4 but 6 k/Event
run sanity_cluster { core and some p/sync_pattern and some (p/Event.((p/Event <: scope)) & p/ClusterScope) } for 4 but 6 p/Scope, 6 k/Scope, 5 k/Event
run sanity_proxies { proxies_ and some (p/MemoryEvent <: proxy).(p/Proxy - p/Generic) and some p/sync_pattern } for 4 but 5 k/Event
run sanity_barriers { barriers and some (p/BarrierArrive <: synchronizes) } for 4 but 5 k/Event
run sanity_mbarrier { mbarrier and some p/MbarWait and some p/sync_pattern } for 4 but 5 k/Event
run sanity_async { async and some (p/Event <: issue) and some (p/Event <: done) } for 5 but 6 k/Event
run sanity_restricted { restricted and some p/sw } for 4 but 5 k/Event
run sanity_rest { rest and some p/TensorMap.~((p/MemoryEvent <: proxy)) } for 5 but 6 k/Event

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Broken lowerings (models/kamui/README.md): each must find a counterexample, a Kamui execution of the
// broken lowering whose read-back violates the PTX model. They show that the checks above can fail.

// an acquire load lowered as a relaxed load (core)
run broken_drop_acquire {
  some a: p/Acquire - ((p/Read <: rmw)).p/Event - p/MbarWait {
    g_core and lowering_ex[a, none] and no Map.widen and no Map.pre and no Map.relax and k/ptx_mm and not ptx_ok
    a.m in k/Read - k/Acquire and a.m.((k/Event <: scope)) = a.((p/Event <: scope)).ms
  }
} for 4 but 5 k/Event

// a release, acquire or acq_rel fence at gpu or sys scope lowered at cta scope (core). The smallest counterexample
// is message passing with a release fence (data write, fence, flag write; flag read, data read): 5 events, so this
// run uses bound 5. (A narrowed fence.sc cannot
// be checked this way: the check reads the PTX side's Fence-SC order back from the Kamui side, which is exact for
// lowerings that keep or widen scopes, as all of Kamui's do, but leaves a narrowed fence.sc with no order.)
run broken_narrow_fence {
  some f: p/Fence - p/FenceSC {
    g_core and lowering_ex[f, none] and no Map.widen and no Map.pre and no Map.relax and k/ptx_mm and not ptx_ok
    f.m in k/Fence - k/FenceSC and f.m.((k/Event <: scope)) = f.(p/cta_of).ms and f.((p/Event <: scope)) not in p/CtaScope
    (f in p/FenceAcq) <=> (f.m in k/FenceAcq) and (f in p/FenceRel) <=> (f.m in k/FenceRel)
    (f in p/FenceAcqRel) <=> (f.m in k/FenceAcqRel)
  }
} for 5 but 7 p/Scope, 7 k/Scope, 5 k/Event

// the standard alternative of an acquire load is a plain lw, which is weak (core, std)
run broken_std_weak_load {
  some a: p/Acquire - ((p/Read <: rmw)).p/Event - p/MbarWait {
    g_core and lowering_ex[a, none] and no Map.relax and k/ptx_mm and not ptx_ok
    a.m in k/Read - k/Acquire and a.m.((k/Event <: scope)) = a.(p/thd).ms
  }
} for 4 but 5 k/Event

// an mbarrier arrive lowered without its release (mbarrier)
run broken_mbar_relaxed {
  some w: p/Release & p/MbarEv - p/MbarInit {
    g_mbarrier and lowering_ex[w, none] and no Map.widen and no Map.pre and no Map.relax and k/ptx_mm and not ptx_ok
    w.m in k/Write - k/Release and w.m.((k/Event <: scope)) = w.((p/Event <: scope)).ms
  }
} for 4 but 5 k/Event

// an asynchronous copy performed without being ordered after the instruction that asked for it, as when
// another thread issues it without the rule of K6 (async)
run broken_copy_unordered {
  some i: (p/Event <: issue).p/Event {
    g_async and lowering_ex[none, i] and no Map.widen and no Map.pre and no Map.relax and k/ptx_mm and not ptx_ok
  }
} for 5 but 6 k/Event

// a fence.release.sync_restrict::shared::cta dropped (restricted)
run broken_drop_restrict {
  some f: p/SyncRestrictCta {
    g_restricted and lowering_ex[f, none] and no Map.widen and no Map.pre and no Map.relax and k/ptx_mm and not ptx_ok
    f.m in k/Marker and f.m.((k/Event <: scope)) = f.(p/thd).ms
  }
} for 6 but 7 p/Scope, 7 k/Scope, 7 k/Event

// a fence.proxy.async dropped (async)
run broken_drop_proxy_fence {
  some f: p/PlainProxyFence - p/AsyncUnit.~(p/thd) {
    g_async and lowering_ex[f, none] and no Map.widen and no Map.pre and no Map.relax and k/ptx_mm and not ptx_ok
    f.m in k/Marker and f.m.((k/Event <: scope)) = f.(p/thd).ms
  }
} for 5 but 6 k/Event

// a weak non-coherent read lowered as a generic one (the first version of K9): not stronger, because another
// non-coherent read of the same location by the same thread is no longer morally strong with it (proxies)
run broken_relax_nc {
  g_proxies and nc and k/ptx_mm and not ptx_ok
} for 4 but 5 k/Event
