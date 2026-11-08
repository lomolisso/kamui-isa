# Definitions of the Kamui model

One row per definition of [`kamui.als`](kamui.als): the rule of [`spec/memory-model.md`](../../spec/memory-model.md)
it encodes (section 4), the PTX ISA 8.7 section it comes from, and the decision that fixes its reading (D<n> in
`models/ptx87/decisions.md`, K<n> in [`decisions.md`](decisions.md)). A proof or a re-implementation of the model
translates this table one row at a time. `kamui.als` is the PTX 8.7 model (K1), so every row holds for
`models/ptx87/ptx87.als` as well.

| Definition | Kind | Rule (spec section 4) | PTX 8.7 | Decision |
|---|---|---|---|---|
| `Scope`, `CtaScope`, `ClusterScope`, `Thread`, `System`, `scope_tree` | sigs, fun, fact | 4.1 scope tree | 8.5 | |
| `AsyncUnit`, `async_units` | sig, fact | 4.10 asynchronous operations | 8.2 (6884) | D21 |
| `Proxy` and its six atoms | sigs | 4.2 proxies | 8.6 | D1, D8 |
| `Space` and its five atoms | sigs | 4.2 state spaces | 5.1 | D17 |
| `Address`, `aliases`, `address_facts` | sig, fun, fact | 4.2 locations, virtual aliases, owners | 8.2.2, 8.6 | D8 |
| `Access` | sig | 4.2 granules of one operation | 8.2.1 | D6 |
| `Event` (`po`, `scope`, `issue`, `done`, `gdep`) | sig | 4.3 events | 8.4 | D20, D32 |
| `MemoryEvent`, `Read`, `Write`, `Acquire`, `Release` | sigs | 4.3 memory operations | 8.4 | |
| `Fence`, `FenceAcq`, `FenceRel`, `FenceAcqRel`, `FenceSC` | sigs | 4.3 fences | 8.4, 9.7.13.4 | D5 |
| `SyncRestrictCta`, `SyncRestrictCluster`, `OpRestrictInit` | sigs | 4.9 restricted fences | 9.7.13.4 | D18 |
| `ProxyFence`, `AliasFence`, `PlainProxyFence` | sigs | 4.11 proxy fences | 9.7.13.4 | D2 |
| `Barrier`, `BarrierArrive`, `BarrierWait`, `barriers` | sigs, fact | 4.8 CTA barriers | 9.7.13.1, 9.7.13.2 | D9, D10, D30 |
| `ClusterArrive`, `ClusterArriveRelaxed`, `ClusterWait`, `cluster_barriers` | sigs, fact | 4.8 cluster barriers | 9.7.13.3 | D11, K6 |
| `Marker` | sig | 4.10 points in program order with no memory effect | | D20 |
| `Mbar`, `MbarEv`, `MbarInit`, `MbarWait`, `mbarrier_state` | sigs, fact | 4.15 mbarrier state | 9.7.13.15.1 | D12 |
| `mb_next`, `mb_init`, `mb_inval` | preds | 4.15 phase completion, init, inval | 9.7.13.15.4 to .10 | D13, D14 |
| `wait_true`, `FalseWaits` | pred, fun | 4.15 test_wait and try_wait | 9.7.13.15.16 | D15 |
| `mb_undefined` | pred | 4.14 undefined behaviour of mbarrier objects | 9.7.13.15 | D7, D15 |
| `bitk`, `bitand`, `bitor`, `bitxor` | funs | 4.3 values of bitwise atomics | 9.7.13.5 | D35 |
| `thd`, `threads` | fun, fact | 4.4 program order, an event's thread | 8.2 | |
| `same_alias_r`, `same_location_r`, `same_alias`, `same_location` | funs | 4.2 same address, same memory | 8.2.1, 8.6 | D8 |
| `cta_of`, `same_cta_r`, `cluster_of` | funs | 4.1 the CTA and cluster of an event | 8.5 | |
| `po_loc` | fun | 4.4 program order on one address | 8.2.1 | |
| `fr`, `com`, `communication` | funs, fact | 4.4 reads-from, coherence, from-read | 8.9 | |
| `dependencies` | fact | 4.4 dependencies and read-modify-write pairs | 8.10.4 | K4 |
| `Weak`, `StrongW`, `StrongR` | funs | 4.5 weak and strong operations | 8.4 | |
| `proxy_of` | fun | 4.5 fences use the generic proxy | 8.6 | D1 |
| `scope_incl_r` | fun | 4.5 scope inclusion | 8.7 | |
| `footprint`, `full_overlap_r`, `overlap_ok_r` | funs | 4.5 complete overlap | 8.7, 8.2.1 | D6 |
| `ms_r`, `strong` | funs | 4.5 morally strong | 8.7 | |
| `inside`, `scoped` | funs | 4.1 helpers of the 2019 model | | |
| `co_strong` | fact | 4.6 coherence order | 8.9.1 | D6 |
| `fence_sc_order` | fact | 4.6 Fence-SC order | 8.9.2 | |
| `RelFences`, `AcqFences`, `AcqReads` | funs | 4.7 fences and reads that start or end a pattern | 8.8 | D5, D10, D15 |
| `rel_pattern`, `acq_pattern` | funs | 4.7 release and acquire patterns | 8.8 | |
| `obs` | fun | 4.7 observation order | 8.9.3 | |
| `sync_pattern`, `cluster_sync`, `sw` | funs | 4.8 synchronizes-with | 8.9.4 | D11 |
| `TxAnchor`, `RRel`, `RAcq`, `rleft`, `rright` | sig, funs | 4.9 restricted release and acquire | 9.7.13.4, 6897 | D18, D19 |
| `bco_plain`, `sw_restricted`, `cause_base` | funs | 4.10 base causality order | 8.9.5 | D19, D20, D21 |
| `GenericM`, `pf_space_ok`, `pf_src`, `pf_dst` | funs | 4.11 proxy fences | 8.9.5 | D2 |
| `TmFence`, `pf_dst_with` | funs | 4.11 tensormap proxy fences act as a pair | 9.7.13.4 | D37 |
| `ppbco_with`, `ppbco` | funs | 4.11 proxy-preserved base causality order | 8.9.5 | D2, D40 |
| `cause` | fun | 4.12 causality order | 8.9.6 | |
| `coherence` | pred | 4.13 axiom: coherence | 8.10.1 | |
| `fence_sc` | pred | 4.13 axiom: Fence-SC | 8.10.2 | D3 |
| `acc_lift`, `AtomicR`, `Atomics`, `atomic_pair_r`, `atomicity` | funs, pred | 4.13 axiom: atomicity | 8.10.3 | D6, D25, D42, K4 |
| `no_thin_air` | pred | 4.13 axiom: no thin air | 8.10.4 | |
| `sc_per_location` | pred | 4.13 axiom: SC per location | 8.10.5 | |
| `causality` | pred | 4.13 axiom: causality | 8.10.6 | D4 |
| `ptx_mm` | pred | 4.13 the model: all axioms | 8.10 | K1 |
| `mixed_size_race` | pred | 4.14 mixed-size data race | 8.7.2 | D38 |
| `undefined` | pred | 4.14 undefined behaviour | 8.7.2, 9.7.13.15 | D7 |
