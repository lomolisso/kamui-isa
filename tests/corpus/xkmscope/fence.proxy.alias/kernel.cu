// fence.proxy.alias: fence between accesses through different virtual aliases (PTX 9.7.13.4).
extern "C" __global__ void k_fence_proxy_alias(const unsigned *a, unsigned *d, unsigned *d2, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i];
  asm volatile("fence.proxy.alias;" ::: "memory");
  d2[i] = d[i] + 1;
}
