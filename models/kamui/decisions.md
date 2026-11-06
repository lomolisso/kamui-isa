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
| any other set, and `fence.tso` | `fence.acq_rel.sys` |
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
PTX's `cp.async.bulk` is a per-thread instruction, ordered after the earlier instructions of the thread that
issues it (6884). Who performs a uniform instruction, and what is it ordered after?

Choice: a uniform instruction executed by a set A of active threads is performed by one thread of A (the one
`kelect` picks) and is ordered after the earlier instructions of every thread of A, as if a `kwarpsync` over A
preceded it. A per-thread PTX copy issued by several active threads is lowered to an elect loop: each iteration
picks one thread, moves its operands into uniform registers and issues one uniform copy. With one active thread
(every litmus test) A is that thread and the rule adds nothing. The cluster barrier counts the arrival of every
thread of A.

Why: this is the H100's lowering (`ELECT`, `UBLKCP`, `evidence/sass-observations.csv`), and the ordering rule is
what makes the copy a thread asked for come after that thread's earlier writes, even when another thread issues
it. Check: the `uniform` group of `check_lowering.sh` and its broken lowering (`broken/elect-no-order`).

## K7. Shared memory of other CTAs is reached with generic instructions

Question: `docs/design/addressing.md` lists `klds`/`ksts`/`katoms` for "CTA and cluster window offsets". On the
H100, `ld.shared::cluster`, `st.shared::cluster`, `atom.shared::cluster` and `red.shared::cluster` compile to the
generic `LD.E`, `ST.E`, `ATOM.E` with an address in the cluster window, and `LDS`/`STS`/`ATOMS` reach only the
executing CTA's window.

Choice: as the H100. `klds`, `ksts`, `katoms` take an offset in the executing CTA's shared window; the shared
memory of other CTAs of the cluster is reached through the generic forms with the cluster-window address. The
addressing design document is corrected.

Why: 1-to-1 with the H100; the model is unaffected (D17: the windows are views of one location).

## K8. Reductions on shared memory are atomics with no result

Choice: `red.shared` lowers to `katoms ... RZ` and `red.shared::cluster` to `katom ... RZ` (the H100 has no
shared-memory `RED`). The events are the same (D34).

## K9. ldu is a weak generic read

Choice: `ldu.global` lowers to `kldg.weak`, as the H100 compiles it to a plain `LDG`. The PTX model reads `ldu`
through the non-coherent (texture) path (D29), which may return older values; a weak generic read returns a
subset of them. Kamui is stronger here. Tests: `ptx/kamui/ptx87/ld-st/MP+ldu` (allowed in PTX, forbidden for the
lowered program).

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

## K13. wgmma.commit_group is a bit of the last kgmma

Choice: the H100 has no instruction for `wgmma.commit_group`; the commit point is part of the matrix instruction.
Kamui's `kgmma` has a `.commit` bit; the lowering sets it on the last `kgmma` before the commit point. A commit
with no `kgmma` since the previous one closes an empty group, which is complete at once: the lowering drops it and
lowers a later `wgmma.wait_group n` to `kwarpgroup.depbar n'`, where `n'` counts only the non-empty groups among
the newest `n`. Waiting for all but `n'` non-empty groups waits for at least what PTX asks.

## K14. st.param

Choice: `st.param` writes an argument of a device-function call, which only the calling thread can see. It lowers
to a register move or to a store into the callee's stack frame (`kstl`). There is no PTX litmus test (the model
treats `.param` as read-only).
