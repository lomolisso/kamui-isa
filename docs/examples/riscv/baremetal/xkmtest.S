# Uses the toy Xkmtest custom-0 instructions, then exits through HTIF with a0 as the exit code.
  .include "xkm-macros.inc"
  .section .text.init
  .globl _start
_start:
  li       a1, 40
  li       a2, 1
  kmt.add1 a3, a1, a2         # a3 = 40 + 1 + 1 = 42
  li       t0, 42
  li       a0, 0
  beq      a3, t0, 1f
  li       a0, 5
1:
  slli     a0, a0, 1
  ori      a0, a0, 1
  la       t1, tohost
  sd       a0, 0(t1)
2:
  j        2b
  .include "htif.inc"
