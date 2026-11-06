# Design decisions

These documents fix the execution model before the tier 1 specification is written. They were decided on
2026-11-05, from the H100 evidence in `evidence/` and the PTX memory models in `models/`.

**Guiding rule: Kamui works like the H100.** Register sizes, addresses, convergence, scopes and the uniform
datapath follow the H100, one to one, while Kamui stays a RISC-V ISA. Where Kamui departs from the H100, the
document says so and why:

- no scheduling information (stall counts, dependency barriers) in instructions: the hardware checks dependencies
  ([register-model.md](register-model.md));
- `.cluster` is a scope of its own, as PTX requires; the H100 runs it as `.gpu` ([scope-encoding.md](scope-encoding.md));
- the 32 standard RISC-V registers are pairs of Kamui registers, and standard 32-bit RISC-V instructions work on
  them ([register-model.md](register-model.md)).

| Document | Decision |
|---|---|
| [register-model.md](register-model.md) | 255 32-bit registers per thread plus a zero register, pairs for 64-bit values, 7 predicates and a guard on every instruction, 8-bit register fields, floating point in integer registers (Zfinx, Zdinx, Zhinx), the base ISA |
| [long-instructions.md](long-instructions.md) | every Kamui instruction is 64 bits long, in the custom space of the RISC-V long-instruction draft; where that draft is, what Kamui depends on, and what changes if the draft changes |
| [convergence.md](convergence.md) | independent thread scheduling with convergence barriers, required from tier 1 |
| [scope-encoding.md](scope-encoding.md) | scope and ordering fields in every memory instruction; all GPU memory follows the PTX 8.7 model; plain RISC-V loads and stores are `.weak` |
| [addressing.md](addressing.md) | the H100's window layout and its global, shared, local and generic instructions |
| [uniform-datapath.md](uniform-datapath.md) | 63 uniform registers, 7 uniform predicates, uniform instructions and operands per warp |
