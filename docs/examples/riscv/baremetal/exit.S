# Bare-metal RV64 test: compute 6*7, print "OK" through the HTIF console, exit with code 0 if 42.
  .section .text.init
  .globl _start
_start:
  li    a0, 6
  li    a1, 7
  mul   a2, a0, a1            # a2 = 42
  la    s0, msg
1:
  lbu   a3, 0(s0)
  beqz  a3, 3f
  li    t0, 0x0101000000000000  # device 1 (console), command 1 (putchar)
  or    t0, t0, a3
  la    t1, tohost
  sd    t0, 0(t1)
2:
  ld    t2, 0(t1)             # wait until the host has consumed the request
  bnez  t2, 2b
  addi  s0, s0, 1
  j     1b
3:
  li    t0, 42
  li    a0, 0
  beq   a2, t0, 4f
  li    a0, 3                 # exit code 3 if the multiply was wrong
4:
  slli  a0, a0, 1
  ori   a0, a0, 1
  la    t1, tohost
  sd    a0, 0(t1)
5:
  j     5b

  .data
msg: .string "OK\n"
  .include "htif.inc"
