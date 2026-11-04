# Interpretation decisions of the PTX 8.7 model

The PTX ISA 8.7 manual defines the memory model in English (chapter 8) and adds ordering rules in the
instruction descriptions (chapter 9). Where the text leaves room, the model in `ptx87.als` makes a choice. This
file lists every such choice, numbered `D1` to `D40`: the text it interprets (section and line of the plain-text
manual, PTX ISA 8.7, February 2025), the alternatives, the choice, and the litmus tests whose verdict depends on
it (under `tests/litmus/ptx/`; most are in `kamui/ptx87/`).

The list is written so that the model can be implemented again from it, without reading `ptx87.als`: a second
implementation that makes the same choices must give the same verdicts. A second model was written independently
from the manual in Dartagnan (`deps/dat3m`, `cat/ptx-v8.7.cat`, with its own interpretation log `cat/ptx-v8.7.md`,
entries `M1` to `M51` at first); the two disagreed on ten tests at first and on five more after the feature tests
were added. The readings settled then are D37 to D40 and the notes "Cross-check" below. Terms: *po* program order, *rf*
reads-from, *co* coherence order, *fr* from-reads, *bco* base causality order, *ms* morally strong.

## Base relations and axioms

### D1. Fences are performed via the generic proxy

> "Two operations are said to be morally strong relative to each other if [...] Both operations are performed
> via the same proxy. If both are memory operations, then they overlap completely." (8.7, 6785-6794)

The proxy condition is not limited to memory operations, but the manual never says which proxy a fence uses.

- A: fences have no proxy, so a fence is never morally strong with anything (NVIDIA's mixed-proxy Alloy model).
  Then the patterns `fence; st.relaxed` and `ld.relaxed; fence` of 8.8 can never synchronize.
- B: fences, barriers and every other non-memory operation are performed via the generic proxy (Dat3M's
  `ptx-v7.5.cat`).

Choice: **B**. The address condition applies only when both are memory operations.
Tests: `imported/mixedproxy/Release_acquire_pattern` (forbidden; the mixed-proxy model says allowed),
`kamui/families/MP/MP+fence-*`.

### D2. Proxy fences in proxy-preserved base causality order

> "X and Y are performed to the same address, using the generic proxy, or X and Y are performed to the same
> address, using the same proxy, and by the same thread block, or X and Y are aliases and there is an alias
> proxy fence along the base causality path from X to Y." (8.9.5, 6996-7005)
>
> "A uni-directional proxy ordering from the from-proxykind to the to-proxykind establishes ordering between a
> prior memory access performed via the from-proxykind and a subsequent memory access performed via the
> to-proxykind." (9.7.13.4, 22645) "The memory ordering is limited only to operations performed on objects in
> the state space specified." (22660)

Chapter 8 has a clause for the alias fence only; the async and tensormap proxy fences have no formal home.

- A: only the three clauses of 8.9.5; proxy fences other than alias order nothing.
- B: the clauses of the mixed-proxy model (Lustig et al., ISCA 2022): an operation X of proxy p before a proxy
  fence F that orders p -> generic, then generic operations; or generic operations, then F ordering generic -> q,
  then Y of proxy q; or both; each combined with an alias fence. The non-generic operation must be in F's thread
  block (CTA), and in F's state space or address range when F names one.

Choice: **B**, with each fence's set of uni-directional orderings: `fence.proxy.async{.space}` orders
generic <-> async; `fence.proxy.{texture,surface,constant}` (PTX 7.5 tests) generic <-> that proxy;
`fence.proxy.tensormap::generic.{release,acquire}` and `fence.proxy.async::generic.*` order generic -> the named
proxy only. Tests: `kamui/hand/CoWR+fence.proxy.async+async-bulk+same-cta`,
`kamui/ptx87/async-bulk/TMA-load+fence.proxy.async.*`, `kamui/ptx87/tensormap/*`, the mixed-proxy and Dat3M
proxy tests.

The tensormap proxy fences are the exception: they act only as a release/acquire pair (D37).

### D3. The Fence-SC axiom uses base causality order

> "Fence-SC order cannot contradict causality order. For a pair of morally strong fence.sc operations F1 and
> F2, if F1 precedes F2 in causality order, then F1 must precede F2 in Fence-SC order." (8.10.2, 7058-7060)

Causality order is defined on memory operations (8.9.5 and 8.9.6 relate "a memory operation X" to "a memory
operation Y"), so read literally it never relates two fences.

- A: literal: the axiom is empty (the mixed-proxy model's version is, because its fences have no proxy).
- B: for fences, use base causality order (which relates any operations).

Choice: **B**. The Fence-SC order itself: an acyclic order relating every pair of morally strong `fence.sc`
operations (8.9.2, 6916), which is equivalent to "a total order per scope" (22617) for the trees the model
builds. Tests: `kamui/families/SB/SB+fence-sc.*`, `kamui/families/IRIW/IRIW+fence-sc.*`.

### D4. The Causality axiom

> "If a read R precedes an overlapping write W in causality order, then R cannot read from W. If a write W
> precedes an overlapping read R in causality order, then for any byte accessed by both R and W, R cannot read
> from any write W' that precedes W in coherence order." (8.10.6, 7223-7226)

- A: `irreflexive((rf + fr)?; cause)` (the 2019 Alloy model; also requires causality to be acyclic).
- B: `irreflexive((rf + fr); cause)` (the text; Dat3M).

Choice: **B**. "Overlapping" covers virtual aliases of the same memory (the manual's own alias litmus test,
7270). No test in the suite separates A from B.

### D5. fence.acquire and fence.release

> Table 20: "memory fence operation | A membar, fence.sc or fence.acq_rel instruction." (8.4, 6603-6678)
> "Or a memory fence followed by a strong write on M in program order" (release pattern, 8.8, 6830-6845)

Table 20 predates PTX 8.6 and does not list `fence.acquire`/`fence.release`.

Choice: `fence.release` may start a release pattern and `fence.acquire` may end an acquire pattern; neither
does the other job. `fence.sc` and `fence.acq_rel` do both; `.acq_rel` is the default (22613); `membar` is
`fence.sc` (22638). Tests: `kamui/families/*/*+fence-rel-acq.*`.

### D6. Granules, complete overlap and single-copy atomicity

> "Memory operations with a vector data type are modelled as a set of equivalent memory operations with a
> scalar data type, executed in an unspecified order on the elements in the vector." (8.2.1, 6569)
> "R reads any byte from W. R reads any byte from any write W' which precedes W in coherence order." (8.10.3,
> single-copy atomicity, 7062-7071)

The axioms speak of bytes. The model divides each location into the coarsest granules the test's accesses
need (one per location in an ordinary test). A scalar operation that covers several granules is one event per
granule, grouped as one *access*.

- reads-from and from-reads are per granule;
- two memory operations *overlap completely* when they cover the same granules at the same virtual address;
- single-copy atomicity: a read R and a morally strong write W: R does not take some granule from W and another
  granule from a write before W in coherence order (or from the initial value);
- two accesses that share several granules are ordered the same way by coherence order on all of them;
- `atom.b128` is one 16-byte scalar operation (one granule), although 6570 caps scalars at 64 bits.

Tests: `kamui/ptx87/sizes/*`, `kamui/ptx87/rmw/cas.b128`.

### D7. Undefined behaviour allows every outcome

> "The axioms in the memory consistency model do not apply if a PTX program contains one or more mixed-size
> data-races." (8.7.2, 6811) "Performing any mbarrier operation except mbarrier.init on a memory location that
> does not contain a valid mbarrier object, results in undefined behaviour." (9.7.13.15.10)

Choice: if any execution of the program that satisfies the axioms has undefined behaviour, every outcome of the
test is allowed. Undefined behaviour in the model: an mbarrier operation other than `init` that reads a location
without a valid object (before `init` or after `inval`); more arrivals than pending; a wait whose state token is
older than the previous phase (D15). A mixed-size data race is not undefined behaviour in this sense: see D38.

Cross-check: the Dartagnan model only flagged mbarrier misuse and kept the axioms (M35), which forbade
`mbarrier-init+inval+use` and `mbarrier-init+no-fence+cluster-barrier`. Decided for this reading: the manual says
"results in undefined behavior" with no limit on the result, and looking for misuse only in executions that
satisfy the axioms avoids a stale read justifying itself (the concern of M35). The
exception of 6817 (overlapping atomic operations whose scopes include each other stay atomic) is in the
atomicity axiom. Tests: `kamui/ptx87/sizes/mixed-size+race`, `mixed-size+flag`,
`kamui/ptx87/mbarrier-init/*`.

### D8. Proxy references and virtual aliases in litmus tests

> "Although virtual aliases use the generic method of memory access, since using distinct virtual addresses
> behaves as if using different proxies, they require a proxy fence to establish memory ordering." (8.6, 6779)

The PTX 7.5 tests (from Dat3M and NVIDIA's mixed-proxy suite) declare `y @ generic aliases x` and
`s @ surface aliases x`.

Choice (as Dat3M's parser): `@ generic aliases` declares another virtual address of the same memory (a virtual
alias); `@ texture|surface|constant aliases` declares a reference that accesses the *same* virtual address
through that proxy. Tests: `imported/mixedproxy/*`, `imported/dat3m/Nvidia/proxy/*`.

## Barriers

### D9. CTA barriers: generations, thread counts, completion

> "barrier{.cta}.sync [...] b specifies the number of threads participating in the barrier [...] the barrier is
> reinitialized so that it can be immediately reused." (9.7.13.1) "A bar{.cta}.sync or bar{.cta}.red or
> bar{.cta}.arrive operation synchronizes with a bar{.cta}.sync or bar{.cta}.red operation executed on the same
> barrier." (8.9.4, 6928)

Choice:
- The arrivals at one barrier resource of one CTA form generations; a thread arrives at most once per
  generation, generations follow every thread's program order, and with a thread count `b` a generation has
  exactly `b` arrivals. Without a count, a generation has every thread of the CTA (in the test) that uses that
  barrier resource. Which threads form which generation is chosen by the model when counts allow several ways.
- An arrival synchronizes with the waits of its generation.
- A test's outcome is a final state, so it needs every thread to finish: an execution in which a barrier never
  completes has no outcome (Dat3M also counts executions in which a thread stays blocked; there the loads after
  the barrier keep their initial register values).
- Dat3M's litmus form `bar.cta.sync i, a, b` (instance `i`, barrier `a`, count `b`) and the PTX forms
  `bar.sync a{, b}`, `bar.arrive a, b`, `barrier.sync` are both read.

Tests: `imported/dat3m/Barrier/*` (the four `quorum*-pass` tests differ from Dat3M because of the third point;
see the allow-list), `kamui/ptx87/bar/*`.

### D10. The wait of a CTA barrier is also a fence

> "guarantees that when the barrier completes, prior memory accesses requested by this thread are performed
> relative to all threads participating in the barrier. [...] no new memory access is requested by this thread
> before the barrier completes." (9.7.13.1, 22300-22304)

Choice (the 2019 model): the wait half of `bar.sync`/`bar.red` acts as an `acq_rel` fence in release and
acquire patterns, in addition to synchronizing with its generation. Tests: `imported/dat3m/Manual/*bar*`.

Cross-check: the Dartagnan model treated the barrier as synchronization only (8.9.4, and 6653-6655 list
`membar`, `fence.sc` and `fence.acq_rel` as the memory fences), so a relaxed store after the barrier did not
carry the other threads' writes to a third thread. Decided for this reading, which is also that of NVIDIA's 2019
model (`deps/ptx-memory-model/ptx.als`, `BarrierWait` in both fence sets). The fence is at the wait, after the
thread's own arrival, so an acquire pattern that ends at the wait does not reach the threads its arrival
synchronizes with. Tests: `kamui/features/bar/WRC+{bar,barrier}.sync+*` (relaxed-acquire and release-acquire
forbidden, relaxed-relaxed and reader-side allowed).

### D11. barrier.cluster

> "The optional .relaxed qualifier on barrier.cluster.arrive specifies that there are no memory ordering and
> visibility guarantees provided for the memory accesses performed prior to barrier.cluster.arrive."
> (22514-22516) "A barrier.cluster.arrive operation synchronizes with a barrier.cluster.wait operation." (8.9.4,
> 6930) Example: `fence.cluster.acq_rel; barrier.cluster.arrive.relaxed` (22548).

Choice: every non-exited thread of the cluster takes part in every generation; `.release` (the default) arrive
synchronizes with the waits of its generation; a `.relaxed` arrive synchronizes nothing by itself but acts as the
strong write of a release pattern that starts with a fence (so the manual's example works, with the usual
morally-strong condition between the fence and the waiting thread). The wait is acquire (its only form) and does
not cover asynchronous operations (22506). Tests: `kamui/hand/MP+barrier.cluster*`,
`kamui/ptx87/barrier-cluster/*`.

## mbarrier

### D12. An mbarrier is a location whose value is its state

> The object holds "current phase", "Count of pending arrivals", "Count of expected arrivals for the next phase",
> "tx-count" (9.7.13.15.1, 23959-23966). "mbarrier.arrive.release [M]" is a release pattern and
> "mbarrier.test_wait.acquire [M]" an acquire pattern (8.8).

The manual never says which write a wait observes. Choice: the state is the value of the mbarrier location.
`init` and `inval` are writes; `arrive`, `arrive_drop`, `arrive.expect_tx`, `expect_tx`, `complete_tx` and the
implicit complete-tx of asynchronous instructions are read-modify-writes that compute the next state;
`test_wait` and `try_wait` are reads. All of them are performed via the generic proxy, the implicit complete-tx
included (although the manual's example 22744 hints that asynchronous operations reach mbarriers through the
async proxy, that reading would make the documented TMA-plus-mbarrier pattern need a proxy fence that the
manual never asks for). Release and acquire then follow from the usual rules: the arrivals of a phase are a chain
of read-modify-writes, so a wait that reads the state after the phase completed observes every arrival of the
phase (8.9.3). Tests: `kamui/hand/MP+mbarrier-*`, `kamui/ptx87/mbarrier/*`.

### D13. Phase completion

> "the current phase is complete when [...] pending arrivals has reached zero [and] the tx-count has reached
> zero [...] the following actions are performed atomically: transitions to the next phase [...] pending
> arrival count is reinitialized to the expected arrival count." (9.7.13.15.4 to .7, 24072-24085)

Choice: every update checks both counts; the update that leaves both at zero completes the phase (it advances
the phase and sets pending = expected; for `arrive_drop`, the lowered expected count). The tx-count may go
negative before the matching expect_tx. Tests: `kamui/ptx87/mbarrier/mbarrier-expect-*`, `mbarrier-arrive-drop`.

### D14. mbarrier.init

> "the synchronizing effect of the fence only applies to the prior mbarrier.init operations" (`.op_restrict`,
> 22622)

Choice: `mbarrier.init` has no `.sem`, so it is a weak write: another thread may use the object only after a
release pattern orders the init before its operation (for example `fence.mbarrier_init.release.cluster` and a
cluster barrier). Before that, the other thread's operation may read the location without a valid object
(undefined, D7). Tests: `kamui/ptx87/mbarrier-init/*`.

### D15. test_wait and try_wait

> "When mbarrier.test_wait and mbarrier.try_wait operations with .acquire qualifier returns True, they form the
> acquire pattern" (24784). Valid "only for: the current incomplete phase [...] the immediately preceding phase"
> (24764).

Choice: the wait returns True when the phase it names has completed: for `.parity p`, when the parity of the
current phase differs from `p`; for a state token, when the current phase is later than the token's (the token is
the phase an earlier arrive read). With `.acquire` (the default) it is an acquire pattern only when it returns
True. `try_wait` returns the same result as `test_wait` at the moment it reads (a time-out is a False result). A
wait on a token older than the preceding phase is undefined (D7). Tests: `kamui/ptx87/mbarrier/mbarrier-wait-false*`,
`MP+mbarrier-token`, `mbarrier-parity-1`.

### D16. Remote arrivals and the scope of a wait

> "All memory accesses [...] requested prior, in program order, to mbarrier.arrive having release semantics
> during the completed phase by the participating threads of the CTA are performed and are visible to the
> executing thread." (24797)

Arrivals from another CTA (`.shared::cluster`) are not "threads of the CTA". Choice: no special rule; the usual
morally-strong condition decides: a remote arrive synchronizes with a wait if each one's scope includes the other
thread, so both need `.cluster`. Tests: `kamui/ptx87/mbarrier/MP+mbarrier-remote-*`.

## Restricted fences

### D17. shared::cta and shared::cluster are windows onto one location

> "The addresses in the .shared::cta window also fall within the .shared::cluster window." (5.1.7, 3151-3155)

Choice: a variable in a CTA's shared memory is one location, whichever window (or generic address) an
instruction uses to reach it; the windows are not virtual aliases (no alias fence is needed). Tests:
`kamui/ptx87/spaces/*`.

### D18. .sync_restrict and .op_restrict

> "When .sync_restrict is .sync_restrict::shared::cta, .sem must be .release, and the effect of the fence only
> applies to operations performed on objects in .shared::cta state space. Likewise, when .sync_restrict is
> .sync_restrict::shared::cluster, .sem must be .acquire, and the effect of the fence only applies to operations
> performed on objects in .shared::cluster state space." (22626-22630)

The text does not say which side is restricted, nor whether the pattern's own write or read is.

Choice: the restriction applies to the operations the fence orders: for the release form, the earlier operations
(only those on the executing CTA's shared memory); for the acquire form, the later operations (only those on
shared memory of a CTA in the cluster, the executing CTA's own included). The strong write or read that completes
the pattern is not restricted (the manual's examples, 22749-22755, pair them with a remote mbarrier arrive and
an mbarrier try_wait). `fence.mbarrier_init.release.cluster` orders only the thread's earlier `mbarrier.init`
operations. Tests: `kamui/ptx87/restrict/*`, `kamui/ptx87/mbarrier/MP+*fence-restrict*`,
`kamui/ptx87/barrier-cluster/*fence-restrict*`, `kamui/ptx87/mbarrier-init/*`.

### D19. Restricted ordering is not transitive on the restricted side

> "The implicit mbarrier complete-tx operation [...] is ordered only with respect to the memory operations
> performed by the same asynchronous instruction, and in particular it does not transitively establish ordering
> with respect to prior instructions from the issuing thread." (6897-6901)

Base causality order is transitive (8.9.5), so "only these operations" cannot hold if the edges join it.

Choice: a restricted release (D18's release forms, the complete-tx of an asynchronous instruction,
`cp.async.mbarrier.arrive`) contributes edges from its allowed operations only, and they are not extended
backwards through program order; a restricted acquire contributes edges to its allowed operations only, not
extended forwards. On the unrestricted side the edges continue as usual. Tests:
`kamui/ptx87/restrict/MP+fence-restrict-cta+not-transitive`, `kamui/ptx87/async-bulk/TMA-load+complete-tx-not-transitive`,
`kamui/ptx87/st-async/MP+st.async+not-transitive`, `kamui/ptx87/cp-async/MP+cp.async.mbarrier.arrive+not-transitive`.

## Asynchronous operations

### D20. Completion by a wait instruction

> "The completion of a cp{.reduce}.async.bulk operation is followed by an implicit generic-async proxy fence. So
> the result of the asynchronous operation is made visible to the generic proxy as soon as its completion is
> observed." (18763) "Writes being made visible to the executing thread" (`cp.async.bulk.wait_group`, 20212)

Choice: the completion of an asynchronous operation precedes, in base causality order, the instruction that waits
for it (`cp.async.bulk.wait_group N`, `cp.async.wait_group`/`wait_all`, `wgmma.wait_group`), and an implicit
generic <-> async proxy fence sits between the operation's writes and its completion. The edge is part of base
causality order, so the result reaches other threads through the waiting thread's later synchronization.
`wait_group.read` waits only for the reads, which are followed by their own implicit proxy fence (so the source
may then be overwritten). Bulk async-groups complete in order; `wait_group N` waits for all but the newest `N`
committed groups. Tests: `kamui/ptx87/async-bulk/TMA-store+*`, `kamui/ptx87/cp-async/*`.

### D21. Who performs asynchronous operations

> "These asynchronous operations are ordered after prior instructions in the same thread (except in the case of
> wgmma.mma_async), but they are not part of the program order for that thread." (6884-6887) "The copy operation
> in cp.async.bulk is treated as a weak memory operation and the complete-tx operation on the mbarrier has
> .release semantics at the .cluster scope" (19150)

Choice: the operations of an asynchronous instruction are performed by an *asynchronous unit*, a thread-like node
of the scope tree with its own program order (the copy's reads, then its writes, then the implicit proxy fence,
then the complete-tx). The reads (and a tensor copy's tensor-map read) belong to a unit in the issuing CTA. The
writes to a CTA's shared memory and the complete-tx on that CTA's mbarrier belong to a unit in that CTA (one per
destination for multicast); writes to global memory stay in the issuing CTA. This makes the documented use (a
copy issued by another CTA of the cluster, waited for at the default `.cta` scope) synchronize. The copy's memory
operations are weak (their scope is their unit). The instruction precedes its first operation in base causality
order. Tests: `kamui/ptx87/async-bulk/TMA-multicast`, `kamui/ptx87/st-async/*`.

Cross-check: the Dartagnan model attributed every operation of a copy to the issuing thread, so a multicast write
into another CTA's shared memory and a wgmma read there were not "by the same thread block" (8.9.5, 7001) and a
write-after-read between them was unordered. Decided for this reading (19133-19135: the data is multicast "in the
shared memory of each destination CTA", like the mbarrier signal). Test:
`kamui/idioms/tma-multicast-war+remote-arrive.cluster` (forbidden).

### D22. cp.async (non-bulk)

> "cp.async is treated as a weak memory operation in the Memory Consistency Model." (18831) "The asynchronous
> mbarrier arrive-on operation performed by a cp.async.mbarrier.arrive instruction is ordered with respect to the
> memory operations performed by all prior cp.async operations initiated by the same thread" (6893)

Choice: a weak read and a weak write in the generic proxy (the manual assigns the async proxy only to the bulk
copies, wgmma and tcgen05), in an asynchronous unit of the issuing CTA. `cp.async.mbarrier.arrive` is an
asynchronous arrive (a restricted release, D19, covering the thread's earlier cp.async operations); without
`.noinc` the pending count is first incremented by one (9.7.13.15.15). Tests: `kamui/ptx87/cp-async/*`.

### D23. st.async and red.async

> "The store operation is treated as a weak memory operation. The complete-tx operation on the mbarrier has
> .release semantics at .cluster scope." (17241-17244) ".release: [...] a strong memory operation with .release
> semantics at the scope specified by .scope [...] defaults to .sys" (17275-17282)

No proxy is named. Choice: the generic proxy. The weak forms write a CTA's shared memory and complete-tx its
mbarrier (an asynchronous unit in that CTA, D21); the `.release` forms are release operations on global memory
at the given scope (`.sys` by default; the syntax line 23349 lists `.gpu, .cluster` for red.async, the description
23438 `.gpu, .sys`: the model reads both). Tests: `kamui/ptx87/st-async/*`.

### D24. wgmma.mma_async

> "(except in the case of wgmma.mma_async)" (6886) "An async proxy fence must be used to establish an ordering
> between prior writes to shared memory matrices and subsequent reads of the same matrices in a wgmma.mma_async
> instruction." (33443) wgmma.fence "establishes an ordering between prior accesses to any warpgroup registers
> and subsequent accesses to the same registers" (33424)

Choice: the shared-memory operand reads are weak reads of the async proxy in an asynchronous unit; they are
ordered after earlier instructions only through the latest `wgmma.fence` before the instruction (not at all
without one); completion by `wgmma.wait_group` (D20). Register accumulators are not modelled (registers are not
memory). The litmus form `wgmma.mma_async r, a, b` puts the value read from `a` into `r`. Tests:
`kamui/ptx87/wgmma/*`.

Cross-check: the Dartagnan model ordered the wgmma only after memory fences (M48), so a wgmma after an mbarrier wait
and `wgmma.fence` could read stale data. Decided for this reading: the proxy-fence sentence concerns generic writes
crossing into the async proxy, and the exclusion of 6886 leaves `wgmma.fence` as the point where the warpgroup orders
its earlier instructions before a wgmma, which is where CUTLASS's sm90 main loop synchronizes
(`kamui/idioms/tma-pipeline-raw+wgmma`).

### D25. No atomicity across proxies

> "Each reduction operation performed by the cp.reduce.async.bulk has individually .relaxed.gpu memory ordering
> semantics." (19394) "The cp{.reduce}.async.bulk operations are performed in the asynchronous proxy" (18756)

Choice: the reductions are atomic read-modify-writes of the async proxy at gpu scope; with a generic atomic on
the same location they are not morally strong (different proxies), so atomicity is not guaranteed between them.
Tests: `kamui/ptx87/async-bulk/cp.reduce.async.bulk+generic-atomic`, `2+cp.reduce.async.bulk`.

### D26. Transaction counts in litmus tests

`complete_tx::bytes` counts bytes. Choice (a litmus convention): a copy completes one transaction unit per
copied granule; tests set `expect_tx` in the same units.

## Other operations

### D27. Operations with no effect on the model

> "Cache operators on load or store instructions are treated as performance hints only." (15572) "Cache
> eviction priority [...] is treated as a performance hint." (15696)

Choice: cache operators, eviction priorities, cache hints, `.level::prefetch_size`, `prefetch`, `prefetchu`,
`prefetch.tensormap`, `cp.async.bulk.prefetch{.tensor}`, `applypriority`, `createpolicy`,
`griddepcontrol.launch_dependents`, and the address computations `cvta`, `mapa`, `isspacep`, `getctarank` create
no event. Register-only instructions (`mov`, `cvt`, `prmt`, `shfl.sync`, `vote.sync`, `match.sync`, `redux.sync`,
`activemask`, `elect.sync`) touch no memory. A cache policy "is treated as a performance hint only, and does not
change the memory consistency behavior of the program" (16674). Tests: `kamui/ptx87/ld-st/MP+cache-operators`,
`kamui/ptx87/hints/*` (H100 results in `evidence/litmus-h100/README.md`).

### D28. .volatile and .mmio

> "The semantics of volatile operations are equivalent to a relaxed memory operation with system-scope"
> (8.4.2, 6704) "it is equivalent to the semantics of a strong operation" (.mmio, 6686) "Only .sys thread scope
> is valid for ld.mmio operation. The qualifiers .mmio and .relaxed must be specified together." (16634)

Choice: both are relaxed operations at system scope; the extra guarantees (no merging, exactly-once) are not
visible in a litmus outcome. Tests: `kamui/hand/*volatile*`, `kamui/ptx87/ld-st/*mmio`.

### D29. ld.global.nc and ldu

> "The memory consistency model does not apply to texture (including ld.global.nc) and surface accesses."
> (6521)

Choice: reads through a separate, non-generic proxy (the texture proxy of the PTX 7.5 model). PTX 8.7 has no
proxy fence for it, so such a read is never guaranteed to see data written during the kernel; it always may
return the initial value. `ldu` (read-only data, 9.7.9.10) is treated the same way. Tests:
`kamui/ptx87/ld-st/MP+ld.global.nc`, `CoWR+ld.global.nc`, `MP+ldu`.

Cross-check: the Dartagnan model read `ldu` as an ordinary weak load (M11: 6521 does not name it), which forbade
`MP+ldu`. Decided for this reading: the manual says only "Load read-only data" (16927), nothing promises that
`ldu` sees data written during the kernel, and the weaker reading promises nothing the text does not.

### D30. bar.warp.sync in litmus tests

> "bar.warp.sync also guarantee memory ordering among threads participating in barrier." (22448)

Choice: a barrier among the threads of its member mask, like a CTA barrier with that many threads. In a litmus
test bit `k` of the mask stands for thread `Pk` (the threads must share a CTA). Tests:
`kamui/ptx87/bar/MP+bar.warp.sync*`.

### D31. multimem and vectors

> "Optional qualifiers .ldsem, .stsem and .redsem specify the memory synchronizing effect [...] multimem.ld_reduce
> and multimem.st default to .weak and multimem.red defaults to .relaxed [...] .sys scope is assumed by default."
> (17504-17512)

Choice: one memory operation per location of the multicast object, with the instruction's semantics and scope,
in a free order (as the elements of a vector, 6569); `ld_reduce` combines the values read. Atomicity is per
location. Vector loads, stores and atomics: one scalar operation per element, in a free order. Tests:
`kamui/ptx87/multimem/*`, `kamui/ptx87/sizes/MP+vector-*`.

### D32. griddepcontrol.wait

> ".wait modifier causes the executing thread to wait until all prerequisite grids in flight have completed and
> all the memory operations from the prerequisite grids are performed and made visible to the current grid."
> (23827)

Choice: in a litmus test, threads name their grid; grid `N` depends on grid `N-1`. Every operation of the
prerequisite grid precedes `griddepcontrol.wait` in base causality order. Tests: `kamui/ptx87/griddep/*`.

### D33. ldmatrix and stmatrix

Choice: warp-collective loads and stores of matrix fragments in shared memory are weak shared-memory accesses of
each participating thread; which lane's address feeds which thread is not modelled (each litmus thread names its
own location). Tests: `kamui/ptx87/ld-st/MP+ldmatrix+bar.sync`.

### D34. red

> Table 20: "read operation | All variants of ld instruction and atom instruction (but not red instruction)."

Choice: `red` is a read-modify-write whose read returns nothing to the program; that read takes part in
atomicity and observation order like any atomic operation. Dat3M's `red.acq_rel` (not valid PTX 8.7, whose
`red` has `.relaxed` and `.release`) is read as acquire-release. Tests: `kamui/ptx87/rmw/red+final`,
`MP+red.release`, `imported/dat3m/Manual/Red-*`.

### D35. Values

Choice: memory operations carry integer values. Arithmetic of float atomics (`atom.add.f16`, `.f32`) is
modelled with integers (the model depends only on which write a read takes its value from). Bitwise atomics
work on values below 16.

### D36. Outside the model

- sm_100 and later (outside Kamui's sm_90a target): `tcgen05` and its section 9.7.16.5 (tensor memory,
  `tcgen05.fence`, `tcgen05.commit`), `st.bulk`, `clusterlaunchcontrol`, tensor copies with `gather4`/`scatter4`.
- Graphics: texture and surface instructions beyond the PTX 7.5 proxy rules (the model does not apply, 6521).
- CUDA API synchronization (6967), kernel launch and exit, `trap`.
- Read-modify-writes that cover several granules, so the partial-overlap exception of 6817 is in the axiom but no
  litmus test can express it.
- Programs with loops: the model is exact for straight-line tests; loops need unrolling, which Dartagnan does.

## Decisions from the cross-check with the Dartagnan model

### D37. The tensormap proxy fences act as a pair

> "A .release proxy fence can form a release sequence that synchronizes with an acquire sequence that contains a
> .acquire proxy fence." (9.7.13.4, 22662-22664)

Both examples of the manual (22733-22737, 25045-25050) use `fence.proxy.tensormap::generic.release` (or
`tensormap.cp_fenceproxy`, which ends with it) and `fence.proxy.tensormap::generic.acquire` together.

- A: as every other proxy fence under D2, either fence alone orders generic -> tensormap when the tensormap
  operation is in its thread block (an acquire proxy fence in the reader's CTA after an ordinary release was
  enough).
- B: generic -> tensormap only through the pair: a generic operation X, base causality to a release tensormap
  proxy fence, base causality to an acquire tensormap proxy fence in the thread block of the tensormap operation
  Y (and naming Y's address), base causality to Y.

Choice: **B** (the Dartagnan model's reading, M26; the first model used A). Tests:
`kamui/ptx87/tensormap/MP+tensormap+no-release-proxy-fence` (allowed),
`MP+tensormap+no-acquire-proxy-fence` (allowed), `MP+tensormap+proxy-fences` and
`MP+tensormap.cp_fenceproxy` (forbidden).

### D38. Mixed-size data races: per program, values from writes

> "The axioms in the memory consistency model do not apply if a PTX program contains one or more mixed-size
> data-races." (8.7.2, 6811) "In the absence of any constraint, each read operation returns the value committed
> by some write operation to the same memory location, including the initial write to that memory location."
> (8, 6511-6512)

- Per program or per execution: the first sentence speaks of the program, so one execution that satisfies the
  axioms and has a mixed-size data race (as in D7) frees every execution of the program.
- What a read returns: 6511 is not one of the axioms of 8.10, so it still holds: a read returns a value some
  write (or the initial state) committed; no other value appears.

Choice: a program with a mixed-size data race allows exactly the outcomes of its executions that satisfy only
the well-formedness facts (values from writes, program order, the instructions' own semantics), with none of the
axioms. (The first model allowed every outcome, the Dartagnan model judged each execution on its own, M16; this
merges the per-program part of the first with the values part of the second.) Tests:
`kamui/ptx87/sizes/mixed-size+race` (forbidden: no write produces 7), `mixed-size+flag` (allowed: the race is in
the execution that reads the flag as 0).

### D39. A shared::cta to shared::cluster copy into the issuing CTA

> "When the source of the copy is .shared::cta and the destination is .shared::cluster, the destination has to be
> in the shared memory of a different CTA within the cluster." (9.7.9.25.4.1, 19067-19068) The sentence before it,
> on .shared::cta destinations: "the destination address has to be in the shared memory of the executing CTA
> within the cluster, otherwise the behavior is undefined." (19064-19065)

- A: an ordinary copy, since no consequence is stated.
- B: a requirement on the program, worded like its neighbour; breaking it is undefined behaviour.

Choice: **B** (decided at the cross-check). The breach is visible in the program text, so the test allows every
outcome of a program that has an execution (D7). The same reading applies to an arrive-on that takes the pending
arrival count below zero, outside its valid range of 0 to 2^20 - 1 (9.7.13.15.2, 23989-23993; D7). Tests:
`kamui/features/async/self-copy+*` (allowed), `kamui/features/mbarrier/arrive-beyond-pending` (allowed).

### D40. Write-after-read from the generic proxy to the async proxy

> "A proxy fence is required to synchronize memory operations across different proxies." (8.6, 6779) "A memory
> read (e.g., by ld or atom) has been performed when the value read has been transmitted from memory and cannot be
> modified by another thread participating in the barrier." (9.7.13.1, 22306-22307)

- A: follow 6779 and 22645 literally: without `fence.proxy.async`, a generic read is not ordered before a later
  async-proxy write, even through a release and an acquire.
- B: a generic read that precedes an async-proxy write to the same location in base causality order has been
  performed before the write is issued, and cannot return its value.

Choice: **B** (decided at the cross-check): a generic read before an async-proxy write in base causality order is
in proxy-preserved base causality order. CUTLASS's RS main loop
(`sm90_mma_tma_gmma_rs_warpspecialized.hpp:666-684`) relies on it: the consumer reads the stage with `ldmatrix`,
arrives on the mbarrier, and the producer refills the stage with a TMA copy, with no proxy fence. Test:
`kamui/idioms/rs-mainloop-war+ldmatrix` (forbidden).
