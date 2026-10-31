// bfe: bit field extract, unsigned and signed, 32 and 64 bits (PTX 9.7.1.19).
extern "C" __global__ void k_bfe(const unsigned *a32,
                                 unsigned *du,
                                 int *ds,
                                 const unsigned long long *a64,
                                 unsigned long long *d64,
                                 int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned pos = i & 31, len = (i >> 3) & 31;
  unsigned u;
  int s;
  unsigned long long u64;
  asm volatile("bfe.u32 %0, %1, %2, %3;" : "=r"(u) : "r"(a32[i]), "r"(pos), "r"(len));
  asm volatile("bfe.s32 %0, %1, %2, %3;" : "=r"(s) : "r"(a32[i]), "r"(pos), "r"(len));
  asm volatile("bfe.u64 %0, %1, %2, %3;" : "=l"(u64) : "l"(a64[i]), "r"(pos * 2), "r"(len * 2));
  du[i] = u;
  ds[i] = s;
  d64[i] = u64;
}
