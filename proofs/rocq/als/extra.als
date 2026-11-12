// Checks of the PTX 8.7 to Kamui lowering that models/kamui/compile_ptx87_kamui.als does not have, run by
// check.sh next to this file before the Rocq proof (a counterexample would mean the lowering is wrong):
//   - the standard alternatives (std: wider scopes, a fence.sc.sys before .aqrl) on the programs of every feature
//     group, at bound 3 (compile_ptx87_kamui.als checks them on core programs only, up to bound 4);
//   - broken lowerings for the two groups that have none there (barriers, rest); each must find a counterexample.
// Mixed-size accesses cannot be checked this way: the lowering of compile_ptx87_kamui.als excludes them.

module extra
open util
open compile_ptx87_kamui
open ptx87 as p
open kamui as k

pred proxies_std { g_proxies and std and k/ptx_mm }
pred barriers_std { g_barriers and std and k/ptx_mm }
pred mbarrier_std { g_mbarrier and std and k/ptx_mm }
pred async_std { g_async and std and k/ptx_mm }
pred restricted_std { g_restricted and std and k/ptx_mm }
pred rest_std { g_rest and std and k/ptx_mm }

assert proxies_std_coherence { proxies_std => (p/coherence or p/undefined) }
assert proxies_std_fence_sc { proxies_std => (p/fence_sc or p/undefined) }
assert proxies_std_atomicity { proxies_std => (p/atomicity or p/undefined) }
assert proxies_std_no_thin_air { proxies_std => (p/no_thin_air or p/undefined) }
assert proxies_std_sc_per_location { proxies_std => (p/sc_per_location or p/undefined) }
assert proxies_std_causality { proxies_std => (p/causality or p/undefined) }
assert barriers_std_coherence { barriers_std => (p/coherence or p/undefined) }
assert barriers_std_fence_sc { barriers_std => (p/fence_sc or p/undefined) }
assert barriers_std_atomicity { barriers_std => (p/atomicity or p/undefined) }
assert barriers_std_no_thin_air { barriers_std => (p/no_thin_air or p/undefined) }
assert barriers_std_sc_per_location { barriers_std => (p/sc_per_location or p/undefined) }
assert barriers_std_causality { barriers_std => (p/causality or p/undefined) }
assert mbarrier_std_coherence { mbarrier_std => (p/coherence or p/undefined) }
assert mbarrier_std_fence_sc { mbarrier_std => (p/fence_sc or p/undefined) }
assert mbarrier_std_atomicity { mbarrier_std => (p/atomicity or p/undefined) }
assert mbarrier_std_no_thin_air { mbarrier_std => (p/no_thin_air or p/undefined) }
assert mbarrier_std_sc_per_location { mbarrier_std => (p/sc_per_location or p/undefined) }
assert mbarrier_std_causality { mbarrier_std => (p/causality or p/undefined) }
assert async_std_coherence { async_std => (p/coherence or p/undefined) }
assert async_std_fence_sc { async_std => (p/fence_sc or p/undefined) }
assert async_std_atomicity { async_std => (p/atomicity or p/undefined) }
assert async_std_no_thin_air { async_std => (p/no_thin_air or p/undefined) }
assert async_std_sc_per_location { async_std => (p/sc_per_location or p/undefined) }
assert async_std_causality { async_std => (p/causality or p/undefined) }
assert restricted_std_coherence { restricted_std => (p/coherence or p/undefined) }
assert restricted_std_fence_sc { restricted_std => (p/fence_sc or p/undefined) }
assert restricted_std_atomicity { restricted_std => (p/atomicity or p/undefined) }
assert restricted_std_no_thin_air { restricted_std => (p/no_thin_air or p/undefined) }
assert restricted_std_sc_per_location { restricted_std => (p/sc_per_location or p/undefined) }
assert restricted_std_causality { restricted_std => (p/causality or p/undefined) }
assert rest_std_coherence { rest_std => (p/coherence or p/undefined) }
assert rest_std_fence_sc { rest_std => (p/fence_sc or p/undefined) }
assert rest_std_atomicity { rest_std => (p/atomicity or p/undefined) }
assert rest_std_no_thin_air { rest_std => (p/no_thin_air or p/undefined) }
assert rest_std_sc_per_location { rest_std => (p/sc_per_location or p/undefined) }
assert rest_std_causality { rest_std => (p/causality or p/undefined) }

// Bound 3, as the identity commands of compile_ptx87_kamui.als, with one more Kamui event (an inserted fence).
proxies_std_coherence_3: check proxies_std_coherence for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_std_fence_sc_3: check proxies_std_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_std_atomicity_3: check proxies_std_atomicity for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_std_no_thin_air_3: check proxies_std_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_std_sc_per_location_3: check proxies_std_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
proxies_std_causality_3: check proxies_std_causality for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
barriers_std_coherence_3: check barriers_std_coherence for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_std_fence_sc_3: check barriers_std_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_std_atomicity_3: check barriers_std_atomicity for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_std_no_thin_air_3: check barriers_std_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_std_sc_per_location_3: check barriers_std_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
barriers_std_causality_3: check barriers_std_causality for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
mbarrier_std_coherence_3: check mbarrier_std_coherence for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_std_fence_sc_3: check mbarrier_std_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_std_atomicity_3: check mbarrier_std_atomicity for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_std_no_thin_air_3: check mbarrier_std_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_std_sc_per_location_3: check mbarrier_std_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
mbarrier_std_causality_3: check mbarrier_std_causality for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_std_coherence_3: check async_std_coherence for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_std_fence_sc_3: check async_std_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_std_atomicity_3: check async_std_atomicity for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_std_no_thin_air_3: check async_std_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_std_sc_per_location_3: check async_std_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
async_std_causality_3: check async_std_causality for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
restricted_std_coherence_3: check restricted_std_coherence for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_std_fence_sc_3: check restricted_std_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_std_atomicity_3: check restricted_std_atomicity for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_std_no_thin_air_3: check restricted_std_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_std_sc_per_location_3: check restricted_std_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
restricted_std_causality_3: check restricted_std_causality for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AsyncUnit, 0 k/AsyncUnit, 0 p/Marker, 0 k/Marker, 0 p/AliasFence, 0 k/AliasFence, 0 p/PlainProxyFence, 0 k/PlainProxyFence
rest_std_coherence_3: check rest_std_coherence for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_std_fence_sc_3: check rest_std_fence_sc for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_std_atomicity_3: check rest_std_atomicity for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_std_no_thin_air_3: check rest_std_no_thin_air for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_std_sc_per_location_3: check rest_std_sc_per_location for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait
rest_std_causality_3: check rest_std_causality for 3 but 7 p/Scope, 7 k/Scope, 4 k/Event, 0 p/Access, 0 k/Access, 0 p/AliasFence, 0 k/AliasFence, 0 p/BarrierArrive, 0 k/BarrierArrive, 0 p/BarrierWait, 0 k/BarrierWait, 0 p/ClusterArrive, 0 k/ClusterArrive, 0 p/ClusterWait, 0 k/ClusterWait

// Sanity: each group has lowered programs with a widened scope or an inserted fence whose PTX side synchronizes.

run sanity_proxies_std { proxies_std and some p/sw and (some Map.pre or some e: Map.widen | e.m.((k/Event <: scope)) != e.((p/Event <: scope)).ms) } for 4 but 7 p/Scope, 7 k/Scope, 6 k/Event
run sanity_barriers_std { barriers_std and some p/sw and (some Map.pre or some e: Map.widen | e.m.((k/Event <: scope)) != e.((p/Event <: scope)).ms) } for 4 but 7 p/Scope, 7 k/Scope, 6 k/Event
run sanity_mbarrier_std { mbarrier_std and some p/sw and (some Map.pre or some e: Map.widen | e.m.((k/Event <: scope)) != e.((p/Event <: scope)).ms) } for 4 but 7 p/Scope, 7 k/Scope, 6 k/Event
run sanity_async_std { async_std and some p/sw and (some Map.pre or some e: Map.widen | e.m.((k/Event <: scope)) != e.((p/Event <: scope)).ms) } for 4 but 7 p/Scope, 7 k/Scope, 6 k/Event
run sanity_restricted_std { restricted_std and some p/sw and (some Map.pre or some e: Map.widen | e.m.((k/Event <: scope)) != e.((p/Event <: scope)).ms) } for 4 but 7 p/Scope, 7 k/Scope, 6 k/Event
run sanity_rest_std { rest_std and some p/sw and (some Map.pre or some e: Map.widen | e.m.((k/Event <: scope)) != e.((p/Event <: scope)).ms) } for 4 but 7 p/Scope, 7 k/Scope, 6 k/Event

// a barrier.cluster.arrive.release lowered as barrier.cluster.arrive.relaxed (barriers). Message passing through
// the cluster barrier: data write, arrive, wait; arrive, wait, data read.
run broken_cluster_relaxed {
  some a: p/ClusterArrive - p/ClusterArriveRelaxed {
    g_barriers and lowering_ex[a, none] and no Map.widen and no Map.pre and no Map.relax and k/ptx_mm and not ptx_ok
    a.m in k/ClusterArriveRelaxed and a.m not in k/ProxyFence and a.m.((k/Event <: scope)) = a.((p/Event <: scope)).ms
  }
} for 6 but 7 p/Scope, 7 k/Scope, 6 k/Event

// a fence.proxy.tensormap::generic.release lowered as a plain release fence, without the proxy fence (rest). A
// generic write of a tensor map, the release and the acquire tensormap proxy fences, a tensormap-proxy read.
run broken_drop_tensormap_release {
  some f: p/TmFence & p/FenceRel {
    g_rest and lowering_ex[f, none] and no Map.widen and no Map.pre and no Map.relax and k/ptx_mm and not ptx_ok
    f.m in k/FenceRel - k/ProxyFence - k/SyncRestrictCta - k/OpRestrictInit
    f.m.((k/Event <: scope)) = f.((p/Event <: scope)).ms
  }
} for 4 but 7 p/Scope, 7 k/Scope, 4 k/Event
