// szext: sign- or zero-extend from a bit position, clamp and wrap modes (PTX 9.7.1.21).
extern "C" __global__ void k_szext(const unsigned *a,
                                   const unsigned *b,
                                   int *d0,
                                   int *d1,
                                   unsigned *d2,
                                   int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int r0, r1;
  unsigned r2;
  asm volatile("szext.clamp.s32 %0, %1, %2;" : "=r"(r0) : "r"(a[i]), "r"(b[i]));
  asm volatile("szext.wrap.s32 %0, %1, %2;" : "=r"(r1) : "r"(a[i]), "r"(b[i]));
  asm volatile("szext.clamp.u32 %0, %1, %2;" : "=r"(r2) : "r"(a[i]), "r"(b[i]));
  d0[i] = r0; d1[i] = r1; d2[i] = r2;
}
