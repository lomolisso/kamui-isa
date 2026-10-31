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
