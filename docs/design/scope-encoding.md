# Memory scopes, orderings and plain accesses

Decided 2026-11-05.

## Question

PTX memory operations have a scope (`.cta`, `.cluster`, `.gpu`, `.sys`) and an ordering (`.weak`, `.relaxed`,
`.acquire`, `.release`, `.acq_rel`, `.sc`). How does a Kamui instruction say which ones it has, and what do the
standard RISC-V loads, stores and atomics mean on GPU memory? No RISC-V extension, ratified or in progress, has
memory scopes.

## Decision

**Scope and ordering are fields of every Kamui memory instruction:** loads, stores, atomics, reductions and
fences. One Kamui instruction for each PTX memory operation.

| Field | Values |
|---|---|
| Scope (2 bits) | `cta`, `cluster`, `gpu`, `sys` |
| Ordering (3 bits) | loads: `weak`, `relaxed`, `acquire`; stores: `weak`, `relaxed`, `release`; atomics: `relaxed`, `acquire`, `release`, `acq_rel`; fences: `acquire`, `release`, `acq_rel`, `sc`, and the proxy fences |

The H100 also carries the scope in every memory instruction (`STRONG.SM`, `STRONG.GPU`, `STRONG.SYS`), but it
builds acquire and release from separate instructions (`MEMBAR` before a release store, `CCTL.IVALL` after an
acquire load). A Kamui implementation may do the same internally; the ISA keeps one instruction so that the
memory model, its proofs and the checking tools see one event per PTX operation.

`.cluster` stays a scope of its own, because the PTX contract has it. The H100 runs it as `.gpu`, and a Kamui
implementation may do the same (being stronger than the contract is allowed). This is the one place where the ISA
does not copy the H100.

## Which memory model applies

**All memory a GPU thread can reach follows the PTX ISA 8.7 memory model:** global memory (including host memory
reached through global addresses, as with pinned or managed (unified) memory, which the `.sys` scope orders
against the host), shared memory of the CTA and of the cluster, and local memory. Kamui's memory model is PTX's,
exactly, with implementations allowed to be stronger; when Kamui adopts a newer PTX version, it adopts that
version's memory model.

How this fits RISC-V: the RISC-V memory model (RVWMO) says that "the memory consistency model for memory regions
marked as non-coherent in PMAs is currently platform-specific and/or device-specific" (unprivileged
specification, explanatory material on the memory model). GPU memory is such a region, and Kamui defines its model
as the PTX model. RVWMO, and RISC-V's rules for I/O regions, apply only to memory-mapped device registers and to
regions the platform does not mark as GPU memory.

**Plain standard loads and stores** (`lb` to `ld`, `sb` to `sd`) on GPU memory are exactly PTX `.weak` generic
accesses of that width, like the H100's plain `LD`/`LDG` without `.STRONG`. This is what lets the compiler use a
32-bit standard instruction in place of a weak Kamui load or store.

The meaning of the standard atomic and ordering instructions on GPU memory (the A extension, Zacas, Zabha,
Zalasr, Zawrs, `FENCE`) is fixed by the Kamui memory model specification. The starting proposal is the system
scope, the strongest, so that standard code stays correct; scoped code uses the Kamui instructions.

## Why

- **One instruction per PTX operation** gives the memory model, the lowering proof and Dartagnan a direct tag for
  every event; a fence sequence would have to be proved correct as a whole. AMDGPU GFX12 also puts a scope operand
  on every memory instruction.
- **The scope must not be lost**: on the H100 the three hardware levels differ 4 to 30 times in cost. A release
  fence takes 10 cycles at `.cta`, 275 at `.gpu` and 1142 at `.sys` (`fence.acq_rel`); `st.release` 15, 554
  and 1175 cycles (probes `lat-scopes-*`, `evidence/probes/README.md`).
- **Fields cost little**: a 64-bit instruction has room for scope, ordering and space fields next to its
  registers ([long-instructions.md](long-instructions.md)).
- Ordered and scoped accesses are under 1% of executed instructions in every workload we measured (job q231), so
  their encoding size does not matter; their cost when executed does.

Evidence: `evidence/sass-observations.csv` (rows `ld.scope.*`, `atom.scope.*`, `fence.*`), the litmus results in
`evidence/litmus-h100/`, the PTX 8.7 models in `models/ptx87` and the Dartagnan fork in `deps/dat3m`.
