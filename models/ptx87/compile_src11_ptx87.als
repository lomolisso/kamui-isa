// The scoped C++ (scoped RC11) to PTX 8.7 mapping check: a bounded search for a PTX execution of a compiled,
// race-free scoped C++ program whose reverse-mapped execution violates scoped RC11.
//
// Derived from compile_src11_ptx.als of the PTX memory model of Lustig, Sahasrabuddhe and Giroux (ASPLOS 2019,
// NVlabs/PTXMemoryModel, BSD 3-Clause licence, see LICENSE), with ptx87.als as the PTX model. Changes: the PTX
// side is limited to what the mapping produces (hw_plain); the asserts are the artifact's coherence, atomicity,
// SC and no-thin-air checks; the sanity runs include scope trees with a cluster level, so C++ cluster scope
// (memory_scope_cluster) is covered. The mapping is the paper's (Figure 11): relaxed -> .relaxed, acquire and
// release -> .acquire and .release, fences -> fence.{acquire,release,acq_rel,sc}, all at the mapped scope.

module compile_src11_ptx87
open util as util
open ptx87 as hw
open src11[hw/Event,hw/Address,hw/Scope] as sw

////////////////////////////////////////////////////////////////////////////////

pred wf_map_insts {
  // All HW insts are derived from some SW inst
  sw/Event.map = hw/Event
  // every sw event lowers to at least one hw event
  all e: sw/Event | some e.map
  // every hw event comes from exactly one sw event
  all e: hw/Event | one e.~map
  // map sb onto po
  sb in map.^po.~map
}

pred wf_map_addrs {
  // "map" respects the address mappings
  sw/MemoryEvent<:address = map.(hw/MemoryEvent<:address).(~addrmap)
}

pred wf_map_scope {
  scopemap.~scopemap in iden
}

pred wf_map {
  wf_map_insts
  wf_map_addrs
  wf_map_scope
}

// The PTX side of a compiled C++ program: generic-proxy accesses to global memory, no aliases, no mixed sizes,
// no barriers, no asynchronous operations, no mbarrier objects, no restricted or proxy fences.
pred hw_plain {
  hw/MemoryEvent.proxy in Generic
  no hw/Access and no acc
  hw/Address.space in Global and no hw/Address.alias and no hw/Address.owner
  no ProxyFence and no AliasFence and no PlainProxyFence and no Barrier and no ClusterArrive and no ClusterWait
  no Marker and no AsyncUnit and no issue and no done and no gdep
  no Mbar and no MbarInit and no MbarWait and no TxAnchor
  no SyncRestrictCta and no SyncRestrictCluster and no OpRestrictInit and no ClusterArriveRelaxed
}

pred reverse_map_rf {
  hw/Write <: rf in ~map.(sw/Write <: rf).map
  hw/Read - hw/Write.rf = map[sw/Read - sw/Write.rf]
}

pred reverse_map_co {
  co in ~map.mo.map
}

pred reverse_map_fr {
  hw/fr in ~map.rb.map
}

pred reverse_map {
  reverse_map_rf
  reverse_map_co
  reverse_map_fr
}

////////////////////////////////////////////////////////////////////////////////

pred compile_read_na  { (sw/Read  & NA ).map in hw/Read }
pred compile_read_rx  { (sw/Read  & RLX).map in hw/Read }
pred compile_read_aq  { (sw/Read  & ACQ).map in hw/Acquire }
pred compile_write_na { (sw/Write & NA ).map in hw/Write }
pred compile_write_rx { (sw/Write & RLX).map in hw/Write }
pred compile_write_rl { (sw/Write & REL).map in hw/Release }
pred compile_fence_aq { (sw/Fence & ACQ).map in hw/FenceAcq }
pred compile_fence_rl { (sw/Fence & REL).map in hw/FenceRel }
pred compile_fence_ar { (sw/Fence & AR ).map in hw/FenceAcqRel }
pred compile_fence_sc { (sw/Fence & SC ).map in hw/FenceSC }

pred compile_rmw { sw/Read <: rmw = map.rmw.~map }

pred compile_scope {
  (sw/Thread <: start).map = scopemap.start
  (sw/Event <: scope).scopemap = map.scope
  (sw/Scope <: subscope).scopemap in scopemap.subscope
}

pred compile_MemoryEvents {
  compile_read_na
  compile_read_rx
  compile_read_aq
  compile_write_na
  compile_write_rx
  compile_write_rl
  compile_fence_aq
  compile_fence_rl
  compile_fence_ar
  compile_fence_sc
  compile_rmw
  compile_scope
}

pred compile_src11_ptx87 {
  // Start with a valid C11 program
  not racy

  // ...compile onto ptx
  wf_map
  hw_plain
  compile_MemoryEvents

  // ...find a legal ptx execution
  ptx_mm

  // ...reverse-map that execution back into C11
  and reverse_map
}

////////////////////////////////////////////////////////////////////////////////
// The checks (bounds of the 2019 artifact; see README.md for the bounds used and the times)

assert src11_ptx87_legal_coherence { compile_src11_ptx87 => sw/coherence }
check src11_ptx87_legal_coherence for 6

assert src11_ptx87_legal_atomicity { compile_src11_ptx87 => sw/atomicity }
check src11_ptx87_legal_atomicity for 6

assert src11_ptx87_legal_sc { compile_src11_ptx87 => sw/sc }
check src11_ptx87_legal_sc for 6 but 5 sw/Event

assert src11_ptx87_legal_no_thin_air { compile_src11_ptx87 => sw/no_thin_air }
check src11_ptx87_legal_no_thin_air for 6

// the same checks at smaller bounds (every signature at most 4 or 5 atoms)
coherence_4: check src11_ptx87_legal_coherence for 4
coherence_5: check src11_ptx87_legal_coherence for 5
atomicity_4: check src11_ptx87_legal_atomicity for 4
atomicity_5: check src11_ptx87_legal_atomicity for 5
sc_4: check src11_ptx87_legal_sc for 4
sc_5: check src11_ptx87_legal_sc for 5

// the paper's size (5 C++ events) with room for a cluster level in the scope tree: sys, gpu, cluster, two CTAs,
// two threads (7 nodes; `for 5` alone allows only 5)
coherence_5e7s: check src11_ptx87_legal_coherence for 5 but 7 hw/Scope, 7 sw/Scope
atomicity_5e7s: check src11_ptx87_legal_atomicity for 5 but 7 hw/Scope, 7 sw/Scope
sc_5e7s: check src11_ptx87_legal_sc for 5 but 7 hw/Scope, 7 sw/Scope

////////////////////////////////////////////////////////////////////////////////
// Sanity: the checks are not vacuous (each run must find an instance)

run sanity {
  some hw/Read
  compile_src11_ptx87
} for 4 but 4 hw/Scope

// message passing with a synchronizing release/acquire pair
run MP { some NA <: sb.(sw/sw).sb :> NA & rf and some sw/Scope <: subscope and compile_src11_ptx87 and src11 } for 4

// the same, with the synchronization at the scope of a cluster: the C++ scope maps to a ClusterScope node that
// lies between the GPU and two CTAs, one per thread
run MP_cluster {
  some NA <: sb.(sw/sw).sb :> NA & rf
  some c: ClusterScope | some (sw/Event <: scope).scopemap & sw/Event -> c and #(c.subscope & CtaScope) = 2
  compile_src11_ptx87 and src11
} for 6 but 4 sw/Event, 4 hw/Event, 8 hw/Scope, 8 sw/Scope
