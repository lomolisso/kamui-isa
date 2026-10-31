// fence.sem.acq_rel: acquire-release fence (PTX 9.7.13.4).
extern "C" __global__ void k_fence_sem_acq_rel(const unsigned *a, unsigned *d, unsigned *f, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i];
  asm volatile("fence.acq_rel.gpu;" ::: "memory");
  f[i] = 1;
}
