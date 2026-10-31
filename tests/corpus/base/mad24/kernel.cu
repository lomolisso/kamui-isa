// mad24: 24-bit multiply-add, .lo and .hi (PTX 9.7.1.6).
extern "C" __global__ void k_mad24(const int *a, const int *b, const int *c, int *dlo, int *dhi, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int lo, hi;
  asm volatile("mad24.lo.s32 %0, %1, %2, %3;" : "=r"(lo) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  asm volatile("mad24.hi.u32 %0, %1, %2, %3;" : "=r"(hi) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  dlo[i] = lo;
  dhi[i] = hi;
}
