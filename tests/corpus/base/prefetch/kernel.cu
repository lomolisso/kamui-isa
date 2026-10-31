// prefetch: prefetch to the L1 and L2 caches; results do not depend on it (PTX 9.7.9.15).
extern "C" __global__ void k_prefetch(const int *a, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("prefetch.global.L1 [%0];" :: "l"(&a[(i + 32) % n]));
  asm volatile("prefetch.global.L2 [%0];" :: "l"(&a[(i + 64) % n]));
  asm volatile("prefetch.L1 [%0];" :: "l"(&a[(i + 96) % n]));
  d[i] = a[i] + 1;
}
