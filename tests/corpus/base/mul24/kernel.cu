// mul24: 24-bit multiply, .lo and .hi (PTX 9.7.1.5).
extern "C" __global__ void k_mul24(const int *a, const int *b, int *d, unsigned *du, int *dhi, int *dc, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int lo, h;
  unsigned ulo;
  asm volatile("mul24.lo.s32 %0, %1, %2;" : "=r"(lo) : "r"(a[i]), "r"(b[i]));
  asm volatile("mul24.lo.u32 %0, %1, %2;" : "=r"(ulo) : "r"(a[i]), "r"(b[i]));
  asm volatile("mul24.hi.s32 %0, %1, %2;" : "=r"(h) : "r"(a[i]), "r"(b[i]));
  d[i] = lo;
  du[i] = ulo;
  dhi[i] = h;
  dc[i] = __mul24(a[i], b[i]);
}
