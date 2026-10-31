// cnot: C logical not: 1 when the source is zero, else 0 (PTX 9.7.8.5).
extern "C" __global__ void k_cnot(const unsigned *a, unsigned *d, unsigned long long *d64, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned r;
  unsigned long long r64;
  asm volatile("cnot.b32 %0, %1;" : "=r"(r) : "r"(a[i] & (i & 1 ? 0u : ~0u)));
  asm volatile("cnot.b64 %0, %1;" : "=l"(r64) : "l"((unsigned long long)(i & 2 ? 0 : a[i])));
  d[i] = r;
  d64[i] = r64;
}
