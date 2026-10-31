// prefetchu: prefetch to the uniform cache; results do not depend on it (PTX 9.7.9.15).
extern "C" __global__ void k_prefetchu(const int *a, int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("prefetchu.L1 [%0];" :: "l"(&a[(i + 32) % n]));
  d[i] = a[i] + 1;
}
