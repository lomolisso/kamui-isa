# Each lane computes a1 = a0*a0 + 1 (a0 = lane id, set by the driver)
# and stores it into results[a0] in the one shared memory.
  .section .text.init
  .globl _start
_start:
  mul   a1, a0, a0
  addi  a1, a1, 1
  la    t0, results
  slli  t1, a0, 3
  add   t0, t0, t1
  sd    a1, 0(t0)
1:
  j     1b
  .data
  .globl results
results: .dword 0, 0, 0, 0
