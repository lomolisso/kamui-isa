# 64-bit instructions and the RISC-V long-instruction draft

Decided 2026-11-05.

Every Kamui instruction is 64 bits long (see [register-model.md](register-model.md) for why). RISC-V has no
ratified length encoding beyond 32 bits today: the old scheme for longer instructions was removed from the manual in
its 20250508 edition. A RISC-V task group is drafting a new one, the Long Instruction extensions (Zl), and the
draft reserves a quarter of the 64-bit encoding space for custom (vendor) instructions. Kamui places its
instructions in that custom space and follows the draft's layout. Kamui conforms to RISC-V **if the draft is
ratified with its custom space**. Until then the draft can change, and this document records what Kamui depends on
and what to do when it changes.

## 1. Where the specification is

| | |
|---|---|
| Repository | <https://github.com/riscv/riscv-long-instruction> (a fork of the RISC-V ISA manual) |
| Chapter | `src/unpriv/zl.adoc`; encoding figure `src/unpriv/images/bytefield/zl-encoding-scheme.edn`; 64-bit formats `src/unpriv/images/wavedrom/zl-formats64.edn` |
| Pinned version | commit `65c377a`, 2026-11-02 ("Incorporate recent discussions") |
| Status (2026-11-05) | task group draft, in the first phase of the RISC-V specification process (Inception on the RISC-V specification status dashboard, no target date) |
| Draft's own caveats | "All opcode values are tentative." "Whether to allocate custom space before the formats are settled is still open." |

Kamui's encodings follow the pinned version. When the draft moves, Kamui moves with it (section 3) and the pin in
this table is updated.

## 2. What Kamui depends on

Zl is an extension next to the 32-bit base, not a new RISC-V: "RV32I, RV64I and their extensions use 32-bit
instructions and, with C, 16-bit instructions. The Long Instruction extensions (Zl) add 48-bit and 64-bit
instructions." Standard 32-bit RISC-V instructions keep working unchanged.

The draft's 64-bit instruction, in 16-bit parcels A (`inst[15:0]`) to D (`inst[63:48]`):

| Bits | Content in the draft | Kamui |
|---|---|---|
| `inst[4:0]` | `11111`: a long instruction | fixed |
| `inst[6:5]` | group of major opcodes; `10` = "all custom" | fixed at `10` |
| `inst[31:7]` | payload (25 bits) | Kamui fields |
| `inst[33:32]` | `11`: 64 bits long (other values: 48 bits) | fixed at `11` |
| `inst[36:34]` | major opcode within the group, `000` to `110` (`111` is reserved) | Kamui uses `000` first, then `001` |
| `inst[63:37]` | payload (27 bits) | Kamui fields |

So the custom space is 7 major opcodes of 52 payload bits each. Kamui needs about one of them: roughly half of one
major opcode without guards, and about 1.5 with a 4-bit guard on every instruction and 12-bit load offsets (an
estimate made before the instruction list exists; the encoding table will give the real number).

What Kamui does **not** use: the 48-bit forms and the standard Zl instructions (long immediates, long branches,
PC-relative loads). Kamui uses only the length scheme and the custom group.

Points that are open in the draft and matter to Kamui:

- **Instruction alignment.** "Zl requires IALIGN=16", meaning instructions may start at any 2-byte boundary. That
  is needed for 48-bit instructions. Kamui has only 32-bit and 64-bit instructions, so all its instructions start at
  4-byte boundaries; the draft does not say whether a processor that implements only those may keep 4-byte
  alignment (IALIGN=32). To ask the task group.
- **Whether the custom group stays.** The draft says this is still open.

## 3. What changes when the draft changes

Kamui's semantics never depend on the draft: only where the bits sit. The table lists every kind of change and what
Kamui then updates to conform again.

| Change in the draft | Kamui must update |
|---|---|
| The length marker moves (`inst[4:0]`, `inst[33:32]` or `inst[36:34]` change meaning) | the fixed bits of every Kamui instruction: the encoding table; the Sail decode clauses; the functional simulator's decoder; the compiler's instruction encodings, assembler and disassembler; the hardware's length logic in fetch and its decoder. Then reassemble the conformance tests and recompile existing binaries |
| The custom group moves (another `inst[6:5]` value or other major opcodes) | the same list, for the group and major-opcode bits only |
| The custom space shrinks | nothing more while Kamui still fits (it needs about 1 to 1.5 of the 7 major opcodes); otherwise the same list, with Kamui's instructions packed into fewer major opcodes |
| The draft fixes where fields sit inside custom instructions | Kamui's field layout: the same list, for every format |
| Instruction alignment stays at 2 bytes | the hardware's fetch unit accepts instructions at 2-byte boundaries and the Sail model's rule for misaligned branch targets changes; Kamui code is unchanged |
| The custom group is removed, or the task group stops | technically nothing: Kamui's encodings keep working, but they sit in space the ratified manual calls reserved, so Kamui is a non-conforming extension until RISC-V offers custom space for long instructions. Kamui can then re-encode into it (first row's list) |
| Renames (the extension's name, mnemonics of standard Zl instructions) | documentation only |

Never affected: the meaning of every instruction, the register model, the memory model and its formal models, the
PTX to Kamui lowering table and its proofs, the compiler's instruction selection, and checks that read Kamui
assembly text.

Rules that keep this list short:

- **One encoding table** in this repository is the only place that says where bits sit. The Sail decoder, the
  simulator's decoder, the compiler's encodings and the hardware decoder are generated from it or checked against
  it.
- The fixed bits (marker, group, major opcode) are defined once in that table, separately from the Kamui fields.
- Kamui's instructions are packed into the lowest custom major opcodes, so a smaller custom space still holds them.
- Tests and checks are kept as assembly text, so a re-encoding is a reassembly.

## 4. Checking the draft over time

At every change to the draft's repository, and at the latest before each Kamui release:

```bash
git -C riscv-long-instruction fetch
git -C riscv-long-instruction diff 65c377a origin/main -- \
  src/unpriv/zl.adoc src/unpriv/images/bytefield/zl-encoding-scheme.edn src/unpriv/images/wavedrom/zl-formats64.edn
```

Compare the result with section 2. If anything Kamui depends on changed, apply the matching row of section 3 in
the same change that moves the pin in section 1. Also check the extension's phase on the RISC-V specification
status dashboard: when it reaches Freeze (public review) the layout is unlikely to change again, and at
Ratification Kamui's encodings become conforming.
