# User-mode program for the proxy kernel (pk): Linux-style syscalls write(64) and exit(93).
  .text
  .globl _start
_start:
  li a0, 1          # fd = stdout
  la a1, msg
  li a2, 15         # length of "hello from pk!\n"
  li a7, 64         # SYS_write
  ecall
  li a0, 7          # exit code
  li a7, 93         # SYS_exit
  ecall
  .data
msg: .string "hello from pk!\n"
