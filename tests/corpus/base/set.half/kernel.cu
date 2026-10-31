// set.half: half-precision compare to a register (PTX 9.7.7.1).
extern "C" __global__ void k_set_half(const _Float16 *a,
                                      const _Float16 *b,
                                      unsigned short *d,
                                      unsigned *du,
                                      int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned short r;
  unsigned u;
  asm volatile("set.lt.f16.f16 %0, %1, %2;" : "=h"(r) : "h"(*(const unsigned short *)&a[i]),
               "h"(*(const unsigned short *)&b[i]));
  asm volatile("set.ge.u32.f16 %0, %1, %2;" : "=r"(u) : "h"(*(const unsigned short *)&a[i]),
               "h"(*(const unsigned short *)&b[i]));
  d[i] = r;
  du[i] = u;
}
