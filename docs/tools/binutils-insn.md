# The `.insn` directive (GNU as and LLVM)

## What it is

`.insn` is an assembler directive that emits an instruction from its **format and field values**
instead of its mnemonic. Neither GNU as nor LLVM knows the Kamui `Xkm` instructions, so `.insn` is
how we write Kamui assembly until `kamui-llvm` can assemble it. Test programs for the C++ functional
simulator, the Sail model and Spike all start as `.S` files that use `.insn`, usually hidden behind
assembler macros with readable names.

Both assemblers accept the same syntax for the 32-bit formats, so one source file works with
`riscv64-unknown-elf-gcc`/`as` and with `clang`/`llvm-mc`.

## Where it runs

In the dev container (see [devcontainer.md](devcontainer.md)). Tools on `PATH`:
`riscv64-unknown-elf-{gcc,as,objdump,objcopy}` (GNU), and `clang`, `llvm-mc`, `llvm-objdump`,
`llvm-objcopy` (LLVM 20, from `/usr/lib/llvm-20/bin`).

## Version pinned

- GNU as 2.42 (`binutils-riscv64-unknown-elf` 2.42-1ubuntu1+6), GCC 13.2.0 (Ubuntu 24.04 packages).
- LLVM/clang 20.1.8 (apt.llvm.org).
- Documentation this page is based on: the GNU as manual, sections "RISC-V Directives" and "RISC-V
  Instruction Formats" (source `gas/doc/c-riscv.texi`), and the LLVM 20.1.8 sources
  `llvm/lib/Target/RISCV/AsmParser/RISCVAsmParser.cpp` (`parseDirectiveInsn`) and
  `llvm/lib/Target/RISCV/RISCVInstrInfo.td` (`InsnR` ... `Insn64`). Links are under
  [References](#references).

## Commands we use

```bash
# GNU, via the gcc driver (runs the C preprocessor on .S files)
riscv64-unknown-elf-gcc -march=rv64imafd_zicsr_zifencei_zfh_zba_zbb_zbs_zicond -mabi=lp64d -c file.S -o file.o
riscv64-unknown-elf-objdump -d file.o

# LLVM
clang --target=riscv64-unknown-elf -march=rv64imafd_zicsr_zifencei_zfh_zba_zbb_zbs_zicond -c file.S -o file.o
llvm-mc --triple=riscv64 -mattr=+m,+a,+f,+d,+zfh,+zba,+zbb,+zbs,+zicond --filetype=obj file.S -o file.o
llvm-objdump -d file.o

# Bare-metal executable for Spike or sail_riscv_sim (link at 0x80000000, see spike.md)
riscv64-unknown-elf-gcc -march=... -mabi=lp64d -nostdlib -nostartfiles -static -T link.ld -o prog.elf prog.S
```

`-march` names only standard extensions (Kamui's base ISA here). Xkm is invisible to the assembler;
that is the point of `.insn`. For the bare-metal link script and the HTIF exit convention, see
[spike.md](spike.md#input-formats).

## Input formats

### The format forms (`.insn <type> <operands>`)

`opcode` is a 7-bit number or one of the names `LOAD`, `LOAD_FP`, `CUSTOM_0`, `MISC_MEM`, `OP_IMM`,
`AUIPC`, `OP_IMM_32`, `STORE`, `STORE_FP`, `CUSTOM_1`, `AMO`, `OP`, `LUI`, `OP_32`, `MADD`, `MSUB`,
`NMSUB`, `NMADD`, `OP_FP`, `OP_V`, `CUSTOM_2`, `BRANCH`, `JALR`, `JAL`, `SYSTEM`, `OP_VE`,
`CUSTOM_3`. Both assemblers know these names (LLVM's table is in `RISCVInstrFormats.td`, lines 133
to 159).

| Form | Syntax | Fields (bit ranges) |
|---|---|---|
| R | `.insn r opcode, funct3, funct7, rd, rs1, rs2` | funct7[31:25] rs2[24:20] rs1[19:15] funct3[14:12] rd[11:7] opcode[6:0] |
| R4 | `.insn r4 opcode, funct3, funct2, rd, rs1, rs2, rs3` (also `.insn r` with 7 operands) | rs3[31:27] funct2[26:25] rs2 rs1 funct3 rd opcode |
| I | `.insn i opcode, funct3, rd, rs1, simm12` or `.insn i opcode, funct3, rd, simm12(rs1)` | imm[31:20] rs1 funct3 rd opcode |
| S | `.insn s opcode, funct3, rs2, simm12(rs1)` | imm[11:5] rs2 rs1 funct3 imm[4:0] opcode |
| B (alias SB) | `.insn b opcode, funct3, rs1, rs2, label` | branch immediate, PC-relative |
| U | `.insn u opcode, rd, simm20` | imm[31:12] rd opcode |
| J (alias UJ) | `.insn j opcode, rd, label` | jump immediate, PC-relative |
| CR, CI, CIW, CA, CB, CJ, CL, CS, CSS | compressed forms | not usable without C (LLVM refuses them unless C/Zca is on) |

### The raw forms

- `.insn <value>`: GNU and LLVM derive the length from the low bits. `11` means 32-bit, anything
  else 16-bit.
- `.insn <length>, <value>`: the length is in bytes. LLVM accepts 2, 4, 6 and 8 and refuses longer
  ("instruction lengths over 64 bits are not supported", `RISCVAsmParser.cpp` lines 3264 to 3271).
  For 6 and 8 it does not check the length-encoding bits ("the encodings for longer instructions
  are not frozen", line 3274). GNU accepts long values as big numbers and checks the value against
  the length prefix (`riscv_ip_hardcode` in `gas/config/tc-riscv.c`).

### Register constraints

- Register operands are 5-bit fields. `rd`, `rs1`, `rs2` and `rs3` accept **either** integer names
  (`x0` to `x31`, ABI names) **or** floating-point names (`f0` to `f31`, `fa0`, ...). The assembler
  only encodes the number. Nothing checks that an Xkm instruction gets the register class it
  expects: the macro layer and the tests must.
- There is no way to name a register above 31 (`x32` is rejected by both assemblers, shown below).
  If Kamui adopts register fields wider than 5 bits (an open question in the register-model
  design), `.insn` with register names stops working. Encodings would then have to be built as
  numbers, in raw `.insn 8, <expr>` forms with numeric register indices.
- Immediates are range-checked (simm12, simm20). Values outside the range are errors.

### Readable mnemonics with macros

Wrap each Xkm instruction in a macro once, in an include file shared by all tests. From
[`docs/examples/riscv/asm/xkm-macros.inc`](../examples/riscv/asm/xkm-macros.inc):

```asm
  .macro kmt.add1 rd, rs1, rs2
  .insn r CUSTOM_0, 0, 0, \rd, \rs1, \rs2
  .endm
```

Then `kmt.add1 a0, a1, a2` assembles like a real instruction in both assemblers. Notes:

- Use `.include "file.inc"` (not `#include`) so the same file works with `llvm-mc`, which does not
  run the C preprocessor. Pass search paths with `-Wa,-I<dir>` (gcc) or `-I <dir>` (llvm-mc).
- Macro names may contain dots (`kmt.add1`), like real RISC-V mnemonics.
- Kamui's real macro file (planned: `encodings/asm/xkm.inc`) should be **generated** from the
  riscv-opcodes files in `encodings/` (see [riscv-opcodes.md](riscv-opcodes.md)), so the assembler,
  the decoder tables and Sail cannot disagree.

## Output formats

Normal ELF object files. Disassemblers do not know Xkm: GNU `objdump` prints
`.insn 4, 0x00c5850b` and `llvm-objdump` prints `<unknown>`. For readable traces use the Sail
model's `assembly` mapping ([sail.md](sail.md)), Spike with an Xkm extension library, which
provides disassembly ([spike.md](spike.md)), or a small `objdump` post-processor driven by
`instr_dict.json`.

## Worked example (real output)

Input files: [`docs/examples/riscv/asm/`](../examples/riscv/asm/) (`xkm-macros.inc`,
`insn-demo.S`, `insn-long.S`, `insn-bad.S`, `insn-16.S`). Start a shell with `tools/dev.sh` at the
repository root, then work inside the example folder so that the file names in error messages match
the outputs below. Objects go to `build/examples/riscv/`:

```bash
ISA=rv64imafd_zicsr_zifencei_zfh_zba_zbb_zbs_zicond
OUT=$PWD/build/examples/riscv
mkdir -p $OUT
cd docs/examples/riscv/asm
```

The demo uses every 32-bit form:

```asm
  .include "xkm-macros.inc"
  .text
  .globl demo
demo:
  kmt.add1 a0, a1, a2                 # macro, R type, custom-0
  kmt.mix  t0, t1, t2
  .insn r  0x0b, 0, 1, a3, a4, a5     # numeric opcode instead of CUSTOM_0
  .insn r  CUSTOM_1, 7, 0x7f, s1, s2, s3
  .insn r4 CUSTOM_2, 1, 2, fa0, fa1, fa2, fa3   # R4 type, FP registers allowed
  .insn i  CUSTOM_0, 2, a0, a1, -5    # I type
  .insn i  CUSTOM_0, 3, a0, 16(a1)    # I type, load-like syntax
  .insn s  CUSTOM_1, 2, a2, 8(a1)     # S type
  .insn b  CUSTOM_3, 1, a0, a1, demo  # B type (branch to a label)
  .insn u  CUSTOM_3, a0, 0x12345      # U type
  .insn j  CUSTOM_3, a0, demo         # J type
  .insn 0x00c5850b                    # raw 32-bit word (kmt.add1 a0, a1, a2)
  .insn 4, 0x00c5850b                 # raw with explicit length
  ret
```

GNU:

```
$ riscv64-unknown-elf-gcc -march=$ISA -mabi=lp64d -c insn-demo.S -o $OUT/demo-gnu.o
$ riscv64-unknown-elf-objdump -d $OUT/demo-gnu.o
...
0000000000000000 <demo>:
   0:	00c5850b          	.insn	4, 0x00c5850b
   4:	0273028b          	.insn	4, 0x0273028b
   8:	02f7068b          	.insn	4, 0x02f7068b
   c:	ff3974ab          	.insn	4, 0xff3974ab
  10:	6cc5955b          	.insn	4, 0x6cc5955b
  14:	ffb5a50b          	.insn	4, 0xffb5a50b
  18:	0105b50b          	.insn	4, 0x0105b50b
  1c:	00c5a42b          	.insn	4, 0x00c5a42b
  20:	feb510fb          	.insn	4, 0xfeb510fb
  24:	1234557b          	.insn	4, 0x1234557b
  28:	fd9ff57b          	.insn	4, 0xfd9ff57b
  2c:	00c5850b          	.insn	4, 0x00c5850b
  30:	00c5850b          	.insn	4, 0x00c5850b
  34:	00008067          	ret
```

LLVM (`llvm-mc` and `clang -c` both succeed with exit status 0 on the same file):

```
$ llvm-mc --triple=riscv64 -mattr=+m,+a,+f,+d,+zfh,+zba,+zbb,+zbs,+zicond --filetype=obj insn-demo.S -o $OUT/demo-mc.o
$ clang --target=riscv64-unknown-elf -march=$ISA -c insn-demo.S -o $OUT/demo-clang.o
$ llvm-objdump -d $OUT/demo-clang.o
...
0000000000000000 <demo>:
       0: 00c5850b     	<unknown>
       4: 0273028b     	<unknown>
       8: 02f7068b     	<unknown>
       c: ff3974ab     	<unknown>
      10: 6cc5955b     	<unknown>
      14: ffb5a50b     	<unknown>
      18: 0105b50b     	<unknown>
      1c: 00c5a42b     	<unknown>
      20: 00b5107b     	<unknown>
      24: 1234557b     	<unknown>
      28: 0000057b     	<unknown>
      2c: 00c5850b     	<unknown>
      30: 00c5850b     	<unknown>
      34: 00008067     	ret
```

All words are identical except the two label-relative ones at `0x20` (B) and `0x28` (J). Both
objects carry the same relocations there (`R_RISCV_BRANCH demo`, `R_RISCV_JAL demo`). GNU also fills
in the offset; LLVM leaves zero for the linker. After linking they are the same. The `llvm-mc` and
`clang` objects are byte-identical. To compare the `.text` bytes yourself:

```bash
riscv64-unknown-elf-objcopy -O binary -j .text $OUT/demo-gnu.o $OUT/gnu.bin
llvm-objcopy -O binary -j .text $OUT/demo-mc.o $OUT/mc.bin
llvm-objcopy -O binary -j .text $OUT/demo-clang.o $OUT/clang.bin
sha256sum $OUT/gnu.bin $OUT/mc.bin $OUT/clang.bin
```

Check by hand that the macro produced the right bits. `kmt.add1 a0, a1, a2` has funct7 0, rs2 = 12,
rs1 = 11, funct3 0, rd = 10 and opcode 0x0B, so `(12<<20)|(11<<15)|(10<<7)|0x0b = 0x00c5850b`. This
matches `MATCH_KMT_ADD1 = 0xb`, `MASK = 0xfe00707f` from riscv-opcodes (see
[riscv-opcodes.md](riscv-opcodes.md#worked-example-real-output)).

Long encodings (`insn-long.S`), both with exit status 0:

```
$ riscv64-unknown-elf-as -march=$ISA insn-long.S -o $OUT/long-gnu.o
$ riscv64-unknown-elf-objdump -d $OUT/long-gnu.o | tail -5
0000000000000000 <longinsn>:
   0:	101f 0000 0000      	.insn	6, 0x101f
   6:	0000103f 00000000 	.insn	8, 0x103f
   e:	00008067          	ret

$ llvm-mc --triple=riscv64 --filetype=obj insn-long.S -o $OUT/long-mc.o
$ llvm-objdump -d $OUT/long-mc.o | tail -5
       0: 101f 0000 0000       	<unknown>
       6: 0000103f 00000000    	<unknown>
       e: 00008067     	ret
```

Register constraint (`insn-bad.S`):

```
$ riscv64-unknown-elf-as -march=$ISA insn-bad.S -o /dev/null
insn-bad.S:3: Error: illegal operands `r CUSTOM_0,0,0,x32,a1,a2'
$ llvm-mc --triple=riscv64 --filetype=obj insn-bad.S -o /dev/null
insn-bad.S:3:27: error: invalid operand for instruction
  .insn r CUSTOM_0, 0, 0, x32, a1, a2
                          ^
```

## Limitations and gotchas

- No disassembly of Xkm. Debugging needs our own decoder (see [Output formats](#output-formats)).
- `.insn` does not know operand types: an FP register in an integer slot assembles silently.
- 48-bit instructions are accepted by both assemblers, but Spike treats them as illegal without Zca
  (see [spike.md](spike.md#limitations-and-gotchas)), and riscv-opcodes cannot describe them.
- Without C (`-march` with no `c`), GNU still lets you write 16-bit raw `.insn`; LLVM refuses
  ("compressed instructions are not allowed"). `insn-16.S` contains two such lines if you want to
  see it. Do not use 16-bit forms.
- B and J forms with labels produce relocations, so GNU and LLVM objects differ before linking.
- `#include` works only through the compiler driver (`gcc`/`clang` on `.S`). Use `.include` for
  portability to `llvm-mc`.

## How Kamui uses it

- **Generated macros.** `encodings/asm/xkm.inc` (planned) is generated from the riscv-opcodes files.
  Its check: assemble a file that uses every Xkm macro with both GNU and LLVM, and compare each word
  with `MATCH`/`MASK` from `encoding.out.h`.
- **Hand-written test programs.** Programs such as vector add, shuffle reduction, barrier and
  atomics tests are `.S` files that use those macros, linked at `0x80000000`, and run on Sail, the
  C++ functional simulator and optionally Spike.
- **Evidence for the encoding design.** 48-bit and 64-bit raw `.insn` work in both assemblers, but
  register names cannot go above 31. This matters for the open register-model question (5-bit
  register fields against wider ones).

## References

- GNU as manual, RISC-V dependent features:
  <https://sourceware.org/binutils/docs/as/RISC_002dV_002dDirectives.html> and
  <https://sourceware.org/binutils/docs/as/RISC_002dV_002dFormats.html>.
- GNU as source (binutils 2.42), `gas/config/tc-riscv.c`:
  <https://sourceware.org/git/?p=binutils-gdb.git;a=blob;f=gas/config/tc-riscv.c;hb=refs/tags/binutils-2_42>.
- LLVM 20.1.8 source:
  [`RISCVAsmParser.cpp`](https://github.com/llvm/llvm-project/blob/llvmorg-20.1.8/llvm/lib/Target/RISCV/AsmParser/RISCVAsmParser.cpp)
  (`parseDirectiveInsn`),
  [`RISCVInstrInfo.td`](https://github.com/llvm/llvm-project/blob/llvmorg-20.1.8/llvm/lib/Target/RISCV/RISCVInstrInfo.td)
  (`InsnR`, `InsnR4`, `InsnI`, `InsnS`, `InsnB`, `InsnU`, `InsnJ`, `Insn32`, `Insn48`, `Insn64`),
  [`RISCVInstrFormats.td`](https://github.com/llvm/llvm-project/blob/llvmorg-20.1.8/llvm/lib/Target/RISCV/RISCVInstrFormats.td)
  (opcode names).
- RISC-V assembly programmer's manual: <https://github.com/riscv-non-isa/riscv-asm-manual>.
