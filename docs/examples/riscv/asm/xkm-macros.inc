# Readable mnemonics for the toy Xkmtest instructions (custom-0, funct3 = 0).
# .insn r opcode, funct3, funct7, rd, rs1, rs2
  .macro kmt.add1 rd, rs1, rs2
  .insn r CUSTOM_0, 0, 0, \rd, \rs1, \rs2
  .endm
  .macro kmt.mix rd, rs1, rs2
  .insn r CUSTOM_0, 0, 1, \rd, \rs1, \rs2
  .endm
