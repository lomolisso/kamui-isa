// cvt.pack: pack saturated narrow integers into one register (PTX 9.7.9.22).
extern "C" __global__ void k_cvt_pack(const int *a,
                                      const int *b,
                                      const unsigned *c,
                                      unsigned *d0,
                                      unsigned *d1,
                                      int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r0, r1;
  asm volatile("cvt.pack.sat.u16.s32 %0, %1, %2;" : "=r"(r0) : "r"(a[i]), "r"(b[i]));
  asm volatile("cvt.pack.sat.s8.s32.b32 %0, %1, %2, %3;" : "=r"(r1) : "r"(a[i] >> 8), "r"(b[i] >> 8), "r"(c[i]));
  d0[i] = r0; d1[i] = r1;
}
