# The Kamui memory model

This chapter says what every Kamui memory instruction means when several threads use memory at the same time:
which values a load may return, and which orders between memory operations a program can rely on. It covers all
tiers. The encodings of the instructions are in the ISA specification; this chapter fixes only names, operands
and meaning.

Background for readers new to memory models: a **litmus test** is a tiny multi-threaded program plus a question
about its final state. The classic one is message passing (MP): thread 0 writes `data = 1` and then `flag = 1`;
thread 1 reads `flag` and then `data`. "Can thread 1 see `flag == 1` but `data == 0`?" A memory model answers
*allowed* or *forbidden* for every such question. [`tests/litmus/README.md`](../tests/litmus/README.md) has the
tests and their answers.

## 1. The contract

**On GPU memory, Kamui's memory model is the PTX ISA 8.7 memory model, exactly** (chapter 8 of NVIDIA's PTX ISA
manual, version 8.7). A Kamui program may show exactly the outcomes PTX 8.7 allows for the PTX program it
corresponds to, operation by operation. Two consequences:

- **Implementations may be stronger.** A functional simulator in which every access goes to one memory shows
  none of the weak outcomes, and that is allowed. A design built like the H100 shows the ones the H100 shows.
  Software must not rely on any outcome being impossible unless the model forbids it.
- **It is versioned.** When Kamui moves to a newer PTX version, it adopts that version's memory model.

Why PTX: Kamui runs PTX programs (compiled from CUDA), so a Kamui memory model weaker than PTX would break them,
and one stronger than PTX would make every implementation pay for orderings PTX programs do not ask for. The
design decision is in [`docs/design/scope-encoding.md`](../docs/design/scope-encoding.md).

The formal model is [`models/kamui/kamui.als`](../models/kamui/kamui.als), which is the PTX 8.7 model of
[`models/ptx87`](../models/ptx87/README.md) under another name. Kamui adds no rule to it; what Kamui adds is a
table saying which PTX operations each Kamui instruction performs (section 5) and what the standard RISC-V
instructions mean on GPU memory (section 6). The design decisions of the Kamui model are K1 to K14 in
[`models/kamui/decisions.md`](../models/kamui/decisions.md); the interpretation decisions it inherits from the PTX
model are D1 to D40 in [`models/ptx87/decisions.md`](../models/ptx87/decisions.md).

## 2. Where it applies: GPU memory and I/O

**GPU memory** is all memory a Kamui thread can reach with an ordinary address:

- global memory, including host memory mapped into the GPU's address space (pinned or managed memory, which the
  `.sys` scope orders against the host);
- the shared memory of the CTA and of the cluster (the shared and cluster windows of
  [`docs/design/addressing.md`](../docs/design/addressing.md));
- local memory (the local window).

How this fits RISC-V: the RISC-V memory model, RVWMO, says that "the memory consistency model for memory regions
marked as non-coherent in PMAs is currently platform-specific and/or device-specific". GPU memory is such a region,
and Kamui defines its model as the PTX model. RVWMO is not used for GPU memory.

**I/O regions** (memory-mapped device registers) follow RISC-V's rules for I/O. Every access to an I/O region is
an `.mmio` access in PTX terms: relaxed at system scope, performed exactly once, never merged or split (K5).
FENCE with the `i` and `o` bits orders them (section 6).

## 3. Threads, scopes and events

**Threads and the scope tree.** Threads are grouped into CTAs, CTAs into clusters, clusters into a GPU, and GPUs
and the host into the system. A **scope** names one level of this tree, seen from the executing thread:

| Scope | Threads it includes |
|---|---|
| `cta` | the threads of my CTA |
| `cluster` | the threads of my cluster (up to 16 CTAs) |
| `gpu` | the threads of my GPU |
| `sys` | every thread, on every GPU and the host |

Kamui keeps all four scopes. The H100 implements `cluster` as `gpu`; a Kamui implementation may do the same.

**Operations.** Every memory instruction performs one or more **operations** (the model calls them events):

- a **read** or a **write** of one location, with a value;
- a **read-modify-write**: a read and a write of one location that no other write can come between;
- a **fence**;
- a **barrier** arrival or wait.

Each memory operation has an **ordering** and a **scope**:

| Ordering | Meaning, in one line |
|---|---|
| `weak` | an ordinary access; no ordering of its own, no scope |
| `relaxed` | a strong access at its scope: coherent with other strong accesses that include each other's threads |
| `acquire` | relaxed, and later operations of the thread cannot be seen before it |
| `release` | relaxed, and earlier operations of the thread are seen before it |
| `acq_rel` | both (read-modify-writes and fences) |
| `sc` | an acquire-release fence that is also ordered with every other `sc` fence it includes (fences only) |

**Proxies.** Memory can be reached by different paths, which PTX calls proxies: the generic proxy (ordinary loads
and stores), the async proxy (bulk and tensor copies, matrix operands), the tensormap proxy (tensor-map
descriptors), and the non-coherent read path (`ld.global.nc`). Operations through different proxies are ordered
only through proxy fences. Kamui keeps the proxies as PTX defines them (the H100 has the corresponding fences:
`FENCE.VIEW.ASYNC`, `UTMACCTL`).

## 4. The rules

These are the rules of PTX 8.7 chapter 8, which `kamui.als` encodes one definition at a time;
[`models/kamui/definitions.md`](../models/kamui/definitions.md) maps every definition to the numbered rule below.
The examples are litmus tests of `tests/litmus/`.

### 4.1 Scope tree

The CTAs, clusters, GPUs and the system form a tree with threads as leaves; an operation's scope is a node above
its thread (PTX 8.5). A weak operation has its own thread as scope.

### 4.2 Locations, state spaces, proxies and aliases

A location is one granule of memory. It belongs to one state space (global, shared, local, constant, parameter);
shared and local locations have an owner (a CTA, or a thread). Two virtual addresses of the same memory are
**virtual aliases**; using both behaves as if they were different proxies and needs a proxy fence (PTX 8.2, 8.6).
The shared windows of the CTAs of a cluster are views of one memory (D17).

### 4.3 Operations

Reads, writes, read-modify-writes, fences, barrier operations and markers (points in program order with no memory
effect of their own, such as the issue of an asynchronous copy), as in section 3. Bitwise atomics combine values
bit by bit (D35).

### 4.4 An execution

An execution says, for each read, which write it reads from (**reads-from**), and orders the writes to each
location (**coherence order**). A read that reads from no write returns the initial value. **Program order** is the
order of a thread's operations.

### 4.5 Morally strong

Two operations are **morally strong** with respect to each other when both are strong (not weak), each one's scope
includes the other's thread, they use the same proxy, and they cover exactly the same bytes (PTX 8.7). Most rules
apply only to morally strong pairs. Example: in `tests/litmus/ptx/kamui/families/CoRR+relaxed.gpu+diff-cta`, two
relaxed `.gpu` loads in another CTA cannot see a newer and then an older value; with weak loads
(`CoRR+weak`) they can.

### 4.6 Coherence order and Fence-SC order

Morally strong writes to one location are ordered by coherence order (PTX 8.9.1). Every pair of morally strong
`fence.sc` is ordered by **Fence-SC order**, one order for the whole execution (8.9.2).

### 4.7 Release and acquire patterns, observation

A **release pattern** is a release write, or a release (or acq_rel, or sc) fence followed in program order by a
strong write. An **acquire pattern** is an acquire read, or a strong read followed by an acquire fence (8.8).
A write is **observed** by a read that reads from it, directly or through a chain of read-modify-writes (8.9.3).

### 4.8 Synchronizes-with

A release pattern **synchronizes with** an acquire pattern when the acquire pattern observes the release pattern's
write and the two are morally strong (8.9.4). The other ways to synchronize:

- `fence.sc` operations, through Fence-SC order;
- CTA barriers (`bar.sync`, `bar.arrive`, `bar.red`, `bar.warp.sync`): the arrivals of one completion of the
  barrier synchronize with its waits; the wait also acts as an acquire-release fence (D9, D10, D30);
- cluster barriers: a `barrier.cluster.arrive` synchronizes with the `barrier.cluster.wait` of its generation; a
  `.relaxed` arrive gives no ordering of its own (D11);
- mbarrier objects (4.15): an arrive with release semantics synchronizes with a test or try that returns True with
  acquire semantics.

Example: `tests/litmus/ptx/kamui/families/MP+rel-acq.gpu+diff-cta`, forbidden.

### 4.9 Restricted release and acquire

Some fences order only some operations (PTX 9.7.13.4): `fence.release.sync_restrict::shared::cta` only earlier
operations on the executing CTA's shared memory; `fence.acquire.sync_restrict::shared::cluster` only later
operations on shared memory of the cluster; `fence.mbarrier_init.release.cluster` only earlier `mbarrier.init`
operations; the implicit complete-tx of an asynchronous copy only that copy's operations. These orders are not
transitive on their restricted side (D18, D19).

### 4.10 Base causality and asynchronous operations

**Base causality order** is program order and synchronizes-with, and their combinations (8.9.5). Asynchronous
operations (cp.async, bulk and tensor copies, matrix operands) are performed outside program order, by an
asynchronous unit, and are ordered after the instruction that started them; their completion (a wait on their
group, or the complete-tx on an mbarrier) is ordered before the instruction that waits for it (8.9.1.1; D20, D21).
`griddepcontrol.wait` is ordered after every operation of the prerequisite grid (D32).

### 4.11 Proxy-preserved base causality

Base causality orders two accesses of the same location only when they use the same proxy (the generic proxy, or
one proxy within one CTA), or when a proxy fence of the right direction lies between them on the path (8.9.5;
D2). The tensormap proxy fences act as a pair, a release fence after the write and an acquire fence before the
use (D37). A generic read before an async-proxy write needs no fence (D40).

### 4.12 Causality order

**Causality order** is proxy-preserved base causality, possibly started by an observation (8.9.6).

### 4.13 The axioms

An execution is allowed when all six hold (8.10):

| Axiom | In one line |
|---|---|
| Coherence | a write that precedes another write to the same location in causality order also precedes it in coherence order |
| Fence-SC | `fence.sc` operations related by base causality are related the same way in Fence-SC order |
| Atomicity | no write comes between the read and the write of a read-modify-write (for morally strong operations); a read does not take some bytes from one write and others from an older one |
| No thin air | values do not appear out of nowhere: reads-from plus dependencies is acyclic |
| SC per location | morally strong accesses to one location, plus program order on it, are acyclic |
| Causality | a read does not read from a write that it precedes in causality order, nor from a write older (in coherence order) than one that precedes it |

### 4.14 Undefined behaviour

A program with a **mixed-size data race** (two operations that partly overlap, at least one a write, neither
morally strong with nor causality-ordered with the other) is not constrained by the axioms, but its reads still
return values some write wrote (8.7.2; D38). Using an mbarrier location that holds no valid object, arriving more
often than pending, or waiting for a phase older than the previous one is undefined: every outcome is allowed
(9.7.13.15; D7, D15).

### 4.15 mbarrier objects

An mbarrier is a location in shared memory whose value is its state: the current phase, the pending arrival count,
the expected arrival count and the transaction count. `init` and `inval` write it; arrive, expect-tx and
complete-tx are read-modify-writes of it; test and try read it (D12). A phase completes when the pending count and
the transaction count are both zero: the phase advances and the pending count is reset to the expected count
(D13). A test or try returns True when the phase it names has completed (D15).

Kamui gives every mbarrier operation exactly this meaning, including at `.cta` scope (K11). The H100 does not
order the data at `.cta` scope (`evidence/litmus-h100/README.md`): a Kamui implementation built like the H100 must
add that ordering.

## 5. Kamui memory instructions

One Kamui instruction for each PTX memory operation, with scope and ordering as fields
([`docs/design/scope-encoding.md`](../docs/design/scope-encoding.md)). The full table, with every form and the H100
instruction each one copies, is [`models/kamui/instructions.yaml`](../models/kamui/instructions.yaml); names are
provisional.

| Family | Kamui | Performs the PTX operation | H100 |
|---|---|---|---|
| loads | `kld`, `kldg`, `klds`, `kldl` `{.weak, .relaxed.<s>, .acquire.<s>}`; `kldg.nc`; `.mmio`; `kldc.{const,param}` | `ld` (generic, `.global`, `.shared::cta`, `.local`), `ld.global.nc`, `ld.mmio`, `ld.const`, `ld.param` | `LD`, `LDG`, `LDS`, `LDL`, `LDC` |
| stores | `kst`, `kstg`, `ksts`, `kstl` `{.weak, .relaxed.<s>, .release.<s>}`; `.mmio` | `st` of the same space | `ST`, `STG`, `STS`, `STL` |
| atomics | `katom`, `katomg`, `katoms` `.<op>{.relaxed, .acquire, .release, .acq_rel}.<s>`; `kred`, `kredg` | `atom`, `red` | `ATOM`, `ATOMG`, `ATOMS`, `RED`, `REDG` |
| multimem | `kldgmc`, `kstgmc`, `kredgmc` | `multimem.ld_reduce`, `.st`, `.red` | `LDGMC`, `STG`, `REDG` on a multicast address |
| fences | `kfence.{acquire, release, acq_rel, sc}.<s>`; `kfence.restrict.*`; `kfence.proxy.{alias, async, tensormap}`; `kcctl.rml2` | `fence`, restricted fences, proxy fences, `discard` | `MEMBAR` + `CCTL` sequences, `FENCE.VIEW.ASYNC`, `UTMACCTL`, `CCTL.E.RML2` |
| CTA barriers | `kbar.sync`, `kbar.arv`, `kbar.red`; `kwarpsync` | `bar.sync`, `bar.arrive`, `bar.red`, `bar.warp.sync` | `BAR.*`, `WARPSYNC` |
| cluster barriers | `kcgabar.arv{.release, .relaxed}`, `kcgabar.wait.acquire` | `barrier.cluster.*` | `UCGABAR_ARV`, `UCGABAR_WAIT` |
| mbarrier | `kmbar.{init, inval, arv, arv.drop, arv.expect_tx, expect_tx, complete_tx, test, try}`, `.remote` for another CTA's object; `kmbar.arv.ldgsts` | `mbarrier.*`, `cp.async.mbarrier.arrive` | `SYNCS.*`, `ARRIVES.LDGSTSBAR` |
| async copies | `kldgsts`, `kldgdepbar`, `kdepbar.ldgsts`; `kblkcp`, `kblkred`, `ktmaldg`, `ktmastg`, `ktmaredg`, `ktmacmdflush`, `kdepbar.bulk`; `kstas`, `kredas` | `cp.async*`, `cp.async.bulk*`, `cp.reduce.async.bulk*`, `st.async`, `red.async` | `LDGSTS`, `LDGDEPBAR`, `DEPBAR`, `UBLKCP`, `UBLKRED`, `UTMALDG`, `UTMASTG`, `UTMAREDG`, `UTMACMDFLUSH`, `STAS`, `REDAS` |
| grids | `kacqbulk`, `kpreexit` | `griddepcontrol.wait`, `.launch_dependents` | `ACQBULK`, `PREEXIT` |
| matrix (memory side) | `kldsm`, `kstsm`; `kwarpgroup.arrive`, `kgmma`, `kwarpgroup.commit`, `kwarpgroup.depbar` | `ldmatrix`, `stmatrix`; `wgmma.fence`, `.mma_async`, `.commit_group`, `.wait_group` | `LDSM`, `STSM`, `WARPGROUP.*`, `HGMMA` |

Notes:

- `klds`, `ksts` and `katoms` reach only the executing CTA's shared memory. The shared memory of another CTA of the
  cluster is reached with the generic forms and a generic address (K7).
- Bulk and tensor copies and the cluster barrier take uniform operands. When several threads each ask for a copy,
  the compiler issues them one thread at a time (an elect loop); each copy is the copy of the thread it was issued
  for and is ordered after that thread's earlier instructions only. Ordering between threads needs explicit
  synchronization and `kfence.proxy.async`, as in PTX (K6).
- `kwarpgroup.commit` is a Kamui instruction where the H100 has a field of `HGMMA` (K13).

## 6. Standard RISC-V instructions on GPU memory

Kamui's base ISA includes RISC-V's standard memory instructions. On GPU memory they are exact PTX operations at
system scope (K2, K3):

| Standard instruction | PTX operations |
|---|---|
| `lb`, `lbu`, `lh`, `lhu`, `lw`, `lwu`, `ld` | `ld.weak` |
| `sb`, `sh`, `sw`, `sd` | `st.weak` |
| `amo<op>.{b,h,w,d}` (A, Zabha) | `atom.relaxed.sys.<op>` (`swap` is `exch`) |
| `amo<op>.aq`, `.rl` | `atom.acquire.sys`, `atom.release.sys` |
| `amo<op>.aqrl` | `fence.sc.sys`, then `atom.acq_rel.sys` |
| `amocas.{b,h,w,d,q}` (Zacas) | `atom.<sem>.sys.cas` (`.q` is 128 bits) |
| `l{b,h,w,d}.aq`, `s{b,h,w,d}.rl` (Zalasr) | `ld.acquire.sys`, `st.release.sys` |
| `l*.aqrl`, `s*.aqrl` | `fence.sc.sys`, then `ld.acquire.sys` or `st.release.sys` |
| `lr` and a successful `sc` (A) | one read-modify-write at system scope, ordered as an AMO with the same bits; a failed `sc` writes nothing (K4) |
| `fence` with `w` before and `r` after (for example `fence rw,rw`) | `fence.sc.sys` |
| `fence` with only `r` before (`fence r,rw`) | `fence.acquire.sys` |
| `fence` with only `w` after (`fence rw,w`) | `fence.release.sys` |
| `fence.tso` | `fence.acq_rel.sys` |
| `cbo.inval` (Zicbom) | `discard.global.L2` of the cache block |
| `fence.i`, `cbo.clean`, `cbo.flush`, `prefetch.*`, `ntl.*`, `pause`, `wrs.*` | no memory operation |

In FENCE, `i` counts as `r` and `o` as `w`.

**What this means for portable code.** Plain loads and stores are weak, so code compiled by a stock RISC-V compiler
is not guaranteed on GPU memory when it synchronizes through them: C and C++ compilers map relaxed atomics to
`lw`/`sw` and acquire and release to fences around them (the mappings of the RISC-V manual). Code for GPU memory
must come from a Kamui compiler, which uses the Kamui instructions of section 5 (or the AMOs and Zalasr
instructions above). Note also that Kamui's `.aq` and `.rl` are PTX acquire and release, not RISC-V's RCsc
annotations: a `.rl` store followed by an `.aq` load does not stop store buffering; `.aqrl` does.

| Test (`tests/litmus/kamui-isa/hand/`) | Kamui |
|---|---|
| `MP+fence-plain` (`sw; fence rw,w; sw` and `lw; fence r,rw; lw`) | allowed |
| `MP+rl-aq` (`sw.rl` and `lw.aq`) | forbidden |
| `MP+amo-rl-aq` (`amoswap.w.rl` and `amoor.w.aq`) | forbidden |
| `SB+fence-plain` (`fence rw,rw` between plain accesses) | forbidden: `fence.sc` orders even weak accesses through Fence-SC order |
| `SB+rl-aq` | allowed |
| `SB+aqrl` | forbidden |
| `CoRR+plain` | allowed |
| `MP+kfence` (Kamui release and acquire fences at `.gpu`) | forbidden |

## 7. The lowering from PTX

The table every PTX compiler for Kamui follows, in the style of LLVM's AMDGPU memory-model tables. The
authoritative version, one rule per PTX form, is [`models/kamui/lowering.yaml`](../models/kamui/lowering.yaml);
`std` is the standard instruction a compiler may use instead, when one exists. Address arithmetic (`cvta`, `mapa`,
window bases) is not shown.

| PTX | Kamui | `std` alternative | Why |
|---|---|---|---|
| `ld.weak` / `st.weak` (any space) | `kld*.weak` / `kst*.weak` of the space | `lw` / `sw` (exact) | the same events |
| `ld.relaxed.<s>` / `st.relaxed.<s>` | `kld*.relaxed.<s>` / `kst*.relaxed.<s>` | none (`lw` is weaker) | the same events |
| `ld.acquire.<s>` / `st.release.<s>` | `kld*.acquire.<s>` / `kst*.release.<s>` | `lw.aq` / `sw.rl` (exact at `.sys`, stronger otherwise) | the same events |
| `ld.shared::cluster`, `st.shared::cluster`, `atom.shared::cluster` | `kld`, `kst`, `katom` with a generic address | as above | the H100 uses generic `LD`/`ST`/`ATOM` (K7) |
| `ld.volatile` / `st.volatile` | `kld*.relaxed.sys` / `kst*.relaxed.sys` | none | PTX defines volatile as relaxed at system scope (K10) |
| `ld.global.nc`, `ldu.global` | `kldg.nc` | none (a plain `lw` is not stronger when the thread also reads the location through the non-coherent path) | the same events (K9) |
| `ld.const`, `ld.param` | `kldc.const`, `kldc.param` | none | the same events |
| `atom.<sem>.<s>.<op>` | `katom*.<op>.<sem>.<s>` | `amo<op>` / `amocas` with the matching bits (exact at `.sys`, stronger otherwise; `acq_rel` becomes `.aqrl`, which adds `fence.sc.sys`) | the same events |
| `red.<sem>.<s>.<op>` | `kredg` / `kred`; `katoms` / `katom` with result `RZ` on shared memory | `amo<op>` with `rd = x0` | a reduction is an atomic with no result (K8, D34) |
| `fence.<sem>.<s>`, `membar.{cta,gl,sys}` | `kfence.<sem>.<s>`, `kfence.sc.{cta,gpu,sys}` | `fence rw,rw` / `fence.tso` / `fence r,rw` / `fence rw,w` (exact at `.sys`, stronger otherwise) | membar is `fence.sc` |
| restricted and proxy fences | `kfence.restrict.*`, `kfence.proxy.*` | none | the same events |
| `bar.sync`, `barrier.sync`, `bar.arrive`, `bar.red`, `bar.warp.sync` | `kbar.sync`, `kbar.arv`, `kbar.red`, `kwarpsync` | none | the same events |
| `barrier.cluster.arrive{.relaxed}`, `.wait` | `kcgabar.arv{.release,.relaxed}`, `kcgabar.wait.acquire` | none | the same events, per thread (K6) |
| `mbarrier.*` | `kmbar.*` | none | the same events, full ordering at `.cta` (K11) |
| `cp.async`, `commit_group`, `wait_group n` | `kldgsts`, `kldgdepbar`, `kdepbar.ldgsts n` | none | the same events |
| `cp.async.wait_all` | `kldgdepbar; kdepbar.ldgsts 0` | none | PTX defines it as commit then wait 0 |
| `cp.async.bulk*`, `cp.reduce.async.bulk*`, tensor forms | `kblkcp`, `kblkred`, `ktmaldg`, `ktmastg`, `ktmaredg` (in an elect loop when several threads issue) | none | the same events per issuing thread (K6) |
| `cp.async.bulk.commit_group`, `.wait_group{.read} n` | `ktmacmdflush`, `kdepbar.bulk{.read} n` | none | the same events |
| `st.async`, `red.async` | `kstas`, `kredas` | none | the same events |
| `tensormap.replace` | `kstg.weak` of the field | `sw` | the same events (K12) |
| `tensormap.cp_fenceproxy...release.<s>` | `klds.weak r, [src]; kstg.weak [dst], r; kfence.proxy.tensormap.release.<s>` | none | PTX defines it as the copy and the release proxy fence (K12) |
| `wgmma.fence`, `.mma_async`, `.commit_group`, `.wait_group n` | `kwarpgroup.arrive`, `kgmma`, `kwarpgroup.commit`, `kwarpgroup.depbar n` | none | the same events (K13) |
| `ldmatrix`, `stmatrix` | `kldsm`, `kstsm` | none | the same events |
| `multimem.*` | `kldgmc`, `kstgmc`, `kredgmc` | none | the same events |
| `discard.global.L2` | `kcctl.rml2` | `cbo.inval` (128-byte block) | the same events |
| `griddepcontrol.wait`, `.launch_dependents` | `kacqbulk`, `kpreexit` | none | the same events |
| `st.param` | a register move or a store into the callee's frame | none | private to the thread (K14) |
| `prefetch`, cache hints, `applypriority`, `createpolicy` | `prefetch.r`, `ktmacctl.pf`, or nothing | | no memory effect (D27) |

Every PTX memory operation becomes one Kamui instruction except `cp.async.wait_all` (two) and
`tensormap.cp_fenceproxy` (three per 16-byte chunk, which copies 128 bytes).

## 8. Examples

**Message passing with Kamui instructions.** Thread 0 in CTA 0, thread 1 in CTA 1:

```
kstg.weak data, 1          | kldg.acquire.gpu r0, flag
kstg.release.gpu flag, 1   | kldg.weak r1, data
```

`r0 == 1 && r1 == 0` is forbidden: the release store and the acquire load are morally strong (both at `.gpu`, which
includes both threads), the load observes the store, so they synchronize and the weak store of `data` precedes the
weak load in causality order. With `.cta` instead of `.gpu` the two operations are not morally strong (each scope
must include the other thread) and the outcome is allowed (`tests/litmus/ptx/kamui/families/MP+rel-acq.*`).

**The same with standard instructions.** `sw.rl flag, 1` and `lw.aq r0, flag` are release and acquire at `.sys`:
forbidden, as above. `fence rw,w; sw flag, 1` and `lw r0, flag; fence r,rw` are not: the plain accesses are weak, and a
release or acquire fence synchronizes only through a strong access after (or before) it (`MP+fence-plain`,
allowed). A `fence rw,rw` (`fence.sc.sys`) is different: two `fence.sc` are always ordered with each other, so
store buffering through it is forbidden even with plain accesses (`SB+fence-plain`).

**mbarrier at `.cta` scope.** Thread 0 writes `data`, then `kmbar.arv.release.cta [b]`; thread 1 of the same CTA
waits with `kmbar.try.parity.acquire.cta` until it returns True, then reads `data`. Reading the old value is
forbidden on Kamui (K11), although the H100 shows it in about 1% of runs.

## 9. How it is checked

| Check | Command | What it shows |
|---|---|---|
| the model is PTX's | `python tools/litmus/check_suite.py` | `kamui.als` equals `ptx87.als` below its first line |
| litmus lowering | `python tools/litmus/to_kamui.py` then `run_formal.py --models kamui-alloy,kamui-std-alloy` | every PTX test lowered (Kamui instructions, and standard instructions where allowed) and decided by the Kamui model; `check_suite.py` fails if a lowered test allows an outcome PTX forbids |
| lowering check, identity | `python tools/litmus/check_suite.py` | where the lowering is one Kamui instruction with the same events per PTX operation, the Kamui execution is a copy of the PTX one, so every PTX axiom holds, for programs of every size |
| bounded lowering check, standard instructions | `models/kamui/check_lowering.sh all` | for all programs of up to 4 events (loads, stores, read-modify-write halves, fences), widened scopes and the inserted `fence.sc` preserve each PTX axiom |
| broken lowerings | `models/kamui/check_lowering.sh broken`, `to_kamui.py --broken <rule>` | a deliberately wrong lowering is caught |

The results and their times are in [`models/kamui/README.md`](../models/kamui/README.md).
