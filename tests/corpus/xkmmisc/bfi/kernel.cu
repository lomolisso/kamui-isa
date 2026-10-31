// bfi: bit field insert, 32 and 64 bits (PTX 9.7.1.20).
extern "C" __global__ void k_bfi(const unsigned *a32,
                                 const unsigned *b32,
                                 unsigned *d,
                                 unsigned long long *d64,
                                 int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned pos = i & 31, len = (i >> 3) & 31;
  unsigned r;
  unsigned long long r64;
  asm volatile("bfi.b32 %0, %1, %2, %3, %4;" : "=r"(r) : "r"(a32[i]), "r"(b32[i]), "r"(pos), "r"(len));
  asm volatile("bfi.b64 %0, %1, %2, %3, %4;" : "=l"(r64) : "l"((unsigned long long)a32[i] * 0x9e3779b97f4a7c15ull),
               "l"((unsigned long long)b32[i] << 32), "r"(pos * 2), "r"(len * 2));
  d[i] = r;
  d64[i] = r64;
}
