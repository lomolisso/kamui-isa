# Design decisions of the Kamui memory model

Each decision says what the question was, what Kamui chose and why, and which tests or checks depend on it.
D<n> refers to the interpretation decisions of the PTX 8.7 model (`models/ptx87/decisions.md`), which Kamui
inherits unchanged; K<n> are Kamui's own. Background: [`spec/memory-model.md`](../../spec/memory-model.md),
[`docs/design/scope-encoding.md`](../../docs/design/scope-encoding.md),
[`docs/design/addressing.md`](../../docs/design/addressing.md).

## K1. The Kamui model is the PTX 8.7 model plus an instruction table

Question: Kamui's memory contract on GPU memory is PTX 8.7, exactly (`docs/design/scope-encoding.md`). Should the
Kamui model be written as a model of its own (for example in the style of RISC-V's RVWMO, with preserved program
order and a global memory order per scope) and then shown to implement PTX, or should it be the PTX model itself?

Choice: the PTX model itself. `kamui.als` is `models/ptx87/ptx87.als` under another module name, and
`tools/litmus/check_suite.py` fails if the two differ below the `module` line. What is Kamui's own is the table
`instructions.yaml`: for each Kamui instruction and each standard RISC-V memory instruction, the PTX operation
whose events it produces. Kamui adds no axiom: the three things PTX has no instruction for (LR/SC, warp-uniform
instructions, accesses to I/O registers) are expressed with existing events (K4, K5, K6).

Why: a separate RVWMO-style model with a global memory order is multi-copy atomic, so it would forbid outcomes
PTX allows (IRIW with weak or narrow-scope accesses) and would no longer be "PTX exactly"; making it equal to PTX
would mean writing PTX again in another form. With one model, a PTX program and its Kamui lowering can be
compared directly, and RVWMO governs nothing a Kamui thread reaches except I/O registers. A model of the H100-like
reference hardware (caches, MEMBAR, invalidations) is a different question: whether an implementation follows
this model. Decided by the project lead on 2026-11-06.

Checks: the core comparison in `check_suite.py`; every check of this directory.

## K2. Standard RISC-V atomics and ordering instructions are exact PTX operations at system scope

Question: what do the standard memory instructions of Kamui's base ISA mean on GPU memory (the A extension,
Zacas, Zabha, Zalasr, FENCE)? Plain loads and stores are already decided: `.weak` accesses
(`docs/design/scope-encoding.md`).

Choice (decided by the project lead on 2026-11-06): each is the PTX operation of the same kind at `.sys` scope:

| Standard | PTX events |
|---|---|
| `l{b,h,w,d}`, `s{b,h,w,d}` | `ld.weak`, `st.weak` |
| `amo<op>.{b,h,w,d}` | `atom.relaxed.sys.<op>` (`swap` is `exch`, `minu`/`maxu` are `min`/`max`) |
| `.aq`, `.rl` on an AMO, `amocas`, a Zalasr load or store | `.acquire.sys`, `.release.sys` |
| `.aqrl` | `fence.sc.sys` followed by the `.acq_rel.sys` (AMO) or `.acquire.sys` / `.release.sys` (load / store) form |
| `amocas.{b,h,w,d,q}` | `atom.<sem>.sys.cas` (`.q` is `.b128`) |
| FENCE | K3 |

Why: these are exact equivalents, so a compiler may later replace a 64-bit Kamui instruction by the 32-bit
standard one where they match (`lowering.yaml`, `std`). The system scope is the widest, so standard code that
synchronizes through these instructions with any thread, the host included, keeps its meaning. The other choice,
RISC-V's own strength (an `.aq` or `.rl` annotation is RCsc, which in PTX terms needs a `fence.sc` on every such
access), costs a `fence.sc.sys` per access (1138 cycles on the H100, `evidence/probes/README.md`) and would still
not make stock-compiled C and C++ correct: those compilers map relaxed atomics and fence-based synchronization to
plain loads and stores, which are `.weak` here. Code for GPU memory must therefore come from a Kamui compiler.
`.aqrl` gets the fence because RISC-V maps C++ `seq_cst` read-modify-writes to it, and the scoped C++ mapping of
PTX needs `fence.sc` before them (Lustig et al., Figure 11).

Tests: `tests/litmus/kamui-isa/std/*` (MP through fences and plain accesses is allowed on GPU memory; through
`sw.rl` and `lw.aq` it is forbidden).

## K3. FENCE

Question: RISC-V's FENCE has predecessor and successor sets (r, w, i, o); PTX fences have kinds.

Choice: count `i` as `r` and `o` as `w` (device input and output are reads and writes). Then:

| FENCE | PTX events |
|---|---|
| the predecessor set has `w` and the successor set has `r` (for example `fence rw,rw`, `fence w,r`) | `fence.sc.sys` |
| the predecessor set is `r` only (`fence r,rw`, `fence r,r`, `fence r,w`) | `fence.acquire.sys` |
| the successor set is `w` only (`fence rw,w`, `fence w,w`) | `fence.release.sys` |
| `fence.tso` (every other non-empty pair of sets is covered by the rows above) | `fence.acq_rel.sys` |
| `fence.i` | none (instruction fetch) |

Why: store-to-load order needs `fence.sc` in PTX (SB is allowed with `fence.acq_rel`); a fence after reads only is
an acquire fence and one before writes only a release fence, which is how C++ fences map to RISC-V (`fence r,rw`,
`fence rw,w`, `fence.tso`, `fence rw,rw` for acquire, release, acq_rel and seq_cst). PTX fences order every
earlier and later access, so these are at least as strong as the FENCE they replace.

## K4. LR and SC

Question: PTX has no load-reserved / store-conditional.

Choice: an LR and the SC that succeeds on its reservation are one atomic read-modify-write at `.sys` scope (the
read is the LR, the write the SC; the `rmw` relation of the model), with the ordering of an AMO with the same
`aq`/`rl` bits. A failed SC writes nothing; its LR is then a `.relaxed.sys` read (`.acquire.sys` with `aq`).

Why: this is what an LR/SC loop is for, and it gives a loop that ends in a successful SC the meaning of the AMO it
implements. RISC-V allows an SC to fail at any time, so a program cannot rely on success. There is no litmus form:
the lowering never produces LR/SC.

## K5. I/O regions

Question: RVWMO and RISC-V's I/O rules apply to device registers. How do they meet the PTX model?

Choice: every access to an I/O region is an `.mmio` access: relaxed at system scope, performed exactly once, never
merged or split (PTX 8.4.2 and D28). The Kamui forms are `kldg.mmio` and `kstg.mmio`; a standard load or store to
an I/O region means the same. FENCE with `i` or `o` orders them as K3 says.

Why: PTX's `.mmio` is the PTX meaning of a device-register access, and the H100 implements it (`LDG.E.MMIO.SYS`).
Strong system-scope operations are ordered by fences as RISC-V I/O accesses are.

## K6. Warp-uniform instructions and the elect loop

Question: Kamui copies the H100's uniform datapath (`docs/design/uniform-datapath.md`): bulk and tensor copies
(`kblkcp`, `kblkred`, `ktma*`) and the cluster barrier (`kcgabar`) take uniform operands and run once for the warp.
PTX's `cp.async.bulk` is a per-thread instruction: its operations "are ordered after prior instructions in the same
thread" (8.9.1.1). When several threads of a warp each ask for a copy, which thread is a uniform copy performed for,
and what is it ordered after?

Choice: the compiler issues the copies through an elect loop, as the H100 does: each iteration picks one of the
remaining threads (`kelect`), moves that thread's operands into uniform registers and issues one uniform copy. That
copy is the copy of the picked thread: it is ordered after that thread's earlier instructions, as PTX says, and
after nothing else. A uniform instruction does not synchronize the active threads with each other; ordering between
threads needs explicit synchronization, and a copy that reads data written through the generic proxy needs
`kfence.proxy.async` in the writing thread, both as in PTX. Issuing a copy is not completing it: its results and
the reuse of its buffers wait for its mbarrier or its bulk group. The cluster barrier counts the arrival of every
active thread, each with its own release or acquire, as PTX does per thread.

Why: the H100's loop (`evidence/sass/cp.async.bulk.global_to_shared.sass`: `ELECT`, `UBLKCP`, `BRA.U.ANY` back while
a thread is left) issues each thread's own copy, so the thread that asks for a copy is the thread it is performed
for and PTX's rule applies unchanged. `elect.sync` only waits for the threads of its mask and has no memory effect
(PTX 9.7.13.14). An earlier draft ordered every uniform instruction after the earlier instructions of all active
threads, as if a `kwarpsync` came first; that is more than PTX asks and was dropped (project lead, 2026-11-06).
Check: the `async` group of `check_lowering.sh` and the broken lowering that performs a copy for another thread
than the one that asked for it.

## K7. Shared memory of other CTAs is reached with generic instructions

Question: `docs/design/addressing.md` lists `klds`/`ksts`/`katoms` for "CTA and cluster window offsets". On the
H100, `ld.shared::cluster`, `st.shared::cluster`, `atom.shared::cluster` and `red.shared::cluster` compile to the
generic `LD.E`, `ST.E`, `ATOM.E` with an address in the cluster window, and `LDS`/`STS`/`ATOMS` reach only the
executing CTA's window.

Choice: as the H100. `klds`, `ksts`, `katoms` take an offset in the executing CTA's shared window; the shared
memory of other CTAs of the cluster is reached through the generic forms `kld`, `kst`, `katom` with a full generic
address, which the compiler builds from the window base, the target CTA's rank (bits 24 and up) and the offset, as
`evidence/sass/ld.shared.cluster.sass` does (`SR_SWINHI`, `LEA ... 0x18`, `PRMT`, then `ST.E`). Global accesses
keep their own form (`ld.global` is `kldg`, the H100's `LDG`). The addressing design document is corrected
(project lead, 2026-11-06).

Why: 1-to-1 with the H100; the model is unaffected (D17: the windows are views of one location).

## K8. Reductions on shared memory are atomics with no result

Choice: `red.shared` lowers to `katoms ... RZ` and `red.shared::cluster` to `katom ... RZ` (the H100 has no
shared-memory `RED`). The events are the same (D34).

## K9. ldu reads through the non-coherent path

Choice: `ldu.global` lowers to `kldg.nc`, the same events as the PTX model's reading (D29: a read through the
non-coherent path, like `ld.global.nc`). Neither `ldu` nor `ld.global.nc` has a standard alternative.

Why: the H100 compiles `ldu` to a plain `LDG` and `ld.global.nc` to `LDG.E.CONSTANT`, and an earlier version of
this lowering copied that (`ldu` as a weak generic read), on the idea that a generic read is stronger. The bounded
check (`proxies` group, `check_lowering.sh`) found that it is not: in the PTX model, two reads of one location by
one thread through the same path are morally strong, so they are coherent with each other (SC per location); when
only one of them becomes a generic read, the pair is no longer morally strong, and the later read may return an
older value. A program that reads one location with `ldu` and then with `ld.global.nc` keeps PTX's guarantee only
if both use the same path. The H100's choice is an implementation that may break that guarantee for such
programs; whether PTX means to give it (6521 says the memory model does not apply to these reads at all) is an open
question, recorded in the report.

## K10. .volatile

Choice: Kamui has no volatile qualifier. `ld.volatile` and `st.volatile` lower to the relaxed system-scope form of
their space (PTX 8.4.2 and D28). "Never merged or split" is a rule for the compiler, which must not merge
identical loads across an ordering instruction either (ptxas 12.8 does: `models/ptx87/README.md`).

## K11. mbarrier at .cta scope has the full ordering of the manual

Choice: every `kmbar` instruction has the meaning of its PTX operation, including the release semantics of an
arrive and the acquire semantics of a successful test or try at `.cta` scope (9.7.13.15.16). The H100 does not
give this ordering at `.cta` scope (`evidence/litmus-h100/README.md`): a Kamui implementation built like the H100
must add it (an order-preserving drain before the arrive, or make later accesses wait for a successful test).

## K12. Tensor-map instructions

Choice: `tensormap.replace` is a weak generic write of the field (the H100's `STG` sequence); `tensormap.cp_fenceproxy`
is a weak shared-memory read and a weak global write per 16-byte chunk, followed by
`kfence.proxy.tensormap.release.<s>` (9.7.9.26). This is the same as the PTX model's reading.

## K13. wgmma.commit_group is its own instruction

Question: the H100 has no instruction for `wgmma.commit_group`: the group is an operand of the matrix instruction
(`HGMMA ... gsb0`, waited for with `WARPGROUP.DEPBAR.LE gsb0, N`, `evidence/sass/wgmma.mma_async*.sass`). Should
Kamui copy that, with a commit bit on the last `kgmma`?

Choice: no. `wgmma.commit_group` lowers to `kwarpgroup.commit` and `wgmma.wait_group N` to `kwarpgroup.depbar N`.
A commit with no `kgmma` since the previous one makes an empty group, as in PTX (9.7.15.7.2), and waits count it.

Why: with a commit bit, a commit that closes an empty group has no `kgmma` to carry it, and a compiler would have to
drop it and lower the later wait counts on every control-flow path, which is real work for little gain. A separate
instruction lowers PTX one to one. Our H100 evidence has one group per kernel, so how the H100 handles an empty
group is not shown. Fusing the commit into the last `kgmma` remains a possible optimization for a compiler that
proves it equivalent. One of the few places where the ISA does not copy the H100 (project lead, 2026-11-06).

## K14. st.param

Choice: `st.param` writes an argument of a device-function call, which only the calling thread can see. It lowers
to a register move or to a store into the callee's stack frame (`kstl`). There is no PTX litmus test (the model
treats `.param` as read-only).
