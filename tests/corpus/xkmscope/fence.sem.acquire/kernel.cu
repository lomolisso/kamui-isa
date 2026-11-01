// fence.sem.acquire: the lightweight .acquire and .release fences of PTX 8.6 (PTX 9.7.13.4).
extern "C" __global__ void k_fence_sem_acquire(const unsigned *a, unsigned *d, unsigned *f, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i];
  asm volatile("fence.release.gpu;" ::: "memory");
  f[i] = 1;
  asm volatile("fence.acquire.gpu;" ::: "memory");
  d[i] += 1;
}
