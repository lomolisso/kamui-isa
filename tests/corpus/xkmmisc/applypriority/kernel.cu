// applypriority: change the L2 eviction priority of a cached line (PTX 9.7.9.16).
extern "C" __global__ void k_applypriority(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  asm volatile("applypriority.global.L2::evict_normal [%0], 128;" :: "l"(&a[(i & ~31)]));
  d[i] = a[i] + 1;
}
