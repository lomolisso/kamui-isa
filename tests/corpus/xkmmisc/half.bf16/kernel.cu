// half.bf16: bf16 arithmetic: add, sub, mul, fma, min, max, scalar and packed (PTX 9.7.4).
extern "C" __global__ void k_half_bf16(const unsigned short *a,
                                       const unsigned short *b,
                                       const unsigned short *c,
                                       unsigned short *dadd,
                                       unsigned short *dmul,
                                       unsigned short *dfma,
                                       unsigned short *dmin,
                                       unsigned *dsub2,
                                       int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  __bf16 x = __builtin_bit_cast(__bf16, a[i]), y = __builtin_bit_cast(__bf16, b[i]);
  dadd[i] = __builtin_bit_cast(unsigned short, (__bf16)(x + y));
  dmul[i] = __builtin_bit_cast(unsigned short, (__bf16)(x * y));
  unsigned short f, mn;
  unsigned p;
  asm volatile("fma.rn.bf16 %0, %1, %2, %3;" : "=h"(f) : "h"(a[i]), "h"(b[i]), "h"(c[i]));
  asm volatile("min.bf16 %0, %1, %2;" : "=h"(mn) : "h"(a[i]), "h"(b[i]));
  asm volatile("sub.rn.bf16x2 %0, %1, %2;" : "=r"(p) : "r"((unsigned)a[i] << 16 | b[i]), "r"((unsigned)c[i] * 0x10001u));
  dfma[i] = f; dmin[i] = mn; dsub2[i] = p;
}
