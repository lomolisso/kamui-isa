// ex2.half: approximate 2^x on f16, f16x2 and bf16 (PTX 9.7.4.10).
extern "C" __global__ void k_ex2_half(const unsigned short *a,
                                      const unsigned short *b,
                                      unsigned short *d,
                                      unsigned *d2,
                                      unsigned short *db,
                                      int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned short h, bh;
  unsigned h2;
  asm volatile("ex2.approx.f16 %0, %1;" : "=h"(h) : "h"(a[i]));
  asm volatile("ex2.approx.f16x2 %0, %1;" : "=r"(h2) : "r"((unsigned)a[i] * 0x10001u));
  asm volatile("ex2.approx.ftz.bf16 %0, %1;" : "=h"(bh) : "h"(b[i]));
  d[i] = h; d2[i] = h2; db[i] = bh;
}
