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

sig Scope { subscope: set Scope }
sig CtaScope extends Scope {}
sig ClusterScope extends Scope {}
sig Thread extends Scope { start: one Event }

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

// A memory location (one granule of memory, see Access). `alias`: other virtual addresses of the same memory
// (8.2.2, 8.6). `owner`: the CTA whose shared memory holds a shared location. `init`: the initial value.
sig Address {
  alias: set Address,
  space: one Space,
  owner: lone CtaScope,
  init: one Int
}
fun aliases : Address->Address { Address <: *(alias + ~alias) }
fact address_facts {
  all a: Address | a.aliases.init = a.init
  all a: Address | a.space = Shared <=> some a.owner
}

// A scalar memory operation of the manual (8.2). Normally one event; an operation that covers several granules
// of a mixed-size test has one event per granule, all with the same Access (D6).
sig Access {}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Events (8.4 operation types). `po` is program order (immediate successor). A weak memory operation has its
// own thread as scope; a strong operation has a wider scope (2019 model).

abstract sig Event {
  po: lone Event,
  scope: one Scope
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

// Proxy fences (fence.proxy.*, 9.7.13.4). `dirs` holds the uni-directional orderings the fence establishes,
// from-proxy -> to-proxy; `pspace` limits it to some state spaces (none: all); `paddr` to some locations
// (none: all). The alias proxy fence is AliasFence.
sig ProxyFence in Event {
  dirs: Proxy -> Proxy,
  pspace: set Space,
  paddr: set Address
}
sig AliasFence extends Event {}
sig PlainProxyFence extends Event {} // a proxy fence with no other effect (fence.proxy.async and the like)

// CTA barriers (bar.sync, bar.arrive, bar.red; 9.7.13.1). bar.sync is an arrive followed by a wait (2019).
// `bid`: the barrier resource the instruction names (a value, so a register operand works); `bcount`: the
// number of threads the barrier waits for (none: every thread of the CTA that uses the barrier, D9).
// `bgen` groups the arrivals of one completion of the barrier (a generation); `synchronizes` follows from it.
abstract sig Barrier extends Event {}
sig BarrierArrive extends Barrier {
  bid: one Int,
  bcount: lone Int,
  bwait: lone BarrierWait,
  bgen: set BarrierArrive,
  synchronizes: set BarrierWait
}
sig BarrierWait extends Barrier {}

// Events that are no memory operation, fence or barrier: markers the translator places in program order
// (for example the issue of an asynchronous instruction).
sig Marker extends Event {}

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

// Two memory operations overlap completely: same virtual address, same set of granules (D6).
fun same_acc_r : Event->Event { acc.~acc + iden }
fun full_overlap_r : MemoryEvent->MemoryEvent {
  { disj e1, e2: MemoryEvent | e1.same_acc_r.address = e2.same_acc_r.address }
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

fact co_strong {
  Write <: ms_r :> Write in ^co + ^~co
}

// 8.9.2 Fence-SC order: an acyclic order relating every pair of morally strong fence.sc operations.
fact fence_sc_order {
  all disj f1, f2: FenceSC | f1->f2 in ms_r => (f1->f2 in sc or f2->f1 in sc)
  sc in ms_r
  acyclic[sc]
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.8 Release and acquire patterns.

fun RelFences : Event { FenceRel + FenceAcqRel + BarrierWait }
fun AcqFences : Event { FenceAcq + FenceAcqRel + BarrierWait }
fun AcqReads : Read { Acquire }

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
// 8.9.4 Synchronizes-with, 8.9.5 base causality order.

// release pattern X synchronizes with acquire pattern Y: a write of X precedes a read of Y in observation order,
// and the first operation of X and the last of Y are morally strong
fun sync_pattern : Event->Event { strong[rel_pattern.obs.acq_pattern] }

fun sw : Event->Event {
  sc                // fence.sc
  + synchronizes    // bar.sync, bar.red, bar.arrive
  + sync_pattern
}

fun bco : Event->Event { ^(po + sw) }

// 8.9.5 Proxy-preserved base causality order. The manual's three clauses (same address in the generic proxy;
// same address, same proxy, same thread block; aliases with an alias fence on the path), plus the proxy-fence
// clauses of the mixed-proxy model for operations of other proxies (D2).

fun GenericM : MemoryEvent { proxy.Generic }
fun cta_of : Event->CtaScope { thd.*~subscope :> CtaScope }
fun same_cta_r : Event->Event { cta_of.~cta_of }

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

fun ppbco_with[cb: Event->Event] : MemoryEvent->MemoryEvent {
  // no proxy fence or alias fence
  same_alias[GenericM <: cb :> GenericM]
  + same_alias[(MemoryEvent <: cb :> MemoryEvent) & same_cta_r & proxy.~proxy]
  // proxy fence for the source, for the destination, for both
  + same_alias[(cb & pf_src).cb :> GenericM]
  + same_alias[GenericM <: cb.(cb & pf_dst)]
  + same_alias[(cb & pf_src).cb.(cb & pf_dst)]
  // alias fence, alone or with proxy fences
  + same_location[GenericM <: cb.(AliasFence <: cb) :> GenericM]
  + same_location[(cb & pf_src).(cb :> AliasFence).cb :> GenericM]
  + same_location[GenericM <: cb.(AliasFence <: cb).(cb & pf_dst)]
  + same_location[(cb & pf_src).(cb :> AliasFence).cb.(cb & pf_dst)]
}

fun cause_base : Event->Event { bco }
fun ppbco : MemoryEvent->MemoryEvent { ppbco_with[cause_base] }

// 8.9.6 Causality order.
fun cause : MemoryEvent->MemoryEvent { ppbco + obs.ppbco }

////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// 8.10 Axioms.

// 8.10.1 Coherence: a write that precedes an overlapping write in causality order precedes it in coherence.
pred coherence { same_location[Write <: cause :> Write] in ^co }

// 8.10.2 Fence-SC: fence.sc operations related by base causality are related the same way in Fence-SC order.
// (D3: causality order relates memory operations; for fences the model uses base causality order.)
pred fence_sc { FenceSC <: cause_base :> FenceSC in sc }

// 8.10.3 Atomicity: single-copy atomicity (D6) and atomicity of read-modify-write operations.
pred atomicity {
  no strong[fr].(strong[co]) & rmw
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

// Programs whose behaviour the manual leaves undefined (any outcome is allowed). Empty in the core.
pred undefined { some none }

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
  acyclic[bgen.(^po & bid.~bid)]                        // generations of a resource follow program order
  all a: BarrierArrive | some a.bcount => #a.bgen = a.bcount
  all a: BarrierArrive | no a.bcount =>                  // every thread of the CTA that uses the resource
    a.bgen.thd = { t: Thread | some b: BarrierArrive | b.thd = t and b.bid = a.bid and b->a in same_cta_r }
  synchronizes = bgen.bwait
}
