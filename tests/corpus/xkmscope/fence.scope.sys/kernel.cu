// fence.scope.sys: acq_rel and sc fences at .sys scope (PTX 9.7.13.4).
extern "C" __global__ void k_fence_scope_sys(const unsigned *a, unsigned *d, unsigned *f, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i];
  asm volatile("fence.acq_rel.sys;" ::: "memory");
  f[i] = 1;
  asm volatile("fence.sc.sys;" ::: "memory");
  d[i] += 1;
}
