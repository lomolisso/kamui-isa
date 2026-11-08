// The PTX ISA 8.7 memory consistency model (chapter 8 of the PTX ISA manual, version 8.7, February 2025, and the
// memory-ordering text of the instruction descriptions), in Alloy 6.
//
// Derived from two NVIDIA models (BSD 3-Clause licence, see LICENSE):
// - the PTX 6.0 model of Lustig, Sahasrabuddhe and Giroux, "A Formal Analysis of the NVIDIA PTX Memory
//   Consistency Model", ASPLOS 2019 (NVlabs/PTXMemoryModel, ptx.als): events, the scope tree, morally strong,
//   release and acquire patterns, the CTA barrier, the axioms;
// - the PTX 7.5 mixed-proxy model of Lustig, Cooksey and Giroux, ISCA 2022 (NVlabs/mixedproxy, alloy/ptx.als):
//   proxies, virtual aliases, proxy and alias fences, proxy-preserved base causality, data values.
//
// Section numbers (8.x, 9.7.x) refer to the PTX ISA 8.7 manual. D<n> refers to the numbered interpretation
// decisions in decisions.md, which say where the manual leaves room and what this model chooses.
//
// A litmus test is an Alloy module that opens this one, declares its events as `one sig` atoms, pins every
// relation of the program in a fact, and runs `ptx_mm and (outcome or undefined)` (see README.md).

module ptx87
open util

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.5 Scopes. The scope tree: the root is the system, threads are the leaves. The levels a test uses
// (gpu, cluster, cta) are nodes of the tree; CtaScope and ClusterScope mark the nodes that some rules need.
// An AsyncUnit is the thread-like node that performs the operations of one asynchronous instruction (D21).

sig Scope { subscope: set Scope }
sig CtaScope extends Scope {}
sig ClusterScope extends Scope {}
sig Thread extends Scope { start: one Event }
sig AsyncUnit extends Thread {}

fun System : Scope { Scope - Scope.subscope }
fact scope_tree {
  one System
  subscope.~subscope in iden
  no Thread.subscope
  acyclic[subscope]
  start.~start in iden
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.6 Proxies and 5.1 state spaces.

abstract sig Proxy {}
one sig Generic, Async, TensorMap, Texture, Surface, Constant extends Proxy {}

abstract sig Space {}
one sig Global, Shared, Local, Const, Param extends Space {}

// A memory location: one granule of memory (see Access). `alias`: other virtual addresses of the same memory
// (8.2.2, 8.6). `owner`: the CTA whose shared memory holds a shared location (the thread, for local memory).
// `init`: the initial value.
sig Address {
  alias: set Address,
  space: one Space,
  owner: lone Scope,
  init: one Int
}
fun aliases : Address->Address { Address <: *(alias + ~alias) }
fact address_facts {
  all a: Address | a.aliases.init = a.init
  all a: Address | a.space in Shared + Local <=> some a.owner
  Address <: owner in (space.Shared) -> CtaScope + (space.Local) -> Thread
}

// A scalar memory operation of the manual (8.2.1). Normally one event; an operation that covers several
// granules of a mixed-size test has one event per granule, all with the same Access (D6).
sig Access {}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Events (8.4 operation types). `po` is program order (immediate successor). A weak memory operation has its
// own thread as scope; a strong operation has a wider scope (2019 model).
// `issue`, `done`, `gdep`: edges of base causality order that are not program order or synchronizes-with in
// the manual's sense: an asynchronous instruction to its operations (6884), the completion of asynchronous
// operations to the instruction that waits for it, and the completion of a prerequisite grid to
// griddepcontrol.wait (9.7.13.13).

abstract sig Event {
  po: lone Event,
  scope: one Scope,
  issue: set Event,
  done: set Event,
  gdep: set Event
}
abstract sig MemoryEvent extends Event {
  address: one Address,
  proxy: one Proxy,
  val: one Int,
  acc: lone Access
}
sig Read extends MemoryEvent {
  rmw: lone Write,
  dep: set Event
}
sig Write extends MemoryEvent {
  rf: set Read,
  co: set Write
}
sig Acquire extends Read {} { scope not in Thread }
sig Release extends Write {} { scope not in Thread }

// Memory fences (fence, membar). Fences are performed via the generic proxy (D1).
abstract sig Fence extends Event {} { scope not in Thread }
sig FenceAcq extends Fence {}
sig FenceRel extends Fence {}
sig FenceAcqRel extends Fence {}
sig FenceSC extends FenceAcqRel { sc: set FenceSC }

// Restricted fences (9.7.13.4): .sync_restrict::shared::cta (release), .sync_restrict::shared::cluster
// (acquire), .op_restrict::mbarrier_init (release).
sig SyncRestrictCta in FenceRel {}
sig SyncRestrictCluster in FenceAcq {}
sig OpRestrictInit in FenceRel {}

// Proxy fences (fence.proxy.*, 9.7.13.4). `dirs` holds the uni-directional orderings the fence establishes,
// from-proxy -> to-proxy; `pspace` limits it to some state spaces (none: all); `paddr` to some locations
// (none: all). A proxy fence that also has release or acquire semantics is also a FenceRel or FenceAcq.
// The alias proxy fence is AliasFence.
sig ProxyFence in Event {
  dirs: Proxy -> Proxy,
  pspace: set Space,
  paddr: set Address
}
sig AliasFence extends Event {}
sig PlainProxyFence extends Event {} // a proxy fence with no other effect (fence.proxy.async and the like)

// CTA barriers (bar.sync, bar.arrive, bar.red, bar.warp.sync; 9.7.13.1, 9.7.13.2). bar.sync is an arrive
// followed by a wait (2019). `bid`: the barrier resource the instruction names (a value, so a register operand
// works); `bcount`: the number of threads the barrier waits for (none: every thread of the CTA that uses the
// resource, D9). `bgen` groups the arrivals of one completion of the barrier (a generation).
abstract sig Barrier extends Event {}
sig BarrierArrive extends Barrier {
  bid: one Int,
  bcount: lone Int,
  bwait: lone BarrierWait,
  bgen: set BarrierArrive,
  synchronizes: set BarrierWait
}
sig BarrierWait extends Barrier {}

// Cluster barriers (barrier.cluster.arrive{.release,.relaxed}, barrier.cluster.wait{.acquire}; 9.7.13.3).
sig ClusterArrive extends Event {
  cwait: lone ClusterWait,
  cgen: set ClusterArrive
}
sig ClusterArriveRelaxed in ClusterArrive {}
sig ClusterWait extends Event {}

// Events that are no memory operation, fence or barrier: markers the translator places in program order (the
// issue of an asynchronous instruction, a wait for asynchronous operations, griddepcontrol.wait, ...).
sig Marker extends Event {}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// mbarrier objects (9.7.13.15). An mbarrier is a location in shared memory; its value is the object's state:
// the current phase (counted from 0; its parity is the phase bit), the pending arrival count, the expected
// arrival count and the tx-count (D12). Every operation on it is a read, a write or a read-modify-write of
// that state. A negative phase marks a location that holds no valid mbarrier object.

sig Mbar in Address {
  iph, ipend, iexp, itx: one Int     // initial state (iph < 0: not initialized before the threads start)
}
sig MbarEv in MemoryEvent {
  ph, pend, expc, tx: one Int
}
sig MbarInit in Write {}             // mbarrier.init
sig MbarWait in Read {               // mbarrier.test_wait / try_wait: wait for a phase, by parity or by token
  wpar: lone Int,
  wtok: lone Int
}

fact mbarrier_state {
  MbarEv = address.Mbar
  no Mbar & (Address.alias + alias.Address)
  all r: Read & MbarEv | some r.~rf =>
      (r.ph = r.~rf.ph and r.pend = r.~rf.pend and r.expc = r.~rf.expc and r.tx = r.~rf.tx)
    else
      (r.ph = r.address.iph and r.pend = r.address.ipend and r.expc = r.address.iexp and r.tx = r.address.itx)
  MbarInit + MbarWait in MbarEv
  all w: MbarInit | w.ph = 0 and w.tx = 0 and w.pend = w.expc
}

// The state after an update that removes `darr` pending arrivals, `dexp` expected arrivals and adds `dtx` to the
// tx-count. When pending arrivals and tx-count both reach zero the phase completes: the phase advances and the
// pending count is reinitialized to the expected count (9.7.13.15.4 to .7, D13).
pred mb_next[r: Read, w: Write, darr: Int, dexp: Int, dtx: Int] {
  let p = minus[r.pend, darr], e = minus[r.expc, dexp], t = plus[r.tx, dtx] |
    (p = 0 and t = 0) => (w.ph = plus[r.ph, 1] and w.pend = e and w.expc = e and w.tx = 0)
                      else (w.ph = r.ph and w.pend = p and w.expc = e and w.tx = t)
}

// mbarrier.init (9.7.13.15.9): phase 0, pending = expected = count, tx-count 0.
pred mb_init[w: Write, count: Int] { w.ph = 0 and w.pend = count and w.expc = count and w.tx = 0 }

// mbarrier.inval (9.7.13.15.10).
pred mb_inval[w: Write] { w.ph = -1 and w.pend = 0 and w.expc = 0 and w.tx = 0 }

// waitComplete of test_wait / try_wait (9.7.13.15.16): the phase named by the parity operand (or by the state
// token returned by an earlier arrive) has completed.
pred wait_true[r: Read] {
  (some r.wpar and rem[r.ph, 2] != r.wpar) or (some r.wtok and r.ph > r.wtok)
}
fun FalseWaits : Read { { r: MbarWait | not wait_true[r] } }

// Undefined behaviour of mbarrier objects: an operation other than init on a location with no valid object
// (9.7.13.15.10), more arrivals than pending (9.7.13.15.13), a wait for a phase that is neither the current
// one nor the one just before (9.7.13.15.16); see D7 and D15.
pred mb_undefined {
  (some r: Read & MbarEv | r.ph < 0)
  or (some w: (Write & MbarEv) - MbarInit | w.pend < 0)
  or (some r: MbarWait | some r.wtok and r.ph > plus[r.wtok, 1])
}

// Bitwise operations of atom.and/.or/.xor on values below 16 (Alloy has no bitwise integer operators).
fun bitk[a: Int, k: Int] : Int { rem[div[a, k], 2] }
fun bitand[a: Int, b: Int] : Int {
  plus[plus[mul[bitk[a, 1], bitk[b, 1]], mul[mul[bitk[a, 2], bitk[b, 2]], 2]],
       plus[mul[mul[bitk[a, 4], bitk[b, 4]], 4], mul[mul[bitk[a, 8], bitk[b, 8]], 8]]]
}
fun bitor[a: Int, b: Int] : Int { minus[plus[a, b], bitand[a, b]] }
fun bitxor[a: Int, b: Int] : Int { minus[plus[a, b], mul[bitand[a, b], 2]] }

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Well-formedness of an execution.

fun thd : Event->Thread { *~po.~start }
fact threads {
  acyclic[po]
  all e: Event | one e.thd
  scope in thd.*~subscope                    // an event's scope includes its own thread (8.5)
}

fun same_alias_r : Event->Event { address.~address }           // same virtual address
fun same_location_r : Event->Event { address.aliases.~address } // same memory (virtual aliases included)
fun same_alias[r: Event->Event] : Event->Event { r & same_alias_r }
fun same_location[r: Event->Event] : Event->Event { r & same_location_r }

fun cta_of : Event->CtaScope { thd.*~subscope :> CtaScope }
fun same_cta_r : Event->Event { cta_of.~cta_of }
fun cluster_of : Event->ClusterScope { thd.*~subscope :> ClusterScope }

// po between operations on the same virtual address ("overlapping", 8.2.1)
fun po_loc : Event->Event { same_alias[^po] }

fun fr : Read->Write {
  ~rf.^co
  + ((Read - Write.rf) <: same_location_r :> Write)  // reads of the initial value
}
fun com : MemoryEvent->MemoryEvent { rf + ^co + fr }

fact communication {
  rf + co in same_location_r
  rf.~rf in iden
  all r: Read | some r.~rf => r.val = r.~rf.val else r.val = r.address.init
  acyclic[co]
  no Write & address.(space.(Const + Param))   // the constant and parameter spaces are read-only
}

fact dependencies {
  dep in ^po
  rmw in po & dep & same_alias_r & scope.~scope & proxy.~proxy
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.7 Morally strong.

fun Weak : Event { (scope :> Thread).Thread }
fun StrongW : Write { Write - Weak }
fun StrongR : Read { Read - Weak }

fun proxy_of : Event->Proxy { MemoryEvent <: proxy + (Event - MemoryEvent) -> Generic } // D1

// Each operation's scope includes the other's thread. Two operations of one thread always qualify.
fun scope_incl_r : Event->Event { symmetric[scope.*subscope.~thd] }

// The granules an operation covers; two memory operations overlap completely if they cover the same ones (D6).
fun footprint : Event->Address { (acc.~acc + iden).address }
fun full_overlap_r : MemoryEvent->MemoryEvent {
  { e1, e2: MemoryEvent | e1.footprint = e2.footprint }
}
fun overlap_ok_r : Event->Event {
  (MemoryEvent->MemoryEvent & same_alias_r & full_overlap_r) + (Event->Event - MemoryEvent->MemoryEvent)
}
fun ms_r : Event->Event {
  (scope_incl_r & proxy_of.~proxy_of & overlap_ok_r) - iden
}
fun strong[r: Event->Event] : Event->Event { r & ms_r }

// The 2019 helpers: events inside a scope, and events whose scope is (at least) that scope.
fun inside[s: Scope] : Event { s.*subscope.~thd }
fun scoped[s: Scope] : Event { s.*~subscope.~scope }

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.9.1 Coherence order: overlapping morally strong writes are ordered (and causality-ordered ones, by the
// Coherence axiom). Morally strong already means same proxy, same virtual address and complete overlap.
// Two operations that share several granules are ordered the same way on all of them (D6).

fact co_strong {
  Write <: ms_r :> Write in ^co + ^~co
  no (~acc.(^co).acc) & ~(~acc.(^co).acc)
}

// 8.9.2 Fence-SC order: an acyclic order relating every pair of morally strong fence.sc operations.
fact fence_sc_order {
  all disj f1, f2: FenceSC | f1->f2 in ms_r => (f1->f2 in sc or f2->f1 in sc)
  sc in ms_r
  acyclic[sc]
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.8 Release and acquire patterns. fence.release and fence.acquire are fences that may start a release
// pattern, or end an acquire pattern, only (D5). The wait of a CTA barrier acts as an acq_rel fence (D10).
// A test_wait or try_wait with .acquire forms an acquire pattern only when it returns True (9.7.13.15.16).

fun RelFences : Event { FenceRel + FenceAcqRel + BarrierWait }
fun AcqFences : Event { FenceAcq + FenceAcqRel + BarrierWait }
fun AcqReads : Read { Acquire - FalseWaits }

// first operation of a release pattern -> the strong write it ends with
fun rel_pattern : Event->Write {
  (Release <: optional[po_loc] :> StrongW)
  + (RelFences <: ^po :> StrongW)
}
// the strong read an acquire pattern starts with -> its last operation
fun acq_pattern : Read->Event {
  (StrongR <: optional[po_loc] :> AcqReads)
  + (StrongR <: ^po :> AcqFences)
}

// 8.9.3 Observation order: W -> R if they are morally strong and R reads W, or through atomic operations.
fun obs : Write->Read { strong[rf].*(rmw.(strong[rf])) }

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.9.4 Synchronizes-with.

// release pattern X synchronizes with acquire pattern Y: a write of X precedes a read of Y in observation order,
// and the first operation of X and the last of Y are morally strong
fun sync_pattern : Event->Event { strong[rel_pattern.obs.acq_pattern] }

// barrier.cluster.arrive synchronizes with the barrier.cluster.wait operations of its generation (8.9.4). A
// relaxed arrive gives no ordering of its own (9.7.13.3): it acts as the strong write of a release pattern that
// starts with a fence (D11).
fun cluster_sync : Event->Event {
  ((ClusterArrive - ClusterArriveRelaxed) <: cgen.cwait)
  + strong[(RelFences <: ^po :> ClusterArriveRelaxed).cgen.cwait]
}

fun sw : Event->Event {
  sc                // fence.sc
  + synchronizes    // bar.sync, bar.red, bar.arrive, bar.warp.sync
  + cluster_sync    // barrier.cluster
  + sync_pattern    // release and acquire patterns (incl. mbarrier arrive and test_wait)
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Restricted release and acquire. Some release patterns order only some earlier operations, and some acquire
// patterns only some later ones (D18, D19):
// - fence.release.sync_restrict::shared::cta: earlier operations on the executing CTA's shared memory;
// - fence.mbarrier_init.release.cluster: earlier mbarrier.init operations of the same thread;
// - the complete-tx of an asynchronous instruction (TxAnchor): only the memory operations of that instruction
//   ("does not transitively establish ordering with respect to prior instructions", 6897);
// - fence.acquire.sync_restrict::shared::cluster: later operations on shared memory of the cluster.
// These edges are not closed transitively on their restricted side.

sig TxAnchor in Write { txops: set Event }

fun RRel : Event { SyncRestrictCta + OpRestrictInit + TxAnchor }
fun RAcq : Event { SyncRestrictCluster }

// allowed earlier event -> the restricted head
fun rleft : Event->Event {
  ({ x: MemoryEvent, f: SyncRestrictCta | x.address.space = Shared and x.address.owner = f.cta_of }
     & ^po)
  + (MbarInit <: ^po :> OpRestrictInit)
  + ~(TxAnchor <: txops)
}
// the restricted tail -> allowed later event
fun rright : Event->Event {
  { f: SyncRestrictCluster, y: MemoryEvent | y.address.space = Shared and y.address.owner in f.cluster_of.*subscope }
    & ^po
}

// 8.9.5 Base causality order: program order, synchronizes-with, and their compositions; plus the asynchronous
// edges above and the restricted edges.
fun bco_plain : Event->Event { ^(po + issue + done + gdep + (sw - RRel <: sw - sw :> RAcq)) }
fun sw_restricted : Event->Event { RRel <: sw + sw :> RAcq }
fun cause_base : Event->Event {
  let left = (rleft :> RRel) + (*bco_plain :> (Event - RRel)),
      right = (RAcq <: rright) + ((Event - RAcq) <: *bco_plain) |
    bco_plain + left.sw_restricted.right
}

// 8.9.5 Proxy-preserved base causality order. The manual's three clauses (same address in the generic proxy;
// same address, same proxy, same thread block; aliases with an alias fence on the path), plus the proxy-fence
// clauses of the mixed-proxy model for operations of other proxies (D2).

fun GenericM : MemoryEvent { proxy.Generic }

// X may cross from its proxy to the generic proxy at proxy fence F (X before F), and F lets the generic proxy
// cross to Y's proxy (F before Y). Both need the non-generic operation in F's thread block (8.9.5).
fun pf_space_ok : ProxyFence->MemoryEvent {
  { f: ProxyFence, m: MemoryEvent | (no f.pspace or m.address.space in f.pspace)
                                     and (no f.paddr or m.address in f.paddr) }
}
fun pf_src : MemoryEvent->ProxyFence {
  { m: MemoryEvent, f: ProxyFence | m.proxy -> Generic in f.dirs } & same_cta_r & ~pf_space_ok
}
fun pf_dst : ProxyFence->MemoryEvent {
  { f: ProxyFence, m: MemoryEvent | Generic -> m.proxy in f.dirs } & same_cta_r & pf_space_ok
}

// The tensormap proxy fences order generic -> tensormap only as a pair: a .release fence after the generic
// operation and a .acquire fence before the tensormap operation, related by base causality (9.7.13.4: "A
// .release proxy fence can form a release sequence that synchronizes with an acquire sequence that contains a
// .acquire proxy fence"; D37). Every other proxy fence acts alone (D2).
fun TmFence : ProxyFence { { f: ProxyFence | Generic -> TensorMap in f.dirs } }
fun pf_dst_with[cb: Event->Event] : Event->MemoryEvent {
  (cb & (pf_dst - (TmFence <: pf_dst)))
  + ((TmFence & FenceRel) <: (cb.(cb & ((TmFence & FenceAcq) <: pf_dst))))
}

fun ppbco_with[cb: Event->Event] : MemoryEvent->MemoryEvent {
  // no proxy fence or alias fence
  same_alias[GenericM <: cb :> GenericM]
  + same_alias[(MemoryEvent <: cb :> MemoryEvent) & same_cta_r & proxy.~proxy]
  // a generic read before an async-proxy write: the read was performed before the write is issued (D40)
  + same_alias[(GenericM & Read) <: cb :> (proxy.Async & Write)]
  // proxy fence for the source, for the destination, for both
  + same_alias[(cb & pf_src).cb :> GenericM]
  + same_alias[GenericM <: cb.(pf_dst_with[cb])]
  + same_alias[(cb & pf_src).cb.(pf_dst_with[cb])]
  // alias fence, alone or with proxy fences
  + same_location[GenericM <: cb.(AliasFence <: cb) :> GenericM]
  + same_location[(cb & pf_src).(cb :> AliasFence).cb :> GenericM]
  + same_location[GenericM <: cb.(AliasFence <: cb).(pf_dst_with[cb])]
  + same_location[(cb & pf_src).(cb :> AliasFence).cb.(pf_dst_with[cb])]
}

fun ppbco : MemoryEvent->MemoryEvent { ppbco_with[cause_base] }

// 8.9.6 Causality order.
fun cause : MemoryEvent->MemoryEvent { ppbco + obs.ppbco }

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.10 Axioms.

// 8.10.1 Coherence: a write that precedes an overlapping write in causality order precedes it in coherence.
pred coherence { same_location[Write <: cause :> Write] in ^co }

// 8.10.2 Fence-SC: morally strong fence.sc operations related by base causality are related the same way in
// Fence-SC order. (D3: causality order relates memory operations; for fences the model uses base causality order.
// D41: only morally strong pairs, as the manual says.)
pred fence_sc { (FenceSC <: cause_base :> FenceSC) & ms_r in sc }

// 8.10.3 Atomicity. Single-copy atomicity: a read does not take some granules from a morally strong write and
// others from a write before it in coherence order (D6). RMW atomicity, also for atomic operations that overlap
// only partially (8.7.2). Coherence order is transitive (8.9.6), so the write between is taken from ^co (D42).
fun acc_lift[r: Event->Event] : Event->Event { (acc.~acc + iden).r.(acc.~acc + iden) }
fun AtomicR : Read { rmw.Write }
fun Atomics : MemoryEvent { AtomicR + AtomicR.rmw }
fun atomic_pair_r : Event->Event {
  ms_r + (Atomics <: (scope_incl_r & proxy.~proxy & same_location_r) :> Atomics)
}
pred atomicity {
  no (Read <: ms_r :> Write) & acc_lift[~rf] & acc_lift[fr]
  no (fr & atomic_pair_r).(^co & atomic_pair_r) & rmw
}

// 8.10.4 No thin air.
pred no_thin_air { acyclic[rf + dep] }

// 8.10.5 Sequential consistency per location.
pred sc_per_location { acyclic[strong[com] + po_loc] }

// 8.10.6 Causality: a read cannot read from a write it precedes in causality order, nor from a write that
// precedes in coherence order a write that precedes the read in causality order (D4).
pred causality { irreflexive[(rf + fr).cause] }

pred ptx_mm {
  coherence and fence_sc and atomicity and no_thin_air and sc_per_location and causality
}

// 8.7.2 A mixed-size data race: two operations that overlap only partially, at least one of them a write, not
// morally strong and not related in causality order.
pred mixed_size_race {
  some disj e1, e2: MemoryEvent |
    e1->e2 in same_location_r and e1.footprint.aliases != e2.footprint.aliases and some (e1 + e2) & Write
    and e1->e2 not in ms_r + cause + ~cause
}

// Undefined behaviour: any outcome is allowed (D7). A mixed-size data race is handled by the query instead
// (D38): it switches the axioms off for the whole program, but reads still return written values (8, "In the
// absence of any constraint, each read operation returns the value committed by some write operation"), so a
// racy program allows exactly the outcomes of its executions that satisfy only the facts.
pred undefined { mb_undefined }

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// CTA barriers. A barrier completes when its thread count has arrived (9.7.13.1); the arrivals of one completion
// form a generation. Every barrier operation of the test must complete: a program that waits forever has no
// final state, so no outcome (D9).

fact barriers {
  bwait in po                                            // bar.sync = arrive; wait (the wait follows directly)
  BarrierWait in BarrierArrive.bwait
  bgen = ~bgen                                           // generations: an equivalence relation
  iden & BarrierArrive->BarrierArrive in bgen
  bgen.bgen in bgen
  bgen in same_cta_r & bid.~bid                          // one barrier resource of one CTA
  no ^po & bgen                                          // a thread arrives once per generation
  acyclic[bgen.(^po & bid.~bid)]                         // generations of a resource follow program order
  all a: BarrierArrive | some a.bcount => #a.bgen = a.bcount
  all a: BarrierArrive | no a.bcount =>                  // every thread of the CTA that uses the resource
    a.bgen.thd = { t: Thread | some b: BarrierArrive | b.thd = t and b.bid = a.bid and b->a in same_cta_r }
  synchronizes = bgen.bwait
}

// Cluster barriers: every (non-exited) thread of the cluster takes part in every generation (9.7.13.3).
fact cluster_barriers {
  cwait in ^po
  cwait.~cwait in iden
  ClusterWait in ClusterArrive.cwait
  cgen = ~cgen
  iden & ClusterArrive->ClusterArrive in cgen
  cgen.cgen in cgen
  cgen in cluster_of.~cluster_of
  no ^po & cgen
  acyclic[cgen.^po]
  all a: ClusterArrive | a.cgen.thd = (a.cluster_of.*subscope & Thread) - AsyncUnit
}

// Asynchronous units and the other extra edges of base causality.
fact async_units {
  issue + done + gdep in Event->Event
  no AsyncUnit.~thd.issue                               // asynchronous operations issue nothing themselves
}
