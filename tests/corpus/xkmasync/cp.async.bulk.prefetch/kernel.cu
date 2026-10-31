// cp.async.bulk.prefetch: bulk prefetch of global memory into L2 (PTX 9.7.9.25.4.3).
extern "C" __global__ void k_cp_async_bulk_prefetch(const unsigned *a, unsigned *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  if (threadIdx.x == 0) asm volatile("cp.async.bulk.prefetch.L2.global [%0], 512;" :: "l"(&a[128 * blockIdx.x]));
  d[i] = a[i] + 1;
}
