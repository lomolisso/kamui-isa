# Register model

Decided 2026-11-05.

## Question

How many registers can a Kamui thread name, how wide are they, and how do Kamui's registers relate to the 32
standard RISC-V registers? PTX registers are unlimited virtual registers. `ptxas` gives an H100 thread up to 255
32-bit registers, and Hopper kernels move registers between warpgroups at run time with `setmaxnreg`. A standard
RISC-V instruction names 32 registers with 5-bit fields.

## Decision

Kamui's registers are the H100's registers.

| State, per thread | Kamui | H100 |
|---|---|---|
| General registers | `R0` to `R254`, 32 bits each | the same |
| Zero register | `RZ` (register number 255): reads 0, writes are ignored | the same |
| 64-bit values (addresses, `.u64`, `.f64`) | an aligned pair `R2k:R2k+1`, low half in the even register | the same |
| Predicate registers | `P0` to `P6`; `PT` (number 7) reads true | the same |

Per warp there are uniform registers and uniform predicates as well (see [uniform-datapath.md](uniform-datapath.md)).

**Encoding.** Every Kamui instruction is 64 bits long (see [long-instructions.md](long-instructions.md)). A
register field is 8 bits wide, so an instruction names any of the 256 registers directly; an FMA with four register
operands uses 32 of the 52 free bits. A predicate field is 3 bits. Every Kamui instruction carries a guard: a
predicate register and a negate bit (`@P0`, `@!P0`; `@PT` means no guard), as on the H100. A 64-bit operand whose
register number is odd is reserved (the instruction is illegal).

**Standard RISC-V registers.** Kamui is RV64, so it also has the 32 standard 64-bit registers. They are pairs of
Kamui registers:

| Standard register | Kamui registers |
|---|---|
| `x0` | `RZ` (zero) |
| `x1` | `R0:R1` |
| `x2` | `R2:R3` |
| `xk` (1 to 31) | `R(2k-2):R(2k-1)` |
| `x31` | `R60:R61` |

A standard instruction does exactly what the RISC-V specification says, on these pairs. For example `addw x1, x2,
x3` adds the low halves `R2` and `R4`, writes the sum to `R0`, and writes its sign extension to `R1`. Registers
`R62` to `R254` are reachable only through Kamui instructions.

**Floating point.** Kamui uses the standard extensions for floating point in integer registers: Zfinx, Zdinx and
Zhinx. There is no separate `f` register file, as on the H100, where integer and floating-point values share one
file. A standard single-precision instruction works on an `x` register (a pair) and fills the high half with copies
of the sign bit (the Zfinx rule). Kamui's own floating-point instructions work on one 32-bit register (`.f32`,
`.f16x2`, `.bf16x2`) or on a pair (`.f64`).

**`setmaxnreg`** keeps its PTX meaning: it changes the number of 32-bit registers per thread of a warpgroup, as
on the H100.

**No scheduling information in instructions.** H100 instructions carry stall counts, a yield bit, dependency
barrier indices and register reuse flags, set by `ptxas`. Kamui instructions do not: the hardware checks
dependencies itself, so a Kamui binary is correct on every Kamui implementation, and the specification, the Sail
model and the functional simulator contain no pipeline timing. This is a deliberate difference from the H100.

**State beyond the standard registers.** `R62` to `R254`, the predicates and the uniform state are not part of
the standard `x` registers. Code that saves only the `x` registers (a trap handler written for standard RISC-V)
does not save them; Kamui provides its own instructions to save and restore them, in the same way the vector
extension adds its own state.

**Compiler.** The compiler first emits Kamui 64-bit instructions only. Later it may replace a Kamui instruction by
a standard 32-bit RISC-V instruction when the two have the same effect: the Kamui instruction has no guard and no
qualifier the standard one lacks, its operands are standard registers (`R0` to `R61` as the pairs above), and
nothing still reads a register that the standard instruction writes but the Kamui one does not (for example the
high half that `addw` sign-extends into). Plain standard loads and stores are `.weak` accesses (see
[scope-encoding.md](scope-encoding.md)), so they can replace weak Kamui loads and stores under the same rule.

## Base ISA

RV64 with I, M, A, Zicsr, Zfinx, Zdinx, Zhinx, Zba, Zbb, Zbs, Zicond, Zacas, Zalasr, Zabha, Zawrs, Zicntr, Zihpm,
Zicbop, Zicbom, Zihintntl, Zihintpause, Zbkb and Zbkx, plus the Kamui extensions (`Xkm*`) in 64-bit instructions.
No C, no V, no F, D, Zfh, Zfa or Zfbfmin.

Consequences of choosing Zfinx over F and D:

- Software built for F and D does not run on Kamui. The RISC-V specification states it: "software that assumes the
  presence of the F extension is incompatible with software that assumes the presence of the Zfinx extension, and
  vice versa." Kamui code comes from Kamui's own compiler, so this costs nothing for GPU kernels. Kamui is
  therefore not an RVA23 (application profile) processor; it does not try to be one.
- Zfa and Zfbfmin depend on F, so Kamui cannot include them. The operations PTX needs from them (minimum and
  maximum with PTX's NaN rules, bfloat16 conversions) are Kamui instructions.

## Why

Measured on the H100 (`evidence/histograms/README.md`, jobs q231 and q237; `evidence/histograms/occupancy.csv`):

- Of 202 kernel rows, 84 use more than 32 registers, 48 more than 64, 34 more than 128 and 6 more than 168.
  flash-attn 2 uses 255 registers and still spills; the warp-specialized Hopper GEMMs launch with 168 registers
  and rebalance to 40/232 (or 24/240) with `setmaxnreg`.
- Registers limit occupancy in 111 of 149 kernels measured with Nsight Compute.
- An increase with `setmaxnreg` waits until another warpgroup has released registers (probes `setmaxnreg-*`,
  `evidence/probes/README.md`).

Kamui must run these kernels without spilling more than the H100 does, so a thread needs 255 32-bit registers.
Plain 8-bit fields give that without register banks, prefixes or mode bits, which would complicate the compiler and
add hidden state to every instruction. Those fields do not fit in 32-bit instructions: three 8-bit fields leave room
for only 8 operations in all of RISC-V's custom 32-bit space, and an FMA needs four. NVIDIA uses 128-bit
instructions; Kamui uses 64-bit ones.

32-bit registers keep the H100's capacity and allocation: the same number of registers per thread, the same
pairs for 64-bit values, the same `setmaxnreg` granularity.

## Alternatives considered

| Alternative | Why not |
|---|---|
| 8-bit fields in the 32-bit space left free by omitting C | too small: the base instructions alone need about 2^38.6 code points, the space holds 2^31.6 |
| 5-bit fields plus a mode that sets the high register bits (AMD gfx1250) or a prefix instruction (Ventus) | conforming today, but every instruction depends on hidden state; the compiler needs an extra pass, and code size grows with each prefix |
| A separate register file for matrix accumulators, 32 + 32 ordinary registers | kernels like flash-attn 2 spill above 64 ordinary registers |
| Accumulators in a separate tensor memory (Blackwell `tcgen05`) | not how Hopper code works; can be added later as an extension |
| 64-bit registers, 128 or 256 names | 128 holds the H100's bytes only if every value is packed two per register; 256 doubles the storage per thread |
