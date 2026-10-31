// slct: select on the sign of a third operand, integer and float selector (PTX 9.7.6.4).
extern "C" __global__ void k_slct(const int *a, const int *b, const int *c, int *d0, int *d1, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int r0, r1;
  asm volatile("slct.s32.s32 %0, %1, %2, %3;" : "=r"(r0) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  asm volatile("slct.s32.f32 %0, %1, %2, %3;" : "=r"(r1) : "r"(a[i]), "r"(b[i]), "f"((float)c[i] * 0.5f));
  d0[i] = r0;
  d1[i] = r1;
}
