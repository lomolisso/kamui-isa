# HTIF mailbox shared by Spike and sail_riscv_sim. Writing (code << 1) | 1 to tohost ends the run.
  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
