// dp2a: two-way 16-bit by 8-bit dot product, .lo and .hi bytes (PTX 9.7.1.24).
extern "C" __global__ void k_dp2a(const unsigned *a,
                                  const unsigned *b,
                                  const unsigned *c,
                                  int *dlo,
                                  unsigned *dhi,
                                  int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int lo;
  unsigned hi;
  asm volatile("dp2a.lo.s32.s32 %0, %1, %2, %3;" : "=r"(lo) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  asm volatile("dp2a.hi.u32.u32 %0, %1, %2, %3;" : "=r"(hi) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  dlo[i] = lo;
  dhi[i] = hi;
}
