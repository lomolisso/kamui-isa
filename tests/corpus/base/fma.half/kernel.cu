// fma.half: half-precision fused multiply-add, with .relu (PTX 9.7.4.4).
extern "C" __global__ void k_fma_half(const _Float16 *a,
                                      const _Float16 *b,
                                      const _Float16 *c,
                                      _Float16 *d,
                                      _Float16 *drelu,
                                      int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = __builtin_fmaf16(a[i], b[i], c[i]);
  _Float16 r;
  asm volatile("fma.rn.relu.f16 %0, %1, %2, %3;" : "=h"(*(unsigned short *)&r)
               : "h"(*(const unsigned short *)&a[i]), "h"(*(const unsigned short *)&b[i]),
                 "h"(*(const unsigned short *)&c[i]));
  drelu[i] = r;
}
