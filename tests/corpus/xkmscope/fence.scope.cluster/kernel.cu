// fence.scope.cluster: fences at .cluster scope (PTX 9.7.13.4).
extern "C" __global__ void k_fence_scope_cluster(const unsigned *a, unsigned *d, unsigned *f, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i];
  __nvvm_fence_sc_cluster();
  f[i] = 1;
  asm volatile("fence.acq_rel.cluster;" ::: "memory");
  d[i] += 1;
}
