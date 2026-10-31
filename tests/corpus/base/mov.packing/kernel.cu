// mov.packing: pack two 32-bit values into 64 bits and unpack them (PTX 9.7.9.4).
extern "C" __global__ void k_mov_packing(const unsigned *a,
                                         const unsigned *b,
                                         unsigned long long *dp,
                                         unsigned *dlo,
                                         unsigned *dhi,
                                         int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned long long p;
  unsigned lo, hi;
  asm volatile("mov.b64 %0, {%1, %2};" : "=l"(p) : "r"(a[i]), "r"(b[i]));
  asm volatile("mov.b64 {%0, %1}, %2;" : "=r"(lo), "=r"(hi) : "l"(p ^ 0x0123456789abcdefull));
  dp[i] = p;
  dlo[i] = lo;
  dhi[i] = hi;
}
