// dp4a: four-way byte dot product with accumulate, signed and unsigned (PTX 9.7.1.23).
extern "C" __global__ void k_dp4a(const unsigned *a,
                                  const unsigned *b,
                                  const unsigned *c,
                                  int *ds,
                                  unsigned *du,
                                  int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int s;
  unsigned u;
  asm volatile("dp4a.s32.s32 %0, %1, %2, %3;" : "=r"(s) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  asm volatile("dp4a.u32.u32 %0, %1, %2, %3;" : "=r"(u) : "r"(a[i]), "r"(b[i]), "r"(c[i]));
  ds[i] = s;
  du[i] = u;
}
