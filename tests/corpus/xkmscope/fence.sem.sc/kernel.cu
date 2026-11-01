// fence.sem.sc: sequentially consistent fence from C++ (PTX 9.7.13.4).
extern "C" __global__ void k_fence_sem_sc(const unsigned *a, unsigned *d, unsigned *f, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  d[i] = a[i];
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  f[i] = 1;
}
