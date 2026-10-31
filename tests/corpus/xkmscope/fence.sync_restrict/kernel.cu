// fence.sync_restrict: fences restricted to shared::cta or shared::cluster accesses (PTX 9.7.13.4).
extern "C" __global__ void k_fence_sync_restrict(const unsigned *a, unsigned *d, unsigned *f, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i];
  asm volatile("fence.release.sync_restrict::shared::cta.cluster;" ::: "memory");
  f[i] = 1;
  asm volatile("fence.acquire.sync_restrict::shared::cluster.cluster;" ::: "memory");
}
