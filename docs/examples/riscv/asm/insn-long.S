# Probe: raw 48-bit and 64-bit encodings (reserved length prefixes, not ratified).
  .text
  .globl longinsn
longinsn:
  .insn 6, 0x00000000101f              # 48-bit: bits [5:0] = 011111
  .insn 8, 0x000000000000103f          # 64-bit: bits [6:0] = 0111111
  ret
