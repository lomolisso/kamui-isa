// fence.scope.gpu: acq_rel and sc fences at .gpu scope (PTX 9.7.13.4).
extern "C" __global__ void k_fence_scope_gpu(const unsigned *a, unsigned *d, unsigned *f, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i];
  asm volatile("fence.acq_rel.gpu;" ::: "memory");
  f[i] = 1;
  asm volatile("fence.sc.gpu;" ::: "memory");
  d[i] += 1;
}
