// min.half: f16 min and max, including the NaN-propagating forms (PTX 9.7.4.7, 9.7.4.8).
extern "C" __global__ void k_min_half(const unsigned short *a,
                                      const unsigned short *b,
                                      unsigned short *d,
                                      int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned short r[4];
  unsigned short x = (i & 7) == 0 ? (unsigned short)0x7e00 : a[i];
  asm volatile("min.f16 %0, %1, %2;" : "=h"(r[0]) : "h"(x), "h"(b[i]));
  asm volatile("max.f16 %0, %1, %2;" : "=h"(r[1]) : "h"(x), "h"(b[i]));
  asm volatile("min.NaN.f16 %0, %1, %2;" : "=h"(r[2]) : "h"(x), "h"(b[i]));
  asm volatile("max.NaN.f16 %0, %1, %2;" : "=h"(r[3]) : "h"(x), "h"(b[i]));
  for (int k = 0; k < 4; k++) d[4 * i + k] = r[k];
}
