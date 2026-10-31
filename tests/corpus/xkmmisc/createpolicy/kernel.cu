// createpolicy: build an L2 cache policy and use it on a load with .L2::cache_hint (PTX 9.7.9.18, 9.7.9.2).
extern "C" __global__ void k_createpolicy(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  unsigned long long pol;
  unsigned r;
  asm volatile("createpolicy.fractional.L2::evict_last.b64 %0, 1.0;" : "=l"(pol));
  asm volatile("ld.global.L2::cache_hint.u32 %0, [%1], %2;" : "=r"(r) : "l"(&a[i]), "l"(pol));
  d[i] = r + 1;
}
